#!/usr/bin/env bash
set -Eeuo pipefail

NS_TARGET="prod-x12cs"
NS_ALLOWED="prod-yx13cs"
NS_OTHER="prod-z99cs"

echo "================================================="
echo " CKS LAB - NetworkPolicy Redis"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

command -v kubectl >/dev/null 2>&1 || {
    echo "[ERROR] kubectl not found"
    exit 1
}

echo
echo "[1/4] Preparing namespaces..."

for ns in "$NS_TARGET" "$NS_ALLOWED" "$NS_OTHER"; do
    kubectl create namespace "$ns" \
        --dry-run=client -o yaml |
        kubectl apply -f - >/dev/null
done

echo "[OK] Namespaces ready"


echo
echo "[2/4] Preparing Redis workload..."

kubectl -n "$NS_TARGET" delete \
    networkpolicy allow-redis-access \
    --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "$NS_TARGET" delete pod redis-backend \
    --ignore-not-found \
    --wait=true >/dev/null 2>&1 || true

kubectl -n "$NS_TARGET" delete service redis-backend \
    --ignore-not-found >/dev/null 2>&1 || true

cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: redis-backend
  namespace: prod-x12cs
  labels:
    app: redis-backend
    tier: backend
spec:
  containers:
  - name: redis
    image: redis:7.2-alpine
    ports:
    - containerPort: 6379
      protocol: TCP
---
apiVersion: v1
kind: Service
metadata:
  name: redis-backend
  namespace: prod-x12cs
spec:
  type: ClusterIP
  selector:
    app: redis-backend
  ports:
  - port: 6379
    targetPort: 6379
    protocol: TCP
YAML

kubectl -n "$NS_TARGET" \
    wait --for=condition=Ready \
    pod/redis-backend \
    --timeout=120s >/dev/null

echo "[OK] Redis workload ready"


echo
echo "[3/4] Preparing client workloads..."

for ns in "$NS_TARGET" "$NS_ALLOWED" "$NS_OTHER"; do
    kubectl -n "$ns" delete pod \
        client-allowed \
        client-denied \
        client-test \
        --ignore-not-found \
        --wait=false >/dev/null 2>&1 || true
done

cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: client-allowed
  namespace: prod-x12cs
  labels:
    backend: prod-x12cs
spec:
  containers:
  - name: client
    image: redis:7.2-alpine
    command: ["sh", "-c", "sleep infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-denied
  namespace: prod-x12cs
  labels:
    backend: other
spec:
  containers:
  - name: client
    image: redis:7.2-alpine
    command: ["sh", "-c", "sleep infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-allowed
  namespace: prod-yx13cs
  labels:
    role: test
spec:
  containers:
  - name: client
    image: redis:7.2-alpine
    command: ["sh", "-c", "sleep infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: client-denied
  namespace: prod-z99cs
  labels:
    role: test
spec:
  containers:
  - name: client
    image: redis:7.2-alpine
    command: ["sh", "-c", "sleep infinity"]
YAML

for item in \
    "prod-x12cs client-allowed" \
    "prod-x12cs client-denied" \
    "prod-yx13cs client-allowed" \
    "prod-z99cs client-denied"
do
    set -- $item

    kubectl -n "$1" \
        wait --for=condition=Ready \
        pod/"$2" \
        --timeout=120s >/dev/null
done

echo "[OK] Client workloads ready"


echo
echo "[4/4] Verifying scenario..."

ERRORS=0

if ! kubectl -n "$NS_TARGET" \
    get pod redis-backend \
    -o jsonpath='{.status.phase}' |
    grep -q '^Running$'; then
    ERRORS=$((ERRORS + 1))
fi

if ! kubectl -n "$NS_TARGET" \
    get svc redis-backend \
    -o jsonpath='{.spec.type}' |
    grep -q '^ClusterIP$'; then
    ERRORS=$((ERRORS + 1))
fi

if [[ "$(
    kubectl -n "$NS_TARGET" \
        get pod redis-backend \
        -o jsonpath='{.metadata.labels.app}'
)" != "redis-backend" ]]; then
    ERRORS=$((ERRORS + 1))
fi

if [[ "$(
    kubectl -n "$NS_TARGET" \
        get pod client-allowed \
        -o jsonpath='{.metadata.labels.backend}'
)" != "prod-x12cs" ]]; then
    ERRORS=$((ERRORS + 1))
fi

if ! kubectl -n "$NS_TARGET" exec client-allowed -- \
    redis-cli \
        -h redis-backend \
        -p 6379 \
        ping 2>/dev/null |
    grep -q '^PONG$'; then

    echo "[ERROR] Baseline connectivity test failed"
    ERRORS=$((ERRORS + 1))
fi

if [[ "$ERRORS" -ne 0 ]]; then
    echo "[ERROR] Scenario validation failed"
    exit 1
fi

echo
echo "================================================="
echo " CKS NETWORKPOLICY LAB READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo "You can start the exercise."
echo