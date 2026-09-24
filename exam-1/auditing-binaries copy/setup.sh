#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the playground controlplane as root.
STATE=/var/lib/cks-auditing-binaries
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl ssh curl tar sha256sum sha512sum python3 systemctl awk; do
    command -v "$cmd" >/dev/null || { echo "Missing prerequisite: $cmd" >&2; exit 1; }
done
if ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install python3-yaml first.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y python3-yaml
fi
install -d -m 700 "$STATE"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
# Official release archives include both the executable and benchmark configuration.
if ! command -v kube-bench >/dev/null; then
    case $(uname -m) in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) echo 'Unsupported architecture'; exit 1;; esac
    curl -fsSL https://api.github.com/repos/aquasecurity/kube-bench/releases/latest -o "$work/release.json"
    version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"].lstrip("v"))' "$work/release.json")
    base="https://github.com/aquasecurity/kube-bench/releases/download/v$version"
    archive="kube-bench_${version}_linux_${arch}.tar.gz"
    curl -fsSL "$base/$archive" -o "$work/$archive"
    curl -fsSL "$base/kube-bench_${version}_checksums.txt" -o "$work/checksums"
    (cd "$work"; awk -v f="$archive" '$2 == f || $2 == "*"f' checksums > selected; test -s selected; sha256sum -c selected)
    mkdir "$work/unpacked"
    tar -xzf "$work/$archive" -C "$work/unpacked"
    test ! -e /etc/kube-bench || { echo 'Existing /etc/kube-bench must be inspected before installing.'; exit 1; }
    mkdir /etc/kube-bench
    cp -a "$work/unpacked/cfg" /etc/kube-bench/cfg
    install -m 755 "$work/unpacked/kube-bench" /usr/local/bin/kube-bench
fi
kubectl get node controlplane node01 >/dev/null
ssh -o BatchMode=yes -o ConnectTimeout=10 node01 'bash -s' <<'REMOTE_DEPS'
set -Eeuo pipefail
if ! command -v crictl >/dev/null; then
    for tool in curl tar sha256sum kubelet; do command -v "$tool" >/dev/null; done
    case $(uname -m) in x86_64) arch=amd64;; aarch64|arm64) arch=arm64;; *) exit 1;; esac
    # Match the installed Kubernetes minor release.
    version=$(kubelet --version | awk '{split($2,v,"."); print v[1]"."v[2]".0"}')
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    archive="crictl-${version}-linux-${arch}.tar.gz"
    base="https://github.com/kubernetes-sigs/cri-tools/releases/download/$version"
    curl -fsSL "$base/$archive" -o "$tmp/$archive"
    curl -fsSL "$base/$archive.sha256" -o "$tmp/checksum"
    hash=$(awk 'NR==1 {print $1}' "$tmp/checksum")
    (cd "$tmp"; printf '%s  %s\n' "$hash" "$archive" | sha256sum -c -)
    tar -xzf "$tmp/$archive" -C "$tmp" crictl
    install -m 755 "$tmp/crictl" /usr/local/bin/crictl
fi
crictl info >/dev/null
REMOTE_DEPS
test -s /etc/kubernetes/manifests/kube-apiserver.yaml
# Record a fresh reference on each setup; never modify the API server manifest.
sha512sum /etc/kubernetes/manifests/kube-apiserver.yaml > "$STATE/reference.sha512"
# Locate the actual configuration rather than assuming the kubeadm default path.
pid=$(systemctl show kubelet -p MainPID --value)
python3 - "$pid" "$STATE" <<'PY'
import sys, pathlib, shutil, yaml
args = pathlib.Path('/proc/' + sys.argv[1] + '/cmdline').read_bytes().decode().split('\0')
if any(a == '--anonymous-auth' or a.startswith('--anonymous-auth=') for a in args):
    raise SystemExit('Explicit anonymous-auth CLI override found; refusing to rewrite unrelated service configuration.')
config = next((a.split('=',1)[1] for a in args if a.startswith('--config=')), None)
if config is None and '--config' in args:
    config = args[args.index('--config')+1]
if not config:
    raise SystemExit('No kubelet configuration file found.')
p = pathlib.Path(config)
text = p.read_text()
# Edit only the relevant scalar, preserving comments and unrelated YAML.
root = yaml.compose(text)
node = root
keys = ['authentication', 'anonymous', 'enabled']
for depth, key in enumerate(keys):
    if not isinstance(node, yaml.MappingNode):
        raise SystemExit('Expected a mapping in kubelet configuration.')
    matches = [v for k, v in node.value if k.value == key]
    if len(matches) > 1:
        raise SystemExit('Duplicate authentication configuration key.')
    if not matches:
        if node.flow_style:
            raise SystemExit('Cannot safely extend a flow-style authentication mapping.')
        # Insert the missing branch into its parent without reserializing the file.
        line = node.end_mark.line
        lines = text.splitlines(keepends=True)
        indent = node.start_mark.column
        addition = ''.join(' ' * (indent + 2 * offset) + name +
                           (': true\n' if name == 'enabled' else ':\n')
                           for offset, name in enumerate(keys[depth:]))
        prefix = ''.join(lines[:line])
        if prefix and not prefix.endswith('\n'):
            prefix += '\n'
        updated = prefix + addition + ''.join(lines[line:])
        break
    node = matches[0]
