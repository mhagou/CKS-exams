#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground. No Kubernetes or worker changes are needed.
trap 'printf "Setup failed at line %s\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run setup as root on controlplane.' >&2; exit 1; }
export PATH="/usr/local/bin:$PATH"

missing=()
for cmd in curl jq; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if ((${#missing[@]})); then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates "${missing[@]}"
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y ca-certificates "${missing[@]}"
    else
        echo 'Install curl and jq using the playground package manager, then rerun.' >&2
        exit 1
    fi
fi
for cmd in tar sha256sum install; do
    command -v "$cmd" >/dev/null || { echo "Missing prerequisite: $cmd" >&2; exit 1; }
done
case $(uname -m) in
    x86_64) arch=amd64; trivy_arch=64bit ;;
    aarch64|arm64) arch=arm64; trivy_arch=ARM64 ;;
    *) echo 'Supported architectures: amd64 and arm64.' >&2; exit 1 ;;
esac
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
fetch() { curl --fail --silent --show-error --location --retry 3 "$1" -o "$2"; }

# Preserve existing installations. Resolve upstream release filenames at runtime.
# Optional BOM_VERSION/TRIVY_VERSION/SYFT_VERSION/GRYPE_VERSION select release tags.
install_tool() {
    local tool=$1 repo=$2 tag=$3 release asset url digest checksum_url expected actual
    if command -v "$tool" >/dev/null 2>&1; then
        printf 'Keeping existing %s installation.\n' "$tool"
        return
    fi
    mkdir -p "$work/$tool"
    release="https://api.github.com/repos/$repo/releases/latest"
    [[ -z $tag ]] || release="https://api.github.com/repos/$repo/releases/tags/$tag"
    fetch "$release" "$work/$tool/release.json"
    case $tool in
        bom) asset=$(jq -er --arg a "$arch" '
            [.assets[].name | select(. == ("bom-"+$a+"-linux") or . == ("bom-linux-"+$a))]
            | if length == 1 then .[0] else error("No unique bom binary") end' "$work/$tool/release.json") ;;
        trivy) asset=$(jq -er --arg suffix "_Linux-${trivy_arch}.tar.gz" '
            [.assets[].name | select(endswith($suffix))]
            | if length == 1 then .[0] else error("No unique Trivy archive") end' "$work/$tool/release.json") ;;
        *) asset=$(jq -er --arg suffix "_linux_${arch}.tar.gz" '
            [.assets[].name | select(endswith($suffix))]
            | if length == 1 then .[0] else error("No unique tool archive") end' "$work/$tool/release.json") ;;
    esac
    url=$(jq -er --arg n "$asset" '.assets[] | select(.name == $n) | .browser_download_url' "$work/$tool/release.json")
    fetch "$url" "$work/$tool/$asset"
    digest=$(jq -r --arg n "$asset" '.assets[] | select(.name == $n) | .digest // ""' "$work/$tool/release.json")
    checksum_url=$(jq -r '[.assets[] | select(.name | test("checksums.*\\.txt$|sha256sums(\\.txt)?$"; "i")) | .browser_download_url][0] // ""' "$work/$tool/release.json")
    expected=''
    if [[ -n $checksum_url ]]; then
        fetch "$checksum_url" "$work/$tool/checksums.txt"
        expected=$(awk -v name="$asset" '$2 == name || $2 == "*"name {print $1}' "$work/$tool/checksums.txt")
    elif [[ $digest == sha256:* ]]; then
        expected=${digest#sha256:}
    else
        # Older bom releases publish a checksum beside each binary.
        checksum_url=$(jq -r --arg n "$asset" '[.assets[] | select(.name == ($n+".sha256") or .name == ($n+".sha256sum")) | .browser_download_url][0] // ""' "$work/$tool/release.json")
        if [[ -n $checksum_url ]]; then
            fetch "$checksum_url" "$work/$tool/checksums.txt"
            read -r expected _ < "$work/$tool/checksums.txt"
        fi
    fi
    [[ $expected =~ ^[a-fA-F0-9]{64}$ ]] || { echo "No usable official checksum for $asset; refusing installation." >&2; exit 1; }
    actual=$(sha256sum "$work/$tool/$asset"); actual=${actual%% *}
    [[ ${actual,,} == ${expected,,} ]] || { echo "Checksum mismatch: $asset" >&2; exit 1; }
    if [[ $tool == bom ]]; then
        install -m 0755 "$work/$tool/$asset" "/usr/local/bin/$tool"
    else
        tar -xzf "$work/$tool/$asset" -C "$work/$tool" "$tool"
        install -m 0755 "$work/$tool/$tool" "/usr/local/bin/$tool"
    fi
}
install_tool bom kubernetes-sigs/bom "${BOM_VERSION:-}"
install_tool trivy aquasecurity/trivy "${TRIVY_VERSION:-}"
install_tool syft anchore/syft "${SYFT_VERSION:-}"
install_tool grype anchore/grype "${GRYPE_VERSION:-}"

# Check executability and required interfaces without generating candidate reports.
bom generate --help >/dev/null
trivy image --help >/dev/null
syft --help >/dev/null
grype --help >/dev/null
jq -en 'true' >/dev/null
# Prepare the vulnerability database, but do not scan any image or report.
grype db update
grype db status >/dev/null

printf '\n=================================================\n CKS LAB READY\n=================================================\n'
printf 'Scenario preparation completed successfully.\n'
printf 'Practice image: %s\n' "${LAB_IMAGE:-docker.io/library/alpine:3.20.3}"
printf 'Work in a directory of your choice; the task names sbom1.json, sbom2.json, and sbom3.json.\n'
printf 'Pass that directory as the first argument to validate.sh (default: current directory).\n'
printf 'Existing reports are preserved. Registry access is required to generate reports.\n'
