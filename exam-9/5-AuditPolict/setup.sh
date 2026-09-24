#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
# PyYAML is needed to preserve existing exclusions and evaluate ordered policy rules.
if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install python3 and python3-yaml, then retry.' >&2; exit 1; }
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-yaml
fi
kubectl --request-timeout=20s get --raw=/readyz >/dev/null
kubectl get node controlplane >/dev/null
[[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]] || {
    echo 'Expected a kubeadm controlplane with a static API server manifest.' >&2; exit 1;
}
# Keep unrelated namespaces, API server settings, mounts and audit backends intact.
if ! kubectl get namespace frontend >/dev/null 2>&1; then
    kubectl create namespace frontend >/dev/null
fi
install -d -m 0755 /etc/Kubernetes/logpolicy
python3 <<'PY'
from pathlib import Path
import shutil
import yaml
p = Path('/etc/Kubernetes/logpolicy/audit-policy.yaml')
exclusions = []
if p.exists():
    old = yaml.safe_load(p.read_text())
    if not isinstance(old, dict) or old.get('kind') != 'Policy':
        raise SystemExit('Existing policy is not a valid Policy; refusing to overwrite it.')
    backup = p.with_suffix('.yaml.pre-lab')
    if not backup.exists():
        shutil.copy2(p, backup)
    exclusions = [r for r in old.get('rules', []) if r.get('level') == 'None']
if not exclusions:
    exclusions = [{'level': 'None', 'nonResourceURLs': ['/healthz*', '/readyz*', '/livez*']}]
policy = {'apiVersion': 'audit.k8s.io/v1', 'kind': 'Policy',
          'omitStages': ['RequestReceived'], 'rules': exclusions}
p.write_text(yaml.safe_dump(policy, sort_keys=False))
p.chmod(0o644)
check = yaml.safe_load(p.read_text())
assert check['rules'] and all(r['level'] == 'None' for r in check['rules'])
PY
kubectl --request-timeout=20s get --raw=/readyz >/dev/null
[[ $(kubectl get namespace frontend -o jsonpath='{.status.phase}') == Active ]]
[[ -s /etc/Kubernetes/logpolicy/audit-policy.yaml ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
