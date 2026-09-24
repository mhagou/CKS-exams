#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only cluster checks; run on the same playground controlplane as setup.
STATE=/var/lib/cks-spectacle-trivy
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$*"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$*"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then printf 'RESULT: SUCCESS\n'; exit 0; fi
    printf 'RESULT: FAILED\n'; exit 1
}
for command in kubectl trivy; do
    if ! command -v "$command" >/dev/null; then fail "$command is unavailable"; finish; fi
done
if [[ ! -f $STATE/ready || ! -s $STATE/baseline.tsv || ! -d $STATE/cache/db ]]; then
    fail 'Successful setup baseline and vulnerability database are required'; finish
fi
for variable in ${!TRIVY_@}; do unset "$variable"; done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
printf '{}\n' > "$work/trivy.yaml"
cd "$work"
if ! kubectl -n spectacle get pods -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.uid}{"\t"}{.metadata.deletionTimestamp}{"\n"}{end}' > pods.tsv; then
    fail 'Cannot inspect pods in spectacle'; finish
fi
declare -A results=()
while IFS=$'\t' read -r name uid classification image; do
    current_uid=$(awk -F '\t' -v name="$name" '$1 == name {print $2}' pods.tsv)
    if [[ $classification == critical ]]; then
        results[$image]=10
        # A deletionTimestamp alone is insufficient: wait for actual removal.
        if awk -F '\t' -v uid="$uid" '$2 == uid {found=1} END {exit !found}' pods.tsv; then
            fail "Vulnerable original pod $name has not been deleted"
        else
            pass "Vulnerable original pod $name was deleted"
        fi
    elif [[ $classification == clean ]]; then
        results[$image]=0
        deleting=$(awk -F '\t' -v name="$name" '$1 == name {print $3}' pods.tsv)
        if [[ $current_uid == "$uid" && -z $deleting ]]; then
            pass "Unaffected pod $name was preserved"
        else
            fail "Unaffected pod $name was unnecessarily deleted"
        fi
    else
        fail 'Invalid setup baseline'; finish
    fi
done < "$STATE/baseline.tsv"

# Scan every remaining regular, init and ephemeral container, including any
# replacement pods. Use the setup database so advisory updates do not change grading.
while IFS=$'\t' read -r name uid deleting; do
    [[ -n $name ]] || continue
    if ! kubectl -n spectacle get pod "$name" -o jsonpath='{range .spec.containers[*]}{"spec\tregular/"}{.name}{"\t"}{.image}{"\n"}{end}{range .spec.initContainers[*]}{"spec\tinit/"}{.name}{"\t"}{.image}{"\n"}{end}{range .spec.ephemeralContainers[*]}{"spec\tephemeral/"}{.name}{"\t"}{.image}{"\n"}{end}{range .status.containerStatuses[*]}{"status\tregular/"}{.name}{"\t"}{.imageID}{"\n"}{end}{range .status.initContainerStatuses[*]}{"status\tinit/"}{.name}{"\t"}{.imageID}{"\n"}{end}{range .status.ephemeralContainerStatuses[*]}{"status\tephemeral/"}{.name}{"\t"}{.imageID}{"\n"}{end}' > containers.tsv; then
        fail "Cannot inspect remaining pod $name"; continue
    fi
    # Match each container to its runtime image. A tag may now point elsewhere;
    # scanning it as well would not describe the image actually in this pod.
    awk -F '\t' '
        $1 == "spec" {spec[$2]=$3}
        $1 == "status" {runtime[$2]=$3}
        END {for (key in spec) print spec[key] "\t" runtime[key]}
    ' containers.tsv > images.txt
    safe=true
    if [[ ! -s images.txt ]]; then
        fail "No container images could be inspected for $name"; continue
    fi
    while IFS=$'\t' read -r configured image; do
        image=${image#docker-pullable://}
        image=${image#docker://}
        if [[ -z $image ]]; then
            # A container that has not started still needs its requested image checked.
            image=$configured
        elif [[ $image != *@sha256:* ]]; then
            # Local config IDs cannot be scanned remotely. Only an immutable
            # requested reference is a reliable fallback; never silently skip it.
            if [[ $configured == *@sha256:* ]]; then
                image=$configured
            else
                fail "Cannot resolve the running image digest for a container in $name"
                safe=false
                continue
            fi
        fi
        if [[ ! ${results[$image]+known} ]]; then
            rc=0
            trivy --config "$work/trivy.yaml" --cache-dir "$STATE/cache" image \
                --image-src remote --scanners vuln --severity CRITICAL --ignorefile /dev/null \
                --ignore-unfixed=false --skip-db-update --exit-code 10 --no-progress \
                "$image" > scan.log 2>&1 || rc=$?
            results[$image]=$rc
        fi
        case ${results[$image]} in
            0) ;;
            10) fail "Remaining pod $name contains an image with CRITICAL vulnerabilities"; safe=false ;;
            *) fail "Cannot scan an image of $name (registry/database/scanner error)"; safe=false ;;
        esac
    done < images.txt
    if [[ $safe == true ]]; then pass "Remaining pod $name has no CRITICAL image findings"; fi
done < pods.tsv
finish
