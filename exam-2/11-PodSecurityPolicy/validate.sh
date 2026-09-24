#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the live API object, not a submitted manifest. The question asks
# for policy creation, not cluster-wide enforcement, a binding, or a test Pod.
# Do not grade the erroneous Pod example in the embedded solution.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then
        printf 'RESULT: SUCCESS\n'
        exit 0
    fi
    printf 'RESULT: FAILED\n'
    exit 1
}
blocked() {
    fail "PodSecurityPolicy pod-psp can be read: $1"
    fail 'Privileged Pods are forbidden (cannot evaluate)'
    fail 'Only secret and configMap volumes are allowed (cannot evaluate)'
    fail 'seLinux uses RunAsAny (cannot evaluate)'
    fail 'runAsUser uses RunAsAny (cannot evaluate)'
    fail 'fsGroup uses RunAsAny (cannot evaluate)'
    finish
}
command -v kubectl >/dev/null 2>&1 || blocked 'kubectl is missing'
if [[ -z ${KUBECONFIG:-} && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi

# One API read gives a consistent snapshot. A missing privileged boolean has
# the native false default. Other required fields must be present explicitly.
template='{{.metadata.name}}{{"\n"}}{{if .spec.privileged}}true{{else}}false{{end}}{{"\n"}}{{range .spec.volumes}}{{.}}{{","}}{{end}}{{"\n"}}{{.spec.seLinux.rule}}{{"\n"}}{{.spec.runAsUser.rule}}{{"\n"}}{{.spec.fsGroup.rule}}{{"\n"}}'
if ! snapshot=$(kubectl --request-timeout=30s get podsecuritypolicies.policy pod-psp -o go-template="$template"); then
    blocked 'resource missing, API unsupported, or access failed; PSP requires Kubernetes v1.24 or earlier'
fi
mapfile -t fields <<< "$snapshot"
if [[ ${fields[0]:-} != pod-psp || ${#fields[@]} -ne 6 ]]; then
    blocked 'unexpected API response'
fi
pass 'PodSecurityPolicy pod-psp exists'
if [[ ${fields[1]} == false ]]; then
    pass 'Privileged Pods are forbidden'
else
    fail 'Privileged Pods are forbidden'
fi

# Compare the allowed volume set, independent of order or duplicates.
secret=false
configmap=false
unexpected=false
IFS=',' read -r -a volumes <<< "${fields[2]}"
for volume in "${volumes[@]}"; do
    case "$volume" in
        secret) secret=true ;;
        configMap) configmap=true ;;
        *) unexpected=true ;;
    esac
done
if [[ $secret == true && $configmap == true && $unexpected == false ]]; then
    pass 'Only secret and configMap volumes are allowed'
else
    fail 'Only secret and configMap volumes are allowed'
fi

rules=(seLinux runAsUser fsGroup)
for i in 0 1 2; do
    if [[ ${fields[i+3]} == RunAsAny ]]; then
        pass "${rules[i]} uses RunAsAny"
    else
        fail "${rules[i]} uses RunAsAny"
    fi
done
finish
