#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the playground controlplane as root, never on the development host.
trap 'echo "Scenario preparation failed." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
K=(kubectl --request-timeout=30s)
[[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]
[[ $("${K[@]}" get node controlplane -o jsonpath='{.metadata.name}') == controlplane ]]
[[ $("${K[@]}" get node node01 -o jsonpath='{.metadata.name}') == node01 ]]
"${K[@]}" get --raw=/readyz >/dev/null

# Do not undo admission configuration belonging to a previous lab. Confirm that
# ordinary Pod admission works before staging this exercise. Dry-run creates nothing.
"${K[@]}" create --dry-run=server -f - >/dev/null <<'POD'
apiVersion: v1
kind: Pod
metadata:
  generateName: cks-admission-baseline-
  namespace: default
spec:
  restartPolicy: Never
  securityContext:
    runAsNonRoot: true
    runAsUser: 65534
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: probe
    image: registry.k8s.io/pause:3.10
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: [ALL]
POD

# Stage inputs only. The candidate creates the destination directory, copies
# the inputs, and configures the API server. No cluster configuration is changed.
assets=/root/cks-admissioncontroller
install -d -m 0700 "$assets"
cat > "$assets/admission-config.yaml" <<'CONFIG'
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
- name: ImagePolicyWebhook
  configuration:
    imagePolicy:
      kubeConfigFile: /etc/kubernetes/admission/webhook.kubeconfig
      allowTTL: 50
      denyTTL: 50
      retryBackoff: 500
      defaultAllow: false
CONFIG
cat > "$assets/webhook.kubeconfig" <<'CONFIG'
apiVersion: v1
kind: Config
clusters:
- cluster:
    server: https://imagescanner.local:8080/image_policy
  name: scanner
contexts:
- context:
    cluster: scanner
    user: api-server
  name: scanner-context
current-context: scanner-context
users:
- name: api-server
  user: {}
CONFIG
# The source kubeconfig references an absent user. Supply an empty identity so
# the intended failure is the dummy endpoint, not an invalid kubeconfig.
chmod 0600 "$assets/admission-config.yaml" "$assets/webhook.kubeconfig"
[[ -s "$assets/admission-config.yaml" && -s "$assets/webhook.kubeconfig" ]]
[[ $(kubectl --kubeconfig="$assets/webhook.kubeconfig" config view --minify \
  -o jsonpath='{.clusters[0].cluster.server}') == https://imagescanner.local:8080/image_policy ]]
"${K[@]}" get --raw=/readyz >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nCandidate input files: %s\n' "$assets"
