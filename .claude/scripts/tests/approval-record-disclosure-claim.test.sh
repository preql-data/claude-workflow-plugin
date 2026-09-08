#!/bin/bash
# approval-record-disclosure-claim.test.sh — L1 unit fixture for
# claude-workflow-plugin-pqnd: the approval record (and the sibling
# COMPLETION record) are DISCLOSURE, not TAMPER-EVIDENCE, and nothing in the
# operator-facing surface this file scans (Section 1S; originally just the
# six sites below, widened in round 6) may regress back to that claim.
#
# THE FACT THIS FILE GUARDS AGAINST REGRESSING. qa-gate.sh's approval record
# and verify-before-stop.sh's release predicate used to call the
# `QA-GATE APPROVED change_set_hash=<h>` comment "tamper-evident" in six
# places (qa-gate.sh:2113; verify-before-stop.sh:3074, 3403, 3424, 6203,
# 7084 at the time pqnd was filed) and refused a bare `bd label add
# qa-approved` specifically on that claimed basis. The claim was FALSE and
# CANNOT be made true in this design: the writer (`qa-gate.sh approve`) and a
# forger (anyone who can run `bd comment`) have IDENTICAL privileges, and
# there is no secret the gate holds that a local writer could not also read.
# A byte-0 well-formed `QA-GATE APPROVED ...` comment satisfies every reader
# with no `approve` ever having run — see THE FACT section of the pqnd task
# for the measured jq reproduction.
#
# pqnd's ruling: correct the CLAIM, keep the CONTROL. The mechanism's real
# job — refusing an approval with no record (OMISSION) and refusing a record
# whose hash does not bind the current change set (STALENESS) — is genuine
# and stays. Only the adjective describing what the record PROVES was wrong.
#
# THE CASE-VARIANT DISCOVERY, folded into scope here because it sits in the
# SAME two files this task already edits (not a different task's scope): a
# case-SENSITIVE audit for "tamper-evident" found exactly six hits and missed
# two more in the same two files — qa-gate.sh's own "TAMPER-EVIDENT APPROVAL
# RECORD" (ALL-CAPS) and verify-before-stop.sh's `approval_binding_attests`
# "tamper-EVIDENT record" (mixed-case) — plus two markdown-obfuscated hits in
# docs (`Tamper-*evident*`, filed separately: the docs are not
# qa-gate.sh/verify-before-stop.sh and carry their own audit-row provenance
# discipline per CONTRIBUTING.md). The second of the two in-file misses
# renders into the EXACT SAME `emit_block` call as the operator-facing
# LABEL_WITHOUT_RECORD text (verify-before-stop.sh, `$(approval_binding_
# attests)` is concatenated directly into that block), so a case-sensitive
# checker would have shipped a corrected headline sentence sitting fifteen
# lines above a contradicting one in the SAME paragraph. Section 1's scan is
# therefore explicitly case-insensitive and markdown-emphasis-agnostic
# (strips `*`/`_`/backtick before matching) — the normalize step IS the fix
# for the blind spot, not an incidental implementation choice, and 1M.c pins
# it against every variant actually found.
#
# PAIRING (.claude/tests/README.md "The pairing requirement"). Section 1 is
# the negative control proper (must never find the banned claim); 1M proves
# it is not vacuous (a mutant that reintroduces the claim, in either file's
# own shape, MUST be caught, including the case/markdown variants that were
# the whole discovery). Section 2 is the DISCRIMINATOR: it does not grep the
# file, it extracts the shipped LABEL-WITHOUT-RECORD-BLOCK and
# APPROVAL-BINDING-TEXT regions VERBATIM, stubs only `emit_block` (capture
# instead of print+exit) and the two inputs the block reads
# (CURRENT_TASK/APPROVAL_RECORD_DETAIL), and RUNS them — observing the exact
# bytes an operator would read at a real Stop block, built from the real
# `approval_record_causes`/`approval_binding_attests` functions. 2M is that
# leg's own non-vacuity proof.
#
# WHICH CONTROL IS LOAD-BEARING (R1-F1, independent review, pqnd round 1,
# reviewed_hash d1246134 — confirmed independently, not taken on faith).
# BANNED_CLAIM_PATTERN (sections 1/1M/2.10/2M) is a finite phrase
# ALTERNATION — a DENYLIST. Sol's reproduction: appending "This
# provenance-authenticated record can only be produced by qa-gate.sh
# approve." asserts the identical false tamper-evidence claim in unlisted
# words and passes every check in those sections, because none of them is
# one of the five listed phrases. A denylist answers "which phrases are
# forbidden" and is wrong the moment someone (or something adversarial)
# thinks of a phrase not on the list — the SAME shape this codebase already
# hit and fixed for ingest content (a denylist defeated by `=`, then `[`,
# then regex metacharacters, then glob metacharacters, eventually REPLACED
# by a closed allowlist grammar rather than grown a synonym at a time).
# Section 2P is that replacement, applied here: it pins the runtime-rendered
# LABEL_WITHOUT_RECORD block by EXACT CONTENT (sha256). Only the pinned
# bytes are permitted; ANY other text — an enumerated synonym, an
# unenumerated one nobody has thought of yet, a stray extra sentence, a
# reordered paragraph — moves the hash and fails. Section 2Q turns Sol's
# finding and four more evasions into a permanent regression: each one
# provably passes the OLD diagnostic (documenting the gap this section
# closes) and provably fails the NEW pin (documenting the fix).
#
# 2P IS THE LOAD-BEARING CONTROL FOR "DOES THE OPERATOR-FACING TEXT SAY
# EXACTLY THE REVIEWED THING". Sections 1/1M/2.10/2M are KEPT — not because
# they still guard anything the pin does not, but because a hash mismatch
# alone does not tell a maintainer WHAT changed, and a readable phrase-level
# diagnostic does. Do not maintain BANNED_CLAIM_PATTERN believing it is the
# guard; extending its alternation is not a fix for anything 2P/2Q do not
# already catch, and is the mistake this section exists to stop repeating.
#
# FOUR GUARD SHAPES, FOUR INDEPENDENT-REVIEW ROUNDS, EACH DEFEATED ON FIRST
# CONTACT — READ THIS BEFORE BUILDING A FIFTH. (1) A phrase denylist
# (BANNED_CLAIM_PATTERN) — defeated by an unlisted synonym, R1-F1. (2) A
# content pin (2P) over the rendered LABEL_WITHOUT_RECORD template — correct
# for the template, but its driver synthesized inputs instead of exercising
# the real producers, R2-F1. (3) Source pins on every producer PLUS a static
# call-graph closure check (is_local_fn/extract_calls) meant to catch a NEW
# unaccounted producer automatically — the closure check itself was defeated
# by a global-variable data-flow path no call graph can see and by an
# alternate function-definition syntax the regex never covered, R3-F1/R3-F2;
# that mechanism was REMOVED rather than re-guarded, matching the operator's
# standing precedent for the design-conflict waiver and the quarantine
# mechanism. (4) A RENDERED-OUTPUT STATE MATRIX (Section 4) — 7 states, each
# driving the real end-to-end code and pinned by sha256: correct for the ONE
# emit_block site it drives, but R4-F1 (round 4) confirmed a SECOND,
# entirely separate operator-facing emit_block site (REVIEW_DISCIPLINE_
# BLOCKED, verify-before-stop.sh) that no state reaches, moves no pin, and
# matches no phrase. THE OPERATOR'S RULING ON THAT FOURTH FINDING: stop.
# Four shapes, each covering a proper subset of the real surface, each
# looking complete when it shipped — there is no principled reason a fifth
# would be different. The residual is now STATED (Section 4's own header,
# below, names R4-F1 exactly) and FILED (claude-workflow-plugin-7n36) rather
# than chased into a fifth mechanism. A maintainer who wants to extend this
# file should read that task first, not propose "just widen the pattern
# again" — that proposal has already been tried, differently, four times.
#
# WIDENED SCOPE (round 6, orchestrator finding 2026-09-06T17:57:25Z). Every
# section above scans exactly two globs — qa-gate.sh and
# verify-before-stop.sh, canonical + 7 e2e mirrors each, 16 files, asserted
# at 1.0/1.0b as "exactly 8 copies" of each. That scan is real and correct
# for what it covers; its INPUT SET was narrower than the claim it
# licensed. HANDOFF.md:102 stated, in an operator-facing release-record
# document, "the Stop gate now requires a tamper-evident approval record
# whose change_set_hash matches the current diff" — the exact false claim
# this file exists to correct — and carried it through FOUR independent-
# review rounds (this file's own R1-R5 above) because none of them ever
# looked at a file named HANDOFF.md. Same shape as the finding that closed
# Family 1: a check that is real, correct, and called, with an input set
# narrower than the claim it licenses, reads as "no banned claim ships" and
# means "not in these 16 files".
#
# THE FIX (Section 1S below): the scan widens from two globs to an
# explicit, ENUMERATED allowlist of what IS scanned, defined POSITIVELY —
# not a denylist of paths to skip. This arc has already lost six rounds to
# denylists (see "WHICH CONTROL IS LOAD-BEARING" above); the fix does not
# add a seventh. "Operator-facing surface" NAMES that enumeration
# (discover_operator_facing_surface, below) — it is not a claim that the
# enumeration equals everything the plugin ships (R6-F1, independent
# review round 6: an earlier version of this paragraph claimed exactly
# that, calling it "the full in/out partition", and was false — see
# Section 1S's own header for the corrected framing and what to compare
# against if you need the broader answer). 1SM is this widening's
# pairing-requirement control, proving the widened discovery would have
# caught the real HANDOFF.md miss without mutating the real file.
#
# ALSO FIXED IN THIS ROUND, same defect family, found only because the
# widened scan was run empirically against them before this file could
# assert anything about them: docs/HOOKS.md:1767 and
# docs/RELEASE_AUDIT.md:766 (both markdown-emphasis-wrapped
# "Tamper-*evident*", tracked separately as claude-workflow-plugin-xo0p and
# closed here rather than left to fail the moment the widened scan
# shipped). Also found this round: review-check.sh:2556 ("the tested proof
# that property must survive" — ordinary English about an unrelated
# escalation-tracking invariant) collided with BANNED_CLAIM_PATTERN's
# "proof that" alternative and was reworded to "the tests proving this
# property must survive" (no change in meaning) — but calling that
# collision INCIDENTAL was wrong: a later whole-tree sweep (R6-F4,
# independent review round 6) found the SAME "proof that" alternative
# matching ordinary English in nine further in-tree files with no relation
# to any forgery claim. It was SYSTEMATIC, not incidental, and was REMOVED
# from the pattern rather than reworded around again — see
# BANNED_CLAIM_PATTERN's own definition below for the fuller argument.
#
# ROUND 7 (independent review round 7, R7-F1/R7-F2). R7-F1 (HIGH): the
# R6-F3 set pins compared relpath_join's sorted output against constants
# captured in C-collation order, but relpath_join's own `sort` was not
# locale-pinned — under a UTF-8 collating locale the comparison failed
# SPURIOUSLY, with the identical 1S.2b/1S.10b failure signature as the
# genuine drop-plus-add attack the pins exist to catch, and a printed
# remediation recipe that would lead a maintainer to "fix" it by
# rewriting the pin into their own locale's order. Fixed by pinning
# `LC_ALL=C sort` at the one site that determines final order
# (relpath_join). NOTE (R8-F1, independent review round 8): this
# paragraph used to go on to claim that fix superseded every OTHER bare
# sort in this file too, "verified by reading every call site" — that
# claim was false for two of the eleven; see the ROUND 8 paragraph below
# and relpath_join's own comment, further down this file, for the
# corrected census and the rule. 1S.13 (below) proves the pin is
# load-bearing: it drives the shipped function, unmodified, under two
# forced non-C locales, and drives a copy with the pin stripped under the
# same forced locale to prove it breaks without the fix. R7-F2 (LOW):
# Section 1's own two banners (the block comment above and its runtime
# printf) claimed a scope wider than Section 1 actually scans
# (review-check.sh's copies are scanned too, but at 1S.1, not here) — true
# rather than false, and not the sixth R6-F1 instance (nothing was left
# unscanned as a result), but the same sentence-shape and worth ending
# while the file was open anyway; both now name the two scripts Section 1
# actually scans, matching the Sections list below. Also added this
# round: 1M.c5, a positive-detection assertion for "cannot be forged" —
# the one BANNED_CLAIM_PATTERN alternative that had carried no coverage
# anywhere in this file since the pattern was written.
#
# ROUND 8 (independent review round 8, R8-F1 through R8-F4 — all below
# risk_threshold=high). R8-F1 (MEDIUM): the ROUND 7 paragraph above
# overstated its own fix, claiming relpath_join's LC_ALL=C pin
# "superseded" every other discover_* function's internal sort, "verified
# by reading every call site" — not true of all of them. Corrected
# census (three genuinely different reasons, not one) and the
# pin-together-or-not-at-all rule are at relpath_join's own comment,
# below (verified by MUTATION — reversing each of this file's 11 bare
# sort sites individually and re-running — not by reading).
# R8-F2 (MEDIUM): the 3.0/3.1 runtime banners (below) claimed "every
# source region"/"each contributor", the same totality claim this file's
# own 3.2-removal note (also below) had already disavowed by name since
# round 5; scoped to name what they actually enumerate (the call-graph-
# reachable set, R2-F1's own term) rather than asserting totality. R8-F3
# (LOW): 1M.c7 (below) adds the positive-detection assertion the SPACE
# form "tamper evident" had carried none of, unlike its three sibling
# alternatives. R8-F4 (LOW): the Sections list entry 1 (below) said "each
# script" unqualified where Section 1 scans exactly two; scoped to match,
# and the round-7-fix comment's claim that the list was "already worded
# this correctly" (false when written) is dropped rather than repeated.
#
# Sections:
#   1   SOURCE SCAN — zero banned-claim hits across all 8 copies of each of
#       the two scripts scanned here (qa-gate.sh, verify-before-stop.sh;
#       canonical + 7 e2e fixture mirrors each), and the corrected
#       replacement language IS present. DIAGNOSTIC, not load-bearing (see
#       above) — a fast, readable, file-level sanity check.
#   1M  META — reintroduce the claim (qa-gate.sh shape, verify-before-
#       stop.sh shape, an ALL-CAPS shape, and a markdown-emphasis shape) and
#       prove the scanner catches every one; restore control on the shipped
#       files
#   1S  WIDENED SCAN SCOPE (round 6) — the SOURCE SCAN's file-discovery
#       widened from two globs to an explicit, enumerable allowlist (named
#       "operator-facing surface" below — a term this section's header
#       defines, not a claim of totality; R6-F1): review-check.sh (the
#       third script the brief names) + all three scripts' fixture
#       mirrors, docs/**/*.md (excl. docs/reviews/**),
#       HANDOFF/README/CONTRIBUTING/CLAUDE.md, every plugin.json-installed
#       file (parsed from the manifests with jq, not hand-copied),
#       .claude/agents/*.md. Zero banned-claim hits asserted per category
#       and across the deduplicated whole; each named OUT-OF-SCOPE example
#       proven ABSENT from the discovered set rather than only described
#       in prose. 1S.12M (R6-F2) makes the docs/reviews/** exclusion
#       itself load-bearing; 1S.2b/1S.8b/1S.10b (R6-F3) pin the
#       docs/plugin-installed/union sets exactly, not just their counts;
#       1S.13 (R7-F1) proves those SET PINS do not depend on the ambient
#       locale, by driving the shared relpath_join helper, unmodified,
#       under two forced non-C locales, and by driving a locale-pin-
#       stripped copy of it under the same forced locale to prove the pin
#       is load-bearing.
#   1SM META for 1S — the pairing requirement applied to DISCOVERY BREADTH
#       rather than phrase-matching accuracy (1M already covers the
#       latter): seed the real historical HANDOFF.md defect string into a
#       sandbox (never the real file), prove the widened discovery finds
#       it and the scan reports a hit, prove the OLD two-glob discovery
#       structurally never could, restore control on the real PROJECT_DIR
#       via the identical function.
#   2   RUNTIME-OBSERVED LEG — drive the shipped LABEL_WITHOUT_RECORD block
#       for real and assert the OMISSION/STALENESS/FORGERY text renders,
#       the banned claim does not, and the operational recipe is unchanged
#       (anti-overreach: behaviour, not just wording, is asserted intact)
#   2M  META — mutate the extracted region back to the banned claim and
#       prove section 2's own assertion catches it; restore control on the
#       shipped region
#   2P  CONTENT PIN (R1-F1 fix) — THE LOAD-BEARING CONTROL. The rendered
#       LABEL_WITHOUT_RECORD block must equal a reviewed sha256 exactly;
#       any other content, however worded, fails. Includes its own
#       trivial-sensitivity META (one appended byte must move the hash) and
#       the anti-overreach recipe for a legitimate future rewording.
#   2Q  EVASION REGRESSION (R1-F1) — Sol's reproduction plus four more,
#       each asserted BOTH ways: the phrase diagnostic does NOT catch it
#       (the gap) and the content pin DOES (the fix)
#   3   TRANSITIVE SOURCE PINS (R2-F1 fix) — 2P pinned the TEMPLATE; this
#       pins the CONTRIBUTORS the template interpolates but section 2's
#       driver synthesizes (APPROVAL_RECORD_DETAIL's two producers,
#       checks_scope_note, and — transitively — everything IT calls) so a
#       claim written at any real producer, not just inside the template,
#       fails the suite. (3.2, the static call-graph closure check that
#       used to sit here, was REMOVED in the R3-F1/R3-F2 fix below — not
#       replaced in place; see Section 4's own header.) 3.3 proves the R2-F1
#       fix the way 2Q proves R1-F1's.
#   4   RENDERED-OUTPUT STATE MATRIX (R3-F1/R3-F2 fix; R4-F1 residual
#       stated and filed, not fixed) — 7 representative states (M1-M7),
#       each driving the REAL end-to-end LABEL_WITHOUT_RECORD_BLOCK code
#       and pinning the result by sha256, replacing 3.2's defeated static
#       closure computation with "these N states, actually run" rather than
#       "every producer, statically enumerated". 4.M is the per-state
#       one-byte-sensitivity META; 4.V1/4.V2 prove the R3-F1/R3-F2 fixes the
#       way 2Q/3.3 prove theirs. Its own header states the coverage
#       residual explicitly, including R4-F1's confirmed second emit_block
#       site this matrix does not drive — filed as
#       claude-workflow-plugin-7n36, not chased into a fifth guard shape.
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
QAG="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"
FIXTURES_DIR="$PROJECT_DIR/.claude/tests/e2e/fixtures"

for f in "$QAG" "$VBS"; do
    if [ ! -f "$f" ]; then
        printf 'approval-record-disclosure-claim.test: artifact under test missing: %s\n' "$f" >&2
        exit 2
    fi
done
if [ ! -d "$FIXTURES_DIR" ]; then
    printf 'approval-record-disclosure-claim.test: fixtures dir missing: %s\n' "$FIXTURES_DIR" >&2
    exit 2
fi

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

contains_count() {
    printf '%s' "$2" | grep -cF -- "$1" 2>/dev/null || true
}

assert_contains() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -gt 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected to CONTAIN: %s\n' "$name" "$needle"
    fi
}

# assert_absent <name> <needle> <haystack> — R5-F2 (independent review round
# 5): called once, at assertion 4.6b, and NEVER DEFINED — this exact file,
# built to catch "a check that claims to check and cannot run", shipped one.
# `set -u` (line 1 of this file) only traps an unset VARIABLE; an unresolved
# COMMAND under `set +e` (no `set -e` anywhere here) just prints
# "command not found" to stderr, returns 127, and the script carries on —
# so 4.6b was neither PASS nor FAIL, in EVERY run since it was written,
# through four independent-review rounds and two full four-tier acceptance
# runs, none of which caught it (shellcheck cannot distinguish an unresolved
# name from an intentional external command; a stable pass COUNT proved the
# number stable, not that every named assertion had actually run). Dropped
# in verbatim from gate-claim-honesty.test.sh:257, the house definition —
# not reinvented — so this file's "absent" semantics match the one other
# spec in this codebase that already needed them.
assert_absent() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -eq 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected NOT to contain: %s\n' "$name" "$needle"
    fi
}

