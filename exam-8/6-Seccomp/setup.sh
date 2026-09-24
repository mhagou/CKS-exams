#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
# jq is used to validate the semantics of the candidate's JSON profile.
if ! command -v jq >/dev/null; then
    if command -v apt-get >/dev/null; then
        apt-get update
        apt-get install -y jq
    elif command -v dnf >/dev/null; then
        dnf install -y jq
    else
        echo 'Install jq on the playground, then rerun setup.' >&2
        exit 1
    fi
fi
kubectl get node controlplane >/dev/null
kubectl wait --for=condition=Ready node/controlplane --timeout=120s

# Preserve namespace policy and unrelated resources if the namespace exists.
if ! kubectl get namespace secure-runtime >/dev/null 2>&1; then
    kubectl create namespace secure-runtime
fi
# Only this exercise's named pod is reset. Existing profile files are preserved.
kubectl -n secure-runtime delete pod secure-app --ignore-not-found --wait=true --timeout=90s
kubectl create -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
  namespace: secure-runtime
spec:
  nodeName: controlplane
  securityContext:
    seccompProfile:
      type: Unconfined
  containers:
    - name: nginx-container
      image: nginx:alpine
      ports:
        - containerPort: 80
      readinessProbe:
        httpGet:
          path: /
          port: 80
        initialDelaySeconds: 2
        periodSeconds: 3
YAML
kubectl -n secure-runtime wait --for=condition=Ready pod/secure-app --timeout=180s
kubectl -n secure-runtime get pod secure-app -o json | jq -e '
  .spec.nodeName == "controlplane" and
  .spec.securityContext.seccompProfile.type == "Unconfined" and
  .status.phase == "Running"
' >/dev/null
kubectl -n secure-runtime exec secure-app -- sh -c \
    'wget -q -O /dev/null -T 5 http://127.0.0.1:80/'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
