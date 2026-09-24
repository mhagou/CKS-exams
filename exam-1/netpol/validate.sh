#!/usr/bin/env bash
set -u

NS="prod-x12cs"
POLICY="allow-redis-access"

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
echo " CKS NetworkPolicy - VALIDATION"
echo "================================================="


# ============================================================
# PART 1 : NetworkPolicy existence
# ============================================================

echo
echo "---- PART 1 : NETWORK POLICY --------------------"

if kubectl -n "$NS" \
    get networkpolicy "$POLICY" >/dev/null 2>&1; then

    pass "NetworkPolicy allow-redis-access exists"

else

    fail "NetworkPolicy allow-redis-access does not exist"

    echo
    echo "PASS : $PASS"
    echo "FAIL : $FAIL"
    exit 1
fi


# ============================================================
# Target pod selector
# ============================================================

SELECTOR_APP="$(
    kubectl -n "$NS" \
        get networkpolicy "$POLICY" \
        -o jsonpath='{.spec.podSelector.matchLabels.app}' \
        2>/dev/null
)"

if [[ "$SELECTOR_APP" == "redis-backend" ]]; then
    pass "Policy targets redis-backend using an existing label"
else
    fail "Policy does not correctly select redis-backend"
fi


# ============================================================
# Policy type
# ============================================================

POLICY_JSON="$(
    kubectl -n "$NS" \
        get networkpolicy "$POLICY" \
        -o json
)"

if echo "$POLICY_JSON" |
    grep -q '"Ingress"'; then

    pass "Ingress policy is enabled"

else

    fail "Ingress policy type is missing"

fi


# ============================================================
# Port
# ============================================================

PORT_FOUND="$(
    kubectl -n "$NS" \
        get networkpolicy "$POLICY" \
        -o jsonpath='{range .spec.ingress[*].ports[*]}{.protocol}:{.port}{"\n"}{end}' \
        2>/dev/null
)"

if echo "$PORT_FOUND" |
    grep -q '^TCP:6379$'; then

    pass "TCP port 6379 is allowed"

else

    fail "TCP port 6379 is not correctly configured"

fi


# ============================================================
# Same namespace selector
# ============================================================

SAME_NS_ALLOWED="$(
    kubectl -n "$NS" \
        get networkpolicy "$POLICY" \
        -o json |
    python3 -c '
import json
import sys

d = json.load(sys.stdin)
ok = False

for rule in d.get("spec", {}).get("ingress", []):
    for peer in rule.get("from", []):
        labels = peer.get("podSelector", {}).get("matchLabels", {})

        if labels.get("backend") == "prod-x12cs":
            ok = True

print("yes" if ok else "no")
'
)"

if [[ "$SAME_NS_ALLOWED" == "yes" ]]; then
    pass "Same-namespace pods with backend=prod-x12cs are allowed"
else
    fail "Required same-namespace podSelector is missing"
fi

# ============================================================
# prod-yx13cs namespace
# ============================================================

NS_ALLOWED="$(
    kubectl -n "$NS" \
        get networkpolicy "$POLICY" \
        -o json |
    python3 -c '
import json,sys

d=json.load(sys.stdin)

ok=False

for rule in d.get("spec",{}).get("ingress",[]):
    for src in rule.get("from",[]):

        n=src.get("namespaceSelector",{})
        labels=n.get("matchLabels",{})

        if labels.get("kubernetes.io/metadata.name") == "prod-yx13cs":
            ok=True

print("yes" if ok else "no")
'
)"

if [[ "$NS_ALLOWED" == "yes" ]]; then

    pass "prod-yx13cs namespace is allowed using existing namespace labels"

else

    fail "prod-yx13cs namespaceSelector is missing or incorrect"

fi


# ============================================================
# PART 2 : Runtime tests
# ============================================================

echo
echo "---- PART 2 : RUNTIME CONNECTIVITY --------------"

sleep 2


# ------------------------------------------------------------
# Same namespace + correct label -> ALLOW
# ------------------------------------------------------------

if timeout 8 \
    kubectl -n prod-x12cs \
    exec client-allowed -- \
    redis-cli \
        -h redis-backend \
        -p 6379 \
        ping 2>/dev/null |
    grep -q '^PONG$'; then

    pass "backend=prod-x12cs can access Redis"

else

    fail "backend=prod-x12cs cannot access Redis"

fi


# ------------------------------------------------------------
# Same namespace + wrong label -> DENY
# ------------------------------------------------------------

if timeout 5 \
    kubectl -n prod-x12cs \
    exec client-denied -- \
    redis-cli \
        -h redis-backend \
        -p 6379 \
        ping >/dev/null 2>&1; then

    fail "Unapproved pod in prod-x12cs can access Redis"

else

    pass "Other pods in prod-x12cs are blocked"

fi


# ------------------------------------------------------------
# prod-yx13cs -> ALLOW
# ------------------------------------------------------------

if timeout 8 \
    kubectl -n prod-yx13cs \
    exec client-allowed -- \
    redis-cli \
        -h redis-backend.prod-x12cs.svc.cluster.local \
        -p 6379 \
        ping 2>/dev/null |
    grep -q '^PONG$'; then

    pass "Pods from prod-yx13cs can access Redis"

else

    fail "Pods from prod-yx13cs cannot access Redis"

fi


# ------------------------------------------------------------
# Other namespace -> DENY
# ------------------------------------------------------------

if timeout 5 \
    kubectl -n prod-z99cs \
    exec client-denied -- \
    redis-cli \
        -h redis-backend.prod-x12cs.svc.cluster.local \
        -p 6379 \
        ping >/dev/null 2>&1; then

    fail "Unauthorized namespace can access Redis"

else

    pass "Unauthorized namespaces are blocked"

fi


# ============================================================
# PART 3 : Redis health
# ============================================================

echo
echo "---- PART 3 : REDIS HEALTH ----------------------"

if kubectl -n prod-x12cs \
    exec redis-backend -- \
    redis-cli -p 6379 ping 2>/dev/null |
    grep -q '^PONG$'; then

    pass "Redis is still healthy"

else

    fail "Redis is not responding"

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