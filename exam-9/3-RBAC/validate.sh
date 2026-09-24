#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation against the current playground context.
ns=database
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( failed == 0 ))
}
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is available'
    finish
    exit 1
fi

# Evaluate live API rules, accepting split/duplicate rules and any ordering.
# Every granted permission must be in the requested set, and at least one
# rule must grant access without a resourceNames restriction.
role_only() {
    local name=$1 group=$2 resource=$3 verb=$4 result template
    template='{{range .rules}}{{if .nonResourceURLs}}BAD{{end}}{{range .apiGroups}}{{if ne . "GROUP"}}BAD{{end}}{{end}}{{range .resources}}{{if ne . "RESOURCE"}}BAD{{end}}{{end}}{{range .verbs}}{{if ne . "VERB"}}BAD{{end}}{{end}}{{if and .apiGroups .resources .verbs}}{{if not .resourceNames}}FULL{{end}}{{end}}{{end}}'
    template=${template//GROUP/$group}
    template=${template//RESOURCE/$resource}
    template=${template//VERB/$verb}
    result=$(kubectl -n "$ns" get role "$name" -o go-template="$template") || return 1
    [[ $result != *BAD* && $result == *FULL* ]]
}
role_bound() {
    local role=$1 result template
    template='{{range .items}}{{if and (eq .roleRef.kind "Role") (eq .roleRef.name "ROLE")}}{{range .subjects}}{{if and (eq .kind "ServiceAccount") (eq .name "test-sa") (eq .namespace "database")}}BOUND{{end}}{{end}}{{end}}{{end}}'
    template=${template//ROLE/$role}
    result=$(kubectl -n "$ns" get rolebindings -o go-template="$template") || return 1
    [[ $result == *BOUND* ]]
}

if [[ $(kubectl -n "$ns" get pod web-pod -o jsonpath='{.spec.serviceAccountName}{"/"}{.status.phase}' 2>/dev/null) == test-sa/Running ]] &&
    kubectl -n "$ns" get serviceaccount test-sa >/dev/null 2>&1; then
    pass 'web-pod is running with ServiceAccount test-sa in database'
else
    fail 'web-pod is running with ServiceAccount test-sa in database'
fi

if role_only test-role-1 '' pods get && role_bound test-role-1 &&
    [[ $(kubectl -n "$ns" auth can-i get pods --as=system:serviceaccount:database:test-sa) == yes ]]; then
    pass 'The original bound Role grants only get on Pods'
else
    fail 'The original bound Role grants only get on Pods'
fi

if role_only test-role-2 apps statefulsets update; then
    pass 'Role test-role-2 grants only update on StatefulSets in database'
else
    fail 'Role test-role-2 grants only update on StatefulSets in database'
fi

# Task 3 is truncated in task.txt. Its exact binding requirement must be
# supplied before this validator can certify the complete exercise.
fail 'Task 3 cannot be evaluated: the RoleBinding requirement in task.txt is truncated'
finish
