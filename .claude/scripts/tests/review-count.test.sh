#!/bin/bash
# review-count.test.sh — L1 unit fixture for review-check.sh's `gate` predicate
# (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# Drives `review-check.sh gate <tid> --comments-json <file>` (the offline seam
# substituting `bd show --json` output) across the counting + independence
# predicate:
#   - findings below risk_threshold are ignored;
#   - a RESOLVED comment clears a finding ONLY with non-empty fix= AND test=;
#   - ARBITRATION sustain keeps a finding open, overrule clears it, latest wins;
#   - reviewer == an implementer role -> reviewer_not_independent;
#   - an empty implementer set -> vacuously independent;
#   - META (plan-mandated): removing an ARBITRATION overrule from a clean
#     comment-set flips the gate to unresolved_findings.
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
RCHECK="$PROJECT_DIR/.claude/scripts/review-check.sh"

if [ ! -f "$RCHECK" ]; then
    printf 'review-count.test: script under test missing: %s\n' "$RCHECK" >&2
    exit 2
fi
if ! command -v jq >/dev/null 2>&1; then
    printf 'review-count.test: jq is required\n' >&2
    exit 2
fi

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

WORK=$(mktemp -d -t review-count-test.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# mk_comments <text> [text...] -> JSON array of the comment texts on stdout.
mk_comments() {
    local arr='[]' c
    for c in "$@"; do
        arr=$(printf '%s' "$arr" | jq --arg c "$c" '. + [$c]')
    done
    printf '%s' "$arr"
}

# art_line <reviewer> <threshold> <findings-token> -> a REVIEW-ARTIFACT comment.
art_line() {
    printf 'REVIEW-ARTIFACT v1 iteration=1 reviewer=%s model=m reviewed_hash=h risk_threshold=%s verdict=findings stopped_by=verdict findings=[%s] at 2026-07-25T00:00:00Z: summary' \
        "$1" "$2" "$3"
}

GATE_OUT=""
GATE_EXIT=0
run_gate() {
    printf '%s' "$1" > "$WORK/comments.json"
    GATE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RCHECK" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
    GATE_EXIT=$?
}
ekey_of() { printf '%s' "$1" | jq -r '.error_key // ""' 2>/dev/null || echo ""; }
openct_of() { printf '%s' "$1" | jq -r '.open_findings // 0' 2>/dev/null || echo "0"; }

# 2ty helpers. art_hashed <iteration> <reviewed_hash> -> a clean, findings-free
# REVIEW-ARTIFACT record for a NAMED change-set hash (art_line above pins
# reviewed_hash=h, which the rounds legs have to vary).
art_hashed() {
    printf 'REVIEW-ARTIFACT v1 iteration=%s reviewer=qa-claude model=m reviewed_hash=%s risk_threshold=high verdict=approve stopped_by=verdict findings=[] at 2026-08-06T00:00:0%sZ: round %s\n' \
        "$1" "$2" "$1" "$1"
}
# run_gate_ref <comments-json> [extra args...] — run_gate with extra flags.
run_gate_ref() {
    local comments="$1"
    shift || true
    printf '%s' "$comments" > "$WORK/comments.json"
    GATE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RCHECK" gate t-1 \
        --comments-json "$WORK/comments.json" "$@" 2>/dev/null)
    GATE_EXIT=$?
}
rounds_of()     { printf '%s' "$1" | jq -r 'if has("rounds") then (.rounds|tostring) else "<absent>" end' 2>/dev/null || echo "<absent>"; }
roundshash_of() { printf '%s' "$1" | jq -r '.rounds_hash // ""' 2>/dev/null || echo ""; }

IMPL_BACKEND="IMPLEMENTER: role=backend implemented the feature"

# ---------------------------------------------------------------------------
echo "=== Section 1: threshold counting ==="

# Below threshold (low finding, high bar) -> ignored -> clean.
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high 'R1-F2:low')")"
assert_eq "below-threshold finding is ignored (exit 0)" "0" "$GATE_EXIT"
assert_eq "below-threshold: open_findings=0" "0" "$(openct_of "$GATE_OUT")"

