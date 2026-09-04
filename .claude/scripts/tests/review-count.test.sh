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

# 4b.5-4b.7 META (load-bearing): TWO independent layers now guard this exact
# shape — the pre-existing MALFORMED-ARTIFACT-GUARD (checks the FINAL
# selected $art) and the k6re selector's own ART-SELECT-FINDINGS-GUARD
# (checks every CANDIDATE up front, so it also catches a malformed record
# that never wins selection at all — see that guard's own comment in
# review-check.sh). Stripping either ALONE must not reproduce the vg8
# defect (the other layer catches it); stripping BOTH together must.
# Testing each combination separately is what makes "load-bearing" a
# provable claim about BOTH layers rather than an assumption about one.
#
# FIXTURE CHOICE: the 4b.1 SPLIT_COMMENT is NOT reusable here — its
# corruption also eats the record's `at <ts>` token (pushed to line 2 along
# with findings=[...]), so this selector's OWN, separate TS_UNPARSEABLE
# check would catch it regardless of whether either findings-guard is
# present, making a "did the OLD guard specifically catch this" test
# meaningless. 4b.3's UNCLOSED bracket corrupts findings=[...] ALONE —
# iteration= and `at <ts>` both remain well-formed on the one line — so it
# is the fixture that actually isolates which guard is doing the work.
strip_region() {
    # strip_region <start-sentinel-literal> <end-sentinel-literal> <in-file>
    awk -v startpat="$1" -v endpat="$2" '
        index($0, startpat) { skip=1; next }
        index($0, endpat)   { skip=0; next }
        skip!=1 {print}
    ' "$3"
}
MALFORMED_START='# MALFORMED-ARTIFACT-GUARD-START'
MALFORMED_END='# MALFORMED-ARTIFACT-GUARD-END'
FINDINGS_START='# ART-SELECT-FINDINGS-GUARD BEGIN'
FINDINGS_END='# ART-SELECT-FINDINGS-GUARD END'
UNCLOSED_FINDINGS='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical at 2026-07-25T00:00:00Z: x'

printf '%s' "$(mk_comments "$IMPL_BACKEND" "$UNCLOSED_FINDINGS")" > "$WORK/comments.json"

# 4b.5 Strip ONLY the OLD (downstream) guard. The NEW (upfront, selector-
# level) guard is untouched and must still catch it.
STRIP_OLD_ONLY="$WORK/review-check-nomalformed-old.sh"
strip_region "$MALFORMED_START" "$MALFORMED_END" "$RCHECK" > "$STRIP_OLD_ONLY"
chmod +x "$STRIP_OLD_ONLY"
assert_eq "4b.5a META: stripping the OLD guard alone changes the file" "differs" \
    "$(cmp -s "$RCHECK" "$STRIP_OLD_ONLY" && echo identical || echo differs)"
assert_eq "4b.5b META: stripped-old copy parses" "0" \
    "$(bash -n "$STRIP_OLD_ONLY" 2>/dev/null && echo 0 || echo 1)"
META_OLD_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STRIP_OLD_ONLY" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_OLD_RC=$?
assert_eq "4b.5c META: WITHOUT the OLD guard alone, the NEW guard still refuses (exit 4) — genuine defense in depth" \
    "4" "$META_OLD_RC"
assert_eq "4b.5d META: ...error_key=review_artifact_malformed (via the new guard)" \
    "review_artifact_malformed" "$(ekey_of "$META_OLD_OUT")"

# 4b.6 Strip ONLY the NEW (upfront) guard. The OLD (downstream) guard is
# untouched and must still catch it.
STRIP_NEW_ONLY="$WORK/review-check-nomalformed-new.sh"
strip_region "$FINDINGS_START" "$FINDINGS_END" "$RCHECK" > "$STRIP_NEW_ONLY"
chmod +x "$STRIP_NEW_ONLY"
assert_eq "4b.6a META: stripping the NEW guard alone changes the file" "differs" \
    "$(cmp -s "$RCHECK" "$STRIP_NEW_ONLY" && echo identical || echo differs)"
assert_eq "4b.6b META: stripped-new copy parses" "0" \
    "$(bash -n "$STRIP_NEW_ONLY" 2>/dev/null && echo 0 || echo 1)"
META_NEW_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STRIP_NEW_ONLY" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_NEW_RC=$?
# claude-workflow-plugin-k6re R3-F1 changed what 4b.6c/d and 4b.7 below can
# prove. The pre-R3-F1 selector ran THREE genuinely independent, unanchored
# checks (a bare findings=[...] substring test, a bare iteration= scan, a
# bare `at <ts>` scan) — stripping the findings check removed ALL findings
# awareness from the selector, so ONLY the downstream MALFORMED-ARTIFACT-
# GUARD stood between UNCLOSED_FINDINGS and a silent pass. R3-F1's fix makes
# every stage a STRICT SUPERSET of the one before it (art_ts_ok's own
# pattern re-requires the SAME tightened findings=[...] shape art_findings_ok
# checks, because that is what "anchored" means: you cannot validate a
# timestamp positioned after findings=[...] without the findings token
# itself being well-formed first). One consequence, measured directly:
# stripping ONLY the dedicated ART-SELECT-FINDINGS-GUARD region no longer
# lets a malformed-findings record escape the selector at all — art_ts_ok(),
# untouched and unsentineled because it is not a separable "guard" but the
# anchor itself, still refuses it, just under badts instead of badfindings.
# 4b.6 below is updated to assert that (still a real, meaningful safety
# property: the selector is robust even with ONE of its two overlapping
# findings-aware checks removed) rather than a stale error_key. 4b.7 (strip
# BOTH regions) can no longer reproduce the vg8 defect at all under this
# design — see its updated comment below, and the NEW "revert the anchor"
# META in section 4c, which is what proves the CURRENT fix is load-bearing.
assert_eq "4b.6c META: WITHOUT the dedicated findings guard alone, the selector STILL refuses (exit 4) — art_ts_ok's own anchored pattern independently re-requires the same tightened findings shape, so this is a SECOND overlapping check, not merely a fallback to a downstream guard" \
    "4" "$META_NEW_RC"
assert_eq "4b.6d META: ...error_key=review_artifact_timestamp_unparseable (via art_ts_ok, still inside the selector — the record never reaches \$art, so the downstream MALFORMED-ARTIFACT-GUARD is never even consulted here)" \
    "review_artifact_timestamp_unparseable" "$(ekey_of "$META_NEW_OUT")"

# 4b.7 Strip BOTH sentineled regions. Under the PRE-R3-F1 design this was
# where the vg8 defect reproduced (exit 0, open_findings=0) — see git
# history for that version of this test. Under the R3-F1 anchored design it
# no longer can: art_ts_ok()'s own pattern text (defined once, shared with
# art_findings_ok() via $ART_SOFT, and NOT wrapped in either stripped
# sentinel region because it is the anchor itself rather than a removable
# layer on top of it) still requires the same tightened, whitespace-free
# findings=[...] shape UNCLOSED_FINDINGS violates. This is a STRONGER
# property than the two-layer model the old test asserted, not a weaker
# one — proving it needs a DIFFERENT mechanism than sentinel-stripping two
# named regions, because there is no longer a pair of regions whose joint
# removal deletes all findings-awareness from the selector. That mechanism
# is the "revert the anchor" META in section 4c immediately below: reverting
# art_findings_ok()/art_ts_ok() themselves (not merely two call sites) to
# their pre-R3-F1 unanchored shape is what makes the suppression return, and
# that is the test that earns the word "load-bearing" for this fix. This
# leg keeps 4b.7a/b intact (something real was still removed) and replaces
# 4b.7c/d with the CURRENT, correct expectation.
STRIP_BOTH="$WORK/review-check-nomalformed-both.sh"
strip_region "$MALFORMED_START" "$MALFORMED_END" "$RCHECK" \
    | strip_region "$FINDINGS_START" "$FINDINGS_END" /dev/stdin > "$STRIP_BOTH"
chmod +x "$STRIP_BOTH"
STRIP_BOTH_LINES=$(wc -l < "$STRIP_BOTH" | tr -d ' ')
REAL_G_LINES=$(wc -l < "$RCHECK" | tr -d ' ')
assert_eq "4b.7a META: stripping BOTH sentineled regions removed lines from each" "1" \
    "$([ "$STRIP_BOTH_LINES" -lt "$REAL_G_LINES" ] && echo 1 || echo 0)"
assert_eq "4b.7b META: stripped-both copy parses" "0" \
    "$(bash -n "$STRIP_BOTH" 2>/dev/null && echo 0 || echo 1)"
META_BOTH_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$STRIP_BOTH" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_BOTH_EXIT=$?
assert_eq "4b.7c META (R3-F1 UPDATE): even WITHOUT both sentineled regions, the unclosed-bracket record is STILL refused (exit 4) — art_ts_ok's own embedded pattern, defined outside both stripped regions, is the third and now non-removable protection; see section 4c's anchor-revert META for the test that actually reproduces vg8 under this design" \
    "4" "$META_BOTH_EXIT"
assert_eq "4b.7d META (R3-F1 UPDATE): ...error_key=review_artifact_timestamp_unparseable (same mechanism as 4b.6d)" \
    "review_artifact_timestamp_unparseable" "$(ekey_of "$META_BOTH_OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4c: R3-F1 (Sol/Codex k6re round 3) — the anchored, end-to-end parse ==="
# Sol's round-3 finding on claude-workflow-plugin-k6re: the pre-existing
# findings=[...] guard was a bare substring test matched ANYWHERE on the
# line, while the extraction beside it was GREEDY and preferred the LAST
# such occurrence. Two reproductions (see docs/reviews/claude-workflow-
# plugin-k6re-r3.json and review-check.sh's ART-PARSE-SHARED comment for
# the full finding): a malformed record whose bracket swallows real, later
# tokens (4c.1 below), and — worse, needing NO malformation at all — a
# perfectly well-formed record whose free-text SUMMARY merely mentions the
# token (4c.2, the leg that matters most per the task brief).

# 4c.1 THE MALFORMED SMUGGLING CASE FROM THE REVIEW. Sol's exact reproduction:
# the first findings=[ never closes, swallowing a real artifact_hash=/at <ts>
# pair as bracket "content" while presenting a second, well-formed-looking
# findings=[] at the very end. Pre-R3-F1 this passed the substring guard,
# greedy sed found the trailing empty token, and the HIGH finding vanished
# (exit 0, open_findings=0). Post-fix it must refuse outright.
SOL_R3F1_MALFORMED='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R3-F1:high artifact_hash=ah at 2026-08-30T10:00:00Z: summary findings=[]'
run_gate "$(mk_comments "$IMPL_BACKEND" "$SOL_R3F1_MALFORMED")"
assert_eq "4c.1a Sol's malformed-bracket reproduction: exit 4, NOT the old silent exit 0" "4" "$GATE_EXIT"
assert_eq "4c.1b ...error_key=review_artifact_malformed (never unresolved_findings=0 masquerading as clean)" \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"
assert_eq "4c.1c ...ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"

# 4c.2 THE REPRODUCTION AS CONTROL — the leg that matters most. A perfectly
# WELL-FORMED record (findings=[...] closes correctly, artifact_hash= and
# at <ts>: both present and well-formed) whose free-text summary merely
# CONTAINS the literal substring "findings=[]". No malformed input anywhere.
# Pre-R3-F1: greedy sed preferred the summary's trailing "findings=[]" over
# the real "findings=[R3-F1:high]" earlier on the line -- ART_FINDINGS read
# back "", the gate reported open_findings=0, exit 0 -- a real open HIGH
# silently suppressed by an ordinary review summary that happened to quote
# this very defect. Post-fix: the anchored $ART_PREFIX excludes the summary
# entirely, so the quoted text is structurally unreachable.
WELLFORMED_PROSE_MENTIONS_FINDINGS='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R3-F1:high] artifact_hash=ah at 2026-08-30T10:00:00Z: fixed the bug where findings=[] was mis-parsed'
run_gate "$(mk_comments "$IMPL_BACKEND" "$WELLFORMED_PROSE_MENTIONS_FINDINGS")"
assert_eq "4c.2a THE REPRODUCTION: exit 4 (the open HIGH is reported, not silently zeroed)" "4" "$GATE_EXIT"
assert_eq "4c.2b ...error_key=unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "4c.2c ...open_findings=1" "1" "$(openct_of "$GATE_OUT")"
assert_eq "4c.2d ...open_finding_ids names R3-F1, the real finding" \
    '["R3-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"
assert_eq "4c.2e ...artifact.findings_token reads back the REAL token, not the summary's fake one" \
    "R3-F1:high" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

# 4c.3 ONE LEG PER TOKEN. A single well-formed record where EVERY machine
# token has a REAL value, and the free-text summary independently mentions
# a DIFFERENT, FAKE value for every one of them in valid key=value shape.
# Each token's parsed value must be the REAL one; the summary is never
# consulted for any of them. iteration=7 also serves double duty as the
# integer-shape control (a non-throwaway value distinct from every other
# fixture's typical 1).
TOKEN_LEG_RECORD='REVIEW-ARTIFACT v1 iteration=7 reviewer=sol-codex model=gpt-5.6-sol pin=gpt-5.6-sol reviewed_hash=aaaa1111 risk_threshold=high verdict=findings stopped_by=verdict findings=[R9-F1:high] artifact_hash=realhash123 at 2026-08-30T10:00:00Z: note: earlier drafts used iteration=99 reviewer=someone-else model=fake-model pin=fake-pin reviewed_hash=bbbb2222 risk_threshold=low verdict=approve stopped_by=cap:timeout findings=[R9-F9:critical] artifact_hash=fakehash999 -- none of that applies to this round'
run_gate "$(mk_comments "$IMPL_BACKEND" "$TOKEN_LEG_RECORD")"
assert_eq "4c.3-iteration: real value 7, not the summary's fake 99" \
    "7" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.iteration')"
assert_eq "4c.3-reviewer: real identity sol-codex, not the summary's fake someone-else" \
    "sol-codex" "$(printf '%s' "$GATE_OUT" | jq -r '.reviewer_identity')"
assert_eq "4c.3-model: real gpt-5.6-sol, not the summary's fake fake-model" \
    "gpt-5.6-sol" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.model')"
assert_eq "4c.3-pin: real gpt-5.6-sol, not the summary's fake fake-pin" \
    "gpt-5.6-sol" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewer_pin')"
assert_eq "4c.3-reviewed_hash: real aaaa1111, not the summary's fake bbbb2222" \
    "aaaa1111" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewed_hash')"
assert_eq "4c.3-risk_threshold: real high, not the summary's fake low" \
    "high" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.risk_threshold')"
assert_eq "4c.3-verdict: real findings, not the summary's fake approve" \
    "findings" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.verdict')"
assert_eq "4c.3-stopped_by: real verdict, not the summary's fake cap:timeout" \
    "verdict" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.stopped_by')"
assert_eq "4c.3-stopped_by: cap_terminated=false follows the REAL stopped_by, not the summary's fake cap:timeout" \
    "false" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.cap_terminated')"
assert_eq "4c.3-findings: real R9-F1:high, not the summary's fake R9-F9:critical" \
    "R9-F1:high" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"
assert_eq "4c.3-artifact_hash: real realhash123, not the summary's fake fakehash999" \
    "realhash123" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.artifact_hash')"
assert_eq "4c.3-findings: open_finding_ids names the REAL id R9-F1, never the fake R9-F9" \
    '["R9-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"

