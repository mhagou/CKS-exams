#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C

# Read-only validation; the listener may remain alive or be stopped.
lab=/var/lib/cks-kh77539
binary=$lab/listener
submission=/candidate/KH77539/files.txt
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0;
    else echo 'RESULT: FAILED'; exit 1; fi
}
if [[ $EUID != 0 ]]; then
    fail 'Run validation as root on controlplane'
    finish
fi
if [[ ! -f $lab/owned-by-this-lab || ! -s $lab/open-files.numeric || ! -s $lab/open-files.named ]]; then
    fail 'Initial scenario records are available (run setup before attempting the task)'
    finish
fi

# Accept a names-only list, lsof -Fn output, or a complete lsof table.
# Ignore ordering, duplicates, blank lines and lsof's deletion annotation.
normalize() {
    awk '
        { sub(/\r$/, "") }
        /^COMMAND[[:space:]]/ || /^NAME$/ { next }
        /^n/ { sub(/^n/, "") }
        NF >= 9 && $2 ~ /^[0-9]+$/ { print $9; next }
        NF { print $1 }
    ' | sort -u
}
if [[ -f $submission && -s $submission && -r $submission ]]; then
    pass 'The requested open-file report exists at /candidate/KH77539/files.txt'
    actual=$(normalize < "$submission")
    complete=false
    for mode in numeric named; do
        expected=$(normalize < "$lab/open-files.$mode")
        missing=$(comm -23 <(printf '%s\n' "$expected") <(printf '%s\n' "$actual"))
        if [[ -z $missing ]]; then complete=true; break; fi
    done
    if [[ $complete == true ]]; then
        pass 'The report includes all initial open-file names of the port 389 process'
    else
        fail 'The report is missing open-file names of the port 389 process'
    fi
else
    fail 'The requested open-file report exists and is nonempty at /candidate/KH77539/files.txt'
    fail 'The report includes all initial open-file names of the port 389 process'
fi

# Removing an executing binary need not terminate its process. If it still
# exists, /proc distinguishes unlinking from merely renaming the executable.
deleted=true
[[ ! -e $binary && ! -L $binary ]] || deleted=false
if [[ -r $lab/pid ]]; then
    read -r pid < "$lab/pid"
    if [[ $pid =~ ^[0-9]+$ && -e /proc/$pid/exe ]]; then
        exe=$(readlink "/proc/$pid/exe" || true)
        # Only attribute this PID to the lab when its command line matches.
        if tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fxq "$lab/listener.py"; then
            [[ $exe == *' (deleted)' ]] || deleted=false
        fi
    fi
fi
if [[ $deleted == true ]]; then
    pass 'The executable backing the lab listener has been deleted'
else
    fail 'The executable backing the lab listener has been deleted'
fi
finish
