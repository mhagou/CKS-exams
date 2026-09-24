#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on controlplane. Only uniquely named test resources are modified.
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
if [[ $EUID -ne 0 ]] || ! command -v kubectl >/dev/null || ! command -v python3 >/dev/null; then
    printf '[FAIL] Run as root on controlplane with kubectl and Python 3 available.\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi
python3 - <<'PY'
import datetime
import glob
import json
import os
import pathlib
import signal
import subprocess
import sys
import time
import uuid

passed = failed = 0
owned = []

def check(ok, description):
    global passed, failed
    passed += bool(ok)
    failed += not ok
    print(('[PASS] ' if ok else '[FAIL] ') + description, flush=True)

def kube(*args, obj=None):
    p = subprocess.run(['kubectl', '--request-timeout=15s', *args],
                       input=json.dumps(obj) if obj is not None else None,
                       text=True, capture_output=True, timeout=25)
    if p.returncode:
        raise RuntimeError(p.stderr.strip() or 'kubectl failed')
    return p.stdout

def create(obj, resource, namespace=None):
    name = obj['metadata']['name']
    # Names contain a UUID. Register before creation so timeouts also clean up.
    owned.append((resource, name, namespace))
    return json.loads(kube('create', '-f', '-', '-o', 'json', obj=obj))

def cleanup():
    for resource, name, namespace in reversed(owned):
        try:
            args = ['delete', resource, name, '--ignore-not-found', '--wait=false']
            if namespace:
                args += ['-n', namespace]
            if resource == 'pod':
                args += ['--grace-period=0', '--force']
            kube(*args)
        except Exception as exc:
            check(False, f'Cleanup {resource}/{name}: {exc}')

def interrupted(signum, frame):
    raise RuntimeError(f'Interrupted by signal {signum}')