# 4c.4 at <ts> — the one token with no direct single-value field on the
# envelope. Tested via the SELECTION mechanism instead: two candidates tied
# on iteration=1, an EARLY real timestamp whose own summary mentions a LATER
# fake one, and a genuinely LATER real timestamp with an ordinary summary.
# If timestamp extraction were confused by the fake mention, the early
# record would misread as carrying the max timestamp and WOULDN'T lose the
# tie -- its own (findings-bearing) verdict would govern instead of the
# later record's clean approve.
TS_EARLY_FAKE_LATE='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical] artifact_hash=ah at 2026-01-01T00:00:00Z: scheduling note, revisit at 2099-12-31T23:59:59Z: reminder'
TS_LATE_REAL='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=approve stopped_by=verdict findings=[] artifact_hash=ah at 2026-06-01T00:00:00Z: approve — no findings at/above high'
run_gate "$(mk_comments "$IMPL_BACKEND" "$TS_EARLY_FAKE_LATE" "$TS_LATE_REAL")"
assert_eq "4c.4a at-ts: the genuinely later record (2026-06-01) wins the tie, not the one whose summary mentions a later-looking fake timestamp: exit 0" \
    "0" "$GATE_EXIT"
assert_eq "4c.4b ...artifact.verdict=approve (TS_LATE_REAL, not TS_EARLY_FAKE_LATE's stale findings)" \
    "approve" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.verdict')"

# 4c.5 ANTI-OVERREACH. Ordinary records with ordinary summaries -- no
# adversarial content anywhere -- must parse EXACTLY as before. This is not
# a new property (the whole rest of this file's 250+ assertions already
# cover it), but names it explicitly as the R3-F1 anti-overreach control.
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high 'R1-F1:critical')")"
assert_eq "4c.5a anti-overreach: an ordinary well-formed record still reports its real open finding (exit 4)" \
    "4" "$GATE_EXIT"
assert_eq "4c.5b ...open_finding_ids=[R1-F1]" '["R1-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high '')")"
assert_eq "4c.5c anti-overreach: an ordinary empty-findings record is still clean (exit 0)" "0" "$GATE_EXIT"

# 4c.6 META: REVERT THE EXTRACTION SOURCE FROM $ART_PREFIX TO THE RAW LINE.
# UPDATED for claude-workflow-plugin-k6re R7-F1 (independent review round
# 7) -- read this update before assuming the assertions below still say
# what the original 4c.6 said, because they no longer do.
#
# ORIGINALLY, this META proved that scoping ART_FINDINGS's extraction to
# $ART_PREFIX instead of the raw winning line $art was what closed
# reproduction 2 (4c.2 above): the pre-R7-F1 extractor was an UNANCHORED,
# greedy sed scan (`.*findings=\[([^]]*)\].*`), so the only thing stopping
# it from matching a summary-embedded "findings=[]" mention was never
# handing it the summary to begin with.
#
# R7-F1 replaced that extractor with one anchored at
# ^REVIEW-ARTIFACT v1 iteration=... end to end (art_findings_open_len /
# art_bracket_end_len, review-check.sh ART-FINDINGS-EXTRACT): it locates
# the bracket by POSITION under a grammar anchored at the start of the
# line, not by scanning for a pattern that could match anywhere in its
# input, and neither function's own regex has a trailing `$` anchor, so
# nothing AFTER the bracket it matches -- summary text included -- is ever
# consulted, regardless of how much of the line is handed to it.
#
# MEASURED DIRECTLY (this file's own standing discipline: verify, do not
# assume -- the same discipline the ORIGINAL false "at most one
# occurrence" claim R7-F1 was filed against skipped): feeding the anchored
# extractor $art (the full raw line, summary and all) instead of
# $ART_PREFIX on the 4c.2 fixture still extracts the correct token. The
# scoping to $ART_PREFIX is RETAINED in the shipped script regardless --
# consistency with every other extractor on this page, and defense in
# depth against a future rewrite of these two functions that reintroduces
# scanning -- but it is no longer the SOLE reason reproduction 2 stays
# closed, and asserting otherwise here would be exactly the category of
# stale, untested claim R7-F1 exists to stop. Section 13.6 below is the
# CURRENT equivalent proof for the R7-F1 attack specifically: restoring
# the OLD unanchored extractor verbatim (with the tightened content class
# kept) still refuses, because the tightened SELECTOR now catches the
# crafted record before any extractor runs at all.
REVERT_ANCHOR="$WORK/review-check-revert-r3f1-anchor.sh"
# Sentinel is the line immediately preceding the extractor's own herestring
# feed (unique to this block; ART-PREFIX-PARTITION above has its own,
# separate <<<"$ART_PREFIX" feed this must not touch) rather than a line
# number, for the same drift-resistance reason strip_region/swap_region
# above use sentinels rather than positions.
awk '
    /else \{ print "FAIL" \}/ { armed=1 }
    armed && /<<<"\$ART_PREFIX" 2>\/dev\/null\)/ {
        sub(/<<<"\$ART_PREFIX"/, "<<<\"$art\"")
        armed=0
    }
    { print }
' "$RCHECK" > "$REVERT_ANCHOR"
chmod +x "$REVERT_ANCHOR"
assert_eq "4c.6a META: the source-swap mutation applied (mutant differs from source)" "differs" \
    "$(cmp -s "$RCHECK" "$REVERT_ANCHOR" && echo identical || echo differs)"
assert_eq "4c.6b META: mutated checker parses" "0" \
    "$(bash -n "$REVERT_ANCHOR" 2>/dev/null && echo 0 || echo 1)"
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$WELLFORMED_PROSE_MENTIONS_FINDINGS")" > "$WORK/comments.json"
META_REVERT_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVERT_ANCHOR" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_REVERT_EXIT=$?
assert_eq "4c.6c META (post-R7-F1, measured): the anchored extractor correctly parses the SAME well-formed 4c.2 fixture even fed the raw line -- exit 4, NOT the pre-R7-F1 mutant's silent exit 0" \
    "4" "$META_REVERT_EXIT"
assert_eq "4c.6d META: ...open_findings=1 (the real finding is found, never silently dropped to 0)" \
    "1" "$(openct_of "$META_REVERT_OUT")"
assert_eq "4c.6e META: ...artifact.findings_token reads back the REAL token R3-F1:high -- the anchor alone, independent of ART_PREFIX-scoping, is what protects this fixture now" \
    "R3-F1:high" "$(printf '%s' "$META_REVERT_OUT" | jq -r '.artifact.findings_token')"
# Discriminator: the mutant still runs the real predicate elsewhere (an
# ordinary record with no adversarial summary is unaffected by this one
# substitution), so the (non-)difference above is this substitution and
# nothing else.
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high 'R1-F1:critical')")" > "$WORK/comments.json"
META_REVERT_DISCRIM=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVERT_ANCHOR" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_REVERT_DISCRIM_EXIT=$?
assert_eq "4c.6f discriminator: the mutant still catches an UNRELATED ordinary open finding (exit 4) -- ran the real predicate" \
    "4" "$META_REVERT_DISCRIM_EXIT"
assert_eq "4c.6g discriminator: ...error_key=unresolved_findings" \
    "unresolved_findings" "$(ekey_of "$META_REVERT_DISCRIM")"

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
echo "=== Section 11: k6re TIER-0 K3 — REVIEW-ARTIFACT selection is by (iteration, timestamp) AGREEMENT, never by comment position ==="
# MEASURED defect: review-check.sh:1511 selected the governing REVIEW-ARTIFACT
# record with `grep ... | tail -1` — "latest" meant LAST IN COMMENT ORDER,
# never highest iteration. The same three comments, reordered, flipped the
# gate between ok:false/open_findings:2 and ok:true/open_findings:0.
#
# A FIRST DRAFT of this fix selected by max(iteration) alone, tie-broken by
# timestamp. Measured against the LIVE store (not assumed), that draft is
# falsified by claude-workflow-plugin-fkm.1.1's real review history: reviewer
# sol-codex posted ONE record at iteration=2; reviewer qa-claude then posted
# FIVE MORE records — against three different reviewed_hash values, spanning
# nearly a day, ending in a genuine verdict=approve — every one still carrying
# iteration=1 (a stagnant counter, not a per-cycle reset: two of the five
# share one reviewed_hash and BOTH say 1). Max(iteration) alone would have
# picked the single stale sol-codex record over five newer, superseding ones.
# Pure timestamp alone fails symmetrically: qa-gate.sh review-record stamps
# `at <ts>` at RECORD-WRITE time, so a backfill of an old round through that
# path is chronologically latest by construction however old the review it
# describes.
#
# THE SHIPPED RULE: a record governs only if it is the SAME record under
# BOTH orderings — highest iteration AND (independently, across the whole
# candidate set) latest timestamp. Disagreement between the two refuses,
# naming both candidates, rather than silently trusting either axis alone.
# This matters NOW because claude-workflow-plugin-k6re must backfill
# historical review records (e.g. r2..r9 alongside an already-recorded r10):
# a HISTORICALLY-FAITHFUL backfill (real review-time timestamps, not
# write-time) resolves automatically under this rule; a naive one that
# stamps "now" does not — and refuses loud rather than silently governing,
# which is the property this fix exists to guarantee either way.
iter_of()    { printf '%s' "$1" | jq -r '.artifact.iteration // "?"' 2>/dev/null || echo "?"; }
artverd_of() { printf '%s' "$1" | jq -r '.artifact.verdict // "?"' 2>/dev/null || echo "?"; }
# NOT `.ok // "?"`: jq's `//` treats a literal JSON `false` as absent too
# (the same gotcha qa-gate.sh's REVIEW-CAP-TERMINATED-REFUSAL comment names
# for cap_terminated), which would silently read a genuine ok=false as "?".
ok_of()      { printf '%s' "$1" | jq -r '.ok' 2>/dev/null || echo "?"; }

# art_iter <iteration> <verdict> <findings-token> <ts> -> a REVIEW-ARTIFACT
# comment with independent control over every field this section's legs vary
# (the art_line/art_hashed/art_hashed_ts helpers above each fix at least one
# of these, which is why this section defines its own).
art_iter() {
    printf 'REVIEW-ARTIFACT v1 iteration=%s reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=%s stopped_by=verdict findings=[%s] artifact_hash=ah at %s: summary' \
        "$1" "$2" "$3" "$4"
}

# 11.1 THE REPRODUCTION, AS THE CONTROL. Round 10 (findings, 2 open at/above
# high) is the true latest; round 2 (approve, backfilled LATER in comment
# order but carrying its OWN true, EARLIER historical timestamp — the
# historically-faithful backfill this fix's rule requires, see the section
# header) must never govern just because it is last in the array. Both
# comment orders below carry the IDENTICAL three comments — only the
# position of the two REVIEW-ARTIFACT records differs; both agree on
# iteration order (10 > 2) AND timestamp order (round 10's own review-time
# is later than round 2's), so this fix resolves them with no ambiguity.
REC_R10=$(art_iter 10 findings 'R10-F1:high,R10-F2:critical' 2026-08-30T10:00:00Z)
REC_R2=$(art_iter 2 approve '' 2026-08-20T09:00:00Z)
CHRONO_ORDER=$(mk_comments "$IMPL_BACKEND" "$REC_R2" "$REC_R10")
BACKFILL_LAST_ORDER=$(mk_comments "$IMPL_BACKEND" "$REC_R10" "$REC_R2")

run_gate "$CHRONO_ORDER"
assert_eq "11.1a chronological order (r2 then r10): exit 4 (r10 governs)" "4" "$GATE_EXIT"
assert_eq "11.1b chronological order: open_findings=2" "2" "$(openct_of "$GATE_OUT")"
assert_eq "11.1c chronological order: error_key=unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "11.1d chronological order: artifact.iteration=10 (not 2)" "10" "$(iter_of "$GATE_OUT")"

run_gate "$BACKFILL_LAST_ORDER"
assert_eq "11.1e backfill-last order (r10 then r2): SAME exit 4 (r10 STILL governs)" "4" "$GATE_EXIT"
assert_eq "11.1f backfill-last order: SAME open_findings=2" "2" "$(openct_of "$GATE_OUT")"
assert_eq "11.1g backfill-last order: SAME error_key=unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "11.1h backfill-last order: artifact.iteration=10 (not 2) regardless of position" "10" "$(iter_of "$GATE_OUT")"

# 11.2 ANTI-VACUITY. A leg that passes because nothing was read is the family
# of defect this whole arc is about (.claude/tests/README.md's pairing
# requirement). Prove the fixture genuinely carries TWO distinct iteration
# values (not a fixture that accidentally only has one, which any selector
# — buggy or fixed — would trivially get "right"), and that the gate's own
# JSON was genuinely parsed rather than some vacuous default: artifact.verdict
# must read back as "findings" (round 10's real verdict), not "approve"
# (round 2's), and not the empty/"?" sentinel a failed jq read would produce.
DISTINCT_ITERS=$(printf '%s' "$CHRONO_ORDER" | jq -r '.[]' | grep -oE 'iteration=[0-9]+' | sort -u | wc -l | tr -d '[:space:]')
assert_eq "11.2a anti-vacuity: the fixture genuinely carries 2 distinct iteration values" "2" "$DISTINCT_ITERS"
run_gate "$BACKFILL_LAST_ORDER"
assert_eq "11.2b anti-vacuity: artifact.verdict is round 10's real verdict (findings), proving the JSON was actually parsed" \
    "findings" "$(artverd_of "$GATE_OUT")"
assert_eq "11.2c anti-vacuity: open_finding_ids names round 10's own findings" "R10-F1, R10-F2" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.open_finding_ids | join(", ")' 2>/dev/null)"

# 11.3 TIE: two records share the numerically highest iteration. Resolved by
# each tied record's OWN timestamp (lexicographic max — the same convention
# max_record_ts uses for a different grammar), never by position. Both
# orderings below must pick the SAME winner: the later-timestamped approve.
TIE_EARLY=$(art_iter 5 findings 'R5-F1:high' 2026-08-30T10:00:00Z)
TIE_LATE=$(art_iter 5 approve '' 2026-08-30T11:00:00Z)
run_gate "$(mk_comments "$IMPL_BACKEND" "$TIE_EARLY" "$TIE_LATE")"
assert_eq "11.3a tie broken by timestamp (early then late in the array): exit 0 (later timestamp wins)" "0" "$GATE_EXIT"
assert_eq "11.3b ...artifact.verdict=approve (the later-timestamped record)" "approve" "$(artverd_of "$GATE_OUT")"
run_gate "$(mk_comments "$IMPL_BACKEND" "$TIE_LATE" "$TIE_EARLY")"
assert_eq "11.3c tie broken by timestamp (late then early in the array): SAME exit 0" "0" "$GATE_EXIT"
assert_eq "11.3d ...SAME winner regardless of array position (artifact.verdict=approve)" "approve" "$(artverd_of "$GATE_OUT")"

# 11.4 DOUBLE TIE: same iteration AND the same timestamp. No further
# principled signal exists to break it, so this refuses (loud and named)
# rather than falling back to position — which is the exact defect this
# rewrite removes.
DTIE_A=$(art_iter 5 findings 'R5-F1:high' 2026-08-30T11:00:00Z)
DTIE_B=$(art_iter 5 approve '' 2026-08-30T11:00:00Z)
run_gate "$(mk_comments "$IMPL_BACKEND" "$DTIE_A" "$DTIE_B")"
assert_eq "11.4a double tie (same iteration, same timestamp): exit 4" "4" "$GATE_EXIT"
assert_eq "11.4b ...error_key=review_artifact_selection_tie_unresolved" \
    "review_artifact_selection_tie_unresolved" "$(ekey_of "$GATE_OUT")"
