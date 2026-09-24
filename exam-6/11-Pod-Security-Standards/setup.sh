#!/usr/bin/env bash
set -Eeuo pipefail

# This task starts from an absent namespace. There are no prerequisite
# manifests, packages, or worker configuration to install.
trap 'printf "[ERROR] Scenario preparation failed at line %s.\n" "$LINENO" >&2' ERR
die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run this script as root on controlplane.'
command -v kubectl >/dev/null || die 'kubectl is required on the Kubernetes control plane.'
if [[ -z ${KUBECONFIG:-} && ! -f ${HOME}/.kube/config && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=30s "$@"; }

k get --raw=/readyz >/dev/null
for node in controlplane node01; do
    k wait --for=condition=Ready "node/$node" --timeout=60s >/dev/null
done
for permission in 'create namespaces' 'patch namespaces' 'create pods' 'get pods' 'delete pods' 'create pods/exec'; do
    read -r verb resource <<< "$permission"
    [[ $(k auth can-i "$verb" "$resource" --namespace=test) == yes ]] ||
        die "Current credentials lack permission: $permission"
done

# Never delete or relabel a pre-existing, potentially unrelated namespace.
# Re-running before the candidate starts is safe and changes nothing.
existing=$(k get namespace test --ignore-not-found -o name)
[[ -z $existing ]] || die 'Namespace test already exists. Use a fresh playground or explicitly remove the previous exercise resources before setup.'

printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nStart with the namespace creation step in task.txt.\n'
