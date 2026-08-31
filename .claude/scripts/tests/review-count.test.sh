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
echo "=== Section 7: CYCLE-SURVIVAL — a round survives housekeeping-driven hash movement within one open cycle (0in1) ==="
# MEASURED on claude-workflow-plugin-fkm.3: reconcile_tracker (the Stop hook's
# OWN housekeeping, run on every fire) folded a previously-untracked but
# already-existing path into the tracker mid-review, moving change_set_hash
# with the reviewed CONTENT unchanged. Pure hash-equality then reported
# rounds=0 over a task carrying four open HIGH findings — the escalation
# machinery's "no reviewer has disagreed with anything" text is a direct,
# false consequence.
#
# The fix is a per-round EXCEPTION, not a blanket "count everything in the
# cycle": claude-workflow-plugin-2ty deliberately resets rounds when a change
# set moves because of GENUINE new work ("a new change set has needed no
# rounds yet"), and that must survive too (component spec
# escalation-basis.sh legs C/H pin it at the integration level). The
# exception requires ALL of: a cycle open (a `QA-GATE: entered` record),
# the round's own timestamp inside it, and no `IMPLEMENTER` record newer
# than the round — reconcile posts no bd comment of its own and is the only
# OTHER writer of the tracker, so "no implementer since" leaves reconcile as
# the only explanation for the hash's movement.

# art_hashed_ts <iteration> <reviewed_hash> <ts> — like art_hashed above, but
# with an EXPLICIT own record timestamp, needed here to control ordering
# against a QA-GATE: entered / IMPLEMENTER record precisely.
art_hashed_ts() {
    printf 'REVIEW-ARTIFACT v1 iteration=%s reviewer=qa-claude model=m reviewed_hash=%s risk_threshold=high verdict=approve stopped_by=verdict findings=[] at %s: round %s' \
        "$1" "$2" "$3" "$1"
}
gate_entered_at() { printf 'QA-GATE: entered at %s' "$1"; }
implementer_at()  { printf 'IMPLEMENTER: role=backend task=t-1 at %s' "$1"; }
roundsbasis_of()    { printf '%s' "$1" | jq -r '.rounds_basis // "?"' 2>/dev/null || echo "?"; }
roundsstale_of()    { printf '%s' "$1" | jq -r '.rounds_stale_hash_count // "?"' 2>/dev/null || echo "?"; }

# 7.1 THE BASELINE REPRODUCTION: a cycle is open, one round landed against h1,
# and NOTHING else happened — no implementer record at all — before the
# reference moves to h2. The round must SURVIVE (rounds=1), not reset to 0.
C71=$(mk_comments \
    "$(gate_entered_at 2026-08-06T00:00:00Z)" \
    "$(art_hashed_ts 1 h1 2026-08-06T00:01:00Z)")
run_gate_ref "$C71" --change-set-hash h2
assert_eq "7.1 reconcile-only movement: rounds SURVIVES (1, not reset to 0)" "1" "$(rounds_of "$GATE_OUT")"
assert_eq "7.1 ...rounds_basis=cycle (the exception was available and used)" "cycle" "$(roundsbasis_of "$GATE_OUT")"
assert_eq "7.1 ...rounds_stale_hash_count=1 (the surviving round is against a stale hash)" \
    "1" "$(roundsstale_of "$GATE_OUT")"

# 7.2 CONTROL: the identical comments, referenced against h1 (the round's OWN
# hash) rather than h2. Counted via plain equality this time — no round is
# "stale" against its own hash.
run_gate_ref "$C71" --change-set-hash h1
assert_eq "7.2 control: exact-hash reference still counts 1 via equality" "1" "$(rounds_of "$GATE_OUT")"
assert_eq "7.2 ...rounds_stale_hash_count=0 (nothing needed the exception)" "0" "$(roundsstale_of "$GATE_OUT")"

# 7.3 NO CYCLE ESTABLISHED (no QA-GATE: entered record at all — e.g. a
# --comments-json seam with no enter, as every OTHER section in this file
# uses): falls back to hash-equality ONLY, unchanged from pre-0in1 behaviour.
# This is what keeps section 6 above green without any changes.
C73=$(mk_comments "$(art_hashed_ts 1 h1 2026-08-06T00:01:00Z)")
run_gate_ref "$C73" --change-set-hash h2
assert_eq "7.3 no established cycle: rounds resets to 0 (today's behaviour, unchanged)" \
    "0" "$(rounds_of "$GATE_OUT")"
assert_eq "7.3 ...rounds_basis=hash_equality (the exception was never available)" \
    "hash_equality" "$(roundsbasis_of "$GATE_OUT")"

# 7.4 A ROUND FROM A PRIOR CYCLE must not carry forward into a fresh one: the
# round's own timestamp PRECEDES the (current) QA-GATE: entered record, so
# even though a cycle IS open now, this round is not IN it.
C74=$(mk_comments \
    "$(art_hashed_ts 1 h1 2026-08-06T00:00:00Z)" \
    "$(gate_entered_at 2026-08-06T02:00:00Z)")
run_gate_ref "$C74" --change-set-hash h2
assert_eq "7.4 a round predating the current cycle does NOT survive" "0" "$(rounds_of "$GATE_OUT")"
assert_eq "7.4 ...rounds_basis is still cycle (the cycle IS established; this round just isn't in it)" \
    "cycle" "$(roundsbasis_of "$GATE_OUT")"