assert_eq "11.4c ...ok=false" "false" "$(ok_of "$GATE_OUT")"

# 11.5 UNPARSEABLE iteration. Must NOT rank as 0 and lose silently (the A2-2
# sibling shape at sev_rank's `*) echo 0 ;;`, explicitly not to be
# reproduced here) and must NOT silently win either — so it is never ranked.
#
# POSITION NEVER MATTERS, for ANY comparison (claude-workflow-plugin-k6re
# R12-F1, superseding R11-F1's narrower claim). R11-F1 shipped a recovery
# that excused a malformed candidate strictly BEFORE an unambiguous
# well-formed winner, reasoning that bd's own comment order is append-only
# so an earlier position could never be a corrupted LATER round in
# disguise. Independent review round 12 of claude-workflow-plugin-i8cx
# falsified that premise against the actual bd 1.2.2 source: `bd show
# --include-comments` orders comments `ORDER BY created_at ASC, id ASC`,
# and `bd import` (which this repository's own mandatory reconciliation
# runs unconditionally) preserves a supplied created_at verbatim even onto
# an already-existing issue — so a malformed comment imported AFTER a
# well-formed winner, carrying an OLDER created_at, sorts BEFORE it. No
# derived key fixes this (comment `id` is a UUIDv7, itself time-derived and
# equally backfillable), so the fix removes position from the decision
# entirely rather than choosing a different one. This never applies to a
# comparison between two WELL-FORMED candidates — fkm.1.1 (section 11.8)
# and the tie/double-tie legs (11.3/11.4) are untouched and still resolve
# purely on iteration/timestamp agreement, never on position.
#
# 11.5a-d below is the R11-F1/R12-F1 shape: one good record (GOOD_R3), one
# malformed record (BAD_ITER), tested BOTH ways round. Both orderings now
# agree — refuse — which is the property this fix restores: a malformed
# candidate can no longer be laundered into a silent pass by choosing which
# side of the winner it lands on. Section 11.9 below is where the sole
# remaining recovery path (an explicit, content-hash-addressed operator
# quarantine — never an inference from position) is covered, along with its
# own META/anti-regression legs; 11.5c/d keep the R11-F1 fixture shape here
# too so the discriminator (11.5h/11.5i) and the NOITER/BAD_TS siblings in
# this existing section stay in one place for comparison.
GOOD_R3=$(art_iter 3 approve '' 2026-08-30T11:00:00Z)
BAD_ITER='REVIEW-ARTIFACT v1 iteration=abc reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=approve stopped_by=verdict findings=[] artifact_hash=ah at 2026-08-30T10:00:00Z: summary'
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3" "$BAD_ITER")"
assert_eq "11.5a unparseable iteration (bad record LAST, i.e. AFTER the good one): STILL exit 4" "4" "$GATE_EXIT"
assert_eq "11.5b ...error_key=review_artifact_iteration_unparseable (bad record could outrank the good one)" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3")"
assert_eq "11.5c unparseable iteration (bad record FIRST, i.e. BEFORE the good one): NOW exit 4 too (k6re R12-F1 — position is no longer trusted either direction)" \
    "4" "$GATE_EXIT"
assert_eq "11.5d ...SAME error_key=review_artifact_iteration_unparseable regardless of position" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"

# 11.5e A record with NO iteration= token at all is unparseable too (empty
# never satisfies ^[0-9]+$), not a silent 0. Kept in the "bad AFTER good"
# orientation for continuity with the original fixture; section 11.9 covers
# the missing-token shape explicitly against the quarantine mechanism.
NOITER='REVIEW-ARTIFACT v1 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=approve stopped_by=verdict findings=[] artifact_hash=ah at 2026-08-30T10:00:00Z: summary'
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3" "$NOITER")"
assert_eq "11.5f missing iteration= token entirely (bad AFTER good): exit 4" "4" "$GATE_EXIT"
assert_eq "11.5g ...error_key=review_artifact_iteration_unparseable" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"

# 11.5h DISCRIMINATOR: the SAME comment set with the bad record removed
# passes cleanly — proving 11.5a/f refuse because of the malformed iteration
# specifically, not for some unrelated reason.
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3")"
assert_eq "11.5i discriminator: without the bad record, the gate is clean (exit 0)" "0" "$GATE_EXIT"

# 11.5j UNPARSEABLE timestamp — the SYMMETRIC case. Timestamp is now equally
# load-bearing (it decides ties AND disagreement, see 11.8 below), so an
# unparseable `at <ts>` must refuse just as loudly as an unparseable
# iteration, under its OWN distinct key (an operator seeing
# review_artifact_timestamp_unparseable knows which field to look at,
# rather than a generic "something is wrong"). Same k6re R12-F1 symmetry as
# 11.5a-d applies here: BOTH orderings refuse, never just one.
BAD_TS='REVIEW-ARTIFACT v1 iteration=99 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=approve stopped_by=verdict findings=[] artifact_hash=ah at not-a-real-timestamp: summary'
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3" "$BAD_TS")"
assert_eq "11.5k unparseable timestamp (bad record LAST, AFTER the good one): STILL exit 4" "4" "$GATE_EXIT"
assert_eq "11.5l ...error_key=review_artifact_timestamp_unparseable" \
    "review_artifact_timestamp_unparseable" "$(ekey_of "$GATE_OUT")"
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_TS" "$GOOD_R3")"
assert_eq "11.5m unparseable timestamp (bad record FIRST, BEFORE the good one): NOW exit 4 too (k6re R12-F1)" \
    "4" "$GATE_EXIT"
assert_eq "11.5n ...SAME error_key=review_artifact_timestamp_unparseable regardless of position" \
    "review_artifact_timestamp_unparseable" "$(ekey_of "$GATE_OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 11.8: DISAGREEMENT — claude-workflow-plugin-fkm.1.1's REAL review history ==="
# Not a constructed edge case: this is fkm.1.1's actual REVIEW-ARTIFACT
# history (measured 2026-08-31/09-01 against the live store via
# `dolt sql -q "SELECT SUBSTRING_INDEX(text,'\n',1), created_at FROM comments
# WHERE issue_id='claude-workflow-plugin-fkm.1.1' AND ... LIKE 'REVIEW-ARTIFACT
# v1 %' ORDER BY created_at"`), reproduced verbatim as an offline fixture.
# Six records, chronological: sol-codex posts iteration=2 (12:50:31Z, findings
# on hash 594...), then qa-claude posts FIVE MORE across three different
# reviewed_hash values ending 2026-08-03T04:37:47Z (approve) — every one of
# the five still says iteration=1. Whichever process assigns qa-claude's
# iteration number on this task never incremented it; this is not a
# per-cycle reset (two of the five share reviewed_hash=159f58eb... and BOTH
# say iteration=1).
#
# max(iteration) alone would silently pick the STALE sol-codex record
# (iteration=2, a hash five later rounds already superseded) over five
# newer qa-claude ones. max(timestamp) alone would silently pick whichever
# qa-claude record happens to be posted last, discarding the fact that an
# UNEXPLAINED higher iteration number exists elsewhere. Neither silent
# choice is defensible from the data alone — so this refuses, naming BOTH
# the iteration-winner and the timestamp-winner, which is exactly the
# evidence an operator needs to diagnose which lane's counter is broken.
FKM111_R2=$(art_iter 2 findings 'R2-F1:high,R2-F2:high,R2-F3:high' 2026-08-02T12:50:31Z)
FKM111_C1='REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude-fable-5 reviewed_hash=f3f4c3db14c016c89a9ff3d0d9cb6dd797a99cba7e1a63f3c644ab7b082febdb risk_threshold=high verdict=findings stopped_by=verdict findings=[R3-F1:high,R3-F2:low] at 2026-08-02T14:32:17Z: findings — 2 finding(s) reported'
FKM111_C2='REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude-fable-5 reviewed_hash=f3f4c3db14c016c89a9ff3d0d9cb6dd797a99cba7e1a63f3c644ab7b082febdb risk_threshold=high verdict=findings stopped_by=verdict findings=[R4-F1:high] at 2026-08-02T15:58:53Z: findings — 1 finding(s) reported'
FKM111_C3='REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude-fable-5 reviewed_hash=d69a4b7b79c6115bd628c34f776d231cefd12a2d48bb4ddf21349ab9e3ca44a1 risk_threshold=high verdict=approve stopped_by=verdict findings=[R5-F1:low,R5-F2:info] at 2026-08-02T23:54:28Z: approve — no findings at/above high'
FKM111_C4='REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude-fable-5 reviewed_hash=159f58ebd3f2cfcef7560aedf1518d43a5199455cf6818738a07e0ac62a9d1f2 risk_threshold=high verdict=findings stopped_by=verdict findings=[R6-F1:high,R6-F2:low,R6-F3:low,R6-F4:info] at 2026-08-03T03:06:26Z: findings — 4 finding(s) reported'
FKM111_C5='REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude-fable-5 reviewed_hash=159f58ebd3f2cfcef7560aedf1518d43a5199455cf6818738a07e0ac62a9d1f2 risk_threshold=high verdict=approve stopped_by=verdict findings=[R7-F1:low,R7-F2:low,R7-F3:info,R7-F4:info] at 2026-08-03T04:37:47Z: approve — no findings at/above high'
FKM111_COMMENTS=$(mk_comments "$FKM111_R2" "$FKM111_C1" "$FKM111_C2" "$FKM111_C3" "$FKM111_C4" "$FKM111_C5")

run_gate "$FKM111_COMMENTS"
assert_eq "11.8a fkm.1.1 real history: refuses (exit 4), neither silent choice is made" "4" "$GATE_EXIT"
assert_eq "11.8b ...error_key=review_artifact_selection_disagreement" \
    "review_artifact_selection_disagreement" "$(ekey_of "$GATE_OUT")"
assert_eq "11.8c ...ok=false" "false" "$(ok_of "$GATE_OUT")"
assert_eq "11.8d ...observations names the iteration-winning record's iteration (2)" "1" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -c 'iteration=2 ' || true)"
assert_eq "11.8e ...AND the timestamp-winning record (the final approve at 04:37:47Z)" "1" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -c '2026-08-03T04:37:47Z' || true)"
# 11.8d2/11.8e2 STRUCTURAL: the observations field this fix quotes for an
# operator to read must never itself echo a reviewer= identity —
# reviewer-lane-structural.test.sh scans review-check.sh's RUNTIME output
# for exactly this shape (correction 10), and fkm.1.1's own real data
# carries reviewer=sol-codex on the very record this DISAGREEMENT names.
# A prior version of this fix quoted the raw record verbatim and leaked it
# at runtime; this pins the fix (safe_summary() reports only
# iteration=/reviewed_hash=/at=, never reviewer=/model=/pin=) so it cannot
# regress silently.
assert_eq "11.8d2 STRUCTURAL: observations never echoes a reviewer= identity token" "0" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"
assert_eq "11.8e2 STRUCTURAL: ...nor anywhere in the FULL gate envelope's runtime bytes (the field this pins is one of several; this is the end-to-end proof)" "0" \
    "$(printf '%s' "$GATE_OUT" | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"

# 11.8f DISCRIMINATOR: strip the lone sol-codex record out, leaving only
# qa-claude's five iteration=1 records — no disagreement is possible with a
# single distinct iteration value in play, so this must resolve cleanly to
# the chronologically-last one (the real approve), proving 11.8a-e refuse
# specifically BECAUSE of the cross-lane iteration mismatch, not because
# five same-iteration records are inherently unresolvable (11.3 already
# covers plain same-iteration ties).
FKM111_NO_R2=$(mk_comments "$FKM111_C1" "$FKM111_C2" "$FKM111_C3" "$FKM111_C4" "$FKM111_C5")
run_gate "$FKM111_NO_R2"
assert_eq "11.8g discriminator: without the sol-codex record, resolves cleanly (exit 0)" "0" "$GATE_EXIT"
assert_eq "11.8h ...artifact.verdict=approve (the chronologically-last qa-claude record)" \
    "approve" "$(artverd_of "$GATE_OUT")"

# ---------------------------------------------------------------------------
# 11.6 META (load-bearing, required by .claude/tests/README.md's pairing
# requirement): splice the EXACT pre-fix `tail -1` one-liner back into the
# sentinel-bounded region and re-run 11.1's identical two orderings against
# it. The mutant must reproduce the ORIGINAL defect — position alone
# flipping the outcome — proving 11.1's order-independence is because of
# this fix and not some unrelated property of the fixture.
MUTANT_ARTSEL="$WORK/review-check-preartsel.sh"
{
    sed -n '1,/# ART-ITERATION-SELECT BEGIN/p' "$RCHECK"
    cat <<'OLDCODE_ARTSEL'
    art=$(grep -E '^REVIEW-ARTIFACT v1 ' "$firstlines" | tail -1 || true)
OLDCODE_ARTSEL
    sed -n '/# ART-ITERATION-SELECT END/,$p' "$RCHECK"
} > "$MUTANT_ARTSEL"
chmod +x "$MUTANT_ARTSEL"
assert_eq "11.6a META: the mutant differs from the shipped script (non-vacuous splice)" "differs" \
    "$(cmp -s "$RCHECK" "$MUTANT_ARTSEL" && echo identical || echo differs)"
assert_eq "11.6b META: the mutant parses" "0" \
    "$(bash -n "$MUTANT_ARTSEL" 2>/dev/null && echo 0 || echo 1)"

printf '%s' "$CHRONO_ORDER" > "$WORK/comments.json"
META_ARTSEL_CHRONO=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_ARTSEL" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_ARTSEL_CHRONO_RC=$?
printf '%s' "$BACKFILL_LAST_ORDER" > "$WORK/comments.json"
META_ARTSEL_BACKFILL=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_ARTSEL" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_ARTSEL_BACKFILL_RC=$?

assert_eq "11.6c META: mutant on chronological order still refuses (exit 4) — matches the fixed script BY COINCIDENCE" \
    "4" "$META_ARTSEL_CHRONO_RC"
assert_eq "11.6c2 META: ...and for the coincidental reason (r10 IS last in THIS order too, artifact.iteration=10)" \
    "10" "$(iter_of "$META_ARTSEL_CHRONO")"
assert_eq "11.6d META: mutant on backfill-last order WRONGLY passes (exit 0) — the k6re defect reproduced" \
    "0" "$META_ARTSEL_BACKFILL_RC"
assert_eq "11.6e META: ...open_findings silently drops to 0" "0" "$(openct_of "$META_ARTSEL_BACKFILL")"
assert_eq "11.6f META: ...artifact.iteration reads back 2 (the stale, backfilled record) instead of 10" \
    "2" "$(iter_of "$META_ARTSEL_BACKFILL")"
assert_eq "11.6g META: reordering alone flips the mutant's verdict (chrono != backfill-last)" "1" \
    "$([ "$META_ARTSEL_CHRONO_RC" != "$META_ARTSEL_BACKFILL_RC" ] && echo 1 || echo 0)"

# 11.7 THE AWK READ GUARD: awk's OWN exit-code convention differs from
# grep's (0 = ran successfully, covering both "matched" and "matched
# none"; non-zero = could not even open the file — measured directly on
# this platform earlier in this fix's development). A read failure on
# $firstlines must refuse loud and named, matching the i8cx-wave-2 shape
# MAX-RECORD-TS-READ-GUARD and IMPLEMENTER-SET-READ-GUARD already guard for
# their own reads of the same file — never silently read as "no records".
# Shimmed unconditionally (no argv match needed): this fix's awk invocation
# is the only awk call cmd_gate can reach before either an early exit or
# the (in a read-failure scenario, never-reached) ROUNDS block below it.
SHIM_AWKFAIL="$WORK/shim-awkfail"
mkdir -p "$SHIM_AWKFAIL"
cat > "$SHIM_AWKFAIL/awk" <<'SHIMEOF'
#!/bin/bash
exit 2
SHIMEOF
chmod +x "$SHIM_AWKFAIL/awk"

