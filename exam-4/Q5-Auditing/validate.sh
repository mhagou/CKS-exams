#!/usr/bin/env bash
set -Eeuo pipefail

# Policy creation is the entire question. Activation, log destinations and
# retention are not required. Supply any alternative policy path as argument 1.
policy=${1:-/root/cks-q5-auditing/audit-policy.yaml}
if [[ $# -gt 1 ]] || ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
    echo '[FAIL] Usage: ./validate.sh [policy-file]; Python 3 with PyYAML is required (provided by setup.sh).'
    echo 'Totals: 0 passed, 1 failed'
    echo 'RESULT: FAILED'
    exit 1
fi
python3 - "$policy" <<'PY'
import sys
import yaml

passed = failed = 0

def report(ok, message):
    global passed, failed
    passed += bool(ok)
    failed += not ok
    print(('[PASS] ' if ok else '[FAIL] ') + message)

def finish():
    print(f'Totals: {passed} passed, {failed} failed')
    print('RESULT: FAILED' if failed else 'RESULT: SUCCESS')
    sys.exit(1 if failed else 0)

# Unknown fields are rejected: Kubernetes may otherwise ignore a misspelled
# selector, accidentally broadening a rule. Duplicate keys are ambiguous too.
class Loader(yaml.SafeLoader):
    pass

def mapping(loader, node):
    result = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node)
        if key in result:
            raise ValueError(f'duplicate YAML key: {key}')
        result[key] = loader.construct_object(value_node)
    return result

Loader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, mapping)
stages = {'RequestReceived', 'ResponseStarted', 'ResponseComplete', 'Panic'}

def strings(obj, field):
    value = obj.get(field) or []
    if not isinstance(value, list) or any(not isinstance(x, str) for x in value):
        raise ValueError(f'{field} must be a list of strings')
    return value

def omissions(obj):
    value = set(strings(obj, 'omitStages'))
    if not value <= stages:
        raise ValueError('unknown audit stage')
    if 'omitManagedFields' in obj and not isinstance(obj['omitManagedFields'], bool):
        raise ValueError('omitManagedFields must be a boolean')
    return value

try:
    with open(sys.argv[1], encoding='utf-8') as stream:
        policy = yaml.load(stream, Loader=Loader)
    if not isinstance(policy, dict) or policy.get('apiVersion') != 'audit.k8s.io/v1' or policy.get('kind') != 'Policy':
        raise ValueError('expected audit.k8s.io/v1 Policy')
    if set(policy) - {'apiVersion', 'kind', 'metadata', 'rules', 'omitStages', 'omitManagedFields'}:
        raise ValueError('unknown policy field')
    global_omit = omissions(policy)
    rules = policy.get('rules')
    if not isinstance(rules, list):
        raise ValueError('rules must be a list')
    for rule in rules:
        if not isinstance(rule, dict) or rule.get('level') not in {'None', 'Metadata', 'Request', 'RequestResponse'}:
            raise ValueError('invalid rule or audit level')
        if set(rule) - {'level', 'users', 'userGroups', 'verbs', 'resources', 'namespaces', 'nonResourceURLs', 'omitStages', 'omitManagedFields'}:
            raise ValueError('unknown rule field')
        for field in ('users', 'userGroups', 'verbs', 'namespaces', 'nonResourceURLs'):
            strings(rule, field)
        omissions(rule)
        resources = rule.get('resources') or []
        if not isinstance(resources, list):
            raise ValueError('resources must be a list')
        if rule.get('nonResourceURLs') and (resources or rule.get('namespaces')):
            raise ValueError('nonResourceURLs cannot be combined with resources or namespaces')
        for resource in resources:
            if not isinstance(resource, dict) or set(resource) - {'group', 'resources', 'resourceNames'}:
                raise ValueError('invalid resource selector')
            if not isinstance(resource.get('group', ''), str):
                raise ValueError('resource group must be a string')
            strings(resource, 'resources')
            strings(resource, 'resourceNames')
            if resource.get('resourceNames') and not resource.get('resources'):
                raise ValueError('resourceNames requires resources')
    report(True, 'Audit policy parses with valid rule fields')
except (OSError, ValueError, TypeError, yaml.YAMLError) as exc:
    report(False, f'Cannot read a valid audit policy: {exc}')
    finish()

# Partition all possible Secret requests into symbolic boxes. A sentinel stands
# for every value not explicitly named in the policy. Group membership uses
# independent boolean dimensions, so overlapping group selectors are covered.
# Subtraction preserves first-match semantics without enumerating requests.
fields = ('users', 'namespaces', 'verbs', 'resourceNames')
other = object()
universe = []
for field in fields:
    values = ({'get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection'}
              if field == 'verbs' else {other, ''})
    for rule in rules:
        if field == 'resourceNames':
            for resource in rule.get('resources') or []:
                values.update(strings(resource, field))
        else:
            values.update(strings(rule, field))
    universe.append(frozenset(values))
groups = sorted({g for rule in rules for g in strings(rule, 'userGroups')})
universe.extend(frozenset({False, True}) for _ in groups)
universe = tuple(universe)

def subtract(box, match):
    intersection = tuple(a & b for a, b in zip(box, match))
    if any(not part for part in intersection):
        return [box], False
    remaining = []
    core = list(box)
    for i, part in enumerate(intersection):
        difference = core[i] - part
        if difference:
            piece = core.copy()
            piece[i] = difference
            remaining.append(tuple(piece))
        core[i] = part
    return remaining, True

unmatched = [universe]
problem = None
for number, rule in enumerate(rules, 1):
    if rule.get('nonResourceURLs'):
        continue
    selectors = rule.get('resources') or [{}]
    for resource in selectors:
        if resource.get('group', '') not in ('', '*'):
            continue
        names = resource.get('resources') or []
        if names and not {'secrets', '*'} & set(names):
            continue
        box = list(universe)
        for i, field in enumerate(fields):
            values = strings(resource if field == 'resourceNames' else rule, field)
            if values:
                box[i] = frozenset(values)
        selected_groups = strings(rule, 'userGroups')
        matches = []
        for group in selected_groups or [None]:
            match = box.copy()
            if group is not None:
                match[4 + groups.index(group)] = frozenset({True})
            matches.append(tuple(match))
        for match in matches:
            rest = []
            for pending in unmatched:
                pieces, hit = subtract(pending, match)
                rest.extend(pieces)
                if hit:
                    if rule['level'] != 'Metadata':
                        problem = f'Rule {number} selects some Secret requests at {rule["level"]} level'
                    # Ordinary requests only have these two normal stages.
                    if {'RequestReceived', 'ResponseComplete'} <= global_omit | omissions(rule):
                        problem = f'Rule {number} suppresses all normal audit stages for some Secret requests'
            unmatched = rest
if unmatched:
    problem = problem or 'Some Secret requests have no matching audit rule'
report(problem is None, problem or 'All Secret requests select Metadata with a normal audit stage retained')
finish()
PY
