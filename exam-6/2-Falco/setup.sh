#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the playground controlplane. The rule and its mount are candidate work.
trap 'echo "ERROR: preparation failed at line $LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
kubectl get node controlplane node01 >/dev/null

# jq is used to inspect resource ownership and mounts reliably.
if ! command -v jq >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install jq, then rerun setup.' >&2; exit 1; }
    apt-get update
    apt-get install -y jq
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
if ! kubectl -n falco get daemonset falco >/dev/null 2>&1; then
    # Do not create a second sensor alongside a differently named installation.
    existing=$(kubectl get daemonsets -A -o json | jq -r '
      .items[] | select(any(.spec.template.spec.containers[];
      (.image | test("(^|/)falco([:@]|$)")))) | .metadata.namespace + "/" + .metadata.name')
    [[ -z $existing ]] || { echo "Existing Falco installation found at $existing; adapt it to the task namespace/name before setup." >&2; exit 1; }
    if ! command -v helm >/dev/null; then
        for tool in curl tar sha256sum; do
            command -v "$tool" >/dev/null || { echo "Missing dependency: $tool" >&2; exit 1; }
        done
        case $(uname -m) in
            x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
            *) echo 'Unsupported Helm architecture.' >&2; exit 1 ;;
        esac
        version=${HELM_VERSION:-v3.19.0}
        archive="helm-${version}-linux-${arch}.tar.gz"
        curl -fsSL --retry 3 "https://get.helm.sh/$archive" -o "$work/$archive"
        curl -fsSL --retry 3 "https://get.helm.sh/$archive.sha256sum" -o "$work/checksum"
        (cd "$work" && sha256sum -c checksum)
        tar -xzf "$work/$archive" -C "$work"
        install -m 0755 "$work/linux-$arch/helm" /usr/local/bin/helm
    fi
    # Official chart; retain its driver/runtime defaults. Never upgrade an existing sensor.
    # https://falco.org/docs/setup/kubernetes/
    helm install falco falco --repo https://falcosecurity.github.io/charts \
        --namespace falco --create-namespace --set fullnameOverride=falco \
        --wait --timeout 10m
fi
kubectl -n falco rollout status daemonset/falco --timeout=300s
kubectl -n falco get daemonset falco -o json | jq -e '
  .status.desiredNumberScheduled > 0 and
  .status.numberReady == .status.desiredNumberScheduled' >/dev/null

kubectl create namespace falco-dev-mem-demo --dry-run=client -o yaml | kubectl apply -f -
# Scope the privileged admission exception to the exercise namespace only.
kubectl label namespace falco-dev-mem-demo pod-security.kubernetes.io/enforce=privileged --overwrite
for name in falco-gpu-amd falco-gpu-nvidia falco-cpu; do
    if [[ $name == falco-cpu ]]; then
        container='        securityContext:
          privileged: true
        command:
          - /bin/sh
          - -c
          - |
            dd if=/dev/urandom of=/tmp/mem bs=1K count=4
            while true; do
              cat /tmp/mem > /dev/null
              sleep 10
            done'
    else
        container='        command: ["/bin/sh", "-c", "sleep 3600"]'
    fi
    kubectl apply -f - <<YAML
apiVersion: apps/v1
kind: Deployment
metadata:
  name: $name
  namespace: falco-dev-mem-demo
spec:
  replicas: 1
  selector:
    matchLabels:
      app: $name
  template:
    metadata:
      labels:
        app: $name
    spec:
      containers:
      - name: busybox
        image: busybox:latest
$container
YAML
    kubectl -n falco-dev-mem-demo rollout status "deployment/$name" --timeout=180s
done
kubectl -n falco-dev-mem-demo exec deployment/falco-cpu -- sh -c 'test -s /tmp/mem && cat /tmp/mem >/dev/null'
# Ensure a ready sensor covers the node hosting the event source.
node=$(kubectl -n falco-dev-mem-demo get pods -l app=falco-cpu -o json |
    jq -r '.items[] | select(.metadata.deletionTimestamp == null and .status.phase == "Running") | .spec.nodeName' | head -n1)
uid=$(kubectl -n falco get ds falco -o jsonpath='{.metadata.uid}')
kubectl -n falco get pods -o json | jq -e --arg node "$node" --arg uid "$uid" '
  any(.items[]; .spec.nodeName == $node and
    any(.metadata.ownerReferences[]?; .uid == $uid) and
    any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\nScenario preparation completed successfully.\n'
# Reruns preserve candidate rules and unrelated configuration; they do not reset a solution.
