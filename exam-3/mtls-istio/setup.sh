#!/usr/bin/env bash
set -Eeuo pipefail

# Playground only. Existing candidate policies are never removed on reset.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
missing=()
for tool in curl jq; do command -v "$tool" >/dev/null || missing+=("$tool"); done
if ((${#missing[@]})); then
  command -v apt-get >/dev/null || { echo 'Install curl and jq first.' >&2; exit 1; }
  apt-get update -qq
  apt-get install -y "${missing[@]}"
fi
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
k() { kubectl --request-timeout=30s "$@"; }
k get nodes >/dev/null
planes=$(k get deployments -A -l app=istiod -o json)
count=$(jq '.items | length' <<<"$planes")
if [[ $count == 0 ]]; then
  if k get crd peerauthentications.security.istio.io >/dev/null 2>&1; then
    echo 'Existing Istio CRDs but no discoverable istiod: restore that installation first.' >&2
    exit 1
  fi
  # Select a compatible release explicitly with ISTIO_VERSION when necessary.
  version=${ISTIO_VERSION:-}
  if [[ -z $version ]]; then
    version=$(curl -fsSL --retry 3 https://api.github.com/repos/istio/istio/releases/latest | jq -er '.tag_name')
  fi
  [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
  case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) echo 'Unsupported architecture.' >&2; exit 1 ;;
  esac
  archive="istio-${version}-linux-${arch}.tar.gz"
  url="https://github.com/istio/istio/releases/download/${version}/${archive}"
  curl -fsSL --retry 3 "$url" -o "$work/$archive"
  curl -fsSL --retry 3 "$url.sha256" -o "$work/checksum"
  hash=$(awk 'NR == 1 {print $1}' "$work/checksum")
  [[ $hash =~ ^[[:xdigit:]]{64}$ ]]
  (cd "$work"; echo "$hash  $archive" | sha256sum -c -)
  tar -xzf "$work/$archive" -C "$work"
  install -m 0755 "$work/istio-$version/bin/istioctl" /usr/local/bin/istioctl
  istioctl install --set profile=minimal -y
  planes=$(k get deployments -A -l app=istiod -o json)
  count=$(jq '.items | length' <<<"$planes")
fi
[[ $count == 1 ]] || { echo 'This lab requires one unambiguous Istio control plane.' >&2; exit 1; }
istio_ns=$(jq -r '.items[0].metadata.namespace' <<<"$planes")
istiod=$(jq -r '.items[0].metadata.name' <<<"$planes")
revision=$(jq -r '.items[0].metadata.labels["istio.io/rev"] // "default"' <<<"$planes")
k -n "$istio_ns" rollout status deployment/"$istiod" --timeout=300s
# An existing mesh-wide requirement would leave the main objective pre-solved.
# Refuse that baseline instead of weakening unrelated security configuration.
config=$(jq -r '[.items[0].spec.template.spec.volumes[]? |
  select(.name == "config-volume") | .configMap.name][0] // empty' <<<"$planes")
if [[ -z $config ]]; then
  config=istio
  [[ $revision == default ]] || config="istio-$revision"
fi
mesh=$(k -n "$istio_ns" get configmap "$config" -o jsonpath='{.data.mesh}')
root_ns=$(awk '$1 == "rootNamespace:" {gsub(/["\047]/,"",$2); print $2; exit}' <<<"$mesh")
root_ns=${root_ns:-istio-system}
if k -n "$root_ns" get peerauthentications.security.istio.io -o json | jq -e '
  any(.items[]; ((.spec.selector.matchLabels // {}) | length) == 0 and .spec.mtls.mode == "STRICT")' >/dev/null; then
  echo 'Existing mesh security configuration conflicts with the initial lab state; it was preserved.' >&2
  exit 1
fi

# Never replace resources belonging to another exercise.
for ref in 'default service helloworld' 'default deployment helloworld-v1' 'default deployment helloworld-v2' 'test pod test'; do
  read -r ns kind name <<<"$ref"
  obj=$(k -n "$ns" get "$kind" "$name" --ignore-not-found -o json)
  if [[ -n $obj ]] && ! jq -e '.metadata.labels["cks-lab"] == "mtls-istio"' <<<"$obj" >/dev/null; then
    echo "Resource $ns/$kind/$name already exists and is not owned by this lab." >&2
    exit 1
  fi
done
if k get namespace test >/dev/null 2>&1; then
  k get namespace test -o json | jq -e '
    .metadata.labels["istio-injection"] != "enabled" and
    (.metadata.labels["istio.io/rev"] // "") == "" and
    .metadata.labels["istio.io/dataplane-mode"] != "ambient"' >/dev/null || {
      echo 'The existing test namespace is enrolled in a mesh; use a clean test namespace.' >&2; exit 1;
    }
else
  k create namespace test
fi
k get namespace default -o json | jq -e '.metadata.labels["istio.io/dataplane-mode"] != "ambient"' >/dev/null || {
  echo 'The default namespace is in ambient mode; this exercise needs sidecars.' >&2; exit 1;
}
# Opt in the sample workloads without changing namespace injection settings.
curl -fsSL --retry 3 \
  https://raw.githubusercontent.com/istio/istio/refs/heads/master/samples/helloworld/helloworld.yaml \
  -o "$work/helloworld.yaml"
k create --dry-run=client -f "$work/helloworld.yaml" -o json | jq --arg rev "$revision" '
  (if .kind == "List" then . else {apiVersion:"v1",kind:"List",items:[.]} end) |
  .items |= map(.metadata.namespace = "default" | .metadata.labels["cks-lab"] = "mtls-istio" |
    if .kind == "Deployment" then
      .spec.template.metadata.labels["sidecar.istio.io/inject"] = "true" |
      .spec.template.metadata.labels["istio.io/rev"] = $rev |
      .spec.template.metadata.annotations["sidecar.istio.io/inject"] = "true"
    else . end)' > "$work/sample.json"
k apply -f "$work/sample.json"
k -n test delete pod test --ignore-not-found --wait=true >/dev/null
k apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: test
  labels:
    cks-lab: mtls-istio
    sidecar.istio.io/inject: "false"
  annotations:
    sidecar.istio.io/inject: "false"
spec:
  containers:
  - name: curl
    image: curlimages/curl:8.12.1
    command: ["sleep", "infinity"]
YAML
for deployment in helloworld-v1 helloworld-v2; do
  k -n default rollout status deployment/"$deployment" --timeout=300s
done
k -n default get pods -l app=helloworld -o json | jq -e '
  [.items[] | select(.metadata.deletionTimestamp == null)] |
  length > 0 and all(.[]; any((.spec.containers + (.spec.initContainers // []))[]; .name == "istio-proxy"))' >/dev/null
k -n test wait pod/test --for=condition=Ready --timeout=180s
k -n test get pod test -o json | jq -e '
  all((.spec.containers + (.spec.initContainers // []))[]; .name != "istio-proxy")' >/dev/null
ready=false
for attempt in {1..12}; do
  if k -n test exec test -- curl --noproxy '*' -fsSI --connect-timeout 3 --max-time 8 \
    http://helloworld.default.svc:5000/hello >/dev/null 2>&1; then
    ready=true; break
  fi
  sleep 5
done
if [[ $ready != true ]]; then
  echo 'Baseline connectivity failed. Inspect existing mesh policies, networking and workload health; no policies were reset.' >&2
  exit 1
fi
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
