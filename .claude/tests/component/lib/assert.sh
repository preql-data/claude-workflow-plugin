#!/bin/bash
# assert.sh - Reusable test assertions for the L2 component tier.
#
# Phase B (claude-workflow-plugin-0wk.11). These helpers are the source of
# truth extracted from bd-github-link.test.sh:41-63 and the equivalent
# block at phase5-synthetic-tests.sh:31-53. Specs source this file (the
# component runner does it automatically) and update the shared counters
# PASS / FAIL / FAILED_TESTS in the caller's shell.
#
# Contract for specs:
#   - Declare integer PASS/FAIL up front (the runner sets them per-spec).
#   - Declare FAILED_TESTS as an array (used to print failing names at end).
#   - Use the helpers below; never call jq/grep inline. This keeps the
#     PASS/FAIL accounting consistent across the whole tier.
#
# Helpers:
#   assert_eq       <name> <expected> <actual>
#   assert_match    <name> <pattern>  <actual>     # extended regex
#   assert_contains <name> <substring> <actual>    # plain substring
#   assert_json_field <name> <json> <jq-path> <expected>
#
# Each helper bumps PASS or FAIL exactly once. Failures print expected/actual
# (or pattern/actual) lines so the runner output is greppable.

# Source-guard: tolerate being sourced multiple times.
if [ -n "${__COMPONENT_ASSERT_SH_SOURCED:-}" ]; then
    return 0 2>/dev/null || true
fi
__COMPONENT_ASSERT_SH_SOURCED=1

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

assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' \
            "$name" "$pattern" "$actual"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    # Use plain fixed-string grep so callers can pass any text without
    # worrying about regex escapes.
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

assert_json_field() {
    # assert_json_field <name> <json> <jq-path> <expected>
    # Extracts a field via jq and asserts equality. Empty / null jq output
    # becomes the literal empty string for the comparison.
    local name="$1" json="$2" path="$3" expected="$4"
    if ! command -v jq >/dev/null 2>&1; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    jq missing on PATH\n' "$name"
        return
    fi
    local actual
    actual=$(printf '%s' "$json" | jq -r "$path // empty" 2>/dev/null || echo "")
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    path:     %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$path" "$expected" "$actual"
    fi
}
