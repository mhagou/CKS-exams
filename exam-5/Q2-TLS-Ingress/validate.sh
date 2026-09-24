#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only API inspection. No Ingress controller is required by task.txt.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
  echo 'RESULT: FAILED'
  exit 1
}
for tool in kubectl openssl base64; do
  if ! command -v "$tool" >/dev/null; then fail "Required validation tool is available: $tool"; finish; fi
done
ns=secure-ingress
work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT
umask 077
if ! kubectl -n "$ns" get ingress -o name > "$work/ingresses"; then
  fail 'Exercise Ingress resources can be read'
  finish
fi
if [[ ! -s $work/ingresses ]]; then
  fail 'An Ingress exists in the exercise namespace'
  finish
fi
pass 'An Ingress exists in the exercise namespace'

# Accept any candidate resource name, any hostname, and named or numeric ports.
# A TLS host must also be routed by the same Ingress. Wildcard rules are allowed.
matched=false
valid=false
while IFS= read -r ingress; do
  kubectl -n "$ns" get "$ingress" -o go-template='{{range .spec.rules}}{{if .http}}{{.host}}{{"\n"}}{{end}}{{end}}' > "$work/hosts" || continue
  kubectl -n "$ns" get "$ingress" -o go-template='{{range .spec.tls}}{{$secret := .secretName}}{{range .hosts}}{{.}}{{"\t"}}{{$secret}}{{"\n"}}{{end}}{{end}}' > "$work/tls" || continue
  while IFS=$'\t' read -r host secret; do
    [[ -n $host && -n $secret && $secret != '<no value>' ]] || continue
    routes=false
    while IFS= read -r rule; do
      if [[ $host == "$rule" || -z $rule ]]; then routes=true; break; fi
      if [[ $rule == \*.* && $host == *.* && ${host#*.} == "${rule#*.}" ]]; then routes=true; break; fi
    done < "$work/hosts"
    $routes || continue
    matched=true
    [[ $(kubectl -n "$ns" get secret "$secret" -o jsonpath='{.type}' 2>/dev/null) == kubernetes.io/tls ]] || continue
    if ! kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d > "$work/cert"; then continue; fi
    if ! kubectl -n "$ns" get secret "$secret" -o jsonpath='{.data.tls\.key}' 2>/dev/null | base64 -d > "$work/key"; then continue; fi
    openssl x509 -in "$work/cert" -noout -checkend 0 >/dev/null 2>&1 || continue
    # OpenSSL's hostname check handles ordinary and wildcard certificates.
    check_host=$host
    [[ $host != \*.* ]] || check_host="probe.${host#*.}"
    openssl x509 -in "$work/cert" -noout -checkhost "$check_host" >/dev/null 2>&1 || continue
    cert_pub=$(openssl x509 -in "$work/cert" -pubkey -noout 2>/dev/null) || continue
    key_pub=$(openssl pkey -in "$work/key" -passin pass: -pubout 2>/dev/null) || continue
    [[ -n $cert_pub && $cert_pub == "$key_pub" ]] || continue
    valid=true
    break
  done < "$work/tls"
  if $valid; then break; fi
done < "$work/ingresses"
if $matched; then pass 'An Ingress configures TLS for a routed hostname'; else fail 'An Ingress configures TLS for a routed hostname'; fi
if $valid; then
  pass 'The referenced TLS Secret contains an unexpired matching certificate and private key'
else
  fail 'The referenced TLS Secret contains an unexpired matching certificate and private key'
fi
finish
