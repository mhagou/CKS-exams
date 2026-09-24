#!/usr/bin/env bash
set -Eeuo pipefail

# This is deliberately a syntax-practice lab: task.txt requests a mock file,
# not a usable image export. Do not generate an SBOM during preparation.
trap 'printf "[ERROR] Preparation failed at line %s.\n" "$LINENO" >&2' ERR
export PATH="/usr/local/bin:$PATH"
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required.' >&2; exit 1; }
k=(kubectl --request-timeout=30s --namespace=default)
"${k[@]}" get node controlplane >/dev/null

if ! command -v bom >/dev/null; then
    # jq is used to select the architecture-specific upstream asset and its
    # official SHA-256 digest without relying on release-page formatting.
    missing=()
    command -v curl >/dev/null || missing+=(curl)
    command -v jq >/dev/null || missing+=(jq)
    if ((${#missing[@]})); then
        command -v apt-get >/dev/null || {
            echo 'Install curl and jq, then rerun setup.' >&2; exit 1;
        }
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${missing[@]}" ca-certificates
    fi
    case "$(uname -m)" in
        x86_64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l) arch=arm ;;
        *) echo 'Unsupported architecture for automatic bom installation.' >&2; exit 1 ;;
    esac
    tmp=$(mktemp -d)
    trap 'rm -rf -- "$tmp"' EXIT
    version=v0.7.1
    asset="bom-${arch}-linux"
    curl -fsSL --retry 3 "https://api.github.com/repos/kubernetes-sigs/bom/releases/tags/$version" -o "$tmp/release.json"
    digest=$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .digest | select(type == "string")' "$tmp/release.json")
    [[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || {
        echo 'Official binary checksum unavailable; refusing unverified installation.' >&2; exit 1;
    }
    curl -fsSL --retry 3 "https://github.com/kubernetes-sigs/bom/releases/download/$version/$asset" -o "$tmp/bom"
    printf '%s  %s\n' "${digest#sha256:}" "$tmp/bom" | sha256sum --check --status
    install -m 0755 "$tmp/bom" /usr/local/bin/bom
fi
help=$(bom generate --help)
for option in --image-archive --format --output; do
    [[ $help == *"$option"* ]] || { echo 'Installed bom lacks required functionality.' >&2; exit 1; }
done

# Preserve an existing matching pod; do not delete a potentially unrelated pod.
existing=$("${k[@]}" get pod kiwi --ignore-not-found -o name)
if [[ -z $existing ]]; then
    "${k[@]}" run kiwi --image=nginx:1.21.6
else
    images=$("${k[@]}" get pod kiwi -o jsonpath='{range .spec.containers[*]}{.image}{"\n"}{end}')
    if ! grep -Eq '^(docker.io/(library/)?)?nginx:1\.21\.6$' <<< "$images"; then
        echo 'Existing default/kiwi has a different image; refusing to overwrite it.' >&2
        exit 1
    fi
fi

archive=/root/image-archive/nginx_1.21.6.tar
mkdir -p /root/image-archive
# Like touch in task.txt, do not truncate existing candidate data on a rerun.
if [[ ! -e $archive && ! -L $archive ]]; then
    touch "$archive"
fi
[[ -f $archive && -r $archive ]] || { echo 'Archive placeholder is not a readable file.' >&2; exit 1; }
"${k[@]}" wait --for=condition=Ready pod/kiwi --timeout=180s
[[ $("${k[@]}" get pod kiwi -o jsonpath='{.status.phase}') == Running ]]
bom generate --help >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
