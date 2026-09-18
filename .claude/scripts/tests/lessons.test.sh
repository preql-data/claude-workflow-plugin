#!/bin/bash
# lessons.test.sh — spec 0.7 (claude-workflow-plugin-e0d.7), extended for tag
# scoping by claude-workflow-plugin-zerv (v5 phase P item P8), extended again
# for the exclusion ACCOUNTING added by claude-workflow-plugin-9hv4.
#
# Asserts the behaviour of .claude/scripts/lessons.sh:
#   - happy path: add a fresh lesson -> appended, with all three comments.
#   - dedup: same normalized text twice -> merged (one entry, merged sources
#     AND merged tags).
#   - dedup is case+whitespace-insensitive.
#   - different lessons -> two distinct entries.
#   - idempotent: same lesson, same source, same tags -> noop.
#   - missing args: missing --source, missing lesson, missing --tag, no args.
#   - unknown subcommand: exits 1 with usage on stderr.
#   - --stdin: heredoc text survives apostrophes and backticks intact.
#   - INJECTION: a tag or prose carrying `-->` is REJECTED and the ledger is
#     BYTE-UNCHANGED. Never sanitised.
#   - tag charset + closed vocabulary enforcement.
#   - list: verbatim with no flags, filtered with --tag/--untagged/--since/
#     --limit, and the flag-validation errors.
#   - (9hv4) list's ACCOUNTING: a filtered call reports total/matched/
#     returned/excluded_by_filter/excluded_by_limit on stderr, cross-checked
#     against independently-computed ground truth (not lessons.sh's own
#     arithmetic re-run) — a scoped read returns fewer than the unscoped
#     control, and the gap is exactly what the accounting names as excluded.
#   - (9hv4) DISTINGUISHABILITY: a legitimate zero-match (valid tag, an
#     impossible --since bound) reports ok:true/matched:0; an out-of-
#     vocabulary tag on the READ path and a missing ledger file both report
#     ok:false with DIFFERENT, non-interchangeable error codes. All three are
#     tellable apart without relying on the exit code alone.
#   - LEDGER INVARIANTS against the committed LESSONS.md: zero untagged
#     entries (backfill completeness), every prose string exactly once, and
#     ordinal stability for the citations in grader.md / rubrics/default.md.
#   - vocabulary parity between lessons.sh's TAG_VOCABULARY and the table in
#     the LESSONS.md preamble.
#
# META-TESTS (each proves a specific assertion above is load-bearing, and each
# is anchored to a unique TEXT pattern rather than a line number, per the
# LESSONS.md rule recorded 2026-06-13):
#   M1 stub the normalizer to always-miss -> the dedup assertion must fail.
#   M2 stub validate_tag to a no-op -> the `-->` tag now REACHES the ledger,
#      proving the byte-unchanged assertion is caused by the guard and not by
#      `add` failing for some unrelated reason.
#   M3 stub assert_no_comment_grammar -> `-->` in PROSE lands and the entry's
#      tags read back WRONG, demonstrating the field relocation the guard
#      exists to prevent.
#   M4 a fixture with one untagged entry -> the untagged count must be 1,
#      proving the "zero untagged" invariant can actually see an untagged
#      entry.
#   M5 a fixture with a duplicated entry -> the prose-uniqueness invariant
#      must see the duplicate.
#   M6 a stubbed TAG_VOCABULARY -> the vocabulary-parity assertion must fail.
#   M7 (9hv4) stub tags_contain to a no-op -> --tag returns EVERYTHING, and
#      the accounting line claims zero exclusion for a filter that (on the
#      shipped script, proven by a restore control in the same block)
#      excludes most of the ledger. This is literally the task's own
#      required META: "stub the scoping so it always returns everything, and
#      assert a test notices."
#   M8 (9hv4) stub the excluded_by_limit computation to always read 0 ->
#      --limit still trims stdout for real, but the accounting now LIES
#      about it; a consumer cross-checking matched-minus-returned against
#      the claimed figure catches the lie, and a restore control proves the
#      shipped script reports the true figure for the identical call.
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
GRADER_MD="$PROJECT_DIR/.claude/agents/grader.md"
DEFAULT_RUBRIC="$PROJECT_DIR/.claude/rubrics/default.md"

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

# Byte-level file comparison. The injection tests assert on BYTES rather than
# on an exit code, because a guard that returns 1 while still writing a
# partial line would satisfy the exit code and corrupt the ledger anyway.
assert_files_identical() {
    local name="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n' "$name"
        printf '    files differ:\n'
        diff "$a" "$b" | head -6 | sed 's/^/      /'
    fi
}

