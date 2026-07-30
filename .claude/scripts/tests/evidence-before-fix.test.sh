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
# ---------------------------------------------------------------------------
# EBF-CORE (claude-workflow-plugin-kfe) — the systematic-debugging merge.
#
# The upstream `systematic-debugging` methodology was MERGED into the existing
# evidence-before-fix protocol rather than vendored beside it: one authoritative
# debugging protocol, evidence-before-fix winning every conflict. The merged
# text lives in a delimited region:
#
#     <!-- EBF-CORE-START -->  ...  <!-- EBF-CORE-END -->
#
# inside each of the FOUR carriers' existing protocol sections, and it is
# byte-identical across all four.
#
# WHY A DELIMITED REGION AND NOT WHOLE-SECTION IDENTITY. Byte-identity across
# the three specialists is impossible and is not attempted: the shared skeleton
# is interleaved MID-SENTENCE with domain material (frontend names viewport /
# throttle / route / focus / React render order; devops names sandbox replay,
# soak, fault injection; backend names traces and profiler output). Enforcing
# whole-section identity would delete real guidance. HTML comments are the
# delimiters because they render invisibly in the prompt and are awk-extractable,
# matching the repo's shell-sentinel convention.
#
# THE VACUITY HOLE THIS CLOSES. Two EMPTY regions compare equal, so an identity
# assertion on its own is one `sed -i` from meaningless: strip every line
# between the markers in all four files and a naive checker still reports
# perfect parity. The guard is therefore three-part — the extracted region must
# (a) sit between markers that each appear exactly once, (b) be at least
# MIN_EBF_LINES lines, and (c) contain BOTH new sentinels. META-A below plants
# exactly that mutation and asserts the identity check passes (documenting that
# the hole is real) while the region checker rejects (documenting that it is
# closed).
#
# Exit codes:
#   0  every required file contains both original sentinels and both EBF-CORE
#      sentinels, every EBF-CORE region is non-vacuous and byte-identical to
#      qa.md's, and every META-TEST flags its planted mutation
#   1  one or more assertions failed, or the assertion count moved

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"

# Sentinels. Both must be present.
SENTINEL_MODE="evidence mode"
SENTINEL_ANTI="symptom-patching"

# EBF-CORE sentinels (kfe). Two clauses the merge contributed that no carrier
# carried before it: the hypothesis-isolation rule and the bounce-twice
# supremacy clause. Both are fixed-string, both live INSIDE the delimited
# region, and both are required there — which is what makes an emptied region
# fail rather than silently compare equal to its emptied twin.
SENTINEL_ONE_VAR="one variable at a time"
SENTINEL_DESIGN="question the design assumption"

EBF_START="<!-- EBF-CORE-START -->"
EBF_END="<!-- EBF-CORE-END -->"

# Floor for the extracted region, counted in NON-BLANK lines. The shipped
# region is 76 lines / 73 non-blank (measured 2026-07-30); 40 is comfortably
# below that, so ordinary prose edits do not trip it, and comfortably above
# any stub a region-emptying mutation would leave behind.
MIN_EBF_LINES=40

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

# --- EBF-CORE helpers -----------------------------------------------------

# ebf_extract <file> — print the region BETWEEN the markers, markers excluded.
# Prints nothing when either marker is absent, which the caller distinguishes
# from a short region via the marker count.
ebf_extract() {
    awk '
        /^<!-- EBF-CORE-START -->$/ { inside = 1; next }
        /^<!-- EBF-CORE-END -->$/   { inside = 0 }
        inside { print }
    ' "$1"
}

# ebf_region_status <file> — echo ONE status token. An stdout contract rather
# than a return code so a future caller can use it inside $(...) without the
# subshell swallowing the answer (LESSONS.md: command substitution runs in a
# subshell; encode the signal in stdout).
#
#   OK            markers appear exactly once each, region >= MIN_EBF_LINES,
#                 and BOTH EBF-CORE sentinels are inside the region
#   NO_FILE       the file does not exist
#   NO_MARKERS    a marker is missing, or appears more than once
#   SHORT_REGION  region below the floor — the vacuity hole (META-A)
#   NO_SENTINEL   region long enough but a sentinel is missing from it
ebf_region_status() {
    local f="$1" ns ne tmp n
    if [ ! -f "$f" ]; then
        printf 'NO_FILE'
        return 0
    fi
    ns=$(grep -cF -- "$EBF_START" "$f" | tr -d ' \n')
    ne=$(grep -cF -- "$EBF_END" "$f" | tr -d ' \n')
    if [ "$ns" != "1" ] || [ "$ne" != "1" ]; then
        printf 'NO_MARKERS'
        return 0
    fi
    tmp=$(mktemp -t ebf-region.XXXXXX)
    ebf_extract "$f" > "$tmp"
    # NON-BLANK lines, not `wc -l`: a region emptied to 60 blank lines would
    # clear a raw line-count floor while carrying no instruction at all.
    n=$(grep -c . "$tmp" | tr -d ' \n')
    if [ "$n" -lt "$MIN_EBF_LINES" ]; then
        rm -f "$tmp"
        printf 'SHORT_REGION'
        return 0
    fi
    if ! grep -qF -- "$SENTINEL_ONE_VAR" "$tmp" \
        || ! grep -qF -- "$SENTINEL_DESIGN" "$tmp"; then
        rm -f "$tmp"
        printf 'NO_SENTINEL'
        return 0
    fi
    rm -f "$tmp"
    printf 'OK'
}

