#!/usr/bin/env bash
set -Eeuo pipefail

kubectl() { command kubectl --request-timeout=20s "$@"; }

# Read-only API checks plus a temporary local port-forward; no cluster mutations.
LAB_DIR=${LAB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)}
pass=0
fail=0
report() {
    if [[ $1 == true ]]; then
        printf '[PASS] %s\n' "$2"; pass=$((pass + 1))
    else
        printf '[FAIL] %s\n' "$2"; fail=$((fail + 1))
    fi
}
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$pass" "$fail"
    if ((fail == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
for tool in kubectl jq openssl curl; do
    if ! type -P "$tool" >/dev/null; then
        report false "Required command available: $tool"
        finish
    fi
done
tmp=$(mktemp -d)
pf_pid=''
cleanup() {
    if [[ -n $pf_pid ]]; then kill "$pf_pid" 2>/dev/null || true; wait "$pf_pid" 2>/dev/null || true; fi
    rm -rf "$tmp"
}
trap cleanup EXIT
if ! kubectl get namespaces >/dev/null 2>&1; then
    report false 'Kubernetes API is accessible'; finish
fi

for ns in asia europe; do
    : > "$tmp/eligible.json"
    ok=false
    if kubectl -n "$ns" get deployments -o json > "$tmp/deployments.json" &&
        jq -e '.items[] | select(.spec.replicas == 2 and
            (.status.observedGeneration // 0) >= .metadata.generation and
            (.status.updatedReplicas // 0) == 2 and (.status.readyReplicas // 0) == 2 and
            (.status.availableReplicas // 0) == 2) |
            select(any(.spec.template.spec.containers[];
                (.image | test("(^|/)nginx([:@]|$)")) and
                any(.ports[]?; .containerPort == 80)))' "$tmp/deployments.json" > "$tmp/eligible.json"; then
        ok=true
    fi
    report "$ok" "$ns has a ready two-replica nginx Deployment exposing port 80"
    # Follow Service selectors and ready EndpointSlices, without fixing labels or names.
    ok=false
    if kubectl -n "$ns" get services -o json > "$tmp/services.json" &&
       kubectl -n "$ns" get endpointslices -o json > "$tmp/endpoints.json"; then
        while IFS= read -r svc; do
            selector=$(jq -c --arg svc "$svc" '.items[] | select(.metadata.name == $svc) | .spec.selector // {}' "$tmp/services.json")
            if jq -e --argjson sel "$selector" '
                select(($sel | length) > 0) |
                .spec.template.metadata.labels as $labels |
                select(all($sel | to_entries[]; $labels[.key] == .value))
            ' "$tmp/eligible.json" >/dev/null &&
                jq -e --arg svc "$svc" '.items[] |
                    select(.metadata.labels["kubernetes.io/service-name"] == $svc) |
                    select(any(.ports[]?; .port == 80)) |
                    select(any(.endpoints[]?; .conditions.ready != false))
                ' "$tmp/endpoints.json" >/dev/null; then
                if [[ $ns == europe ]]; then
                    jq --arg svc "$svc" '[.items[] |
                        select(.metadata.labels["kubernetes.io/service-name"] == $svc) |
                        .endpoints[]? | select(.conditions.ready != false) | .addresses[]] | unique' \
                        "$tmp/endpoints.json" > "$tmp/europe-ips.json"
                fi
                ok=true; break
            fi
        done < <(jq -r '.items[] | select(any(.spec.ports[]; .port == 80)) | .metadata.name' "$tmp/services.json")
    fi
    report "$ok" "$ns has a port-80 Service with ready endpoints for the nginx Deployment"
done

ok=false
if kubectl -n world get secret test-secret -o json > "$tmp/secret.json" &&
    jq -e '.type == "kubernetes.io/tls" and .data["tls.crt"] and .data["tls.key"]' "$tmp/secret.json" >/dev/null; then
    jq -r '.data["tls.crt"]' "$tmp/secret.json" | base64 -d > "$tmp/tls.crt"
    jq -r '.data["tls.key"]' "$tmp/secret.json" | base64 -d > "$tmp/tls.key"
    chmod 600 "$tmp/tls.key"
    if openssl x509 -in "$tmp/tls.crt" -checkhost world.universe.mine -noout >/dev/null 2>&1 &&
       openssl x509 -in "$tmp/tls.crt" -checkend 0 -noout >/dev/null 2>&1 &&
       openssl x509 -in "$tmp/tls.crt" -pubkey -noout > "$tmp/cert.pub" 2>/dev/null &&
       openssl pkey -in "$tmp/tls.key" -pubout > "$tmp/key.pub" 2>/dev/null &&
       cmp -s "$tmp/cert.pub" "$tmp/key.pub" &&
       openssl x509 -in "$LAB_DIR/cert.crt" -outform DER > "$tmp/input.der" 2>/dev/null &&
       openssl x509 -in "$tmp/tls.crt" -outform DER > "$tmp/secret.der" 2>/dev/null &&
       cmp -s "$tmp/input.der" "$tmp/secret.der"; then ok=true; fi
fi
report "$ok" 'world/test-secret contains the supplied certificate and matching private key'

ok=false
if kubectl -n world get ingress world -o json > "$tmp/ingress.json" &&
   jq -e '
       any(.spec.tls[]?; .secretName == "test-secret" and any(.hosts[]?; . == "world.universe.mine")) and
       any(.spec.rules[]?; .host == "world.universe.mine" and
           any(.http.paths[]?; .path == "/europe" and .backend.service.name == "europe" and
               (.backend.service.port.number == 80 or .backend.service.port.name != null)))
   ' "$tmp/ingress.json" >/dev/null; then ok=true; fi
report "$ok" 'world/world routes world.universe.mine/europe to europe with TLS using test-secret'

# Confirm the namespace bridge actually targets Europe, including selectorless
# Services backed by EndpointSlices as an alternative to ExternalName.
ok=false
if kubectl -n world get service europe -o json > "$tmp/bridge.json" &&
   jq -e --slurpfile ing "$tmp/ingress.json" '
       .spec.ports as $ports |
       any($ing[].spec.rules[]?; .host == "world.universe.mine" and
           any(.http.paths[]?; .path == "/europe" and .backend.service.name == "europe" and
               (.backend.service.port as $p |
                any($ports[]; .port == 80 and
                    ($p.number == .port or ($p.name != null and $p.name == .name))))))
   ' "$tmp/bridge.json" >/dev/null; then
    if jq -e '.spec.type == "ExternalName" and
        (.spec.externalName | rtrimstr(".")) == "europe.europe.svc.cluster.local"' "$tmp/bridge.json" >/dev/null; then
        ok=true
    elif [[ -s $tmp/europe-ips.json ]] &&
        kubectl -n world get endpointslices -l kubernetes.io/service-name=europe -o json > "$tmp/bridge-endpoints.json" &&
        jq -e --slurpfile ips "$tmp/europe-ips.json" '
            [.items[].endpoints[]? | select(.conditions.ready != false) | .addresses[]] as $actual |
            ($actual | length) > 0 and all($actual[]; . as $ip | $ips[0] | index($ip) != null)
        ' "$tmp/bridge-endpoints.json" >/dev/null; then ok=true; fi
fi
report "$ok" 'world/europe exposes port 80 and forwards to the Europe backend'

# Discover the selected controller by its class and controller-class argument.
# Forward directly to its HTTPS listener so DNS/NodePort reachability is irrelevant.
# Runtime success proves the rewrite works; do not insist on an annotation spelling.
ok=false
class=$(jq -r '.spec.ingressClassName // .metadata.annotations["kubernetes.io/ingress.class"] // empty' "$tmp/ingress.json" 2>/dev/null || true)
controller=k8s.io/ingress-nginx
if [[ -n $class ]]; then
    controller=$(kubectl get ingressclass "$class" -o jsonpath='{.spec.controller}' 2>/dev/null || true)
fi
if [[ -n $controller ]] && kubectl get pods -A -o json > "$tmp/pods.json"; then
    while IFS=$'\t' read -r ns pod port; do
        [[ -n $pod ]] || continue
        kubectl -n "$ns" port-forward --address=127.0.0.1 "pod/$pod" ":$port" > "$tmp/forward.log" 2>&1 &
        pf_pid=$!
        local_port=''
        for ((i=0; i<40; i++)); do
            local_port=$(sed -n 's/^Forwarding from 127\.0\.0\.1:\([0-9]*\) ->.*/\1/p' "$tmp/forward.log" | head -n1)
            [[ -n $local_port ]] && break
            kill -0 "$pf_pid" 2>/dev/null || break
            sleep 0.25
        done
        if [[ -n $local_port && -s $tmp/tls.crt ]]; then
            for ((i=0; i<10; i++)); do
                code=$(curl --silent --show-error --noproxy '*' --max-time 5 \
                    --cacert "$tmp/tls.crt" --resolve "world.universe.mine:$local_port:127.0.0.1" \
                    -o "$tmp/body" -w '%{http_code}' "https://world.universe.mine:$local_port/europe" 2>/dev/null || true)
                if [[ $code == 200 ]] && grep -qi 'Welcome to nginx' "$tmp/body"; then ok=true; break; fi
                sleep 1
            done
        fi
        kill "$pf_pid" 2>/dev/null || true
        wait "$pf_pid" 2>/dev/null || true
        pf_pid=''
        [[ $ok == true ]] && break
    done < <(jq -r --arg controller "$controller" '
        .items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) as $pod |
        .spec.containers[] | select(.image | test("ingress-nginx/controller")) |
        select(any(.args[]?; . == ("--controller-class=" + $controller)) or
            ($controller == "k8s.io/ingress-nginx" and
             ([.args[]? | select(startswith("--controller-class="))] | length) == 0)) |
        .ports[]? | select(.name == "https") |
        [$pod.metadata.namespace, $pod.metadata.name, (.containerPort | tostring)] | @tsv
    ' "$tmp/pods.json")
fi
report "$ok" 'HTTPS /europe serves nginx through the controller with certificate verification and effective rewriting'
finish
