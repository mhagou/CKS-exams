#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground control plane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

# Preserve an existing namespace and all unrelated resources.
if [[ -z "$(k get namespace seminar --ignore-not-found -o name)" ]]; then
    k create namespace seminar >/dev/null
fi
[[ "$(k get namespace seminar -o jsonpath='{.status.phase}')" == Active ]]

# Reset only the objects explicitly assigned to this exercise.
k -n seminar delete rolebinding k8s-seminar-bind --ignore-not-found --wait=true >/dev/null
k -n seminar delete role k8s-seminar --ignore-not-found --wait=true >/dev/null
k -n seminar delete serviceaccount seminar-sa --ignore-not-found --wait=true >/dev/null

for object in serviceaccount/seminar-sa role/k8s-seminar rolebinding/k8s-seminar-bind; do
    [[ -z "$(k -n seminar get "$object" --ignore-not-found -o name)" ]]
done
[[ "$(k get namespace seminar -o jsonpath='{.status.phase}')" == Active ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
