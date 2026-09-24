#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation. Run on controlplane; ADMIN_KUBECONFIG may select custom credentials.
passes=0
failures=0
report() {
    if [[ $1 == pass ]]; then
        printf '[PASS] %s\n' "$2"
        passes=$((passes + 1))
    else
        printf '[FAIL] %s\n' "$2"
        failures=$((failures + 1))
    fi
}
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
    if (( failures == 0 )); then
        printf 'RESULT: SUCCESS\n'
        exit 0
    fi
    printf 'RESULT: FAILED\n'
    exit 1
}
for command in kubectl jq systemctl; do
    if ! command -v "$command" >/dev/null; then
        report fail "Required validation command available: $command"
        finish
    fi
done
if [[ $(hostname -s) != controlplane ]]; then
    report fail 'Validation runs on controlplane'
    finish
fi
admin_config=${ADMIN_KUBECONFIG:-/etc/kubernetes/admin.conf}
if [[ ! -r $admin_config ]]; then
    report fail 'Readable admin kubeconfig (set ADMIN_KUBECONFIG for a custom path)'
    finish
fi
kube=(kubectl --kubeconfig="$admin_config" --request-timeout=15s)

# configz reports the running configuration including flags and drop-in overrides.
# Neither the example cache TTLs nor its client CA path are task requirements.
effective=''
if effective=$("${kube[@]}" get --raw /api/v1/nodes/controlplane/proxy/configz) &&
   jq -e '.kubeletconfig | type == "object"' <<< "$effective" >/dev/null; then
    if jq -e '.kubeletconfig.authentication.anonymous.enabled == false' <<< "$effective" >/dev/null; then
        report pass 'Controlplane kubelet disables anonymous authentication'
    else
        report fail 'Controlplane kubelet disables anonymous authentication'
    fi
    if jq -e '.kubeletconfig.authorization.mode == "Webhook"' <<< "$effective" >/dev/null; then
        report pass 'Controlplane kubelet delegates authorization to the API server (Webhook)'
    else
        report fail 'Controlplane kubelet delegates authorization to the API server (Webhook)'
    fi
else
    report fail 'Anonymous authentication disabled: effective configuration could not be read'
    report fail 'Webhook authorization enabled: effective configuration could not be read'
fi

if systemctl is-active --quiet kubelet &&
   [[ $("${kube[@]}" get --raw /api/v1/nodes/controlplane/proxy/healthz 2>/dev/null) == ok ]]; then
    report pass 'Controlplane kubelet service is active and its health endpoint responds'
else
    report fail 'Controlplane kubelet service is active and its health endpoint responds'
fi
finish
