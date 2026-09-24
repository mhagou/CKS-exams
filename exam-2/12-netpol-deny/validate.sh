#!/usr/bin/env bash
set -Eeuo pipefail

passed=0
failed=0
probe_ns=''
probe_name="cks-netpol-check-$$-$RANDOM"
created_pods=()
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
  if (( failed == 0 )); then exit 0; else exit 1; fi
}
cleanup() {
  local entry
  for entry in "${created_pods[@]}"; do
    kubectl -n "${entry%%/*}" delete pod "${entry#*/}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  done
  if [[ -n "$probe_ns" ]]; then
    kubectl delete namespace "$probe_ns" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  fi
}
unexpected() { trap - ERR; fail 'Validation could not complete (see command error above).'; finish; exit 1; }
trap cleanup EXIT
trap unexpected ERR
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; exit 1; }

if kubectl -n moon get networkpolicy np-restriction >/dev/null 2>&1; then
  types=$(kubectl -n moon get networkpolicy np-restriction -o jsonpath='{.spec.policyTypes[*]}')
  if [[ " $types " == *' Ingress '* ]]; then
    pass 'np-restriction governs ingress traffic'
  else
    fail 'np-restriction must govern ingress traffic'
  fi
  # Convert the API selector to kubectl's selector syntax, including expressions.
  selector=$(kubectl -n moon get networkpolicy np-restriction -o go-template='{{range $k,$v := .spec.podSelector.matchLabels}}{{printf "%s=%s," $k $v}}{{end}}{{range .spec.podSelector.matchExpressions}}{{if eq .operator "In"}}{{.key}} in ({{range $i,$v := .values}}{{if $i}},{{end}}{{$v}}{{end}}),{{else if eq .operator "NotIn"}}{{.key}} notin ({{range $i,$v := .values}}{{if $i}},{{end}}{{$v}}{{end}}),{{else if eq .operator "Exists"}}{{.key}},{{else if eq .operator "DoesNotExist"}}!{{.key}},{{end}}{{end}}')
  selector=${selector%,}
  selected=$(kubectl -n moon get pods -l "$selector" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  if [[ $'\n'"$selected"$'\n' == *$'\nnginx-pod\n'* ]]; then
    pass 'np-restriction exists in moon and selects nginx-pod'
  else
    fail 'np-restriction must select nginx-pod in moon'
  fi
else
  fail 'np-restriction exists in moon'
fi
if ! kubectl -n moon wait --for=condition=Ready pod/nginx-pod --timeout=30s; then
  fail 'nginx-pod is ready for connectivity tests'; finish; exit 1
fi
ip=$(kubectl -n moon get pod nginx-pod -o jsonpath='{.status.podIP}')
[[ -n "$ip" ]]
case "$ip" in *:*) ip="[$ip]" ;; esac
# A fresh namespace ensures that "any namespace" is exercised.
probe_ns=$(kubectl create namespace "$probe_name" -o jsonpath='{.metadata.name}')
kubectl -n "$probe_ns" run control --image=nginx:stable-alpine --restart=Never >/dev/null
kubectl -n "$probe_ns" wait --for=condition=Ready pod/control --timeout=180s >/dev/null
control_ip=$(kubectl -n "$probe_ns" get pod control -o jsonpath='{.status.podIP}')
case "$control_ip" in *:*) control_ip="[$control_ip]" ;; esac

# Each probe reports transport results separately from kubectl/exec errors.
probe() {
  kubectl -n "$1" exec "$2" -- sh -c '
    if wget -q -T 3 -O /dev/null "$1"; then echo ALLOW; else echo DENY; fi
  ' sh "http://$3:80/" 2>/dev/null
}
for ns in hello moon "$probe_ns"; do
  for kind in ordinary backend unlabeled; do
    name="$probe_name-$kind"
    created_pods+=("$ns/$name")
    labels="app=$kind"
    # An absent app label must not bypass the restriction. Explicit labels
    # also avoid kubectl run's default run label matching a candidate rule.
    if [[ "$kind" == unlabeled ]]; then labels=''; fi
    kubectl -n "$ns" run "$name" --image=busybox:1.37 --restart=Never \
      --labels="$labels" --command -- sleep 900 >/dev/null
    kubectl -n "$ns" wait --for=condition=Ready "pod/$name" --timeout=180s >/dev/null
    expected=DENY
    if [[ "$ns" == hello || "$kind" == backend ]]; then expected=ALLOW; fi
    description="$kind pod in $ns: expected $expected to nginx-pod TCP/80"
    # Check client health/egress against an independent listener first.
    healthy=false
    for attempt in 1 2 3 4 5; do
      if result=$(probe "$ns" "$name" "$control_ip") && [[ "$result" == ALLOW ]]; then
        healthy=true; break
      fi
      sleep 2
    done
    if ! "$healthy"; then
      fail "$description (control connection failed; cannot trust this probe)"
      continue
    fi
    # Give policy propagation time, then require three consecutive results.
    matched=0
    for attempt in 1 2 3 4 5 6; do
      if result=$(probe "$ns" "$name" "$ip") && [[ "$result" == "$expected" ]]; then
        matched=$((matched + 1))
      else
        matched=0
      fi
      if (( matched == 3 )); then break; fi
      sleep 2
    done
    if (( matched == 3 )) && [[ "$expected" == DENY ]]; then
      # Recheck the very same listener through an allowed source, so a
      # crashed/unreachable server cannot masquerade as policy enforcement.
      if ! result=$(probe hello "$probe_name-backend" "$ip") || [[ "$result" != ALLOW ]]; then
        fail "$description (allowed-source target health check failed)"
        continue
      fi
    fi
    if (( matched == 3 )); then pass "$description"; else fail "$description"; fi
  done
done
finish
