#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. An enforcing NetworkPolicy CNI
# must already be installed; this lab does not replace cluster networking.
owner=cks-netpol-deny
client="cks-setup-probe-$$"
client_created=false
cleanup() {
  if "$client_created"; then
    kubectl -n hello delete pod "$client" --ignore-not-found --wait=false >/dev/null || true
  fi
}
trap cleanup EXIT
trap 'echo "Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground.' >&2; exit 1; }

# Refuse to reset namespaces belonging to another exercise.
for ns in moon hello; do
  if kubectl get namespace "$ns" >/dev/null 2>&1; then
    actual=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.cks-lab}')
    [[ "$actual" == "$owner" ]] || {
      echo "Namespace $ns already exists and is not owned by this lab; resolve the conflict first." >&2
      exit 1
    }
  fi
done
for ns in moon hello; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then
    kubectl create namespace "$ns"
    kubectl label namespace "$ns" "cks-lab=$owner"
  fi
done
kubectl label namespace hello ns=test --overwrite
# Check for conflicts before resetting any existing candidate work.
for ns in moon hello; do
  policies=$(kubectl -n "$ns" get networkpolicy -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
  while IFS= read -r policy; do
    [[ -z "$policy" || ( "$ns" == moon && "$policy" == np-restriction ) ]] || {
      echo "Additional policies in $ns could interfere with this lab; resolve them first." >&2
      exit 1
    }
  done <<< "$policies"
done
# Reset only the named exercise policy. Other policies are left untouched.
kubectl -n moon delete networkpolicy np-restriction --ignore-not-found
kubectl -n moon delete pod nginx-pod --ignore-not-found --wait=true --timeout=60s
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: nginx-pod
  namespace: moon
  labels:
    run: nginx-pod
    cks-lab: cks-netpol-deny
spec:
  containers:
  - name: nginx
    image: nginx:stable-alpine
    ports:
    - containerPort: 80
    readinessProbe:
      httpGet:
        path: /
        port: 80
      initialDelaySeconds: 1
      periodSeconds: 2
YAML
kubectl -n moon wait --for=condition=Ready pod/nginx-pod --timeout=180s
ip=$(kubectl -n moon get pod nginx-pod -o jsonpath='{.status.podIP}')
[[ -n "$ip" ]]
case "$ip" in *:*) ip="[$ip]" ;; esac
client_created=true
kubectl -n hello run "$client" --image=busybox:1.37 --restart=Never --command -- sleep 600
kubectl -n hello wait --for=condition=Ready "pod/$client" --timeout=180s
kubectl -n hello exec "$client" -- wget -q -T 5 -O /dev/null "http://$ip:80/"
[[ $(kubectl -n moon get pod nginx-pod -o jsonpath='{.metadata.labels.run}') == nginx-pod ]]
[[ $(kubectl get namespace hello -o jsonpath='{.metadata.labels.ns}') == test ]]
[[ -z $(kubectl -n moon get networkpolicy -o name) ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