# 7.5 2ty PRESERVED AT THE UNIT LEVEL: an IMPLEMENTER record NEWER than the
# round means genuine new work may have landed since — the round does NOT
# survive.
C75=$(mk_comments \
    "$(gate_entered_at 2026-08-06T00:00:00Z)" \
    "$(art_hashed_ts 1 h1 2026-08-06T00:01:00Z)" \
    "$(implementer_at 2026-08-06T00:02:00Z)")
run_gate_ref "$C75" --change-set-hash h2
assert_eq "7.5 an IMPLEMENTER record newer than the round EXCLUDES it (2ty preserved)" \
    "0" "$(rounds_of "$GATE_OUT")"

# 7.6 ...but an IMPLEMENTER record OLDER than the round (the specialist who
# made the ORIGINAL edit, before anyone reviewed it) does not exclude it.
C76=$(mk_comments \
    "$(gate_entered_at 2026-08-06T00:00:00Z)" \
    "$(implementer_at 2026-08-06T00:00:30Z)" \
    "$(art_hashed_ts 1 h1 2026-08-06T00:01:00Z)")
run_gate_ref "$C76" --change-set-hash h2
assert_eq "7.6 an IMPLEMENTER record OLDER than the round does not exclude it" \
    "1" "$(rounds_of "$GATE_OUT")"

# 7.7 An IMPLEMENTER record that matches the grammar prefix but carries no
# extractable timestamp reads as UNPARSEABLE, never as "newer than the round"
# — this counter must never fail TOWARD suppression on ambiguity, the same
# governing rule the anchor-width note above states for the firstline match.
C77=$(mk_comments \
    "$(gate_entered_at 2026-08-06T00:00:00Z)" \
    "IMPLEMENTER: role=backend implemented the feature, no timestamp token here" \
    "$(art_hashed_ts 1 h1 2026-08-06T00:01:00Z)")
run_gate_ref "$C77" --change-set-hash h2
assert_eq "7.7 an unparseable IMPLEMENTER record is treated as no-evidence, not as newer (round survives)" \
    "1" "$(rounds_of "$GATE_OUT")"

# 7.8 An UNPARSEABLE cycle marker (matches the QA-GATE: entered prefix but
# carries no extractable ISO timestamp) never manufactures the exception
# either: the positive claim needs evidence, and there is none here.
C78=$(mk_comments \
    "QA-GATE: entered at some-day-soon-ish, no real timestamp" \
    "$(art_hashed_ts 1 h1 2026-08-06T00:01:00Z)")
run_gate_ref "$C78" --change-set-hash h2
assert_eq "7.8 an unparseable cycle marker falls back to hash_equality (no exception)" \
    "0" "$(rounds_of "$GATE_OUT")"
assert_eq "7.8 ...rounds_basis=hash_equality" "hash_equality" "$(roundsbasis_of "$GATE_OUT")"

# 7.9 An artifact with NO reviewed_hash token cannot survive via the cycle
# exception either — mirrors 6.7's convention (unattributable is not a match
# for everything) rather than the anchor-width convention: the exception is a
# POSITIVE claim and an unattributed record cannot support one.
C79=$(mk_comments \
    "$(gate_entered_at 2026-08-06T00:00:00Z)" \
    "REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=m risk_threshold=high verdict=approve stopped_by=verdict findings=[] at 2026-08-06T00:01:00Z: no hash token")
run_gate_ref "$C79" --change-set-hash h2
assert_eq "7.9 no reviewed_hash token: still 0 even with a cycle established" "0" "$(rounds_of "$GATE_OUT")"

# ---------------------------------------------------------------------------
# 7.10 META (load-bearing): neutralise the cycle-survival rule in a checker
# copy — CYCLE_ESTABLISHED can never reach "1" — and re-run 7.1's EXACT input.
# It must report rounds=0, reproducing the 0in1 defect and proving 7.1 is
# sensitive to the added rule rather than passing for an unrelated reason.
NOCYCLE_GATE="$WORK/review-check-hash-only.sh"
sed 's/CYCLE_ESTABLISHED="1"/CYCLE_ESTABLISHED="0"/' "$RCHECK" > "$NOCYCLE_GATE"
chmod +x "$NOCYCLE_GATE"
NC_ORIG=$(grep -c 'CYCLE_ESTABLISHED="0"' "$RCHECK" || true)
NC_ORIG=$(printf '%s' "$NC_ORIG" | tr -d '[:space:]')
NC_MUT=$(grep -c 'CYCLE_ESTABLISHED="0"' "$NOCYCLE_GATE" || true)
NC_MUT=$(printf '%s' "$NC_MUT" | tr -d '[:space:]')
assert_eq "7.10 META: the substitution landed exactly once (mutant differs from source)" "1" "$((NC_MUT - NC_ORIG))"
assert_eq "7.10 META: mutated checker parses" "0" \
    "$(bash -n "$NOCYCLE_GATE" 2>/dev/null && echo 0 || echo 1)"
printf '%s' "$C71" > "$WORK/comments.json"
META_NC_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$NOCYCLE_GATE" gate t-1 \
    --comments-json "$WORK/comments.json" --change-set-hash h2 2>/dev/null)
assert_eq "7.10 META: WITHOUT the cycle-survival rule, 7.1's SAME input reports rounds=0 (the 0in1 defect)" \
    "0" "$(rounds_of "$META_NC_OUT")"
assert_eq "7.10 META: ...and rounds_basis reads hash_equality, not cycle" \
    "hash_equality" "$(roundsbasis_of "$META_NC_OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: cap_terminated — a review that stopped at a CAP is incomplete by construction (nq5f) ==="
