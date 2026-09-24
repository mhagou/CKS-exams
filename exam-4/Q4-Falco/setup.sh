#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the playground controlplane. Falco installation is a task objective,
# so deliberately do not install it or alter existing Falco configuration.
NS=cks-q4-falco
IMAGE=${LAB_IMAGE:-busybox:1.37}
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null
kubectl get node controlplane node01 >/dev/null
kubectl wait --for=condition=Ready node/controlplane node/node01 --timeout=120s
if kubectl get namespace "$NS" >/dev/null 2>&1; then
    [[ $(kubectl get namespace "$NS" -o jsonpath='{.metadata.labels.cks-exercise}') == q4-falco ]] || {
        echo "Namespace $NS already exists and is not owned by this lab." >&2; exit 1;
    }
else
    kubectl create namespace "$NS"
    kubectl label namespace "$NS" cks-exercise=q4-falco
fi
# Only this lab's practice pod is reset. No worker host preparation is needed.
kubectl -n "$NS" delete pod shell-practice --ignore-not-found --wait=true
kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: shell-practice
  namespace: $NS
spec:
  nodeName: controlplane
  tolerations:
    - operator: Exists
  terminationGracePeriodSeconds: 0
  containers:
    - name: practice
      image: $IMAGE
      command: ["sleep", "2147483647"]
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          memory: 64Mi
YAML
kubectl -n "$NS" wait --for=condition=Ready pod/shell-practice --timeout=180s
kubectl -n "$NS" exec shell-practice -- /bin/true
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nPractice pod: %s/shell-practice on controlplane.\n' "$NS"
