#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="/root/cks-lab-q3"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
ETCD_MANIFEST="/etc/kubernetes/manifests/etcd.yaml"

echo "================================================="
echo " CKS LAB 03 - Scenario setup"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

mkdir -p "$LAB_DIR"

ERRORS=0


# ============================================================
# Prerequisites
# ============================================================

echo
echo "[1/4] Checking prerequisites..."

for cmd in kubectl curl tar grep awk sha256sum; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "[ERROR] Missing command: $cmd"
        exit 1
    fi
done

[[ -f "$APISERVER_MANIFEST" ]] || {
    echo "[ERROR] kube-apiserver manifest not found"
    exit 1
}

[[ -f "$ETCD_MANIFEST" ]] || {
    echo "[ERROR] etcd manifest not found"
    exit 1
}

echo "[OK] Prerequisites available"


# ============================================================
# etcdctl
# ============================================================

echo
echo "[2/4] Checking etcdctl..."

if ! command -v etcdctl >/dev/null 2>&1; then

    ARCH="$(uname -m)"

    case "$ARCH" in
        x86_64)
            ETCD_ARCH="amd64"
            ;;
        aarch64|arm64)
            ETCD_ARCH="arm64"
            ;;
        *)
            echo "[ERROR] Unsupported architecture: $ARCH"
            exit 1
            ;;
    esac

    ETCD_IMAGE="$(
        awk '
            /image:/ && /etcd:/ {
                print $2
                exit
            }
        ' "$ETCD_MANIFEST"
    )"

    if [[ -z "$ETCD_IMAGE" ]]; then
        echo "[ERROR] Cannot determine etcd version"
        exit 1
    fi

    ETCD_VERSION="$(
        echo "$ETCD_IMAGE" |
        sed -E 's#.*etcd:##' |
        sed -E 's/-[0-9]+$//'
    )"

    if [[ ! "$ETCD_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "[ERROR] Unsupported etcd version format: ${ETCD_VERSION}"
        exit 1
    fi

    TMP_DIR="$(mktemp -d)"
    trap 'rm -rf "$TMP_DIR"' EXIT

    ARCHIVE="etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}.tar.gz"

    URL="https://github.com/etcd-io/etcd/releases/download/v${ETCD_VERSION}/${ARCHIVE}"

    echo "[INFO] Installing required lab tooling..."

    curl -fsSL "$URL" \
        -o "${TMP_DIR}/${ARCHIVE}"

    tar -xzf "${TMP_DIR}/${ARCHIVE}" \
        -C "$TMP_DIR"

    install -m 0755 \
        "${TMP_DIR}/etcd-v${ETCD_VERSION}-linux-${ETCD_ARCH}/etcdctl" \
        /usr/local/bin/etcdctl

    rm -rf "$TMP_DIR"
    trap - EXIT
fi


if ! etcdctl version >/dev/null 2>&1; then
    echo "[ERROR] etcdctl validation failed"
    exit 1
fi

echo "[OK] Required tooling ready"


# ============================================================
# Environment
# ============================================================

echo
echo "[3/4] Preparing scenario..."

# Remove artifacts from a previous execution of this lab
rm -f /etc/kubernetes/etcd-encryption.yaml

# A clean initial state is expected.
if grep -q -- '--encryption-provider-config' \
    "$APISERVER_MANIFEST"; then

    echo "[ERROR] Existing encryption-provider configuration detected."
    echo "[ERROR] This playground is not in the expected initial state."
    exit 1
fi


# Make sure cluster is healthy before starting the exercise.
if ! kubectl get --raw='/readyz' >/dev/null 2>&1; then
    echo "[ERROR] Kubernetes API server is not healthy"
    exit 1
fi

echo "[OK] Scenario component ready"


# ============================================================
# etcd access validation
# ============================================================

echo
echo "[4/4] Verifying scenario..."

ETCD_CA="/etc/kubernetes/pki/etcd/ca.crt"
ETCD_CERT="/etc/kubernetes/pki/apiserver-etcd-client.crt"
ETCD_KEY="/etc/kubernetes/pki/apiserver-etcd-client.key"

for f in "$ETCD_CA" "$ETCD_CERT" "$ETCD_KEY"; do
    if [[ ! -f "$f" ]]; then
        echo "[ERROR] Required cluster file missing"
        ERRORS=$((ERRORS + 1))
    fi
done


if [[ "$ERRORS" -eq 0 ]]; then

    if ! ETCDCTL_API=3 etcdctl \
        --endpoints=https://127.0.0.1:2379 \
        --cacert="$ETCD_CA" \
        --cert="$ETCD_CERT" \
        --key="$ETCD_KEY" \
        endpoint health >/dev/null 2>&1; then

        echo "[ERROR] etcd validation failed"
        ERRORS=$((ERRORS + 1))
    fi

fi


if ! kubectl get nodes >/dev/null 2>&1; then
    echo "[ERROR] Cluster validation failed"
    ERRORS=$((ERRORS + 1))
fi


if [[ "$ERRORS" -ne 0 ]]; then
    echo
    echo "[ERROR] Scenario validation failed."
    exit 1
fi


echo
echo "================================================="
echo " CKS LAB 03 READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo "You can start the exercise."
echo
