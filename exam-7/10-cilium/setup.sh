#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the playground. Re-running preserves candidate policies, so it is
# non-destructive; use a fresh lab namespace to restart a completed exercise.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
kubectl get nodes controlplane node01 >/dev/null
# Installing/replacing a CNI is not a safe generic operation on an existing lab.
kubectl get crd ciliumnetworkpolicies.cilium.io >/dev/null || {
  echo 'A working Cilium playground is required; existing CNI configuration was preserved.' >&2; exit 1;
}
mapfile -t agents < <(kubectl get ds -A -l k8s-app=cilium -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}')
((${#agents[@]})) || { echo 'No Cilium agent DaemonSet found.' >&2; exit 1; }
for agent in "${agents[@]}"; do read -r ns name <<< "$agent"; kubectl -n "$ns" rollout status "ds/$name" --timeout=180s; done
[[ -n $(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{.items[*].status.podIP}') ]] || {
  echo 'Running kube-dns/CoreDNS pods with k8s-app=kube-dns are required.' >&2; exit 1;
}
for ns in database web cks-cilium-outside; do
  if ! kubectl get namespace "$ns" >/dev/null 2>&1; then kubectl create namespace "$ns"; fi
done
# A denied initial API connection makes the independent entity-policy objective
# observable. This policy allows nothing and does not contain the solution.
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: cks-cilium-dev-initial-deny
  namespace: default
  labels:
    cks-lab: cilium
spec:
  podSelector:
    matchLabels:
      env: dev
      cks-lab: cilium
  policyTypes: [Egress]
  egress: []
YAML
# Each pod serves harmless echo traffic on TCP 3306, 8080, 53 and UDP 53.
# Port 3306 simulates the transport of MySQL; no database credentials are needed.
make_pod() {
  local ns=$1 name=$2 app=$3 env=$4 node=$5
  if kubectl -n "$ns" get pod "$name" >/dev/null 2>&1; then
    [[ $(kubectl -n "$ns" get pod "$name" -o jsonpath='{.metadata.labels.cks-lab}') == cilium ]] || {
      echo "Refusing to overwrite unrelated pod $ns/$name" >&2; exit 1;
    }
    return
  fi
  kubectl apply -f - <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: $name
  namespace: $ns
  labels:
    cks-lab: cilium
    app: $app
    env: $env
spec:
  nodeSelector:
    kubernetes.io/hostname: $node
  tolerations:
  - operator: Exists
    effect: NoSchedule
  automountServiceAccountToken: false
  containers:
  - name: probe
    image: python:3.12-alpine
    command: [python3, -u, -c]
    args:
    - |
      import socket, threading, time
      def tcp(port):
          s = socket.socket()
          s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
          s.bind(('0.0.0.0', port)); s.listen()
          while True:
              c, _ = s.accept()
              c.settimeout(2)
              try: c.sendall(c.recv(1024))
              except OSError: pass
              finally: c.close()
      def udp():
          s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
          s.bind(('0.0.0.0', 53))
          while True:
              data, addr = s.recvfrom(2048); s.sendto(data, addr)
      for port in (3306, 8080, 53):
          threading.Thread(target=tcp, args=(port,), daemon=True).start()
      threading.Thread(target=udp, daemon=True).start()
      while True: time.sleep(3600)
    readinessProbe:
      tcpSocket:
        port: 3306
      initialDelaySeconds: 2
      periodSeconds: 2
    resources:
      requests:
        cpu: 10m
        memory: 24Mi
      limits:
        memory: 96Mi
YAML
}
make_pod database cks-db database test node01
make_pod database cks-db-peer peer test controlplane
make_pod web cks-backend backend test controlplane
make_pod web cks-frontend frontend test controlplane
make_pod cks-cilium-outside cks-outsider backend test controlplane
make_pod default cks-dev dev-client dev node01
make_pod default cks-dev-other other-client dev controlplane
for ns in database web cks-cilium-outside default; do
  kubectl -n "$ns" wait pod -l cks-lab=cilium --for=condition=Ready --timeout=180s
done
for pair in 'database cks-db' 'database cks-db-peer' 'web cks-backend' 'web cks-frontend' 'cks-cilium-outside cks-outsider' 'default cks-dev' 'default cks-dev-other'; do
  read -r ns pod <<< "$pair"
  kubectl -n "$ns" get ciliumendpoint "$pod" >/dev/null
  kubectl -n "$ns" exec "$pod" -- python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",3306),2); s.sendall(b"ready"); assert s.recv(5)==b"ready"'
done
# Confirm the required cross-node allowed path works before declaring readiness.
db_ip=$(kubectl -n database get pod cks-db -o jsonpath='{.status.podIP}')
kubectl -n web exec cks-backend -- python3 -c 'import socket,sys; s=socket.create_connection((sys.argv[1],3306),3); s.sendall(b"ready"); assert s.recv(5)==b"ready"' "$db_ip"
printf '\n=================================================\n CKS LAB READY\n=================================================\nScenario preparation completed successfully.\n'
printf 'API-access clients are in default; database and web workloads are in their named namespaces.\nValidation: ./validate.sh [1|2] (default: final stage 2).\nExisting candidate policies are preserved on reruns.\n'
