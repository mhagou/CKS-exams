#!/usr/bin/env bash
set -Eeuo pipefail
# Optional scope: ./validate.sh [namespace [pod-name]]. Default: all namespaces.
passed=0
failed=0
probe_ns=''
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
  (( failed == 0 ))
}
cleanup() {
  if [[ -n $probe_ns ]]; then
    kubectl delete namespace "$probe_ns" --ignore-not-found --wait=true --timeout=60s >/dev/null || return 1
    probe_ns=''
  fi
}
trap 'cleanup || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! command -v kubectl >/dev/null; then fail 'kubectl is available'; finish; exit 1; fi
scope=(-A)
[[ -z ${1:-} ]] || scope=(-n "$1")
if ! rows=$(kubectl get pods "${scope[@]}" --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.namespace}{"|"}{.metadata.name}{"|"}{.spec.nodeName}{"|"}{range .spec.containers[*]}{.name}{" "}{end}{"\n"}{end}'); then
  fail 'Running Pods can be inspected'; finish; exit 1
fi
modern=false
kubectl explain pod.spec.containers.securityContext.appArmorProfile >/dev/null 2>&1 && modern=true
found=false
working=false
while IFS='|' read -r ns pod node containers; do
  [[ -n $pod ]] || continue
  [[ -z ${2:-} || $pod == "$2" ]] || continue
  for container in $containers; do
    # Kernel state accepts both current fields and legacy annotations, including
    # Pod-level inheritance, without requiring a particular resource name.
    state=$(kubectl exec -n "$ns" "$pod" -c "$container" -- sh -c \
      'cat /proc/self/attr/apparmor/current 2>/dev/null || cat /proc/self/attr/current' 2>/dev/null) || continue
    [[ $state == *' (enforce)' ]] || continue
    profile=${state% (enforce)}
    case "$profile" in unconfined|cri-containerd.apparmor.d|docker-default) continue ;; esac
    found=true
    printf 'Inspecting %s/%s container %s (profile %s).\n' "$ns" "$pod" "$container" "$profile"
    # A failed exec is not proof of a denied write: require an explicit marker
    # from a shell that actually attempted creation. Remove any unexpected file.
    marker=$(kubectl exec -n "$ns" "$pod" -c "$container" -- sh -c '
      f=/tmp/cks-apparmor-check-$$
      if (umask 077; set -C; echo test > "$f") 2>/dev/null; then
        rm -f "$f"; echo WRITE_ALLOWED
      else echo WRITE_DENIED; fi' 2>/dev/null) || continue
    [[ $marker == WRITE_DENIED ]] || continue

    # A fresh writable emptyDir and a root process rule out a read-only root
    # filesystem or Unix permissions as the sole reason for the denial.
    if [[ -z $probe_ns ]]; then
      probe_ns=$(kubectl create -f - -o jsonpath='{.metadata.name}' <<'NS'
apiVersion: v1
kind: Namespace
metadata:
  generateName: cks-apparmor-check-
NS
) || { fail 'Temporary test namespace can be created'; finish; exit 1; }
    fi
    kubectl delete pod probe -n "$probe_ns" --ignore-not-found --wait=true --timeout=60s >/dev/null
    # YAML single-quote escaping also supports profiles containing punctuation.
    quoted_profile=${profile//\'/\'\'}
    {
      cat <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: probe
  namespace: $probe_ns
YAML
      if ! $modern; then
        printf "  annotations:\n    container.apparmor.security.beta.kubernetes.io/check: 'localhost/%s'\n" "$quoted_profile"
      fi
      cat <<YAML
spec:
  nodeName: $node
  restartPolicy: Never
  activeDeadlineSeconds: 180
  tolerations:
  - operator: Exists
  containers:
  - name: check
    image: busybox:1.28
    command: [sh, -c, 'sleep 150']
    securityContext:
      runAsUser: 0
      readOnlyRootFilesystem: false
YAML
      if $modern; then
        printf "      appArmorProfile:\n        type: Localhost\n        localhostProfile: '%s'\n" "$quoted_profile"
      fi
      cat <<'YAML'
    volumeMounts:
    - name: scratch
      mountPath: /tmp
  volumes:
  - name: scratch
    emptyDir: {}
YAML
    } | kubectl create -f - >/dev/null || continue
    kubectl wait -n "$probe_ns" --for=condition=Ready pod/probe --timeout=90s >/dev/null 2>&1 || continue
    probe_state=$(kubectl exec -n "$probe_ns" probe -- sh -c \
      'cat /proc/self/attr/apparmor/current 2>/dev/null || cat /proc/self/attr/current' 2>/dev/null) || continue
    [[ $probe_state == "$state" ]] || continue
    result=$(kubectl exec -n "$probe_ns" probe -- sh -c '
      [ "$(id -u)" = 0 ] || exit 1
      [ -d /tmp ] || exit 1
      if (echo test > /tmp/cks-apparmor-probe) 2>/dev/null; then
        rm -f /tmp/cks-apparmor-probe; echo WRITE_ALLOWED
      else echo WRITE_DENIED; fi' 2>/dev/null) || continue
    if [[ $result == WRITE_DENIED ]]; then working=true; break; fi
  done
  $working && break
done <<< "$rows"
if $found; then pass 'A running candidate container uses a loaded AppArmor profile in enforce mode'
else fail 'A running candidate container uses a loaded AppArmor profile in enforce mode'; fi
if $working; then
  pass 'Writing to /tmp fails in the candidate container'
  pass 'The same AppArmor profile denies writing to a fresh writable /tmp volume'
else
  fail 'Candidate /tmp denial and independent AppArmor enforcement could not both be verified'
fi
if ! cleanup; then fail 'Temporary validation resources were cleaned up'; fi
finish
