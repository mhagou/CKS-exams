#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. No Kubernetes changes are needed.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run setup.sh as root on controlplane.' >&2; exit 1; }
export PATH="/usr/local/bin:$PATH"
missing=()
for command in curl jq; do
    command -v "$command" >/dev/null || missing+=("$command")
done
if ((${#missing[@]})); then
    command -v apt-get >/dev/null || {
        echo "Install these prerequisites and rerun: ${missing[*]}" >&2; exit 1;
    }
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" ca-certificates
fi
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fetch() { curl --fail --silent --show-error --location --retry 3 --connect-timeout 20 --max-time 180 "$@"; }

if command -v trivy >/dev/null && trivy --version >/dev/null 2>&1 &&
    trivy image --help | grep -q spdx; then
    scanner=trivy
elif command -v syft >/dev/null && syft version >/dev/null 2>&1 &&
    syft --help | grep -q spdx; then
    scanner=syft
else
    # Official, pinned release; verify its published checksum before installation.
    # https://oss.anchore.com/docs/installation/verification/
    version=1.23.1
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) echo 'Unsupported architecture for automatic Syft installation.' >&2; exit 1 ;;
    esac
    archive="syft_${version}_linux_${arch}.tar.gz"
    base="https://github.com/anchore/syft/releases/download/v${version}"
    fetch "$base/$archive" -o "$work/$archive"
    fetch "$base/syft_${version}_checksums.txt" -o "$work/checksums.txt"
    awk -v file="$archive" '$2 == file { print }' "$work/checksums.txt" > "$work/selected.sha256"
    [[ $(wc -l < "$work/selected.sha256") -eq 1 ]]
    (cd "$work" && sha256sum --check selected.sha256)
    tar -xzf "$work/$archive" -C "$work" syft
    # Preserve any pre-existing nonworking installation instead of overwriting it.
    if [[ -e /usr/local/bin/syft || -L /usr/local/bin/syft ]]; then
        backup=$(mktemp -d /usr/local/bin/syft.backup.XXXXXX)
        mv /usr/local/bin/syft "$backup/syft"
    fi
    install -m 0755 "$work/syft" /usr/local/bin/syft
    scanner=syft
fi

# Check registry access and the target tag without generating any SBOM.
fetch 'https://auth.docker.io/token?service=registry.docker.io&scope=repository:library/nginx:pull' -o "$work/auth.json"
token=$(jq -er '.token // .access_token' "$work/auth.json")
fetch -H "Authorization: Bearer $token" \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    'https://registry-1.docker.io/v2/library/nginx/manifests/1.19' -o "$work/manifest.json"
jq -e '.schemaVersion == 2 and ((.manifests // .layers) | length > 0)' "$work/manifest.json" >/dev/null
mkdir -p /opt
[[ -w /opt ]]
# A rerun resets only this exercise output, preserving prior work in a backup.
if [[ -e /opt/sbom.spdx || -L /opt/sbom.spdx ]]; then
    [[ ! -d /opt/sbom.spdx ]] || { echo '/opt/sbom.spdx is a directory; cannot reset it.' >&2; exit 1; }
    backup=$(mktemp -d /opt/sbom-backup.XXXXXX)
    mv /opt/sbom.spdx "$backup/sbom.spdx"
    printf 'Previous exercise output preserved in %s\n' "$backup"
fi
if [[ $scanner == trivy ]]; then
    trivy --version >/dev/null
else
    syft version >/dev/null
fi
[[ ! -e /opt/sbom.spdx && ! -L /opt/sbom.spdx ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
