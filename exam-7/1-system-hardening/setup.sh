#!/usr/bin/env bash
set -Eeuo pipefail

# The question's service name takes precedence over the example commands.
namespace=system-hardening
service=nginx-external
probe=''
k() { kubectl --request-timeout=20s "$@"; }
cleanup() {
    if [[ -n "$probe" ]]; then
        k -n "$namespace" delete pod "$probe" --ignore-not-found --wait=false >/dev/null || true
    fi
}
trap cleanup EXIT
trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run setup as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground control plane.' >&2; exit 1; }

k create namespace "$namespace" --dry-run=client -o yaml | k apply -f - >/dev/null
k -n "$namespace" apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:stable
        ports:
        - containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: 80
          initialDelaySeconds: 2
          periodSeconds: 3
YAML
# Recreate only this exercise's service, resetting candidate changes cleanly.
k -n "$namespace" delete service "$service" --ignore-not-found --wait=true >/dev/null
k -n "$namespace" create service nodeport "$service" --tcp=80:80 --dry-run=client -o yaml |
    k -n "$namespace" apply -f - >/dev/null
k -n "$namespace" patch service "$service" --type=merge -p '{"spec":{"selector":{"app":"nginx"}}}' >/dev/null
k -n "$namespace" rollout status deployment/nginx --timeout=180s >/dev/null
[[ $(k -n "$namespace" get service "$service" -o jsonpath='{.spec.type}') == NodePort ]]
[[ -n $(k -n "$namespace" get service "$service" -o jsonpath='{.spec.ports[0].nodePort}') ]]

# Verify real service traffic using a short-lived in-cluster client.
probe=$(k -n "$namespace" create -f - -o jsonpath='{.metadata.name}' <<YAML
apiVersion: v1
kind: Pod
metadata:
  generateName: service-setup-probe-
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 90
  automountServiceAccountToken: false
  containers:
  - name: client
    image: busybox:1.37
    command: ["sh", "-c", "wget -q -T 10 -O /dev/null http://${service}.${namespace}.svc:80/"]
YAML
)
if ! k -n "$namespace" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$probe" --timeout=100s >/dev/null; then
    k -n "$namespace" logs "$probe" >&2 || true
    exit 1
fi
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nNamespace: %s\nService: %s\n' "$namespace" "$service"
