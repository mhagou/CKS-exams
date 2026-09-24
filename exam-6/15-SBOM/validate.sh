#!/usr/bin/env bash
set -Eeuo pipefail

# Read-only assessment of candidate artifacts. Scans use disposable output/cache.
# The task does not specify an image, a CVE threshold, or saved Grype output.
# Tool metadata establishes provenance without imposing version-specific strings.
# This verifies a live Grype check, not historical execution by the candidate.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
for tool in jq grype; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        fail "Required validation tool is unavailable: $tool"
    fi
done
((failed == 0)) || finish
report_dir=${1:-.}
if ! report_dir=$(cd -- "$report_dir" && pwd); then
    fail 'Report directory exists'; finish
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
# Ignore unrelated Grype configuration, including fail-on severity policies.
printf '{}\n' > "$scratch/grype.yaml"

check_report() {
    local name=$1 format=$2 producer=$3 file="$report_dir/$1" valid=1
    if [[ $format == spdx ]]; then
        if ! jq -e --arg producer "$producer" '
            type == "object" and
            (.spdxVersion | type == "string" and startswith("SPDX-")) and
            (.SPDXID == "SPDXRef-DOCUMENT") and
            (.documentNamespace | type == "string" and length > 0) and
            (.packages | type == "array" and length > 0) and
            all(.packages[]; (.name | type == "string" and length > 0) and
                (.SPDXID | type == "string" and startswith("SPDXRef-"))) and
            any(.creationInfo.creators[]?;
                test("^Tool:"; "i") and test($producer; "i"))
        ' "$file" >/dev/null 2>&1; then valid=0; fi
    else
        if ! jq -e '
            type == "object" and .bomFormat == "CycloneDX" and
            (.specVersion | type == "string" and length > 0) and
            (.components | type == "array" and length > 0) and
            all(.components[]; (.name | type == "string" and length > 0) and
                (.type | type == "string" and length > 0)) and
            any(.metadata.tools | .. | objects;
                (.name? // "" | test("trivy"; "i")))
        ' "$file" >/dev/null 2>&1; then valid=0; fi
    fi
    if ((valid)); then
        pass "$name contains a populated $format report with $producer provenance"
    else
        fail "$name must contain a populated $format report with $producer provenance"
        fail "Grype check of $name: report is missing or invalid"
        return
    fi
    # Use the prepared DB (updates disabled); vulnerability findings are allowed.
    # No reports or persistent configuration are written by the validator.
    if GRYPE_DB_AUTO_UPDATE=false GRYPE_CHECK_FOR_APP_UPDATE=false \
       GRYPE_FAIL_ON_SEVERITY='' GRYPE_CACHE_DIR="$scratch/cache" \
       grype --config "$scratch/grype.yaml" "sbom:$file" -o json \
       > "$scratch/$name.grype.json" 2> "$scratch/$name.stderr" &&
       jq -e 'type == "object" and (.matches | type == "array")' \
       "$scratch/$name.grype.json" >/dev/null 2>&1; then
        pass "Grype successfully checks $name and produces parseable JSON"
    else
        fail "Grype check of $name failed (including possible database/tool failure)"
        head -n 8 "$scratch/$name.stderr" >&2
    fi
}
check_report sbom1.json spdx bom
check_report sbom2.json cyclonedx trivy
check_report sbom3.json spdx syft
finish
