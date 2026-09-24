#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
# Python is used for IP interval arithmetic in validation, not just JSON parsing.
if ! command -v python3 >/dev/null; then
  command -v apt-get >/dev/null || { echo 'Install Python 3 before preparing this lab.' >&2; exit 1; }
  apt-get update
  apt-get install -y python3
fi
ns=threat-prevention
owner=cks-block-netpol
if kubectl get namespace "$ns" >/dev/null 2>&1; then
  [[ $(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.cks-lab}') == "$owner" ]] || {
    echo "Namespace $ns already exists and is not owned by this lab; refusing to reset it." >&2; exit 1;
  }
else
  kubectl create namespace "$ns"
  kubectl label namespace "$ns" cks-lab="$owner"
fi
# Only this dedicated, ownership-checked exercise namespace is reset.
kubectl -n "$ns" delete networkpolicy --all
for pod in lab-client lab-peer; do
  kubectl -n "$ns" delete pod "$pod" --ignore-not-found --wait=true
  kubectl -n "$ns" run "$pod" --image=python:3.12-alpine --labels="cks-lab=$owner,app=$pod" \
    --restart=Never --command -- python3 -m http.server 8080
 done
kubectl -n "$ns" wait --for=condition=Ready pod/lab-client pod/lab-peer --timeout=180s
[[ -z $(kubectl -n "$ns" get networkpolicy -o name) ]]
peer=$(kubectl -n "$ns" get pod lab-peer -o jsonpath='{.status.podIP}')
kubectl -n "$ns" exec lab-client -- python3 -c \
  'import sys,urllib.request; assert urllib.request.urlopen("http://"+sys.argv[1]+":8080", timeout=5).status == 200' "$peer"
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
