#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. Reruns preserve candidate work.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
[[ -r /etc/kubernetes/manifests/kube-apiserver.yaml ]]
kubectl --request-timeout=20s get --raw=/readyz >/dev/null
kubectl --request-timeout=20s get node controlplane >/dev/null

# Python's standard library handles process inspection and streaming audit logs
# in the validator; no YAML packages or extra Kubernetes utilities are needed.
if ! command -v python3 >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends python3
    elif command -v dnf >/dev/null; then
        dnf install -y python3
    else
        echo 'Install Python 3 on the playground, then rerun setup.' >&2
        exit 1
    fi
fi
if ! kubectl --request-timeout=20s get namespace test >/dev/null 2>&1; then
    kubectl --request-timeout=20s create namespace test >/dev/null
fi
[[ $(kubectl --request-timeout=20s get namespace test -o jsonpath='{.status.phase}') == Active ]]
command -v python3 >/dev/null
kubectl --request-timeout=20s get --raw=/readyz >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
