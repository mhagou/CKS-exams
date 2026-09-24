#!/usr/bin/env bash
set -Eeuo pipefail

# No score threshold, hardening changes, or running cluster Pod are requested.
# This checks current scan functionality, not whether a command was run before.
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PATH="/usr/local/bin:$PATH"
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then
        echo 'RESULT: SUCCESS'
    else
        echo 'RESULT: FAILED'
        exit 1
    fi
}

if ! tmp=$(mktemp -d); then
    fail 'Create temporary scan workspace'
    finish
fi
trap 'rm -rf -- "$tmp"' EXIT
scanner_ready=false
if command -v kubesec >/dev/null && kubesec version >"$tmp/version" 2>&1 && [[ -s "$tmp/version" ]]; then
    pass 'Kubesec is installed and its version command works'
    scanner_ready=true
else
    fail 'Kubesec is installed and its version command works'
fi

if [[ -r "$script_dir/pod.yaml" && -s "$script_dir/pod.yaml" ]]; then
    pass 'pod.yaml exists and is readable'
else
    fail 'pod.yaml exists and is readable'
fi

if ! command -v jq >/dev/null; then
    fail 'JSON validation prerequisite jq is available (run setup on the playground)'
elif [[ "$scanner_ready" != true || ! -r "$script_dir/pod.yaml" || ! -s "$script_dir/pod.yaml" ]]; then
    fail 'Kubesec can scan pod.yaml (prerequisites missing)'
else
    # A negative security score can cause a nonzero exit. The walkthrough does
    # not require a minimum score, so inspect valid structured results instead.
    scan_status=0
    kubesec scan "$script_dir/pod.yaml" >"$tmp/scan.json" 2>"$tmp/scan.err" || scan_status=$?
    if jq -e '
        type == "array" and length > 0 and
        all(.[]; .valid == true and (.score | type == "number")) and
        any(.[]; (.object // "") | startswith("Pod/"))
    ' "$tmp/scan.json" >/dev/null 2>&1; then
        pass 'Kubesec scans pod.yaml and returns valid Pod scoring results'
    else
        fail "Kubesec scans pod.yaml and returns valid Pod scoring results (exit $scan_status)"
        echo 'Check manifest validity and access to the Kubernetes schema download source.'
        if [[ -s "$tmp/scan.err" ]]; then cat "$tmp/scan.err" >&2; fi
    fi
fi
finish
