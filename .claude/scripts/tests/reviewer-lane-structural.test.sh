#!/bin/bash
# reviewer-lane-structural.test.sh — L1 unit fixture for correction 10's
# STRUCTURAL guard (claude-workflow-plugin-icn4 item 1), hoisted out of the L2
# component spec .claude/tests/component/specs/reviewer-lane-degradation.sh.
#
# WHY THIS MOVED HERE. The structural guard is three greps plus one META
# injection — no fixture, no Beads, done in well under a second. It shipped
# bundled into the L2 component tier, a RESERVED tier that runs at
# ~65-minutes-per-invocation cadence, not on every `make test`. QA measured
# (claude-workflow-plugin-icn4, from j7kk QA round 2) that a correction-10
# violation survived FOUR green verification passes and two commits precisely
# because the only guard that could see it lived at that cadence — "guard
# cadence must be at least violation cadence." The BEHAVIOURAL half (stub
# Codex MCP server, byte-identical-output diff across lane conditions) stays
# in the L2 file, where the fixture scaffolding it actually needs lives.
#
# THE INVARIANT (correction 10, docs/plans/v5-design-phase*.md, "Sol-first
# must never touch the three gate scripts"): qa-gate.sh, verify-before-stop.sh
# and review-check.sh must contain zero references to codex or the reviewer
# lane. Lane selection is prompt/statusline-side only — the orchestrator's
# relay step reads codex-detect.sh status — because a gate that reasons about
# model/lane selection acquires a second, invisible way to refuse
# (model-select.sh:1339).
#
# THE PATTERN, AND WHY IT CHANGED (claude-workflow-plugin-mruw). The
# originally-shipped pattern, `codex|reviewer[._]lane`, requires a LITERAL '.'
# or '_' immediately between the two words — so the natural, space-separated
# phrase "reviewer lane" was NOT a match (this very guard's own former header,
# and both plan docs' correction 10, used that exact phrase in prose without
# ever remarking that it was safe only because of this narrow reading), and
# the hyphenated form in this file's own former name never was either. mruw
# measured that gap and this file resolves it by WIDENING rather than merely
# documenting: LANE_GUARD_PATTERN below matches "reviewer"+"lane" separated by
# zero or more of space/dot/underscore/hyphen (strictly a superset of the old
# pattern — nothing previously caught stops being caught), plus the
# unconditional bare "codex" tripwire, unchanged. The one place the widened
# pattern newly tripped was reworded, not exempted (qa-gate.sh's "the Claude
# reviewer lane" -> "Claude's own in-session review"), the same discipline
# v9dx applied to its own two catches: preserve the information, drop the
# token, never loosen the guard.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement" — four legs per
# check; TWO checks share this file, each gets its own):
#
#   ITEM 1 (the hoist itself) —
#     1 NON-VACUITY  section A2: inject a bare "codex" token into a COPY of
#                    review-check.sh and assert the injection landed.
#     2 MISBEHAVIOUR section A2: the same grep run against that copy trips
#                    (nonzero), naming the "has zero codex/reviewer-lane
#                    references" assertion it would fail.
#     3 RESTORE      section A1: the grep run against the REAL shipped files
#                    reads 0.
#     4 EXECUTION    section C (shared with item 2 below).
#
#   ITEM 2 (mruw's widened pattern) —
#     1 NON-VACUITY  section B: inject a SPACE-separated "reviewer lane" (no
#                    codex, no dot/underscore) into a fresh copy and assert
#                    the injection landed.
#     2 MISBEHAVIOUR section B: demonstrate BOTH halves of the fix in one
#                    place — the OLD/narrow pattern reads 0 on that injection
#                    (the historical gap, reproduced on demand) and the
#                    NEW/WIDENED pattern reads nonzero on the SAME bytes (the
#                    fix closing it).
#     3 RESTORE      section A1: the REAL shipped files read 0 under the NEW
#                    pattern too (post-reword).
#     4 EXECUTION    section C: each shipped script is actually RUN in its
#                    cheapest side-effect-free, bd-independent invocation
#                    (qa-gate.sh / review-check.sh with no args -> usage() to
#                    stderr, exit 1; verify-before-stop.sh fed
#                    `stop_hook_active:true` -> the AgentLint H3 circuit
#                    breaker, `{}`, exit 0 — all three empirically confirmed
#                    side-effect-free and bd-free), and the SAME widened
#                    pattern is run over the CAPTURED RUNTIME OUTPUT: a source
#                    clean of the token could still print it at runtime (a
#                    concatenated string, a sourced constant, an env-derived
#                    message) — this is what actually observes the shipped
#                    artifact RUNNING clean, not merely sitting clean on disk.
#
# Offline. No bd dependency anywhere in this file — the L1 store canary in
# run-tests.sh cannot fire on a spec that never calls bd — and no fixture
# scaffolding, which is the entire reason this costs seconds, not minutes.
#
# Exit codes: 0 all pass / 1 any fail / 2 invocation error (missing script)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPTS_DIR="$PROJECT_DIR/.claude/scripts"
QAGATE="$SCRIPTS_DIR/qa-gate.sh"
VBS="$SCRIPTS_DIR/verify-before-stop.sh"
RCHECK="$SCRIPTS_DIR/review-check.sh"

