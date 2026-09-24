#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. Re-running preserves candidate work.
trap 'printf "[FAIL] Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
if ! command -v openssl >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y openssl
    elif command -v dnf >/dev/null; then
        dnf install -y openssl
    elif command -v yum >/dev/null; then
        yum install -y openssl
    else
        echo 'Install OpenSSL on the playground, then re-run setup.' >&2
        exit 1
    fi
fi
if [[ -z ${KUBECONFIG:-} && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=20s "$@"; }

# Check access before making the one required change. Do not create user
# credentials, a CSR, a Role, or a RoleBinding: those are candidate objectives.
k get --raw=/readyz >/dev/null
k get certificatesigningrequests.certificates.k8s.io >/dev/null
if [[ -z $(k get namespace john --ignore-not-found -o name) ]]; then
    k create namespace john >/dev/null
fi
[[ $(k get namespace john -o jsonpath='{.status.phase}') == Active ]]
[[ $(k auth can-i create certificatesigningrequests.certificates.k8s.io) == yes ]]
[[ $(k auth can-i create roles.rbac.authorization.k8s.io -n john) == yes ]]
[[ $(k auth can-i create rolebindings.rbac.authorization.k8s.io -n john) == yes ]]
openssl version >/dev/null

printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Existing exercise work, if any, has been preserved.\n'
