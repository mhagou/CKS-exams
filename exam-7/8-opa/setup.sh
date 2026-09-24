#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on the playground.' >&2; exit 1; }
# jq keeps structural validation of live Kubernetes objects auditable.
if ! command -v jq >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update -qq
    apt-get install -y jq
  else
    echo 'Install jq on the playground, then rerun setup.' >&2
    exit 1
  fi
fi
kubectl get nodes >/dev/null
# Preserve an existing Gatekeeper installation, including its configuration.
if ! kubectl get crd constrainttemplates.templates.gatekeeper.sh >/dev/null 2>&1; then
  kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.14/deploy/gatekeeper.yaml
fi
kubectl wait --for=condition=Established crd/constrainttemplates.templates.gatekeeper.sh --timeout=180s
kubectl wait --for=condition=Ready pod -n gatekeeper-system -l control-plane=controller-manager --timeout=300s
# Reset only this exercise's constraint, if a previous attempt exists.
if kubectl get crd k8srequiredlabels.constraints.gatekeeper.sh >/dev/null 2>&1; then
  kubectl delete k8srequiredlabels.constraints.gatekeeper.sh require-env-label --ignore-not-found --wait=true
fi
kubectl apply -f - <<'YAML'
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequiredlabels
        violation[{"msg": msg, "details": {"missing_labels": missing}}] {
          provided := {label | input.review.object.metadata.labels[label]}
          required := {label | label := input.parameters.labels[_]}
          missing := required - provided
          count(missing) > 0
          msg := sprintf("you must provide labels: %v", [missing])
        }
YAML
for ((i=0; i<90; i++)); do
  if kubectl get crd k8srequiredlabels.constraints.gatekeeper.sh >/dev/null 2>&1; then break; fi
  sleep 2
done
kubectl wait --for=condition=Established crd/k8srequiredlabels.constraints.gatekeeper.sh --timeout=120s
ready=false
for ((i=0; i<60; i++)); do
  if kubectl get constrainttemplate k8srequiredlabels -o json | jq -e '
    .metadata.generation as $g |
    .status.created == true and
    ([.status.byPod[]? | select((.errors // [] | length) > 0 or .observedGeneration != $g)] | length == 0)
  ' >/dev/null; then ready=true; break; fi
  sleep 2
done
[[ $ready == true ]] || { echo 'Template did not become ready.' >&2; exit 1; }
[[ -z $(kubectl get k8srequiredlabels.constraints.gatekeeper.sh require-env-label --ignore-not-found -o name) ]]
# Verify the initial scenario permits an unlabeled namespace, without persisting it.
# Retry to allow the previous attempt's constraint to leave admission caches.
ready=false
for ((i=0; i<30; i++)); do
  if kubectl create namespace "cks-opa-setup-$(date +%s)-$RANDOM" --dry-run=server >/dev/null 2>&1; then
    ready=true; break
  fi
  sleep 2
done
[[ $ready == true ]] || { echo 'Initial namespace admission is blocked; inspect existing policies.' >&2; exit 1; }
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
