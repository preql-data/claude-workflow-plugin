#!/bin/bash
# lessons.test.sh — spec 0.7 (claude-workflow-plugin-e0d.7).
#
# Asserts the behaviour of .claude/scripts/lessons.sh:
#   - happy path: add a fresh lesson -> appended.
#   - dedup: same normalized text twice -> merged (one entry, two sources).
#   - dedup is case+whitespace-insensitive.
#   - different lessons -> two distinct entries.
#   - idempotent: adding the same lesson with a source already present
#     -> noop.
#   - missing args: missing --source, missing lesson, no args.
#   - unknown subcommand: exits 1 with usage on stderr.
#   - list: prints the ledger; exits 1 if no ledger present.
#
# META-TEST: stub the normalizer to always-miss (return unique value
# per call) and assert the dedup assertion now fails — proving the
# dedup test is sensitive to the normalizer actually doing its job.
#
# Conventions mirror qa-gate-choose.test.sh: a tempdir fixture with a
# fresh LESSONS.md, helper functions for asserts, trailing summary.
# No bats. No jq required (lessons.sh emits JSON but we grep substrings
# rather than parse with jq, so this test stays jq-free for portability).
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

KEEP_FIXTURE=0
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
LESSONS_SH="$PROJECT_DIR/.claude/scripts/lessons.sh"
SEED_LEDGER="$PROJECT_DIR/LESSONS.md"

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

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
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

# Fixture helpers: each test reseeds the ledger from the committed
# seed so dedup/append tests have a known starting state.
FIXTURE=$(mktemp -d -t lessons-test.XXXXXX)
# shellcheck disable=SC2329  # cleanup invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\n' "$FIXTURE"
    else
        rm -rf "$FIXTURE"
    fi
}
trap cleanup EXIT

reseed() {
    cp "$SEED_LEDGER" "$FIXTURE/LESSONS.md"
}