assert_files_differ() {
    local name="$1" a="$2" b="$3"
    if cmp -s "$a" "$b"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    files are identical but should differ\n' "$name"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

# Fixture helpers: each test reseeds the ledger from the committed
# seed so dedup/append tests have a known starting state.
FIXTURE=$(mktemp -d -t lessons-test.XXXXXX)
# cleanup runs only via the EXIT trap below; the static analyzer can't see
# that indirection. Newer shellchecks emit SC2329 on the definition, older
# ones (CI) emit SC2317 on every statement in the body. Suppress both.
# shellcheck disable=SC2329,SC2317
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

snapshot() {
    cp "$FIXTURE/LESSONS.md" "$FIXTURE/snapshot.md"
}

# Invocation helper: every call uses the fixture as CLAUDE_PROJECT_DIR
# so the real LESSONS.md at the repo root is never touched.
LSH() {
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" "$@"
}

# Count the ledger entries carrying no tags comment.
untagged_count() {
    grep '^- ' "$1" | grep -cv '<!-- tags:' || true
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
STDERR=$(LSH add "some lesson text" --tag gate 2>&1 >/dev/null) || RC=$?
assert_eq "usage: add missing --source exit 1" "1" "$RC"
assert_contains "usage: add missing --source shows usage" "Usage:" "$STDERR"

# 1.4 add missing lesson -> exit 1.
RC=0
reseed
STDERR=$(LSH add --source claude-workflow-plugin-test.1 --tag gate 2>&1 >/dev/null) || RC=$?
assert_eq "usage: add missing lesson exit 1" "1" "$RC"

# 1.5 add with neither -> exit 1.
RC=0
reseed
LSH add >/dev/null 2>&1 || RC=$?
assert_eq "usage: add with no args exit 1" "1" "$RC"

# 1.6 add WITHOUT --tag -> exit 1, and the ledger is untouched. --tag is
# required because an untagged entry is invisible to every scoped read, which
# for a scoping consumer is the same as not being in the ledger at all.
reseed
snapshot
RC=0
STDERR=$(LSH add "A lesson with no tag at all" \
    --source claude-workflow-plugin-test.notag 2>&1 >/dev/null) || RC=$?
assert_eq "usage: add missing --tag exit 1" "1" "$RC"
assert_contains "usage: add missing --tag shows usage" "Usage:" "$STDERR"
assert_files_identical "usage: add missing --tag left the ledger byte-unchanged" \
    "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: happy path (new lesson appended) ==="

reseed
SEED_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
OUT=$(LSH add "Tests must assert user-visible behaviour" \
    --source claude-workflow-plugin-test.1 --tag testing)
assert_contains "happy: action=appended" "\"action\":\"appended\"" "$OUT"
assert_contains "happy: source recorded" \
    "\"sources\":\"claude-workflow-plugin-test.1\"" "$OUT"
assert_contains "happy: tags recorded" "\"tags\":\"testing\"" "$OUT"

NEW_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "happy: ledger has +1 entry" "$((SEED_LINES + 1))" "$NEW_LINES"

# Verify the new entry's text and all THREE HTML comments, in order.
LAST_LINE=$(grep '^- Tests must assert' "$FIXTURE/LESSONS.md")
assert_contains "happy: new line has sources comment" \
    "<!-- sources: claude-workflow-plugin-test.1 -->" "$LAST_LINE"
assert_contains "happy: new line has tags comment" \
    "<!-- tags: testing -->" "$LAST_LINE"
assert_contains "happy: new line has recorded comment" \
    "<!-- recorded:" "$LAST_LINE"
# Field ORDER is part of the grammar: sources, then tags, then recorded.
if printf '%s' "$LAST_LINE" \
    | grep -q '<!-- sources: [^>]*--> <!-- tags: [^>]*--> <!-- recorded: [0-9-]* -->$'; then
    PASS=$((PASS + 1)); printf '  PASS: %s\n' "happy: three comments in the fixed order"
else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("happy: three comments in the fixed order")
    printf '  FAIL: %s\n    line: %s\n' "happy: three comments in the fixed order" "$LAST_LINE"
fi

# Multiple --tag flags render sorted and comma-joined.
reseed
OUT=$(LSH add "A multi tag lesson" --source claude-workflow-plugin-test.mt \
    --tag testing --tag gate --tag agents)
assert_contains "happy: repeated --tag renders sorted" \
    "\"tags\":\"agents, gate, testing\"" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: dedup (same text twice -> one entry, merged lists) ==="

reseed
LSH add "A lesson about reproducible bugs" \
    --source claude-workflow-plugin-test.a --tag evidence >/dev/null
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")

OUT=$(LSH add "A lesson about reproducible bugs" \
    --source claude-workflow-plugin-test.b --tag testing)
assert_contains "dedup: action=merged" "\"action\":\"merged\"" "$OUT"

AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "dedup: entry count unchanged after second add" \
    "$BEFORE_LINES" "$AFTER_LINES"

MERGED_LINE=$(grep '^- A lesson about reproducible bugs' "$FIXTURE/LESSONS.md")
assert_contains "dedup: both sources on the same line" \
    "claude-workflow-plugin-test.a, claude-workflow-plugin-test.b" "$MERGED_LINE"
assert_contains "dedup: both tags on the same line" \
    "<!-- tags: evidence, testing -->" "$MERGED_LINE"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: dedup is case- and whitespace-insensitive ==="

reseed
LSH add "Mocks must match the real producer's shape" \
    --source claude-workflow-plugin-test.x --tag testing >/dev/null
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")

# Same text, different case + extra whitespace.
OUT=$(LSH add "MOCKS  must  MATCH the   real producer's SHAPE" \
    --source claude-workflow-plugin-test.y --tag testing)
assert_contains "norm: case/ws-insensitive merges" \
    "\"action\":\"merged\"" "$OUT"

AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "norm: entry count still unchanged" "$BEFORE_LINES" "$AFTER_LINES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: different lessons -> two entries ==="

reseed
BEFORE_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
LSH add "Lesson one about timeouts" \
    --source claude-workflow-plugin-test.1 --tag gate >/dev/null
LSH add "Lesson two about idempotency" \
    --source claude-workflow-plugin-test.2 --tag process >/dev/null
AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
assert_eq "distinct: two new lessons appended" \
    "$((BEFORE_LINES + 2))" "$AFTER_LINES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: idempotent (same lesson + same source + same tags) ==="

reseed
LSH add "Noop lesson" --source claude-workflow-plugin-test.dup --tag gate >/dev/null
BEFORE=$(grep '^- Noop lesson' "$FIXTURE/LESSONS.md")

OUT=$(LSH add "Noop lesson" --source claude-workflow-plugin-test.dup --tag gate)
assert_contains "idempotent: action=noop" "\"action\":\"noop\"" "$OUT"

AFTER=$(grep '^- Noop lesson' "$FIXTURE/LESSONS.md")
assert_eq "idempotent: line unchanged" "$BEFORE" "$AFTER"

# A new tag on an existing source is NOT a noop — the tag list changed.
OUT=$(LSH add "Noop lesson" --source claude-workflow-plugin-test.dup --tag testing)
assert_contains "idempotent: a new tag alone still merges" \
    "\"action\":\"merged\"" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: --stdin (the quoting-safe input path) ==="

# The motivating defect: the usage string's single-quoted examples end at the
# first apostrophe, and several shipped entries lost their possessives to it.
# Double quotes would instead run the backticks lessons routinely contain.
# --stdin with a quoted heredoc is literal on both counts.
reseed
# Run the invocation EXACTLY as the usage string and the LESSONS.md preamble
# spell it — a quoted heredoc on a plain command. It cannot be wrapped in
# $(...) here: bash's parser loses the closing paren across a nested heredoc,
# so the output is captured through a file instead.
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" add --stdin \
    --source claude-workflow-plugin-test.sin --tag evidence \
    > "$FIXTURE/stdin-out.json" 2>&1 <<'LESSON'
A freshness gate must not read a directory that the gate's own earlier
steps write to: `git status` rewrites a linked worktree admin dir.
LESSON
OUT=$(cat "$FIXTURE/stdin-out.json")
assert_contains "stdin: appended" "\"action\":\"appended\"" "$OUT"
STDIN_LINE=$(grep "^- A freshness gate must not read a directory that the gate's own" \
    "$FIXTURE/LESSONS.md" || true)
assert_contains "stdin: the apostrophe survived" "the gate's own earlier" "$STDIN_LINE"
# shellcheck disable=SC2016  # literal backticks are the needle, not a command.
assert_contains "stdin: the backticks survived" '`git status`' "$STDIN_LINE"
assert_contains "stdin: multi-line input collapsed to one line" \
    "earlier steps write to" "$STDIN_LINE"
assert_eq "stdin: exactly one entry was created" "1" \
    "$(grep -c "^- A freshness gate must not read a directory that the gate's own" \
        "$FIXTURE/LESSONS.md")"

# --stdin plus inline text is ambiguous -> reject.
reseed
snapshot
RC=0
LSH add --stdin "inline as well" --source claude-workflow-plugin-test.sin \
    --tag evidence </dev/null >/dev/null 2>&1 || RC=$?
assert_eq "stdin: --stdin with inline text exits 1" "1" "$RC"
assert_files_identical "stdin: rejected call left the ledger byte-unchanged" \
    "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: INJECTION — reject, never sanitise, ledger byte-unchanged ==="

# The entry grammar is three HTML comments on ONE line. A value containing
# `-->` closes its comment early and relocates every later field on read-back.
# The contract is REJECT (never clean), and the ledger must not move a byte.

# 8.1 A tag carrying `-->` plus a forged trailing field.
reseed
snapshot
RC=0
STDERR=$(LSH add "An injected lesson" --source claude-workflow-plugin-test.inj \
    --tag 'gate --> <!-- recorded: 1999-01-01' 2>&1 >/dev/null) || RC=$?
assert_eq "injection: --> in a tag exits 1" "1" "$RC"
assert_contains "injection: error is structured JSON with ok:false" \
    '"ok":false' "$STDERR"
assert_files_identical "injection: --> tag left the ledger BYTE-UNCHANGED" \
    "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"

# 8.2 POSITIVE CONTROL. A byte-unchanged ledger also describes an `add` that
# is broken for an unrelated reason, so prove the identical call DOES write
# when the only difference is a legal tag. Without this control the assertion
# above cannot distinguish "the guard fired" from "nothing works".
reseed
snapshot
LSH add "An injected lesson" --source claude-workflow-plugin-test.inj \
    --tag gate >/dev/null
assert_files_differ "injection: CONTROL — the same add with a legal tag DOES write" \
    "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"

# 8.3 `-->` in the lesson PROSE. Prose has no charset restriction (lessons
# legitimately contain < and >), so the comment-grammar guard is the only
# thing standing between this input and a corrupted entry.
reseed
snapshot
RC=0
LSH add 'Prose with --> <!-- tags: process --> an injected tail' \
    --source claude-workflow-plugin-test.inj2 --tag gate >/dev/null 2>&1 || RC=$?
assert_eq "injection: --> in prose exits 1" "1" "$RC"
assert_files_identical "injection: --> prose left the ledger BYTE-UNCHANGED" \
    "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"

# 8.4 An angle bracket or comma in a source id would truncate or split the
# comma-joined list on the next rewrite.
reseed
snapshot
RC=0
LSH add "A lesson" --source 'a,b' --tag gate >/dev/null 2>&1 || RC=$?
assert_eq "injection: comma in --source exits 1" "1" "$RC"
assert_files_identical "injection: bad source left the ledger BYTE-UNCHANGED" \
    "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"

# 8.5 Charset and closed-vocabulary enforcement on tags.
reseed
RC=0
STDERR=$(LSH add "A lesson" --source claude-workflow-plugin-test.c --tag 'Gate' 2>&1 >/dev/null) || RC=$?
assert_eq "injection: uppercase tag exits 1" "1" "$RC"
assert_contains "injection: uppercase tag names the charset rule" \
    "invalid-tag-charset" "$STDERR"

RC=0
STDERR=$(LSH add "A lesson" --source claude-workflow-plugin-test.c --tag 'gate!' 2>&1 >/dev/null) || RC=$?
assert_eq "injection: punctuation in tag exits 1" "1" "$RC"

RC=0
STDERR=$(LSH add "A lesson" --source claude-workflow-plugin-test.c --tag '-gate' 2>&1 >/dev/null) || RC=$?
assert_eq "injection: leading-hyphen tag exits 1" "1" "$RC"

RC=0
STDERR=$(LSH add "A lesson" --source claude-workflow-plugin-test.c --tag 'security' 2>&1 >/dev/null) || RC=$?
assert_eq "injection: out-of-vocabulary tag exits 1" "1" "$RC"
assert_contains "injection: out-of-vocabulary error names the closed list" \
    "unknown-tag" "$STDERR"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: list ==="

reseed
LIST_OUT=$(LSH list)
assert_contains "list: includes seeded worktree-isolation lesson" \
    "concurrent specialists require worktree isolation" "$LIST_OUT"
assert_contains "list: includes seeded boundary-mock lesson" \
    "boundary mocks must use the real downstream producer's shape" \
    "$(printf '%s' "$LIST_OUT" | tr '[:upper:]' '[:lower:]')"

# 9.1 With no flags, `list` is byte-identical to `cat`. The grading packet
# depends on this: the grader receives the WHOLE ledger because lessons are
# criteria-by-reference there, and any narrowing narrows the criteria.
LSH list > "$FIXTURE/list-out.md"
assert_files_identical "list: no flags is byte-identical to the ledger file" \
    "$FIXTURE/LESSONS.md" "$FIXTURE/list-out.md"

# 9.2 --tag filters, OR-combined across repeats.
reseed
GATE_N=$(LSH list --tag gate | grep -c '^- ')
TESTING_N=$(LSH list --tag testing | grep -c '^- ')
BOTH_N=$(LSH list --tag gate --tag testing | grep -c '^- ')
if [ "$BOTH_N" -ge "$GATE_N" ] && [ "$BOTH_N" -ge "$TESTING_N" ] \
   && [ "$BOTH_N" -le $((GATE_N + TESTING_N)) ] && [ "$GATE_N" -gt 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS: %s\n' "list: --tag is OR-combined across repeats"
else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("list: --tag is OR-combined across repeats")
    printf '  FAIL: list --tag OR semantics (gate=%s testing=%s both=%s)\n' \
        "$GATE_N" "$TESTING_N" "$BOTH_N"
fi
# Every returned line really carries the tag.
OFF_TAG=$(LSH list --tag packaging | grep -cv '<!-- tags: [^>]*packaging' || true)
assert_eq "list: --tag returns only entries carrying that tag" "0" "$OFF_TAG"

# 9.3 --since reads the existing recorded: comment; no new state.
reseed
SINCE_N=$(LSH list --since 2026-08-01 | grep -c '^- ' || true)
OLD_LEAK=$(LSH list --since 2026-08-01 | grep -c '<!-- recorded: 2026-0[1-7]' || true)
assert_eq "list: --since excludes everything older than the bound" "0" "$OLD_LEAK"
if [ "$SINCE_N" -gt 0 ]; then
    PASS=$((PASS + 1)); printf '  PASS: %s\n' "list: --since returns the recent slice"
else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("list: --since returns the recent slice")
    printf '  FAIL: list --since 2026-08-01 returned nothing\n'
fi

# 9.4 --limit keeps the MOST RECENT n, in ledger order.
LAST_ENTRY=$(grep '^- ' "$FIXTURE/LESSONS.md" | tail -1)
LIMIT_OUT=$(LSH list --limit 3)
assert_eq "list: --limit returns exactly n entries" "3" "$(printf '%s\n' "$LIMIT_OUT" | grep -c '^- ')"
assert_eq "list: --limit keeps the MOST RECENT entries" \
    "$LAST_ENTRY" "$(printf '%s\n' "$LIMIT_OUT" | tail -1)"

# 9.5 flag validation.
RC=0; LSH list --untagged --tag gate >/dev/null 2>&1 || RC=$?
assert_eq "list: --untagged with --tag exits 1" "1" "$RC"
RC=0; LSH list --since 2026-8-6 >/dev/null 2>&1 || RC=$?
assert_eq "list: malformed --since exits 1" "1" "$RC"
RC=0; LSH list --limit 0 >/dev/null 2>&1 || RC=$?
assert_eq "list: --limit 0 exits 1" "1" "$RC"
RC=0; LSH list --limit abc >/dev/null 2>&1 || RC=$?
assert_eq "list: non-numeric --limit exits 1" "1" "$RC"
RC=0; LSH list --bogus >/dev/null 2>&1 || RC=$?
assert_eq "list: unknown flag exits 1" "1" "$RC"

# list with missing ledger -> exit 1.
MISSING_DIR=$(mktemp -d -t lessons-missing.XXXXXX)
RC=0
CLAUDE_PROJECT_DIR="$MISSING_DIR" bash "$LESSONS_SH" list >/dev/null 2>&1 || RC=$?
assert_eq "list: missing ledger exit 1" "1" "$RC"
rm -rf "$MISSING_DIR"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9 (claude-workflow-plugin-9hv4): list's exclusion accounting ==="

# 9.6 — a filtered list reports an accounting line on stderr: total ledger
# size, how many matched, how many were returned, and how many were
# excluded by the filter vs by --limit. Ground truth for "matched" is
# computed the SAME way section 9.2 already does (grep over the tags
# comment) — independently of lessons.sh's own arithmetic — so this cannot
# pass merely because both sides share a bug.
reseed
TOTAL_TRUTH=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
GATE_TRUTH=$(grep '^- ' "$FIXTURE/LESSONS.md" | grep -c '<!-- tags: [^>]*gate')
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list --tag gate \
    >"$FIXTURE/list-stdout.txt" 2>"$FIXTURE/list-stderr.json"
STATS=$(cat "$FIXTURE/list-stderr.json")
RETURNED_TRUTH=$(grep -c '^- ' "$FIXTURE/list-stdout.txt" || true)

assert_contains "9.6: accounting line reports ok:true" '"ok":true' "$STATS"
assert_contains "9.6: accounting reports the true total ledger size" \
    "\"total_ledger_entries\":${TOTAL_TRUTH}" "$STATS"
assert_contains "9.6: accounting's matched count agrees with an independent grep" \
    "\"matched\":${GATE_TRUTH}" "$STATS"
assert_contains "9.6: accounting names the tag filter actually applied" \
    "\"tags\":[\"gate\"]" "$STATS"
assert_eq "9.6: accounting's returned count equals the ACTUAL stdout line count" \
    "$RETURNED_TRUTH" "$(printf '%s' "$STATS" | sed -n 's/.*"returned":\([0-9]*\).*/\1/p')"

# 9.7 — CONTROL: a scoped read returns fewer entries than the unscoped read,
# and excluded_by_filter accounts for the entire gap. Without this control,
# 9.6 alone could pass against a script that always returned the whole
# ledger and merely mislabeled the count.
UNSCOPED_TRUTH=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list | grep -c '^- ')
if [ "$GATE_TRUTH" -lt "$UNSCOPED_TRUTH" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "9.7: scoped read (--tag gate) returns fewer than the unscoped CONTROL"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("9.7: scoped read returns fewer than the unscoped control")
    printf '  FAIL: 9.7 - gate=%s unscoped=%s\n' "$GATE_TRUTH" "$UNSCOPED_TRUTH"
fi
EXCLUDED_TRUTH=$((TOTAL_TRUTH - GATE_TRUTH))
assert_contains "9.7: excluded_by_filter accounts for the WHOLE gap to the total" \
    "\"excluded_by_filter\":${EXCLUDED_TRUTH}" "$STATS"

# 9.8 — --limit's cap is named too: excluded_by_limit is the gap between
# what matched the filter and what the cap actually let through.
if [ "$GATE_TRUTH" -gt 1 ]; then
    LIMIT_STATS=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list --tag gate --limit 1 2>&1 >/dev/null)
    assert_contains "9.8: --limit accounting reports exactly what the cap cut" \
        "\"excluded_by_limit\":$((GATE_TRUTH - 1))" "$LIMIT_STATS"
    assert_contains "9.8: --limit accounting still reports the filter's own exclusion separately" \
        "\"excluded_by_filter\":${EXCLUDED_TRUTH}" "$LIMIT_STATS"
else
    printf '  note: 9.8 SKIPPED (fewer than 2 gate-tagged entries in this fixture; cap cannot be exercised)\n'
fi

# 9.9 — THE ONE THAT MATTERS MOST (9hv4's own framing): a read that FAILS
# must be distinguishable from one that correctly matched nothing. A valid
# tag combined with an impossible --since bound legitimately matches zero
# entries; an unknown tag and a missing ledger are FAILURES. All three must
# be tellable apart by parsing stderr (ok / error code), not by trusting a
# bare exit code or an empty stdout stream alone.
reseed

# (a) Legitimate zero-match.
RC=0
ZERO_STATS=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list --tag gate --since 2099-01-01 2>&1 >/dev/null) || RC=$?
assert_eq "9.9a: legitimate zero-match exits 0" "0" "$RC"
assert_contains "9.9a: legitimate zero-match still reports ok:true" '"ok":true' "$ZERO_STATS"
assert_contains "9.9a: legitimate zero-match reports matched:0 EXPLICITLY" \
    '"matched":0' "$ZERO_STATS"

# (b) Failure: an out-of-vocabulary tag on the READ path (not just `add`).
RC=0
BADTAG_STATS=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list --tag security 2>&1 >/dev/null) || RC=$?
assert_eq "9.9b: unknown tag on list exits 1 (never silently treated as 'matches nothing')" "1" "$RC"
assert_contains "9.9b: unknown tag reports ok:false" '"ok":false' "$BADTAG_STATS"
assert_contains "9.9b: unknown tag names the closed-vocabulary failure specifically" \
    "unknown-tag" "$BADTAG_STATS"

