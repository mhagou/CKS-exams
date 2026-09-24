#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. Installation reference:
# https://falco.org/docs/setup/packages/
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl timeout; do
    command -v "$cmd" >/dev/null || { echo "Missing prerequisite: $cmd" >&2; exit 1; }
done
kubectl get node controlplane >/dev/null

# jq is used to inspect structured Falco alerts during validation.
if ! command -v falco >/dev/null || ! command -v jq >/dev/null; then
    command -v apt-get >/dev/null || { echo 'Automatic dependency installation requires Debian/Ubuntu.' >&2; exit 1; }
    apt-get update
    if ! command -v jq >/dev/null; then apt-get install -y jq; fi
    if ! command -v falco >/dev/null; then
        case "$(uname -m)" in
            x86_64|aarch64) ;;
            *) echo 'Unsupported Falco architecture.' >&2; exit 1 ;;
        esac
        apt-get install -y ca-certificates curl gnupg
        # APT verifies package hashes against signed repository metadata.
        install -d -m 0755 /usr/share/keyrings
        curl -fsSL https://falco.org/repo/falcosecurity-packages.asc |
            gpg --batch --yes --dearmor -o /usr/share/keyrings/cks-devmem-falco.gpg
        printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cks-devmem-falco.gpg] https://download.falco.org/packages/deb stable main' \
            > /etc/apt/sources.list.d/cks-devmem-falco.list
        apt-get update
        # Let the official installer select a suitable driver for this host.
        FALCO_FRONTEND=noninteractive FALCOCTL_ENABLED=no apt-get install -y falco
    fi
fi

install -d -m 0755 /etc/falco
# Preserve any existing rules, including candidate work on a repeated setup.
if [[ ! -e /etc/falco/falco_rules.local.yaml ]]; then
    printf '# Local rules for the exercise.\n' > /etc/falco/falco_rules.local.yaml
fi

owner=$(kubectl get pod test-falco -n default --ignore-not-found \
    -o jsonpath='{.metadata.labels.cks-exercise}')
if kubectl get pod test-falco -n default >/dev/null 2>&1; then
    [[ "$owner" == devmem ]] || { echo 'Unrelated default/test-falco already exists; refusing to replace it.' >&2; exit 1; }
    kubectl delete pod test-falco -n default --wait=true --timeout=60s >/dev/null
fi
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: test-falco
  namespace: default
  labels:
    cks-exercise: devmem
spec:
  nodeName: controlplane
  tolerations:
    - operator: Exists
      effect: NoSchedule
  containers:
    - name: test-falco
      image: busybox:1.37
      command: ["sh", "-c", "while :; do sleep 3600; done"]
      securityContext:
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
YAML
kubectl wait -n default --for=condition=Ready pod/test-falco --timeout=180s
# The exercise needs a failed open, never access to actual physical memory.
kubectl exec -n default test-falco -- sh -c 'command -v cat >/dev/null && test ! -e /dev/mem'

# Check that the installed capture engine can start without changing its config
# or loading a solution rule. This temporary rule only tests engine startup.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat > "$work/smoke.yaml" <<'YAML'
- rule: CKS engine startup probe
  desc: Temporary engine startup check
  condition: evt.type = execve
  output: Engine startup probe
  priority: DEBUG
YAML
if ! timeout 45 falco -M 3 -r "$work/smoke.yaml" \
    -o stdout_output.enabled=false -o file_output.enabled=false \
    -o syslog_output.enabled=false -o program_output.enabled=false \
    -o http_output.enabled=false >"$work/engine.log" 2>&1; then
    cat "$work/engine.log" >&2
    echo 'Falco capture engine did not start; inspect the existing host installation.' >&2
    exit 1
fi
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nTest pod: default/test-falco (controlplane).\n'
