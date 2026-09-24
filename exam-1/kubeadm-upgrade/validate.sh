#!/usr/bin/env bash
set -u

WORKER="node01"
LAB_DIR="/root/cks-lab-q4"
STATE_FILE="${LAB_DIR}/state.env"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

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
echo " CKS LAB 05 - VALIDATION"
echo "================================================="

if [[ ! -f "$STATE_FILE" ]]; then
    echo "[ERROR] Lab state file missing."
    exit 1
fi

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


echo
echo "---- PART 1 : PACKAGE UPGRADE -------------------"

CURRENT_KUBEADM="$(
    ssh ${SSH_OPTS} "$WORKER" \
      "dpkg-query -W -f='\${Version}' kubeadm" \
      2>/dev/null
)"

CURRENT_KUBELET="$(
    ssh ${SSH_OPTS} "$WORKER" \
      "dpkg-query -W -f='\${Version}' kubelet" \
      2>/dev/null
)"

CURRENT_KUBECTL="$(
    ssh ${SSH_OPTS} "$WORKER" \
      "dpkg-query -W -f='\${Version}' kubectl" \
      2>/dev/null
)"


if dpkg --compare-versions \
    "$CURRENT_KUBEADM" gt "$BASE_KUBEADM"; then

    pass "kubeadm was upgraded"

else

    fail "kubeadm was not upgraded"

fi


if dpkg --compare-versions \
    "$CURRENT_KUBELET" gt "$BASE_KUBELET"; then

    pass "kubelet was upgraded"

else

    fail "kubelet was not upgraded"

fi


if dpkg --compare-versions \
    "$CURRENT_KUBECTL" gt "$BASE_KUBECTL"; then

    pass "kubectl was upgraded"

else

    fail "kubectl was not upgraded"

fi


if [[ "$CURRENT_KUBEADM" == "$TARGET_VERSION" ]]; then
    pass "kubeadm reached the expected target version"
else
    fail "kubeadm target version is incorrect"
fi


if [[ "$CURRENT_KUBELET" == "$TARGET_VERSION" ]]; then
    pass "kubelet reached the expected target version"
else
    fail "kubelet target version is incorrect"
fi


if [[ "$CURRENT_KUBECTL" == "$TARGET_VERSION" ]]; then
    pass "kubectl reached the expected target version"
else
    fail "kubectl target version is incorrect"
fi


echo
echo "---- PART 2 : NODE HEALTH -----------------------"

if ssh ${SSH_OPTS} "$WORKER" \
    "systemctl is-active --quiet kubelet"; then

    pass "kubelet service is running"

else

    fail "kubelet service is not running"

fi


READY="$(
    kubectl get node "$WORKER" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' \
      2>/dev/null
)"

if [[ "$READY" == "True" ]]; then
    pass "Worker node is Ready"
else
    fail "Worker node is not Ready"
fi


echo
echo "---- PART 3 : SCHEDULING ------------------------"

UNSCHEDULABLE="$(
    kubectl get node "$WORKER" \
      -o jsonpath='{.spec.unschedulable}' \
      2>/dev/null
)"

if [[ "$UNSCHEDULABLE" != "true" ]]; then
    pass "Worker node is uncordoned"
else
    fail "Worker node is still cordoned"
fi


NODE_VERSION="$(
    kubectl get node "$WORKER" \
      -o jsonpath='{.status.nodeInfo.kubeletVersion}' \
      2>/dev/null |
    sed 's/^v//'
)"

PKG_VERSION_NO_RELEASE="$(
    echo "$CURRENT_KUBELET" |
    sed 's/-.*//'
)"

if [[ "$NODE_VERSION" == "$PKG_VERSION_NO_RELEASE" ]]; then

    pass "Kubernetes reports the upgraded kubelet version"

else

    fail "Node status does not report the expected kubelet version"

fi


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
