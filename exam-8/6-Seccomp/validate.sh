#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation; execute later on controlplane with cluster-admin access.
# The question's SNMP_ACT_ERRNO spelling is a typo: libseccomp uses SCMP_ACT_ERRNO.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then
        echo 'RESULT: SUCCESS'
        exit 0
    fi
    echo 'RESULT: FAILED'
    exit 1
}
for tool in kubectl jq; do
    if ! command -v "$tool" >/dev/null; then
        fail "Required validation tool is available: $tool"
        finish
    fi
done
k() { kubectl --request-timeout=20s "$@"; }
if ! pod=$(k -n secure-runtime get pod secure-app -o json); then
    fail 'secure-runtime/secure-app exists and is accessible'
    finish
fi
pass 'secure-runtime/secure-app exists'
node=$(jq -r '.spec.nodeName // empty' <<<"$pod")
profile_path=/var/lib/kubelet/seccomp/profiles/block-debug.json
profile=''
case "$node" in
    controlplane) profile=$(cat "$profile_path" 2>/dev/null) || true ;;
    node01)
        # If the candidate reschedules the pod, inspect its actual node.
        profile=$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 \
            'cat /var/lib/kubelet/seccomp/profiles/block-debug.json') || true
        ;;
esac
if [[ -n "$profile" ]] && jq -e 'type == "object"' <<<"$profile" >/dev/null 2>&1; then
    pass "Valid JSON profile exists at $profile_path on the pod's node"
else
    fail "Valid JSON profile exists at $profile_path on the pod's node"
fi

# Accept combined or separate rules, different ordering, and explicit ALLOW
# entries. Blocking must be unconditional and return a nonzero errno.
if [[ -n "$profile" ]] && jq -e '
    . as $p |
    .defaultAction == "SCMP_ACT_ALLOW" and
    (.syscalls | type == "array") and
    all(.syscalls[];
      (.names | type == "array") and
      (if .action == "SCMP_ACT_ALLOW" then
         all(.names[]; . != "ptrace" and . != "process_vm_readv")
       else
         .action == "SCMP_ACT_ERRNO" and
         ((.errnoRet // 1) | type == "number" and . > 0 and . <= 4095) and
         all(.names[]; . == "ptrace" or . == "process_vm_readv")
       end)) and
    all(["ptrace", "process_vm_readv"][]; . as $name |
      any($p.syscalls[];
        .action == "SCMP_ACT_ERRNO" and
        ((.args // []) | length == 0) and
        (.includes // {} | length == 0) and
        (.excludes // {} | length == 0) and
        any(.names[]; . == $name)))
' <<<"$profile" >/dev/null 2>&1; then
    pass 'Profile blocks ptrace and process_vm_readv with ERRNO and allows all other syscalls'
else
    fail 'Profile blocks ptrace and process_vm_readv with ERRNO and allows all other syscalls'
fi

if jq -e '
    .spec as $s |
    all(($s.containers + ($s.initContainers // []) + ($s.ephemeralContainers // []))[];
      (.securityContext.privileged // false) == false and
      ((.securityContext.seccompProfile // $s.securityContext.seccompProfile) |
        .type == "Localhost" and .localhostProfile == "profiles/block-debug.json"))
' <<<"$pod" >/dev/null; then
    pass 'All pod containers use the requested Localhost profile without privileged bypass'
else
    fail 'All pod containers use the requested Localhost profile without privileged bypass'
fi

if jq -e '.status.phase == "Running" and
    any(.status.conditions[]?; .type == "Ready" and .status == "True") and
    (.metadata.deletionTimestamp == null)' <<<"$pod" >/dev/null; then
    pass 'Pod is Running and Ready'
else
    fail 'Pod is Running and Ready'
fi
while IFS= read -r container; do
    if k -n secure-runtime exec secure-app -c "$container" -- sh -c \
        'awk '\''$1 == "Seccomp:" {found=1; if ($2 != 2) exit 1} END {if (!found) exit 1}'\'' /proc/1/status'; then
        pass "Seccomp filtering is active for container $container"
    else
        fail "Seccomp filtering is active for container $container"
    fi
done < <(jq -r '.spec.containers[].name' <<<"$pod")

# Check the existing application's HTTP service without assuming its container name.
http_ok=false
while IFS= read -r container; do
    if k -n secure-runtime exec secure-app -c "$container" -- sh -c \
        'if command -v wget >/dev/null; then wget -q -O /dev/null -T 5 http://127.0.0.1:80/; else curl -fsS --max-time 5 -o /dev/null http://127.0.0.1:80/; fi' \
        >/dev/null 2>&1; then
        http_ok=true
        break
    fi
done < <(jq -r '.spec.containers[].name' <<<"$pod")
if "$http_ok"; then
    pass 'Application responds successfully to HTTP on port 80'
else
    fail 'Application responds successfully to HTTP on port 80'
fi
finish