else:
    if not isinstance(node, yaml.ScalarNode):
        raise SystemExit('Expected a scalar anonymous authentication setting.')
    updated = text[:node.start_mark.index] + 'true' + text[node.end_mark.index:]
data = yaml.safe_load(updated)
if data['authentication']['anonymous']['enabled'] is not True:
    raise SystemExit('Could not prepare kubelet configuration.')
backup = pathlib.Path(sys.argv[2]) / 'kubelet-config.original'
if not backup.exists():
    shutil.copy2(p, backup)
p.write_text(updated)
PY
systemctl restart kubelet
ready=false
for ((i=0; i<60; i++)); do
    if kubectl get --raw /api/v1/nodes/controlplane/proxy/configz > "$work/configz" 2>/dev/null &&
       python3 -c 'import json,sys; sys.exit(json.load(open(sys.argv[1]))["kubeletconfig"]["authentication"]["anonymous"]["enabled"] is not True)' "$work/configz"; then
        ready=true; break
    fi
    sleep 2
done
$ready
systemctl is-active --quiet kubelet
# Capture only for preparation checks; do not print benchmark remediation.
kube-bench run --targets node --json > "$work/bench.json" 2> "$work/bench.err" || true
python3 - "$work/bench.json" <<'PY'
import json, sys
def checks(x):
    if isinstance(x, dict):
        if 'anonymous' in str(x.get('test_desc', '')).lower() and x.get('status') == 'FAIL':
            yield x
        for v in x.values(): yield from checks(v)
    elif isinstance(x, list):
        for v in x: yield from checks(v)
if not list(checks(json.load(open(sys.argv[1])))):
    raise SystemExit('kube-bench did not report the required initial failure; check benchmark compatibility.')
PY
# A raw CRI container has no Kubernetes controller to recreate it after removal.
ssh -o BatchMode=yes node01 'bash -s' <<'REMOTE'
set -Eeuo pipefail
state=/var/lib/cks-auditing-binaries
install -d -m 700 "$state"
if [[ -s $state/container.id ]]; then
    id=$(cat "$state/container.id")
    if crictl inspect "$id" >/dev/null 2>&1; then crictl stop "$id" >/dev/null; crictl rm "$id" >/dev/null; fi
fi
if [[ -s $state/sandbox.id ]]; then
    id=$(cat "$state/sandbox.id")
    if crictl inspectp "$id" >/dev/null 2>&1; then crictl stopp "$id" >/dev/null; crictl rmp "$id" >/dev/null; fi
fi
mkdir -p "$state/logs"
cat > "$state/pod.json" <<'JSON'
{"metadata":{"name":"cks-auditing-process","namespace":"cks-auditing-binaries","uid":"cks-auditing-process","attempt":0},"log_directory":"/var/lib/cks-auditing-binaries/logs","linux":{"security_context":{"namespace_options":{"network":2}}}}
JSON
cat > "$state/container.json" <<'JSON'
{"metadata":{"name":"process-simulation","attempt":0},"image":{"image":"docker.io/library/busybox:1.37.0"},"command":["/bin/sh","-c","printf '#!/bin/sh\\nwhile :; do sleep 3600; done\\n' > /tmp/cryptominer; chmod 755 /tmp/cryptominer; exec /tmp/cryptominer"],"log_path":"simulation.log","linux":{}}
JSON
crictl pull docker.io/library/busybox:1.37.0 >/dev/null
crictl runp "$state/pod.json" > "$state/sandbox.id"
crictl create "$(cat "$state/sandbox.id")" "$state/container.json" "$state/pod.json" > "$state/container.id"
crictl start "$(cat "$state/container.id")" >/dev/null
sleep 2
crictl exec "$(cat "$state/container.id")" /bin/sh -c 'test "$(cat /proc/1/comm)" = cryptominer'
REMOTE
ssh -o BatchMode=yes node01 'cat /var/lib/cks-auditing-binaries/container.id' > "$STATE/container.id"
ssh -o BatchMode=yes node01 'cat /var/lib/cks-auditing-binaries/sandbox.id' > "$STATE/sandbox.id"
cat <<'MSG'
=================================================
 CKS LAB READY
=================================================
Scenario preparation completed successfully.
Use node01 for the worker objective. kube-bench is available on controlplane.
Save your before/after checksum evidence in files; pass their path(s) to validate.sh.
With no arguments, validate.sh searches /root, /home and /tmp for checksum evidence.
MSG
