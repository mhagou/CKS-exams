#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. This task needs no workload fixtures.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
[[ -r $KUBECONFIG ]] || { echo 'An administrator kubeconfig is required.' >&2; exit 1; }
[[ -s /etc/kubernetes/manifests/kube-apiserver.yaml ]] || {
    echo 'Expected the existing kubeadm API server static Pod manifest.' >&2; exit 1;
}
kubectl --request-timeout=20s get --raw=/readyz >/dev/null
kubectl --request-timeout=20s get node controlplane >/dev/null
kubectl --request-timeout=20s get node node01 >/dev/null

# Do not disable another exercise's auditing, or overwrite a candidate's work.
# A fresh playground already has the initial state required by this exercise.
found=0
for proc in /proc/[0-9]*; do
    [[ -r $proc/cmdline ]] || continue
    argv=()
    mapfile -d '' -t argv < "$proc/cmdline" 2>/dev/null || continue
    executable=${argv[0]:-}
    [[ ${executable##*/} == kube-apiserver ]] || continue
    found=1
    for arg in "${argv[@]}"; do
        case "$arg" in
            --audit-policy-file|--audit-policy-file=?*)
                echo 'Existing auditing detected. Use a fresh playground for this exercise; existing configuration was preserved.' >&2
                exit 1
                ;;
        esac
    done
done
[[ $found -eq 1 ]] || { echo 'No local running API server was found.' >&2; exit 1; }

# jq is used to check structured audit events, including absence of secret bodies.
if ! command -v jq >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq
    elif command -v dnf >/dev/null; then
        dnf install -y jq
    else
        echo 'Install jq using the playground package manager, then rerun setup.' >&2
        exit 1
    fi
fi
jq -n -e 'true' >/dev/null
kubectl --request-timeout=20s get --raw=/readyz >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
