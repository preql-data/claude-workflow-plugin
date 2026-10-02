#!/bin/bash
# approve-success-gate.test.sh — L1 unit fixture for the structural half of
# claude-workflow-plugin-k6re R6-F2 (the STRUCTURAL chokepoint fix, hoisted
# out of the L2 component spec .claude/tests/component/specs/
# approve-idempotency.sh Section J/JM the same way reviewer-lane-
# structural.test.sh hoisted correction 10's guard out of an L2 spec: this
# is pure grep/text-injection, no fixture, no bd, no git — seconds, not
# minutes — and the BEHAVIOURAL half (does a real `qa-gate.sh approve`
# actually refuse a mismatched --expect-hash on the idempotent no-op path)
# stays in the L2 file, where the fixture scaffolding it needs already
# lives).
#
# THE INVARIANT THIS PINS. cmd_approve has exactly TWO success-reporting
# exits (the hash-aware idempotency no-op, and the fresh-approval path at
# the end of the function). R6-F2 found that the FIRST of those had, for the
# SECOND time (the first was A2/i8cx, over compute_design_conflict_open),
# skipped a precondition that must hold on every path reporting
# status=approved: --expect-hash. The fix (emit_approve_success,
# APPROVE-SUCCESS-GATE in qa-gate.sh, immediately above cmd_approve) makes
# this structural rather than a third hand-copied guard: `emit_json 1
# "approve" "$tid" "approved" ...` — the raw envelope print — now appears
# EXACTLY ONCE in the whole script, inside emit_approve_success itself.
# Every success-reporting exit calls that function instead of printing
# directly. A future THIRD exit added straight to cmd_approve, bypassing the
# gate, changes the raw-emit count from 1 to 2+ and is caught here.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement"):
#   1 NON-VACUITY  section B: inject a raw, gate-bypassing success emission
#                  into a COPY and assert the injection landed.
#   2 MISBEHAVIOUR section B: the SAME grep the structural assertions use
#                  now reads 2, not 1 — i.e. section A's invariant WOULD
#                  have caught exactly the shape a fifth reach-around of
#                  this arm would take (a new exit that never calls the
#                  gate).
#   3 RESTORE      section A: the REAL shipped qa-gate.sh reads 1/2 (raw
#                  emit / gate calls) right now.
#   4 EXECUTION    section C: qa-gate.sh is actually RUN (its cheapest
#                  side-effect-free, bd-independent invocation — no args,
#                  usage() to stderr, exit 1, the same invocation
#                  reviewer-lane-structural.test.sh's own execution leg
#                  uses) and the SAME raw-emit pattern is checked against
#                  neither being printed at the top-level usage text — the
#                  usage text documents the FLAG, not the envelope shape, so
#                  this also confirms usage() does not itself contain a
#                  literal success emission masquerading as documentation.
#
# THE BEHAVIOURAL PROOF — real approve calls, a real mismatch, a real
# refusal, plus the anchor-revert META that strips the check inside
# emit_approve_success and watches the R6-F2 forgery reproduce end to end —
# is approve-idempotency.sh Section J (the fresh proof) and Section JM (the
# META). Nothing here duplicates that; this file is deliberately blind to
# whether the CHECK inside the gate is correct, only to whether the gate is
# the sole route to a success envelope.
#
# Offline. No bd dependency anywhere in this file (matches reviewer-lane-
# structural.test.sh's own offline convention) — the L1 store canary in
# run-tests.sh cannot fire on a spec that never calls bd.
#
# Exit codes: 0 all pass / 1 any fail / 2 invocation error (missing script)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SCRIPTS_DIR="$PROJECT_DIR/.claude/scripts"
QAGATE="$SCRIPTS_DIR/qa-gate.sh"

# The two canonical patterns every assertion in this file reads — never a
# re-typed literal — so there is exactly one place to update either if
# emit_approve_success's own call shape ever changes. Single-quoted on
# purpose: these are grep patterns matching qa-gate.sh's SOURCE BYTES
# (literal `"$tid"`), never meant to expand in THIS shell.
# shellcheck disable=SC2016
RAW_EMIT_PATTERN='emit_json 1 "approve" "\$tid" "approved"'
# shellcheck disable=SC2016
GATE_CALL_PATTERN='emit_approve_success "\$tid"'

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

if [ ! -f "$QAGATE" ]; then
    printf 'approve-success-gate.test: script under test missing: %s\n' "$QAGATE" >&2
    exit 2
fi

