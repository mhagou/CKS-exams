#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. Starter manifests are written next
# to this script; the AppArmor source is written to /root/secure-profile on node01.
LAB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for command in kubectl ssh; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
kubectl get node controlplane node01 >/dev/null
kubectl wait --for=condition=Ready node/node01 --timeout=60s >/dev/null

ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -s' <<'REMOTE'
set -Eeuo pipefail
export PATH="$PATH:/usr/sbin:/sbin"
[[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] || {
    echo 'node01 must have AppArmor enabled in its kernel.' >&2; exit 1;
}
[[ -r /sys/kernel/security/apparmor/profiles ]] || {
    echo 'The AppArmor kernel interface is unavailable on node01.' >&2; exit 1;
}
# Do not unload a profile that may already protect another workload.
if grep -q '^secure-profile (' /sys/kernel/security/apparmor/profiles; then
    echo 'secure-profile is already loaded; use a clean lab state before setup.' >&2
    exit 1
fi
if ! command -v apparmor_parser >/dev/null ||
   [[ ! -r /etc/apparmor.d/tunables/global || ! -r /etc/apparmor.d/abstractions/base ]]; then
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y apparmor
    elif command -v zypper >/dev/null; then
        zypper --non-interactive install apparmor-parser apparmor-profiles
    else
        echo 'Install the distribution AppArmor parser and abstractions package on node01.' >&2
        exit 1
    fi
fi
command -v apparmor_parser >/dev/null
test -r /etc/apparmor.d/tunables/global
test -r /etc/apparmor.d/abstractions/base
cat > /root/secure-profile <<'PROFILE'
#include <tunables/global>
profile secure-profile flags=(attach_disconnected) {
  #include <abstractions/base>
  file,
  deny /bin/sh mrwklx,
}
PROFILE
chmod 0644 /root/secure-profile
# Compile without loading the profile into the kernel or writing a cache.
apparmor_parser --skip-kernel-load --skip-cache /root/secure-profile
test -s /root/secure-profile
! grep -q '^secure-profile (' /sys/kernel/security/apparmor/profiles
REMOTE

cat > "$LAB_DIR/secure-ns.yaml" <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: secured-area
YAML
cat > "$LAB_DIR/secure-pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: secure-nginx
  namespace: secured-area
spec:
  containers:
  - name: nginx
    image: nginx:1.25.2
YAML
kubectl apply -f "$LAB_DIR/secure-ns.yaml" >/dev/null
# Reset only the namespace label that belongs to this exercise.
if [[ -n $(kubectl get ns secured-area -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}') ]]; then
    kubectl label namespace secured-area pod-security.kubernetes.io/enforce- >/dev/null
fi
# The task asks for manifest edits, not deployment. Do not start the nginx Pod.
[[ $(kubectl get ns secured-area -o 'jsonpath={.status.phase}') == Active ]]
[[ -z $(kubectl get ns secured-area -o 'jsonpath={.metadata.labels.pod-security\.kubernetes\.io/enforce}') ]]
kubectl create --dry-run=client --validate=false -f "$LAB_DIR/secure-pod.yaml" -o name >/dev/null
test -s "$LAB_DIR/secure-ns.yaml"
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Starter manifests: %s/secure-ns.yaml and %s/secure-pod.yaml\n' "$LAB_DIR" "$LAB_DIR"
printf 'Worker profile source: node01:/root/secure-profile\n'