# At/above threshold -> open.
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high 'R1-F1:critical')")"
assert_eq "at/above-threshold finding is open (exit 4)" "4" "$GATE_EXIT"
assert_eq "at/above-threshold: error_key" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "at/above-threshold: open id reported" "R1-F1" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.open_finding_ids[0]')"

# threshold=info counts everything (even info).
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex info 'R1-F5:info')")"
assert_eq "threshold=info counts an info finding (exit 4)" "4" "$GATE_EXIT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: RESOLVED requires non-empty fix= AND test= ==="

# RESOLVED lacking test= -> stays open.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "RESOLVED R1-F1 at 2026-07-25T01:00:00Z: fix=commit:abc — patched but no test cited")"
assert_eq "RESOLVED lacking test= stays open (exit 4)" "4" "$GATE_EXIT"
assert_eq "RESOLVED lacking test=: still unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"

# RESOLVED with fix= AND test= -> clears.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "RESOLVED R1-F1 at 2026-07-25T01:00:00Z: fix=commit:abc test=tests/x.sh — fixed with regression test")"
assert_eq "RESOLVED with fix+test clears the finding (exit 0)" "0" "$GATE_EXIT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: ARBITRATION sustain/overrule + latest-wins ==="

# sustain keeps the finding open.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "ARBITRATION R1-F1 decision=sustain at 2026-07-25T02:00:00Z: agreed, must fix")"
assert_eq "ARBITRATION sustain keeps finding open (exit 4)" "4" "$GATE_EXIT"

# overrule clears the finding.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "ARBITRATION R1-F1 decision=overrule at 2026-07-25T02:00:00Z: false positive")"
assert_eq "ARBITRATION overrule clears finding (exit 0)" "0" "$GATE_EXIT"

# latest-wins: overrule THEN sustain -> latest sustain -> open.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "ARBITRATION R1-F1 decision=overrule at 2026-07-25T02:00:00Z: initially dismissed" \
    "ARBITRATION R1-F1 decision=sustain at 2026-07-25T03:00:00Z: on reflection, real")"
assert_eq "ARBITRATION latest-wins (overrule then sustain -> open, exit 4)" "4" "$GATE_EXIT"

# latest-wins the other way: sustain THEN overrule -> latest overrule -> clear.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "ARBITRATION R1-F1 decision=sustain at 2026-07-25T02:00:00Z: looked real" \
    "ARBITRATION R1-F1 decision=overrule at 2026-07-25T03:00:00Z: confirmed false positive")"
assert_eq "ARBITRATION latest-wins (sustain then overrule -> clear, exit 0)" "0" "$GATE_EXIT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: independence ==="

# reviewer == an implementer role -> not independent.
run_gate "$(mk_comments "IMPLEMENTER: role=qa wrote the code" \
    "$(art_line qa high '')")"
assert_eq "reviewer==implementer -> exit 4" "4" "$GATE_EXIT"
assert_eq "reviewer==implementer -> error_key" "reviewer_not_independent" "$(ekey_of "$GATE_OUT")"
assert_eq "reviewer==implementer -> independent=false" "false" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

# empty implementer set -> vacuously independent (and no findings -> clean).
run_gate "$(mk_comments "$(art_line sol-codex high '')")"
assert_eq "empty implementer set -> vacuous independent (exit 0)" "0" "$GATE_EXIT"
assert_eq "empty implementer set -> independent=true" "true" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

# reviewer independent of a DIFFERENT implementer role -> passes independence.
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high '')")"
assert_eq "reviewer independent of a different role (exit 0)" "0" "$GATE_EXIT"

# missing artifact entirely -> review_artifact_missing.
run_gate "$(mk_comments "$IMPL_BACKEND")"
assert_eq "no REVIEW-ARTIFACT -> exit 4" "4" "$GATE_EXIT"
assert_eq "no REVIEW-ARTIFACT -> error_key" "review_artifact_missing" "$(ekey_of "$GATE_OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4b: malformed artifact lines are NOT zero-findings (vg8) ==="
# DEFECT CLASS (claude-workflow-plugin-vg8): an embedded newline in a record
# header scalar splits the ONE-LINE record comment, pushing findings=[...] onto
# line 2. The gate reads first lines only, so it saw a REVIEW-ARTIFACT with no
# findings token and reported open=0 — SUPPRESSING a real critical finding.
# Defense in depth (layer 2): a REVIEW-ARTIFACT line without a WELL-FORMED
# findings=[...] token is MALFORMED, never "zero findings".