WORK=$(mktemp -d -t approve-success-gate.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# A. STRUCTURAL (item's RESTORE control): the shipped script has EXACTLY one
# raw success emission (inside emit_approve_success) and EXACTLY two calls
# into the gate (the idempotent no-op, and the fresh-approval path).
RAW_CNT=$(grep -cE "$RAW_EMIT_PATTERN" "$QAGATE" 2>/dev/null || true)
[ -z "$RAW_CNT" ] && RAW_CNT=0
assert_eq "structural: qa-gate.sh prints a raw status=approved envelope for 'approve' in exactly ONE place (inside emit_approve_success)" \
    "1" "$RAW_CNT"

GATE_CNT=$(grep -cE "$GATE_CALL_PATTERN" "$QAGATE" 2>/dev/null || true)
[ -z "$GATE_CNT" ] && GATE_CNT=0
assert_eq "structural: qa-gate.sh calls emit_approve_success in exactly TWO places (the idempotent no-op, and the fresh-approval path)" \
    "2" "$GATE_CNT"

# The function itself must exist and be defined exactly once — a future
# rename or accidental duplicate definition would make the two counts above
# pass for the wrong reason (grep matching call sites of a DIFFERENT
# function that happens to share a name fragment).
DEF_CNT=$(grep -cE '^emit_approve_success\(\) \{' "$QAGATE" 2>/dev/null || true)
[ -z "$DEF_CNT" ] && DEF_CNT=0
assert_eq "structural: emit_approve_success is defined exactly once" "1" "$DEF_CNT"

# ---------------------------------------------------------------------------
# B. META (NON-VACUITY + MISBEHAVIOUR): inject a raw, gate-bypassing success
# emission into a COPY — simulating exactly the shape a FIFTH reach-around
# of the idempotency arm would take (a new exit added straight to
# cmd_approve instead of through emit_approve_success) — and confirm both
# that the injection landed and that section A's own invariant would have
# caught it.
INJECTED="$WORK/qa-gate-thirdbypass.sh"
cp "$QAGATE" "$INJECTED"
# Single-quoted on purpose: `$tid` must land in the injected COPY as the
# literal 4 characters, matching the shape a real (bypassing) call site
# would have — not expand against this shell's (unset) $tid.
# shellcheck disable=SC2016
INJECT_LINE='    emit_json 1 "approve" "$tid" "approved" "k6re approve-success-gate.test.sh META: a gate-bypassing success emission (never actually reached — text-only injection)"'
printf '\n%s\n' "$INJECT_LINE" >> "$INJECTED"

INJECT_LANDED_CNT=$(grep -cF "$INJECT_LINE" "$INJECTED" 2>/dev/null || true)
[ -z "$INJECT_LANDED_CNT" ] && INJECT_LANDED_CNT=0
assert_eq "META non-vacuity: the gate-bypassing injection landed in the copy" "1" "$INJECT_LANDED_CNT"

if cmp -s "$QAGATE" "$INJECTED"; then
    assert_eq "META: mutant applied (differs from its source)" "differs" "identical"
else
    assert_eq "META: mutant applied (differs from its source)" "differs" "differs"
fi

INJ_RAW_CNT=$(grep -cE "$RAW_EMIT_PATTERN" "$INJECTED" 2>/dev/null || true)
[ -z "$INJ_RAW_CNT" ] && INJ_RAW_CNT=0
assert_eq "META misbehaviour: injecting a bypass flips the raw-emit count from 1 to 2 — section A's invariant WOULD catch a fifth reach-around of this exact shape" \
    "2" "$INJ_RAW_CNT"
assert_eq "META misbehaviour: ...i.e. 'exactly ONE raw success emission' would now FAIL" \
    "yes" "$([ "$INJ_RAW_CNT" -ne 1 ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# C. EXECUTION (leg 4): drive the ACTUAL shipped script running, in its
# cheapest side-effect-free, bd-independent invocation, and confirm the raw
# success pattern is not somehow ALSO present in the runtime usage() text —
# usage() documents the --expect-hash FLAG (a legitimate, expected mention
# of "approve" and "approved" in prose), never a literal envelope print, so
# this also guards against the invariant's own grep pattern drifting to
# match documentation instead of code.
QAGATE_OUT="$WORK/qa-gate-noarg.out"
qa_gate_rc=0
bash "$QAGATE" >"$QAGATE_OUT" 2>&1 || qa_gate_rc=$?
assert_eq "execution: qa-gate.sh with no args runs its real usage() path (exit 1)" "1" "$qa_gate_rc"

USAGE_RAW_CNT=$(grep -cE "$RAW_EMIT_PATTERN" "$QAGATE_OUT" 2>/dev/null || true)
[ -z "$USAGE_RAW_CNT" ] && USAGE_RAW_CNT=0
assert_eq "execution: qa-gate.sh's RUNTIME usage() output contains no literal success-envelope print" "0" "$USAGE_RAW_CNT"

USAGE_MENTIONS_FLAG=$(grep -c -- '--expect-hash' "$QAGATE_OUT" 2>/dev/null || true)
[ -z "$USAGE_MENTIONS_FLAG" ] && USAGE_MENTIONS_FLAG=0
assert_eq "execution: ...while still documenting --expect-hash (the usage text is not accidentally empty)" \
    "yes" "$([ "$USAGE_MENTIONS_FLAG" -gt 0 ] && echo yes || echo no)"

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
