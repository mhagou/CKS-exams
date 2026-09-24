#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. No candidate rules are installed.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl timeout; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
kubectl get node controlplane >/dev/null

if ! command -v falco >/dev/null; then
    # Official signed apt repository: apt verifies package signatures/hashes
    # and selects the native architecture. Preserve existing Falco installs.
    # https://falco.org/docs/setup/packages/
    command -v apt-get >/dev/null || {
        echo 'Automatic Falco installation requires Debian/Ubuntu with apt-get.' >&2
        exit 1
    }
    apt-get update
    apt-get install -y ca-certificates curl gnupg
    if ! grep -Rqs 'download.falco.org/packages/deb' /etc/apt/sources.list /etc/apt/sources.list.d; then
        install -d -m 0755 /usr/share/keyrings
        key_tmp=$(mktemp)
        curl -fsSL https://falco.org/repo/falcosecurity-packages.asc -o "$key_tmp"
        gpg --batch --yes --dearmor -o /usr/share/keyrings/cks-falco-cli.gpg "$key_tmp"
        rm -f "$key_tmp"
        chmod 0644 /usr/share/keyrings/cks-falco-cli.gpg
        printf '%s\n' 'deb [signed-by=/usr/share/keyrings/cks-falco-cli.gpg] https://download.falco.org/packages/deb stable main' \
            > /etc/apt/sources.list.d/cks-falco-cli.list
    fi
    apt-get update
    # Let the official installer select a compatible driver. No existing
    # service is stopped, and no driver/configuration override is forced.
    DEBIAN_FRONTEND=noninteractive FALCO_FRONTEND=noninteractive FALCOCTL_ENABLED=no \
        apt-get install -y falco
fi
falco --version

namespace=cks-falco-cli
owner=cks-falco-cli
if kubectl get namespace "$namespace" >/dev/null 2>&1; then
    actual=$(kubectl get namespace "$namespace" -o jsonpath='{.metadata.labels.cks-exercise}')
    [[ "$actual" == "$owner" ]] || {
        echo "Namespace $namespace exists and is not owned by this exercise." >&2
        exit 1
    }
else
    kubectl create namespace "$namespace"
    kubectl label namespace "$namespace" "cks-exercise=$owner"
fi

# Recreate only our Pod; preserve any previously submitted incident file.
if kubectl -n "$namespace" get pod nginx >/dev/null 2>&1; then
    actual=$(kubectl -n "$namespace" get pod nginx -o jsonpath='{.metadata.labels.cks-exercise}')
    [[ "$actual" == "$owner" ]] || {
        echo 'The nginx Pod is not owned by this exercise.' >&2; exit 1;
    }
    kubectl -n "$namespace" delete pod nginx --wait=true --timeout=90s
fi
kubectl apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: nginx
  namespace: cks-falco-cli
  labels:
    cks-exercise: cks-falco-cli
spec:
  nodeName: controlplane
  tolerations:
    - operator: Exists
      effect: NoSchedule
  terminationGracePeriodSeconds: 5
  containers:
    - name: nginx
      image: nginx:stable
      command: ["/bin/sh", "-c"]
      args:
        - |
          # Harmless, continuous exec activity in this same Nginx container.
          (while :; do cat /etc/hostname >/dev/null; sleep 0.25; done) &
          exec nginx -g 'daemon off;'
      readinessProbe:
        httpGet:
          path: /
          port: 80
        initialDelaySeconds: 2
        periodSeconds: 2
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          memory: 128Mi
YAML
kubectl -n "$namespace" wait --for=condition=Ready pod/nginx --timeout=180s

# A temporary, unrelated file-read rule tests actual kernel capture AND
# container enrichment. It neither detects execs nor writes the incident file.
probe_dir=$(mktemp -d /tmp/cks-falco-check.XXXXXX)
trap 'rm -rf -- "$probe_dir"' EXIT
cat > "$probe_dir/probe.yaml" <<'YAML'
- rule: CKS preparation file read probe
  desc: Temporary readiness check, not a candidate rule
  condition: evt.type = openat and evt.dir = < and proc.name = cat and fd.name = /etc/hostname and container.id != host
  output: "CKS_PREPARATION_PROBE %container.image.repository %container.id"
  priority: DEBUG
YAML
if ! timeout 45 falco -M 8 -r "$probe_dir/probe.yaml" \
    -o stdout_output.enabled=true -o file_output.enabled=false \
    -o syslog_output.enabled=false -o program_output.enabled=false \
    -o http_output.enabled=false -o grpc_output.enabled=false \
    > "$probe_dir/output" 2> "$probe_dir/errors"; then
    echo 'Falco could not complete a short capture with its existing configuration.' >&2
    cat "$probe_dir/errors" >&2
    exit 1
fi
if ! grep -Eq 'CKS_PREPARATION_PROBE [^ ]*nginx[ :]' "$probe_dir/output"; then
    echo 'Falco did not detect the Nginx file-read probe with container metadata.' >&2
    echo 'Check the Falco driver and container-runtime metadata integration.' >&2
    exit 1
fi
kubectl -n "$namespace" exec nginx -- sh -c 'kill -0 1 && test -r /etc/hostname'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\n'
printf 'Scenario preparation completed successfully.\n'
printf 'Target: namespace %s, Pod nginx, one Nginx container on controlplane.\n' "$namespace"
printf 'Harmless process activity runs continuously inside the container.\n'
if [[ -e /opt/falco-incident.txt ]]; then
    printf 'An existing /opt/falco-incident.txt was preserved; it may be from an earlier attempt.\n'
fi
