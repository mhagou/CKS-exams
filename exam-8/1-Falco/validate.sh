#!/usr/bin/env bash
set -Eeuo pipefail

# Run as root on controlplane after solving the exercise.
# Usage: ./validate.sh [rule-file-or-directory ...]
# Default: ./catch-rogue.yaml. Use --configured to test installed Falco rules.
# Extra positional paths allow candidate rules that depend on shared macros.
passed=0 failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
  printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
  if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
  echo 'RESULT: FAILED'; exit 1
}
for command in kubectl falco jq timeout; do
  if ! command -v "$command" >/dev/null; then fail "Missing dependency: $command (run setup first)"; finish; fi
done
if [[ $EUID -ne 0 || $(hostname -s) != controlplane ]]; then
  fail 'Validation must run as root on controlplane'; finish
fi
args=()
if [[ ${1:-} == --configured ]]; then
  if (($# != 1)); then fail '--configured does not accept additional rule paths'; finish; fi
else
  if (($# == 0)); then set -- ./catch-rogue.yaml; fi
  for path in "$@"; do
    if [[ ! -r $path ]]; then fail "Candidate rule path is unreadable: $path"; finish; fi
    args+=(-r "$path")
  done
fi

work=$(mktemp -d)
capture_pid=''
cleanup() {
  if [[ -n $capture_pid ]]; then
    kill "$capture_pid" 2>/dev/null || true
    wait "$capture_pid" 2>/dev/null || true
  fi
  rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ! kubectl get pod rogue-pod -n default -o json >"$work/pod.json"; then
  fail 'The demonstration pod exists'; finish
fi
if ! jq -e '.spec.nodeName == "controlplane" and
  any(.status.conditions[]?; .type == "Ready" and .status == "True")' "$work/pod.json" >/dev/null; then
  fail 'The demonstration pod is ready on the node monitored by Falco'; finish
fi
cid=$(jq -r '.status.containerStatuses[]? | select(.name == "snooper-container") | .containerID // empty' "$work/pod.json")
cid=${cid#*://}
if [[ -z $cid ]]; then fail 'Cannot resolve the demonstration container identity'; finish; fi
pass 'The demonstration container is running on controlplane'

# Output routing changes are ephemeral and do not alter rule conditions, priority,
# capture engine, or persistent configuration. No services are stopped/restarted.
timeout --signal=TERM --kill-after=5s 60s falco "${args[@]}" -M 25 \
  -o json_output=true -o stdout_output.enabled=true \
  -o file_output.enabled=false -o syslog_output.enabled=false \
  -o program_output.enabled=false -o http_output.enabled=false \
  -o webserver.enabled=false >"$work/alerts" 2>"$work/diagnostics" &
capture_pid=$!

# The pod already reads every three seconds; explicit reads provide extra probes.
triggered=false
host_triggered=false
for attempt in {1..10}; do
  sleep 2
  if ! kill -0 "$capture_pid" 2>/dev/null; then break; fi
  if kubectl exec -n default rogue-pod -c snooper-container -- \
    cat /data/secret.txt >/dev/null 2>&1; then triggered=true; fi
  # A host read of the same fixture must not be classified as a rogue container.
  if cat /opt/sensitive-data/secret.txt >/dev/null 2>&1; then host_triggered=true; fi
done
if wait "$capture_pid"; then
  pass 'Falco successfully loaded and ran the candidate rules'
else
  fail 'Falco could not complete capture with the candidate rules'
  cat "$work/diagnostics" >&2
fi
capture_pid=''
if [[ $triggered == true ]]; then pass 'Sensitive-file reads were triggered in the container';
else fail 'Could not trigger the sensitive-file read'; fi

# Match structured event data, not rule names, output wording, or YAML formatting.
# Ignore non-JSON startup messages. Accept short or full runtime container IDs.
jq -R 'fromjson? | select(type == "object")' "$work/alerts" >"$work/events.json"
jq -s --arg cid "$cid" '
  [.[] | select(
    (.output_fields // {}) as $f |
    ($f["container.id"] // "") as $id |
    ($id | length) >= 12 and ($cid | startswith($id)) and
    ($f["fd.name"] // "" | endswith("/secret.txt")) and
    ($f["container.name"] // "" | length) > 0 and
    ($f["container.name"] != "<NA>") and
    ($f["proc.cmdline"] // "" | contains("cat"))
  )]' "$work/events.json" >"$work/matches.json"
if jq -e 'length > 0' "$work/matches.json" >/dev/null; then
  pass 'A live sensitive-file alert identifies the rogue container, file, and command'
  if [[ $host_triggered == true ]] && jq -e -s --slurpfile matches "$work/matches.json" '
    ($matches[0] | map(.rule) | unique) as $rules |
    any(.[];
      .rule as $rule | (.output_fields // {}) as $f |
      ($rules | index($rule)) != null and
      ($f["fd.name"] // "" | endswith("/secret.txt")) and
      (($f["container.id"] // "host") == "host" or
       $f["container.id"] == "<NA>" or $f["container.id"] == "")
    ) | not' "$work/events.json" >/dev/null; then
    pass 'The detecting rule excludes host reads of the sensitive file'
  else
    fail 'Host reads could not be tested or were incorrectly classified by the detecting rule'
  fi
else
  fail 'No live alert contained the rogue container identity, secret.txt path, and read command'
  echo 'Inspect the candidate output fields and Falco container metadata enrichment.' >&2
fi
finish
