#!/usr/bin/env bash
set -Eeuo pipefail
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if ((failed == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
  ((failed == 0))
}
for command in kubectl jq; do
  if ! command -v "$command" >/dev/null; then fail "Required tool is available: $command"; finish; exit 1; fi
done
if ! constraint=$(kubectl get k8srequiredlabels.constraints.gatekeeper.sh require-env-label -o json 2>&1); then
  fail 'K8sRequiredLabels constraint require-env-label exists'
  printf '%s\n' "$constraint" >&2
  finish
  exit 1
fi
pass 'K8sRequiredLabels constraint require-env-label exists'
if jq -e '(.spec.enforcementAction // "deny") == "deny" and
  (.spec.parameters.labels | unique) == ["env"]' <<<"$constraint" >/dev/null; then
  pass 'Constraint enforces presence of the env key'
else
  fail 'Constraint enforces presence of the env key'
fi
# All objects missing env must be in scope. Selectors that only filter out
# objects already carrying env are equivalent and are accepted.
if jq -e '
  def covers_missing_env:
    (.matchLabels // {} | length) == 0 and
    all(.matchExpressions[]?;
      .key == "env" and (.operator == "DoesNotExist" or .operator == "NotIn"));
  (.spec.match // {}) as $m |
  (($m.scope // "*") != "Namespaced") and
  (($m.name // "*") == "*") and
  (($m.namespaces // []) as $n | ($n | length) == 0 or ($n | index("*") != null)) and
  (($m.excludedNamespaces // [] | length) == 0) and
  (($m.labelSelector // {}) | covers_missing_env) and
  (($m.namespaceSelector // {}) | covers_missing_env) and
  (($m.kinds // []) as $k | ($k | length) == 0 or
    any($k[]; any(.apiGroups[]?; . == "" or . == "*") and
                any(.kinds[]?; . == "Namespace" or . == "*")))
' <<<"$constraint" >/dev/null; then
  pass 'Constraint covers all newly created Namespaces missing env'
else
  fail 'Constraint covers all newly created Namespaces missing env'
fi
# Server-side dry runs exercise the admission webhook without creating resources.
# Retry each probe to accommodate Gatekeeper reconciliation after candidate edits.
probe() {
  local labels=$1 expectation=$2 description=$3 output='' admitted=false name manifest
  name="cks-opa-check-$(date +%s)-$RANDOM"
  manifest=$(jq -nc --arg name "$name" --argjson labels "$labels" \
    '{apiVersion:"v1",kind:"Namespace",metadata:{name:$name,labels:$labels}}')
  for ((attempt=0; attempt<10; attempt++)); do
    admitted=false
    if output=$(kubectl create --dry-run=server --request-timeout=20s -f - -o json <<<"$manifest" 2>&1); then admitted=true; fi
    if [[ $expectation == allow && $admitted == true ]]; then pass "$description"; return; fi
    if [[ $expectation == deny && $admitted == false && $output == *'[require-env-label]'* && $output == *'denied the request'* ]]; then
      pass "$description"; return
    fi
    sleep 2
  done
  fail "$description"
  printf '  Admission response: %s\n' "$output" >&2
}
probe '{}' deny 'Namespace without labels is denied by require-env-label'
probe '{"team":"cks"}' deny 'Namespace with unrelated labels but no env is denied'
probe '{"env":"test"}' allow 'Namespace with env=test is admitted'
probe '{"env":"arbitrary-value-123"}' allow 'Namespace with another env value is admitted'
probe '{"env":""}' allow 'Namespace with an empty env value is admitted'
finish
