#!/usr/bin/env bash
set -Eeuo pipefail

passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then printf 'RESULT: SUCCESS\n'; exit 0; fi
    printf 'RESULT: FAILED\n'; exit 1
}
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is available'; finish
fi
if [[ -z ${KUBECONFIG:-} && ! -f ${HOME}/.kube/config && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=30s "$@"; }
if ! k get namespace test >/dev/null; then
    fail 'Namespace test exists and is accessible'; finish
fi
pass 'Namespace test exists'
if level=$(k get namespace test -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}') && [[ $level == restricted ]]; then
    pass 'Namespace test enforces the restricted Pod Security Standard'
else
    fail 'Namespace test must enforce the restricted Pod Security Standard'
fi

# Server dry-run exercises admission without persisting any test resources.
# Only the specific PodSecurity rejection counts, not RBAC or quota errors.
if rejection=$(k create --dry-run=server -f - 2>&1 <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  generateName: pss-root-probe-
  namespace: test
spec:
  containers:
  - name: probe
    image: nginx
    command: ["sleep", "1h"]
EOF
); then
    fail 'Admission must reject the original insecure nginx Pod'
elif [[ $rejection == *'violates PodSecurity "restricted:'* ]]; then
    pass 'Admission rejects the original insecure nginx Pod under restricted policy'
else
    fail 'Could not establish a restricted PodSecurity rejection'
    printf '%s\n' "$rejection" >&2
fi

if ! k -n test get pod test-pod >/dev/null; then
    fail 'Corrected Pod test/test-pod exists'; finish
fi
if k -n test wait --for=condition=Ready pod/test-pod --timeout=60s >/dev/null 2>&1 &&
    [[ $(k -n test get pod test-pod -o jsonpath='{.status.phase}') == Running ]] &&
    [[ -z $(k -n test get pod test-pod -o jsonpath='{.metadata.deletionTimestamp}') ]]; then
    pass 'Corrected Pod test/test-pod is Running and Ready'
else
    fail 'Corrected Pod test/test-pod must be Running and Ready'
fi

# Namespace enforcement does not retroactively fix existing Pods. Submit the
# live spec to admission again under a fresh name. JSONPath serializes the
# spec object as JSON; no YAML parsing or extra dependency is necessary.
if spec=$(k -n test get pod test-pod -o jsonpath='{.spec}') &&
    result=$(printf '{"apiVersion":"v1","kind":"Pod","metadata":{"generateName":"pss-fixed-probe-","namespace":"test"},"spec":%s}\n' "$spec" |
        k create --dry-run=server -f - 2>&1); then
    pass 'The live Pod specification passes current namespace admission'
else
    fail 'The live Pod specification must pass current namespace admission'
    printf '%s\n' "${result:-Could not read Pod specification.}" >&2
fi

# Inspect every regular container without assuming its name or UID value.
if containers=$(k -n test get pod test-pod -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}'); then
    while IFS= read -r container; do
        [[ -n $container ]] || continue
        if uid=$(k -n test exec test-pod -c "$container" -- id -u 2>/dev/null) &&
            [[ $uid =~ ^[0-9]+$ && $uid != 0 ]]; then
            pass "Container $container runs as a non-root user"
        else
            fail "Could not verify a non-root runtime UID for container $container"
        fi
    done <<< "$containers"
else
    fail 'Could not inspect the running containers'
fi
finish