printf '%s' "$CHRONO_ORDER" > "$WORK/comments.json"
META_AWKFAIL_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" PATH="$SHIM_AWKFAIL:$PATH" \
    bash "$RCHECK" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_AWKFAIL_RC=$?
assert_eq "11.7a awk read-failure guard: exit 4 (never a silent pass)" "4" "$META_AWKFAIL_RC"
assert_eq "11.7b ...error_key=review_artifact_set_unreadable" \
    "review_artifact_set_unreadable" "$(ekey_of "$META_AWKFAIL_OUT")"
assert_eq "11.7c ...ok=false" "false" "$(ok_of "$META_AWKFAIL_OUT")"

# 11.7d RESTORE CONTROL: identical comments, shim removed (real awk) — back
# to the real predicate (11.1a's actual outcome), proving 11.7a-c is a
# genuine consequence of the read failure, not a fixture-specific artifact.
run_gate "$CHRONO_ORDER"
assert_eq "11.7e restore control (no shim): back to the real predicate (unresolved_findings)" \
    "unresolved_findings" "$(ekey_of "$GATE_OUT")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 11.9: the quarantine override has been REMOVED (claude-workflow-plugin-k6re, R2-F1) ==="
# HISTORY. Independent review round 11 of claude-workflow-plugin-i8cx
# (R11-F1) found: badfindings/baditer/badts in the END block used to be
# checked FIRST, unconditionally — ANY malformed REVIEW-ARTIFACT candidate
# ANYWHERE in a task's comment history refused the WHOLE selection FOREVER,
# with no recovery, because bd comments are append-only. The shipped R11-F1
# fix excused a malformed candidate strictly BEFORE an unambiguous
# well-formed winner, reasoning that append-only storage means an earlier
# POSITION could never be a corrupted later round in disguise.
#
# Independent review round 12 (R12-F1) falsified that premise against the
# ACTUAL bd 1.2.2 source, not by assertion, and replaced it with an
# explicit, content-hash-addressed operator override: `qa-gate.sh
# quarantine-artifact` posted a REVIEW-ARTIFACT-QUARANTINE v1 record naming
# a malformed candidate's own sha256, and the selector excused any
# candidate whose hash matched one.
#
# Independent review round 2 of THIS SAME TASK (R2-F1) found THAT
# mechanism forgeable in turn, on its own first independent review: the
# comment stream this selector reads carries no verifiable author (every
# reader of it loses that field, not only this one), the matcher accepted
# a bare `REVIEW-ARTIFACT-QUARANTINE v1 hash=<64 hex>` PREFIX rather than
# the writer's full `at <ts>: <reason>` grammar, and a hand-typed comment
# or a `bd import` reaches the selector without ever calling the writer's
# own validation. Removed entirely rather than re-guarded — this section
# now proves REMOVAL, not recovery: a malformed candidate refuses the
# whole selection unconditionally and PERMANENTLY, and NOTHING posted
# after the fact, however well-formed it looks, changes that.
#
# NOTE ON FIXTURE SHAPE. This harness's `--comments-json` seam supplies
# comment TEXT directly, bypassing bd's storage layer — so these fixtures
# express review-check.sh's own selector logic given an ORDERED comment
# stream, at exactly the abstraction level review-check.sh itself operates
# on. Array order here stands in for whatever bd-side created_at ordering
# produced — the same framing section 11.1's header already uses for
# "chronological" vs "backfill-last" order.
#
# THIS SECTION RETIRES the quarantine-RECOVERY legs the R12-F1-era version
# of this section carried (post a quarantine record, watch the gate
# resolve) and REPURPOSES their fixtures/helpers into the opposite proof —
# posting the SAME shapes of record and watching the gate refuse anyway.
# 11.9c/d/e(i-vi)/h/i below are otherwise UNCHANGED from the R12-F1-era
# section: their claim (a malformed candidate refuses regardless of its
# position, and the refusal never leaks a reviewer identity) never
# depended on quarantine existing and remains true after its removal.

# sha256_of_stdin — same shasum-then-sha256sum convention review-check.sh's
# writer/reader used for this mechanism while it existed, so a hash
# computed HERE for a fixture is guaranteed to match what the selector
# would have computed for the identical raw line. Still needed
# post-removal: the negative control below has to name the EXACT hash of
# the malformed candidate it is failing to excuse, and the META has to
# drive the REVIVED mechanism through its own real hash-matching path.
# Softly degrades: prints nothing and the caller below skips (not fails)
# the hash-dependent legs on a host with neither tool, the same
# fail-toward-refusal posture the (removed) mechanism itself always took.
sha256_of_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}'
    fi
}
HASH_TOOL_AVAILABLE="no"
[ -n "$(printf 'probe' | sha256_of_stdin)" ] && HASH_TOOL_AVAILABLE="yes"

# quarantine_line <hash> <reason> -> a REVIEW-ARTIFACT-QUARANTINE v1 comment
# matching the FULL grammar `qa-gate.sh quarantine-artifact` used to write,
# back when that command existed — the "legitimate-looking" shape, not a
# bare prefix. Used below to prove even THIS shape excuses nothing any more.
quarantine_line() {
    printf 'REVIEW-ARTIFACT-QUARANTINE v1 hash=%s at 2026-09-01T00:00:00Z: %s' "$1" "$2"
}

# forged_quarantine_prefix <hash> -> the BARE PREFIX the R2-F1 finding
# itself named as forgeable: no `at <ts>: <reason>` suffix at all. Something
# a hand-typed comment or a bd import could produce trivially, without ever
# calling any writer's validation.
forged_quarantine_prefix() {
    printf 'REVIEW-ARTIFACT-QUARANTINE v1 hash=%s' "$1"
}

# 11.9a/b THE REPRODUCTION, AS THE CONTROL. Identical fixture to 11.5c/d
# (one malformed-iteration record, then a later well-formed one), asserted
# on OUTCOME only (exit code + error_key/artifact fields), never on prose,
# per the pairing requirement. This is now ALSO the baseline the negative
# controls below are measured against: neither a WELL-FORMED nor a FORGED
# quarantine record changes this outcome, which is the entire point of
# this section post-removal.
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3")"
assert_eq "11.9a malformed iteration BEFORE a later well-formed record: exit 4 (unconditional -- no recovery mechanism exists any more)" \
    "4" "$GATE_EXIT"
assert_eq "11.9b ...error_key=review_artifact_iteration_unparseable (refuses named and loud, never a vacuous pass)" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"

# 11.9a2-a7 THE NEGATIVE CONTROL (the important one, per R2-F1's own
# framing): post a comment matching the FULL, well-formed writer grammar
# the removed quarantine-artifact command used to produce -- not a bare
# prefix, the complete `at <ts>: <reason>` shape a legitimate operator
# invocation would have posted -- naming the EXACT hash of the malformed
# candidate above. The gate must STILL refuse, with the SAME error_key as
# 11.9a/b -- proving the selector honours NO quarantine record any more,
# however well-formed, rather than merely that a loosely-matched prefix
# was tightened.
if [ "$HASH_TOOL_AVAILABLE" = "yes" ]; then
    BAD_ITER_HASH=$(printf '%s' "$BAD_ITER" | sha256_of_stdin)
    WELLFORMED_QUARANTINE=$(quarantine_line "$BAD_ITER_HASH" "verified via bd show --include-comments; not a real review round")
    run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3" "$WELLFORMED_QUARANTINE")"
    assert_eq "11.9a2 NEGATIVE CONTROL: malformed BEFORE good, WITH a full well-formed quarantine record naming its exact hash: STILL exit 4" \
        "4" "$GATE_EXIT"
    assert_eq "11.9a3 ...SAME error_key as the unquarantined case (review_artifact_iteration_unparseable) -- excuses nothing" \
        "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
    # 11.9a4/a5 SAME record, malformed candidate now AFTER good — proving
    # the removal is position-symmetric too, matching 11.9a/b's baseline.
    run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3" "$BAD_ITER" "$WELLFORMED_QUARANTINE")"
    assert_eq "11.9a4 NEGATIVE CONTROL: malformed AFTER good, WITH the same well-formed quarantine record: STILL exit 4" \
        "4" "$GATE_EXIT"
    assert_eq "11.9a5 ...SAME error_key" \
        "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
    # 11.9a6/a7 THE FORGED SHAPE SPECIFICALLY: a bare hash= prefix with NO
    # `at <ts>: <reason>` suffix -- exactly what R2-F1 found the retired
    # matcher accepted -- excuses nothing either. This is the direct
    # disproof of the finding, not merely a stronger form of 11.9a2's
    # control.
    FORGED_QUARANTINE=$(forged_quarantine_prefix "$BAD_ITER_HASH")
    run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3" "$FORGED_QUARANTINE")"
    assert_eq "11.9a6 NEGATIVE CONTROL (the forged shape itself): a bare hash= prefix, no at/reason suffix, excuses nothing: STILL exit 4" \
        "4" "$GATE_EXIT"
    assert_eq "11.9a7 ...SAME error_key" \
        "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
else
    printf '  SKIP: 11.9a2-a7 negative-control legs — neither shasum nor sha256sum on PATH\n' >&2
fi

# 11.9c ANTI-VACUITY. Two independent proofs that the malformed record was
# actually PRESENT in the fixture and actually PARSED by the selector, not
# silently invisible to it:
#   (i) the raw fixture genuinely contains the malformed token (not a typo
#       that accidentally makes it well-formed);
#  (ii) a stream holding ONLY that malformed record (no competing good
#       record at all) still REFUSES, naming the specific class
#       (review_artifact_iteration_unparseable) — never falls back to
#       review_artifact_missing/NONE, which is what would happen if the
#       selector treated a malformed candidate as though it were simply
#       absent. Silently degrading "something was posted and it is
#       corrupt" to "nothing has been posted yet" would be dangerous in
#       its own right (a fast path meant for genuinely-unreviewed change
#       sets would wrongly treat a corrupted review as no review), so this
#       is a safety property in addition to being an anti-vacuity proof.
BAD_ITER_RAW_HITS=$(printf '%s' "$BAD_ITER" | grep -c 'iteration=abc' || true)
assert_eq "11.9c-i anti-vacuity: the fixture genuinely carries the malformed iteration=abc token" \
    "1" "$BAD_ITER_RAW_HITS"
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER")"
assert_eq "11.9c-ii anti-vacuity: malformed record ALONE (no good competitor) still refuses (exit 4)" \
    "4" "$GATE_EXIT"
assert_eq "11.9c-iii ...error_key=review_artifact_iteration_unparseable, NEVER review_artifact_missing" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"

# 11.9d THE THIRD MALFORMED CLASS: findings=[...] malformed (MALFORMED /
# review_artifact_malformed), same position-independence applied
# uniformly. The fix is not scoped to the `iterations` field alone — all
# three malformed classes were reachable through the SAME (now removed)
# quarantine check upstream in the awk pattern-action block, so all three
# share the identical, now-unconditional refusal.
BAD_FINDINGS='REVIEW-ARTIFACT v1 iteration=99 reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical at 2026-08-30T10:00:00Z: unclosed bracket'
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_FINDINGS" "$GOOD_R3")"
assert_eq "11.9d-i MALFORMED findings token, bad FIRST/good LAST: exit 4 (position irrelevant)" \
    "4" "$GATE_EXIT"
assert_eq "11.9d-ii ...error_key=review_artifact_malformed" \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3" "$BAD_FINDINGS")"
assert_eq "11.9d-iii MALFORMED findings token, good FIRST/bad LAST: SAME exit 4 (no asymmetry left between the two classes)" \
    "4" "$GATE_EXIT"
assert_eq "11.9d-iv ...SAME error_key=review_artifact_malformed regardless of position" \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"

# 11.9e MIXED: a malformed record BEFORE the good winner AND a second
# malformed record AFTER it. Proves order AMONG multiple bad records is
# irrelevant too — EVERY malformed candidate refuses the whole selection;
# since there is no longer ANY way to clear one, a mixed fixture refuses
# just as unconditionally as a single bad record does.
BAD_ITER_EARLY='REVIEW-ARTIFACT v1 iteration=xyz reviewer=sol-codex model=m pin=m reviewed_hash=h risk_threshold=high verdict=approve stopped_by=verdict findings=[] artifact_hash=ah at 2026-08-30T09:00:00Z: summary'
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER_EARLY" "$GOOD_R3" "$BAD_ITER")"
assert_eq "11.9e-i mixed (bad BEFORE good, bad AFTER good too): refuses (exit 4)" \
    "4" "$GATE_EXIT"
assert_eq "11.9e-ii ...error_key=review_artifact_iteration_unparseable" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
# 11.9e-iii DISCRIMINATOR (part 1): remove the TRAILING malformed record —
# the leading one ALONE still refuses.
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER_EARLY" "$GOOD_R3")"
assert_eq "11.9e-iii discriminator: without the TRAILING bad record, the LEADING one alone still refuses (exit 4)" \
    "4" "$GATE_EXIT"
assert_eq "11.9e-iv ...error_key=review_artifact_iteration_unparseable" \
    "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
# 11.9e-v DISCRIMINATOR (part 2, symmetric): remove the LEADING malformed
# record instead — the trailing one alone still refuses too. Together with
# 11.9e-iii this proves NEITHER position is special; either bad record
# alone is sufficient to refuse, matching 11.5/11.9a-d's single-record legs.
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3" "$BAD_ITER")"
assert_eq "11.9e-v discriminator: without the LEADING bad record, the TRAILING one alone still refuses (exit 4)" \
    "4" "$GATE_EXIT"
# 11.9e-vi BASELINE: remove BOTH bad records — resolves cleanly, proving
# 11.9e-i/iii/v refuse specifically because of the malformed record(s)
# present, not for some unrelated reason baked into the fixture.
run_gate "$(mk_comments "$IMPL_BACKEND" "$GOOD_R3")"
assert_eq "11.9e-vi baseline: with BOTH bad records removed, resolves cleanly (exit 0)" \
    "0" "$GATE_EXIT"
# 11.9e-vii/viii NEGATIVE CONTROL, mixed case: a full, well-formed
# quarantine record for EACH bad hash STILL does not clear either one —
# quarantine does not compose any better than it excuses a single bad
# record, because it does not do anything at all any more.
if [ "$HASH_TOOL_AVAILABLE" = "yes" ]; then
    BAD_ITER_HASH=$(printf '%s' "$BAD_ITER" | sha256_of_stdin)
    BAD_ITER_EARLY_HASH=$(printf '%s' "$BAD_ITER_EARLY" | sha256_of_stdin)
    QUARANTINE_EARLY=$(quarantine_line "$BAD_ITER_EARLY_HASH" "verified, not a real round (early)")
    QUARANTINE_TRAILING=$(quarantine_line "$BAD_ITER_HASH" "verified, not a real round (trailing)")
    run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER_EARLY" "$GOOD_R3" "$BAD_ITER" "$QUARANTINE_EARLY" "$QUARANTINE_TRAILING")"
    assert_eq "11.9e-vii NEGATIVE CONTROL: both malformed candidates each named by a well-formed quarantine record: STILL refuses (exit 4)" \
        "4" "$GATE_EXIT"
    assert_eq "11.9e-viii ...SAME error_key as the unquarantined mixed case" \
        "review_artifact_iteration_unparseable" "$(ekey_of "$GATE_OUT")"
