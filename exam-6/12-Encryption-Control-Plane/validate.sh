#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation: no manifests, cluster resources or services are changed.
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
passes=0
failures=0
pass() { printf '[PASS] %s\n' "$1"; passes=$((passes + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failures=$((failures + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
    if (( failures == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( failures == 0 ))
}
if [[ $EUID -ne 0 || $(hostname -s) != controlplane ]]; then
    fail 'Run as root on controlplane to inspect the running control-plane processes.'
    finish; exit 1
fi
for tool in python3 kubectl; do
    if ! command -v "$tool" >/dev/null; then
        fail "Required validation dependency is missing: $tool"
        finish; exit 1
    fi
done

# Python's standard library provides process inspection and TLS probes without
# adding a YAML/JSON parsing package. Arguments support both --flag=value and
# --flag value. Actual running processes are independent of YAML formatting.
runtime_status=0
runtime_output=$(python3 - <<'PY'
import pathlib, socket, ssl, sys, urllib.parse

expected = 'TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256'
passed = failed = 0

def report(ok, text):
    global passed, failed
    print(('[PASS] ' if ok else '[FAIL] ') + text, flush=True)
    passed += bool(ok)
    failed += not ok

def flags(args):
    result = {}
    for i, arg in enumerate(args):
        if arg.startswith('--'):
            key, sep, value = arg.partition('=')
            result[key] = value if sep else (args[i+1] if i+1 < len(args) else '')
    return result

processes = {'kube-apiserver': [], 'etcd': []}
for path in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
    try:
        args = [x.decode() for x in path.read_bytes().split(b'\0') if x]
    except (OSError, UnicodeError):
        continue
    if args and args[0].rsplit('/', 1)[-1] in processes:
        processes[args[0].rsplit('/', 1)[-1]].append(flags(args[1:]))

def probe(host, port, version):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.minimum_version = context.maximum_version = version
    # No application request or credentials are sent. Peer certificate trust is
    # checked separately by kubectl; this probe tests protocol negotiation only.
    with socket.create_connection((host, port), timeout=5) as conn:
        with context.wrap_socket(conn, server_hostname=host) as tls:
            return tls.version()

api = processes['kube-apiserver']
etcd = processes['etcd']
report(len(api) == 1, 'Exactly one local API server process is running')
report(len(etcd) == 1, 'Exactly one local etcd process is running')
if len(api) == 1:
    f = api[0]
    report(f.get('--tls-min-version') == 'VersionTLS13', 'Running API server requires TLS 1.3')
    report(set(f.get('--tls-cipher-suites', '').split(',')) == {expected},
           'Running API server has the requested cipher-suite configuration')
    host = f.get('--bind-address', '0.0.0.0')
    host = {'0.0.0.0': '127.0.0.1', '::': '::1'}.get(host, host)
    port = int(f.get('--secure-port', '6443'))
    tls13_ok = False
    try:
        tls13_ok = probe(host, port, ssl.TLSVersion.TLSv1_3) == 'TLSv1.3'
    except (OSError, ValueError) as exc:
        print('  TLS 1.3 probe: ' + str(exc))
    report(tls13_ok, 'API server accepts a TLS 1.3 handshake')
    rejected = False
    if tls13_ok:
        try:
            probe(host, port, ssl.TLSVersion.TLSv1_2)
        except ssl.SSLError as exc:
            # A timeout/reset alone does not prove a minimum protocol version.
            rejected = 'PROTOCOL_VERSION' in str(exc) or 'UNSUPPORTED_PROTOCOL' in str(exc)
        except OSError:
            pass
    report(rejected, 'API server rejects TLS 1.2 with a protocol-version error')
if len(etcd) == 1:
    f = etcd[0]
    report(set(f.get('--cipher-suites', '').split(',')) == {expected},
           'Running etcd has the requested cipher-suite configuration')
    urls = f.get('--listen-client-urls', 'http://localhost:2379').split(',')
    report(all(urllib.parse.urlparse(u).scheme == 'https' for u in urls),
           'etcd client listeners use TLS')
# TLS 1.3 cipher names are intentionally not compared with the TLS 1.2 suite:
# Go selects TLS 1.3 ciphers independently of the cipher-suites option.
print('Runtime checks: %d passed, %d failed' % (passed, failed))
sys.exit(1 if failed else 0)
PY
) || runtime_status=$?
while IFS= read -r line; do
    printf '%s\n' "$line"
    case $line in
        '[PASS] '*) passes=$((passes + 1)) ;;
        '[FAIL] '*) failures=$((failures + 1)) ;;
    esac
done <<< "$runtime_output"
if (( runtime_status != 0 && failures == 0 )); then
    fail 'Runtime inspection could not complete.'
fi
if kubectl --request-timeout=15s get --raw=/readyz >/dev/null 2>&1; then
    pass 'API server is ready, including its etcd readiness check'
else
    fail 'API server readiness, including etcd, could not be confirmed'
fi
finish
