#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "ERROR: scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
# jq is used to inspect policy inheritance and admission results in validate.sh.
missing=()
for command_name in curl jq; do
  command -v "$command_name" >/dev/null || missing+=("$command_name")
done
if ((${#missing[@]})); then
  command -v apt-get >/dev/null || { echo 'Install curl and jq, then retry.' >&2; exit 1; }
  apt-get update -qq
  apt-get install -y "${missing[@]}"
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Preserve any existing Istio installation. Never upgrade or replace it here.
kubectl get deployments -A -l app=istiod -o json > "$work/istiod.json"
if [[ $(jq '.items | length' "$work/istiod.json") == 0 ]]; then
  if kubectl get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
    echo 'An existing/partial Istio installation needs attention; refusing to replace it.' >&2
    exit 1
  fi
  version=${ISTIO_VERSION:-1.30.4}
  case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo 'Unsupported architecture for automatic Istio installation.' >&2; exit 1 ;;
  esac
  archive="istio-${version}-linux-${arch}.tar.gz"
  url="https://github.com/istio/istio/releases/download/${version}"
  curl -fsSL --retry 3 "$url/$archive" -o "$work/$archive"
  curl -fsSL --retry 3 "$url/$archive.sha256" -o "$work/$archive.sha256"
  (cd "$work"; sha256sum -c "$archive.sha256")
  tar -xzf "$work/$archive" -C "$work"
  install -m 0755 "$work/istio-$version/bin/istioctl" /usr/local/bin/istioctl
  istioctl x precheck
  istioctl install -y --set profile=minimal
  kubectl get deployments -A -l app=istiod -o json > "$work/istiod.json"
fi
while read -r ns name; do
  kubectl -n "$ns" rollout status "deployment/$name" --timeout=180s
done < <(jq -r '.items[] | [.metadata.namespace,.metadata.name] | @tsv' "$work/istiod.json")
kubectl get crd peerauthentications.security.istio.io >/dev/null

# Only reset a namespace previously created by this lab. Preserve other labs.
if kubectl get namespace restricted-zone -o json > "$work/ns.json" 2>/dev/null; then
  if ! jq -e '.metadata.labels["cks-lab"] == "mtls-istio-sidecar"' "$work/ns.json" >/dev/null; then
    echo 'restricted-zone already exists without this lab ownership label; refusing to overwrite it.' >&2
    exit 1
  fi
  kubectl delete namespace restricted-zone --wait=true --timeout=180s
fi
if kubectl -n default get pod cks-mtls-legacy -o json > "$work/legacy.json" 2>/dev/null; then
  jq -e '.metadata.labels["cks-lab"] == "mtls-istio-sidecar"' "$work/legacy.json" >/dev/null || {
    echo 'The legacy pod name is already in use by an unrelated resource.' >&2; exit 1;
  }
  kubectl -n default delete pod cks-mtls-legacy --wait=true
fi
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Namespace
metadata:
  name: restricted-zone
  labels:
    cks-lab: mtls-istio-sidecar
    istio-injection: disabled
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: httpbin
  namespace: restricted-zone
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
  namespace: restricted-zone
spec:
  selector:
    app: httpbin
  ports:
  - name: http
    port: 8000
    targetPort: 80
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
  namespace: restricted-zone
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
      version: v1
  template:
    metadata:
      labels:
        app: httpbin
        version: v1
    spec:
      serviceAccountName: httpbin
      containers:
      - name: httpbin
        image: docker.io/kennethreitz/httpbin
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /status/200
            port: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: cks-mtls-legacy
  namespace: default
  labels:
    cks-lab: mtls-istio-sidecar
    sidecar.istio.io/inject: "false"
    istio.io/dataplane-mode: none
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  containers:
  - name: client
    image: curlimages/curl:8.12.1
    command: ["sleep", "3650d"]
YAML
kubectl -n restricted-zone rollout status deployment/httpbin --timeout=180s
kubectl -n default wait --for=condition=Ready pod/cks-mtls-legacy --timeout=180s
kubectl -n restricted-zone get pods -l app=httpbin -o json | jq -e '
  (.items | length) > 0 and all(.items[];
    ([.spec.containers[], .spec.initContainers[]?] | all(.name != "istio-proxy")))' >/dev/null
kubectl -n default get pod cks-mtls-legacy -o json | jq -e '
  [.spec.containers[], .spec.initContainers[]?] | all(.name != "istio-proxy")' >/dev/null
kubectl -n default exec cks-mtls-legacy -c client -- \
  curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 \
  http://httpbin.restricted-zone.svc:8000/status/200 >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
