#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only validation. Namespace defaults to the one implied by task.txt.
namespace=${NAMESPACE:-default}
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Validation could not complete (line $LINENO)"; finish' ERR
if ! command -v kubectl >/dev/null; then fail 'kubectl is available'; finish; fi
if [[ -z ${KUBECONFIG:-} && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=30s "$@"; }
if ! k get namespace "$namespace" >/dev/null 2>&1; then
    fail "Can access namespace $namespace"; finish
fi
handler=$(k get runtimeclass gvisor -o jsonpath='{.handler}' 2>/dev/null || true)
if [[ $handler == runsc ]]; then pass 'RuntimeClass gvisor uses handler runsc'
else fail 'RuntimeClass gvisor uses handler runsc'; fi
if ! k -n "$namespace" get pod secure >/dev/null 2>&1; then
    fail "Pod $namespace/secure exists"; finish
fi
class=$(k -n "$namespace" get pod secure -o jsonpath='{.spec.runtimeClassName}')
if [[ $class == gvisor ]]; then pass 'Pod secure selects RuntimeClass gvisor'
else fail 'Pod secure selects RuntimeClass gvisor'; fi
if k -n "$namespace" wait --for=condition=Ready pod/secure --timeout=90s >/dev/null 2>&1 &&
   [[ $(k -n "$namespace" get pod secure -o jsonpath='{.status.phase}') == Running ]] &&
   [[ -z $(k -n "$namespace" get pod secure -o jsonpath='{.metadata.deletionTimestamp}') ]]; then
    pass 'Pod secure is running and ready'
else fail 'Pod secure is running and ready'; fi
# Test the executable rather than insisting on an image registry, tag, or name.
containers=$(k -n "$namespace" get pod secure -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
nginx_found=false
runtime_ok=false
while IFS= read -r container; do
    [[ -n $container ]] || continue
    if k -n "$namespace" exec secure -c "$container" -- nginx -v >/dev/null 2>&1; then
        nginx_found=true
        if output=$(k -n "$namespace" exec secure -c "$container" -- dmesg 2>/dev/null) &&
           [[ ${output,,} == *gvisor* ]]; then
            runtime_ok=true
        fi
    fi
done <<< "$containers"
if $nginx_found; then pass 'Pod secure contains a running nginx container'
else fail 'Pod secure contains a running nginx container'; fi
if $runtime_ok; then pass 'nginx container reports gVisor in its runtime kernel log'
else fail 'nginx container reports gVisor in its runtime kernel log'; fi
finish
