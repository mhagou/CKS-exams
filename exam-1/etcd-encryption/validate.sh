#!/usr/bin/env bash
set -u

APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"
ENCRYPTION_CONFIG="/etc/kubernetes/etcd-encryption.yaml"

ETCD_CA="/etc/kubernetes/pki/etcd/ca.crt"
ETCD_CERT="/etc/kubernetes/pki/apiserver-etcd-client.crt"
ETCD_KEY="/etc/kubernetes/pki/apiserver-etcd-client.key"

TEST_SECRET="cks-encryption-validation-$$"
TEST_NAMESPACE="default"

PASS=0
FAIL=0


pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}

fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}


cleanup() {
    kubectl -n "$TEST_NAMESPACE" \
        delete secret "$TEST_SECRET" \
        --ignore-not-found >/dev/null 2>&1 || true
}

trap cleanup EXIT


echo
echo "================================================="
echo " CKS LAB 03 - VALIDATION"
echo "================================================="


# ============================================================
# PART 1
# ============================================================

echo
echo "---- PART 1 : ENCRYPTION CONFIGURATION -----------"


if [[ -f "$ENCRYPTION_CONFIG" ]]; then
    pass "Encryption configuration file exists"
else
    fail "Encryption configuration file is missing"
fi


if [[ -f "$ENCRYPTION_CONFIG" ]]; then

    if grep -q 'kind:[[:space:]]*EncryptionConfiguration' \
        "$ENCRYPTION_CONFIG"; then

        pass "EncryptionConfiguration resource is defined"
    else
        fail "EncryptionConfiguration resource is invalid"
    fi


    if grep -q 'aescbc:' "$ENCRYPTION_CONFIG"; then
        pass "AES-CBC encryption provider is configured"
    else
        fail "AES-CBC encryption provider is missing"
    fi


    if grep -qE '^[[:space:]]*-[[:space:]]*secrets[[:space:]]*$' \
        "$ENCRYPTION_CONFIG"; then

        pass "Secret resources are configured for encryption"
    else
        fail "Secret resources are not configured for encryption"
    fi

fi


# ============================================================
# PART 2
# ============================================================

echo
echo "---- PART 2 : KUBE-APISERVER --------------------"


if grep -q -- '--encryption-provider-config=' \
    "$APISERVER_MANIFEST"; then

    pass "kube-apiserver uses an encryption provider configuration"
else

    fail "kube-apiserver encryption provider argument is missing"

fi


if grep -q '/etc/kubernetes/etcd-encryption.yaml' \
    "$APISERVER_MANIFEST"; then

    pass "Encryption configuration is available to kube-apiserver"
else

    fail "Encryption configuration is not available to kube-apiserver"

fi


if kubectl get --raw='/readyz' >/dev/null 2>&1; then

    pass "Kubernetes API server is healthy"

else

    fail "Kubernetes API server is not healthy"

fi


# ============================================================
# PART 3
# ============================================================

echo
echo "---- PART 3 : ETCD ENCRYPTION -------------------"


if kubectl -n "$TEST_NAMESPACE" \
    create secret generic "$TEST_SECRET" \
    --from-literal=password='cks-validation-value' \
    >/dev/null 2>&1; then

    pass "API server can create new Secrets"

else

    fail "Unable to create validation Secret"

fi


sleep 1


ETCD_KEY_PATH="/registry/secrets/${TEST_NAMESPACE}/${TEST_SECRET}"


if command -v etcdctl >/dev/null 2>&1; then

    RAW="$(
        ETCDCTL_API=3 etcdctl \
            --endpoints=https://127.0.0.1:2379 \
            --cacert="$ETCD_CA" \
            --cert="$ETCD_CERT" \
            --key="$ETCD_KEY" \
            get "$ETCD_KEY_PATH" \
            --print-value-only \
            2>/dev/null || true
    )"


    if [[ -n "$RAW" ]]; then
        pass "Secret exists directly in etcd"
    else
        fail "Secret could not be retrieved directly from etcd"
    fi


    if printf '%s' "$RAW" |
       grep -a -q 'k8s:enc:aescbc:v1'; then

        pass "Secret is encrypted with AES-CBC in etcd"

    else

        fail "Secret is not stored with the expected AES-CBC encryption prefix"

    fi


    if printf '%s' "$RAW" |
       grep -a -q 'cks-validation-value'; then

        fail "Plaintext Secret data is visible directly in etcd"

    else

        pass "Plaintext Secret data is not visible in etcd"

    fi

else

    fail "etcdctl is not available"

fi


# ============================================================
# Result
# ============================================================

echo
echo "================================================="
echo " RESULT"
echo "================================================="
echo
echo "PASS : $PASS"
echo "FAIL : $FAIL"
echo


if [[ "$FAIL" -eq 0 ]]; then

    echo "RESULT: SUCCESS"
    echo
    echo "Lab completed successfully."
    exit 0

else

    echo "RESULT: FAILED"
    echo
    echo "Some objectives are not yet satisfied."
    exit 1

fi