else
    printf '  SKIP: 11.9e-vii/viii negative-control leg — neither shasum nor sha256sum on PATH\n' >&2
fi

# 11.9f META (required by .claude/tests/README.md's pairing requirement):
# splice the mechanism's ENTIRE pre-removal implementation -- a FROZEN,
# mechanically-extracted snapshot of review-check.sh's ART-ITERATION-SELECT
# body exactly as it read immediately before this fix, never
# hand-transcribed -- back into a COPY of the CURRENT (fixed)
# review-check.sh, replacing everything between the SAME
# `# ART-ITERATION-SELECT BEGIN`/`END` sentinel comments the shipped script
# still carries. This is the strongest form of "strip your removal and
# watch it break again" available: it reintroduces the REAL removed code,
# not a hand-written approximation of it, and drives it through the REAL
# `gate` subcommand end to end.
FIXTURE_PRE_R2F1="$PROJECT_DIR/.claude/scripts/tests/fixtures/review-check-art-select-pre-r2f1.snippet"
FIXTURE_PRE_R2F1_SHA256_PINNED="bf409e58c0170fe882baa1361c928ae8347c9e7cb9163414bc2f524ca881e043"
if [ ! -f "$FIXTURE_PRE_R2F1" ]; then
    printf '  SKIP: 11.9f META — frozen fixture missing: %s\n' "$FIXTURE_PRE_R2F1" >&2
elif [ "$HASH_TOOL_AVAILABLE" != "yes" ]; then
    printf '  SKIP: 11.9f META — neither shasum nor sha256sum on PATH (the revived mechanism needs one)\n' >&2
else
    FIXTURE_PRE_R2F1_SHA256=$(sha256_of_stdin < "$FIXTURE_PRE_R2F1")
    assert_eq "11.9f-0 the frozen fixture is byte-identical to its pinned sha256 (it must never be 'refreshed' -- see its own header)" \
        "$FIXTURE_PRE_R2F1_SHA256_PINNED" "$FIXTURE_PRE_R2F1_SHA256"

    MUTANT_QREVIVED="$WORK/review-check-quarantine-revived.sh"
    {
        sed -n '1,/# ART-ITERATION-SELECT BEGIN/p' "$RCHECK"
        cat "$FIXTURE_PRE_R2F1"
        sed -n '/# ART-ITERATION-SELECT END/,$p' "$RCHECK"
    } > "$MUTANT_QREVIVED"
    chmod +x "$MUTANT_QREVIVED"
    assert_eq "11.9f-i META: the mutant differs from the shipped script (non-vacuous splice)" "differs" \
        "$(cmp -s "$RCHECK" "$MUTANT_QREVIVED" && echo identical || echo differs)"
    assert_eq "11.9f-ii META: the mutant parses" "0" \
        "$(bash -n "$MUTANT_QREVIVED" 2>/dev/null && echo 0 || echo 1)"

    # 11.9f-iii/iv MISBEHAVIOUR: with the mechanism revived, a FORGED
    # quarantine comment -- the bare hash= prefix R2-F1 itself found
    # forgeable, NOT the writer's full grammar -- WRONGLY clears the
    # malformed candidate. This is the R2-F1 defect, reproduced on demand.
    BAD_ITER_HASH=$(printf '%s' "$BAD_ITER" | sha256_of_stdin)
    FORGED_QUARANTINE=$(forged_quarantine_prefix "$BAD_ITER_HASH")
    printf '%s' "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3" "$FORGED_QUARANTINE")" > "$WORK/comments.json"
    META_QREVIVED_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_QREVIVED" gate t-1 \
        --comments-json "$WORK/comments.json" 2>/dev/null)
    META_QREVIVED_RC=$?
    assert_eq "11.9f-iii META misbehaviour: WITH the mechanism revived, a FORGED (bare-prefix) quarantine comment WRONGLY clears the malformed candidate (exit 0) -- the R2-F1 defect, reproduced" \
        "0" "$META_QREVIVED_RC"
    assert_eq "11.9f-iv ...artifact.iteration=3 -- a malformed, never-legitimately-quarantined candidate silently excused by a forged record" \
        "3" "$(iter_of "$META_QREVIVED_OUT")"

    # 11.9f-v/vi DISCRIMINATOR: the SAME revived mutant, with NO quarantine
    # comment at all, still refuses on the ordinary malformed fixture --
    # proving 11.9f-iii/iv is specifically about the FORGED record being
    # honoured, not a general breakage the splice introduced.
    printf '%s' "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3")" > "$WORK/comments.json"
    META_QREVIVED_NOQ=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_QREVIVED" gate t-1 \
        --comments-json "$WORK/comments.json" 2>/dev/null)
    META_QREVIVED_NOQ_RC=$?
    assert_eq "11.9f-v discriminator: the SAME revived mutant, with NO quarantine comment, still refuses (exit 4)" \
        "4" "$META_QREVIVED_NOQ_RC"
    assert_eq "11.9f-vi ...error_key=review_artifact_iteration_unparseable" \
        "review_artifact_iteration_unparseable" "$(ekey_of "$META_QREVIVED_NOQ")"

    # 11.9f-vii/viii RESTORE CONTROL: the REAL, shipped (unmutated) script,
    # the IDENTICAL forged-quarantine fixture that fooled the mutant above,
    # in the SAME test run -- proving the shipped removal is what refuses
    # it, not an artifact of environment/order.
    printf '%s' "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3" "$FORGED_QUARANTINE")" > "$WORK/comments.json"
    META_RESTORE_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RCHECK" gate t-1 \
        --comments-json "$WORK/comments.json" 2>/dev/null)
    META_RESTORE_RC=$?
    assert_eq "11.9f-vii RESTORE CONTROL: the REAL shipped script, same forged-quarantine fixture that fooled the mutant: refuses (exit 4)" \
        "4" "$META_RESTORE_RC"
    assert_eq "11.9f-viii ...error_key=review_artifact_iteration_unparseable (the mutation, not the shipped script, is what misbehaves)" \
        "review_artifact_iteration_unparseable" "$(ekey_of "$META_RESTORE_OUT")"
fi

# 11.9g RESTORE CONTROL: the REAL (unmutated) script, same 11.9a fixture,
# run again here regardless of whether a hash tool was available to run
# 11.9f above — confirms nothing in this section leaked state into the
# rest of this suite.
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3")"
assert_eq "11.9g restore control (real script, no mutation, run after the META): exit 4" "4" "$GATE_EXIT"

# 11.9h LANE-PURITY (correction 10 discipline, mirroring 11.8d2/11.8e2):
# BAD_ITER embeds reviewer=sol-codex verbatim. The malformed-refusal
# observations (now much longer prose, explaining there is no recovery
# path left) must still never leak it -- this was true before the removal
# (safe_summary() never quoted raw records) and remains true after.
run_gate "$(mk_comments "$IMPL_BACKEND" "$BAD_ITER" "$GOOD_R3")"
assert_eq "11.9h STRUCTURAL: the malformed-refusal observations never echo a reviewer= identity token" "0" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"
assert_eq "11.9i STRUCTURAL: ...nor anywhere in the full gate envelope's runtime bytes" "0" \
    "$(printf '%s' "$GATE_OUT" | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"
# 11.9j ANTI-VACUITY for 11.9h/i: the observations DOES carry the
# malformed record's own safe_summary() fields (iteration=unparseable, its
# own at= timestamp) and explicitly states there is no recovery path --
# something real and record-derived, proving the structural check above is
# proving something was scrubbed, not that the message was empty and had
# nothing to leak in the first place. No hash= token any more (this fix
# removed hash computation entirely, not merely its printing).
assert_eq "11.9j anti-vacuity: the observations DOES carry the malformed record's own iteration=unparseable marker" "1" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -cF 'iteration=unparseable' || true)"
assert_eq "11.9j2 anti-vacuity: ...AND its own at=<timestamp> (BAD_ITER's real 10:00:00Z), not a placeholder" \
    "1" "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -cF 'at=2026-08-30T10:00:00Z' || true)"
assert_eq "11.9j3 anti-vacuity: ...and explicitly states there is no recovery path (the R2-F1 removal, not a silent behaviour change)" \
    "1" "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -cF 'no recovery path' || true)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 11.10: R1-F1 — iteration comparison is EXACT for arbitrary-length digit strings, never coerced through awk's numeric type (claude-workflow-plugin-k6re) ==="
# MEASURED defect (independent review round 1 of claude-workflow-plugin-k6re,
# reviewed_hash 5a3e65de46593b76cea7c11b4717cf7888c48b50d0e84f7467bd9961b889bb1c):
# `iters[n] = itraw + 0` forced an already-validated (^[0-9]+$), UNBOUNDED
# digit string into awk's one numeric type -- a C double, 53-bit mantissa --
# before the max/winner computation ran. Two DISTINCT decimal integers above
# 2^53 (9007199254740992) can collapse to the identical double. MEASURED on
# this host: assigning "9007199254740992"+0 and "9007199254740993"+0 to two
# variables and comparing them with == reports equal (see 11.10c2 below,
# which pins this platform fact directly rather than asserting it in prose).
# Consequence: an OLDER record at iteration=9007199254740993 and a NEWER
# record at iteration=9007199254740992 compared iteration-EQUAL, so the
# newer record read as simultaneously max-iteration AND max-timestamp and
# was silently SELECTED as governing -- exactly the wrong-record-selection
# and refuse-on-ambiguity regression K3 exists to prevent, reached through a
# channel K3's own design never considered (numeric precision, not
# position).
#
# THE FIX: iteration values are never converted to awk's numeric type at
# any length (review-check.sh ART-ITER-CMP). Comparison is by normalised
# (leading zeros stripped) LENGTH first, then a length-tie broken by a
# STRING (never strnum-coerced) lexicographic compare.

# 11.10a/b THE REPRODUCTION, AS THE CONTROL. Exactly the MEASURED shape: A
# carries the HIGHER true iteration (...993) but the OLDER timestamp; B
# carries the LOWER true iteration (...992) but is the timestamp winner.
# Pre-fix this fixture silently selected B (exit 0); the whole point of this
# fix is that it now refuses instead.
REC_HUGE_OLDER=$(art_iter 9007199254740993 approve '' 2026-08-30T09:00:00Z)
REC_HUGE_NEWER=$(art_iter 9007199254740992 approve '' 2026-08-30T10:00:00Z)
run_gate "$(mk_comments "$IMPL_BACKEND" "$REC_HUGE_OLDER" "$REC_HUGE_NEWER")"
assert_eq "11.10a R1-F1 reproduction: exit 4 (NOT the old silent exit 0)" "4" "$GATE_EXIT"
assert_eq "11.10b ...error_key=review_artifact_selection_disagreement (neither silently governs)" \
    "review_artifact_selection_disagreement" "$(ekey_of "$GATE_OUT")"

# 11.10c ANTI-VACUITY. The two iteration tokens really are distinct decimal
# strings in the fixture (not a typo that accidentally makes them equal),
# and 11.10c2 pins the platform fact this whole section is measured against
# directly (awk's own +0 coercion genuinely collapses these two strings to
# one double on this host) rather than merely asserting it in a comment.
HUGE_DISTINCT=$(printf '%s\n%s\n' "$REC_HUGE_OLDER" "$REC_HUGE_NEWER" | grep -oE 'iteration=[0-9]+' | sort -u | wc -l | tr -d '[:space:]')
assert_eq "11.10c anti-vacuity: fixture genuinely carries 2 distinct iteration tokens" "2" "$HUGE_DISTINCT"
assert_eq "11.10c2 anti-vacuity: they really do differ only past awk's 2^53 double boundary (both collapse under a bare +0 on THIS host)" \
    "1" "$(awk 'BEGIN{a="9007199254740993"+0; b="9007199254740992"+0; print (a==b) ? 1 : 0}')"

# 11.10d ANTI-OVERREACH: an ORDINARY small-number case that a NAIVE
# (non-length-aware) string compare would get WRONG in the OPPOSITE
# direction -- lexicographically "9" > "10" (first character '9' > '1'), so
# a fix that forgot to compare LENGTH first would treat 9 as the higher
# iteration and spuriously DISAGREE with the (correct) timestamp winner,
# false-positive-refusing perfectly ordinary data. Iteration 10 is both the
# true iteration-max and the timestamp-max here; this must resolve cleanly,
# on the real winner, exactly as it did before this fix (this is the case
# that matters in practice and must not regress).
REC_9=$(art_iter 9 approve '' 2026-08-30T09:00:00Z)
REC_10=$(art_iter 10 findings 'R10-F1:high' 2026-08-30T10:00:00Z)
run_gate "$(mk_comments "$IMPL_BACKEND" "$REC_9" "$REC_10")"
assert_eq "11.10d anti-overreach: ordinary 9-then-10 resolves on the REAL max (unresolved_findings), never a spurious DISAGREEMENT" \
    "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "11.10d2 ...artifact.iteration=10 (not 9 -- length beats naive lexicographic order)" \
    "10" "$(iter_of "$GATE_OUT")"

# 11.10e/f LEADING ZEROS -- DECISION STATED EXPLICITLY: "007" and "7" are
# the SAME iteration number (leading zeros carry no magnitude information)
# and must TIE, resolved by timestamp exactly like any other same-iteration
# tie (section 11.3) -- never treated as two different iterations by virtue
# of "007" being a longer raw string. LZ_PAD carries an OPEN finding and an
# EARLIER timestamp; LZ_BARE is a clean approve with a LATER timestamp. If
# leading zeros were (wrongly) significant, "007" would out-rank "7" on raw
# length and this would refuse via DISAGREEMENT (LZ_PAD iteration-wins,
# LZ_BARE timestamp-wins); normalised correctly, they TIE and the later
# timestamp (LZ_BARE, clean) governs.
LZ_PAD=$(art_iter 007 findings 'R1-F1:high' 2026-08-30T09:00:00Z)
LZ_BARE=$(art_iter 7 approve '' 2026-08-30T10:00:00Z)
run_gate "$(mk_comments "$IMPL_BACKEND" "$LZ_PAD" "$LZ_BARE")"
assert_eq "11.10e leading zeros: 007 and 7 tie (same iteration); later-timestamp LZ_BARE governs (exit 0)" \
    "0" "$GATE_EXIT"
assert_eq "11.10e2 ...artifact.verdict=approve (LZ_BARE, not LZ_PAD's stale findings)" \
    "approve" "$(artverd_of "$GATE_OUT")"
run_gate "$(mk_comments "$IMPL_BACKEND" "$LZ_BARE" "$LZ_PAD")"
assert_eq "11.10f leading zeros, reversed array position: SAME result (position-independent, as K3 requires)" \
    "0" "$GATE_EXIT"
assert_eq "11.10f2 ...SAME winner regardless of position" "approve" "$(artverd_of "$GATE_OUT")"

# 11.10g A leading-zero DIFFERENT-value pair: "0010" genuinely outranks "9"
# (10 > 9) despite "0010" being a LONGER raw string before normalisation --
# proving padding does not throw off the magnitude compare in the OTHER
# direction either (a value must be recognised as correctly GREATER, not
# just correctly EQUAL, once its zeros are stripped). Both axes agree here
# (0010 is also the later timestamp), so this resolves cleanly on 0010.
LZ_BIG=$(art_iter 0010 findings 'R1-F1:high' 2026-08-30T10:00:00Z)
LZ_SMALL=$(art_iter 9 approve '' 2026-08-30T09:00:00Z)
run_gate "$(mk_comments "$IMPL_BACKEND" "$LZ_SMALL" "$LZ_BIG")"
assert_eq "11.10g leading-zero magnitude: 0010 correctly outranks 9 (unresolved_findings)" \
    "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "11.10g2 ...artifact.iteration reads back the raw winning token (0010), proving 0010 -- not 9 -- genuinely governs" \
    "0010" "$(iter_of "$GATE_OUT")"

