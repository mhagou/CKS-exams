#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation of live API objects. The task does not require a Pod or
# Deployment. A Pod-level override alone cannot disable an account's default.
readonly namespace=service-account-caution
readonly baseline=cks-q7-serviceaccount-baseline
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then
        printf 'RESULT: SUCCESS\n'
        exit 0
    fi
    printf 'RESULT: FAILED\n'
    exit 1
}
k() { kubectl --request-timeout=30s "$@"; }

if ! command -v kubectl >/dev/null 2>&1; then
    fail 'Cannot evaluate ServiceAccounts: kubectl is unavailable.'
    finish
fi
if ! marker=$(k -n "$namespace" get configmap "$baseline" -o jsonpath='{.metadata.labels.cks-lab-owner}') ||
    [[ "$marker" != cks-q7-serviceaccount-token ]]; then
    fail 'Cannot evaluate account creation: lab baseline is missing or invalid.'
    finish
fi
if ! uids=$(k -n "$namespace" get configmap "$baseline" -o jsonpath='{.data.uids}') || [[ -z "$uids" ]]; then
    fail 'Cannot read the starting ServiceAccount inventory.'
    finish
fi

# Read the persisted boolean from the API, not a candidate manifest. Unset or
# true does not satisfy disabling automounting at the ServiceAccount level.
if ! accounts=$(k get serviceaccounts --all-namespaces -o go-template='{{range .items}}{{.metadata.namespace}}/{{.metadata.name}} {{.metadata.uid}} {{printf "%v" .automountServiceAccountToken}}{{"\n"}}{{end}}'); then
    fail 'Cannot inspect live ServiceAccounts across namespaces.'
    finish
fi

created=0
secured=0
while read -r account uid automount; do
    [[ -n "$uid" ]] || continue
    if [[ $'\n'"$uids"$'\n' == *$'\n'"$uid"$'\n'* ]]; then
        continue
    fi
    created=$((created + 1))
    if [[ "$automount" == false ]]; then
        secured=$((secured + 1))
        printf 'Matching ServiceAccount: %s\n' "$account"
    fi
done <<< "$accounts"

if ((created > 0)); then
    pass 'A ServiceAccount was created after scenario preparation.'
else
    fail 'No ServiceAccount was created after scenario preparation.'
fi
if ((secured > 0)); then
    pass 'A newly created ServiceAccount disables token automounting by default.'
else
    fail 'No newly created ServiceAccount disables token automounting by default.'
fi
finish
