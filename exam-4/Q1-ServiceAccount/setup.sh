#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "ERROR: Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo 'ERROR: kubectl is required on the playground controlplane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

# Never overwrite an existing candidate solution or delete unrelated workloads.
namespace=$(k get namespace secret-room --ignore-not-found -o name)
if [[ -n "$namespace" ]]; then
    account=$(k -n secret-room get serviceaccount hidden-user --ignore-not-found -o name)
    if [[ -n "$account" ]]; then
        echo 'ERROR: hidden-user already exists in secret-room. Use a fresh exercise state before preparing this lab.' >&2
        exit 1
    fi
else
    k create namespace secret-room
fi

[[ $(k get namespace secret-room -o jsonpath='{.status.phase}') == Active ]]
[[ -z $(k -n secret-room get serviceaccount hidden-user --ignore-not-found -o name) ]]

printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
