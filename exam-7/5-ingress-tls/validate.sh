#!/usr/bin/env bash
set -Eeuo pipefail
passed=0
failed=0
check() {
  local description=$1
  shift
  if "$@"; then
    printf '[PASS] %s\n' "$description"
    passed=$((passed + 1))
  else
    printf '[FAIL] %s\n' "$description"
    failed=$((failed + 1))
  fi
}
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
  echo 'RESULT: FAILED'
  exit 1
}
k() { kubectl --request-timeout=30s "$@"; }
for tool in kubectl curl awk mktemp; do
  check "Required tool: $tool" command -v "$tool"
done
(( failed == 0 )) || finish
check 'Ingress rocket-ingress exists in namespace rocket' k -n rocket get ingress rocket-ingress
(( failed == 0 )) || finish
annotation=$(k -n rocket get ingress rocket-ingress -o jsonpath='{.metadata.annotations.nginx\.ingress\.kubernetes\.io/ssl-redirect}' 2>/dev/null) || annotation=''
check 'Explicit SSL redirect annotation is true' test "$annotation" = true
class=$(k -n rocket get ingress rocket-ingress -o jsonpath='{.spec.ingressClassName}' 2>/dev/null) || class=''
# The legacy class annotation is also an effective class selection when the
# field is absent; a conflicting explicit field always takes precedence.
if [[ -z $class ]]; then
  class=$(k -n rocket get ingress rocket-ingress -o jsonpath='{.metadata.annotations.kubernetes\.io/ingress\.class}' 2>/dev/null) || class=''
fi
check 'Ingress selects class nginx' test "$class" = nginx
routes=$(k -n rocket get ingress rocket-ingress -o go-template='{{range .spec.rules}}{{$host := .host}}{{range .http.paths}}{{printf "%s %s %s %s " $host .path .pathType .backend.service.name}}{{if .backend.service.port.number}}{{.backend.service.port.number}}{{else}}{{.backend.service.port.name}}{{end}}{{"\n"}}{{end}}{{end}}' 2>/dev/null) || routes=''
route_ok=false
while read -r host path type service port; do
  if [[ $host == rocket-server.local && $path == / && $type == Prefix && $service == rocket-server ]]; then
    if [[ $port == 80 ]]; then
      route_ok=true
    elif [[ -n $port ]]; then
      ports=$(k -n rocket get service rocket-server -o go-template='{{range .spec.ports}}{{printf "%s %d\n" .name .port}}{{end}}' 2>/dev/null) || ports=''
      while read -r name number; do
        if [[ $name == "$port" && $number == 80 ]]; then route_ok=true; fi
      done <<< "$ports"
    fi
  fi
done <<< "$routes"
check 'Host rocket-server.local routes / (Prefix) to rocket-server port 80' "$route_ok"

# Runtime tests use an ephemeral local port-forward, never mutate cluster state.
# TLS Secret names, certificate issuers and filenames are not task requirements.
# -k permits the self-signed certificates shown in the task's example.
tmp=$(mktemp -d)
pf_pid=''
cleanup() {
  if [[ -n $pf_pid ]]; then kill "$pf_pid" 2>/dev/null || true; wait "$pf_pid" 2>/dev/null || true; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
controllers=$(k get pods -A -o go-template='{{range .items}}{{$ns := .metadata.namespace}}{{$pod := .metadata.name}}{{range .spec.containers}}{{printf "%s %s %s\n" $ns $pod .image}}{{end}}{{end}}' 2>/dev/null |
  awk '$3 ~ /(^|\/)ingress-nginx\/controller(:|@)/ {print $1, $2}') || controllers=''
# Overrides permit an existing controller mirrored to a private image registry.
if [[ -n ${CONTROLLER_NAMESPACE:-} && -n ${CONTROLLER_POD:-} ]]; then
  controllers="$CONTROLLER_NAMESPACE $CONTROLLER_POD"
fi
redirect_ok=false
https_ok=false
while read -r ns pod; do
  [[ -n $ns && -n $pod ]] || continue
  # Discover container ports; standard ingress-nginx names are http and https.
  http=$(k -n "$ns" get pod "$pod" -o jsonpath='{.spec.containers[*].ports[?(@.name=="http")].containerPort}' 2>/dev/null) || continue
  https=$(k -n "$ns" get pod "$pod" -o jsonpath='{.spec.containers[*].ports[?(@.name=="https")].containerPort}' 2>/dev/null) || continue
  [[ $http =~ ^[0-9]+$ && $https =~ ^[0-9]+$ ]] || continue
  kubectl -n "$ns" port-forward --address=127.0.0.1 "pod/$pod" ":$http" ":$https" >"$tmp/forward" 2>&1 &
  pf_pid=$!
  for attempt in {1..20}; do
    local_http=$(awk -v p="$http" '$1=="Forwarding" && $5==p {split($3,a,":"); print a[2]; exit}' "$tmp/forward")
    local_https=$(awk -v p="$https" '$1=="Forwarding" && $5==p {split($3,a,":"); print a[2]; exit}' "$tmp/forward")
    [[ -n $local_http && -n $local_https ]] && break
    kill -0 "$pf_pid" 2>/dev/null || break
    sleep 1
  done
  if [[ -n $local_http && -n $local_https ]]; then
    # Allow time for the controller to reconcile a freshly submitted Ingress.
    for attempt in {1..15}; do
      code=$(curl --noproxy '*' -sS --max-time 5 -o /dev/null -D "$tmp/headers" -w '%{http_code}' -H 'Host: rocket-server.local' "http://127.0.0.1:$local_http/" 2>/dev/null) || code=000
      if [[ $code =~ ^30[1278]$ ]] && awk 'tolower($1)=="location:" && tolower($2) ~ /^https:\/\/rocket-server[.]local([:\/\r]|$)/ {ok=1} END {exit !ok}' "$tmp/headers"; then
        redirect_ok=true
      fi
      code=$(curl --noproxy '*' -ksS --max-time 5 -o /dev/null -w '%{http_code}' --resolve "rocket-server.local:$local_https:127.0.0.1" -H 'Host: rocket-server.local' "https://rocket-server.local:$local_https/" 2>/dev/null) || code=000
      [[ $code == 200 ]] && https_ok=true
      if "$redirect_ok" && "$https_ok"; then break; fi
      sleep 2
    done
  fi
  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
  pf_pid=''
  if "$redirect_ok" && "$https_ok"; then break; fi
done <<< "$controllers"
check 'HTTP requests redirect to HTTPS for rocket-server.local' "$redirect_ok"
check 'HTTPS requests for rocket-server.local/ reach a working backend' "$https_ok"
finish