# (c) Failure: missing ledger file, on a FILTERED call.
MISSING_DIR2=$(mktemp -d -t lessons-missing2.XXXXXX)
RC=0
MISSING_STATS=$(CLAUDE_PROJECT_DIR="$MISSING_DIR2" bash "$LESSONS_SH" list --tag gate 2>&1 >/dev/null) || RC=$?
assert_eq "9.9c: missing ledger on a filtered list exits 1" "1" "$RC"
assert_contains "9.9c: missing ledger reports ok:false" '"ok":false' "$MISSING_STATS"
assert_contains "9.9c: missing ledger names its OWN failure, not the tag one" \
    "ledger-not-found" "$MISSING_STATS"
rm -rf "$MISSING_DIR2"

# (d) The two failure modes are pairwise distinguishable from EACH OTHER,
# not just from the zero-match success — a reader parsing only "ok:false"
# could not tell a bad tag from a missing file, which would still leave an
# operator guessing what to fix.
if printf '%s' "$BADTAG_STATS" | grep -qF '"ok":false' && \
   printf '%s' "$MISSING_STATS" | grep -qF '"ok":false' && \
   ! printf '%s' "$BADTAG_STATS" | grep -qF 'ledger-not-found' && \
   ! printf '%s' "$MISSING_STATS" | grep -qF 'unknown-tag'; then
    PASS=$((PASS + 1))
    printf '  PASS: %s\n' "9.9d: the two failure modes carry distinct, non-interchangeable error codes"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("9.9d: the two failure modes carry distinct error codes")
    printf '  FAIL: 9.9d - badtag=%s missing=%s\n' "$BADTAG_STATS" "$MISSING_STATS"