# claude-workflow-plugin-nq5f: a review terminating at cap:max_review_iterations
# (or cap:max_findings / cap:timeout) ran out of TURNS or BUDGET, not out of
# things to find — its verdict is a FLOOR, not a ceiling, and a reader must be
# able to see that MECHANICALLY rather than by re-deriving the stopped_by enum
# split by hand every time (qa-claude did exactly that by hand during D1 and
# immediately found a sibling defect one screen away).

# art_line_stopped <reviewer> <threshold> <findings-token> <stopped_by> — like
# art_line, but stopped_by is a parameter instead of the hardcoded "verdict".
art_line_stopped() {
    printf 'REVIEW-ARTIFACT v1 iteration=1 reviewer=%s model=m reviewed_hash=h risk_threshold=%s verdict=findings stopped_by=%s findings=[%s] at 2026-07-25T00:00:00Z: summary' \
        "$1" "$2" "$4" "$3"
}
# NOTE: NOT `.artifact.cap_terminated // "?"` — jq's `//` falls through on a
# LITERAL `false`, not only on absence, which would silently misreport every
# non-cap-terminated case here as "?" (measured: it did, on the first run of
# this section). `has()` is the correct idiom, matching rounds_of above.
capterm_of() { printf '%s' "$1" | jq -r '.artifact | if has("cap_terminated") then (.cap_terminated|tostring) else "?" end' 2>/dev/null || echo "?"; }

# 8.1 the two NON-cap conclusions: complete, cap_terminated=false.
run_gate "$(mk_comments "$(art_line_stopped sol-codex high '' verdict)")"
assert_eq "8.1 stopped_by=verdict: cap_terminated=false" "false" "$(capterm_of "$GATE_OUT")"
run_gate "$(mk_comments "$(art_line_stopped sol-codex high '' stop_condition)")"
assert_eq "8.1 stopped_by=stop_condition: cap_terminated=false" "false" "$(capterm_of "$GATE_OUT")"

# 8.2 all three CAP conclusions: incomplete, cap_terminated=true.
run_gate "$(mk_comments "$(art_line_stopped sol-codex high '' cap:max_findings)")"
assert_eq "8.2 stopped_by=cap:max_findings: cap_terminated=true" "true" "$(capterm_of "$GATE_OUT")"
run_gate "$(mk_comments "$(art_line_stopped sol-codex high '' cap:max_review_iterations)")"
assert_eq "8.2 stopped_by=cap:max_review_iterations: cap_terminated=true" "true" "$(capterm_of "$GATE_OUT")"
run_gate "$(mk_comments "$(art_line_stopped sol-codex high '' cap:timeout)")"
assert_eq "8.2 stopped_by=cap:timeout: cap_terminated=true" "true" "$(capterm_of "$GATE_OUT")"

# 8.3 cap_terminated is reported even when the cap-terminated review is
# otherwise CLEAN (verdict=findings but findings=[] here is a stand-in for
# "nothing found before the budget ran out" — exactly the shape that must not
# be read as "reviewed and clean"). The gate's OPEN-FINDINGS verdict (exit 0
# here, since there is nothing to resolve) is UNCHANGED by this fix — nq5f
# exposes the signal for a caller to consult, it does not itself add a new
# hard refusal to the open-findings gate.
CAPCLEAN_COMMENTS=$(mk_comments "$(art_line_stopped sol-codex high '' cap:max_review_iterations)")
run_gate "$CAPCLEAN_COMMENTS"
assert_eq "8.3 a cap-terminated, zero-findings review still passes the OPEN-FINDINGS gate (exit 0; unchanged scope)" \
    "0" "$GATE_EXIT"
assert_eq "8.3 ...but cap_terminated=true is still reported, so a caller can refuse to treat it as sufficient" \
    "true" "$(capterm_of "$GATE_OUT")"

# ---------------------------------------------------------------------------
# 8.4 META (load-bearing): break the cap:* classification in a checker copy —
# treat NOTHING as cap-terminated — and the SAME cap:max_review_iterations
# input must then report cap_terminated=false, proving 8.2 is sensitive to the
# classification rather than passing for an unrelated reason.
NOCAPCLASS_GATE="$WORK/review-check-nocapclass.sh"
sed 's/cap:\*) ART_CAP_TERMINATED="true" ;;/no-such-prefix-*) ART_CAP_TERMINATED="true" ;;/' \
    "$RCHECK" > "$NOCAPCLASS_GATE"
chmod +x "$NOCAPCLASS_GATE"
if cmp -s "$RCHECK" "$NOCAPCLASS_GATE"; then
    assert_eq "8.4 META: the substitution applied (mutant differs from source)" "differs" "identical"
else
    assert_eq "8.4 META: the substitution applied (mutant differs from source)" "differs" "differs"
    assert_eq "8.4 META: mutated checker parses" "0" \
        "$(bash -n "$NOCAPCLASS_GATE" 2>/dev/null && echo 0 || echo 1)"
    printf '%s' "$(mk_comments "$(art_line_stopped sol-codex high '' cap:max_review_iterations)")" > "$WORK/comments.json"
    META_NCC_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$NOCAPCLASS_GATE" gate t-1 \
        --comments-json "$WORK/comments.json" 2>/dev/null)
    assert_eq "8.4 META: WITHOUT the classification a cap-terminated review reports cap_terminated=false (the nq5f gap)" \
        "false" "$(capterm_of "$META_NCC_OUT")"
    # Discriminator: the mutant still reports the real stopped_by value, so the
    # cap_terminated difference is the classification and nothing else.
    assert_eq "8.4 META: the mutant still reports the real stopped_by (ran the real predicate)" \
        "cap:max_review_iterations" "$(printf '%s' "$META_NCC_OUT" | jq -r '.artifact.stopped_by // "?"')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: i8cx wave 2 — a failed read of the implementer/cycle record set must never look independent or safe ==="
