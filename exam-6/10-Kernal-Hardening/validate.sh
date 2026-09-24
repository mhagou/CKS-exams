#!/usr/bin/env bash
set -Eeuo pipefail
# The task is a set of practice notes. Strace leaves no required artifact, so
# command history/process termination is deliberately not graded. The two
# seccomp paths in the notes differ: accept any applied Localhost profile.
passed=0 failed=0 probe=''
pass() { echo "[PASS] $*"; passed=$((passed+1)); }
fail() { echo "[FAIL] $*"; failed=$((failed+1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    ((failed == 0))
}
cleanup() {
    if [[ -n $probe ]]; then
        kubectl -n default delete pod "$probe" --ignore-not-found --wait=true --timeout=60s >/dev/null || return 1
        probe=''
    fi
}
trap 'cleanup || true' EXIT
for tool in kubectl ssh jq; do
    if ! command -v "$tool" >/dev/null; then fail "Required validation tool: $tool"; finish; exit 1; fi
done
if [[ $EUID != 0 ]]; then fail 'Run validation as root on controlplane'; finish; exit 1; fi
node_command() {
    case "$node" in
        controlplane) bash -c "$1" ;;
        node01) ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 "$1" ;;
        *) return 1 ;;
    esac
}
# Read the actual CRI process, including images without cat or a shell.
runtime_state() {
    local id inspect pid
    node=$(jq -r '.spec.nodeName // empty' <<< "$podjson")
    id=$(jq -r --arg c "$container" '.status.containerStatuses[]? | select(.name==$c) | .containerID // empty' <<< "$podjson")
    id=${id#*://}
    [[ $id =~ ^[a-fA-F0-9]+$ ]] || return 1
    inspect=$(node_command "crictl inspect '$id'") || return 1
    pid=$(jq -r '.info.pid // .status.pid // empty' <<< "$inspect") || return 1
    [[ $pid =~ ^[0-9]+$ && $pid -gt 0 ]] || return 1
    status=$(node_command "cat /proc/$pid/status") || return 1
    armor=$(node_command "cat /proc/$pid/attr/apparmor/current 2>/dev/null || cat /proc/$pid/attr/current") || return 1
}
for pod in hello-apparmor audit-pod; do
    if ! podjson=$(kubectl -n default get pod "$pod" -o json); then
        fail "$pod exists"; continue
    fi
    if ! jq -e 'any(.status.conditions[]?; .type=="Ready" and .status=="True")' <<< "$podjson" >/dev/null; then
        fail "$pod is Ready"; continue
    fi
    pass "$pod is Ready"
    # Select the task workload by its initial name, with a single-container
    # fallback to accept candidate renaming. Ignore unrelated sidecars.
    if [[ $pod == hello-apparmor ]]; then original=hello; else original=test-container; fi
    container=$(jq -r --arg c "$original" 'if any(.spec.containers[]; .name==$c) then $c elif (.spec.containers|length)==1 then .spec.containers[0].name else empty end' <<< "$podjson")
    if [[ -z $container ]]; then fail "$pod workload container can be identified"; continue; fi
    if ! runtime_state; then fail "$pod runtime state is readable through CRI on its node"; continue; fi
    context=$(jq -c --arg c "$container" '.spec.containers[] | select(.name==$c) | .securityContext // {}' <<< "$podjson")
    if [[ $pod == hello-apparmor ]]; then
        # Accept both structured fields and legacy AppArmor annotations.
        profile=$(jq -r --arg c "$container" '
            (.spec.containers[] | select(.name==$c) | .securityContext.appArmorProfile) as $cc |
            ($cc // .spec.securityContext.appArmorProfile) as $p |
            if $p.type=="Localhost" then $p.localhostProfile
            else (.metadata.annotations["container.apparmor.security.beta.kubernetes.io/"+$c] // "") |
                if startswith("localhost/") then ltrimstr("localhost/") else "" end end' <<< "$podjson")
        if [[ -n $profile && $armor == "$profile (enforce)" ]]; then
            pass 'AppArmor Localhost profile is enforced on the running workload'
        else
            fail 'AppArmor Localhost profile is enforced on the running workload'
        fi
        # Require an actual access-denied response, not a missing utility or
        # read-only-filesystem error. Clean up the test directory if allowed.
        if kubectl -n default exec "$pod" -c "$container" -- sh -c '
            command -v mkdir >/dev/null || exit 2
            d=/cks-write-test-$$
            if output=$(mkdir "$d" 2>&1); then rmdir "$d"; exit 1; fi
            case "$output" in *"Permission denied"*|*"Permission Denied"*|*"Operation not permitted"*) exit 0;; *) echo "$output" >&2; exit 2;; esac'; then
            pass 'AppArmor workload denies directory creation'
        else
            fail 'AppArmor workload denies directory creation'
        fi
    else
        profile=$(jq -r --arg c "$container" '
            (.spec.containers[] | select(.name==$c) | .securityContext.seccompProfile) // .spec.securityContext.seccompProfile |
            if .type=="Localhost" then .localhostProfile // "" else "" end' <<< "$podjson")
        if [[ -n $profile ]] && awk '$1=="Seccomp:" && $2==2 {ok=1} END {exit !ok}' <<< "$status"; then
            pass 'audit-pod uses a Localhost profile with runtime seccomp filtering'
        else
            fail 'audit-pod uses a Localhost profile with runtime seccomp filtering'
        fi
        if [[ $(jq -r '.allowPrivilegeEscalation' <<< "$context") == false ]] &&
            awk '$1=="NoNewPrivs:" && $2==1 {ok=1} END {exit !ok}' <<< "$status"; then
            pass 'audit-pod disables privilege escalation in configuration and runtime'
        else
            fail 'audit-pod disables privilege escalation in configuration and runtime'
        fi
        # http-echo may be shell-less. A temporary probe copies the effective
        # security contexts, annotations, runtime class and node placement.
        # Mount denial is a behavioral check, not proof of its seccomp cause:
        # a missing CAP_SYS_ADMIN can also deny mount, including with LOG rules.
        probe="cks-kernel-probe-$(date +%s)-$$"
        manifest=$(jq --arg name "$probe" --arg c "$container" '
            . as $p | (.spec.containers[] | select(.name==$c)) as $c |
            {apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:"default",annotations:($p.metadata.annotations // {})},
             spec:({nodeName:$p.spec.nodeName,restartPolicy:"Never",automountServiceAccountToken:false,
                    securityContext:($p.spec.securityContext // {}),
                    containers:[{name:$c.name,image:"busybox:1.36",command:["sh","-c","sleep 300"],securityContext:($c.securityContext // {})}]}
                    + (if $p.spec.runtimeClassName then {runtimeClassName:$p.spec.runtimeClassName} else {} end))}' <<< "$podjson")
        if kubectl create -f - <<< "$manifest" >/dev/null &&
            kubectl -n default wait --for=condition=Ready "pod/$probe" --timeout=90s >/dev/null &&
            kubectl -n default exec "$probe" -c "$container" -- sh -c '
                command -v mount >/dev/null || exit 2
                # /tmp already exists. No directory creation can mask mount denial.
                if output=$(mount -t tmpfs -o size=512M tmpfs /tmp 2>&1); then
                    umount /tmp; exit 1
                fi
                case "$output" in *"Permission denied"*|*"permission denied"*|*"Operation not permitted"*) exit 0;; *) echo "$output" >&2; exit 2;; esac'; then
            pass 'Mount is denied with audit-pod security settings'
        else
            fail 'Mount is denied with audit-pod security settings'
        fi
        if ! cleanup; then fail 'Temporary validation Pod was removed'; fi
    fi
done
finish
