#!/usr/bin/env bash
set -Eeuo pipefail
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
if [[ $EUID -ne 0 ]] || ! command -v kubectl >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    printf '[FAIL] Run on controlplane as root with kubectl, python3 and PyYAML available.\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi
# Read-only configuration inspection plus server-side dry-run API requests.
# No cluster resources are persisted, and no candidate configuration is changed.
python3 <<'PY'
import glob
import json
import os
from pathlib import Path
import subprocess
import time
import uuid
import yaml

passed = failed = 0

def report(ok, description):
    global passed, failed
    passed += bool(ok)
    failed += not bool(ok)
    print(('[PASS] ' if ok else '[FAIL] ') + description, flush=True)

def finish():
    print(f'Totals: {passed} passed, {failed} failed')
    print('RESULT: FAILED' if failed else 'RESULT: SUCCESS')
    raise SystemExit(1 if failed else 0)

def kube(*args, body=None):
    p = subprocess.run(['kubectl', '--request-timeout=20s', *args],
                       input=json.dumps(body) if body is not None else None,
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode:
        raise RuntimeError(p.stderr.strip())
    return p.stdout

try:
    kube('get', '--raw=/readyz')
    report(True, 'API server is ready')
    # /proc exposes actual running arguments, not an unapplied manifest edit.
    processes = []
    for entry in Path('/proc').glob('[0-9]*'):
        try:
            args = (entry / 'cmdline').read_bytes().decode().strip('\0').split('\0')
            if args and os.path.basename(args[0]) == 'kube-apiserver':
                processes.append((entry, args))
        except (OSError, UnicodeError):
            continue
    if len(processes) != 1:
        raise RuntimeError('Expected one local running kube-apiserver process.')
    proc, args = processes[0]
    flags = {}
    for i, arg in enumerate(args):
        if arg.startswith('--'):
            key, sep, value = arg[2:].partition('=')
            flags[key] = value if sep else (args[i+1] if i+1 < len(args) else '')
    log = Path('/var/log/Kubernetes/logs.txt')
    live_log = proc / 'root' / flags.get('audit-log-path', '').lstrip('/')
    location_ok = (flags.get('audit-log-path') == str(log) and log.is_file()
                   and live_log.is_file() and os.path.samefile(log, live_log))
    report(location_ok, 'Running log backend writes to /var/log/Kubernetes/logs.txt on the host')
    report(flags.get('audit-log-maxage') == '5', 'Running audit log retention is 5 days')
    report(flags.get('audit-log-maxbackup') == '10', 'Running audit backend retains at most 10 old files')
    policy_path = flags.get('audit-policy-file', '')
    if not policy_path:
        raise RuntimeError('Running API server has no audit policy configured.')
    policy = yaml.safe_load((proc / 'root' / policy_path.lstrip('/')).read_text())
    provided = yaml.safe_load(Path('/etc/Kubernetes/logpolicy/audit-policy.yaml').read_text())
    rules = policy.get('rules', [])
    if policy.get('kind') != 'Policy' or not isinstance(rules, list):
        raise RuntimeError('Active policy file is invalid.')

    # Ordered first-match evaluation for ordinary authenticated resource requests.
    # Also test rule boundaries (namespace, user, verb and resource-name filters).
    def level(resource, verb='patch', namespace='', group='', name='audit-probe',
              user='audit-policy-probe', groups=('system:authenticated',)):
        for r in rules:
            if r.get('users') and user not in r['users']:
                continue
            if r.get('userGroups') and not set(groups).intersection(r['userGroups']):
                continue
            if r.get('verbs') and verb not in r['verbs']:
                continue
            if r.get('namespaces') and namespace not in r['namespaces']:
                continue
            if r.get('nonResourceURLs'):
                continue
            if r.get('resources'):
                matched = False
                for selector in r['resources']:
                    if selector.get('group', '') not in (group, '*'):
                        continue
                    patterns = selector.get('resources', [])
                    if patterns and resource not in patterns and '*' not in patterns:
                        continue
                    if selector.get('resourceNames') and name not in selector['resourceNames']:
                        continue
                    matched = True
                if not matched:
                    continue
            return r.get('level', 'None')
        return 'None'

    changes = ('create', 'update', 'patch', 'delete', 'deletecollection')
    report(all(level('nodes', v) == 'RequestResponse' for v in changes),
           'Node changes match RequestResponse policy rules')
    pv_global = all(level('persistentvolumes', v) in ('Request', 'RequestResponse') for v in changes)
    pv_scoped = all(level('persistentvolumes', v, 'frontend') in ('Request', 'RequestResponse') for v in changes)
    report(pv_global or pv_scoped, 'PersistentVolume changes have request-body policy coverage')
    print('[NOTE] PersistentVolumes are cluster-scoped. A frontend-only PV rule cannot match real PV requests; '
          'the stated rule or effective cluster-wide coverage is accepted.', flush=True)
    namespaces = {'frontend', 'default', 'kube-system', 'audit-other-namespace'}
    for r in rules:
        namespaces.update(n for n in r.get('namespaces', []) if n)
    report(all(level(res, v, ns) == 'Metadata' for res in ('configmaps', 'secrets')
               for v in changes for ns in namespaces),
           'ConfigMap and Secret changes match Metadata rules across namespaces')
    filters = ('users', 'userGroups', 'verbs', 'resources', 'namespaces', 'nonResourceURLs')
    catchall = any(r.get('level') == 'Metadata' and not any(r.get(k) for k in filters) for r in rules)
    report(catchall and all(level(res, v, ns, group) == 'Metadata'
                           for res, ns, group in [('pods', 'frontend', ''), ('deployments', 'default', 'apps'),
                                                  ('namespaces', '', ''), ('audit-unknown', 'other', 'example.com')]
                           for v in ('get', 'list', 'create', 'patch', 'delete')),
           'A Metadata catch-all covers other requests')
    # Setup preserved pre-existing exclusions, or supplied health endpoint exclusions.
    backup = Path('/etc/Kubernetes/logpolicy/audit-policy.yaml.pre-lab')
    base = yaml.safe_load(backup.read_text()) if backup.exists() else {}
    original_none = [r for r in base.get('rules', []) if r.get('level') == 'None']
    if not original_none:
        original_none = [{'level': 'None', 'nonResourceURLs': ['/healthz*', '/readyz*', '/livez*']}]
    # Check exclusions by matching representative non-resource requests and resource
    # requests rather than requiring identical rule structures.
    def exclusion_preserved(original):
        # For arbitrary inherited rules, allow split/merged equivalent selector rules.
        import itertools
        users = original.get('users') or ['audit-policy-probe']
        groupsets = [(g,) for g in original.get('userGroups', [])] or [('system:authenticated',)]
        verbs = original.get('verbs') or ['get', 'list', 'create', 'patch', 'delete']
        nss = original.get('namespaces') or ['', 'frontend', 'audit-other-namespace']
        urls = original.get('nonResourceURLs', [])
        if urls:
            for pattern, user, groups, verb in itertools.product(urls, users, groupsets, verbs):
                url = pattern.rstrip('*') + ('audit-probe' if pattern.endswith('*') else '')
                found = 'None'
                for r in rules:
                    if r.get('users') and user not in r['users']: continue
                    if r.get('userGroups') and not set(groups).intersection(r['userGroups']): continue
                    if r.get('verbs') and verb not in r['verbs']: continue
                    if r.get('resources') or r.get('namespaces'): continue
                    pats = r.get('nonResourceURLs', [])
                    if pats and not any(url == p or (p.endswith('*') and url.startswith(p[:-1])) for p in pats): continue
                    found = r.get('level'); break
                if found != 'None': return False
            return True
        for sel in original.get('resources') or [{'group': '', 'resources': ['pods']}]:
            for res, verb, ns, user, groups, name in itertools.product(
                    sel.get('resources') or ['pods'], verbs, nss, users, groupsets,
                    sel.get('resourceNames') or ['audit-probe']):
                if level(res.replace('*', 'pods'), verb, ns, sel.get('group', '').replace('*', ''), name, user, groups) != 'None':
                    return False
        return True
    report(all(exclusion_preserved(r) for r in original_none), 'Original do-not-log exclusions remain effective')
    report(provided.get('kind') == 'Policy' and any(r.get('level') != 'None' for r in provided.get('rules', [])),
           'Provided basic policy has been extended')

    if not location_ok:
        raise RuntimeError('Cannot verify fresh events at the required host log path.')
    token = 'cks-audit-' + uuid.uuid4().hex[:12]
    checks = []
    offsets = {}
    for filename in glob.glob('/var/log/Kubernetes/logs*'):
        try:
            stat = os.stat(filename)
            offsets[(stat.st_dev, stat.st_ino)] = stat.st_size
        except OSError:
            pass
    def probe(description, expected, args, body=None):
        marker = token + '-' + str(len(checks))
        args = [a.replace('MARKER', marker) for a in args]
        try:
            kube(*args, body=body)
            checks.append((description, expected, marker, True))
        except RuntimeError as e:
            print(f'[NOTE] Probe failed: {e}', flush=True)
            checks.append((description, expected, marker, False))
    probe('Fresh Node change includes request and response bodies', 'RequestResponse',
          ['patch', 'node', 'controlplane', '--type=merge', '--dry-run=server',
           '--field-manager=MARKER', '-p', json.dumps({'metadata': {'annotations': {'cks-audit-probe': token}}})])
    for ns in ('frontend', 'kube-system'):
        for resource, kind in [('configmaps', 'ConfigMap'), ('secrets', 'Secret')]:
            probe(f'Fresh {kind} change in {ns} logs Metadata only', 'Metadata',
                  ['create', '--raw', f'/api/v1/namespaces/{ns}/{resource}?dryRun=All&fieldManager=MARKER', '-f', '-'],
                  {'apiVersion': 'v1', 'kind': kind, 'metadata': {'name': token, 'namespace': ns}})
    probe('Other requests produce fresh Metadata events', 'Metadata',
          ['get', '--raw', '/api/v1/namespaces?limit=1&cks-audit-probe=MARKER'])
    if pv_global:
        probe('Fresh PersistentVolume change includes its request body', 'RequestBody',
              ['create', '--raw', '/api/v1/persistentvolumes?dryRun=All&fieldManager=MARKER', '-f', '-'],
              {'apiVersion': 'v1', 'kind': 'PersistentVolume', 'metadata': {'name': token},
               'spec': {'capacity': {'storage': '1Mi'}, 'accessModes': ['ReadWriteOnce'],
                        'persistentVolumeReclaimPolicy': 'Retain', 'hostPath': {'path': '/tmp/' + token}}})
    events = {}
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        # Include rotated uncompressed files in case the backend rotates mid-probe.
        for filename in glob.glob('/var/log/Kubernetes/logs*'):
            if filename.endswith('.gz'): continue
            try:
                with open(filename) as stream:
                    stat = os.fstat(stream.fileno())
                    key = (stat.st_dev, stat.st_ino)
                    stream.seek(offsets.get(key, 0) if stat.st_size >= offsets.get(key, 0) else 0)
                    while True:
                        pos = stream.tell()
                        line = stream.readline()
                        if not line or not line.endswith('\n'):
                            offsets[key] = pos
                            break
                        if token not in line: continue
                        try: event = json.loads(line)
                        except ValueError: continue
                        if event.get('stage') != 'ResponseComplete': continue
                        for _, _, marker, _ in checks:
                            if marker in event.get('requestURI', ''):
                                events[marker] = event
            except OSError:
                continue
        if all(marker in events or not ok for _, _, marker, ok in checks): break
        time.sleep(1)
    for description, expected, marker, ok in checks:
        e = events.get(marker, {})
        if expected == 'Metadata':
            valid = e.get('level') == 'Metadata' and 'requestObject' not in e and 'responseObject' not in e
        elif expected == 'RequestResponse':
            valid = e.get('level') == expected and e.get('requestObject') is not None and e.get('responseObject') is not None
        else:
            valid = e.get('level') in ('Request', 'RequestResponse') and e.get('requestObject') is not None
        report(ok and valid, description)
except Exception as e:
    report(False, str(e))
finish()
PY
