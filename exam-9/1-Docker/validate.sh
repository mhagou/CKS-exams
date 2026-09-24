#!/usr/bin/env bash
set -Eeuo pipefail
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
# Read-only worker checks. No daemon restarts, configuration edits or repairs.
if output=$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -s' <<'REMOTE'
set -Eeuo pipefail
check() { if "$@"; then echo PASS; else echo FAIL; fi; }
membership() {
    id developer >/dev/null 2>&1 || return 1
    local gid
    gid=$(getent group docker | cut -d: -f3)
    [[ -z $gid ]] || ! id -G developer | tr ' ' '\n' | grep -qx "$gid"
}
other_groups() {
    local state=/var/lib/cks-exam9-docker gid current
    [[ -r $state/other-groups && -r $state/primary-group ]] || return 1
    [[ $(id -g developer) == "$(cat "$state/primary-group")" ]] || return 1
    gid=$(getent group docker | cut -d: -f3) || gid=''
    current=$(id -G developer | tr ' ' '\n' | awk -v gid="$gid" '$0 != gid' | sort -nu) || return 1
    local expected
    while IFS= read -r expected; do
        grep -qx "$expected" <<< "$current" || return 1
    done < "$state/other-groups"
}
socket_group() { [[ -S /var/run/docker.sock && $(stat -Lc %g /var/run/docker.sock) == 0 ]]; }
daemon_health() { systemctl is-active --quiet docker.service && docker -H unix:///var/run/docker.sock info >/dev/null 2>&1; }
no_tcp() {
    local listeners
    listeners=$(ss -H -lntp) || return 1
    # Include all dockerd processes, IPv4 and IPv6. docker-proxy ports belong
    # to published containers and are not Docker daemon API listeners.
    ! grep -q '"dockerd"' <<< "$listeners"
}
check membership
check other_groups
check socket_group
check daemon_health
check no_tcp
REMOTE
); then
    mapfile -t checks <<< "$output"
    descriptions=('developer is not a member of docker' 'All other developer groups and the primary group are preserved' 'Docker socket belongs to group root' 'Docker daemon is active and its Unix API responds' 'Docker daemon listens on no TCP port')
    for i in "${!descriptions[@]}"; do
        if [[ ${checks[$i]:-} == PASS ]]; then pass "${descriptions[$i]}"; else fail "${descriptions[$i]}"; fi
    done
else
    fail 'Worker inspection over SSH succeeded (root access required)'
fi
# Examine live cluster state rather than resource manifest formatting.
if nodes=$(kubectl --request-timeout=30s get nodes -o go-template='{{range .items}}{{.metadata.name}}{{" "}}{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}{{"\n"}}{{end}}'); then
    if awk 'NF != 2 || $2 != "True" {bad=1} $1=="controlplane" {cp=1} $1=="node01" {worker=1} END {exit (bad || !cp || !worker)}' <<< "$nodes"; then
        pass 'Both playground nodes are Ready'
    else fail 'Both playground nodes are Ready'; fi
else fail 'Both playground nodes are Ready'; fi
if pods=$(kubectl --request-timeout=30s get pods -A -o go-template='{{range .items}}{{.metadata.namespace}}/{{.metadata.name}}{{" "}}{{.status.phase}}{{" "}}{{range .status.conditions}}{{if eq .type "Ready"}}{{.status}}{{end}}{{end}}{{"\n"}}{{end}}'); then
    if awk 'NF && $2 != "Succeeded" && !($2 == "Running" && $3 == "True") {print "Unhealthy pod: " $0; bad=1} END {exit bad}' <<< "$pods"; then
        pass 'Cluster pods are running and Ready or successfully completed'
    else fail 'Cluster pods are running and Ready or successfully completed'; fi
else fail 'Cluster pod health can be inspected'; fi
printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
if ((failed == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; exit 1; fi
