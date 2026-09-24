#!/usr/bin/env bash
set -Eeuo pipefail
# Stage 1: only web/backend ingress; unrestricted egress.
# The prose takes precedence over the examples allowing same-namespace ingress.
# Stage 2: authoritative prose requires ONLY web/backend TCP 3306 ingress
# and ONLY kube-system/kube-dns TCP+UDP 53 egress. Both check API access.
# No resources or policies are created, changed, or repaired here.
passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed+1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed+1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if ((failed == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
}
trap 'fail "Validation interrupted by an unexpected error at line $LINENO"; finish; exit 1' ERR
stage=${1:-2}
[[ $stage == 1 || $stage == 2 ]] || { fail 'Usage: validate.sh [1|2]'; finish; exit 1; }
command -v kubectl >/dev/null || { fail 'kubectl is available'; finish; exit 1; }
ip() { kubectl -n "$1" get pod "$2" -o jsonpath='{.status.podIP}'; }
# Exit 42 is a genuine connection failure. Execution/tool errors cannot count
# as successful denials. Echo responses prove the positive control is alive.
probe() {
  local ns=$1 pod=$2 host=$3 port=$4 mode=${5:-tcp}
  kubectl -n "$ns" exec -i "$pod" -- python3 - "$host" "$port" "$mode" <<'PY'
import socket, sys, struct, ssl
host, port, mode = sys.argv[1], int(sys.argv[2]), sys.argv[3]
try:
    s = socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET,
                      socket.SOCK_DGRAM if mode in ('udp', 'dns-udp') else socket.SOCK_STREAM)
    s.settimeout(3); s.connect((host, port))
    if mode == 'api':
        s = ssl._create_unverified_context().wrap_socket(s, server_hostname='kubernetes')
        s.sendall(b'GET /version HTTP/1.0\r\nHost: kubernetes\r\n\r\n')
        if not s.recv(1024).startswith(b'HTTP/'): sys.exit(43)
    elif mode.startswith('dns-'):
        q = b'\x45\x67\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00' + b'\x0akubernetes\x07default\x03svc\x07cluster\x05local\x00\x00\x01\x00\x01'
        s.sendall(struct.pack('!H', len(q)) + q if mode == 'dns-tcp' else q)
        data = s.recv(4096)
        if mode == 'dns-tcp':
            while len(data) < 14:
                chunk = s.recv(4096)
                if not chunk: sys.exit(43)
                data += chunk
            data = data[2:]
        # An actual DNS answer (including NXDOMAIN on a custom cluster domain)
        # proves transport reachability without assuming the cluster's domain.
        if len(data) < 12 or data[:2] != q[:2] or not (data[2] & 128): sys.exit(43)
    else:
        s.sendall(b'cks-probe')
        if s.recv(32) != b'cks-probe': sys.exit(43)
except (OSError, ssl.SSLError):
    sys.exit(42)
PY
}
check() {
  local expected=$1 description=$2 rc=0
  shift 2
  # Retry only allowed connections to accommodate policy convergence.
  if probe "$@" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  if [[ $expected == allow && $rc == 42 ]]; then
    sleep 2
    if probe "$@" >/dev/null 2>&1; then rc=0; else rc=$?; fi
  fi
  if [[ $expected == allow && $rc == 0 || $expected == deny && $rc == 42 ]]; then
    pass "$description"
  else
    fail "$description (probe exit $rc; 42=unreachable, other nonzero=probe error)"
  fi
}
for pair in 'database cks-db' 'database cks-db-peer' 'web cks-backend' 'web cks-frontend' 'cks-cilium-outside cks-outsider' 'default cks-dev' 'default cks-dev-other'; do
  read -r ns pod <<< "$pair"
  if ! kubectl -n "$ns" wait "pod/$pod" --for=condition=Ready --timeout=10s >/dev/null 2>&1 ||
     ! kubectl -n "$ns" exec "$pod" -- python3 -c 'import socket; s=socket.create_connection(("127.0.0.1",3306),2); s.sendall(b"ok"); assert s.recv(2)==b"ok"' >/dev/null 2>&1; then
    fail "Healthy test fixture $ns/$pod (rerun setup if missing)"; finish; exit 1
  fi
done
pass 'Test fixtures are running and their local listeners respond'
outsider=$(ip cks-cilium-outside cks-outsider)
# Test both database identities: policy must cover the namespace, not one app.
for target in cks-db cks-db-peer; do
  dest=$(ip database "$target")
  check allow "web/backend reaches $target TCP 3306" web cks-backend "$dest" 3306
  other=deny; [[ $stage == 1 ]] && other=allow
  check "$other" "Stage $stage: backend access to $target TCP 8080" web cks-backend "$dest" 8080
  check deny "web/frontend cannot reach $target" web cks-frontend "$dest" 3306
  check deny "web/frontend cannot reach $target TCP 8080" web cks-frontend "$dest" 8080
  check deny "backend label in another namespace cannot reach $target" cks-cilium-outside cks-outsider "$dest" 3306
  peer=cks-db-peer; [[ $target == cks-db-peer ]] && peer=cks-db
  check deny "Stage $stage: same-namespace access to $target is denied" database "$peer" "$dest" 3306
  for port in 3306 8080 53; do
    # Validate the external listener from an unrestricted source first.
    check allow "Egress control target TCP $port is reachable" web cks-backend "$outsider" "$port"
    check "$other" "Stage $stage: $target egress to non-DNS TCP $port" database "$target" "$outsider" "$port"
  done
  check allow 'Non-DNS UDP 53 control listener is reachable' web cks-backend "$outsider" 53 udp
  check "$other" "Stage $stage: $target egress to non-DNS UDP 53" database "$target" "$outsider" 53 udp
done
mapfile -t dns_ips < <(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.status.podIP}{"\n"}{end}')
if ((${#dns_ips[@]} == 0)); then fail 'DNS endpoints exist'; fi
for dns in "${dns_ips[@]}"; do
  [[ -n $dns ]] || { fail 'DNS endpoint has an IP'; continue; }
  for pod in cks-db cks-db-peer; do
    check allow "$pod DNS UDP 53 to $dns" database "$pod" "$dns" 53 dns-udp
    check allow "$pod DNS TCP 53 to $dns" database "$pod" "$dns" 53 dns-tcp
  done
done
api=$(kubectl -n default get service kubernetes -o jsonpath='{.spec.clusterIP}')
for pod in cks-dev cks-dev-other; do
  check allow "env=dev client $pod reaches kube-apiserver HTTPS" default "$pod" "$api" 443 api
done
# The task explicitly asks for an entities-based policy, not just open traffic.
entities=$(kubectl -n default get ciliumnetworkpolicies -o jsonpath='{range .items[*]}{.spec.egress[*].toEntities[*]}{" "}{.specs[*].egress[*].toEntities[*]}{" "}{end}')
entities+=" $(kubectl get ciliumclusterwidenetworkpolicies -o jsonpath='{range .items[*]}{.spec.egress[*].toEntities[*]}{" "}{.specs[*].egress[*].toEntities[*]}{" "}{end}')"
if [[ " $entities " == *' kube-apiserver '* ]]; then
  pass 'An explicit kube-apiserver entity egress rule exists'
else
  fail 'An explicit kube-apiserver entity egress rule exists'
fi
finish
if ((failed == 0)); then exit 0; else exit 1; fi
