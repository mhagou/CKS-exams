#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the playground controlplane only. Never run on the generation host.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for command in kubectl timeout; do
  command -v "$command" >/dev/null || { echo "Missing command: $command" >&2; exit 1; }
done
[[ $(hostname -s) == controlplane ]] || { echo 'Run on controlplane.' >&2; exit 1; }
kubectl get node controlplane >/dev/null
kubectl wait --for=condition=Ready node/controlplane --timeout=90s >/dev/null

# jq is used to inspect structured Falco alerts, not candidate YAML.
if ! command -v falco >/dev/null || ! command -v jq >/dev/null; then
  command -v apt-get >/dev/null || {
    echo 'Automatic dependency installation requires apt; install Falco and jq on this playground first.' >&2
    exit 1
  }
  apt-get update -qq
  if ! command -v jq >/dev/null; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y jq
  fi
  if ! command -v falco >/dev/null; then
    # Official signed repository; apt chooses and verifies the native architecture.
    # https://falco.org/docs/setup/packages/
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg
    key=$(mktemp)
    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc -o "$key"
    gpg --batch --yes --dearmor -o /usr/share/keyrings/cks-falco-archive-keyring.gpg "$key"
    rm -f "$key"
    printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cks-falco-archive-keyring.gpg] https://download.falco.org/packages/deb stable main' \
      > /etc/apt/sources.list.d/cks-falco.list
    apt-get update -qq
    # Let the package select a compatible driver. Preserve existing installations.
    DEBIAN_FRONTEND=noninteractive FALCO_FRONTEND=noninteractive FALCOCTL_ENABLED=no \
      apt-get install -y falco
  fi
fi

marker='CKS Falco lab: harmless demonstration data only.'
[[ ! -L /opt/sensitive-data && ! -L /opt/sensitive-data/secret.txt ]] || {
  echo 'Refusing to use a symlink at the lab data path.' >&2; exit 1;
}
if [[ -e /opt/sensitive-data/secret.txt ]]; then
  [[ -f /opt/sensitive-data/secret.txt ]] &&
    [[ $(cat /opt/sensitive-data/secret.txt) == "$marker" ]] || {
      echo 'Existing secret.txt is not owned by this lab; refusing to expose or replace it.' >&2; exit 1;
    }
else
  mkdir -p /opt/sensitive-data
  printf '%s\n' "$marker" > /opt/sensitive-data/secret.txt
  chmod 0644 /opt/sensitive-data/secret.txt
fi

owner=$(kubectl get pod rogue-pod -n default --ignore-not-found \
  -o jsonpath='{.metadata.labels.cks-exercise}')
if kubectl get pod rogue-pod -n default >/dev/null 2>&1; then
  [[ $owner == falco-rogue ]] || {
    echo 'Existing default/rogue-pod is not owned by this lab.' >&2; exit 1;
  }
  kubectl delete pod rogue-pod -n default --wait=true --timeout=90s >/dev/null
fi
kubectl apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: rogue-pod
  namespace: default
  labels:
    cks-exercise: falco-rogue
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
    - name: snooper-container
      image: busybox:1.37
      command: ["sh", "-c", "while true; do cat /data/secret.txt; sleep 3; done"]
      volumeMounts:
        - name: data-vol
          mountPath: /data
  volumes:
    - name: data-vol
      hostPath:
        path: /opt/sensitive-data
        type: Directory
YAML
kubectl wait -n default --for=condition=Ready pod/rogue-pod --timeout=180s >/dev/null
[[ $(kubectl exec -n default rogue-pod -- cat /data/secret.txt) == "$marker" ]]
kubectl logs -n default rogue-pod --tail=5 | grep -Fq "$marker"

# Confirm the installed capture engine works, without adding any exercise rule
# or changing persistent Falco settings. Keep other running services untouched.
log=$(mktemp)
trap 'rm -f "$log"' EXIT
if ! timeout --signal=TERM --kill-after=5s 45s falco -M 5 \
  -o stdout_output.enabled=true -o file_output.enabled=false \
  -o syslog_output.enabled=false -o program_output.enabled=false \
  -o http_output.enabled=false -o webserver.enabled=false >"$log" 2>&1; then
  echo 'Falco could not capture events using the installed configuration:' >&2
  cat "$log" >&2
  exit 1
fi
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'The demonstration workload and Falco are on controlplane.\n'
