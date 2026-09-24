#!/usr/bin/env bash
set -Eeuo pipefail
# Run on controlplane. Read-only except for a local temporary copy of the report.
# CSV alone cannot establish the historical tool, syscall/container filters or
# observation duration. A reviewer may pass --capture-reviewed AFTER inspecting
# the actual capture command/session (Falco or Sysdig, target container, process
# spawn/exec events, >=40 seconds). This accepts transient Sysdig sessions and
# equivalent Falco rules without demanding any particular rule/file names.
reviewed=false
if [[ ${1:-} == --capture-reviewed && $# -eq 1 ]]; then
    reviewed=true
elif [[ $# -ne 0 ]]; then
    echo 'Usage: validate.sh [--capture-reviewed]' >&2
    exit 2
fi
passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    [[ $failed -eq 0 ]]
}
for cmd in ssh awk date mktemp; do
    if ! command -v "$cmd" >/dev/null; then fail "Required validator command: $cmd"; finish; exit 1; fi
done
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
if ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 \
    'test -f /home/cert_masters/report && test -s /home/cert_masters/report && cat /home/cert_masters/report' > "$tmp/report"; then
    pass 'Nonempty incident report exists at /home/cert_masters/report on node01'
else
    fail 'Nonempty incident report exists at /home/cert_masters/report on node01'
    finish
    exit 1
fi
# Allow optional field brackets/quotes and whitespace, but exactly three fields.
if awk -F, '
function clean(s) {
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
    if (s ~ /^\[.*\]$/ || s ~ /^".*"$/) s=substr(s,2,length(s)-2)
    return s
}
NF {
    if (NF != 3) { bad=1; next }
    t=clean($1); u=clean($2); p=clean($3)
    if (t == "" || u !~ /^[0-9]+$/ || p == "") { bad=1; next }
    print t "\t" u "\t" p
    count++
}
END { if (bad || !count) exit 1 }
' "$tmp/report" > "$tmp/records"; then
    pass 'Report uses timestamp,uid,processName records'
else
    fail 'Report uses timestamp,uid,processName records'
    finish
    exit 1
fi
# The simulated executable is an actual copy of sleep, not a script whose
# proc.name could depend on the interpreter. UID is 0 in the prepared container.
if awk -F '\t' '$2 == 0 && $3 == "cryptominer" { found=1 } END { exit !found }' "$tmp/records"; then
    pass 'Report identifies the simulated anomalous process and its UID'
else
    fail 'Report identifies the simulated anomalous process and its UID'
fi
# Accept Falco/Sysdig time-of-day, ISO/date timestamps and epoch timestamps.
# Time-of-day records can cross midnight. Nanoseconds are retained by awk.
bad=0
while IFS=$'\t' read -r stamp uid process; do
    if [[ $stamp =~ ^[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?$ ]]; then
        if ! date -d "$stamp" +%s >/dev/null 2>&1; then bad=1; continue; fi
        value=$(awk -F: '{print ($1*3600)+($2*60)+$3}' <<< "$stamp")
    elif [[ $stamp =~ ^[0-9]{10}([.][0-9]+)?$ ]]; then
        value=$stamp
    elif [[ $stamp =~ ^[0-9]{19}$ ]]; then
        value="${stamp:0:10}.${stamp:10}"
    elif value=$(date -d "$stamp" +%s.%N 2>/dev/null); then
        :
    else
        bad=1
        continue
    fi
    printf '%s\n' "$value" >> "$tmp/times"
done < "$tmp/records"
if (( bad == 0 )); then pass 'All report timestamps are valid'; else fail 'All report timestamps are valid'; fi
if $reviewed; then
    pass 'Reviewer confirmed Falco/Sysdig process filters for the target container and at least 40 seconds of observation'
else
    fail 'Capture method and duration require review; CSV alone cannot prove these objectives'
    echo 'Inspect the original capture command/session, then use --capture-reviewed only if it meets both objectives.'
fi
# Informational only: a 40-second capture need not contain events exactly at
# either endpoint. Do not falsely reject it for a shorter timestamp span.
if [[ -s $tmp/times && $bad -eq 0 ]]; then
    awk 'NR==1 {first=$1; prev=$1} {
        if ($1 < prev && prev < 86400 && $1 < 86400 && prev-$1 > 43200) offset+=86400
        value=$1+offset
        if (NR==1 || value<lo) lo=value
        if (NR==1 || value>hi) hi=value
        prev=$1
    } END {printf "Report timestamp span: %.3f seconds (supporting evidence only).\n", hi-lo}' "$tmp/times"
fi
finish
