#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

# Preserve an existing namespace and all unrelated resources. Refuse conflicting
# policies instead of deleting work from another exercise.
existing=$(k get namespace testing --ignore-not-found -o name)
if [[ -n "$existing" ]]; then
    policies=$(k -n testing get networkpolicies -o go-template='{{range .items}}{{if ne .metadata.name "deny-all"}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}')
    if [[ -n "$policies" ]]; then
        echo 'The testing namespace contains unrelated NetworkPolicies; use a clean playground namespace.' >&2
        exit 1
    fi
else
    k create namespace testing >/dev/null
fi
k -n testing delete networkpolicy deny-all --ignore-not-found >/dev/null
[[ $(k get namespace testing -o jsonpath='{.status.phase}') == Active ]]
[[ -z $(k -n testing get networkpolicies -o name) ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
