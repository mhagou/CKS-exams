#!/usr/bin/env bash
set -Eeuo pipefail

# task.txt supplies only a title; solution.txt supplies the scenario identity
# and intended permission scope. No permission grants are installed here.
trap 'echo "Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

# Preserve existing resources, including candidate work on repeat runs.
if [[ -z $(k get namespace rbac-minimize --ignore-not-found -o name) ]]; then
    k create namespace rbac-minimize >/dev/null
fi
if [[ -z $(k -n rbac-minimize get serviceaccount app-reader --ignore-not-found -o name) ]]; then
    k -n rbac-minimize create serviceaccount app-reader >/dev/null
fi
[[ $(k get namespace rbac-minimize -o jsonpath='{.status.phase}') == Active ]]
[[ $(k -n rbac-minimize get serviceaccount app-reader -o jsonpath='{.metadata.name}') == app-reader ]]
# A fresh scenario must not already have the exercise's read permissions.
# Do not remove unrelated bindings or overwrite a previous candidate solution.
for resource in pods services deployments.apps; do
    if ! answer=$(k auth can-i list "$resource" -n rbac-minimize \
        --as=system:serviceaccount:rbac-minimize:app-reader \
        --as-group=system:serviceaccounts \
        --as-group=system:serviceaccounts:rbac-minimize \
        --as-group=system:authenticated); then
        [[ $answer == no ]] || exit 1
    fi
    if [[ $answer != no ]]; then
        echo 'Existing permissions overlap this exercise; use a clean exercise identity before setup.' >&2
        exit 1
    fi
done
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
