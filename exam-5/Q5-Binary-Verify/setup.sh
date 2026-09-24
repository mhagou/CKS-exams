#!/usr/bin/env bash
set -Eeuo pipefail

# task.txt supplies only a title. solution.txt supplies the context: a Pod
# records SHA-256 hashes of the host kubectl and kubelet binaries. No official
# release, expected digest, or deliberately corrupted binary is specified.
trap 'printf "Setup failed at line %s.\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for tool in kubectl ssh sha256sum; do
    command -v "$tool" >/dev/null || { echo "Missing prerequisite: $tool" >&2; exit 1; }
done
k() { kubectl --request-timeout=20s "$@"; }

# These are prerequisites of the existing playground, not components to replace.
for node in controlplane node01; do
    ready=$(k get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
    [[ $ready == True ]] || { echo "Node $node is not Ready." >&2; exit 1; }
done

check_binaries='set -eu
for binary in kubectl kubelet; do
    path=$(command -v "$binary") || { echo "Missing Kubernetes binary: $binary" >&2; exit 1; }
    test -f "$path" && test -x "$path" && test -r "$path"
    printf "%s: %s\n" "$binary" "$path"
done
command -v sha256sum >/dev/null'
printf 'controlplane binary locations:\n'
bash -c "$check_binaries"
# Some playground workers omit kubectl. Reuse the installed control-plane
# client only on the same architecture, and preserve any existing worker client.
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'command -v kubectl >/dev/null'; then
    worker_arch=$(ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 uname -m)
    [[ $worker_arch == "$(uname -m)" ]] || {
        echo 'Cannot copy kubectl to a worker with a different architecture.' >&2
        exit 1
    }
    client=$(command -v kubectl)
    digest=$(sha256sum "$client")
    digest=${digest%% *}
    ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 "
        set -eu
        command -v sha256sum >/dev/null
        test ! -e /usr/local/bin/kubectl
        test ! -L /usr/local/bin/kubectl
        tmp=\$(mktemp)
        trap 'rm -f \"\$tmp\"' EXIT
        cat > \"\$tmp\"
        printf '%s  %s\\n' '$digest' \"\$tmp\" | sha256sum -c - >/dev/null
        install -m 0755 \"\$tmp\" /usr/local/bin/kubectl
    " < "$client"
fi
printf 'node01 binary locations:\n'
ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 bash -s <<< "$check_binaries"

# Preserve all existing namespace configuration and candidate resources on reruns.
if ! k get namespace binary-verify >/dev/null 2>&1; then
    k create namespace binary-verify >/dev/null
fi
[[ $(k get namespace binary-verify -o jsonpath='{.status.phase}') == Active ]]

printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
