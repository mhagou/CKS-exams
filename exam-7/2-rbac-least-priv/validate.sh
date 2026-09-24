#!/usr/bin/env bash
set -Eeuo pipefail

passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
k() { kubectl --request-timeout=30s "$@"; }
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is required'; finish
fi
if ! k get namespace dev-z >/dev/null; then
    fail 'Namespace dev-z exists and is accessible'; finish
fi
pass 'Namespace dev-z exists'

# Real authorization checks accept permissions supplied by any valid binding.
for permission in 'get pods' 'list pods' 'watch pods' 'get configmaps' 'list configmaps'; do
    read -r verb resource <<< "$permission"
    if answer=$(k auth can-i "$verb" "$resource" -n dev-z --as=jacob --as-group=system:authenticated); then
        if [[ "$answer" == yes ]]; then
            pass "Jacob can $verb $resource in dev-z"
        else
            fail "Jacob can $verb $resource in dev-z (unexpected response)"
        fi
    else
        fail "Jacob can $verb $resource in dev-z"
    fi
done

# Inspect effective rules as well as positive probes: fixed negative probes
# alone would miss named-resource grants, subresources, or custom verbs.
# This review is a non-persistent authorization API request, not a repair.
template='{{.status.incomplete}}{{"\n"}}{{range .status.resourceRules}}{{$rule := .}}{{range .apiGroups}}{{$group := .}}{{range $rule.resources}}{{$resource := .}}{{range $rule.verbs}}{{printf "%s|%s|%s\n" $group $resource .}}{{end}}{{end}}{{end}}{{end}}'
if ! review=$(k --as=jacob --as-group=system:authenticated create -f - -o "go-template=$template" <<'YAML'
apiVersion: authorization.k8s.io/v1
kind: SelfSubjectRulesReview
spec:
  namespace: dev-z
YAML
); then
    fail 'Effective permissions can be inspected'; finish
fi
if [[ ${review%%$'\n'*} != false ]]; then
    fail 'Effective permissions review is complete'; finish
fi

# Default authenticated-user grants include cluster-scoped self-review APIs.
# They are outside this namespace task. Discover scope rather than assuming
# a fixed list of Kubernetes APIs; unknown or wildcard grants fail closed.
if ! cluster_resources=$(k api-resources --namespaced=false -o name); then
    fail 'API resource scopes can be discovered'; finish
fi
declare -A cluster_scoped=()
while IFS= read -r resource; do
    [[ -z "$resource" ]] || cluster_scoped["$resource"]=1
done <<< "$cluster_resources"

secrets_ok=true
only_required=true
while IFS='|' read -r group resource verb; do
    [[ -n "$resource" ]] || continue
    base=${resource%%/*}
    key=$base
    [[ -z "$group" ]] || key="$base.$group"
    if [[ -n ${cluster_scoped[$key]:-} ]]; then
        continue
    fi
    case "$group|$resource|$verb" in
        '|pods|get'|'|pods|list'|'|pods|watch'|'|configmaps|get'|'|configmaps|list') continue ;;
    esac
    only_required=false
    printf '  Excess grant: apiGroup=%s resource=%s verb=%s\n' "${group:-core}" "$resource" "$verb"
    if [[ "$group" == '' || "$group" == '*' ]]; then
        if [[ "$base" == secrets || "$base" == '*' ]]; then
            secrets_ok=false
        fi
    fi
done <<< "${review#*$'\n'}"

if "$secrets_ok"; then
    pass 'Jacob has no access to secrets in dev-z'
else
    fail 'Jacob has no access to secrets in dev-z'
fi
if "$only_required"; then
    pass 'Jacob has only the requested namespace resource permissions'
else
    fail 'Jacob has only the requested namespace resource permissions'
fi
finish