# review-check.sh:1417 (the audit's fourth must-fix): the old body piped
# `grep -oE ... "$firstlines" | sed ... | sort -u`, closed with a blanket
# `|| true`. sort is always last and succeeds trivially on the empty stdin a
# failed grep leaves behind, so a genuine grep READ FAILURE on $firstlines
# (permission, ENOENT, a vanished mktemp dir) was byte-identical to grep
# cleanly finding ZERO IMPLEMENTER records — and `[ -n "$impl_lines" ] && ...`
# short-circuits on either, so INDEPENDENT kept its "true" default. A failed
# read made a non-independent reviewer look independent.
#
# max_record_ts (feeding cycle_opened_ts / latest_implementer_ts, :1079-ish)
# has the identical shape one function up, with a further-reaching consumer:
# verify-before-stop.sh's F1 fast path reads latest_implementer_ts off this
# envelope and treats an EMPTY value as "no implementer in flight, safe to
# auto-approve a doc-only change set" — so a masked read failure there could
# have fed a RELEASE decision in a different script entirely.
#
# Neither fix needs pipefail: grep is the first stage of its pipe in both
# cases, captured on its own statement before sed/sort ever run.

REAL_GREP=$(command -v grep)
SHIM_IMPLREAD="$WORK/shim-implread"
SHIM_IMPLTS="$WORK/shim-implts"
mkdir -p "$SHIM_IMPLREAD" "$SHIM_IMPLTS"

# Fails ONLY the exact impl_lines extraction review-check.sh:1417 makes
# (grep -oE '^IMPLEMENTER: role=[a-z]+' <firstlines>, no trailing space) —
# every OTHER grep call cmd_gate makes (art extraction, both max_record_ts
# calls, RESOLVED/ARBITRATION lookups) stays on the real binary. Matches this
# tree's established shim-scoping convention (qa-gate-pipefail.test.sh's
# shim-sortu, "fail ONLY <x>"; argv match via `[ "$a" = ... ]`, never a glob
# `case`, because the pattern text itself contains glob metacharacters
# (`[a-z]`) that a case arm would reinterpret rather than match literally).
# rc 2: what this platform's grep reports for "could not read the file"
# (measured; rc 1 is grep's own clean no-match and must never trip this).
cat > "$SHIM_IMPLREAD/grep" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = '^IMPLEMENTER: role=[a-z]+' ]; then
        exit 2
    fi
done
exec ${REAL_GREP} "\$@"
SHIMEOF
chmod +x "$SHIM_IMPLREAD/grep"

# Fails ONLY the LATEST_IMPLEMENTER_TS read inside max_record_ts (note the
# TRAILING SPACE — distinct from the impl_lines pattern above, so this shim
# cannot accidentally also intercept :1417's own extraction and conflate the
# two fixes' evidence).
cat > "$SHIM_IMPLTS/grep" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = '^IMPLEMENTER: role=[a-z]+ ' ]; then
        exit 2
    fi
done
exec ${REAL_GREP} "\$@"
SHIMEOF
chmod +x "$SHIM_IMPLTS/grep"

# run_gate_shim <dir> <comments-json> — run_gate with a shim dir prepended to
# PATH for exactly this one invocation (env-prefixed, never leaked to later
# sections/assertions).
run_gate_shim() {
    local shimdir="$1" comments="$2"
    printf '%s' "$comments" > "$WORK/i8cx-comments.json"
    GATE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$shimdir:$PATH" \
        bash "$RCHECK" gate t-1 --comments-json "$WORK/i8cx-comments.json" 2>/dev/null)
    GATE_EXIT=$?
}

# 9.1 THE POSITIVE LEG, shipped script: backend both implemented AND is named
# as the reviewer — if the read had worked, this is section 4's exact
# self-review shape (reviewer==implementer -> reviewer_not_independent). With
# the read shimmed to fail, the OLD code silently defaulted to
# independent=true (reproduced by the 9.4 mutant below); the FIXED code must
# refuse instead, and refuse for the HONEST reason (the set could not be
# read), not by asserting a fact — "reviewer IS an implementer" — the failed
# read never actually established.
SELF_REVIEW_COMMENTS=$(mk_comments "IMPLEMENTER: role=backend implemented the feature" "$(art_line backend high '')")
run_gate_shim "$SHIM_IMPLREAD" "$SELF_REVIEW_COMMENTS"
assert_eq "9.1 shimmed read failure on a self-review shape: exit 4 (never a silent pass)" "4" "$GATE_EXIT"
assert_eq "9.1b ...ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"
assert_eq "9.1c ...error_key names the read failure, not a false independence claim" \
    "implementer_set_unreadable" "$(ekey_of "$GATE_OUT")"

# 9.2 RESTORE CONTROL: identical self-review comments, shim removed (real
# grep) — the REAL detection still fires, matching section 4's coverage
# (repeated here so this section is self-contained and does not depend on
# section 4 having run first).
run_gate "$SELF_REVIEW_COMMENTS"
assert_eq "9.2 restore control (no shim): self-review still exit 4" "4" "$GATE_EXIT"
assert_eq "9.2b ...error_key=reviewer_not_independent (the real, established violation)" \
    "reviewer_not_independent" "$(ekey_of "$GATE_OUT")"
assert_eq "9.2c ...independent=false (the real predicate, not the read-failure refusal)" \
    "false" "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

