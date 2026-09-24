#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation. The task requires no saved candidate artifact; a
# successful comparison cannot demonstrate that the candidate ran it earlier.
readonly reference=/var/lib/cks-sha512sum/reference.sha512
readonly binary=/usr/bin/kubelet
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then
        printf 'RESULT: SUCCESS\n'
        exit 0
    fi
    printf 'RESULT: FAILED\n'
    exit 1
}

if ! command -v sha512sum >/dev/null 2>&1; then
    fail 'SHA-512 verification is available (sha512sum is missing).'
    finish
fi
if [[ ! -r "$reference" ]] || ! record=$(cat "$reference"); then
    fail 'The supplied lab reference is readable; run setup first.'
    finish
fi
digest=${record%% *}
if [[ ! "$digest" =~ ^[[:xdigit:]]{128}$ || "$record" != "$digest  $binary" ]]; then
    fail 'The lab reference contains a SHA-512 digest for /usr/bin/kubelet.'
    finish
fi

if [[ -f "$binary" && -r "$binary" ]] && sha512sum --check --status "$reference"; then
    pass '/usr/bin/kubelet matches the supplied SHA-512 reference.'
else
    fail '/usr/bin/kubelet matches the supplied SHA-512 reference.'
fi
printf 'Note: This checks the current comparison, not prior candidate commands.\n'
finish
