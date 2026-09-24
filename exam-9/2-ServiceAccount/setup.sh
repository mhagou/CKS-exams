#!/usr/bin/env bash
set -Eeuo pipefail

trap 'echo "Scenario preparation failed." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
K=(kubectl --request-timeout=30s)

if ! "${K[@]}" get namespace monitoring >/dev/null 2>&1; then
    "${K[@]}" create namespace monitoring >/dev/null
fi
"${K[@]}" apply -f - >/dev/null <<'YAML'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: stats-monitor-sa
  namespace: monitoring
automountServiceAccountToken: true
YAML

install -d -m 0755 /home/candidate/stats-monitor
cat > /home/candidate/stats-monitor/deployment.yaml <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: stats-monitor
  namespace: monitoring
spec:
  replicas: 1
  selector:
    matchLabels:
      app: stats-monitor
  template:
    metadata:
      labels:
        app: stats-monitor
    spec:
      serviceAccountName: stats-monitor-sa
      containers:
        - name: stats-monitor-container
          image: busybox:1.36.1
          command: ["sh", "-c", "while :; do sleep 3600; done"]
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
YAML
chmod 0644 /home/candidate/stats-monitor/deployment.yaml
if id candidate >/dev/null 2>&1; then
    chown candidate:"$(id -gn candidate)" /home/candidate/stats-monitor \
        /home/candidate/stats-monitor/deployment.yaml
fi

# Reset only this exercise's Deployment, including any prior candidate edits.
"${K[@]}" -n monitoring delete deployment stats-monitor --ignore-not-found --wait=true >/dev/null
"${K[@]}" apply -f /home/candidate/stats-monitor/deployment.yaml >/dev/null
"${K[@]}" -n monitoring rollout status deployment/stats-monitor --timeout=180s >/dev/null
[[ $("${K[@]}" -n monitoring get sa stats-monitor-sa -o jsonpath='{.automountServiceAccountToken}') == true ]]
[[ $("${K[@]}" -n monitoring get deployment stats-monitor -o jsonpath='{.spec.template.spec.serviceAccountName}') == stats-monitor-sa ]]
[[ -z $("${K[@]}" -n monitoring get deployment stats-monitor -o jsonpath='{.spec.template.spec.volumes}') ]]
pod=$("${K[@]}" -n monitoring get pods -l app=stats-monitor -o jsonpath='{.items[0].metadata.name}')
"${K[@]}" -n monitoring exec "$pod" -c stats-monitor-container -- \
    sh -c 'test -s /var/run/secrets/kubernetes.io/serviceaccount/token' >/dev/null
[[ -s /home/candidate/stats-monitor/deployment.yaml ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
