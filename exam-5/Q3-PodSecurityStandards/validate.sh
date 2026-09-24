#!/usr/bin/env bash
set -Eeuo pipefail

# Names are defaults from the supporting notes, not grading requirements.
# Usage: NAMESPACE=my-namespace SERVICE_ACCOUNT=my-viewer ./validate.sh
# The brief task leaves RBAC verbs unspecified. Interpret "PSS viewer" as
# effective GET access to the target Namespace (which includes its status).
# Do not require the ineffective namespaced Role shown in solution.txt or
# unnecessary access to a separate namespaces/status endpoint.
NAMESPACE=${NAMESPACE:-api-security}
SERVICE_ACCOUNT=${SERVICE_ACCOUNT:-pss-viewer}
passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( failed == 0 ))
}
for cmd in kubectl jq; do
    if ! command -v "$cmd" >/dev/null; then
        fail "Required command is missing: $cmd"
        finish; exit 1
    fi
done
if [[ -z ${KUBECONFIG:-} && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=30s "$@"; }
if ! ns=$(k get namespace "$NAMESPACE" -o json); then
    fail "Namespace $NAMESPACE exists and is accessible"
    finish; exit 1
fi
if jq -e '.metadata.labels["pod-security.kubernetes.io/enforce"] == "baseline"' <<<"$ns" >/dev/null; then
    pass "Namespace $NAMESPACE enforces the baseline standard"
else
    fail "Namespace $NAMESPACE enforces the baseline standard"
fi

# All admission probes are server-side dry runs: nothing is persisted.
# Require a specific PSA denial, not an unrelated quota/webhook/API error.
if denial=$(k create --dry-run=server -f - -o name 2>&1 <<EOF
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-pss-probe-
  namespace: ${NAMESPACE}
spec:
  containers:
  - name: probe
    image: registry.k8s.io/pause:3.10
    securityContext:
      privileged: true
EOF
); then
    fail 'Pod Security admission rejects a privileged Pod'
elif [[ $denial == *'violates PodSecurity "baseline:'* ]]; then
    pass 'Pod Security admission rejects a privileged Pod'
else
    fail 'Could not confirm baseline admission rejection'
    printf '  %s\n' "$denial"
fi

# Accept any running, ready Pod whose complete spec passes current admission
# and whose regular, init, and ephemeral containers satisfy the extra task
# requirements. Baseline alone does not require non-root or block escalation.
pod_ok=false
if pods=$(k -n "$NAMESPACE" get pods -o json); then
    while IFS= read -r pod; do
        name=$(jq -r '.metadata.name' <<<"$pod")
        if ! jq -e '
            .metadata.deletionTimestamp == null and .status.phase == "Running" and
            any(.status.conditions[]?; .type == "Ready" and .status == "True") and
            (.spec as $s | all((.spec.containers + (.spec.initContainers // []) +
                (.spec.ephemeralContainers // []))[];
                .securityContext.allowPrivilegeEscalation == false and
                (.securityContext.privileged != true) and
                (((.securityContext.capabilities.add // []) | index("SYS_ADMIN")) == null)))
        ' <<<"$pod" >/dev/null; then continue; fi

        # Re-create only the spec for admission evaluation, keeping labels and
        # annotations that other admission policies may use. Ephemeral
        # containers cannot be submitted on creation; assess them separately.
        probe=$(jq --arg ns "$NAMESPACE" '
            {apiVersion:"v1", kind:"Pod", metadata:{generateName:"cks-pss-check-",
             namespace:$ns, labels:(.metadata.labels // {}),
             annotations:(.metadata.annotations // {})}, spec:.spec}
            | del(.spec.nodeName, .spec.ephemeralContainers)
        ' <<<"$pod")
        if ! k create --dry-run=server -f - -o name <<<"$probe" >/dev/null 2>&1; then continue; fi
        containers_ok=true
        while IFS=$'\t' read -r container uid nonroot kind; do
            # When available, inspect the running process UID. Distroless
            # images and completed init containers use enforced spec fallback.
            actual=''
            if [[ $kind != init ]]; then
                actual=$(k -n "$NAMESPACE" exec "$name" -c "$container" -- id -u 2>/dev/null) || actual=''
            fi
            if [[ $actual =~ ^[0-9]+$ ]]; then
                if [[ $actual =~ ^0+$ ]]; then containers_ok=false; fi
            elif [[ $uid =~ ^[0-9]+$ && ! $uid =~ ^0+$ ]]; then
                :
            elif [[ $nonroot == true && $uid != 0 ]]; then
                :
            else
                containers_ok=false
            fi
        done < <(jq -r '
            .spec as $s |
            ((.spec.containers[] | [., "regular"]),
             (.spec.initContainers[]? | [., "init"]),
             (.spec.ephemeralContainers[]? | [., "ephemeral"])) |
            .[0] as $c | [ $c.name,
              (($c.securityContext.runAsUser // $s.securityContext.runAsUser) // "unset"),
              (if $c.securityContext.runAsNonRoot != null then $c.securityContext.runAsNonRoot
               else ($s.securityContext.runAsNonRoot // false) end), .[1]] | @tsv
        ' <<<"$pod")
        # Ephemeral containers are uncommon here. Their baseline compliance
        # is checked by also submitting them as regular containers in a probe.
        if jq -e '(.spec.ephemeralContainers // []) | length > 0' <<<"$pod" >/dev/null; then
            ephemeral_probe=$(jq --argjson original "$pod" '
                .spec.containers = ($original.spec.ephemeralContainers |
                    map(del(.targetContainerName))) | del(.spec.initContainers)
            ' <<<"$probe")
            if ! k create --dry-run=server -f - -o name <<<"$ephemeral_probe" >/dev/null 2>&1; then
                containers_ok=false
            fi
        fi
        if [[ $containers_ok == true ]]; then pod_ok=true; break; fi
    done < <(jq -c '.items[]' <<<"$pods")
fi
if [[ $pod_ok == true ]]; then
    pass "Pod $name is ready, baseline compliant, non-root, and blocks privilege escalation"
else
    fail 'A ready baseline-compliant Pod runs non-root and blocks privilege escalation in every container'
fi

if k -n "$NAMESPACE" get serviceaccount "$SERVICE_ACCOUNT" >/dev/null 2>&1; then
    pass "PSS viewer service account $SERVICE_ACCOUNT exists"
    if k --as="system:serviceaccount:$NAMESPACE:$SERVICE_ACCOUNT" \
        --as-group=system:serviceaccounts \
        --as-group="system:serviceaccounts:$NAMESPACE" \
        --as-group=system:authenticated \
        get namespace "$NAMESPACE" -o name >/dev/null 2>&1; then
        pass 'PSS viewer can read the namespace and its Pod Security labels'
    else
        fail 'PSS viewer can read the namespace and its Pod Security labels'
    fi
else
    fail "PSS viewer service account $SERVICE_ACCOUNT exists"
    fail 'PSS viewer can read the namespace and its Pod Security labels'
fi
finish
