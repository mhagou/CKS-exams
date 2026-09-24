#!/usr/bin/env bash
set -Eeuo pipefail
passes=0
failures=0
pass() { printf '[PASS] %s\n' "$*"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failures=$((failures + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
  if ((failures == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
  ((failures == 0))
}
for dependency in kubectl jq; do
  if ! command -v "$dependency" >/dev/null; then
    fail "Required dependency missing: $dependency"; finish; exit 1
  fi
done
work=$(mktemp -d)
probe="cks-mtls-check-$(date +%s)-$$"
cleanup() {
  kubectl -n restricted-zone delete pod "$probe" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'fail "Unexpected validation error at line $LINENO"; finish; exit 1' ERR

# Admission of a fresh, unannotated Pod checks conventional AND revision injection.
if kubectl create -f - > /dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $probe
  namespace: restricted-zone
spec:
  containers:
  - name: client
    image: curlimages/curl:8.12.1
    command: ["sleep", "3650d"]
YAML
then
  kubectl -n restricted-zone get pod "$probe" -o json > "$work/probe.json"
  if jq -e '[.spec.containers[], .spec.initContainers[]?] | any(.name == "istio-proxy")' "$work/probe.json" >/dev/null; then
    pass 'New Pods automatically receive an Istio sidecar'
  else
    fail 'New Pods automatically receive an Istio sidecar'
  fi
else
  fail 'New Pods automatically receive an Istio sidecar (probe creation failed)'
fi

# Policy semantics, not resource names or YAML formatting. A mesh-wide STRICT
# baseline is also valid. Override for installations using a custom root namespace.
# Reference: https://istio.io/latest/docs/reference/config/security/peer_authentication/
root_namespace=${ISTIO_ROOT_NAMESPACE:-istio-system}
if kubectl get peerauthentications.security.istio.io -A -o json > "$work/policies.json" &&
   kubectl -n restricted-zone get pods -o json > "$work/pods.json"; then
  if jq -e --arg root "$root_namespace" --slurpfile pods "$work/pods.json" '
    def matches_existing_pod:
      (.spec.selector.matchLabels // {} | to_entries) as $selector |
      any($pods[0].items[]; .metadata.labels as $labels |
        all($selector[]; $labels[.key] == .value));
    def baseline($ns):
      [.items[] | select(.metadata.namespace == $ns)
       | select((.spec.selector.matchLabels // {} | length) == 0)]
      | sort_by(.metadata.creationTimestamp) | .[0].spec.mtls.mode // "UNSET";
    baseline($root) as $mesh | baseline("restricted-zone") as $ns |
    (if $ns == "UNSET" then $mesh else $ns end) == "STRICT"
    and all(.items[] | select(.metadata.namespace == "restricted-zone" or
      (.metadata.namespace == $root and matches_existing_pod));
      ((.spec.mtls.mode // "UNSET") as $mode |
       # Namespace-wide policy overrides the mesh baseline; workload overrides
       # must not re-enable plaintext, including port-level exceptions.
       if (.spec.selector.matchLabels // {} | length) == 0 then true
       else ($mode == "STRICT" or $mode == "UNSET") and
         all((.spec.portLevelMtls // {})[]; (.mode // "UNSET") == "UNSET" or .mode == "STRICT")
       end))
  ' "$work/policies.json" >/dev/null; then
    pass 'Namespace-wide STRICT mTLS baseline with no plaintext workload/port exceptions'
  else
    fail 'Namespace-wide STRICT mTLS baseline with no plaintext workload/port exceptions'
  fi
else
  fail 'PeerAuthentication policies are readable'
fi

if kubectl -n restricted-zone get pods -l app=httpbin -o json > "$work/server.json" &&
   jq -e '[.items[] | select(.metadata.deletionTimestamp == null)] |
     length > 0 and all(.[];
       ([.spec.containers[], .spec.initContainers[]?] | any(.name == "istio-proxy")) and
       any(.status.conditions[]?; .type == "Ready" and .status == "True"))' "$work/server.json" >/dev/null; then
  pass 'Running payment-service Pods have ready Istio sidecars'
else
  fail 'Running payment-service Pods have ready Istio sidecars'
fi

healthy=false
if kubectl -n restricted-zone wait --for=condition=Ready "pod/$probe" --timeout=120s >/dev/null 2>&1; then
  for attempt in {1..12}; do
    if kubectl -n restricted-zone exec "$probe" -c client -- curl --noproxy '*' \
      -fsS --connect-timeout 3 --max-time 8 http://httpbin.restricted-zone.svc:8000/status/200 > /dev/null 2>&1; then
      healthy=true; break
    fi
    sleep 2
  done
fi
if $healthy; then pass 'Payment service is reachable from an injected client';
else fail 'Payment service is reachable from an injected client'; fi

# Use the original legacy Pod, and verify it still really is a plaintext client.
legacy_ok=false
if kubectl -n default get pod cks-mtls-legacy -o json > "$work/legacy.json" &&
   jq -e '([.spec.containers[], .spec.initContainers[]?] | all(.name != "istio-proxy")) and
     any(.status.conditions[]?; .type == "Ready" and .status == "True")' "$work/legacy.json" >/dev/null &&
   kubectl -n default exec cks-mtls-legacy -c client -- curl --version > /dev/null 2>&1; then
  legacy_ok=true
fi
# A numeric ClusterIP avoids mistaking a DNS failure for successful enforcement.
service_ip=$(kubectl -n restricted-zone get service httpbin -o jsonpath='{.spec.clusterIP}')
case "$service_ip" in *:*) service_ip="[$service_ip]" ;; esac
blocked=true
if $legacy_ok && $healthy && [[ -n $service_ip && $service_ip != None ]]; then
  for attempt in {1..3}; do
    code=$(kubectl -n default exec cks-mtls-legacy -c client -- curl --noproxy '*' \
      -sS -o /dev/null -w '%{http_code}' --connect-timeout 3 --max-time 8 \
      "http://$service_ip:8000/status/200" 2>/dev/null) && rc=0 || rc=$?
    # Any HTTP response proves plaintext reached an HTTP server, even a 403/503.
    # Only transport rejection counts; exec errors and missing curl do not.
    if [[ $code != 000 || ! $rc =~ ^(7|28|52|56)$ ]]; then blocked=false; fi
  done
else
  blocked=false
fi
if $blocked; then pass 'Legacy Pod without a sidecar cannot access the payment service over plaintext';
else fail 'Legacy Pod without a sidecar cannot access the payment service over plaintext'; fi
finish
