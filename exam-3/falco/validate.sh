#!/usr/bin/env bash
set -Eeuo pipefail

# Run on playground controlplane.
# Falco and its local rule are validated on node01, where the runtime probe runs.
passes=0
failures=0

pass() { echo "[PASS] $*"; passes=$((passes+1)); }
fail() { echo "[FAIL] $*"; failures=$((failures+1)); }

finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passes" "$failures"
    if (( failures == 0 )); then
        echo 'RESULT: SUCCESS'
        return 0
    else
        echo 'RESULT: FAILED'
        return 1
    fi
}

work=$(mktemp -d)
ns=
cleanup() {
    if [[ -n "$ns" ]]; then
        kubectl delete namespace "$ns" --wait=true --timeout=60s >/dev/null 2>&1 || true
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5 node01)

for cmd in kubectl ssh; do
    if ! command -v "$cmd" >/dev/null; then
        fail "Required command available on controlplane: $cmd"
        finish || true
        exit 1
    fi
done

if ! kubectl get node node01 >/dev/null 2>&1 ||
   ! kubectl wait --for=condition=Ready node/node01 --timeout=60s >/dev/null 2>&1; then
    fail 'node01 is present and Ready'
    finish || true
    exit 1
else
    pass 'node01 is present and Ready'
fi

if ! "${SSH[@]}" 'true' >/dev/null 2>&1; then
    fail 'SSH access from controlplane to node01'
    finish || true
    exit 1
else
    pass 'SSH access from controlplane to node01'
fi

config=${FALCO_CONFIG:-/etc/falco/falco.yaml}
rules=${RULES_FILE:-/etc/falco/falco_rules.local.yaml}

if "${SSH[@]}" "command -v falco >/dev/null && command -v python3 >/dev/null && python3 -c 'import yaml'"; then
    pass 'Falco and validation prerequisites are available on node01'
else
    fail 'Falco and validation prerequisites are available on node01'
    finish || true
    exit 1
fi

# Discover an active Falco service remotely.
service=$("${SSH[@]}" 'bash -s' <<'REMOTE'
set -e
service=${FALCO_SERVICE:-}
if [[ -z "$service" ]]; then
    while read -r unit _; do
        [[ "$unit" == falco*.service && "$unit" != falcoctl* ]] || continue
        if systemctl is-active --quiet "$unit"; then
            printf '%s\n' "$unit"
            exit 0
        fi
    done < <(systemctl list-units --type=service --all --no-legend --plain)
fi
[[ -n "$service" ]] && systemctl is-active --quiet "$service" && printf '%s\n' "$service"
REMOTE
) || true

if [[ -n "$service" ]]; then
    pass "Falco sensor is running on node01 ($service)"
else
    fail 'Falco sensor is running on node01'
fi

# Structural checks: tolerate YAML formatting/key order but require task semantics.
if "${SSH[@]}" python3 - "$rules" <<'PY'
import sys, yaml

with open(sys.argv[1]) as f:
    entries = yaml.safe_load(f) or []

rules = [
    x for x in entries
    if isinstance(x, dict) and x.get("rule") == "Detect dev mem access"
]
assert rules, "Required rule is missing"

merged = {}
for r in rules:
    merged.update(r)

assert str(merged.get("priority", "")).upper() == "WARNING", "Priority must be WARNING"
assert merged.get("output") == (
    "Sensitive file opened "
    "(user=%user.name command=%proc.cmdline file=%fd.name)"
), "Output differs from the task"

condition = str(merged.get("condition", ""))
assert "fd.name" in condition and "/dev/mem" in condition, (
    "Condition must test fd.name against /dev/mem"
)
PY
then
    pass 'Required Falco rule has the requested name, condition, output and WARNING priority'
else
    fail 'Required Falco rule has the requested name, condition, output and WARNING priority'
fi

# Falco itself must accept the effective ruleset on node01.
if "${SSH[@]}" falco -c "$config" -L >"$work/list" 2>"$work/errors" &&
   grep -Fq 'Detect dev mem access' "$work/list"; then
    pass 'Falco on node01 loads the configured rule set containing the requested rule'
else
    fail 'Falco on node01 loads the configured rule set containing the requested rule'
    cat "$work/errors" >&2
fi

