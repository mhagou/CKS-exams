#!/usr/bin/env bash
set -Eeuo pipefail
# cks1 in the question is mapped to the playground worker node01.
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v ssh >/dev/null
command -v kubectl >/dev/null
kubectl --request-timeout=30s get node controlplane node01 >/dev/null
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -s' <<'REMOTE'
set -Eeuo pipefail
[[ $EUID -eq 0 ]]
command -v systemctl >/dev/null
command -v ss >/dev/null
# Use distribution packages only when needed. Refuse package removals, notably
# conflicts with an existing Kubernetes container runtime.
packages=()
command -v dockerd >/dev/null || packages+=(docker.io)
command -v python3 >/dev/null || packages+=(python3)
if ((${#packages[@]})); then
    command -v apt-get >/dev/null || { echo 'Docker/Python missing; no supported package manager.' >&2; exit 1; }
    apt-get update
    apt-get --simulate install --no-install-recommends "${packages[@]}" > /tmp/cks-docker-packages.txt
    if grep -q '^Remv ' /tmp/cks-docker-packages.txt; then
        rm -f /tmp/cks-docker-packages.txt
        echo 'Dependency installation would remove existing packages; refusing.' >&2
        exit 1
    fi
    rm -f /tmp/cks-docker-packages.txt
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-remove --no-install-recommends "${packages[@]}"
fi
systemctl cat docker.service >/dev/null
state=/var/lib/cks-exam9-docker
install -d -m 700 "$state"
getent group docker >/dev/null || groupadd docker
id developer >/dev/null 2>&1 || useradd -m -s /bin/bash developer
docker_gid=$(getent group docker | cut -d: -f3)
[[ $(id -g developer) != "$docker_gid" ]] || { echo 'developer has docker as primary group; refusing to alter existing primary membership.' >&2; exit 1; }
# Capture the original other memberships only once, so reruns do not hide mistakes.
if [[ ! -f $state/other-groups ]]; then
    id -G developer | tr ' ' '\n' | grep -vx "$docker_gid" | sort -nu > "$state/other-groups"
    id -g developer > "$state/primary-group"
fi
usermod -aG docker developer
install -d /etc/docker /etc/systemd/system/docker.service.d
# Preserve all daemon settings except the two exercise-specific settings. Keep
# existing service arguments (containerd path, data root, etc.) as well.
python3 - "$state" <<'PY'
import json, pathlib, re, shlex, shutil, subprocess, sys
state = pathlib.Path(sys.argv[1])
config = pathlib.Path('/etc/docker/daemon.json')
if config.exists() and not (state / 'daemon.json.original').exists():
    shutil.copy2(config, state / 'daemon.json.original')
data = json.loads(config.read_text()) if config.exists() else {}
raw = subprocess.check_output(['systemctl', 'show', 'docker.service', '-p', 'ExecStart', '--value'], text=True)
m = re.search(r'argv\[\]=(.*?) ; ignore_errors=', raw)
if not m:
    raise SystemExit('Cannot safely inspect Docker ExecStart.')
args = shlex.split(m.group(1))
if not args or pathlib.Path(args[0]).name != 'dockerd':
    raise SystemExit('Unsupported Docker service wrapper; refusing to replace it.')
if any(a == '--config-file' or a.startswith('--config-file=') for a in args):
    raise SystemExit('Custom Docker configuration path requires manual adaptation.')
kept = []
i = 0
while i < len(args):
    a = args[i]
    if a in ('-H', '--host', '-G', '--group'):
        i += 2
        continue
    if a.startswith(('--host=', '--group=')) or (a.startswith(('-H', '-G')) and len(a) > 2):
        i += 1
        continue
    kept.append(a)
    i += 1
# Loopback exposure is sufficient for this educational scenario.
data['group'] = 'docker'
data['hosts'] = ['unix:///var/run/docker.sock', 'tcp://127.0.0.1:2375']
config.write_text(json.dumps(data, indent=2) + '\n')
# systemd command syntax: quote each argument and escape specifier expansion.
def quote(a):
    return '"' + a.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$') + '"'
pathlib.Path('/etc/systemd/system/docker.service.d/90-cks-exam9.conf').write_text(
    '[Service]\nExecStart=\nExecStart=' + ' '.join(map(quote, kept)) + '\n')
PY
systemctl daemon-reload
systemctl restart docker.service
systemctl is-active --quiet docker.service
[[ -S /var/run/docker.sock ]]
[[ $(stat -Lc %G /var/run/docker.sock) == docker ]]
id -nG developer | tr ' ' '\n' | grep -qx docker
ss -H -lntp | grep '127.0.0.1:2375' | grep -q '"dockerd"'
REMOTE
kubectl --request-timeout=30s wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\nScenario preparation completed successfully on node01 (cks1).\n'
