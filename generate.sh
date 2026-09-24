#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# CKS Lab Generator
#
# Examples:
#   ./generate.sh --all
#   ./generate.sh exam-2
#   ./generate.sh exam-2/3-AppArmor
#   ./generate.sh --review exam-2/3-AppArmor
#   ./generate.sh --review exam-2
#   ./generate.sh --force exam-2/3-AppArmor
#   ./generate.sh --force --review exam-2/3-AppArmor
#   ./generate.sh --status
#
# Default:
#   - generate missing/incomplete labs
#   - skip complete labs
#   - NO independent Codex review
#
# --review:
#   - enable a second Codex pass after generation
#
# --force:
#   - regenerate even when setup.sh + validate.sh already exist
# ============================================================

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_ROOT="$ROOT/.generation-logs"

FORCE=false
STATUS=false
REVIEW=false
TARGET=""

# Global flag set when Codex reports an exhausted usage quota.
USAGE_LIMIT_REACHED=false


# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

usage() {
    cat <<'USAGE'
Usage:

  ./generate.sh --all
  ./generate.sh exam-2
  ./generate.sh exam-2/3-AppArmor

Optional:

  ./generate.sh --review --all
  ./generate.sh --review exam-2
  ./generate.sh --review exam-2/3-AppArmor

  ./generate.sh --force exam-2/3-AppArmor
  ./generate.sh --force --review exam-2/3-AppArmor

  ./generate.sh --status

Options:

  --all
      Process every exercise containing task.txt.

  --review
      Enable an independent second Codex review pass.
      Disabled by default to reduce Codex usage.

  --force
      Regenerate setup.sh and validate.sh even when both
      already exist.

  --status
      Display repository generation status only.

  -h, --help
      Display this help.

Default behavior:

  - Complete labs are skipped.
  - A complete lab contains both setup.sh and validate.sh.
  - Missing/incomplete labs are generated.
  - Generated scripts are checked with bash -n.
  - Codex review is NOT executed unless --review is specified.
  - If the Codex usage limit is reached, generation stops
    immediately and can safely be resumed later.
USAGE
}


die() {
    echo "[ERROR] $*" >&2
    exit 1
}


relative() {
    local path="$1"
    printf '%s\n' "${path#"$ROOT"/}"
}


safe_name() {
    printf '%s' "$1" |
        tr '/ ' '__' |
        tr -cd '[:alnum:]_.-'
}


check_environment() {
    command -v codex >/dev/null 2>&1 ||
        die "codex is not installed or not in PATH."

    [[ -f "$ROOT/AGENTS.md" ]] ||
        die "$ROOT/AGENTS.md not found."

    mkdir -p "$LOG_ROOT"
}


is_usage_limit() {
    local logfile="$1"

    [[ -f "$logfile" ]] || return 1

    grep -aqiE \
        "You've hit your usage limit|usage limit reached|usage limit|rate limit exceeded" \
        "$logfile"
}


# ------------------------------------------------------------
# Status
# ------------------------------------------------------------

show_status() {
    local total=0
    local complete=0
    local partial=0
    local missing=0

    echo "================================================="
    echo " CKS LAB GENERATION STATUS"
    echo "================================================="
    echo

    while IFS= read -r -d '' task; do

        local dir
        dir="$(dirname "$task")"

        total=$((total + 1))

        if [[ -f "$dir/setup.sh" &&
              -f "$dir/validate.sh" ]]; then

            complete=$((complete + 1))
            printf '[COMPLETE] %s\n' "$(relative "$dir")"

        elif [[ -f "$dir/setup.sh" ||
                -f "$dir/validate.sh" ]]; then

            partial=$((partial + 1))
            printf '[PARTIAL ] %s\n' "$(relative "$dir")"

        else

            missing=$((missing + 1))
            printf '[MISSING ] %s\n' "$(relative "$dir")"

        fi

    done < <(
        find "$ROOT"/exam-* \
            -type f \
            -name task.txt \
            -print0 2>/dev/null |
        sort -z
    )

    echo
    echo "-------------------------------------------------"
    echo "Total    : $total"
    echo "Complete : $complete"
    echo "Partial  : $partial"
    echo "Missing  : $missing"
    echo "-------------------------------------------------"
}


