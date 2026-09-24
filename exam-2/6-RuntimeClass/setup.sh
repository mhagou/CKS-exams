#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground, as root on controlplane.
# Kubernetes requires lowercase DNS names: task.txt's gVisor / gVisor-pod
# are interpreted as gvisor / gvisor-pod. Neither answer resource is created.
# Runtime prerequisites follow:
# https://gvisor.dev/docs/user_guide/install/
# https://gvisor.dev/docs/user_guide/containerd/quick_start/

die() { echo "ERROR: $*" >&2; exit 1; }
[[ $EUID == 0 ]] || die 'Run as root on controlplane.'
for tool in kubectl ssh; do command -v "$tool" >/dev/null || die "Missing $tool."; done
k() { kubectl --request-timeout=30s "$@"; }
k get nodes controlplane node01 >/dev/null
for node in controlplane node01; do
    runtime=$(k get node "$node" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
    [[ $runtime == containerd://* ]] || die "$node uses $runtime; this setup supports existing containerd installations."
done
# Do not erase previous candidate work or unrelated resources on a rerun.
[[ -z $(k get runtimeclass gvisor --ignore-not-found -o name) ]] || die 'The exercise RuntimeClass already exists; remove it before resetting this exercise.'
[[ -z $(k get pod gvisor-pod -n test --ignore-not-found -o name) ]] || die 'The exercise Pod already exists; remove it before resetting this exercise.'

# The same preparation runs locally and over SSH. Preserve the daemon's active
# config and defaults; append only a missing handler. Never regenerate config.
prepare_node() (
    set -Eeuo pipefail
    fail() { echo "Runtime preparation failed on $(hostname): $*" >&2; exit 1; }
    for tool in systemctl containerd awk readlink tar sha512sum; do
        command -v "$tool" >/dev/null || fail "Missing $tool."
    done
    # Find the active service through its executable instead of assuming a unit name.
    unit=''
    while read -r candidate _; do
        pid=$(systemctl show "$candidate" -p MainPID --value)
        [[ $pid =~ ^[1-9][0-9]*$ ]] || continue
        exe=$(readlink -f "/proc/$pid/exe" 2>/dev/null) || continue
        if [[ ${exe##*/} == containerd ]]; then
            [[ -z $unit ]] || fail 'Multiple containerd services found.'
            unit=$candidate
            daemon=$exe
            daemon_pid=$pid
        fi
    done < <(systemctl list-units --type=service --state=running --no-legend --plain)
    [[ -n $unit ]] || fail 'No running containerd service found.'
    mapfile -d '' -t args < "/proc/$daemon_pid/cmdline"
    config=/etc/containerd/config.toml
    for ((i=1; i<${#args[@]}; i++)); do
        case ${args[i]} in
            --config|-c) i=$((i+1)); config=${args[i]:?Missing config argument} ;;
            --config=*) config=${args[i]#*=} ;;
        esac
    done
    [[ $config == /* ]] || fail 'Containerd uses a relative config path.'
    service_path=''
    while IFS= read -r -d '' entry; do
        case $entry in PATH=*) service_path=${entry#PATH=} ;; esac
    done < "/proc/$daemon_pid/environ"
    [[ -n $service_path ]] || fail 'Cannot determine containerd service PATH.'

    work=$(mktemp -d)
    changed=0
    existed=0
    committed=0
    cleanup_node() {
        status=$?
        trap - EXIT
        if ((changed && !committed)); then
            if ((existed)); then cp -p "$work/original.toml" "$config"; else rm -f "$config"; fi
            systemctl restart "$unit" || status=1
        fi
        rm -rf "$work"
        exit "$status"
    }
    trap cleanup_node EXIT
    "$daemon" --config "$config" config dump > "$work/effective.toml"
    # Normalize quoting in containerd's own TOML output for small AWK checks.
    tr -d "\"'" < "$work/effective.toml" > "$work/normalized"
    version=$(awk '$1 == "version" {print $3; exit}' "$work/normalized")
    case $version in
        2) section='plugins.io.containerd.grpc.v1.cri.containerd.runtimes.runsc'
           header='[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runsc]' ;;
        3) section='plugins.io.containerd.cri.v1.runtime.containerd.runtimes.runsc'
           header='[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]' ;;
        *) fail "Unsupported containerd config version: $version." ;;
    esac
    handler=$(awk -v target="[$section]" '
        /^[[:space:]]*\[/ {s=$0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)}
        s == target && $1 == "runtime_type" {print $3}
    ' "$work/normalized")
    [[ -z $handler || $handler == io.containerd.runsc.v1 ]] || fail 'Existing runsc handler conflicts; preserving its configuration.'

    # Preserve a working installation. New installs include the sidecar files
    # shipped by current upstream releases, not just the two legacy binaries.
    if ! PATH="$service_path" command -v runsc >/dev/null ||
       ! PATH="$service_path" command -v containerd-shim-runsc-v1 >/dev/null; then
        for dependency in curl bzip2; do
            if ! command -v "$dependency" >/dev/null; then
                command -v apt-get >/dev/null || fail "Install $dependency before rerunning."
                apt-get update -qq
                DEBIAN_FRONTEND=noninteractive apt-get install -y "$dependency"
            fi
        done
        arch=$(uname -m)
        case $arch in x86_64|aarch64) ;; *) fail "Unsupported architecture $arch." ;; esac
        dest=/usr/local/bin
        case :$service_path: in *:/usr/local/bin:*) ;; *) dest=${daemon%/*} ;; esac
        # Do not shadow a partially installed runtime with a different version.
        if PATH="$service_path" command -v runsc >/dev/null ||
           PATH="$service_path" command -v containerd-shim-runsc-v1 >/dev/null; then
            fail 'Incomplete existing gVisor installation; restore its matching runtime/shim pair first.'
        fi
        url="https://storage.googleapis.com/gvisor/releases/release/latest/$arch"
        curl -fsSL --retry 3 "$url/gvisor.tar.bz2" -o "$work/gvisor.tar.bz2"
        curl -fsSL --retry 3 "$url/gvisor.tar.bz2.sha512" -o "$work/gvisor.tar.bz2.sha512"
        (cd "$work"; sha512sum -c gvisor.tar.bz2.sha512 >/dev/null)
        mkdir -p "$dest"
        tar -xjf "$work/gvisor.tar.bz2" --no-same-owner -C "$dest"
    fi
    PATH="$service_path" runsc --version >/dev/null
    PATH="$service_path" command -v containerd-shim-runsc-v1 >/dev/null
    if [[ -z $handler ]]; then
        if [[ -e $config ]]; then
            existed=1
            cp -p "$config" "$work/original.toml"
        else
            mkdir -p "${config%/*}"
        fi
        changed=1
        if ((!existed)); then printf 'version = %s\n' "$version" > "$config"; fi
        printf '\n# CKS RuntimeClass exercise prerequisite\n%s\n  runtime_type = "io.containerd.runsc.v1"\n' "$header" >> "$config"
        # Parsing failure restores the original file without replacing other settings.
        "$daemon" --config "$config" config dump > /dev/null
        systemctl restart "$unit"
    fi
    systemctl is-active --quiet "$unit"
    committed=1
)

echo 'Preparing runtime prerequisites on both playground nodes...'
prepare_node
{ printf 'set -Eeuo pipefail\n'; declare -f prepare_node; printf '\nprepare_node\n'; } |
    ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01 bash -s
k wait --for=condition=Ready node/controlplane node/node01 --timeout=180s >/dev/null
if [[ -z $(k get namespace test --ignore-not-found -o name) ]]; then
    k create namespace test >/dev/null
fi
[[ $(k get namespace test -o jsonpath='{.status.phase}') == Active ]] || die 'Namespace test is not active.'

# Exercise the CRI handler on both nodes using disposable resources with unique
# names. The candidate's answer resources are never created or printed.
probe="cks-runtime-probe-$(date +%s)-$$"
ns_created=0
rc_created=0
cleanup_probe() {
    local status=$?
    trap - EXIT
    if ((ns_created)); then k delete namespace "$probe" --ignore-not-found --wait=true --timeout=120s >/dev/null || status=1; fi
    if ((rc_created)); then k delete runtimeclass "$probe" --ignore-not-found >/dev/null || status=1; fi
    exit "$status"
}
trap cleanup_probe EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
k create namespace "$probe" >/dev/null
ns_created=1
k create -f - >/dev/null <<EOF
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: $probe
handler: runsc
EOF
rc_created=1
for node in controlplane node01; do
    k create -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: check-$node
  namespace: $probe
spec:
  nodeName: $node
  runtimeClassName: $probe
  tolerations:
  - operator: Exists
  containers:
  - name: check
    image: nginx:stable
EOF
    k wait -n "$probe" --for=condition=Ready "pod/check-$node" --timeout=240s >/dev/null || die "Runtime smoke test failed on $node; inspect containerd and kubelet logs."
done
# Cleanup is part of the self-check: do not report ready until it succeeds.
k delete namespace "$probe" --wait=true --timeout=120s >/dev/null
ns_created=0
k delete runtimeclass "$probe" >/dev/null
rc_created=0
[[ -z $(k get runtimeclass gvisor --ignore-not-found -o name) ]] || die 'Unexpected exercise RuntimeClass exists.'
[[ -z $(k get pod gvisor-pod -n test --ignore-not-found -o name) ]] || die 'Unexpected exercise Pod exists.'
printf '\nName correction: use lowercase gvisor and gvisor-pod; Kubernetes rejects uppercase resource names.\n'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
