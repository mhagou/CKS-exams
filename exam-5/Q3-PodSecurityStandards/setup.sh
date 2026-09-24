#!/usr/bin/env bash
set -Eeuo pipefail

# This creation exercise needs no pre-created Kubernetes resources.
# Re-running this preflight preserves candidate work and unrelated labs.
trap 'printf "Setup failed at line %s.\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground.' >&2; exit 1; }
if [[ -z ${KUBECONFIG:-} && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=30s "$@"; }
k get --raw=/readyz >/dev/null
for node in controlplane node01; do
    k wait --for=condition=Ready "node/$node" --timeout=120s >/dev/null
done
[[ $(k auth can-i '*' '*' --all-namespaces) == yes ]] || {
    echo 'An administrative kubeconfig is required.' >&2; exit 1;
}
# jq is used to inspect all container types and submit sanitized admission
# probes; no image, workload, security policy, or RBAC is installed here.
if ! command -v jq >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update -qq
        apt-get install -y jq
    elif command -v dnf >/dev/null; then
        dnf install -y jq
    elif command -v yum >/dev/null; then
        yum install -y jq
    else
        echo 'Install jq using the playground package manager, then rerun setup.' >&2
        exit 1
    fi
fi
jq -en '1 == 1' >/dev/null
k api-resources --api-group=rbac.authorization.k8s.io -o name | \
    grep -qx 'clusterrolebindings.rbac.authorization.k8s.io'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Create the resources described in task.txt. Existing work is preserved.\n'
printf 'Validation defaults: namespace api-security, service account pss-viewer.\n'
printf 'For other names: NAMESPACE=<name> SERVICE_ACCOUNT=<name> ./validate.sh\n'
