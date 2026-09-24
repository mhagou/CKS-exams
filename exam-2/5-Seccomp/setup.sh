#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed." >&2' ERR

[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
command -v ssh >/dev/null || { echo 'ssh is required for validation of worker profiles.' >&2; exit 1; }
[[ $(hostname -s) == controlplane ]] || { echo 'Run on controlplane.' >&2; exit 1; }
# JSON parsing is needed to compare seccomp profiles without depending on their
# formatting. Validation must not install tools or change the candidate's state.
if ! command -v jq >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Install jq before preparing this lab.' >&2; exit 1; }
    apt-get update
    apt-get install -y jq
fi
kubectl get node controlplane >/dev/null
kubectl get node node01 >/dev/null
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'test "$(id -u)" -eq 0' || {
    echo 'Root SSH access to node01 is required for profile validation.' >&2
    exit 1
}

# The supplied exercise omitted its input profile. LOG permits syscalls and
# requests kernel auditing; installing and selecting this profile is the task.
# Do not replace an unrelated pre-existing input file.
if [[ -e /root/auditing.json ]]; then
    [[ $(jq -cS . /root/auditing.json) == '{"defaultAction":"SCMP_ACT_LOG"}' ]] || {
        echo '/root/auditing.json already contains a different profile; preserve it before setup.' >&2
        exit 1
    }
else
    printf '{\n  "defaultAction": "SCMP_ACT_LOG"\n}\n' > /root/auditing.json
fi
chmod 0644 /root/auditing.json
if ! kubectl get namespace alpha >/dev/null 2>&1; then
    kubectl create namespace alpha
fi
# Reset only the exercise Pod; leave other namespace resources intact.
kubectl delete pod nginx-auditing -n alpha --ignore-not-found --wait=true --timeout=60s

[[ -s /root/auditing.json ]]
[[ $(kubectl get namespace alpha -o jsonpath='{.status.phase}') == Active ]]
[[ -z $(kubectl get pod nginx-auditing -n alpha --ignore-not-found -o name) ]]
kubectl get node node01 >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nInput profile: /root/auditing.json\n'