signal.signal(signal.SIGTERM, interrupted)
signal.signal(signal.SIGINT, interrupted)
try:
    kube('get', '--raw=/readyz')
    check(True, 'API server is ready')
    # Inspect the actual process, not a manifest that may not have taken effect.
    servers = []
    for proc in pathlib.Path('/proc').glob('[0-9]*'):
        try:
            argv = (proc / 'cmdline').read_bytes().decode().strip('\0').split('\0')
            if argv and os.path.basename(argv[0]) == 'kube-apiserver':
                servers.append((proc, argv))
        except (OSError, UnicodeError):
            pass
    if len(servers) != 1:
        raise RuntimeError('Expected one running local kube-apiserver; found %d' % len(servers))
    proc, argv = servers[0]
    flags = {}
    for i, arg in enumerate(argv):
        if arg.startswith('--'):
            key, sep, value = arg.partition('=')
            flags[key] = value if sep else (argv[i + 1] if i + 1 < len(argv) else '')
    policy = '/etc/kubernetes/test-audit.yaml'
    logfile = '/var/log/test-audit.log'
    check(flags.get('--audit-policy-file') == policy
          and pathlib.Path(policy).is_file()
          and (proc / ('root' + policy)).is_file(),
          'Running API server uses the required audit policy file')
    check(flags.get('--audit-log-path') == logfile,
          'Running API server logs to /var/log/test-audit.log')
    check(flags.get('--audit-log-maxage') == '20', 'Audit log retention is 20 days')
    # Host visibility proves that container-only logging is not mistaken for
    # the required persistent host log. Accept any volume/mount names.
    check(pathlib.Path(logfile).is_file(), 'Audit log exists on the controlplane host')
    if not pathlib.Path(logfile).is_file():
        raise RuntimeError('Cannot test audit events without the required host log')
    kube('get', 'namespace', 'test')
    token = 'audit-check-' + uuid.uuid4().hex[:12]
    outside = token
    start = datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00', 'Z')
    # Track offsets per inode, including rotations. Never read historical logs
    # as evidence for this validation run.
    offsets = {}
    def paths():
        return glob.glob('/var/log/test-audit*.log')
    for path in paths():
        stat = os.stat(path)
        offsets[(stat.st_dev, stat.st_ino)] = stat.st_size
    events = []
    def collect():
        for path in paths():
            try:
                with open(path, 'rb') as stream:
                    stat = os.fstat(stream.fileno())
                    key = (stat.st_dev, stat.st_ino)
                    offset = offsets.get(key, 0)
                    stream.seek(offset if stat.st_size >= offset else 0)
                    while True:
                        pos = stream.tell()
                        line = stream.readline()
                        if not line or not line.endswith(b'\n'):
                            stream.seek(pos)
                            break
                        try:
                            event = json.loads(line)
                        except ValueError:
                            raise RuntimeError('Audit log is not JSON; event validation cannot proceed')
                        stamp = event.get('requestReceivedTimestamp', '')
                        if stamp >= start:
                            events.append(event)
                    offsets[key] = stream.tell()
            except FileNotFoundError:
                continue
    create({'apiVersion': 'v1', 'kind': 'Namespace', 'metadata': {'name': outside}}, 'namespace')
    for namespace in ('test', outside):
        pod = {'apiVersion': 'v1', 'kind': 'Pod',
               'metadata': {'name': token, 'namespace': namespace},
               'spec': {'nodeSelector': {'cks-audit-validator': token},
                        'automountServiceAccountToken': False,
                        'securityContext': {'runAsNonRoot': True, 'runAsUser': 65534,
                                            'seccompProfile': {'type': 'RuntimeDefault'}},
                        'containers': [{'name': 'pause', 'image': 'registry.k8s.io/pause:3.10',
                                        'securityContext': {'allowPrivilegeEscalation': False,
                                                            'capabilities': {'drop': ['ALL']}}}]}}
        # An unmatched selector keeps these pods pending: no image pull needed.
        obj = create(pod, 'pod', namespace)
        kube('get', 'pod', token, '-n', namespace)
        kube('get', 'pods', '-n', namespace)
        kube('patch', 'pod', token, '-n', namespace, '--type=merge',
             '-p', '{"metadata":{"annotations":{"audit-probe":"patch"}}}')
        obj = json.loads(kube('get', 'pod', token, '-n', namespace, '-o', 'json'))
        obj['metadata']['annotations']['audit-probe'] = 'update'
        kube('replace', '-f', '-', obj=obj)
        kube('delete', 'pod', token, '-n', namespace, '--grace-period=0', '--force', '--wait=false')
        cm = create({'apiVersion': 'v1', 'kind': 'ConfigMap',
                     'metadata': {'name': token, 'namespace': namespace},
                     'data': {'probe': 'create'}}, 'configmap', namespace)
        cm['data']['probe'] = 'update'
        kube('replace', '-f', '-', obj=cm)
        kube('delete', 'configmap', token, '-n', namespace, '--wait=false')
    kube('get', '--raw=/version')
    # Wait through a normal batch flush, even when positive events arrive early,
    # so negative probes cannot pass simply because logging was delayed.
    wait = int(os.environ.get('AUDIT_WAIT_SECONDS', '30'))
    if wait < 30:
        wait = 30
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        collect()
        time.sleep(1)
    collect()
    def allowed(event):
        ref = event.get('objectRef', {})
        return (ref.get('namespace') == 'test' and ref.get('resource') == 'pods'
                and not ref.get('apiGroup') and not ref.get('subresource')
                and event.get('verb') in ('delete', 'update'))
    matching = [e for e in events if allowed(e) and e.get('objectRef', {}).get('name') == token]
    for verb in ('update', 'delete'):
        check(any(e.get('verb') == verb for e in matching),
              f'Fresh pod {verb} events in namespace test are logged')
    check(bool(matching) and all(e.get('level') == 'Metadata'
                                and 'requestObject' not in e and 'responseObject' not in e
                                for e in events if allowed(e)),
          'Matching events use Metadata level without request/response bodies')
    unexpected = [e for e in events if not allowed(e)]
    check(not unexpected,
          'Only pod update/delete events in test are logged (negative probes included)')
    if unexpected:
        for event in unexpected[:3]:
            ref = event.get('objectRef', {})
            print('  Unexpected: verb=%s namespace=%s resource=%s' %
                  (event.get('verb'), ref.get('namespace', '-'), ref.get('resource', '-')))
except Exception as exc:
    check(False, str(exc))
finally:
    cleanup()
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: FAILED' if failed else 'RESULT: SUCCESS')
sys.exit(1 if failed else 0)
PY
