#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. No Kubernetes resources are needed.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v systemctl >/dev/null

# Use the distribution package only when Docker is absent. Do not replace an
# existing containerd installation or upgrade existing playground packages.
packages=()
command -v dockerd >/dev/null || packages+=(docker.io)
command -v python3 >/dev/null || packages+=(python3)
command -v ss >/dev/null || packages+=(iproute2)
if ((${#packages[@]})); then
    command -v apt-get >/dev/null || {
        echo 'Install Docker Engine, python3 and iproute2 for this distribution first.' >&2
        exit 1
    }
    apt-get update -qq
    plan=$(apt-get --simulate --no-install-recommends --no-upgrade install "${packages[@]}")
    if grep -Eq '^Remv |^Inst [^ ]+ \[' <<<"$plan"; then
        echo 'Dependency installation would replace or upgrade existing packages; refusing.' >&2
        exit 1
    fi
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends --no-upgrade "${packages[@]}"
fi
for cmd in getent id useradd usermod groupadd; do command -v "$cmd" >/dev/null; done
systemctl start docker.service
pid=$(systemctl show docker.service --property=MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]]

# Preserve the running daemon's options. If hosts are defined in JSON, modify
# that array only; otherwise add a host through a dedicated systemd drop-in.
# Docker forbids defining hosts in both places.
python3 - "$pid" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sys

pid = sys.argv[1]
args = Path(f'/proc/{pid}/cmdline').read_bytes().decode().rstrip('\0').split('\0')
if Path(os.readlink(f'/proc/{pid}/exe')).name != 'dockerd':
    sys.exit('docker.service does not directly run dockerd; refusing to replace its launcher.')
config = Path('/etc/docker/daemon.json')
for i, arg in enumerate(args):
    if arg == '--config-file':
        config = Path(args[i + 1])
    elif arg.startswith('--config-file='):
        config = Path(arg.split('=', 1)[1])
data = json.loads(config.read_text()) if config.exists() else {}
hosts = list(data.get('hosts', []))
cli_hosts = []
for i, arg in enumerate(args):
    if arg in ('-H', '--host'):
        cli_hosts.append(args[i + 1])
    elif arg.startswith('--host='):
        cli_hosts.append(arg.split('=', 1)[1])
    elif arg.startswith('-H') and len(arg) > 2:
        cli_hosts.append(arg[2:].lstrip('='))
if any(h.startswith('tcp://') for h in hosts + cli_hosts):
    sys.exit(0)  # An existing TCP endpoint already supplies the initial state.
endpoint = 'tcp://127.0.0.1:2375'
if 'hosts' in data:
    backup = config.with_name(config.name + '.cks17.original')
    if not backup.exists():
        shutil.copy2(config, backup)
    data['hosts'] = (hosts or ['unix:///var/run/docker.sock']) + [endpoint]
    config.write_text(json.dumps(data, indent=2) + '\n')
else:
    if not cli_hosts:
        args += ['--host=unix:///var/run/docker.sock']
    args += ['--host=' + endpoint]
    # Quote literal arguments for systemd, including its own $/% expansion.
    def quote(value):
        return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('%', '%%').replace('$', '$$').replace('\n', '\\n').replace('\r', '\\r') + '"'
    dropin = Path('/etc/systemd/system/docker.service.d/99-cks17-tcp.conf')
    dropin.parent.mkdir(parents=True, exist_ok=True)
    dropin.write_text('[Service]\nExecStart=\nExecStart=' + ' '.join(map(quote, args)) + '\n')
PY
systemctl daemon-reload
systemctl restart docker.service
getent group docker >/dev/null || groupadd docker
id developer >/dev/null 2>&1 || useradd -m -s /bin/bash developer
usermod -aG docker developer

# Self-check the actual process and group database without printing the answer.
ready=false
for ((attempt=0; attempt<30; attempt++)); do
    pid=$(systemctl show docker.service --property=MainPID --value)
    listeners=$(ss -H -lntp)
    if systemctl is-active --quiet docker.service &&
       [[ $pid =~ ^[1-9][0-9]*$ ]] &&
       grep -Fq "pid=$pid," <<<"$listeners"; then
        ready=true
        break
    fi
    sleep 1
done
[[ $ready == true ]]
docker_gid=$(getent group docker | cut -d: -f3)
[[ " $(id -G developer) " == *" $docker_gid "* ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully on controlplane.\n'