fi

# (e) The missing-ledger failure is structured JSON on the UNFILTERED path
# too (list with no flags) — the existence check runs before the
# filtered/unfiltered branch, so both paths must fail the same clear way.
MISSING_DIR3=$(mktemp -d -t lessons-missing3.XXXXXX)
RC=0
MISSING_UNFILTERED=$(CLAUDE_PROJECT_DIR="$MISSING_DIR3" bash "$LESSONS_SH" list 2>&1 >/dev/null) || RC=$?
assert_eq "9.9e: missing ledger on the unfiltered list also exits 1" "1" "$RC"
assert_contains "9.9e: missing ledger on the unfiltered list reports ok:false too" \
    '"ok":false' "$MISSING_UNFILTERED"
rm -rf "$MISSING_DIR3"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 10: committed-ledger invariants ==="

# 10.1 BACKFILL COMPLETENESS. Every entry in the shipped ledger carries tags.
# An untagged entry is invisible to every scoped consumer, so a partial
# backfill silently shrinks what the orchestrator sees.
UNTAGGED_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$LESSONS_SH" list --untagged)
UNTAGGED_RC=$?
assert_eq "ledger: list --untagged exits 0" "0" "$UNTAGGED_RC"
assert_eq "ledger: ZERO untagged entries in the committed LESSONS.md" \
    "0" "$(printf '%s' "$UNTAGGED_OUT" | grep -c '^- ' || true)"
