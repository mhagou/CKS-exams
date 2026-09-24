#!/usr/bin/env bash
set -Eeuo pipefail
K=(kubectl --request-timeout=30s)
passed=0 failed=0
created=()
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    cleanup
    trap - EXIT
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
cleanup() {
    local item
    for item in "${created[@]}"; do
        if ! "${K[@]}" -n "${item%%/*}" delete pod "${item#*/}" --ignore-not-found --wait=true --timeout=60s >/dev/null; then
            fail "Could not clean up temporary pod $item"
        fi
    done
    created=()
}
trap cleanup EXIT
trap 'fail "Unexpected validation error at line $LINENO"; finish' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; }
if "${K[@]}" get crd ciliumnetworkpolicies.cilium.io >/dev/null 2>&1 &&
   [[ -n $("${K[@]}" -n kube-system get pods -l k8s-app=cilium -o name) ]] &&
   "${K[@]}" -n kube-system wait pod -l k8s-app=cilium --for=condition=Ready --timeout=60s >/dev/null 2>&1; then
    pass 'Cilium is present and ready'
else
    fail 'Cilium is present and ready'; finish
fi
for ns in app data manage; do
    if "${K[@]}" -n "$ns" wait pod "${ns}1" --for=condition=Ready --timeout=60s >/dev/null 2>&1 &&
       [[ $("${K[@]}" -n "$ns" get pod "${ns}1" -o jsonpath='{.metadata.labels.id}') == "$ns" ]]; then
        pass "$ns/${ns}1 is ready with the requested label"
    else
        fail "$ns/${ns}1 is ready with the requested label"
    fi
done
if "${K[@]}" -n app get ciliumnetworkpolicy policy1 >/dev/null 2>&1; then
    pass 'CiliumNetworkPolicy app/policy1 exists'
else
    fail 'CiliumNetworkPolicy app/policy1 exists'
fi
(( failed == 0 )) || finish

# Each probe has two listening ports to detect accidental HTTP-only restrictions.
# No candidate resources or policies are altered.
make_probe() {
    local ns=$1 label=$2 name=$3
    created+=("$ns/$name")
    "${K[@]}" create -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels:
    id: $label
spec:
  terminationGracePeriodSeconds: 0
  containers:
  - name: probe
    image: nginx:stable
    command: ["/bin/sh", "-ec"]
    args:
    - |
      printf 'events {} http { server { listen 80; listen 8080; location / { return 200 "ok"; } } }' > /tmp/nginx.conf
      exec nginx -c /tmp/nginx.conf -g 'daemon off;'
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 1
      periodSeconds: 2
YAML
    "${K[@]}" -n "$ns" wait pod "$name" --for=condition=Ready --timeout=180s >/dev/null
}
suffix="$(date +%s)-$$-$RANDOM"
source_probe="cks-source-$suffix"
allowed_probe="cks-allowed-$suffix"
wrong_label="cks-label-$suffix"
wrong_ns="cks-namespace-$suffix"
make_probe app validation-other "$source_probe"
make_probe data data "$allowed_probe"
make_probe data validation-other "$wrong_label"
make_probe manage data "$wrong_ns"

# Return curl's code through stdout so kubectl/exec failures cannot count as denial.
request() {
    local ns=$1 pod=$2 address=$3 port=$4
    "${K[@]}" -n "$ns" exec "$pod" -- sh -c '
        command -v curl >/dev/null || exit 127
        curl --noproxy "*" -sS -o /dev/null --connect-timeout 2 --max-time 3 "http://$1:$2/" 2>/dev/null
        rc=$?
        printf "%s" "$rc"
    ' sh "$address" "$port"
}
pod_ip() {
    local ip
    ip=$("${K[@]}" -n "$1" get pod "$2" -o jsonpath='{.status.podIP}')
    [[ -n $ip ]] || return 1
    if [[ $ip == *:* ]]; then printf '[%s]' "$ip"; else printf '%s' "$ip"; fi
}
check_path() {
    local src=$1 ns=$2 dst=$3 port=$4 expected=$5 ip rc attempt good=0
    ip=$(pod_ip "$ns" "$dst")
    # Confirm the destination really serves this port before testing a denial.
    rc=$(request "$ns" "$dst" 127.0.0.1 "$port") || rc=exec-error
    if [[ $rc != 0 ]]; then
        fail "$ns/$dst:$port test server is healthy (code $rc)"; return
    fi
    # Allow policy/identity propagation; require two consecutive matching results.
    for attempt in {1..10}; do
        rc=$(request app "$src" "$ip" "$port") || rc=exec-error
        if { [[ $expected == allow && $rc == 0 ]]; } ||
           { [[ $expected == deny && ( $rc == 28 || $rc == 7 ) ]]; }; then
            good=$((good + 1))
            (( good < 2 )) || break
        else
            good=0
        fi
        sleep 2
    done
    if (( good >= 2 )); then
        pass "app/$src -> $ns/$dst TCP/$port: $expected"
    else
        fail "app/$src -> $ns/$dst TCP/$port: expected $expected (curl code $rc)"
    fi
}
for src in app1 "$source_probe"; do
    check_path "$src" data data1 80 allow
    check_path "$src" manage manage1 80 deny
    for port in 80 8080; do
        check_path "$src" data "$allowed_probe" "$port" allow
        check_path "$src" data "$wrong_label" "$port" deny
        check_path "$src" manage "$wrong_ns" "$port" deny
    done
done
finish
