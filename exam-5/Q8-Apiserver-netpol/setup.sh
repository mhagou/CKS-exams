#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground. task.txt leaves the namespace/roles unspecified;
# solution.txt supplies api-restrict, role=admin, and role=restricted as context.
# This script leaves both roles able to reach the API, with no exercise policies.
NS=api-restrict
OWNER=cks-q8-apiserver-netpol
IMAGE=${PROBE_IMAGE:-curlimages/curl:8.12.1}
k() { kubectl --request-timeout=20s "$@"; }
die() { echo "ERROR: $*" >&2; exit 1; }
trap 'echo "ERROR: preparation failed at line $LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || die 'Run setup.sh as root on controlplane.'
command -v kubectl >/dev/null || die 'kubectl is required on the Kubernetes control plane.'
k get node controlplane node01 >/dev/null
k wait --for=condition=Ready node/node01 --timeout=120s

# Refuse to reset an unrelated namespace. Only this lab namespace is reset.
existing=$(k get namespace "$NS" --ignore-not-found -o name)
if [[ -n $existing ]]; then
    owner=$(k get namespace "$NS" -o jsonpath='{.metadata.labels.cks-lab-owner}')
    [[ $owner == "$OWNER" ]] || die "$NS already exists and is not owned by this lab."
else
    k create namespace "$NS"
    k label namespace "$NS" "cks-lab-owner=$OWNER"
fi
k delete networkpolicy --all -n "$NS" --wait=true
k delete pod admin-pod restricted-pod cks-q8-preflight -n "$NS" --ignore-not-found --wait=true --timeout=90s

for role in admin restricted; do
    k apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: ${role}-pod
  namespace: $NS
  labels:
    role: $role
spec:
  nodeSelector:
    kubernetes.io/hostname: node01
  automountServiceAccountToken: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: client
      image: $IMAGE
      command: ["sh", "-c", "exec sleep 2147483647"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
        readOnlyRootFilesystem: true
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
YAML
done
k wait -n "$NS" --for=condition=Ready pod/admin-pod pod/restricted-pod --timeout=180s

# Numeric destinations avoid conflating DNS failure with API isolation.
urls=()
port=$(k get service kubernetes -n default -o jsonpath='{.spec.ports[0].port}')
ips=$(k get service kubernetes -n default -o jsonpath='{range .spec.clusterIPs[*]}{.}{"\n"}{end}')
[[ -n $ips && -n $port ]] || die 'Cannot discover the Kubernetes Service.'
while read -r ip; do
    [[ -n $ip ]] || continue
    [[ $ip != *:* ]] || ip="[$ip]"
    urls+=("https://$ip:$port/version")
done <<< "$ips"
endpoints=$(k get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o go-template='{{range .items}}{{$slice := .}}{{range .endpoints}}{{if ne .conditions.ready false}}{{range .addresses}}{{$ip := .}}{{range $slice.ports}}{{printf "%s %v\n" $ip .port}}{{end}}{{end}}{{end}}{{end}}{{end}}')
[[ -n $endpoints ]] || die 'No ready Kubernetes API endpoints discovered.'
while read -r ip port; do
    [[ $ip != *:* ]] || ip="[$ip]"
    urls+=("https://$ip:$port/version")
done <<< "$endpoints"
for pod in admin-pod restricted-pod; do
    for url in "${urls[@]}"; do
        # An HTTP 401/403 also proves network connectivity; no credentials needed.
        k exec -n "$NS" "$pod" -- curl --noproxy '*' -ksS --connect-timeout 3 --max-time 6 -o /dev/null "$url" || die "Initial API connectivity failed for $pod ($url)."
    done
done

# Verify the existing CNI enforces egress, using a disposable probe only.
# This is a generic capability check, not the candidate's API-specific policy.
cleanup() {
    k delete networkpolicy cks-q8-preflight -n "$NS" --ignore-not-found >/dev/null
    k delete pod cks-q8-preflight -n "$NS" --ignore-not-found --wait=true --timeout=60s >/dev/null
}
trap cleanup EXIT
k run cks-q8-preflight -n "$NS" --image="$IMAGE" --restart=Never --labels=cks-q8-preflight=true \
    --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"node01"},"automountServiceAccountToken":false,"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"cks-q8-preflight","image":"'"$IMAGE"'","command":["sh","-c","exec sleep 2147483647"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
k wait -n "$NS" --for=condition=Ready pod/cks-q8-preflight --timeout=180s
k exec -n "$NS" cks-q8-preflight -- curl --noproxy '*' -ksS --connect-timeout 3 --max-time 6 -o /dev/null "${urls[0]}"
k apply -f - <<YAML
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cks-q8-preflight
  namespace: $NS
spec:
  podSelector:
    matchLabels:
      cks-q8-preflight: "true"
  policyTypes: [Egress]
  egress: []
YAML
blocked=false
for attempt in {1..10}; do
    result=$(k exec -n "$NS" cks-q8-preflight -- sh -c 'curl --noproxy "*" -ks --connect-timeout 3 --max-time 5 -o /dev/null "$1"; printf "RC=%s" "$?"' sh "${urls[0]}")
    if [[ $result == RC=7 || $result == RC=28 ]]; then blocked=true; break; fi
    sleep 2
done
[[ $blocked == true ]] || die 'The existing network plugin does not enforce the egress probe. A NetworkPolicy-capable CNI is required; existing networking was preserved.'
cleanup
trap - EXIT
[[ -z $(k get networkpolicy -n "$NS" -o name) ]] || die 'Unexpected policies remain in the lab namespace.'
for pod in admin-pod restricted-pod; do
    k exec -n "$NS" "$pod" -- curl --noproxy '*' -ksS --connect-timeout 3 --max-time 6 -o /dev/null "${urls[0]}"
done
cat <<'READY'
=================================================
 CKS LAB READY
=================================================
Scenario preparation completed successfully.
Namespace: api-restrict
Clients: admin-pod (role=admin), restricted-pod (role=restricted).
Both clients currently have API access. Restrict ordinary clients while retaining admin access.
READY
