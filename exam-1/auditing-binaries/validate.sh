#!/usr/bin/env bash

set -u

LAB_DIR="/root/cks-lab-q1"

KUBELET_CONFIG="/var/lib/kubelet/config.yaml"
APISERVER_MANIFEST="/etc/kubernetes/manifests/kube-apiserver.yaml"

WORKER="node01"

SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

PASS=0
FAIL=0
INFO=0


pass() {

    echo "[PASS] $1"
    PASS=$((PASS + 1))

}


fail() {

    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))

}


info() {

    echo "[INFO] $1"
    INFO=$((INFO + 1))

}


echo
echo "================================================="
echo " CKS LAB 01 - VALIDATION"
echo "================================================="


# ============================================================
# PART 1 - Kube-bench / Kubelet
# ============================================================

echo
echo "---- PART 1 : KUBELET HARDENING -----------------"


if systemctl is-active --quiet kubelet; then

    pass "kubelet service is running"

else

    fail "kubelet service is not running"

fi


ANONYMOUS="$(
python3 - "$KUBELET_CONFIG" <<'PY'
import sys

path = sys.argv[1]

with open(path) as f:
    lines = f.readlines()

auth_indent = None
anonymous_indent = None

for line in lines:

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
            print(stripped.split(":", 1)[1].strip())
            raise SystemExit

print("NOT_FOUND")
PY
)"


if [[ "$ANONYMOUS" == "false" ]]; then

    pass "Kubelet anonymous authentication is disabled"

else

    fail "Kubelet anonymous authentication is NOT disabled"

fi


if command -v kube-bench >/dev/null 2>&1; then

    BENCH_OUTPUT="$(
        kube-bench run \
            --targets node \
            2>/dev/null || true
    )"

    if echo "$BENCH_OUTPUT" |
       grep -E '\[PASS\].*4\.2\.1' >/dev/null; then

        pass "kube-bench check 4.2.1 passes"

    else

        fail "kube-bench check 4.2.1 does not pass"

        echo
        echo "Relevant kube-bench output:"

        echo "$BENCH_OUTPUT" |
            grep -E '4\.2\.1|anonymous-auth' |
            head -10 || true

    fi

else

    fail "kube-bench is not installed"

fi



# ============================================================
# PART 2 - Integrity check
# ============================================================

echo
echo "---- PART 2 : BINARY / MANIFEST INTEGRITY -------"


HASH_FILE="${LAB_DIR}/kube-apiserver-known-good.sha512"


if [[ -f "$HASH_FILE" ]]; then

    pass "Known-good SHA512 exists"

else

    fail "Known-good SHA512 file is missing"

fi


if [[ -f "$HASH_FILE" ]]; then

    GOOD_HASH="$(tr -d '[:space:]' < "$HASH_FILE")"

    CURRENT_HASH="$(
        sha512sum "$APISERVER_MANIFEST" |
        awk '{print $1}'
    )"

    echo
    echo "Known good:"
    echo "  $GOOD_HASH"

    echo
    echo "Current:"
    echo "  $CURRENT_HASH"

    echo

    if [[ "$GOOD_HASH" != "$CURRENT_HASH" ]]; then

        pass "Manifest modification is detectable via SHA512"

    else

        info "Manifest currently matches known-good SHA512"

    fi

fi



# ============================================================
# PART 3 - Suspicious process/container
# ============================================================

echo
echo "---- PART 3 : MALICIOUS PROCESS -----------------"


if ! ssh ${SSH_OPTS} "$WORKER" true >/dev/null 2>&1; then

    fail "Cannot reach node01"
    
else

    PROCESS_EXISTS="$(
        ssh ${SSH_OPTS} "$WORKER" \
        "ps -eo comm,args | grep -c '[c]ryptominer'" \
        2>/dev/null || true
    )"

    if [[ "$PROCESS_EXISTS" == "0" ]]; then

        pass "Suspicious cryptominer process is gone"

    else

        fail "Suspicious cryptominer process is still running"

    fi


    CONTAINER_EXISTS="$(
        ssh ${SSH_OPTS} "$WORKER" \
        "ctr -n k8s.io containers list -q 2>/dev/null |
         grep -c '^cks-system-monitor$'" \
        2>/dev/null || true
    )"

    if [[ "$CONTAINER_EXISTS" == "0" ]]; then

        pass "Suspicious container has been removed"

    else

        fail "Suspicious container still exists"

    fi

fi



# ============================================================
# Final score
# ============================================================

TOTAL=$((PASS + FAIL))

echo
echo "================================================="
echo " RESULT"
echo "================================================="

echo
echo "PASS : $PASS"
echo "FAIL : $FAIL"

if [[ $INFO -gt 0 ]]; then
    echo "INFO : $INFO"
fi

echo

if [[ $FAIL -eq 0 ]]; then

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