# 9.3 NEGATIVE CONTROL: a genuinely doc-only task (no IMPLEMENTER records at
# all), shim removed — must NOT be refused. This is the exact case the i8cx
# audit named: "doc-only work is orchestrator-authored and legitimately has
# none; refusing that would deadlock every documentation commit."
DOC_ONLY_COMMENTS=$(mk_comments "$(art_line qa-claude high '')")
run_gate "$DOC_ONLY_COMMENTS"
assert_eq "9.3 doc-only task (genuinely no IMPLEMENTER records), unshimmed: exit 0" "0" "$GATE_EXIT"
assert_eq "9.3b ...independent=true (vacuously, correctly)" "true" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

# 9.3c A SECOND negative-shaped control, but SHIMMED: the shim fires on the
# ARGUMENT (the grep pattern), not on the file's content, so it also
# intercepts this genuinely-empty case. It must STILL refuse — proving the
# fix's guard is keyed on "did the read succeed", not "does the content look
# like a self-review", which is what makes 9.1 trustworthy rather than a
# fixture-specific coincidence.
run_gate_shim "$SHIM_IMPLREAD" "$DOC_ONLY_COMMENTS"
assert_eq "9.3c doc-only task, shimmed: STILL refuses (the guard is read-outcome-keyed, not content-keyed)" \
    "4" "$GATE_EXIT"
assert_eq "9.3d ...same error_key as 9.1" "implementer_set_unreadable" "$(ekey_of "$GATE_OUT")"

# 9.4 META (load-bearing): revert review-check.sh:1417's fix on a checker
# copy — splice the exact pre-fix one-liner back into the sentinel-bounded
# region — and re-run 9.1's SAME shimmed scenario against it. The mutant must
# reproduce the ORIGINAL defect: a silent independent=true pass.
MUTANT_1417="$WORK/review-check-preimpl1417.sh"
{
    sed -n '1,/# IMPLEMENTER-SET-READ-GUARD BEGIN/p' "$RCHECK"
    cat <<'OLDCODE'
    local impl_lines
    impl_lines=$(grep -oE '^IMPLEMENTER: role=[a-z]+' "$firstlines" | sed -E 's/^IMPLEMENTER: role=//' | sort -u || true)
OLDCODE
    sed -n '/# IMPLEMENTER-SET-READ-GUARD END/,$p' "$RCHECK"
} > "$MUTANT_1417"
chmod +x "$MUTANT_1417"
assert_eq "9.4 META: the mutant differs from the shipped script (non-vacuous splice)" "differs" \
    "$(cmp -s "$RCHECK" "$MUTANT_1417" && echo identical || echo differs)"
assert_eq "9.4b META: the mutant parses" "0" \
    "$(bash -n "$MUTANT_1417" 2>/dev/null && echo 0 || echo 1)"

printf '%s' "$SELF_REVIEW_COMMENTS" > "$WORK/i8cx-comments.json"
META_1417_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$SHIM_IMPLREAD:$PATH" \
    bash "$MUTANT_1417" gate t-1 --comments-json "$WORK/i8cx-comments.json" 2>/dev/null)
META_1417_RC=$?
assert_eq "9.4c META: WITHOUT the read guard, the shimmed self-review WRONGLY passes (exit 0) — the i8cx:1417 defect" \
    "0" "$META_1417_RC"
assert_eq "9.4d META: ...ok=true" "true" "$(printf '%s' "$META_1417_OUT" | jq -r '.ok')"
assert_eq "9.4e META: ...independent=true (the silent pass)" "true" \
    "$(printf '%s' "$META_1417_OUT" | jq -r '.independent')"

# 9.4f Discriminator: the mutant still correctly detects the UNSHIMMED
# self-review — proving the splice only affects read-failure handling, not
# the underlying independence comparison itself.
META_1417_UNSHIMMED=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_1417" gate t-1 \
    --comments-json "$WORK/i8cx-comments.json" 2>/dev/null)
assert_eq "9.4f discriminator: the mutant, UNSHIMMED, still catches the real self-review (ran the real predicate)" \
    "reviewer_not_independent" "$(ekey_of "$META_1417_UNSHIMMED")"

# 9.5 max_record_ts (the LATEST_IMPLEMENTER_TS half): a real implementer
# record + an independent reviewer + clean findings — the gate itself PASSES
# either way (exit 0); what a shimmed read failure must change is the
# latest_implementer_ts FIELD, from "" (the old, dangerous-downstream shape)
# to "unparseable" (what verify-before-stop.sh's F1 fast path already reads
# as "unestablished, fail closed" — see review-check.sh's own comment on
# max_record_ts for the full chain).
IMPLTS_COMMENTS=$(mk_comments \
    "IMPLEMENTER: role=backend task=t-1 at 2026-07-25T00:00:00Z" \
    "$(art_line qa-claude high '')")
run_gate "$IMPLTS_COMMENTS"
assert_eq "9.5 baseline (unshimmed): gate passes" "0" "$GATE_EXIT"
assert_eq "9.5b ...latest_implementer_ts is the real timestamp" "2026-07-25T00:00:00Z" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.latest_implementer_ts')"

run_gate_shim "$SHIM_IMPLTS" "$IMPLTS_COMMENTS"
assert_eq "9.5c shimmed: the gate itself still passes (this fix does not change cmd_gate's own verdict)" \
    "0" "$GATE_EXIT"
assert_eq "9.5d ...but latest_implementer_ts is now 'unparseable', never the dangerous ''" \
    "unparseable" "$(printf '%s' "$GATE_OUT" | jq -r '.latest_implementer_ts')"

