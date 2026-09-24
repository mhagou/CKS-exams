#!/usr/bin/env bash
set -Eeuo pipefail

# Run on controlplane as root. Supports host Falco and Kubernetes deployments.
# Optional: FALCO_NODE=controlplane|node01 selects the node to test.
# FALCO_LOG_FILE=/absolute/path reads a host file output instead of/in addition
# to journald. For external-only output, expose fresh alerts in that local/remote
# host file first. The validator never changes Falco's output configuration.
# ALERT_WAIT_SECONDS can be increased for buffered output (default: 30).
PASS=0 FAIL=0
TMP=$(mktemp -d)
NS="cks-falco-check-$(date +%s)-$$"
CREATED=false
ok() { printf '[PASS] %s\n' "$*"; PASS=$((PASS + 1)); }
bad() { printf '[FAIL] %s\n' "$*"; FAIL=$((FAIL + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$PASS" "$FAIL"
    if (( FAIL == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
cleanup() {
    if [[ $CREATED == true ]]; then
        kubectl delete namespace "$NS" --ignore-not-found --wait=false >/dev/null 2>&1 ||
            echo "Warning: could not clean up temporary namespace $NS" >&2
    fi
    rm -rf "$TMP"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
for cmd in kubectl script timeout; do
    if ! command -v "$cmd" >/dev/null; then bad "Required validation command is available: $cmd"; finish; fi
done
[[ $EUID -eq 0 ]] || { bad 'Run validation as root on controlplane'; finish; }
WAIT=${ALERT_WAIT_SECONDS:-30}
[[ $WAIT =~ ^[1-9][0-9]*$ ]] || { bad 'ALERT_WAIT_SECONDS must be a positive integer'; finish; }
# Enumerate by executable image, not deployment, namespace, or container names.
if ! kubectl get pods -A -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{.status.phase}{"|"}{range .spec.containers[*]}{.name}{"="}{.image}{","}{end}{"\n"}{end}' > "$TMP/pods"; then
    bad 'Kubernetes API is accessible'; finish
fi
: > "$TMP/monitors"
while IFS='|' read -r ns pod node phase containers; do
    [[ $phase == Running ]] || continue
    IFS=',' read -ra entries <<< "$containers"
    for entry in "${entries[@]}"; do
        image=${entry#*=}
        if [[ $image =~ (^|/)falco([:@]|$) ]]; then
            printf '%s|%s|%s|%s\n' "$node" "$ns" "$pod" "${entry%%=*}" >> "$TMP/monitors"
        fi
    done
done < "$TMP/pods"
host() {
    if [[ $NODE == controlplane ]]; then bash -s -- "$@";
    else ssh -o BatchMode=yes -o ConnectTimeout=5 node01 bash -s -- "$@"; fi
}
NODE=${FALCO_NODE:-}
if [[ -z $NODE ]]; then
    if pgrep -x falco >/dev/null; then NODE=controlplane
    else NODE=$(cut -d '|' -f 1 "$TMP/monitors" | head -n 1); fi
    if [[ -z $NODE ]]; then
        # Discover a host installation on the worker without changing it.
        if command -v ssh >/dev/null && ssh -o BatchMode=yes -o ConnectTimeout=5 node01 'pgrep -x falco >/dev/null' 2>/dev/null; then
            NODE=node01
        else
            NODE=controlplane
        fi
    fi
fi
[[ $NODE == controlplane || $NODE == node01 ]] || { bad 'FALCO_NODE must be controlplane or node01'; finish; }
HOST=false
if host <<'SH'
pgrep -x falco >/dev/null
SH
then HOST=true; fi
if [[ $HOST == true ]] || grep -q "^$NODE|" "$TMP/monitors"; then
    ok "Falco is running on $NODE"
else
    bad "Falco is running on $NODE (set FALCO_NODE=node01 for a worker-only host installation)"; finish
fi
if ! kubectl create namespace "$NS" >/dev/null; then bad 'Create temporary test namespace'; finish; fi
CREATED=true
if ! kubectl -n "$NS" run shell-check --image="${LAB_IMAGE:-busybox:1.37}" --restart=Never \
    --overrides="{\"spec\":{\"nodeName\":\"$NODE\",\"tolerations\":[{\"operator\":\"Exists\"}],\"terminationGracePeriodSeconds\":0}}" \
    --command -- sleep 2147483647 >/dev/null ||
   ! kubectl -n "$NS" wait --for=condition=Ready pod/shell-check --timeout=180s >/dev/null; then
    bad 'Temporary shell test pod becomes ready'; finish
fi
# Allow Falco's container metadata discovery before the test event.
sleep 5
LOG=${FALCO_LOG_FILE:-}
# Restrict paths to safe characters because ssh serializes remote arguments.
[[ -z $LOG || $LOG =~ ^/[a-zA-Z0-9_./-]+$ ]] || { bad 'FALCO_LOG_FILE must be an absolute path without special characters'; finish; }
OFFSET=0
if [[ -n $LOG ]]; then
    if ! OFFSET=$(host "$LOG" <<'SH'
[[ -f $1 && -r $1 ]] && stat -c %s -- "$1"
SH
); then bad 'Configured Falco output file is readable'; finish; fi
fi
# A fresh time window prevents accepting alerts from an earlier exercise run.
SINCE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1
# script supplies a local PTY even when validation itself has no terminal.
if ! timeout 20 script -q -e -c "kubectl -n $NS exec -it shell-check -- /bin/sh -c 'sleep 2'" /dev/null > "$TMP/exec" 2>&1; then
    bad 'Exec a shell into the test pod with an attached terminal'; cat "$TMP/exec"; finish
fi
ok 'Exec a shell into the test pod with an attached terminal'
collect() {
    : > "$TMP/alerts"
    if [[ $HOST == true ]]; then
        host "$SINCE" <<'SH' >> "$TMP/alerts" 2>/dev/null || true
journalctl --since "$1" --no-pager -o cat _COMM=falco + SYSLOG_IDENTIFIER=falco
SH
    fi
    if [[ -n $LOG ]]; then
        host "$LOG" "$OFFSET" <<'SH' >> "$TMP/alerts" 2>/dev/null || true
size=$(stat -c %s -- "$1")
start=$(( $2 + 1 ))
# Account for truncation/rotation since the snapshot.
(( size >= $2 )) || start=1
tail -c +"$start" -- "$1"
SH
    fi
    while IFS='|' read -r node ns pod container; do
        [[ $node == "$NODE" ]] || continue
        kubectl -n "$ns" logs "$pod" -c "$container" --since-time="$SINCE" >> "$TMP/alerts" 2>/dev/null || true
    done < "$TMP/monitors"
}
FOUND=false
for ((i=0; i<WAIT; i++)); do
    collect
    if grep -Fq 'CRITICAL: SHELL OPENED' "$TMP/alerts"; then FOUND=true; break; fi
    sleep 1
done
if [[ $FOUND == true ]]; then
    ok 'Falco emits CRITICAL: SHELL OPENED for the shell exec test'
else
    bad 'No fresh CRITICAL: SHELL OPENED alert observed for the shell exec test'
    echo 'Checked Falco journald/container logs and any FALCO_LOG_FILE supplied.'
    echo 'For file-only output set FALCO_LOG_FILE; for buffered output increase ALERT_WAIT_SECONDS.'
fi
finish
