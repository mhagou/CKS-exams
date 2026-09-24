#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only except for a temporary cross-node test client, removed on exit.
# Native NetworkPolicy and Cilium policies are accepted when enforced by Cilium.
NS=${LAB_NAMESPACE:-default}
passed=0 failed=0 probe=''
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    ((failed == 0))
}
k() { kubectl --request-timeout=30s "$@"; }
cleanup() {
    if [[ -n $probe ]]; then
        if ! k -n "$NS" delete pod "$probe" --ignore-not-found --wait=false >/dev/null; then
            echo "[FAIL] Could not clean up temporary pod $NS/$probe" >&2
            return 1
        fi
    fi
}
trap cleanup EXIT
trap 'fail "Validation could not complete at line $LINENO"; finish || true; exit 1' ERR
trap 'exit 130' INT
trap 'exit 143' TERM
for tool in kubectl jq; do
    if ! command -v "$tool" >/dev/null; then fail "$tool is required; run setup on the playground first"; finish || true; exit 1; fi
done
if ! k get nodes controlplane node01 >/dev/null; then
    fail 'Both playground nodes are accessible'; finish || true; exit 1
fi

pods=$(k -n "$NS" get pods -o json)
nginx=$(jq -c '[.items[] | select(.metadata.labels.app == "nginx" and .metadata.deletionTimestamp == null)]' <<<"$pods")
server=$(jq -r '.[0].metadata.name // empty' <<<"$nginx")
server_node=$(jq -r '.[0].spec.nodeName // empty' <<<"$nginx")
server_ip=$(jq -r '.[0].status.podIP // empty' <<<"$nginx")
if jq -e 'length == 1 and (.[0] | (.spec.hostNetwork != true) and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    any(.spec.containers[]; (.image | test("(^|/)nginx(:|@|$)"))))' <<<"$nginx" >/dev/null; then
    pass 'One ready NGINX pod labeled app=nginx uses the requested image'
else fail 'One ready NGINX pod labeled app=nginx uses the requested image'; fi
# Resolve Deployment ownership rather than requiring a particular deployment name.
rs=$(jq -r '.[0].metadata.ownerReferences[]? | select(.kind == "ReplicaSet") | .name' <<<"$nginx")
deployment=''
if [[ -n $rs ]]; then
    deployment=$(k -n "$NS" get rs "$rs" -o jsonpath='{.metadata.ownerReferences[?(@.kind=="Deployment")].name}' 2>/dev/null || true)
fi
if [[ -n $deployment ]] && k -n "$NS" get deployment "$deployment" -o json | jq -e '
    .spec.replicas == 1 and .status.readyReplicas == 1' >/dev/null; then
    pass 'NGINX is managed by a Deployment with one replica'
else fail 'NGINX is managed by a Deployment with one replica'; fi

