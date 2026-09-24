#!/usr/bin/env bash
set -Eeuo pipefail

# Admission is the effective state for this task. All probes are server dry-runs.
# No requirement to deploy nginx or apply seccomp appears in task.txt.
# Reference: https://kubernetes.io/docs/concepts/security/pod-security-admission/
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then
        echo 'RESULT: SUCCESS'
        exit 0
    fi
    echo 'RESULT: FAILED'
    exit 1
}
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is available'
    finish
fi
k() { kubectl --request-timeout=30s "$@"; }
if ! ns=$(k get namespace secure-team -o jsonpath='{.status.phase}' 2>&1); then
    fail 'Namespace secure-team exists and is accessible'
    printf '%s\n' "$ns" >&2
    fail 'Baseline enforcement could not be tested'
    fail 'Restricted warnings could not be tested'
    finish
fi
if [[ $ns != Active ]]; then
    fail 'Namespace secure-team is Active'
    fail 'Baseline enforcement could not be tested'
    fail 'Restricted warnings could not be tested'
    finish
fi
pass 'Namespace secure-team exists and is Active'

# A restricted-compliant control distinguishes policy rejection from API failures.
# The second probe differs only in runAsNonRoot, allowed by Baseline but not
# Restricted. The third enables privileged mode, prohibited by Baseline.
probe() {
    local mode=$1 nonroot=true privileged=false
    [[ $mode != baseline ]] || nonroot=false
    [[ $mode != privileged ]] || privileged=true
    k create --dry-run=server -o name -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-psa-${mode}-
  namespace: secure-team
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: ${nonroot}
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: registry.k8s.io/pause:3.10
    securityContext:
      privileged: ${privileged}
      allowPrivilegeEscalation: ${privileged}
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
    resources:
      requests:
        cpu: 1m
        memory: 8Mi
      limits:
        cpu: 10m
        memory: 16Mi
EOF
}

if control=$(probe control 2>&1); then
    pass 'Admission accepts a Restricted-compliant control Pod'
else
    fail 'Admission accepts a Restricted-compliant control Pod'
    printf '%s\n' "$control" >&2
fi

if denied=$(probe privileged 2>&1); then
    fail 'Baseline rejects a privileged Pod (dry-run was accepted)'
elif [[ $denied =~ violates\ PodSecurity\ \"baseline: ]]; then
    pass 'Baseline admission rejects a privileged Pod'
else
    fail 'Baseline rejection was not confirmed (unexpected admission error)'
    printf '%s\n' "$denied" >&2
fi

if warning=$(probe baseline 2>&1); then
    pass 'Admission permits a Baseline-compliant Pod that violates Restricted'
    if [[ $warning =~ Warning:.*would\ violate\ PodSecurity\ \"restricted: ]]; then
        pass 'Admission warns about Restricted violations'
    else
        fail 'Admission warns about Restricted violations'
        printf '%s\n' "$warning" >&2
    fi
else
    fail 'Admission permits a Baseline-compliant Pod that violates Restricted'
    fail 'Restricted warning behavior could not be confirmed'
    printf '%s\n' "$warning" >&2
fi
finish
