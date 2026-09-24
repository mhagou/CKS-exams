#!/usr/bin/env bash
set -Eeuo pipefail

# Usage: ./validate.sh [namespace [pod-name]]
# The question explicitly requires a Secret. Direct serviceAccountToken
# projection alone (as in solution.txt) does not satisfy that requirement.
# No particular Secret type, key, path, lifetime or resource name is required.
# TokenReviews are non-persisted authentication checks; no resources are repaired.
NS=${1:-serviceaccount-projection}
POD=${2:-}
passed=0 failed=0
report() {
    if [[ $1 == true ]]; then
        printf '[PASS] %s\n' "$2"; passed=$((passed + 1))
    else
        printf '[FAIL] %s\n' "$2"; failed=$((failed + 1))
    fi
}
finish() {
    printf '\nTotals: %d passed, %d failed\n' "$passed" "$failed"
    if (( failed == 0 )); then echo 'RESULT: SUCCESS'; else echo 'RESULT: FAILED'; fi
    (( failed == 0 ))
}
for cmd in kubectl jq base64 date; do
    if ! command -v "$cmd" >/dev/null; then
        report false "Required validation command is available: $cmd"
        finish; exit 1
    fi
done
if [[ -n $POD ]]; then
    if ! pods=$(kubectl -n "$NS" get pod "$POD" -o json); then
        report false 'Target Pod is accessible'; finish; exit 1
    fi
    pods=$(jq '{items: [.]}' <<<"$pods")
else
    if ! pods=$(kubectl -n "$NS" get pods -o json); then
        report false 'Lab Pods are accessible'; finish; exit 1
    fi
fi

mounted=false readable=false expires=false authenticated=false
# Enumerate regular running containers and their mounted projected Secrets.
while IFS=$'\t' read -r pod container mount subpath secret items; do
    [[ -n $pod ]] || continue
    if ! data=$(kubectl -n "$NS" get secret "$secret" -o json 2>/dev/null); then
        continue
    fi
    while IFS=$'\t' read -r key relative; do
        [[ -n $key ]] || continue
        if [[ $subpath != '-' ]]; then
            if [[ $relative == "$subpath" ]]; then
                path=$mount
            elif [[ $relative == "$subpath/"* ]]; then
                path=${mount%/}/${relative#"$subpath/"}
            else
                continue
            fi
        else
            path=${mount%/}/$relative
        fi
        mounted=true
        encoded=$(jq -r --arg key "$key" '.data[$key] // empty' <<<"$data")
        [[ -n $encoded ]] || continue
        if ! expected=$(printf '%s' "$encoded" | base64 -d 2>/dev/null); then continue; fi
        # Credentials remain in memory and are never printed in diagnostics.
        if ! token=$(kubectl -n "$NS" exec "$pod" -c "$container" -- cat "$path" 2>/dev/null); then
            continue
        fi
        [[ -n $token && $token == "$expected" ]] || continue
        readable=true
        [[ $token =~ ^[A-Za-z0-9_-]+\.([A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+$ ]] || continue
        payload=${BASH_REMATCH[1]}
        payload=${payload//-/+}; payload=${payload//_/\/}
        case $((${#payload} % 4)) in
            2) payload+='==' ;; 3) payload+='=' ;; 1) continue ;;
        esac
        if ! claims=$(printf '%s' "$payload" | base64 -d 2>/dev/null); then continue; fi
        if ! jq -e --argjson now "$(date +%s)" '
            (.exp | type == "number") and .exp > $now and
            (.sub | type == "string" and startswith("system:serviceaccount:"))
        ' <<<"$claims" >/dev/null 2>&1; then continue; fi
        expires=true
        # Ask the API server to verify the signature, audience and current validity.
        # Supplying the token audience also supports custom-audience credentials.
        if ! review=$(jq -n --arg token "$token" --argjson claims "$claims" '
            {apiVersion:"authentication.k8s.io/v1", kind:"TokenReview",
             spec: {token:$token}} |
            if ($claims.aud | type) == "array" then .spec.audiences=$claims.aud
            elif ($claims.aud | type) == "string" then .spec.audiences=[$claims.aud]
            else . end
        ' | kubectl create -f - -o json 2>/dev/null); then continue; fi
        subject=$(jq -r '.sub' <<<"$claims")
        if jq -e --arg subject "$subject" '
            .status.authenticated == true and .status.user.username == $subject
        ' <<<"$review" >/dev/null; then
            authenticated=true
            printf 'Verified Pod %s, container %s, file %s\n' "$pod" "$container" "$path"
            break
        fi
    done < <(jq -r --argjson items "$items" '
        .data as $data |
        if ($items | length) > 0 then
            $items[] | select($data[.key] != null) | [.key, .path]
        else ($data // {} | keys[]) as $key | [$key, $key] end | @tsv
    ' <<<"$data")
    [[ $authenticated == true ]] && break
done < <(jq -r '
    .items[] | select(.metadata.deletionTimestamp == null) as $p |
    $p.spec.containers[] as $c |
    select(any($p.status.containerStatuses[]?; .name == $c.name and .state.running != null)) |
    $c.volumeMounts[]? as $m |
    $p.spec.volumes[]? | select(.name == $m.name) |
    .projected.sources[]?.secret | select(. != null) |
    [$p.metadata.name, $c.name, $m.mountPath,
     ($m.subPath // "-"), .name, ((.items // []) | tojson)] | @tsv
' <<<"$pods")

report "$mounted" 'A running container mounts a Secret through a projected volume'
report "$readable" 'The projected file is readable and matches its Secret data'
report "$expires" 'That file contains a ServiceAccount JWT with a future expiry'
report "$authenticated" 'The API server authenticates that unexpired mounted token'
if [[ $authenticated != true ]]; then
    echo 'Validation needs permission to read Pods/Secrets, exec cat, and create TokenReviews.'
fi
finish
