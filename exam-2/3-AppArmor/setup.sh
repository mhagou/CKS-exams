#!/usr/bin/env bash
set -Eeuo pipefail

# Generate the initial scenario only. Run later as root on controlplane.
# task.txt does not identify what must be unreadable and supplies no profile.
# This lab defines that target as /etc/cks-spectacle/read-test (harmless data).
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl ssh; do
    command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done
kubectl get node controlplane node01 >/dev/null
kubectl wait --for=condition=Ready node/node01 --timeout=120s >/dev/null

# Prepare the same supplied profile on both nodes without loading it. Do not
# restart services or change boot/kernel settings if AppArmor is unavailable.
prepare_node=$(cat <<'REMOTE'
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Node preparation needs root.' >&2; exit 1; }
[[ $(cat /sys/module/apparmor/parameters/enabled 2>/dev/null) == Y ]] || {
    echo 'AppArmor must already be enabled in the playground kernel.' >&2; exit 1;
}
if ! command -v apparmor_parser >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install AppArmor userspace tools on this node.' >&2; exit 1; }
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y apparmor
fi
[[ -r /sys/kernel/security/apparmor/profiles ]] || {
    echo 'AppArmor kernel interface is unavailable.' >&2; exit 1;
}
mkdir -p /etc/apparmor.d
# Refuse to overwrite a pre-existing unrelated profile.
if [[ -e /etc/apparmor.d/spectacleapp ]] &&
   ! grep -q '^# CKS spectacle lab profile$' /etc/apparmor.d/spectacleapp; then
    echo 'An unmanaged spectacleapp profile already exists; refusing to overwrite it.' >&2
    exit 1
fi
cat > /etc/apparmor.d/spectacleapp <<'PROFILE'
# CKS spectacle lab profile
# The read restriction targets harmless lab data, not application libraries.
#include <tunables/global>
profile spectacleapp flags=(attach_disconnected,mediate_deleted) {
  #include <abstractions/base>
  file,
  network,
  capability,
  mount,
  umount,
  signal,
  ptrace,
  deny /etc/cks-spectacle/ r,
  deny /etc/cks-spectacle/** r,
}
PROFILE
chmod 0644 /etc/apparmor.d/spectacleapp
# Parse only: -Q skips kernel loading, -T skips reading cached profiles.
apparmor_parser -Q -T /etc/apparmor.d/spectacleapp
REMOTE
)
bash -c "$prepare_node"
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 bash -s <<< "$prepare_node"

# Own the namespace before resetting anything in it.
if kubectl get namespace spectacle >/dev/null 2>&1; then
    owner=$(kubectl get namespace spectacle -o jsonpath='{.metadata.labels.cks-lab}')
    [[ $owner == spectacle-apparmor ]] || {
        echo 'Namespace spectacle already exists and is not owned by this lab.' >&2; exit 1;
    }
else
    kubectl create namespace spectacle >/dev/null
    kubectl label namespace spectacle cks-lab=spectacle-apparmor >/dev/null
fi
# Namespace-local admission allowance is needed for the intentionally privileged pod.
kubectl label namespace spectacle pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
kubectl delete pod apparmor-pod -n spectacle --ignore-not-found --wait=true --timeout=90s >/dev/null
kubectl delete serviceaccount test-sa -n spectacle --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: spectacle-read-fixture
  namespace: spectacle
data:
  read-test: "Harmless CKS AppArmor read-access fixture.\n"
---
apiVersion: v1
kind: Pod
metadata:
  name: apparmor-pod
  namespace: spectacle
  labels:
    run: nginx
spec:
  nodeName: node01
  serviceAccountName: default
  containers:
    - name: nginx
      image: nginx:alpine
      securityContext:
        privileged: true
      ports:
        - containerPort: 80
      volumeMounts:
        - name: read-fixture
          mountPath: /etc/cks-spectacle
          readOnly: true
  volumes:
    - name: read-fixture
      configMap:
        name: spectacle-read-fixture
        defaultMode: 0444
YAML
kubectl wait -n spectacle --for=condition=Ready pod/apparmor-pod --timeout=180s >/dev/null
[[ $(kubectl get pod apparmor-pod -n spectacle -o jsonpath='{.spec.containers[0].securityContext.privileged}') == true ]]
[[ $(kubectl get pod apparmor-pod -n spectacle -o jsonpath='{.spec.serviceAccountName}') == default ]]
if kubectl get serviceaccount test-sa -n spectacle >/dev/null 2>&1; then
    echo 'Initial service-account state is incorrect.' >&2; exit 1
fi
kubectl exec -n spectacle apparmor-pod -c nginx -- cat /etc/cks-spectacle/read-test >/dev/null
kubectl exec -n spectacle apparmor-pod -c nginx -- sh -c \
    'wget -q -O /dev/null http://127.0.0.1:80/'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
