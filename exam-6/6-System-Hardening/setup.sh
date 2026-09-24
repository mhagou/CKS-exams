#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the disposable playground's controlplane.
state=/var/lib/cks-kh77539
lab=/opt/cks-kh77539
die() { printf 'Preparation failed: %s\n' "$*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'run as root on controlplane.'

missing=()
command -v python3 >/dev/null || missing+=(python3)
command -v lsof >/dev/null || missing+=(lsof)
if ((${#missing[@]})); then
    command -v apt-get >/dev/null || die 'python3 and lsof are required; no supported package manager found.'
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}"
fi

# Stop only the process from this lab, after checking its executable identity.
if [[ -f $state/pid && -f $state/exe-id ]]; then
    read -r old_pid < "$state/pid"
    read -r old_id < "$state/exe-id"
    if [[ $old_pid =~ ^[0-9]+$ ]] && [[ $(stat -Lc '%d:%i' "/proc/$old_pid/exe" 2>/dev/null || true) == "$old_id" ]]; then
        kill "$old_pid"
        for ((i=0; i<50; i++)); do
            [[ -e /proc/$old_pid/exe ]] || break
            sleep 0.1
        done
        [[ ! -e /proc/$old_pid/exe ]] || die 'previous lab process did not stop.'
    fi
fi
listeners=$(lsof -nP -iTCP:389 -sTCP:LISTEN -t 2>/dev/null || true)
[[ -z $listeners ]] || die 'TCP port 389 is occupied by an unrelated service; nothing was changed in that service.'

install -d -m 0700 "$state"
install -d -m 0755 "$lab" /candidate/KH77539
# Preserve previous candidate work when explicitly resetting the lab.
if [[ -e /candidate/KH77539/files.txt || -L /candidate/KH77539/files.txt ]]; then
    mv /candidate/KH77539/files.txt "$state/files.txt.previous.$(date +%s%N)"
fi
rm -f "$lab/service"
cp --dereference "$(command -v python3)" "$lab/service"
chmod 0755 "$lab/service"
printf 'Harmless CKS exercise data\n' > "$lab/records.dat"
printf 'Harmless CKS exercise configuration\n' > "$lab/service.conf"
rm -f "$state/ready"

# A private copy of the interpreter is the disposable executable. The system
# interpreter and existing services are never altered. No LDAP is implemented.
nohup "$lab/service" -I -u -c '
import os, signal, socket
os.chdir("/opt/cks-kh77539")
files = [open("records.dat"), open("service.conf")]
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 389))
listener.listen(8)
with open("/var/lib/cks-kh77539/ready", "w") as ready:
    ready.write("ready\n")
while True:
    signal.pause()
' </dev/null >"$lab/service.log" 2>&1 &
pid=$!
printf '%s\n' "$pid" > "$state/pid"
stat -Lc '%d:%i' "$lab/service" > "$state/exe-id"
prepared=false
cleanup() {
    if [[ $prepared != true ]]; then
        kill "$pid" 2>/dev/null || true
        printf 'Preparation failed; the lab listener was stopped.\n' >&2
    fi
}
trap cleanup EXIT
for ((i=0; i<50; i++)); do
    [[ -s $state/ready ]] && break
    kill -0 "$pid" 2>/dev/null || die 'lab listener exited.'
    sleep 0.1
done
[[ -s $state/ready ]] || die 'listener did not become ready.'
[[ $(lsof -nP -a -p "$pid" -iTCP:389 -sTCP:LISTEN -t) == "$pid" ]] || die 'listener self-check failed.'

# Keep a private baseline so validation still works if the candidate stops the
# process after collecting its files. Socket display names vary with DNS/options.
lsof -nP -p "$pid" -Fn > "$state/open-files.raw"
sed -n 's/^n\(\/.*\)$/\1/p' "$state/open-files.raw" | sort -u > "$state/file-names"
: > "$state/socket-link"
# Discover the socket descriptor rather than relying on Python's FD allocation.
for fd in /proc/"$pid"/fd/*; do
    target=$(readlink "$fd")
    if [[ $target == socket:* ]]; then printf '%s\n' "$target" > "$state/socket-link"; fi
done
[[ -s $state/file-names && -s $state/socket-link && -x $lab/service ]] || die 'baseline self-check failed.'
grep -Fxq "$lab/records.dat" "$state/file-names" || die 'open-file self-check failed.'
prepared=true
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
