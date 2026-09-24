#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane.
# Falco is prepared on node01 because ordinary lab workloads are scheduled there.
trap 'echo "Scenario preparation failed (line $LINENO)." >&2' ERR

[[ $EUID == 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
command -v kubectl >/dev/null || { echo 'kubectl is required on controlplane.' >&2; exit 1; }
command -v ssh >/dev/null || { echo 'ssh is required on controlplane.' >&2; exit 1; }

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 node01)

kubectl get node controlplane >/dev/null
kubectl get node node01 >/dev/null
kubectl wait --for=condition=Ready node/controlplane --timeout=60s >/dev/null
kubectl wait --for=condition=Ready node/node01 --timeout=60s >/dev/null

"${SSH[@]}" 'true'

# Install Falco prerequisites on node01 only when needed.
"${SSH[@]}" 'bash -s' <<'REMOTE'
set -Eeuo pipefail

if ! python3 -c 'import yaml' 2>/dev/null; then
    command -v apt-get >/dev/null || {
        echo "python3/PyYAML missing on node01 and apt-get is unavailable." >&2
        exit 1
    }
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y python3 python3-yaml
fi

if ! command -v falco >/dev/null; then
    command -v apt-get >/dev/null || {
        echo "Falco missing on node01 and apt-get is unavailable." >&2
        exit 1
    }
    case "$(uname -m)" in
        x86_64|aarch64) ;;
        *) echo "Unsupported Falco architecture on node01." >&2; exit 1 ;;
    esac

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg

    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT

    curl -fsSL https://falco.org/repo/falcosecurity-packages.asc -o "$work/key.asc"
    gpg --batch --dearmor -o "$work/key.gpg" "$work/key.asc"
    install -m 0644 "$work/key.gpg" /usr/share/keyrings/cks-falco.gpg

    echo 'deb [signed-by=/usr/share/keyrings/cks-falco.gpg] https://download.falco.org/packages/deb stable main' \
        > /etc/apt/sources.list.d/cks-falco.list

    apt-get update
    DEBIAN_FRONTEND=noninteractive FALCO_FRONTEND=noninteractive apt-get install -y falco
fi

config=${FALCO_CONFIG:-/etc/falco/falco.yaml}
rules=${RULES_FILE:-/etc/falco/falco_rules.local.yaml}

[[ -f "$config" ]] || { echo "Falco config not found on node01: $config" >&2; exit 1; }
[[ -e "$rules" ]] || install -m 0644 /dev/null "$rules"

# Verify that the selected local rules file is loaded. Do not rewrite Falco config.
python3 - "$config" "$rules" <<'PY'
import os, sys, yaml

with open(sys.argv[1]) as f:
    cfg = yaml.safe_load(f) or {}

target = os.path.realpath(sys.argv[2])
entries = cfg.get("rules_files", [])

def loaded(entry):
    entry = os.path.realpath(entry)
    if entry == target:
        return True
    if os.path.isdir(entry) and os.path.dirname(target) == entry:
        return True
    return False

if not any(loaded(x) for x in entries):
    sys.exit(
        "Falco configuration on node01 does not load "
        f"{sys.argv[2]}; inspect rules_files."
    )
PY

# Discover the active/selected Falco service on node01.
service=${FALCO_SERVICE:-}

if [[ -z "$service" ]]; then
    while read -r unit _; do
        [[ "$unit" == falco*.service && "$unit" != falcoctl* ]] || continue
        if systemctl is-active --quiet "$unit"; then
            service=$unit
            break
        fi
    done < <(systemctl list-units --type=service --all --no-legend --plain)
fi

if [[ -z "$service" ]]; then
    while read -r unit state _; do
        [[ "$unit" == falco*.service && "$unit" != falcoctl* && "$state" == enabled ]] || continue
        service=$unit
        break
    done < <(systemctl list-unit-files --type=service --no-legend)
fi

[[ -n "$service" ]] || {
    echo "No Falco sensor service found on node01." >&2
    exit 1
}

systemctl is-active --quiet "$service" || systemctl start "$service"
sleep 3
systemctl is-active --quiet "$service"

# Validate the currently installed rule set without adding the candidate rule.
falco -c "$config" -L >/dev/null

printf '%s\n' "$service" > /tmp/cks-falco-service
REMOTE

service=$("${SSH[@]}" 'cat /tmp/cks-falco-service 2>/dev/null || true')

printf '\n=================================================\n'
printf ' CKS LAB READY\n'
printf '=================================================\n'
printf 'Scenario preparation completed successfully.\n'
printf 'Falco sensor node: node01\n'
printf 'Falco local rules file on node01: /etc/falco/falco_rules.local.yaml\n'
printf 'Falco service on node01: %s\n' "${service:-detected}"
printf 'Existing Falco rules/configuration were preserved.\n'
