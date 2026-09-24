#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation on the playground controlplane; no services are changed.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
if [[ $EUID -ne 0 ]]; then
    fail 'Run as root on controlplane so socket ownership can be inspected.'
    finish
fi
for cmd in getent id ss python3; do
    if ! command -v "$cmd" >/dev/null; then
        fail "Required inspection tool is missing: $cmd"
        finish
    fi
done

if ! groups=$(id -G developer 2>/dev/null); then
    fail 'The developer user still exists and is outside the docker group.'
else
    docker_gid=$(getent group docker | cut -d: -f3) || docker_gid=''
    if [[ -z $docker_gid || " $groups " != *" $docker_gid "* ]]; then
        pass 'The developer user is not a member of the docker group.'
    else
        fail 'The developer user is still a member of the docker group.'
    fi
fi

# Inspect every live dockerd, including one started outside systemd. Actual
# listeners catch edits that have not taken effect and nonstandard API ports.
# Docker's optional metrics listener is unrelated to the daemon API.
if python3 - <<'PY'
import json
from pathlib import Path
import re
import subprocess
import sys

try:
    listeners = subprocess.check_output(['ss', '-H', '-lntp'], text=True).splitlines()
    found = False
    exposed = False
    for proc in Path('/proc').iterdir():
        if not proc.name.isdigit():
            continue
        try:
            if (proc / 'comm').read_text().strip() != 'dockerd':
                continue
            args = (proc / 'cmdline').read_bytes().decode().rstrip('\0').split('\0')
        except FileNotFoundError:
            continue
        found = True
        config = Path('/etc/docker/daemon.json')
        metrics = ''
        for i, arg in enumerate(args):
            if arg == '--config-file':
                config = Path(args[i + 1])
            elif arg.startswith('--config-file='):
                config = Path(arg.split('=', 1)[1])
            elif arg == '--metrics-addr':
                metrics = args[i + 1]
            elif arg.startswith('--metrics-addr='):
                metrics = arg.split('=', 1)[1]
        data = json.loads(config.read_text()) if config.exists() else {}
        metrics = metrics or data.get('metrics-addr', '')
        for line in listeners:
            if not re.search(r'\bpid=' + proc.name + r',', line):
                continue
            address = line.split()[3]
            # Ignore only an exact metrics endpoint, never all ports on its IP.
            if metrics and address == metrics:
                continue
            exposed = True
    if not found:
        print('Cannot verify a running Docker daemon; restore daemon operation.', file=sys.stderr)
        sys.exit(1)
    sys.exit(1 if exposed else 0)
except (OSError, ValueError, IndexError, subprocess.SubprocessError) as error:
    print(f'Unable to inspect Docker listeners: {error}', file=sys.stderr)
    sys.exit(1)
PY
then
    pass 'The running Docker daemon has no TCP API listener.'
else
    fail 'Docker TCP API access is disabled while the daemon remains running.'
fi
finish
