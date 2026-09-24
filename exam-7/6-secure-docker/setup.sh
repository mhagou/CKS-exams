#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v systemctl >/dev/null
# Use the distribution's signed packages; never replace an installed engine.
missing=()
command -v python3 >/dev/null || missing+=(python3)
command -v ss >/dev/null || missing+=(iproute2)
command -v dockerd >/dev/null || missing+=(docker.io)
if ((${#missing[@]})); then
    command -v apt-get >/dev/null || { echo 'Install Docker Engine, Python 3 and iproute2 on this playground first.' >&2; exit 1; }
    apt-get update -qq
    apt-get install -y --no-remove "${missing[@]}"
fi
getent group docker >/dev/null || groupadd --system docker
systemctl start docker.service
# Preserve all existing daemon arguments except the two settings this lab targets.
python3 <<'PY'
import json, pathlib, shutil, subprocess

def show(key):
    return subprocess.check_output(['systemctl','show','docker.service','--value','-p',key],text=True).strip()
pid = int(show('MainPID'))
args = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().decode().rstrip('\0').split('\0')
if pathlib.Path(args[0]).name != 'dockerd':
    raise SystemExit('Expected docker.service to launch dockerd directly.')
kept, hosts, config = [args[0]], [], '/etc/docker/daemon.json'
i = 1
while i < len(args):
    a = args[i]
    if a in ('-H','--host','-G','--group'):
        if a in ('-H','--host'): hosts.append(args[i+1])
        i += 2
        continue
    if a.startswith(('--host=','--group=')) or a.startswith(('-H','-G')):
        if a.startswith('--host='): hosts.append(a.split('=',1)[1])
        elif a.startswith('-H'): hosts.append(a[2:].lstrip('='))
        i += 1
        continue
    if a == '--config-file': config = args[i+1]
    elif a.startswith('--config-file='): config = a.split('=',1)[1]
    kept.append(a)
    i += 1
p = pathlib.Path(config)
data = json.loads(p.read_text()) if p.exists() else {}
hosts += data.get('hosts', [])
local = [h for h in hosts if h.startswith(('unix://','fd://'))]
if not local: local = ['unix:///var/run/docker.sock']
# Retain TLS settings, runtime, storage, networking and every unrelated option.
backup = pathlib.Path('/var/lib/cks-secure-docker-backup')
backup.mkdir(mode=0o700, parents=True, exist_ok=True)
if p.exists() and not (backup/'daemon.json.original').exists():
    shutil.copy2(p, backup/'daemon.json.original')
if 'hosts' in data or 'group' in data:
    data.pop('hosts',None); data.pop('group',None)
    p.write_text(json.dumps(data,indent=2)+'\n')
for h in dict.fromkeys(local + ['tcp://0.0.0.0:2375']): kept += ['-H',h]
kept += ['--group=docker']
# systemd quoting, including expansion of percent and dollar characters.
def quote(s):
    return '"'+s.replace('\\','\\\\').replace('"','\\"').replace('%','%%').replace('$','$$')+'"'
d = pathlib.Path('/etc/systemd/system/docker.service.d')
d.mkdir(parents=True,exist_ok=True)
(d/'90-cks-secure-docker.conf').write_text('[Service]\nGroup=docker\nExecStart=\nExecStart='+ ' '.join(map(quote,kept))+'\n')
if any(h.startswith('fd://') for h in local):
    d = pathlib.Path('/etc/systemd/system/docker.socket.d')
    d.mkdir(parents=True,exist_ok=True)
    (d/'90-cks-secure-docker.conf').write_text('[Socket]\nSocketGroup=docker\n')
PY
systemctl daemon-reload
# Socket activation owns the socket's group independently of dockerd's --group.
systemctl stop docker.service
if systemctl is-active --quiet docker.socket; then systemctl restart docker.socket; fi
systemctl enable docker.service >/dev/null
systemctl start docker.service
python3 <<'PY'
import pathlib, subprocess, time, grp, os
for _ in range(60):
    pid = subprocess.check_output(['systemctl','show','docker.service','-p','MainPID','--value'],text=True).strip()
    out = subprocess.check_output(['ss','-H','-ltnp'],text=True)
    if pid != '0' and any('0.0.0.0:2375' in line and f'pid={pid},' in line for line in out.splitlines()):
        args = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().split(b'\0')
        owned = set()
        for fd in pathlib.Path(f'/proc/{pid}/fd').iterdir():
            try:
                target = os.readlink(fd)
                if target.startswith('socket:['): owned.add(target[8:-1])
            except FileNotFoundError: pass
        paths = []
        for line in pathlib.Path('/proc/net/unix').read_text().splitlines()[1:]:
            fields = line.split()
            if len(fields)>7 and fields[6] in owned and fields[3] == '00010000':
                paths.append(fields[7])
        insecure_socket = any(pathlib.Path(s).exists() and os.stat(s).st_gid == grp.getgrnam('docker').gr_gid for s in paths)
        if b'--group=docker' in args and insecure_socket and pathlib.Path(f'/proc/{pid}').stat().st_gid == grp.getgrnam('docker').gr_gid:
            break
    time.sleep(1)
else:
    raise SystemExit('Docker initial-state self-check failed; inspect docker.service logs.')
PY
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
