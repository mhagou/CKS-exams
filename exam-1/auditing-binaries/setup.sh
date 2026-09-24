#!/usr/bin/env bash

set -Eeuo pipefail

LAB_DIR="/root/cks-lab-q1"
BACKUP_DIR="${LAB_DIR}/backup"

KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

WORKER="node01"
KUBEBENCH_VERSION="0.16.0"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

echo "================================================="
echo " CKS LAB 01 - Scenario setup"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

mkdir -p "$LAB_DIR" "$BACKUP_DIR"


# ============================================================
# 1. Prerequisites
# ============================================================

echo
echo "[1/5] Checking prerequisites..."

for cmd in curl tar sha256sum sha512sum python3 ssh kubectl; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $cmd"
        exit 1
    fi
done

if ! ssh ${SSH_OPTS} "$WORKER" "true" >/dev/null 2>&1; then
    echo "[ERROR] Cannot SSH to ${WORKER}"
    exit 1
fi

if ! ssh ${SSH_OPTS} "$WORKER" \
    "command -v crictl >/dev/null 2>&1"; then
    echo "[ERROR] crictl is not available on ${WORKER}"
    exit 1
fi

if ! ssh ${SSH_OPTS} "$WORKER" \
    "crictl info >/dev/null 2>&1"; then
    echo "[ERROR] crictl cannot communicate with CRI on ${WORKER}"
    exit 1
fi

echo "[OK] Prerequisites available"


# ============================================================
# 2. kube-bench
# ============================================================

echo
echo "[2/5] Checking kube-bench..."

if ! command -v kube-bench >/dev/null 2>&1; then

    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64)
            KB_ARCH="amd64"
            EXPECTED_SHA256="82dbc7e598740dc9344d41f8ad0b8210d57c4c00bdb2c5f1d8a69a2b98baddcf"
            ;;
        aarch64|arm64)
            KB_ARCH="arm64"
            EXPECTED_SHA256="64500561f5fcaa3f86fe951ed26bbfc28f7bbf3d2eac13843abfd2924955d10b"
            ;;
        *)
            echo "[ERROR] Unsupported architecture: ${ARCH}"
            exit 1
            ;;
    esac

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    ARCHIVE_NAME="kube-bench_${KUBEBENCH_VERSION}_linux_${KB_ARCH}.tar.gz"
    ARCHIVE="${TMP_DIR}/${ARCHIVE_NAME}"

    URL="https://github.com/aquasecurity/kube-bench/releases/download/v${KUBEBENCH_VERSION}/${ARCHIVE_NAME}"

    curl -fsSL "$URL" -o "$ARCHIVE"

    ACTUAL_SHA256="$(sha256sum "$ARCHIVE" | awk '{print $1}')"

    if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
        echo "[ERROR] kube-bench checksum verification failed"
        exit 1
    fi

    tar -xzf "$ARCHIVE" -C "$TMP_DIR"

    install -m 0755 \
        "${TMP_DIR}/kube-bench" \
        /usr/local/bin/kube-bench

    mkdir -p /etc/kube-bench
    rm -rf /etc/kube-bench/cfg
    cp -a "${TMP_DIR}/cfg" /etc/kube-bench/

    rm -rf "$TMP_DIR"
    trap - EXIT

fi

if ! kube-bench version >/dev/null 2>&1; then
    echo "[ERROR] kube-bench validation failed"
    exit 1
fi

echo "[OK] kube-bench ready"


# ============================================================
# 3. Scenario A
# ============================================================

echo
echo "[3/5] Preparing scenario..."

if [[ ! -f "$KUBELET_CONFIG" ]]; then
    echo "[ERROR] Required configuration not found"
    exit 1
fi

if [[ ! -f "${BACKUP_DIR}/kubelet-config.yaml" ]]; then
    cp -a "$KUBELET_CONFIG" \
        "${BACKUP_DIR}/kubelet-config.yaml"
else
    cp -a "${BACKUP_DIR}/kubelet-config.yaml" \
        "$KUBELET_CONFIG"
fi

python3 - "$KUBELET_CONFIG" <<'PY'
import sys

path = sys.argv[1]

with open(path) as f:
    lines = f.readlines()

auth_indent = None
anonymous_indent = None
modified = False

for i, line in enumerate(lines):

    stripped = line.strip()

    if not stripped or stripped.startswith("#"):
        continue

    indent = len(line) - len(line.lstrip())

    if stripped == "authentication:":
        auth_indent = indent
        anonymous_indent = None
        continue

    if auth_indent is not None:

        if indent <= auth_indent:
            auth_indent = None
            anonymous_indent = None

        elif stripped == "anonymous:":
            anonymous_indent = indent
            continue

    if anonymous_indent is not None:

        if indent <= anonymous_indent:
            anonymous_indent = None

        elif stripped.startswith("enabled:"):
            prefix = line[:len(line) - len(line.lstrip())]
            lines[i] = prefix + "enabled: true\n"
            modified = True
            break

if not modified:
    raise SystemExit(1)

with open(path, "w") as f:
    f.writelines(lines)
PY

systemctl restart kubelet

sleep 3

if ! systemctl is-active --quiet kubelet; then
    echo "[ERROR] Scenario preparation failed"
    exit 1
fi

echo "[OK] Scenario component ready"


# ============================================================
# 4. Scenario B
# ============================================================

echo
echo "[4/5] Preparing scenario..."

if [[ ! -f "$APISERVER_MANIFEST" ]]; then
    echo "[ERROR] Required manifest not found"
    exit 1
fi

