#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR=/root/cks-dockerfile-lab
if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    printf '[FAIL] Validation requires python3 and PyYAML (provided by setup.sh).\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi

# Read candidate files only. No builds, cluster calls, or repairs.
python3 - "$LAB_DIR" <<'PY'
import copy
import pathlib
import re
import shlex
import sys
import yaml

root = pathlib.Path(sys.argv[1])
passed = failed = 0

def check(ok, description):
    global passed, failed
    if ok:
        passed += 1
    else:
        failed += 1
    print(f"[{'PASS' if ok else 'FAIL'}] {description}")

# Join Dockerfile continuations and ignore blank lines and full-line comments.
def instructions(text):
    result, pending = [], ''
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        line = line.rstrip()
        if line.endswith('\\'):
            pending += line[:-1] + ' '
            continue
        line = pending + line
        pending = ''
        parts = line.strip().split(None, 1)
        if len(parts) != 2:
            raise ValueError('An instruction has no argument')
        result.append((parts[0].upper(), parts[1].strip()))
    if pending:
        raise ValueError('Unterminated continuation')
    return result

try:
    docker = instructions((root / 'Dockerfile').read_text())
    base = [arg for op, arg in docker if op == 'FROM']
    user = [arg for op, arg in docker if op == 'USER']
    # Require the supplied Ubuntu base, explicitly versioned or digest-pinned.
    pinned = False
    if len(base) == 1:
        parts = shlex.split(base[0])
        if len(parts) == 1:
            ref = parts[0]
            match = re.fullmatch(
                r'(?:docker\.io/(?:library/)?|library/)?ubuntu'
                r'(?::([A-Za-z0-9_][A-Za-z0-9_.-]*))?'
                r'(?:@sha256:([a-fA-F0-9]{64}))?', ref)
            pinned = bool(match and (match[2] or (
                match[1] and match[1].lower() not in {'latest', 'rolling', 'devel'})))
    check(pinned, 'Dockerfile uses an explicit Ubuntu release tag or immutable digest')
    # Numeric UID is equivalent to the requested account for this editing exercise.
    valid_user = False
    if len(user) == 1:
        fields = shlex.split(user[0])
        valid_user = (len(fields) == 1 and bool(re.fullmatch(
            r'(?:test-user|5487)(?::[A-Za-z0-9_.-]+)?', fields[0])))
    check(valid_user, 'Dockerfile selects test-user (UID 5487) rather than root')
    expected = [
        ('FROM', None), ('RUN', 'apt-get update -y'),
        ('RUN', 'apt-install nginx -y'), ('COPY', 'entrypoint.sh /'),
        ('ENTRYPOINT', "['/entrypoint.sh']"), ('USER', None)]
    unchanged = len(docker) == len(expected)
    if unchanged:
        unchanged = all(op == want_op and (want_arg is None or
            shlex.split(arg) == shlex.split(want_arg))
            for (op, arg), (want_op, want_arg) in zip(docker, expected))
    check(unchanged, 'Dockerfile retains all other instructions without additions or removals')
except (OSError, ValueError) as exc:
    check(False, f'Dockerfile can be inspected: {exc}')

# Reject ambiguous duplicate keys rather than silently accepting the last value.
class UniqueLoader(yaml.SafeLoader):
    pass

def unique_mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise ValueError(f'Duplicate YAML key: {key}')
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping

UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
try:
    pod = yaml.load((root / 'deployment.yaml').read_text(), Loader=UniqueLoader)
    context = pod['spec']['containers'][0]['securityContext']
    uid = context.get('runAsUser')
    check(type(uid) is int and uid == 5487, 'Container runs as UID 5487')
    check(context.get('privileged') is False, 'Container is not privileged')
    original = {
        'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'security-context-demo-2'},
        'spec': {'securityContext': {'runAsUser': 1000}, 'containers': [{
            'name': 'sec-ctx-demo-2', 'image': 'gcr.io/google-samples/node-hello:1.0',
            'securityContext': {'runAsUser': 0, 'privileged': True,
                                'allowPrivilegeEscalation': False}}]}}
    masked = copy.deepcopy(pod)
    masked_context = masked['spec']['containers'][0]['securityContext']
    # Mask values only if present, so deleting a required field cannot pass.
    for key in ('runAsUser', 'privileged'):
        if key in masked_context:
            masked_context[key] = original['spec']['containers'][0]['securityContext'][key]
    # Type-aware comparison prevents 0/false or quoted numeric substitutions.
    def same(a, b):
        if type(a) is not type(b):
            return False
        if isinstance(a, dict):
            return a.keys() == b.keys() and all(same(a[k], b[k]) for k in a)
        if isinstance(a, list):
            return len(a) == len(b) and all(same(x, y) for x, y in zip(a, b))
        return a == b
    check(same(masked, original), 'Manifest retains every other setting without additions or removals')
except (OSError, ValueError, TypeError, KeyError, IndexError, AttributeError, yaml.YAMLError) as exc:
    check(False, f'Pod manifest can be inspected: {exc}')

print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
sys.exit(0 if failed == 0 else 1)
PY
