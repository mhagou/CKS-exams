#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. The task supplies no namespace/image.
# Prepare default/x on node01; the candidate creates the RuntimeClass and edits x.
trap 'echo "ERROR: scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for cmd in kubectl ssh; do command -v "$cmd" >/dev/null; done
k() { kubectl --request-timeout=30s "$@"; }
k get node controlplane node01 >/dev/null
[[ $(k get node node01 -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}') == containerd://* ]] || {
    echo 'This setup requires the existing worker runtime to be containerd.' >&2; exit 1;
}
# Avoid replacing an unrelated deployment with the same short name.
existing=$(k -n default get deployment x --ignore-not-found -o name)
if [[ -n $existing ]]; then
    [[ $(k -n default get deployment x -o jsonpath='{.metadata.labels.cks-exercise}') == gvisor ]] || {
        echo 'default/x already exists and is not owned by this lab.' >&2; exit 1;
    }
fi
# A pre-existing shared RuntimeClass is preserved; do not delete cluster-wide state.
if [[ -n $(k get runtimeclass not-trusted --ignore-not-found -o name) ]]; then
    echo 'An existing RuntimeClass will be preserved; that part of the exercise may already be complete.'
fi

ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 'bash -s' <<'WORKER'
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
command -v containerd >/dev/null
systemctl is-active --quiet containerd
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Inspect the running service so a custom config path is respected.
pid=$(systemctl show containerd -p MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ ]]
mapfile -d '' -t argv < "/proc/$pid/cmdline"
config=/etc/containerd/config.toml
for ((i=1; i<${#argv[@]}; i++)); do
    case ${argv[i]} in
        --config|-c) i=$((i+1)); config=${argv[i]} ;;
        --config=*) config=${argv[i]#*=} ;;
    esac
done
[[ $config == /* ]] || { echo 'Relative containerd config paths are unsupported.' >&2; exit 1; }
containerd --config "$config" config dump > "$work/effective"
# containerd emits normalized TOML; remove quote style differences for inspection.
normalize() { tr -d "\"'[:blank:]" < "$1"; }
normalize "$work/effective" > "$work/normalized"
handler=$(awk '
    /^\[/ { active=($0 ~ /^\[plugins\..*\.containerd\.runtimes\.runsc\]$/) }
    active && /^runtime_type=/ { sub(/^runtime_type=/, ""); print }
' "$work/normalized")
if [[ -n $handler && $handler != io.containerd.runsc.v1 ]]; then
    echo 'Existing worker runtime handler conflicts with this lab; configuration preserved.' >&2
    exit 1
fi

# Official checksum-verified release bundle includes the current sidecar binaries.
# https://gvisor.dev/docs/user_guide/install/
if ! command -v runsc >/dev/null || ! command -v containerd-shim-runsc-v1 >/dev/null; then
    if command -v runsc >/dev/null || command -v containerd-shim-runsc-v1 >/dev/null; then
        echo 'Incomplete existing gVisor installation; preserved to avoid mixing versions.' >&2
        exit 1
    fi
    for dep in curl bzip2; do
        if ! command -v "$dep" >/dev/null; then
            command -v apt-get >/dev/null || { echo "Missing $dep and apt-get." >&2; exit 1; }
            apt-get update -qq
            DEBIAN_FRONTEND=noninteractive apt-get install -y "$dep" ca-certificates
        fi
    done
    arch=$(uname -m)
    case $arch in x86_64|aarch64) ;; *) echo "Unsupported architecture: $arch" >&2; exit 1;; esac
    url="https://storage.googleapis.com/gvisor/releases/release/latest/$arch"
    (
        cd "$work"
        curl -fsSLO --retry 3 "$url/gvisor.tar.bz2"
        curl -fsSLO --retry 3 "$url/gvisor.tar.bz2.sha512"
        sha512sum -c gvisor.tar.bz2.sha512
        mkdir bundle
        tar -xjf gvisor.tar.bz2 -C bundle
        # Do not overwrite a partial pre-existing installation or its sidecars.
        for item in runsc containerd-shim-runsc-v1 gvisor-bin; do
            [[ ! -e /usr/local/bin/$item ]] || {
                echo "Partial installation at /usr/local/bin/$item; preserved." >&2; exit 1;
            }
        done
        cp -a bundle/. /usr/local/bin/
    )
fi
runsc --version >/dev/null

if [[ -z $handler ]]; then
    # Append only one runtime table. Preserve all other configuration and imports.
    version=1
    if [[ -f $config ]]; then
        configured_version=$(awk -F= '/^[[:space:]]*version[[:space:]]*=/ {
            sub(/#.*/, "", $2); gsub(/[[:space:]]/, "", $2); print $2; exit
        }' "$config")
        version=${configured_version:-1}
    else
        mkdir -p "$(dirname "$config")"
        printf 'version = 2\n' > "$config"
        version=2
    fi
    case $version in
        1) plugin=cri ;;
        2) plugin=io.containerd.grpc.v1.cri ;;
        3) plugin=io.containerd.cri.v1.runtime ;;
        *) echo "Unsupported containerd configuration version: $version" >&2; exit 1 ;;
    esac
    cp -a "$config" "$work/config.backup"
    # Retain a backup for the playground operator without replacing earlier backups.
    [[ -e ${config}.cks-gvisor.bak ]] || cp -a "$config" "${config}.cks-gvisor.bak"
    printf '\n[plugins."%s".containerd.runtimes.runsc]\n  runtime_type = "io.containerd.runsc.v1"\n' "$plugin" >> "$config"
    if ! containerd --config "$config" config dump >/dev/null 2>&1 || ! systemctl restart containerd; then
        cp -a "$work/config.backup" "$config"
        systemctl restart containerd || true
        echo 'Worker runtime configuration failed; original config restored.' >&2
        exit 1
    fi
fi
systemctl is-active --quiet containerd
containerd --config "$config" config dump > "$work/effective"
normalize "$work/effective" | awk '
    /^\[/ { active=($0 ~ /^\[plugins\..*\.containerd\.runtimes\.runsc\]$/) }
    active && $0 == "runtime_type=io.containerd.runsc.v1" { found=1 }
    END { exit !found }
'
WORKER

k wait --for=condition=Ready node/node01 --timeout=120s >/dev/null
# Replace only the lab-owned Deployment on reruns, resetting candidate changes.
if [[ -n $existing ]]; then
    k -n default delete deployment x --wait=true --timeout=120s >/dev/null
fi
k -n default apply -f - >/dev/null <<'MANIFEST'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: x
  labels:
    cks-exercise: gvisor
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cks-gvisor-x
  template:
    metadata:
      labels:
        app: cks-gvisor-x
    spec:
      nodeSelector:
        kubernetes.io/hostname: node01
      containers:
        - name: app
          image: busybox:1.36.1
          command: ["sh", "-c", "while true; do sleep 3600; done"]
MANIFEST
k -n default rollout status deployment/x --timeout=180s >/dev/null
[[ -z $(k -n default get deployment x -o jsonpath='{.spec.template.spec.runtimeClassName}') ]]
[[ $(k -n default get deployment x -o jsonpath='{.status.readyReplicas}') == 1 ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\nDeployment: default/x\n'
