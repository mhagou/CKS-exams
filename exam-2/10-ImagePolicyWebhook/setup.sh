#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the playground controlplane. The absent backend deliberately
# models an outage; deploying a backend is not part of this exercise.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null
[[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]
export KUBECONFIG=/etc/kubernetes/admin.conf
# A real YAML parser is needed to preserve unrelated admission configuration.
if ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install python3 and python3-yaml, then retry.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y python3 python3-yaml
fi
# A candidate may have stopped the API server with an invalid webhook setting.
# Permit resetting an owned lab in that state; require health on first setup.
if [[ ! -f /var/lib/cks-imagepolicy-lab/kube-apiserver.original.yaml ]]; then
    kubectl --request-timeout=10s get --raw=/readyz >/dev/null
fi
python3 <<'PY'
import os, pathlib, shutil, socket, tempfile, yaml
manifest = pathlib.Path('/etc/kubernetes/manifests/kube-apiserver.yaml')
config = pathlib.Path('/etc/kubernetes/pki/admission_configuration.yaml')
state = pathlib.Path('/var/lib/cks-imagepolicy-lab')
doc = yaml.safe_load(manifest.read_text())
container = next(c for c in doc['spec']['containers']
                 if any(os.path.basename(x) == 'kube-apiserver' for x in c.get('command', [])))
args = container.get('command', []) + container.get('args', [])
for i, arg in enumerate(args):
    if arg.split('=')[0] == '--admission-control-config-file':
        value = arg.split('=', 1)[1] if '=' in arg else args[i+1]
        if value != str(config):
            raise SystemExit('An unrelated admission configuration is active; refusing to replace it.')
# Never take over existing exercise-named files from an unknown installation.
if not state.exists() and (config.exists() or config.with_name('admission_kube_config.yaml').exists()):
    raise SystemExit('Existing admission files are not owned by this lab; refusing to overwrite them.')
with socket.socket() as s:
    s.bind(('127.0.0.1', 18443))
state.mkdir(mode=0o700, exist_ok=True)
backup = state / 'kube-apiserver.original.yaml'
if not backup.exists():
    shutil.copy2(manifest, backup)
# Remove only this plugin from explicitly enabled plugins. Keep all other flags,
# admission plugins, volumes, mounts and container settings.
changed = False
for field in ('command', 'args'):
    old = container.get(field, [])
    new = []
    i = 0
    while i < len(old):
        arg = old[i]
        if arg.split('=')[0] == '--enable-admission-plugins':
            value = arg.split('=', 1)[1] if '=' in arg else old[i+1]
            i += 1 if '=' in arg else 2
            values = [x for x in value.split(',') if x != 'ImagePolicyWebhook']
            new.append('--enable-admission-plugins=' + ','.join(values))
            changed |= 'ImagePolicyWebhook' in value.split(',')
        else:
            new.append(arg)
            i += 1
    if field in container:
        container[field] = new
if changed:
    # Stage outside the watched manifests directory, on the same filesystem.
    fd, tmp = tempfile.mkstemp(prefix='.cks-api-', dir=manifest.parent.parent)
    with os.fdopen(fd, 'w') as f:
        yaml.safe_dump(doc, f, sort_keys=False)
    shutil.copymode(manifest, tmp)
    os.replace(tmp, manifest)
PY
# On a rerun, wait for the old enabled process to exit before breaking its files.
ready=false
for ((i=0; i<90; i++)); do
    if python3 <<'PY'
import pathlib, sys
found = False
for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
    try:
        a = p.read_bytes().decode().strip('\0').split('\0')
    except (OSError, UnicodeError):
        continue
    if a and pathlib.Path(a[0]).name == 'kube-apiserver':
        found = True
        for i, arg in enumerate(a):
            if arg.split('=')[0] == '--enable-admission-plugins':
                value = arg.split('=', 1)[1] if '=' in arg else a[i+1]
                if 'ImagePolicyWebhook' in value.split(','):
                    sys.exit(1)
sys.exit(0 if found else 1)
PY
    then
        if kubectl --request-timeout=5s get --raw=/readyz >/dev/null 2>&1; then ready=true; break; fi
    fi
    sleep 2
 done
$ready || { echo 'API server did not reach the initial state; inspect its logs.' >&2; exit 1; }
python3 <<'PY'
import pathlib, yaml
p = pathlib.Path('/etc/kubernetes/pki/admission_configuration.yaml')
doc = yaml.safe_load(p.read_text()) if p.exists() else {
    'apiVersion': 'apiserver.config.k8s.io/v1', 'kind': 'AdmissionConfiguration', 'plugins': []}
plugins = doc.setdefault('plugins', [])
plugins[:] = [x for x in plugins if x.get('name') != 'ImagePolicyWebhook']
plugins.append({'name': 'ImagePolicyWebhook', 'configuration': {'imagePolicy': {
    'kubeConfigFile': '/etc/kubernetes/pki/admission_kube_config.yml',
    'allowTTL': 50, 'denyTTL': 50, 'retryBackoff': 500, 'defaultAllow': True}}})
p.write_text(yaml.safe_dump(doc, sort_keys=False))
p.chmod(0o600)
k = p.with_name('admission_kube_config.yaml')
k.write_text(yaml.safe_dump({
    'apiVersion': 'v1', 'kind': 'Config',
    'clusters': [{'name': 'image-review', 'cluster': {
        'server': 'https://127.0.0.1:18443/image-review',
        'certificate-authority': '/etc/kubernetes/pki/ca.crt'}}],
    'users': [{'name': 'image-review-client', 'user': {}}],
    'contexts': [{'name': 'image-review', 'context': {
        'cluster': 'image-review', 'user': 'image-review-client'}}],
    'current-context': 'image-review'}, sort_keys=False))
k.chmod(0o600)
assert not pathlib.Path(plugins[-1]['configuration']['imagePolicy']['kubeConfigFile']).exists()
assert yaml.safe_load(k.read_text())['current-context'] == 'image-review'
PY
kubectl --request-timeout=10s get --raw=/readyz >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nThe image review backend is intentionally unavailable for this exercise.\n'