assert_eq "ledger: the same count read directly from the file" \
    "0" "$(untagged_count "$SEED_LEDGER")"

# 10.2 Every entry matches the full three-comment grammar, in order.
TOTAL_ENTRIES=$(grep -c '^- ' "$SEED_LEDGER")
WELL_FORMED=$(grep -c '^- .*<!-- sources: [^>]*--> <!-- tags: [^>]*--> <!-- recorded: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] -->$' "$SEED_LEDGER")
assert_eq "ledger: every entry matches the three-comment grammar" \
    "$TOTAL_ENTRIES" "$WELL_FORMED"

# 10.3 Every prose string appears EXACTLY ONCE. The backfill was a pure
# insertion; if it had duplicated or dropped an entry, the distinct-prose
# count would diverge from the entry count. This also encodes what dedup
# exists to guarantee, so it keeps holding after the landing.
DISTINCT_PROSE=$(grep '^- ' "$SEED_LEDGER" | sed 's/ <!-- .*//' \
    | tr '[:upper:]' '[:lower:]' | sort -u | wc -l | tr -d ' ')
assert_eq "ledger: every prose string appears exactly once" \
    "$TOTAL_ENTRIES" "$DISTINCT_PROSE"

# 10.4 ORDINAL STABILITY. grader.md and rubrics/default.md cite lessons by
# position. Tags were chosen over sections precisely so these keep resolving;
# if a future change reorders the ledger, this is what says so.
ENTRY_1=$(grep '^- ' "$SEED_LEDGER" | sed -n '1p')
ENTRY_2=$(grep '^- ' "$SEED_LEDGER" | sed -n '2p')
assert_contains "ledger: lesson 1 is still the worktree-isolation lesson" \
    "concurrent specialists require worktree isolation" "$ENTRY_1"
