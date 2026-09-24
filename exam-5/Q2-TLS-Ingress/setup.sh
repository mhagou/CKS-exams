#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the Kubernetes playground's controlplane.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
if ! command -v openssl >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    apt-get install -y openssl
  elif command -v dnf >/dev/null; then
    dnf install -y openssl
  else
    echo 'Install OpenSSL before preparing this lab.' >&2
    exit 1
  fi
fi
kubectl get node controlplane node01 >/dev/null
ns=secure-ingress
owner=cks-tls-ingress
if kubectl get namespace "$ns" >/dev/null 2>&1; then
  [[ $(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.cks-lab}') == "$owner" ]] || {
    echo "Namespace $ns already exists and is not owned by this lab; refusing to overwrite it." >&2
    exit 1
  }
else
  kubectl create namespace "$ns" >/dev/null
  kubectl label namespace "$ns" "cks-lab=$owner" >/dev/null
fi
# This namespace is dedicated to the exercise; reruns reset candidate Ingresses.
kubectl -n "$ns" delete ingress --all --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: secure-ingress
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cks-tls-web
  template:
    metadata:
      labels:
        app: cks-tls-web
    spec:
      containers:
        - name: web
          image: nginx:stable-alpine
          ports:
            - containerPort: 80
          readinessProbe:
            httpGet:
              path: /
              port: 80
            initialDelaySeconds: 2
            periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: web-service
  namespace: secure-ingress
spec:
  selector:
    app: cks-tls-web
  ports:
    - port: 80
      targetPort: 80
YAML
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
umask 077
openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
  -subj '/CN=secure-app.example.com' \
  -addext 'subjectAltName=DNS:secure-app.example.com' \
  -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
kubectl -n "$ns" create secret tls secure-app-tls \
  --cert="$work/tls.crt" --key="$work/tls.key" --dry-run=client -o yaml |
  kubectl apply -f - >/dev/null
kubectl -n "$ns" rollout status deployment/web --timeout=180s >/dev/null
[[ $(kubectl -n "$ns" get service web-service -o jsonpath='{.spec.ports[0].port}') == 80 ]]
[[ -n $(kubectl -n "$ns" get endpointslice -l kubernetes.io/service-name=web-service \
  -o jsonpath='{.items[*].endpoints[?(@.conditions.ready==true)].addresses[*]}') ]]
[[ $(kubectl -n "$ns" get secret secure-app-tls -o jsonpath='{.type}') == kubernetes.io/tls ]]
[[ -z $(kubectl -n "$ns" get ingress -o name) ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Exercise namespace: secure-ingress\nBackend: web-service, port 80\nAvailable TLS Secret: secure-app-tls\nCertificate hostname: secure-app.example.com\n'
