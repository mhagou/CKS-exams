#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR

[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground.' >&2; exit 1; }
if ! command -v curl >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y curl ca-certificates
  else
    echo 'Install curl on the playground, then rerun setup.' >&2
    exit 1
  fi
fi
k() { kubectl --request-timeout=30s "$@"; }
k get nodes controlplane node01 >/dev/null

# Reuse existing ingress-nginx installations, including Helm installations.
controllers=$(k get pods -A -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$pod := .metadata.name}}{{range .spec.containers}}{{printf "%s %s %s\n" $ns $pod .image}}{{end}}{{end}}' |
  awk '$3 ~ /(^|\/)ingress-nginx\/controller(:|@)/ {print $1, $2}')
if [[ -z $controllers ]]; then
  # Avoid overwriting an unrelated or incomplete installation.
  if k get ingressclass nginx >/dev/null 2>&1 || k get namespace ingress-nginx >/dev/null 2>&1; then
    echo 'An existing nginx class or ingress-nginx namespace has no recognizable controller Pod. Restore that installation before rerunning setup.' >&2
    exit 1
  fi
  # Official bare-metal manifest; image digests are pinned upstream.
  # https://kubernetes.github.io/ingress-nginx/deploy/#bare-metal-clusters
  version=${INGRESS_NGINX_VERSION:-v1.15.1}
  k apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${version}/deploy/static/provider/baremetal/deploy.yaml"
  k -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
else
  ready=false
  while read -r ns pod; do
    if k -n "$ns" wait --for=condition=Ready "pod/$pod" --timeout=120s; then ready=true; break; fi
  done <<< "$controllers"
  "$ready" || { echo 'No existing ingress controller became ready.' >&2; exit 1; }
fi
if ! k get ingressclass nginx >/dev/null 2>&1; then
  k apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
YAML
fi
[[ $(k get ingressclass nginx -o jsonpath='{.spec.controller}') == k8s.io/ingress-nginx ]] || {
  echo 'The nginx IngressClass belongs to another controller; it was left unchanged.' >&2; exit 1;
}

k create namespace rocket --dry-run=client -o yaml | k apply -f -
# Reset only the candidate resource named in the exercise; preserve Secrets and
# all other namespace resources. Reusing this setup restarts the exercise.
k -n rocket delete ingress rocket-ingress --ignore-not-found
k apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rocket-server
  namespace: rocket
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rocket-server
  template:
    metadata:
      labels:
        app: rocket-server
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
---
apiVersion: v1
kind: Service
metadata:
  name: rocket-server
  namespace: rocket
spec:
  selector:
    app: rocket-server
  ports:
  - name: http
    port: 80
    targetPort: 80
YAML
k -n rocket rollout status deployment/rocket-server --timeout=180s
for attempt in {1..30}; do
  addresses=$(k -n rocket get endpointslices -l kubernetes.io/service-name=rocket-server -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready==true)]}{.addresses[*]}{end}')
  [[ -n $addresses ]] && break
  sleep 2
done
[[ -n $addresses ]] || { echo 'Backend has no ready endpoints.' >&2; exit 1; }
[[ -z $(k -n rocket get ingress rocket-ingress --ignore-not-found -o name) ]]
echo '================================================='
echo ' CKS LAB READY'
echo '================================================='
echo 'Scenario preparation completed successfully.'
