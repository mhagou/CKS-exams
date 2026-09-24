#!/usr/bin/env bash
set -Eeuo pipefail
if [[ $EUID -ne 0 ]] || ! command -v python3 >/dev/null || ! command -v ss >/dev/null; then
    echo '[FAIL] Validation requires root, Python 3 and ss on controlplane.'
    echo 'Totals: 0 passed, 1 failed'
    echo 'RESULT: FAILED'
    exit 1
fi
# Read-only: no reload, restart, configuration changes or test containers.
python3 <<'PY'
import grp, ipaddress, json, os, pathlib, re, shlex, socket, subprocess
passed = failed = 0

def report(ok, description):
    global passed, failed
    print(('[PASS] ' if ok else '[FAIL] ') + description)
    passed += bool(ok); failed += not ok

def run(*args):
    return subprocess.check_output(args,text=True,stderr=subprocess.DEVNULL).strip()

def prop(unit, key):
    return run('systemctl','show',unit,'--value','-p',key)

def options(args):
    result = {}
    i = 1
    while i < len(args):
        a = args[i]
        names = {'-H':'hosts','--host':'hosts','-G':'group','--group':'group','--config-file':'config'}
        if a in names:
            i += 1; result.setdefault(names[a],[]).append(args[i])
        elif '=' in a and a.split('=',1)[0] in names:
            k,v = a.split('=',1); result.setdefault(names[k],[]).append(v)
        elif a.startswith(('-H','-G')) and len(a)>2:
            result.setdefault(names[a[:2]],[]).append(a[2:])
        i += 1
    return result

def root_group(value):
    return str(value) == '0' or grp.getgrnam(str(value)).gr_gid == 0

def local_tcp(address):
    host = address.rsplit(':',1)[0].strip('[]').split('%')[0]
    try: return ipaddress.ip_address(host).is_loopback
    except ValueError: return host.lower() == 'localhost'

try:
    pid = int(prop('docker.service','MainPID'))
    active = prop('docker.service','ActiveState') == 'active' and pid > 0
    report(active, 'Docker daemon is running')
    if not active: raise RuntimeError('Docker is unavailable for the remaining checks.')
    args = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().decode().rstrip('\0').split('\0')
    if pathlib.Path(args[0]).name != 'dockerd': raise RuntimeError('Cannot identify the dockerd process.')
    status = pathlib.Path(f'/proc/{pid}/status').read_text()
    gids = re.search(r'^Gid:\s+(.*)$', status,re.M).group(1).split()
    report(all(g == '0' for g in gids), 'Docker daemon runs with the root group')

    # Identify every Unix listener actually held by this daemon, including fd://.
    inodes = set()
    for fd in pathlib.Path(f'/proc/{pid}/fd').iterdir():
        try:
            target = os.readlink(fd)
            if target.startswith('socket:['): inodes.add(target[8:-1])
        except FileNotFoundError: pass
    sockets = []
    for line in pathlib.Path('/proc/net/unix').read_text().splitlines()[1:]:
        fields = line.split()
        if len(fields)>7 and fields[6] in inodes and fields[3] == '00010000':
            sockets.append(fields[7])
    report(bool(sockets) and all(pathlib.Path(s).exists() and os.stat(s).st_gid == 0 for s in sockets),
           'Docker Unix API sockets belong to the root group')
    responsive = False
    for path in sockets:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(5)
                client.connect(path)
                client.sendall(b'GET /_ping HTTP/1.0\r\nHost: localhost\r\n\r\n')
                response = client.recv(4096)
                responsive |= b' 200 ' in response.split(b'\r\n',1)[0]
        except OSError: pass
    report(responsive, 'Docker API responds on a local Unix socket')
    listeners = run('ss','-H','-ltnp').splitlines()
    external = [line for line in listeners if f'pid={pid},' in line and not local_tcp(line.split()[3])]
    report(not external, 'Docker has no externally bound TCP listeners')

    # systemctl show is the effective merged unit. Require it to match files on
    # disk, then evaluate the next invocation together with its JSON config.
    start = prop('docker.service','ExecStart')
    match = re.search(r'argv\[\]=(.*?) ;',start)
    if not match: raise RuntimeError('Cannot read persistent Docker ExecStart.')
    future_args = shlex.split(match.group(1))
    opt = options(future_args)
    config = pathlib.Path(opt.get('config',['/etc/docker/daemon.json'])[-1])
    data = json.loads(config.read_text()) if config.exists() else {}
    conflict = any(k in opt and k in data for k in ('hosts','group'))
    hosts = opt.get('hosts',data.get('hosts',['unix:///var/run/docker.sock']))
    group = opt.get('group',[data.get('group','docker')])[-1]
    persistent_group = True
    persistent_hosts = True
    for h in hosts:
        if h.startswith('unix://'): persistent_group &= root_group(group)
        elif h.startswith('tcp://'): persistent_hosts &= local_tcp(h[6:])
        elif h.startswith('fd://'):
            persistent_group &= root_group(prop('docker.socket','SocketGroup') or 'root')
            persistent_hosts &= prop('docker.socket','NeedDaemonReload') == 'no'
            listen = prop('docker.socket','Listen')
            for endpoint in re.findall(r'(\S+) \(Stream\)',listen):
                if not endpoint.startswith('/'):
                    persistent_hosts &= local_tcp(endpoint)
            if not listen: persistent_hosts = False
        else: persistent_hosts = False
    service_group = prop('docker.service','Group') or 'root'
    persistent = (not conflict and bool(hosts) and persistent_group and persistent_hosts
                  and root_group(service_group)
                  and prop('docker.service','NeedDaemonReload') == 'no'
                  and prop('docker.service','UnitFileState') in ('enabled','enabled-runtime','static'))
    # Runtime-only enablement does not survive a reboot.
    persistent &= prop('docker.service','UnitFileState') != 'enabled-runtime'
    report(persistent, 'Root-group and listener configuration persist across restarts')
except Exception as exc:
    report(False, f'Validation could not complete: {exc}')
print(f'Totals: {passed} passed, {failed} failed')
print('RESULT: SUCCESS' if failed == 0 else 'RESULT: FAILED')
raise SystemExit(0 if failed == 0 else 1)
PY
