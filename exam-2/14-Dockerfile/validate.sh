#!/usr/bin/env bash
set -Eeuo pipefail

# Source-level exercise: do not build or run candidate code, or change the host.
# Check the three security principles illustrated by task.txt, not its broken
# example solution. Image availability, named-user existence and application
# functionality require a separate build and are outside these static checks.
DOCKERFILE=${1:-/root/cks-dockerfile/Dockerfile}
if [[ ! -r $DOCKERFILE ]] || ! command -v awk >/dev/null; then
    printf '[FAIL] Dockerfile is readable and awk is available\nTotals: 0 passed, 1 failed\nRESULT: FAILED\n'
    exit 1
fi
awk '
function report(ok, description) {
    if (ok) { print "[PASS] " description; passed++ }
    else { print "[FAIL] " description; failed++ }
}
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function expand(s,   key,n) {
    for (n=0; n<20 && match(s, /\$\{[A-Za-z_][A-Za-z_0-9]*\}|\$[A-Za-z_][A-Za-z_0-9]*/); n++) {
        key=substr(s,RSTART,RLENGTH); gsub(/[${}]/,"",key)
        if (!(key in args)) break
        s=substr(s,1,RSTART-1) args[key] substr(s,RSTART+RLENGTH)
    }
    return s
}
function instruction(line,   op,body,n,a,i,base,last,tag,name,user,update,install,digest) {
    line=trim(line); if (line=="") return
    op=toupper(line); sub(/[ \t].*$/, "", op)
    body=line; sub(/^[^ \t]+[ \t]*/, "", body); body=trim(body)
    if (op=="ARG") {
        n=index(body,"=")
        if (n) { name=substr(body,1,n-1); args[name]=substr(body,n+1); gsub(/^"|"$/, "", args[name]) }
    }
    if (op=="FROM") {
        n=split(body,a,/[ \t]+/); i=1
        while (a[i] ~ /^--/ && i<=n) i++
        base=expand(a[i]); stage++; users[stage]=""
        if (tolower(base) in stages) users[stage]=users[stages[tolower(base)]]
        else if (base!="scratch") {
            # Ignore registry port; require an explicit version tag or digest.
            last=base; sub(/^.*\//,"",last)
            tag=last; sub(/^[^:]*:/,"",tag)
            if (index(base,"@")) {
                digest=base; sub(/^.*@sha256:/,"",digest)
                if (base !~ /@sha256:/ || length(digest)!=64 || digest ~ /[^0-9a-f]/) pinned=0
            } else if (last !~ /:/ || tag=="" ||
                       tag ~ /[^A-Za-z0-9_.-]/ ||
                       tolower(tag) ~ /^(latest|lts|current|stable|rolling)(-|$)/) pinned=0
            if (base ~ /\$/) pinned=0
        }
        if (tolower(a[i+1])=="as") stages[tolower(a[i+2])]=stage
    }
    if (op=="USER") {
        user=expand(body)
        # USER is not a shell command: quotes and trailing tokens are not
        # shell quoting/comments. Do not turn invalid declarations into passes.
        if (user !~ /^[A-Za-z0-9_.-]+(:[A-Za-z0-9_.-]+)?$/) user=""
        sub(/:.*/,"",user)
        users[stage]=user
    }
    if (op=="RUN") {
        body=tolower(body)
        # Ignore quoted data (e.g. echo "apt-get update"). Unwrap the
        # common explicit shell form first so its commands are still checked.
        if (sub(/^(\/bin\/)?(sh|bash)[ \t]+-c[ \t]+["\047]/,"",body))
            sub(/["\047]$/, "", body)
        gsub(/"[^\"]*"|\047[^\047]*\047/, "", body)
        update=match(body, /(^|[;&|])[ \t]*(\/usr\/bin\/)?(apt-get|apt)[ \t]+([^;&|]*[ \t])?update([ \t;&|]|$)/)
        install=match(body, /(^|[;&|])[ \t]*(\/usr\/bin\/)?(apt-get|apt)[ \t]+([^;&|]*[ \t])?install([ \t;&|]|$)/)
        # Both commands must share a layer, with update before install.
        if ((update && !install) || (install && (!update || update>=install))) packages=0
        if (body ~ /apt[ \t]+get[ \t]/) packages=0
    }
}
BEGIN { pinned=1; packages=1 }
{
    sub(/\r$/, "")
    if ($0 ~ /^[ \t]*#/) next
    line=$0
    if (line ~ /\\[ \t]*$/) { sub(/\\[ \t]*$/, "", line); logical=logical line " "; next }
    instruction(logical line); logical=""
}
END {
    if (logical!="") instruction(logical)
    report(stage>0 && pinned, "External base images use explicit version tags or digests")
    user=users[stage]
    report(stage>0 && user!="" && tolower(user)!="root" && user !~ /^0+$/ && user !~ /\$/, "Final stage declares or inherits a non-root runtime user")
    report(stage>0 && packages, "APT updates and installs share a layer in the correct order, or APT is unused")
    printf "Totals: %d passed, %d failed\n", passed, failed
    print failed ? "RESULT: FAILED" : "RESULT: SUCCESS"
    exit(failed ? 1 : 0)
}' "$DOCKERFILE"
