#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane, never on the development host.
trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
[[ $EUID -eq 0 ]] || { echo 'Run as root on controlplane.' >&2; exit 1; }
[[ $(hostname -s) == controlplane ]] || { echo 'Run on controlplane.' >&2; exit 1; }
command -v sysctl >/dev/null || { echo 'Required command missing: sysctl (procps).' >&2; exit 1; }

# The task explicitly supplies this initial runtime state. Preserve all
# persistent settings and unrelated kernel parameters.
sysctl -q -w net.ipv4.ip_forward=1
[[ $(sysctl -n net.ipv4.ip_forward) == 1 ]]

cat <<'READY'
=================================================
 CKS LAB READY
=================================================

Scenario preparation completed successfully.
READY
