#!/usr/bin/env bash
set -u

SA="vault-sa"
POD="immutable-pod"

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

echo
echo "================================================="
echo " CKS LAB - VALIDATION"
echo "================================================="


# ============================================================
# PART 1 : ServiceAccount
# ============================================================

echo
echo "---- PART 1 : SERVICE ACCOUNT -------------------"

if kubectl get serviceaccount "$SA" >/dev/null 2>&1; then
    pass "ServiceAccount vault-sa exists"
else
    fail "ServiceAccount vault-sa does not exist"
fi


AUTOMOUNT="$(
    kubectl get serviceaccount "$SA" \
        -o jsonpath='{.automountServiceAccountToken}' \
        2>/dev/null
)"

if [[ "$AUTOMOUNT" == "false" ]]; then
    pass "ServiceAccount automatic token mounting is disabled"
else
    fail "ServiceAccount still automounts API tokens by default"
fi


# ============================================================
# PART 2 : Pod security
# ============================================================

echo
echo "---- PART 2 : POD SECURITY ----------------------"

if ! kubectl get pod "$POD" >/dev/null 2>&1; then
    fail "immutable-pod does not exist"
else

    SA_NAME="$(
        kubectl get pod "$POD" \
            -o jsonpath='{.spec.serviceAccountName}'
    )"

    if [[ "$SA_NAME" == "$SA" ]]; then
        pass "Pod uses vault-sa"
    else
        fail "Pod does not use vault-sa"
    fi


    READ_ONLY="$(
        kubectl get pod "$POD" \
            -o jsonpath='{.spec.containers[?(@.name=="app")].securityContext.readOnlyRootFilesystem}'
    )"

    if [[ "$READ_ONLY" == "true" ]]; then
        pass "Root filesystem is read-only"
    else
        fail "readOnlyRootFilesystem is not enabled"
    fi


    RUN_AS_NON_ROOT="$(
        kubectl get pod "$POD" \
            -o jsonpath='{.spec.containers[?(@.name=="app")].securityContext.runAsNonRoot}'
    )"

    if [[ -z "$RUN_AS_NON_ROOT" ]]; then
        RUN_AS_NON_ROOT="$(
            kubectl get pod "$POD" \
                -o jsonpath='{.spec.securityContext.runAsNonRoot}'
        )"
    fi

    if [[ "$RUN_AS_NON_ROOT" == "true" ]]; then
        pass "runAsNonRoot is enabled"
    else
        fail "runAsNonRoot is not enabled"
    fi

fi


# ============================================================
# PART 3 : Projected token
# ============================================================

echo
echo "---- PART 3 : PROJECTED TOKEN -------------------"

PROJECTED_TOKEN="$(
    kubectl get pod "$POD" -o json |
    python3 -c '
import json, sys

d = json.load(sys.stdin)
found = False

for volume in d.get("spec", {}).get("volumes", []):
    projected = volume.get("projected", {})

    for source in projected.get("sources", []):
        token = source.get("serviceAccountToken")

        if token is not None:
            if token.get("path") == "token":
                found = True

print("yes" if found else "no")
'
)"

if [[ "$PROJECTED_TOKEN" == "yes" ]]; then
    pass "ServiceAccount token uses a Projected Volume"
else
    fail "Projected ServiceAccount token volume is missing"
fi


TOKEN_MOUNT="$(
    kubectl get pod "$POD" -o json |
    python3 -c '
import json, sys

d = json.load(sys.stdin)
found = False

for container in d.get("spec", {}).get("containers", []):
    if container.get("name") != "app":
        continue

    for mount in container.get("volumeMounts", []):
        if mount.get("mountPath") == "/var/run/secrets/kubernetes.io/serviceaccount":
            found = True

print("yes" if found else "no")
'
)"

if [[ "$TOKEN_MOUNT" == "yes" ]]; then
    pass "Projected token is mounted in the ServiceAccount directory"
else
    fail "Projected token mount path is incorrect"
fi


# ============================================================
# PART 4 : /tmp emptyDir
# ============================================================

echo
echo "---- PART 4 : TMP VOLUME ------------------------"

TMP_VOLUME="$(
    kubectl get pod "$POD" -o json |
    python3 -c '
import json, sys

d = json.load(sys.stdin)

emptydirs = set()

for volume in d.get("spec", {}).get("volumes", []):
    if "emptyDir" in volume:
        emptydirs.add(volume["name"])

found = False

for container in d.get("spec", {}).get("containers", []):
    if container.get("name") != "app":
        continue

    for mount in container.get("volumeMounts", []):
        if (
            mount.get("mountPath") == "/tmp"
            and mount.get("name") in emptydirs
        ):
            found = True

print("yes" if found else "no")
'
)"

if [[ "$TMP_VOLUME" == "yes" ]]; then
    pass "/tmp is backed by an emptyDir volume"
else
    fail "/tmp emptyDir volume is missing or incorrectly mounted"
fi


# ============================================================
# PART 5 : Runtime
# ============================================================

echo
echo "---- PART 5 : RUNTIME ---------------------------"

READY="$(
    kubectl get pod "$POD" \
        -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null
)"

if [[ "$READY" == "True" ]]; then
    pass "Pod is Running and Ready"
else
    fail "Pod is not Ready"
fi


UID_VALUE="$(
    kubectl exec "$POD" -- id -u 2>/dev/null || true
)"

if [[ -n "$UID_VALUE" && "$UID_VALUE" != "0" ]]; then
    pass "Container is actually running as non-root"
else
    fail "Container is running as root or could not be checked"
fi


if kubectl exec "$POD" -- \
    sh -c 'echo cks-test > /tmp/cks-write-test && rm /tmp/cks-write-test' \
    >/dev/null 2>&1; then

    pass "Container can write to /tmp"

else

    fail "Container cannot write to /tmp"

fi


if kubectl exec "$POD" -- \
    test -s /var/run/secrets/kubernetes.io/serviceaccount/token \
    >/dev/null 2>&1; then

    pass "Projected ServiceAccount token exists at the required path"

else

    fail "Projected ServiceAccount token is missing"

fi


# Try writing to a normal root filesystem location.
if kubectl exec "$POD" -- \
    sh -c 'touch /cks-root-write-test' \
    >/dev/null 2>&1; then

    kubectl exec "$POD" -- \
        rm -f /cks-root-write-test >/dev/null 2>&1 || true

    fail "Root filesystem is writable"

else

    pass "Root filesystem rejects writes"

fi


# ============================================================
# RESULT
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