# Invocation helper: every call uses the fixture as CLAUDE_PROJECT_DIR
# so the real LESSONS.md at the repo root is never touched.
LSH() {
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" "$@"
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: usage / malformed args ==="

# 1.1 No args -> exit 1 + usage on stderr.
RC=0
STDERR=$(LSH 2>&1 >/dev/null) || RC=$?
assert_eq "usage: no args exit 1" "1" "$RC"
assert_contains "usage: no args mentions Usage" "Usage: lessons.sh" "$STDERR"

# 1.2 Unknown subcommand -> exit 1 + name in stderr.
RC=0
STDERR=$(LSH bogus 2>&1 >/dev/null) || RC=$?
assert_eq "usage: unknown subcommand exit 1" "1" "$RC"
assert_contains "usage: unknown subcommand names the offender" \
    "unknown subcommand: bogus" "$STDERR"

# 1.3 add missing --source -> exit 1.
RC=0
reseed
STDERR=$(LSH add "some lesson text" 2>&1 >/dev/null) || RC=$?
assert_eq "usage: add missing --source exit 1" "1" "$RC"
assert_contains "usage: add missing --source shows usage" "Usage:" "$STDERR"

# 1.4 add missing lesson -> exit 1.
RC=0
reseed
STDERR=$(LSH add --source claude-workflow-plugin-test.1 2>&1 >/dev/null) || RC=$?
assert_eq "usage: add missing lesson exit 1" "1" "$RC"

# 1.5 add with neither -> exit 1.
RC=0
reseed
LSH add >/dev/null 2>&1 || RC=$?
assert_eq "usage: add with no args exit 1" "1" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: happy path (new lesson appended) ==="

reseed
SEED_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
OUT=$(LSH add "Tests must assert user-visible behaviour" \
    --source claude-workflow-plugin-test.1)
assert_contains "happy: action=appended" "\"action\":\"appended\"" "$OUT"
assert_contains "happy: source recorded" \
    "\"sources\":\"claude-workflow-plugin-test.1\"" "$OUT"

NEW_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "happy: ledger has +1 entry" "$((SEED_LINES + 1))" "$NEW_LINES"

# Verify the new entry's text and the HTML-comment metadata.
LAST_LINE=$(grep '^- Tests must assert' "$FIXTURE/LESSONS.md")
assert_contains "happy: new line has sources comment" \
    "<!-- sources: claude-workflow-plugin-test.1 -->" "$LAST_LINE"
assert_contains "happy: new line has recorded comment" \
    "<!-- recorded:" "$LAST_LINE"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: dedup (same text twice -> one entry, two sources) ==="

reseed
LSH add "A lesson about reproducible bugs" --source claude-workflow-plugin-test.a >/dev/null
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")

OUT=$(LSH add "A lesson about reproducible bugs" --source claude-workflow-plugin-test.b)
assert_contains "dedup: action=merged" "\"action\":\"merged\"" "$OUT"

AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "dedup: entry count unchanged after second add" \
    "$BEFORE_LINES" "$AFTER_LINES"

MERGED_LINE=$(grep '^- A lesson about reproducible bugs' "$FIXTURE/LESSONS.md")
assert_contains "dedup: both sources on the same line" \
    "claude-workflow-plugin-test.a, claude-workflow-plugin-test.b" "$MERGED_LINE"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: dedup is case- and whitespace-insensitive ==="

reseed
LSH add "Mocks must match the real producer's shape" \
    --source claude-workflow-plugin-test.x >/dev/null
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")

# Same text, different case + extra whitespace.
OUT=$(LSH add "MOCKS  must  MATCH the   real producer's SHAPE" \
    --source claude-workflow-plugin-test.y)
assert_contains "norm: case/ws-insensitive merges" \
    "\"action\":\"merged\"" "$OUT"

AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "norm: entry count still unchanged" "$BEFORE_LINES" "$AFTER_LINES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: different lessons -> two entries ==="

reseed
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
LSH add "Lesson one about timeouts" --source claude-workflow-plugin-test.1 >/dev/null
LSH add "Lesson two about idempotency" --source claude-workflow-plugin-test.2 >/dev/null
AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "distinct: two new lessons appended" \
    "$((BEFORE_LINES + 2))" "$AFTER_LINES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: idempotent (same lesson + same source -> noop) ==="

reseed
LSH add "Noop lesson" --source claude-workflow-plugin-test.dup >/dev/null
BEFORE=$(grep -F '^- Noop lesson' "$FIXTURE/LESSONS.md" || grep '^- Noop lesson' "$FIXTURE/LESSONS.md")

OUT=$(LSH add "Noop lesson" --source claude-workflow-plugin-test.dup)
assert_contains "idempotent: action=noop" "\"action\":\"noop\"" "$OUT"

AFTER=$(grep '^- Noop lesson' "$FIXTURE/LESSONS.md")
assert_eq "idempotent: line unchanged" "$BEFORE" "$AFTER"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: list ==="

reseed
LIST_OUT=$(LSH list)
assert_contains "list: includes seeded worktree-isolation lesson" \
    "concurrent specialists require worktree isolation" "$LIST_OUT"
assert_contains "list: includes seeded boundary-mock lesson" \
    "boundary mocks must use the real downstream producer's shape" \
    "$(printf '%s' "$LIST_OUT" | tr '[:upper:]' '[:lower:]')"

# list with missing ledger -> exit 1.
MISSING_DIR=$(mktemp -d -t lessons-missing.XXXXXX)
RC=0
CLAUDE_PROJECT_DIR="$MISSING_DIR" bash "$LESSONS_SH" list >/dev/null 2>&1 || RC=$?
assert_eq "list: missing ledger exit 1" "1" "$RC"
rm -rf "$MISSING_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: META-TEST (stubbed normalizer -> dedup must fail) ==="

# Build a stub variant of lessons.sh with a broken `normalize()` that
# returns a random-per-call value, so two identical texts hash to
# different normalized strings and the dedup path can't trigger.
STUB_SH="$FIXTURE/lessons-broken.sh"
cp "$LESSONS_SH" "$STUB_SH"

# Replace the body of normalize() with one that emits a unique random
# token per call (so the dedup check never finds a match). We use a
# Python-free approach: the line is replaced wholesale.
python3 - "$STUB_SH" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# Replace the entire normalize() function body. We match from the
# function header `normalize() {` to the closing `}` on its own line.
pattern = re.compile(
    r'normalize\(\)\s*\{\n(?:.*\n)*?\}\n', re.MULTILINE
)
replacement = (
    'normalize() {\n'
    '    # STUB: always return a unique value so dedup misses.\n'
    '    # shellcheck disable=SC2034  # parameters intentionally ignored\n'
    '    printf \'stub-%s-%s\\n\' "$RANDOM" "$$"\n'
    '}\n'
)
new_src, n = pattern.subn(replacement, src, count=1)
if n != 1:
    sys.exit("META-TEST: failed to patch normalize() in stub (replacements=%d)" % n)
with open(path, 'w') as f:
    f.write(new_src)
PY

reseed
# Add the same lesson twice with the broken stub; with a working
# normalizer the second call would merge. With the broken stub, both
# calls append, so the entry count grows by 2.
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$STUB_SH" add \
    "Broken-normalizer canary lesson" --source claude-workflow-plugin-test.m1 \
    >/dev/null
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$STUB_SH" add \
    "Broken-normalizer canary lesson" --source claude-workflow-plugin-test.m2 \
    >/dev/null
AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")

# Expected: AFTER == BEFORE + 2 (dedup broken; both appended).
# If the test sees BEFORE + 1 here, the stub didn't actually break
# the normalizer, meaning the dedup-assertion's sensitivity is unproven.
assert_eq "META-TEST: broken normalizer appends both copies (BEFORE+2)" \
    "$((BEFORE_LINES + 2))" "$AFTER_LINES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
