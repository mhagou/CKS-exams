#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the target playground, using its current kubectl context.
# This script owns only the resources labeled below, not the whole namespace.
ns=database
owner=cks-exam9-rbac
trap 'echo "Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground.' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns" >/dev/null

# Refuse to overwrite unrelated resources that happen to use the same names.
for object in serviceaccount/test-sa pod/web-pod role/test-role-1 rolebinding/test-role-1-binding; do
    existing=$(kubectl -n "$ns" get "$object" --ignore-not-found -o name)
    if [[ -n $existing ]]; then
        label=$(kubectl -n "$ns" get "$object" -o jsonpath='{.metadata.labels.cks-lab}')
        [[ $label == "$owner" ]] || { echo "Refusing to overwrite unrelated $object." >&2; exit 1; }
    fi
done

# Recreate only the lab Pod and original binding to reset immutable fields.
kubectl -n "$ns" delete pod web-pod --ignore-not-found --wait=true >/dev/null
kubectl -n "$ns" delete rolebinding test-role-1-binding --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: test-sa
  namespace: database
  labels:
    cks-lab: cks-exam9-rbac
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: test-role-1
  namespace: database
  labels:
    cks-lab: cks-exam9-rbac
rules:
- apiGroups: ["", "apps"]
  resources: ["pods", "secrets", "deployments", "statefulsets"]
  verbs: ["get", "list", "watch", "create", "update", "patch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: test-role-1-binding
  namespace: database
  labels:
    cks-lab: cks-exam9-rbac
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: test-role-1
subjects:
- kind: ServiceAccount
  name: test-sa
  namespace: database
---
apiVersion: v1
kind: Pod
metadata:
  name: web-pod
  namespace: database
  labels:
    cks-lab: cks-exam9-rbac
spec:
  serviceAccountName: test-sa
  containers:
  - name: web
    image: nginx:stable-alpine
    resources:
      requests:
        cpu: 10m
        memory: 16Mi
YAML
kubectl -n "$ns" wait --for=condition=Ready pod/web-pod --timeout=180s >/dev/null
[[ $(kubectl -n "$ns" get pod web-pod -o jsonpath='{.spec.serviceAccountName}') == test-sa ]]
[[ $(kubectl -n "$ns" get rolebinding test-role-1-binding -o jsonpath='{.roleRef.name}') == test-role-1 ]]
[[ $(kubectl -n "$ns" auth can-i delete secrets --as=system:serviceaccount:database:test-sa) == yes ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
