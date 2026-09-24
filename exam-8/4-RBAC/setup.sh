#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }
bot=(--as=system:serviceaccount:ci-cd:ci-bot --as-group=system:serviceaccounts --as-group=system:serviceaccounts:ci-cd --as-group=system:authenticated)

# Only lab-owned RBAC is reset. Preserve the namespace and its workloads.
k create namespace ci-cd --dry-run=client -o yaml | k apply -f - >/dev/null
k create serviceaccount ci-bot -n ci-cd --dry-run=client -o yaml | k apply -f - >/dev/null
k apply -f - >/dev/null <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: ci-bot-role
rules:
- apiGroups: [""]
  resources: ["pods", "services", "configmaps"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets"]
  verbs: ["get", "list", "watch", "create", "update", "delete"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["clusterrolebindings", "rolebindings"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
- apiGroups: ["rbac.authorization.k8s.io"]
  resources: ["roles", "clusterroles"]
  verbs: ["bind"]
YAML
# roleRef is immutable, so recreate this lab-owned binding on reset.
k delete clusterrolebinding ci-bot-binding --ignore-not-found >/dev/null
k create clusterrolebinding ci-bot-binding --clusterrole=ci-bot-role --serviceaccount=ci-cd:ci-bot >/dev/null
k get serviceaccount ci-bot -n ci-cd >/dev/null
for resource in pods services configmaps deployments.apps replicasets.apps; do
  for verb in get list watch create update delete; do
    [[ $(k "${bot[@]}" auth can-i "$verb" "$resource" -n ci-cd) == yes ]]
  done
done
# Confirm the initial exposure without persisting a privileged binding.
k "${bot[@]}" create clusterrolebinding "ci-bot-setup-probe-$$" --clusterrole=cluster-admin --serviceaccount=ci-cd:ci-bot --dry-run=server -o name >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
