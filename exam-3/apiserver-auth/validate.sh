#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation. No cluster resources or configuration are changed.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
summary() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then
        printf 'RESULT: SUCCESS\n'
    else
        printf 'RESULT: FAILED\n'
        return 1
    fi
}
stop() { fail "$*"; summary; exit 1; }
[[ $EUID -eq 0 ]] || stop 'Run as root on controlplane to inspect the running API server.'
for tool in curl python3; do
    command -v "$tool" >/dev/null || stop "Required validation command is missing: $tool"
done
if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    mode=kubeadm
    command -v kubectl >/dev/null || stop 'kubectl is unavailable.'
    kc=(kubectl --kubeconfig=/etc/kubernetes/admin.conf --request-timeout=10s)
elif command -v k3s >/dev/null; then
    mode=k3s
    kc=(k3s kubectl --kubeconfig=/etc/rancher/k3s/k3s.yaml --request-timeout=10s)
else
    stop 'Could not identify a kubeadm or K3s API server.'
fi
endpoint=$("${kc[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}') || stop 'Cannot read the administrative kubeconfig.'
[[ $endpoint == https://* ]] || stop 'The administrative kubeconfig must use HTTPS.'
endpoint=${endpoint%/}

disabled_flag() {
    if [[ $mode == k3s ]]; then
        # K3s embeds kube-apiserver in its server process; /proc has no separate
        # API server argv. The credential-free HTTP checks below verify its
        # effective authentication policy, regardless of the argument source.
        systemctl is-active --quiet k3s || return 1
        systemctl show k3s -p MainPID --value
        return
    fi
    python3 - <<'PY'
import pathlib, sys
identities = []
for path in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
    try:
        args = path.read_bytes().decode().rstrip('\0').split('\0')
    except (OSError, UnicodeError):
        continue
    if not args or pathlib.Path(args[0]).name != 'kube-apiserver':
        continue
    identities.append(path.parent.name)
    value = None
    for i, arg in enumerate(args):
        if arg.startswith('--anonymous-auth='):
            value = arg.split('=', 1)[1]
        elif arg == '--anonymous-auth':
            value = args[i + 1] if i + 1 < len(args) else None
    if value not in ('false', 'False', 'FALSE', '0', 'f', 'F'):
        sys.exit(1)
if not identities:
    sys.exit(1)
print(','.join(sorted(identities)))
PY
}
anonymous_rejected() {
    local path code
    for path in /api /readyz /livez; do
        # --disable ignores .curlrc; no client cert, token, or proxy is used.
        # TLS trust is not this exercise's objective. A 403 is NOT a pass:
        # it means an anonymous request reached authorization.
        code=$(curl --disable --noproxy '*' -ksS --connect-timeout 3 --max-time 8 \
            -o /dev/null -w '%{http_code}' "$endpoint$path" 2>/dev/null) || return 1
        [[ $code == 401 ]] || return 1
    done
}
healthy() {
    "${kc[@]}" get --raw=/readyz >/dev/null 2>&1 &&
        "${kc[@]}" get --raw=/api >/dev/null 2>&1
}

# Allow a pending static-pod/service restart to settle before scoring.
printf 'Waiting for the API server to settle (up to about three minutes)...\n'
deadline=$((SECONDS + 180))
while (( SECONDS < deadline )); do
    if healthy && disabled_flag >/dev/null && anonymous_rejected; then
        break
    fi
    sleep 5
done
if disabled_flag >/dev/null; then
    if [[ $mode == kubeadm ]]; then
        pass 'The running API server uses the required disabled-anonymous flag.'
    else
        pass 'The K3s API server service is running.'
    fi
else
    fail 'The API server is not running with the required setting.'
fi
if anonymous_rejected; then
    pass 'Requests without credentials receive HTTP 401, including health endpoints.'
else
    fail 'Anonymous authentication is not fully disabled, or the API endpoint is unreachable.'
fi

# Catch the common case where a flag change initially works but unauthenticated
# kubelet probes subsequently restart the API server. Do not repair the probes.
stable=1
initial_identity=$(disabled_flag) || stable=0
printf 'Checking API readiness and authentication for 60 seconds...\n'
for ((sample=0; sample<7; sample++)); do
    current_identity=$(disabled_flag) || { stable=0; break; }
    if [[ $current_identity != "$initial_identity" ]] || ! healthy || ! anonymous_rejected; then
        stable=0
        break
    fi
    if (( sample < 6 )); then sleep 10; fi
done
if (( stable )); then
    pass 'The API server remains ready and serves authenticated requests after the change.'
else
    fail 'The API server did not remain healthy with anonymous authentication disabled; inspect its logs and probes.'
fi
summary
