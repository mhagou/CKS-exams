#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the Kubernetes playground. The unspecified task namespace is default.
check_pod= check_policy=
cleanup() {
    local status=$?
    trap - EXIT
    if [[ -n "$check_policy" ]]; then
        k -n default delete networkpolicy "$check_policy" --ignore-not-found >/dev/null || status=1
    fi
    if [[ -n "$check_pod" ]]; then
        k -n default delete pod "$check_pod" --ignore-not-found --wait=true --timeout=60s >/dev/null || status=1
    fi
    if (( status != 0 )); then echo 'Scenario preparation failed.' >&2; fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 1' INT TERM
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
k() { kubectl --request-timeout=30s "$@"; }

# Do not erase policies left by other labs or a previous candidate solution.
policies=$(k -n default get networkpolicies -o name)
if [[ -n "$policies" ]]; then
    echo 'The default namespace already has NetworkPolicies. Use a clean playground or remove conflicting lab policies before setup.' >&2
    exit 1
fi
name=cks-netpol-restrict-demo
owner=$(k -n default get pod "$name" --ignore-not-found -o jsonpath='{.metadata.labels.cks-exercise}')
if [[ -n "$(k -n default get pod "$name" --ignore-not-found -o name)" && "$owner" != netpol-restrict ]]; then
    echo "Pod $name belongs to another exercise; refusing to overwrite it." >&2
    exit 1
fi
k -n default apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: cks-netpol-restrict-demo
  labels:
    cks-exercise: netpol-restrict
spec:
  automountServiceAccountToken: false
  containers:
  - name: http
    image: busybox:1.37
    command: [sh, -c, 'mkdir -p /tmp/www; echo ready > /tmp/www/index.html; exec httpd -f -p 8080 -h /tmp/www']
    readinessProbe:
      exec:
        command: [sh, -c, 'wget -q -T 2 -O /dev/null http://127.0.0.1:8080']
      initialDelaySeconds: 1
      periodSeconds: 2
YAML
k -n default wait --for=condition=Ready "pod/$name" --timeout=120s
k -n default exec "$name" -- wget -q -T 3 -O /dev/null http://127.0.0.1:8080
# Verify the playground actually enforces NetworkPolicy before declaring it ready.
# This temporary ingress-only check is removed; the exercise stays unrestricted.
check_pod=$(k -n default create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-netpol-preflight-
spec:
  automountServiceAccountToken: false
  containers:
  - name: client
    image: busybox:1.37
    command: [sh, -c, 'sleep 3600']
YAML
)
k -n default wait --for=condition=Ready "pod/$check_pod" --timeout=120s >/dev/null
ip=$(k -n default get pod "$name" -o jsonpath='{.status.podIP}')
[[ -n "$ip" ]]
if [[ "$ip" == *:* ]]; then ip="[$ip]"; fi
url="http://$ip:8080"
k -n default exec "$check_pod" -- wget -q -T 3 -O /dev/null "$url"
check_policy=$(k -n default create -f - -o jsonpath='{.metadata.name}' <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  generateName: cks-netpol-preflight-
spec:
  podSelector:
    matchLabels:
      cks-exercise: netpol-restrict
  policyTypes: [Ingress]
YAML
)
blocked=false
for attempt in {1..15}; do
    result=$(k -n default exec "$check_pod" -- sh -c 'if wget -q -T 3 -O /dev/null "$1"; then echo ALLOWED; else echo BLOCKED; fi' sh "$url")
    if [[ "$result" == BLOCKED ]]; then blocked=true; break; fi
    sleep 2
done
if [[ "$blocked" != true ]]; then
    echo 'The playground must have a CNI that enforces NetworkPolicy.' >&2
    exit 1
fi
k -n default delete networkpolicy "$check_policy" >/dev/null
check_policy=
restored=false
for attempt in {1..15}; do
    if k -n default exec "$check_pod" -- wget -q -T 3 -O /dev/null "$url" 2>/dev/null; then
        restored=true
        break
    fi
    sleep 2
done
[[ "$restored" == true ]]
k -n default delete pod "$check_pod" --wait=true --timeout=60s >/dev/null
check_pod=
[[ -z "$(k -n default get networkpolicies -o name)" ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nExercise namespace: default\n'
