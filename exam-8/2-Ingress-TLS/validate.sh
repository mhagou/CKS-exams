#!/usr/bin/env bash
set -Eeuo pipefail

passes=0
fails=0
pass() { echo "[PASS] $*"; passes=$((passes + 1)); }
fail() { echo "[FAIL] $*"; fails=$((fails + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passes" "$fails"
  if ((fails == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
  echo 'RESULT: FAILED'; exit 1
}
for tool in kubectl jq curl openssl timeout; do
  if ! command -v "$tool" >/dev/null; then fail "Required validation command is missing: $tool"; fi
done
((fails == 0)) || finish
work=$(mktemp -d)
pf_pid=''
cleanup() {
  if [[ -n $pf_pid ]]; then kill "$pf_pid" 2>/dev/null || true; wait "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'fail "Validation encountered an unexpected error at line $LINENO"; finish' ERR
if kubectl -n secure-web get ingress secure-ingress -o json > "$work/ingress.json"; then
  pass 'Ingress secure-web/secure-ingress exists'
else
  fail 'Ingress secure-web/secure-ingress exists'; finish
fi
check() {
  local description=$1 expression=$2
  if jq -e "$expression" "$work/ingress.json" >/dev/null; then pass "$description"; else fail "$description"; fi
}
# Resolve both named and numeric backend Service ports.
if kubectl -n secure-web get service secure-app -o json > "$work/service.json" &&
   jq -e --slurpfile svc "$work/service.json" '
     any(.spec.rules[]?; .host == "secure-app.company.com" and
       any(.http.paths[]?; .path == "/" and .backend.service.name == "secure-app" and
         (.backend.service.port as $p |
           any($svc[0].spec.ports[]; (.protocol // "TCP") == "TCP" and
             (($p.number != null and .port == $p.number) or
              ($p.name != null and .name == $p.name))))))' "$work/ingress.json" >/dev/null; then
  pass 'Host and root path route to a valid secure-app Service port'
else
  fail 'Host and root path route to a valid secure-app Service port'
fi
check 'TLS uses web-tls for secure-app.company.com' '
  any(.spec.tls[]?; .secretName == "web-tls" and any(.hosts[]?; . == "secure-app.company.com"))'
check 'Ingress selects the nginx class' '
  .spec.ingressClassName == "nginx" or
  ((.spec.ingressClassName // "") == "" and .metadata.annotations["kubernetes.io/ingress.class"] == "nginx")'
check 'SSL passthrough annotation is explicitly false' '
  .metadata.annotations["nginx.ingress.kubernetes.io/ssl-passthrough"] == "false"'
# Redirect is checked at runtime: controller defaults and either redirect annotation
# are valid when they actually enforce HTTPS.
if ! kubectl -n secure-web get secret web-tls -o json > "$work/secret.json" ||
   ! jq -r '.data["tls.crt"] // empty' "$work/secret.json" | base64 -d > "$work/expected.crt" ||
   ! expected=$(openssl x509 -in "$work/expected.crt" -noout -fingerprint -sha256 2>/dev/null); then
  fail 'Existing TLS Secret contains a readable certificate'; finish
fi
# Locate the real controller without depending on its namespace or resource name.
kubectl get pods -A -o json > "$work/pods.json"
controller=$(jq -r '
  [.items[] | select(.metadata.deletionTimestamp == null) |
   select(any(.status.conditions[]?; .type == "Ready" and .status == "True")) |
   . as $pod | .spec.containers[] |
   select(.image | contains("ingress-nginx/controller")) |
   select(all(.args[]?;
     ((startswith("--controller-class=") | not) or . == "--controller-class=k8s.io/ingress-nginx") and
     ((startswith("--watch-namespace=") | not) or . == "--watch-namespace=" or . == "--watch-namespace=secure-web"))) |
   [$pod.metadata.namespace,$pod.metadata.name,
    ([.ports[]? | select(.name == "http") | .containerPort][0] // 80),
    ([.ports[]? | select(.name == "https") | .containerPort][0] // 443)]] |
   .[0] // [] | @tsv' "$work/pods.json")
if [[ -z $controller ]]; then fail 'A ready nginx ingress controller is available for runtime tests'; finish; fi
read -r controller_ns controller_pod http_port https_port <<< "$controller"
kubectl -n "$controller_ns" port-forward --address=127.0.0.1 "pod/$controller_pod" \
  ":$http_port" ":$https_port" > "$work/forward.log" 2>&1 &
pf_pid=$!
http_local=''
https_local=''
for ((i=0; i<50; i++)); do
  http_local=$(sed -n "s/^Forwarding from 127.0.0.1:\([0-9]*\) -> $http_port\$/\1/p" "$work/forward.log" | head -n 1)
  https_local=$(sed -n "s/^Forwarding from 127.0.0.1:\([0-9]*\) -> $https_port\$/\1/p" "$work/forward.log" | head -n 1)
  [[ -n $http_local && -n $https_local ]] && break
  kill -0 "$pf_pid" 2>/dev/null || break
  sleep 0.2
done
if [[ -z $http_local || -z $https_local ]]; then
  fail 'Connection to the ingress controller can be established'; cat "$work/forward.log"; finish
fi
host=secure-app.company.com
https_ok=false
redirect_ok=false
cert_ok=false
# Allow a short reconciliation period after the candidate applies the Ingress.
for ((i=0; i<15; i++)); do
  code=$(curl --noproxy '*' --silent --show-error --insecure --max-time 5 \
    --resolve "$host:$https_local:127.0.0.1" -H "Host: $host" \
    -o "$work/body" -w '%{http_code}' "https://$host:$https_local/" 2>/dev/null) || code=000
  if [[ $code == 200 && $(cat "$work/body") == 'CKS secure-app' ]]; then https_ok=true; else https_ok=false; fi
  code=$(curl --noproxy '*' --silent --max-time 5 -H "Host: $host" \
    -D "$work/headers" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$http_local/" ) || code=000
  location=$(sed -n 's/^[Ll][Oo][Cc][Aa][Tt][Ii][Oo][Nn]:[[:space:]]*//p' "$work/headers" | tr -d '\r' | head -n 1)
  redirect_ok=false
  if [[ $code =~ ^30[1278]$ && $location =~ ^https://secure-app\.company\.com(:443)?/($|\?) ]]; then redirect_ok=true; fi
  timeout 6 openssl s_client -connect "127.0.0.1:$https_local" -servername "$host" \
    </dev/null > "$work/peer" 2>/dev/null || true
  actual=$(openssl x509 -in "$work/peer" -noout -fingerprint -sha256 2>/dev/null) || actual=''
  if [[ -n $actual && $actual == "$expected" ]]; then cert_ok=true; else cert_ok=false; fi
  [[ $https_ok == true && $redirect_ok == true && $cert_ok == true ]] && break
  sleep 2
done
if [[ $https_ok == true ]]; then pass 'HTTPS serves the secure-app application at /'; else fail 'HTTPS serves the secure-app application at /'; fi
if [[ $cert_ok == true ]]; then pass 'The live TLS endpoint serves the web-tls certificate'; else fail 'The live TLS endpoint serves the web-tls certificate'; fi
if [[ $redirect_ok == true ]]; then pass 'HTTP requests redirect to HTTPS for the required host'; else fail 'HTTP requests redirect to HTTPS for the required host'; fi
finish
