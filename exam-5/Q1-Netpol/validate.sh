#!/usr/bin/env bash
set -Eeuo pipefail

# Validate the traffic contract inferred from solution.txt, not its policy name,
# selector syntax, or number of policies. This script never changes resources.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Unexpected validation error at line $LINENO"; finish' ERR
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; }
NS=network-security
PEER=network-security-peer
declare -A addresses

if policies=$(kubectl get networkpolicy -n "$NS" -o name) && [[ -n $policies ]]; then
    pass 'NetworkPolicy resources exist in network-security'
else
    fail 'NetworkPolicy resources exist in network-security'
fi

# Fixture health is checked first so an absent listener or broken exec cannot
# masquerade as a denied connection. Readiness probes use exec and survive policy.
for entry in "$NS/backend-a/backend" "$NS/backend-b/backend" "$NS/frontend/frontend" \
             "$NS/database/database" "$NS/other/other" "$PEER/frontend/frontend" "$PEER/database/database"; do
    IFS=/ read -r ns pod role <<< "$entry"
    if ! info=$(kubectl get pod -n "$ns" "$pod" -o jsonpath='{.metadata.labels.app}{" "}{.status.podIP}{" "}{.status.conditions[?(@.type=="Ready")].status}'); then
        fail "Fixture $ns/$pod exists"; continue
    fi
    read -r actual_role ip ready <<< "$info"
    if [[ $actual_role != "$role" || -z $ip || $ready != True ]]; then
        fail "Fixture $ns/$pod retains its role, IP and readiness"; continue
    fi
    [[ $ip == *:* ]] && ip="[$ip]"
    addresses["$ns/$pod"]=$ip
    if kubectl exec -n "$ns" "$pod" -- sh -ec '
        for port in 8080 8081 5432 5433; do
            wget -q -T 2 -O /dev/null "http://127.0.0.1:$port/" || exit 1
        done'; then
        pass "Fixture $ns/$pod has healthy test listeners"
    else
        fail "Fixture $ns/$pod has healthy test listeners"
    fi
done
((failed == 0)) || finish

probe() {
    local src_ns=$1 src=$2 dst_ns=$3 dst=$4 port=$5 expected=$6
    local result attempt description="$src_ns/$src -> $dst_ns/$dst TCP/$port ($expected)"
    # Repeat denied tests to catch intermittent allowances, and retry allowed
    # tests to tolerate brief packet loss. All connections use literal Pod IPs.
    for attempt in 1 2 3; do
        if ! result=$(kubectl exec -n "$src_ns" "$src" -- sh -c '
            if wget -q -T 2 -O /dev/null "$1"; then echo CONNECTED; else echo BLOCKED; fi
        ' sh "http://${addresses["$dst_ns/$dst"]}:$port/" 2>/dev/null); then
            fail "$description: could not execute probe"; return
        fi
        case "$result" in
            CONNECTED)
                if [[ $expected == allowed ]]; then pass "$description"; return; fi
                fail "$description"; return ;;
            BLOCKED) ;;
            *) fail "$description: invalid probe result"; return ;;
        esac
    done
    if [[ $expected == denied ]]; then pass "$description"; else fail "$description"; fi
}

# Test both backend pods so a policy covering just one does not pass.
for backend in backend-a backend-b; do
    probe "$NS" frontend "$NS" "$backend" 8080 allowed
    probe "$NS" frontend "$NS" "$backend" 8081 denied
    probe "$NS" frontend "$NS" "$backend" 5432 denied
    for source in database other; do
        probe "$NS" "$source" "$NS" "$backend" 8080 denied
    done
    probe "$PEER" frontend "$NS" "$backend" 8080 denied
    probe "$NS" "$backend" "$NS" database 5432 allowed
    probe "$NS" "$backend" "$NS" database 5433 denied
    probe "$NS" "$backend" "$NS" database 8080 denied
    for destination in frontend other; do
        probe "$NS" "$backend" "$NS" "$destination" 5432 denied
        probe "$NS" "$backend" "$NS" "$destination" 8080 denied
    done
    probe "$NS" "$backend" "$PEER" database 5432 denied
done
finish