# 4b.1 end-to-end suppression reproduction: the exact 2-line comment the
# newline-in-reviewed_hash artifact produced. The gate must NOT report clean.
SPLIT_COMMENT='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m reviewed_hash=h
EVIL-SECOND-LINE risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical] at 2026-07-25T00:00:00Z: x'
run_gate "$(mk_comments "$IMPL_BACKEND" "$SPLIT_COMMENT")"
assert_eq "4b.1 split record (findings pushed to line 2): exit 4, NOT a clean pass" "4" "$GATE_EXIT"
assert_eq "4b.1 split record: error_key=review_artifact_malformed" "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"
assert_eq "4b.1 split record: ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"

# 4b.2 a REVIEW-ARTIFACT line with NO findings= token at all -> malformed.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict at 2026-07-25T00:00:00Z: no token")"
assert_eq "4b.2 no findings= token: exit 4" "4" "$GATE_EXIT"
assert_eq "4b.2 no findings= token: error_key=review_artifact_malformed" "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"

# 4b.3 an UNCLOSED findings=[ token (what a newline inside a finding id yields)
# is also malformed — the token is present but not well-formed.
run_gate "$(mk_comments "$IMPL_BACKEND" \
    "REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical at 2026-07-25T00:00:00Z: x")"
assert_eq "4b.3 unclosed findings=[ token: exit 4" "4" "$GATE_EXIT"
assert_eq "4b.3 unclosed findings=[ token: error_key=review_artifact_malformed" "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"

# 4b.4 the legitimate empty-findings record (findings=[]) is NOT malformed.
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high '')")"
assert_eq "4b.4 legitimate findings=[] is well-formed (exit 0)" "0" "$GATE_EXIT"
assert_eq "4b.4 legitimate findings=[]: no error_key" "" "$(ekey_of "$GATE_OUT")"

# 4b.5 META (load-bearing): strip the malformed-line guard from a checker copy;
# the suppressed-findings record must then wrongly PASS as clean (open=0).
# That is exactly the vg8 defect, so a green META proves 4b.1 is sensitive to
# the guard rather than passing for some unrelated reason.
STRIPPED_GATE="$WORK/review-check-nomalformed.sh"
awk '
    /# MALFORMED-ARTIFACT-GUARD-START/ {skip=1; next}
    /# MALFORMED-ARTIFACT-GUARD-END/   {skip=0; next}
    skip!=1 {print}
' "$RCHECK" > "$STRIPPED_GATE"
chmod +x "$STRIPPED_GATE"
STRIP_G_LINES=$(wc -l < "$STRIPPED_GATE" | tr -d ' ')
REAL_G_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
assert_eq "4b.5 META: strip removed the malformed guard (fewer lines)" "1" \
    "$([ "$STRIP_G_LINES" -lt "$REAL_G_LINES" ] && echo 1 || echo 0)"
assert_eq "4b.5 META: stripped checker parses" "0" \
    "$(bash -n "$STRIPPED_GATE" 2>/dev/null && echo 0 || echo 1)"
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$SPLIT_COMMENT")" > "$WORK/comments.json"
META_G_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STRIPPED_GATE" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_G_EXIT=$?
assert_eq "4b.5 META: WITHOUT the guard the split record wrongly passes (exit 0) — the vg8 defect" \
    "0" "$META_G_EXIT"
assert_eq "4b.5 META: WITHOUT the guard the critical finding is suppressed (open=0)" \
    "0" "$(printf '%s' "$META_G_OUT" | jq -r '.open_findings')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: META — removing an ARBITRATION flips the count ==="
# A clean comment-set: one critical finding, cleared by an ARBITRATION
# overrule. Removing that overrule must flip the gate to unresolved_findings —
# proving the gate-count assertion is sensitive to the arbitration record.
GOOD=$(mk_comments "$IMPL_BACKEND" \
    "$(art_line sol-codex high 'R1-F1:critical')" \
    "ARBITRATION R1-F1 decision=overrule at 2026-07-25T02:00:00Z: confirmed false positive")