# ebf_identical <fileA> <fileB> — echo SAME or DIFFERENT. Compared through
# temp files with `cmp` rather than through `$(...)` string equality: command
# substitution strips ALL trailing newlines, so a region differing only in its
# trailing blank lines would compare equal. This is a BYTE comparison.
ebf_identical() {
    local ta tb verdict
    ta=$(mktemp -t ebf-a.XXXXXX)
    tb=$(mktemp -t ebf-b.XXXXXX)
    ebf_extract "$1" > "$ta"
    ebf_extract "$2" > "$tb"
    if cmp -s "$ta" "$tb"; then
        verdict=SAME
    else
        verdict=DIFFERENT
    fi
    rm -f "$ta" "$tb"
    printf '%s' "$verdict"
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

# --- EBF-CORE: the two new sentinels, file-wide ---------------------------
#
# File-wide (not region-scoped) on purpose: this pair answers "did the merged
# text reach this carrier at all". The region-scoped version of the same check
# is inside ebf_region_status, and it is what closes the vacuity hole.

for f in "${REQUIRED_FILES[@]}"; do
    name=$(basename "$f" .md)
    if grep -qF -- "$SENTINEL_ONE_VAR" "$f"; then hit=yes; else hit=no; fi
    assert_eq "EBF-CORE sentinel (hypothesis isolation): $name" "yes" "$hit"
    if grep -qF -- "$SENTINEL_DESIGN" "$f"; then hit=yes; else hit=no; fi
    assert_eq "EBF-CORE sentinel (bounce-twice supremacy): $name" "yes" "$hit"
done

# --- EBF-CORE: region present and NON-VACUOUS -----------------------------

for f in "${REQUIRED_FILES[@]}"; do
    name=$(basename "$f" .md)
    assert_eq "EBF-CORE region: $name has markers, is above the floor, carries both sentinels" \
        "OK" "$(ebf_region_status "$f")"
done

# --- EBF-CORE: byte-identity against qa.md as the reference copy ----------
#
# qa.md is the reference because it is the carrier whose protocol section
# already held the framework before the merge (section 5, the J27 root-cause
# framework); the other three grew their sections around it.

EBF_REFERENCE="$AGENTS_DIR/qa.md"
for f in "$AGENTS_DIR/backend.md" "$AGENTS_DIR/frontend.md" "$AGENTS_DIR/devops.md"; do
    name=$(basename "$f" .md)
    assert_eq "EBF-CORE region: $name is byte-identical to qa.md's" \
        "SAME" "$(ebf_identical "$EBF_REFERENCE" "$f")"
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

# --- META-A: the vacuity hole, planted and closed -------------------------
#
# THE DESIGN HOLE A NAIVE VERSION LEAVES OPEN. Two EMPTY regions compare equal.
# A single `sed -i '/EBF-CORE-START/,/EBF-CORE-END/{//!d}'` across all four
# carriers deletes the entire merged protocol and a naive identity-only checker
# reports perfect parity.
#
# This META plants exactly that mutation in two stub files and asserts BOTH
# halves of the story:
#   A1  the identity check ALONE says SAME — the hole is real, not theoretical
#   A2  ebf_region_status says SHORT_REGION — the floor closes it
#
# A1 is not a bug being tolerated; it is the reason A2 has to exist, asserted
# so that removing the floor cannot be mistaken for a harmless simplification.

META_DIR=$(mktemp -d -t ebf-meta.XXXXXX)

meta_write_stub() {
    # meta_write_stub <path> <body-file-or-empty>
    {
        printf -- '---\n'
        printf 'name: ebf-meta-stub\n'
        printf 'description: META-TEST stub carrying EBF-CORE markers\n'
        printf -- '---\n\n'
        printf '## Evidence-before-fix protocol (bug-typed tasks)\n\n'
        printf '%s\n' "$EBF_START"
        if [ -n "${2:-}" ] && [ -f "$2" ]; then
            cat "$2"
        fi
        printf '%s\n' "$EBF_END"
        printf '\n## What QA will test\n'
    } > "$1"
}

# Both stubs: markers present, region EMPTY.
meta_write_stub "$META_DIR/empty-a.md" ""
meta_write_stub "$META_DIR/empty-b.md" ""

assert_eq "META-A1: identity ALONE passes on two emptied regions (the hole is real)" \
    "SAME" "$(ebf_identical "$META_DIR/empty-a.md" "$META_DIR/empty-b.md")"
assert_eq "META-A2: region checker REJECTS an emptied region (the hole is closed)" \
    "SHORT_REGION" "$(ebf_region_status "$META_DIR/empty-a.md")"

# --- META-B: a one-byte difference must not read as identical -------------
#
# The complementary failure: regions that are full but have drifted. Seeded
# from the SHIPPED region so the mutation is against real content, with the
# difference confined to a single byte.

ebf_extract "$EBF_REFERENCE" > "$META_DIR/real-region.txt"
# Anchor on TEXT, never a line number: append one character to the first line
# that carries the hypothesis-isolation sentinel.
awk -v s="$SENTINEL_ONE_VAR" '
    !done && index($0, s) { print $0 "."; done = 1; next }
    { print }
' "$META_DIR/real-region.txt" > "$META_DIR/drifted-region.txt"

# Verify the mutation LANDED before asserting on it: a no-op awk would make
# META-B report DIFFERENT for the wrong reason (it would report SAME, and a
# silently-unmutated fixture is the classic false green).
META_B_DELTA=$(( $(wc -c < "$META_DIR/drifted-region.txt") - $(wc -c < "$META_DIR/real-region.txt") ))
assert_eq "META-B0: the one-byte mutation actually landed" "1" "$META_B_DELTA"

meta_write_stub "$META_DIR/full-a.md" "$META_DIR/real-region.txt"
meta_write_stub "$META_DIR/full-b.md" "$META_DIR/drifted-region.txt"

assert_eq "META-B1: both drift stubs are individually well-formed (not vacuously unequal)" \
    "OK" "$(ebf_region_status "$META_DIR/full-a.md")"
assert_eq "META-B2: identity check flags a ONE-BYTE region difference" \
    "DIFFERENT" "$(ebf_identical "$META_DIR/full-a.md" "$META_DIR/full-b.md")"

# --- META-C: a full region missing a sentinel is rejected -----------------
#
# Guards the third leg of ebf_region_status. Anchored on text, not line number.

grep -vF -- "$SENTINEL_DESIGN" "$META_DIR/real-region.txt" > "$META_DIR/no-sentinel-region.txt"
META_C_DROPPED=$(( $(grep -c . "$META_DIR/real-region.txt") - $(grep -c . "$META_DIR/no-sentinel-region.txt") ))
assert_eq "META-C0: the sentinel-stripping mutation actually removed a line" "1" "$META_C_DROPPED"

meta_write_stub "$META_DIR/no-sentinel.md" "$META_DIR/no-sentinel-region.txt"
assert_eq "META-C1: region checker REJECTS a long region missing a sentinel" \
    "NO_SENTINEL" "$(ebf_region_status "$META_DIR/no-sentinel.md")"

# --- META-D: a missing marker is not silently an empty region -------------

sed 's/^<!-- EBF-CORE-END -->$//' "$META_DIR/full-a.md" > "$META_DIR/no-end-marker.md"
assert_eq "META-D0: the end-marker removal actually landed" \
    "0" "$(grep -cF -- "$EBF_END" "$META_DIR/no-end-marker.md" | tr -d ' \n')"
assert_eq "META-D1: region checker REJECTS a file with a missing end marker" \
    "NO_MARKERS" "$(ebf_region_status "$META_DIR/no-end-marker.md")"

# Restore-after: the METAs only ever wrote into $META_DIR, never the live repo.
rm -rf "$META_DIR"

# --- Summary -------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi

# Completeness line. A "no failures" signal is not a "the run finished" signal
# (LESSONS.md): a run that aborted halfway also reports zero failures. The
# expected count is hardcoded so DROPPING an assertion fails loudly instead of
# quietly shrinking the suite.
#
#   4  original protocol-sentinel assertions (one per carrier)
#   8  EBF-CORE sentinels        (2 sentinels x 4 carriers)
#   4  EBF-CORE region non-vacuity (one per carrier)
#   3  EBF-CORE byte-identity vs qa.md
#   1  original META-TEST
#   2  META-A (hole is real / hole is closed)
#   3  META-B (mutation landed / stub well-formed / one-byte drift caught)
#   2  META-C (mutation landed / missing sentinel caught)
#   2  META-D (mutation landed / missing marker caught)
EXPECTED_ASSERTIONS=29
RUN=$((PASS + FAIL))
printf '\nTotal: %d assertion(s) run (expected %d)\n' "$RUN" "$EXPECTED_ASSERTIONS"
if [ "$RUN" -ne "$EXPECTED_ASSERTIONS" ]; then
    printf 'INCOMPLETE: assertion count moved. Update EXPECTED_ASSERTIONS deliberately, or find the dropped assertion.\n' >&2
    exit 1
fi

printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
