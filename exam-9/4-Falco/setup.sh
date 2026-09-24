#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Preparation failed at line $LINENO." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl ssh; do command -v "$cmd" >/dev/null; done
# Use the playground's existing context; do not invent the original trace context.
kubectl get node controlplane node01 >/dev/null
[[ $(kubectl get node node01 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}') == True ]]
owner=$(kubectl -n default get pod tomcat --ignore-not-found -o jsonpath='{.metadata.labels.cks-exercise}')
exists=$(kubectl -n default get pod tomcat --ignore-not-found -o name)
if [[ -n $exists && $owner != falco-process-lab ]]; then
    echo 'Refusing to replace an unrelated default/tomcat Pod.' >&2
    exit 1
fi
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -s' <<'WORKER'
set -Eeuo pipefail
[[ $EUID -eq 0 ]]
# Install only missing tools. Signed apt repositories handle package architecture
# selection and verify package hashes. Existing Falco configuration is untouched.
if ! command -v falco >/dev/null || ! command -v sysdig >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Automatic tool installation requires Debian/Ubuntu.' >&2; exit 1; }
    apt-get update
    apt-get install -y ca-certificates curl gnupg
fi
if ! command -v falco >/dev/null; then
    # https://falco.org/docs/setup/packages/
    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc |
        gpg --batch --yes --dearmor -o /usr/share/keyrings/cks-falco.gpg
    echo 'deb [signed-by=/usr/share/keyrings/cks-falco.gpg] https://download.falco.org/packages/deb stable main' > /etc/apt/sources.list.d/cks-falco.list
    apt-get update
    FALCO_FRONTEND=noninteractive FALCOCTL_ENABLED=no apt-get install -y falco
fi
if ! command -v sysdig >/dev/null; then
    # Prefer the distribution's signed package, avoiding an extra repository.
    apt-get install -y sysdig
fi
falco --version
sysdig --version
mkdir -p /home/cert_masters
# Preserve previous candidate work on repeat setup, rather than deleting it.
if [[ -e /home/cert_masters/report || -L /home/cert_masters/report ]]; then
    mv -- /home/cert_masters/report "/home/cert_masters/report.before-setup.$(date +%s%N)"
fi
# Verify actual syscall capture, not merely the presence of a binary. No task
# filter, custom rule or incident report is installed by this smoke test.
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
if ! timeout 20 sysdig -n 1 -p '%evt.type' >"$tmp/event" 2>"$tmp/error" || [[ ! -s $tmp/event ]]; then
    # Older packages use the kernel module; modern versions may support eBPF.
    if sysdig --help 2>&1 | grep -q -- '--modern-bpf'; then
        timeout 20 sysdig --modern-bpf -n 1 -p '%evt.type' >"$tmp/event" 2>"$tmp/error"
        [[ -s $tmp/event ]]
        echo 'Sysdig capture is available with --modern-bpf.'
    else
        cat "$tmp/error" >&2
        echo 'Sysdig cannot capture on this worker/kernel; preparation is incomplete.' >&2
        exit 1
    fi
fi
WORKER
# Recreate only this exercise's Pod so a repeat setup restores its workload.
if [[ -n $exists ]]; then kubectl -n default delete pod tomcat --wait=true; fi
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: tomcat
  namespace: default
  labels:
    cks-exercise: falco-process-lab
spec:
  nodeName: node01
  containers:
    - name: tomcat
      image: tomcat:10.1-jre21-temurin
      command: [/bin/sh, -c]
      args:
        - |
          set -eu
          mkdir -p /tmp/cks-activity
          cp /bin/sleep /tmp/cks-activity/cryptominer
          (
            while :; do
              /tmp/cks-activity/cryptominer 1
              sleep 1
            done
          ) &
          exec catalina.sh run
      resources:
        requests:
          cpu: 100m
          memory: 256Mi
        limits:
          cpu: '1'
          memory: 768Mi
YAML
kubectl -n default wait --for=condition=Ready pod/tomcat --timeout=240s
[[ $(kubectl -n default get pod tomcat -o jsonpath='{.spec.nodeName}') == node01 ]]
[[ $(kubectl -n default get pod tomcat -o jsonpath='{.spec.containers[*].name}' | wc -w) -eq 1 ]]
# Observe the recurring harmless process directly, without configuring detection.
kubectl -n default exec tomcat -- sh -c '
  for attempt in 1 2 3 4 5 6; do
    for comm in /proc/[0-9]*/comm; do
      [ -r "$comm" ] || continue
      read -r name < "$comm" || continue
      [ "$name" != cryptominer ] || exit 0
    done
    sleep 1
  done
  exit 1
'
printf '\n=================================================\n CKS LAB READY\n=================================================\nScenario preparation completed successfully.\nPod: default/tomcat; worker: node01.\nKeep the incident report at /home/cert_masters/report on node01.\n'
