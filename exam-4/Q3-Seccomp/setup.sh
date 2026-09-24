#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null
command -v ssh >/dev/null
# jq is used to evaluate structured Kubernetes and OCI runtime state.
if ! command -v jq >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install jq before setup.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y jq
fi
kubectl wait --for=condition=Ready node/controlplane node/node01 --timeout=120s

# Read-only capability checks plus installation of a missing inspection tool.
# No kubelet/runtime configuration or seccomp profiles are changed.
prepare_node() {
    bash -s <<'NODE'
set -Eeuo pipefail
grep -qw log /proc/sys/kernel/seccomp/actions_avail || { echo 'Kernel lacks seccomp logging.' >&2; exit 1; }
grep -qw log /proc/sys/kernel/seccomp/actions_logged || { echo 'Kernel seccomp logging is disabled.' >&2; exit 1; }
if command -v k3s >/dev/null || command -v crictl >/dev/null; then exit 0; fi
if ! command -v curl >/dev/null; then
    command -v apt-get >/dev/null
    apt-get update -qq
    apt-get install -y curl ca-certificates
fi
case "$(uname -m)" in
    x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
    *) echo 'Unsupported architecture for automatic crictl installation.' >&2; exit 1 ;;
esac
version=v1.35.0
archive="crictl-${version}-linux-${arch}.tar.gz"
base="https://github.com/kubernetes-sigs/cri-tools/releases/download/${version}"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL "$base/$archive" -o "$tmp/$archive"
curl -fsSL "$base/$archive.sha256" -o "$tmp/checksum"
expected=$(awk 'NR == 1 {print $1}' "$tmp/checksum")
[[ $expected =~ ^[0-9a-fA-F]{64}$ ]]
printf '%s  %s\n' "$expected" "$tmp/$archive" | sha256sum -c -
tar -xzf "$tmp/$archive" -C "$tmp" crictl
install -m 0755 "$tmp/crictl" /usr/local/bin/crictl
NODE
}
prepare_node
# Send exactly the same preparation routine to the worker.
{ declare -f prepare_node; printf '\nprepare_node\n'; } | ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 bash -s

namespace=seccomp-lab
if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    [[ $(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.cks-exercise}') == q3-seccomp ]] || {
        echo 'Namespace seccomp-lab already exists and is not owned by this exercise.' >&2; exit 1;
    }
else
    kubectl create namespace "$namespace"
    kubectl label namespace "$namespace" cks-exercise=q3-seccomp
fi
# Reset only the starter pod belonging to this exercise.
if kubectl -n "$namespace" get pod audit-pod >/dev/null 2>&1; then
    [[ $(kubectl -n "$namespace" get pod audit-pod -o jsonpath='{.metadata.labels.cks-exercise}') == q3-seccomp ]] || {
        echo 'Existing audit-pod is not owned by this exercise.' >&2; exit 1;
    }
    kubectl -n "$namespace" delete pod audit-pod --wait=true --timeout=60s
fi
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: audit-pod
  namespace: seccomp-lab
  labels:
    cks-exercise: q3-seccomp
spec:
  nodeName: node01
  containers:
    - name: test-seccomp
      image: nginx:alpine
      command: ["/bin/sh", "-c", "exec sleep 2147483647"]
      securityContext:
        allowPrivilegeEscalation: false
YAML
kubectl -n "$namespace" wait --for=condition=Ready pod/audit-pod --timeout=180s
kubectl -n "$namespace" exec audit-pod -- sh -ec 'p=$(mktemp -d /tmp/cks-initial.XXXXXX); rmdir "$p"'
[[ -z $(kubectl -n "$namespace" get pod audit-pod -o jsonpath='{.spec.securityContext.seccompProfile.localhostProfile}{.spec.containers[0].securityContext.seccompProfile.localhostProfile}') ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\nScenario preparation completed successfully.\nStarter pod: seccomp-lab/audit-pod on node01.\n'
