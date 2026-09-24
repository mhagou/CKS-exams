#!/usr/bin/env bash
set -Eeuo pipefail

# Run later as root on the playground controlplane. This lab is local only.
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
config=/var/lib/kubelet/config.yaml
fail() { printf 'Setup failed: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || fail 'Run as root on controlplane.'
[[ $(hostname -s) == controlplane ]] || fail 'This exercise targets controlplane.'
for command in systemctl kubectl; do
    command -v "$command" >/dev/null || fail "Required command missing: $command"
done
[[ -f $config ]] || fail "Missing $config"
systemctl is-active --quiet kubelet || fail 'The existing kubelet must be running.'
kubectl --request-timeout=15s get node controlplane >/dev/null

# YAML parsing avoids fragile edits to nested authentication settings. jq is
# shared by setup's effective-state checks and the standalone validator.
packages=()
command -v curl >/dev/null || packages+=(curl)
command -v jq >/dev/null || packages+=(jq)
if ! command -v python3 >/dev/null || ! python3 -c 'import yaml' 2>/dev/null; then
    packages+=(python3 python3-yaml)
fi
if ((${#packages[@]})); then
    command -v apt-get >/dev/null || fail "Install these prerequisites and retry: ${packages[*]}"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
fi

# Do not rewrite service units or unrelated environment files. Detect command
# line overrides before touching the task's configuration file.
pid=$(systemctl show kubelet --property=MainPID --value)
python3 - "$pid" "$config" <<'PY'
import sys
args = open('/proc/' + sys.argv[1] + '/cmdline', 'rb').read().decode().split('\0')
def option(name):
    result = None
    for i, arg in enumerate(args):
        if arg.startswith(name + '='):
            result = arg.split('=', 1)[1]
        elif arg == name and i + 1 < len(args):
            result = args[i + 1]
    return result
if option('--config') != sys.argv[2]:
    sys.exit('Setup failed: kubelet is not using the configuration path in task.txt.')
for name, expected in (('--anonymous-auth', 'true'),
                       ('--authorization-mode', 'AlwaysAllow'),
                       ('--read-only-port', '10255')):
    value = option(name)
    if value is not None and value != expected:
        sys.exit('Setup failed: existing command-line security overrides conflict with this lab; no configuration was changed.')
PY

backup=$(mktemp "${config}.cks-backup.XXXXXX")
cp -p "$config" "$backup"
changed=0
cleanup() {
    status=$?
    trap - EXIT
    if ((status != 0 && changed)); then
        cp -p "$backup" "$config"
        systemctl restart kubelet || true
        printf 'Preparation failed; restored the configuration from this attempt.\n' >&2
    fi
    rm -f "$backup"
    exit "$status"
}
trap cleanup EXIT
changed=1
python3 - "$config" <<'PY'
import sys, yaml
path = sys.argv[1]
with open(path) as f:
    config = yaml.safe_load(f)
if not isinstance(config, dict):
    sys.exit('Invalid kubelet configuration')
config.setdefault('authentication', {}).setdefault('anonymous', {})['enabled'] = True
config.setdefault('authorization', {})['mode'] = 'AlwaysAllow'
config['readOnlyPort'] = 10255
with open(path, 'w') as f:
    yaml.safe_dump(config, f, sort_keys=False)
PY
systemctl restart kubelet

ready=0
for ((attempt=0; attempt<60; attempt++)); do
    if systemctl is-active --quiet kubelet &&
       effective=$(kubectl --request-timeout=5s get --raw /api/v1/nodes/controlplane/proxy/configz 2>/dev/null) &&
       jq -e '.kubeletconfig | .authentication.anonymous.enabled == true and .authorization.mode == "AlwaysAllow" and .readOnlyPort == 10255' <<<"$effective" >/dev/null &&
       curl --noproxy '*' -fsk --connect-timeout 2 --max-time 5 https://localhost:10250/pods | jq -e '.kind == "PodList"' >/dev/null &&
       curl --noproxy '*' -fs --connect-timeout 2 --max-time 5 http://localhost:10255/metrics >/dev/null &&
       [[ $(kubectl --request-timeout=5s get node controlplane -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; then
        ready=1
        break
    fi
    sleep 2
done
((ready)) || fail 'The initial scenario did not pass its runtime checks.'
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
