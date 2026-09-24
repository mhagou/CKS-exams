#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only inspection plus server-side dry-run admission: no Pods are persisted.
if [[ $EUID -ne 0 ]] || ! command -v kubectl >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    printf '[FAIL] Run as root on controlplane with kubectl, python3 and python3-yaml installed.\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi
export KUBECONFIG=/etc/kubernetes/admin.conf
python3 <<'PY'
import json, os, pathlib, subprocess, sys, uuid, yaml
passed = failed = 0

def report(ok, description):
    global passed, failed
    passed += bool(ok)
    failed += not ok
    print(('[PASS] ' if ok else '[FAIL] ') + description, flush=True)

def run(*args, data=None):
    return subprocess.run(['kubectl', '--request-timeout=45s', *args],
                          input=data, text=True, capture_output=True, timeout=55)

def flags(args):
    result = {}
    for i, arg in enumerate(args):
        if arg.startswith('--'):
            key, sep, value = arg.partition('=')
            result[key] = value if sep else (args[i+1] if i+1 < len(args) else '')
    return result

try:
    healthy = run('get', '--raw=/readyz')
    report(healthy.returncode == 0, 'API server is ready')
    processes = []
    for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
        try:
            args = p.read_bytes().decode().strip('\0').split('\0')
        except (OSError, UnicodeError):
            continue
        if args and os.path.basename(args[0]) == 'kube-apiserver':
            processes.append((p.parent, flags(args)))
    if len(processes) != 1:
        raise ValueError('Expected one running local kube-apiserver; found %d' % len(processes))
    proc, options = processes[0]
    enabled = 'ImagePolicyWebhook' in options.get('--enable-admission-plugins', '').split(',')
    disabled = 'ImagePolicyWebhook' in options.get('--disable-admission-plugins', '').split(',')
    report(enabled and not disabled, 'ImagePolicyWebhook is enabled in the running API server')

    def inside(path, base='/'):
        path = os.path.normpath(os.path.join(base, path))
        return proc / 'root' / path.lstrip('/')

    config_path = options.get('--admission-control-config-file', '')
    if not config_path:
        raise ValueError('The running API server has no admission configuration flag')
    config = inside(config_path)
    required = pathlib.Path('/etc/kubernetes/pki/admission_configuration.yaml')
    # Compare the relevant policy, not unrelated plugins or their ordering.
    # Resolve external plugin files relative to each admission configuration.
    active = yaml.safe_load(config.read_text())
    def image_policy(document, read_external):
        plugins = [x for x in document.get('plugins', []) if x.get('name') == 'ImagePolicyWebhook']
        if len(plugins) != 1:
            raise ValueError('Admission configuration must contain one ImagePolicyWebhook entry')
        plugin = plugins[0]
        policy_doc = plugin.get('configuration')
        if not policy_doc:
            policy_doc = yaml.safe_load(read_external(plugin['path']))
        policy = dict(policy_doc['imagePolicy'])
        policy.setdefault('defaultAllow', False)
        return policy

    policy = image_policy(active, lambda path: inside(path, os.path.dirname(config_path)).read_text())
    required_policy = image_policy(yaml.safe_load(required.read_text()),
                                   lambda path: (required.parent / path).read_text())
    report(policy == required_policy,
           'The required file supplies the ImagePolicyWebhook policy selected by the API server')
    report(policy.get('defaultAllow', False) is False, 'Image policy defaults to implicit deny')
    kube_path = policy.get('kubeConfigFile', '')
    if not kube_path:
        raise ValueError('Image policy kubeConfigFile is missing')
    kube = yaml.safe_load(inside(kube_path).read_text())
    context = next(x['context'] for x in kube['contexts'] if x['name'] == kube['current-context'])
    cluster = next(x['cluster'] for x in kube['clusters'] if x['name'] == context['cluster'])
    endpoint = cluster['server']
    report(endpoint.startswith('https://'), 'Image policy references a readable HTTPS webhook kubeconfig')

    # A unique image avoids cached ImageReview decisions. Dry-run traverses
    # admission without scheduling or pulling an image. Restricted-compatible
    # settings prevent Pod Security Admission from masking the result.
    token = uuid.uuid4().hex
    pod = {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {
        'name': 'cks-imagepolicy-check-' + token[:12], 'namespace': 'default'},
        'spec': {'automountServiceAccountToken': False, 'restartPolicy': 'Never',
                 'securityContext': {'runAsNonRoot': True, 'runAsUser': 65534,
                                     'seccompProfile': {'type': 'RuntimeDefault'}},
                 'containers': [{'name': 'probe', 'image': 'registry.k8s.io/pause:cks-check-' + token,
                                 'securityContext': {'allowPrivilegeEscalation': False,
                                                     'capabilities': {'drop': ['ALL']}}}]}}
    result = run('create', '--dry-run=server', '-f', '-', '-o', 'json', data=json.dumps(pod))
    message = result.stderr.lower()
    # Do not mistake RBAC, PSA, schema errors or request timeouts for fail-closed
    # admission. Require Forbidden plus the configured backend and a transport error.
    outage = (result.returncode != 0 and 'forbidden' in message
              and endpoint.lower().rstrip('/') in message
              and any(x in message for x in ('connection refused', 'no such host',
                                             'i/o timeout', 'tls handshake timeout',
                                             'context deadline exceeded', 'x509:')))
    report(outage, 'Pod admission fails closed when the image review backend is unavailable')
    if not outage:
        print('  Admission response: ' + (result.stderr.strip() or 'Pod dry-run was accepted.')[:1800])
except Exception as exc:
    report(False, 'Unable to complete objective checks: ' + str(exc))
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
sys.exit(0 if failed == 0 else 1)
PY
