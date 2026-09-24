#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only Kubernetes checks. No resources or configuration are changed.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed+1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed+1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
k() { kubectl --request-timeout=30s "$@"; }
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is available'; finish
fi
if handler=$(k get runtimeclass not-trusted -o jsonpath='{.handler}') && [[ $handler == runsc ]]; then
    pass 'RuntimeClass not-trusted selects handler runsc'
else
    fail 'RuntimeClass not-trusted selects handler runsc'
fi
if runtime=$(k -n default get deployment x -o jsonpath='{.spec.template.spec.runtimeClassName}') && [[ $runtime == not-trusted ]]; then
    pass 'Deployment default/x uses not-trusted in its Pod template'
else
    fail 'Deployment default/x uses not-trusted in its Pod template'
fi

# Follow owner UIDs rather than assuming Pod names, labels, or container names.
if ! uid=$(k -n default get deployment x -o jsonpath='{.metadata.uid}'); then
    fail 'Deployment default/x has running, ready Pods using not-trusted'; finish
fi
if ! k -n default rollout status deployment/x --timeout=120s; then
    fail 'Deployment default/x rollout completes'
else
    pass 'Deployment default/x rollout completes'
fi
if ! rs_rows=$(k -n default get replicasets -o go-template='{{range .items}}{{$uid := .metadata.uid}}{{range .metadata.ownerReferences}}{{if .controller}}{{printf "%s %s\n" $uid .uid}}{{end}}{{end}}{{end}}'); then
    fail 'Deployment ReplicaSets can be inspected'; finish
fi
owners=' '
while read -r rs_uid owner_uid; do
    [[ $owner_uid != "$uid" ]] || owners+="$rs_uid "
done <<< "$rs_rows"
if ! pod_rows=$(k -n default get pods -o go-template='{{range .items}}{{if not .metadata.deletionTimestamp}}{{.metadata.name}} {{range .metadata.ownerReferences}}{{if .controller}}{{.uid}}{{end}}{{end}} {{if .spec.runtimeClassName}}{{.spec.runtimeClassName}}{{else}}none{{end}} {{.status.phase}} {{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}{{"\n"}}{{end}}{{end}}'); then
    fail 'Deployment Pods can be inspected'; finish
fi
count=0
healthy=true
while read -r name owner runtime phase ready; do
    [[ -n $owner && $owners == *" $owner "* ]] || continue
    count=$((count+1))
    if [[ $runtime != not-trusted || $phase != Running || $ready != True ]]; then
        healthy=false
        printf '  Pod %s: runtimeClass=%s phase=%s ready=%s\n' "$name" "$runtime" "$phase" "${ready:-unknown}"
    fi
done <<< "$pod_rows"
if (( count > 0 )) && [[ $healthy == true ]]; then
    pass 'All active Deployment Pods run and are ready using not-trusted'
else
    fail 'All active Deployment Pods run and are ready using not-trusted (at least one required)'
fi
finish
