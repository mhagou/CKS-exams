#!/usr/bin/env bash
set -Eeuo pipefail

# Scope inferred from solution.txt because task.txt contains only a title:
# app-reader reads pods, services and deployments in rbac-minimize only.
# Authorization reviews are non-persistent API requests; no resources are changed.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; }
k() { kubectl --request-timeout=30s "$@"; }
identity=(--as=system:serviceaccount:rbac-minimize:app-reader
    --as-group=system:serviceaccounts
    --as-group=system:serviceaccounts:rbac-minimize
    --as-group=system:authenticated)
if k -n rbac-minimize get serviceaccount app-reader -o name >/dev/null 2>&1; then
    pass 'Exercise ServiceAccount exists'
else
    fail 'Exercise ServiceAccount exists'
    finish
fi

# Require the requested namespaced Role/RoleBinding mechanism, allowing any names
# and bindings to either the identity itself or one of its standard groups.
binding_template='{{range .items}}{{$r := .roleRef}}{{range .subjects}}{{printf "%s|%s|%s|%s|%s\n" $r.kind $r.name .kind .name .namespace}}{{end}}{{end}}'
if bindings=$(k -n rbac-minimize get rolebindings -o go-template="$binding_template"); then
    found=false
    while IFS='|' read -r kind role subject name namespace; do
        [[ $kind == Role ]] || continue
        matches=false
        case "$subject:$name" in
            ServiceAccount:app-reader)
                [[ $namespace == rbac-minimize || $namespace == '<no value>' || -z $namespace ]] && matches=true ;;
            User:system:serviceaccount:rbac-minimize:app-reader|Group:system:serviceaccounts|Group:system:serviceaccounts:rbac-minimize|Group:system:authenticated)
                matches=true ;;
        esac
        if $matches && k -n rbac-minimize get role "$role" -o name >/dev/null 2>&1; then
            found=true
        fi
    done <<< "$bindings"
    if $found; then pass 'ServiceAccount is bound to a namespaced Role'; else fail 'ServiceAccount is bound to a namespaced Role'; fi
else
    fail 'RoleBindings can be inspected'
fi

for resource in pods services deployments.apps; do
    for verb in get list watch; do
        if answer=$(k "${identity[@]}" auth can-i "$verb" "$resource" -n rbac-minimize) && [[ $answer == yes ]]; then
            pass "$verb $resource in rbac-minimize"
        else
            fail "$verb $resource in rbac-minimize"
        fi
    done
done

# SelfSubjectRulesReview reports effective, additive permissions, including
# grants inherited through groups and ClusterRoleBindings. Expand every rule
# to catch wildcards, subresources, writes, secrets and other excess access.
# Standard self-introspection rights are normal for authenticated identities.
rule_template='{{if .status.incomplete}}INCOMPLETE{{"\n"}}{{end}}{{range .status.resourceRules}}{{$rule := .}}{{range .apiGroups}}{{$group := .}}{{range $rule.resources}}{{$resource := .}}{{range $rule.verbs}}{{printf "%s|%s|%s\n" $group $resource .}}{{end}}{{end}}{{end}}{{end}}'
if namespaces=$(k get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); then
    # Also inspect a nonexistent namespace to expose cluster-wide grants even
    # in unusually small clusters. No namespace is created.
    namespaces+=$'\ncks-rbac-scope-probe'
    scope_ok=true
    while IFS= read -r ns; do
        [[ -n $ns ]] || continue
        if ! rules=$(k "${identity[@]}" create -f - -o go-template="$rule_template" <<REVIEW
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectRulesReview
spec:
  namespace: $ns
REVIEW
        ); then
            fail "Effective permissions can be reviewed in $ns"
            scope_ok=false
            continue
        fi
        while IFS='|' read -r group resource verb; do
            [[ -n $group || -n $resource || -n $verb ]] || continue
            if [[ $group == INCOMPLETE ]]; then
                fail "Authorization server returned incomplete rules for $ns"
                scope_ok=false
                continue
            fi
            case "$group/$resource/$verb" in
                authorization.k8s.io/selfsubjectaccessreviews/create|authorization.k8s.io/selfsubjectrulesreviews/create|authentication.k8s.io/selfsubjectreviews/create) continue ;;
            esac
            if [[ $ns == rbac-minimize && $verb =~ ^(get|list|watch)$ ]]; then
                case "$group/$resource" in /pods|/services|apps/deployments) continue ;; esac
            fi
            fail "Excess permission in $ns: $verb ${group:-core}/$resource"
            scope_ok=false
        done <<< "$rules"
    done <<< "$namespaces"
    if $scope_ok; then pass 'Effective resource access is limited to the intended read scope'; fi
else
    fail 'Namespaces can be enumerated for permission scope checks'
fi
finish