# 9.6 META: revert max_record_ts's fix the same way, and show the identical
# shimmed input reports the OLD, dangerous empty string instead.
MUTANT_MAXTS="$WORK/review-check-premaxts.sh"
{
    sed -n '1,/# MAX-RECORD-TS-READ-GUARD BEGIN/p' "$RCHECK"
    cat <<'OLDCODE2'
    lines=$(grep -E "$prefix" "$file" 2>/dev/null) || lines=""
    if [ -z "$lines" ]; then
        printf ''
        return 0
    fi
OLDCODE2
    sed -n '/# MAX-RECORD-TS-READ-GUARD END/,$p' "$RCHECK"
} > "$MUTANT_MAXTS"
chmod +x "$MUTANT_MAXTS"
assert_eq "9.6 META: the mutant differs from the shipped script" "differs" \
    "$(cmp -s "$RCHECK" "$MUTANT_MAXTS" && echo identical || echo differs)"
assert_eq "9.6b META: the mutant parses" "0" \
    "$(bash -n "$MUTANT_MAXTS" 2>/dev/null && echo 0 || echo 1)"

printf '%s' "$IMPLTS_COMMENTS" > "$WORK/i8cx-comments.json"
META_MAXTS_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$SHIM_IMPLTS:$PATH" \
    bash "$MUTANT_MAXTS" gate t-1 --comments-json "$WORK/i8cx-comments.json" 2>/dev/null)
assert_eq "9.6c META: WITHOUT the read guard, the shimmed read reports the empty string — the i8cx defect (an F1 'safe' verdict downstream)" \
    "" "$(printf '%s' "$META_MAXTS_OUT" | jq -r '.latest_implementer_ts')"

META_MAXTS_UNSHIMMED=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_MAXTS" gate t-1 \
    --comments-json "$WORK/i8cx-comments.json" 2>/dev/null)
assert_eq "9.6d discriminator: the mutant, UNSHIMMED, still reports the real timestamp (ran the real predicate)" \
    "2026-07-25T00:00:00Z" "$(printf '%s' "$META_MAXTS_UNSHIMMED" | jq -r '.latest_implementer_ts')"

# 9.7 THE ADJACENT GAP (reported alongside :1417, judged reachable): nothing
# between the artifact-missing check and the independence check required
# reviewer= to actually be present on the record. A hand-written or corrupted
# `bd comments add` (never validated by validate-artifact, which DOES make
# reviewer_identity mandatory for the proper writer) could carry a
# REVIEW-ARTIFACT line with a well-formed findings=[] token but no reviewer=
# token at all — REVIEWER="" then never equals any IMPLEMENTER role
# (`grep -qxF` requires a whole-line match; no role is ever the empty
# string), so it always read as "independent".
NOREVIEWER_COMMENTS=$(mk_comments "$IMPL_BACKEND" \
    "REVIEW-ARTIFACT v1 iteration=1 model=m reviewed_hash=h risk_threshold=high verdict=approve stopped_by=verdict findings=[] at 2026-07-25T01:00:00Z: no reviewer token")
run_gate "$NOREVIEWER_COMMENTS"
assert_eq "9.7 a REVIEW-ARTIFACT with no reviewer= token: exit 4 (never a silent pass)" "4" "$GATE_EXIT"
assert_eq "9.7b ...error_key=reviewer_identity_missing" "reviewer_identity_missing" "$(ekey_of "$GATE_OUT")"

# 9.8 META: strip the REVIEWER-NONEMPTY-GUARD from a checker copy and re-run
# 9.7's SAME input — the mutant must wrongly pass.
MUTANT_REVIEWER="$WORK/review-check-noreviewerguard.sh"
STRIP_9_8_RC=0
awk '
    /# REVIEWER-NONEMPTY-GUARD BEGIN/ { skip=1; found=1; next }
    /# REVIEWER-NONEMPTY-GUARD END/   { skip=0; next }
    skip { next }
    { print }
    END { if (!found) exit 7 }
' "$RCHECK" > "$MUTANT_REVIEWER" || STRIP_9_8_RC=$?
chmod +x "$MUTANT_REVIEWER"
assert_eq "9.8 META: the REVIEWER-NONEMPTY-GUARD sentinels are present (non-vacuous strip)" "0" "$STRIP_9_8_RC"
assert_eq "9.8b META: the stripped copy parses" "0" \
    "$(bash -n "$MUTANT_REVIEWER" 2>/dev/null && echo 0 || echo 1)"

printf '%s' "$NOREVIEWER_COMMENTS" > "$WORK/i8cx-comments.json"
META_REVIEWER_RC=0
META_REVIEWER_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_REVIEWER" gate t-1 \
    --comments-json "$WORK/i8cx-comments.json" 2>/dev/null) || META_REVIEWER_RC=$?
assert_eq "9.8c META: WITHOUT the guard, the no-reviewer record WRONGLY passes (exit 0) — the adjacent gap" \
    "0" "$META_REVIEWER_RC"
assert_eq "9.8d META: ...ok=true" "true" "$(printf '%s' "$META_REVIEWER_OUT" | jq -r '.ok')"
assert_eq "9.8e META: ...independent=true (the silent pass over an unnamed reviewer)" "true" \
    "$(printf '%s' "$META_REVIEWER_OUT" | jq -r '.independent')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 10: i8cx R2-F1 (Sol review round 2) — a failed TRANSFORM (sed/sort) of the implementer role list must not read as an empty, vacuously-independent set ==="
