#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only artifact validation. Never runs Falco or rewrites the submission.
# The Question ends at "in the format"; the embedded example is the only
# indication of the intended record layout: [time],[uid],[process].
# These fields omit container identity, event type and capture start/end.
# They cannot prove tool provenance, filtering or elapsed capture time.
# Do not infer >=20 seconds from the number of lines or reject a correct
# 20-second capture because its first/last events are less than 20s apart.
#
# Usage: ./validate.sh [--reviewed-capture]
# --reviewed-capture is a HUMAN REVIEWER attestation, not an automatic test:
# inspect the candidate's actual invocation, loaded rules/configuration and
# observed run (or a trustworthy transcript). Confirm that Falco captured for
# >=20 seconds, selected process spawn/exec events in exactly one Nginx
# container, and produced this incident file. Accept equivalent rule/filter
# formulations, including execve/execveat and appropriate spawn events.
# Without that attestation the unobservable objectives remain unverified and
# the script deliberately does not claim overall success.

reviewed=false
case "${1:-}" in
    '') ;;
    --reviewed-capture) reviewed=true; shift ;;
    --help|-h)
        sed -n '4,22p' "$0"
        exit 0 ;;
    *) echo 'Usage: validate.sh [--reviewed-capture]' >&2; exit 2 ;;
esac
[[ $# -eq 0 ]] || { echo 'Unexpected arguments.' >&2; exit 2; }

passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
incident=/opt/falco-incident.txt

if [[ -f "$incident" && -r "$incident" && -s "$incident" ]]; then
    pass 'The incident file exists at /opt/falco-incident.txt and is nonempty.'
    # Accept time-of-day and ISO date/time, fractional precision, and optional
    # whitespace around comma separators. No arbitrary process/UID allowlist:
    # candidates may legitimately trigger additional activity in the target.
    if LC_ALL=C awk '
        function valid_time(value, time, parts, n) {
            time = value
            if (time ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ]/)
                time = substr(time, 12)
            sub(/(Z|[+-][0-9][0-9]:[0-9][0-9])$/, "", time)
            if (time !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9](\.[0-9]+)?$/)
                return 0
            n = split(time, parts, ":")
            return n == 3 && parts[1]+0 < 24 && parts[2]+0 < 60 && parts[3]+0 < 61
        }
        {
            sub(/\r$/, "")
            if ($0 !~ /^\[[^][]+\],[[:blank:]]*\[[0-9]+\],[[:blank:]]*\[[^][]+\]$/) {
                bad++; next
            }
            line = $0
            gsub(/\],[[:blank:]]*\[/, "\034", line)
            sub(/^\[/, "", line)
            sub(/\]$/, "", line)
            split(line, field, "\034")
            if (!valid_time(field[1]) || field[3] ~ /^(<NA>|<N\/A>|<unknown>)$/)
                bad++
        }
        END { exit (NR == 0 || bad > 0) }
    ' "$incident"; then
        pass 'Every line contains a timestamp, numeric UID and process name in the intended layout.'
    else
        fail 'Every line must be one incident: [time],[numeric UID],[process name], with no headers or diagnostics.'
    fi
else
    fail 'A readable, nonempty /opt/falco-incident.txt is required.'
    fail 'Incident record format cannot be checked.'
fi

if "$reviewed"; then
    pass 'Reviewer confirmed an actual Falco capture lasting at least 20 seconds.'
    pass 'Reviewer confirmed spawn/exec filtering for one Nginx container and provenance of this file.'
else
    fail 'UNVERIFIED: actual Falco use and >=20-second duration require observation or capture evidence.'
    fail 'UNVERIFIED: single-container spawn/exec filtering cannot be established from these three fields.'
    printf '\nA reviewer may rerun with --reviewed-capture after checking the actual capture.\n'
    printf 'See validate.sh --help for the review criteria; no particular candidate command is required.\n'
fi

printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
if (( failed == 0 )); then
    echo 'RESULT: SUCCESS'
    exit 0
fi
echo 'RESULT: FAILED'
exit 1
