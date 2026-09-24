#!/usr/bin/env bash
set -Eeuo pipefail
# Rule fields are deliberately word-split below; never expand RBAC wildcards
# against files in the directory from which the validator is launched.
set -f

passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
command -v kubectl >/dev/null || { fail 'kubectl is required'; finish; }
k() { kubectl --request-timeout=30s "$@"; }

if k -n seminar get serviceaccount seminar-sa -o name >/dev/null; then
    pass 'ServiceAccount seminar/seminar-sa exists'
else
    fail 'ServiceAccount seminar/seminar-sa exists'
fi

# Inspect live rules, accepting ordering, duplicate rules, and split rules.
# Flatten each rule into four fields without an additional JSON dependency.
template='{{range .rules}}{{range .apiGroups}}{{if eq . ""}}@core{{else}}{{.}}{{end}} {{end}}|{{range .resources}}{{.}} {{end}}|{{range .verbs}}{{.}} {{end}}|{{range .resourceNames}}{{.}} {{end}}|{{range .nonResourceURLs}}{{.}} {{end}}{{"\n"}}{{end}}'
if rules=$(k -n seminar get role k8s-seminar -o go-template="$template"); then
    valid=true
    declare -A covered=()
    while IFS='|' read -r groups resources verbs names urls; do
        [[ -n "$groups$resources$verbs$names$urls" ]] || continue
        [[ -z "$urls" ]] || valid=false
        for group in $groups; do
            case "$group" in @core|apps) ;; *) valid=false ;; esac
        done
        for resource in $resources; do
            case "$resource" in pods|deployments) ;; *) valid=false ;; esac
        done
        for verb in $verbs; do
            case "$verb" in create|update) ;; *) valid=false ;; esac
        done
        # Named-resource restrictions do not grant the full requested access.
        # Redundant restricted rules are fine if unrestricted rules cover it.
        if [[ -z "$names" ]]; then
            for group in $groups; do
                for resource in $resources; do
                    if [[ "$group/$resource" == '@core/pods' || "$group/$resource" == apps/deployments ]]; then
                        for verb in $verbs; do covered["$resource/$verb"]=1; done
                    fi
                done
            done
        fi
    done <<< "$rules"
    for resource in pods deployments; do
        for verb in create update; do
            [[ "${covered[$resource/$verb]:-0}" == 1 ]] || valid=false
        done
    done
    if "$valid"; then
        pass 'Role seminar/k8s-seminar grants only create and update on pods and deployments'
    else
        fail 'Role seminar/k8s-seminar must grant only create and update on pods and deployments'
    fi
else
    fail 'Role seminar/k8s-seminar exists and has the required permissions'
fi

# An omitted ServiceAccount subject namespace inherits the RoleBinding namespace.
binding_template='{{.roleRef.apiGroup}}/{{.roleRef.kind}}/{{.roleRef.name}}{{"\n"}}{{range .subjects}}{{if and (eq .kind "ServiceAccount") (eq .name "seminar-sa") (or (not .namespace) (eq .namespace "seminar"))}}matched{{"\n"}}{{end}}{{end}}'
if binding=$(k -n seminar get rolebinding k8s-seminar-bind -o go-template="$binding_template") &&
   [[ "${binding%%$'\n'*}" == rbac.authorization.k8s.io/Role/k8s-seminar ]] &&
   [[ "$binding" == *$'\nmatched'* ]]; then
    pass 'RoleBinding seminar/k8s-seminar-bind binds the required Role to seminar-sa'
else
    fail 'RoleBinding seminar/k8s-seminar-bind must bind the required Role to seminar-sa'
fi

# Authorization checks require impersonation privileges (normally cluster admin).
# Include the groups of a real ServiceAccount authentication context.
for resource in pods deployments.apps; do
    for verb in create update; do
        if answer=$(k auth can-i "$verb" "$resource" -n seminar \
            --as=system:serviceaccount:seminar:seminar-sa \
            --as-group=system:serviceaccounts \
            --as-group=system:serviceaccounts:seminar \
            --as-group=system:authenticated) && [[ "$answer" == yes ]]; then
            pass "seminar-sa can $verb $resource in seminar"
        else
            fail "seminar-sa can $verb $resource in seminar (also check validator impersonation privileges)"
        fi
    done
done

finish
