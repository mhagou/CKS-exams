#!/usr/bin/env bash
set -u

WORKER="node01"
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

NS="falco-lab"
POD="toolbox"

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
echo " CKS LAB 04 - VALIDATION"
echo "================================================="


# ============================================================
# PART 1
# ============================================================

echo
echo "---- PART 1 : FALCO RULE ------------------------"


if ssh ${SSH_OPTS} "$WORKER" \
    "test -s /etc/falco/falco_rules.local.yaml"; then

    pass "Custom Falco rules file exists"

else

    fail "Custom Falco rules file is missing"

fi


RULE_TEST="$(
    ssh ${SSH_OPTS} "$WORKER" \
        "falco -V /etc/falco/falco_rules.local.yaml 2>&1" \
        || true
)"


if echo "$RULE_TEST" |
   grep -Eqi \
   'valid|successfully validated|validated successfully'; then

    pass "Falco accepts the custom rules"

else

    # Some Falco versions return success without a common
    # validation message. Check exit code separately.

    if ssh ${SSH_OPTS} "$WORKER" \
        "falco -V /etc/falco/falco_rules.local.yaml >/dev/null 2>&1"; then

        pass "Falco accepts the custom rules"

    else

        fail "Falco rejects the custom rules"

    fi

fi


if ssh ${SSH_OPTS} "$WORKER" \
    "grep -Eiq 'priority:[[:space:]]*WARNING' \
     /etc/falco/falco_rules.local.yaml"; then

    pass "Rule uses WARNING priority"

else

    fail "WARNING priority not found"

fi


if ssh ${SSH_OPTS} "$WORKER" \
    "grep -q '/etc/shadow' \
     /etc/falco/falco_rules.local.yaml"; then

    pass "Rule targets /etc/shadow"

else

    fail "Rule does not target /etc/shadow"

fi


# ============================================================
# PART 2
# ============================================================

echo
echo "---- PART 2 : FALCO SERVICE ---------------------"


if ssh ${SSH_OPTS} "$WORKER" \
    "systemctl is-active --quiet falco"; then

    pass "Falco service is running"

else

    fail "Falco service is not running"

fi


# ============================================================
# PART 3
# ============================================================

echo
echo "---- PART 3 : RUNTIME DETECTION -----------------"


if kubectl -n "$NS" \
    get pod "$POD" >/dev/null 2>&1; then

    pass "Test workload is available"

else

    fail "Test workload is unavailable"

fi


# Establish a journal timestamp immediately before the test.

MARKER="$(
    ssh ${SSH_OPTS} "$WORKER" \
        "date --iso-8601=seconds"
)"


sleep 1


if kubectl -n "$NS" \
    exec "$POD" -- \
    cat /etc/shadow >/dev/null 2>&1; then

    pass "Test read of /etc/shadow completed"

else

    fail "Unable to perform test read of /etc/shadow"

fi


sleep 4


FOUND=0


# systemd journal

if ssh ${SSH_OPTS} "$WORKER" \
    "journalctl -u falco \
        --since '$MARKER' \
        --no-pager 2>/dev/null |
     grep -F '/etc/shadow' |
     grep -Ei 'Warning|WARNING' >/dev/null"; then

    FOUND=1
fi


# Traditional Falco logfile

if [[ "$FOUND" -eq 0 ]]; then

    if ssh ${SSH_OPTS} "$WORKER" \
        "test -f /var/log/falco.log &&
         tail -n 200 /var/log/falco.log |
         grep -F '/etc/shadow' |
         grep -Ei 'Warning|WARNING' >/dev/null"; then

        FOUND=1
    fi

fi


# syslog

if [[ "$FOUND" -eq 0 ]]; then

    if ssh ${SSH_OPTS} "$WORKER" \
        "test -f /var/log/syslog &&
         tail -n 500 /var/log/syslog |
         grep -F '/etc/shadow' |
         grep -Ei 'Warning|WARNING' >/dev/null"; then

        FOUND=1
    fi

fi


if [[ "$FOUND" -eq 1 ]]; then

    pass "Falco generated a WARNING for /etc/shadow access"

else

    fail "No Falco WARNING detected for /etc/shadow access"

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
