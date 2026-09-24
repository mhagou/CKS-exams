#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation on controlplane; host /proc works with Docker and CRI runtimes.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
if [[ $EUID -ne 0 ]]; then fail 'Run as root on controlplane to inspect the running API server.'; finish; fi
for tool in kubectl curl; do
    if ! command -v "$tool" >/dev/null; then fail "Required command available: $tool"; finish; fi
done
admin=/etc/kubernetes/admin.conf
k() { kubectl --kubeconfig="$admin" --request-timeout=10s "$@"; }
if k get --raw=/readyz >/dev/null 2>&1; then
    pass 'API server is ready using the original admin kubeconfig.'
else
    fail 'API server is ready using the original admin kubeconfig.'
fi

args=()
count=0
for proc in /proc/[0-9]*/cmdline; do
    argv=()
    if ! mapfile -d '' -t argv < "$proc" 2>/dev/null; then continue; fi
    [[ ${#argv[@]} -gt 0 ]] || continue
    if [[ ${argv[0]##*/} == kube-apiserver ]]; then
        args=("${argv[@]}")
        count=$((count + 1))
    fi
done
# Supports both --flag=value and --flag value, with the last occurrence winning.
flag() {
    local name=$1 value=$2 i
    for ((i=1; i<${#args[@]}; i++)); do
        case "${args[i]}" in
            "--$name="*) value=${args[i]#*=} ;;
            "--$name") value=${args[i+1]:-true} ;;
        esac
    done
    printf '%s' "$value"
}
if ((count != 1)); then
    fail 'Exactly one running API server can be inspected; retry after any restart completes.'
fi
anonymous=$(flag anonymous-auth true)
mode=$(flag authorization-mode AlwaysAllow)
enabled=$(flag enable-admission-plugins '')
disabled=$(flag disable-admission-plugins '')
server=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null) || server=''
code=000
if [[ -n "$server" ]]; then
    # Intentionally send no client certificate, token, or kubeconfig credentials.
    code=$(curl --noproxy '*' -ksS --max-time 10 -o /dev/null -w '%{http_code}' "${server%/}/api" 2>/dev/null) || code=000
fi
if ((count == 1)) && [[ "$anonymous" == false && "$code" == 401 ]]; then
    pass 'Anonymous authentication is disabled and anonymous API requests are rejected.'
else
    fail 'Anonymous authentication is disabled and anonymous API requests are rejected.'
fi
if ((count == 1)) && [[ "$mode" == Node,RBAC || "$mode" == RBAC,Node ]]; then
    pass 'Running API server uses only Node and RBAC authorization.'
else
    fail 'Running API server uses only Node and RBAC authorization.'
fi
if ((count == 1)) && [[ ",$enabled," == *,NodeRestriction,* && ",$disabled," != *,NodeRestriction,* ]]; then
    pass 'NodeRestriction admission is enabled in the running API server.'
else
    fail 'NodeRestriction admission is enabled in the running API server.'
fi
if binding=$(k get clusterrolebinding system:anonymous --ignore-not-found -o name 2>/dev/null); then
    if [[ -z "$binding" ]]; then pass 'ClusterRoleBinding system:anonymous has been removed.'
    else fail 'ClusterRoleBinding system:anonymous has been removed.'; fi
else
    fail 'Could not verify removal of ClusterRoleBinding system:anonymous.'
fi
finish
