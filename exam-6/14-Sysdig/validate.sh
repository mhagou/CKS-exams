#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on controlplane. Optional arguments are passed to Sysdig, e.g.
# ./validate.sh --modern-bpf or ./validate.sh -B /path/to/prepared/probe.o.
# No packages, probes, or configuration are installed/repaired by this script.
passes=0
failures=0
pass() { printf '[PASS] %s\n' "$*"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
    if (( failures == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
if [[ $EUID -ne 0 ]]; then fail 'Validation requires root on controlplane.'; finish; fi
for cmd in kubectl timeout mktemp; do
    if ! command -v "$cmd" >/dev/null; then fail "Missing validation prerequisite: $cmd"; finish; fi
done
if command -v sysdig >/dev/null && sysdig --version >/dev/null 2>&1; then
    pass 'Sysdig is installed and executable.'
else
    fail 'Sysdig is installed and executable.'
    finish
fi
work=$(mktemp -d)
capture_pid=''
cleanup() {
    if [[ -n $capture_pid ]]; then
        kill "$capture_pid" 2>/dev/null || true
        wait "$capture_pid" 2>/dev/null || true
    fi
    rm -rf -- "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if sysdig --list >"$work/fields" 2>"$work/error" &&
    grep -Eq '(^|[[:space:]])user\.uid([[:space:]]|$)' "$work/fields" &&
    grep -Eq '(^|[[:space:]])container\.image\.repository([[:space:]]|$)' "$work/fields"; then
    pass 'Sysdig exposes user.uid and container.image.repository.'
else
    fail 'Sysdig exposes user.uid and container.image.repository.'
    cat "$work/error" >&2
    finish
fi

# The task requires no saved command or output artifact. Test the actual capture
# capability instead of requiring shell history or a particular package source.
namespace=${TEST_NAMESPACE:-default}
pod=${TEST_POD:-test}
k=(kubectl --request-timeout=20s -n "$namespace")
if ! node=$("${k[@]}" get pod "$pod" -o jsonpath='{.spec.nodeName}') || [[ $node != controlplane ]]; then
    fail 'Test workload is available on controlplane for local event capture.'
    finish
fi
if ! "${k[@]}" wait --for=condition=Ready "pod/$pod" --timeout=30s >/dev/null; then
    fail 'Test workload is running.'
    finish
fi
container=$("${k[@]}" get pod "$pod" -o jsonpath='{.spec.containers[0].name}')
id=$("${k[@]}" get pod "$pod" -o jsonpath='{.status.containerStatuses[0].containerID}')
id=${id#*://}
if [[ -z $id ]]; then fail 'Test container has a runtime ID.'; finish; fi
uid=$("${k[@]}" exec "$pod" -c "$container" -- id -u) || {
    fail 'Can execute the test shell and determine its UID.'; finish;
}

# Try the installed default engine, then modern BPF when advertised. Explicit
# caller options override this fallback. These only select capture backends.
engines=(default)
if (( $# == 0 )); then
    sysdig --help >"$work/help" 2>&1 || true
    if grep -q -- '--modern-bpf' "$work/help"; then engines+=(modern); fi
fi
captured=false
for engine in "${engines[@]}"; do
    args=("$@")
    if [[ $engine == modern ]]; then args=(--modern-bpf); fi
    # A bounded capture exits after the first matching exec event. The filter
    # uses runtime identity rather than assuming a Kubernetes container name.
    timeout --signal=TERM --kill-after=3s 25s sysdig "${args[@]}" -n 1 \
        -p 'user_id=%user.uid repo=%container.image.repository' \
        "container.id=${id:0:12} and evt.type in (execve,execveat) and evt.dir=< and container.image.repository exists" \
        >"$work/events" 2>"$work/capture-error" &
    capture_pid=$!
    for (( attempt=0; attempt<10; attempt++ )); do
        sleep 2
        if ! kill -0 "$capture_pid" 2>/dev/null; then break; fi
        "${k[@]}" exec "$pod" -c "$container" -- sh -c ':' > /dev/null 2>"$work/exec-error" || true
    done
    status=0
    wait "$capture_pid" || status=$?
    capture_pid=''
    if (( status == 0 )) && awk -v uid="$uid" '
        $1 == "user_id=" uid && $2 ~ /^repo=.+/ {
            repo=substr($2,6)
            if (repo != "<NA>" && repo != "<NONE>" && repo != "N/A" && repo != "null") ok=1
        }
        END { exit !ok }
    ' "$work/events"; then
        captured=true
        break
    fi
    printf 'Capture diagnostic (%s):\n' "$engine" >&2
    cat "$work/capture-error" "$work/exec-error" "$work/events" >&2 2>/dev/null || true
done
if [[ $captured == true ]]; then
    pass 'Live test-container events report the actual user UID and image repository.'
else
    fail 'Live test-container events report the actual user UID and image repository.'
    echo 'Check the prepared capture driver and container-runtime metadata access. Backend arguments may be supplied to this validator.' >&2
fi
finish
