#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the playground controlplane. This lab needs no cluster resources.
LAB_DIR=/root/cks-dockerfile
[[ $EUID -eq 0 ]] || { echo 'Run setup.sh as root.' >&2; exit 1; }
for command in awk cmp mktemp; do
    command -v "$command" >/dev/null || { echo "Missing required command: $command" >&2; exit 1; }
done
# Do not follow candidate-created links when resetting the exercise.
for path in "$LAB_DIR" "$LAB_DIR/src" "$LAB_DIR/.cks-dockerfile-lab" \
    "$LAB_DIR/Dockerfile" "$LAB_DIR/package.json" \
    "$LAB_DIR/package-lock.json" "$LAB_DIR/src/index.js"; do
    if [[ -L $path ]]; then
        echo "Refusing to overwrite a symbolic link: $path" >&2
        exit 1
    fi
done
# Refuse to overwrite an unrelated directory. Re-running resets this lab only.
if [[ -e $LAB_DIR && ! -f $LAB_DIR/.cks-dockerfile-lab ]]; then
    echo "Refusing to overwrite unmarked directory: $LAB_DIR" >&2
    exit 1
fi
mkdir -p "$LAB_DIR/src"
touch "$LAB_DIR/.cks-dockerfile-lab"
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'DOCKERFILE'
FROM node:latest

ENV CI=true
RUN apt-get update
RUN apt-get install -y wget
RUN apt-get install -y curl

USER root
WORKDIR /code
COPY package.json package-lock.json /code/
RUN npm ci
COPY src /code/src
CMD ["npm", "start"]
DOCKERFILE
cat "$tmp" > "$LAB_DIR/Dockerfile"
cat > "$LAB_DIR/package.json" <<'JSON'
{"name":"cks-dockerfile-lab","version":"1.0.0","private":true,"scripts":{"start":"node src/index.js"}}
JSON
cat > "$LAB_DIR/package-lock.json" <<'JSON'
{"name":"cks-dockerfile-lab","version":"1.0.0","lockfileVersion":3,"requires":true,"packages":{"":{"name":"cks-dockerfile-lab","version":"1.0.0"}}}
JSON
cat > "$LAB_DIR/src/index.js" <<'JS'
const http = require('http');
http.createServer((req, res) => { res.end('CKS practice application\n'); }).listen(3000, '0.0.0.0');
JS
cmp -s "$tmp" "$LAB_DIR/Dockerfile"
for file in package.json package-lock.json src/index.js; do
    [[ -s $LAB_DIR/$file ]] || { echo "Preparation failed: missing $file" >&2; exit 1; }
done
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nEdit %s/Dockerfile. The build context is %s.\n' "$LAB_DIR" "$LAB_DIR"