# The ONE canonical pattern. Every "is the shipped state clean" assertion in
# this file reads this constant — never a re-typed literal — so there is
# exactly one place to widen again if a future spelling slips through.
LANE_GUARD_PATTERN='codex|reviewer[[:space:]_.-]*lane'
# The RETIRED pattern, kept ONLY for section B's before/after demonstration
# of what mruw's widening actually changed. Never used to judge real files.
LANE_GUARD_PATTERN_PRE_MRUW='codex|reviewer[._]lane'

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

for f in "$QAGATE" "$VBS" "$RCHECK"; do
    if [ ! -f "$f" ]; then
        printf 'reviewer-lane-structural.test: script under test missing: %s\n' "$f" >&2
        exit 2
    fi
done

WORK=$(mktemp -d -t reviewer-lane-structural.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# A1. STRUCTURAL (item 1's RESTORE control / item 2's RESTORE control): the
# three gate-critical scripts are clean under the CURRENT (widened) pattern.
GATE_SCRIPTS="qa-gate.sh verify-before-stop.sh review-check.sh"
for f in $GATE_SCRIPTS; do
    CNT=$(grep -cEi "$LANE_GUARD_PATTERN" "$SCRIPTS_DIR/$f" 2>/dev/null || true)
    [ -z "$CNT" ] && CNT=0
    assert_eq "structural: $f has zero codex/reviewer-lane references (any spelling)" "0" "$CNT"
done

# ---------------------------------------------------------------------------
# A2. META for item 1 (NON-VACUITY + MISBEHAVIOUR): inject a bare "codex"
# reference into a COPY and confirm both that the injection landed and that
# the same grep the structural assertions use trips on it.
INJECTED_CODEX="$WORK/review-check-codex-injected.sh"
cp "$RCHECK" "$INJECTED_CODEX"
INJECT_LINE_CODEX='# reviewer_lane hook for codex (deliberate injection for the META test)'
printf '\n%s\n' "$INJECT_LINE_CODEX" >> "$INJECTED_CODEX"

INJECT_LANDED_CNT=$(grep -cF "$INJECT_LINE_CODEX" "$INJECTED_CODEX" 2>/dev/null || true)
[ -z "$INJECT_LANDED_CNT" ] && INJECT_LANDED_CNT=0
assert_eq "item1 META non-vacuity: the codex injection landed in the copy" "1" "$INJECT_LANDED_CNT"

INJ_CODEX_CNT=$(grep -cEi "$LANE_GUARD_PATTERN" "$INJECTED_CODEX" 2>/dev/null || true)
[ -z "$INJ_CODEX_CNT" ] && INJ_CODEX_CNT=0
assert_eq "item1 META misbehaviour: 'structural: has zero codex/reviewer-lane references' would now FAIL (nonzero count)" \
    "yes" "$([ "$INJ_CODEX_CNT" -gt 0 ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# B. META for item 2 (mruw's widening) — NON-VACUITY + MISBEHAVIOUR as a
# before/after pair. A fresh copy gets a SPACE-separated "reviewer lane"
# injection carrying NEITHER "codex" NOR a dot/underscore separator — the
# exact shape that used to slip through (qa-gate.sh:4881, pre-fix: "the
# Claude reviewer lane").
INJECTED_SPACE="$WORK/review-check-space-injected.sh"
cp "$RCHECK" "$INJECTED_SPACE"
INJECT_LINE_SPACE='# the reviewer lane must stay clear of these three files (deliberate injection for the META test)'
printf '\n%s\n' "$INJECT_LINE_SPACE" >> "$INJECTED_SPACE"

INJECT_LANDED_SPACE_CNT=$(grep -cF "$INJECT_LINE_SPACE" "$INJECTED_SPACE" 2>/dev/null || true)
[ -z "$INJECT_LANDED_SPACE_CNT" ] && INJECT_LANDED_SPACE_CNT=0
assert_eq "item2 META non-vacuity: the space-separated injection landed in the copy" "1" "$INJECT_LANDED_SPACE_CNT"

# Sanity: the injected line must NOT contain the bare "codex" token, or this
# fixture would trip the OLD pattern too and prove nothing about the widening
# specifically.
SANITY_CODEX_CNT=$(grep -cEi 'codex' "$INJECTED_SPACE" 2>/dev/null || true)
[ -z "$SANITY_CODEX_CNT" ] && SANITY_CODEX_CNT=0
assert_eq "item2 META sanity: the space-separated injection contains no 'codex' token (isolates the widening from the unconditional tripwire)" \
    "0" "$SANITY_CODEX_CNT"

OLD_CNT=$(grep -cEi "$LANE_GUARD_PATTERN_PRE_MRUW" "$INJECTED_SPACE" 2>/dev/null || true)
[ -z "$OLD_CNT" ] && OLD_CNT=0
assert_eq "item2 META misbehaviour (BEFORE): the RETIRED pre-mruw pattern misses the space-separated phrase (the historical gap, reproduced on demand)" \
    "0" "$OLD_CNT"

NEW_CNT=$(grep -cEi "$LANE_GUARD_PATTERN" "$INJECTED_SPACE" 2>/dev/null || true)
[ -z "$NEW_CNT" ] && NEW_CNT=0
assert_eq "item2 META misbehaviour (AFTER): the WIDENED pattern catches the same bytes the retired pattern missed" \
    "yes" "$([ "$NEW_CNT" -gt 0 ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# C. EXECUTION (leg 4, shared by items 1 and 2): drive the ACTUAL shipped
# scripts running, in their cheapest side-effect-free, bd-independent
# invocation, and extend the SAME widened pattern to their RUNTIME output —
# proving the running artifact is clean, not only its bytes at rest.
#
# Each invocation and its exit code was verified empirically before this file
# was written (qa-gate.sh / review-check.sh with no args exit 1 via their
# documented usage() path; verify-before-stop.sh with stop_hook_active=true
# exits 0 via the documented AgentLint H3 circuit breaker at ~line 2640,
# BEFORE any bd call or test/lint invocation). NOT quite "before any file
# write", though: the unconditional `mkdir -p "$QA_TRACKING_DIR"` at
# verify-before-stop.sh:86 runs first regardless of stop_hook_active — a
# no-op wherever that directory already exists (every standard harness
# context, including the invocation below: $PROJECT_DIR here is
# repo-root-derived, so the dir pre-exists), but a real side effect from a
# foreign cwd with CLAUDE_PROJECT_DIR unset (probed directly —
# claude-workflow-plugin-icn4 R1-F2). The leg itself is unaffected: this
# file's own full run writes zero repo files (`find -newer` marker empty)
# and leaves .beads untouched.
QAGATE_OUT="$WORK/qa-gate-noarg.out"
qa_gate_rc=0
bash "$QAGATE" >"$QAGATE_OUT" 2>&1 || qa_gate_rc=$?
assert_eq "execution: qa-gate.sh with no args runs its real usage() path (exit 1)" "1" "$qa_gate_rc"
QAGATE_OUT_CNT=$(grep -cEi "$LANE_GUARD_PATTERN" "$QAGATE_OUT" 2>/dev/null || true)
[ -z "$QAGATE_OUT_CNT" ] && QAGATE_OUT_CNT=0
assert_eq "execution: qa-gate.sh's RUNTIME usage output has zero codex/reviewer-lane references" "0" "$QAGATE_OUT_CNT"

RCHECK_OUT="$WORK/review-check-noarg.out"
rcheck_rc=0
bash "$RCHECK" >"$RCHECK_OUT" 2>&1 || rcheck_rc=$?
assert_eq "execution: review-check.sh with no args runs its real usage path (exit 1)" "1" "$rcheck_rc"
RCHECK_OUT_CNT=$(grep -cEi "$LANE_GUARD_PATTERN" "$RCHECK_OUT" 2>/dev/null || true)
[ -z "$RCHECK_OUT_CNT" ] && RCHECK_OUT_CNT=0
assert_eq "execution: review-check.sh's RUNTIME usage output has zero codex/reviewer-lane references" "0" "$RCHECK_OUT_CNT"

VBS_OUT="$WORK/vbs-circuit.out"
vbs_rc=0
printf '{"stop_hook_active": true}\n' | bash "$VBS" >"$VBS_OUT" 2>&1 || vbs_rc=$?
assert_eq "execution: verify-before-stop.sh with stop_hook_active=true runs the real AgentLint H3 circuit breaker (exit 0)" "0" "$vbs_rc"
assert_eq "execution: verify-before-stop.sh's circuit-breaker output is exactly {}" "{}" "$(cat "$VBS_OUT" 2>/dev/null)"
VBS_OUT_CNT=$(grep -cEi "$LANE_GUARD_PATTERN" "$VBS_OUT" 2>/dev/null || true)
[ -z "$VBS_OUT_CNT" ] && VBS_OUT_CNT=0
assert_eq "execution: verify-before-stop.sh's RUNTIME circuit-breaker output has zero codex/reviewer-lane references" "0" "$VBS_OUT_CNT"

# ---------------------------------------------------------------------------
if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0
