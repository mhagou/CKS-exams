#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on controlplane. No candidate configuration is modified.
# Runtime checks intentionally do not require particular YAML or volume names.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Unexpected validation error at line $LINENO"; finish' ERR
[[ $EUID -eq 0 ]] || { fail 'Run as root on controlplane.'; finish; }
for tool in kubectl jq stat tail; do
    command -v "$tool" >/dev/null || { fail "Required tool available: $tool"; finish; }
done
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
k() { kubectl --request-timeout=20s "$@"; }
if k get --raw=/readyz >/dev/null 2>&1; then pass 'API server is ready'; else fail 'API server is ready'; finish; fi

# Read the real process arguments, not a possibly stale mirror Pod or manifest.
pids=()
for proc in /proc/[0-9]*; do
    [[ -r $proc/cmdline ]] || continue
    argv=()
    mapfile -d '' -t argv < "$proc/cmdline" 2>/dev/null || continue
    executable=${argv[0]:-}
    if [[ ${executable##*/} == kube-apiserver ]]; then pids+=("${proc##*/}"); fi
done
if (( ${#pids[@]} != 1 )); then
    fail 'Exactly one local API server process is available for inspection'; finish
fi
pid=${pids[0]}
mapfile -d '' -t argv < "/proc/$pid/cmdline"
flag() {
    local name=$1 i value=''
    for ((i=1; i<${#argv[@]}; i++)); do
        case "${argv[i]}" in
            "--$name="*) value=${argv[i]#*=} ;;
            "--$name") value=${argv[i+1]:-} ;;
        esac
    done
    printf '%s' "$value"
}
for setting in 'audit-log-maxsize:500' 'audit-log-maxbackup:5' 'audit-log-maxage:7'; do
    name=${setting%%:*}; expected=${setting#*:}
    if [[ $(flag "$name") == "$expected" ]]; then
        pass "Running API server: $name=$expected"
    else
        fail "Running API server: $name=$expected"
    fi
done
policy=$(flag audit-policy-file)
log=$(flag audit-log-path)
host_policy=/etc/kubernetes/audit/policy.yaml
host_log=/etc/kubernetes/audit/logs/audit.log
# Device/inode identity accepts separate mounts, directory mounts and symlinks.
same_file() {
    [[ -f $1 && -f $2 ]] && [[ $(stat -Lc '%d:%i' "$1") == "$(stat -Lc '%d:%i' "$2")" ]]
}
if [[ $policy == /* ]] && same_file "$host_policy" "/proc/$pid/root$policy"; then
    pass 'Running API server uses the policy file at the requested host location'
else
    fail 'Running API server uses the policy file at the requested host location'
fi
if [[ $log == /* ]] && same_file "$host_log" "/proc/$pid/root$log"; then
    pass 'Audit log is persisted at the requested host location'
else
    fail 'Audit log is persisted at the requested host location'; finish
fi

work=$(mktemp -d)
ns="cks-audit-check-$(date +%s)-$$"
created=0
cleanup() {
    local rc=${1:-$?}
    trap - EXIT
    if (( created )); then
        if ! k delete namespace "$ns" --ignore-not-found --wait=false >/dev/null 2>&1; then
            printf '[FAIL] Could not remove temporary namespace %s\n' "$ns" >&2
            rc=1
        fi
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Keep only new lines, avoiding matches against an earlier validation run.
# -F also follows rotation. The short delay lets tail open before test requests.
tail -n 0 -F -- "$host_log" > "$work/events" 2> "$work/tail-errors" &
reader=$!
# Extend the cleanup handler to stop the reader on all exits.
cleanup_with_reader() {
    local rc=$?
    kill "$reader" 2>/dev/null || true
    wait "$reader" 2>/dev/null || true
    cleanup "$rc"
}
trap cleanup_with_reader EXIT
sleep 1

# Namespace CRUD exercises Request logging outside the Metadata resource rule.
if k create namespace "$ns" -o json > "$work/ns.json"; then
    created=1
else
    fail 'Create temporary namespace for audit probes'; finish
fi
jq '.metadata.annotations["cks-audit-check"]="update"' "$work/ns.json" > "$work/update.json"
if ! k replace -f "$work/update.json" >/dev/null; then fail 'Issue namespace update probe'; fi
if ! k patch namespace "$ns" --type=merge -p '{"metadata":{"annotations":{"cks-audit-check":"patch"}}}' >/dev/null; then
    fail 'Issue namespace patch probe'
fi

# A read and a mutation for every listed resource also check rule precedence.
# Server-side dry runs do not start Pods or leave test Secrets behind.
for resource in pods services configmaps secrets; do
    if ! k get --raw="/api/v1/namespaces/$ns/$resource" >/dev/null; then
        fail "Issue $resource list probe"
    fi
    case "$resource" in
        pods) object='{"apiVersion":"v1","kind":"Pod","metadata":{"name":"probe"},"spec":{"containers":[{"name":"probe","image":"registry.k8s.io/pause:3.10"}]}}' ;;
        services) object='{"apiVersion":"v1","kind":"Service","metadata":{"name":"probe"},"spec":{"ports":[{"port":80}]}}' ;;
        configmaps) object='{"apiVersion":"v1","kind":"ConfigMap","metadata":{"name":"probe"},"data":{"probe":"harmless"}}' ;;
        secrets) object='{"apiVersion":"v1","kind":"Secret","metadata":{"name":"probe"},"stringData":{"probe":"harmless"}}' ;;
    esac
    if ! printf '%s\n' "$object" | k create -n "$ns" --dry-run=server -f - >/dev/null; then
        fail "Issue $resource create probe"
    fi
done
if k delete namespace "$ns" --wait=false >/dev/null; then
    # Keep created=1 until cleanup verifies removal was requested successfully.
    :
else
    fail 'Issue namespace delete probe'
fi

# Parse line by line: a concurrently appended partial JSON line is retried.
collect() {
    jq -R 'fromjson? | select(.kind == "Event")' "$work/events" > "$work/parsed"
}
event_ok() {
    local resource=$1 verb=$2 level=$3
    jq -s -e --arg ns "$ns" --arg resource "$resource" --arg verb "$verb" --arg level "$level" '
      [.[] | select(.objectRef.resource == $resource and .verb == $verb)
       | select((.objectRef.namespace == $ns) or
                (.objectRef.resource == "namespaces" and .objectRef.name == $ns))
       | select(.stage != "RequestReceived")
       | select((.responseStatus.code // 0) >= 200 and (.responseStatus.code // 0) < 300)]
      | length > 0 and all(.[];
          .level == $level and (has("responseObject") | not) and
          (if $level == "Metadata" then (has("requestObject") | not)
           elif $verb == "delete" then true
           else has("requestObject") end))
    ' "$work/parsed" >/dev/null
}
# Bounded wait accommodates the API server audit backend's batching.
for ((attempt=0; attempt<30; attempt++)); do
    collect
    complete=1
    for resource in pods services configmaps secrets; do
        for verb in list create; do event_ok "$resource" "$verb" Metadata || complete=0; done
    done
    for verb in create update patch delete; do event_ok namespaces "$verb" Request || complete=0; done
    (( complete )) && break
    sleep 2
done
for resource in pods services configmaps secrets; do
    if event_ok "$resource" list Metadata && event_ok "$resource" create Metadata; then
        pass "$resource reads and writes log Metadata without request/response bodies"
    else
        fail "$resource reads and writes log Metadata without request/response bodies"
    fi
done
for verb in create update patch delete; do
    if event_ok namespaces "$verb" Request; then
        pass "$verb on other resources logs at Request level"
    else
        fail "$verb on other resources logs at Request level"
    fi
done
# RequestReceived may legitimately be omitted. Backup filenames, YAML layout,
# volume names and the duplicated example volumes block are not final objectives.
if k get --raw=/readyz >/dev/null 2>&1; then pass 'API server remains healthy'; else fail 'API server remains healthy'; fi
if k delete namespace "$ns" --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1; then
    created=0
else
    fail "Temporary namespace cleanup completed ($ns)"
fi
finish
