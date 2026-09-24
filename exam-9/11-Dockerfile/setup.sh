#!/usr/bin/env bash
set -Eeuo pipefail

# File-editing simulation only: no cluster resources or host accounts are needed.
LAB_DIR=/root/cks-dockerfile-lab
trap 'printf "[ERROR] Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run setup.sh as root on controlplane.' >&2; exit 1; }

# A real YAML parser is needed to validate equivalent YAML representations.
if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || {
        echo 'Install python3 and PyYAML, then rerun setup.sh.' >&2; exit 1;
    }
    apt-get update
    apt-get install -y python3 python3-yaml
fi

# Refuse to overwrite an unrelated directory. Reruns reset only these lab files.
if [[ -e "$LAB_DIR" || -L "$LAB_DIR" ]]; then
    [[ -d "$LAB_DIR" && ! -L "$LAB_DIR" && -f "$LAB_DIR/.cks-file-edit-lab" ]] || {
        echo "Refusing to overwrite unrecognized lab directory: $LAB_DIR" >&2; exit 1;
    }
else
    mkdir -m 0755 "$LAB_DIR"
    touch "$LAB_DIR/.cks-file-edit-lab"
fi
for file in Dockerfile deployment.yaml; do
    [[ ! -L "$LAB_DIR/$file" ]] || { echo "Refusing symlink: $file" >&2; exit 1; }
done

# Preserve the supplied non-security errors: building an image is not an objective.
cat > "$LAB_DIR/Dockerfile" <<'DOCKERFILE'
FROM ubuntu:latest
RUN apt-get update -y
RUN apt-install nginx -y
COPY entrypoint.sh /
ENTRYPOINT ['/entrypoint.sh']
USER ROOT
DOCKERFILE
cat > "$LAB_DIR/deployment.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  name: security-context-demo-2
spec:
  securityContext:
    runAsUser: 1000
  containers:
    - name: sec-ctx-demo-2
      image: gcr.io/google-samples/node-hello:1.0
      securityContext:
        runAsUser: 0
        privileged: true
        allowPrivilegeEscalation: false
YAML

python3 - "$LAB_DIR" <<'PY'
import pathlib, sys, yaml
root = pathlib.Path(sys.argv[1])
assert (root / 'Dockerfile').read_text().splitlines() == [
    'FROM ubuntu:latest', 'RUN apt-get update -y', 'RUN apt-install nginx -y',
    'COPY entrypoint.sh /', "ENTRYPOINT ['/entrypoint.sh']", 'USER ROOT']
assert yaml.safe_load((root / 'deployment.yaml').read_text()) == {
    'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'security-context-demo-2'},
    'spec': {'securityContext': {'runAsUser': 1000}, 'containers': [{
        'name': 'sec-ctx-demo-2', 'image': 'gcr.io/google-samples/node-hello:1.0',
        'securityContext': {'runAsUser': 0, 'privileged': True,
                            'allowPrivilegeEscalation': False}}]}}
PY
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Edit %s/Dockerfile and %s/deployment.yaml.\n' "$LAB_DIR" "$LAB_DIR"
printf 'This is a file-editing simulation; no image build or cluster apply is required.\nRerunning setup.sh resets these two exercise files.\n'
