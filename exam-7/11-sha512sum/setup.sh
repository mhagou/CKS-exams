#!/usr/bin/env bash
set -Eeuo pipefail

# Run only on the playground controlplane. No cluster changes are needed.
readonly lab_dir=/var/lib/cks-sha512sum
readonly binary=/usr/bin/kubelet
readonly reference="$lab_dir/reference.sha512"

trap 'printf "Scenario preparation failed (line %s).\n" "$LINENO" >&2' ERR
if (( EUID != 0 )); then
    printf 'Run setup.sh as root on controlplane.\n' >&2
    exit 1
fi

if ! command -v sha512sum >/dev/null 2>&1; then
    # sha512sum is supplied by coreutils on the usual playground images.
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y coreutils
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y coreutils
    else
        printf 'Install coreutils (sha512sum) and rerun setup.sh.\n' >&2
        exit 1
    fi
fi
command -v sha512sum >/dev/null
if [[ ! -f "$binary" || ! -r "$binary" || ! -x "$binary" ]]; then
    printf 'Expected an existing readable executable at %s.\n' "$binary" >&2
    exit 1
fi

# The task's example hash is specific to another binary/version. Supply a
# local exercise baseline, not a claim of upstream authenticity. Preserve
# it on reruns so setup cannot bless a subsequently changed binary.
install -d -m 0755 "$lab_dir"
if [[ ! -e "$reference" ]]; then
    temporary=$(mktemp "$lab_dir/.reference.XXXXXX")
    trap 'rm -f -- "${temporary:-}"' EXIT
    sha512sum "$binary" > "$temporary"
    chmod 0644 "$temporary"
    mv -- "$temporary" "$reference"
fi

# Check preparation without performing or printing the candidate's comparison.
record=$(cat "$reference")
digest=${record%% *}
if [[ ! "$digest" =~ ^[[:xdigit:]]{128}$ || "$record" != "$digest  $binary" ]]; then
    printf 'Invalid lab reference: %s. Inspect it before retrying.\n' "$reference" >&2
    exit 1
fi
[[ -s "$reference" && -r "$binary" && -x "$binary" ]]

cat <<'EOF'
=================================================
 CKS LAB READY
=================================================
Scenario preparation completed successfully.

Verify /usr/bin/kubelet using the supplied SHA-512 reference:
  /var/lib/cks-sha512sum/reference.sha512
The reference records the binary present at first setup, not upstream provenance.
EOF
