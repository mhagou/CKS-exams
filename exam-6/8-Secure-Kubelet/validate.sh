#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only checks; run on the playground controlplane after solving the task.
export KUBECONFIG="${KUBECONFIG:-/etc/kubernetes/admin.conf}"
passed=0
failed=0
record() {
    if [[ $1 == yes ]]; then
        printf '[PASS] %s\n' "$2"
        passed=$((passed + 1))
    else
        printf '[FAIL] %s\n' "$2"
        failed=$((failed + 1))
    fi
}
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then
        printf 'RESULT: SUCCESS\n'
    else
        printf 'RESULT: FAILED\n'
        exit 1
    fi
}
for command in kubectl curl jq systemctl; do
    if ! command -v "$command" >/dev/null; then
        record no "Required validation command is available: $command"
    fi
done
if [[ $(hostname -s) != controlplane ]]; then
    record no 'Validation runs on controlplane (the localhost target).'
fi
((failed == 0)) || finish

healthy=no
if systemctl is-active --quiet kubelet &&
   [[ $(kubectl --request-timeout=10s get node controlplane -o 'jsonpath={.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null) == True ]]; then
    healthy=yes
fi
record "$healthy" 'Kubelet is active and controlplane is Ready.'

# configz reports the running configuration, including command-line overrides
# and configuration drop-ins; no candidate file layout is assumed.
effective='{}'
if data=$(kubectl --request-timeout=15s get --raw /api/v1/nodes/controlplane/proxy/configz 2>/dev/null) &&
   jq -e '.kubeletconfig | type == "object"' <<<"$data" >/dev/null 2>&1; then
    effective=$data
    record yes 'Effective kubelet configuration is accessible through the API server.'
else
    record no 'Effective kubelet configuration is accessible through the API server.'
fi
anonymous=no
authorization=no
readonly=no
if jq -e '.kubeletconfig.authentication.anonymous.enabled == false' <<<"$effective" >/dev/null; then anonymous=yes; fi
if jq -e '.kubeletconfig.authorization.mode == "Webhook"' <<<"$effective" >/dev/null; then authorization=yes; fi
if jq -e '.kubeletconfig.readOnlyPort == 0' <<<"$effective" >/dev/null; then readonly=yes; fi
record "$anonymous" 'Anonymous authentication is disabled in the running kubelet.'
record "$authorization" 'The running kubelet uses Webhook authorization.'
record "$readonly" 'The running kubelet has its read-only port disabled.'

# An unreachable TLS endpoint is not proof of disabled anonymous authentication.
code=''
if code=$(curl --noproxy '*' -sk --connect-timeout 3 --max-time 10 -o /dev/null -w '%{http_code}' https://localhost:10250/pods) && [[ $code == 401 ]]; then
    record yes 'Unauthenticated HTTPS access to /pods returns 401.'
else
    record no "Unauthenticated HTTPS access to /pods returns 401 (observed ${code:-connection failure})."
fi

# The read-only endpoint speaks HTTP, not HTTPS. Require connection refusal,
# not just an HTTP error or timeout. Effective config above also checks that
# the listener was not merely moved to another port.
rc=0
curl --noproxy '*' -s --connect-timeout 3 --max-time 5 -o /dev/null http://localhost:10255/metrics 2>/dev/null || rc=$?
if [[ $rc == 7 ]]; then
    record yes 'The localhost read-only metrics endpoint is not listening.'
else
    record no "The localhost read-only metrics endpoint is not listening (curl exit $rc)."
fi
finish
