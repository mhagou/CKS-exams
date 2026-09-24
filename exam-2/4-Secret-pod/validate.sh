#!/usr/bin/env bash
set -Eeuo pipefail

for command in kubectl python3; do
  if ! command -v "$command" >/dev/null; then
    echo "[FAIL] Required command unavailable: $command"
    echo "Totals: 0 passed, 1 failed"
    echo "RESULT: FAILED"
    exit 1
  fi
done

python3 - <<'PY'
import base64
import json
import posixpath
import re
import subprocess
import sys

passed = failed = 0

def check(ok, description):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] {description}")

def kubectl(*args):
    try:
        result = subprocess.run(
            ['kubectl', '--request-timeout=15s', '-n', 'seminar', *args],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25)
        return result.stdout if result.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired):
        return None

def get(kind, name):
    raw = kubectl('get', kind, name, '-o', 'json')
    try:
        return json.loads(raw) if raw is not None else {}
    except (ValueError, TypeError):
        return {}

expected = {'user': b'admin', 'pass': b'P455W0RD'}
secret = get('secret', 'secret1')
check(bool(secret), 'Secret secret1 exists in namespace seminar')
for key, value in expected.items():
    try:
        ok = base64.b64decode(secret.get('data', {}).get(key, ''), validate=True) == value
    except (ValueError, TypeError):
        ok = False
    check(ok, f'Secret secret1 contains the required {key} value')

pod = get('pod', 'secretpod')
check(bool(pod), 'Pod secretpod exists in namespace seminar')
spec = pod.get('spec', {})
statuses = {s['name']: s for s in pod.get('status', {}).get('containerStatuses', [])}
containers = [c for c in spec.get('containers', []) if re.fullmatch(
    r'(?:(?:docker\.io|index\.docker\.io)/)?(?:library/)?nginx(?::[^@/]+)?(?:@sha256:[0-9a-fA-F]{64})?',
    c.get('image', ''))]
check(bool(containers), 'Pod uses the nginx image')
running = [c for c in containers if statuses.get(c['name'], {}).get('state', {}).get('running') is not None]
check(bool(running) and pod.get('status', {}).get('phase') == 'Running'
      and not pod.get('metadata', {}).get('deletionTimestamp'),
      'The nginx container is running in a non-terminating Pod')

# Resolve keys through both Secret volumes and projected Secret volumes.
# Neither volume names nor mount paths are prescribed by the exercise.
volumes = {}
for volume in spec.get('volumes', []):
    sources = []
    if volume.get('secret', {}).get('secretName') == 'secret1':
        sources.append(volume['secret'])
    for source in volume.get('projected', {}).get('sources', []):
        if source.get('secret', {}).get('name') == 'secret1':
            sources.append(source['secret'])
    paths = {}
    for source in sources:
        items = source.get('items')
        if items is None:
            paths.update({key: key for key in expected})
        else:
            paths.update({item['key']: item['path'] for item in items if item['key'] in expected})
    volumes[volume['name']] = paths

mounted = set()
readable = set()
for container in running:
    for mount in container.get('volumeMounts', []):
        if mount.get('readOnly') is not True:
            continue
        for key, relative in volumes.get(mount['name'], {}).items():
            subpath = mount.get('subPath', '')
            if mount.get('subPathExpr'):
                # Resolve expressions using the actual running container environment.
                expr = mount['subPathExpr']
                values = {}
                for variable in re.findall(r'\$\(([^)]+)\)', expr):
                    value = kubectl('exec', 'secretpod', '-c', container['name'], '--', 'printenv', variable)
                    if value is not None:
                        values[variable] = value.decode(errors='replace').rstrip('\n')
                if any(v not in values for v in re.findall(r'\$\(([^)]+)\)', expr)):
                    continue
                subpath = re.sub(r'\$\(([^)]+)\)', lambda m: values[m[1]], expr)
            if subpath:
                if relative == subpath:
                    path = mount['mountPath']
                elif relative.startswith(subpath.rstrip('/') + '/'):
                    path = posixpath.join(mount['mountPath'], relative[len(subpath.rstrip('/')) + 1:])
                else:
                    continue
            else:
                path = posixpath.join(mount['mountPath'], relative)
            mounted.add(key)
            contents = kubectl('exec', 'secretpod', '-c', container['name'], '--', 'cat', '--', path)
            if contents == expected[key]:
                readable.add(key)

check(mounted == set(expected), 'Both Secret keys are mounted into nginx with readOnly enabled')
check(readable == set(expected), 'The running nginx container can read both expected Secret values from the mounts')
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
sys.exit(1 if failed else 0)
PY
