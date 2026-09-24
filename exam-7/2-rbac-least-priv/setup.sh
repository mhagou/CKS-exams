#!/usr/bin/env bash
set -Eeuo pipefail

trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

# Kubernetes users are identities, not API objects; no certificate is needed
# for this impersonation-based exercise.
if ! k get namespace dev-z >/dev/null 2>&1; then
    k create namespace dev-z
fi
k apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  namespace: dev-z
  name: dev-user-access
rules:
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["*"]
YAML

# roleRef is immutable, so replace only this exercise's binding if necessary.
if k get rolebinding dev-user-binding -n dev-z >/dev/null 2>&1; then
    ref=$(k get rolebinding dev-user-binding -n dev-z -o jsonpath='{.roleRef.apiGroup}/{.roleRef.kind}/{.roleRef.name}')
    if [[ "$ref" != rbac.authorization.k8s.io/Role/dev-user-access ]]; then
        k delete rolebinding dev-user-binding -n dev-z
    fi
fi
k apply -f - <<'YAML'
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  namespace: dev-z
  name: dev-user-binding
subjects:
- kind: User
  apiGroup: rbac.authorization.k8s.io
  name: jacob
roleRef:
  kind: Role
  apiGroup: rbac.authorization.k8s.io
  name: dev-user-access
YAML

[[ $(k get namespace dev-z -o jsonpath='{.status.phase}') == Active ]]
for verb in get list watch create update patch delete deletecollection; do
    answer=$(k auth can-i "$verb" pods -n dev-z --as=jacob --as-group=system:authenticated)
    [[ "$answer" == yes ]]
done
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
