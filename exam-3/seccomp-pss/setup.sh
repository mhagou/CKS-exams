#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. Re-running preserves candidate work.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl ssh; do
    command -v "$tool" >/dev/null || { echo "Required playground tool missing: $tool" >&2; exit 1; }
done
kubectl --request-timeout=30s get node controlplane node01 >/dev/null
kubectl --request-timeout=30s wait --for=condition=Ready node/node01 --timeout=120s >/dev/null

# Preserve unrelated profiles and refuse to overwrite a different existing file.
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -se' <<'REMOTE'
set -Eeuo pipefail
for tool in mktemp cmp install; do
    command -v "$tool" >/dev/null || { echo "Missing worker tool: $tool" >&2; exit 1; }
done
profile=/var/lib/kubelet/seccomp/profiles/audit.json
staged=$(mktemp)
trap 'rm -f "$staged"' EXIT
cat >"$staged" <<'PROFILE'
{
    "defaultAction": "SCMP_ACT_ERRNO",
    "architectures": [
        "SCMP_ARCH_X86_64",
        "SCMP_ARCH_X86",
        "SCMP_ARCH_X32"
    ],
    "syscalls": [
        {
            "names": [
                "accept4",
                "epoll_wait",
                "pselect6",
                "futex",
                "madvise",
                "epoll_ctl",
                "getsockname",
                "setsockopt",
                "vfork",
                "mmap",
                "read",
                "write",
                "close",
                "arch_prctl",
                "sched_getaffinity",
                "munmap",
                "brk",
                "rt_sigaction",
                "rt_sigprocmask",
                "sigaltstack",
                "gettid",
                "clone",
                "bind",
                "socket",
                "openat",
                "execve",
                "set_tid_address",
                "set_robust_list",
                "prlimit64",
                "pread64",
                "getrandom",
                "pipe2",
                "exit_group",
                "select",
                "getpid",
                "fcntl"
            ],
            "action": "SCMP_ACT_ALLOW"
        }
    ]
}
PROFILE
if [[ -L $profile || ( -e $profile && ! -f $profile ) ]]; then
    echo 'The lab profile path is not a regular file; leaving it untouched.' >&2
    exit 1
fi
if [[ -f $profile ]] && ! cmp -s "$staged" "$profile"; then
    echo 'A different audit.json already exists on node01; leaving it untouched.' >&2
    exit 1
fi
install -d -m 0755 /var/lib/kubelet/seccomp/profiles
if [[ ! -f $profile ]]; then
    install -m 0644 "$staged" "$profile"
fi
# Self-check content and readability without running a workload.
cmp -s "$staged" "$profile"
[[ -r $profile && -s $profile ]]
REMOTE

# The namespace and its admission policy are candidate objectives. Leave them alone.
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
