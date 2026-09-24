#!/usr/bin/env bash
set -Eeuo pipefail

# Check live API objects and runtime enforcement; never modify candidate policies.
passed=0 failed=0
probe_ns= peer_ns= target=
k() { kubectl --request-timeout=30s "$@"; }
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
cleanup() {
    if [[ -n "$target" ]]; then
        k -n default delete pod "$target" --ignore-not-found --wait=true --timeout=60s >/dev/null || fail 'Temporary target cleanup'
    fi
    if [[ -n "$probe_ns" ]]; then
        k delete namespace "$probe_ns" --ignore-not-found --wait=true --timeout=60s >/dev/null || fail 'Temporary namespace cleanup'
    fi
    if [[ -n "$peer_ns" ]]; then
        k delete namespace "$peer_ns" --ignore-not-found --wait=true --timeout=60s >/dev/null || fail 'Temporary peer namespace cleanup'
    fi
}
finish() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then fail 'Validation could not complete (see command error above)'; fi
    cleanup
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap finish EXIT
trap 'exit 1' INT TERM
command -v kubectl >/dev/null || { fail 'kubectl is available'; exit 1; }

if k -n default get networkpolicy all-deny >/dev/null 2>&1; then
    pass 'NetworkPolicy all-deny exists in default'
    shape=$(k -n default get networkpolicy all-deny -o go-template='{{if or .spec.podSelector.matchLabels .spec.podSelector.matchExpressions}}scoped{{else}}all{{end}} {{range .spec.policyTypes}}{{.}} {{end}}|{{if .spec.ingress}}{{len .spec.ingress}}{{else}}0{{end}}|{{if .spec.egress}}{{len .spec.egress}}{{else}}0{{end}}')
    if [[ "$shape" == all\ * && "$shape" == *Ingress* && "$shape" == *Egress* && "$shape" == *'|0|0' ]]; then
        pass 'all-deny selects every pod and denies both directions on every protocol and port'
    else
        fail 'all-deny must select every pod, isolate ingress and egress, and grant no traffic'
    fi
else
    fail 'NetworkPolicy all-deny exists in default'
fi

# Policies are additive. Find any grants affecting current pods, including
# grants on ports not exercised by the runtime HTTP tests.
policy_names=$(k -n default get networkpolicies -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
conflicts=0
while IFS= read -r policy; do
    [[ -n "$policy" ]] || continue
    grants=$(k -n default get networkpolicy "$policy" -o go-template='{{$spec := .spec}}{{range .spec.policyTypes}}{{if eq . "Ingress"}}{{if $spec.ingress}}yes{{end}}{{else if eq . "Egress"}}{{if $spec.egress}}yes{{end}}{{end}}{{end}}')
    [[ "$grants" == *yes* ]] || continue
    selector=$(k -n default get networkpolicy "$policy" -o go-template='{{range $k,$v := .spec.podSelector.matchLabels}}{{$k}}={{$v}},{{end}}{{range .spec.podSelector.matchExpressions}}{{if eq .operator "Exists"}}{{.key}}{{else if eq .operator "DoesNotExist"}}!{{.key}}{{else}}{{.key}} {{if eq .operator "In"}}in{{else}}notin{{end}} ({{range $i,$v := .values}}{{if $i}},{{end}}{{$v}}{{end}}){{end}},{{end}}')
    selector=${selector%,}
    matches=$(k -n default get pods -l "$selector" -o name)
    if [[ -n "$matches" ]]; then
        fail "Policy $policy grants traffic to selected pods (policies are additive)"
        conflicts=$((conflicts + 1))
    fi
done <<< "$policy_names"
(( conflicts != 0 )) || pass 'No other policy grants traffic to existing pods'

# Unique resources ensure validation does not depend on candidate workload names.
created=$(k create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  generateName: cks-netpol-check-
YAML
)
probe_ns=$created
peer_ns=$(k create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  generateName: cks-netpol-peer-
YAML
)
make_pod() {
    local namespace=$1
    k -n "$namespace" create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  generateName: netpol-probe-
spec:
  automountServiceAccountToken: false
  containers:
  - name: probe
    image: busybox:1.37
    command: [sh, -c, 'mkdir -p /tmp/www; echo ready > /tmp/www/index.html; exec httpd -f -p 8080 -h /tmp/www']
    readinessProbe:
      exec:
        command: [sh, -c, 'wget -q -T 2 -O /dev/null http://127.0.0.1:8080']
      periodSeconds: 2
YAML
}
source=$(make_pod "$probe_ns")
peer=$(make_pod "$peer_ns")
target=$(make_pod default)
k -n "$probe_ns" wait --for=condition=Ready pod --all --timeout=120s >/dev/null
k -n "$peer_ns" wait --for=condition=Ready "pod/$peer" --timeout=120s >/dev/null
k -n default wait --for=condition=Ready "pod/$target" --timeout=120s >/dev/null
pod_url() {
    local ip
    ip=$(k -n "$1" get pod "$2" -o jsonpath='{.status.podIP}')
    [[ -n "$ip" ]]
    if [[ "$ip" == *:* ]]; then ip="[$ip]"; fi
    printf 'http://%s:8080' "$ip"
}
source_url=$(pod_url "$probe_ns" "$source")
peer_url=$(pod_url "$peer_ns" "$peer")
target_url=$(pod_url default "$target")
k -n "$probe_ns" exec "$source" -- wget -q -T 3 -O /dev/null "$peer_url"
k -n "$peer_ns" exec "$peer" -- wget -q -T 3 -O /dev/null "$source_url"
k -n default exec "$target" -- wget -q -T 3 -O /dev/null http://127.0.0.1:8080
k -n default exec "$target" -- wget -q -T 3 -O /dev/null "$target_url"
pass 'Probe HTTP servers and unrestricted cross-namespace connectivity work'
# Give the CNI time to attach policies to the new target.
sleep 5
check_denied() {
    local namespace=$1 pod=$2 url=$3 description=$4 result
    for attempt in 1 2 3; do
        # Return a marker after wget so an exec/API failure is never counted as denial.
        result=$(k -n "$namespace" exec "$pod" -- sh -c 'if wget -q -T 3 -O /dev/null "$1"; then echo ALLOWED; else echo BLOCKED; fi' sh "$url")
        if [[ "$result" != BLOCKED ]]; then fail "$description"; return; fi
    done
    pass "$description"
}
check_denied "$probe_ns" "$source" "$target_url" 'Ingress from another namespace is blocked'
check_denied default "$target" "$source_url" 'Egress to another namespace is blocked'
