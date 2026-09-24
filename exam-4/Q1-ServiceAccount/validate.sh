#!/usr/bin/env bash
set -Eeuo pipefail

passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then
        echo 'RESULT: SUCCESS'
        exit 0
    fi
    echo 'RESULT: FAILED'
    exit 1
}
k() { kubectl --request-timeout=30s "$@"; }

if ! command -v kubectl >/dev/null; then
    fail 'kubectl is available to inspect the playground'
    finish
fi

# Read the live API object, not the supplied solution manifest.
if account=$(k -n secret-room get serviceaccount hidden-user -o go-template='{{.metadata.name}}|{{.automountServiceAccountToken}}'); then
    pass 'ServiceAccount hidden-user exists in namespace secret-room'
    if [[ "$account" == 'hidden-user|false' ]]; then
        pass 'The ServiceAccount disables automatic token mounting'
    else
        fail 'The ServiceAccount must disable automatic token mounting'
    fi
else
    fail 'ServiceAccount hidden-user exists in namespace secret-room'
    fail 'The ServiceAccount disables automatic token mounting'
fi

# Admission records injected mounts in the live Pod spec. Inspect all container
# types without needing a shell or other tools in the candidate image. A Pod
# override of true defeats the ServiceAccount setting. Completed test Pods count.
# Only token-bearing volumes mounted at the automatic token directory are
# rejected; explicit projections at custom paths are not forbidden by this task.
template='{{range .items}}{{if eq .spec.serviceAccountName "hidden-user"}}{{$pod := .}}{{.metadata.name}}|{{.status.phase}}|{{if .metadata.deletionTimestamp}}deleting{{else}}active{{end}}|{{.spec.automountServiceAccountToken}}|{{range .spec.volumes}}{{$volume := .}}{{if .projected}}{{range .projected.sources}}{{if .serviceAccountToken}}{{range $pod.spec.containers}}{{range .volumeMounts}}{{if and (eq .name $volume.name) (eq .mountPath "/var/run/secrets/kubernetes.io/serviceaccount")}}token{{end}}{{end}}{{end}}{{range $pod.spec.initContainers}}{{range .volumeMounts}}{{if and (eq .name $volume.name) (eq .mountPath "/var/run/secrets/kubernetes.io/serviceaccount")}}token{{end}}{{end}}{{end}}{{range $pod.spec.ephemeralContainers}}{{range .volumeMounts}}{{if and (eq .name $volume.name) (eq .mountPath "/var/run/secrets/kubernetes.io/serviceaccount")}}token{{end}}{{end}}{{end}}{{end}}{{end}}{{end}}{{end}}{{"\n"}}{{end}}{{end}}'

verified=''
if pods=$(k -n secret-room get pods -o go-template="$template"); then
    while IFS='|' read -r name phase lifecycle override mounts; do
        [[ -n "$name" ]] || continue
        if [[ "$lifecycle" == active && "$override" != true && -z "$mounts" && ( "$phase" == Running || "$phase" == Succeeded ) ]]; then
            verified=$name
            break
        fi
    done <<< "$pods"
    if [[ -n "$verified" ]]; then
        pass "Pod $verified uses hidden-user without an automatic token mount"
    else
        fail 'A running or completed Pod must use hidden-user without enabling or retaining an automatic token mount'
    fi
else
    fail 'Candidate verification Pods could be inspected'
fi

finish
