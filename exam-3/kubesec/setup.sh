#!/usr/bin/env bash
set -Eeuo pipefail

# task.txt is an installation/scan walkthrough, with no hardening objective.
# Prepare the scanner and input only; do not deploy or harden the Pod.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run setup.sh as root on controlplane.' >&2; exit 1; }
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export PATH="/usr/local/bin:$PATH"

# jq is used to validate structured scanner output and release metadata.
missing=()
command -v jq >/dev/null || missing+=(jq)
command -v curl >/dev/null || missing+=(curl)
if ((${#missing[@]})); then
    command -v apt-get >/dev/null || {
        echo "Install these prerequisites on the playground: ${missing[*]}" >&2
        exit 1
    }
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" ca-certificates
fi

tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
fetch() { curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 180 "$1" -o "$2"; }

# Keep an existing working installation. Otherwise use the task's release,
# selecting the playground architecture rather than blindly using ARM64.
if ! command -v kubesec >/dev/null || ! kubesec version >"$tmp/version" 2>&1; then
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo 'Unsupported playground architecture.' >&2; exit 1 ;;
    esac
    asset="kubesec_linux_${arch}.tar.gz"
    fetch 'https://api.github.com/repos/controlplaneio/kubesec/releases/tags/v2.14.2' "$tmp/release.json"
    archive_url=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' "$tmp/release.json")
    checksum_url=$(jq -er '[.assets[] | select(.name | test("checksums.*\\.txt$"; "i"))][0].browser_download_url // empty' "$tmp/release.json")
    fetch "$checksum_url" "$tmp/checksums.txt"
    if [[ -f "$script_dir/$asset" ]]; then
        cp -- "$script_dir/$asset" "$tmp/$asset"
    else
        fetch "$archive_url" "$tmp/$asset"
    fi
    expected=$(awk -v name="$asset" '$2 == name || $2 == "*" name {print $1}' "$tmp/checksums.txt")
    [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || { echo 'Missing or ambiguous upstream checksum.' >&2; exit 1; }
    printf '%s  %s\n' "$expected" "$tmp/$asset" | sha256sum --check --status
    tar -xzf "$tmp/$asset" -C "$tmp" kubesec
    install -m 0755 "$tmp/kubesec" /usr/local/bin/kubesec
fi

# Support copying just these scripts. Never overwrite an existing candidate file.
if [[ ! -e "$script_dir/pod.yaml" ]]; then
    cat >"$script_dir/pod.yaml" <<'YAML'
apiVersion: v1
kind: Pod
metadata:
  labels:
    run: test
  name: test
spec:
  containers:
  - image: nginx
    name: test
    resources: {}
  dnsPolicy: ClusterFirst
  restartPolicy: Always
YAML
fi

# Check prerequisites without printing scan advice or changing the input.
kubesec version >"$tmp/version" 2>&1
[[ -s "$tmp/version" && -s "$script_dir/pod.yaml" && -r "$script_dir/pod.yaml" ]]
jq -en 'true' >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
