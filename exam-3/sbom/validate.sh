#!/usr/bin/env bash
set -Eeuo pipefail

# Read the submitted artifact only; no cluster access, downloads, or repairs.
passed=0
failed=0
pass() { printf '[PASS] %s\n' "$1"; passed=$((passed + 1)); }
fail() { printf '[FAIL] %s\n' "$1"; failed=$((failed + 1)); }
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if ((failed == 0)); then echo 'RESULT: SUCCESS'; exit 0; fi
    echo 'RESULT: FAILED'; exit 1
}
file=/opt/sbom.spdx
if [[ -f $file && -r $file && -s $file ]]; then
    pass 'A readable, nonempty SBOM exists at /opt/sbom.spdx.'
else
    fail 'A readable, nonempty SBOM must exist at /opt/sbom.spdx.'
    finish
fi
command -v jq >/dev/null || { fail 'Validation prerequisite jq is missing; run setup before attempting the lab.'; finish; }
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

if jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
    cp -- "$file" "$work/document.json"
else
    # Normalize the relevant SPDX tag-value fields to the same model as JSON.
    # Ignore file/snippet metadata and multiline free-text fields, which may
    # contain strings resembling tags. Package names start package sections.
    if ! jq -Rn '
      reduce inputs as $line
        ({packages: [], creationInfo: {creators: []}, relationships: [], _section: "document", _text: false};
         ($line | sub("\r$"; "")) as $line |
         if ._text then
           ._text = ($line | contains("</text>") | not)
         elif ($line | contains("<text>")) then
           ._text = ($line | contains("</text>") | not)
         elif ($line | test("^[A-Za-z][A-Za-z0-9]*:")) then
           ($line | capture("^(?<key>[^:]+):\\s*(?<value>.*)$")) as $f |
           ($f.value | sub("\\s+$"; "")) as $v |
           if $f.key == "PackageName" then .packages += [{name: $v}] | ._section = "package"
           elif $f.key == "FileName" or $f.key == "SnippetSPDXID" then ._section = "other"
           elif $f.key == "SPDXVersion" then .spdxVersion = $v
           elif $f.key == "DataLicense" then .dataLicense = $v
           elif $f.key == "DocumentName" then .name = $v
           elif $f.key == "DocumentNamespace" then .documentNamespace = $v
           elif $f.key == "Creator" then .creationInfo.creators += [$v]
           elif $f.key == "Created" then .creationInfo.created = $v
           elif $f.key == "Relationship" then .relationships += [$v]
           elif $f.key == "SPDXID" and ._section == "document" then .SPDXID = $v
           elif $f.key == "SPDXID" and ._section == "package" then .packages[-1].SPDXID = $v
           elif $f.key == "PackageVersion" and ._section == "package" then .packages[-1].versionInfo = $v
           else . end
         else . end)
      | del(._section, ._text)
    ' "$file" > "$work/document.json"; then
        fail 'The submitted file could not be parsed as SPDX JSON or tag-value.'
        finish
    fi
fi
check() {
    if jq -e "$2" "$work/document.json" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}
# Check meaningful SPDX structure, not exact tool-generated IDs or ordering.
check 'The artifact has SPDX document metadata and package relationships.' '
    (.spdxVersion | test("^SPDX-2\\.[0-9]+$")) and
    .SPDXID == "SPDXRef-DOCUMENT" and .dataLicense == "CC0-1.0" and
    (.name | length > 0) and (.documentNamespace | test("^[a-zA-Z][a-zA-Z0-9+.-]*:")) and
    (.creationInfo.created | length > 0) and
    (.packages | type == "array" and length > 1) and
    all(.packages[]; (.name | length > 0) and (.SPDXID | startswith("SPDXRef-"))) and
    (.relationships | length > 0)'
check 'The SBOM records Trivy or Syft as a generating tool.' '
    any(.creationInfo.creators[]?; test("^Tool:.*(trivy|syft)"; "i"))'
check 'The SBOM identifies the requested nginx:1.19 image.' '
    def target: test("(^|/|:)nginx:1\\.19($|[[:space:]@(])");
    ([.name, (.packages[]?.name)] | any(.[]; type == "string" and target)) or
    any(.packages[]?; (.name | test("(^|/)nginx$")) and .versionInfo == "1.19")'
check 'The SBOM includes versioned nginx 1.19 software and OS package inventory.' '
    any(.packages[]?; (.name | test("^nginx($|-)")) and
        ((.versionInfo // "") | test("^([0-9]+:)?1\\.19([.+~-]|$)"))) and
    any(.packages[]?; (.name == "libc6" or .name == "base-files" or .name == "dpkg") and
        ((.versionInfo // "") | length > 0))'
finish
