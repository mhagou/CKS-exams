#!/usr/bin/env bash
set -Eeuo pipefail

passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
trap 'fail "Validation could not complete (line $LINENO)"; finish' ERR
for tool in kubectl ssh jq; do
    if ! command -v "$tool" >/dev/null; then fail "Required validation tool: $tool"; finish; fi
done
if [[ $EUID -ne 0 || $(hostname -s) != controlplane ]]; then
    fail 'Run validation as root on controlplane'; finish
fi
k() { kubectl -n alpha "$@"; }
if ! k get pod nginx-auditing >/dev/null 2>&1; then
    fail 'Pod alpha/nginx-auditing exists'; finish
fi
pass 'Pod alpha/nginx-auditing exists'
if k wait pod/nginx-auditing --for=condition=Ready --timeout=60s >/dev/null 2>&1 &&
   [[ $(k get pod nginx-auditing -o jsonpath='{.status.phase}') == Running ]]; then
    pass 'Pod is running and ready'
else
    fail 'Pod is running and ready'
fi
images=$(k get pod nginx-auditing -o jsonpath='{range .spec.containers[*]}{.image}{"\n"}{end}')
if printf '%s\n' "$images" | grep -Eq '^(docker.io/|index.docker.io/)?(library/)?nginx(:[[:alnum:]_][[:alnum:]_.-]*)?(@sha256:[[:xdigit:]]{64})?$'; then
    pass 'Pod uses the nginx image'
else
    fail 'Pod uses the nginx image'
fi
profile_type=$(k get pod nginx-auditing -o jsonpath='{.spec.securityContext.seccompProfile.type}')
profile_path=$(k get pod nginx-auditing -o jsonpath='{.spec.securityContext.seccompProfile.localhostProfile}')
if [[ $profile_type != Localhost || -z $profile_path || $profile_path == /* || /$profile_path/ == */../* ]]; then
    fail 'Pod security context selects a local seccomp profile'; finish
fi
pass 'Pod security context selects a local seccomp profile'

expected='{"defaultAction":"SCMP_ACT_LOG"}'
if [[ -r /root/auditing.json ]] && [[ $(jq -cS . /root/auditing.json 2>/dev/null) == "$expected" ]]; then
    pass 'The supplied auditing.json remains in /root'
else
    fail 'The supplied auditing.json remains in /root'
fi
node=$(k get pod nginx-auditing -o jsonpath='{.spec.nodeName}')
# Discover kubelet's actual root directory, honoring a nondefault --root-dir.
# This function only reads process arguments and the selected profile file.
read_profile() {
    bash -s -- "$1" <<'REMOTE'
set -Eeuo pipefail
relative=$1
root=/var/lib/kubelet
pid=$(pgrep -xo kubelet)
mapfile -d '' -t args < "/proc/$pid/cmdline"
for ((i=0; i<${#args[@]}; i++)); do
    case ${args[i]} in
        --root-dir=*) root=${args[i]#*=} ;;
        --root-dir) root=${args[i+1]} ;;
    esac
done
cat -- "$root/seccomp/$relative"
REMOTE
}
profile_matches() {
    local relative=$1 installed remote_command
    [[ -n $relative && $relative != /* && /$relative/ != */../* ]] || return 1
    if [[ $node == controlplane ]]; then
        installed=$(read_profile "$relative") || return 1
    elif [[ $node == node01 ]]; then
        # Quote a candidate-supplied path for the worker's login shell. POSIX
        # single quoting also works when that shell is not Bash.
        remote_command="bash -s -- '${relative//\'/\'\\\'\'}'"
        installed=$( { declare -f read_profile; printf 'read_profile "$1"\n'; } |
            ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 "$remote_command") || return 1
    else
        return 1
    fi
    [[ $(printf '%s' "$installed" | jq -cS . 2>/dev/null) == "$expected" ]]
}
if profile_matches "$profile_path"; then
    pass 'Selected profile on the assigned node matches the supplied audit profile'
else
    fail 'Selected profile on the assigned node matches the supplied audit profile'
fi

# Container overrides take precedence over the Pod setting. Check all regular
# containers and init containers, including restartable init sidecars.
rows=$(k get pod nginx-auditing -o go-template='{{range .spec.containers}}{{.name}} {{if .securityContext}}{{if .securityContext.seccompProfile}}{{.securityContext.seccompProfile.type}} {{.securityContext.seccompProfile.localhostProfile}}{{else}}inherit -{{end}} {{if .securityContext.privileged}}privileged{{else}}normal{{end}}{{else}}inherit - normal{{end}}{{"\n"}}{{end}}{{range .spec.initContainers}}{{.name}} {{if .securityContext}}{{if .securityContext.seccompProfile}}{{.securityContext.seccompProfile.type}} {{.securityContext.seccompProfile.localhostProfile}}{{else}}inherit -{{end}} {{if .securityContext.privileged}}privileged{{else}}normal{{end}}{{else}}inherit - normal{{end}}{{"\n"}}{{end}}')
overrides_ok=true
while read -r name kind path privilege; do
    [[ -n $name ]] || continue
    if [[ $privilege == privileged ]] || { [[ $kind != inherit ]] && [[ $kind != Localhost ]]; }; then
        overrides_ok=false
    elif [[ $kind == Localhost && $path != "$profile_path" ]] && ! profile_matches "$path"; then
        overrides_ok=false
    fi
done <<< "$rows"
if $overrides_ok; then pass 'Containers retain the Pod audit profile'; else fail 'Containers retain the Pod audit profile'; fi

containers=$(k get pod nginx-auditing -o jsonpath='{range .spec.containers[*]}{.name}{"\n"}{end}')
while IFS= read -r container; do
    [[ -n $container ]] || continue
    if status=$(k exec nginx-auditing -c "$container" -- cat /proc/1/status 2>/dev/null) &&
       printf '%s\n' "$status" | grep -Eq '^Seccomp:[[:space:]]+2[[:space:]]*$'; then
        pass "Runtime seccomp filtering is active for $container"
    else
        fail "Runtime seccomp filtering is active for $container"
    fi
done <<< "$containers"
finish
