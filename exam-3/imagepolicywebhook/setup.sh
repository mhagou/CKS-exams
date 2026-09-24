#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the disposable playground's controlplane, as root.
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl python3; do
    command -v "$cmd" >/dev/null || { echo "Missing required command: $cmd" >&2; exit 1; }
done
export KUBECONFIG=/etc/kubernetes/admin.conf
manifest=/etc/kubernetes/manifests/kube-apiserver.yaml
[[ -s $manifest ]] || { echo 'API server static Pod manifest not found.' >&2; exit 1; }
kubectl --request-timeout=10s get --raw=/readyz >/dev/null
# A YAML parser is needed to preserve unrelated static Pod/configuration fields.
if ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install python3-yaml, then retry.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y python3-yaml
fi

python3 - <<'PY'
import copy
import os
from pathlib import Path
import shutil
import tempfile
import yaml

manifest = Path('/etc/kubernetes/manifests/kube-apiserver.yaml')
directory = Path('/etc/kubernetes/admission')
config = directory / 'admission_config.yaml'
kubeconf = directory / 'kubeconf'
backup = Path('/var/backups/cks-imagepolicywebhook')

def fail(message):
    raise SystemExit(message)

def read(path):
    return yaml.safe_load(path.read_text())

pod = read(manifest)
original = copy.deepcopy(pod)
containers = [c for c in pod['spec']['containers']
              if any(os.path.basename(str(a)) == 'kube-apiserver'
                     for a in c.get('command', []))]
if len(containers) != 1:
    fail('Expected one kube-apiserver container; no configuration changed.')
c = containers[0]

def options(container):
    values = {}
    for key in ('command', 'args'):
        args = container.get(key, [])
        i = 0
        while i < len(args):
            a = args[i]
            if a.startswith('--'):
                name, sep, value = a.partition('=')
                if not sep and i + 1 < len(args) and not args[i + 1].startswith('--'):
                    i += 1
                    value = args[i]
                values.setdefault(name, []).append(value)
            i += 1
    return values

flags = options(c)
for value in flags.get('--admission-control-config-file', []):
    if value != str(config):
        fail('A different admission configuration is in use. Refusing to replace unrelated configuration.')
if '--admission-control' in flags:
    fail('Legacy admission flags require manual migration before preparing this lab.')

# Reset only this controller. Preserve the other plugin selections and arguments.
for key in ('command', 'args'):
    if key not in c:
        continue
    args, result, i = c[key], [], 0
    while i < len(args):
        a = args[i]
        name, sep, value = a.partition('=')
        if name in ('--enable-admission-plugins', '--disable-admission-plugins'):
            if not sep:
                i += 1
                if i >= len(args):
                    fail('Malformed admission argument.')
                value = args[i]
            plugins = [p for p in value.split(',') if p and p != 'ImagePolicyWebhook']
            if plugins:
                result.append(name + '=' + ','.join(plugins))
        else:
            result.append(a)
        i += 1
    c[key] = result

volumes = pod['spec'].setdefault('volumes', [])
mounts = c.setdefault('volumeMounts', [])
by_name = {v['name']: v for v in volumes}
covered = False
for mount in mounts:
    target = mount['mountPath'].rstrip('/') or '/'
    if str(directory) == target or str(directory).startswith(target.rstrip('/') + '/'):
        host = by_name.get(mount['name'], {}).get('hostPath', {}).get('path')
        relative = os.path.relpath(directory, target)
        if (host and not mount.get('subPath') and not mount.get('subPathExpr')
                and os.path.normpath(os.path.join(host, relative)) == str(directory)):
            covered = True
        else:
            fail('An existing mount shadows the lab directory; no configuration changed.')
    elif target.startswith(str(directory) + '/'):
        fail('An existing nested mount shadows lab files; no configuration changed.')
if not covered:
    name = 'cks-imagepolicy-admission'
    if name in by_name or any(m['name'] == name for m in mounts):
        fail('Lab volume name is already in use by another mount.')
    volumes.append({'name': name, 'hostPath': {'path': str(directory), 'type': 'Directory'}})
    mounts.append({'name': name, 'mountPath': str(directory), 'readOnly': True})

admission = read(config) if config.exists() else {
    'apiVersion': 'apiserver.config.k8s.io/v1', 'kind': 'AdmissionConfiguration', 'plugins': []}
if not isinstance(admission, dict) or admission.get('kind') != 'AdmissionConfiguration':
    fail('Existing admission file is not an AdmissionConfiguration.')
plugins = admission.setdefault('plugins', [])
plugins[:] = [p for p in plugins if p.get('name') != 'ImagePolicyWebhook']
plugins.append({'name': 'ImagePolicyWebhook', 'configuration': {'imagePolicy': {
    'kubeConfigFile': str(kubeconf), 'allowTTL': 50, 'denyTTL': 50,
    'retryBackoff': 500, 'defaultAllow': False}}})
# No service is installed: an unavailable backend is intentional in this exercise.
backend = {
    'apiVersion': 'v1', 'kind': 'Config',
    'clusters': [{'name': 'dummy', 'cluster': {
        'server': 'https://127.0.0.1:1/image-policy', 'insecure-skip-tls-verify': True}}],
    'users': [{'name': 'dummy', 'user': {}}],
    'contexts': [{'name': 'dummy', 'context': {'cluster': 'dummy', 'user': 'dummy'}}],
    'current-context': 'dummy'}

# Preserve originals outside the static Pod directory; do not create duplicate Pods.
backup.mkdir(parents=True, exist_ok=True, mode=0o700)
for path in (manifest, config, kubeconf):
    saved = backup / (path.name + '.original')
    if path.exists() and not saved.exists():
        shutil.copy2(path, saved)
directory.mkdir(parents=True, exist_ok=True, mode=0o755)

def write(path, document, mode):
    # Stage outside manifests: kubelet must never read a partial/duplicate manifest.
    fd, temporary = tempfile.mkstemp(prefix='.cks-imagepolicy-', dir=path.parent.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            yaml.safe_dump(document, stream, sort_keys=False)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)

write(config, admission, 0o600)
write(kubeconf, backend, 0o600)
if pod != original:
    write(manifest, pod, manifest.stat().st_mode & 0o777)
assert read(config)['plugins'][-1]['configuration']['imagePolicy']['defaultAllow'] is False
assert 'ImagePolicyWebhook' not in ','.join(options(c).get('--enable-admission-plugins', []))
PY

# Wait for kubelet to observe the manifest and the local API process to converge.
prepared=false
for ((attempt=0; attempt<90; attempt++)); do
    if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1 && python3 - <<'PY'
from pathlib import Path
found = False
for process in Path('/proc').glob('[0-9]*'):
    try:
        args = (process / 'cmdline').read_bytes().split(b'\0')
        if not args or args[0].split(b'/')[-1] != b'kube-apiserver':
            continue
        found = True
        if any(b'ImagePolicyWebhook' in a for a in args):
            raise SystemExit(1)
        root = process / 'root/etc/kubernetes/admission'
        if not (root / 'admission_config.yaml').is_file() or not (root / 'kubeconf').is_file():
            raise SystemExit(1)
    except (FileNotFoundError, ProcessLookupError):
        continue
raise SystemExit(0 if found else 1)
PY
    then
        prepared=true
        break
    fi
    sleep 2
done
$prepared || { echo 'Preparation did not converge; inspect API server/kubelet logs. Originals are in /var/backups/cks-imagepolicywebhook.' >&2; exit 1; }
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
