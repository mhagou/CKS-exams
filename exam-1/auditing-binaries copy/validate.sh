#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only validation. Optional arguments: candidate checksum evidence files.
STATE=/var/lib/cks-auditing-binaries
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
pass=0 fail=0
report() {
    if [[ $1 == 0 ]]; then echo "[PASS] $2"; pass=$((pass+1));
    else echo "[FAIL] $2"; fail=$((fail+1)); fi
}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if [[ $EUID != 0 || ! -s $STATE/reference.sha512 || ! -s $STATE/container.id ]]; then
    report 1 'Run as root on the prepared controlplane; setup state is required.'
    echo "Totals: $pass passed, $fail failed"
    echo 'RESULT: FAILED'
    exit 1
fi
ok=1
if systemctl is-active --quiet kubelet &&
   kubectl get --raw /api/v1/nodes/controlplane/proxy/configz > "$work/configz" 2>/dev/null &&
   python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["kubeletconfig"]["authentication"]["anonymous"]["enabled"] is not False)' "$work/configz"; then ok=0; fi
report "$ok" 'Controlplane kubelet is healthy and effective anonymous authentication is disabled.'
kube-bench run --targets node --json > "$work/bench.json" 2> "$work/bench.err" || true
ok=0
python3 - "$work/bench.json" <<'PY' || ok=1
import json, sys
def checks(x):
    if isinstance(x, dict):
        if 'anonymous' in str(x.get('test_desc', '')).lower() and 'status' in x: yield x
        for v in x.values(): yield from checks(v)
    elif isinstance(x, list):
        for v in x: yield from checks(v)
try:
    matches = list(checks(json.load(open(sys.argv[1]))))
    sys.exit(0 if matches and all(c['status'] == 'PASS' for c in matches) else 1)
except (ValueError, OSError): sys.exit(1)
PY
report "$ok" 'kube-bench anonymous-auth check passes on controlplane.'
# Observation cannot be proven retrospectively. Accept saved before/after hashes
# even if the candidate restored the manifest after the demonstration.
if (($#)); then printf '%s\0' "$@" > "$work/evidence";
else find /root /home /tmp -type f -size -2M -print0 > "$work/evidence" 2>/dev/null || true; fi
reference=$(awk 'NR==1 {print $1}' "$STATE/reference.sha512")
found=false
changed=false
while IFS= read -r -d '' file; do
    [[ $file != "$STATE/"* && $file != "$work/"* && -r $file ]] || continue
    # Resolve aliases so supplying the setup reference itself is not evidence.
    resolved=$(readlink -f -- "$file") || continue
    [[ $resolved != "$STATE/"* && $resolved != "$work/"* ]] || continue
    if awk -v hash="$reference" 'tolower($1)==hash {found=1} END {exit !found}' "$file" 2>/dev/null; then found=true; fi
    # A second saved digest must identify the manifest, not an unrelated file.
    if awk -v hash="$reference" '
        length($1)==128 && $1 !~ /[^[:xdigit:]]/ && tolower($1)!=hash &&
        ($2=="/etc/kubernetes/manifests/kube-apiserver.yaml" ||
         $2=="kube-apiserver.yaml" || $2=="*/etc/kubernetes/manifests/kube-apiserver.yaml") {found=1}
        END {exit !found}' "$file" 2>/dev/null; then changed=true; fi
done < "$work/evidence"
ok=1
if $found; then ok=0; fi
report "$ok" 'Candidate saved the original API server manifest SHA-512 hash.'
ok=1
if current=$(sha512sum /etc/kubernetes/manifests/kube-apiserver.yaml 2>/dev/null); then
    if [[ ${current%% *} != "$reference" ]] || $changed; then ok=0; fi
fi
report "$ok" 'Changed manifest checksum is observable or saved as evidence.'
ok=1
if kubectl get --raw /readyz > /dev/null 2>&1; then ok=0; fi
report "$ok" 'API server remains ready after the manifest change.'
ok=0
ssh -o BatchMode=yes -o ConnectTimeout=10 node01 'bash -s' -- "$(cat "$STATE/container.id")" <<'REMOTE' || ok=1
set -Eeuo pipefail
# A successful list, rather than a failed inspect, distinguishes removal from
# an unreachable runtime. Include exited containers: stopping alone is insufficient.
ids=$(crictl ps -a -q --no-trunc)
while IFS= read -r id; do [[ $id != "$1" ]] || exit 1; done <<< "$ids"
# Limit validation to the specific container requested by the task. Other
# containers and similarly named host processes may belong to another lab.
REMOTE
report "$ok" 'Worker simulation container is stopped and removed from the runtime.'
printf 'Totals: %d passed, %d failed\n' "$pass" "$fail"
if ((fail == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
echo 'RESULT: FAILED'
exit 1
