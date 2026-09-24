#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation of live Kubernetes NetworkPolicy semantics.
# No endpoint or routes are fabricated: an unreachable link-local address would
# otherwise falsely pass a connectivity test even with no effective policy.
# Actual packet enforcement requires an egress-NetworkPolicy-capable CNI.
NS=metadata-protect
fail() {
    printf '[FAIL] %s\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n' "$1"
    exit 1
}
command -v kubectl >/dev/null || fail 'kubectl is required.'
command -v python3 >/dev/null || fail 'Python 3 is required; run setup first.'
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
kubectl -n "$NS" get pods -o json > "$work/pods.json" || fail 'Cannot read exercise Pods.'
kubectl -n "$NS" get networkpolicies -o json > "$work/policies.json" || fail 'Cannot read exercise NetworkPolicies.'
python3 - "$work/pods.json" "$work/policies.json" <<'PY'
import ipaddress
import json
import sys

passed = failed = 0

def report(ok, description):
    global passed, failed
    passed += bool(ok)
    failed += not ok
    print(f"[{'PASS' if ok else 'FAIL'}] {description}")


def selects(selector, labels):
    if any(labels.get(k) != v for k, v in selector.get('matchLabels', {}).items()):
        return False
    for expr in selector.get('matchExpressions', []):
        key, op = expr['key'], expr['operator']
        values = expr.get('values', [])
        if op == 'In' and (key not in labels or labels[key] not in values):
            return False
        if op == 'NotIn' and key in labels and labels[key] in values:
            return False
        if op == 'Exists' and key not in labels:
            return False
        if op == 'DoesNotExist' and key in labels:
            return False
    return True


metadata = ipaddress.ip_address('169.254.169.254')

def allows_metadata(rule):
    # Missing/empty destinations allows all destinations. Any allowed port is
    # enough to violate the task's requirement to block this entire address.
    peers = rule.get('to', [])
    if not peers:
        return True
    for peer in peers:
        if not peer:
            return True
        block = peer.get('ipBlock')
        if block is not None:
            network = ipaddress.ip_network(block['cidr'], strict=False)
            exceptions = [ipaddress.ip_network(c, strict=False)
                          for c in block.get('except', [])]
            if metadata in network and not any(metadata in n for n in exceptions):
                return True
        # Pod/namespace selectors address cluster Pods, not the external
        # link-local metadata endpoint.
    return False


try:
    with open(sys.argv[1]) as f:
        pods = json.load(f)['items']
    with open(sys.argv[2]) as f:
        policies = json.load(f)['items']
    pods = [p for p in pods if p.get('status', {}).get('phase') not in ('Succeeded', 'Failed')]
    report(bool(pods), 'Exercise namespace contains active workloads')
    report(bool(policies), 'A Kubernetes NetworkPolicy exists in metadata-protect')
    for pod in pods:
        name = pod['metadata']['name']
        if pod['spec'].get('hostNetwork', False):
            report(False, f'{name}: host-network traffic cannot reliably be isolated by NetworkPolicy')
            continue
        labels = pod['metadata'].get('labels', {})
        selected = []
        for policy in policies:
            spec = policy['spec']
            types = spec.get('policyTypes', ['Ingress'] + (['Egress'] if 'egress' in spec else []))
            if 'Egress' in types and selects(spec.get('podSelector', {}), labels):
                selected.append(spec)
        # Policies are additive: a second policy can reopen a destination that
        # the candidate excluded in the first one.
        blocked = bool(selected) and not any(
            allows_metadata(rule) for spec in selected for rule in spec.get('egress', [])
        )
        report(blocked, f'{name}: combined egress policies block 169.254.169.254 on all ports')
except (OSError, ValueError, KeyError, TypeError) as exc:
    report(False, f'Cannot evaluate live policy state: {exc}')

print('Validation scope: live NetworkPolicy semantics; CNI packet enforcement is not tested.')
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
sys.exit(0 if failed == 0 else 1)
PY
