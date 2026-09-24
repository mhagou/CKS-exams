#!/usr/bin/env bash
set -Eeuo pipefail

# Installation of Sysdig is the candidate's task, not a setup dependency.
trap 'printf "[ERROR] Preparation failed at line %s.\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
command -v apt-get >/dev/null || { echo 'This exercise requires an apt-based playground.' >&2; exit 1; }
k=(kubectl --request-timeout=30s)
"${k[@]}" get node controlplane >/dev/null
"${k[@]}" wait --for=condition=Ready node/controlplane --timeout=120s

# Preserve existing installations from other exercises; do not uninstall software.
if command -v sysdig >/dev/null 2>&1; then
    echo 'NOTICE: Sysdig is already present; its existing installation is preserved.'
fi

# Only reset this lab's own fixture; never overwrite an unrelated default/test.
existing=$("${k[@]}" -n default get pod test --ignore-not-found -o name)
if [[ -n $existing ]]; then
    owner=$("${k[@]}" -n default get pod test -o jsonpath='{.metadata.labels.cks-lab}')
    [[ $owner == sysdig-14 ]] || {
        echo 'default/test already exists and is not owned by this lab.' >&2
        exit 1
    }
    "${k[@]}" -n default delete pod test --wait=true --timeout=90s >/dev/null
fi

# Sysdig observes the local kernel, so keep the test workload on controlplane.
# A long sleep keeps the fixture available beyond the example's one-hour limit.
"${k[@]}" create -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test
  namespace: default
  labels:
    cks-lab: sysdig-14
spec:
  nodeName: controlplane
  tolerations:
    - key: node-role.kubernetes.io/control-plane
      operator: Exists
      effect: NoSchedule
    - key: node-role.kubernetes.io/master
      operator: Exists
      effect: NoSchedule
  containers:
    - name: nginx
      image: nginx:stable
      command: ["sleep", "2147483647"]
YAML
"${k[@]}" -n default wait --for=condition=Ready pod/test --timeout=180s
[[ $("${k[@]}" -n default get pod test -o jsonpath='{.spec.nodeName}') == controlplane ]]
"${k[@]}" -n default exec test -- sh -c 'test "$(id -u)" = 0'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
