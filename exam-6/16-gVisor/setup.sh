#!/usr/bin/env bash
set -Eeuo pipefail
# Run only on the playground controlplane. No candidate resources are created.
# Upstream: https://gvisor.dev/docs/user_guide/install/
#           https://gvisor.dev/docs/user_guide/containerd/quick_start/
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR
[[ $EUID == 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
for command in kubectl ssh; do command -v "$command" >/dev/null; done
export KUBECONFIG=${KUBECONFIG:-/etc/kubernetes/admin.conf}
k() { kubectl --request-timeout=30s "$@"; }
for node in controlplane node01; do
    runtime=$(k get node "$node" -o jsonpath='{.status.nodeInfo.containerRuntimeVersion}')
    [[ $runtime == containerd://* ]] || { echo "Unsupported runtime on $node: $runtime" >&2; exit 1; }
done
# Do not delete possibly unrelated resources or erase an existing solution.
[[ -z $(k get runtimeclass gvisor --ignore-not-found -o name) ]] || {
    echo 'Exercise RuntimeClass already exists; use a clean exercise state.' >&2; exit 1;
}
[[ -z $(k -n default get pod secure --ignore-not-found -o name) ]] || {
    echo 'Exercise Pod already exists; use a clean exercise state.' >&2; exit 1;
}

prepare_node() {
    bash -s <<'NODE'
set -Eeuo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
for command in containerd ctr systemctl timeout; do command -v "$command" >/dev/null; done
systemctl is-active --quiet containerd
pid=$(systemctl show containerd -p MainPID --value)
mapfile -d '' -t args < "/proc/$pid/cmdline"
config=/etc/containerd/config.toml
for ((i=1; i<${#args[@]}; i++)); do
    case ${args[i]} in
        --config|-c) config=${args[i+1]} ;;
        --config=*) config=${args[i]#*=} ;;
    esac
done
[[ -f $config ]] || { echo "Missing containerd configuration: $config" >&2; exit 1; }
work=$(mktemp -d)
backup=
probe_ns="cks-gvisor-check-$$"
probe_started=false
cleanup() {
    rc=$?
    trap - EXIT
    if $probe_started; then
        ctr --address "$address" -n "$probe_ns" tasks kill -s SIGKILL probe >/dev/null 2>&1 || true
        ctr --address "$address" -n "$probe_ns" tasks rm -f probe >/dev/null 2>&1 || true
        ctr --address "$address" -n "$probe_ns" containers rm probe >/dev/null 2>&1 || true
        ctr --address "$address" -n "$probe_ns" images rm docker.io/library/busybox:1.36 >/dev/null 2>&1 || true
        ctr --address "$address" namespaces rm "$probe_ns" >/dev/null 2>&1 || true
    fi
    if (( rc != 0 )) && [[ -n $backup ]]; then
        cp -p "$backup" "$config"
        systemctl restart containerd || true
        echo 'Restored containerd configuration after preparation failure.' >&2
    fi
    rm -rf "$work"
    exit "$rc"
}
trap cleanup EXIT
containerd --config "$config" config dump > "$work/effective"
# Parse only containerd's normalized TOML output, accepting either quote style.
get_type() {
    tr "'" '"' < "$1" | awk '
      /^[[:space:]]*\[/ { in_runtime = ($0 ~ /\.runtimes\.runsc\][[:space:]]*$/) }
      in_runtime && /^[[:space:]]*runtime_type[[:space:]]*=/ {
          gsub(/"/, "", $3); print $3
      }'
}
type=$(get_type "$work/effective")
[[ -z $type || $type == io.containerd.runsc.v1 ]] || {
    echo 'Existing runtime handler conflicts with this exercise; preserving it.' >&2; exit 1;
}
if ! command -v runsc >/dev/null || ! command -v containerd-shim-runsc-v1 >/dev/null; then
    case $(uname -m) in x86_64|aarch64) arch=$(uname -m) ;; *) echo 'Unsupported architecture.' >&2; exit 1 ;; esac
    if ! command -v curl >/dev/null || ! command -v bzip2 >/dev/null; then
        command -v apt-get >/dev/null || { echo 'Install curl and bzip2 first.' >&2; exit 1; }
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates bzip2
    fi
    url="https://storage.googleapis.com/gvisor/releases/release/latest/$arch"
    ( cd "$work"
      curl -fsSLO --retry 3 "$url/gvisor.tar.bz2"
      curl -fsSLO --retry 3 "$url/gvisor.tar.bz2.sha512"
      sha512sum --check gvisor.tar.bz2.sha512 >/dev/null
      mkdir extracted
      tar -xjf gvisor.tar.bz2 -C extracted
      # Preserve a partial existing installation rather than shadowing it.
      if command -v runsc >/dev/null || command -v containerd-shim-runsc-v1 >/dev/null; then
          echo 'Incomplete existing gVisor installation; restore its matching package first.' >&2
          exit 1
      fi
      cp -a extracted/. /usr/local/bin/
    )
fi
runsc --version >/dev/null
# Ensure the daemon can discover the shim without changing its service environment.
daemon_path=$(tr '\0' '\n' < "/proc/$pid/environ" | sed -n 's/^PATH=//p')
shim=$(command -v containerd-shim-runsc-v1)
case :$daemon_path: in
    *":$(dirname "$shim"):"*) ;;
    *) echo 'The existing containerd service PATH cannot locate the runtime shim.' >&2; exit 1 ;;
esac
if [[ -z $type ]]; then
    version=$(awk '/^version[[:space:]]*=/ {print $3; exit}' "$config")
    case $version in
        2) plugin=io.containerd.grpc.v1.cri ;;
        3) plugin=io.containerd.cri.v1.runtime ;;
        *) echo 'Requires containerd configuration version 2 or 3; preserving existing configuration.' >&2; exit 1 ;;
    esac
    backup="${config}.cks-gvisor.$(date +%s).$$.bak"
    cp -p "$config" "$backup"
    cat >> "$config" <<CONFIG

# CKS exercise runtime prerequisite; existing defaults remain unchanged.
[plugins."$plugin".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
CONFIG
    containerd --config "$config" config dump > "$work/effective"
    [[ $(get_type "$work/effective") == io.containerd.runsc.v1 ]]
    systemctl restart containerd
fi
systemctl is-active --quiet containerd
address=$(tr "'" '"' < "$work/effective" | awk '
    /^\[grpc\]/ {inside=1; next}
    /^\[/ {inside=0}
    inside && /^[[:space:]]*address[[:space:]]*=/ {gsub(/"/, "", $3); print $3; exit}')
[[ -n $address ]] || { echo 'Cannot determine containerd socket.' >&2; exit 1; }
# Check plugin health and execute a disposable runtime probe, without creating
# the RuntimeClass or Kubernetes Pod which the candidate must create.
ctr --address "$address" plugins ls > "$work/plugins"
awk '$1 ~ /io.containerd.grpc.v1|io.containerd.cri.v1/ && $2 ~ /cri|runtime/ && $NF == "ok" {ok=1} END {exit !ok}' "$work/plugins"
probe_started=true
timeout 180 ctr --address "$address" -n "$probe_ns" images pull docker.io/library/busybox:1.36 > "$work/pull.log" 2>&1
timeout 60 ctr --address "$address" -n "$probe_ns" run --rm --runtime io.containerd.runsc.v1 docker.io/library/busybox:1.36 probe dmesg > "$work/probe.log" 2>&1
grep -qi 'gvisor' "$work/probe.log"
NODE
}

printf 'Preparing node prerequisites...\n'
prepare_node
# Transfer the same function without copying any supporting files to the worker.
{ declare -f prepare_node; printf '\nprepare_node\n'; } | ssh -o BatchMode=yes -o ConnectTimeout=10 node01 bash -s
k wait --for=condition=Ready node/controlplane node/node01 --timeout=180s >/dev/null
[[ $(k get node node01 -o jsonpath='{.spec.unschedulable}') != true ]]
[[ -z $(k get runtimeclass gvisor --ignore-not-found -o name) ]]
[[ -z $(k -n default get pod secure --ignore-not-found -o name) ]]
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
