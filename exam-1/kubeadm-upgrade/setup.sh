#!/usr/bin/env bash
set -Eeuo pipefail

WORKER="node01"
LAB_DIR="/root/cks-lab-q4"
STATE_FILE="${LAB_DIR}/state.env"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

echo "================================================="
echo " CKS LAB 05 - Scenario setup"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

mkdir -p "$LAB_DIR"

echo
echo "[1/4] Checking prerequisites..."

for cmd in kubectl ssh awk sed sort; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "[ERROR] Missing command: $cmd"
        exit 1
    }
done

ssh ${SSH_OPTS} "$WORKER" true >/dev/null 2>&1 || {
    echo "[ERROR] Cannot SSH to ${WORKER}"
    exit 1
}

kubectl get node "$WORKER" >/dev/null 2>&1 || {
    echo "[ERROR] Kubernetes node ${WORKER} not found"
    exit 1
}

echo "[OK] Prerequisites available"


# ============================================================
# Worker preparation
# ============================================================

echo
echo "[2/4] Preparing worker scenario..."

ssh ${SSH_OPTS} "$WORKER" 'bash -s' <<'REMOTE'
set -Eeuo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
    echo "[ERROR] This lab currently expects an APT-based worker"
    exit 1
fi

for pkg in kubeadm kubelet kubectl; do
    dpkg-query -W "$pkg" >/dev/null 2>&1 || {
        echo "[ERROR] Missing package: $pkg"
        exit 1
    }
done

KUBELET_VERSION="$(
    kubelet --version |
    awk '{print $2}' |
    sed 's/^v//'
)"

MAJOR="$(echo "$KUBELET_VERSION" | cut -d. -f1)"
MINOR="$(echo "$KUBELET_VERSION" | cut -d. -f2)"

REPO_MINOR="v${MAJOR}.${MINOR}"

mkdir -p /etc/apt/keyrings

if [[ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]]; then
    curl -fsSL \
      "https://pkgs.k8s.io/core:/stable:/${REPO_MINOR}/deb/Release.key" |
      gpg --dearmor \
        -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
fi

cat > /etc/apt/sources.list.d/kubernetes.list <<REPO
deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${REPO_MINOR}/deb/ /
REPO

chmod 644 /etc/apt/sources.list.d/kubernetes.list

apt-get update -qq

mapfile -t VERSIONS < <(
    apt-cache madison kubelet |
    awk '{print $3}' |
    grep "^${MAJOR}\.${MINOR}\." |
    sort -V -r |
    uniq
)

if [[ "${#VERSIONS[@]}" -lt 2 ]]; then
    echo "[ERROR] Not enough package versions are available"
    exit 1
fi

TARGET_VERSION="${VERSIONS[0]}"
LAB_VERSION="${VERSIONS[1]}"

CURRENT_VERSION="$(
    dpkg-query -W -f='${Version}' kubelet
)"

if [[ "$CURRENT_VERSION" != "$LAB_VERSION" ]]; then

    apt-mark unhold \
        kubeadm kubelet kubectl >/dev/null 2>&1 || true

    apt-get install -y \
        --allow-downgrades \
        kubeadm="$LAB_VERSION" \
        kubelet="$LAB_VERSION" \
        kubectl="$LAB_VERSION" \
        >/dev/null

    apt-mark hold \
        kubeadm kubelet kubectl >/dev/null
fi

systemctl daemon-reload
systemctl restart kubelet

sleep 4

if ! systemctl is-active --quiet kubelet; then
    echo "[ERROR] kubelet failed to start"
    exit 1
fi

cat > /root/.cks-upgrade-state <<STATE
BASE_KUBEADM=$(dpkg-query -W -f='${Version}' kubeadm)
BASE_KUBELET=$(dpkg-query -W -f='${Version}' kubelet)
BASE_KUBECTL=$(dpkg-query -W -f='${Version}' kubectl)
TARGET_VERSION=${TARGET_VERSION}
STATE

REMOTE

echo "[OK] Worker scenario ready"


# ============================================================
# Workload
# ============================================================

echo
echo "[3/4] Preparing Kubernetes workload..."

kubectl delete deployment upgrade-lab \
    --ignore-not-found >/dev/null 2>&1 || true

kubectl create deployment upgrade-lab \
    --image=nginx:1.25.2 >/dev/null

kubectl patch deployment upgrade-lab \
    --type='merge' \
    -p "{
      \"spec\": {
        \"template\": {
          \"spec\": {
            \"nodeSelector\": {
              \"kubernetes.io/hostname\": \"${WORKER}\"
            }
          }
        }
      }
    }" >/dev/null

kubectl rollout status deployment/upgrade-lab \
    --timeout=120s >/dev/null

POD_NODE="$(
    kubectl get pods \
      -l app=upgrade-lab \
      -o jsonpath='{.items[0].spec.nodeName}'
)"

if [[ "$POD_NODE" != "$WORKER" ]]; then
    echo "[ERROR] Workload is not running on ${WORKER}"
    exit 1
fi

echo "[OK] Workload ready"


# ============================================================
# Baseline / final verification
# ============================================================

echo
echo "[4/4] Verifying scenario..."

ssh ${SSH_OPTS} "$WORKER" \
    "cat /root/.cks-upgrade-state" \
    > "$STATE_FILE"

BASE_KUBEADM="$(
    grep '^BASE_KUBEADM=' "$STATE_FILE" |
    cut -d= -f2-
)"

BASE_KUBELET="$(
    grep '^BASE_KUBELET=' "$STATE_FILE" |
    cut -d= -f2-
)"

BASE_KUBECTL="$(
    grep '^BASE_KUBECTL=' "$STATE_FILE" |
    cut -d= -f2-
)"

TARGET_VERSION="$(
    grep '^TARGET_VERSION=' "$STATE_FILE" |
    cut -d= -f2-
)"

ERRORS=0

[[ -n "$TARGET_VERSION" ]] || ERRORS=$((ERRORS + 1))

[[ "$BASE_KUBEADM" != "$TARGET_VERSION" ]] || ERRORS=$((ERRORS + 1))
[[ "$BASE_KUBELET" != "$TARGET_VERSION" ]] || ERRORS=$((ERRORS + 1))
[[ "$BASE_KUBECTL" != "$TARGET_VERSION" ]] || ERRORS=$((ERRORS + 1))

if ! ssh ${SSH_OPTS} "$WORKER" \
    "apt-cache madison kubelet | grep -F '$TARGET_VERSION' >/dev/null"; then
    ERRORS=$((ERRORS + 1))
fi

if ! kubectl get node "$WORKER" \
    -o jsonpath='{.spec.unschedulable}' |
    grep -vq '^true$'; then
    ERRORS=$((ERRORS + 1))
fi

if ! kubectl get node "$WORKER" \
    -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' |
    grep -q '^True$'; then
    ERRORS=$((ERRORS + 1))
fi

if [[ "$ERRORS" -ne 0 ]]; then
    echo
    echo "[ERROR] Scenario validation failed"
    exit 1
fi

echo
echo "================================================="
echo " CKS LAB 05 READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo "You can start the exercise."
echo
