#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: ./validate.sh /any/path/to/the/certificate-you-fetched
# The task specifies no certificate filename. Accept any PEM or DER file.
# A cluster cannot prove a past download; a supplied file provides that evidence.
# No candidate files or cluster resources are modified by this validator.
passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %s passed, %s failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( failed == 0 ))
}
for tool in kubectl openssl base64 mktemp; do
    if ! command -v "$tool" >/dev/null; then
        fail "Required command unavailable: $tool"
        finish; exit 1
    fi
done
if [[ -z ${KUBECONFIG:-} && -f /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=20s "$@"; }
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
if ! k get --raw=/readyz >/dev/null; then
    fail 'Kubernetes API is accessible with validator credentials'
    finish; exit 1
fi

if [[ $(k get namespace john -o jsonpath='{.status.phase}' 2>/dev/null) == Active ]]; then
    pass 'Namespace john exists and is active'
else
    fail 'Namespace john exists and is active'
fi

# Match the X.509 subject, not the arbitrary CSR resource name or spec.username
# (spec.username records the submitter, often the administrator).
is_john() {
    local subject
    subject=$(openssl "$1" -in "$2" -noout -subject -nameopt sep_multiline,sname 2>/dev/null) || return 1
    [[ $subject =~ (^|$'\n')[[:space:]]*CN[[:space:]]*=[[:space:]]*john($|$'\n') ]]
}
fetched=false
if [[ $# -ge 1 && -r $1 ]]; then
    if openssl x509 -in "$1" -out "$scratch/fetched.pem" 2>/dev/null ||
       openssl x509 -inform DER -in "$1" -out "$scratch/fetched.pem" 2>/dev/null; then
        fetched=true
    fi
fi
csr_found=false approved_found=false issued_found=false fetched_match=false
if k get csr -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' > "$scratch/csrs"; then
    while IFS= read -r name; do
        [[ -n $name ]] || continue
        if ! k get csr "$name" -o jsonpath='{.spec.request}' | base64 -d > "$scratch/request.pem"; then continue; fi
        is_john req "$scratch/request.pem" || continue
        openssl req -in "$scratch/request.pem" -noout -verify >/dev/null 2>&1 || continue
        csr_found=true
        conditions=$(k get csr "$name" -o jsonpath='{range .status.conditions[*]}{.type}{"="}{.status}{"\n"}{end}') || continue
        [[ $conditions == *'Approved=True'* && $conditions != *'Denied=True'* && $conditions != *'Failed=True'* ]] || continue
        approved_found=true
        if ! k get csr "$name" -o jsonpath='{.status.certificate}' | base64 -d > "$scratch/issued.pem"; then continue; fi
        is_john x509 "$scratch/issued.pem" || continue
        openssl x509 -in "$scratch/issued.pem" -noout -checkend 0 >/dev/null 2>&1 || continue
        # Check that the issued certificate is for the key actually requested.
        request_key=$(openssl req -in "$scratch/request.pem" -noout -pubkey) || continue
        certificate_key=$(openssl x509 -in "$scratch/issued.pem" -noout -pubkey) || continue
        [[ $request_key == "$certificate_key" ]] || continue
        openssl x509 -in "$scratch/issued.pem" -noout -purpose > "$scratch/purpose" || continue
        grep -q '^SSL client : Yes$' "$scratch/purpose" || continue
        issued_found=true
        if $fetched; then
            issued_fp=$(openssl x509 -in "$scratch/issued.pem" -noout -fingerprint -sha256)
            fetched_fp=$(openssl x509 -in "$scratch/fetched.pem" -noout -fingerprint -sha256)
            [[ $issued_fp != "$fetched_fp" ]] || fetched_match=true
        fi
    done < "$scratch/csrs"
else
    fail 'CSR objects can be inspected with validator credentials'
fi
if $csr_found; then pass 'A valid CSR requests the user identity john'; else fail 'A valid CSR requests the user identity john'; fi
if $approved_found; then pass 'A CSR for john is approved without denial or failure'; else fail 'A CSR for john is approved without denial or failure'; fi
if $issued_found; then pass 'An approved CSR has a non-expired client certificate for john and the requested key'; else fail 'An approved CSR has a non-expired client certificate for john and the requested key'; fi
if $fetched_match; then
    pass 'The fetched certificate matches a certificate issued for john'
else
    fail 'Supply the fetched certificate as an argument: ./validate.sh /path/to/certificate (PEM or DER)'
fi

# Inspect server-side RBAC rules. Separate rules, wildcards, and additional
# permissions are accepted: the question does not say "only list".
pods=false secrets=false
rule_template='{{range .rules}}{{range .apiGroups}}{{if eq . ""}}core{{else}}{{.}}{{end}},{{end}}|{{range .resources}}{{.}},{{end}}|{{range .verbs}}{{.}},{{end}}|{{range .resourceNames}}{{.}},{{end}}{{"\n"}}{{end}}'
if k get role john-role -n john -o go-template="$rule_template" > "$scratch/rules"; then
    while IFS='|' read -r groups resources verbs names; do
        [[ -z $names ]] || continue
        [[ ,$groups == *',core,'* || ,$groups == *',*,'* ]] || continue
        [[ ,$verbs == *',list,'* || ,$verbs == *',*,'* ]] || continue
        if [[ ,$resources == *',pods,'* || ,$resources == *',*,'* ]]; then pods=true; fi
        if [[ ,$resources == *',secrets,'* || ,$resources == *',*,'* ]]; then secrets=true; fi
    done < "$scratch/rules"
fi
if $pods && $secrets; then pass 'Role john-role grants list access to pods and secrets in john'; else fail 'Role john-role grants list access to pods and secrets in john'; fi

binding_template='{{.roleRef.apiGroup}}|{{.roleRef.kind}}|{{.roleRef.name}}{{"\n"}}{{range .subjects}}{{.apiGroup}}|{{.kind}}|{{.name}}{{"\n"}}{{end}}'
if k get rolebinding john-role-binding -n john -o go-template="$binding_template" > "$scratch/binding" &&
   grep -qxF 'rbac.authorization.k8s.io|Role|john-role' "$scratch/binding" &&
   grep -qxF 'rbac.authorization.k8s.io|User|john' "$scratch/binding"; then
    pass 'RoleBinding john-role-binding binds Role john-role to User john in john'
else
    fail 'RoleBinding john-role-binding binds Role john-role to User john in john'
fi
for resource in pods secrets; do
    if result=$(k auth can-i list "$resource" -n john --as=john --as-group=system:authenticated) && [[ $result == yes ]]; then
        pass "kubectl auth confirms john can list $resource in john"
    else
        fail "kubectl auth confirms john can list $resource in john"
    fi
done
finish
