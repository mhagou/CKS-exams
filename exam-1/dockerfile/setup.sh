#!/usr/bin/env bash
set -Eeuo pipefail

LAB_DIR="/root/cks-lab-q2"

echo "================================================="
echo " CKS LAB 02 - Scenario setup"
echo "================================================="

if [[ $EUID -ne 0 ]]; then
    echo "[ERROR] Run this script as root."
    exit 1
fi

rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/app"

# ------------------------------------------------------------
# Prepare lab files
# ------------------------------------------------------------

cat > "${LAB_DIR}/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:latest
USER root
RUN apt-get update && apt-get install -y curl
ADD app.tar.gz /opt/app/
CMD ["/opt/app/run.sh"]
DOCKERFILE


cat > "${LAB_DIR}/deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vulnerable-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: vuln
  template:
    metadata:
      labels:
        app: vuln
    spec:
      containers:
      - name: app
        image: myregistry/vulnerable-app:latest
        securityContext:
          privileged: true
YAML


cat > "${LAB_DIR}/app/run.sh" <<'SCRIPT'
#!/bin/sh
echo "Application started"
while true; do
    sleep 3600
done
SCRIPT

chmod +x "${LAB_DIR}/app/run.sh"

tar -C "${LAB_DIR}/app" \
    -czf "${LAB_DIR}/app.tar.gz" \
    run.sh

rm -rf "${LAB_DIR}/app"


# ------------------------------------------------------------
# Verify scenario
# ------------------------------------------------------------

ERRORS=0

[[ -f "${LAB_DIR}/Dockerfile" ]] || ERRORS=$((ERRORS + 1))
[[ -f "${LAB_DIR}/deployment.yaml" ]] || ERRORS=$((ERRORS + 1))
[[ -f "${LAB_DIR}/app.tar.gz" ]] || ERRORS=$((ERRORS + 1))

grep -q '^FROM ubuntu:latest$' \
    "${LAB_DIR}/Dockerfile" || ERRORS=$((ERRORS + 1))

grep -q '^USER root$' \
    "${LAB_DIR}/Dockerfile" || ERRORS=$((ERRORS + 1))

grep -q '^ADD app.tar.gz /opt/app/$' \
    "${LAB_DIR}/Dockerfile" || ERRORS=$((ERRORS + 1))

grep -q 'privileged: true' \
    "${LAB_DIR}/deployment.yaml" || ERRORS=$((ERRORS + 1))


if [[ "$ERRORS" -ne 0 ]]; then
    echo
    echo "[ERROR] Scenario validation failed."
    exit 1
fi


echo
echo "================================================="
echo " CKS LAB 02 READY"
echo "================================================="
echo
echo "Scenario preparation completed successfully."
echo
echo "Lab directory:"
echo "  ${LAB_DIR}"
echo
echo "Start the exercise from:"
echo
echo "  cd ${LAB_DIR}"
echo
