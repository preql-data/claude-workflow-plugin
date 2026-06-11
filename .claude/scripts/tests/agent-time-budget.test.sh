#!/bin/bash
# agent-time-budget.test.sh — spec 0.4 (claude-workflow-plugin-e0d.4).
#
# Asserts every agent prompt under .claude/agents/ carries the shared
# time-budget block. The block is identified by the sentinel substring
# "Depth beats speed" (the rare phrase from principle 3, unlikely to
# appear by accident elsewhere). A future agent file added without the
# block will cause this test to fail, which is the regression coverage
# the spec asks for.
#
# Includes a META-TEST that points the same checker at a fixture file
# lacking the block and asserts it correctly reports failure — proving
# the assertion is sensitive to the block's presence, not vacuous.
#
# Exit codes:
#   0  every agent file contains the sentinel AND the META-TEST flags
#      the broken fixture
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"
SENTINEL="Depth beats speed"

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

# check_block <file> — exit 0 if the file contains the sentinel; 1 if
# not. Plain fixed-string grep so the assertion is whitespace-tolerant.
check_block() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return 2
    fi
    if grep -qF -- "$SENTINEL" "$f"; then
        return 0
    fi
    return 1
}

# --- Real agents ----------------------------------------------------------

# Discover every .md under .claude/agents and check each. We rely on
# discovery (not a hardcoded list) so the next agent we ship is covered
# automatically — including grader.md when Phase A lands.
SHELL_OPT_NULLGLOB=$(shopt -p nullglob)
shopt -s nullglob
AGENT_FILES=("$AGENTS_DIR"/*.md)
eval "$SHELL_OPT_NULLGLOB"

if [ "${#AGENT_FILES[@]}" -eq 0 ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("no agent files discovered")
    printf '  FAIL: no agent files discovered under %s\n' "$AGENTS_DIR"
else
    for f in "${AGENT_FILES[@]}"; do
        name=$(basename "$f" .md)
        if check_block "$f"; then
            rc=0
        else
            rc=1
        fi
        assert_eq "agent-time-budget: $name carries the time-budget block" "0" "$rc"
    done
fi

# --- META-TEST ------------------------------------------------------------

# Build a fixture agent file deliberately missing the block, then call
# check_block on it. The expected outcome is rc=1 (sentinel absent). If
# check_block happens to return 0 anyway — e.g. someone changed the
# sentinel to a fuzzy pattern that matches generic prose — the META-TEST
# fails and the whole assertion is flagged as not actually sensitive.
META_TMP=$(mktemp -t agent-time-budget.XXXXXX)
cat > "$META_TMP" <<'MD'
---
name: missing-block
description: stub agent without the time-budget block
tools: Read
model: claude-opus-4-7
---
You are a stub specialist.

Use extended thinking for all non-trivial work.
MD

# The fixture also must NOT inadvertently contain the sentinel via the
# block-comment, so we add a soft assertion confirming that.
if grep -qF -- "$SENTINEL" "$META_TMP"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST fixture is not actually missing the sentinel — fix the fixture")
    printf '  FAIL: META-TEST fixture inadvertently contains the sentinel\n'
else
    if check_block "$META_TMP"; then
        rc_meta=0
    else
        rc_meta=1
    fi
    assert_eq "META-TEST: checker flags missing-block fixture" "1" "$rc_meta"
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
