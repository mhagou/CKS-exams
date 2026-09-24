#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: ./validate.sh [context]
# KUBECONFIG can point to a separate candidate kubeconfig. Context names and
# CSR names are deliberately not graded: the task contains inconsistent names.
expected_user='60099@internal.users'
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
for tool in kubectl openssl base64; do
    if ! command -v "$tool" >/dev/null; then fail "Required tool is available: $tool"; finish; fi
done
umask 077
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
trap 'fail "Unexpected validation error on line $LINENO"; finish' ERR

# Select a context by certificate identity, accepting arbitrary local aliases.
# Flattening resolves both embedded data and certificate/key file references.
contexts=()
if [[ $# -gt 0 ]]; then
    contexts=("$1")
else
    mapfile -t contexts < <(kubectl config view -o jsonpath='{range .contexts[*]}{.name}{"\n"}{end}')
fi
selected=''
for context in "${contexts[@]}"; do
    if ! kubectl --context="$context" config view --minify --flatten --raw > "$tmp/source" 2> "$tmp/error"; then
        continue
    fi
    cert=$(kubectl --kubeconfig="$tmp/source" config view --raw -o jsonpath='{.users[0].user.client-certificate-data}')
    if [[ -z $cert ]] || ! printf '%s' "$cert" | base64 -d > "$tmp/client.crt" 2>/dev/null; then continue; fi
    subject=$(openssl x509 -in "$tmp/client.crt" -noout -subject -nameopt multiline,sname 2>/dev/null) || continue
    if ! printf '%s\n' "$subject" | grep -Eq '^[[:space:]]*CN[[:space:]]*=[[:space:]]*60099@internal\.users[[:space:]]*$'; then continue; fi
    selected=$context
    break
done
if [[ -z $selected ]]; then
    fail "A kubeconfig context contains a client certificate for $expected_user"
    finish
fi
pass "A kubeconfig context contains a client certificate for $expected_user"
field() { kubectl --kubeconfig="$tmp/source" config view --raw -o "jsonpath={$1}"; }
key=$(field '.users[0].user.client-key-data')
if [[ -z $key ]] || ! printf '%s' "$key" | base64 -d > "$tmp/client.key"; then
    fail 'Client private key is available'; finish
fi
# Rebuild only in a private temporary directory, excluding tokens, exec plugins
# and impersonation. Thus runtime checks exercise the actual client certificate.
server=$(field '.clusters[0].cluster.server')
ca=$(field '.clusters[0].cluster.certificate-authority-data')
cluster_args=("--server=$server")
if [[ -n $ca ]]; then
    printf '%s' "$ca" | base64 -d > "$tmp/ca.crt"
    cluster_args+=("--certificate-authority=$tmp/ca.crt")
fi
for entry in 'insecure-skip-tls-verify' 'tls-server-name' 'proxy-url'; do
    value=$(field ".clusters[0].cluster.$entry")
    [[ -z $value ]] || cluster_args+=("--$entry=$value")
done
k=(kubectl --kubeconfig="$tmp/probe" --request-timeout=15s)
"${k[@]}" config set-cluster target "${cluster_args[@]}" >/dev/null
"${k[@]}" config set-credentials candidate --client-certificate="$tmp/client.crt" --client-key="$tmp/client.key" >/dev/null
"${k[@]}" config set-context probe --cluster=target --user=candidate --namespace=default >/dev/null
"${k[@]}" config use-context probe >/dev/null

# A Forbidden response naming the user proves authentication AND denial.
# Unauthorized, TLS failures, connection errors and anonymous denial must fail.
if output=$("${k[@]}" get pods -n default --limit=1 2>&1); then
    pass 'Client certificate authenticates successfully to the Kubernetes API'
    fail 'The user cannot list pods in namespace default'
elif [[ $output == *'(Forbidden)'* && $output == *"User \"$expected_user\" cannot list resource \"pods\""* && $output == *'in the namespace "default"'* ]]; then
    pass "The API authenticates the client certificate as $expected_user"
    pass 'The user cannot list pods in namespace default'
else
    fail 'The API authenticates the certificate and returns the expected authorization denial'
    printf '%s\n' "$output" >&2
fi
finish
