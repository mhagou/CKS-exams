#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation: never reload sysctl files or change kernel settings.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then
        echo 'RESULT: SUCCESS'
    else
        echo 'RESULT: FAILED'
        exit 1
    fi
}

if [[ $(hostname -s) != controlplane ]]; then
    fail 'Validation must run on controlplane.'
    finish
fi
if ! command -v sysctl >/dev/null; then
    fail 'Required command missing: sysctl.'
    finish
fi

if value=$(sysctl -n net.ipv4.ip_forward 2>/dev/null) && [[ $value == 0 ]]; then
    pass 'IPv4 forwarding is disabled in the live kernel.'
else
    fail 'IPv4 forwarding is disabled in the live kernel.'
fi

# Determine the installed boot loader for sysctl configuration. On systemd
# systems /etc/sysctl.conf is normally included via a sysctl.d symlink;
# systemd-sysctl does not otherwise read it. procps --system reads it last.
loader=''
if command -v systemctl >/dev/null; then
    for service in systemd-sysctl.service procps.service sysctl.service; do
        state=$(systemctl show "$service" -p LoadState --value 2>/dev/null) || continue
        [[ $state == loaded ]] || continue
        unit_state=$(systemctl is-enabled "$service" 2>/dev/null || true)
        [[ $unit_state != masked && $unit_state != disabled ]] || continue
        start=$(systemctl show "$service" -p ExecStart --value 2>/dev/null) || continue
        if [[ $start == *systemd-sysctl* ]]; then
            loader=systemd
            break
        elif [[ $start == *sysctl* && $start == *--system* ]]; then
            loader=procps
            break
        fi
    done
fi

if [[ -z $loader ]]; then
    fail 'Persistent IPv4 forwarding setting: could not identify an enabled sysctl boot loader.'
    finish
fi

# Higher-priority directories override files with the same basename. The
# selected files are then processed in lexical basename order. This also
# honors /dev/null masking symlinks, without executing any configuration.
dirs=(/etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d)
if [[ $loader == procps ]]; then
    dirs+=(/lib/sysctl.d)
fi
declare -A selected=()
shopt -s nullglob
for dir in "${dirs[@]}"; do
    for file in "$dir"/*.conf; do
        base=${file##*/}
        if [[ ! ${selected[$base]+present} ]]; then
            selected[$base]=$file
        fi
    done
done
files=()
if ((${#selected[@]})); then
    while IFS= read -r base; do
        files+=("${selected[$base]}")
    done < <(printf '%s\n' "${!selected[@]}" | LC_ALL=C sort)
fi
if [[ $loader == procps && -e /etc/sysctl.conf ]]; then
    files+=(/etc/sysctl.conf)
fi

readable=true
for file in "${files[@]}"; do
    if [[ ! -r $file ]]; then
        printf 'Cannot read configuration: %s\n' "$file" >&2
        readable=false
    fi
done

persistent=''
if [[ $readable == true ]] && ((${#files[@]})); then
    # Accept dot or slash notation, whitespace, and the optional failure-ignore
    # prefix. Comments are never treated as assignments. Last assignment wins.
    if ! persistent=$(awk '
        /^[[:space:]]*[#;]/ { next }
        {
            pos = index($0, "=")
            if (!pos) next
            key = substr($0, 1, pos - 1)
            gsub(/[[:space:]]/, "", key)
            sub(/^-/, "", key)
            gsub(/\//, ".", key)
            if (key != "net.ipv4.ip_forward") next
            value = substr($0, pos + 1)
            sub(/[[:space:]]*[#;].*$/, "", value)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            result = value
        }
        END { print result }
    ' "${files[@]}"); then
        readable=false
    fi
fi
if [[ $readable == true && $persistent =~ ^[+]?0+$ ]]; then
    pass 'Boot sysctl configuration persistently disables IPv4 forwarding.'
else
    fail 'Boot sysctl configuration persistently disables IPv4 forwarding (missing, overridden, or unreadable setting).'
fi
finish
