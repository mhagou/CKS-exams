#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only configuration inspection; the sole runtime action is a harmless shell exec.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if (( failed == 0 )); then echo 'RESULT: SUCCESS'; exit 0; fi
  echo 'RESULT: FAILED'; exit 1
}
for tool in kubectl jq script stat tail; do
  if ! command -v "$tool" >/dev/null; then fail "Required validation tool: $tool"; finish; fi
done
if [[ $EUID -ne 0 ]]; then fail 'Run validation as root on controlplane'; finish; fi
log=/var/log/falco-cks.json
if [[ ! -r $log ]]; then fail 'Prepared Falco alert log is readable'; finish; fi
if ! pod=$(kubectl -n space get pod shell-lab -o json); then
  fail 'Scenario pod exists'; finish
fi
cid=$(jq -r '.status.containerStatuses[0].containerID // ""' <<< "$pod")
cid=${cid#*://}
if [[ -z $cid ]] || ! jq -e '.status.containerStatuses[0].ready == true' <<< "$pod" >/dev/null; then
  fail 'Scenario container is running and ready'; finish
fi
if ! uid=$(kubectl -n space exec shell-lab -- id -u); then
  fail 'Read actual container user ID'; finish
fi
# Temporary local capture only; never truncate logs or restart/reconfigure Falco.
capture=$(mktemp)
trap 'rm -f "$capture"' EXIT
offset=$(stat -c %s "$log")
for attempt in {1..10}; do
  if ! script -q -e -c 'kubectl -n space exec -it shell-lab -- /bin/sh -c "sleep 1"' /dev/null >/dev/null 2>&1; then
    fail 'Trigger a terminal shell in the scenario container'; finish
  fi
  sleep 2
  tail -c +"$((offset + 1))" "$log" > "$capture"
  # Ignore a partially written last JSON record; retry on the next iteration.
  if jq -e -s --arg cid "$cid" '
      any(.[]; .rule == "Terminal shell in container" and
        ((.output_fields["container.id"] // "") as $id |
        ($id | length) >= 12 and ($cid | startswith($id))))' "$capture" >/dev/null 2>&1; then
    break
  fi
done
if ! jq -e -s 'any(.[]; .rule == "Terminal shell in container")' "$capture" >/dev/null 2>&1; then
  fail 'Fresh terminal-shell alert was generated'; finish
fi
pass 'Fresh terminal-shell alert was generated'
# Evaluate all fields on ONE correlated event, accepting any labels/order/separators.
# Falco output_fields records the actual expanded placeholders, not candidate YAML.
if jq -e -s --arg cid "$cid" --arg uid "$uid" '
    any(.[]; .rule == "Terminal shell in container" and
      ((.output_fields // {}) as $f |
      ($f["container.id"] // "") as $id |
      ($id | length) >= 12 and ($cid | startswith($id)) and
      (($f["user.uid"] | tostring) == $uid) and
      (($f["container.image.repository"] // "") | test("(^|/)busybox$"))))' "$capture" >/dev/null 2>&1; then
  pass 'Shell alert includes the actual user ID, container ID, and container image repository'
else
  fail 'Shell alert must include user.uid, container.id, and container.image.repository with actual container values'
fi
finish
