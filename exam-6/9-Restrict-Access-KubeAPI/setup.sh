#!/usr/bin/env bash
set -Eeuo pipefail

# The supplied task begins with key/CSR creation. There are no workloads or
# pre-existing user privileges to prepare. Preserve existing candidate work.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl base64; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
if ! command -v openssl >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get install -y openssl
    elif command -v dnf >/dev/null; then
        dnf install -y openssl
    else
        echo 'Install openssl using the playground package manager.' >&2
        exit 1
    fi
fi
# Use explicit administrator credentials, even if the candidate switched context.
admin_config=${ADMIN_KUBECONFIG:-/etc/kubernetes/admin.conf}
[[ -r $admin_config ]] || { echo "Cannot read $admin_config" >&2; exit 1; }
k=(kubectl --kubeconfig="$admin_config" --request-timeout=15s)
[[ $("${k[@]}" get --raw=/readyz) == ok ]]
"${k[@]}" get namespace default >/dev/null
"${k[@]}" get certificatesigningrequests.certificates.k8s.io >/dev/null
for permission in 'create certificatesigningrequests.certificates.k8s.io' \
                  'update certificatesigningrequests.certificates.k8s.io/approval'; do
    read -r verb resource <<< "$permission"
    [[ $("${k[@]}" auth can-i "$verb" "$resource") == yes ]]
done
openssl version >/dev/null
# Provide the normal starting administrator kubeconfig only if none exists.
# Never overwrite a kubeconfig or change an existing current context.
if [[ ! -e /root/.kube/config ]]; then
    install -d -m 700 /root/.kube
    install -m 600 "$admin_config" /root/.kube/config
fi
[[ -s /root/.kube/config ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
