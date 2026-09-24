#!/usr/bin/env bash
set -Eeuo pipefail

# Run on controlplane in the playground only. The assessment is supplied by
# task.txt; running a full kube-bench scan is not part of this exercise.
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01)
trap 'echo "ERROR: scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl ssh; do
    command -v "$tool" >/dev/null || { echo "Missing required playground tool: $tool" >&2; exit 1; }
done
# jq parses the effective configuration returned by the kubelet API.
if ! command -v jq >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install jq before running setup.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y -qq jq
fi
kubectl --request-timeout=15s get node node01 >/dev/null
kubectl --request-timeout=15s get --raw /api/v1/nodes/node01/proxy/configz | jq -e '.kubeletconfig | type == "object"' >/dev/null

"${SSH[@]}" bash -s <<'REMOTE'
set -Eeuo pipefail
config=/var/lib/kubelet/config.yaml
[[ -f $config ]] || { echo 'Worker kubelet configuration is missing.' >&2; exit 1; }
systemctl is-active --quiet kubelet
# A YAML parser is necessary to preserve unrelated configuration values and
# support ordinary YAML formatting. Install only if absent, on the playground.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    command -v apt-get >/dev/null || { echo 'Worker requires python3 and python3-yaml.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y -qq python3 python3-yaml
fi
pid=$(systemctl show kubelet -p MainPID --value)
python3 - "$pid" "$config" <<'PY'
import pathlib, sys
args = pathlib.Path('/proc/' + sys.argv[1] + '/cmdline').read_bytes().decode().split('\0')
def option(name):
    for i, arg in enumerate(args):
        if arg.startswith(name + '='):
            return arg.split('=', 1)[1]
        if arg == name:
            return args[i + 1] if i + 1 < len(args) else ''
    return None
if option('--config') != sys.argv[2]:
    sys.exit('Worker kubelet is not using the task configuration path; no configuration changed.')
# Do not overwrite service arguments or unrelated drop-ins to force this lab.
for flag in ('--authorization-mode', '--protect-kernel-defaults', '--config-dir'):
    if option(flag) is not None:
        sys.exit('Worker has configuration overrides (' + flag + '); resolve these before setup. No configuration changed.')
PY
backup_dir=/var/lib/cks-kubebench-lab
install -d -m 700 "$backup_dir"
[[ -e $backup_dir/config.yaml.original ]] || cp -p "$config" "$backup_dir/config.yaml.original"
rollback=$(mktemp "$backup_dir/rollback.XXXXXX")
cp -p "$config" "$rollback"
restore_on_error() {
    status=$?
    trap - ERR
    cp -p "$rollback" "$config"
    systemctl restart kubelet || true
    rm -f "$rollback"
    echo 'Worker preparation failed; the previous kubelet configuration was restored.' >&2
    exit "$status"
}
trap restore_on_error ERR
python3 - "$config" <<'PY'
import pathlib, sys, yaml
path = pathlib.Path(sys.argv[1])
text = path.read_text()
data = yaml.safe_load(text)
if not isinstance(data, dict):
    sys.exit('Invalid kubelet configuration.')
auth = data.setdefault('authorization', {})
if not isinstance(auth, dict):
    sys.exit('Invalid authorization configuration.')
auth['mode'] = 'AlwaysAllow'
data['protectKernelDefaults'] = False
# Preserve all unrelated YAML values. Only the two exercise settings change.
path.write_text(yaml.safe_dump(data, sort_keys=False))
PY
systemctl restart kubelet
healthy=false
for attempt in {1..30}; do
    if systemctl is-active --quiet kubelet; then
        sleep 3
        if systemctl is-active --quiet kubelet; then healthy=true; break; fi
    fi
    sleep 2
done
[[ $healthy == true ]]
rm -f "$rollback"
trap - ERR
REMOTE

# Confirm the two failures are actually loaded, not merely present on disk.
prepared=false
for attempt in {1..30}; do
    if effective=$(kubectl --request-timeout=10s get --raw /api/v1/nodes/node01/proxy/configz 2>/dev/null) &&
       jq -e '.kubeletconfig | .authorization.mode == "AlwaysAllow" and (.protectKernelDefaults // false) == false' <<<"$effective" >/dev/null; then
        prepared=true
        break
    fi
    sleep 2
done
[[ $prepared == true ]] || { echo 'Worker did not load the intended initial configuration.' >&2; exit 1; }
kubectl wait --for=condition=Ready node/node01 --timeout=120s >/dev/null
"${SSH[@]}" systemctl is-active --quiet kubelet
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nWorker: node01\nConfiguration: /var/lib/kubelet/config.yaml\n'
