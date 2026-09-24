#!/usr/bin/env bash
set -Eeuo pipefail

WORKER="node01"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
LAB_NS="falco-lab"

echo "================================================="
echo " CKS LAB 04 - Scenario setup"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

# ============================================================
# 1. Prerequisites
# ============================================================

echo
echo "[1/4] Checking prerequisites..."

for cmd in kubectl ssh; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Missing command: $cmd"
        exit 1
    }
done

ssh ${SSH_OPTS} "$WORKER" true >/dev/null 2>&1 || {
    echo "[ERROR] Cannot SSH to ${WORKER}"
    exit 1
}

echo "[OK] Prerequisites available"


# ============================================================
# 2. Worker preparation
# ============================================================

echo
echo "[2/4] Preparing worker scenario..."

ssh ${SSH_OPTS} "$WORKER" 'bash -s' <<'REMOTE'
set -Eeuo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Worker SSH session is not root"
    exit 1
fi

# ------------------------------------------------------------
# Install Falco if necessary
# ------------------------------------------------------------

if ! command -v falco >/dev/null 2>&1; then

    export DEBIAN_FRONTEND=noninteractive

    apt-get update -qq
    apt-get install -y \
        curl \
        ca-certificates \
        gnupg \
        dialog >/dev/null

    mkdir -p /usr/share/keyrings

    rm -f /usr/share/keyrings/falco-archive-keyring.gpg

    curl -fsSL \
        https://falco.org/repo/falcosecurity-packages.asc |
        gpg --dearmor \
            -o /usr/share/keyrings/falco-archive-keyring.gpg

    cat > /etc/apt/sources.list.d/falcosecurity.list <<'REPO'
deb [signed-by=/usr/share/keyrings/falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main
REPO

    apt-get update -qq

    FALCO_FRONTEND=noninteractive \
    FALCOCTL_ENABLED=no \
        apt-get install -y falco >/dev/null
fi


# ------------------------------------------------------------
# Required paths
# ------------------------------------------------------------

mkdir -p /etc/falco

touch /etc/falco/falco_rules.local.yaml


# ------------------------------------------------------------
# Clean previous lab state
# ------------------------------------------------------------

cat > /etc/falco/falco_rules.local.yaml <<'RULES'
# Local Falco rules
#
# CKS practice environment.
# Add custom rules below.
RULES


# ------------------------------------------------------------
# Ensure local rules file is loaded
# ------------------------------------------------------------

if [[ -f /etc/falco/falco.yaml ]]; then

    if ! grep -q \
        '/etc/falco/falco_rules.local.yaml' \
        /etc/falco/falco.yaml; then

        echo "[ERROR] Local Falco rules file is not configured"
        exit 1
    fi

else
    echo "[ERROR] /etc/falco/falco.yaml missing"
    exit 1
fi


# ------------------------------------------------------------
# Service
# ------------------------------------------------------------

systemctl daemon-reload

if ! systemctl enable falco >/dev/null 2>&1; then
    true
fi

if ! systemctl restart falco; then
    echo "[ERROR] Unable to start Falco"
    journalctl -u falco --no-pager -n 30 || true
    exit 1
fi

sleep 4

if ! systemctl is-active --quiet falco; then
    echo "[ERROR] Falco service is not running"
    journalctl -u falco --no-pager -n 30 || true
    exit 1
fi

REMOTE

echo "[OK] Worker scenario ready"


# ============================================================
# 3. Kubernetes workload
# ============================================================

echo
echo "[3/4] Preparing Kubernetes workload..."

kubectl delete namespace "$LAB_NS" \
    --ignore-not-found \
    --wait=true >/dev/null 2>&1 || true

kubectl create namespace "$LAB_NS" >/dev/null

cat <<'YAML' | kubectl apply -f - >/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: toolbox
  namespace: falco-lab
  labels:
    app: toolbox
spec:
  nodeName: node01
  containers:
  - name: toolbox
    image: ubuntu:24.04
    command:
    - /bin/sh
    - -c
    - sleep infinity
YAML


if ! kubectl -n "$LAB_NS" \
    wait \
    --for=condition=Ready \
    pod/toolbox \
    --timeout=120s >/dev/null; then

    echo "[ERROR] Lab workload did not become Ready"
    kubectl -n "$LAB_NS" describe pod toolbox
    exit 1
fi

echo "[OK] Kubernetes workload ready"


# ============================================================
# 4. Final validation
# ============================================================

echo
echo "[4/4] Verifying scenario..."

ERRORS=0


if ! ssh ${SSH_OPTS} "$WORKER" \
    "systemctl is-active --quiet falco"; then

    ERRORS=$((ERRORS + 1))
fi


if ! ssh ${SSH_OPTS} "$WORKER" \
    "test -f /etc/falco/falco_rules.local.yaml"; then

    ERRORS=$((ERRORS + 1))
fi


if ! kubectl -n "$LAB_NS" \
    get pod toolbox \
    -o jsonpath='{.status.phase}' |
    grep -q '^Running$'; then

    ERRORS=$((ERRORS + 1))
fi


NODE="$(
    kubectl -n "$LAB_NS" \
        get pod toolbox \
        -o jsonpath='{.spec.nodeName}'
)"

if [[ "$NODE" != "$WORKER" ]]; then
    ERRORS=$((ERRORS + 1))
fi


if ! kubectl -n "$LAB_NS" \
    exec toolbox -- \
    test -r /etc/shadow; then

    ERRORS=$((ERRORS + 1))
fi


if [[ "$ERRORS" -ne 0 ]]; then
    echo
    echo "[ERROR] Scenario validation failed"
    exit 1
fi


echo
echo "================================================="
echo " CKS LAB 04 READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo "You can start the exercise."
echo
