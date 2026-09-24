#!/usr/bin/env bash
set -Eeuo pipefail

# task.txt defines mock inputs only. Its illustrative SBOM command fails with
# EOF; no successful candidate artifact is required by the authoritative task.
# Accordingly, SUCCESS below means the stated practice resources are present,
# and must not be interpreted as proof that a candidate generated an SBOM.
export PATH="/usr/local/bin:$PATH"
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }

printf 'Scope: mock-input practice resources only; candidate SBOM generation is not graded.\n'
k=(kubectl --request-timeout=30s --namespace=default)
if command -v kubectl >/dev/null && images=$("${k[@]}" get pod kiwi -o jsonpath='{range .spec.containers[*]}{.image}{"\n"}{end}'); then
    if grep -Eq '^(docker.io/(library/)?)?nginx:1\.21\.6$' <<< "$images"; then
        pass 'default/kiwi uses nginx:1.21.6.'
    else
        fail 'default/kiwi must use nginx:1.21.6.'
    fi
    if state=$("${k[@]}" get pod kiwi -o jsonpath='{.status.phase}{" "}{.status.conditions[?(@.type=="Ready")].status}') && [[ $state == 'Running True' ]]; then
        pass 'The practice pod is running and ready.'
    else
        fail 'The practice pod is not running and ready.'
    fi
else
    fail 'Cannot inspect default/kiwi; check kubectl, cluster access, and the pod.'
fi

if [[ -d /root/image-archive ]]; then
    pass 'The image-archive directory exists.'
else
    fail 'The image-archive directory is missing or inaccessible.'
fi
if [[ -f /root/image-archive/nginx_1.21.6.tar && -r /root/image-archive/nginx_1.21.6.tar ]]; then
    pass 'The requested archive placeholder exists and is readable.'
else
    fail 'The requested archive placeholder is missing or unreadable (run as root).'
fi

if command -v bom >/dev/null && help=$(bom generate --help 2>/dev/null) &&
    [[ $help == *--image-archive* && $help == *--format* && $help == *--output* ]]; then
    pass 'bom supports the syntax-practice workflow.'
else
    fail 'bom is unavailable or lacks the required options.'
fi

printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
if ((failed == 0)); then
    echo 'RESULT: SUCCESS'
else
    echo 'RESULT: FAILED'
    exit 1
fi