# review-check.sh's IMPLEMENTER-SET-TRANSFORM-GUARD. Sibling gap to Section 9
# above, found IN wave 2's own fix by the round-2 independent review: the read
# guard stops a failed GREP from being read as "zero implementer records", but
# the very next statement piped that clean grep output through
# `sed | sort -u` and threw the pipe's own exit status away. sort is always
# the LAST stage, and (without pipefail) a pipeline's "$?" is only the last
# stage's — so a sed failure was invisible whenever the sort after it still
# exited 0 on the empty/partial stdin the failed sed left behind, and a sort
# failure exits nonzero but that "$?" was never even looked at. Either way,
# `[ -n "$impl_lines" ] && ...` short-circuits on the resulting impl_lines="",
# so INDEPENDENT keeps its "true" default: a reviewer who IS an implementer
# reads as vacuously independent — Section 9's exact defect, reopened one
# statement later.
#
# Neither shim needs pipefail to expose: in the fixed code, sed and sort each
# run as the LAST stage of their own two-command pipeline (printf | sed, then
# printf | sort -u), and printf cannot fail — so each command's own "$?" is
# already the pipeline's "$?", pipefail or not.

REAL_SED=$(command -v sed)
REAL_SORT=$(command -v sort)
SHIM_SORTXFORM="$WORK/shim-sortxform"
SHIM_SEDXFORM="$WORK/shim-sedxform"
mkdir -p "$SHIM_SORTXFORM" "$SHIM_SEDXFORM"

# Fails ONLY `sort -u` (the exact call review-check.sh's transform guard
# makes), empty stdout, rc 2. rc 2 is not a measured platform value the way
# grep's rc>1 is in Section 9 — sort has no "clean nonzero" case in this call
# shape (an empty or single-line stdin still sorts with rc 0), so the guard
# checks bare nonzero and the specific value here is not load-bearing; it
# only has to be nonzero to simulate a genuine failure (OOM, full temp disk,
# killed by a signal). Argv match via `[ "$a" = ... ]`, matching this tree's
# established shim-scoping convention.
cat > "$SHIM_SORTXFORM/sort" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = '-u' ]; then
        exit 2
    fi
done
exec ${REAL_SORT} "\$@"
SHIMEOF
chmod +x "$SHIM_SORTXFORM/sort"

# Fails ONLY the exact substitution review-check.sh's transform guard makes
# (`sed -E 's/^IMPLEMENTER: role=//'`) — every OTHER sed call in the script
# (line ~808's `1d;$d`, line ~1156's `s/^ at //`, line ~1446's findings
# extraction) stays on the real binary. Same "nonzero is not load-bearing"
# reasoning as the sort shim above: `s///` does not fail merely for finding
# nothing to substitute, only for an actual failure to run.
cat > "$SHIM_SEDXFORM/sed" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    if [ "\$a" = 's/^IMPLEMENTER: role=//' ]; then
        exit 2
    fi
done
exec ${REAL_SED} "\$@"
SHIMEOF
chmod +x "$SHIM_SEDXFORM/sed"

# Fresh, section-local fixtures (Section 9's own convention: self-contained,
# does not reach into an earlier section's variables) built from the shared
# IMPL_BACKEND/art_line helpers defined at the top of this file.
R2F1_SELF_REVIEW=$(mk_comments "$IMPL_BACKEND" "$(art_line backend high '')")
R2F1_DOC_ONLY=$(mk_comments "$(art_line qa-claude high '')")
R2F1_INDEP=$(mk_comments "$IMPL_BACKEND" "$(art_line qa-claude high '')")

# 10.1 THE POSITIVE LEG, shipped script, SORT shimmed: a self-review shape
# (backend both implemented and reviews) whose read succeeds (impl_rc=0) but
# whose sort -u transform fails empty. The old body would have collapsed this
# to impl_lines="" and passed; the fixed code must refuse, honestly, for the
# transform failure — not by asserting the reviewer IS an implementer, which
# the failed transform never established.
run_gate_shim "$SHIM_SORTXFORM" "$R2F1_SELF_REVIEW"
assert_eq "10.1 sort-shimmed transform failure on a self-review shape: exit 4 (never a silent pass)" "4" "$GATE_EXIT"
assert_eq "10.1b ...ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"
assert_eq "10.1c ...error_key names the transform failure, not a false independence claim" \
    "implementer_set_unreadable" "$(ekey_of "$GATE_OUT")"

# 10.2 THE POSITIVE LEG, shipped script, SED shimmed: identical shape, the
# OTHER fallible stage of the same pipeline.
run_gate_shim "$SHIM_SEDXFORM" "$R2F1_SELF_REVIEW"
assert_eq "10.2 sed-shimmed transform failure on a self-review shape: exit 4 (never a silent pass)" "4" "$GATE_EXIT"
assert_eq "10.2b ...ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"
assert_eq "10.2c ...error_key names the transform failure, not a false independence claim" \
    "implementer_set_unreadable" "$(ekey_of "$GATE_OUT")"

# 10.3 RESTORE CONTROL: identical self-review comments, no shim — the real
# detection still fires.
run_gate "$R2F1_SELF_REVIEW"
assert_eq "10.3 restore control (no shim): self-review still exit 4" "4" "$GATE_EXIT"
assert_eq "10.3b ...error_key=reviewer_not_independent (the real, established violation)" \
    "reviewer_not_independent" "$(ekey_of "$GATE_OUT")"

