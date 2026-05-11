#!/bin/bash
# run.sh - Component-tier test runner.
#
# Phase B (claude-workflow-plugin-0wk.11). Mirrors the L1 runner at
# .claude/scripts/tests/run-tests.sh but discovers specs under
# .claude/tests/component/specs/*.sh and pre-sources the lib/ helpers
# (assert.sh, shim.sh, hook-envelope.sh, fixture.sh) into each spec's
# shell so specs can call mk_fixture / mk_shim / assert_eq directly.
#
# Usage:
#   bash .claude/tests/component/run.sh
#   bash .claude/tests/component/run.sh --filter <pattern>
#
# Exit codes:
#   0  every spec passed
#   1  one or more specs failed
#   2  invocation error (no specs found, jq missing)

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
COMPONENT_DIR="$PROJECT_DIR/.claude/tests/component"
LIB_DIR="$COMPONENT_DIR/lib"
SPECS_DIR="$COMPONENT_DIR/specs"

FILTER=""
if [ "${1:-}" = "--filter" ] && [ -n "${2:-}" ]; then
    FILTER="$2"
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'run.sh: jq is required but not on PATH\n' >&2
    exit 2
fi

if [ ! -d "$SPECS_DIR" ]; then
    printf 'run.sh: specs dir missing: %s\n' "$SPECS_DIR" >&2
    exit 2
fi

# Discover specs. macOS bash 3.2 friendly (no mapfile).
SPECS=()
while IFS= read -r line; do
    SPECS+=("$line")
done < <(find "$SPECS_DIR" -maxdepth 1 -type f -name '*.sh' | sort)

if [ ${#SPECS[@]} -eq 0 ]; then
    printf 'run.sh: no specs found in %s\n' "$SPECS_DIR" >&2
    exit 2
fi

TOTAL=0
SPEC_PASS=0
SPEC_FAIL=0
TOTAL_ASSERTS_PASS=0
TOTAL_ASSERTS_FAIL=0
FAILED_SPECS=()

# Per-spec runner. We invoke each spec in a fresh subshell with the lib
# files pre-sourced; the spec calls mk_fixture, runs assertions, and prints
# its own PASS:/FAIL: lines. The runner captures the final summary line
# (Passed: N / Failed: M) and aggregates.
for spec_file in "${SPECS[@]}"; do
    base=$(basename "$spec_file")
    if [ -n "$FILTER" ] && ! printf '%s' "$base" | grep -q "$FILTER"; then
        continue
    fi
    TOTAL=$((TOTAL + 1))
    printf '\n=== %s ===\n' "$base"

    # The wrapper sources the lib files, then sources the spec. We use a
    # subshell so PATH / CLAUDE_PROJECT_DIR mutations stay scoped to the spec.
    # Captures the spec's exit code; the spec exits non-zero when its FAIL
    # counter is non-zero (specs follow the same convention as phase5).
    spec_output=$(
        bash -u -c "
            set +e
            # Per-spec PASS/FAIL counters live in the same shell as the spec.
            PASS=0
            FAIL=0
            FAILED_TESTS=()
            . '$LIB_DIR/assert.sh'
            . '$LIB_DIR/shim.sh'
            . '$LIB_DIR/hook-envelope.sh'
            . '$LIB_DIR/fixture.sh'
            . '$spec_file'
            # Print a trailing line the runner can grep for.
            printf '__SPEC_SUMMARY__ pass=%d fail=%d\n' \"\$PASS\" \"\$FAIL\"
            if [ \"\$FAIL\" -gt 0 ]; then
                exit 1
            fi
            exit 0
        " 2>&1
    )
    spec_rc=$?
    # Echo the spec's own output so users see per-test PASS/FAIL lines.
    printf '%s\n' "$spec_output"

    # Aggregate the assertion totals from the trailing summary line.
    summary=$(printf '%s' "$spec_output" | grep -E '^__SPEC_SUMMARY__' | tail -1)
    if [ -n "$summary" ]; then
        sp=$(printf '%s' "$summary" | sed -nE 's/.*pass=([0-9]+).*/\1/p')
        sf=$(printf '%s' "$summary" | sed -nE 's/.*fail=([0-9]+).*/\1/p')
        TOTAL_ASSERTS_PASS=$((TOTAL_ASSERTS_PASS + ${sp:-0}))
        TOTAL_ASSERTS_FAIL=$((TOTAL_ASSERTS_FAIL + ${sf:-0}))
    fi

    if [ "$spec_rc" -eq 0 ]; then
        SPEC_PASS=$((SPEC_PASS + 1))
    else
        SPEC_FAIL=$((SPEC_FAIL + 1))
        FAILED_SPECS+=("$base")
    fi
done

printf '\n=== Summary ===\n'
printf 'Specs:      Total: %d  Passed: %d  Failed: %d\n' \
    "$TOTAL" "$SPEC_PASS" "$SPEC_FAIL"
printf 'Assertions: Passed: %d  Failed: %d\n' \
    "$TOTAL_ASSERTS_PASS" "$TOTAL_ASSERTS_FAIL"

if [ "$SPEC_FAIL" -gt 0 ]; then
    printf 'Failed specs:\n'
    for f in "${FAILED_SPECS[@]}"; do
        printf '  - %s\n' "$f"
    done
    exit 1
fi

exit 0
