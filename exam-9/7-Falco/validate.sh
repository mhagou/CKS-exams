#!/usr/bin/env bash
set -Eeuo pipefail
# Live validation is necessary: the requested report contains neither container
# identity nor detector lifetime. Run this script in a second terminal, then
# start the candidate's own capture after the READY message. Allow >=30 seconds
# of capture for the 20-second observation plus startup/flush overhead.
# This script never starts/reconfigures Falco or writes the incident report.
pass=0 fail=0
ok() { echo "[PASS] $*"; pass=$((pass + 1)); }
bad() { echo "[FAIL] $*"; fail=$((fail + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$pass" "$fail"
    if (( fail == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( fail == 0 ))
}
report=/opt/falco-incident.txt
if [[ $EUID -ne 0 ]] || ! command -v kubectl >/dev/null || ! command -v pgrep >/dev/null; then
    bad 'Run as root on controlplane with kubectl and pgrep available.'
    finish; exit 1
fi
if ! kubectl -n default wait --for=condition=Ready pod/nginx --timeout=10s >/dev/null 2>&1; then
    bad 'The exercise Nginx Pod is ready.'; finish; exit 1
fi
# Random executable names fit Linux comm's 15-character limit. Copying busybox
# and invoking its sleep applet creates harmless, identifiable exec events.
token=$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')
positive="fp${token}" negative="fn${token}"
decoy="falco-check-${token}"
created=false
cleanup() {
    kubectl -n default exec nginx -c nginx -- rm -f "/tmp/$positive" >/dev/null 2>&1 || true
    if $created; then kubectl -n default delete pod "$decoy" --ignore-not-found --wait=false >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM
image=$(kubectl -n default get pod nginx -o jsonpath='{.spec.containers[?(@.name=="nginx")].image}')
if ! kubectl -n default run "$decoy" --image="$image" --restart=Never \
    --overrides='{"spec":{"nodeName":"controlplane","tolerations":[{"operator":"Exists","effect":"NoSchedule"}]}}' \
    --command -- sleep 180 >/dev/null; then
    bad 'Create temporary comparison container.'; finish; exit 1
fi
created=true
if ! kubectl -n default wait --for=condition=Ready "pod/$decoy" --timeout=120s >/dev/null; then
    bad 'Temporary comparison container is ready.'; finish; exit 1
fi
if ! kubectl -n default exec nginx -c nginx -- cp /bin/busybox "/tmp/$positive" ||
   ! kubectl -n default exec "$decoy" -- cp /bin/busybox "/tmp/$negative"; then
    bad 'Prepare harmless runtime probes.'; finish; exit 1
fi
uid=$(kubectl -n default exec nginx -c nginx -- id -u)
# Busybox dispatches by argv[0]; use a shell exec -a to keep the executable's
# kernel process name unique while selecting the sleep applet.
probe() {
    kubectl -n default exec "$1" -- sh -c 'exec -a sleep "$1" 0' sh "/tmp/$2" >/dev/null 2>&1
}
count_positive() {
    if [[ -r $report ]]; then
        awk -v name="$positive" -v uid="$uid" -F, '$2=="["uid"]" && $3=="["name"]" {n++} END {print n+0}' "$report"
    else echo 0; fi
}
echo 'READY: start your Falco capture in another terminal, writing a fresh /opt/falco-incident.txt.'
echo 'Keep capture active for at least 30 seconds after its first probe alert; waiting up to 90 seconds.'
seen=false
for ((i=0; i<90; i++)); do
    if ! probe nginx "$positive" || ! probe "$decoy" "$negative"; then break; fi
    if (( $(count_positive) > 0 )); then seen=true; break; fi
    sleep 1
done
if ! $seen; then
    bad 'Live Nginx execution appears in the report with its runtime UID (capture must be active and flushed).'
    finish; exit 1
fi
ok 'Live Nginx process execution appears with its runtime UID.'
initial=$(count_positive)
start=$SECONDS
falco_alive=true
while (( SECONDS - start < 20 )); do
    pgrep -x falco >/dev/null || falco_alive=false
    probe "$decoy" "$negative" || { bad 'Comparison probe execution failed.'; break; }
    sleep 1
done
probe nginx "$positive" || bad 'Final Nginx probe execution failed.'
# Permit buffered output to be flushed when the candidate capture finishes.
for ((i=0; i<30; i++)); do
    (( $(count_positive) > initial )) && break
    sleep 1
done
if $falco_alive && (( SECONDS - start >= 20 )) && (( $(count_positive) > initial )); then
    ok 'Falco was running throughout a runtime observation of at least 20 seconds, with Nginx alerts at both ends.'
else
    bad 'At least 20 seconds of live Falco observation; repeat capture alongside this validator if it already ended.'
fi
if [[ -s $report ]] && awk -F, '
    !/^\[[^][]+\],\[[0-9]+\],\[[^][]+\]$/ {bad=1}
    {
        stamp=$1
        gsub(/^\[|\]$/, "", stamp)
        # Accept Falco clock/ISO timestamps and numeric epoch timestamps.
        if (stamp !~ /[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/ &&
            stamp !~ /^[0-9]+([.][0-9]+)?$/) bad=1
    }
    END {exit (NR==0 || bad)}' "$report"; then
    ok 'Incident file contains one [timestamp],[uid],[processName] record per line.'
else
    bad 'Incident file must contain only nonempty three-field incident records.'
fi
if [[ -r $report ]] && ! awk -F, -v name="$negative" '$3=="["name"]" {found=1} END {exit !found}' "$report"; then
    ok 'Executions from the comparison container were excluded.'
else
    bad 'Executions from another container leaked into the incident report.'
fi
finish
