#!/usr/bin/env bash
set -Eeuo pipefail

# This creation-only exercise needs no seed workloads or host changes.
# PSP is a built-in legacy API; installing a CRD would not restore it.
trap 'printf "ERROR: Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
command -v kubectl >/dev/null 2>&1 || die 'kubectl is required on the playground controlplane.'
[[ $EUID -eq 0 ]] || die 'Run setup.sh as root on controlplane.'
if [[ -z ${KUBECONFIG:-} && -r /etc/kubernetes/admin.conf ]]; then
    export KUBECONFIG=/etc/kubernetes/admin.conf
fi
k() { kubectl --request-timeout=30s "$@"; }

# Query the actual legacy endpoint, rather than relying on cached discovery.
if ! k get --raw /apis/policy/v1beta1/podsecuritypolicies >/dev/null; then
    die 'The legacy PodSecurityPolicy API is unavailable or inaccessible. Use a PSP-capable Kubernetes playground (v1.24 or earlier) with administrator access. Kubernetes v1.25+ cannot run this exercise as written.'
fi
[[ $(k auth can-i create podsecuritypolicies.policy) == yes ]] || die 'The current identity cannot create PodSecurityPolicies.'

# Preserve an existing candidate answer or policy used by another lab.
existing=$(k get podsecuritypolicies.policy pod-psp --ignore-not-found -o name)
[[ -z $existing ]] || die 'pod-psp already exists. Preserve it or explicitly remove it before starting a fresh attempt; setup has left it unchanged.'

# Self-check: the API is accessible, creation is authorized, and the target
# policy is absent. No admission changes, RBAC grants, or Pods are needed by
# the question, and enabling PSP globally could disrupt unrelated workloads.
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
