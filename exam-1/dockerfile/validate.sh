#!/usr/bin/env bash
set -u

LAB_DIR="/root/cks-lab-q2"

DOCKERFILE="${LAB_DIR}/Dockerfile"
DEPLOYMENT="${LAB_DIR}/deployment.yaml"

PASS=0
FAIL=0


pass() {
    echo "[PASS] $1"
    PASS=$((PASS + 1))
}


fail() {
    echo "[FAIL] $1"
    FAIL=$((FAIL + 1))
}


echo
echo "================================================="
echo " CKS LAB 02 - VALIDATION"
echo "================================================="


# ============================================================
# Dockerfile
# ============================================================

echo
echo "---- PART 1 : DOCKERFILE -------------------------"


if [[ ! -f "$DOCKERFILE" ]]; then
    fail "Dockerfile exists"
else

    FROM_LINE="$(
        grep -Ei '^[[:space:]]*FROM[[:space:]]+' "$DOCKERFILE" |
        head -1
    )"

    BASE_IMAGE="$(
        echo "$FROM_LINE" |
        awk '{print $2}'
    )"


    # Pinned base image
    if [[ -n "$BASE_IMAGE" ]] &&
       [[ "$BASE_IMAGE" == *:* ]] &&
       [[ "$BASE_IMAGE" != *":latest" ]]; then

        pass "Base image uses a specific tag"

    else

        fail "Base image is not pinned to a specific tag"

    fi


    # USER
    USER_VALUE="$(
        grep -Ei '^[[:space:]]*USER[[:space:]]+' "$DOCKERFILE" |
        tail -1 |
        awk '{print $2}'
    )"

    if [[ -n "$USER_VALUE" ]] &&
       [[ "$USER_VALUE" != "root" ]] &&
       [[ "$USER_VALUE" != "0" ]]; then

        pass "Container is configured to run as non-root"

    else

        fail "Container is still configured to run as root"

    fi


    # COPY
    if grep -Eiq \
        '^[[:space:]]*COPY[[:space:]]+.*app\.tar\.gz' \
        "$DOCKERFILE"; then

        pass "COPY is used for app.tar.gz"

    else

        fail "COPY is not used for app.tar.gz"

    fi


    # ADD must be absent
    if grep -Eiq \
        '^[[:space:]]*ADD[[:space:]]+' \
        "$DOCKERFILE"; then

        fail "Dockerfile still contains ADD"

    else

        pass "Dockerfile does not use ADD"

    fi

fi


# ============================================================
# Deployment
# ============================================================

echo
echo "---- PART 2 : DEPLOYMENT -------------------------"


if [[ ! -f "$DEPLOYMENT" ]]; then

    fail "deployment.yaml exists"

else

    # Validate YAML structure with kubectl if available
    if command -v kubectl >/dev/null 2>&1; then

        if kubectl create \
            --dry-run=client \
            --validate=false \
            -f "$DEPLOYMENT" \
            -o json >/tmp/cks-q2-deployment.json 2>/dev/null; then

            pass "deployment.yaml is valid Kubernetes YAML"

        else

            fail "deployment.yaml is not valid Kubernetes YAML"

        fi

    fi


    # privileged true must not remain
    if grep -Eiq \
        '^[[:space:]]*privileged:[[:space:]]*true[[:space:]]*$' \
        "$DEPLOYMENT"; then

        fail "Privileged access is still enabled"

    else

        pass "Privileged access is disabled"

    fi


    # capabilities section
    if grep -Eiq \
        '^[[:space:]]*capabilities:[[:space:]]*$' \
        "$DEPLOYMENT"; then

        pass "Linux capabilities configuration exists"

    else

        fail "Linux capabilities configuration is missing"

    fi


    # drop ALL
    if grep -Eq \
        '^[[:space:]]*-[[:space:]]*["'\'']?ALL["'\'']?[[:space:]]*$' \
        "$DEPLOYMENT" ||
       grep -Eiq \
        'drop:[[:space:]]*\[[[:space:]]*["'\'']?ALL["'\'']?[[:space:]]*\]' \
        "$DEPLOYMENT"; then

        pass "All Linux capabilities are dropped"

    else

        fail "Linux capabilities ALL are not dropped"

    fi

fi


# ============================================================
# Result
# ============================================================

echo
echo "================================================="
echo " RESULT"
echo "================================================="
echo
echo "PASS : $PASS"
echo "FAIL : $FAIL"
echo


if [[ "$FAIL" -eq 0 ]]; then

    echo "RESULT: SUCCESS"
    echo
    echo "Lab completed successfully."
    exit 0

else

    echo "RESULT: FAILED"
    echo
    echo "Some objectives are not yet satisfied."
    exit 1

fi