# Determine Falco file output, if enabled. Journald is also inspected.
logfile=$("${SSH[@]}" python3 - "$config" <<'PY'
import sys, yaml
with open(sys.argv[1]) as f:
    c = yaml.safe_load(f) or {}
fo = c.get("file_output", {}) or {}
print(fo.get("filename", "") if fo.get("enabled") else "")
PY
) || logfile=

marker="cks-mem-$(date +%s)-$$"
ns=$(kubectl create namespace "$marker" -o jsonpath='{.metadata.name}')
start=$(date +%s)

# Harmless fixture: /dev/mem inside the test container is an emptyDir-backed file.
# The pod is explicitly placed on node01, where Falco is running.
if kubectl -n "$ns" create -f - >/dev/null <<YAML
apiVersion: v1
kind: Pod
metadata:
  name: probe
spec:
  nodeName: node01
  restartPolicy: Never
  initContainers:
  - name: fixture
    image: ${TEST_IMAGE:-busybox:1.37}
    command: [sh, -c, 'echo harmless > /fixture/mem']
    volumeMounts:
    - name: fixture
      mountPath: /fixture
  containers:
  - name: probe
    image: ${TEST_IMAGE:-busybox:1.37}
    command: [sh, -c, 'sleep 300']
    volumeMounts:
    - name: fixture
      mountPath: /dev/mem
      subPath: mem
      readOnly: true
    - name: fixture
      mountPath: /dev/cks-safe
      subPath: mem
      readOnly: true
  volumes:
  - name: fixture
    emptyDir: {}
YAML
then
    if kubectl -n "$ns" wait --for=condition=Ready pod/probe --timeout=120s >/dev/null; then
        actual_node=$(kubectl -n "$ns" get pod probe -o jsonpath='{.spec.nodeName}')
        if [[ "$actual_node" == node01 ]]; then
            pass 'Runtime probe is running on node01'
        else
            fail 'Runtime probe is running on node01'
        fi

        if kubectl -n "$ns" exec probe -- sh -c '
            mkdir -p "/tmp/$1"
            ln -sf /bin/busybox "/tmp/$1/cat"
            for i in 1 2 3 4 5; do
                "/tmp/$1/cat" /dev/cks-safe >/dev/null
                "/tmp/$1/cat" /dev/mem >/dev/null
                sleep 2
            done
        ' sh "$marker"; then
            pass 'Fresh pod generated safe /dev/mem read events on node01'
        else
            fail 'Runtime probe can generate the read events'
        fi
    else
        fail 'Runtime probe becomes Ready on node01'
    fi
else
    fail 'Runtime probe can be created'
fi

# Look only at fresh node01 Falco output and correlate with the unique command marker.
found=false
for attempt in {1..10}; do
    "${SSH[@]}" journalctl --since "@$start" --no-pager -o cat >"$work/alerts" 2>/dev/null || true

    if [[ -n "$logfile" ]]; then
        "${SSH[@]}" "test -r '$logfile' && cat '$logfile' || true" >>"$work/alerts" 2>/dev/null || true
    fi

    if python3 - "$work/alerts" "$marker" <<'PY'
import json, re, sys

positive = False
negative = False

for line in open(sys.argv[1], errors="replace"):
    if sys.argv[2] not in line:
        continue

    try:
        event = json.loads(line)
        if event.get("rule") != "Detect dev mem access":
            continue
        if str(event.get("priority", "")).upper() != "WARNING":
            continue
        output = event.get("output", "")
    except (ValueError, AttributeError):
        if not re.search(r"\bWarning\b", line, re.I):
            continue
        output = line

    if not re.search(
        r"Sensitive file opened \(user=.+ command=.+ file=.+\)", output
    ):
        continue

    if "file=/dev/mem)" in output:
        positive = True
    if "file=/dev/cks-safe)" in output:
        negative = True

sys.exit(0 if positive and not negative else 1)
PY
    then
        found=true
    else
        found=false
    fi

    # Keep observing briefly after a positive match to catch delayed false positives.
    sleep 2
done

if [[ "$found" == true ]]; then
    pass 'Fresh WARNING alert matches /dev/mem and does not match the comparison path'
else
    fail 'Fresh matching WARNING alert for /dev/mem on node01'
fi

if kubectl delete namespace "$ns" --wait=true --timeout=60s >/dev/null 2>&1; then
    ns=
    pass 'Temporary runtime probe cleaned up'
else
    fail 'Temporary runtime probe cleanup'
fi

finish
