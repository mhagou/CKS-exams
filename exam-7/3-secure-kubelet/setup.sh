#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. No worker changes are needed.
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die 'Run as root on controlplane.'
for command in kubectl systemctl; do
    command -v "$command" >/dev/null || die "Required command missing: $command"
done

# Use an explicit admin kubeconfig; do not rename or alter candidate credentials.
admin_config=${ADMIN_KUBECONFIG:-/etc/kubernetes/admin.conf}
[[ -r $admin_config ]] || die 'Set ADMIN_KUBECONFIG to a readable cluster-admin kubeconfig.'
kube=(kubectl --kubeconfig="$admin_config" --request-timeout=15s)
[[ $(hostname -s) == controlplane ]] || die 'Run this script on controlplane.'
"${kube[@]}" get node controlplane >/dev/null
systemctl is-active --quiet kubelet || die 'The existing kubelet must be running.'

# YAML parsing avoids unsafe indentation-based edits. jq also serves the validator.
if ! command -v jq >/dev/null || ! command -v python3 >/dev/null ||
   ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || die 'Install jq, python3 and the Python yaml module, then rerun.'
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq python3 python3-yaml
fi

pid=$(systemctl show kubelet --property=MainPID --value)
[[ $pid =~ ^[1-9][0-9]*$ && -r /proc/$pid/cmdline ]] || die 'Cannot inspect the running kubelet.'
mapfile -d '' -t args < "/proc/$pid/cmdline"
config=''
for ((i=1; i<${#args[@]}; i++)); do
    case ${args[i]} in
        --config=*) config=${args[i]#*=} ;;
        --config) config=${args[i+1]:-} ;;
        --anonymous-auth|--anonymous-auth=*|--authorization-mode|--authorization-mode=*)
            die 'Existing authentication/authorization command-line overrides must be removed before preparing this configuration-file lab.' ;;
    esac
done
[[ -n $config ]] || die 'The running kubelet has no --config file.'
[[ $config == /* ]] || config="/proc/$pid/cwd/$config"
config=$(readlink -f "$config")
[[ -f $config && -w $config ]] || die 'The active kubelet configuration is not writable.'

# Refuse to begin if the authenticated effective-configuration interface is unavailable.
"${kube[@]}" get --raw /api/v1/nodes/controlplane/proxy/configz |
    jq -e '.kubeletconfig | type == "object"' >/dev/null

backup=$(mktemp "${config}.cks-secure-kubelet.XXXXXX")
cp -p -- "$config" "$backup"
changed=0
rollback() {
    local status=$?
    trap - EXIT
    if (( status != 0 && changed )); then
        printf 'Preparation failed; restoring the pre-run kubelet configuration.\n' >&2
        cp -p -- "$backup" "$config"
        systemctl restart kubelet || true
    fi
    rm -f -- "$backup"
    exit "$status"
}
trap rollback EXIT
changed=1
python3 - "$config" <<'PY'
import pathlib
import sys
import yaml

path = pathlib.Path(sys.argv[1])
original = path.read_text()
data = yaml.safe_load(original)
if not isinstance(data, dict) or data.get('kind') != 'KubeletConfiguration':
    raise SystemExit('Expected an existing KubeletConfiguration document.')
targets = [(('authentication', 'anonymous', 'enabled'), True),
           (('authorization', 'mode'), 'AlwaysAllow')]

# Preserve comments and formatting when the two scalars already exist.
root = yaml.compose(original)
edits = []
for keys, value in targets:
    node = root
    for key in keys:
        if not isinstance(node, yaml.MappingNode):
            node = None
            break
        matches = [v for k, v in node.value if k.value == key]
        node = matches[0] if len(matches) == 1 else None
    if isinstance(node, yaml.ScalarNode):
        edits.append((node.start_mark.index, node.end_mark.index,
                      'true' if value is True else value))
    current = data
    for key in keys[:-1]:
        current = current.setdefault(key, {})
        if not isinstance(current, dict):
            raise SystemExit('Unexpected kubelet authentication/authorization structure.')
    current[keys[-1]] = value

if len(edits) == len(targets) and '&' not in original and '*' not in original:
    updated = original
    for start, end, value in sorted(edits, reverse=True):
        updated = updated[:start] + value + updated[end:]
    if yaml.safe_load(updated) != data:
        raise SystemExit('Configuration edit verification failed.')
else:
    # Missing fields or YAML aliases: preserve all unrelated configuration values.
    updated = yaml.safe_dump(data, sort_keys=False)
path.write_text(updated)
PY
systemctl restart kubelet

prepared=0
for ((attempt=0; attempt<30; attempt++)); do
    if systemctl is-active --quiet kubelet &&
       "${kube[@]}" get --raw /api/v1/nodes/controlplane/proxy/configz 2>/dev/null |
           jq -e '.kubeletconfig.authentication.anonymous.enabled == true and
                  .kubeletconfig.authorization.mode == "AlwaysAllow"' >/dev/null &&
       [[ $("${kube[@]}" get --raw /api/v1/nodes/controlplane/proxy/healthz 2>/dev/null) == ok ]] &&
       [[ $("${kube[@]}" get node controlplane -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; then
        prepared=1
        break
    fi
    sleep 2
done
(( prepared )) || die 'The initial scenario did not become healthy or an existing configuration override prevented preparation.'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
