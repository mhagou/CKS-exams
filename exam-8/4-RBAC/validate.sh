#!/usr/bin/env bash
set -Eeuo pipefail
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if ((failed == 0)); then
    echo 'RESULT: SUCCESS'
    exit 0
  else
    echo 'RESULT: FAILED'
    exit 1
  fi
}
trap 'fail "Unexpected validation error at line $LINENO"; finish; exit 1' ERR
command -v kubectl >/dev/null || { fail 'kubectl is required'; finish; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }
bot=(--as=system:serviceaccount:ci-cd:ci-bot --as-group=system:serviceaccounts --as-group=system:serviceaccounts:ci-cd --as-group=system:authenticated)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if k get serviceaccount ci-bot -n ci-cd >/dev/null; then
  pass 'ci-cd/ci-bot exists'
else
  fail 'ci-cd/ci-bot exists'
fi
for resource in pods services configmaps deployments.apps replicasets.apps; do
  for verb in get list watch create update delete; do
    if answer=$(k "${bot[@]}" auth can-i "$verb" "$resource" -n ci-cd 2>"$work/error") && [[ $answer == yes ]]; then
      pass "Retains $verb $resource in ci-cd"
    else
      fail "Retains $verb $resource in ci-cd"
      cat "$work/error" >&2
    fi
  done
done
for resource in rolebindings.rbac.authorization.k8s.io clusterrolebindings.rbac.authorization.k8s.io; do
  for verb in get list watch; do
    scope=(-n ci-cd)
    [[ $resource != clusterrolebindings.* ]] || scope=()
    if answer=$(k "${bot[@]}" auth can-i "$verb" "$resource" "${scope[@]}" 2>"$work/error") && [[ $answer == yes ]]; then
      pass "Retains $verb $resource"
    else
      fail "Retains $verb $resource"
      cat "$work/error" >&2
    fi
  done
done

# Server dry runs exercise both ordinary authorization and RBAC's bind check.
# A permission to create bindings is acceptable if protected roles cannot be bound.
# Only Forbidden counts as a denial; connectivity/schema errors must fail validation.
denied() {
  local description=$1
  shift
  if k "${bot[@]}" "$@" >"$work/output" 2>"$work/error"; then
    fail "$description (request was allowed)"
  elif grep -q '(Forbidden)' "$work/error"; then
    pass "$description"
  else
    fail "$description (test could not complete)"
    cat "$work/error" >&2
  fi
}
k get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' >"$work/namespaces"
k get clusterroles -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' >"$work/clusterroles"
k get roles -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' >"$work/roles"
probe="ci-bot-validation-$(date +%s)-$$"
protected=0
while read -r role; do
  [[ $role == *admin* ]] || continue
  protected=$((protected + 1))
  denied "Cannot create a cluster binding to $role" create clusterrolebinding "$probe" --clusterrole="$role" --serviceaccount=ci-cd:ci-bot --dry-run=server -o name
  while read -r ns; do
    denied "Cannot bind ClusterRole $role in $ns" create rolebinding "$probe" -n "$ns" --clusterrole="$role" --serviceaccount=ci-cd:ci-bot --dry-run=server -o name
  done <"$work/namespaces"
done <"$work/clusterroles"
while read -r ns role; do
  [[ $role == *admin* ]] || continue
  protected=$((protected + 1))
  denied "Cannot bind Role $role in $ns" create rolebinding "$probe" -n "$ns" --role="$role" --serviceaccount=ci-cd:ci-bot --dry-run=server -o name
done <"$work/roles"
if ((protected == 0)); then fail 'No admin-named roles were available to test'; fi

# Existing bindings matter too: roleRef cannot change, but subjects can.
# Test both PATCH and UPDATE to cover independently granted verbs.
subjects='{"subjects":[{"kind":"ServiceAccount","name":"ci-bot","namespace":"ci-cd"}]}'
for kind in clusterrolebindings rolebindings; do
  k get "$kind" -A -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.roleRef.name}{" "}{.metadata.namespace}{"\n"}{end}' >"$work/bindings"
  while read -r name role ns; do
    [[ $role == *admin* ]] || continue
    scope=()
    [[ -z $ns ]] || scope=(-n "$ns")
    denied "Cannot patch $kind/$name ${ns:+in $ns}" patch "$kind" "$name" "${scope[@]}" --type=merge -p "$subjects" --dry-run=server -o name
    k get "$kind" "$name" "${scope[@]}" -o json >"$work/original.json"
    k patch --local -f "$work/original.json" --type=merge -p "$subjects" -o json >"$work/updated.json"
    denied "Cannot update $kind/$name ${ns:+in $ns}" replace "${scope[@]}" -f "$work/updated.json" --dry-run=server -o name
  done <"$work/bindings"
done
finish