# 11.10h META (required by .claude/tests/README.md's pairing requirement):
# revert iter_cmp()/norm_iter() to the R1-F1 shape (a+0 / b+0, numeric
# compare, no normalisation) via the same BEGIN/END sentinel-splice
# technique 11.6 uses, and watch 11.10a's reproduction select the wrong
# record again -- proving 11.10a/b's refusal is because of THIS fix and not
# some unrelated property of the fixture.
MUTANT_ITERCMP="$WORK/review-check-itercmp-numeric.sh"
{
    sed -n '1,/# ART-ITER-CMP BEGIN/p' "$RCHECK"
    cat <<'OLDCODE_ITERCMP'
        function norm_iter(s) { return s }
        function iter_cmp(a, b,    na, nb) {
            na = a + 0; nb = b + 0
            if (na > nb) return 1
            if (na < nb) return -1
            return 0
        }
OLDCODE_ITERCMP
    sed -n '/# ART-ITER-CMP END/,$p' "$RCHECK"
} > "$MUTANT_ITERCMP"
chmod +x "$MUTANT_ITERCMP"
assert_eq "11.10h-i META: the mutant differs from the shipped script (non-vacuous splice)" "differs" \
    "$(cmp -s "$RCHECK" "$MUTANT_ITERCMP" && echo identical || echo differs)"
assert_eq "11.10h-ii META: the mutant parses" "0" \
    "$(bash -n "$MUTANT_ITERCMP" 2>/dev/null && echo 0 || echo 1)"

printf '%s' "$(mk_comments "$IMPL_BACKEND" "$REC_HUGE_OLDER" "$REC_HUGE_NEWER")" > "$WORK/comments.json"
META_ITERCMP_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_ITERCMP" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_ITERCMP_RC=$?
assert_eq "11.10h-iii META misbehaviour: the mutant WRONGLY resolves the R1-F1 reproduction (exit 0) -- the k6re defect reproduced" \
    "0" "$META_ITERCMP_RC"
assert_eq "11.10h-iv ...artifact.iteration reads back 9007199254740992 (the LOWER true iteration, silently governing)" \
    "9007199254740992" "$(iter_of "$META_ITERCMP_OUT")"

# 11.10h-v DISCRIMINATOR: the mutant must not break the ORDINARY 9-then-10
# case -- proving the mutation surgically reproduces ONLY the
# precision-loss misbehaviour, not a general breakage that would make this
# META non-diagnostic.
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$REC_9" "$REC_10")" > "$WORK/comments.json"
META_ITERCMP_ORD=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$MUTANT_ITERCMP" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
assert_eq "11.10h-v discriminator: the mutant still resolves the ordinary 9-then-10 case correctly (artifact.iteration=10)" \
    "10" "$(iter_of "$META_ITERCMP_ORD")"

# 11.10i RESTORE CONTROL: the REAL (unmutated) script, same reproduction, in
# the SAME test run -- proving 11.10a/b is a genuine consequence of the
# shipped fix and not an artifact of environment/order.
run_gate "$(mk_comments "$IMPL_BACKEND" "$REC_HUGE_OLDER" "$REC_HUGE_NEWER")"
assert_eq "11.10i restore control (real script, no mutation): back to exit 4" "4" "$GATE_EXIT"

# 11.10j/k LANE-PURITY (correction 10 discipline, mirroring 11.8d2/11.9h):
# art_iter's records embed reviewer=sol-codex verbatim; the DISAGREEMENT
# observations for this fixture must never echo it.
assert_eq "11.10j STRUCTURAL: observations never echoes a reviewer= identity token" "0" \
    "$(printf '%s' "$GATE_OUT" | jq -r '.observations' 2>/dev/null | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"
assert_eq "11.10k STRUCTURAL: ...nor anywhere in the full gate envelope runtime bytes" "0" \
    "$(printf '%s' "$GATE_OUT" | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 12: k6re R5-F1 (independent review round 5) — findings=[...] cannot forge another field's declaration ==="
# R5-F1: findings=[...] is the one span in $ART_PREFIX whose content class
# admits `=` -- every OTHER field's value class forbids it. A record that
# OMITS the seven soft fields (all independently optional) and instead
# plants reviewer=/risk_threshold=/verdict=/reviewed_hash=/model=/pin=/
# stopped_by=/artifact_hash= INSIDE the brackets used to be read back by
# every extractor as though genuinely declared, because each one scanned
# the WHOLE of $ART_PREFIX rather than the region the grammar actually
# assigned to it. See ART-PREFIX-PARTITION in review-check.sh for the fix
# (ART_PREFIX_HEAD / ART_PREFIX_TAIL).

# 12.1 THE TASK REPRODUCTION, VERBATIM. iteration=99, ALL seven soft fields
# omitted, findings=[...] stuffed with reviewer=/risk_threshold=/verdict=/
# reviewed_hash= in valid key=value shape. Pre-fix this read back
# REVIEWER=sol-codex (an attacker-chosen "independent" identity where none
# was declared), bypassing REVIEWER-NONEMPTY-GUARD entirely.
R5F1_ATTACK='REVIEW-ARTIFACT v1 iteration=99 findings=[R1-F1,reviewer=sol-codex,risk_threshold=low,verdict=approve,reviewed_hash=deadbeefdeadbeef] at 2026-09-02T00:00:00Z: benign looking summary'
run_gate "$(mk_comments "$R5F1_ATTACK")"
assert_eq "12.1a THE REPRODUCTION: no reviewer= was ever declared -- exit 4, not the pre-fix silent acceptance of the forged identity" \
    "4" "$GATE_EXIT"
assert_eq "12.1b ...error_key=review_artifact_malformed, NOT reviewer_identity_missing -- SUPERSEDED by claude-workflow-plugin-k6re recurrence 5 (Section 14): the bracket content here (R1-F1,reviewer=sol-codex,...) has no severity suffix after R1-F1 and every other item is a bare key=value pair, so the WHOLE bracket now fails art_findings_ok() before REVIEWER-NONEMPTY-GUARD ever runs. Caught one layer earlier, not less safely -- see 12.1g/12.1h for the consequence." \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"
assert_eq "12.1c ...reviewer_identity reads back empty, never the forged sol-codex" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.reviewer_identity')"
assert_eq "12.1d ...artifact.risk_threshold reads back empty, never the forged low" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.risk_threshold')"
assert_eq "12.1e ...artifact.verdict reads back empty, never the forged approve" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.verdict')"
assert_eq "12.1f ...artifact.reviewed_hash reads back empty, never the forged deadbeefdeadbeef" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewed_hash')"
assert_eq "12.1g ...artifact.iteration NOW reads back empty too (claude-workflow-plugin-k6re recurrence 5): the record is malformed as a WHOLE, not merely bracket-forged-but-otherwise-readable -- the same all-or-nothing unreadability every other malformed-bracket record already gets (R3-F1/R7-F1), extended to this shape now that it, too, fails art_findings_ok()" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.iteration')"
assert_eq "12.1h ...artifact.findings_token NOW reads back empty too, never the raw bracket content (claude-workflow-plugin-k6re recurrence 5): ART_FINDINGS is never populated for a record refused at selection" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

# 12.2 THE SAME ATTACK, PAST THE REVIEWER GATE. A genuine reviewer= soft
# field is declared (so REVIEWER-NONEMPTY-GUARD does not short-circuit
# before the OTHER forged fields can be observed), every OTHER soft field
# is omitted, and the brackets carry forged risk_threshold=/verdict=/
# reviewed_hash=/model=/pin=/stopped_by=/artifact_hash= -- the seven
# remaining HEAD-scoped fields plus the one TAIL-scoped field
# (artifact_hash=), all in a single record. Every planted item is its own
# comma-separated "finding" with an unparseable severity (no real
# Rn-Fn:severity shape), so OPEN_COUNT is genuinely 0 and this record
# legitimately passes (exit 0) -- realreviewer left no real findings, which
# is a correct, ordinary clean-review outcome, not a residual gap.
R5F1_ATTACK_PAST_REVIEWER='REVIEW-ARTIFACT v1 iteration=42 reviewer=realreviewer findings=[R1-F1,risk_threshold=critical,verdict=approve,reviewed_hash=cafefeedcafefeed,model=fake-model,pin=fake-pin,stopped_by=verdict,artifact_hash=fakefilehash] at 2026-09-02T00:00:00Z: another benign summary'
run_gate "$(mk_comments "$R5F1_ATTACK_PAST_REVIEWER")"
assert_eq "12.2a ...exit 4, NOT the pre-recurrence-5 exit 0 (claude-workflow-plugin-k6re recurrence 5, Section 14): none of these comma-items is a well-formed Rn-Fn:severity pair (R1-F1 has no severity; the rest are bare key=value), so the bracket is malformed and the record is refused OUTRIGHT rather than tolerated as 'zero real findings' -- a bracket shaped like this was never a genuine clean review to begin with" \
    "4" "$GATE_EXIT"
assert_eq "12.2b ...reviewer_identity NOW reads back empty too, not even the genuine realreviewer (claude-workflow-plugin-k6re recurrence 5): a malformed bracket makes the WHOLE record unreadable, including the otherwise-legitimately-declared soft field that sits before it" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.reviewer_identity')"
assert_eq "12.2c ...artifact.risk_threshold reads back empty, never the bracket-forged critical" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.risk_threshold')"
assert_eq "12.2d ...artifact.verdict reads back empty, never the bracket-forged approve" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.verdict')"
assert_eq "12.2e ...artifact.reviewed_hash reads back empty, never the bracket-forged cafefeedcafefeed" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewed_hash')"
assert_eq "12.2f ...artifact.model reads back empty, never the bracket-forged fake-model" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.model')"
assert_eq "12.2g ...artifact.reviewer_pin reads back empty, never the bracket-forged fake-pin" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewer_pin')"
assert_eq "12.2h ...artifact.stopped_by reads back empty, never the bracket-forged verdict" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.stopped_by')"
assert_eq "12.2i ...artifact.artifact_hash (TAIL-scoped, the ONE field the grammar places AFTER the bracket) reads back empty, never the bracket-forged fakefilehash" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.artifact_hash')"
assert_eq "12.2j ...rounds_hash (a SEPARATE extractor reading the same reviewed_hash= soft field for a different purpose) also reads back empty, never the bracket-forged cafefeedcafefeed" \
    "" "$(roundshash_of "$GATE_OUT")"

# 12.3 ANTI-OVERREACH: a fully-populated LEGITIMATE record (all seven soft
# fields plus artifact_hash=, including a model= value that legitimately
# contains `[`/`]` per the 46w9 bracket widening) must parse EXACTLY as
# before -- every field byte-identical to its declared value.
R5F1_LEGIT='REVIEW-ARTIFACT v1 iteration=10 reviewer=sol-codex model=claude-opus-5[1m] pin=abc123 reviewed_hash=7b8a0107cafefeed risk_threshold=high verdict=approve stopped_by=none findings=[R1-F1:high,R2-F2:low] artifact_hash=9f9f9f9f at 2026-08-26T00:00:00Z: all good here'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R5F1_LEGIT")"
assert_eq "12.3a anti-overreach: reviewer_identity=sol-codex" "sol-codex" "$(printf '%s' "$GATE_OUT" | jq -r '.reviewer_identity')"
assert_eq "12.3b anti-overreach: artifact.model=claude-opus-5[1m] (bracket-bearing model value survives the HEAD/TAIL split)" \
    "claude-opus-5[1m]" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.model')"
assert_eq "12.3c anti-overreach: artifact.reviewer_pin=abc123" "abc123" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewer_pin')"
assert_eq "12.3d anti-overreach: artifact.reviewed_hash=7b8a0107cafefeed" "7b8a0107cafefeed" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewed_hash')"
assert_eq "12.3e anti-overreach: artifact.risk_threshold=high" "high" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.risk_threshold')"
assert_eq "12.3f anti-overreach: artifact.verdict=approve" "approve" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.verdict')"
assert_eq "12.3g anti-overreach: artifact.stopped_by=none" "none" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.stopped_by')"
assert_eq "12.3h anti-overreach: artifact.artifact_hash=9f9f9f9f (TAIL-scoped field, still correctly read)" \
    "9f9f9f9f" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.artifact_hash')"
assert_eq "12.3i anti-overreach: artifact.findings_token=R1-F1:high,R2-F2:low" \
    "R1-F1:high,R2-F2:low" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"
assert_eq "12.3j anti-overreach: exit 4 (R1-F1:high is at risk_threshold=high, genuinely open)" \
    "4" "$GATE_EXIT"
assert_eq "12.3k anti-overreach: open_finding_ids=[R1-F1] (R2-F2:low is below risk_threshold=high, correctly ignored)" \
    '["R1-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"

# 12.4 ANTI-OVERREACH: the BARE production shape (zero soft fields declared
# at all -- the live claude-workflow-plugin-fkm.1.1 six-record shape, see
# Section 11.8) must still parse cleanly: iteration correct, reviewer
# correctly refused as missing (not because of this fix -- true with or
# without it, since none was ever declared).
R5F1_BARE='REVIEW-ARTIFACT v1 iteration=5 findings=[] at 2026-08-01T00:00:00Z: nothing to report'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R5F1_BARE")"
assert_eq "12.4a anti-overreach BARE: reviewer_identity_missing (correctly refused -- no reviewer= was ever declared, same as pre-fix)" \
    "reviewer_identity_missing" "$(ekey_of "$GATE_OUT")"
assert_eq "12.4b anti-overreach BARE: artifact.iteration=5" "5" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.iteration')"

# 12.5 META: REVERT THE PARTITION, WATCH THE FORGERY RETURN. The textual
# change this fix made was redirecting nine extractors from $ART_PREFIX to
# $ART_PREFIX_HEAD and one (artifact_hash=) to $ART_PREFIX_TAIL -- see
# ART-PREFIX-PARTITION in review-check.sh. Reverting JUST those
# redirections, in a mutant copy, must bring the forgery back on the EXACT
# SAME 12.1 reproduction -- proving the partition itself (not some other,
# coincidental guard) is what is load-bearing.
#
# ALSO reverts ART_FINDINGS_LIST_RE to the pre-recurrence-5 denylist
# (claude-workflow-plugin-k6re, Section 14): recurrence 5's allowlist
# structurally excludes `=` from the bracket alphabet entirely, so on the
# UNMODIFIED shipped script this exact payload is now refused BEFORE the
# partition is ever consulted (see 12.1b/12.1g/12.1h above) -- reverting the
# partition ALONE, on TODAY's script, no longer reopens anything, because a
# newer, independent layer already blocks it. That is not this test's fault
# and not a reason to weaken it: to keep isolating the PARTITION specifically
# (proving IT remains necessary defense-in-depth, not merely redundant), this
# mutant neutralises recurrence 5's grammar too, one line, the same
# single-variable revert Section 14.4 uses -- so the payload reaches the
# partition logic on its own merits, exactly as it did before recurrence 5
# existed.
REVERT_PARTITION="$WORK/review-check-revert-r5f1-partition.sh"
# shellcheck disable=SC2016
sed -e 's/"\$ART_PREFIX_HEAD"/"\$ART_PREFIX"/g' -e 's/"\$ART_PREFIX_TAIL"/"\$ART_PREFIX"/g' \
    -e "s/^    ART_FINDINGS_LIST_RE=.*/    ART_FINDINGS_LIST_RE='[^][[:space:]]*'/" \
    "$RCHECK" > "$REVERT_PARTITION"
