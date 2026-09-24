#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="/root/cks-lab-strict-pod"
LAB_FILE="${LAB_DIR}/strict-pod.yaml"

echo "================================================="
echo " CKS LAB - ServiceAccount / Projected Token"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

command -v kubectl >/dev/null 2>&1 || {
    echo "[ERROR] kubectl not found"
    exit 1
}

mkdir -p "$LAB_DIR"

echo
echo "[1/3] Preparing scenario..."

kubectl delete pod immutable-pod \
    --ignore-not-found \
    --wait=true >/dev/null 2>&1 || true

kubectl delete serviceaccount vault-sa \
    --ignore-not-found >/dev/null 2>&1 || true

cat > "$LAB_FILE" <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: vault-sa
---
apiVersion: v1
kind: Pod
metadata:
  name: immutable-pod
spec:
  serviceAccountName: vault-sa
  containers:
  - name: app
    image: busybox:1.36
    command: ["sleep", "3600"]
YAML

kubectl apply -f "$LAB_FILE" >/dev/null

echo "[OK] Scenario created"


echo
echo "[2/3] Waiting for workload..."

kubectl wait \
    --for=condition=Ready \
    pod/immutable-pod \
    --timeout=120s >/dev/null

echo "[OK] Workload ready"


echo
echo "[3/3] Verifying scenario..."

ERRORS=0

[[ -f "$LAB_FILE" ]] || ERRORS=$((ERRORS + 1))

if [[ "$(
    kubectl get pod immutable-pod \
        -o jsonpath='{.spec.serviceAccountName}'
)" != "vault-sa" ]]; then
    ERRORS=$((ERRORS + 1))
fi

if [[ "$(
    kubectl get pod immutable-pod \
        -o jsonpath='{.status.phase}'
)" != "Running" ]]; then
    ERRORS=$((ERRORS + 1))
fi

if [[ "$ERRORS" -ne 0 ]]; then
    echo "[ERROR] Scenario validation failed"
    exit 1
fi

echo
echo "================================================="
echo " CKS LAB READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo
echo "Lab file:"
echo "  ${LAB_FILE}"
echo
