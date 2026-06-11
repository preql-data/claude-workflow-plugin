#!/bin/bash
# worktree-isolation.test.sh — spec 0.6 (claude-workflow-plugin-e0d.6).
#
# Two assertions and a META-TEST:
#
#   1. orchestrator.md contains the parallel-isolation rule. We assert
#      the literal phrase "isolated worktree" plus the documented
#      mechanism token `isolation: "worktree"`. Both must be present;
#      one alone could be hand-wave prose.
#
#   2. `.worktreeinclude` exists at repo root and is non-empty (after
#      stripping comments and blank lines, there is at least one real
#      pattern line). An empty file would silently disable the
#      worktree-copy mechanism the spec depends on.
#
# META-TEST: a fixture orchestrator file without the rule must fail
# the check (proves the assertion is sensitive); a fixture
# `.worktreeinclude` containing only comments must fail the non-empty
# check (proves the comment-stripping logic is real).
#
# Exit codes:
#   0  all assertions pass and the META-TESTs flag the broken fixtures
#   1  one or more assertions failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
ORCHESTRATOR="$PROJECT_DIR/.claude/agents/orchestrator.md"
WORKTREE_INCLUDE="$PROJECT_DIR/.worktreeinclude"

# Sentinels. The mechanism token is the verified parameter spelling
# from code.claude.com/docs/en/sub-agents.
SENTINEL_PHRASE="isolated worktree"
SENTINEL_MECHANISM='isolation: "worktree"'

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

# check_orchestrator <file> — exit 0 if BOTH sentinels are present;
# 1 if either is missing; 2 if the file doesn't exist.
check_orchestrator() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return 2
    fi
    if ! grep -qF -- "$SENTINEL_PHRASE" "$f"; then
        return 1
    fi
    if ! grep -qF -- "$SENTINEL_MECHANISM" "$f"; then
        return 1
    fi
    return 0
}

# check_worktreeinclude <file> — exit 0 if the file exists AND has
# at least one non-comment non-blank line; 1 if empty or comments-only;
# 2 if the file doesn't exist.
check_worktreeinclude() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return 2
    fi
    # Strip comments and whitespace; count remaining non-empty lines.
    local real_lines
    real_lines=$(sed 's/#.*$//' "$f" | grep -cE '[^[:space:]]')
    if [ "$real_lines" -gt 0 ]; then
        return 0
    fi
    return 1
}

# --- Assertion 1: orchestrator.md carries the rule ------------------------

if check_orchestrator "$ORCHESTRATOR"; then
    rc=0
else
    rc=$?
fi
assert_eq "worktree-isolation: orchestrator.md carries the parallel-isolation rule" "0" "$rc"

# --- Assertion 2: .worktreeinclude exists and is non-empty ---------------

if check_worktreeinclude "$WORKTREE_INCLUDE"; then
    rc=0
else
    rc=$?
fi
assert_eq "worktree-isolation: .worktreeinclude exists and has patterns" "0" "$rc"

# --- META-TEST: orchestrator fixture missing the rule --------------------

META_ORC=$(mktemp -t worktree-isolation-orc.XXXXXX)
cat > "$META_ORC" <<'MD'
---
name: orchestrator
description: stub orchestrator without the worktree rule
tools: Task
model: claude-opus-4-7
---
You are the orchestrator. Delegate to specialists with Task().
MD

# Soft-check the fixture itself does not happen to contain the sentinels.
if grep -qF -- "$SENTINEL_PHRASE" "$META_ORC" || grep -qF -- "$SENTINEL_MECHANISM" "$META_ORC"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST orchestrator fixture inadvertently contains a sentinel")
    printf '  FAIL: META-TEST orchestrator fixture inadvertently contains a sentinel\n'
else
    if check_orchestrator "$META_ORC"; then
        rc_meta=0
    else
        rc_meta=$?
    fi
    assert_eq "META-TEST: checker flags orchestrator without isolation rule" "1" "$rc_meta"
fi

rm -f "$META_ORC"

# --- META-TEST: .worktreeinclude fixture with only comments --------------

META_WI=$(mktemp -t worktree-isolation-wi.XXXXXX)
cat > "$META_WI" <<'WI'
# this fixture has no real patterns, only comments and blanks

# trailing comment
WI

if check_worktreeinclude "$META_WI"; then
    rc_meta=0
else
    rc_meta=$?
fi
assert_eq "META-TEST: checker flags comments-only .worktreeinclude" "1" "$rc_meta"

rm -f "$META_WI"

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