chmod +x "$REVERT_PARTITION"
assert_eq "12.5a META: the partition-revert mutation applied (mutant differs from source)" "differs" \
    "$(cmp -s "$RCHECK" "$REVERT_PARTITION" && echo identical || echo differs)"
assert_eq "12.5b META: mutated checker parses" "0" \
    "$(bash -n "$REVERT_PARTITION" 2>/dev/null && echo 0 || echo 1)"
printf '%s' "$(mk_comments "$R5F1_ATTACK")" > "$WORK/comments.json"
META_PARTITION_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVERT_PARTITION" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
assert_eq "12.5c META: WITHOUT the partition, the SAME 12.1 reproduction no longer trips REVIEWER-NONEMPTY-GUARD (error_key is not reviewer_identity_missing any more)" \
    "1" "$([ "$(ekey_of "$META_PARTITION_OUT")" != "reviewer_identity_missing" ] && echo 1 || echo 0)"
assert_eq "12.5d META: ...reviewer_identity reads back the FORGED sol-codex (the exact R5-F1 defect, reproduced)" \
    "sol-codex" "$(printf '%s' "$META_PARTITION_OUT" | jq -r '.reviewer_identity')"
assert_eq "12.5e META: ...artifact.risk_threshold reads back the FORGED low" \
    "low" "$(printf '%s' "$META_PARTITION_OUT" | jq -r '.artifact.risk_threshold')"
assert_eq "12.5f META: ...artifact.verdict reads back the FORGED approve" \
    "approve" "$(printf '%s' "$META_PARTITION_OUT" | jq -r '.artifact.verdict')"
assert_eq "12.5g META: ...artifact.reviewed_hash reads back the FORGED deadbeefdeadbeef" \
    "deadbeefdeadbeef" "$(printf '%s' "$META_PARTITION_OUT" | jq -r '.artifact.reviewed_hash')"
# Discriminator: the mutant still runs the real predicate elsewhere -- an
# ordinary, fully-declared record (12.3's fixture) parses IDENTICALLY on
# the mutant, proving the difference above is the partition and nothing
# else (the mutant did not simply break in some way that would make every
# field read back empty, or every record fail some other way).
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$R5F1_LEGIT")" > "$WORK/comments.json"
META_PARTITION_DISCRIM=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVERT_PARTITION" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
assert_eq "12.5h discriminator: the mutant still parses an ordinary fully-declared record identically (artifact.reviewed_hash=7b8a0107cafefeed)" \
    "7b8a0107cafefeed" "$(printf '%s' "$META_PARTITION_DISCRIM" | jq -r '.artifact.reviewed_hash')"
assert_eq "12.5i discriminator: ...artifact.artifact_hash=9f9f9f9f (TAIL field also unaffected on the legitimate path)" \
    "9f9f9f9f" "$(printf '%s' "$META_PARTITION_DISCRIM" | jq -r '.artifact.artifact_hash')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 13: k6re R7-F1 (independent review round 7) — findings=[...] cannot smuggle its OWN delimiter via a nested [ ==="
# R7-F1: Section 12 above (R5-F1) partitioned $ART_PREFIX so nine of ten
# extractors read from $ART_PREFIX_HEAD/$ART_PREFIX_TAIL, which structurally
# cannot contain a byte of the bracket. ART_FINDINGS is the TENTH -- the one
# extractor meant to read the bracket -- and its content class (before this
# fix) excluded only `]` and whitespace, PERMITTING a literal `[`. A finding
# value that itself contains the literal text "findings=[" plants a SECOND
# occurrence of that text inside $ART_PREFIX, and the anchored grammar closes
# the bracket at the FIRST `]` it meets -- the nested one, not the real one.
# See review-check.sh's ART-FINDINGS-EXTRACT comment for the full defect and
# fix.

# 13.1 THE REPRODUCTION, VERBATIM (Sol round 7, reproduced by the
# orchestrator before dispatch). A declared HIGH finding must never silently
# vanish -- the shipped script must REFUSE this record outright rather than
# report a clean review.
R7F1_CRAFTED='REVIEW-ARTIFACT v1 iteration=7 reviewer=example-name model=m pin=m reviewed_hash=abc risk_threshold=high verdict=findings stopped_by=verdict findings=[R7-F1:high,findings=[] at 2026-09-03T00:00:00Z: summary'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R7F1_CRAFTED")"
assert_eq "13.1a THE REPRODUCTION: exit 4, NOT the pre-fix silent exit 0" "4" "$GATE_EXIT"
assert_eq "13.1b ...error_key=review_artifact_malformed (refused outright, never unresolved_findings=0 masquerading as clean, never a bare clean approve)" \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"
assert_eq "13.1c ...ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"

# 13.2 CONTROL: the identical record WITHOUT the nested token parses
# correctly and reports the real open HIGH finding.
R7F1_CONTROL='REVIEW-ARTIFACT v1 iteration=7 reviewer=example-name model=m pin=m reviewed_hash=abc risk_threshold=high verdict=findings stopped_by=verdict findings=[R7-F1:high] at 2026-09-03T00:00:00Z: summary'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R7F1_CONTROL")"
assert_eq "13.2a CONTROL: exit 4 (the real open HIGH is reported)" "4" "$GATE_EXIT"
assert_eq "13.2b ...error_key=unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "13.2c ...open_finding_ids=[R7-F1]" '["R7-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"
assert_eq "13.2d ...artifact.findings_token=R7-F1:high" "R7-F1:high" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

# 13.3 ANTI-OVERREACH. The widened exclusion (`[` in addition to `]` and
# whitespace) must not disturb any legitimate shape: a multi-finding list, a
# record whose model=/pin= legitimately contain brackets (46w9) alongside a
# real finding, and the bare empty-findings shape (the live fkm.1.1 record
# shape, Section 11.8 above).
R7F1_MULTI='REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=m reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:high,R2-F2:medium] at 2026-08-30T10:00:00Z: two findings'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R7F1_MULTI")"
assert_eq "13.3a anti-overreach MULTI: open_finding_ids=[R1-F1] (R2-F2 is below risk_threshold=high, correctly ignored -- the multi-finding LIST ITSELF parses intact)" \
    '["R1-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"
assert_eq "13.3b ...artifact.findings_token=R1-F1:high,R2-F2:medium (both survive extraction byte-identical)" \
    "R1-F1:high,R2-F2:medium" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

R7F1_BRACKET_MODEL='REVIEW-ARTIFACT v1 iteration=3 reviewer=alice model=claude-opus-5[1m] pin=claude-opus-5[1m] reviewed_hash=deadbeef risk_threshold=high verdict=findings stopped_by=verdict findings=[R9-F1:low] artifact_hash=cafebabe at 2026-09-03T00:00:00Z: looks good'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R7F1_BRACKET_MODEL")"
assert_eq "13.3c anti-overreach BRACKET-MODEL: exit 0 (R9-F1 is below risk_threshold=high)" "0" "$GATE_EXIT"
assert_eq "13.3d ...artifact.model=claude-opus-5[1m] (46w9 bracket-bearing value survives the WIDENED exclusion)" \
    "claude-opus-5[1m]" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.model')"
assert_eq "13.3e ...artifact.reviewer_pin=claude-opus-5[1m]" \
    "claude-opus-5[1m]" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.reviewer_pin')"
assert_eq "13.3f ...artifact.findings_token=R9-F1:low (findings extraction unaffected by the bracket-bearing model/pin elsewhere on the same line)" \
    "R9-F1:low" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high '')")"
assert_eq "13.3g anti-overreach EMPTY: an ordinary empty-findings record (the live fkm.1.1 bare shape) is still clean (exit 0)" "0" "$GATE_EXIT"
assert_eq "13.3h ...artifact.findings_token is empty, not a stray artifact of the widened class" \
    "" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

# 13.4 META: REVERT THE WHOLE R7-F1 FIX, WATCH THE EXACT REPORTED SYMPTOM
# RETURN. The fix has two parts: (1) the findings content class, tightened
# (at R7-F1's time) in five hand-kept-consistent literal copies
# (ART-PARSE-SHARED) -- claude-workflow-plugin-k6re recurrence 5 (Section 14)
# later replaced those literals with ONE shared bash variable,
# ART_FINDINGS_LIST_RE, threaded through the same four awk invocations, so
# reverting "the R7-F1 content class" today means reverting that ONE
# variable's value to what it was pre-R7-F1 (`[^][:space:]]*`, excluding
# only `]` and whitespace, still permitting a literal `[`) rather than
# sed-substituting five dead literal copies; (2) the ART_FINDINGS
# extraction itself, rewritten from an unanchored sed scan to an anchored
# re-derivation, wrapped in ART-FINDINGS-EXTRACT BEGIN/END sentinels for
# exactly this purpose. swap_region below generalises Section 4b's
# strip_region: this fix REPLACES a mechanism rather than adding a guard
# beside one, so deleting the sentineled region outright (as strip_region
# does) would leave ART_FINDINGS permanently unset for EVERY record, not
# just the adversarial one, defeating the discriminator leg before it could
# run.
swap_region() {
    # swap_region <start-sentinel-literal> <end-sentinel-literal> <replacement-file> <in-file>
    awk -v startpat="$1" -v endpat="$2" -v replfile="$3" '
        index($0, startpat) { while ((getline rline < replfile) > 0) print rline; skip=1; next }
        index($0, endpat)   { skip=0; next }
        skip!=1 {print}
    ' "$4"
}
cat > "$WORK/pre-r7f1-extraction.txt" <<'PREFIXEOF'
    # ART_FINDINGS is the field R3-F1 was filed against: sed's leading `.*`
    # is GREEDY and prefers the LAST findings=[...] occurrence on a line, so
    # this command was never safe to run against anything wider than the
    # anchored prefix -- see ART-PREFIX-GUARD above for the measured
    # reproduction. $ART_PREFIX contains AT MOST one findings=[...]
    # occurrence by construction (art_prefix_len()'s own regex requires the
    # WHOLE prefix to match exactly once, end to end), so greedy-vs-leftmost
    # is no longer a live question here: there is only one occurrence left
    # to find.
    ART_FINDINGS=$(printf '%s' "$ART_PREFIX" | sed -nE 's/.*findings=\[([^]]*)\].*/\1/p' || true)
PREFIXEOF
STEP1_CONTENTCLASS="$WORK/review-check-step1-contentclass.sh"
sed "s/^    ART_FINDINGS_LIST_RE=.*/    ART_FINDINGS_LIST_RE='[^][:space:]]*'/" "$RCHECK" > "$STEP1_CONTENTCLASS"
REVERT_R7F1="$WORK/review-check-revert-r7f1-full.sh"
swap_region '# ART-FINDINGS-EXTRACT BEGIN' '# ART-FINDINGS-EXTRACT END' "$WORK/pre-r7f1-extraction.txt" "$STEP1_CONTENTCLASS" > "$REVERT_R7F1"
chmod +x "$REVERT_R7F1"
assert_eq "13.4a META: the full R7-F1 revert mutation applied (mutant differs from source)" "differs" \
    "$(cmp -s "$RCHECK" "$REVERT_R7F1" && echo identical || echo differs)"
assert_eq "13.4b META: mutated checker parses" "0" \
    "$(bash -n "$REVERT_R7F1" 2>/dev/null && echo 0 || echo 1)"
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$R7F1_CRAFTED")" > "$WORK/comments.json"
META_R7F1_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVERT_R7F1" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_R7F1_EXIT=$?
assert_eq "13.4c META: WITHOUT the fix, the SAME 13.1 crafted record wrongly passes (exit 0) -- the R7-F1 defect, reproduced" \
    "0" "$META_R7F1_EXIT"
assert_eq "13.4d META: ...ok=true (a clean review is reported)" \
    "true" "$(printf '%s' "$META_R7F1_OUT" | jq -r '.ok')"
assert_eq "13.4e META: ...open_findings silently drops to 0" \
    "0" "$(openct_of "$META_R7F1_OUT")"
assert_eq "13.4f META: ...artifact.findings_token reads back empty (the exact vanishing measured pre-fix)" \
    "" "$(printf '%s' "$META_R7F1_OUT" | jq -r '.artifact.findings_token')"
# Discriminator: the mutant still runs the real predicate on an ordinary,
# non-adversarial record -- proving the difference above is this fix and
# nothing else.
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$R7F1_CONTROL")" > "$WORK/comments.json"
META_R7F1_DISCRIM=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVERT_R7F1" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_R7F1_DISCRIM_EXIT=$?
assert_eq "13.4g discriminator: the mutant still catches an UNRELATED ordinary open finding (exit 4)" \
    "4" "$META_R7F1_DISCRIM_EXIT"
assert_eq "13.4h discriminator: ...open_finding_ids=[R7-F1] (the CONTROL fixture, unaffected by the revert)" \
    '["R7-F1"]' "$(printf '%s' "$META_R7F1_DISCRIM" | jq -c '.open_finding_ids')"

# 13.5 META: CONTENT-CLASS-ONLY REVERT (keep the shipped anchored
# extraction). Isolates the first half of the fix: even with the anchored
# re-derivation in place, an unwidened content class still lets the bracket
# close at the nested `]` instead of the real one. The anchor correctly
# locates the TRUE opening bracket (so R7-F1 is not lost outright this
# time), but the captured token is CORRUPTED -- it runs through the nested
# "findings=[" rather than stopping at the real close. Wrong is wrong
# whether or not it happens to be silent for this particular ordering; this
# is why the fix touches the content class, not merely the extractor.
# (Reverts ART_FINDINGS_LIST_RE to the pre-R7-F1 value -- see the 13.4
# comment above for why this is a single-variable revert since
# claude-workflow-plugin-k6re recurrence 5, not five literal copies.)
CONTENTCLASS_ONLY="$WORK/review-check-contentclass-only.sh"
sed "s/^    ART_FINDINGS_LIST_RE=.*/    ART_FINDINGS_LIST_RE='[^][:space:]]*'/" "$RCHECK" > "$CONTENTCLASS_ONLY"
chmod +x "$CONTENTCLASS_ONLY"
assert_eq "13.5a META: the content-class-only revert applied (mutant differs from source)" "differs" \
    "$(cmp -s "$RCHECK" "$CONTENTCLASS_ONLY" && echo identical || echo differs)"
assert_eq "13.5b META: mutated checker parses" "0" \
    "$(bash -n "$CONTENTCLASS_ONLY" 2>/dev/null && echo 0 || echo 1)"
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$R7F1_CRAFTED")" > "$WORK/comments.json"
META_CC_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$CONTENTCLASS_ONLY" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_CC_EXIT=$?
assert_eq "13.5c META: exit 4 either way (the content-class-only revert still blocks the crafted record on the real, corrupted-but-nonzero finding it now produces -- see 13.5d)" \
    "4" "$META_CC_EXIT"
assert_eq "13.5c2 META: ...but WHY it is 4 changes: without the content-class fix, the crafted record is no longer refused at SELECTION (via unresolved_findings this time, not review_artifact_malformed)" \
    "unresolved_findings" "$(ekey_of "$META_CC_OUT")"
assert_eq "13.5d META: ...artifact.findings_token is CORRUPTED (R7-F1:high,findings=[ -- not the clean R7-F1:high the CONTROL parses to), proving the anchor alone is not sufficient even though it happens not to be silent for this ordering" \
    "R7-F1:high,findings=[" "$(printf '%s' "$META_CC_OUT" | jq -r '.artifact.findings_token')"

