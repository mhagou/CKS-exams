#!/usr/bin/env bash
set -Eeuo pipefail
# Usage: ./validate.sh [namespace [pod [container]]]
# Without arguments, discover Localhost-profile containers in all namespaces.
# No specific resource name, image, or profile filename is required.
passes=0 failures=0
pass() { printf '[PASS] %s\n' "$*"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$passes" "$failures"
    if (( failures == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
for tool in kubectl jq ssh; do
    if ! command -v "$tool" >/dev/null; then fail "Required validation tool is missing: $tool"; finish; fi
done
[[ $EUID -eq 0 ]] || { fail 'Run validation as root on controlplane.'; finish; }
if [[ $# -gt 3 ]]; then fail 'Usage: validate.sh [namespace [pod [container]]]'; finish; fi
query=(get pods -A -o json)
if [[ $# -ge 1 ]]; then query=(get pods -n "$1" -o json); fi
if ! pods=$(kubectl "${query[@]}"); then fail 'Read live pods'; finish; fi
candidates=$(jq -r --arg pod "${2:-}" --arg container "${3:-}" '
 .items[] | select($pod == "" or .metadata.name == $pod) | . as $p |
 .spec.containers[] | select($container == "" or .name == $container) | . as $c |
 ($c.securityContext.seccompProfile // $p.spec.securityContext.seccompProfile) as $s |
 select($s.type == "Localhost" and ($s.localhostProfile // "") != "") |
 select(.securityContext.privileged != true) |
 $p.status.containerStatuses[]? | select(.name == $c.name and .state.running != null) |
 [$p.metadata.namespace, $p.metadata.name, $c.name, $p.spec.nodeName, .containerID] | @tsv
' <<<"$pods")
if [[ -z $candidates ]]; then
    fail 'A running, non-privileged container uses a custom Localhost seccomp profile'
    finish
fi
# Inspect the OCI policy actually supplied to the running container, rather than
# a profile file that might have been edited after container creation.
inspect_node() {
    local node=$1 id=$2
    local script
    script=$(cat <<'NODE'
set -Eeuo pipefail
id=$1
[[ $id =~ ^[a-fA-F0-9]+$ ]]
grep -qw log /proc/sys/kernel/seccomp/actions_logged || exit 1
if command -v k3s >/dev/null; then
    k3s crictl inspect "$id"
elif [[ -f /etc/crictl.yaml ]]; then
    crictl inspect "$id"
else
    # Use discovered sockets without creating or changing crictl configuration.
    for socket in /run/containerd/containerd.sock /run/crio/crio.sock /var/run/cri-dockerd.sock; do
        if [[ -S $socket ]]; then
            crictl --runtime-endpoint "unix://$socket" inspect "$id" && exit 0
        fi
    done
    exit 1
fi
NODE
)
    case "$node" in
        controlplane) bash -s -- "$id" <<<"$script" ;;
        node01) ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 "bash -s -- $id" <<<"$script" ;;
        *) return 1 ;;
    esac
}
found_policy=false
while IFS=$'\t' read -r ns pod container node runtime_id; do
    id=${runtime_id#*://}
    [[ $id =~ ^[a-fA-F0-9]+$ ]] || continue
    if ! inspection=$(inspect_node "$node" "$id"); then
        printf 'Could not inspect %s/%s (%s) on %s.\n' "$ns" "$pod" "$container" "$node" >&2
        continue
    fi
    # Both an explicit unconditional LOG rule and default LOG are valid.
    # Conditional non-LOG overrides do not satisfy logging mkdir generally.
    if ! jq -e '
        (.info | if type == "string" then fromjson else . end) |
        .runtimeSpec.linux.seccomp | select(type == "object") |
        [.syscalls[]? | select(any(.names[]?; . == "mkdir"))] as $rules |
        (all($rules[]; .action == "SCMP_ACT_LOG")) and
        ((.defaultAction == "SCMP_ACT_LOG") or
         any($rules[]; .action == "SCMP_ACT_LOG" and ((.args // []) | length == 0)))
    ' <<<"$inspection" >/dev/null; then
        continue
    fi
    found_policy=true
    # Test a disposable directory and remove it within the same exec session.
    # A writable mount may be supplied through TEST_DIRECTORY for hardened pods.
    if kubectl -n "$ns" exec "$pod" -c "$container" -- sh -ec '
        base=$1
        p="$base/cks-seccomp-check-$$-$(date +%s)"
        trap '\''rmdir "$p" 2>/dev/null || true'\'' EXIT
        mkdir "$p"
        test -d "$p"
    ' sh "${TEST_DIRECTORY:-/tmp}"; then
        pass "Custom seccomp profile applied to running container $ns/$pod ($container)"
        pass 'Effective runtime policy logs mkdir without denying it; kernel LOG auditing is enabled'
        pass 'Directory creation succeeds in the running container'
        finish
    fi
    printf 'Directory test failed for %s/%s (%s); check shell/tools and writable TEST_DIRECTORY.\n' "$ns" "$pod" "$container" >&2
done <<<"$candidates"
if [[ $found_policy == true ]]; then
    pass 'A running container has an effective custom policy that logs mkdir'
    fail 'Directory creation succeeds in that container (requires sh, mkdir, rmdir, date and a writable test directory)'
else
    fail 'A running custom-profile container has an effective mkdir LOG policy with kernel logging enabled'
fi
finish
