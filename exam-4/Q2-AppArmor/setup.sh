#!/usr/bin/env bash
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for command in kubectl ssh; do
  command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done
kubectl get node controlplane node01 >/dev/null
kubectl wait --for=condition=Ready node/controlplane node/node01 --timeout=120s

# Only install AppArmor userspace if missing. Never change boot flags or reboot.
prepare_node() {
  bash -s <<'NODE'
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
[[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] || {
  echo 'AppArmor must already be enabled in this node kernel; use an AppArmor-capable playground.' >&2
  exit 1
}
[[ -r /sys/kernel/security/apparmor/profiles ]] || {
  echo 'The AppArmor security filesystem is unavailable on this node.' >&2
  exit 1
}
if ! command -v apparmor_parser >/dev/null || [[ ! -f /etc/apparmor.d/abstractions/base ]]; then
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y apparmor
  elif command -v zypper >/dev/null; then
    zypper --non-interactive install apparmor-parser apparmor-profiles
  else
    echo 'Install the distribution AppArmor parser and base abstractions before retrying.' >&2
    exit 1
  fi
fi
command -v apparmor_parser >/dev/null
[[ -r /etc/apparmor.d/tunables/global && -r /etc/apparmor.d/abstractions/base ]]
apparmor_parser --version >/dev/null
NODE
}
prepare_node
# Forward the same prerequisite preparation to the worker.
{ declare -f prepare_node; echo prepare_node; } | ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -s'

# These are the supplied exercise resources, not an applied solution.
# Keep them outside /etc/apparmor.d so a service reload cannot load them.
lab_dir=/root/cks-apparmor
mkdir -p "$lab_dir"
cat > "$lab_dir/deny-write.profile" <<'PROFILE'
#include <tunables/global>
profile k8s-deny-write flags=(attach_disconnected) {
  #include <abstractions/base>
  file,
  # Deny all file writes in /tmp
  deny /tmp/** w,
}
PROFILE
if kubectl explain pod.spec.securityContext.appArmorProfile >/dev/null 2>&1; then
  cat > "$lab_dir/pod-with-apparmor.yaml" <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: hello-apparmor
spec:
  securityContext:
    appArmorProfile:
      type: Localhost
      localhostProfile: k8s-deny-write
  containers:
  - name: hello
    image: busybox:1.28
    command: [ "sh", "-c", "echo 'Hello AppArmor!' && sleep 1h" ]
POD
else
  cat > "$lab_dir/pod-with-apparmor.yaml" <<'POD'
apiVersion: v1
kind: Pod
metadata:
  name: hello-apparmor
  annotations:
    container.apparmor.security.beta.kubernetes.io/hello: localhost/k8s-deny-write
spec:
  containers:
  - name: hello
    image: busybox:1.28
    command: [ "sh", "-c", "echo 'Hello AppArmor!' && sleep 1h" ]
POD
fi
# Parse only: -Q skips loading into the kernel; -T skips reading the cache.
apparmor_parser -Q -T "$lab_dir/deny-write.profile" >/dev/null
kubectl create --dry-run=client -f "$lab_dir/pod-with-apparmor.yaml" -o name >/dev/null
[[ -s "$lab_dir/deny-write.profile" && -s "$lab_dir/pod-with-apparmor.yaml" ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nExercise resources: %s\n' "$lab_dir"
# Reruns refresh only staged resources. Existing candidate Pods/profiles are preserved.