# 13.6 META LEG-5 PIN: EXTRACTION-ONLY REVERT (keep the shipped, tightened
# content class; put back the ORIGINAL greedy sed as the extractor). This is
# the leg the task brief calls out by name: greediness direction was never
# the axis that mattered. If merely anchoring the extraction (independent of
# the content class) were what closed R7-F1, swapping the anchored
# extraction back out for the original unanchored, greedy one-liner would
# reopen it. It does not: the tightened content class already refuses the
# crafted record at SELECTION, before any extractor -- greedy, leftmost, or
# anchored -- ever runs against it.
EXTRACTION_ONLY="$WORK/review-check-extraction-only.sh"
swap_region '# ART-FINDINGS-EXTRACT BEGIN' '# ART-FINDINGS-EXTRACT END' "$WORK/pre-r7f1-extraction.txt" "$RCHECK" > "$EXTRACTION_ONLY"
chmod +x "$EXTRACTION_ONLY"
assert_eq "13.6a META: the extraction-only revert applied (mutant differs from source)" "differs" \
    "$(cmp -s "$RCHECK" "$EXTRACTION_ONLY" && echo identical || echo differs)"
assert_eq "13.6b META: mutated checker parses" "0" \
    "$(bash -n "$EXTRACTION_ONLY" 2>/dev/null && echo 0 || echo 1)"
assert_eq "13.6c META: the mutant genuinely restores the pre-fix GREEDY sed as the extractor, not merely a relabelled copy of the shipped one (the shipped anchored helper name is gone from this region)" "0" \
    "$(grep -c 'art_findings_open_len' "$EXTRACTION_ONLY")"
assert_eq "13.6c2 META: ...and the restored line is the literal pre-fix greedy sed one-liner" "1" \
    "$(grep -Fc "ART_FINDINGS=\$(printf '%s' \"\$ART_PREFIX\" | sed -nE 's/.*findings=\\[([^]]*)\\].*/\\1/p' || true)" "$EXTRACTION_ONLY")"
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$R7F1_CRAFTED")" > "$WORK/comments.json"
META_EO_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$EXTRACTION_ONLY" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
META_EO_EXIT=$?
assert_eq "13.6d META LEG-5: WITH the original greedy sed restored as the extractor, the crafted record STILL refuses (exit 4) -- greediness was never what protected this record" \
    "4" "$META_EO_EXIT"
assert_eq "13.6e META LEG-5: ...error_key=review_artifact_malformed (refused at SELECTION -- the extractor this mutant restored never even runs)" \
    "review_artifact_malformed" "$(ekey_of "$META_EO_OUT")"
# Discriminator: the mutant still parses an ordinary record correctly (the
# restored greedy sed is harmless on a $ART_PREFIX with only one findings=[
# occurrence, which is all a SELECTION-approved record can ever contain).
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$R7F1_CONTROL")" > "$WORK/comments.json"
META_EO_DISCRIM=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$EXTRACTION_ONLY" gate t-1 \
    --comments-json "$WORK/comments.json" 2>/dev/null)
assert_eq "13.6f discriminator: the mutant still parses an ordinary control record identically (findings_token=R7-F1:high)" \
    "R7-F1:high" "$(printf '%s' "$META_EO_DISCRIM" | jq -r '.artifact.findings_token')"

# ---------------------------------------------------------------------------
echo "=== Section 14: claude-workflow-plugin-k6re operator ruling (fifth recurrence) -- findings=[...] item grammar closes the glob / RESOLVED-grep / ARBITRATION-grep injection family in ONE ingest-side fix ==="
# Recurrence 5 of the review-artifact-parse-boundary defect family (see the
# ART-FINDINGS-ITEM-GRAMMAR comment in review-check.sh for the full defect,
# fix, and corpus evidence). R7-F1 (Section 13) excluded `[` from the
# findings=[...] content class, but the class remained a DENYLIST
# (`[^][[:space:]]*`) permitting every ERE metacharacter and every shell glob
# metacharacter. Three sinks downstream of ART_FINDINGS all trusted that
# content as inert:
#   (a) `IFS=','; for item in $ART_FINDINGS` (cmd_gate) is unquoted with no
#       `set -f` anywhere in this file -- PATHNAME EXPANSION against the
#       process's own CWD.
#   (b) `grep -E "^RESOLVED ${fid} " "$firstlines"` -- $fid unescaped in an ERE.
#   (c) `grep -E "^ARBITRATION ${fid} " "$firstlines"` -- the identical injection.
# The fix replaces the denylist with the ALLOWLIST validate-artifact already
# enforces (finding id ^R[0-9]+-F[0-9]+$, severity
# critical|high|medium|low|info), shared via ONE bash variable
# (ART_FINDINGS_LIST_RE) threaded through all four awk invocations exactly as
# ART_SOFT_FIELDS_RE already is -- so reverting the fix for the META below is
# a single-line mutation, not five hand-kept-consistent reverts.

# 14.1 THE REPRODUCTION, all three sinks, each independently.

# 14.1a SINK (b): grep -E "^RESOLVED ${fid} " -- a crafted fid=".*" matches
# ANY unrelated RESOLVED record and wrongly clears a real declared HIGH.
K6RE_R5_CRAFTED=$(art_line sol-codex high '.*:high')
K6RE_R5_UNRELATED_RESOLVED='RESOLVED R9-F9 at 2026-07-24T00:00:00Z: fix=unrelatedfix test=unrelatedtest'
run_gate "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_CRAFTED" "$K6RE_R5_UNRELATED_RESOLVED")"
assert_eq "14.1a SINK-b (RESOLVED grep injection): exit 4, refused BEFORE the RESOLVED grep ever runs" "4" "$GATE_EXIT"
assert_eq "14.1a ...error_key=review_artifact_malformed (not unresolved_findings, not a clean approve)" \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"
assert_eq "14.1a ...ok=false" "false" "$(printf '%s' "$GATE_OUT" | jq -r '.ok')"

# 14.1b SINK (c): grep -E "^ARBITRATION ${fid} " -- identical injection, and
# needs only ONE decision=overrule record with no fix=/test= corroboration.
K6RE_R5_UNRELATED_ARBITRATION='ARBITRATION R9-F9 at 2026-07-24T00:00:00Z: decision=overrule'
run_gate "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_CRAFTED" "$K6RE_R5_UNRELATED_ARBITRATION")"
assert_eq "14.1b SINK-c (ARBITRATION grep injection): exit 4, refused BEFORE the ARBITRATION grep ever runs" "4" "$GATE_EXIT"
assert_eq "14.1b ...error_key=review_artifact_malformed" "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"

# 14.1c SINK (a): IFS=','; for item in $ART_FINDINGS -- unquoted, no set -f,
# so a findings=[*:high] value undergoes pathname expansion against the
# process's CWD. Plant a file that glob-matches to prove the mechanism is
# live, then confirm the SHIPPED script never reaches it: refused at
# selection regardless of what the CWD contains.
K6RE_R5_GLOBDIR="$WORK/k6re-r5-glob"
mkdir -p "$K6RE_R5_GLOBDIR"
: > "$K6RE_R5_GLOBDIR/a:b:high"
K6RE_R5_GLOB_ART=$(art_line sol-codex high '*:high')
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_GLOB_ART")" > "$K6RE_R5_GLOBDIR/comments.json"
K6RE_R5_GLOB_OUT=$(cd "$K6RE_R5_GLOBDIR" && CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$RCHECK" gate t-1 --comments-json "$K6RE_R5_GLOBDIR/comments.json" 2>/dev/null)
K6RE_R5_GLOB_EXIT=$?
assert_eq "14.1c SINK-a (glob expansion): exit 4 even with a glob-matching file (a:b:high) present in CWD" "4" "$K6RE_R5_GLOB_EXIT"
assert_eq "14.1c ...error_key=review_artifact_malformed (refused before the unquoted for-loop ever iterates)" \
    "review_artifact_malformed" "$(ekey_of "$K6RE_R5_GLOB_OUT")"

# 14.2 CONTROL: an ordinary, non-adversarial multi-item findings list is
# untouched -- the correct open finding is still reported, at the correct id.
K6RE_R5_CONTROL=$(art_line sol-codex high 'R1-F1:high,R2-F2:medium,R3-F3:low')
run_gate "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_CONTROL")"
assert_eq "14.2a CONTROL: exit 4 (the real open HIGH is reported)" "4" "$GATE_EXIT"
assert_eq "14.2b ...error_key=unresolved_findings" "unresolved_findings" "$(ekey_of "$GATE_OUT")"
assert_eq "14.2c ...open_finding_ids=[R1-F1] (R2-F2/R3-F3 correctly below risk_threshold=high)" \
    '["R1-F1"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"
assert_eq "14.2d ...artifact.findings_token unchanged, byte-identical to the declared list" \
    "R1-F1:high,R2-F2:medium,R3-F3:low" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.findings_token')"

# 14.3 ANTI-OVERREACH: every legitimate shape the new allowlist must still
# accept, and one illegitimate shape (a misspelled severity) it correctly
# refuses -- proving the class is neither too loose (14.1 already proved
# that direction) nor too tight.
run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line qa-claude high '')")"
assert_eq "14.3a anti-overreach EMPTY: findings=[] (the majority live shape) still clean (exit 0)" "0" "$GATE_EXIT"

run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line qa-claude info 'R1-F1:critical,R2-F2:high,R3-F3:medium,R4-F4:low,R5-F5:info')")"
assert_eq "14.3b anti-overreach ALL FIVE SEVERITIES: every enum word accepted in one list (exit 4, all five open at risk_threshold=info)" \
    "4" "$GATE_EXIT"
assert_eq "14.3c ...open_findings=5" "5" "$(openct_of "$GATE_OUT")"

run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high 'R007-F007:high')")"
assert_eq "14.3d anti-overreach LEADING ZEROS: R007-F007 (matches validate-artifact's own ^R[0-9]+-F[0-9]+\$, leading zeros are legal digits) exit 4" "4" "$GATE_EXIT"
assert_eq "14.3e ...open_finding_ids=[R007-F007]" '["R007-F007"]' "$(printf '%s' "$GATE_OUT" | jq -c '.open_finding_ids')"

R7F1_BRACKET_MODEL_R5='REVIEW-ARTIFACT v1 iteration=3 reviewer=alice model=claude-opus-5[1m] pin=claude-opus-5[1m] reviewed_hash=deadbeef risk_threshold=high verdict=findings stopped_by=verdict findings=[R9-F1:low] artifact_hash=cafebabe at 2026-09-03T00:00:00Z: looks good'
run_gate "$(mk_comments "$IMPL_BACKEND" "$R7F1_BRACKET_MODEL_R5")"
assert_eq "14.3f anti-overreach BRACKET-MODEL re-affirmed under the new findings grammar: exit 0" "0" "$GATE_EXIT"
assert_eq "14.3g ...artifact.model=claude-opus-5[1m] (46w9 class untouched by this fix)" \
    "claude-opus-5[1m]" "$(printf '%s' "$GATE_OUT" | jq -r '.artifact.model')"

run_gate "$(mk_comments "$IMPL_BACKEND" "$(art_line sol-codex high 'R1-F1:critikal')")"
assert_eq "14.3h anti-overreach MISSPELLED SEVERITY: 'critikal' is not in the enum, correctly refused (exit 4)" "4" "$GATE_EXIT"
assert_eq "14.3i ...error_key=review_artifact_malformed (not silently read as an unknown/below-threshold severity)" \
    "review_artifact_malformed" "$(ekey_of "$GATE_OUT")"

# 14.4 META: REVERT THE FIX (one line -- ART_FINDINGS_LIST_RE is a SINGLE
# shared bash variable threaded through all four awk invocations, so
# reverting its value alone reopens every one of the three sinks
# simultaneously; this IS the maintainability property the shared-variable
# refactor was chosen for over six independently-edited literal copies).
K6RE_R5_REVERT="$WORK/review-check-k6re-r5-revert.sh"
sed "s/^    ART_FINDINGS_LIST_RE=.*/    ART_FINDINGS_LIST_RE='[^][[:space:]]*'/" "$RCHECK" > "$K6RE_R5_REVERT"
chmod +x "$K6RE_R5_REVERT"
assert_eq "14.4a META: the revert mutation applied (mutant differs from source)" "differs" \
    "$(cmp -s "$RCHECK" "$K6RE_R5_REVERT" && echo identical || echo differs)"
assert_eq "14.4b META: mutated checker parses" "0" \
    "$(bash -n "$K6RE_R5_REVERT" 2>/dev/null && echo 0 || echo 1)"
assert_eq "14.4c META: the mutation touches EXACTLY the one grammar-declaration line, nothing else" "1" \
    "$(diff "$RCHECK" "$K6RE_R5_REVERT" | grep -c '^<')"

# 14.4d/e/f: sink (b) reopens.
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_CRAFTED" "$K6RE_R5_UNRELATED_RESOLVED")" > "$WORK/comments.json"
META_R5_B_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$K6RE_R5_REVERT" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_R5_B_EXIT=$?
assert_eq "14.4d META SINK-b: WITHOUT the fix, the crafted findings=[.*:high] + unrelated RESOLVED wrongly clears (exit 0)" \
    "0" "$META_R5_B_EXIT"
assert_eq "14.4e META SINK-b: ...ok=true (a clean review is wrongly reported)" \
    "true" "$(printf '%s' "$META_R5_B_OUT" | jq -r '.ok')"
assert_eq "14.4f META SINK-b: ...open_findings silently drops to 0 (the exact vanishing measured pre-fix)" \
    "0" "$(openct_of "$META_R5_B_OUT")"

# 14.4g/h: sink (c) reopens.
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_CRAFTED" "$K6RE_R5_UNRELATED_ARBITRATION")" > "$WORK/comments.json"
META_R5_C_OUT=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$K6RE_R5_REVERT" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
META_R5_C_EXIT=$?
assert_eq "14.4g META SINK-c: WITHOUT the fix, the crafted findings=[.*:high] + unrelated ARBITRATION overrule wrongly clears (exit 0)" \
    "0" "$META_R5_C_EXIT"
assert_eq "14.4h META SINK-c: ...open_findings silently drops to 0" "0" "$(openct_of "$META_R5_C_OUT")"

# 14.4i/j: sink (a) reopens (same glob-planted directory as 14.1c).
META_R5_A_OUT=$(cd "$K6RE_R5_GLOBDIR" && CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$K6RE_R5_REVERT" gate t-1 --comments-json "$K6RE_R5_GLOBDIR/comments.json" 2>/dev/null)
META_R5_A_EXIT=$?
assert_eq "14.4i META SINK-a: WITHOUT the fix, findings=[*:high] in a CWD containing a:b:high wrongly clears (exit 0)" \
    "0" "$META_R5_A_EXIT"
assert_eq "14.4j META SINK-a: ...open_findings silently drops to 0 (the declared HIGH vanishes via glob expansion)" \
    "0" "$(openct_of "$META_R5_A_OUT")"

# Discriminator: the mutant still catches an ORDINARY unrelated open finding
# -- proving 14.4d-j measure this fix and nothing else (a mutant that always
# reports clean regardless of input would trivially pass 14.4 too).
printf '%s' "$(mk_comments "$IMPL_BACKEND" "$K6RE_R5_CONTROL")" > "$WORK/comments.json"
META_R5_DISCRIM=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$K6RE_R5_REVERT" gate t-1 --comments-json "$WORK/comments.json" 2>/dev/null)
assert_eq "14.4k discriminator: the mutant still reports the real open HIGH on the CONTROL fixture" \
    '["R1-F1"]' "$(printf '%s' "$META_R5_DISCRIM" | jq -c '.open_finding_ids')"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
