#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation of the scenario contextualized by solution.txt.
# Policy names, selector syntax, ordering, and YAML formatting are not graded.
NS=api-restrict
passed=0
failed=0
k() { kubectl --request-timeout=20s "$@"; }
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Validation error at line $LINENO; check cluster access and prerequisites."; finish' ERR
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; }
k get namespace "$NS" >/dev/null || { fail 'Lab namespace is accessible'; finish; }
policies=$(k get networkpolicy -n "$NS" -o go-template='{{range .items}}{{$name := .metadata.name}}{{range .spec.policyTypes}}{{if eq . "Egress"}}{{$name}}{{"\n"}}{{end}}{{end}}{{end}}')
if [[ -n $policies ]]; then pass 'An egress NetworkPolicy exists in the exercise namespace'; else fail 'An egress NetworkPolicy exists in the exercise namespace'; fi

# Select actual clients by role, not by arbitrary Pod/container names.
admins=$(k get pods -n "$NS" -l role=admin -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
restricted=$(k get pods -n "$NS" -l role=restricted -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
[[ -n $admins && -n $restricted ]] || { fail 'Both admin and restricted clients exist'; finish; }
for pod in $admins $restricted; do
    state=$(k get pod -n "$NS" "$pod" -o jsonpath='{.status.phase}{" "}{.spec.hostNetwork}{" "}{range .status.conditions[?(@.type=="Ready")]}{.status}{end}')
    if [[ $state != 'Running  True' && $state != 'Running false True' ]]; then
        fail "$pod is a ready, ordinary network client"; finish
    fi
    # Default container selection allows renamed containers. The supplied lab
    # clients contain curl; an exec/tool failure must never count as a denial.
    k exec -n "$NS" "$pod" -- sh -c 'command -v curl >/dev/null' || { fail "$pod has a usable connectivity probe"; finish; }
done
pass 'Both client roles are running and usable for connectivity tests'

urls=()
port=$(k get service kubernetes -n default -o jsonpath='{.spec.ports[0].port}')
ips=$(k get service kubernetes -n default -o jsonpath='{range .spec.clusterIPs[*]}{.}{"\n"}{end}')
[[ -n $ips && -n $port ]] || { fail 'Kubernetes Service destinations can be discovered'; finish; }
while read -r ip; do
    [[ -n $ip ]] || continue
    [[ $ip != *:* ]] || ip="[$ip]"
    urls+=("https://$ip:$port/version")
done <<< "$ips"
endpoints=$(k get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o go-template='{{range .items}}{{$slice := .}}{{range .endpoints}}{{if ne .conditions.ready false}}{{range .addresses}}{{$ip := .}}{{range $slice.ports}}{{printf "%s %v\n" $ip .port}}{{end}}{{end}}{{end}}{{end}}{{end}}')
[[ -n $endpoints ]] || { fail 'Ready API endpoints can be discovered'; finish; }
while read -r ip port; do
    [[ $ip != *:* ]] || ip="[$ip]"
    urls+=("https://$ip:$port/version")
done <<< "$endpoints"

probe() {
    k exec -n "$NS" "$1" -- sh -c '
        curl --noproxy "*" -ks --connect-timeout 3 --max-time 5 -o /dev/null "$1"
        printf "RC=%s" "$?"
    ' sh "$2"
}
# Allow a short convergence window, then require repeated denied connections.
# No --fail: HTTP authentication/authorization errors mean the API IS reachable.
sleep 3
for url in "${urls[@]}"; do
    healthy=true
    for pod in $admins; do
        if result=$(probe "$pod" "$url") && [[ $result == RC=0 ]]; then
            pass "$pod can reach $url"
        else
            fail "$pod cannot reach $url (probe: ${result:-exec failure})"
            healthy=false
        fi
    done
    for pod in $restricted; do
        if [[ $healthy != true ]]; then
            fail "$pod denial at $url cannot be established without a working admin control"
            continue
        fi
        denied=true
        for attempt in 1 2 3; do
            if ! result=$(probe "$pod" "$url"); then denied=false; break; fi
            case "$result" in
                RC=7|RC=28) ;;
                *) denied=false; break ;;
            esac
        done
        if [[ $denied == true ]]; then
            pass "$pod is blocked from $url"
        else
            fail "$pod is not demonstrably blocked from $url (probe: ${result:-exec failure})"
        fi
    done
done
finish