if [[ ! -f "${BACKUP_DIR}/kube-apiserver.yaml" ]]; then

    cp -a "$APISERVER_MANIFEST" \
        "${BACKUP_DIR}/kube-apiserver.yaml"

else

    cp -a "${BACKUP_DIR}/kube-apiserver.yaml" \
        "$APISERVER_MANIFEST"

fi

GOOD_HASH="$(
    sha512sum "$APISERVER_MANIFEST" |
    awk '{print $1}'
)"

echo "$GOOD_HASH" \
    > "${LAB_DIR}/kube-apiserver-known-good.sha512"

printf '\n# CKS-LAB integrity marker\n' \
    >> "$APISERVER_MANIFEST"

CURRENT_HASH="$(
    sha512sum "$APISERVER_MANIFEST" |
    awk '{print $1}'
)"

if [[ "$GOOD_HASH" == "$CURRENT_HASH" ]]; then
    echo "[ERROR] Scenario preparation failed"
    exit 1
fi

echo "[OK] Scenario component ready"


# ============================================================
# 5. Scenario C - CRI
# ============================================================

echo
echo "[5/5] Preparing worker scenario..."

ssh ${SSH_OPTS} "$WORKER" 'bash -s' <<'REMOTE'
set -Eeuo pipefail

LAB="/tmp/cks-lab-q1"
POD_NAME="cks-runtime-service"
CONTAINER_NAME="system-monitor"
IMAGE="docker.io/library/busybox:1.36.1"

mkdir -p "$LAB"


# ------------------------------------------------------------
# Clean previous instance
# ------------------------------------------------------------

OLD_CONTAINERS="$(
    crictl ps -a \
        --name "$CONTAINER_NAME" \
        -q 2>/dev/null || true
)"

for id in $OLD_CONTAINERS; do
    crictl stop "$id" >/dev/null 2>&1 || true
    crictl rm "$id" >/dev/null 2>&1 || true
done


OLD_PODS="$(
    crictl pods \
        --name "$POD_NAME" \
        -q 2>/dev/null || true
)"

for id in $OLD_PODS; do
    crictl stopp "$id" >/dev/null 2>&1 || true
    crictl rmp "$id" >/dev/null 2>&1 || true
done


# ------------------------------------------------------------
# Image
# ------------------------------------------------------------

crictl pull "$IMAGE" >/dev/null


# ------------------------------------------------------------
# CRI configs
# ------------------------------------------------------------

cat > "${LAB}/pod.json" <<'JSON'
{
  "metadata": {
    "name": "cks-runtime-service",
    "namespace": "system-services",
    "uid": "cks-runtime-service",
    "attempt": 1
  },
  "hostname": "worker-service",
  "log_directory": "/tmp",
  "linux": {}
}
JSON


cat > "${LAB}/container.json" <<'JSON'
{
  "metadata": {
    "name": "system-monitor",
    "attempt": 1
  },
  "image": {
    "image": "docker.io/library/busybox:1.36.1"
  },
  "command": [
    "/bin/sh",
    "-c"
  ],
  "args": [
    "cp /bin/sleep /tmp/cryptominer && exec /tmp/cryptominer 86400"
  ],
  "log_path": "system-monitor.log",
  "stdin": false,
  "stdin_once": false,
  "tty": false,
  "linux": {}
}
JSON


# ------------------------------------------------------------
# Create through CRI
# ------------------------------------------------------------

POD_ID="$(
    crictl runp "${LAB}/pod.json"
)"

if [[ -z "$POD_ID" ]]; then
    echo "[ERROR] Worker scenario preparation failed"
    exit 1
fi


CONTAINER_ID="$(
    crictl create \
        "$POD_ID" \
        "${LAB}/container.json" \
        "${LAB}/pod.json"
)"

if [[ -z "$CONTAINER_ID" ]]; then
    echo "[ERROR] Worker scenario preparation failed"
    exit 1
fi


crictl start "$CONTAINER_ID" >/dev/null

sleep 2


# ------------------------------------------------------------
# Internal verification
# ------------------------------------------------------------

if ! crictl ps \
    --name "$CONTAINER_NAME" \
    -q |
    grep -q .; then

    echo "[ERROR] Worker scenario preparation failed"
    exit 1
fi


if ! ps -eo comm,args |
    grep -q '[c]ryptominer'; then

    echo "[ERROR] Worker scenario preparation failed"
    exit 1
fi

REMOTE

echo "[OK] Worker scenario ready"


# ============================================================
# Final verification
# ============================================================

echo
echo "================================================="
echo " Verifying scenario"
echo "================================================="

ERRORS=0

if ! systemctl is-active --quiet kubelet; then
    ERRORS=$((ERRORS + 1))
fi


KNOWN_HASH="$(
    cat "${LAB_DIR}/kube-apiserver-known-good.sha512"
)"

CURRENT_HASH="$(
    sha512sum "$APISERVER_MANIFEST" |
    awk '{print $1}'
)"

if [[ "$KNOWN_HASH" == "$CURRENT_HASH" ]]; then
    ERRORS=$((ERRORS + 1))
fi


if ! ssh ${SSH_OPTS} "$WORKER" \
    "crictl ps --name system-monitor -q | grep -q ."; then
    ERRORS=$((ERRORS + 1))
fi


if ! ssh ${SSH_OPTS} "$WORKER" \
    "ps -eo comm,args | grep -q '[c]ryptominer'"; then
    ERRORS=$((ERRORS + 1))
fi


if [[ "$ERRORS" -ne 0 ]]; then
    echo
    echo "[ERROR] Scenario validation failed"
    exit 1
fi


echo
echo "================================================="
echo " CKS LAB 01 READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo "You can start the exercise."
echo

