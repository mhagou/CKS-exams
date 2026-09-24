#!/usr/bin/env bash
set -Eeuo pipefail

# Run on the playground controlplane. This task only asks for a policy file.
# Keep both existing API server configuration and the supplied example untouched.
[[ $EUID -eq 0 ]] || { echo 'Run setup.sh as root on controlplane.' >&2; exit 1; }
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR

# A real YAML parser is needed to evaluate ordered audit rules reliably.
if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-yaml
    else
        echo 'Install Python 3 and its PyYAML module, then rerun setup.sh.' >&2
        exit 1
    fi
fi

lab_dir=/root/cks-q5-auditing
policy=$lab_dir/audit-policy.yaml
install -d -m 0700 "$lab_dir"
if [[ ! -e $policy ]]; then
    (umask 077; cat > "$policy" <<'POLICY'
apiVersion: audit.k8s.io/v1
kind: Policy
rules: []
POLICY
    )
fi
# Do not overwrite candidate work on subsequent setup runs.
[[ -f $policy && -r $policy && -w $policy ]]
python3 -c 'import yaml' >/dev/null
printf '\n=================================================\n CKS LAB READY\n=================================================\n\nScenario preparation completed successfully.\n'
printf 'Working policy: %s\nExisting work is preserved on reruns.\n' "$policy"
printf 'Validate with: ./validate.sh [path-to-policy]\n'
