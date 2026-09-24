#!/usr/bin/env bash
set -Eeuo pipefail

# Interpret the terse task using solution.txt: record the SHA-256 hashes of
# host kubectl and kubelet from a Pod. This is not release authenticity checking.
# Search all namespaces by default. Optional usage:
#   ./validate.sh [namespace [pod]]
# For another result file, use HASH_FILE=/path/to/file ./validate.sh ...
# Container names, images, mount paths, and Pod names are not prescribed.
# Both running Pods and completed Pods with retained logs can pass.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
k() { kubectl --request-timeout=20s "$@"; }
for tool in kubectl sha256sum awk; do
    if ! command -v "$tool" >/dev/null; then
        fail "Required validation tool is unavailable: $tool"
        finish
    fi
done
if (( $# > 2 )); then
    fail 'Usage: validate.sh [namespace [pod]]'
    finish
fi
scope=(-A)
[[ -z ${1:-} ]] || scope=(-n "$1")
if ! pods=$(k get pods "${scope[@]}" -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.nodeName}{"\n"}{end}'); then
    fail 'Candidate Pods can be inspected'
    finish
fi

# Read the current host binaries independently of the candidate's output.
# Never execute a candidate-provided command or modify the candidate's Pod.
host_hashes='set -eu
for binary in kubectl kubelet; do
    path=$(command -v "$binary")
    digest=$(sha256sum "$path")
    printf "%s %s\n" "${digest%% *}" "$binary"
done'
declare -A hashes=()
matched=''
while IFS='|' read -r namespace pod node; do
    [[ -n $pod && -n $node ]] || continue
    [[ -z ${2:-} || $pod == "$2" ]] || continue
    case "$node" in controlplane|node01) ;; *) continue ;; esac
    if [[ ! ${hashes[$node]+cached} ]]; then
        if [[ $node == controlplane ]]; then
            hashes[$node]=$(bash -c "$host_hashes") || hashes[$node]=''
        else
            hashes[$node]=$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 bash -s <<< "$host_hashes") || hashes[$node]=''
        fi
    fi
    [[ -n ${hashes[$node]} ]] || continue
    containers=$(k get pod -n "$namespace" "$pod" -o jsonpath='{range .spec.initContainers[*]}{.name}{"\n"}{end}{range .spec.containers[*]}{.name}{"\n"}{end}') || continue
    evidence=''
    while IFS= read -r container; do
        [[ -n $container ]] || continue
        logs=$(k logs -n "$namespace" "$pod" -c "$container" --tail=-1 2>/dev/null) || logs=''
        record=$(k exec -n "$namespace" "$pod" -c "$container" -- cat "${HASH_FILE:-/tmp/verified-hashes.txt}" 2>/dev/null) || record=''
        evidence+=$'\n'"$logs"$'\n'"$record"
    done <<< "$containers"
    verified=0
    while read -r digest binary; do
        # Match checksum records by digest and basename, allowing any mount path
        # and both sha256sum text and binary record formats.
        if awk -v expected="$digest" -v binary="$binary" '
            tolower($1) == expected {
                path=$2; sub(/^\*/, "", path); sub(/^.*\//, "", path)
                if (path == binary) found=1
            }
            END { exit !found }
        ' <<< "$evidence"; then
            verified=$((verified + 1))
        fi
    done <<< "${hashes[$node]}"
    if (( verified == 2 )); then
        matched="$namespace/$pod"
        break
    fi
done <<< "$pods"

if [[ -n $matched ]]; then
    pass "Pod $matched records correct SHA-256 hashes of its node's kubectl and kubelet"
else
    fail 'A Pod records correct SHA-256 hashes of its node’s kubectl and kubelet'
    echo 'Check Pod logs or the result file (default /tmp/verified-hashes.txt; override with HASH_FILE).'
    echo 'Host binaries must be readable on controlplane, or through root SSH on node01.'
fi
finish
