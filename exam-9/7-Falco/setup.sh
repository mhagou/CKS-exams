#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null
kubectl get node controlplane >/dev/null

# Install only when missing. APT verifies repository metadata and package hashes
# and chooses the native architecture. Preserve existing Falco installations.
if ! command -v falco >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Automatic Falco installation requires Debian/Ubuntu.' >&2; exit 1; }
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    key=$(mktemp)
    trap 'rm -f "${key:-}"' EXIT
    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc -o "$key"
    gpg --batch --yes --dearmor -o /usr/share/keyrings/cks-falco-keyring.gpg "$key"
    echo 'deb [signed-by=/usr/share/keyrings/cks-falco-keyring.gpg] https://download.falco.org/packages/deb stable main' > /etc/apt/sources.list.d/cks-falco.list
    apt-get update
    # Official package auto-selects a compatible driver; no driver is forced.
    DEBIAN_FRONTEND=noninteractive FALCO_FRONTEND=noninteractive FALCOCTL_ENABLED=no apt-get install -y falco
fi
falco --version

owner=$(kubectl -n default get pod nginx --ignore-not-found -o jsonpath='{.metadata.labels.cks-exercise}')
if kubectl -n default get pod nginx >/dev/null 2>&1; then
    [[ $owner == falco-processes ]] || { echo 'Refusing to replace an unrelated default/nginx Pod.' >&2; exit 1; }
    kubectl -n default delete pod nginx --wait=true --timeout=90s
fi
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: default
  labels:
    cks-exercise: falco-processes
spec:
  nodeName: controlplane
  tolerations:
    - operator: Exists
      effect: NoSchedule
  containers:
    - name: nginx
      image: nginx:stable-alpine
      command: ["/bin/sh", "-c"]
      args:
        - |
          # Harmless recurring executions for the candidate to observe.
          (while :; do ls /tmp >/dev/null; sleep 1; done) &
          exec nginx -g 'daemon off;'
      readinessProbe:
        httpGet:
          path: /
          port: 80
        initialDelaySeconds: 2
        periodSeconds: 2
YAML
kubectl -n default wait --for=condition=Ready pod/nginx --timeout=180s
kubectl -n default exec nginx -c nginx -- sh -c 'kill -0 1 && command -v ls && command -v sleep' >/dev/null
# Smoke-test the installed engine without supplying any solution rules or
# touching existing service/configuration. Keep diagnostic output on failure.
log=$(mktemp)
trap 'rm -f "${key:-}" "${log:-}"' EXIT
if command -v pgrep >/dev/null && pgrep -x falco >/dev/null; then
    # An existing detector may own an exclusive driver device. Do not compete
    # with it or stop its service just to perform a smoke test.
    :
elif ! timeout 45 falco -M 2 >"$log" 2>&1; then
    cat "$log" >&2
    echo 'Falco cannot capture with its existing configuration; resolve the reported engine error and rerun setup.' >&2
    exit 1
fi
printf '\n=================================================\n CKS LAB READY\n=================================================\nScenario preparation completed successfully.\nNginx: default/nginx on controlplane.\nExisting incident reports are preserved; use a fresh report for this exercise.\n'