run_gate "$GOOD"
assert_eq "META baseline: with ARBITRATION overrule the gate is clean (exit 0)" "0" "$GATE_EXIT"

# Strip the ARBITRATION comment from the array.
STRIPPED=$(printf '%s' "$GOOD" | jq '[.[] | select(startswith("ARBITRATION ") | not)]')
run_gate "$STRIPPED"
assert_eq "META: removing the ARBITRATION flips the gate to exit 4" "4" "$GATE_EXIT"
assert_eq "META: removing the ARBITRATION -> unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "META: the once-overruled finding is now open" "R1-F1" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.open_finding_ids[0]')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: ROUNDS — review rounds against ONE change set (2ty) ==="
# The J21 escalation cap used to charge STOP-HOOK PASSES against a budget named
# for review rounds. `gate` now reports the rounds directly so the cap can
# escalate on max(iterations, rounds) instead of on how often the orchestrator
# polled. These legs pin the counting rules.

# 6.1 three rounds against ONE hash, named explicitly.
THREE_ON_H1=$(mk_comments "$IMPL_BACKEND" \
    "$(art_hashed 1 h1)" "$(art_hashed 2 h1)" "$(art_hashed 3 h1)")
run_gate_ref "$THREE_ON_H1" --change-set-hash h1
assert_eq "6.1 three artifacts on h1: rounds=3" "3" "$(rounds_of "$GATE_OUT")"
assert_eq "6.1 three artifacts on h1: rounds_hash echoes the reference" "h1" "$(roundshash_of "$GATE_OUT")"

# 6.2 a FOURTH round against a DIFFERENT hash RESETS the count. This is the
# property that makes rounds the right quantity for the cap: a new change set has
# needed no rounds yet, however many the previous one took.
FOUR_MIXED=$(mk_comments "$IMPL_BACKEND" \
    "$(art_hashed 1 h1)" "$(art_hashed 2 h1)" "$(art_hashed 3 h1)" "$(art_hashed 4 h2)")
run_gate_ref "$FOUR_MIXED" --change-set-hash h2
assert_eq "6.2 a fourth round against a NEW hash resets rounds to 1" "1" "$(rounds_of "$GATE_OUT")"
run_gate_ref "$FOUR_MIXED" --change-set-hash h1
assert_eq "6.2 ...while the old hash still reports its own 3" "3" "$(rounds_of "$GATE_OUT")"

# 6.3 with no --change-set-hash the reference is the LATEST artifact's own hash,
# so the count is self-consistent with the `artifact` block on the same envelope.
run_gate_ref "$FOUR_MIXED"
assert_eq "6.3 no flag: reference defaults to the latest artifact's hash" "h2" "$(roundshash_of "$GATE_OUT")"
assert_eq "6.3 no flag: rounds counted against that default" "1" "$(rounds_of "$GATE_OUT")"

# 6.4 THE PROSE-ONLY REGRESSION. Measured on claude-workflow-plugin-8zi: before
# any artifact existed, `bd show 8zi | grep -c REVIEW-ARTIFACT` returned 1, and
# the hit was a reviewer's own sentence "zero REVIEW-ARTIFACT firstlines". Agents
# quote record grammars in comments constantly, so an unanchored count reports
# rounds nobody ran — and rounds feed an escalation cap whose default outcome is
# a release. The count MUST measure 0 here.
PROSE_ONLY=$(mk_comments "$IMPL_BACKEND" \
    "QA round 1 note: this task has zero REVIEW-ARTIFACT firstlines so far; a REVIEW-ARTIFACT v1 record with reviewed_hash=h1 would be the first." \
    "Orchestrator: agreed, no REVIEW-ARTIFACT v1 reviewed_hash=h1 record exists yet.")
run_gate_ref "$PROSE_ONLY" --change-set-hash h1
assert_eq "6.4 prose-only mentions: rounds=0 (anchored on the firstline grammar)" \
    "0" "$(rounds_of "$GATE_OUT")"
assert_eq "6.4 prose-only mentions: still review_artifact_missing" \
    "review_artifact_missing" "$(ekey_of "$GATE_OUT")"
