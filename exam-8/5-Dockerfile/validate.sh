#!/usr/bin/env bash
set -Eeuo pipefail

# This task asks for a source edit, not an image build or cluster deployment.
# Inspect instructions without executing any candidate-controlled commands.
file=/opt/course/image/api-server.Dockerfile
if [[ ! -r "$file" || ! -f "$file" ]]; then
    printf '[FAIL] Dockerfile exists and is readable\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi

awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function report(ok, description) {
    if (ok) { print "[PASS] " description; passed++ }
    else { print "[FAIL] " description; failed++ }
}
function instruction(line,    op,rest,n,a,i,src,dst) {
    line=trim(line)
    if (line == "" || line ~ /^#/) return
    op=line; sub(/[ \t].*$/, "", op); op=toupper(op)
    rest=line; sub(/^[^ \t]+[ \t]*/, "", rest); rest=trim(rest)
    if (op == "FROM") {
        from++
        n=split(rest,a,/[ \t]+/); i=1
        if (a[i] ~ /^--platform=/) i++
        base=a[i++]
        if (base !~ /^gcr\.io\/distroless\/base(:[A-Za-z0-9_.-]+)?(@sha256:[0-9a-f]+)?$/ || base ~ /:debug/) badbase=1
        if (i <= n && !(i+1 == n && toupper(a[i]) == "AS")) badbase=1
    } else if (op == "COPY") {
        copies++
        # Common COPY flags do not change which files are included.
        while (rest ~ /^--(chmod|chown|link)(=([^ \t]+))?[ \t]+/) {
            sub(/^--[^ \t]+[ \t]+/, "", rest)
        }
        if (rest ~ /^\[/) {
            if (rest !~ /^\[[ \t]*"(\.\/)?app-server"[ \t]*,[ \t]*"\/app\/server"[ \t]*\]$/) badcopy=1
        } else {
            n=split(rest,a,/[ \t]+/)
            src=a[1]; dst=a[2]
            gsub(/^"|"$/, "", src); gsub(/^"|"$/, "", dst)
            if (n != 2 || (src != "app-server" && src != "./app-server") || dst != "/app/server") badcopy=1
        }
        if (from != 1) badorder=1
    } else if (op == "USER") {
        # Numeric 65532 is the distroless nonroot account.
        user=rest
        if (from != 1) badorder=1
    } else if (op == "ENTRYPOINT") {
        entry=rest
        if (from != 1) badorder=1
    } else {
        # With only the supplied binary needed, RUN/ADD and other additions
        # are outside this edit-only task and may reintroduce unsafe content.
        extra=1
    }
}
{
    sub(/\r$/, "")
    line=$0
    if (pending == "" && trim(line) ~ /^#/) next
    if (line ~ /\\$/) {
        sub(/\\$/, "", line); pending=pending line " "; next
    }
    instruction(pending line); pending=""
}
END {
    report(NR <= 7, "No lines added beyond the original seven-line Dockerfile")
    report(from == 1 && !badbase && !badorder, "Uses the required minimal distroless base")
    report(!extra && pending == "", "No package-manager or shell installation instructions remain")
    report(copies == 1 && !badcopy, "Copies only app-server to the application entrypoint path")
    report(user ~ /^(nonroot|65532)(:(nonroot|65532))?$/, "Runs as the distroless nonroot account")
    report(entry ~ /^\[[ \t]*"\/app\/server"[ \t]*\]$/, "Uses an exec-form application ENTRYPOINT")
    printf "Totals: %d passed, %d failed\n", passed, failed
    print failed ? "RESULT: FAILED" : "RESULT: SUCCESS"
    exit(failed ? 1 : 0)
}' "$file"