# ------------------------------------------------------------
# Task discovery
# ------------------------------------------------------------

resolve_tasks() {
    local target="$1"

    if [[ "$target" == "--all" ]]; then

        find "$ROOT"/exam-* \
            -type f \
            -name task.txt \
            -print0 2>/dev/null |
        sort -z

        return
    fi

    local path

    if [[ "$target" = /* ]]; then
        path="$target"
    else
        path="$ROOT/$target"
    fi

    [[ -e "$path" ]] ||
        die "Target does not exist: $target"

    # Direct task.txt
    if [[ -f "$path" ]]; then

        [[ "$(basename "$path")" == "task.txt" ]] ||
            die "File target must be task.txt: $target"

        printf '%s\0' "$path"
        return
    fi

    # Exercise directory
    if [[ -f "$path/task.txt" ]]; then
        printf '%s\0' "$path/task.txt"
        return
    fi

    # Exam/directory containing several exercises
    find "$path" \
        -type f \
        -name task.txt \
        -print0 |
    sort -z
}


# ------------------------------------------------------------
# Static validation
# ------------------------------------------------------------

static_check() {
    local dir="$1"

    [[ -f "$dir/setup.sh" ]] || {
        echo "[ERROR] setup.sh missing." >&2
        return 1
    }

    [[ -f "$dir/validate.sh" ]] || {
        echo "[ERROR] validate.sh missing." >&2
        return 1
    }

    bash -n "$dir/setup.sh"
    bash -n "$dir/validate.sh"

    chmod +x \
        "$dir/setup.sh" \
        "$dir/validate.sh"
}


# ------------------------------------------------------------
# Generator
# ------------------------------------------------------------

run_generator() {
    local dir="$1"
    local logfile="$2"

    local rc=0

    codex exec \
        -C "$dir" \
        --approve-for-me \
        --ephemeral \
        --color never \
        'Read task.txt completely and follow the repository AGENTS.md instructions.

Inspect all relevant supporting files in this exercise directory.

Generate setup.sh and validate.sh for this CKS exercise.

Important rules:

- This development machine is NOT the Kubernetes playground.
- Do not execute setup.sh.
- Do not execute validate.sh.
- Do not run kubectl against a real cluster.
- Do not SSH to controlplane or node01.
- Do not restart system services on this machine.
- Do not install lab software on this machine.
- Only write the scripts and perform safe static checks.

setup.sh:
- will later run as root on controlplane
- may SSH to node01 when worker preparation is required
- must prepare the initial scenario
- must not solve the task
- must not reveal the solution
- should make the smallest practical changes
- should preserve unrelated playground configuration
- should be safely resettable/idempotent where practical

validate.sh:
- must never repair the solution
- must validate the actual task objectives
- should prefer effective/runtime state when meaningful
- must accept realistic equivalent solutions
- must avoid implementation-specific false negatives
- should remain as simple as reasonably possible

The requirements in the Question/task are authoritative.
Embedded Solution sections are contextual hints only and may contain mistakes.

Before finishing:
- re-read task.txt
- ensure every task requirement is covered
- ensure setup.sh does not solve the task
- ensure validate.sh does not silently repair anything
- run only safe static syntax checks such as bash -n
- ensure setup.sh and validate.sh are executable.' \
        </dev/null \
        >"$logfile" 2>&1 || rc=$?

    if is_usage_limit "$logfile"; then
        USAGE_LIMIT_REACHED=true
        return 20
    fi

    return "$rc"
}


# ------------------------------------------------------------
# Reviewer
# ------------------------------------------------------------

run_reviewer() {
    local dir="$1"
    local logfile="$2"

    local rc=0

    codex exec \
        -C "$dir" \
        --approve-for-me \
        --ephemeral \
        --color never \
        'Act as a strict reviewer of this generated CKS lab.

Read:

- task.txt
- repository AGENTS.md
- setup.sh
- validate.sh
- relevant supporting files

Review the generated scripts for:

1. setup.sh accidentally solving or revealing the task.
2. Missing task requirements.
3. Incorrect assumptions about controlplane or node01.
4. Destructive or unnecessarily invasive configuration changes.
5. Missing prerequisites.
6. Avoidable version-specific assumptions.
7. validate.sh false positives.
8. validate.sh false negatives.
9. Validation tied to one implementation instead of the required outcome.
10. Missing runtime/effective-state validation where materially useful.
11. Unnecessary validator complexity.
12. Idempotency/reset problems.
13. Unsafe simulations.
14. Dependencies installed only for implementation convenience.
15. Changes to unrelated playground resources.

If a real issue exists, directly correct setup.sh and/or validate.sh.

Do not modify task.txt.
Do not modify solution.txt.
Do not execute setup.sh.
Do not execute validate.sh.
Do not run kubectl.
Do not SSH to nodes.
Do not run systemctl.
Do not modify the current development host.

Only perform static analysis and safe static syntax checks.

If the scripts are already correct, leave them unchanged.

Finish with safe checks such as:

bash -n setup.sh
bash -n validate.sh' \
        </dev/null \
        >"$logfile" 2>&1 || rc=$?

    if is_usage_limit "$logfile"; then
        USAGE_LIMIT_REACHED=true
        return 20
    fi

    return "$rc"
}


# ------------------------------------------------------------
# Process one lab
# ------------------------------------------------------------

generate_lab() {
    local task="$1"

    local dir
    local rel
    local log_name
    local gen_log
    local review_log
    local rc

    dir="$(dirname "$task")"
    rel="$(relative "$dir")"

    log_name="$(safe_name "$rel")"

    gen_log="$LOG_ROOT/${log_name}.generate.log"
    review_log="$LOG_ROOT/${log_name}.review.log"

    echo
    echo "================================================="
    echo " LAB: $rel"
    echo "================================================="

    # --------------------------------------------------------
    # Missing-only behavior
    # --------------------------------------------------------

    if [[ "$FORCE" == false &&
          -f "$dir/setup.sh" &&
          -f "$dir/validate.sh" ]]; then

        echo "[SKIP] setup.sh and validate.sh already exist."
        return 10
    fi

    if [[ "$FORCE" == true ]]; then
        echo "[INFO] Force regeneration enabled."

    elif [[ -f "$dir/setup.sh" ||
            -f "$dir/validate.sh" ]]; then

        echo "[INFO] Incomplete lab detected."
        echo "[INFO] Codex will complete/regenerate the scripts."
    fi

    # --------------------------------------------------------
    # Generator
    # --------------------------------------------------------

    if [[ "$REVIEW" == true ]]; then
        echo "[1/4] Generator"
    else
        echo "[1/3] Generator"
    fi

    set +e
    run_generator "$dir" "$gen_log"
    rc=$?
    set -e

    if (( rc == 20 )); then

        echo "[LIMIT] Codex usage limit reached."
        echo "        Log: $(relative "$gen_log")"

        return 20

    elif (( rc != 0 )); then

        echo "[FAIL] Generator failed (exit $rc)."
        echo "       Log: $(relative "$gen_log")"

        return 1
    fi

    # --------------------------------------------------------
    # Initial static validation
    # --------------------------------------------------------

    if [[ "$REVIEW" == true ]]; then
        echo "[2/4] Static validation"
    else
        echo "[2/3] Static validation"
    fi

    if ! static_check "$dir"; then

        echo "[FAIL] Generated scripts failed static validation."
        echo "       Generator log: $(relative "$gen_log")"

        return 1
    fi

    echo "[PASS] Static validation"

    # --------------------------------------------------------
    # Optional reviewer
    # --------------------------------------------------------

    if [[ "$REVIEW" == true ]]; then

        echo "[3/4] Independent review"

        set +e
        run_reviewer "$dir" "$review_log"
        rc=$?
        set -e

        if (( rc == 20 )); then

            echo "[LIMIT] Codex usage limit reached during review."
            echo "        Generated scripts have been preserved."
            echo "        Log: $(relative "$review_log")"

            return 20

        elif (( rc != 0 )); then

            echo "[FAIL] Reviewer failed (exit $rc)."
            echo "       Review log: $(relative "$review_log")"

            return 1
        fi

        echo "[4/4] Final validation"

        if ! static_check "$dir"; then

            echo "[FAIL] Scripts invalid after review."
            echo "       Review log: $(relative "$review_log")"

            return 1
        fi

        echo "[PASS] Review completed"

    else

        echo "[3/3] Independent review skipped"
    fi

    echo
    echo "[PASS] $rel"
    echo "       setup.sh"
    echo "       validate.sh"

    return 0
}


# ============================================================
# Argument parsing
# ============================================================

while [[ $# -gt 0 ]]; do

    case "$1" in

        --force)
            FORCE=true
            shift
            ;;

        --review)
            REVIEW=true
            shift
            ;;

        --status)
            STATUS=true
            shift
            ;;

        --all)
            [[ -z "$TARGET" ]] ||
                die "Only one target may be specified."

            TARGET="--all"
            shift
            ;;

        -h|--help)
            usage
            exit 0
            ;;

        -*)
            die "Unknown option: $1"
            ;;

        *)
            [[ -z "$TARGET" ]] ||
                die "Only one target may be specified."

            TARGET="$1"
            shift
            ;;

    esac

done


# ============================================================
# Environment
# ============================================================

check_environment


# ============================================================
# Status-only mode
# ============================================================

if [[ "$STATUS" == true ]]; then
    show_status
    exit 0
fi


# ============================================================
# Require target
# ============================================================

[[ -n "$TARGET" ]] || {
    usage
    exit 1
}


# ============================================================
# Discover all tasks BEFORE invoking Codex.
#
# Important:
# Codex must never receive the find/read stream as stdin.
# ============================================================

TASKS=()

while IFS= read -r -d '' task; do
    TASKS+=("$task")
done < <(resolve_tasks "$TARGET")

TOTAL="${#TASKS[@]}"

if (( TOTAL == 0 )); then
    die "No task.txt found for target: $TARGET"
fi


# ============================================================
# Discovery summary
# ============================================================

echo
echo "================================================="
echo " TASK DISCOVERY"
echo "================================================="
echo "Tasks selected : $TOTAL"

if [[ "$REVIEW" == true ]]; then
    echo "Review         : ENABLED"
else
    echo "Review         : DISABLED"
fi

if [[ "$FORCE" == true ]]; then
    echo "Force          : ENABLED"
else
    echo "Force          : DISABLED"
fi

echo "================================================="


# ============================================================
# Generation loop
# ============================================================

GENERATED=0
SKIPPED=0
FAILED=0
PROCESSED=0
PAUSED=false

for task in "${TASKS[@]}"; do

    PROCESSED=$((PROCESSED + 1))

    set +e
    generate_lab "$task"
    rc=$?
    set -e

    case "$rc" in

        0)
            GENERATED=$((GENERATED + 1))
            ;;

        10)
            SKIPPED=$((SKIPPED + 1))
            ;;

        20)
            PAUSED=true

            echo
            echo "================================================="
            echo " CODEX USAGE LIMIT REACHED"
            echo "================================================="
            echo
            echo "Generation has been paused."
            echo
            echo "Already generated labs are preserved."
            echo "Complete labs will be skipped on the next run."
            echo
            echo "Resume later with:"
            echo
            echo "  ./generate.sh $TARGET"
            echo
            echo "================================================="

            break
            ;;

        *)
            FAILED=$((FAILED + 1))
            ;;

    esac

done


# ============================================================
# Final summary
# ============================================================

REMAINING=$((TOTAL - PROCESSED))

# If the current lab stopped because of usage limit,
# it may also need to be revisited. This number is therefore
# informational rather than a strict "missing labs" count.

echo
echo "================================================="
echo " GENERATION SUMMARY"
echo "================================================="
echo "Selected  : $TOTAL"
echo "Processed : $PROCESSED"
echo "Generated : $GENERATED"
echo "Skipped   : $SKIPPED"
echo "Failed    : $FAILED"

if [[ "$PAUSED" == true ]]; then
    echo "Status    : PAUSED - CODEX USAGE LIMIT"
else
    echo "Status    : COMPLETED"
fi

echo "================================================="


# ============================================================
# Exit handling
# ============================================================

if [[ "$PAUSED" == true ]]; then
    echo
    echo "Wait for the Codex usage reset, then rerun:"
    echo
    echo "  ./generate.sh $TARGET"
    echo

    exit 20
fi


if (( FAILED > 0 )); then

    echo
    echo "Some labs failed."
    echo
    echo "Inspect logs in:"
    echo
    echo "  $LOG_ROOT"

    exit 1
fi


echo
echo "Generation completed successfully."