# The unanchored count these legs exist to rule out, measured on the same input:
# 2 matches for a task with zero rounds.
PROSE_RAW=$(printf '%s' "$PROSE_ONLY" | jq -r '.[]' | grep -c 'REVIEW-ARTIFACT v1 ' || true)
PROSE_RAW=$(printf '%s' "$PROSE_RAW" | tr -d '[:space:]')
assert_eq "6.4 CONTROL: an UNANCHORED count over the same comments would report 2" \
    "2" "$PROSE_RAW"

# 6.5 hash comparison is whole-token, not prefix: ref=h1 must not match h1beef.
run_gate_ref "$(mk_comments "$IMPL_BACKEND" "$(art_hashed 1 h1beef)")" --change-set-hash h1
assert_eq "6.5 a longer hash sharing the reference's prefix does NOT count" "0" "$(rounds_of "$GATE_OUT")"

# 6.6 rounds is present (as 0) on the artifact-missing envelope. That state — "a
# cycle is open and nobody has spoken yet" — is exactly the one the caller needs
# a number for, so the field cannot be conditional on an artifact existing.
run_gate_ref "$(mk_comments "$IMPL_BACKEND")" --change-set-hash h1
assert_eq "6.6 no artifact at all: rounds is present and 0, not absent" "0" "$(rounds_of "$GATE_OUT")"

# 6.7 an artifact with NO reviewed_hash token cannot be counted against any
# reference (it is unattributable, not a match for everything).
run_gate_ref "$(mk_comments "$IMPL_BACKEND" \
    "REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=m risk_threshold=high verdict=approve stopped_by=verdict findings=[] at 2026-08-06T00:00:00Z: no hash token")" \
    --change-set-hash h1
assert_eq "6.7 an artifact with no reviewed_hash token counts 0" "0" "$(rounds_of "$GATE_OUT")"

# 6.8 the UNESTABLISHED signal: a usage error answers on the terse envelope,
# which carries NO rounds key at all. Callers must read a missing key as
# "unestablished" and fall back to their own signal — never as zero rounds.
USAGE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RCHECK" gate t-1 \
    --comments-json "$WORK/comments.json" --change-set-hash 2>/dev/null)
USAGE_RC=$?
assert_eq "6.8 --change-set-hash with no value: usage error rc=1" "1" "$USAGE_RC"
assert_eq "6.8 usage error: error_key=usage" "usage" "$(ekey_of "$USAGE_OUT")"
assert_eq "6.8 usage error: the rounds key is ABSENT (unestablished, not zero)" \
    "<absent>" "$(rounds_of "$USAGE_OUT")"

# 6.9 META (load-bearing): UNANCHOR the rounds matcher in a checker copy and the
# prose-only leg must start counting the prose. This is the mutation the fix was
# explicitly told not to inherit, so it gets a mutant rather than a promise.
UNANCHORED_GATE="$WORK/review-check-unanchored.sh"
sed 's|/\^\[\[:space:\]\]\*REVIEW-ARTIFACT v1 /|/REVIEW-ARTIFACT v1 /|' "$RCHECK" > "$UNANCHORED_GATE"
chmod +x "$UNANCHORED_GATE"
if cmp -s "$RCHECK" "$UNANCHORED_GATE"; then
    assert_eq "6.9 META: the unanchor mutation APPLIED (mutant differs from source)" "differs" "identical"
else
    assert_eq "6.9 META: the unanchor mutation APPLIED (mutant differs from source)" "differs" "differs"
    assert_eq "6.9 META: mutated checker parses" "0" \
        "$(bash -n "$UNANCHORED_GATE" 2>/dev/null && echo 0 || echo 1)"
    printf '%s' "$PROSE_ONLY" > "$WORK/comments.json"
    META_UA_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$UNANCHORED_GATE" gate t-1 \
        --comments-json "$WORK/comments.json" --change-set-hash h1 2>/dev/null)
    assert_eq "6.9 META: WITHOUT the firstline anchor the prose mentions COUNT as rounds (the 8zi defect)" \
        "2" "$(rounds_of "$META_UA_OUT")"
    # Discriminator: the mutant still ran the real predicate (same verdict), so
    # the rounds difference is the anchor and nothing else.
    assert_eq "6.9 META: the mutant still reported review_artifact_missing (ran the real predicate)" \
        "review_artifact_missing" "$(ekey_of "$META_UA_OUT")"
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
