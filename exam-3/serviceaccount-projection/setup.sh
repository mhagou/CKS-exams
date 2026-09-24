#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. This resets the starter Pod only.
NS=serviceaccount-projection
POD=cks-projected-token-lab
OWNER=cks-serviceaccount-projection
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
# jq is used for structured projection discovery and JWT/TokenReview validation.
if ! command -v jq >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get install -y jq
    else
        echo 'Install jq using the playground package manager, then rerun setup.' >&2
        exit 1
    fi
fi
kubectl get node controlplane >/dev/null
if kubectl get namespace "$NS" >/dev/null 2>&1; then
    owner=$(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.cks-lab}')
    [[ $owner == "$OWNER" ]] || {
        echo "Namespace $NS already exists and is not owned by this lab; refusing to reset it." >&2
        exit 1
    }
else
    kubectl create -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
  labels:
    cks-lab: $OWNER
EOF
fi

kubectl -n "$NS" delete pod "$POD" --ignore-not-found --wait=true --timeout=90s
kubectl -n "$NS" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $POD
  labels:
    cks-lab: $OWNER
spec:
  automountServiceAccountToken: false
  containers:
    - name: nginx
      image: nginx:alpine
EOF
kubectl -n "$NS" wait --for=condition=Ready "pod/$POD" --timeout=180s
kubectl -n "$NS" get pod "$POD" -o json | jq -e '
    .spec.automountServiceAccountToken == false and
    ([.spec.volumes[]? | select(.projected != null)] | length == 0) and
    any(.status.conditions[]?; .type == "Ready" and .status == "True")
' >/dev/null
kubectl -n "$NS" exec "$POD" -- sh -c 'test ! -e /var/run/secrets/kubernetes.io/serviceaccount/token'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\n'
printf 'Scenario preparation completed successfully.\nNamespace: %s\nStarter Pod: %s\n' "$NS" "$POD"
printf 'Work in this namespace; validate.sh also accepts a namespace and optional Pod name.\n'
