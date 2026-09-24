#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Run only on the playground controlplane. No system services are changed.
lab=/var/lib/cks-kh77539
binary=$lab/listener
fail() { echo "Preparation failed: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || fail 'run as root on controlplane'

missing=()
command -v python3 >/dev/null || missing+=(python3)
command -v lsof >/dev/null || missing+=(lsof)
command -v ss >/dev/null || missing+=(iproute2)
if ((${#missing[@]})); then
    command -v apt-get >/dev/null || fail "install required tools: ${missing[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi

# Refuse to reuse an unrelated directory or stop an unrelated process.
if [[ -e $lab ]]; then
    [[ -f $lab/owned-by-this-lab ]] || fail "unrecognized directory: $lab"
else
    install -d -m 700 "$lab"
    touch "$lab/owned-by-this-lab"
fi
if [[ -f $lab/pid ]]; then
    read -r oldpid < "$lab/pid"
    if [[ $oldpid =~ ^[0-9]+$ && -d /proc/$oldpid ]]; then
        oldexe=$(readlink "/proc/$oldpid/exe" || true)
        if [[ $oldexe == "$binary" || $oldexe == "$binary (deleted)" ]]; then
            kill "$oldpid"
            for _ in {1..50}; do
                [[ ! -e /proc/$oldpid/exe ]] && break
                sleep 0.1
            done
            [[ ! -e /proc/$oldpid/exe ]] || fail 'previous lab process did not stop'
        fi
    fi
fi
[[ -z $(ss -H -ltn 'sport = :389') ]] || fail 'TCP port 389 is already in use; existing listener was preserved'
[[ -z $(ss -H -lun 'sport = :389') ]] || fail 'UDP port 389 is already in use; existing listener was preserved'

# This is a private copy, never the system interpreter or a system daemon.
rm -f -- "$binary"
cp -- "$(readlink -f "$(command -v python3)")" "$binary"
chmod 700 "$binary"
cat > "$lab/listener.py" <<'PY'
import os
import signal
import socket

os.chdir('/var/lib/cks-kh77539')
data = open('service.data', 'rb')
listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(('127.0.0.1', 389))
listener.listen(8)
while True:
    signal.pause()
PY
printf 'Harmless CKS exercise data.\n' > "$lab/service.data"
install -d -m 755 /candidate/KH77539
# Preserve any earlier candidate submission while resetting this exercise.
if [[ -e /candidate/KH77539/files.txt || -L /candidate/KH77539/files.txt ]]; then
    mv -- /candidate/KH77539/files.txt "$lab/files.previous.$(date +%s%N)"
fi
nohup "$binary" "$lab/listener.py" </dev/null >/dev/null 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$lab/pid"
ready=false
for _ in {1..50}; do
    if ss -H -ltnp 'sport = :389' | grep -Fq "pid=$pid,"; then
        ready=true
        break
    fi
    kill -0 "$pid" 2>/dev/null || fail 'lab listener exited'
    sleep 0.1
done
[[ $ready == true ]] || fail 'lab listener did not become ready'
[[ $(readlink "/proc/$pid/exe") == "$binary" ]] || fail 'unexpected lab executable'

# Capture the stable initial open-file names, including cwd, executable,
# mappings, descriptors and socket. Keep both common lsof display modes.
lsof -nP -a -p "$pid" -Fn > "$lab/open-files.numeric.raw"
lsof -a -p "$pid" -Fn > "$lab/open-files.named.raw"
for mode in numeric named; do
    sed -n 's/^n//p' "$lab/open-files.$mode.raw" | sort -u > "$lab/open-files.$mode"
    [[ -s $lab/open-files.$mode ]] || fail 'could not record initial open files'
    grep -Fxq "$binary" "$lab/open-files.$mode" || fail 'executable missing from initial open files'
    grep -Fxq "$lab/service.data" "$lab/open-files.$mode" || fail 'data file missing from initial open files'
done
[[ -x $binary && ! -e /candidate/KH77539/files.txt ]] || fail 'initial state self-check failed'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
