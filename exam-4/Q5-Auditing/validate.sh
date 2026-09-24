#!/usr/bin/env bash
set -Eeuo pipefail

# Q5 - Kubernetes Auditing
#
# Requirement:
#   Create an audit policy that logs Metadata for ALL Secrets.
#
# Only the audit policy is validated.
# kube-apiserver activation, audit log destination and retention are outside
# the scope of this validator.
#
# Usage:
#   ./validate.sh [policy-file]

policy=${1:-/root/cks-q5-auditing/audit-policy.yaml}

PASS=0
FAIL=0

ok() {
    printf '[PASS] %s\n' "$*"
    PASS=$((PASS + 1))
}

bad() {
    printf '[FAIL] %s\n' "$*"
    FAIL=$((FAIL + 1))
}

finish() {
    printf '\nTotals: %s passed, %s failed\n' "$PASS" "$FAIL"

    if (( FAIL == 0 )); then
        echo 'RESULT: SUCCESS'
        exit 0
    fi

    echo 'RESULT: FAILED'
    exit 1
}

if [[ $# -gt 1 ]]; then
    bad 'Usage: ./validate.sh [policy-file]'
    finish
fi

if ! command -v python3 >/dev/null 2>&1; then
    bad 'Python 3 is available'
    finish
fi

if ! python3 -c 'import yaml' >/dev/null 2>&1; then
    bad 'Python PyYAML module is available'
    finish
fi

if [[ ! -f "$policy" ]]; then
    bad "Audit policy exists: $policy"
    finish
fi

python3 - "$policy" <<'PY'
import sys
import yaml

policy_file = sys.argv[1]

passed = 0
failed = 0


def report(result, message):
    global passed, failed

    if result:
        print(f"[PASS] {message}")
        passed += 1
    else:
        print(f"[FAIL] {message}")
        failed += 1


#
# Reject duplicate YAML keys.
#
class UniqueKeyLoader(yaml.SafeLoader):
    pass


def construct_mapping(loader, node, deep=False):
    mapping = {}

    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)

        if key in mapping:
            raise ValueError(f"duplicate YAML key: {key}")

        mapping[key] = loader.construct_object(value_node, deep=deep)

    return mapping


UniqueKeyLoader.add_constructor(
    yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG,
    construct_mapping,
)


#
# Load and perform basic structural validation.
#
try:
    with open(policy_file, encoding="utf-8") as stream:
        policy = yaml.load(stream, Loader=UniqueKeyLoader)

    if not isinstance(policy, dict):
        raise ValueError("policy must be a YAML object")

    if policy.get("apiVersion") != "audit.k8s.io/v1":
        raise ValueError("apiVersion must be audit.k8s.io/v1")

    if policy.get("kind") != "Policy":
        raise ValueError("kind must be Policy")

    rules = policy.get("rules")

    if not isinstance(rules, list):
        raise ValueError("rules must be a list")

    valid_levels = {
        "None",
        "Metadata",
        "Request",
        "RequestResponse",
    }

    for number, rule in enumerate(rules, 1):

        if not isinstance(rule, dict):
            raise ValueError(f"rule {number} must be an object")

        if rule.get("level") not in valid_levels:
            raise ValueError(
                f"rule {number} has invalid audit level"
            )

        resources = rule.get("resources", [])

        if resources is not None and not isinstance(resources, list):
            raise ValueError(
                f"rule {number}: resources must be a list"
            )

        for resource in resources or []:

            if not isinstance(resource, dict):
                raise ValueError(
                    f"rule {number}: invalid resource selector"
                )

            group = resource.get("group", "")

            if not isinstance(group, str):
                raise ValueError(
                    f"rule {number}: resource group must be a string"
                )

            names = resource.get("resources", [])

            if names is not None:
                if (
                    not isinstance(names, list)
                    or any(not isinstance(x, str) for x in names)
                ):
                    raise ValueError(
                        f"rule {number}: resources must contain strings"
                    )

    report(True, "Audit policy parses with valid rule fields")

except (OSError, ValueError, TypeError, yaml.YAMLError) as exc:
    report(False, f"Cannot read a valid audit policy: {exc}")

    print(f"\nTotals: {passed} passed, {failed} failed")
    print("RESULT: FAILED")
    sys.exit(1)


#
# Q5 requirement:
#
#     Log Metadata for ALL Secrets.
#
# Kubernetes audit rules use first-match semantics.
#
# We therefore walk the rules in order and look for the first rule that
# universally covers Secret requests.
#
# A rule universally covers Secrets when:
#
#   - it is a resource rule
#   - core API group is selected
#   - secrets (or *) is selected
#   - there are no restrictions on:
#       users
#       userGroups
#       verbs
#       namespaces
#       resourceNames
#
# If a previous rule already universally selects Secrets at another level,
# the policy cannot satisfy the requirement because first-match wins.
#

found = False
problem = None

for number, rule in enumerate(rules, 1):

    #
    # nonResourceURLs rules do not apply to Secret resources.
    #
    if rule.get("nonResourceURLs"):
        continue

    resources = rule.get("resources") or []

    for resource in resources:

        group = resource.get("group", "")

        if group not in ("", "*"):
            continue

        names = resource.get("resources") or []

        if "secrets" not in names and "*" not in names:
            continue

        #
        # Determine whether this rule covers ALL Secret requests.
        #
        restricted = any(
            rule.get(field)
            for field in (
                "users",
                "userGroups",
                "verbs",
                "namespaces",
            )
        )

        if resource.get("resourceNames"):
            restricted = True

        if restricted:
            #
            # This rule only covers part of the Secret request space.
            # Continue looking for a general rule.
            #
            continue

        #
        # This is the first unrestricted rule encountered that applies
        # to every Secret request.
        #
        if rule.get("level") == "Metadata":
            found = True
        else:
            problem = (
                f"Rule {number} matches all Secret requests at "
                f'{rule.get("level")} level before a Metadata rule'
            )

        break

    if found or problem:
        break


if problem:
    report(False, problem)

elif found:
    report(
        True,
        "All Secret requests are logged at Metadata level",
    )

else:
    report(
        False,
        "No Metadata rule covers all Secret requests",
    )


print(f"\nTotals: {passed} passed, {failed} failed")

if failed:
    print("RESULT: FAILED")
    sys.exit(1)

print("RESULT: SUCCESS")
PY