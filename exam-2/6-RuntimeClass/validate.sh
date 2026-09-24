#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only validation of live API objects; no local candidate YAML is required.
# task.txt's uppercase names are invalid Kubernetes DNS names. Use their
# lowercase forms, consistent with the intent of the embedded example.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed+1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed+1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    ((failed == 0))
}
k() { kubectl --request-timeout=30s "$@"; }
if ! command -v kubectl >/dev/null; then
    fail 'kubectl is required to inspect the playground.'
    finish
    exit 1
fi
if handler=$(k get runtimeclass gvisor -o jsonpath='{.handler}'); then
    if [[ $handler == runsc ]]; then pass 'RuntimeClass gvisor uses handler runsc.'
    else fail "RuntimeClass gvisor uses handler '$handler', expected runsc."; fi
else
    fail 'RuntimeClass gvisor exists and uses handler runsc.'
fi
if ! k get pod gvisor-pod -n test -o name >/dev/null; then
    fail 'Pod test/gvisor-pod exists.'
    fail 'The Pod selects RuntimeClass gvisor.'
    fail 'The Pod uses the nginx image.'
    fail 'The nginx container is running in the requested sandbox.'
    finish
    exit 1
fi
pass 'Pod test/gvisor-pod exists.'
if selected=$(k get pod gvisor-pod -n test -o jsonpath='{.spec.runtimeClassName}') && [[ $selected == gvisor ]]; then
    pass 'The Pod selects RuntimeClass gvisor.'
else
    fail 'The Pod selects RuntimeClass gvisor.'
fi

# Accept tags, digests, registry-qualified official nginx and any container name.
# Sidecars and container ordering do not affect image matching.
nginx_containers=()
if images=$(k get pod gvisor-pod -n test -o jsonpath='{range .spec.containers[*]}{.name}{"\t"}{.image}{"\n"}{end}'); then
    while IFS=$'\t' read -r name image; do
        if [[ $image =~ ^((docker.io|index.docker.io|registry-1.docker.io)/)?(library/)?nginx([:@].+)?$ ]]; then
            nginx_containers+=("$name")
        fi
    done <<< "$images"
fi
if ((${#nginx_containers[@]})); then pass 'The Pod uses the nginx image.'
else fail 'The Pod uses the nginx image.'; fi

# A selected RuntimeClass alone is insufficient: an unavailable handler leaves
# the Pod Pending. Require a live running nginx container and assigned node.
running=0
if state=$(k get pod gvisor-pod -n test -o jsonpath='{.status.phase}{"|"}{.spec.nodeName}{"|"}{.metadata.deletionTimestamp}') &&
   statuses=$(k get pod gvisor-pod -n test -o jsonpath='{range .status.containerStatuses[*]}{.name}{"\t"}{.state.running.startedAt}{"\n"}{end}'); then
    IFS='|' read -r phase node deleting <<< "$state"
    if [[ $phase == Running && -n $node && -z $deleting && ${selected:-} == gvisor && ${handler:-} == runsc ]]; then
        while IFS=$'\t' read -r name started; do
            for nginx_name in "${nginx_containers[@]}"; do
                if [[ $name == "$nginx_name" && -n $started ]]; then running=1; fi
            done
        done <<< "$statuses"
    fi
fi
if ((running)); then pass 'The nginx container is running in the requested sandbox.'
else fail 'The nginx container is running in the requested sandbox (check Pod events).'; fi
finish