assert_contains "ledger: lesson 2 is still the boundary-mock lesson" \
    "Boundary mocks must use the real downstream producer's shape" "$ENTRY_2"
# And the citations those ordinals serve still exist. If a cite is reworded
# away, this fails and tells the next editor the pin above is now unowned
# rather than leaving it silently guarding nothing.
assert_contains "ledger: grader.md still cites LESSONS.md by ordinal" \
    "lesson 2" "$(cat "$GRADER_MD")"
assert_contains "ledger: rubrics/default.md C7 still cites LESSONS.md by ordinal" \
    "lesson 2" "$(cat "$DEFAULT_RUBRIC")"

# 10.5 VOCABULARY PARITY. The closed vocabulary is declared twice — enforced
# in lessons.sh, documented in the LESSONS.md preamble table. Two declarations
# with no parity check drift.
SH_VOCAB=$(sed -n 's/^TAG_VOCABULARY="\(.*\)"$/\1/p' "$LESSONS_SH" \
    | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')
# shellcheck disable=SC2016  # backticks are markdown syntax in the table rows.
MD_VOCAB=$(sed -n 's/^| `\([a-z][a-z0-9-]*\)` |.*/\1/p' "$SEED_LEDGER" \
    | LC_ALL=C sort | tr '\n' ' ')
assert_eq "ledger: TAG_VOCABULARY matches the LESSONS.md preamble table" \
    "$SH_VOCAB" "$MD_VOCAB"
assert_eq "ledger: the vocabulary is the expected closed set" \
    "agents evidence gate packaging process testing " "$SH_VOCAB"
# Every tag actually used in the ledger is in the vocabulary.
USED_TAGS=$(grep -o '<!-- tags: [^>]*-->' "$SEED_LEDGER" \
    | sed 's/<!-- tags: //; s/ *-->//' | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
    | grep -v '^$' | LC_ALL=C sort -u | tr '\n' ' ')
assert_eq "ledger: every tag in use is in the vocabulary" "$SH_VOCAB" "$USED_TAGS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 11: META-TESTS ==="

# Helper: build a stub copy of lessons.sh with one TEXT-anchored mutation, and
# refuse to proceed unless the mutation actually landed. A stub that silently
# failed to patch produces the same observable as a guard that does nothing.
#
# (claude-workflow-plugin-9hv4) EVERY call site below invokes this as
# `VAR=$(make_stub ...)` — a command substitution, which runs the function in
# a SUBSHELL. Any write this function made directly to $FAIL/$FAILED_TESTS on
# the failure path was therefore CONFINED TO THAT SUBSHELL and discarded the
# instant the substitution completed: the exact "bash functions invoked via
# $(...) run in a subshell; any variable they set is lost to the parent"
# lesson this ledger already records (LESSONS.md, the model-select.sh
# manual-adopt entry). Worse, the diagnostic printf had no `>&2`, so on
# failure it did not even reach the terminal — it was captured INTO the
# caller's own $VAR (e.g. $M8_SH) as if it were a stub path, and the `if`
# only ever tested the exit code, so the message went nowhere at all. Net
# effect: a stale sed anchor made the whole META block vanish from BOTH the
# Pass and the Fail count, with zero visible trace — discovered only because
# M8's own anchor does not exist on lessons.sh's pre-9hv4 shape, which is
# exactly the "run the new check against the unfixed state" step this task's
# devops checklist requires. Fixed by moving ALL counting to the call site
# (which runs in the PARENT shell, so it sticks) and sending the diagnostic
# to stderr (which is never the captured return value).
make_stub() {
    local name="$1" sed_expr="$2"
    local stub="$FIXTURE/lessons-$name.sh"
    sed "$sed_expr" "$LESSONS_SH" > "$stub"
    if cmp -s "$stub" "$LESSONS_SH"; then
        printf 'META setup: stub %s did not modify lessons.sh\n' "$name" >&2
        return 1
    fi
    if ! bash -n "$stub" 2>/dev/null; then
        printf 'META setup: stub %s is not valid bash\n' "$name" >&2
        return 1
    fi
    printf '%s' "$stub"
}

# Call-site helper for the failure branch every `if VAR=$(make_stub ...)`
# needs: runs in the PARENT shell (never inside make_stub's own subshell), so
# the count actually lands. $1 is the stub name, used verbatim in the
# recorded failure text so a stale anchor names itself in the summary.
make_stub_setup_failed() {
    local name="$1"
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META setup: stub '$name' failed (see stderr for which check)")
    printf '  FAIL: META setup: stub %s failed (see stderr for which check)\n' "$name"
}

# --- M1: stubbed normalizer -> dedup must fail -----------------------------
# Build a stub variant of lessons.sh with a broken `normalize()` that
# returns a random-per-call value, so two identical texts hash to
# different normalized strings and the dedup path can't trigger.
STUB_SH="$FIXTURE/lessons-broken.sh"
cp "$LESSONS_SH" "$STUB_SH"

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
    --tag testing >/dev/null
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$STUB_SH" add \
    "Broken-normalizer canary lesson" --source claude-workflow-plugin-test.m2 \
    --tag testing >/dev/null
AFTER_LINES=$(grep -c '^- ' "$FIXTURE/LESSONS.md")

# Expected: AFTER == BEFORE + 2 (dedup broken; both appended).
# If the test sees BEFORE + 1 here, the stub didn't actually break
# the normalizer, meaning the dedup-assertion's sensitivity is unproven.
assert_eq "M1: broken normalizer appends both copies (BEFORE+2)" \
    "$((BEFORE_LINES + 2))" "$AFTER_LINES"

# --- M2: stubbed validate_tag -> the `-->` tag REACHES the ledger ----------
# Proves section 8.1's byte-unchanged result is caused by the tag validation
# and not by `add` being broken in some unrelated way.
if M2_SH=$(make_stub "notagcheck" 's/^validate_tag() {$/validate_tag() { return 0 ;/'); then
    reseed
    snapshot
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M2_SH" add "An injected lesson" \
        --source claude-workflow-plugin-test.m2i \
        --tag 'gate --> <!-- recorded: 1999-01-01' >/dev/null 2>&1 || true
    assert_files_differ "M2: with validate_tag stubbed, the --> tag DOES reach the ledger" \
        "$FIXTURE/snapshot.md" "$FIXTURE/LESSONS.md"
    INJ_LINE=$(grep '^- An injected lesson' "$FIXTURE/LESSONS.md" || true)
    assert_contains "M2: the injected entry carries the forged 1999 date" \
        "1999-01-01" "$INJ_LINE"
    # The concrete damage: the line now carries TWO `recorded:` comments and
    # no longer matches the three-comment grammar section 10.2 asserts over
    # the whole ledger. Do not assert on what a specific extractor happens to
    # return — which field wins is an accident of greedy matching, and that
    # accident is exactly why the contract is "reject" rather than "reason
    # about whether this particular injection is exploitable".
    assert_eq "M2: the injected line carries a second recorded: comment" \
        "2" "$(printf '%s' "$INJ_LINE" | grep -o '<!-- recorded:' | grep -c .)"
    if printf '%s' "$INJ_LINE" \
        | grep -q '<!-- sources: [^>]*--> <!-- tags: [^>]*--> <!-- recorded: [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] -->$'; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("M2: the injected line violates the three-comment grammar")
        printf '  FAIL: M2 — the injected line still matches the grammar: %s\n' "$INJ_LINE"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "M2: the injected line violates the three-comment grammar"
    fi
else
    make_stub_setup_failed "notagcheck"
fi

# --- M3: stubbed comment-grammar guard -> prose `-->` corrupts read-back ---
if M3_SH=$(make_stub "nogrammar" "s/\\*'<!--'\\*|\\*'-->'\\*)/'@@nevermatches@@')/"); then
    reseed
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M3_SH" add \
        'Prose with --> <!-- tags: process --> an injected tail' \
        --source claude-workflow-plugin-test.m3 --tag gate >/dev/null 2>&1 || true
    M3_LINE=$(grep '^- Prose with -->' "$FIXTURE/LESSONS.md" || true)
    assert_contains "M3: without the grammar guard, the prose --> entry IS written" \
        "an injected tail" "$M3_LINE"
    # The concrete damage: strip_comments cuts at the FIRST `<!--`, so the
    # entry's prose reads back TRUNCATED. The lesson can never match itself
    # again (every re-add appends a duplicate), and a merge rewrite would
    # persist the truncation — silent, permanent text loss.
    #
    # An earlier version of this META compared the read-back TAGS instead and
    # passed on a trailing space rather than on any relocation: the extractor
    # returned "gate " and the assertion was != "gate". Assert the damage,
    # and print the value so a wrong-reason pass is visible.
    M3_PROSE=$(printf '%s' "$M3_LINE" \
        | sed -e 's/<!--.*$//' -e 's/^- //' -e 's/[[:space:]]*$//')
    if [ -n "$M3_LINE" ] && [ "$M3_PROSE" = "Prose with -->" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s (prose reads back as "%s")\n' \
            "M3: the entry's prose reads back TRUNCATED at the injected -->" "$M3_PROSE"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("M3: the entry's prose reads back TRUNCATED at the injected -->")
        printf '  FAIL: M3 — expected prose "Prose with -->", got "%s"\n' "$M3_PROSE"
    fi
else
    make_stub_setup_failed "nogrammar"
fi

# --- M4: a fixture with one untagged entry must be FLAGGED -----------------
# Proves section 10.1's "zero untagged" invariant can see an untagged entry
# at all. Without this, a filter that never matches anything would report a
# clean ledger forever.
reseed
printf -- '- A deliberately untagged canary entry <!-- sources: claude-workflow-plugin-test.m4 --> <!-- recorded: 2026-01-01 -->\n' \
    >> "$FIXTURE/LESSONS.md"
M4_OUT=$(LSH list --untagged)
assert_eq "M4: a fixture with one untagged entry reports exactly 1" \
    "1" "$(printf '%s' "$M4_OUT" | grep -c '^- ')"
assert_contains "M4: the flagged entry is the untagged canary" \
    "deliberately untagged canary" "$M4_OUT"
assert_eq "M4: the direct file count agrees" "1" "$(untagged_count "$FIXTURE/LESSONS.md")"

# --- M5: a duplicated entry must break prose uniqueness --------------------
reseed
# Read fully into a variable before appending: reading and writing the same
# file in one pipeline is unordered (SC2094), and here it would race the
# duplicate this META depends on.
M5_DUP=$(grep '^- ' "$FIXTURE/LESSONS.md" | head -1)
printf '%s\n' "$M5_DUP" >> "$FIXTURE/LESSONS.md"
M5_TOTAL=$(grep -c '^- ' "$FIXTURE/LESSONS.md")
M5_DISTINCT=$(grep '^- ' "$FIXTURE/LESSONS.md" | sed 's/ <!-- .*//' \
    | tr '[:upper:]' '[:lower:]' | sort -u | wc -l | tr -d ' ')
if [ "$M5_TOTAL" -ne "$M5_DISTINCT" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: %s (total=%s distinct=%s)\n' \
        "M5: a duplicated entry breaks the prose-uniqueness invariant" "$M5_TOTAL" "$M5_DISTINCT"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("M5: a duplicated entry breaks the prose-uniqueness invariant")
    printf '  FAIL: M5 — total=%s distinct=%s (should differ)\n' "$M5_TOTAL" "$M5_DISTINCT"
fi

# --- M6: a drifted TAG_VOCABULARY must break parity ------------------------
if M6_SH=$(make_stub "vocabdrift" 's/^TAG_VOCABULARY="\(.*\)"$/TAG_VOCABULARY="\1 security"/'); then
    M6_VOCAB=$(sed -n 's/^TAG_VOCABULARY="\(.*\)"$/\1/p' "$M6_SH" \
        | tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ')
    if [ "$M6_VOCAB" != "$MD_VOCAB" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "M6: a drifted TAG_VOCABULARY fails the parity assertion"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("M6: a drifted TAG_VOCABULARY fails the parity assertion")
        printf '  FAIL: M6 — drifted vocab still compared equal (%s)\n' "$M6_VOCAB"
    fi
else
    make_stub_setup_failed "vocabdrift"
fi

# --- M7 (claude-workflow-plugin-9hv4): stub the scoping to a no-op --------
# The task's own required META, verbatim: "stub the scoping so it always
# returns everything, and assert a test notices." Stubs tags_contain() to
# unconditionally match, so `--tag <anything>` returns the WHOLE ledger.
# Proves 9.6/9.7's "scoped is strictly smaller than unscoped, and the
# accounting names the gap" assertions are load-bearing: if tag scoping
# silently degraded into a no-op, THIS is what would catch it, because a
# suite that only ever compared "scoped vs zero" (never "scoped vs
# unscoped") would stay green while every consumer silently received the
# entire ledger on every "scoped" call.
if M7_SH=$(make_stub "notagscope" 's/^tags_contain() {$/tags_contain() { return 0 ;/'); then
    reseed
    M7_UNSCOPED=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M7_SH" list | grep -c '^- ')
    M7_SCOPED=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M7_SH" list --tag packaging | grep -c '^- ')
    # With tags_contain always matching, --tag packaging can no longer
    # exclude anything: scoped must equal unscoped exactly.
    assert_eq "M7: with tags_contain stubbed to always-match, --tag returns EVERYTHING" \
        "$M7_UNSCOPED" "$M7_SCOPED"
    # The accounting line lies in exactly the way that matters for 9hv4's
    # own stated failure mode: it claims nothing was excluded by a filter
    # that, on the real script, excludes most of the ledger.
    M7_STATS=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M7_SH" list --tag packaging 2>&1 >/dev/null)
    assert_contains "M7: the stubbed run's own accounting falsely claims NOTHING was excluded" \
        '"excluded_by_filter":0' "$M7_STATS"
    # Restore control: the SAME call against the SHIPPED script excludes
    # most of the ledger and says so — proving the assertions above actually
    # distinguish the stub from reality, not that they always read this way.
    reseed
    SHIPPED_SCOPED=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list --tag packaging | grep -c '^- ')
    SHIPPED_UNSCOPED=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list | grep -c '^- ')
    if [ "$SHIPPED_SCOPED" -lt "$SHIPPED_UNSCOPED" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "M7 restore control: the shipped script's --tag packaging DOES exclude entries"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("M7 restore control: the shipped script's --tag packaging DOES exclude entries")
        printf '  FAIL: M7 restore control — shipped scoped=%s unscoped=%s (should differ)\n' \
            "$SHIPPED_SCOPED" "$SHIPPED_UNSCOPED"
    fi
else
    make_stub_setup_failed "notagscope"
fi

# --- M8 (claude-workflow-plugin-9hv4): stub the --limit accounting to lie -
# Stubs the excluded_by_limit computation itself (not the cap enforcement)
# to a hardcoded 0, so --limit still trims stdout for real but the
# accounting no longer admits it. Proves the "excluded_by_limit reports the
# TRUE gap" assertions (9.8) are sensitive to the accounting lying about a
# real cap, not merely to a cap existing somewhere. A consumer that trusted
# "excluded_by_limit":0 without a cross-check would accept a scoped read
# that silently dropped entries under a cap and reported nothing wrong.
# shellcheck disable=SC2016  # single-quoted sed pattern; \$ must stay literal for sed, not expand in bash.
if M8_SH=$(make_stub "fakelimit" \
    's/^    local excluded_by_limit=\$((matched - returned))$/    local excluded_by_limit=0/'); then
    reseed
    M8_GATE_TOTAL=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M8_SH" list --tag gate | grep -c '^- ')
    if [ "$M8_GATE_TOTAL" -gt 1 ]; then
        M8_STATS=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M8_SH" list --tag gate --limit 1 2>&1 >/dev/null)
        M8_RETURNED=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$M8_SH" list --tag gate --limit 1 2>/dev/null | grep -c '^- ')
        # The cap IS still enforced on stdout (still exactly 1 line)...
        assert_eq "M8: the stub still enforces --limit on stdout for real" "1" "$M8_RETURNED"
        # ...but the accounting now lies about how much that cost.
        assert_contains "M8: the stubbed accounting falsely claims nothing was cut by --limit" \
            '"excluded_by_limit":0' "$M8_STATS"
        # A consumer cross-checking matched-minus-returned against the
        # claimed excluded_by_limit catches the lie directly: matched is
        # still reported truthfully (M8 only touched the OTHER field), so
        # matched-1 (the true gap) disagreeing with the claimed 0 exposes it.
        M8_MATCHED=$(printf '%s' "$M8_STATS" | sed -n 's/.*"matched":\([0-9]*\).*/\1/p')
        if [ "$((M8_MATCHED - 1))" -ne 0 ]; then
            PASS=$((PASS + 1))
            printf '  PASS: %s\n' "M8: matched-minus-returned disagrees with the stub's claimed excluded_by_limit, exposing the lie"
        else
            FAIL=$((FAIL + 1))
            FAILED_TESTS+=("M8: matched-minus-returned disagrees with the stub's claimed excluded_by_limit")
            printf '  FAIL: M8 — matched=%s (expected more than 1, to distinguish from the false 0)\n' "$M8_MATCHED"
        fi
        # Restore control: the SHIPPED script reports the REAL figure for
        # the identical call.
        reseed
        SHIPPED_LIMIT_STATS=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LESSONS_SH" list --tag gate --limit 1 2>&1 >/dev/null)
        SHIPPED_MATCHED=$(printf '%s' "$SHIPPED_LIMIT_STATS" | sed -n 's/.*"matched":\([0-9]*\).*/\1/p')
        assert_contains "M8 restore control: the shipped script reports the REAL excluded_by_limit" \
            "\"excluded_by_limit\":$((SHIPPED_MATCHED - 1))" "$SHIPPED_LIMIT_STATS"
    else
        printf '  note: M8 SKIPPED (fewer than 2 gate-tagged entries in this fixture; cap cannot be exercised)\n'
    fi
else
    make_stub_setup_failed "fakelimit"
fi

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
