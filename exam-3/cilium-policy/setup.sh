#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground. Installation/configuration of Cilium and creation
# of the application and policies are candidate objectives, not setup actions.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
kubectl --request-timeout=20s get nodes controlplane node01 >/dev/null
[[ $(kubectl get nodes -o name | wc -l) -eq 2 ]] || {
    echo 'This exercise requires exactly controlplane and node01.' >&2; exit 1;
}

# jq is used for structured inspection of live endpoint and workload state.
missing=()
command -v curl >/dev/null || missing+=(curl)
command -v jq >/dev/null || missing+=(jq)
if ((${#missing[@]})); then
    if command -v apt-get >/dev/null; then
        apt-get update -qq
        apt-get install -y "${missing[@]}" ca-certificates
    elif command -v dnf >/dev/null; then
        dnf install -y "${missing[@]}" ca-certificates
    else
        echo "Install required tools: ${missing[*]}" >&2
        exit 1
    fi
fi

# Install only the client, never the CNI. Preserve an existing CLI installation.
if ! command -v cilium >/dev/null; then
    case $(uname -m) in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo 'Unsupported architecture for the Cilium CLI.' >&2; exit 1 ;;
    esac
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    version=$(curl -fsSL --retry 3 https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
    archive="cilium-linux-${arch}.tar.gz"
    base="https://github.com/cilium/cilium-cli/releases/download/$version"
    curl -fsSL --retry 3 "$base/$archive" -o "$work/$archive"
    curl -fsSL --retry 3 "$base/$archive.sha256sum" -o "$work/$archive.sha256sum"
    (cd "$work" && sha256sum --check "$archive.sha256sum")
    tar -xzf "$work/$archive" -C "$work" cilium
    install -m 0755 "$work/cilium" /usr/local/bin/cilium
fi

# A missing CNI can legitimately leave nodes NotReady before the exercise.
# Never uninstall another CNI or disable existing encryption to reset this lab.
kubectl --request-timeout=20s get namespace default >/dev/null
kubectl --request-timeout=20s get nodes controlplane node01 >/dev/null
cilium version --client >/dev/null
jq --version >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Use namespace default (or set LAB_NAMESPACE when validating).\nExisting cluster networking and exercise resources were preserved.\n'
