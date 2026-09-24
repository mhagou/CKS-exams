#!/usr/bin/env bash
set -Eeuo pipefail

state=/var/lib/cks-kh77539
lab=/opt/cks-kh77539
report=/candidate/KH77539/files.txt
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed+1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed+1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
if [[ $EUID != 0 ]]; then fail 'Validation requires root to inspect the lab process.'; finish; fi
if [[ ! -s $state/pid || ! -s $state/exe-id || ! -s $state/file-names || ! -s $state/socket-link ]]; then
    fail 'Lab baseline is missing; preparation must have completed successfully.'
    finish
fi
read -r pid < "$state/pid"
read -r exe_id < "$state/exe-id"
read -r socket_link < "$state/socket-link"

# The question specifies no PID submission file. A complete report of the
# correct process's open files demonstrates identification of that process.
if [[ -f $report && -s $report && -r $report ]]; then
    pass 'The requested open-file report exists.'
    complete=true
    while IFS= read -r name; do
        # Accept bare names, lsof columns, and /proc listings, including the
        # optional " (deleted)" suffix after unlinking the executable.
        if ! grep -Fq -- "$name" "$report"; then complete=false; fi
    done < "$state/file-names"
    if ! grep -Fq -- "$socket_link" "$report" &&
       ! grep -Eq ':(389|ldap)([[:space:]]|$)' "$report"; then
        complete=false
    fi
    if [[ $complete == true ]]; then
        pass 'The report contains all open-file names for the port 389 process.'
    else
        fail 'The report is missing open-file names or the listening socket of the port 389 process.'
    fi
else
    fail 'A nonempty readable /candidate/KH77539/files.txt is required.'
    fail 'Open-file names cannot be verified without the report.'
fi

# Unlinking a running executable is sufficient: stopping the service is not an
# objective. A renamed executable still has a link and is not deleted.
deleted=false
if [[ $pid =~ ^[0-9]+$ ]] && [[ $(stat -Lc '%d:%i' "/proc/$pid/exe" 2>/dev/null || true) == "$exe_id" ]]; then
    [[ $(stat -Lc '%h' "/proc/$pid/exe" 2>/dev/null || true) == 0 ]] && deleted=true
else
    # When the original process has exited, check its recorded executable path.
    [[ ! -e $lab/service && ! -L $lab/service ]] && deleted=true
fi
if [[ $deleted == true ]]; then pass 'The service executable was deleted.'
else fail 'The service executable has not been deleted.'; fi
finish