client=$(jq -c '.items[] | select(.metadata.name == "curlpod")' <<<"$pods")
container=$(jq -r '.spec.containers[]? | select(.image | test("(^|/)rapidfort/curl(:|@|$)")) | .name' <<<"$client" | head -n 1)
if [[ -n $client ]] && jq -e '.metadata.labels.app == "curlpod" and .spec.hostNetwork != true and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    any(.spec.containers[]; (.image | test("(^|/)rapidfort/curl(:|@|$)")) and
      (((.command // []) + (.args // []) | join(" ")) | test("(^|[ ;])sleep 3600([ ;]|$)")))' <<<"$client" >/dev/null; then
    pass 'curlpod is ready with the requested label, image, and sleep command'
else fail 'curlpod is ready with the requested label, image, and sleep command'; fi

svc=$(k -n "$NS" get service nginx -o json 2>/dev/null || echo '{}')
slices=$(k -n "$NS" get endpointslices -l kubernetes.io/service-name=nginx -o json)
if jq -e 'any(.spec.ports[]?; .port == 80 and (.protocol // "TCP") == "TCP")' <<<"$svc" >/dev/null &&
    jq -e --arg pod "$server" 'any(.items[]; any(.ports[]?; .port == 80) and
        any(.endpoints[]?; .targetRef.name == $pod and .conditions.ready != false))' <<<"$slices" >/dev/null; then
    pass 'Service nginx exposes port 80 and resolves to the NGINX pod on port 80'
else fail 'Service nginx exposes port 80 and resolves to the NGINX pod on port 80'; fi
http() {
    local pod=$1 url=$2
    k -n "$NS" exec "$pod" -c "$container" -- curl --noproxy '*' -fsS --connect-timeout 5 --max-time 15 "$url" >/dev/null
}
if [[ -n $container ]] && http curlpod http://nginx:80/; then
    pass 'curlpod reaches nginx through Service DNS over HTTP'
else fail 'curlpod reaches nginx through Service DNS over HTTP'; fi

agents=$(k get pods -A -l k8s-app=cilium -o json)
agent_exec() {
    local node=$1; shift
    local row ans ap
    row=$(jq -r --arg node "$node" '[.items[] | select(.spec.nodeName == $node and .metadata.deletionTimestamp == null)] | .[0] | [.metadata.namespace, .metadata.name] | @tsv' <<<"$agents")
    IFS=$'\t' read -r ans ap <<<"$row"
    [[ -n $ans && -n $ap ]] || return 1
    # Older Cilium releases used cilium for the in-agent executable.
    k -n "$ans" exec "$ap" -c cilium-agent -- sh -c '
        if command -v cilium-dbg >/dev/null; then exec cilium-dbg "$@"; else exec cilium "$@"; fi
    ' sh "$@"
}
healthy=true
for node in controlplane node01; do
    if ! agent_exec "$node" status --brief; then healthy=false; fi
done
if $healthy; then pass 'Cilium agents are healthy on both nodes'; else fail 'Cilium agents are healthy on both nodes'; fi

# Endpoint state confirms these pods are actually managed by Cilium and policy
# is enforced on the traffic direction tested; mere policy existence is insufficient.
endpoint() {
    local node=$1 name=$2
    agent_exec "$node" endpoint list -o json | jq -c --arg name "$NS/$name" '
        .[] | select(.status["external-identifiers"]["pod-name"] == $name)'
}
client_node=$(jq -r '.spec.nodeName // empty' <<<"$client")
se=$(endpoint "$server_node" "$server" 2>/dev/null || true)
ce=$(endpoint "$client_node" curlpod 2>/dev/null || true)
if [[ -n $se && -n $ce ]]; then pass 'Both application pods are Cilium-managed endpoints'
else fail 'Both application pods are Cilium-managed endpoints'; fi
se=${se:-'{}'}
ce=${ce:-'{}'}
if jq -e '.status.policy.realized["policy-enabled"] | . == "ingress" or . == "both"' <<<"$se" >/dev/null ||
    jq -e '.status.policy.realized["policy-enabled"] | . == "egress" or . == "both"' <<<"$ce" >/dev/null; then
    pass 'Cilium enforces policy on the client-to-NGINX traffic path'
else fail 'Cilium enforces policy on the client-to-NGINX traffic path'; fi

# Same-node traffic is deliberately unencrypted by Cilium. Test across nodes
# without moving or altering candidate workloads. Retain labels and SA identity.
source=curlpod
if [[ -n $server_node && $server_node == "$client_node" && -n $container ]]; then
    remote=controlplane
    [[ $server_node != controlplane ]] || remote=node01
    probe="cks-encryption-probe-$(date +%s)-$RANDOM"
    if jq --arg name "$probe" --arg ns "$NS" --arg node "$remote" '
        {apiVersion:"v1",kind:"Pod",metadata:{name:$name,namespace:$ns,labels:.metadata.labels},
         spec:{nodeName:$node,serviceAccountName:.spec.serviceAccountName,
          imagePullSecrets:.spec.imagePullSecrets,securityContext:.spec.securityContext,
          tolerations:[{operator:"Exists"}],restartPolicy:"Never",
          containers:[.spec.containers[] | select(.image | test("(^|/)rapidfort/curl(:|@|$)")) |
             {name:.name,image:.image,command:["sleep","3600"],securityContext:.securityContext}]}}
    ' <<<"$client" | k create -f - >/dev/null &&
        k -n "$NS" wait --for=condition=Ready "pod/$probe" --timeout=120s >/dev/null; then
        source=$probe
        client_node=$remote
    else fail 'Temporary cross-node client becomes ready'; fi
fi
url="http://$server_ip:80/"
[[ $server_ip != *:* ]] || url="http://[$server_ip]:80/"
if [[ -n $server_ip && -n $client_node && $client_node != "$server_node" && -n $container ]] && http "$source" "$url"; then
    pe=$(endpoint "$client_node" "$source" 2>/dev/null || true)
    if [[ -n $pe && $se != '{}' ]]; then
        pass 'HTTP traffic succeeds between Cilium endpoints on different nodes'
    else fail 'Cross-node test pods are Cilium-managed endpoints'; fi
else fail 'HTTP traffic succeeds between Cilium endpoints on different nodes'; fi

# Query running agents, not Helm values/ConfigMaps. Both supported encryption
# mechanisms require established kernel state, not just an enable flag.
for node in controlplane node01; do
    state=$(agent_exec "$node" encrypt status 2>/dev/null || true)
    if ! grep -Eq '^Msg:[[:space:]]*[^[:space:]]' <<<"$state" && { { grep -Eiq 'Encryption:[[:space:]]*Wireguard' <<<"$state" &&
         grep -Eiq 'Peers:[[:space:]]*[1-9][0-9]*' <<<"$state"; } ||
       { grep -Eiq 'Encryption:[[:space:]]*IPsec' <<<"$state" &&
         grep -Eiq 'Keys in use:[[:space:]]*[1-9][0-9]*' <<<"$state"; }; }; then
        pass "$node has active Cilium encryption state"
    else fail "$node has active Cilium encryption state"; printf '%s\n' "$state"; fi
done
# Encryption status plus successful cross-node traffic is operational evidence;
# this validator does not claim to perform a packet-level cryptographic audit.
if cleanup; then probe=''; else fail 'Temporary test resource cleanup'; probe=''; fi
if finish; then exit 0; else exit 1; fi
