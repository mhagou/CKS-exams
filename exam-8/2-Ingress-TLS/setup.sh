#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run this script as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl must be configured for the playground.' >&2; exit 1; }
# jq is used to inspect live selectors, ports, and controller containers reliably.
missing=()
for tool in curl openssl jq; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
command -v timeout >/dev/null || missing+=(coreutils)
if ((${#missing[@]})); then
  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y "${missing[@]}"
  elif command -v dnf >/dev/null; then
    dnf install -y "${missing[@]}"
  else
    echo "Install required commands: ${missing[*]}" >&2; exit 1
  fi
fi
kubectl get nodes controlplane node01 >/dev/null
work=$(mktemp -d)
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Preserve existing ingress installations. Do not overwrite a conflicting class.
class=$(kubectl get ingressclass nginx --ignore-not-found -o jsonpath='{.spec.controller}')
if [[ -n $class && $class != k8s.io/ingress-nginx ]]; then
  echo 'The existing nginx IngressClass belongs to another controller; resolve this conflict first.' >&2
  exit 1
fi
controllers=$(kubectl get pods -A -o json | jq -r '
  .items[] | select(any(.spec.containers[]; .image | contains("ingress-nginx/controller"))) |
  [.metadata.namespace,.metadata.name] | @tsv')
if [[ -z $controllers ]]; then
  # Do not overwrite a pre-existing installation which simply has no Pods yet.
  existing=$(kubectl get deployment,daemonset -A -o json | jq -r '
    .items[] | select(any(.spec.template.spec.containers[]; .image | contains("ingress-nginx/controller"))) | .metadata.name')
  if [[ -n $existing ]]; then
    echo 'An ingress-nginx workload exists but has no Pods. Restore its health and rerun setup.' >&2
    exit 1
  fi
  if kubectl get namespace ingress-nginx >/dev/null 2>&1; then
    echo 'Namespace ingress-nginx already exists without a discoverable controller; inspect it before installation.' >&2
    exit 1
  fi
  # Official upstream bare-metal manifest; images include upstream digest pins.
  version=${INGRESS_NGINX_VERSION:-v1.15.1}
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${version}/deploy/static/provider/baremetal/deploy.yaml" \
    -o "$work/controller.yaml"
  kubectl apply -f "$work/controller.yaml" >/dev/null
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=300s
  kubectl -n ingress-nginx wait --for=condition=complete job/ingress-nginx-admission-create job/ingress-nginx-admission-patch --timeout=180s
elif [[ -z $class ]]; then
  kubectl apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: IngressClass
metadata:
  name: nginx
spec:
  controller: k8s.io/ingress-nginx
YAML
fi

kubectl create namespace secure-web --dry-run=client -o yaml | kubectl apply -f - >/dev/null
# Reset only the candidate's named exercise resource.
kubectl -n secure-web delete ingress secure-ingress --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: secure-app
  namespace: secure-web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: secure-app
  template:
    metadata:
      labels:
        app: secure-app
    spec:
      containers:
      - name: web
        image: nginx:stable-alpine
        command: ["/bin/sh", "-c"]
        args:
        - "printf 'CKS secure-app\\n' > /usr/share/nginx/html/index.html; exec nginx -g 'daemon off;'"
        ports:
        - name: http
          containerPort: 80
        readinessProbe:
          httpGet:
            path: /
            port: http
          initialDelaySeconds: 2
          periodSeconds: 2
---
apiVersion: v1
kind: Service
metadata:
  name: secure-app
  namespace: secure-web
spec:
  selector:
    app: secure-app
  ports:
  - name: http
    port: 80
    targetPort: http
YAML
# Preserve a valid existing exercise certificate across reruns.
kubectl -n secure-web get secret web-tls --ignore-not-found -o json > "$work/secret.json"
valid=false
if [[ -s $work/secret.json ]]; then
  jq -r '.data["tls.crt"] // empty' "$work/secret.json" | base64 -d > "$work/tls.crt"
  jq -r '.data["tls.key"] // empty' "$work/secret.json" | base64 -d > "$work/tls.key"
  if openssl x509 -in "$work/tls.crt" -checkend 86400 -noout >/dev/null 2>&1 &&
     openssl x509 -in "$work/tls.crt" -checkhost secure-app.company.com -noout >/dev/null 2>&1 &&
     openssl x509 -in "$work/tls.crt" -pubkey -noout > "$work/cert.pub" 2>/dev/null &&
     openssl pkey -in "$work/tls.key" -pubout > "$work/key.pub" 2>/dev/null &&
     cmp -s "$work/cert.pub" "$work/key.pub"; then
    valid=true
  fi
fi
if [[ $valid == false ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -subj '/CN=secure-app.company.com' -addext 'subjectAltName=DNS:secure-app.company.com' \
    -keyout "$work/tls.key" -out "$work/tls.crt" >/dev/null 2>&1
  kubectl -n secure-web create secret tls web-tls --cert="$work/tls.crt" --key="$work/tls.key" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null
fi
kubectl -n secure-web rollout status deployment/secure-app --timeout=180s
kubectl -n secure-web get endpointslices -l kubernetes.io/service-name=secure-app -o json |
  jq -e 'any(.items[].endpoints[]?; .conditions.ready == true)' >/dev/null
kubectl get ingressclass nginx -o json | jq -e '.spec.controller == "k8s.io/ingress-nginx"' >/dev/null
kubectl get pods -A -o json | jq -e '
  any(.items[]; any(.spec.containers[];
      (.image | contains("ingress-nginx/controller")) and
      all(.args[]?;
        ((startswith("--controller-class=") | not) or . == "--controller-class=k8s.io/ingress-nginx") and
        ((startswith("--watch-namespace=") | not) or . == "--watch-namespace=" or . == "--watch-namespace=secure-web")))
      and any(.status.conditions[]?; .type == "Ready" and .status == "True"))' >/dev/null
kubectl -n secure-web get secret web-tls -o json |
  jq -e '.data["tls.crt"] != null and .data["tls.key"] != null' >/dev/null
[[ -z $(kubectl -n secure-web get ingress secure-ingress --ignore-not-found -o name) ]]
echo '================================================='
echo ' CKS LAB READY'
echo '================================================='
echo 'Scenario preparation completed successfully.'
