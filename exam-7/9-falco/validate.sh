#!/usr/bin/env bash
set -Eeuo pipefail

# Runtime test of the local rules file used by task.txt. No service/config edits.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
if [[ $EUID -ne 0 ]]; then fail 'Run validation as root on controlplane'; finish; fi
for cmd in kubectl falco jq timeout; do
    if ! command -v "$cmd" >/dev/null; then fail "Required command available: $cmd"; finish; fi
done
rules=/etc/falco/falco_rules.local.yaml
if [[ ! -s "$rules" ]]; then fail "Local rules exist: $rules"; finish; fi
work=$(mktemp -d)
falco_pid=''
cleanup() {
    if [[ -n "$falco_pid" ]]; then
        kill "$falco_pid" 2>/dev/null || true
        wait "$falco_pid" 2>/dev/null || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if timeout 30 falco -V "$rules" >"$work/check.log" 2>&1; then
    pass 'Local Falco rules compile successfully'
else
    fail 'Local Falco rules compile successfully'
    cat "$work/check.log" >&2
    finish
fi
# Reuse the harmless setup pod; no temporary cluster objects are needed.
if ! kubectl get pod test-falco -n default -o json >"$work/pod.json" ||
   ! jq -e '.spec.nodeName == "controlplane" and
       any(.status.conditions[]?; .type == "Ready" and .status == "True")' "$work/pod.json" >/dev/null; then
    fail 'Test pod is Ready on controlplane (run setup first)'; finish
fi
container=$(jq -r '.spec.containers[0].name' "$work/pod.json")
id=$(jq -r --arg name "$container" '.status.containerStatuses[] | select(.name == $name) | .containerID' "$work/pod.json")
id=${id#*://}
if [[ -z "$id" || "$id" == null ]] ||
   ! kubectl exec -n default test-falco -c "$container" -- sh -c 'command -v cat >/dev/null && test ! -e /dev/mem'; then
    fail 'Safe test container with no physical memory device is available'; finish
fi

# Only this foreground process gets output overrides. Candidate rules and the
# installed capture engine are unchanged; other running Falco instances stay up.
timeout --signal=TERM --kill-after=5 65 falco -M 30 -r "$rules" -U \
    -o json_output=true -o stdout_output.enabled=true \
    -o file_output.enabled=false -o syslog_output.enabled=false \
    -o program_output.enabled=false -o http_output.enabled=false \
    >"$work/alerts" 2>"$work/falco.log" &
falco_pid=$!
# Repeated attempts tolerate engine/plugin startup without a version-specific
# readiness-log match. The shell verifies absence immediately before each read.
triggered=0
for ((attempt=0; attempt<25; attempt++)); do
    kill -0 "$falco_pid" 2>/dev/null || break
    if timeout 8 kubectl --request-timeout=5s exec -n default test-falco -c "$container" -- \
        sh -c 'test ! -e /dev/mem || exit 42; cat /dev/mem >/dev/null 2>&1; test "$?" -ne 0' \
        >/dev/null 2>&1; then triggered=$((triggered + 1)); fi
    sleep 1
done
capture_rc=0
wait "$falco_pid" || capture_rc=$?
falco_pid=''
if (( capture_rc == 0 && triggered > 0 )); then
    pass 'Falco captured while the container attempted to read absent /dev/mem'
else
    fail 'Falco captured while the container attempted to read absent /dev/mem'
    cat "$work/falco.log" >&2
fi
# Parse JSON rather than comparing rule YAML. Container IDs can be shortened.
# Names of lists/macros and condition formatting are deliberately unrestricted.
jq -R 'fromjson? | select(type == "object")' "$work/alerts" >"$work/events.json"
if jq -se --arg id "$id" '
    any(.[];
        (.output_fields["container.id"] // "" | tostring) as $cid |
        .rule == "devmem" and
        ((.priority // "" | ascii_downcase) == "notice") and
        ($cid | length) >= 12 and ($id | startswith($cid)) and
        (.output // "" | contains("Shell (container_id=" + $cid + ")")))
    ' "$work/events.json" >/dev/null; then
    pass 'devmem emits a NOTICE Shell alert containing the triggering container ID'
else
    fail 'devmem emits a NOTICE Shell alert containing the triggering container ID'
    echo 'No matching runtime alert was observed; check the local rule and capture-engine diagnostics.' >&2
fi
finish
