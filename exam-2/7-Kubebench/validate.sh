#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation, run from controlplane with an administrative kubeconfig.
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
SSH=(ssh -o BatchMode=yes -o ConnectTimeout=10 root@node01)
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'
    exit 1
}
for tool in kubectl ssh jq; do
    if ! command -v "$tool" >/dev/null; then
        fail "Required validation tool is missing: $tool"
    fi
done
(( failed == 0 )) || finish

# YAML parsing accepts reordered keys, quotes, comments and flow-style YAML.
# The task explicitly requires changes in this file as well as an effective fix.
if saved=$("${SSH[@]}" python3 - <<'PY'
import json, pathlib, yaml
config = yaml.safe_load(pathlib.Path('/var/lib/kubelet/config.yaml').read_text())
auth = config.get('authorization') or {}
print(json.dumps({'authorization': auth.get('mode'),
                  'protectKernelDefaults': config.get('protectKernelDefaults')}))
PY
); then
    if jq -e '.authorization == "Webhook"' <<<"$saved" >/dev/null; then
        pass 'Worker configuration enables webhook authorization.'
    else
        fail 'Worker configuration must enable webhook authorization.'
    fi
    if jq -e '.protectKernelDefaults == true' <<<"$saved" >/dev/null; then
        pass 'Worker configuration protects kernel defaults.'
    else
        fail 'Worker configuration must protect kernel defaults.'
    fi
else
    fail 'Could not read or parse /var/lib/kubelet/config.yaml on node01.'
fi

# configz exposes the configuration loaded by the running kubelet, including
# command-line overrides; an edit without an effective restart must not pass.
if effective=$(kubectl --request-timeout=15s get --raw /api/v1/nodes/node01/proxy/configz); then
    if jq -e '.kubeletconfig.authorization.mode == "Webhook"' <<<"$effective" >/dev/null; then
        pass 'Running worker kubelet uses webhook authorization.'
    else
        fail 'Running worker kubelet does not use webhook authorization.'
    fi
    if jq -e '.kubeletconfig.protectKernelDefaults == true' <<<"$effective" >/dev/null; then
        pass 'Running worker kubelet protects kernel defaults.'
    else
        fail 'Running worker kubelet does not protect kernel defaults.'
    fi
else
    fail 'Could not inspect effective worker authorization and kernel protection through configz.'
fi
if "${SSH[@]}" systemctl is-active --quiet kubelet; then
    pass 'Worker kubelet service is active.'
else
    fail 'Worker kubelet service is not active or could not be inspected.'
fi
if ready=$(kubectl --request-timeout=15s get node node01 -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}') && [[ $ready == True ]]; then
    pass 'Worker node01 is Ready.'
else
    fail 'Worker node01 is not Ready or could not be inspected.'
fi
finish
