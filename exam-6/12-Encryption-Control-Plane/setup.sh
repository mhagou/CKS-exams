#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the disposable controlplane playground. No worker changes needed.
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
manifest_dir=/etc/kubernetes/manifests
backup_dir=/var/backups/cks-control-plane-tls
work=''
changed=0
finished=0
cleanup() {
    local rc=$?
    trap - EXIT
    if (( changed && ! finished )); then
        echo 'Preparation failed; restoring the manifests from this run.' >&2
        for name in kube-apiserver etcd; do
            cp -p "$work/$name.original" "$work/$name.restore"
            mv -f "$work/$name.restore" "$manifest_dir/$name.yaml"
        done
        echo 'Allow kubelet time to restore control-plane health.' >&2
    fi
    [[ -z $work ]] || rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run as root on controlplane.'
[[ $(hostname -s) == controlplane ]] || fail 'This script requires controlplane.'
for tool in kubectl python3 openssl timeout awk curl tar sha256sum; do
    command -v "$tool" >/dev/null || fail "Required tool is missing: $tool"
done
openssl s_client -help 2>&1 | awk '/-tls1_3/ { found=1 } END { exit !found }' || fail 'OpenSSL must support TLS 1.3.'
for name in kube-apiserver etcd; do
    [[ -f $manifest_dir/$name.yaml && ! -L $manifest_dir/$name.yaml ]] || fail "Missing regular static Pod manifest: $name"
done
kubectl --request-timeout=15s get --raw=/readyz >/dev/null || fail 'The initial API server must be ready.'

# crictl is explicitly used by task.txt. Download only if it is absent.
if ! command -v crictl >/dev/null; then
    case $(uname -m) in
        x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) fail 'Unsupported architecture for automatic crictl installation.' ;;
    esac
    version=$(kubectl version --client -o json | python3 -c 'import json,sys; v=json.load(sys.stdin)["clientVersion"]; print("v"+v["major"]+"."+v["minor"].rstrip("+")+".0")')
    work=$(mktemp -d)
    asset="crictl-${version}-linux-${arch}.tar.gz"
    base="https://github.com/kubernetes-sigs/cri-tools/releases/download/${version}"
    curl -fsSL --retry 3 "$base/$asset" -o "$work/$asset"
    curl -fsSL --retry 3 "$base/$asset.sha256" -o "$work/checksum"
    digest=$(awk 'NR==1 {print $1}' "$work/checksum")
    [[ $digest =~ ^[[:xdigit:]]{64}$ ]] || fail 'Invalid upstream checksum.'
    (cd "$work"; printf '%s  %s\n' "$digest" "$asset" | sha256sum -c - >/dev/null)
    tar -xzf "$work/$asset" -C "$work" crictl
    install -m 0755 "$work/crictl" /usr/local/bin/crictl
    rm -rf "$work"
    work=''
fi
crictl ps >/dev/null || fail 'crictl cannot reach the existing CRI endpoint; check its configuration.'

install -d -m 0700 "$backup_dir"
# Stage outside the watched directory, on the same filesystem for atomic rename.
work=$(mktemp -d /etc/kubernetes/.cks-tls.XXXXXX)
for name in kube-apiserver etcd; do
    cp -p "$manifest_dir/$name.yaml" "$work/$name.original"
    if [[ ! -e $backup_dir/$name.yaml ]]; then
        cp -p "$manifest_dir/$name.yaml" "$backup_dir/$name.yaml"
    fi
done

# Only remove the exercise's flags. Preserve every other byte. Refuse unfamiliar
# YAML representations before changing anything instead of risking a broad rewrite.
python3 - "$work" <<'PY'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
for name, flags in [('kube-apiserver', ['tls-min-version', 'tls-cipher-suites']),
                    ('etcd', ['cipher-suites'])]:
    src = root / (name + '.original')
    lines = src.read_text().splitlines(keepends=True)
    output = []
    for line in lines:
        if any('--' + flag in line for flag in flags) and not line.lstrip().startswith('#'):
            pattern = r'''\s*-\s*["']?--(?:''' + '|'.join(flags) + r''')=[^\s"']*["']?\s*(?:#.*)?'''
            if not re.fullmatch(pattern, line.rstrip('\n')):
                raise SystemExit('Unsupported flag layout in ' + name + '; no manifests changed.')
            continue
        output.append(line)
    (root / (name + '.new')).write_text(''.join(output))
PY
for name in etcd kube-apiserver; do
    if ! cmp -s "$work/$name.original" "$work/$name.new"; then
        chmod --reference="$work/$name.original" "$work/$name.new"
        chown --reference="$work/$name.original" "$work/$name.new"
        changed=1
        mv -f "$work/$name.new" "$manifest_dir/$name.yaml"
    fi
done

# Read actual host-visible process arguments, not stale mirror Pod status.
baseline_running() {
    python3 - <<'PY'
import pathlib, sys
seen = set()
for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
    try:
        args = p.read_bytes().split(b'\0')
    except (OSError, ProcessLookupError):
        continue
    name = args[0].rsplit(b'/', 1)[-1].decode(errors='replace')
    forbidden = {'kube-apiserver': (b'--tls-min-version', b'--tls-cipher-suites'),
                 'etcd': (b'--cipher-suites',)}
    if name in forbidden:
        if any(a.split(b'=', 1)[0] in forbidden[name] for a in args[1:]):
            sys.exit(1)
        seen.add(name)
sys.exit(0 if seen == set(forbidden) else 1)
PY
}
echo 'Waiting for the initial control-plane state...'
ready=0
for ((attempt=0; attempt<90; attempt++)); do
    if baseline_running && kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then
        ready=$((ready + 1))
        (( ready < 3 )) || break
    else
        ready=0
    fi
    sleep 3
done
(( ready >= 3 )) || fail 'Control-plane preparation did not become healthy.'
crictl ps >/dev/null || fail 'CRI inspection failed after preparation.'
finished=1
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
