#!/bin/bash
# run-tests.sh — entry point for the plugin's local test suite.
#
# Each test file under this directory is a self-contained bash script that
# exits 0 on success and 1 on failure. We invoke them sequentially and
# aggregate the verdict.
#
# Usage:
#   bash .claude/scripts/tests/run-tests.sh
#   bash .claude/scripts/tests/run-tests.sh --filter <pattern>   # only run matching tests
#
# Exit codes:
#   0 — all tests passed
#   1 — at least one test failed
#   2 — invocation error (no tests found, missing dependencies)

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
TESTS_DIR="$PROJECT_DIR/.claude/scripts/tests"

FILTER=""
if [ "${1:-}" = "--filter" ] && [ -n "${2:-}" ]; then
    FILTER="$2"
fi

if ! command -v jq >/dev/null 2>&1; then
    printf 'run-tests.sh: jq is required but not on PATH\n' >&2
    exit 2
fi

# Discover tests: any *.sh under tests/ that's NOT this runner itself.
# Avoid mapfile so we work on macOS bash 3.2.
TESTS=()
while IFS= read -r line; do
    TESTS+=("$line")
done < <(find "$TESTS_DIR" -maxdepth 1 -type f -name '*.sh' \
    ! -name 'run-tests.sh' | sort)

if [ ${#TESTS[@]} -eq 0 ]; then
    printf 'run-tests.sh: no test files found in %s\n' "$TESTS_DIR" >&2
    exit 2
fi

TOTAL=0
PASS=0
FAIL=0
FAILED_FILES=()

for test_file in "${TESTS[@]}"; do
    base=$(basename "$test_file")
    if [ -n "$FILTER" ] && ! printf '%s' "$base" | grep -q "$FILTER"; then
        continue
    fi
    TOTAL=$((TOTAL + 1))
    printf '\n=== %s ===\n' "$base"
    if bash "$test_file"; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        FAILED_FILES+=("$base")
    fi
done

printf '\n=== Summary ===\n'
printf 'Total: %d  Passed: %d  Failed: %d\n' "$TOTAL" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf 'Failed tests:\n'
    for f in "${FAILED_FILES[@]}"; do
        printf '  - %s\n' "$f"
    done
    exit 1
fi

exit 0
