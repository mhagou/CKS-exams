#!/usr/bin/env bash
set -Eeuo pipefail

passed=0
failed=0
report() {
    if [[ $1 == true ]]; then
        printf '[PASS] %s\n' "$2"
        passed=$((passed + 1))
    else
        printf '[FAIL] %s\n' "$2"
        failed=$((failed + 1))
    fi
}
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
if ! command -v kubectl >/dev/null; then
    report false 'kubectl is available'
    finish
fi
K=(kubectl --request-timeout=30s -n monitoring)
value=$("${K[@]}" get sa stats-monitor-sa -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null) || value=''
report "$([[ $value == false ]] && echo true || echo false)" 'ServiceAccount stats-monitor-sa disables automatic API credential mounting'

# Inspect the live API objects. Container names and mount directories are not
# prescribed: resolve the projected path plus mountPath (or a file subPath).
# The volume name "token" IS explicitly required by the question.
check_projection() {
    local resource=$1 prefix=$2 runtime=${3:-} sa paths mounts
    local container mount readonly subpath subexpr path resolved found=false
    sa=$("${K[@]}" get "$resource" -o "jsonpath={${prefix}.serviceAccountName}") || return 1
    [[ $sa == stats-monitor-sa ]] || return 1
    paths=$("${K[@]}" get "$resource" -o "jsonpath={range ${prefix}.volumes[?(@.name==\"token\")].projected.sources[*]}{.serviceAccountToken.path}{'\n'}{end}") || return 1
    [[ -n $paths ]] || return 1
    mounts=$("${K[@]}" get "$resource" -o "jsonpath={range ${prefix}.containers[*]}{.name}{'\n'}{range .volumeMounts[?(@.name==\"token\")]}{.mountPath}{'|'}{.readOnly}{'|'}{.subPath}{'|'}{.subPathExpr}{'\n'}{end}{end}") || return 1
    container=''
    while IFS= read -r line; do
        if [[ $line != *'|'* ]]; then container=$line; continue; fi
        IFS='|' read -r mount readonly subpath subexpr <<< "$line"
        [[ $readonly == true && -z $subexpr ]] || continue
        while IFS= read -r path; do
            [[ -n $path ]] || continue
            if [[ -z $subpath ]]; then
                resolved="${mount%/}/$path"
            elif [[ $path == "$subpath" ]]; then
                resolved=$mount
            elif [[ $path == "$subpath/"* ]]; then
                resolved="${mount%/}/${path#"$subpath/"}"
            else
                continue
            fi
            [[ $resolved == /var/run/secrets/kubernetes.io/serviceaccount/token ]] || continue
            if [[ -n $runtime ]]; then
                # Read only; never print credentials or modify the mount.
                "${K[@]}" exec "$runtime" -c "$container" -- sh -c \
                    'test -r /var/run/secrets/kubernetes.io/serviceaccount/token && test -s /var/run/secrets/kubernetes.io/serviceaccount/token' \
                    >/dev/null || return 1
            fi
            found=true
        done <<< "$paths"
    done <<< "$mounts"
    [[ $found == true ]]
}

if check_projection deployment/stats-monitor .spec.template.spec; then
    report true 'Deployment uses stats-monitor-sa and projects volume token read-only at the required token path'
else
    report false 'Deployment uses stats-monitor-sa and projects volume token read-only at the required token path'
fi

ready=true
"${K[@]}" rollout status deployment/stats-monitor --timeout=120s >/dev/null 2>&1 || ready=false
replicas=$("${K[@]}" get deployment stats-monitor -o jsonpath='{.spec.replicas}' 2>/dev/null) || replicas=0
[[ $replicas =~ ^[0-9]+$ ]] && (( replicas > 0 )) || ready=false
report "$ready" 'Deployment has a completed rollout with running replicas'

# Follow ownership rather than assuming labels or generated ReplicaSet names.
runtime_ok=true
count=0
uid=$("${K[@]}" get deployment stats-monitor -o jsonpath='{.metadata.uid}' 2>/dev/null) || uid=''
rs_rows=$("${K[@]}" get replicasets -o jsonpath='{range .items[*]}{.metadata.uid}{"|"}{.metadata.ownerReferences[?(@.controller==true)].uid}{"\n"}{end}') || { rs_rows=''; runtime_ok=false; }
pod_rows=$("${K[@]}" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.metadata.ownerReferences[?(@.controller==true)].uid}{"|"}{.status.phase}{"|"}{.metadata.deletionTimestamp}{"\n"}{end}') || { pod_rows=''; runtime_ok=false; }
while IFS='|' read -r rs_uid owner; do
    [[ -n $uid && $owner == "$uid" ]] || continue
    while IFS='|' read -r pod pod_owner phase deleting; do
        [[ $pod_owner == "$rs_uid" && -z $deleting ]] || continue
        count=$((count + 1))
        if [[ $phase != Running ]] || ! check_projection "pod/$pod" .spec "$pod"; then
            runtime_ok=false
            printf '  Pod %s does not have the required readable projected token and read-only mount.\n' "$pod"
        fi
    done <<< "$pod_rows"
done <<< "$rs_rows"
(( count > 0 )) || runtime_ok=false
report "$runtime_ok" 'Running Deployment Pods expose a nonempty projected ServiceAccount token at the required read-only path'
finish