# extract_region <src> <BEGIN-marker> <END-marker> <out> — text-anchored,
# never line-numbered (same helper as gate-claim-honesty.test.sh, WIDENED
# here — this file's own local copy only, gate-claim-honesty.test.sh's is
# untouched). Reports a miss (exit 7) rather than silently extracting
# nothing.
#
# WIDENED FOR R2-F1'S NESTED SENTINELS. gate-claim-honesty.test.sh's version
# requires `index($0, b) == 1` — the marker at COLUMN 1 exactly — which
# every PRE-EXISTING sentinel in verify-before-stop.sh satisfies (they wrap
# top-level functions/if-blocks). Section 3's APPROVAL-RECORD-DETAIL-INIT
# and -WORKTREE-APPEND sentinels are nested inside indented if/else bodies,
# matching the indentation of the comments already around them (house
# style) — so they do NOT start at column 1, and the strict check silently
# extracted an EMPTY region for both (found empty, not "not found": `inr`
# never went true, so `found` stayed 0 too — actually the exit-7 guard DOES
# catch this, since `found` requires the begin-marker to match at least
# once — this was caught by 3.0a/3.0b's own non-vacuity assertions the first
# time this section was run, before either hash constant was hand-computed
# against real output). Matching "marker after optional leading whitespace"
# is a STRICT SUPERSET of "marker at column 1" (zero leading whitespace is
# one valid case), so this widening cannot change what any EXISTING
# column-1 sentinel extracts — verified directly: LABEL-WITHOUT-RECORD-BLOCK
# and APPROVAL-BINDING-TEXT extract byte-identical regions before and after.
extract_region() {
    local src="$1" b="$2" e="$3" out="$4"
    awk -v b="$b" -v e="$e" '
        function starts_with_ws_then(line, marker,    idx, prefix) {
            idx = index(line, marker)
            if (idx == 0) return 0
            prefix = substr(line, 1, idx - 1)
            return (prefix ~ /^[ \t]*$/)
        }
        starts_with_ws_then($0, b) { inr = 1; found = 1 }
        inr { print }
        starts_with_ws_then($0, e) { inr = 0 }
        END { if (!found) exit 7 }
    ' "$src" > "$out"
}

# normalize_claim_text — fold case and strip markdown emphasis/code markers
# (`*`, `_`, backtick) so a disguised phrase ("Tamper-*evident*",
# "TAMPER-EVIDENT", "tamper_evident") normalizes to the same bytes a plain
# phrase would. THIS NORMALIZATION IS THE FIX for the case-variant discovery
# documented in the file header — 1M.c pins it directly.
normalize_claim_text() {
    tr '[:upper:]' '[:lower:]' | tr -d '*`_'
}

