#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only checks against the live solution; no repairs or test resources.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Validation command failed at line $LINENO"; finish' ERR
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; }
if kubectl get serviceaccount test-sa -n spectacle >/dev/null 2>&1; then
    pass 'Service account spectacle/test-sa exists'
else
    fail 'Service account spectacle/test-sa exists'
fi
# Prefer the original application. If renamed, find pods mounting the supplied
# fixture, without requiring particular labels, volume names or container names.
if kubectl get pod apparmor-pod -n spectacle >/dev/null 2>&1; then
    pods=apparmor-pod
elif ! pods=$(kubectl get pods -n spectacle -o go-template='{{range .items}}{{$pod := .metadata.name}}{{range .spec.containers}}{{range .volumeMounts}}{{if or (eq .mountPath "/etc/cks-spectacle") (eq .mountPath "/etc/cks-spectacle/") (eq .mountPath "/etc/cks-spectacle/read-test")}}{{$pod}}{{"\n"}}{{end}}{{end}}{{end}}{{end}}' | sort -u); then
    fail 'Can inspect pods in spectacle'; finish
fi
[[ -n $pods ]] || { fail 'An application pod exists in spectacle'; finish; }
while IFS= read -r pod; do
    if ! kubectl wait -n spectacle --for=condition=Ready "pod/$pod" --timeout=30s >/dev/null 2>&1; then
        fail "$pod is Ready"; continue
    fi
    pass "$pod is Ready"
    if [[ $(kubectl get pod "$pod" -n spectacle -o jsonpath='{.spec.serviceAccountName}') == test-sa ]]; then
        pass "$pod uses test-sa"
    else
        fail "$pod uses test-sa"
    fi
    # Include init and ephemeral containers, not just the first application container.
    privileges=$(kubectl get pod "$pod" -n spectacle -o jsonpath='{range .spec.containers[*]}{.securityContext.privileged}{"\n"}{end}{range .spec.initContainers[*]}{.securityContext.privileged}{"\n"}{end}{range .spec.ephemeralContainers[*]}{.securityContext.privileged}{"\n"}{end}')
    if [[ $privileges == *true* ]]; then
        fail "$pod has no privileged containers"
    else
        pass "$pod has no privileged containers"
    fi
    containers=$(kubectl get pod "$pod" -n spectacle -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
    fixture_containers=0
    while IFS= read -r container; do
        context="$pod/$container"
        # Only the application containers mounting the supplied fixture need
        # its read-denial test. Sidecars still undergo the pod privilege check.
        mounts=$(kubectl get pod "$pod" -n spectacle -o "jsonpath={.spec.containers[?(@.name==\"$container\")].volumeMounts[*].mountPath}")
        has_fixture=false
        for mount in $mounts; do
            if [[ $mount == /etc/cks-spectacle || $mount == /etc/cks-spectacle/ ||
                  $mount == /etc/cks-spectacle/read-test ]]; then
                has_fixture=true
            fi
        done
        [[ $has_fixture == true ]] || continue
        fixture_containers=$((fixture_containers + 1))
        # Kernel-reported confinement accepts pod-level, container-level and legacy
        # annotation configurations, and detects unloaded/complain-mode profiles.
        if active=$(kubectl exec -n spectacle "$pod" -c "$container" -- sh -c \
            'cat /proc/1/attr/apparmor/current 2>/dev/null || cat /proc/1/attr/current' 2>/dev/null) &&
            [[ $active == 'spectacleapp (enforce)' ]]; then
            pass "$context runs under spectacleapp in enforce mode"
        else
            fail "$context runs under spectacleapp in enforce mode"
        fi
        # Require an existing world-readable fixture and working cat first. A missing
        # file, missing utility, or exec failure must not count as a denied read.
        if kubectl exec -n spectacle "$pod" -c "$container" -- sh -c '
            command -v cat >/dev/null || exit 1
            cat /etc/hostname >/dev/null || exit 1
            test -f /etc/cks-spectacle/read-test || exit 1
            mode=$(stat -L -c %a /etc/cks-spectacle/read-test) || exit 1
            test "$((0$mode & 0444))" -eq "$((0444))" || exit 1
            export LC_ALL=C
            if output=$(cat /etc/cks-spectacle/read-test 2>&1); then exit 1; fi
            case "$output" in
                *"Permission denied"*|*"Operation not permitted"*) exit 0 ;;
                *) exit 1 ;;
            esac
        ' >/dev/null 2>&1; then
            pass "$context cannot read the protected lab fixture"
        else
            fail "$context cannot read the protected lab fixture (must exist with DAC read permissions)"
        fi
    done <<< "$containers"
    if (( fixture_containers == 0 )); then
        fail "$pod retains an application container with the protected lab fixture"
    fi
done <<< "$pods"
finish
