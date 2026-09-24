#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only configuration inspection plus a server dry-run; no Pod is persisted.
passes=0
failures=0
pass() { printf '[PASS] %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failures=$((failures + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
    if (( failures == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
[[ $EUID -eq 0 ]] || { fail 'Run validation as root on controlplane.'; finish; }
command -v kubectl >/dev/null || { fail 'kubectl is available.'; finish; }
export KUBECONFIG=/etc/kubernetes/admin.conf
if kubectl --request-timeout=10s get --raw=/readyz >/dev/null 2>&1; then
    pass 'API server is ready.'
else
    fail 'API server is ready.'
fi

# Inspect actual process arguments, avoiding stale mirror Pods and YAML formatting.
pids=()
for proc in /proc/[0-9]*; do
    [[ -r $proc/cmdline ]] || continue
    args=()
    mapfile -d '' -t args < "$proc/cmdline" 2>/dev/null || continue
    [[ ${args[0]:-} == */kube-apiserver || ${args[0]:-} == kube-apiserver ]] || continue
    pids+=("$proc")
done
if (( ${#pids[@]} != 1 )); then
    fail 'Exactly one running local API server can be inspected; retry after any restart.'
    finish
fi
mapfile -d '' -t args < "${pids[0]}/cmdline"
flag_values() {
    local name=$1 i
    for ((i=0; i<${#args[@]}; i++)); do
        if [[ ${args[i]} == "$name="* ]]; then
            printf '%s\n' "${args[i]#*=}"
        elif [[ ${args[i]} == "$name" ]]; then
            printf '%s\n' "${args[i+1]:-}"
        fi
    done
}
enabled=$(flag_values --enable-admission-plugins | paste -sd, -)
disabled=$(flag_values --disable-admission-plugins | paste -sd, -)
for plugin in NodeRestriction ImagePolicyWebhook; do
    if [[ ,$enabled, == *",$plugin,"* && ,$disabled, != *",$plugin,"* ]]; then
        pass "$plugin is explicitly enabled in the running API server."
    else
        fail "$plugin is explicitly enabled in the running API server."
    fi
done
config=$(flag_values --admission-control-config-file | tail -n 1)
if [[ $config == /etc/kubernetes/admission/admission_config.yaml && -r ${pids[0]}/root$config ]]; then
    pass 'Running API server references the supplied, accessible admission configuration.'
else
    fail 'Running API server references the supplied, accessible admission configuration.'
fi

# Unique image avoids cached admission decisions. Restricted-compatible Pod avoids
# unrelated Pod Security failures. --dry-run=server never creates a resource.
probe="cks-imagepolicy-probe-$(date +%s)-$$"
if output=$(kubectl --request-timeout=30s create --dry-run=server -f - 2>&1 <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $probe
  namespace: default
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: registry.k8s.io/pause:$probe
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: [ALL]
YAML
); then
    fail 'Image admission fails closed with the dummy backend unavailable (probe was accepted).'
else
    # Do not mistake RBAC, transport failures, or another admission policy for success.
    if [[ $output == *Forbidden* ]] && {
        [[ $output == *'https://127.0.0.1:1/image-policy'* && $output == *'connection refused'* ]] ||
        [[ $output == *'image policy webhook backend denied'* ]] ||
        [[ $output == *'images rejected by webhook backend'* ]];
    }; then
        pass 'ImagePolicyWebhook rejects the runtime admission probe.'
    else
        fail 'Runtime denial can be attributed to ImagePolicyWebhook.'
        printf 'Diagnostic: %s\n' "$output"
    fi
fi
finish