# banned_claim_count <file> — count of LINES (post-normalization) matching
# any banned claim. A count, not a boolean, so 1M can assert "at least the
# mutation's line" rather than merely non-zero.
#
# "proof that" REMOVED (R6-F4, independent review round 6). It matched
# ordinary English with no relation to any forgery claim in NINE in-tree
# files outside this guard's scope (codex-review.sh, .claude/tests/
# README.md, denylist-shared.sh, workflow-doctor.test.sh, design-gate-
# precheck-wiring.test.sh, design-conform.test.sh, two e2e .ts specs,
# CHANGELOG.md) — SYSTEMATIC noise, not the one incidental collision it was
# first taken for (review-check.sh:2556, reworded rather than removed at
# the time; see the file header's "ALSO FIXED IN THIS ROUND" paragraph).
# It also caught nothing the other four alternatives do not: AT THE TIME
# of this removal, every positive-detection string this file exercised
# (1M.c1-c4 below, and the seeded HANDOFF line in 1SM) matched via
# tamper-evident, "tamper evident", or unforgeable alone. A false-positive
# channel that pressures maintainers into rewording honest prose to go
# green is a real cost in a repo whose thesis is that documentation must
# be honest — do not re-add it as a sixth alternative without a positive
# string that needs it and that nothing else here already catches.
# "cannot be forged" itself carried no positive-detection coverage
# anywhere in this file until 1M.c5 (added at pqnd round 7, R7 "also
# include") closed that gap directly — see 1M.c5 below.
BANNED_CLAIM_PATTERN='tamper-evident|tamper evident|unforgeable|cannot be forged'
banned_claim_count() {
    normalize_claim_text < "$1" | grep -cE "$BANNED_CLAIM_PATTERN" 2>/dev/null || true
}
# banned_claim_count_text <text> — same predicate over a captured string
# rather than a file, for the runtime-observed leg in section 2.
banned_claim_count_text() {
    printf '%s' "$1" | normalize_claim_text | grep -cE "$BANNED_CLAIM_PATTERN" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# WIDENED-SCOPE DISCOVERY (round 6) — Section 1S below. Every function here
# takes a ROOT as its first argument and is never hardcoded to PROJECT_DIR,
# so the SAME functions drive both the real scan (root=$PROJECT_DIR) and the
# 1SM sandbox negative control (root=a temp directory) — the sandbox leg
# exercises this file's actual discovery logic, not a reimplementation of
# it that could silently diverge. See the file header's "WIDENED SCOPE"
# paragraph for the root-cause narrative these functions close.
# ---------------------------------------------------------------------------

# discover_script_mirrors <root> <script-basename> — the canonical file
# under .claude/scripts plus every e2e fixture's copy at the same relative
# path. Same shape as the QAG_COPIES/VBS_COPIES construction above
# (untouched, already independently reviewed 5 rounds) for any root where
# the canonical script is known to exist (1S.0a/1S.0b assert this function
# reproduces their output exactly against $PROJECT_DIR) — EXCEPT the
# canonical-path line is existence-gated here, which QAG_COPIES/VBS_COPIES's
# is not. QAG_COPIES/VBS_COPIES can skip the check because the file's own
# top-of-script guard already verified $QAG/$VBS exist before line 1 of any
# section runs. This function has no such guarantee: 1SM's sandbox leg
# calls it against a root that deliberately does NOT have a
# .claude/scripts/qa-gate.sh, and an un-gated printf would emit that
# non-existent path as a candidate STRING — first caught as 1SM.1 counting
# a phantom path as "found", second (once 1SM.1's own counting loop was
# corrected to require -f) as a raw "No such file or directory" from
# banned_claim_count's `< "$1"` leaking onto stderr in 1SM.3. Gating here,
# at the one shared producer, fixes both call sites at once rather than
# teaching every caller to filter the same phantom.
discover_script_mirrors() {
    local root="$1" name="$2"
    { [ -f "$root/.claude/scripts/$name" ] && printf '%s/.claude/scripts/%s\n' "$root" "$name"
      find "$root/.claude/tests/e2e/fixtures" -maxdepth 4 -type f -path "*/.claude/scripts/$name" 2>/dev/null
    } | sort -u
}

# discover_docs_md <root> — every docs/**/*.md file EXCEPT docs/reviews/**
# (an archive of dated review artifacts, excluded deliberately, not
# incidentally — see the OUT-OF-SCOPE paragraph below).
discover_docs_md() {
    local root="$1"
    find "$root/docs" -name '*.md' ! -path '*/docs/reviews/*' 2>/dev/null | sort -u
}

# discover_named_root_files <root> — the four singleton operator-facing
# documents named explicitly in this task's brief. Existence-gated (not a
# glob), so a missing file is silently absent from the result rather than
# an error; 1S.4's exact-4 assertion is what catches that instead.
discover_named_root_files() {
    local root="$1" f
    for f in HANDOFF.md README.md CONTRIBUTING.md CLAUDE.md; do
        [ -f "$root/$f" ] && printf '%s/%s\n' "$root" "$f"
    done
}

# discover_agents_md <root> — .claude/agents/*.md directly, independent of
# plugin.json's own agents[] array (which discover_plugin_installed_files
# below also walks) — the brief lists this as its own explicit bullet, so
# it is globbed directly rather than only reached transitively.
discover_agents_md() {
    local root="$1"
    find "$root/.claude/agents" -maxdepth 1 -name '*.md' 2>/dev/null | sort -u
}

# discover_plugin_installed_files <root> — "every file the plugin actually
# installs per .claude-plugin/plugin.json", PARSED from the manifest with
# jq rather than hand-copied into this file, so a newly-added agent, command,
# hook or MCP server is picked up the next time this runs instead of
# requiring this spec to be edited in lockstep — the exact staleness this
# task exists to close, applied to its own scan. Walks: .agents[]/.commands[]/
# .skills[] (resolving a directory entry to every file under it), the hook
# script paths referenced inside the manifest's .hooks -> hooks.json (plus
# hooks.json itself), and .mcpServers[].args[] (stripping a leading
# ${VAR_NAME}/ token, e.g. ${CLAUDE_PLUGIN_ROOT}/). Any path jq cannot
# resolve or that does not exist on disk is silently dropped, matching
# discover_named_root_files's existence-gating above — 1S.8's non-vacuity
# floor is what catches a wholesale parse failure.
discover_plugin_installed_files() {
    local root="$1"
    local pj="$root/.claude-plugin/plugin.json" hj hj_rel rel
    [ -f "$pj" ] || return 0
    while IFS= read -r rel; do
        rel="${rel#./}"
        if [ -d "$root/$rel" ]; then
            find "$root/$rel" -type f 2>/dev/null
        elif [ -f "$root/$rel" ]; then
            printf '%s/%s\n' "$root" "$rel"
        fi
    done < <(jq -r '(.agents // [])[], (.commands // [])[], (.skills // [])[]' "$pj" 2>/dev/null)

    hj_rel=$(jq -r '.hooks // empty' "$pj" 2>/dev/null)
    if [ -n "$hj_rel" ]; then
        hj_rel="${hj_rel#./}"
        hj="$root/$hj_rel"
        if [ -f "$hj" ]; then
            printf '%s\n' "$hj"
            jq -r '[.hooks[][]?.hooks[]?.command] | .[]' "$hj" 2>/dev/null \
                | grep -oE '\.claude/scripts/[A-Za-z0-9_.-]+\.sh' \
                | sort -u \
                | while IFS= read -r scriptrel; do
                    [ -f "$root/$scriptrel" ] && printf '%s/%s\n' "$root" "$scriptrel"
                done
        fi
    fi

    jq -r '[.mcpServers[]?.args[]?] | .[]' "$pj" 2>/dev/null \
        | sed -E 's#\$\{[A-Z_]+\}/##' \
        | while IFS= read -r argrel; do
            [ -n "$argrel" ] && [ -f "$root/$argrel" ] && printf '%s/%s\n' "$root" "$argrel"
        done
}

# discover_operator_facing_surface <root> — the deduplicated union of every
# category above, i.e. what Section 1S actually scans and what 1SM's
# sandbox leg proves the discovery reaches.
discover_operator_facing_surface() {
    local root="$1"
    {
        discover_script_mirrors "$root" qa-gate.sh
        discover_script_mirrors "$root" verify-before-stop.sh
        discover_script_mirrors "$root" review-check.sh
        discover_docs_md "$root"
        discover_named_root_files "$root"
        discover_agents_md "$root"
        discover_plugin_installed_files "$root"
    } | sort -u
}

WORK=$(mktemp -d -t approval-record-disclosure-claim.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ===========================================================================
# 1. SOURCE SCAN — zero banned-claim hits across all 8 copies of each of the
#    two scripts scanned here (qa-gate.sh, verify-before-stop.sh), and the
#    corrected replacement language is present. (R7-F2, independent review
#    round 7: reworded from "every shipped copy" / "ships", which read as a
#    claim wider than this section's own scan — review-check.sh's 8 copies
#    are scanned too, but at 1S.1, not here. Scoped to match the Sections
#    list below — R8-F4, independent review round 8: that list's own entry
#    1 needed the identical fix, applied there now; it was not "already
#    correct" as this note originally claimed.)
# ===========================================================================
printf '\n--- 1. SOURCE SCAN: no tamper-evidence claim in the two scripts scanned here ---\n'

QAG_COPIES=()
while IFS= read -r line; do QAG_COPIES+=("$line"); done < <(
    { printf '%s\n' "$QAG"; find "$FIXTURES_DIR" -maxdepth 4 -type f -path '*/.claude/scripts/qa-gate.sh'; } | sort -u
)
VBS_COPIES=()
while IFS= read -r line; do VBS_COPIES+=("$line"); done < <(
    { printf '%s\n' "$VBS"; find "$FIXTURES_DIR" -maxdepth 4 -type f -path '*/.claude/scripts/verify-before-stop.sh'; } | sort -u
)

assert_eq "1.0 non-vacuity: discovered exactly 8 copies of qa-gate.sh (canonical + 7 mirrors)" \
    "8" "${#QAG_COPIES[@]}"
assert_eq "1.0b non-vacuity: discovered exactly 8 copies of verify-before-stop.sh" \
    "8" "${#VBS_COPIES[@]}"

QAG_HITS=0
for f in "${QAG_COPIES[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    QAG_HITS=$((QAG_HITS + ${n:-0}))
done
assert_eq "1.1 zero banned-claim hits across all 8 qa-gate.sh copies" "0" "$QAG_HITS"

VBS_HITS=0
for f in "${VBS_COPIES[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    VBS_HITS=$((VBS_HITS + ${n:-0}))
done
assert_eq "1.2 zero banned-claim hits across all 8 verify-before-stop.sh copies" "0" "$VBS_HITS"

# The positive half — a file that merely deleted the false phrase without
# saying anything accurate would pass 1.1/1.2 and fail these.
QAG_TEXT=$(cat "$QAG")
assert_contains "1.3 qa-gate.sh names the corrected mechanism (disclosure record)" \
    "disclosure record" "$QAG_TEXT"
assert_contains "1.4 qa-gate.sh's approval-record comment uses the corrected term" \
    "CHANGE-SET-BOUND APPROVAL" "$QAG_TEXT"
assert_contains "1.5 qa-gate.sh cites the correcting task" \
    "claude-workflow-plugin-pqnd" "$QAG_TEXT"

VBS_TEXT=$(cat "$VBS")
assert_contains "1.6 verify-before-stop.sh's operator-facing block names OMISSION" \
    "(OMISSION)" "$VBS_TEXT"
assert_contains "1.7 ...names STALENESS" \
    "(STALENESS)" "$VBS_TEXT"
assert_contains "1.8 ...names FORGERY and what it does NOT detect" \
    "(FORGERY)" "$VBS_TEXT"
# Deliberately no trailing backtick in this needle: the source escapes it as
# \` inside the emit_block string (7113) but leaves it bare inside ordinary
# `#` comments (3407) — two different valid encodings of the same forgery-
# vector mention. Section 2's runtime assertion (2.7b) pins the EVALUATED
# form precisely instead, where bash has already resolved the escape.
assert_contains "1.9 ...names the forgery vector explicitly (bd comment)" \
    "bd comment" "$VBS_TEXT"
assert_contains "1.10 verify-before-stop.sh cites the correcting task" \
    "claude-workflow-plugin-pqnd" "$VBS_TEXT"

# ---------------------------------------------------------------------------
# 1M. META — the scanner is not vacuous: it catches the claim reintroduced in
# every shape actually found on this task (plain, ALL-CAPS, markdown-
# emphasis), in EITHER file, and the shipped files still pass (restore
# control).
# ---------------------------------------------------------------------------
printf '\n--- 1M. META: reintroducing the claim, in every shape found, must be caught ---\n'

QAG_MUT="$WORK/qa-gate-mut.sh"
sed 's/# llh.18 (red-team P0\/P1): the comment is now the CHANGE-SET-BOUND APPROVAL/# llh.18 (red-team P0\/P1): the comment is now the TAMPER-EVIDENT APPROVAL/' \
    "$QAG" > "$QAG_MUT"
assert_eq "1M.0 non-vacuity: the qa-gate.sh mutant differs from the shipped file" \
    "yes" "$([ "$(banned_claim_count "$QAG_MUT" | tr -d '[:space:]')" != "0" ] && echo yes || echo no)"
assert_eq "1M.1 SPECIFIC (qa-gate.sh, ALL-CAPS shape): the scanner catches it" \
    "yes" "$([ "$(banned_claim_count "$QAG_MUT" | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"

VBS_MUT="$WORK/verify-before-stop-mut.sh"
sed 's/The release path requires a change-set-bound record that qa-gate.sh approve/The release path requires a tamper-evident record that qa-gate.sh approve/' \
    "$VBS" > "$VBS_MUT"
assert_eq "1M.2 non-vacuity: the verify-before-stop.sh mutant differs from the shipped file" \
    "yes" "$([ "$(banned_claim_count "$VBS_MUT" | tr -d '[:space:]')" != "0" ] && echo yes || echo no)"
assert_eq "1M.3 SPECIFIC (verify-before-stop.sh, plain shape): the scanner catches it" \
    "yes" "$([ "$(banned_claim_count "$VBS_MUT" | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"

# 1M.c — the case/markdown-variant discovery itself, pinned directly against
# the exact three encodings this task found in the wild (mixed-case in
# verify-before-stop.sh's approval_binding_attests, ALL-CAPS in qa-gate.sh,
# and the markdown-emphasis form found in docs). Synthetic haystacks, not
# file mutations: this is a unit check of normalize_claim_text/
# banned_claim_count_text themselves.
assert_eq "1M.c1 catches ALL-CAPS (the qa-gate.sh:5063 shape, pre-fix)" \
    "yes" "$([ "$(banned_claim_count_text 'the comment is now the TAMPER-EVIDENT APPROVAL RECORD' | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
assert_eq "1M.c2 catches mixed-case (the verify-before-stop.sh:7050 shape, pre-fix)" \
    "yes" "$([ "$(banned_claim_count_text 'this is a tamper-EVIDENT record, not a cryptographic sandbox' | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
assert_eq "1M.c3 catches markdown-emphasis (the docs/HOOKS.md shape: Tamper-*evident*)" \
    "yes" "$([ "$(banned_claim_count_text 'Hand-forged records are possible. Tamper-*evident*, not a sandbox.' | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
assert_eq "1M.c4 catches unforgeable (R6-F4: 'proof that' removed from the pattern below; this string still matches via unforgeable alone)" \
    "yes" "$([ "$(banned_claim_count_text 'this record is UNFORGEABLE, proof that no one could have forged it' | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
# R7 "also include" (independent review round 7): "cannot be forged" is the
# fourth BANNED_CLAIM_PATTERN alternative and, unlike the other three, had
# no positive-detection assertion anywhere in this file — an unexercised
# alternative in the one pattern this file's whole thesis rests on is the
# same "untested guard" shape the rest of this file exists to close.
assert_eq "1M.c5 catches 'cannot be forged' (R7 'also include': previously exercised by no positive-detection assertion anywhere in this file)" \
    "yes" "$([ "$(banned_claim_count_text 'this record cannot be forged, so no separate signature is needed' | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
# NEGATIVE: the CORRECTED wording itself (which necessarily discusses
# forgery, since the whole point is stating what is NOT detected) must NOT
# trip the scanner — otherwise the check would forbid writing the very
# correction it exists to require.
assert_eq "1M.c6 the corrected wording (negated forgery statement) does NOT trip the scanner" \
    "0" "$(banned_claim_count_text 'it does NOT detect a well-formed record written by hand instead of by qa-gate.sh approve (FORGERY)' | tr -d '[:space:]')"

# 1M.c7 (R8-F3, independent review round 8): the SPACE form "tamper
# evident" — BANNED_CLAIM_PATTERN's second alternative — carried no
# positive-detection assertion anywhere in this file, unlike its three
# siblings (c1-c3 exercise the HYPHEN form, c4 unforgeable, c5 cannot be
# forged). It is not redundant with the hyphen alternative:
# normalize_claim_text strips `*`/backtick/`_` but never touches the space
# or the hyphen itself, so "tamper evident" and "tamper-evident" remain
# distinguishable strings after normalization, and the space form is what
# uniquely catches markdown/backtick/underscore-wrapped authoring shapes
# the hyphen alternative does not (e.g. "Tamper *evident*",
# "**tamper evident**", backtick- or underscore-quoted "tamper evident").
# Verified by the same per-alternative-removal method c5 was validated by:
# the string below matches the full pattern once, drops to zero ONLY when
# the "tamper evident" alternative is removed, and stays at one when any
# of the other three alternatives is removed instead.
assert_eq "1M.c7 catches the SPACE form 'tamper evident' via markdown emphasis (R8-F3: previously exercised by no positive-detection assertion anywhere in this file)" \
    "yes" "$([ "$(banned_claim_count_text 'the record is **tamper evident** by design' | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"

# RESTORE CONTROL: the shipped files, same predicate, carry no hits (this is
# 1.1/1.2 again, restated here so the META and its control sit together).
assert_eq "1M.4 RESTORE CONTROL: shipped qa-gate.sh still carries zero hits" \
    "0" "$QAG_HITS"
assert_eq "1M.5 RESTORE CONTROL: shipped verify-before-stop.sh still carries zero hits" \
    "0" "$VBS_HITS"

# ===========================================================================
# 1S. WIDENED SCAN SCOPE — an operator-facing surface, enumerated
#     positively and defined BY discover_operator_facing_surface (above).
#
# WHAT "OPERATOR-FACING SURFACE" MEANS, AND WHAT IT DOES NOT (R6-F1,
# independent review round 6 — corrected, not merely re-argued). An
# earlier version of this section called the union below "the full in/out
# partition" and, at the union assertion itself, "what an operator
# actually reads or the plugin actually ships" — both false the moment
# they were written, the same sentence-shape as R5-F1 one round earlier in
# this same file. "Operator-facing surface" is this section's NAME for
# whatever discover_operator_facing_surface returns; that function IS the
# definition, enumerated in THE FIX below. It is not a claim about
# everything the plugin ships: `workflow-manifest.sh generate` — the
# repo's own declared shipped-surface oracle — lists rows this union does
# not, including .claude/scripts/*.sh outside the three scripts named
# below and the operator-class .claude/rubrics/*.md. Compare the two
# directly if you need that broader answer; this section proves a
# narrower one it can actually stand behind — do these enumerated files
# carry the banned claim.
#
# ROOT CAUSE THIS CLOSES (orchestrator finding, 2026-09-06T17:57:25Z):
# everything above scans exactly two globs — qa-gate.sh and
# verify-before-stop.sh, canonical + 7 e2e mirrors each, 16 files total,
# asserted at 1.0/1.0b as "exactly 8 copies" of each. That scan is real and
# correct for what it covers; its INPUT SET was narrower than the claim it
# licensed. HANDOFF.md:102 stated, in an operator-facing release-record
# document, "the Stop gate now requires a tamper-evident approval record" —
# the exact false claim this file exists to correct — and carried it
# through FOUR independent-review rounds because none of them ever looked
# at a file named HANDOFF.md. A check that is real and correct and narrower
# than the claim it licenses reads as "no banned claim ships" and means
# "not in these 16 files" — the same shape as the finding that closed
# Family 1 (see "WHICH CONTROL IS LOAD-BEARING" in the file header).
#
# THE FIX: an ALLOWLIST of what IS scanned, enumerated in code below (not a
# denylist of paths to skip — this arc has already lost six rounds to
# denylists; see the file header). IN SCOPE, each with its own non-vacuity
# floor/count and its own zero-hit assertion:
#   - qa-gate.sh / verify-before-stop.sh / review-check.sh (the three
#     scripts the brief names) + all fixture mirrors — 24 files
#   - docs/**/*.md, excluding docs/reviews/** — 39 files today
#   - HANDOFF.md / README.md / CONTRIBUTING.md / CLAUDE.md — 4 files
#   - every file the plugin actually installs per
#     .claude-plugin/plugin.json (agents, commands, skills, the hook
#     scripts hooks.json wires up, the MCP server entrypoints) — PARSED
#     with jq, not hand-copied, so a newly-added agent/command/hook/server
#     is picked up automatically — 24 files raw today
#   - .claude/agents/*.md, globbed directly (the brief's own explicit
#     bullet, independent of plugin.json's agents[] also reaching them) —
#     9 files
# Deduplicated across all of the above: 90 files today (1S.10/1S.11).
#
# OUT OF SCOPE, DELIBERATELY, because they are archives and rewriting them
# would be its own dishonesty: CHANGELOG.md entries for already-released
# versions, .beads/**, .claude/.qa-tracking/**, docs/reviews/**,
# LESSONS.md, and this spec file itself (which must quote the banned
# phrase in order to detect it). 1S.12.* PROVES each named example is
# absent from the discovered surface rather than describing the exclusion
# only in this comment.
#
# NUMBERS BUMP LEGITIMATELY (matching EXPECTED_SPECS' own convention in
# run-tests.sh): adding a doc, an agent, a command, a hook or an MCP server
# is ordinary, unrelated work that will move 1S.2/1S.6/1S.8/1S.10's counts.
# That is expected — each assertion below states the exact command to
# re-measure it, so a bump is a mechanical, falsifiable edit rather than a
# guess (CONTRIBUTING.md "every number carries the command that produced
# it"), not a reason to loosen these to inexact floors.
#
# ALSO FIXED IN THIS ROUND, same defect family, found only because the
# widened scan was run empirically against them before this file could
# assert anything (see the file header's dated paragraph): docs/HOOKS.md
# and docs/RELEASE_AUDIT.md (markdown-emphasis-wrapped
# "Tamper-*evident*", tracked separately as claude-workflow-plugin-xo0p and
# closed here). Also found this round: review-check.sh's "the tested proof
# that property must survive" (ordinary English, unrelated to any forgery
# claim) collided with BANNED_CLAIM_PATTERN's "proof that" alternative and
# was reworded with no change in meaning — but a later whole-tree sweep
# (R6-F4, independent review round 6) showed the collision was SYSTEMATIC
# (nine further in-tree files), not the one INCIDENTAL hit it was first
# taken for, so "proof that" was REMOVED from the pattern rather than
# reworded around again (see BANNED_CLAIM_PATTERN's own definition for the
# fuller argument).
# ===========================================================================
printf '\n--- 1S. WIDENED SCAN SCOPE: the operator-facing surface, defined positively ---\n'

RVC_COPIES=()
while IFS= read -r line; do RVC_COPIES+=("$line"); done < <(discover_script_mirrors "$PROJECT_DIR" review-check.sh)
assert_eq "1S.0 non-vacuity: discovered exactly 8 copies of review-check.sh (canonical + 7 mirrors)" \
    "8" "${#RVC_COPIES[@]}"

# CONSISTENCY, not just non-vacuity: the new shared discover_script_mirrors
# function, applied to qa-gate.sh/verify-before-stop.sh, must reproduce
# EXACTLY what the independently-reviewed QAG_COPIES/VBS_COPIES
# construction above already found (untouched by this round) — proving the
# new function is not a second, silently-different way of finding the same
# files, using the already-trusted construction as the reference oracle.
#
# LOCALE NOTE (R8-F1, independent review round 8): the two bare `sort -u`
# calls below (this file's own :QAG_SORTED/:VBS_SORTED lines) and the one
# inside discover_script_mirrors (shared by DSM_QAG and DSM_VBS) are none
# of them locale-pinned, yet 1S.0a/1S.0b just below are safe under any
# locale — by SYMMETRY, not by supersession: both sides of each
# comparison run the identical bare sort, in the same process, under the
# same ambient locale. See relpath_join's own comment, further down this
# file, for the full argument and the pin-together-or-not-at-all rule
# this trio is subject to.
DSM_QAG=$(discover_script_mirrors "$PROJECT_DIR" qa-gate.sh)
QAG_SORTED=$(printf '%s\n' "${QAG_COPIES[@]}" | sort -u)
assert_eq "1S.0a discover_script_mirrors agrees with the reviewed QAG_COPIES construction" \
    "$QAG_SORTED" "$DSM_QAG"
DSM_VBS=$(discover_script_mirrors "$PROJECT_DIR" verify-before-stop.sh)
VBS_SORTED=$(printf '%s\n' "${VBS_COPIES[@]}" | sort -u)
assert_eq "1S.0b discover_script_mirrors agrees with the reviewed VBS_COPIES construction" \
    "$VBS_SORTED" "$DSM_VBS"

RVC_HITS=0
for f in "${RVC_COPIES[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    RVC_HITS=$((RVC_HITS + ${n:-0}))
done
assert_eq "1S.1 zero banned-claim hits across all 8 review-check.sh copies" "0" "$RVC_HITS"

# ---------------------------------------------------------------------------
# SET PINS (R6-F3, independent review round 6) — an exact COUNT is not an
# exact SET: QA demonstrated that dropping docs/HOOKS.md from discovery
# while adding .claude/rubrics/default.md holds 1S.2's count at 39 and
# 1S.10's union at 90, both green, with docs/HOOKS.md — one of the two
# files THIS TASK had to correct — silently outside the scanned set.
# ANSWER TO THE EXACT-VS-FLOOR QUESTION (recorded, not re-litigated): KEEP
# EXACT, never a floor — "at least N" is the same shape as the defect this
# whole file exists to fix, since the original 16-file scan would have
# satisfied any floor too. Instead, the two ORGANICALLY-GROWING categories
# (docs/**/*.md, plugin-installed) plus the UNION are upgraded from
# exact-COUNT to exact-SET, pinned as a sorted, PROJECT_DIR-relative path
# list so a mismatch is a `diff`, not just a number. The three CLOSED
# categories (8 mirrors x3, 4 named root, 9 agents) keep plain counts
# (1S.0/1S.0a/1S.0b/1S.4/1S.6) — a set pin adds nothing there; those lists
# are enumerated by name in code already (QAG/VBS/RVC copies,
# discover_named_root_files, discover_agents_md), so there is no separate
# "which one" question a count could hide.
#
# assert_set_pin <name> <expected-multiline> <actual-multiline> — like
# assert_eq, but a mismatch prints a `diff` (- pinned / + actual) so the
# failure NAMES which path appeared or disappeared, not only that the set
# changed.
assert_set_pin() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n' "$name"
        printf '    the discovered set differs from the pinned list:\n'
        diff -u --label pinned --label actual \
            <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") | sed 's/^/    /'
        printf '    If this is a DELIBERATE addition or removal (a new doc, a new\n'
        printf '    plugin.json entry): paste the "+ ..." line(s) above into this pin'"'"'s\n'
        printf '    EXPECTED_*_SET constant in section 1S of THIS file and drop any\n'
        printf '    "- ..." line(s), in the SAME change set as the file that was added or\n'
        printf '    removed. If not, investigate before touching the pin.\n'
    fi
}

# relpath_join <root> <path...> — each path stripped of its "<root>/"
# prefix, sorted, newline-joined. The comparison this feeds is a SET
# equality, not a sequence one, so this sorts explicitly rather than
# trusting callers to have done so: discover_docs_md/discover_agents_md/
# discover_named_root_files/discover_script_mirrors and the final
# discover_operator_facing_surface union all pipe through `sort -u`
# internally, but discover_plugin_installed_files does not — it emits
# plugin.json's/jq's own array order, which is stable but not
# alphabetical. Sorting here once, for every caller, means the EXPECTED_*
# constants below can be written in one canonical (alphabetical) order
# regardless of which discover_* function fed them.
#
# LOCALE PINNED (R7-F1, independent review round 7): the sort below is
# `LC_ALL=C sort`, not a bare `sort`. The EXPECTED_*_SET constants are
# captured in C-collation order; under a UTF-8 collating locale (glibc
# en_US.UTF-8's case-insensitive-primary collation, at minimum) a bare
# `sort` reorders these same paths and the set pins fail SPURIOUSLY, with
# the identical two-assertion failure signature (1S.2b/1S.10b) as the
# genuine drop-plus-add attack this pin exists to catch. 1S.13 (below)
# drives this exact function, unmodified, under a forced non-C locale and
# proves both that the pin is load-bearing and that the fix holds. Do not
# reintroduce a bare `sort` here, or in any new relpath_join-shaped
# helper this file grows later.
#
# THE OTHER BARE SORTS IN THIS FILE (R8-F1, independent review round 8) —
# an earlier version of the ROUND 7 paragraph in the file header claimed
# this pin "superseded" every other discover_* function's internal sort,
# "verified by reading every call site". That claim was false, caught by
# MUTATION (reversing each of the 11 bare `sort`/`sort -u` sites in this
# file individually and re-running the suite under LC_ALL=C), not by
# reading. The 11 sites split into three genuinely different reasons, not
# one:
#   1. ORDER REACHES NO COMPARED VALUE (8 sites — reversing any one alone
#      leaves the suite at 195/0, non-vacuously: every site emits 6+
#      lines). discover_docs_md's and discover_operator_facing_surface's
#      own internal sorts genuinely ARE superseded — by THIS function's
#      own LC_ALL=C sort, which feeds 1S.2b/1S.10b; the hook-script
#      sub-list inside discover_plugin_installed_files is superseded the
#      same way, feeding 1S.8b. The QAG_COPIES/VBS_COPIES construction in
#      section 1 is superseded too, but by a SECOND bare `sort -u`
#      immediately downstream (QAG_SORTED/VBS_SORTED, above), which
#      re-sorts unconditionally regardless of what order arrives.
#      discover_agents_md is not superseded by anything — 1S.6/1S.7 are
#      plain counts, so its order was never compared to a constant at
#      all. assert_names_defined/assert_names_invoked (near the CLASS
#      GUARD section) are covered by reason 3, below, not this one.
#   2. SYMMETRY, A PIN-TOGETHER-OR-NOT-AT-ALL UNIT — discover_script_
#      mirrors' own bare `sort -u` (shared by both DSM_QAG and DSM_VBS,
#      above) and the QAG_SORTED/VBS_SORTED lines each fail 1S.0a/1S.0b
#      when reversed ALONE, but pass 195/0 when all three are reversed
#      TOGETHER — because 1S.0a compares QAG_SORTED against DSM_QAG, and
#      1S.0b compares VBS_SORTED against DSM_VBS, and NEITHER comparison
#      goes through this function or any other locale pin: both sides of
#      each comparison run the identical bare `sort -u`, in the same
#      process, under the same ambient locale, so they move together.
#      This is DATA-INDEPENDENT as long as all three stay bare — QA
#      measured that pinning any subset (e.g. QAG_SORTED/VBS_SORTED
#      alone) still passes 195/0 TODAY, by COINCIDENCE (the current file
#      set happens to collate identically under LC_ALL=C and
#      en_US.UTF-8), and that one e2e fixture directory named with a
#      leading uppercase letter breaks that coincidence (mirror-set sha
#      f0f21613aa99 under C vs 2c956586f7ed under en_US.UTF-8), which
#      would surface as a phantom 1S.0a/1S.0b mismatch. RULE: pin this
#      trio all together, or leave all three bare. A partial pin is not a
#      stronger guarantee than no pin — it is a weaker one wearing a
#      pin's confidence.
#   3. MEMBERSHIP, NOT ORDER — assert_names_defined/assert_names_invoked
#      (near the CLASS GUARD section, far below) feed
#      missing_assert_names, which tests set membership via `grep -qxF`;
#      no comparison anywhere downstream of either function cares what
#      order they emit their lines in.
# Inventory, re-derived here rather than trusted from an earlier miscount:
# 11 bare sort invocations + 3 locale-pinned (this function's own,
# load-bearing; plus two probes in 1S.13, one pinned to C, one to
# en_US.UTF-8) = 14 real sort invocations total. A naive whole-file grep
# for this function's own locale-pin string is NOT this count, and will
# not stay stable: comments (this paragraph among them) and 1S.13's own
# sed/grep-based mutation harness also contain that string as TEXT to
# manipulate, not as a sort call to execute, and how many such mentions
# exist changes independently of how many real sort invocations exist.
# Count real invocations by classifying each line that pipes through
# `sort` (excluding comments), the way the census above was built — not
# by grepping for the pin string.
relpath_join() {
    local root="$1"; shift
    printf '%s\n' "$@" | sed "s#^$root/##" | LC_ALL=C sort
}

# Pinned at pqnd R6-F3. Re-measure with the discover_* function itself
# (e.g. `discover_docs_md "$PROJECT_DIR"`, run standalone via this file's
# own source) rather than hand-deriving; paste the sorted, root-relative
# output over the matching constant below.
EXPECTED_DOCS_MD_SET=$(cat <<'EOF'
docs/AGENTLINT_REPORT.md
docs/AGENTS.md
docs/ARCHITECTURE.md
docs/BEADS.md
docs/CODEX_SETUP.md
docs/EFFORT-AB-TEST.md
docs/HOOKS.md
docs/MCP_SERVERS.md
docs/QUICKSTART.md
docs/RELEASE_AUDIT.md
docs/TROUBLESHOOTING.md
docs/WORKFLOW.md
docs/al-2026-05-09-115501-e029af5d.md
docs/al-2026-06-11-162927-be22c771.md
docs/al-2026-06-11-192450-3afc944d.md
docs/al-2026-06-11-193529-ca095329.md
docs/al-2026-06-11-230915-a643bd1a.md
docs/al-2026-06-12-004610-a692e3ef.md
docs/al-2026-06-12-025719-3d6db70f.md
docs/al-2026-06-12-030342-eebe9ae5.md
docs/al-2026-06-12-030350-011f9137.md
docs/al-2026-06-12-072601-4fef5e4f.md
docs/al-2026-06-12-074306-03e32ea4.md
docs/al-2026-06-12-202528-5f7c9e14.md
docs/al-2026-06-12-203044-fcc0297e.md
docs/al-2026-06-12-203710-023fd027.md
docs/al-2026-07-25-081910-47996d6f.md
docs/al-2026-07-25-100556-f87d6410.md
docs/al-2026-07-26-170112-031a02dc.md
docs/al-2026-07-29-173819-e34ef46e.md
docs/al-2026-08-12-014754-1f608934.md
docs/plans/README.md
docs/plans/v3-upgrade.md
docs/plans/v4-trimodel.md
docs/plans/v4.1-upgrade-wave.md
docs/plans/v5-design-phase-plan.md
docs/plans/v5-design-phase.md
docs/plans/verification-suite.md
docs/v4.1-closure.md
EOF
)

EXPECTED_PLUGIN_FILES_SET=$(cat <<'EOF'
.claude/agents/backend.md
.claude/agents/design-reviewer.md
.claude/agents/designer.md
.claude/agents/devops.md
.claude/agents/frontend.md
.claude/agents/grader.md
.claude/agents/judge.md
.claude/agents/orchestrator.md
.claude/agents/qa.md
.claude/commands/mutation-sweep.md
.claude/commands/workflow-doctor.md
.claude/commands/workflow-model.md
.claude/hooks/hooks.json
.claude/mcp/bd-mcp/bin/bd-mcp.js
.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js
.claude/scripts/bd-github-link.sh
.claude/scripts/intent-router.sh
.claude/scripts/post-edit.sh
.claude/scripts/prevent-orchestrator-edits.sh
.claude/scripts/session-end.sh
.claude/scripts/session-start.sh
.claude/scripts/subagent-start.sh
.claude/scripts/verify-before-stop.sh
.claude/skills/workflow-engine/SKILL.md
EOF
)

EXPECTED_SURFACE_SET=$(cat <<'EOF'
.claude/agents/backend.md
.claude/agents/design-reviewer.md
.claude/agents/designer.md
.claude/agents/devops.md
.claude/agents/frontend.md
.claude/agents/grader.md
.claude/agents/judge.md
.claude/agents/orchestrator.md
.claude/agents/qa.md
.claude/commands/mutation-sweep.md
.claude/commands/workflow-doctor.md
.claude/commands/workflow-model.md
.claude/hooks/hooks.json
.claude/mcp/bd-mcp/bin/bd-mcp.js
.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js
.claude/scripts/bd-github-link.sh
.claude/scripts/intent-router.sh
.claude/scripts/post-edit.sh
.claude/scripts/prevent-orchestrator-edits.sh
.claude/scripts/qa-gate.sh
.claude/scripts/review-check.sh
.claude/scripts/session-end.sh
.claude/scripts/session-start.sh
.claude/scripts/subagent-start.sh
.claude/scripts/verify-before-stop.sh
.claude/skills/workflow-engine/SKILL.md
.claude/tests/e2e/fixtures/go-cli-refactor/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/go-cli-refactor/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/go-cli-refactor/.claude/scripts/verify-before-stop.sh
.claude/tests/e2e/fixtures/monorepo-frontend-only/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/monorepo-frontend-only/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/monorepo-frontend-only/.claude/scripts/verify-before-stop.sh
.claude/tests/e2e/fixtures/multi-domain-signup/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/multi-domain-signup/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/multi-domain-signup/.claude/scripts/verify-before-stop.sh
.claude/tests/e2e/fixtures/node-react-auth/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/node-react-auth/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/node-react-auth/.claude/scripts/verify-before-stop.sh
.claude/tests/e2e/fixtures/python-django-bug/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/python-django-bug/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/python-django-bug/.claude/scripts/verify-before-stop.sh
.claude/tests/e2e/fixtures/qa-block-recovery/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/qa-block-recovery/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/qa-block-recovery/.claude/scripts/verify-before-stop.sh
.claude/tests/e2e/fixtures/rubric-revision-loop/.claude/scripts/qa-gate.sh
.claude/tests/e2e/fixtures/rubric-revision-loop/.claude/scripts/review-check.sh
.claude/tests/e2e/fixtures/rubric-revision-loop/.claude/scripts/verify-before-stop.sh
CLAUDE.md
CONTRIBUTING.md
HANDOFF.md
README.md
docs/AGENTLINT_REPORT.md
docs/AGENTS.md
docs/ARCHITECTURE.md
docs/BEADS.md
docs/CODEX_SETUP.md
docs/EFFORT-AB-TEST.md
docs/HOOKS.md
docs/MCP_SERVERS.md
docs/QUICKSTART.md
docs/RELEASE_AUDIT.md
docs/TROUBLESHOOTING.md
docs/WORKFLOW.md
docs/al-2026-05-09-115501-e029af5d.md
docs/al-2026-06-11-162927-be22c771.md
docs/al-2026-06-11-192450-3afc944d.md
docs/al-2026-06-11-193529-ca095329.md
docs/al-2026-06-11-230915-a643bd1a.md
docs/al-2026-06-12-004610-a692e3ef.md
docs/al-2026-06-12-025719-3d6db70f.md
docs/al-2026-06-12-030342-eebe9ae5.md
docs/al-2026-06-12-030350-011f9137.md
docs/al-2026-06-12-072601-4fef5e4f.md
docs/al-2026-06-12-074306-03e32ea4.md
docs/al-2026-06-12-202528-5f7c9e14.md
docs/al-2026-06-12-203044-fcc0297e.md
docs/al-2026-06-12-203710-023fd027.md
docs/al-2026-07-25-081910-47996d6f.md
docs/al-2026-07-25-100556-f87d6410.md
docs/al-2026-07-26-170112-031a02dc.md
docs/al-2026-07-29-173819-e34ef46e.md
docs/al-2026-08-12-014754-1f608934.md
docs/plans/README.md
docs/plans/v3-upgrade.md
docs/plans/v4-trimodel.md
docs/plans/v4.1-upgrade-wave.md
docs/plans/v5-design-phase-plan.md
docs/plans/v5-design-phase.md
docs/plans/verification-suite.md
docs/v4.1-closure.md
EOF
)
# ---------------------------------------------------------------------------

# Measured: find "$PROJECT_DIR/docs" -name '*.md' ! -path '*/docs/reviews/*' | wc -l
DOCS_MD=()
while IFS= read -r line; do DOCS_MD+=("$line"); done < <(discover_docs_md "$PROJECT_DIR")
assert_eq "1S.2 non-vacuity: discovered exactly 39 docs/**/*.md files (excl. docs/reviews/**)" \
    "39" "${#DOCS_MD[@]}"
assert_set_pin "1S.2b exact SET (R6-F3): the discovered docs/**/*.md paths match the pinned list, not just its count" \
    "$EXPECTED_DOCS_MD_SET" "$(relpath_join "$PROJECT_DIR" "${DOCS_MD[@]}")"
DOCS_HITS=0
for f in "${DOCS_MD[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    DOCS_HITS=$((DOCS_HITS + ${n:-0}))
done
assert_eq "1S.3 zero banned-claim hits across all discovered docs/**/*.md files" "0" "$DOCS_HITS"

NAMED_ROOT=()
while IFS= read -r line; do NAMED_ROOT+=("$line"); done < <(discover_named_root_files "$PROJECT_DIR")
assert_eq "1S.4 non-vacuity: discovered exactly 4 named root files (HANDOFF/README/CONTRIBUTING/CLAUDE.md)" \
    "4" "${#NAMED_ROOT[@]}"
NAMED_HITS=0
for f in "${NAMED_ROOT[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    NAMED_HITS=$((NAMED_HITS + ${n:-0}))
done
assert_eq "1S.5 zero banned-claim hits across HANDOFF.md/README.md/CONTRIBUTING.md/CLAUDE.md" \
    "0" "$NAMED_HITS"

# Measured: find "$PROJECT_DIR/.claude/agents" -maxdepth 1 -name '*.md' | wc -l
AGENTS_MD=()
while IFS= read -r line; do AGENTS_MD+=("$line"); done < <(discover_agents_md "$PROJECT_DIR")
assert_eq "1S.6 non-vacuity: discovered exactly 9 .claude/agents/*.md files" "9" "${#AGENTS_MD[@]}"
AGENTS_HITS=0
for f in "${AGENTS_MD[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    AGENTS_HITS=$((AGENTS_HITS + ${n:-0}))
done
assert_eq "1S.7 zero banned-claim hits across all .claude/agents/*.md files" "0" "$AGENTS_HITS"

# Measured: the discover_plugin_installed_files function itself, run against
# PROJECT_DIR — see its own header comment for what it parses.
PLUGIN_FILES=()
while IFS= read -r line; do PLUGIN_FILES+=("$line"); done < <(discover_plugin_installed_files "$PROJECT_DIR")
assert_eq "1S.8 non-vacuity: discovered exactly 24 plugin.json-installed files (agents+commands+skills+hooks+mcp, raw)" \
    "24" "${#PLUGIN_FILES[@]}"
assert_set_pin "1S.8b exact SET (R6-F3): the discovered plugin.json-installed paths match the pinned list, not just its count" \
    "$EXPECTED_PLUGIN_FILES_SET" "$(relpath_join "$PROJECT_DIR" "${PLUGIN_FILES[@]}")"
PLUGIN_HITS=0
for f in "${PLUGIN_FILES[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    PLUGIN_HITS=$((PLUGIN_HITS + ${n:-0}))
done
assert_eq "1S.9 zero banned-claim hits across every plugin.json-installed file" "0" "$PLUGIN_HITS"

# The grand union: everything above, deduplicated (raw counts double-count
# verify-before-stop.sh once against 1S.8/1S.9's hook-script entry, and the
# 9 agents once against 1S.8/1S.9's agents[] entries —
# 8(qa-gate.sh mirrors)+8(verify-before-stop.sh mirrors)+
# 8(review-check.sh mirrors)+39(docs)+4(named root)+9(agents)+
# 24(plugin-installed) = 100 raw, minus 10 overlaps (9 agents + 1
# verify-before-stop.sh canonical, both also reached via plugin.json
# parsing) = 90 (R6-F1: the previous formula here summed to 116 by
# duplicating a "24" term in place of one of the two "8"s — the five
# categories actually sum to 100, not 116) — measured directly below
# rather than hand-derived, which is the whole point of asserting the
# UNION's own count instead of trusting arithmetic on seven sub-counts.
# This is the enumerated operator-facing surface as this section's header
# (above) defines the term — not a claim about everything the plugin
# ships (R6-F1: see that header for what to compare against if you need
# the broader answer).
SURFACE=()
while IFS= read -r line; do SURFACE+=("$line"); done < <(discover_operator_facing_surface "$PROJECT_DIR")
assert_eq "1S.10 non-vacuity: the deduplicated operator-facing surface has exactly 90 files" \
    "90" "${#SURFACE[@]}"
assert_set_pin "1S.10b exact SET (R6-F3): the discovered union paths match the pinned list, not just its count" \
    "$EXPECTED_SURFACE_SET" "$(relpath_join "$PROJECT_DIR" "${SURFACE[@]}")"
SURFACE_HITS=0
for f in "${SURFACE[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    SURFACE_HITS=$((SURFACE_HITS + ${n:-0}))
done
assert_eq "1S.11 zero banned-claim hits across the ENTIRE operator-facing surface" "0" "$SURFACE_HITS"

# OUT-OF-SCOPE PROOF: each named example is checked ABSENT from the
# discovered surface, rather than merely described in the header comment.
# CAVEAT, found by independent review (R6-F2, round 6): none of the six
# examples below can actually exercise the docs/reviews/** exclusion
# filter specifically, because discover_docs_md only ever matches `*.md`
# and every file docs/reviews/ holds today is `.json` — the filter and
# these examples are true independently of each other, so a bug in the
# filter alone (e.g. it silently stopped excluding docs/reviews/**) would
# not fail any assertion here. 1S.12M (below, after 1SM) is the assertion
# that actually exercises the filter, by seeding a `.md` file under a
# sandbox docs/reviews/.
OUT_OF_SCOPE_EXAMPLES=(
    "$PROJECT_DIR/CHANGELOG.md"
    "$PROJECT_DIR/LESSONS.md"
    "$PROJECT_DIR/.beads/issues.jsonl"
    "$PROJECT_DIR/docs/reviews/claude-workflow-plugin-pqnd-r1.json"
    "$PROJECT_DIR/.claude/scripts/tests/approval-record-disclosure-claim.test.sh"
    "$PROJECT_DIR/.claude/.qa-tracking/completion-claude-workflow-plugin-pqnd-backend.json"
)
SURFACE_JOINED=$(printf '%s\n' "${SURFACE[@]}")
oos_i=0
for excluded in "${OUT_OF_SCOPE_EXAMPLES[@]}"; do
    oos_i=$((oos_i + 1))
    hit=$(printf '%s\n' "$SURFACE_JOINED" | grep -cxF "$excluded" || true)
    assert_eq "1S.12.$oos_i OUT-OF-SCOPE proof: ${excluded#"$PROJECT_DIR"/} is NOT in the discovered surface" \
        "0" "${hit:-0}"
done

# ---------------------------------------------------------------------------
# 1S.12M META for 1S.12 (R6-F2, independent review round 6) — makes the
# docs/reviews/** exclusion filter itself load-bearing. 1S.12 above cannot:
# every one of its six examples is excluded from the surface for a reason
# UNRELATED to the docs/reviews/** filter (wrong extension, wrong
# directory prefix entirely, or this spec file's own self-reference), and
# docs/reviews/ holds no .md files today (`find "$PROJECT_DIR/docs/reviews"
# -type f | sed 's/.*\././' | sort -u` = json only) — QA reproduced this by
# deleting the exclusion outright in a scratchpad copy of discover_docs_md
# and got 179 passed, 0 failed: the bug the filter exists to catch is
# invisible to every assertion that ran before this one. This section
# seeds a sandbox docs/reviews/*.md file (the shape the filter exists to
# catch) beside an ordinary sandbox docs/*.md sibling (the control —
# proves the sandbox and the function both work at all), and asserts
# discover_docs_md keeps one and drops the other.
# ---------------------------------------------------------------------------
printf '\n--- 1S.12M META: the docs/reviews/** exclusion actually excludes a seeded .md ---\n'

DOCS_EXCL_SANDBOX="$WORK/docs-exclusion-sandbox"
mkdir -p "$DOCS_EXCL_SANDBOX/docs/reviews"
printf '# kept (sandbox fixture, NOT a real doc)\n' > "$DOCS_EXCL_SANDBOX/docs/kept.md"
printf '# leaked review artifact (sandbox fixture, NOT the real docs/reviews/)\n' \
    > "$DOCS_EXCL_SANDBOX/docs/reviews/leaked.md"

assert_eq "1S.12M.0a non-vacuity: the sandbox docs/kept.md seed landed" \
    "yes" "$([ -f "$DOCS_EXCL_SANDBOX/docs/kept.md" ] && echo yes || echo no)"
assert_eq "1S.12M.0b non-vacuity: the sandbox docs/reviews/leaked.md seed landed" \
    "yes" "$([ -f "$DOCS_EXCL_SANDBOX/docs/reviews/leaked.md" ] && echo yes || echo no)"

DOCS_EXCL_RESULT=$(discover_docs_md "$DOCS_EXCL_SANDBOX")
KEPT_HIT=$(printf '%s\n' "$DOCS_EXCL_RESULT" | grep -cxF "$DOCS_EXCL_SANDBOX/docs/kept.md" || true)
assert_eq "1S.12M.1 CONTROL: the ordinary sandbox doc IS discovered (the function and sandbox both work)" \
    "1" "${KEPT_HIT:-0}"
LEAKED_HIT=$(printf '%s\n' "$DOCS_EXCL_RESULT" | grep -cxF "$DOCS_EXCL_SANDBOX/docs/reviews/leaked.md" || true)
assert_eq "1S.12M.2 SPECIFIC (the fix): the seeded docs/reviews/*.md is excluded, not merely absent by coincidence" \
    "0" "${LEAKED_HIT:-0}"

# RESTORE CONTROL: the real PROJECT_DIR's own docs/**/*.md discovery is
# unaffected by this sandbox — this is 1S.2 again, repeated here so the
# sandbox proof and the real-tree count sit side by side.
assert_eq "1S.12M.3 RESTORE CONTROL: the real PROJECT_DIR still discovers exactly 39 docs/**/*.md files" \
    "39" "${#DOCS_MD[@]}"

# ---------------------------------------------------------------------------
# 1S.13 LOCALE CONTROL (R7-F1, independent review round 7) — makes the
# LC_ALL=C pin on relpath_join's sort (above) itself load-bearing, the same
# way 1S.12M made the docs/reviews/** exclusion load-bearing rather than
# merely described in prose. Under a UTF-8 collating locale, an unpinned
# `sort` reorders the same paths the EXPECTED_*_SET constants are captured
# in (C order), and the set pins at 1S.2b/1S.8b/1S.10b fail SPURIOUSLY —
# with the identical failure signature as the genuine drop-plus-add attack
# those pins exist to catch (the same two assertion names, a diff naming
# real paths that never actually moved).
#
# THE FOUR LEGS. (1) NON-VACUITY — 1S.13.0a/0b prove the extracted mutant
# body really has the locale pin stripped, and only that (one substitution,
# not a rewrite); 1S.13.0c proves both extractions still parse; 1S.13.0d
# proves THIS HOST actually collates en_US.UTF-8 differently from C, so a
# pass below means something — an environment missing the locale would fail
# 0d LOUDLY and distinguishably, rather than silently passing 1S.13.2/.3 for
# the wrong reason. (2) SPECIFIC MISBEHAVIOUR — 1S.13.1 drives the MUTANT
# (locale pin stripped) under a forced en_US.UTF-8 and proves it no longer
# reproduces the pinned union set: the exact regression R7-F1 found,
# reproduced deliberately here rather than waited for. (3) RESTORE CONTROL —
# 1S.13.2/1S.13.3 drive the REAL, UNMODIFIED shipped relpath_join under two
# forced non-C locales (en_US.UTF-8, fr_FR.UTF-8) and prove it still
# matches. (4) EXECUTION — 1S.13.1/1S.13.2/1S.13.3 actually RUN the
# extracted function (via `declare -f`, verbatim — not a re-implementation)
# as its own bash process; none of it is a static grep of this file's
# source for the string "LC_ALL=C". (0d is a real bash process too — a
# direct locale probe establishing the host precondition the other three
# depend on — but it does not itself run the extracted function, so it is
# named separately here rather than folded into "every leg", which an
# earlier version of this sentence did; found and corrected in the same
# R8-F1 sweep, same method: checked, not assumed.)
# ---------------------------------------------------------------------------
printf '\n--- 1S.13 LOCALE CONTROL: the SET PINS do not depend on the ambient locale ---\n'

RELPATH_JOIN_SRC=$(declare -f relpath_join)
RELPATH_JOIN_SHIPPED="$WORK/relpath_join_shipped.sh"
{
    printf '%s\n' "$RELPATH_JOIN_SRC"
    printf 'relpath_join "$@"\n'
} > "$RELPATH_JOIN_SHIPPED"
RELPATH_JOIN_MUTANT="$WORK/relpath_join_mutant.sh"
sed 's/LC_ALL=C sort/sort/' "$RELPATH_JOIN_SHIPPED" > "$RELPATH_JOIN_MUTANT"

assert_eq "1S.13.0a non-vacuity: the shipped relpath_join extraction really pins LC_ALL=C" \
    "1" "$(grep -c 'LC_ALL=C sort' "$RELPATH_JOIN_SHIPPED" | tr -d '[:space:]')"
assert_eq "1S.13.0b non-vacuity: the mutant extraction really strips the locale pin, and only that" \
    "yes" "$([ "$(grep -c 'LC_ALL=C sort' "$RELPATH_JOIN_MUTANT" | tr -d '[:space:]')" = "0" ] && [ "$(wc -l < "$RELPATH_JOIN_MUTANT" | tr -d '[:space:]')" = "$(wc -l < "$RELPATH_JOIN_SHIPPED" | tr -d '[:space:]')" ] && echo yes || echo no)"
assert_eq "1S.13.0c non-vacuity: both extractions still parse as valid bash" \
    "yes" "$(bash -n "$RELPATH_JOIN_SHIPPED" 2>/dev/null && bash -n "$RELPATH_JOIN_MUTANT" 2>/dev/null && echo yes || echo no)"

LOCALE_PROBE_C=$(printf 'Banana\napple\n' | LC_ALL=C sort)
LOCALE_PROBE_EN=$(printf 'Banana\napple\n' | LC_ALL=en_US.UTF-8 sort)
assert_eq "1S.13.0d non-vacuity: en_US.UTF-8 is installed and really collates differently from C on this host (else no leg below can prove anything)" \
    "yes" "$([ "$LOCALE_PROBE_C" != "$LOCALE_PROBE_EN" ] && echo yes || echo no)"

MUT_SURFACE_EN=$(LC_ALL=en_US.UTF-8 bash "$RELPATH_JOIN_MUTANT" "$PROJECT_DIR" "${SURFACE[@]}")
assert_eq "1S.13.1 SPECIFIC: under en_US.UTF-8, relpath_join with the locale pin stripped no longer matches the pinned union set (the R7-F1 regression, reproduced)" \
    "yes" "$([ "$MUT_SURFACE_EN" != "$EXPECTED_SURFACE_SET" ] && echo yes || echo no)"

SHIPPED_SURFACE_EN=$(LC_ALL=en_US.UTF-8 bash "$RELPATH_JOIN_SHIPPED" "$PROJECT_DIR" "${SURFACE[@]}")
assert_eq "1S.13.2 RESTORE CONTROL: under en_US.UTF-8, the SHIPPED relpath_join still matches the pinned union set" \
    "$EXPECTED_SURFACE_SET" "$SHIPPED_SURFACE_EN"

SHIPPED_SURFACE_FR=$(LC_ALL=fr_FR.UTF-8 bash "$RELPATH_JOIN_SHIPPED" "$PROJECT_DIR" "${SURFACE[@]}")
assert_eq "1S.13.3 RESTORE CONTROL (second locale): under fr_FR.UTF-8, the SHIPPED relpath_join still matches the pinned union set" \
    "$EXPECTED_SURFACE_SET" "$SHIPPED_SURFACE_FR"

# ---------------------------------------------------------------------------
# 1SM. META for 1S — the pairing requirement applied to DISCOVERY BREADTH,
# not phrase-matching accuracy (1M above already proves the latter: every
# known shape of the claim, reintroduced into qa-gate.sh/verify-before-
# stop.sh, is caught). What 1M could never prove is that the SCAN'S FILE
# LIST reaches a file like HANDOFF.md at all — before this round it
# structurally did not, regardless of content. This section proves the
# widened discovery closes exactly that gap, using the REAL historical
# defect string, without touching the real HANDOFF.md.
#
# THE FOUR LEGS: (1) NON-VACUITY — 1SM.0 proves the seed landed in the
# sandbox before anything is asserted about scanning it. (2) SPECIFIC
# MISBEHAVIOUR — 1SM.2 names exactly which discovered file carries the hit
# (not merely "count > 0"). (3) RESTORE CONTROL — 1SM.4 re-runs the SAME
# function against the real, fixed PROJECT_DIR and asserts zero (this is
# 1S.11 again, via the identical call, so the sandbox and the real leg
# cannot silently be exercising different logic). (4) EXECUTION — every
# assertion below exercises a REAL function this file already defines
# (1SM.0 is `cat` over the seeded file; 1SM.1 calls
# discover_script_mirrors; 1SM.2 onward calls
# discover_operator_facing_surface / banned_claim_count, the two functions
# Section 1S itself uses) — nothing here is a byte comparison over
# markdown. (Corrected alongside 1S.13's EXECUTION leg, same sweep, same
# method: the previous wording named only the last two functions as if
# every assertion in this section called them, which was not true of
# 1SM.0/1SM.1.)
# ---------------------------------------------------------------------------
printf '\n--- 1SM. META: the widened scan would have caught the real HANDOFF.md miss ---\n'

SCOPE_SANDBOX="$WORK/scope-sandbox"
mkdir -p "$SCOPE_SANDBOX"
HANDOFF_DEFECT_LINE='the Stop gate now requires a tamper-evident approval record whose change_set_hash matches the current diff'
printf '# HANDOFF (sandbox fixture, NOT the real file)\n\n%s\n' "$HANDOFF_DEFECT_LINE" > "$SCOPE_SANDBOX/HANDOFF.md"

assert_contains "1SM.0 non-vacuity: the seed landed in the sandbox HANDOFF.md" \
    "$HANDOFF_DEFECT_LINE" "$(cat "$SCOPE_SANDBOX/HANDOFF.md")"

# THE OLD (pre-widening) DISCOVERY, run for real against the sandbox: it
# only ever globbed paths ending in .claude/scripts/qa-gate.sh or
# .claude/scripts/verify-before-stop.sh, so a file named HANDOFF.md was
# never a candidate regardless of content — proven by actually running it,
# not merely asserted from the pattern.
OLD_SANDBOX_HITS=0
for old_name in qa-gate.sh verify-before-stop.sh; do
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        OLD_SANDBOX_HITS=$((OLD_SANDBOX_HITS + 1))
    done < <(discover_script_mirrors "$SCOPE_SANDBOX" "$old_name")
done
assert_eq "1SM.1 the OLD two-glob discovery finds nothing at all in this sandbox (structurally blind, not content-blind)" \
    "0" "$OLD_SANDBOX_HITS"

# THE NEW discovery, run for real against the sandbox: must find the seeded
# HANDOFF.md and the scan over it must report the hit.
SANDBOX_SURFACE=()
while IFS= read -r line; do SANDBOX_SURFACE+=("$line"); done < <(discover_operator_facing_surface "$SCOPE_SANDBOX")
assert_contains "1SM.2 SPECIFIC: the widened discovery's file list includes the seeded sandbox HANDOFF.md" \
    "$SCOPE_SANDBOX/HANDOFF.md" "$(printf '%s\n' "${SANDBOX_SURFACE[@]}")"

SANDBOX_HITS=0
for f in "${SANDBOX_SURFACE[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    SANDBOX_HITS=$((SANDBOX_HITS + ${n:-0}))
done
assert_eq "1SM.3 SPECIFIC: the widened scan reports a hit for the sandboxed HANDOFF.md (the real miss, reproduced)" \
    "yes" "$([ "${SANDBOX_HITS:-0}" -gt 0 ] && echo yes || echo no)"

# RESTORE CONTROL: the identical function, run against the real project,
# still reports zero — same call as 1S.11, repeated here so the sandbox
# failure and the real-tree pass sit side by side under one function.
RESTORE_SURFACE=()
while IFS= read -r line; do RESTORE_SURFACE+=("$line"); done < <(discover_operator_facing_surface "$PROJECT_DIR")
RESTORE_HITS=0
for f in "${RESTORE_SURFACE[@]}"; do
    n=$(banned_claim_count "$f" | tr -d '[:space:]')
    RESTORE_HITS=$((RESTORE_HITS + ${n:-0}))
done
assert_eq "1SM.4 RESTORE CONTROL: the real, fixed PROJECT_DIR still carries zero hits under the same function" \
    "0" "$RESTORE_HITS"

# ===========================================================================
# 2. RUNTIME-OBSERVED LEG — drive the shipped LABEL_WITHOUT_RECORD block for
#    real (not a grep of the source) and assert what an operator would
#    actually read at a genuine Stop block.
# ===========================================================================
printf '\n--- 2. RUNTIME: the shipped LABEL_WITHOUT_RECORD block, actually emitted ---\n'

ABT="$WORK/abt.sh"
ABT_RC=0
extract_region "$VBS" "# APPROVAL-BINDING-TEXT BEGIN" "# APPROVAL-BINDING-TEXT END" "$ABT" || ABT_RC=$?
assert_eq "2.0 non-vacuity: the APPROVAL-BINDING-TEXT sentinels exist in the shipped hook" \
    "0" "$ABT_RC"

LWR="$WORK/lwr.sh"
LWR_RC=0
extract_region "$VBS" "# LABEL-WITHOUT-RECORD-BLOCK BEGIN" "# LABEL-WITHOUT-RECORD-BLOCK END" "$LWR" || LWR_RC=$?
assert_eq "2.1 non-vacuity: the LABEL-WITHOUT-RECORD-BLOCK sentinels exist in the shipped hook" \
    "0" "$LWR_RC"

ABT_PARSE=0; bash -n "$ABT" 2>/dev/null || ABT_PARSE=$?
LWR_PARSE=0; bash -n "$LWR" 2>/dev/null || LWR_PARSE=$?
assert_eq "2.2 the extracted APPROVAL-BINDING-TEXT region is valid bash on its own" "0" "$ABT_PARSE"
assert_eq "2.3 the extracted LABEL-WITHOUT-RECORD-BLOCK region is valid bash on its own" "0" "$LWR_PARSE"

# drive_label_without_record <abt-region> <lwr-region> — sources the REAL
# approval_record_causes/approval_binding_attests, stubs only emit_block
# (capture its argument instead of printing JSON + exit) and
# checks_scope_note (an already-tested, unrelated concern), sets the two
# inputs the block reads, and sources the extracted if-block. Because
# LABEL_WITHOUT_RECORD=true is set BEFORE sourcing, the if-block's body runs
# immediately and calls the stubbed emit_block with the fully-composed
# operator text as its one argument.
drive_label_without_record() {
    local abt_region="$1" lwr_region="$2"
    (
        set -u
        # shellcheck disable=SC2329  # invoked from $lwr_region after it is
        # sourced below, not from this subshell directly — shellcheck cannot
        # trace a caller defined in a file extracted at runtime by awk (same
        # reasoning as gate-claim-honesty.test.sh's drive_f1note).
        emit_block() { printf '%s' "$1"; }
        # shellcheck disable=SC2329  # see emit_block above
        checks_scope_note() { printf ''; }
        # shellcheck disable=SC2034  # read by the sourced $lwr_region below
        # (interpolated into its emit_block argument) — shellcheck cannot
        # trace a reader defined in a file extracted at runtime by awk.
        CURRENT_TASK="proj-1"
        # shellcheck disable=SC2034  # see CURRENT_TASK above
        APPROVAL_RECORD_DETAIL="test detail: no matching change-set-bound record"
        # shellcheck disable=SC2034  # see CURRENT_TASK above — this one gates
        # the sourced if-block's own condition, not just its body.
        LABEL_WITHOUT_RECORD="true"
        # shellcheck disable=SC1090
        . "$abt_region"
        # shellcheck disable=SC1090
        . "$lwr_region"
    )
}

SHIPPED_BLOCK=$(drive_label_without_record "$ABT" "$LWR")

assert_eq "2.4 the shipped block EMITTED text (it ran, it is not empty)" \
    "yes" "$([ -n "$SHIPPED_BLOCK" ] && echo yes || echo no)"

# THE CENTRAL ASSERTIONS — the corrected threat-model taxonomy actually
# renders, in the ACTUAL emitted bytes, not merely in the source file.
assert_contains "2.5 the emitted block names OMISSION" "(OMISSION)" "$SHIPPED_BLOCK"
assert_contains "2.6 the emitted block names STALENESS" "(STALENESS)" "$SHIPPED_BLOCK"
assert_contains "2.7 the emitted block names FORGERY and the vector (bd comment)" \
    "(FORGERY)" "$SHIPPED_BLOCK"
assert_contains "2.7b ...naming bd comment as the vector" 'bd comment`' "$SHIPPED_BLOCK"
assert_contains "2.7c ...stating no secret the gate holds is unreadable to a local writer" \
    "no secret this gate holds" "$SHIPPED_BLOCK"
assert_contains "2.8 the emitted block uses the corrected term change-set-bound" \
    "change-set-bound record" "$SHIPPED_BLOCK"
assert_contains "2.9 approval_binding_attests' own residual bullet is corrected too" \
    "disclosure record, not a cryptographic sandbox" "$SHIPPED_BLOCK"

# THE NEGATIVE HALF, over the OUTPUT — never over the file. Comments
# elsewhere in this same file legitimately discuss the historical claim (the
# APPROVAL-SELECTOR-ANCHOR rationale); this is why 1.*/1M.* scan the file and
# 2.* scans the RUNTIME OUTPUT ONLY, matching the same "grep the function's
# output, not the file" discipline gate-claim-honesty.test.sh's own
# APPROVAL-BINDING-TEXT section documents for exactly this reason.
assert_eq "2.10 the emitted block carries ZERO banned-claim hits" \
    "0" "$(banned_claim_count_text "$SHIPPED_BLOCK" | tr -d '[:space:]')"

# ANTI-OVERREACH: the operational recipe must be UNCHANGED — this is a
# wording change, not a behaviour change. A fix that corrected the claim by
# deleting the recipe would pass every assertion above and still be wrong.
assert_contains "2.11 anti-overreach: the enter recipe step is still present" \
    "qa-gate.sh enter proj-1" "$SHIPPED_BLOCK"
assert_contains "2.12 anti-overreach: the impact-report regeneration step is still present" \
    "impact-report.sh proj-1" "$SHIPPED_BLOCK"
assert_contains "2.13 anti-overreach: the approve step is still present" \
    "qa-gate.sh approve proj-1" "$SHIPPED_BLOCK"
assert_contains "2.14 anti-overreach: the hash-aware idempotency note survives" \
    "hash-aware" "$SHIPPED_BLOCK"
assert_contains "2.15 anti-overreach: the membership-vs-content attestation survives" \
    "MEMBERSHIP PLUS REVIEW-AT-REVIEW-TIME" "$SHIPPED_BLOCK"

# ---------------------------------------------------------------------------
# 2M. META — the runtime assertion is not vacuous: reintroduce the banned
# claim into a COPY of the extracted region and prove 2.10 catches it;
# restore control on the shipped block.
# ---------------------------------------------------------------------------
printf '\n--- 2M. META: reintroducing the claim in the RUNTIME text must break 2.10 ---\n'

LWR_MUT="$WORK/lwr-mut.sh"
sed 's/The release path requires a change-set-bound record that qa-gate.sh approve/The release path requires a tamper-evident record that qa-gate.sh approve/' \
    "$LWR" > "$LWR_MUT"
assert_eq "2M.0 non-vacuity: the mutant region differs from the shipped one" \
    "yes" "$([ "$(shasum -a 256 "$LWR_MUT" | awk '{print $1}')" != "$(shasum -a 256 "$LWR" | awk '{print $1}')" ] && echo yes || echo no)"
LWR_MUT_PARSE=0; bash -n "$LWR_MUT" 2>/dev/null || LWR_MUT_PARSE=$?
assert_eq "2M.1 the mutant region is still valid bash (a failure is the mutation, not a syntax error)" \
    "0" "$LWR_MUT_PARSE"

MUT_BLOCK=$(drive_label_without_record "$ABT" "$LWR_MUT")
assert_eq "2M.2 the mutant block still emits text (it RAN)" \
    "yes" "$([ -n "$MUT_BLOCK" ] && echo yes || echo no)"
assert_eq "2M.3 SPECIFIC: the mutant reintroduces the banned claim, so 2.10 FAILS on it" \
    "yes" "$([ "$(banned_claim_count_text "$MUT_BLOCK" | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"

# RESTORE CONTROL: same driver, same inputs, shipped region — zero hits.
assert_eq "2M.4 RESTORE CONTROL: the shipped block, re-driven, still carries zero hits" \
    "0" "$(banned_claim_count_text "$SHIPPED_BLOCK" | tr -d '[:space:]')"

# ===========================================================================
# 2P. CONTENT PIN (R1-F1, independent review, pqnd round 1) — THE
#     LOAD-BEARING CONTROL. See the file header ("WHICH CONTROL IS
#     LOAD-BEARING") for the full argument against the phrase-denylist
#     sections 1/1M/2.10/2M carry. This is the allowlist form: only the
#     bytes below are permitted for the rendered LABEL_WITHOUT_RECORD block.
# ===========================================================================
printf '\n--- 2P. CONTENT PIN: the rendered block is byte-for-byte the reviewed text ---\n'

sha256_of() {
    # Mirrors qa-gate.sh's sha256_file fallback order (shasum first, then
    # sha256sum) so this spec degrades the same way the shipped script does
    # on a host missing one of the two tools, rather than inventing a second
    # convention. Unlike sha256_file this hashes a STRING via stdin, not a
    # named file, so it has no "no digest tool" sentinel to return — a host
    # with neither tool cannot run this spec's central control at all, which
    # is why that case exits 2 (invocation error) below rather than reading
    # as a false pass or a false fail.
    if command -v shasum >/dev/null 2>&1; then
        printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        printf '%s' "$1" | sha256sum | awk '{print $1}'
    else
        printf 'approval-record-disclosure-claim.test: neither shasum nor sha256sum on PATH — 2P cannot run\n' >&2
        exit 2
    fi
}

# Pinned at the sha256 below, reviewed at pqnd (this task), over the EXACT
# bytes drive_label_without_record renders with CURRENT_TASK=proj-1 and the
# fixed APPROVAL_RECORD_DETAIL above — fully deterministic (no timestamp, no
# live hash, no random value anywhere in approval_record_causes /
# approval_binding_attests / the LABEL_WITHOUT_RECORD block itself; checks_
# scope_note is stubbed empty). Recomputed and diffed against this constant
# on every run; NOT regenerated at run time, or a wrong rendering would just
# re-pin itself and this section would guard nothing.
#
# ANTI-OVERREACH / RE-BLESSING A LEGITIMATE REWORDING: a future, deliberate,
# reviewed change to this block's wording WILL make this section fail — that
# is the control working, not a bug. To re-bless it: re-run this file
# standalone, copy the "ACTUAL sha256" value 2P.1 prints on the mismatch,
# and paste it over EXPECTED_BLOCK_SHA256 below IN THE SAME reviewed change
# set as the wording edit — never as an unreviewed drive-by fix to a red
# suite. The failure message below repeats this recipe so the next
# maintainer does not have to find this comment first.
EXPECTED_BLOCK_SHA256="935650ec3ce1ea02df15155f72391fb8a92f1ebb5ca94ad6fb2639b97768593d"

assert_eq "2P.0 non-vacuity: EXPECTED_BLOCK_SHA256 has the shape of a real sha256 (64 hex chars)" \
    "yes" "$(printf '%s' "$EXPECTED_BLOCK_SHA256" | grep -qE '^[0-9a-f]{64}$' && echo yes || echo no)"

ACTUAL_BLOCK_SHA256=$(sha256_of "$SHIPPED_BLOCK")
if [ "$ACTUAL_BLOCK_SHA256" = "$EXPECTED_BLOCK_SHA256" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: 2P.1 THE LOAD-BEARING CHECK: rendered block matches the reviewed sha256 exactly\n'
else
    FAIL=$((FAIL + 1)); FAILED_TESTS+=("2P.1 THE LOAD-BEARING CHECK: rendered block matches the reviewed sha256 exactly")
    printf '  FAIL: 2P.1 THE LOAD-BEARING CHECK: rendered block matches the reviewed sha256 exactly\n'
    printf '    expected sha256: %s\n' "$EXPECTED_BLOCK_SHA256"
    printf '    ACTUAL   sha256: %s\n' "$ACTUAL_BLOCK_SHA256"
    printf '    If this is a DELIBERATE, REVIEWED change to the LABEL_WITHOUT_RECORD\n'
    printf '    block wording: paste the ACTUAL value above over EXPECTED_BLOCK_SHA256\n'
    printf '    near the top of section 2P in THIS file, in the SAME change set as the\n'
    printf '    wording edit. If it is not deliberate, the operator-facing text changed\n'
    printf '    unexpectedly -- investigate before touching the pin. Full rendered text\n'
    printf '    follows for diffing against the previous reviewed wording:\n'
    printf '    ----------------------------------------------------------------\n'
    printf '%s\n' "$SHIPPED_BLOCK"
    printf '    ----------------------------------------------------------------\n'
fi

# ---------------------------------------------------------------------------
# 2P-M. META — trivial sensitivity: the pin must move on ANY difference, not
# just on the specific evasion phrases 2Q exercises. One appended byte is
# the smallest possible mutation; if this passes and 2Q's mutants also pass,
# the pin proves total content-equality rather than a coincidental match on
# a few tried inputs.
# ---------------------------------------------------------------------------
printf '\n--- 2P-M. META: the pin must move on a ONE-BYTE difference ---\n'

TRIVIAL_MUT_BLOCK="${SHIPPED_BLOCK} "
assert_eq "2P-M.0 non-vacuity: the one-byte mutant really differs from the shipped block" \
    "yes" "$([ "$TRIVIAL_MUT_BLOCK" != "$SHIPPED_BLOCK" ] && echo yes || echo no)"
assert_eq "2P-M.1 SPECIFIC: a single appended space moves the hash away from the pin" \
    "yes" "$([ "$(sha256_of "$TRIVIAL_MUT_BLOCK")" != "$EXPECTED_BLOCK_SHA256" ] && echo yes || echo no)"
assert_eq "2P-M.2 RESTORE CONTROL: the unmodified shipped block still matches the pin" \
    "$EXPECTED_BLOCK_SHA256" "$(sha256_of "$SHIPPED_BLOCK")"

# ===========================================================================
# 2Q. EVASION REGRESSION (R1-F1, independent review) — Sol's reproduction
#     plus four more (mine), each asserted BOTH ways: the phrase-diagnostic
#     from sections 1/1M/2.10/2M does NOT catch it (the documented gap the
#     independent review found) and the content pin from 2P DOES (the fix).
#     Never "add these five phrases to BANNED_CLAIM_PATTERN" — per the file
#     header, that is the error this section replaces, not repeats.
# ===========================================================================
printf '\n--- 2Q. EVASION REGRESSION: R1-F1 reproduced, and closed by the pin, not the list ---\n'

EVASION_PHRASES=(
    "This provenance-authenticated record can only be produced by qa-gate.sh approve."
    "cryptographically bound to the approving process"
    "only qa-gate.sh approve can emit this record"
    "authenticity is guaranteed by the writer"
    "this record is attested, not merely asserted"
)
EVASION_LABELS=(
    "2Q.1 (Sol's reproduction: provenance-authenticated)"
    "2Q.2 (cryptographically bound)"
    "2Q.3 (only qa-gate.sh approve can emit)"
    "2Q.4 (authenticity is guaranteed)"
    "2Q.5 (attested, not merely asserted)"
)
qi=0
while [ "$qi" -lt "${#EVASION_PHRASES[@]}" ]; do
    phrase="${EVASION_PHRASES[$qi]}"
    label="${EVASION_LABELS[$qi]}"
    assert_eq "${label}a DOCUMENTED GAP: the phrase diagnostic does NOT catch this evasion (why 2P, not this list, must be load-bearing)" \
        "0" "$(banned_claim_count_text "$phrase" | tr -d '[:space:]')"
    evaded_block="${SHIPPED_BLOCK}
${phrase}"
    assert_eq "${label}b THE FIX: the content pin DOES catch the same evasion (hash moves away from the reviewed pin)" \
        "yes" "$([ "$(sha256_of "$evaded_block")" != "$EXPECTED_BLOCK_SHA256" ] && echo yes || echo no)"
    qi=$((qi + 1))
done

# RESTORE CONTROL: unmodified shipped block, re-hashed, still matches — the
# evasion loop above did not mutate $SHIPPED_BLOCK itself.
assert_eq "2Q.6 RESTORE CONTROL: the unmodified shipped block still matches the pin after the evasion loop" \
    "$EXPECTED_BLOCK_SHA256" "$(sha256_of "$SHIPPED_BLOCK")"

# ===========================================================================
# 3. TRANSITIVE SOURCE PINS (R2-F1, independent review round 2, confirmed
#    against source before this section was written) — R1-F1's pin (2P)
#    covers the TEMPLATE at LABEL-WITHOUT-RECORD-BLOCK as it stands; it does
#    NOT cover the CONTRIBUTORS that template interpolates. Section 2's
#    driver hardcodes APPROVAL_RECORD_DETAIL and stubs checks_scope_note to
#    empty, so a claim written into either real PRODUCER — the
#    verify-before-stop.sh:6491-shaped vector this section closes — never
#    reaches SHIPPED_BLOCK, never moves EXPECTED_BLOCK_SHA256, reads as
#    ZERO on the phrase diagnostic by construction, and passes every
#    assertion sections 1 through 2Q make.
#
#    THE CONTRIBUTOR SET AS UNDERSTOOD AT THIS FIX (R2-F1) — verified by
#    reading the call graph, every producer below grepped for further
#    $(...) calls before being declared a leaf. THIS IS NOT "THE FULL
#    CONTRIBUTOR SET" and must not be read as one (R5-F1, independent
#    review round 5: an earlier version of this comment called it that,
#    which was already false the moment it was written — R3-F1, below,
#    proved the call-graph method itself blind to an eighth contributor:
#    verified_state_unchanged_detail, reached through a global-variable
#    ASSIGNMENT (SUITE_REUSE_DETAIL) no `$(...)` walk can see at all. That
#    contributor is real, is covered, and is NOT in this list or in a 3.1
#    source pin — see Section 4's M5 state, which drives it directly).
#    What follows is the call-graph-reachable set only, as it stood at
#    R2-F1:
#      $APPROVAL_RECORD_DETAIL  assigned:  APPROVAL-RECORD-DETAIL-INIT
#                               appended:  APPROVAL-RECORD-DETAIL-WORKTREE-APPEND
#      $(approval_record_causes ...)   ->  APPROVAL-RECORD-CAUSES-FN   (leaf)
#      $(approval_binding_attests)     ->  APPROVAL-BINDING-ATTESTS-FN (leaf)
#      $(checks_scope_note)            ->  CHECKS-SCOPE-NOTE-FN, which
#                                           itself calls TWO MORE local
#                                           functions:
#        $(override_scope_names ...)   ->  OVERRIDE-DISCLOSURE (pre-existing
#                                           sentinel, yzo9, REUSED — it
#                                           already wraps override_active
#                                           too, which override_scope_names
#                                           itself calls) (leaf)
#        $(broader_verification_note)  ->  BROADER-VERIFICATION-NOTE-FN,
#                                           which calls tree_fingerprint —
#                                           see that sentinel's own header
#                                           for why this closure stops
#                                           there: tree_fingerprint returns a
#                                           COMPUTED git digest, never
#                                           static prose, so no maintainer
#                                           edit to it can assert a false
#                                           security property the way an
#                                           edit to any producer above could.
#      $CURRENT_TASK            NOT a producer: an opaque task id
#                               substituted at runtime (from bd task
#                               state), with no static source template to
#                               pin.
#      $LABEL_WITHOUT_RECORD    NOT a producer: a boolean gating whether
#                               this block runs at all; never itself
#                               interpolated into the rendered prose.
#
#    7 regions pinned by SOURCE sha256 in 3.1 (2 assignment/append regions +
#    4 function bodies + 1 reused pre-existing sentinel), alongside the
#    rendered-block pin (2P) that already covers the fixed template.
#
#    SELF-MAINTENANCE ("the enumeration must be checkable, not asserted")
#    WAS THE GOAL HERE; ROUND 3 PROVED IT DID NOT HOLD, which is why this
#    paragraph is now past tense rather than the present tense it used to
#    be (R5-F1: that present-tense wording was itself stale the moment 3.2
#    was removed, and is the reason this whole paragraph is rewritten, not
#    just re-dated). A check used to sit here — 3.2, SINCE REMOVED; see its
#    own removal note further down this file — that extracted the ACTUAL
#    $(...) calls out of each pinned region's CURRENT source and failed if
#    any call target was a function DEFINED in this file (as opposed to a
#    builtin/external command like printf/tail, which no local edit can
#    inject a claim into) that was not already in the accounted-for set
#    above. The GOAL was that a sixth interpolation added to any pinned
#    region — a new call, a new bare variable — would fail mechanically,
#    before anyone had to remember this comment exists. TWO independent
#    findings proved that goal unmet: R3-F1 (a global-variable READ, not a
#    call — invisible to any call-graph walk, this mechanism included) and
#    R3-F2 (an alternate function-definition/invocation syntax the check's
#    own regex missed). The mechanism was REMOVED rather than re-guarded a
#    third time; Section 4 replaced "prove every producer is enumerated"
#    with "render N named states and pin what they actually produce".
#
#    3.3 proves the gap R2-F1 found is closed the way 2Q proved R1-F1's:
#    Sol's evasion phrase, written into the :6491-shaped producer THIS TIME
#    (not appended after rendering, as 2Q does for the rendered-block pin),
#    reaches an end-to-end render that exercises the REAL producer — and
#    the new source pin on that producer, unlike sections 1 through 2Q,
#    catches it.
# ===========================================================================
printf '\n--- 3.0 EXTRACT: the call-graph-reachable source regions, as understood at R2-F1 ---\n'

ARDI="$WORK/ardi.sh"; ARDI_RC=0
extract_region "$VBS" "# APPROVAL-RECORD-DETAIL-INIT BEGIN" "# APPROVAL-RECORD-DETAIL-INIT END" "$ARDI" || ARDI_RC=$?
ARDW="$WORK/ardw.sh"; ARDW_RC=0
extract_region "$VBS" "# APPROVAL-RECORD-DETAIL-WORKTREE-APPEND BEGIN" "# APPROVAL-RECORD-DETAIL-WORKTREE-APPEND END" "$ARDW" || ARDW_RC=$?
ARC_FN="$WORK/arc-fn.sh"; ARC_FN_RC=0
extract_region "$VBS" "# APPROVAL-RECORD-CAUSES-FN BEGIN" "# APPROVAL-RECORD-CAUSES-FN END" "$ARC_FN" || ARC_FN_RC=$?
ABA_FN="$WORK/aba-fn.sh"; ABA_FN_RC=0
extract_region "$VBS" "# APPROVAL-BINDING-ATTESTS-FN BEGIN" "# APPROVAL-BINDING-ATTESTS-FN END" "$ABA_FN" || ABA_FN_RC=$?
CSN_FN="$WORK/csn-fn.sh"; CSN_FN_RC=0
extract_region "$VBS" "# CHECKS-SCOPE-NOTE-FN BEGIN" "# CHECKS-SCOPE-NOTE-FN END" "$CSN_FN" || CSN_FN_RC=$?
BVN_FN="$WORK/bvn-fn.sh"; BVN_FN_RC=0
extract_region "$VBS" "# BROADER-VERIFICATION-NOTE-FN BEGIN" "# BROADER-VERIFICATION-NOTE-FN END" "$BVN_FN" || BVN_FN_RC=$?
OD="$WORK/od.sh"; OD_RC=0
extract_region "$VBS" "# OVERRIDE-DISCLOSURE BEGIN" "# OVERRIDE-DISCLOSURE END" "$OD" || OD_RC=$?

assert_eq "3.0a non-vacuity: APPROVAL-RECORD-DETAIL-INIT sentinels exist" "0" "$ARDI_RC"
assert_eq "3.0b non-vacuity: APPROVAL-RECORD-DETAIL-WORKTREE-APPEND sentinels exist" "0" "$ARDW_RC"
assert_eq "3.0c non-vacuity: APPROVAL-RECORD-CAUSES-FN sentinels exist" "0" "$ARC_FN_RC"
assert_eq "3.0d non-vacuity: APPROVAL-BINDING-ATTESTS-FN sentinels exist" "0" "$ABA_FN_RC"
assert_eq "3.0e non-vacuity: CHECKS-SCOPE-NOTE-FN sentinels exist" "0" "$CSN_FN_RC"
assert_eq "3.0f non-vacuity: BROADER-VERIFICATION-NOTE-FN sentinels exist" "0" "$BVN_FN_RC"
assert_eq "3.0g non-vacuity: OVERRIDE-DISCLOSURE sentinels exist (pre-existing, reused)" "0" "$OD_RC"
assert_eq "3.0h non-vacuity: every extracted region is non-empty" \
    "yes" "$([ -s "$ARDI" ] && [ -s "$ARDW" ] && [ -s "$ARC_FN" ] && [ -s "$ABA_FN" ] && [ -s "$CSN_FN" ] && [ -s "$BVN_FN" ] && [ -s "$OD" ] && echo yes || echo no)"

sha256_of_file() {
    # File-hashing twin of 2P's sha256_of (which hashes a captured STRING).
    # Same fallback order as qa-gate.sh's sha256_file.
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$1" | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$1" | awk '{print $1}'
    else
        printf 'approval-record-disclosure-claim.test: neither shasum nor sha256sum on PATH — section 3 cannot run\n' >&2
        exit 2
    fi
}

# assert_source_pin <region-file> <expected-sha256> <region-name> <label>
#
# Requirement (anti-overreach with SEVERAL pins): the failure message names
# WHICH region moved, by <region-name>, and gives the identical re-bless
# recipe 2P's own failure message gives.
assert_source_pin() {
    local region="$1" expected="$2" name="$3" label="$4" actual
    actual=$(sha256_of_file "$region")
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s: %s source matches its reviewed sha256\n' "$label" "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$label: $name source matches its reviewed sha256")
        printf '  FAIL: %s: %s source matches its reviewed sha256\n' "$label" "$name"
        printf '    region:          %s\n' "$name"
        printf '    expected sha256: %s\n' "$expected"
        printf '    ACTUAL   sha256: %s\n' "$actual"
        printf '    If this is a DELIBERATE, REVIEWED change to %s: paste the ACTUAL\n' "$name"
        printf '    value above over its EXPECTED_*_SHA256 constant in section 3 of THIS\n'
        printf '    file, in the SAME change set as the edit. If not, the source changed\n'
        printf '    unexpectedly -- investigate before touching the pin.\n'
    fi
}

printf '\n--- 3.1 SOURCE PINS: each call-graph-reachable contributor pinned by its own exact sha256 ---\n'

# Pinned at pqnd R2-F1. Each constant covers exactly ONE region so a
# mismatch names exactly one contributor.
EXPECTED_ARDI_SHA256="f3d41c97a25a9df7ee93520e274a6193af2ff443322c0b2df63176d5c613e082"
# claude-workflow-plugin-3otl R1-F1: re-pinned. The APPROVAL-RECORD-DETAIL-
# WORKTREE-APPEND region legitimately grew a second axis (WTRES_DESIGN_DETAIL,
# composed alongside WTRES_REVIEW_DETAIL — see wtres_design_is_ready and its
# call site in verify-before-stop.sh). Confirmed load-bearing before pasting
# the new value over the old one: reverting this one line while leaving the
# region edit in place fails 3.1b again (measured), so this pin is still
# doing its job rather than being a rubber stamp.
EXPECTED_ARDW_SHA256="043d61414b54f9207fdb6ce0b897cc1e66ecbb40a484fd12fd0e02a8cb6a5ee9"
EXPECTED_ARC_FN_SHA256="bbcd614a3e7188ef30e77431644d467fec0d6423ec590637845edda055fbeaa6"
EXPECTED_ABA_FN_SHA256="0e448b98e62608bd51f107ef7b09bf859e4237e190890d9efbd64c72ae6a7cd1"
EXPECTED_CSN_FN_SHA256="9836be34aaaa76388a1ab9284bd3194d6e61bd95cd225af67531d956255a7db1"
EXPECTED_BVN_FN_SHA256="60e279fa406f5d3221191b8f6da130e1932fb3c4bfa2320ac14b8d86d0b4e55c"
EXPECTED_OD_SHA256="d983b0f5151a516122b50440c2ecdabfc74fbbf69baf778d6005af44608500e4"

assert_source_pin "$ARDI" "$EXPECTED_ARDI_SHA256" "APPROVAL-RECORD-DETAIL-INIT" "3.1a"
assert_source_pin "$ARDW" "$EXPECTED_ARDW_SHA256" "APPROVAL-RECORD-DETAIL-WORKTREE-APPEND" "3.1b"
assert_source_pin "$ARC_FN" "$EXPECTED_ARC_FN_SHA256" "APPROVAL-RECORD-CAUSES-FN" "3.1c"
assert_source_pin "$ABA_FN" "$EXPECTED_ABA_FN_SHA256" "APPROVAL-BINDING-ATTESTS-FN" "3.1d"
assert_source_pin "$CSN_FN" "$EXPECTED_CSN_FN_SHA256" "CHECKS-SCOPE-NOTE-FN" "3.1e"
assert_source_pin "$BVN_FN" "$EXPECTED_BVN_FN_SHA256" "BROADER-VERIFICATION-NOTE-FN" "3.1f"
assert_source_pin "$OD" "$EXPECTED_OD_SHA256" "OVERRIDE-DISCLOSURE" "3.1g"

# ---------------------------------------------------------------------------
# 3.1M META: each source pin must move on a ONE-BYTE difference — proves
# total content-equality per region, not a coincidental match on the one
# evasion phrase 3.3 exercises.
# ---------------------------------------------------------------------------
printf '\n--- 3.1M META: each source pin must move on a ONE-BYTE difference ---\n'

REGION_FILES=("$ARDI" "$ARDW" "$ARC_FN" "$ABA_FN" "$CSN_FN" "$BVN_FN" "$OD")
REGION_NAMES=("APPROVAL-RECORD-DETAIL-INIT" "APPROVAL-RECORD-DETAIL-WORKTREE-APPEND" "APPROVAL-RECORD-CAUSES-FN" "APPROVAL-BINDING-ATTESTS-FN" "CHECKS-SCOPE-NOTE-FN" "BROADER-VERIFICATION-NOTE-FN" "OVERRIDE-DISCLOSURE")
REGION_EXPECTED=("$EXPECTED_ARDI_SHA256" "$EXPECTED_ARDW_SHA256" "$EXPECTED_ARC_FN_SHA256" "$EXPECTED_ABA_FN_SHA256" "$EXPECTED_CSN_FN_SHA256" "$EXPECTED_BVN_FN_SHA256" "$EXPECTED_OD_SHA256")

ri=0
while [ "$ri" -lt "${#REGION_FILES[@]}" ]; do
    rf="${REGION_FILES[$ri]}"; rn="${REGION_NAMES[$ri]}"; rexp="${REGION_EXPECTED[$ri]}"
    rmut="${rf}.onebyte"
    cat "$rf" > "$rmut"
    printf ' ' >> "$rmut"
    assert_eq "3.1M.${ri}a non-vacuity: $rn one-byte mutant really differs from shipped source" \
        "yes" "$([ "$(sha256_of_file "$rmut")" != "$(sha256_of_file "$rf")" ] && echo yes || echo no)"
    assert_eq "3.1M.${ri}b SPECIFIC: $rn one-byte mutant moves the hash away from its pin" \
        "yes" "$([ "$(sha256_of_file "$rmut")" != "$rexp" ] && echo yes || echo no)"
    ri=$((ri + 1))
done

# ---------------------------------------------------------------------------
# 3.2 REMOVED (R3-F1 / R3-F2, independent review round 3; operator ruling).
#
# This section used to be the SELF-MAINTAINING closure check: is_local_fn
# (grep -qE "^$1\(\) \{"), extract_calls (grep -oE '\$\([a-zA-Z_]...'), and
# assert_calls_accounted_for, walking each pinned region's $(...) call
# syntax to catch an unaccounted interpolation mechanically. It is GONE, not
# demoted, per the operator's standing precedent for a mechanism defeated on
# repeated contact (the design-conflict waiver and the quarantine mechanism
# both went the same way) — REMOVED rather than guarded again, so a future
# reader cannot mistake a demoted check still sitting in the file for a live
# one.
#
# WHY REMOVAL, STATED PRECISELY, because "bash resists static analysis" by
# itself explains nothing without the two concrete ways this one failed:
#   R3-F1  verified_state_unchanged_detail's output reaches the operator
#          through a GLOBAL VARIABLE ASSIGNMENT (SUITE_REUSE_DETAIL, set far
#          upstream in the main dispatch, read back by checks_scope_note as
#          a plain variable) — not a function CALL at all. extract_calls
#          only ever looked for `$(name` call syntax; there is no regex
#          fix for "trace every global assignment reachable from every
#          read-site across an 8000-line, mostly set -u-free script". This
#          is a CLASS of gap, not an instance one more pattern closes.
#   R3-F2  is_local_fn (`^$1\(\) \{`) recognizes only column-1
#          `name() {` — a lint-clean `function name { ... }` definition, or
#          a statement-form call extract_calls' `$(name` pattern does not
#          match, are both invisible to it. The CLOSURE-COMPUTATION
#          MACHINERY ITSELF was the thing defeated here, not a producer it
#          failed to enumerate — widening it again repeats R1-F1's mistake
#          one layer up (a parser, guarded harder, is still a parser).
#
# WHAT REPLACES IT: Section 4 below pins the RENDERED OUTPUT of the real
# code across a matrix of representative states. It does not attempt to
# prove "every producer is enumerated" (which is what static analysis kept
# failing to establish) — it proves "these N states, actually executed,
# produce exactly this text", which requires no call-graph or definition-
# syntax reasoning at all: bash does not care how a function was defined or
# invoked when it actually RUNS it, so a claim written by ANY means, in a
# producer reachable from a covered state, moves that state's hash. Section
# 4.V2 demonstrates this directly for a `function name { ... }`-defined
# producer — the exact shape that defeated is_local_fn.
#
# 3.0/3.1/3.1M (the source pins on individual regions) are UNCHANGED and
# stay: they are correct as far as they go (a region's own literal bytes
# either match the reviewed sha256 or they do not), the operator confirmed
# this, and Section 4 does not depend on them. What they no longer do is
# stand in for "we found every contributor" — that claim belongs to Section
# 4 now, stated as a coverage list, not implied by an enumeration nobody can
# fully verify.
# ---------------------------------------------------------------------------
# 3.3 THE R2-F1 FIX, PROVED THE WAY 2Q PROVES R1-F1'S: a claim written into
# the REAL :6491-shaped producer now reaches an end-to-end render (the
# vulnerability, reproduced against the actual code path — not a synthetic
# stand-in), the phrase diagnostic still does not catch it (restating why a
# longer denylist was never the fix), and the new source pin does.
# ---------------------------------------------------------------------------
printf '\n--- 3.3 THE R2-F1 FIX: a claim at the real producer now fails the suite, via the pin, not the list ---\n'

# drive_e2e_label_without_record <ardi-region> <abt-region> <lwr-region>
#   <current_cs_hash> <current_task> — UNLIKE drive_label_without_record
#   (section 2, kept as-is), this does NOT hardcode APPROVAL_RECORD_DETAIL:
#   it sources the REAL (or mutant) APPROVAL-RECORD-DETAIL-INIT region
#   first, with CURRENT_CS_HASH/CURRENT_TASK as ITS inputs, so whatever that
#   producer assigns is what reaches the render — exactly the path R2-F1
#   found bypassed. checks_scope_note is still stubbed: this driver's
#   subject is the APPROVAL_RECORD_DETAIL producer, which has its own
#   separate source pin (3.1a) and its own separate proof here.
drive_e2e_label_without_record() {
    local ardi_region="$1" abt_region="$2" lwr_region="$3" cs_hash="$4" task="$5"
    (
        set -u
        # shellcheck disable=SC2329  # invoked from $lwr_region after it is
        # sourced below — see drive_label_without_record above for the full
        # reasoning (identical here).
        emit_block() { printf '%s' "$1"; }
        # shellcheck disable=SC2329  # see emit_block above
        checks_scope_note() { printf ''; }
        # shellcheck disable=SC2034  # read by $ardi_region and $lwr_region
        # below once sourced.
        CURRENT_TASK="$task"
        # shellcheck disable=SC2034  # read by $ardi_region below once sourced.
        CURRENT_CS_HASH="$cs_hash"
        # shellcheck disable=SC2034  # see CURRENT_TASK above
        LABEL_WITHOUT_RECORD="true"
        # No APPROVAL_RECORD_DETAIL pre-init here (unlike the other three):
        # $ardi_region unconditionally assigns it in either branch of its
        # own if/else, immediately below, before anything reads it — a
        # pre-init would itself be dead and shellcheck (correctly) flags
        # dead assignments (SC2034), unlike the genuinely-consumed-
        # elsewhere ones above.
        # shellcheck disable=SC1090
        . "$ardi_region"
        # shellcheck disable=SC1090
        . "$abt_region"
        # shellcheck disable=SC1090
        . "$lwr_region"
    )
}

E2E_BLOCK=$(drive_e2e_label_without_record "$ARDI" "$ABT" "$LWR" "deadbeefcafef00d" "proj-e2e")
assert_eq "3.3.0 non-vacuity: the E2E driver (real producer, real inputs) EMITTED text" \
    "yes" "$([ -n "$E2E_BLOCK" ] && echo yes || echo no)"
assert_contains "3.3.1 sanity: the E2E render carries the REAL producer's hash-specific text (it really ran the producer, not a stand-in)" \
    "deadbeefcafef00d" "$E2E_BLOCK"

# THE VULNERABILITY, REPRODUCED: append Sol's evasion phrase to a COPY of
# the REAL producer's source — this is R2-F1 exactly (the :6491 shape),
# not a synthetic stand-in appended to already-rendered output.
ARDI_EVASION="$WORK/ardi-evasion.sh"
{
    cat "$ARDI"
    # shellcheck disable=SC2016  # single-quoted on purpose: $APPROVAL_RECORD_DETAIL
    # must land LITERALLY in the generated $ARDI_EVASION file, to be expanded
    # when THAT file is later sourced by drive_e2e_label_without_record — not
    # expanded now, against this shell's own (unset) copy of the variable.
    printf '\nAPPROVAL_RECORD_DETAIL="$APPROVAL_RECORD_DETAIL This provenance-authenticated record can only be produced by qa-gate.sh approve."\n'
} > "$ARDI_EVASION"
ARDI_EVASION_PARSE=0; bash -n "$ARDI_EVASION" 2>/dev/null || ARDI_EVASION_PARSE=$?
assert_eq "3.3.2 non-vacuity: the evasion-mutated producer is still valid bash" "0" "$ARDI_EVASION_PARSE"

E2E_EVADED_BLOCK=$(drive_e2e_label_without_record "$ARDI_EVASION" "$ABT" "$LWR" "deadbeefcafef00d" "proj-e2e")
assert_eq "3.3.3 THE VULNERABILITY: the evasion phrase, written at the real producer, DOES reach the end-to-end render" \
    "yes" "$([ "$(contains_count "provenance-authenticated" "$E2E_EVADED_BLOCK" | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
assert_eq "3.3.4 THE GAP RESTATED: the phrase diagnostic alone still does not catch it (same shape as 2Q.1a — this is why the pin, not the list, must be load-bearing)" \
    "0" "$(banned_claim_count_text "$E2E_EVADED_BLOCK" | tr -d '[:space:]')"
assert_eq "3.3.5 THE FIX: the source pin on the REAL producer DOES catch it — sha256 differs from EXPECTED_ARDI_SHA256" \
    "yes" "$([ "$(sha256_of_file "$ARDI_EVASION")" != "$EXPECTED_ARDI_SHA256" ] && echo yes || echo no)"

# RESTORE CONTROL, both halves: the real producer's source is unmodified,
# and its end-to-end render carries no evasion text.
assert_eq "3.3.6 RESTORE CONTROL: the real producer's source, unmodified, still matches its pin" \
    "$EXPECTED_ARDI_SHA256" "$(sha256_of_file "$ARDI")"
assert_eq "3.3.7 RESTORE CONTROL: the E2E render of the REAL (unmutated) producer carries no evasion text" \
    "0" "$(contains_count "provenance-authenticated" "$E2E_BLOCK" | tr -d '[:space:]')"

# ===========================================================================
# 4. RENDERED-OUTPUT STATE MATRIX (R3-F1 / R3-F2, independent review round 3;
#    operator ruling — see 3.2's removal note above for the full reasoning).
#
#    THE SHAPE CHANGE. Sections 1-3.3 tried to prove completeness by
#    ENUMERATING producers (a phrase list, then source regions, then a
#    call-graph closure) — each enumeration was defeated by something the
#    previous one's author had not thought to list. This section proves a
#    DIFFERENT, narrower claim that does not require enumeration at all: for
#    each of N named states, drive the REAL end-to-end code (not a
#    synthetic stand-in) and pin the resulting operator text by sha256. Any
#    change to ANY contributor — however it is defined, however it is
#    invoked, however many calls deep, including one reached only through a
#    global variable no call-graph walk would find — moves the hash of
#    every state that reaches it, because the pin is over what the code
#    ACTUALLY PRINTED, not over a model of what the code might print.
#
#    THE STATE LIST, AND HOW IT WAS DERIVED: read line-by-line from
#    checks_scope_note's actual branches (verify-before-stop.sh, the
#    CHECKS-SCOPE-NOTE-FN region) and from APPROVAL-RECORD-DETAIL-INIT /
#    -WORKTREE-APPEND's own if/elif/else structure — not guessed, and not
#    a re-run of the closure computation just removed. One-factor-at-a-time
#    (OFAT): each state changes exactly one dimension from the M1 baseline,
#    because the branches enumerated are independent (no evidence any two
#    interact), and a full cross-product would be combinatorial for no
#    proven benefit.
#      M1  BASELINE                    — hash present, worktree default
#                                         (checked N worktree(s)), fresh
#                                         (non-reused) suite run, no
#                                         override active
#      M2  HASH-UNRECOMPUTABLE         — CURRENT_CS_HASH empty (ARDI's
#                                         "could not be recomputed" branch)
#      M3  WORKTREE-REVIEW-DIRTY       — ARDW's WTRES_REVIEW_DETAIL branch
#      M4  WORKTREE-DELETED            — ARDW's WTRES_DELETED_TOKEN branch
#      M5  SUITE-REUSE-DETAIL-POPULATED — SUITE_REUSED=true via
#                                         VERIFY_SKIP_UNCHANGED, driving the
#                                         REAL verified_state_unchanged_detail
#                                         against a fixed fixture file (R3-F1's
#                                         exact path, closed at its source)
#      M6  SUITE-REUSE-DETAIL-EMPTY    — SUITE_REUSED=true via the escalation
#                                         branch, where SUITE_REUSE_DETAIL
#                                         stays empty by the shipped code's
#                                         own design (see checks_scope_note's
#                                         comment on this)
#      M7  OVERRIDE-ACTIVE             — OVERRIDE_TEST=true, exercising
#                                         override_active/override_scope_names
#                                         and the [OVERRIDE] tag + summary
#                                         paragraph
#    M1 already IS "worktree default" and "no override active", so those two
#    "at minimum" items are covered by the baseline rather than a dedicated
#    state — restating them as separate states would render byte-identical
#    text to M1 under a different name.
#
#    STATED COVERAGE RESIDUAL (required to be legible, not just true). NOT
#    covered by this matrix:
#      - THIS MATRIX COVERS EXACTLY ONE emit_block SITE, STATED FIRST BECAUSE
#        IT IS THE ONE THAT MATTERS MOST (R4-F1, independent review round 4,
#        confirmed against source). render_matrix_state sources ONLY the
#        LABEL-WITHOUT-RECORD-BLOCK sentinel region (verify-before-stop.sh,
#        ending at its own END sentinel, currently line 7227) — it does not
#        drive, source, or in any way exercise ANY OTHER emit_block call in
#        either shipped script. A CONCRETE, CONFIRMED EXAMPLE: the very next
#        block in the file, `if [ "$REVIEW_DISCIPLINE_BLOCKED" = "true" ];
#        then`, has its OWN, entirely separate operator-facing emit_block
#        call (currently line 7237, "Approved change-set, but the
#        INDEPENDENT REVIEW is not clean..."). No state M1-M7 ever sets
#        REVIEW_DISCIPLINE_BLOCKED=true or reaches that branch. A claim
#        written into THAT block's static prose (or into
#        $REVIEW_DISCIPLINE_DETAIL, which it interpolates) reaches a real
#        operator at a real Stop block, moves NONE of these seven pinned
#        hashes, matches NONE of BANNED_CLAIM_PATTERN's four alternatives
#        (it is, by construction, an unenumerated synonym), and is invisible
#        to every 3.1 source pin too (those cover ARDI/ARDW/ARC_FN/ABA_FN/
#        CSN_FN/BVN_FN/OD — none of which include this block's source). The
#        SAME is true, unconfirmed but structurally identical, of
#        DESIGN_DISCIPLINE_BLOCKED's sibling block, the generic QA-required
#        block further down, and EVERY emit_block / emit_error_json / similar
#        call site in qa-gate.sh — all of it OUTSIDE this guard entirely, not
#        merely under-covered by it. Filed as claude-workflow-plugin-7n36 (a
#        known, accepted limit — not fixed here; see the file header's
#        four-shape history for why the operator ruled to stop rather than
#        build a fifth guard shape).
#      - TEST_CMD/LINT_CMD/TYPE_CMD presence combinations other than the
#        baseline's (test+lint present, type absent — this repo's own real
#        shape). All-absent, type-present, and every other combination are
#        UNEXERCISED here.
#      - TIMEOUT_NOT_ENFORCED (the watchdog-fallback paragraph) — UNEXERCISED.
#      - Any DIMENSION INTERACTION (e.g. an override active AND a dirty
#        worktree AND a reused suite simultaneously) — OFAT deliberately
#        does not cross dimensions; an interaction bug between two covered
#        dimensions could exist and this matrix would not find it.
#      - broader_verification_note's OWN internal branches (ledger empty /
#        tree moved / tree unchanged / degraded-tool cases) — held at ONE
#        constant state (empty ledger, "NONE RECORDED") across every row
#        here on purpose, so that function's OWN variance (already covered
#        in depth by gate-claim-honesty.test.sh's Section 4) does not leak
#        into these pins as unrelated noise.
#      - WITHIN THE ONE SITE THIS MATRIX DOES COVER: a producer reachable
#        from NONE of these 7 states — a new `if` branch gated on a
#        condition none of M1-M7 sets — would not be exercised, and this
#        matrix would not catch a claim written there. That is the honest
#        trade this whole section makes: a STATED incompleteness ("these 7
#        states, not others, of this one block") in place of a HIDDEN one
#        ("our regex might miss a definition form"). Extending coverage
#        WITHIN this site means adding a new M-state for a newly-identified
#        branch, not widening a pattern; extending it to ANOTHER site is the
#        claude-workflow-plugin-7n36 work, deliberately not undertaken here.
# ===========================================================================
printf '\n--- 4.0 EXTRACT: the one new region R3-F1 requires ---\n'

VSU_FN="$WORK/vsu-fn.sh"; VSU_FN_RC=0
extract_region "$VBS" "# VERIFIED-STATE-UNCHANGED-DETAIL-FN BEGIN" "# VERIFIED-STATE-UNCHANGED-DETAIL-FN END" "$VSU_FN" || VSU_FN_RC=$?
assert_eq "4.0a non-vacuity: VERIFIED-STATE-UNCHANGED-DETAIL-FN sentinels exist" "0" "$VSU_FN_RC"
assert_eq "4.0b non-vacuity: the extracted region is non-empty" "yes" "$([ -s "$VSU_FN" ] && echo yes || echo no)"

# reset_matrix_baseline — the M1 BASELINE every state starts from and
# overrides at most one dimension of. Documented ONCE here rather than
# repeated per state, so "what is the baseline" has one place to read.
# shellcheck disable=SC2034  # every assignment in this function is read by
# the sourced regions render_matrix_state applies immediately after it runs
# (ARDI/ARDW/CSN_FN/BVN_FN/VSU_FN) — shellcheck cannot see a reader defined
# in a file extracted and sourced at runtime.
reset_matrix_baseline() {
    CURRENT_TASK="proj-m"
    CURRENT_CS_HASH="cafefeed0000000000000000000000000000000000000000000000000feed1"
    APPROVAL_RECORD_DETAIL=""
    LABEL_WITHOUT_RECORD="true"
    WTRES_REVIEW_DETAIL=""
    # claude-workflow-plugin-3otl R1-F1: sibling of WTRES_REVIEW_DETAIL above.
    # The shipped APPROVAL-RECORD-DETAIL-WORKTREE-APPEND region reads this
    # variable unconditionally now that the design axis exists
    # (wtres_design_is_ready), and render_matrix_state sources that region
    # ALONE under `set -u` — an un-seeded read there is an unbound-variable
    # crash, not an empty string (measured: all 7 matrix states died on
    # "WTRES_DESIGN_DETAIL: unbound variable" before this line existed).
    # Seeded HERE rather than inside the sourced region itself, on QA's
    # stated preference: the region runs AFTER wtres_design_is_ready has
    # already set the real detail on the live path, so an initialiser placed
    # inside it would overwrite (erase) that message on every state that
    # populates it, breaking wtres-8b.4's design-conflict disclosure text.
    WTRES_DESIGN_DETAIL=""
    WTRES_DELETED_TOKEN=""
    WTRES_CHECKED="0"
    WTRES_WORKTREE=""
    # FP_NO_GIT/FP_NO_HASH: the shipped script's own constants
    # (verify-before-stop.sh:585-586), reproduced here rather than sourced —
    # tree_fingerprint is stubbed below (a live git digest, not a
    # contributor this suite pins), so broader_verification_note's
    # degradation-sentinel comparisons need these two literal values
    # available under set -u regardless.
    FP_NO_GIT="no-git"
    FP_NO_HASH="no-hash"
    # A nonexistent path, deliberately: broader_verification_note's
    # `[ ! -s "$VERIFICATION_LEDGER" ]` guard then takes its "NONE RECORDED"
    # branch on every state, holding that function's OWN considerable
    # internal variance at one constant across this whole matrix (see the
    # section header's stated coverage residual on this point).
    VERIFICATION_LEDGER="$WORK/matrix-qatrack/verification-ledger-nonexistent"
    RUNNER="npm"
    TEST_CMD="npm test"
    LINT_CMD="npm run lint"
    TYPE_CMD=""
    SUITE_REUSED="false"
    SUITE_REUSE_REASON=""
    SUITE_REUSE_DETAIL=""
    SUITE_REUSE_OVERRIDE_KNOWN="false"
    TIMEOUT_NOT_ENFORCED=""
    OVERRIDE_TEST="false"
    OVERRIDE_LINT="false"
    OVERRIDE_TYPE="false"
    QA_TRACKING_DIR="$WORK/matrix-qatrack"
    mkdir -p "$QA_TRACKING_DIR"
    rm -f "$QA_TRACKING_DIR"/last-verified-state.* 2>/dev/null || true
}

# Every state_m*_* function below: shellcheck disable=SC2329 (invoked
# indirectly via render_matrix_state's `"$state_fn"`, never called by name
# directly — the same reasoning as every stub function elsewhere in this
# file) and SC2034 (each assignment is read by the sourced regions applied
# immediately after the state function runs). Both apply for the same
# reason at every one of the seven; stated once here rather than repeated
# seven times.
# shellcheck disable=SC2329,SC2034
state_m1_baseline() { :; }  # no override — the baseline itself
# shellcheck disable=SC2329,SC2034
state_m2_hash_unrecomputable() { CURRENT_CS_HASH=""; }
# shellcheck disable=SC2329,SC2034
state_m3_worktree_review_dirty() {
    WTRES_WORKTREE="/tmp/wt-fixed"
    WTRES_REVIEW_DETAIL="an approval bound in worktree /tmp/wt-fixed DOES cover this change set, but its independent review is not clean (open finding R1-F1 at risk_threshold=high)"
}
# shellcheck disable=SC2329,SC2034
state_m4_worktree_deleted() { WTRES_DELETED_TOKEN="wt-4f2a-deleted-fixed"; }
# shellcheck disable=SC2329,SC2034
state_m5_suite_reuse_detail_populated() {
    SUITE_REUSED="true"
    SUITE_REUSE_REASON="tree and change-set unchanged since the last recorded run"
    SUITE_REUSE_OVERRIDE_KNOWN="true"
    # A FIXED fixture, not a live read: three tab-separated fields
    # (ts, fingerprint, hash) so the REAL verified_state_unchanged_detail
    # renders deterministic, reviewable text instead of live git/tracker
    # state that would move this pin on every unrelated commit.
    printf '2026-01-01T00:00:00Z\tfp-fixed-1234\thash-fixed-5678\n' \
        > "$QA_TRACKING_DIR/last-verified-state.$CURRENT_TASK"
    SUITE_REUSE_DETAIL=$(verified_state_unchanged_detail "$CURRENT_TASK")
}
# shellcheck disable=SC2329,SC2034
state_m6_suite_reuse_detail_empty() {
    SUITE_REUSED="true"
    SUITE_REUSE_REASON="escalation contract"
    SUITE_REUSE_OVERRIDE_KNOWN="false"
    SUITE_REUSE_DETAIL=""
}
# shellcheck disable=SC2329,SC2034
state_m7_override_active() { OVERRIDE_TEST="true"; }

# render_matrix_state <state-fn-name> — sources every REAL region needed for
# a full end-to-end render (pure function-definition regions first, so they
# exist before anything calls them; then baseline + the named state's
# overrides, which may themselves call a just-sourced function; then the
# ORDER-DEPENDENT regions — ARDI/ARDW/LWR execute immediately on sourcing
# and read whatever state is already set). Stubs ONLY genuinely-dynamic leaf
# data this suite must not let leak live values into a pin (tree_fingerprint
# — a live git digest recomputed on every call, never static prose) plus
# emit_block (capture instead of print+exit) and two PURE PLUMBING functions
# (sanitize_task_id, last_verified_state_file_for — path formatting only,
# reimplemented verbatim rather than sourced via a third new sentinel for
# two functions no false security claim could hide inside; verified
# byte-identical to verify-before-stop.sh:89-91 and :3206-3210 above).
render_matrix_state() {
    local state_fn="$1"
    (
        set -u
        # shellcheck disable=SC2329  # invoked from $lwr_region after it is
        # sourced below — see drive_label_without_record's identical note.
        emit_block() { printf '%s' "$1"; }
        # shellcheck disable=SC2329  # live git digest — deliberately NOT
        # let through to a pin; see BROADER-VERIFICATION-NOTE-FN's own
        # header for why this one function is the documented exclusion.
        tree_fingerprint() { printf 'FAKE-FIXED-FINGERPRINT-for-determinism'; }
        # shellcheck disable=SC2329
        sanitize_task_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
        # shellcheck disable=SC2329
        last_verified_state_file_for() {
            local tid="$1"
            [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-verified-state"; return; }
            printf '%s/last-verified-state.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
        }
        # shellcheck disable=SC1090  # runtime extraction output, not constant
        . "$ABT"
        # shellcheck disable=SC1090
        . "$CSN_FN"
        # shellcheck disable=SC1090
        . "$OD"
        # shellcheck disable=SC1090
        . "$BVN_FN"
        # shellcheck disable=SC1090
        . "$VSU_FN"
        reset_matrix_baseline
        "$state_fn"
        # shellcheck disable=SC1090
        . "$ARDI"
        # shellcheck disable=SC1090
        . "$ARDW"
        # shellcheck disable=SC1090
        . "$LWR"
    )
}

printf '\n--- 4.1-4.7 STATE MATRIX: real end-to-end render, pinned by sha256, per state ---\n'

# assert_matrix_pin <state-label> <rendered-text> <expected-sha256>
assert_matrix_pin() {
    local label="$1" text="$2" expected="$3" actual
    actual=$(sha256_of "$text")
    if [ "$actual" = "$expected" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s: rendered state matches its reviewed sha256\n' "$label"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$label: rendered state matches its reviewed sha256")
        printf '  FAIL: %s: rendered state matches its reviewed sha256\n' "$label"
        printf '    expected sha256: %s\n' "$expected"
        printf '    ACTUAL   sha256: %s\n' "$actual"
        printf '    If this is a DELIBERATE, REVIEWED change reachable from this state:\n'
        printf '    paste the ACTUAL value above over this state'"'"'s EXPECTED_M*_SHA256\n'
        printf '    constant in section 4 of THIS file, in the SAME change set as the edit.\n'
        printf '    If not, investigate before touching the pin. Full rendered text:\n'
        printf '    ----------------------------------------------------------------\n'
        printf '%s\n' "$text"
        printf '    ----------------------------------------------------------------\n'
    fi
}

M1_TEXT=$(render_matrix_state state_m1_baseline)
M2_TEXT=$(render_matrix_state state_m2_hash_unrecomputable)
M3_TEXT=$(render_matrix_state state_m3_worktree_review_dirty)
M4_TEXT=$(render_matrix_state state_m4_worktree_deleted)
M5_TEXT=$(render_matrix_state state_m5_suite_reuse_detail_populated)
M6_TEXT=$(render_matrix_state state_m6_suite_reuse_detail_empty)
M7_TEXT=$(render_matrix_state state_m7_override_active)

assert_eq "4.1a non-vacuity: M1 BASELINE emitted text" "yes" "$([ -n "$M1_TEXT" ] && echo yes || echo no)"
assert_contains "4.1b sanity: M1 shows the worktree-default append" "checked 0 worktree(s)" "$M1_TEXT"
assert_contains "4.1c sanity: M1 shows a fresh (non-reused) run" "RAN      tests       npm test" "$M1_TEXT"
EXPECTED_M1_SHA256="13bd2ffdac50ffd1c25cd8f8241c276db03b983cfb12f253f3136065ca11097f"
assert_matrix_pin "4.1d M1 BASELINE" "$M1_TEXT" "$EXPECTED_M1_SHA256"

assert_eq "4.2a non-vacuity: M2 HASH-UNRECOMPUTABLE emitted text" "yes" "$([ -n "$M2_TEXT" ] && echo yes || echo no)"
assert_contains "4.2b sanity: M2 shows the unrecomputable-hash branch" "could not be recomputed" "$M2_TEXT"
EXPECTED_M2_SHA256="ac43e048fe1b6673268c5d6b5264b324423b8d7739605ce32d9b2d04524ff231"
assert_matrix_pin "4.2c M2 HASH-UNRECOMPUTABLE" "$M2_TEXT" "$EXPECTED_M2_SHA256"

assert_eq "4.3a non-vacuity: M3 WORKTREE-REVIEW-DIRTY emitted text" "yes" "$([ -n "$M3_TEXT" ] && echo yes || echo no)"
# claude-workflow-plugin-3otl R1-F1: the ARDW template's tail legitimately
# changed from "resolve-finding or arbitrate, then re-run" to
# "resolve-finding/arbitrate the review, or record a fresh design verdict,
# then re-run" — the top-level "or" now separates the REVIEW remediation from
# the (new) DESIGN remediation, so the review-internal alternative moved to a
# "/". M3 only sets WTRES_REVIEW_DETAIL (design stays empty), so it still
# renders the review-only half of that sentence; updated to what the shipped
# template actually emits on this state.
assert_contains "4.3b sanity: M3 shows the review-dirty worktree append" "resolve-finding/arbitrate the review" "$M3_TEXT"
# Re-pinned for the same reason as EXPECTED_ARDW_SHA256 above (section 3.1):
# confirmed load-bearing the same way — the OLD value against this NEW render
# is exactly the R1-F1 failure this task fixed (measured before this edit).
EXPECTED_M3_SHA256="bcc95918ac018a8d562463b6b99560df4d27044b1e5928092d7f5cc7196fedc3"
assert_matrix_pin "4.3c M3 WORKTREE-REVIEW-DIRTY" "$M3_TEXT" "$EXPECTED_M3_SHA256"

assert_eq "4.4a non-vacuity: M4 WORKTREE-DELETED emitted text" "yes" "$([ -n "$M4_TEXT" ] && echo yes || echo no)"
assert_contains "4.4b sanity: M4 shows the deleted-worktree append" "no longer exists as a live worktree" "$M4_TEXT"
EXPECTED_M4_SHA256="9e0fe9474caedcc2ab4dee13f630f7595d79f37c58cba37b57c070709d0d5637"
assert_matrix_pin "4.4c M4 WORKTREE-DELETED" "$M4_TEXT" "$EXPECTED_M4_SHA256"

assert_eq "4.5a non-vacuity: M5 SUITE-REUSE-DETAIL-POPULATED emitted text" "yes" "$([ -n "$M5_TEXT" ] && echo yes || echo no)"
assert_contains "4.5b sanity: M5 carries the REAL verified_state_unchanged_detail output (R3-F1's exact path, exercised)" \
    "fp-fixed-1234" "$M5_TEXT"
assert_contains "4.5c sanity: M5's Reused-because line rendered" "Reused because the tree" "$M5_TEXT"
EXPECTED_M5_SHA256="f81420c44080b66bdb0dc1eb994410678fcd94eed9bac85ca83b18d0638ea42f"
assert_matrix_pin "4.5d M5 SUITE-REUSE-DETAIL-POPULATED" "$M5_TEXT" "$EXPECTED_M5_SHA256"

assert_eq "4.6a non-vacuity: M6 SUITE-REUSE-DETAIL-EMPTY emitted text" "yes" "$([ -n "$M6_TEXT" ] && echo yes || echo no)"
assert_absent "4.6b sanity: M6 carries NO Reused-because line (detail genuinely empty)" "Reused because" "$M6_TEXT"
assert_contains "4.6c sanity: M6 shows the escalation-contract reason" "escalation contract" "$M6_TEXT"
EXPECTED_M6_SHA256="e8f395e04689ef7d67ecefed6f91e24dca13503940f5fd07dff1499cd4793041"
assert_matrix_pin "4.6d M6 SUITE-REUSE-DETAIL-EMPTY" "$M6_TEXT" "$EXPECTED_M6_SHA256"

assert_eq "4.7a non-vacuity: M7 OVERRIDE-ACTIVE emitted text" "yes" "$([ -n "$M7_TEXT" ] && echo yes || echo no)"
assert_contains "4.7b sanity: M7 shows the [OVERRIDE] tag on the tests line" "[OVERRIDE: .claude/test-cmd" "$M7_TEXT"
assert_contains "4.7c sanity: M7 shows the override summary paragraph" "OPERATOR OVERRIDE IN EFFECT for: test" "$M7_TEXT"
EXPECTED_M7_SHA256="1f6b72c03c028a4cc0ed20fe94b49a9a95fe1f335f7fe4228cb9b9c7c1be55bb"
assert_matrix_pin "4.7d M7 OVERRIDE-ACTIVE" "$M7_TEXT" "$EXPECTED_M7_SHA256"

# ---------------------------------------------------------------------------
# 4.M META: each state's pin must move on a ONE-BYTE difference — proves
# total content-equality per state, matching 2P-M's and 3.1M's own
# non-vacuity discipline applied to the new mechanism.
# ---------------------------------------------------------------------------
printf '\n--- 4.M META: each state pin must move on a ONE-BYTE difference ---\n'

MATRIX_TEXTS=("$M1_TEXT" "$M2_TEXT" "$M3_TEXT" "$M4_TEXT" "$M5_TEXT" "$M6_TEXT" "$M7_TEXT")
MATRIX_LABELS=("M1" "M2" "M3" "M4" "M5" "M6" "M7")
MATRIX_EXPECTED=("$EXPECTED_M1_SHA256" "$EXPECTED_M2_SHA256" "$EXPECTED_M3_SHA256" "$EXPECTED_M4_SHA256" "$EXPECTED_M5_SHA256" "$EXPECTED_M6_SHA256" "$EXPECTED_M7_SHA256")

mi=0
while [ "$mi" -lt "${#MATRIX_TEXTS[@]}" ]; do
    mtext="${MATRIX_TEXTS[$mi]}"; mlabel="${MATRIX_LABELS[$mi]}"; mexp="${MATRIX_EXPECTED[$mi]}"
    mtext_mut="${mtext} "
    assert_eq "4.M.${mi}a non-vacuity: $mlabel one-byte mutant really differs" \
        "yes" "$([ "$mtext_mut" != "$mtext" ] && echo yes || echo no)"
    assert_eq "4.M.${mi}b SPECIFIC: $mlabel one-byte mutant moves the hash away from its pin" \
        "yes" "$([ "$(sha256_of "$mtext_mut")" != "$mexp" ] && echo yes || echo no)"
    mi=$((mi + 1))
done

# ===========================================================================
# 4.V1 R3-F1 VECTOR PROOF — the SAME shape as 3.3's r2 proof, applied to the
# global-variable path: write the evasion phrase into a COPY of
# verified_state_unchanged_detail's own template, re-render M5 (the state
# that actually calls it) with the mutant, and prove the MATRIX pin (not a
# phrase list) catches it.
# ===========================================================================
printf '\n--- 4.V1 R3-F1 VECTOR: an evasion phrase in verified_state_unchanged_detail now fails via the matrix pin ---\n'

VSU_EVASION="$WORK/vsu-evasion.sh"
sed "s/\"\${fp:-?}\" \"\${hash:-?}\" \"\${ts:-?}\"/\"\${fp:-?}\" \"\${hash:-?}\" \"\${ts:-?}\"; printf ' This provenance-authenticated record can only be produced by qa-gate.sh approve.'/" \
    "$VSU_FN" > "$VSU_EVASION"
VSU_EVASION_PARSE=0; bash -n "$VSU_EVASION" 2>/dev/null || VSU_EVASION_PARSE=$?
assert_eq "4.V1.0 non-vacuity: the evasion-mutated VSU region is still valid bash" "0" "$VSU_EVASION_PARSE"
assert_eq "4.V1.1 non-vacuity: the mutant source differs from the shipped region" \
    "yes" "$([ "$(sha256_of_file "$VSU_EVASION")" != "$(sha256_of_file "$VSU_FN")" ] && echo yes || echo no)"

render_matrix_state_with_vsu() {
    local state_fn="$1" vsu_region="$2"
    (
        set -u
        # shellcheck disable=SC2329
        emit_block() { printf '%s' "$1"; }
        # shellcheck disable=SC2329
        tree_fingerprint() { printf 'FAKE-FIXED-FINGERPRINT-for-determinism'; }
        # shellcheck disable=SC2329
        sanitize_task_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
        # shellcheck disable=SC2329
        last_verified_state_file_for() {
            local tid="$1"
            [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-verified-state"; return; }
            printf '%s/last-verified-state.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
        }
        # shellcheck disable=SC1090
        . "$ABT"
        # shellcheck disable=SC1090
        . "$CSN_FN"
        # shellcheck disable=SC1090
        . "$OD"
        # shellcheck disable=SC1090
        . "$BVN_FN"
        # shellcheck disable=SC1090
        . "$vsu_region"
        reset_matrix_baseline
        "$state_fn"
        # shellcheck disable=SC1090
        . "$ARDI"
        # shellcheck disable=SC1090
        . "$ARDW"
        # shellcheck disable=SC1090
        . "$LWR"
    )
}

M5_EVADED_TEXT=$(render_matrix_state_with_vsu state_m5_suite_reuse_detail_populated "$VSU_EVASION")
assert_eq "4.V1.2 THE VULNERABILITY: the evasion phrase, written at the real global-variable producer, DOES reach the end-to-end render" \
    "yes" "$([ "$(contains_count "provenance-authenticated" "$M5_EVADED_TEXT" | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
assert_eq "4.V1.3 THE FIX: the M5 matrix pin catches it — rendered text no longer matches EXPECTED_M5_SHA256" \
    "yes" "$([ "$(sha256_of "$M5_EVADED_TEXT")" != "$EXPECTED_M5_SHA256" ] && echo yes || echo no)"
assert_eq "4.V1.4 RESTORE CONTROL: M5 re-rendered with the REAL region still matches its pin" \
    "$EXPECTED_M5_SHA256" "$(sha256_of "$(render_matrix_state state_m5_suite_reuse_detail_populated)")"

# ===========================================================================
# 4.V2 R3-F2 VECTOR PROOF — is_local_fn (`^$1\(\) \{`) and extract_calls
# (`\$\(name`) were both defeated by ALTERNATE bash syntax: a `function
# name { ... }`-style definition, invoked in statement form. The matrix
# approach does not parse definitions or call syntax at all, so it should
# not care which form a NEW producer uses. Proved directly: inject exactly
# that shape into a copy of a real region and show M1's pin still catches
# it.
# ===========================================================================
printf '\n--- 4.V2 R3-F2 VECTOR: a function-keyword, statement-form producer now fails via the matrix pin ---\n'

ARDI_FNKW_EVASION="$WORK/ardi-fnkw-evasion.sh"
{
    cat "$ARDI"
    printf '\nfunction _r3f2_evasion_producer {\n'
    printf '    printf '"'"' This record is cryptographically unforgeable end to end.'"'"'\n'
    printf '}\n'
    # shellcheck disable=SC2016  # single-quoted on purpose: this line must
    # land LITERALLY in the generated $ARDI_FNKW_EVASION file, to be
    # expanded when THAT file is later sourced — not expanded now, against
    # this shell's own (unset) copy of the name.
    printf '_r3f2_evasion_producer_out=$(_r3f2_evasion_producer)\n'
    # shellcheck disable=SC2016  # same reason as immediately above.
    printf 'APPROVAL_RECORD_DETAIL="${APPROVAL_RECORD_DETAIL}${_r3f2_evasion_producer_out}"\n'
} > "$ARDI_FNKW_EVASION"
ARDI_FNKW_PARSE=0; bash -n "$ARDI_FNKW_EVASION" 2>/dev/null || ARDI_FNKW_PARSE=$?
assert_eq "4.V2.0 non-vacuity: the function-keyword evasion producer is still valid bash" "0" "$ARDI_FNKW_PARSE"
assert_eq "4.V2.1 non-vacuity: is_local_fn's OLD pattern would have missed this definition form (documents the R3-F2 gap; the mechanism itself is removed, not re-tested)" \
    "0" "$(grep -cE '^_r3f2_evasion_producer\(\) \{' "$ARDI_FNKW_EVASION" | tr -d '[:space:]')"

render_matrix_state_with_ardi() {
    local state_fn="$1" ardi_region="$2"
    (
        set -u
        # shellcheck disable=SC2329
        emit_block() { printf '%s' "$1"; }
        # shellcheck disable=SC2329
        tree_fingerprint() { printf 'FAKE-FIXED-FINGERPRINT-for-determinism'; }
        # shellcheck disable=SC2329
        sanitize_task_id() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
        # shellcheck disable=SC2329
        last_verified_state_file_for() {
            local tid="$1"
            [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-verified-state"; return; }
            printf '%s/last-verified-state.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
        }
        # shellcheck disable=SC1090
        . "$ABT"
        # shellcheck disable=SC1090
        . "$CSN_FN"
        # shellcheck disable=SC1090
        . "$OD"
        # shellcheck disable=SC1090
        . "$BVN_FN"
        # shellcheck disable=SC1090
        . "$VSU_FN"
        reset_matrix_baseline
        "$state_fn"
        # shellcheck disable=SC1090
        . "$ardi_region"
        # shellcheck disable=SC1090
        . "$ARDW"
        # shellcheck disable=SC1090
        . "$LWR"
    )
}

M1_EVADED_TEXT=$(render_matrix_state_with_ardi state_m1_baseline "$ARDI_FNKW_EVASION")
assert_eq "4.V2.2 THE VULNERABILITY: the function-keyword producer's output DOES reach the end-to-end render" \
    "yes" "$([ "$(contains_count "cryptographically unforgeable" "$M1_EVADED_TEXT" | tr -d '[:space:]')" -gt 0 ] && echo yes || echo no)"
assert_eq "4.V2.3 THE FIX: the M1 matrix pin catches it — rendered text no longer matches EXPECTED_M1_SHA256" \
    "yes" "$([ "$(sha256_of "$M1_EVADED_TEXT")" != "$EXPECTED_M1_SHA256" ] && echo yes || echo no)"
assert_eq "4.V2.4 RESTORE CONTROL: M1 re-rendered with the REAL region still matches its pin" \
    "$EXPECTED_M1_SHA256" "$(sha256_of "$(render_matrix_state state_m1_baseline)")"

# ===========================================================================
# CLASS GUARD (R5-F2, independent review round 5 — the generalisable half).
# A one-off fix for assert_absent would repeat this task's own defect
# family: a check that is INVOKED but CANNOT RUN, indistinguishable in the
# pass count from one that ran and passed. assert_absent was called at
# assertion 4.6b and never defined anywhere in this self-contained file —
# every run printed "assert_absent: command not found" to stderr, returned
# 127, and was counted by NOTHING (not PASS, not FAIL): the suite reported
# "149 passed, 0 failed" with 150 assertions written, through four
# independent-review rounds and two full four-tier acceptance runs, because
# a STABLE pass count proved the number stable, not that every named
# assertion had actually run. This guard makes that class of gap
# self-detecting IN THIS FILE, without building a fifth cross-file static
# analyser (four have already been defeated on this exact task — see the
# file header's four-shape history; this is deliberately NOT that shape,
# since it checks ONE file against ITSELF, never one file's claims against
# another file's source).
#
# THE CHECK: every assert_*-shaped name this file INVOKES (a bare word at
# the start of a statement, space-terminated — how every real call in this
# file is written) must resolve to a name this file DEFINES
# (`assert_something() {` at column 1). assert_absent, invoked with no
# definition anywhere, is exactly the shape this catches; so would a
# renamed helper, a typo in a call site, or a definition accidentally
# deleted alongside an unrelated edit.
# ===========================================================================
printf '\n--- CLASS GUARD: every assert_* helper invoked in this file is defined in this file ---\n'

# assert_names_defined/invoked <file> — the two halves of the comparison,
# factored into named functions so the META below runs the IDENTICAL logic
# against a mutated copy rather than a hand-copied re-implementation (a
# second copy of this logic drifting from the first is exactly the kind of
# gap this guard exists to close, in miniature).
assert_names_defined() {
    grep -oE '^assert_[A-Za-z_][A-Za-z0-9_]*\(\)' "$1" | sed 's/().*//' | sort -u
}
assert_names_invoked() {
    grep -oE '^[[:space:]]*assert_[A-Za-z_][A-Za-z0-9_]* ' "$1" | sed 's/^[[:space:]]*//; s/ $//' | sort -u
}
# missing_assert_names <file> — invoked names with no matching definition.
missing_assert_names() {
    local file="$1" defined invoked name missing=""
    defined=$(assert_names_defined "$file")
    invoked=$(assert_names_invoked "$file")
    for name in $invoked; do
        printf '%s\n' "$defined" | grep -qxF "$name" || missing="$missing $name"
    done
    printf '%s' "$missing" | sed 's/^ *//'
}

# $0 — this file's own invocation path, exactly as PROJECT_DIR (top of this
# file) already derives its value from `$(dirname "$0")`; reused here for
# the identical reason, not a new convention.
SELF_FILE="$0"
CLASS_GUARD_MISSING=$(missing_assert_names "$SELF_FILE")
assert_eq "CLASS GUARD: every assert_* helper invoked in this file resolves to a definition in this file" \
    "" "$CLASS_GUARD_MISSING"

# ---------------------------------------------------------------------------
# CLASS GUARD META — non-vacuity. Reproduces R5-F2's exact shape on a
# throwaway COPY (append an invocation of a helper that is never defined)
# and proves missing_assert_names catches it; restores control on the real
# file.
# ---------------------------------------------------------------------------
printf '\n--- CLASS GUARD META: an invoked-but-undefined helper must be caught ---\n'

SELF_FILE_MUT="$WORK/self-file-undefined-helper.sh"
cat "$SELF_FILE" > "$SELF_FILE_MUT"
printf 'assert_totally_undefined_r5f2_probe "meta-only, never defined" "x" "y"\n' >> "$SELF_FILE_MUT"
assert_eq "CLASS GUARD META non-vacuity: the mutant copy really differs from the real file" \
    "yes" "$([ "$(sha256_of_file "$SELF_FILE_MUT")" != "$(sha256_of_file "$SELF_FILE")" ] && echo yes || echo no)"
assert_eq "CLASS GUARD META SPECIFIC: the invoked-but-undefined helper IS caught, by name" \
    "assert_totally_undefined_r5f2_probe" "$(missing_assert_names "$SELF_FILE_MUT")"
assert_eq "CLASS GUARD META RESTORE CONTROL: the real file still reports nothing missing" \
    "" "$(missing_assert_names "$SELF_FILE")"

# ===========================================================================
printf '\n=== approval-record-disclosure-claim.test.sh: %d passed, %d failed ===\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed:\n'
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
exit 0
