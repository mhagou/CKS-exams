#!/usr/bin/env bash
set -Eeuo pipefail

passes=0
failures=0
probe=''
pass() { printf '[PASS] %s\n' "$*"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
k() { kubectl --request-timeout=30s "$@"; }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
  if ((failures == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
}
cleanup() {
  if [[ -n $probe ]]; then
    if ! k -n default delete pod "$probe" --ignore-not-found --wait=false >/dev/null; then
      fail "Could not clean up temporary pod default/$probe"
    fi
  fi
}
on_exit() {
  rc=$?
  trap - EXIT
  cleanup
  if ((rc != 0 && failures == 0)); then fail 'Validation could not complete'; fi
  finish
  ((failures == 0)) && exit 0
  exit 1
}
trap on_exit EXIT
trap 'fail "Unexpected validation error at line $LINENO"; exit 1' ERR
for tool in kubectl jq; do
  command -v "$tool" >/dev/null || { fail "Required command missing: $tool (run setup first)"; exit 1; }
done
planes=$(k get deployments -A -l app=istiod -o json)
[[ $(jq '.items | length' <<<"$planes") == 1 ]] || {
  fail 'Cannot identify a single Istio control plane'; exit 1;
}
istio_ns=$(jq -r '.items[0].metadata.namespace' <<<"$planes")
revision=$(jq -r '.items[0].metadata.labels["istio.io/rev"] // "default"' <<<"$planes")
# Read the mesh configuration mounted by istiod, rather than assuming that its
# installation namespace must be the mesh root namespace.
config=$(jq -r '[.items[0].spec.template.spec.volumes[]? |
  select(.name == "config-volume") | .configMap.name][0] // empty' <<<"$planes")
if [[ -z $config ]]; then
  config=istio
  [[ $revision == default ]] || config="istio-$revision"
fi
mesh=$(k -n "$istio_ns" get configmap "$config" -o jsonpath='{.data.mesh}')
root_ns=$(awk '$1 == "rootNamespace:" {gsub(/["\047]/,"",$2); print $2; exit}' <<<"$mesh")
root_ns=${root_ns:-istio-system}
policies=$(k get peerauthentications.security.istio.io -A -o json)
# Istio uses the oldest policy if multiple policies have the same scope.
if jq -e --arg root "$root_ns" '
  [.items[] | select(.metadata.namespace == $root and
    ((.spec.selector.matchLabels // {}) | length) == 0)] |
  sort_by(.metadata.creationTimestamp) | length > 0 and .[0].spec.mtls.mode == "STRICT"
' <<<"$policies" >/dev/null; then
  pass 'The mesh-wide PeerAuthentication policy requires STRICT mTLS'
else
  fail 'No effective mesh-wide STRICT PeerAuthentication policy in the mesh root namespace'
fi

if k get namespace test -o json | jq -e '
  .metadata.labels["istio-injection"] != "enabled" and
  (.metadata.labels["istio.io/rev"] // "") == "" and
  .metadata.labels["istio.io/dataplane-mode"] != "ambient"' >/dev/null &&
  k -n test get pod test -o json | jq -e '
    .status.phase == "Running" and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    all((.spec.containers + (.spec.initContainers // []))[]; .name != "istio-proxy")' >/dev/null; then
  pass 'The test pod is ready and its namespace remains outside the mesh'
else
  fail 'The test pod must be running without mesh injection in namespace test'
  exit 1
fi
# Discover the application container, allowing candidate changes to its name.
client=$(k -n test get pod test -o json | jq -r '.spec.containers[] | select(.name != "istio-proxy") | .name' | head -n 1)
if ! k -n test exec test -c "$client" -- curl --version >/dev/null; then
  fail 'The test pod cannot execute curl'; exit 1
fi
pods=$(k -n default get pods -l app=helloworld -o json)
if jq -e '[.items[] | select(.metadata.deletionTimestamp == null)] |
  length > 0 and all(.[];
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    any((.spec.containers + (.spec.initContainers // []))[]; .name == "istio-proxy"))' <<<"$pods" >/dev/null &&
  k -n default get service helloworld -o json | jq -e 'any(.spec.ports[]; .port == 5000)' >/dev/null; then
  pass 'Helloworld has ready mesh workloads and its required service port'
else
  fail 'Helloworld is missing, unhealthy, or lacks its mesh proxy/service'; exit 1
fi

# Resolve namespace/workload inheritance, including port-specific exceptions.
# Resource names and an omitted versus empty selector do not affect grading.
if jq -e --arg root "$root_ns" --argjson policies "$policies" '
  def oldest: sort_by(.metadata.creationTimestamp) | .[0];
  def inherit($parent): if . == null or . == "UNSET" then $parent else . end;
  [$policies.items[] | select(.metadata.namespace == $root and
    ((.spec.selector.matchLabels // {}) | length) == 0)] | oldest |
  (.spec.mtls.mode | inherit("PERMISSIVE")) as $global |
  [$policies.items[] | select(.metadata.namespace == "default" and
    ((.spec.selector.matchLabels // {}) | length) == 0)] | oldest |
  (.spec.mtls.mode | inherit($global)) as $namespace |
  $pods[0].items | map(select(.metadata.deletionTimestamp == null)) |
  all(.[]; .metadata.labels as $labels |
    [$policies.items[] | select(.metadata.namespace == "default" and
      ((.spec.selector.matchLabels // {}) | length) > 0) |
      select(.spec.selector.matchLabels | to_entries | all(.[]; $labels[.key] == .value))] |
    oldest | (.spec.mtls.mode | inherit($namespace)) as $workload |
    (.spec.portLevelMtls["5000"].mode | inherit($workload)) == "STRICT")
' --slurpfile pods <(printf '%s' "$pods") <<<null >/dev/null; then
  pass 'Helloworld port 5000 has no effective weaker PeerAuthentication override'
else
  fail 'An effective PeerAuthentication setting leaves helloworld port 5000 below STRICT'
fi

# Temporary client only: no policies, labels on existing resources, or
# candidate workload configuration are modified.
probe=$(k -n default create -f - -o jsonpath='{.metadata.name}' <<YAML
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-mtls-check-
  labels:
    sidecar.istio.io/inject: "true"
    istio.io/rev: "$revision"
  annotations:
    sidecar.istio.io/inject: "true"
spec:
  restartPolicy: Never
  containers:
  - name: curl
    image: curlimages/curl:8.12.1
    command: ["sleep", "infinity"]
YAML
)
if ! k -n default wait pod/"$probe" --for=condition=Ready --timeout=180s >/dev/null; then
  fail 'Temporary mesh client did not become ready'; exit 1
fi
if ! k -n default get pod "$probe" -o json | jq -e '
  any((.spec.containers + (.spec.initContainers // []))[]; .name == "istio-proxy")' >/dev/null; then
  fail 'Temporary mesh client did not receive an Istio proxy'; exit 1
fi
url=http://helloworld.default.svc:5000/hello
allowed=false
for attempt in {1..12}; do
  if k -n default exec "$probe" -c curl -- curl --noproxy '*' -fsSI \
    --connect-timeout 3 --max-time 8 "$url" >/dev/null 2>&1; then
    allowed=true; break
  fi
  sleep 3
done
if [[ $allowed == true ]]; then
  pass 'Helloworld remains reachable from a mesh client'
else
  fail 'Helloworld is unreachable from a mesh client; denial alone is insufficient'
fi

# Accept connection reset/empty reply/TLS rejection, not DNS errors, missing
# tools, HTTP denials, or timeouts. Require three consecutive rejections.
rejected=0
for attempt in {1..12}; do
  result=$(k -n test exec test -c "$client" -- sh -c '
    code=$(curl --noproxy "*" -sSI -o /dev/null -w "%{http_code}" \
      --connect-timeout 3 --max-time 8 "$1" 2>/dev/null)
    rc=$?
    printf "%s %s\n" "$rc" "$code"
  ' sh "$url")
  case "$result" in
    '56 000'|'52 000'|'35 000') rejected=$((rejected + 1)) ;;
    *) rejected=0 ;;
  esac
  ((rejected >= 3)) && break
  sleep 3
done
if ((rejected >= 3)); then
  pass 'Plaintext HEAD requests from test/test are rejected at the connection level'
else
  fail "Plaintext access was not consistently rejected (last curl status: $result)"
fi
