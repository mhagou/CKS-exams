#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl ssh; do command -v "$tool" >/dev/null || { echo "Missing $tool" >&2; exit 1; }; done
packages=()
command -v strace >/dev/null || packages+=(strace)
command -v jq >/dev/null || packages+=(jq)
if ((${#packages[@]})); then
    command -v apt-get >/dev/null || { echo 'Install strace and jq with your distribution package manager.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y --no-install-recommends "${packages[@]}"
fi
kubectl wait --for=condition=Ready node/controlplane node/node01 --timeout=120s
prepare_node() {
    [[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] || { echo 'AppArmor kernel support is required.' >&2; return 1; }
    if ! command -v apparmor_parser >/dev/null; then
        command -v apt-get >/dev/null || return 1
        apt-get update -qq
        apt-get install -y --no-install-recommends apparmor
    fi
    command -v crictl >/dev/null || { echo 'The playground must provide configured crictl.' >&2; return 1; }
    crictl info >/dev/null
    test -r /sys/kernel/security/apparmor/profiles
    mkdir -p /var/lib/kubelet/seccomp/profiles
}
prepare_node
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 "$(declare -f prepare_node); set -Eeuo pipefail; prepare_node"
work=/root/cks-kernel-hardening
mkdir -p "$work"
for pod in hello-apparmor audit-pod; do
    owner=$(kubectl -n default get pod "$pod" --ignore-not-found -o jsonpath='{.metadata.labels.cks-lab}')
    exists=$(kubectl -n default get pod "$pod" --ignore-not-found -o name)
    [[ -z $exists || $owner == kernel-hardening ]] || { echo "Unrelated pod $pod already exists." >&2; exit 1; }
done
# Unloaded permissive starter: the candidate must implement confinement.
if [[ ! -e /root/apparmor ]]; then
    cat > /root/apparmor <<'PROFILE'
#include <tunables/global>
profile k8s-apparmor-example-deny-write flags=(attach_disconnected,mediate_deleted) {
  # Starter policy: permits writes. Edit before loading for this exercise.
  file,
  network,
  capability,
}
PROFILE
fi
if [[ ! -e $work/seccomp-starter.json ]]; then
    printf '%s\n' '{"defaultAction":"SCMP_ACT_ALLOW"}' > "$work/seccomp-starter.json"
fi
cat > "$work/pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: hello-apparmor
  namespace: default
  labels:
    cks-lab: kernel-hardening
spec:
  nodeSelector:
    kubernetes.io/hostname: node01
  containers:
  - name: hello
    image: busybox:1.36
    command: ["sh", "-c", "echo 'Hello AppArmor!'; sleep 2147483647"]
YAML
cat > "$work/audit-pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: audit-pod
  namespace: default
  labels:
    app: audit-pod
    cks-lab: kernel-hardening
spec:
  nodeSelector:
    kubernetes.io/hostname: node01
  securityContext:
    seccompProfile:
      type: Unconfined
  containers:
  - name: test-container
    image: hashicorp/http-echo:1.0
    args: ["-text=just made some syscalls!"]
YAML
kubectl -n default delete pod hello-apparmor audit-pod --ignore-not-found --wait=true --timeout=90s
kubectl apply -f "$work/pod.yaml" -f "$work/audit-pod.yaml"
kubectl -n default wait --for=condition=Ready pod/hello-apparmor pod/audit-pod --timeout=180s
kubectl -n default exec hello-apparmor -- sh -ec 'd=$(mktemp -d /tmp/cks-initial.XXXXXX); rmdir "$d"'
[[ $(kubectl -n default get pod audit-pod -o jsonpath='{.spec.securityContext.seccompProfile.type}') == Unconfined ]]
# Bounded harmless process for optional strace practice; reuse on reruns.
pid=$(cat "$work/strace.pid" 2>/dev/null || true)
if [[ ! $pid =~ ^[0-9]+$ ]] || [[ $(cat "/proc/$pid/comm" 2>/dev/null || true) != cks-trace-demo ]]; then
    nohup bash -c 'echo cks-trace-demo > /proc/self/comm; end=$((SECONDS+86400)); while ((SECONDS<end)); do sleep 1; done' > "$work/strace.log" 2>&1 &
    pid=$!
    echo "$pid" > "$work/strace.pid"
fi
kill -0 "$pid"
test -s /root/apparmor
test -s "$work/seccomp-starter.json"
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Practice manifests and strace PID: %s\nAppArmor starter: /root/apparmor\nPods: default/hello-apparmor and default/audit-pod on node01.\n' "$work"
