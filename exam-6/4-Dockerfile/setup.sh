#!/usr/bin/env bash
set -Eeuo pipefail

# This is a file-review exercise; no image build or cluster changes are needed.
# Re-running setup resets only the two candidate files in this lab directory.
LAB_DIR=${LAB_DIR:-/root/cks-dockerfile-lab}
[[ $EUID -eq 0 ]] || { echo 'Run setup as root on controlplane.' >&2; exit 1; }
trap 'echo "Scenario preparation failed." >&2' ERR

# A YAML parser is needed to validate mappings and booleans, not their formatting.
if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || {
        echo 'Install python3 and python3-yaml, then rerun setup.' >&2
        exit 1
    }
    apt-get update -qq
    apt-get install -y python3 python3-yaml
fi

mkdir -p -- "$LAB_DIR"
cat > "$LAB_DIR/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:latest
USER root
RUN apt get install -y lsof=4.72 wget=1.17.1 nginx=4.2
ENV ENVIRONMENT=testing
USER root
CMD ["nginx -d"]
DOCKERFILE

cat > "$LAB_DIR/Deployment.yaml" <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  labels:
    app: kafka
  name: kafka
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kafka
  template:
    metadata:
      labels:
        app: kafka
    spec:
      containers:
        - image: bitnami/kafka
          name: kafka
          volumeMounts:
            - name: kafka-vol
              mountPath: /var/lib/kafka
          securityContext:
            capabilities:
              add: [NET_ADMIN]
              drop: [all]
            privileged: true
            readOnlyRootFilesystem: false
            runAsUser: 65535
          resources: {}
      volumes:
        - name: kafka-vol
          emptyDir: {}
YAML

python3 - "$LAB_DIR" <<'PY'
import pathlib
import sys
import yaml

directory = pathlib.Path(sys.argv[1])
docker = (directory / 'Dockerfile').read_text()
assert docker.startswith('FROM ubuntu:latest\n')
assert docker.count('USER root\n') == 2
deployment = yaml.safe_load((directory / 'Deployment.yaml').read_text())
pod = deployment['spec']['template']['spec']
container = pod['containers'][0]
assert deployment['kind'] == 'Deployment'
assert container['image'] == 'bitnami/kafka'
assert container['securityContext']['privileged'] is True
assert container['securityContext']['readOnlyRootFilesystem'] is False
assert container['volumeMounts'][0]['name'] == pod['volumes'][0]['name']
PY

printf '\n=================================================\n CKS LAB READY\n=================================================\n\n'
printf 'Scenario preparation completed successfully.\nCandidate files: %s/Dockerfile and %s/Deployment.yaml\n' "$LAB_DIR" "$LAB_DIR"
printf 'Edit these files in place. This exercise does not require building or deploying them.\n'
