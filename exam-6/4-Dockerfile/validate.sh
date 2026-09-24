#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation of the artifacts requested by task.txt.
LAB_DIR=${LAB_DIR:-/root/cks-dockerfile-lab}
if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    printf '[FAIL] Validation requires python3 and python3-yaml (provided by setup).\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi

python3 - "$LAB_DIR" <<'PY'
import pathlib
import re
import shlex
import sys
import yaml

directory = pathlib.Path(sys.argv[1])
passed = failed = 0

def check(ok, description):
    global passed, failed
    if ok:
        passed += 1
        print('[PASS] ' + description)
    else:
        failed += 1
        print('[FAIL] ' + description)

# Reject duplicate keys rather than interpreting an ambiguous security setting.
class Loader(yaml.SafeLoader):
    pass

def mapping(loader, node, deep=False):
    loader.flatten_mapping(node)
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in result:
            raise ValueError('Duplicate YAML mapping key: ' + str(key))
        result[key] = loader.construct_object(value_node, deep=deep)
    return result

Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)

try:
    text = (directory / 'Dockerfile').read_text()
    text = re.sub(r'\\\r?\n', ' ', text)
    instructions = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        fields = line.split(None, 1)
        if len(fields) != 2:
            raise ValueError('Incomplete Dockerfile instruction')
        instructions.append((fields[0].upper(), fields[1]))
    bases = []
    aliases = set()
    valid_bases = True
    for op, arg in instructions:
        if op != 'FROM':
            continue
        tokens = shlex.split(arg)
        tokens = [t for t in tokens if not t.startswith('--platform=')]
        base = tokens[0]
        bases.append(base)
        reference = base.split('@', 1)[0]
        valid_bases &= reference in ('ubuntu:18.04', 'docker.io/ubuntu:18.04',
                                    'docker.io/library/ubuntu:18.04') or base in aliases
        if len(tokens) == 3 and tokens[1].upper() == 'AS':
            aliases.add(tokens[2])
        elif len(tokens) != 1:
            valid_bases = False
    check(bool(bases) and valid_bases, 'Dockerfile uses the required Ubuntu 18.04 base')
    users = [shlex.split(arg) for op, arg in instructions if op == 'USER']
    # UID 65534 is the Ubuntu nobody account; a group suffix is equivalent.
    valid_users = bool(users) and all(
        len(u) == 1 and u[0].split(':', 1)[0] in ('nobody', '65534') for u in users)
    # The final stage must explicitly select the requested user.
    selected = False
    for op, arg in instructions:
        if op == 'FROM':
            selected = False
        elif op == 'USER':
            selected = True
    check(valid_users and selected, 'Dockerfile replaces root user directives with nobody')
except (OSError, ValueError, IndexError) as exc:
    check(False, 'Dockerfile can be inspected: ' + str(exc))

try:
    docs = list(yaml.load_all((directory / 'Deployment.yaml').read_text(), Loader=Loader))
    deployments = [d for d in docs if isinstance(d, dict) and d.get('kind') == 'Deployment']
    targets = [d for d in deployments if d.get('metadata', {}).get('name') == 'kafka']
    if len(targets) != 1:
        raise ValueError('Expected one kafka Deployment')
    deployment = targets[0]
    pod = deployment['spec']['template']['spec']
    containers = pod['containers']
    if not isinstance(containers, list) or not containers:
        raise ValueError('Deployment must contain containers')
    contexts = [c.get('securityContext') or {} for c in
                containers + (pod.get('initContainers') or [])]
    check(deployment.get('apiVersion') == 'apps/v1', 'Kafka Deployment is present')
    check(all(c.get('privileged', False) is False for c in contexts),
          'Deployment containers are not privileged (omission defaults to false)')
    check(all(c.get('readOnlyRootFilesystem') is True for c in contexts),
          'Deployment containers have read-only root filesystems')
except (OSError, ValueError, TypeError, KeyError, AttributeError, yaml.YAMLError) as exc:
    check(False, 'Deployment manifest can be inspected: ' + str(exc))

print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
sys.exit(1 if failed else 0)
PY
