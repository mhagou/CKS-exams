#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only inspection and a server-side dry-run; no candidate resources change.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
  echo 'RESULT: FAILED'; exit 1
}
if [[ $EUID -ne 0 ]] || ! command -v kubectl >/dev/null; then
  fail 'Validation requires root on controlplane and kubectl.'
  finish
fi
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
K=(kubectl --request-timeout=45s)

if "${K[@]}" get --raw=/readyz >/dev/null 2>&1; then
  pass 'API server is running and ready.'
else
  fail 'API server is running and ready.'
fi

# /proc provides the actual running command, independent of manifest formatting,
# container names, runtime tooling, or mirror Pods blocked by admission.
pids=()
for proc in /proc/[0-9]*; do
  [[ -r "$proc/cmdline" ]] || continue
  args=()
  mapfile -d '' -t args < "$proc/cmdline" 2>/dev/null || continue
  (( ${#args[@]} > 0 )) || continue
  if [[ ${args[0]##*/} == kube-apiserver ]]; then pids+=("${proc##*/}"); fi
done
if (( ${#pids[@]} != 1 )); then
  fail 'Exactly one local running API server can be inspected.'
else
  pid=${pids[0]}
  mapfile -d '' -t args < "/proc/$pid/cmdline"
  flag() {
    local key=$1 i value='' item
    for ((i=0; i<${#args[@]}; i++)); do
      case ${args[i]} in
        "$key"=*) item=${args[i]#*=} ;;
        "$key") item=${args[i+1]:-} ;;
        *) continue ;;
      esac
      # Kubernetes list flags accumulate across repeated occurrences.
      case $key in
        --enable-admission-plugins|--disable-admission-plugins|--admission-control)
          value+=${value:+,}$item ;;
        *) value=$item ;;
      esac
    done
    printf '%s' "$value"
  }
  enabled=$(flag --enable-admission-plugins)
  legacy=$(flag --admission-control)
  disabled=$(flag --disable-admission-plugins)
  for plugin in ImagePolicyWebhook NodeRestriction; do
    if [[ ,$enabled,$legacy, == *,$plugin,* && ,$disabled, != *,$plugin,* ]]; then
      pass "$plugin is enabled in the running API server."
    else
      fail "$plugin is enabled in the running API server."
    fi
  done
  config=$(flag --admission-control-config-file)
  # Compare resolved files, not mount names or the container-side mount path.
  # Do not compare against the example YAML: equivalent configuration is valid.
  if [[ -d /etc/kubernetes/admission && -s /etc/kubernetes/admission/admission-config.yaml \
     && $config == /* && -s /proc/$pid/root$config ]] && \
     cmp -s /etc/kubernetes/admission/admission-config.yaml "/proc/$pid/root$config"; then
    pass 'The running API server references the prepared admission configuration.'
  else
    fail 'The running API server references /etc/kubernetes/admission/admission-config.yaml (or its mounted equivalent).'
  fi
fi

# ImagePolicyWebhook supports dry-run. This exercises admission without scheduling
# a Pod or leaving a resource behind. Restricted-compatible spec avoids unrelated
# Pod Security rejections; unrelated denials and timeouts are never counted as pass.
# ImagePolicyWebhook caches by image-review contents, including these annotations.
# Use a fresh review so an earlier decision cannot mask current backend behavior.
probe_id="$(date +%s%N)-$$-$RANDOM"
if output=$("${K[@]}" create --dry-run=server -f - 2>&1 <<POD
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-image-policy-probe-
  namespace: default
  annotations:
    validation.image-policy.k8s.io/probe: "$probe_id"
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: registry.k8s.io/pause:3.10
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
POD
); then
  fail 'The dummy image-policy webhook blocks new Pods (probe was admitted).'
else
  if [[ $output == *'Forbidden'* && $output == *'https://imagescanner.local:8080/image_policy'*  \
      && $output != *'failed calling webhook'* ]]; then
    pass 'Failure to contact the supplied dummy image-policy webhook blocks new Pods.'
  else
    fail 'Pod rejection is attributable to the image-policy webhook.'
    printf '  Probe response: %s\n' "$output"
  fi
fi
finish