# 10.4/10.5/10.6 ANTI-OVERREACH: a genuinely doc-only task (no IMPLEMENTER
# records at all, grep rc 1) never reaches the transform block — guarded by
# `if [ "$impl_rc" -eq 0 ]`. Must pass unshimmed AND with either transform
# shim active: the shim fires on the ARGUMENT, not on whether it is ever
# invoked, so this proves the new guard is unreachable on doc-only work
# rather than merely untriggered by these particular fixtures.
run_gate "$R2F1_DOC_ONLY"
assert_eq "10.4 doc-only task, unshimmed: exit 0" "0" "$GATE_EXIT"
assert_eq "10.4b ...independent=true (vacuously, correctly)" "true" "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

run_gate_shim "$SHIM_SORTXFORM" "$R2F1_DOC_ONLY"
assert_eq "10.5 doc-only task, sort-shimmed: STILL exit 0 (transform block never reached)" "0" "$GATE_EXIT"
assert_eq "10.5b ...independent=true" "true" "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

run_gate_shim "$SHIM_SEDXFORM" "$R2F1_DOC_ONLY"
assert_eq "10.6 doc-only task, sed-shimmed: STILL exit 0 (transform block never reached)" "0" "$GATE_EXIT"
assert_eq "10.6b ...independent=true" "true" "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"

# 10.7 ANTI-OVERREACH: a genuinely independent reviewer, unshimmed — the
# transform runs for real (impl_rc=0, backend implemented), succeeds
# normally, and the independence comparison behaves exactly as before this
# fix. Proves the new guard does not misfire on ordinary, healthy operation.
run_gate "$R2F1_INDEP"
assert_eq "10.7 genuinely independent reviewer, unshimmed: exit 0" "0" "$GATE_EXIT"
assert_eq "10.7b ...independent=true" "true" "$(printf '%s' "$GATE_OUT" | jq -r '.independent')"
assert_eq "10.7c ...implementers correctly resolved (not masked)" '["backend"]' \
    "$(printf '%s' "$GATE_OUT" | jq -c '.implementers')"

# 10.8 META (load-bearing): revert review-check.sh's TRANSFORM-GUARD fix on a
# checker copy — splice the exact pre-fix one-liner back into the
# sentinel-bounded region — and re-run 10.1/10.2's shimmed scenarios against
# it. The mutant must reproduce the ORIGINAL R2-F1 defect: a silent
# independent=true pass.
MUTANT_R2F1="$WORK/review-check-pre-r2f1.sh"
{
    sed -n '1,/# IMPLEMENTER-SET-TRANSFORM-GUARD BEGIN/p' "$RCHECK"
    cat <<'OLDCODE_R2F1'
    if [ "$impl_rc" -eq 0 ]; then
        impl_lines=$(printf '%s\n' "$impl_raw" | sed -E 's/^IMPLEMENTER: role=//' | sort -u)
    fi
OLDCODE_R2F1
    sed -n '/# IMPLEMENTER-SET-TRANSFORM-GUARD END/,$p' "$RCHECK"
} > "$MUTANT_R2F1"
chmod +x "$MUTANT_R2F1"
assert_eq "10.8 META: the mutant differs from the shipped script (non-vacuous splice)" "differs" \
    "$(cmp -s "$RCHECK" "$MUTANT_R2F1" && echo identical || echo differs)"
assert_eq "10.8b META: the mutant parses" "0" \
    "$(bash -n "$MUTANT_R2F1" 2>/dev/null && echo 0 || echo 1)"

printf '%s' "$R2F1_SELF_REVIEW" > "$WORK/i8cx-r2f1-comments.json"
META_R2F1_SORT_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$SHIM_SORTXFORM:$PATH" \
    bash "$MUTANT_R2F1" gate t-1 --comments-json "$WORK/i8cx-r2f1-comments.json" 2>/dev/null)
META_R2F1_SORT_RC=$?
assert_eq "10.9 META: WITHOUT the transform guard, sort-shimmed self-review WRONGLY passes (exit 0) — the R2-F1 defect" \
    "0" "$META_R2F1_SORT_RC"
assert_eq "10.9b META: ...ok=true" "true" "$(printf '%s' "$META_R2F1_SORT_OUT" | jq -r '.ok')"
assert_eq "10.9c META: ...independent=true (the silent pass)" "true" \
    "$(printf '%s' "$META_R2F1_SORT_OUT" | jq -r '.independent')"

# 10.10 META, the OTHER shimmed stage against the SAME mutant.
META_R2F1_SED_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$SHIM_SEDXFORM:$PATH" \
    bash "$MUTANT_R2F1" gate t-1 --comments-json "$WORK/i8cx-r2f1-comments.json" 2>/dev/null)
META_R2F1_SED_RC=$?
assert_eq "10.10 META: WITHOUT the transform guard, sed-shimmed self-review WRONGLY passes (exit 0) — the R2-F1 defect" \
    "0" "$META_R2F1_SED_RC"
assert_eq "10.10b META: ...ok=true" "true" "$(printf '%s' "$META_R2F1_SED_OUT" | jq -r '.ok')"
assert_eq "10.10c META: ...independent=true (the silent pass)" "true" \
    "$(printf '%s' "$META_R2F1_SED_OUT" | jq -r '.independent')"

# 10.11 Discriminator: the mutant still correctly detects the UNSHIMMED
# self-review — proving the splice only affects transform-failure handling,
# not the underlying independence comparison itself.
META_R2F1_UNSHIMMED=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_R2F1" gate t-1 \
    --comments-json "$WORK/i8cx-r2f1-comments.json" 2>/dev/null)
assert_eq "10.11 discriminator: the mutant, UNSHIMMED, still catches the real self-review (ran the real predicate)" \
    "reviewer_not_independent" "$(ekey_of "$META_R2F1_UNSHIMMED")"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
