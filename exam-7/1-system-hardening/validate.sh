#!/usr/bin/env bash
set -Eeuo pipefail

namespace=system-hardening
service=nginx-external
passed=0
failed=0
probe=''
k() { kubectl --request-timeout=20s "$@"; }
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
cleanup() {
    if [[ -n "$probe" ]]; then
        if ! k -n "$namespace" delete pod "$probe" --ignore-not-found --wait=false >/dev/null; then
            echo "Unable to clean up validation pod: $namespace/$probe" >&2
            return 1
        fi
        probe=''
    fi
}
trap cleanup EXIT
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is available to inspect the playground'
    finish
fi
if ! state=$(k -n "$namespace" get service "$service" -o jsonpath='{.spec.type}{"|"}{.spec.clusterIP}{"|"}{.spec.ports[*].nodePort}{"|"}{.spec.externalIPs[*]}{"|"}{.status.loadBalancer.ingress[*]}'); then
    fail "Service $namespace/$service exists and is readable"
    finish
fi
IFS='|' read -r type cluster_ip node_ports external_ips load_balancer <<< "$state"
if [[ "$type" == ClusterIP ]]; then
    pass 'Service type is ClusterIP'
else
    fail "Service type is ClusterIP (found $type)"
fi
if [[ -z "$node_ports" && -z "$external_ips" && -z "$load_balancer" ]]; then
    pass 'Service has no NodePort, external IPs, or load-balancer ingress'
else
    fail 'Service has no NodePort, external IPs, or load-balancer ingress'
fi

# Probe the live service from a temporary cluster Pod. No candidate resources
# are modified. Names, selectors, container names and YAML layout are irrelevant.
if [[ -z "$cluster_ip" || "$cluster_ip" == None ]]; then
    fail 'Service retains an internal virtual IP'
else
    pass 'Service retains an internal virtual IP'
fi
if probe=$(k -n "$namespace" create -f - -o jsonpath='{.metadata.name}' <<YAML
apiVersion: v1
kind: Pod
metadata:
  generateName: service-validation-probe-
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 90
  automountServiceAccountToken: false
  containers:
  - name: client
    image: busybox:1.37
    command: ["sh", "-c", "wget -q -T 10 -O /dev/null http://${service}.${namespace}.svc:80/"]
YAML
); then
    if k -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$probe" --timeout=100s >/dev/null; then
        pass 'nginx remains reachable over HTTP on port 80 inside the cluster'
    else
        fail 'nginx remains reachable over HTTP on port 80 inside the cluster'
        k -n "$namespace" logs "$probe" >&2 || true
        k -n "$namespace" get pod "$probe" -o wide >&2 || true
    fi
else
    fail 'An in-cluster HTTP validation client could be created'
fi
if ! cleanup; then
    fail 'Temporary validation pod was cleaned up'
fi
finish
