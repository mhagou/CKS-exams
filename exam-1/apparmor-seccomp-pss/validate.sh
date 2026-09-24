#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation. The task requires editing a file, not admitting or
# starting the Pod; restricted admission would also require unrelated changes.
LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
POD_FILE=${1:-"$LAB_DIR/secure-pod.yaml"}
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
for command in kubectl ssh; do
    if ! command -v "$command" >/dev/null; then
        fail "Required validation command is missing: $command"
        finish
    fi
done

if ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 \
    "grep -Fxq 'secure-profile (enforce)' /sys/kernel/security/apparmor/profiles"; then
    pass 'secure-profile is loaded on node01 in enforce mode'
else
    fail 'secure-profile must be loaded on node01 in enforce mode'
fi
if label=$(kubectl get namespace secured-area -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}') && [[ $label == restricted ]]; then
    pass 'secured-area is labeled to enforce the restricted Pod Security Standard'
else
    fail 'secured-area must be labeled to enforce the restricted Pod Security Standard'
fi

# kubectl parses YAML into an object; Go templates resolve container overrides
# and Pod-level defaults without depending on formatting or container names.
# Client dry-run does not create a resource or enforce namespace admission.
template='{{if and (eq .apiVersion "v1") (eq .kind "Pod") (eq .metadata.name "secure-nginx") (eq .metadata.namespace "secured-area") .spec.containers}}@identity|ok{{"\n"}}{{else}}@identity|bad{{"\n"}}{{end}}
{{$pod := .}}
{{range $key, $group := .spec}}{{if or (eq $key "containers") (eq $key "initContainers") (eq $key "ephemeralContainers")}}{{range $group}}
{{$sc := .securityContext.seccompProfile}}{{if not $sc}}{{$sc = $pod.spec.securityContext.seccompProfile}}{{end}}
{{$aa := .securityContext.appArmorProfile}}{{$legacy := ""}}{{if $pod.metadata.annotations}}{{$legacy = index $pod.metadata.annotations (printf "container.apparmor.security.beta.kubernetes.io/%s" .name)}}{{end}}
{{if and (not $aa) (not $legacy)}}{{$aa = $pod.spec.securityContext.appArmorProfile}}{{end}}
{{.name}}|{{if $sc}}{{$sc.type}}{{else}}unset{{end}}|{{if $aa}}{{if eq $aa.type "Localhost"}}localhost/{{$aa.localhostProfile}}{{else}}invalid-field{{end}}{{else}}{{if $legacy}}{{$legacy}}{{else}}unset{{end}}{{end}}|{{if .securityContext.privileged}}privileged{{else}}confined{{end}}{{"\n"}}
{{end}}{{end}}{{end}}'

if [[ ! -f $POD_FILE ]] || ! rows=$(kubectl create --dry-run=client --validate=false -f "$POD_FILE" -o "go-template=$template"); then
    fail 'secure-pod.yaml must be a readable Pod manifest'
    finish
fi
identity_count=0
container_count=0
seccomp_ok=true
apparmor_ok=true
identity_ok=true
confinement_ok=true
while IFS='|' read -r name seccomp apparmor confinement; do
    [[ -n $name ]] || continue
    if [[ $name == @identity ]]; then
        identity_count=$((identity_count + 1))
        [[ $seccomp == ok ]] || identity_ok=false
        continue
    fi
    container_count=$((container_count + 1))
    if [[ $seccomp != RuntimeDefault ]]; then
        seccomp_ok=false
        printf '  Container %s: seccomp is not RuntimeDefault.\n' "$name"
    fi
    if [[ $apparmor != localhost/secure-profile ]]; then
        apparmor_ok=false
        printf '  Container %s: AppArmor does not select secure-profile.\n' "$name"
    fi
    if [[ $confinement != confined ]]; then
        confinement_ok=false
        printf '  Container %s: privileged mode bypasses the requested confinement.\n' "$name"
    fi
done <<< "$rows"
if [[ $identity_ok == true ]] && (( identity_count == 1 && container_count > 0 )); then
    pass 'Manifest describes secure-nginx in secured-area'
else
    fail 'Manifest must describe one secure-nginx Pod in secured-area with containers'
fi
if [[ $seccomp_ok == true ]] && (( container_count > 0 )); then
    pass 'Manifest selects RuntimeDefault seccomp for every container'
else
    fail 'Manifest must select RuntimeDefault seccomp for every container'
fi
if [[ $apparmor_ok == true ]] && (( container_count > 0 )); then
    pass 'Manifest selects the custom localhost AppArmor profile for every container'
else
    fail 'Manifest must select the custom localhost AppArmor profile for every container'
fi
if [[ $confinement_ok == true ]] && (( container_count > 0 )); then
    pass 'Manifest containers do not bypass confinement through privileged mode'
else
    fail 'Manifest containers must not bypass confinement through privileged mode'
fi
finish
