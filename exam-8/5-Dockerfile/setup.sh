#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground. Re-running resets this exercise's Dockerfile.
trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
lab=/opt/course/image
mkdir -p "$lab"
[[ ! -L "$lab/api-server.Dockerfile" ]] || {
    echo 'Refusing to overwrite a symlink at the exercise path.' >&2; exit 1;
}

# The supplied exercise has no application payload. Supply a harmless native
# executable as a COPY fixture only; building/running an API is not an objective.
# Preserve an existing application binary, if one is already supplied.
if [[ ! -e "$lab/app-server" && ! -L "$lab/app-server" ]]; then
    install -m 0755 /bin/true "$lab/app-server"
fi
[[ -f "$lab/app-server" && -x "$lab/app-server" ]] || {
    echo 'The existing app-server must be an executable file.' >&2; exit 1;
}

initial=$(cat <<'DOCKERFILE'
FROM ubuntu:20.04
RUN apt-get update && apt-get install -y curl wget python3 python3-pip
RUN useradd -m appuser
COPY ./app-server /app/server
RUN chmod +x /app/server
USER root
ENTRYPOINT /app/server
DOCKERFILE
)
printf '%s\n' "$initial" > "$lab/api-server.Dockerfile"
chmod 0644 "$lab/api-server.Dockerfile"

# Check the complete initial file without exposing the candidate's answer.
[[ $(cat "$lab/api-server.Dockerfile") == "$initial" ]]
[[ -s "$lab/app-server" && -x "$lab/app-server" ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
