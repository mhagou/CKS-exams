#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the playground controlplane. This only prepares the namespace.
trap 'echo "Scenario preparation failed." >&2' ERR
command -v kubectl >/dev/null || { echo "kubectl is required." >&2; exit 1; }
if ! command -v python3 >/dev/null; then
  if command -v apt-get >/dev/null; then
    apt-get update
    apt-get install -y python3
  else
    echo "Install python3 for the validator, then rerun setup." >&2
    exit 1
  fi
fi

if ! kubectl get namespace seminar >/dev/null 2>&1; then
  kubectl create namespace seminar
fi
phase=$(kubectl get namespace seminar -o jsonpath='{.status.phase}')
[[ "$phase" == Active ]] || { echo "Namespace seminar is not active." >&2; exit 1; }
command -v python3 >/dev/null

cat <<'EOF'
=================================================
 CKS LAB READY
=================================================
Scenario preparation completed successfully.
Existing exercise resources, if any, have been preserved.
EOF
