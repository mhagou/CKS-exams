#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only checks plus a harmless read of the existing simulated memory file.
passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Validation could not complete (line $LINENO)"; finish' ERR
for tool in kubectl jq; do
    if ! command -v "$tool" >/dev/null; then fail "Required validation tool: $tool"; finish; fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
ns=falco-dev-mem-demo
if kubectl get namespace "$ns" >/dev/null 2>&1; then pass 'Demo namespace exists'; else fail 'Demo namespace exists'; fi
for name in falco-gpu-amd falco-gpu-nvidia falco-cpu; do
    if kubectl -n "$ns" get deployment "$name" -o json >"$work/deploy" 2>/dev/null &&
       jq -e '(.spec.replicas // 1) >= 1 and
         (.status.observedGeneration >= .metadata.generation) and
         (.status.availableReplicas // 0) >= .spec.replicas' "$work/deploy" >/dev/null; then
        pass "$name is available"
    else fail "$name is available"; fi
done
if kubectl -n falco get configmap falco-custom-rules -o json >"$work/cm" 2>/dev/null &&
   jq -e '((.data // {}) + (.binaryData // {})) | length > 0' "$work/cm" >/dev/null; then
    pass 'Custom rules ConfigMap exists and contains data'
else fail 'Custom rules ConfigMap exists and contains data'; fi
if ! kubectl -n falco get ds falco -o json >"$work/ds" 2>/dev/null; then
    fail 'Falco DaemonSet exists'; finish
fi
if jq -e '.status.desiredNumberScheduled > 0 and
    .status.numberReady == .status.desiredNumberScheduled and
    .status.updatedNumberScheduled == .status.desiredNumberScheduled and
    .status.observedGeneration >= .metadata.generation' "$work/ds" >/dev/null; then
    pass 'Falco DaemonSet rollout is healthy'
else fail 'Falco DaemonSet rollout is healthy'; fi
uid=$(jq -r '.metadata.uid' "$work/ds")
# Resolve actual Deployment -> ReplicaSet -> Pod ownership, without naming assumptions.
if ! kubectl -n "$ns" get deployment falco-cpu -o json >"$work/cpu" 2>/dev/null ||
   ! kubectl -n "$ns" get rs -o json >"$work/rs" ||
   ! kubectl -n "$ns" get pods -o json >"$work/pods"; then
    fail 'CPU event source can be inspected'; finish
fi
cpu_uid=$(jq -r '.metadata.uid' "$work/cpu")
rs_uids=$(jq -c --arg uid "$cpu_uid" '[.items[] |
    select(any(.metadata.ownerReferences[]?; .uid == $uid)) | .metadata.uid]' "$work/rs")
pod=$(jq -r --argjson ids "$rs_uids" '.items[] |
    select(.metadata.deletionTimestamp == null and .status.phase == "Running") |
    select(any(.metadata.ownerReferences[]?; .uid as $u | $ids | index($u))) |
    .metadata.name' "$work/pods" | head -n1)
if [[ -z $pod ]]; then fail 'Running CPU event source exists'; finish; fi
kubectl -n "$ns" get pod "$pod" -o json >"$work/pod"
node=$(jq -r '.spec.nodeName' "$work/pod")
# Locate the file in a running container, allowing candidate container renames.
container=''
while IFS= read -r c; do
    if kubectl -n "$ns" exec "$pod" -c "$c" -- test -s /tmp/mem >/dev/null 2>&1; then container=$c; break; fi
done < <(jq -r '.spec.containers[].name' "$work/pod")
if [[ -z $container ]]; then fail 'Simulated memory file exists'; finish; fi
pass 'Simulated memory file exists'
cid=$(jq -r --arg c "$container" '.status.containerStatuses[] | select(.name == $c) | .containerID' "$work/pod")
cid=${cid#*://}; cid=${cid:0:12}
if [[ -z $cid || $cid == null ]]; then fail 'Event source container ID is available'; finish; fi
if ! kubectl -n falco get pods -o json >"$work/sensors"; then fail 'Falco sensors can be inspected'; finish; fi
sensor=$(jq -r --arg node "$node" --arg uid "$uid" '.items[] |
    select(.spec.nodeName == $node and .metadata.deletionTimestamp == null) |
    select(any(.metadata.ownerReferences[]?; .uid == $uid)) |
    select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
    .metadata.name' "$work/sensors" | head -n1)
if [[ -z $sensor ]]; then fail 'Ready Falco sensor covers the event source node'; finish; fi
# Check effective Pod mounts, accepting direct or projected ConfigMap volumes.
if jq -e --arg p "$sensor" '.items[] | select(.metadata.name == $p) |
    [.spec.volumes[]? | select(.configMap.name == "falco-custom-rules" or
      any(.projected.sources[]?; .configMap.name == "falco-custom-rules")) | .name] as $v |
    any(.spec.containers[]; any(.volumeMounts[]?; .name as $n | $v | index($n)))' "$work/sensors" >/dev/null; then
    pass 'Custom rules ConfigMap is mounted in the running sensor Pod'
else fail 'Custom rules ConfigMap is mounted in the running sensor Pod'; fi
# A fresh time window excludes historic alerts. No rule name/output formatting is imposed.
start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
if ! kubectl -n "$ns" exec "$pod" -c "$container" -- cat /tmp/mem >/dev/null; then
    fail 'Trigger a read of /tmp/mem'; finish
fi
pass 'Trigger a read of /tmp/mem'
found=false
for attempt in {1..15}; do
    if kubectl -n falco logs "$sensor" --all-containers=true --since-time="$start" >"$work/logs" 2>"$work/log-error"; then
        # Works with plain Falco output and JSON output; associate the path with this source.
        if awk -v id="$cid" -v pod="$pod" '
          index($0,"/tmp/mem") && (index($0,id) || index($0,pod)) &&
          tolower($0) ~ /warning/ {found=1}
          END {exit !found}' "$work/logs"; then found=true; break; fi
    fi
    sleep 2
done
if $found; then pass 'Fresh WARNING alert identifies /tmp/mem and the source container'
else fail 'Fresh WARNING alert identifies /tmp/mem and the source container (checked sensor logs for 30s)'; fi
finish
