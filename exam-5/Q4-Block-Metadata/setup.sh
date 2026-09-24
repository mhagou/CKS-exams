#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground's controlplane. This namespace belongs to this lab.
NS=metadata-protect
OWNER=cks-block-metadata
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
# Python's standard-library ipaddress supports semantic CIDR validation; no pip packages.
if ! command -v python3 >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get install -y --no-install-recommends python3
    else
        echo 'Install Python 3 on controlplane, then rerun setup.' >&2
        exit 1
    fi
fi
python3 -c 'import ipaddress, json'
kubectl get node controlplane node01 >/dev/null
existing=$(kubectl get namespace "$NS" --ignore-not-found -o name)
if [[ -n $existing ]]; then
    owner=$(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.cks-lab-owner}')
    [[ $owner == "$OWNER" ]] || {
        echo "Namespace $NS already exists and is not owned by this lab; refusing to reset it." >&2
        exit 1
    }
else
    kubectl create namespace "$NS"
    kubectl label namespace "$NS" "cks-lab-owner=$OWNER"
fi
# Explicit reruns reset candidate policies only in this lab's dedicated namespace.
kubectl -n "$NS" delete networkpolicy --all --wait=true
kubectl -n "$NS" delete pod metadata-client --ignore-not-found --wait=true
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: metadata-client
  namespace: metadata-protect
  labels:
    app: metadata-client
spec:
  nodeSelector:
    kubernetes.io/hostname: node01
  automountServiceAccountToken: false
  containers:
    - name: client
      image: busybox:1.37.0
      command: ["sh", "-c", "exec sleep 2147483647"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          memory: 32Mi
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/metadata-client --timeout=180s
kubectl -n "$NS" exec metadata-client -- sh -c 'command -v wget >/dev/null'
[[ -z $(kubectl -n "$NS" get networkpolicy -o name) ]]
cat <<'MESSAGE'
=================================================
 CKS LAB READY
=================================================
Scenario preparation completed successfully.
Exercise namespace: metadata-protect
Workload: metadata-client
The playground CNI must support Kubernetes egress NetworkPolicy enforcement.
MESSAGE
