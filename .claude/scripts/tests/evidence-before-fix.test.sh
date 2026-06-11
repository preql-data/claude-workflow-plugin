#!/bin/bash
# evidence-before-fix.test.sh — spec 0.5 (claude-workflow-plugin-e0d.5).
#
# Asserts the evidence-before-fix protocol is present in qa.md and the
# three implementing specialists (backend.md, frontend.md, devops.md).
# The protocol is identified by two sentinel substrings that each agent
# file must carry:
#
#   1. "evidence mode" — the protocol's named mode for bug-typed tasks;
#      appears in the bounce-twice rule across all four files.
#   2. "symptom-patching" — the explicit anti-pattern name spec 0.5
#      asks the prompts to call out, so every specialist understands
#      what they are defending against.
#
# Using two sentinels (both must be present in every file) reduces the
# chance of a vacuous pass — a file that gestured at "evidence" without
# naming the anti-pattern would slip through a one-sentinel check.
#
# A future agent file added to the bug-fixing rotation without the
# protocol will cause this test to fail, which is the regression
# coverage spec 0.5 asks for.
#
# Includes a META-TEST that points the same checker at a fixture file
# missing both sentinels and asserts it correctly reports failure —
# proving the assertions are sensitive to the sentinels' presence, not
# vacuous.
#
# Exit codes:
#   0  every required file contains both sentinels AND the META-TEST
#      flags the broken fixture
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"

# Sentinels. Both must be present.
SENTINEL_MODE="evidence mode"
SENTINEL_ANTI="symptom-patching"

# The four files spec 0.5 names. We discover via list, not glob, because
# spec 0.5 specifically scopes to "qa.md AND all three implementation
# specialists" — a future orchestrator.md or grader.md does not need the
# bug-fix protocol (orchestrator never patches; grader is read-only).
REQUIRED_FILES=(
    "$AGENTS_DIR/qa.md"
    "$AGENTS_DIR/backend.md"
    "$AGENTS_DIR/frontend.md"
    "$AGENTS_DIR/devops.md"
)

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

# check_protocol <file> — exit 0 if the file contains BOTH sentinels;
# 1 if either is missing; 2 if the file doesn't exist. Fixed-string
# grep so whitespace and casing don't drift.
check_protocol() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return 2
    fi
    if ! grep -qF -- "$SENTINEL_MODE" "$f"; then
        return 1
    fi
    if ! grep -qF -- "$SENTINEL_ANTI" "$f"; then
        return 1
    fi
    return 0
}

# --- Real agents ----------------------------------------------------------

for f in "${REQUIRED_FILES[@]}"; do
    name=$(basename "$f" .md)
    if check_protocol "$f"; then
        rc=0
    else
        rc=$?
    fi
    assert_eq "evidence-before-fix: $name carries the protocol sentinels" "0" "$rc"
done

# --- META-TEST ------------------------------------------------------------

# Build a fixture agent file deliberately missing the sentinels, then
# call check_protocol on it. Expected outcome: rc=1 (sentinel absent).
# If check_protocol returns 0 anyway — e.g. someone changed the sentinel
# to a fuzzy pattern that matches generic prose — the META-TEST fails
# and the whole assertion is flagged as not actually sensitive.
META_TMP=$(mktemp -t evidence-before-fix.XXXXXX)
cat > "$META_TMP" <<'MD'
---
name: missing-protocol
description: stub agent without the evidence-before-fix block
tools: Read
model: claude-opus-4-7
---
You are a stub specialist.

Use extended thinking for all non-trivial work.

## TDD workflow

1. Write a failing test first.
2. Implement the minimal code to pass.
MD

# Soft assertions: the fixture must NOT inadvertently contain either
# sentinel. If it did, the META-TEST would be tautologically right.
if grep -qF -- "$SENTINEL_MODE" "$META_TMP"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST fixture inadvertently contains '$SENTINEL_MODE'")
    printf '  FAIL: META-TEST fixture inadvertently contains "%s"\n' "$SENTINEL_MODE"
elif grep -qF -- "$SENTINEL_ANTI" "$META_TMP"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST fixture inadvertently contains '$SENTINEL_ANTI'")
    printf '  FAIL: META-TEST fixture inadvertently contains "%s"\n' "$SENTINEL_ANTI"
else
    if check_protocol "$META_TMP"; then
        rc_meta=0
    else
        rc_meta=$?
    fi
    # rc=1 is the expected "sentinel missing" result; rc=2 would mean the
    # tempfile vanished, which is a fixture bug rather than the behaviour
    # the META-TEST asserts.
    assert_eq "META-TEST: checker flags missing-protocol fixture" "1" "$rc_meta"
fi

rm -f "$META_TMP"

# --- Summary -------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0
