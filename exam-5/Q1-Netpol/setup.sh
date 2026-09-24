#!/usr/bin/env bash
set -Eeuo pipefail

# task.txt is underspecified. Traffic requirements are inferred from the
# NetworkPolicy in solution.txt; its reversed egress comment is not authoritative.
# Run only on the intended playground. These two namespaces belong to this lab.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
IMAGE=${LAB_IMAGE:-busybox:1.37.0}
OWNER=cks-exam5-q1-netpol
namespaces=(network-security network-security-peer)

# Check ownership of BOTH namespaces before changing either one.
for ns in "${namespaces[@]}"; do
    existing=$(kubectl get namespace "$ns" --ignore-not-found -o name)
    if [[ -n $existing ]]; then
        owner=$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.cks-lab-owner}')
        [[ $owner == "$OWNER" ]] || {
            echo "Refusing to reset unrelated namespace $ns." >&2; exit 1;
        }
    fi
done
for ns in "${namespaces[@]}"; do
    kubectl delete namespace "$ns" --ignore-not-found --wait=true --timeout=120s >/dev/null
    kubectl create namespace "$ns" >/dev/null
    kubectl label namespace "$ns" "cks-lab-owner=$OWNER" >/dev/null
done

create_pod() {
    local ns=$1 name=$2 role=$3
    # All roles expose test listeners, including ports that should be forbidden.
    # HTTP on 5432 is a harmless TCP reachability fixture, not a real database.
    kubectl apply -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels:
    app: $role
spec:
  automountServiceAccountToken: false
  securityContext:
    runAsUser: 1000
    runAsGroup: 1000
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: fixture
      image: $IMAGE
      command: [sh, -ec]
      args:
        - |
          mkdir -p /tmp/www
          echo cks-network-fixture > /tmp/www/index.html
          for port in 8080 8081 5432 5433; do
            httpd -p "\$port" -h /tmp/www
          done
          exec sleep 2147483647
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: [ALL]
      readinessProbe:
        exec:
          command: [sh, -ec, 'wget -q -T 2 -O /dev/null http://127.0.0.1:8080/']
        initialDelaySeconds: 1
        periodSeconds: 2
      resources:
        requests:
          cpu: 5m
          memory: 8Mi
        limits:
          memory: 64Mi
YAML
}
for spec in 'backend-a backend' 'backend-b backend' 'frontend frontend' 'database database' 'other other'; do
    read -r name role <<< "$spec"
    create_pod network-security "$name" "$role"
done
create_pod network-security-peer frontend frontend
create_pod network-security-peer database database
for ns in "${namespaces[@]}"; do
    kubectl wait -n "$ns" --for=condition=Ready pod --all --timeout=180s >/dev/null
    [[ -z $(kubectl get networkpolicy -n "$ns" -o name) ]]
done
# Verify the initial network is usable; no answer policy is installed.
for target in backend-a backend-b database; do
    ip=$(kubectl get pod -n network-security "$target" -o jsonpath='{.status.podIP}')
    [[ $ip == *:* ]] && ip="[$ip]"
    for port in 8080 8081 5432 5433; do
        kubectl exec -n network-security frontend -- wget -q -T 3 -O /dev/null "http://$ip:$port/"
    done
done
for backend in backend-a backend-b; do
    ip=$(kubectl get pod -n network-security database -o jsonpath='{.status.podIP}')
    [[ $ip == *:* ]] && ip="[$ip]"
    kubectl exec -n network-security "$backend" -- wget -q -T 3 -O /dev/null "http://$ip:5432/"
    ip=$(kubectl get pod -n network-security "$backend" -o jsonpath='{.status.podIP}')
    [[ $ip == *:* ]] && ip="[$ip]"
    kubectl exec -n network-security-peer frontend -- wget -q -T 3 -O /dev/null "http://$ip:8080/"
done
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
