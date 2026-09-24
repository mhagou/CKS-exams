#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only inspection and server-side dry-run requests; no configuration changes.
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
if [[ $EUID != 0 ]] || ! command -v python3 >/dev/null || ! command -v kubectl >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
  printf '[FAIL] Run as root with kubectl, python3 and python3-yaml (provided by setup).\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
  exit 1
fi
python3 - <<'PY'
import json, os, pathlib, subprocess, uuid, yaml
passed = failed = 0
def report(ok, description, detail=''):
    global passed, failed
    if ok: passed += 1
    else: failed += 1
    print(('[PASS] ' if ok else '[FAIL] ') + description, flush=True)
    if not ok and detail: print('       ' + str(detail).replace('\n', ' ')[:700], flush=True)
def run(args, data=None):
    try:
        p = subprocess.run(['kubectl','--request-timeout=30s'] + args,
                           input=data, text=True, capture_output=True, timeout=45)
        return p.returncode, p.stdout + p.stderr
    except (OSError, subprocess.TimeoutExpired) as e: return 1, str(e)
rc, out = run(['get','--raw=/readyz'])
report(rc == 0, 'Kubernetes API server is ready', out)
# Inspect live process arguments and files visible in that container's mount namespace.
# This accepts different manifest/container/volume names and both flag syntaxes.
processes = []
for p in pathlib.Path('/proc').glob('[0-9]*/cmdline'):
    try:
        argv = p.read_bytes().decode().rstrip('\0').split('\0')
        if pathlib.Path(argv[0]).name == 'kube-apiserver': processes.append((p.parent, argv))
    except (OSError, UnicodeError, IndexError): pass
plugin_ok = bool(processes); deny_ok = bool(processes); endpoint_ok = bool(processes)
errors = []
for proc, argv in processes:
    flags = {}; i = 1
    while i < len(argv):
        arg = argv[i]
        if arg.startswith('--'):
            key, eq, value = arg.partition('=')
            if not eq and i + 1 < len(argv) and not argv[i+1].startswith('--'):
                i += 1; value = argv[i]
            flags[key] = value
        i += 1
    enabled = flags.get('--enable-admission-plugins','').split(',')
    disabled = flags.get('--disable-admission-plugins','').split(',')
    plugin_ok &= 'ImagePolicyWebhook' in enabled and 'ImagePolicyWebhook' not in disabled
    def read_config(path):
        # Relative configuration paths, if used, are relative to the server's cwd.
        root = proc/'root' if os.path.isabs(path) else proc/'cwd'
        with open(root/path.lstrip('/')) as f: return yaml.safe_load(f)
    try:
        admission = read_config(flags['--admission-control-config-file'])
        plugin = next(p for p in admission['plugins'] if p['name'] == 'ImagePolicyWebhook')
        config = plugin.get('configuration')
        if config is None: config = read_config(plugin['path'])
        policy = config['imagePolicy']
        # Omission has the documented false default; behavior is also tested below.
        deny_ok &= policy.get('defaultAllow', False) is False
        kubeconfig = read_config(policy['kubeConfigFile'])
        context = next(c['context'] for c in kubeconfig['contexts'] if c['name'] == kubeconfig['current-context'])
        cluster = next(c['cluster'] for c in kubeconfig['clusters'] if c['name'] == context['cluster'])
        endpoint_ok &= cluster['server'].rstrip('/') == 'https://wakanda.local:8081/image_policy'
    except Exception as e:
        deny_ok = endpoint_ok = False
        errors.append(str(e))
if not processes: errors.append('No running local kube-apiserver process found')
report(plugin_ok, 'ImagePolicyWebhook is enabled in the running API server', '; '.join(errors))
report(deny_ok, 'Active admission configuration specifies implicit deny', '; '.join(errors))
report(endpoint_ok, 'Active webhook context targets the required HTTPS endpoint', '; '.join(errors))

# Nothing is persisted or scheduled. Unique annotations avoid reusing cached verdicts.
# Restricted-compatible security settings minimize interference from other admission rules.
token = uuid.uuid4().hex
namespace = os.environ.get('CKS_VALIDATE_NAMESPACE', 'default')
def probe(image, suffix):
    pod = {'apiVersion':'v1','kind':'Pod',
      'metadata':{'name':'cks-imagepolicy-'+token[:12]+'-'+suffix,'namespace':namespace,
        'annotations':{'cks.image-policy.k8s.io/probe':token+'-'+suffix}},
      'spec':{'restartPolicy':'Never','automountServiceAccountToken':False,
        'securityContext':{'runAsNonRoot':True,'runAsUser':65532,'seccompProfile':{'type':'RuntimeDefault'}},
        'containers':[{'name':'probe','image':image,
          'resources':{'requests':{'cpu':'1m','memory':'8Mi'},'limits':{'cpu':'10m','memory':'32Mi'}},
          'securityContext':{'allowPrivilegeEscalation':False,'readOnlyRootFilesystem':True,
                             'capabilities':{'drop':['ALL']}}}]}}
    return run(['create','--dry-run=server','-f','-','-o','name'], json.dumps(pod))
rc, out = probe('registry.k8s.io/pause:3.10', 'allow')
report(rc == 0, 'Scanner-approved image is admitted (server dry-run)', out)
rc, out = probe('nginx:1.16', 'deny')
report(rc != 0 and 'CKS scanner: vulnerable image fixture' in out,
       'Vulnerable image is rejected by the scanner', out)
rc, out = probe('registry.invalid/cks-scan-error:'+token, 'error')
# The fixture returns HTTP 503 for this request only; the service and configuration
# remain untouched. Check provenance so unrelated admission denials cannot pass.
error_from_webhook = 'CKS simulated scanner unavailable' in out
report(rc != 0 and error_from_webhook,
       'Scanner failure rejects the request (effective implicit deny)', out)
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
raise SystemExit(0 if failed == 0 else 1)
PY
