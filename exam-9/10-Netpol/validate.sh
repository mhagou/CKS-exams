#!/usr/bin/env bash
set -Eeuo pipefail
passed=0
failed=0
probe_namespace=''
target_pods=()
k() { kubectl --request-timeout=30s "$@"; }
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( failed == 0 ))
}
cleanup() {
    local pod
    for pod in "${target_pods[@]}"; do
        if ! k -n testing delete pod "$pod" --ignore-not-found --wait=false >/dev/null; then
            fail "Cleanup of temporary Pod $pod"
        fi
    done
    if [[ -n "$probe_namespace" ]]; then
        if ! k delete namespace "$probe_namespace" --ignore-not-found --wait=false >/dev/null; then
            fail 'Cleanup of temporary probe namespace'
        fi
    fi
}
on_exit() {
    local status=$?
    trap - EXIT
    if (( status != 0 )); then fail 'Validation could not complete (see error above)'; fi
    cleanup
    finish
}
trap on_exit EXIT
trap 'exit 1' INT TERM
command -v kubectl >/dev/null || { fail 'kubectl is available'; exit 0; }
if ! k -n testing get networkpolicy deny-all >/dev/null; then
    fail 'NetworkPolicy testing/deny-all exists'
    exit 0
fi
pass 'NetworkPolicy testing/deny-all exists'

# Query API objects, not a candidate manifest. Omitted and empty rule lists
# are equivalent, and policyTypes ordering is immaterial.
shape=$(k -n testing get networkpolicy deny-all -o go-template='{{if or .spec.podSelector.matchLabels .spec.podSelector.matchExpressions}}subset{{else}}all{{end}} {{range .spec.policyTypes}}{{.}} {{end}}')
if [[ "$shape" == all\ * ]]; then pass 'Policy selects all Pods in testing'; else fail 'Policy selects all Pods in testing'; fi
for direction in Ingress Egress; do
    if [[ " $shape " == *" $direction "* ]]; then pass "Policy isolates $direction"; else fail "Policy isolates $direction"; fi
done
rules=$(k -n testing get networkpolicy deny-all -o go-template='{{if or .spec.ingress .spec.egress}}allow{{else}}deny{{end}}')
if [[ "$rules" == deny ]]; then pass 'Policy grants no ingress or egress'; else fail 'Policy grants no ingress or egress'; fi
# Kubernetes policies are additive: a second allow policy defeats a blanket
# namespace denial even if deny-all itself is correct.
grants=$(k -n testing get networkpolicies -o go-template='{{range .items}}{{if or .spec.ingress .spec.egress}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
if [[ -z "$grants" ]]; then pass 'No namespace policy adds traffic allowances'; else fail "Namespace policies contain traffic allowances: $grants"; fi

# Use Pod IPs so blocked DNS cannot masquerade as successful isolation.
# Images can be overridden for a playground with its own registry mirror.
image=${PROBE_IMAGE:-busybox:1.36.1}
probe_namespace=$(k create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  generateName: cks-netpol-check-
YAML
)
create_probe() {
    local namespace=$1
    k -n "$namespace" create -f - -o jsonpath='{.metadata.name}' <<YAML
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-netpol-probe-
spec:
  automountServiceAccountToken: false
  terminationGracePeriodSeconds: 0
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: "$image"
    command: [sh, -c, 'mkdir -p /tmp/www; echo cks-netpol-ok > /tmp/www/index.html; exec httpd -f -p 8080 -h /tmp/www']
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
    readinessProbe:
      exec:
        command: [sh, -c, 'wget -q -T 2 -O - http://127.0.0.1:8080 | grep -q cks-netpol-ok']
      periodSeconds: 2
    resources:
      requests:
        cpu: 5m
        memory: 8Mi
      limits:
        memory: 64Mi
YAML
}
a=$(create_probe testing); target_pods+=("$a")
b=$(create_probe testing); target_pods+=("$b")
c=$(create_probe "$probe_namespace")
d=$(create_probe "$probe_namespace")
for pod in "$a" "$b"; do k -n testing wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null; done
for pod in "$c" "$d"; do k -n "$probe_namespace" wait --for=condition=Ready "pod/$pod" --timeout=120s >/dev/null; done
ip_a=$(k -n testing get pod "$a" -o jsonpath='{.status.podIP}')
ip_b=$(k -n testing get pod "$b" -o jsonpath='{.status.podIP}')
ip_d=$(k -n "$probe_namespace" get pod "$d" -o jsonpath='{.status.podIP}')
url() { if [[ "$1" == *:* ]]; then printf 'http://[%s]:8080' "$1"; else printf 'http://%s:8080' "$1"; fi; }
allowed() {
    k -n "$probe_namespace" exec "$c" -- sh -c 'wget -q -T 3 -O - "$1" | grep -q cks-netpol-ok' sh "$(url "$ip_d")"
}
if allowed; then
    pass 'Control connection between unrestricted Pods works'
else
    fail 'Control connection failed; denial tests would be inconclusive'
    exit 0
fi
denied() {
    local namespace=$1 pod=$2 ip=$3 description=$4
    # Return success only after executing a healthy local probe and observing
    # repeated failed remote connections. An exec failure cannot count as PASS.
    if k -n "$namespace" exec "$pod" -- sh -c '
        wget -q -T 2 -O - http://127.0.0.1:8080 | grep -q cks-netpol-ok || exit 2
        for attempt in 1 2 3; do
            if wget -q -T 3 -O /dev/null "$1"; then exit 3; fi
        done
    ' sh "$(url "$ip")"; then pass "$description"; else fail "$description"; fi
}
# Allow time for the CNI to apply policy to newly created endpoints.
sleep 5
denied "$probe_namespace" "$c" "$ip_a" 'Ingress from outside testing is denied (TCP 8080)'
denied testing "$a" "$ip_d" 'Egress from testing is denied (TCP 8080)'
denied testing "$a" "$ip_b" 'Traffic between testing Pods is denied (TCP 8080)'
if allowed; then pass 'Control connection remains healthy after denial tests'; else fail 'Control connection remains healthy after denial tests'; fi
# API checks cover all ports/protocols; runtime checks sample TCP enforcement.
