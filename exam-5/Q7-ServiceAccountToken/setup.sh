#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground. Re-running records a fresh starting point without
# deleting any candidate or unrelated resources.
readonly namespace=service-account-caution
readonly baseline=cks-q7-serviceaccount-baseline
readonly owner=cks-q7-serviceaccount-token
trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR

if ! command -v kubectl >/dev/null 2>&1; then
    printf 'kubectl is required; run on the configured playground controlplane.\n' >&2
    exit 1
fi

k() { kubectl --request-timeout=30s "$@"; }

if [[ -z $(k get namespace "$namespace" --ignore-not-found -o name) ]]; then
    k create namespace "$namespace" >/dev/null
fi
[[ $(k get namespace "$namespace" -o jsonpath='{.status.phase}') == Active ]]

# Wait for namespace initialization before capturing existing account UIDs.
for ((attempt=0; attempt<30; attempt++)); do
    if [[ -n $(k -n "$namespace" get serviceaccount default --ignore-not-found -o name) ]]; then
        break
    fi
    sleep 1
done
k -n "$namespace" get serviceaccount default -o name >/dev/null

# Do not overwrite a ConfigMap belonging to another exercise or application.
if [[ -n $(k -n "$namespace" get configmap "$baseline" --ignore-not-found -o name) ]]; then
    if [[ $(k -n "$namespace" get configmap "$baseline" -o jsonpath='{.metadata.labels.cks-lab-owner}') != "$owner" ]]; then
        printf 'Baseline ConfigMap name is already in use by another owner.\n' >&2
        exit 1
    fi
fi

uids=$(k get serviceaccounts --all-namespaces -o jsonpath='{range .items[*]}{.metadata.uid}{"\n"}{end}')
[[ -n "$uids" ]]
k -n "$namespace" create configmap "$baseline" \
    --from-literal="uids=$uids" --dry-run=client -o yaml |
    k label --local -f - "cks-lab-owner=$owner" -o yaml |
    k apply -f - >/dev/null

# Verify the stored starting point; no target ServiceAccount is created here.
[[ $(k -n "$namespace" get configmap "$baseline" -o jsonpath='{.data.uids}') == "$uids" ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nSuggested working namespace: %s\n' "$namespace"
