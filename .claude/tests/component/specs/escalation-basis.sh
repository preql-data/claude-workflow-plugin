#!/bin/bash
# escalation-basis.sh — L2 component spec for the J21 escalation BASIS
# (claude-workflow-plugin-2ty).
#
# THE DEFECT, with three measured instances (2026-08-05, all recorded on 2ty):
# the iteration counter charged STOP-HOOK PASSES and gate transitions, not
# review rounds, so the J21 cap fired on tasks where nothing had failed and
# nobody had reviewed anything:
#   * qzv.1 — counter 3, review verdicts 1, six gate entries in one cycle.
#   * 8zi   — counter 3, review artifacts 0; three server-side 529 errors and one
#             stream-watchdog stall each produced a Stop and another bump.
#   * 8zi   — counter 3 again, this time WHILE the reviewer was mid-review.
# The consequence is not cosmetic: reaching the cap forces a J21 decision, and
# the DEFAULT when none is recorded by the next Stop is DEFER, which sets
# qa-deferred and lets the following Stop RELEASE. An over-charging counter
# therefore steers work toward release-without-approval on a timer.
#
# WHAT THIS SPEC PINS, one leg per property:
#
#   A. POLL-ONLY (the bump). A project with no test/lint/type command has no
#      suite to run, so a Stop cannot be a verification iteration. Five Stops
#      must leave the counter untouched and escalate nothing.
#      META A: revert the bump to unconditional and the same five Stops escalate.
#   B. ROUNDS DRIVE THE CAP. Three REVIEW-ARTIFACT records against ONE
#      change-set hash escalate on their own, with the iteration counter at 0.
#   C. A NEW CHANGE SET RESETS. The same three records plus a moved change set
#      escalate nothing — rounds are counted against the CURRENT hash.
#   D. REVIEW IN FLIGHT (the suppression). A cycle open with zero artifacts for
#      the current hash and a PASSING suite: the counter climbs past the cap over
#      five Stops and no escalation fires, because nobody has disagreed with
#      anything yet.
#      META D: neutralize the suppression and the same leg escalates.
#   E. ANTI-OVERREACH on D's scope. A RED suite still escalates while a cycle is
#      open with zero artifacts — a failing suite is its own evidence, and J21
#      exists for exactly that loop.
#   F. AUTO-DEFER SURVIVES. After a legitimate escalation the documented escape
#      still lands on the second unanswered escalated Stop — on its OWN counter,
#      while the iteration counter stays frozen at the cap.
#   G. `enter` WIPES the auto-defer counter, so the first escalated Stop of a
#      fresh cycle can never auto-defer immediately.
#   I. RECONCILE SURVIVAL (claude-workflow-plugin-0in1, added after this spec's
#      initial landing). Rounds counted by hash EQUALITY alone silently zero a
#      real, findings-bearing review the moment the gate's OWN housekeeping
#      (reconcile_tracker, run by the Stop hook on every fire) folds in a
#      git-visible path no Write/Edit hook ever saw — same bytes, wider
#      tracker. Measured on claude-workflow-plugin-fkm.3: four HIGH findings
#      landed, reconcile grew the tracker with no specialist active, and the
#      NEXT Stop reported "no reviewer has disagreed with anything" over a
#      task carrying four open HIGH findings. Leg I reproduces that sequence
#      end to end (a real git-visible untracked file, not a test-side tracker
#      rewrite) and its META restores hash-equality-only counting to prove the
#      false text returns without the fix.
#      NOTE ON LEGS C AND H: 0in1's fix does NOT touch the property they pin —
#      a change set that moves because of GENUINE new work still starts a
#      fresh round count (claude-workflow-plugin-2ty's "a new change set has
#      needed no rounds yet"). The two are distinguished by whether an
#      IMPLEMENTER record is newer than the round in question (reconcile posts
#      no bd comment of its own and is the only OTHER writer of the tracker
#      that feeds change_set_hash). Leg C never opens a cycle (no `enter`), so
#      the cycle-survival rule was never reachable there and it needed no
#      change. Leg H DOES open a cycle, so its fixture (and META R1c's, which
#      shares the same shape) now posts an IMPLEMENTER record before moving
#      the tracker — modelling the GENUINE-new-work case explicitly rather
#      than leaving it implicit, which is what made the fixture ambiguous
#      between "reconcile" and "real work" once the rule could tell them
#      apart. See the CYCLE-SURVIVAL region in review-check.sh's cmd_gate for
#      the full reasoning.
#
#   J. SKIP-WHEN-UNCHANGED (claude-workflow-plugin-j7kk, 9xl4's cheap
#      structural half — added after this spec's initial landing, same as I).
#      A real npm-backed Stop fired TWICE on an identical git tree: the
#      second fire must not re-invoke npm, must not charge a second
#      verification iteration (the SAME "iterations, not passes" rule POLL-
#      ONLY/leg A already pins, extended to a second reason to say no), and
#      must name the reuse in the block reason. A CONTENT-ONLY edit to the
#      SAME tracked path between fires — the one shape change_set_hash alone
#      cannot see, gate-claim-honesty.test.sh's own Section 6 subject — must
#      force a genuine third npm invocation, proven here through the REAL
#      hook rather than the isolated predicate. Seeding three review records
#      is ITSELF a real tree change — qa-gate.sh review-record lands its
#      artifact under docs/reviews/, not workflow bookkeeping — so a fourth
#      fire genuinely re-runs (measured RED on the first draft of this leg,
#      which wrongly expected a skip there) and, being the THIRD genuine run,
#      escalates on ITER alone; a fifth fire, tree unchanged since the
#      fourth, is a regression check that the PRE-EXISTING escalation-replay
#      reading still fires correctly (the label from the fourth Stop's
#      escalation is already set, so the fifth reads QA_ESCALATED=true at
#      dispatch and correctly never reaches the new skip branch at all).
#      NOT ESTABLISHED, and said so at the leg itself rather than left
#      implied: whether ESC_SUITE_CLAUSE's ROUNDS-alone/still-a-skip branch —
#      QA_ESCALATED turning true for the FIRST time on the exact Stop a skip
#      also fires on — is reachable in production, and if so that it renders
#      correctly there; this fixture cannot separate "ROUNDS reaches the cap"
#      from "ITER already has" without a writer that seeds a round without
#      touching the tree, which none of the shipped ones are. The fix mirrors
#      SUITE_REUSE_REASON default-vs-named-reason branch), so it is not
#      unexercised code, but this SPECIFIC call site has inspection, not a
#      driven L2 assertion, behind it.
#      META J: the same hash-only narrowing gate-claim-honesty.test.sh's 6M
#      applies to the extracted predicate, applied instead to the real,
#      unmodified verify-before-stop.sh — the content-only edit is then
#      WRONGLY skipped.
#
#   K. R1-F1 FIX (claude-workflow-plugin-j7kk QA round 1) — a write landing
#      DURING the suite's own run window, not between two Stops, must not be
#      blessed into the skip baseline. Leg J's Stop 3 proves the skip catches
#      a content-only edit made BETWEEN two Stop fires; Leg K proves the
#      narrower, more dangerous case QA's review found uncovered — a mutation
#      arriving WHILE the suite is dispatched, so record_verified_state's
#      post-run reading and the caller's pre-dispatch reading are looking at
#      two DIFFERENT tree states even though only one Stop fired. A real
#      concurrent writer is not needed: the "npm" shim standing in for the
#      test runner performs the write itself, as a side effect, before it
#      exits — indistinguishable, from verify-before-stop.sh's point of view,
#      from an external process racing it, and exactly reproducible. Stop 1
#      (genuine run, mid-run write lands) must persist NO skip-state record;
#      Stop 2 (nothing further touched) must therefore re-run the suite for
#      real rather than replaying a green the suite never measured
#      end-to-end over that content — QA's own stated acceptance for R1-F1.
#      META K: reverting record_verified_state's pre/post comparison to an
#      unconditional persist (the pre-fix shape) reproduces the defect
#      exactly — Stop 1 persists despite the mid-run write, and Stop 2
#      wrongly skips.
#
# escalation-binding.sh (the spec 0.2 regression suite) is deliberately NOT
# modified: its cap-drive legs all fail the suite, so they exercise the
# unsuppressed path and their continued passing is part of this change's evidence.
#
# Run via the L2 component runner (.claude/tests/component/run.sh), which
# pre-sources assert.sh / shim.sh / hook-envelope.sh / fixture.sh.

set -u

# ---------------------------------------------------------------------------
# Shared helpers.

# The gate's own cap (verify-before-stop.sh MAX_ITERATIONS). Named here so the
# META's "climbed past the cap" assertion reads as the same number the gate uses.
MAX_ITER_EXPECTED=3

# stack_stub <fixture> <json> — replace the symlinked detector with a stub that
# prints <json>. The `\n` rides inside the %s argument, so the OUTER printf emits
# it literally and the stub's OWN printf turns it into the trailing newline.
stack_stub() {
    local fx="$1" json="$2"
    rm -f "$fx/.claude/scripts/detect-stack.sh"
    {
        printf '#!/bin/bash\n'
        printf '# Test-time stack detector (escalation-basis spec).\n'
        printf 'printf %s\n' "'$json\n'"
    } > "$fx/.claude/scripts/detect-stack.sh"
    chmod +x "$fx/.claude/scripts/detect-stack.sh"
}

NO_RUNNER_JSON='{"runner":"none","test_cmd":"","lint_cmd":"","type_cmd":""}'
NPM_RUNNER_JSON='{"runner":"npm","test_cmd":"npm test","lint_cmd":"","type_cmd":""}'

labels_for() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}
has_label_ct() {
    local n
    n=$(printf '%s' ",$(labels_for "$1")," | grep -c ",$2," || true)
    printf '%s' "$n" | tr -d '[:space:]'
}
san() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
count_in() {
    local n
    n=$(printf '%s' "$1" | grep -c "$2" || true)
    printf '%s' "$n" | tr -d '[:space:]'
}

# fire <vbs> — one Stop fire; leaves the verdict line in STOP_OUT and the block
# reason in STOP_REASON. One fire per read, because every fire is state.
STOP_OUT=""
STOP_REASON=""
fire() {
    STOP_OUT=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$1" 2>&1 | tail -1)
    STOP_REASON=$(printf '%s' "$STOP_OUT" | jq -r '.reason // empty' 2>/dev/null || echo "")
}

# seed_round <task-id> <iteration> <reviewed-hash> [root] — write ONE
# REVIEW-ARTIFACT record through the REAL writer (qa-gate.sh review-record,
# which re-validates through review-check.sh), so these seeds track the grammar
# instead of drifting from it. Findings-free and independent of any implementer
# role, so nothing but the ROUND COUNT is under test.
seed_round() {
    local tid="$1" iter="$2" hash="$3" root="${4:-$COMPONENT_FIXTURE_PATH}"
    local art
    art="$root/.claude/.qa-tracking/round-$(san "$tid")-r$iter.json"
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"qa-claude","reviewer_model":"seeded","reviewer_pin":"seeded","reviewed_hash":"$hash","risk_threshold":"high","stop_condition":"seeded round $iter","verdict":"approve","findings":[],"iterations":$iter,"stopped_by":"verdict"}
JSON
    # claude-workflow-plugin-rqer (v5 D2): --file now asserts the CANONICAL
    # derived path; piped via stdin instead so this scratch fixture needs no
    # renaming.
    CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" \
        review-record "$tid" < "$art" >/dev/null 2>&1
}

# ===========================================================================
# LEG A — POLL-ONLY: no suite to run, so no Stop is a verification iteration.

mk_fixture
FIX_A="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_A="$FIX_A/.claude/scripts/verify-before-stop.sh"
CT_A="$FIX_A/.claude/scripts/current-task.sh"
TRACK_A="$FIX_A/.claude/.qa-tracking"
stack_stub "$FIX_A" "$NO_RUNNER_JSON"

TID_A=$(cd "$FIX_A" && bd create "poll-only escalation" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "A: seeded task id" "$BD_ID_RE" "$TID_A"
# Deliberately NOT `qa-gate.sh enter`: leg A isolates the BUMP, so the
# review-in-flight suppression (which needs qa-gate-entered) must not be what
# saves it. current-task is set directly so the gate still has an active task.
bash "$CT_A" set "$TID_A" >/dev/null 2>&1
bd label add "$TID_A" qa-pending >/dev/null 2>&1
assert_eq "A: precondition — the gate cycle is NOT open (no qa-gate-entered)" \
    "0" "$(has_label_ct "$TID_A" "qa-gate-entered")"

for _ in 1 2 3 4 5; do
    printf 'src/handler.ts\n' > "$TRACK_A/changed-files.txt"
    fire "$VBS_A"
done
assert_decision "A: five poll-only Stops still block (QA approval is still required)" \
    "$STOP_OUT" "block"
ITER_A=$(head -1 "$TRACK_A/iteration-count.$(san "$TID_A")" 2>/dev/null || echo "absent")
[ -z "$ITER_A" ] && ITER_A="absent"
assert_eq "A: the iteration counter was NEVER written (no suite ran, so nothing was charged)" \
    "absent" "$ITER_A"
assert_eq "A: no qa-escalated label after five Stops" "0" "$(has_label_ct "$TID_A" "qa-escalated")"
assert_eq "A: no qa-deferred label after five Stops (the auto-defer chain never started)" \
    "0" "$(has_label_ct "$TID_A" "qa-deferred")"
assert_eq "A: the block reason carries NO J21 escalation block" \
    "0" "$(count_in "$STOP_REASON" 'ESCALATION: Iteration')"
assert_contains "A: ...and it reports the basis it measured instead" \
    "Escalation basis: verification iterations=0" "$STOP_REASON"

# ===========================================================================
# META A — revert the bump to unconditional at its own site. The same five
# poll-only Stops must then escalate, which is the shipped-before behaviour and
# the defect. Pattern-anchored on the read-path assignment (unique), never a line
# number.

mk_fixture
FIX_AM="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
CT_AM="$FIX_AM/.claude/scripts/current-task.sh"
TRACK_AM="$FIX_AM/.claude/.qa-tracking"
stack_stub "$FIX_AM" "$NO_RUNNER_JSON"

# The mutant lives in the fixture's .claude/scripts/ — verify-before-stop.sh
# loads workflow-denylist.sh from its OWN directory (BASH_SOURCE-relative) and
# blocks with a denylist-missing reason when it cannot, so a copy parked at the
# fixture root would satisfy "no escalation" without ever reaching the gate.
REAL_VBS_AM=$(readlink "$FIX_AM/.claude/scripts/verify-before-stop.sh" \
    || printf '%s' "$FIX_AM/.claude/scripts/verify-before-stop.sh")
VBS_AM="$FIX_AM/.claude/scripts/vbs-unconditional-bump.sh"
sed 's|ITER=$(read_iteration "$ITERATION_FILE")|ITER=$(bump_iteration "$ITERATION_FILE")|' \
    "$REAL_VBS_AM" > "$VBS_AM"
chmod +x "$VBS_AM"
if assert_mutant_applied "2ty META-A unconditional bump" "$REAL_VBS_AM" "$VBS_AM"; then
    AM_LANDED=$(grep -c 'ITER=$(bump_iteration "$ITERATION_FILE")' "$VBS_AM" || true)
    AM_LANDED=$(printf '%s' "$AM_LANDED" | tr -d '[:space:]')
    assert_eq "META A: both branches now bump (the pre-fix unconditional site)" "2" "$AM_LANDED"
    AM_READ_GONE=$(grep -c 'ITER=$(read_iteration "$ITERATION_FILE")' "$VBS_AM" || true)
    AM_READ_GONE=$(printf '%s' "$AM_READ_GONE" | tr -d '[:space:]')
    assert_eq "META A: the read path is gone from the mutant" "0" "$AM_READ_GONE"

    TID_AM=$(cd "$FIX_AM" && bd create "poll-only under mutant" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$CT_AM" set "$TID_AM" >/dev/null 2>&1
    bd label add "$TID_AM" qa-pending >/dev/null 2>&1
    for _ in 1 2 3 4 5; do
        printf 'src/handler.ts\n' > "$TRACK_AM/changed-files.txt"
        fire "$VBS_AM"
    done
    ITER_AM=$(head -1 "$TRACK_AM/iteration-count.$(san "$TID_AM")" 2>/dev/null || echo "absent")
    assert_eq "META A: under the mutant the counter charges every Stop (climbs past the cap)" \
        "1" "$([ "${ITER_AM:-0}" -ge "$MAX_ITER_EXPECTED" ] 2>/dev/null && echo 1 || echo 0)"
    assert_eq "META A: ...so the poll-only task IS escalated (leg A's assertion WOULD fail)" \
        "1" "$(has_label_ct "$TID_AM" "qa-escalated")"
fi

# ===========================================================================
# LEG B — three review ROUNDS against one change-set hash escalate on their own,
# with the iteration counter at 0. This is the quantity J21 is named for.
#
# LEG C rides the same fixture: a fourth-round-against-a-different-hash reset is
# a statement about the SAME record set read against a MOVED change set, so both
# tasks' artifacts are seeded while the tracker still holds the original set.

mk_fixture
FIX_B="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_B="$FIX_B/.claude/scripts/verify-before-stop.sh"
CT_B="$FIX_B/.claude/scripts/current-task.sh"
TRACK_B="$FIX_B/.claude/.qa-tracking"
IR_B="$FIX_B/.claude/scripts/impact-report.sh"
stack_stub "$FIX_B" "$NO_RUNNER_JSON"

# The change set both tasks' rounds are recorded against.
printf 'src/handler.ts\n' > "$TRACK_B/changed-files.txt"
HASH_X=$(CLAUDE_PROJECT_DIR="$FIX_B" bash "$IR_B" --hash-only 2>/dev/null || echo "")
assert_eq "B: precondition — the original change set has a computable hash" "1" \
    "$([ -n "$HASH_X" ] && echo 1 || echo 0)"

TID_B=$(cd "$FIX_B" && bd create "three rounds on one hash" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
TID_C=$(cd "$FIX_B" && bd create "rounds reset on a new hash" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
for t in "$TID_B" "$TID_C"; do
    bd label add "$t" qa-pending >/dev/null 2>&1
    seed_round "$t" 1 "$HASH_X"
    seed_round "$t" 2 "$HASH_X"
    seed_round "$t" 3 "$HASH_X"
done
ROUNDS_B=$(CLAUDE_PROJECT_DIR="$FIX_B" bash "$FIX_B/.claude/scripts/review-check.sh" \
    gate "$TID_B" --change-set-hash "$HASH_X" 2>/dev/null | jq -r '.rounds // "?"' 2>/dev/null || echo "?")
assert_eq "B: precondition — three records really landed against this hash" "3" "$ROUNDS_B"

bash "$CT_B" set "$TID_B" >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK_B/changed-files.txt"
fire "$VBS_B"
assert_decision "B: the Stop blocks (still no approval)" "$STOP_OUT" "block"
ITER_B=$(head -1 "$TRACK_B/iteration-count.$(san "$TID_B")" 2>/dev/null || echo "absent")
[ -z "$ITER_B" ] && ITER_B="absent"
assert_eq "B: the iteration counter is untouched — rounds alone reached the cap" "absent" "$ITER_B"
assert_eq "B: three rounds against the current hash DO escalate" \
    "1" "$(has_label_ct "$TID_B" "qa-escalated")"
assert_contains "B: ...and the reason offers the J21 decision gate" \
    "ESCALATION: Iteration" "$STOP_REASON"
assert_contains "B: ...naming rounds as the basis, not the iteration count" \
    "independent review rounds against this change set=3" "$STOP_REASON"
# The escalation record itself has to be auditable from the comment alone.
ESC_REC=$(bd_show_with_comments "$TID_B" \
    | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
    | grep '^QA-GATE ESCALATED ' | tail -1 || true)
assert_contains "B: the ESCALATED record names its basis and both components" \
    "verification iterations=0, review rounds=3" "$ESC_REC"

# --- LEG C: move the change set; the same three records stop counting ---------
printf 'src/handler.ts\nsrc/other.ts\n' > "$TRACK_B/changed-files.txt"
HASH_Y=$(CLAUDE_PROJECT_DIR="$FIX_B" bash "$IR_B" --hash-only 2>/dev/null || echo "")
assert_eq "C: precondition — moving the change set moved the hash" "1" \
    "$([ -n "$HASH_Y" ] && [ "$HASH_Y" != "$HASH_X" ] && echo 1 || echo 0)"
bash "$CT_B" set "$TID_C" >/dev/null 2>&1
fire "$VBS_B"
assert_decision "C: the Stop blocks" "$STOP_OUT" "block"
assert_eq "C: three rounds against the PREVIOUS hash do NOT escalate the new change set" \
    "0" "$(has_label_ct "$TID_C" "qa-escalated")"
assert_contains "C: ...because rounds are counted against the current hash (0)" \
    "independent review rounds against this change set=0" "$STOP_REASON"
assert_eq "C: no J21 block offered on a change set nobody has reviewed yet" \
    "0" "$(count_in "$STOP_REASON" 'ESCALATION: Iteration')"

# ===========================================================================
# LEG D — REVIEW IN FLIGHT: a cycle is open, zero artifacts exist for the current
# hash, and the suite PASSES. The counter climbs past the cap over five Stops and
# nothing escalates, because no reviewer has spoken. This is the third measured
# instance (the escalation that fired mid-review) made impossible.

mk_fixture
FIX_D="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_D="$FIX_D/.claude/scripts/verify-before-stop.sh"
QG_D="$FIX_D/.claude/scripts/qa-gate.sh"
TRACK_D="$FIX_D/.claude/.qa-tracking"
stack_stub "$FIX_D" "$NPM_RUNNER_JSON"
# A PASSING suite: the suppression is scoped to "nothing is failing", so this leg
# has to actually run a green suite rather than have no runner at all.
mk_shim "npm" "$FIX_D" 0 "PASS  12 tests passed" >/dev/null
NPM_LOG_D="$FIX_D/bin/npm.log"

TID_D=$(cd "$FIX_D" && bd create "review in flight" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_D" enter "$TID_D" >/dev/null
bd label add "$TID_D" qa-pending >/dev/null 2>&1
assert_eq "D: precondition — the cycle IS open (qa-gate-entered set by enter)" \
    "1" "$(has_label_ct "$TID_D" "qa-gate-entered")"
D_ROUNDS=$(CLAUDE_PROJECT_DIR="$FIX_D" bash "$FIX_D/.claude/scripts/review-check.sh" \
    gate "$TID_D" 2>/dev/null | jq -r '.rounds // "?"' 2>/dev/null || echo "?")
assert_eq "D: precondition — zero review artifacts on the task" "0" "$D_ROUNDS"

for _ in 1 2 3 4 5; do
    printf 'src/handler.ts\n' > "$TRACK_D/changed-files.txt"
    fire "$VBS_D"
done
assert_decision "D: the fifth Stop still blocks (QA review is still required)" "$STOP_OUT" "block"
NPM_D=$(grep -c . "$NPM_LOG_D" 2>/dev/null || echo 0)
NPM_D=$(printf '%s' "$NPM_D" | tr -d '[:space:]')
assert_eq "D: the suite really ran on every Stop (5 invocations)" "5" "$NPM_D"
ITER_D=$(head -1 "$TRACK_D/iteration-count.$(san "$TID_D")" 2>/dev/null || echo "0")
assert_eq "D: the counter DID climb past the cap — this leg is not passing because nothing bumped" \
    "5" "$ITER_D"
assert_eq "D: and yet NOTHING escalated (no reviewer has disagreed with anything)" \
    "0" "$(has_label_ct "$TID_D" "qa-escalated")"
assert_eq "D: no auto-defer either — the release-on-a-timer chain never starts" \
    "0" "$(has_label_ct "$TID_D" "qa-deferred")"
assert_eq "D: no J21 options offered" "0" "$(count_in "$STOP_REASON" 'ESCALATION: Iteration')"
assert_contains "D: the reason explains the suppression rather than staying silent" \
    "the J21 escalation is SUPPRESSED" "$STOP_REASON"
assert_contains "D: ...and names the state it measured" \
    "A review cycle is OPEN on this task" "$STOP_REASON"

# ===========================================================================
# META D — neutralize the review-in-flight suppression in a copy. The same leg
# must then escalate, proving leg D measures the suppression and not some
# unrelated reason for a quiet gate.

mk_fixture
FIX_DM="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_DM="$FIX_DM/.claude/scripts/qa-gate.sh"
TRACK_DM="$FIX_DM/.claude/.qa-tracking"
stack_stub "$FIX_DM" "$NPM_RUNNER_JSON"
mk_shim "npm" "$FIX_DM" 0 "PASS  12 tests passed" >/dev/null

REAL_VBS_DM=$(readlink "$FIX_DM/.claude/scripts/verify-before-stop.sh" \
    || printf '%s' "$FIX_DM/.claude/scripts/verify-before-stop.sh")
VBS_DM="$FIX_DM/.claude/scripts/vbs-no-suppression.sh"
# Strip the sentinel region around the LABEL TRANSITION's call to
# escalation_suppressed. The predicate itself and its other two callers (the
# J21-options gate and the basis note) survive, so the stripped copy still runs
# and still explains itself — it just escalates where it should not, which is the
# one behaviour this META measures.
awk '
    /# REVIEW-IN-FLIGHT SUPPRESSION BEGIN/ { skip = 1; next }
    /# REVIEW-IN-FLIGHT SUPPRESSION END/   { skip = 0; next }
    skip != 1 { print }
' "$REAL_VBS_DM" > "$VBS_DM"
chmod +x "$VBS_DM"
if assert_mutant_applied "2ty META-D no suppression" "$REAL_VBS_DM" "$VBS_DM"; then
    assert_eq "META D: mutated gate parses" "0" \
        "$(bash -n "$VBS_DM" 2>/dev/null && echo 0 || echo 1)"
    # WHICH mutation landed: exactly ONE call site of the shared predicate is
    # gone. Counting the DIFFERENCE in `if` CALLS — not bare mentions, which
    # would also count the region's own explanatory comment, and not a fixed
    # total, which would go stale the day a fourth caller is added.
    DM_ORIG=$(grep -cE '^[[:space:]]*if escalation_suppressed' "$REAL_VBS_DM" || true)
    DM_ORIG=$(printf '%s' "$DM_ORIG" | tr -d '[:space:]')
    DM_MUT=$(grep -cE '^[[:space:]]*if escalation_suppressed' "$VBS_DM" || true)
    DM_MUT=$(printf '%s' "$DM_MUT" | tr -d '[:space:]')
    assert_eq "META D: the strip removed exactly one call to the shared suppression predicate" \
        "1" "$((DM_ORIG - DM_MUT))"
    assert_eq "META D: ...and the predicate plus its other callers survive" "1" \
        "$([ "$DM_MUT" -ge 2 ] && grep -q '^escalation_suppressed() {' "$VBS_DM" && echo 1 || echo 0)"

    TID_DM=$(cd "$FIX_DM" && bd create "review in flight under mutant" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_DM" enter "$TID_DM" >/dev/null
    bd label add "$TID_DM" qa-pending >/dev/null 2>&1
    for _ in 1 2 3 4 5; do
        printf 'src/handler.ts\n' > "$TRACK_DM/changed-files.txt"
        fire "$VBS_DM"
    done
    assert_eq "META D: WITHOUT the suppression the mid-review task IS escalated (leg D WOULD fail)" \
        "1" "$(has_label_ct "$TID_DM" "qa-escalated")"
    # THE PAYOFF, and the reason this defect is P1 rather than bookkeeping: the
    # mutant does not merely escalate. Escalation at Stop 3 means Stops 4 and 5
    # are escalated Stops, the second of which AUTO-DEFERS — so five Stops during
    # a review nobody has reported on end with qa-deferred set, and the NEXT Stop
    # is allowed to release. That is the measured 8zi chain, reproduced here on
    # demand. Leg D shows the shipped gate never enters it.
    assert_eq "META D: ...and then AUTO-DEFERRED, arming the release the fix prevents" \
        "1" "$(has_label_ct "$TID_DM" "qa-deferred")"
    # Discriminator: the mutant ran the REAL gate rather than dying early — the
    # suite really ran on the way to the cap, and the counter stops at the cap
    # precisely because escalation then suppresses further verification runs
    # (whereas leg D, unescalated, charged all five).
    ITER_DM=$(head -1 "$TRACK_DM/iteration-count.$(san "$TID_DM")" 2>/dev/null || echo "0")
    assert_eq "META D: the mutant drove the real verification path to the cap (counter=3)" \
        "$MAX_ITER_EXPECTED" "$ITER_DM"
    NPM_DM=$(grep -c . "$FIX_DM/bin/npm.log" 2>/dev/null || echo 0)
    NPM_DM=$(printf '%s' "$NPM_DM" | tr -d '[:space:]')
    assert_eq "META D: ...running the suite three times before the escalation contract stopped it" \
        "$MAX_ITER_EXPECTED" "$NPM_DM"
fi

# ===========================================================================
# LEG E — ANTI-OVERREACH on the suppression's scope: a RED suite escalates even
# with a cycle open and zero artifacts. A failing suite is its own evidence, and
# a cycle is open during almost all implementation work — an unscoped suppression
# would have deleted J21 from the failing-test loop entirely.
#
# LEG F rides the same fixture: auto-defer is what happens two Stops after a
# legitimate escalation, so it needs one.

mk_fixture
FIX_E="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_E="$FIX_E/.claude/scripts/verify-before-stop.sh"
QG_E="$FIX_E/.claude/scripts/qa-gate.sh"
TRACK_E="$FIX_E/.claude/.qa-tracking"
stack_stub "$FIX_E" "$NPM_RUNNER_JSON"
mk_shim "npm" "$FIX_E" 1 "FAIL  src/handler.test.ts: AssertionError: 1 test failing" >/dev/null
NPM_LOG_E="$FIX_E/bin/npm.log"

TID_E=$(cd "$FIX_E" && bd create "red suite with an open cycle" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_E" enter "$TID_E" >/dev/null
bd label add "$TID_E" qa-pending >/dev/null 2>&1
assert_eq "E: precondition — the cycle is open" "1" "$(has_label_ct "$TID_E" "qa-gate-entered")"

REASON_E1=""
for i in 1 2 3; do
    printf 'src/handler.ts\n' > "$TRACK_E/changed-files.txt"
    fire "$VBS_E"
    if [ "$i" = "1" ]; then REASON_E1="$STOP_REASON"; fi
done
assert_decision "E: the cap-hit Stop blocks" "$STOP_OUT" "block"
assert_eq "E: a RED suite escalates even mid-review (suppression is scoped to nothing-failing)" \
    "1" "$(has_label_ct "$TID_E" "qa-escalated")"
assert_contains "E: ...with the J21 options, because this loop is what J21 is for" \
    "ESCALATION: Iteration" "$STOP_REASON"

# --- QA R1-F1 reproduction (a): iteration 1, RED suite, cycle open, zero
# artifacts — the ordinary post-block fix round, and the most common block in the
# workflow. The suppression PARAGRAPH must be absent: nothing is suppressed here,
# and a check IS failing. (Leg D pins the same string PRESENT where suppression
# is real, so this absence assertion is non-vacuous in both directions.)
assert_eq "E-R1F1(a): iteration 1 with a RED suite does NOT claim the escalation is SUPPRESSED" \
    "0" "$(count_in "$REASON_E1" 'SUPPRESSED')"
assert_eq "E-R1F1(a): ...nor claims no technical check is failing" \
    "0" "$(count_in "$REASON_E1" 'no technical check is failing')"
assert_contains "E-R1F1(a): ...while still reporting the basis it measured" \
    "Escalation basis: verification iterations=1" "$REASON_E1"
assert_eq "E-R1F1(a): ...and offers no J21 options below the cap" \
    "0" "$(count_in "$REASON_E1" 'ESCALATION: Iteration')"

# --- QA R1-F1 reproduction (b): the cap-hit Stop, RED suite, cycle open. The
# gate escalates here (leg E's own assertion above), so printing SUPPRESSED one
# line above the J21 options would contradict the options themselves.
assert_eq "E-R1F1(b): the cap-hit Stop does NOT print SUPPRESSED above its own J21 options" \
    "0" "$(count_in "$STOP_REASON" 'SUPPRESSED')"
# The non-vacuity pair for R1-F2's absence assertions in leg H: where the cap IS
# reached, the banner says so.
assert_contains "E-R1F2 pair: at a real cap-hit the banner DOES claim the cap was reached" \
    "cap reached" "$STOP_REASON"
ITER_E3=$(head -1 "$TRACK_E/iteration-count.$(san "$TID_E")" 2>/dev/null || echo "0")
assert_eq "E: three verification iterations were charged (the suite ran each time)" "3" "$ITER_E3"

# --- LEG F: the auto-defer escape still lands, on its own counter -------------
printf 'src/handler.ts\n' > "$TRACK_E/changed-files.txt"
fire "$VBS_E"
assert_decision "F: the FIRST escalated Stop still blocks (one more chance to answer)" \
    "$STOP_OUT" "block"
NPM_E4=$(grep -c . "$NPM_LOG_E" 2>/dev/null || echo 0)
NPM_E4=$(printf '%s' "$NPM_E4" | tr -d '[:space:]')
assert_eq "F: the escalation contract still skips the suite (npm stays at 3)" "3" "$NPM_E4"
ITER_E4=$(head -1 "$TRACK_E/iteration-count.$(san "$TID_E")" 2>/dev/null || echo "0")
assert_eq "F: and the iteration counter did NOT grow for a Stop that ran nothing" "3" "$ITER_E4"
ESCST_E4=$(head -1 "$TRACK_E/escalated-stops.$(san "$TID_E")" 2>/dev/null || echo "0")
assert_eq "F: the auto-defer counter charged that Stop instead (1)" "1" "$ESCST_E4"

printf 'src/handler.ts\n' > "$TRACK_E/changed-files.txt"
fire "$VBS_E"
assert_empty_envelope "F: the SECOND unanswered escalated Stop auto-defers (allow)" "$STOP_OUT"
assert_eq "F: qa-deferred is set by auto-defer" "1" "$(has_label_ct "$TID_E" "qa-deferred")"
assert_eq "F: qa-pending is preserved" "1" "$(has_label_ct "$TID_E" "qa-pending")"
DEFER_REC=$(bd_show_with_comments "$TID_E" \
    | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
    | grep -c '^QA-GATE AUTO-DEFER ' || true)
DEFER_REC=$(printf '%s' "$DEFER_REC" | tr -d '[:space:]')
assert_eq "F: exactly one auto-defer record" "1" "$DEFER_REC"
ITER_E5=$(head -1 "$TRACK_E/iteration-count.$(san "$TID_E")" 2>/dev/null || echo "0")
assert_eq "F: the iteration counter is STILL 3 — auto-defer no longer borrows it" "3" "$ITER_E5"

# ===========================================================================
# LEG G — a fresh `enter` wipes the auto-defer counter. Without this, the FIRST
# escalated Stop of the next cycle would auto-defer immediately, and auto-defer's
# consequence is that the following Stop is ALLOWED.

bash "$QG_E" enter "$TID_E" >/dev/null
assert_eq "G: enter wipes the auto-defer counter" "1" \
    "$([ -e "$TRACK_E/escalated-stops.$(san "$TID_E")" ] && echo 0 || echo 1)"
assert_eq "G: enter wipes the iteration counter too (unchanged behaviour)" "1" \
    "$([ -e "$TRACK_E/iteration-count.$(san "$TID_E")" ] && echo 0 || echo 1)"
assert_eq "G: enter cleared qa-escalated" "0" "$(has_label_ct "$TID_E" "qa-escalated")"
assert_eq "G: enter cleared qa-deferred" "0" "$(has_label_ct "$TID_E" "qa-deferred")"

# ===========================================================================
# LEG H — QA R1-F1 reproduction (c) and R1-F2, the state where the readout was
# UNCONDITIONALLY false rather than merely mis-scoped: an escalation is already
# live, the change set has MOVED so the rounds that triggered it no longer count,
# the cycle is still open and nothing is failing.
#
# Every antecedent of the suppression sentence holds — a cycle IS open, no
# artifact exists for THIS hash, nothing IS failing — so the old code printed
# "the J21 escalation is SUPPRESSED" on a Stop where the escalation was live, the
# J21 options were being offered one paragraph below, and the NEXT Stop
# auto-deferred into a release. An agent that believes the sentence does not
# record the J21 choice that would have stopped that release.
#
# It is also where R1-F2 bites: ITER is frozen by the escalation contract and
# ROUNDS just dropped to 0, so the banners — which key on the STICKY LABEL, not
# on the basis — asserted "cap reached" and "basis 0 >= 3" while the basis was 0.
# Newly reachable, and only because the counter stopped charging every Stop.

mk_fixture
FIX_H="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_H="$FIX_H/.claude/scripts/verify-before-stop.sh"
QG_H="$FIX_H/.claude/scripts/qa-gate.sh"
TRACK_H="$FIX_H/.claude/.qa-tracking"
IR_H="$FIX_H/.claude/scripts/impact-report.sh"
# No runner: ITER stays 0 throughout, so the basis is the rounds count alone and
# the "current basis is below the cap" state is reached without any other moving
# part.
stack_stub "$FIX_H" "$NO_RUNNER_JSON"

TID_H=$(cd "$FIX_H" && bd create "escalation outlives its basis" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
# enter FIRST: it clears escalation labels, so the cycle has to be opened before
# the escalation is driven, not after.
bash "$QG_H" enter "$TID_H" >/dev/null
bd label add "$TID_H" qa-pending >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK_H/changed-files.txt"
HASH_HX=$(CLAUDE_PROJECT_DIR="$FIX_H" bash "$IR_H" --hash-only 2>/dev/null || echo "")
seed_round "$TID_H" 1 "$HASH_HX"
seed_round "$TID_H" 2 "$HASH_HX"
seed_round "$TID_H" 3 "$HASH_HX"

# Stop 1 — three rounds against the CURRENT hash: escalate for real.
fire "$VBS_H"
assert_eq "H: precondition — three rounds against the current hash escalate" \
    "1" "$(has_label_ct "$TID_H" "qa-escalated")"
assert_contains "H: precondition — and that Stop's banner claims the cap, correctly" \
    "cap reached" "$STOP_REASON"

# Move the change set: a FRESH specialist turn (0in1's cycle-survival rule
# needs this to be modelled explicitly now — see the CYCLE-SURVIVAL region in
# review-check.sh's cmd_gate) genuinely touches a new file, so the three
# existing rounds do NOT carry forward: they reviewed a diff this one is no
# longer the whole of. A sentinel-future timestamp (the same device
# subagent-start.sh's and verify-before-stop.sh's own specs use) keeps this
# deterministically AFTER the seeded rounds regardless of wall-clock timing.
bd comments add "$TID_H" "IMPLEMENTER: role=backend task=$TID_H at 2099-01-01T00:00:00Z" >/dev/null 2>&1
printf 'src/handler.ts\nsrc/other.ts\n' > "$TRACK_H/changed-files.txt"
HASH_HY=$(CLAUDE_PROJECT_DIR="$FIX_H" bash "$IR_H" --hash-only 2>/dev/null || echo "")
assert_eq "H: precondition — the change set moved" "1" \
    "$([ -n "$HASH_HY" ] && [ "$HASH_HY" != "$HASH_HX" ] && echo 1 || echo 0)"
H_ROUNDS=$(CLAUDE_PROJECT_DIR="$FIX_H" bash "$FIX_H/.claude/scripts/review-check.sh" \
    gate "$TID_H" --change-set-hash "$HASH_HY" 2>/dev/null | jq -r '.rounds // "?"' 2>/dev/null || echo "?")
assert_eq "H: precondition — rounds against the NEW hash is 0" "0" "$H_ROUNDS"
assert_eq "H: precondition — the cycle is still open and the escalation still live" \
    "1:1" "$(has_label_ct "$TID_H" "qa-gate-entered"):$(has_label_ct "$TID_H" "qa-escalated")"

# Stop 2 — every antecedent of the suppression sentence now holds, and it is
# still false: this task IS escalated.
fire "$VBS_H"
assert_decision "H: the Stop blocks" "$STOP_OUT" "block"
assert_eq "H-R1F1(c): an ESCALATED task is never described as SUPPRESSED" \
    "0" "$(count_in "$STOP_REASON" 'SUPPRESSED')"
assert_eq "H-R1F1(c): ...and the gate does not claim nobody has disagreed while offering J21" \
    "0" "$(count_in "$STOP_REASON" 'no reviewer has disagreed')"
assert_contains "H-R1F1(c): ...the J21 options ARE still offered (the escalation is live)" \
    "ESCALATION: Iteration" "$STOP_REASON"
# R1-F2: the arithmetic has to be true.
assert_eq "H-R1F2: no 'cap reached' claim while the current basis is below the cap" \
    "0" "$(count_in "$STOP_REASON" 'cap reached')"
assert_eq "H-R1F2: no false inequality (basis 0 >= 3)" \
    "0" "$(count_in "$STOP_REASON" 'basis 0 >= 3')"
assert_contains "H-R1F2: ...it says the escalation came from an earlier Stop" \
    "escalated on an earlier Stop" "$STOP_REASON"
assert_contains "H-R1F2: ...naming the basis that actually triggered it" \
    "at basis 3" "$STOP_REASON"
assert_contains "H-R1F2: ...and that the current basis is below the cap" \
    "BELOW the cap" "$STOP_REASON"
ESCST_H=$(head -1 "$TRACK_H/escalated-stops.$(san "$TID_H")" 2>/dev/null || echo "0")
assert_eq "H: this was the first escalated Stop" "1" "$ESCST_H"

# Stop 3 — RESIDUAL, pinned rather than fixed (QA R1-F3, recorded as a named
# residual on 2ty): a live escalation is NOT disarmed when the state becomes
# review-in-flight, so the auto-defer chain still reaches a release from here.
# Auto-defer runs before the suite and cannot consult FAILED_CHECKS, so this is
# not the one-liner it looks like. Asserted so the residual is measurable and
# goes red the day someone closes it, rather than being described in prose only.
fire "$VBS_H"
assert_empty_envelope "H-RESIDUAL(R1-F3): the second escalated Stop still auto-defers (allow)" "$STOP_OUT"
assert_eq "H-RESIDUAL(R1-F3): ...setting qa-deferred, which lets the NEXT Stop release" \
    "1" "$(has_label_ct "$TID_H" "qa-deferred")"

# ===========================================================================
# META R1 — the suppression paragraph's guard has TWO clauses, and each gets its
# own mutant + its own scenario. One mutant that removed both would prove only
# that "some guard" exists; these prove WHICH clause carries which reproduction.
#
# Both mutants live in one fixture: the stack stub is a file, so switching the
# runner between the two scenarios costs a rewrite rather than a second fixture.

mk_fixture
FIX_M="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
QG_M="$FIX_M/.claude/scripts/qa-gate.sh"
TRACK_M="$FIX_M/.claude/.qa-tracking"
IR_M="$FIX_M/.claude/scripts/impact-report.sh"
REAL_VBS_M=$(readlink "$FIX_M/.claude/scripts/verify-before-stop.sh" \
    || printf '%s' "$FIX_M/.claude/scripts/verify-before-stop.sh")

# --- META R1a: drop the FAILED_CHECKS half of the guard (keep the label half).
# Scenario: reproduction (a) — red suite, below the cap, cycle open.
VBS_MA="$FIX_M/.claude/scripts/vbs-note-unscoped.sh"
sed 's|if escalation_suppressed && \[ "$QA_ESCALATED" != "true" \]; then|if [ "$REVIEW_IN_FLIGHT" = "true" ] \&\& [ "$QA_ESCALATED" != "true" ]; then|' \
    "$REAL_VBS_M" > "$VBS_MA"
chmod +x "$VBS_MA"
if assert_mutant_applied "2ty META-R1a note not scoped to a green suite" "$REAL_VBS_M" "$VBS_MA"; then
    assert_eq "META R1a: mutated gate parses" "0" \
        "$(bash -n "$VBS_MA" 2>/dev/null && echo 0 || echo 1)"
    stack_stub "$FIX_M" "$NPM_RUNNER_JSON"
    mk_shim "npm" "$FIX_M" 1 "FAIL  src/handler.test.ts: AssertionError" >/dev/null
    TID_MA=$(cd "$FIX_M" && bd create "unscoped note under mutant" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_M" enter "$TID_MA" >/dev/null
    bd label add "$TID_MA" qa-pending >/dev/null 2>&1
    printf 'src/handler.ts\n' > "$TRACK_M/changed-files.txt"
    fire "$VBS_MA"
    assert_eq "META R1a: WITHOUT the green-suite clause a RED-suite Stop claims SUPPRESSED (repro (a) returns)" \
        "1" "$([ "$(count_in "$STOP_REASON" 'SUPPRESSED')" -ge 1 ] && echo 1 || echo 0)"
    # Discriminator: the mutant ran the real gate — it reported the failing suite.
    assert_contains "META R1a: the mutant ran the real gate (the red suite is in the reason)" \
        "Tests failing" "$STOP_REASON"
fi

# --- META R1c: drop the label half of the guard (keep the FAILED_CHECKS half).
# Scenario: reproduction (c) — escalation live, rounds dropped, suite green.
VBS_MC="$FIX_M/.claude/scripts/vbs-note-ignores-label.sh"
sed 's|if escalation_suppressed && \[ "$QA_ESCALATED" != "true" \]; then|if escalation_suppressed; then|' \
    "$REAL_VBS_M" > "$VBS_MC"
chmod +x "$VBS_MC"
if assert_mutant_applied "2ty META-R1c note ignores the live escalation" "$REAL_VBS_M" "$VBS_MC"; then
    assert_eq "META R1c: mutated gate parses" "0" \
        "$(bash -n "$VBS_MC" 2>/dev/null && echo 0 || echo 1)"
    stack_stub "$FIX_M" "$NO_RUNNER_JSON"
    TID_MC=$(cd "$FIX_M" && bd create "escalated note under mutant" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_M" enter "$TID_MC" >/dev/null
    bd label add "$TID_MC" qa-pending >/dev/null 2>&1
    printf 'src/handler.ts\n' > "$TRACK_M/changed-files.txt"
    HASH_MX=$(CLAUDE_PROJECT_DIR="$FIX_M" bash "$IR_M" --hash-only 2>/dev/null || echo "")
    seed_round "$TID_MC" 1 "$HASH_MX"
    seed_round "$TID_MC" 2 "$HASH_MX"
    seed_round "$TID_MC" 3 "$HASH_MX"
    fire "$VBS_MC"
    assert_eq "META R1c: precondition — the mutant escalated the task for real" \
        "1" "$(has_label_ct "$TID_MC" "qa-escalated")"
    # Same 0in1 modelling fix as leg H: a genuine specialist turn, not an
    # unmodelled tracker rewrite, is why rounds must drop for the new hash.
    bd comments add "$TID_MC" "IMPLEMENTER: role=backend task=$TID_MC at 2099-01-01T00:00:00Z" >/dev/null 2>&1
    printf 'src/handler.ts\nsrc/other.ts\n' > "$TRACK_M/changed-files.txt"
    fire "$VBS_MC"
    assert_eq "META R1c: WITHOUT the live-escalation clause an ESCALATED Stop claims SUPPRESSED (repro (c) returns)" \
        "1" "$([ "$(count_in "$STOP_REASON" 'SUPPRESSED')" -ge 1 ] && echo 1 || echo 0)"
    # Discriminator: the mutant reached the escalated readout, not some earlier exit.
    assert_contains "META R1c: the mutant ran the real gate (escalated readout reached)" \
        "ESCALATION: Iteration" "$STOP_REASON"
fi

# ===========================================================================
# LEG I — RECONCILE SURVIVAL (claude-workflow-plugin-0in1). Reproduces the
# fkm.3 sequence end to end, through the REAL mechanism (a git-visible file no
# Write/Edit hook ever saw, discovered by the Stop hook's OWN reconcile step —
# not a test-side tracker rewrite): a cycle opens, a reviewer posts real HIGH
# findings against the change set as it stands, then a file lands outside the
# tracker with NO specialist active since the review. The round must survive
# (rounds stays 1, not 0) and the false "no reviewer has disagreed with
# anything" / "SUPPRESSED" text must not print.

mk_fixture
FIX_I="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_I="$FIX_I/.claude/scripts/verify-before-stop.sh"
QG_I="$FIX_I/.claude/scripts/qa-gate.sh"
RC_I="$FIX_I/.claude/scripts/review-check.sh"
TRACK_I="$FIX_I/.claude/.qa-tracking"
IR_I="$FIX_I/.claude/scripts/impact-report.sh"
stack_stub "$FIX_I" "$NPM_RUNNER_JSON"
mk_shim "npm" "$FIX_I" 0 "PASS  12 tests passed" >/dev/null

# A real git checkout, the same isolation shape verify-before-stop.sh's own
# qzv fixture uses (its comment records WHY: without the ignore, the
# reconciler folds the harness's OWN scaffolding into the change set too).
printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIX_I/.gitignore"
mkdir -p "$FIX_I/src"
printf 'export function handler() {}\n' > "$FIX_I/src/handler.ts"
(cd "$FIX_I" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

TID_I=$(cd "$FIX_I" && bd create "reconcile must not zero a landed review" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_I" enter "$TID_I" >/dev/null
bd label add "$TID_I" qa-pending >/dev/null 2>&1
# The specialist who made the ORIGINAL edit, posted before the review — so
# LATEST_IMPLEMENTER_TS predates the round and cannot exclude it.
bd comments add "$TID_I" "IMPLEMENTER: role=backend task=$TID_I at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK_I/changed-files.txt"
HASH_IX=$(CLAUDE_PROJECT_DIR="$FIX_I" bash "$IR_I" --hash-only 2>/dev/null || echo "")
assert_eq "I: precondition — the reviewed change set has a computable hash" "1" \
    "$([ -n "$HASH_IX" ] && echo 1 || echo 0)"

# The review lands FOUR HIGH findings against the hash the tracker shows RIGHT
# NOW — the shape fkm.3 measured, not a synthetic zero-findings seed.
ART_I="$FIX_I/.claude/.qa-tracking/round-I.json"
cat > "$ART_I" <<JSON
{"contract_version":"1","task_id":"$TID_I","reviewer_identity":"sol-codex","reviewer_model":"seeded","reviewer_pin":"seeded","reviewed_hash":"$HASH_IX","risk_threshold":"high","stop_condition":"seeded review","verdict":"findings","findings":[{"id":"R1-F1","severity":"high","location":"x","evidence":"y","description":"z"},{"id":"R1-F2","severity":"high","location":"x","evidence":"y","description":"z"},{"id":"R1-F3","severity":"high","location":"x","evidence":"y","description":"z"},{"id":"R1-F4","severity":"high","location":"x","evidence":"y","description":"z"}],"iterations":1,"stopped_by":"verdict"}
JSON
CLAUDE_PROJECT_DIR="$FIX_I" bash "$QG_I" review-record "$TID_I" < "$ART_I" >/dev/null 2>&1
I_ROUNDS_PRE=$(CLAUDE_PROJECT_DIR="$FIX_I" bash "$RC_I" \
    gate "$TID_I" --change-set-hash "$HASH_IX" 2>/dev/null | jq -r '.rounds // "?"' 2>/dev/null || echo "?")
assert_eq "I: precondition — the review counts against the hash it reviewed" "1" "$I_ROUNDS_PRE"

# A git-visible file lands OUTSIDE the tracker — exactly the mechanism 94d's
# reconcile_tracker exists to fold in (a Bash write, invisible to
# post-edit.sh) and exactly fkm.3's trigger. NO implementer record is posted
# for this: nothing but reconcile's own housekeeping can explain the
# tracker's growth on the next Stop.
printf 'export function other() {}\n' > "$FIX_I/src/other.ts"

# The Stop fires: its OWN reconcile-tracker step (94d) discovers src/other.ts
# AND the review artifact's own canonical file (claude-workflow-plugin-rqer:
# review-record above just wrote a REAL, git-visible
# docs/reviews/$TID_I-r1.json — that is AC-4, the artifact entering the
# change set exactly like any other reviewable path) and folds both in
# before this Stop reads anything else — the real mechanism, not a test-side
# rewrite of changed-files.txt.
fire "$VBS_I"
assert_decision "I: the Stop blocks (four open HIGH findings, unresolved)" "$STOP_OUT" "block"
TRACKED_I=$(grep -c . "$TRACK_I/changed-files.txt" 2>/dev/null || echo 0)
TRACKED_I=$(printf '%s' "$TRACKED_I" | tr -d '[:space:]')
assert_eq "I: precondition — the Stop's OWN reconcile grew the tracker to 3 paths (src/handler.ts seeded + src/other.ts and the review artifact discovered)" "3" "$TRACKED_I"
HASH_IY=$(CLAUDE_PROJECT_DIR="$FIX_I" bash "$IR_I" --hash-only 2>/dev/null || echo "")
assert_eq "I: precondition — the reconcile-driven fold moved the hash" "1" \
    "$([ -n "$HASH_IY" ] && [ "$HASH_IY" != "$HASH_IX" ] && echo 1 || echo 0)"

I_POST_OUT=$(CLAUDE_PROJECT_DIR="$FIX_I" bash "$RC_I" gate "$TID_I" --change-set-hash "$HASH_IY" 2>/dev/null)
assert_eq "I: the review SURVIVES reconcile's own housekeeping (rounds=1, not 0)" \
    "1" "$(printf '%s' "$I_POST_OUT" | jq -r '.rounds // "?"')"
assert_eq "I: ...and the envelope names WHY (rounds_basis=cycle)" \
    "cycle" "$(printf '%s' "$I_POST_OUT" | jq -r '.rounds_basis // "?"')"
assert_eq "I: ...naming that the surviving round is against a stale hash" \
    "1" "$(printf '%s' "$I_POST_OUT" | jq -r '.rounds_stale_hash_count // "?"')"
assert_eq "I: the four HIGH findings are still visible to the gate" \
    "4" "$(printf '%s' "$I_POST_OUT" | jq -r '.open_findings // "?"')"

assert_eq "I: the false 'no reviewer has disagreed' text does NOT print" \
    "0" "$(count_in "$STOP_REASON" 'no reviewer has disagreed')"
assert_eq "I: ...nor the SUPPRESSED claim (a reviewer HAS spoken, with 4 open HIGH findings)" \
    "0" "$(count_in "$STOP_REASON" 'SUPPRESSED')"
assert_contains "I: ...and the basis line reports the surviving round" \
    "independent review rounds against this change set=1" "$STOP_REASON"

# ===========================================================================
# META I — restore hash-equality-ONLY counting (the pre-0in1 rule) in a copy
# of review-check.sh. The identical bd state — same task, same review, same
# reconciled hash — must then report rounds=0, reproducing the defect, proving
# leg I measures the cycle-survival rule and not some unrelated reason the
# false text stayed absent.

REAL_RC_I=$(readlink "$FIX_I/.claude/scripts/review-check.sh" \
    || printf '%s' "$FIX_I/.claude/scripts/review-check.sh")
RC_IM="$FIX_I/.claude/scripts/review-check-hash-only.sh"
sed 's/CYCLE_ESTABLISHED="1"/CYCLE_ESTABLISHED="0"/' "$REAL_RC_I" > "$RC_IM"
chmod +x "$RC_IM"
if assert_mutant_applied "0in1 META-I hash-equality-only restored" "$REAL_RC_I" "$RC_IM"; then
    assert_eq "META I: mutated review-check.sh parses" "0" \
        "$(bash -n "$RC_IM" 2>/dev/null && echo 0 || echo 1)"
    # WHICH mutation landed: CYCLE_ESTABLISHED can now never reach "1", so the
    # literal "0" assignment appears twice (the original declaration plus the
    # neutralised branch) where the shipped script has it once.
    MI_ORIG=$(grep -c 'CYCLE_ESTABLISHED="0"' "$REAL_RC_I" || true)
    MI_ORIG=$(printf '%s' "$MI_ORIG" | tr -d '[:space:]')
    MI_MUT=$(grep -c 'CYCLE_ESTABLISHED="0"' "$RC_IM" || true)
    MI_MUT=$(printf '%s' "$MI_MUT" | tr -d '[:space:]')
    assert_eq "META I: the substitution landed exactly once" "1" "$((MI_MUT - MI_ORIG))"

    META_I_OUT=$(CLAUDE_PROJECT_DIR="$FIX_I" bash "$RC_IM" gate "$TID_I" --change-set-hash "$HASH_IY" 2>/dev/null)
    assert_eq "META I: WITHOUT the cycle-survival rule the SAME review reports rounds=0 (the 0in1 defect)" \
        "0" "$(printf '%s' "$META_I_OUT" | jq -r '.rounds // "?"')"
    assert_eq "META I: ...and basis is reported hash_equality, not cycle" \
        "hash_equality" "$(printf '%s' "$META_I_OUT" | jq -r '.rounds_basis // "?"')"
    # Discriminator: the mutant still ran the real predicate — independence and
    # the four open findings are unaffected, so the rounds difference is the
    # cycle-survival rule and nothing else.
    assert_eq "META I: the mutant still reports the 4 open findings (ran the real predicate)" \
        "4" "$(printf '%s' "$META_I_OUT" | jq -r '.open_findings // "?"')"
fi

# ===========================================================================
# LEG J — SKIP-WHEN-UNCHANGED (claude-workflow-plugin-j7kk, 9xl4's cheap
# structural half). See the file header for the property under test.
#
# A REAL git checkout is required this time (unlike A-H, which are immune to
# this feature precisely because they are NOT git repos — tree_fingerprint
# returns the "no-git" sentinel there and the skip predicate refuses to
# engage on a sentinel, on either side; see gate-claim-honesty.test.sh
# Section 6's 6.8/6.9). Same isolation shape LEG I already uses.

mk_fixture
FIX_J="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_J="$FIX_J/.claude/scripts/verify-before-stop.sh"
QG_J="$FIX_J/.claude/scripts/qa-gate.sh"
CT_J="$FIX_J/.claude/scripts/current-task.sh"
TRACK_J="$FIX_J/.claude/.qa-tracking"
stack_stub "$FIX_J" "$NPM_RUNNER_JSON"
mk_shim "npm" "$FIX_J" 0 "PASS  12 tests passed" >/dev/null
NPM_LOG_J="$FIX_J/bin/npm.log"

printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIX_J/.gitignore"
mkdir -p "$FIX_J/src"
printf 'export function handler() {}\n' > "$FIX_J/src/handler.ts"
(cd "$FIX_J" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

TID_J=$(cd "$FIX_J" && bd create "skip-when-unchanged" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_J" enter "$TID_J" >/dev/null
bd label add "$TID_J" qa-pending >/dev/null 2>&1
bash "$CT_J" set "$TID_J" >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"

fire "$VBS_J"
assert_decision "J: Stop 1 (genuine run) blocks — no approval yet" "$STOP_OUT" "block"
NPM_J1=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
NPM_J1=$(printf '%s' "$NPM_J1" | tr -d '[:space:]')
assert_eq "J: Stop 1 really ran npm (1 invocation)" "1" "$NPM_J1"
ITER_J1=$(head -1 "$TRACK_J/iteration-count.$(san "$TID_J")" 2>/dev/null || echo "0")
assert_eq "J: Stop 1 charged one verification iteration" "1" "$ITER_J1"
STATE_GLOB_J=$(cd "$FIX_J" && ls .claude/.qa-tracking/last-verified-state.* 2>/dev/null | head -1)
assert_eq "J: Stop 1 persisted a skip-state record for this task" \
    "yes" "$([ -n "$STATE_GLOB_J" ] && [ -s "$FIX_J/$STATE_GLOB_J" ] && echo yes || echo no)"

# --- Stop 2: IDENTICAL tree. Must SKIP, not re-run. -------------------------
printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
fire "$VBS_J"
assert_decision "J: Stop 2 (identical tree) still blocks (no approval was recorded)" "$STOP_OUT" "block"
NPM_J2=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
NPM_J2=$(printf '%s' "$NPM_J2" | tr -d '[:space:]')
assert_eq "J: Stop 2 did NOT re-invoke npm (still 1) — the skip fired" "1" "$NPM_J2"
ITER_J2=$(head -1 "$TRACK_J/iteration-count.$(san "$TID_J")" 2>/dev/null || echo "0")
assert_eq "J: Stop 2 did NOT charge a second verification iteration (SUITE_REUSED's 'iterations, not passes' rule, extended)" \
    "1" "$ITER_J2"
assert_contains "J: Stop 2's reason says the checks were NOT re-run this loop" \
    "NOT re-run this loop" "$STOP_REASON"
# claude-workflow-plugin-i8cx R2-F5: SUITE_REUSE_REASON's wording was
# corrected from "...since the last full run" to "...since the last recorded
# run" — the old wording asserted fullness this string has no way to verify
# (the recorded run may itself have been narrowed by an operator override;
# that fact is disclosed separately, by checks_scope_note/checks_scope_claim
# reading SUITE_REUSE_OVERRIDE_KNOWN). Already the asserted wording in
# .claude/scripts/tests/override-disclosure.test.sh's D3.2 negative control;
# this leg was simply not updated in the same pass.
assert_contains "J: ...and names the SPECIFIC reason" \
    "tree and change-set unchanged since the last recorded run" "$STOP_REASON"
assert_eq "J: ...and never claims the escalation contract (QA_ESCALATED is false throughout this leg)" \
    "0" "$(count_in "$STOP_REASON" 'escalation contract')"

# --- Stop 3: CONTENT-ONLY edit to the SAME path (the k0mc shape). Must RUN. -
printf 'export function handler() { return 1; }\n' > "$FIX_J/src/handler.ts"
printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
fire "$VBS_J"
assert_decision "J: Stop 3 (content-only edit, same path) still blocks" "$STOP_OUT" "block"
NPM_J3=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
NPM_J3=$(printf '%s' "$NPM_J3" | tr -d '[:space:]')
assert_eq "J: Stop 3 DID re-invoke npm (2) — a content-only edit to an already-tracked path is the one thing change_set_hash alone cannot see, and the real hook still catches it" \
    "2" "$NPM_J3"
ITER_J3=$(head -1 "$TRACK_J/iteration-count.$(san "$TID_J")" 2>/dev/null || echo "0")
assert_eq "J: Stop 3 charged a second verification iteration (a genuine run happened)" "2" "$ITER_J3"

# --- Stop 4: seeding rounds is ITSELF a real tree change (RED, measured) ----
# FIRST ATTEMPT at this leg fired straight into a single "Stop 4" after
# seeding three rounds and asserted the skip fired there AND named the skip
# as Stop 4's escalation reason. Neither held, and each RED taught something:
#
#   RED 1 — npm ran a THIRD time (actual 3, expected 2): seed_round's writer
#   (qa-gate.sh review-record) lands its artifact at the rqer-derived path
#   UNDER docs/reviews/ (REVIEW_ARTIFACT_SUBDIR), a real git-visible file, not
#   workflow bookkeeping under .qa-tracking/. Three seeded rounds is three NEW
#   untracked files — exactly the tree movement tree_fingerprint exists to
#   catch. Fixed by splitting into a settling Stop 4 (accepts the real
#   re-run) and a Stop 5 that fires with nothing further touched.
#
#   RED 2, after that split — Stop 5's message still said "per the
#   escalation contract", not the skip reason. Root cause, confirmed by
#   reading the mechanism rather than patching the assertion: by "Stop 4"
#   this leg has ALREADY run the suite for real THREE times (Stop 1, Stop 3,
#   Stop 4), so ITER alone reaches MAX_ITERATIONS=3 there — Stop 4 escalates
#   on ITER ALONE, before ROUNDS enters into it at all, and does so as a
#   GENUINE run (SUITE_REUSED=false at that dispatch), which is the
#   pre-existing, already-correct 2ty case. The qa-escalated LABEL this sets
#   is then already TRUE by the time Stop 5 fires, so Stop 5's own
#   suite-dispatch reads QA_ESCALATED=true BEFORE it ever asks whether a
#   skip is possible — it correctly takes the ORIGINAL escalation-replay
#   branch, and "per the escalation contract" is the ACCURATE thing to say
#   there (a prior escalation genuinely did happen, at Stop 4).
#
#   THE SPECIFIC INTERACTION THE ESC_SUITE_CLAUSE FIX TARGETS — QA_ESCALATED
#   turning true FOR THE FIRST TIME on the exact same Stop a skip fires on,
#   via ROUNDS rather than a prior escalation — could not be constructed in
#   this fixture: reaching it needs ITER to still be BELOW the cap when
#   ROUNDS reaches it, but this leg's own Stop 1/3/4 already spend all three
#   real-run "iterations" getting the skip mechanism itself under test, and
#   the ONLY writer that can seed a round (review-record) always disturbs
#   the tree, so the Stop immediately after seeding is never a skip — by the
#   time one IS possible again, the label from that intervening real run has
#   already made the (correct) escalation-contract reading apply instead.
#   NOT ESTABLISHED, stated plainly rather than left as a red assertion:
#   whether ESC_SUITE_CLAUSE's ROUNDS-alone/still-a-skip branch is reachable
#   in production and, if so, that it renders correctly there. The FIX
#   mirrors the identical, ALREADY-PROVEN pattern in the FAILED_CHECKS path a
#   few hundred lines above (same SUITE_REUSE_REASON default-vs-named-reason
#   branch), so it is not unexercised code — checks_scope_claim/note's
#   parameterisation is unit-tested directly in gate-claim-honesty.test.sh
#   Section 6.11 — but this SPECIFIC call site has inspection, not a driven
#   assertion, behind it.
IR_J="$FIX_J/.claude/scripts/impact-report.sh"
HASH_J3=$(CLAUDE_PROJECT_DIR="$FIX_J" bash "$IR_J" --hash-only 2>/dev/null || echo "")
assert_eq "J: precondition — Stop 3's change set has a computable hash to seed rounds against" \
    "1" "$([ -n "$HASH_J3" ] && echo 1 || echo 0)"
seed_round "$TID_J" 1 "$HASH_J3"
seed_round "$TID_J" 2 "$HASH_J3"
seed_round "$TID_J" 3 "$HASH_J3"

printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
fire "$VBS_J"
NPM_J4=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
NPM_J4=$(printf '%s' "$NPM_J4" | tr -d '[:space:]')
assert_eq "J: Stop 4 DID re-invoke npm (3) — seed_round's real writer (review-record) landed three NEW files under docs/reviews/, which is a genuine tree change the skip correctly refuses to ignore" \
    "3" "$NPM_J4"
ITER_J4=$(head -1 "$TRACK_J/iteration-count.$(san "$TID_J")" 2>/dev/null || echo "0")
assert_eq "J: Stop 4 charged a third verification iteration (a genuine run happened, for the same reason)" "3" "$ITER_J4"
assert_eq "J: Stop 4 escalates on ITER ALONE (the third genuine run reaches MAX_ITERATIONS=3 regardless of ROUNDS)" \
    "1" "$(has_label_ct "$TID_J" "qa-escalated")"

# --- Stop 5: the escalation label now persists from Stop 4, so a
# tree-unchanged replay correctly reads QA_ESCALATED=true at DISPATCH TIME
# and takes the ORIGINAL escalation-replay branch — a regression check that
# the pre-existing "per the escalation contract" reading still fires
# correctly once a real prior escalation exists, unaffected by the new
# skip-when-unchanged branch sitting beside it.
printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
fire "$VBS_J"
NPM_J5=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
NPM_J5=$(printf '%s' "$NPM_J5" | tr -d '[:space:]')
assert_eq "J: Stop 5 did NOT re-invoke npm (still 3) — the escalation contract replay fires, same as it always has" \
    "3" "$NPM_J5"
assert_contains "J: Stop 5's reason IS the escalation banner, correctly attributed to the PRIOR (Stop 4) escalation" \
    "per the escalation contract" "$STOP_REASON"

# ===========================================================================
# META J — narrow the skip predicate to change_set_hash alone, the SAME
# mutation gate-claim-honesty.test.sh's 6M pins in isolation, applied here to
# the real, unmodified verify-before-stop.sh. Stop 3's content-only edit must
# then be WRONGLY skipped.
# ===========================================================================
REAL_VBS_J=$(readlink "$FIX_J/.claude/scripts/verify-before-stop.sh" \
    || printf '%s' "$FIX_J/.claude/scripts/verify-before-stop.sh")
VBS_JM="$FIX_J/.claude/scripts/vbs-hash-only-skip.sh"
sed 's/if \[ "\$fp" = "\$cur_fp" \] && \[ "\$hash" = "\$cur_hash" \]; then/if [ "$hash" = "$cur_hash" ]; then/' \
    "$REAL_VBS_J" > "$VBS_JM"
chmod +x "$VBS_JM"
if assert_mutant_applied "j7kk META-J hash-only skip predicate" "$REAL_VBS_J" "$VBS_JM"; then
    assert_eq "META J: mutated gate parses" "0" \
        "$(bash -n "$VBS_JM" 2>/dev/null && echo 0 || echo 1)"

    # Fresh task, fresh baseline, driven through the MUTANT (the mutation is
    # in the COMPARISON, not the writer — record_verified_state is untouched).
    TID_JM=$(cd "$FIX_J" && bd create "skip-when-unchanged under mutant" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_J" enter "$TID_JM" >/dev/null
    bd label add "$TID_JM" qa-pending >/dev/null 2>&1
    bash "$CT_J" set "$TID_JM" >/dev/null 2>&1
    printf 'export function handler() { return 2; }\n' > "$FIX_J/src/handler.ts"
    (cd "$FIX_J" && git add -A && git commit -qm "JM baseline" 2>/dev/null) || true
    printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_JM" >/dev/null 2>&1
    NPM_JM1=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
    NPM_JM1=$(printf '%s' "$NPM_JM1" | tr -d '[:space:]')

    # Content-only edit to the SAME path — identical shape to Stop 3 above.
    printf 'export function handler() { return 3; }\n' > "$FIX_J/src/handler.ts"
    printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_JM" >/dev/null 2>&1
    NPM_JM2=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
    NPM_JM2=$(printf '%s' "$NPM_JM2" | tr -d '[:space:]')
    assert_eq "META J: SPECIFIC MISBEHAVIOUR — under the hash-only mutant, npm did NOT run again over a REAL content edit (Stop 3's own assertion above would FAIL on this mutant)" \
        "$NPM_JM1" "$NPM_JM2"

    # RESTORE CONTROL: the shipped predicate, an identical scenario (fresh
    # task, same edit shape), still catches it.
    TID_JC=$(cd "$FIX_J" && bd create "skip-when-unchanged restore control" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_J" enter "$TID_JC" >/dev/null
    bd label add "$TID_JC" qa-pending >/dev/null 2>&1
    bash "$CT_J" set "$TID_JC" >/dev/null 2>&1
    printf 'export function handler() { return 4; }\n' > "$FIX_J/src/handler.ts"
    (cd "$FIX_J" && git add -A && git commit -qm "JC baseline" 2>/dev/null) || true
    printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
    fire "$VBS_J"
    NPM_JC1=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
    NPM_JC1=$(printf '%s' "$NPM_JC1" | tr -d '[:space:]')
    printf 'export function handler() { return 5; }\n' > "$FIX_J/src/handler.ts"
    printf 'src/handler.ts\n' > "$TRACK_J/changed-files.txt"
    fire "$VBS_J"
    NPM_JC2=$(grep -c . "$NPM_LOG_J" 2>/dev/null || echo 0)
    NPM_JC2=$(printf '%s' "$NPM_JC2" | tr -d '[:space:]')
    assert_eq "META J: RESTORE CONTROL — the SHIPPED predicate, the identical content-edit shape, DOES re-invoke npm" \
        "1" "$((NPM_JC2 - NPM_JC1))"
fi

# ===========================================================================
# LEG K — R1-F1: A WRITE LANDING DURING THE SUITE'S OWN RUN WINDOW MUST NOT
# BE BLESSED INTO THE SKIP BASELINE (claude-workflow-plugin-j7kk QA round 1).
# See the file header for the property under test.
#
# A real concurrent writer is not needed to reproduce this deterministically:
# the shim standing in for the test runner performs the write itself, as its
# own side effect, before it exits — indistinguishable, from
# verify-before-stop.sh's point of view, from an external process racing it,
# and it gives an exact, reproducible line for WHEN the write lands relative
# to dispatch (inside npm's own invocation, i.e. strictly between
# VERIFY_FP_PRE/VERIFY_HASH_PRE's read and record_verified_state's post-run
# read).
#
# THE MUTATED FILE IS THE ALREADY-TRACKED handler.ts (a content-only rewrite),
# NOT A NEW FILE — measured, not assumed, after a first draft of this leg used
# a new untracked path (src/midrun.ts) and RED-taught the reason not to, the
# same way Leg J's own Stop 4 RED-taught seed_round's tree movement above:
# a new git-visible untracked path is exactly what reconcile_tracker (Leg I's
# subject — it runs on every Stop and folds any not-yet-tracked git-visible
# path into changed-files.txt) exists to fold in, so it ALSO moves
# current_change_set_hash at the NEXT Stop, independently of anything
# record_verified_state does. That gave META K's mutant a SECOND, unrelated
# reason for Stop 2 to correctly re-run (a genuinely new tracked path), which
# masked the specific misbehaviour this leg exists to catch — measured
# directly: the mutant's Stop 2 re-ran npm regardless of the R1-F1 fix being
# reverted or not, so the leg could not tell the two apart. A content-only
# edit to a path ALREADY in changed-files.txt moves tree_fingerprint's diff
# hash (the content changed) without moving current_change_set_hash's path
# list (the path was already there) and without ever creating a new
# git-visible path for reconcile_tracker to react to — the SAME isolation
# Leg J's Stop 3 already uses, for the same reason: an unambiguous read on
# which comparison caught the mismatch, with no second mechanism able to
# produce the same observable.
# ---------------------------------------------------------------------------

mk_fixture
FIX_K="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
VBS_K="$FIX_K/.claude/scripts/verify-before-stop.sh"
QG_K="$FIX_K/.claude/scripts/qa-gate.sh"
CT_K="$FIX_K/.claude/scripts/current-task.sh"
TRACK_K="$FIX_K/.claude/.qa-tracking"
stack_stub "$FIX_K" "$NPM_RUNNER_JSON"

printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIX_K/.gitignore"
mkdir -p "$FIX_K/src"
printf 'export function handler() {}\n' > "$FIX_K/src/handler.ts"
(cd "$FIX_K" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# The "npm" shim under test for this leg: logs its invocation (the same
# convention every other leg's NPM_LOG counts against — mk_shim's own
# generator produces an identical logging line, reused verbatim below), THEN
# mutates the ALREADY-TRACKED src/handler.ts in place (a fresh random suffix
# each invocation, so consecutive runs are never a no-op rewrite) as its own
# side effect, before it exits 0. mk_shim (shim.sh) has no hook for a side
# effect beyond logging + a fixed exit code, so this shim is hand-authored
# the same way stack_stub's detector stub is (above).
NPM_BIN_K=$(mk_shim_dir "$FIX_K")
NPM_LOG_K="$NPM_BIN_K/npm.log"
: > "$NPM_LOG_K"
NPM_MUTATE_FILE_K="$FIX_K/src/handler.ts"
{
    printf '#!/bin/bash\n'
    printf '# Test-time npm shim (escalation-basis LEG K, claude-workflow-plugin-j7kk\n'
    printf '# R1-F1): logs its invocation, THEN rewrites the ALREADY-TRACKED\n'
    printf '# src/handler.ts in place as a side effect, simulating a write landing\n'
    printf '# DURING the suite dispatch window.\n'
    printf 'printf "%%s\\n" "$*" >> %q\n' "$NPM_LOG_K"
    printf 'printf "export function handler() { return %%d; }\\n" "$RANDOM" > %q\n' "$NPM_MUTATE_FILE_K"
    printf 'printf "%%s\\n" %q\n' "PASS  12 tests passed"
    printf 'exit 0\n'
} > "$NPM_BIN_K/npm"
chmod +x "$NPM_BIN_K/npm"

TID_K=$(cd "$FIX_K" && bd create "skip-when-unchanged mid-run write" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_K" enter "$TID_K" >/dev/null
bd label add "$TID_K" qa-pending >/dev/null 2>&1
bash "$CT_K" set "$TID_K" >/dev/null 2>&1
printf 'src/handler.ts\n' > "$TRACK_K/changed-files.txt"

HANDLER_BASELINE_K=$(cat "$NPM_MUTATE_FILE_K")
fire "$VBS_K"
assert_decision "K: Stop 1 (genuine run; npm rewrites the already-tracked handler.ts as a side effect) blocks — no approval yet" "$STOP_OUT" "block"
NPM_K1=$(grep -c . "$NPM_LOG_K" 2>/dev/null || echo 0)
NPM_K1=$(printf '%s' "$NPM_K1" | tr -d '[:space:]')
assert_eq "K: Stop 1 really ran npm once" "1" "$NPM_K1"
assert_eq "K: precondition — the shim's mid-run write really changed handler.ts's content" \
    "yes" "$([ "$(cat "$NPM_MUTATE_FILE_K")" != "$HANDLER_BASELINE_K" ] && echo yes || echo no)"
assert_eq "K: precondition — and it is STILL the same path (a content-only edit, the k0mc shape, not a new file)" \
    "yes" "$([ -e "$NPM_MUTATE_FILE_K" ] && echo yes || echo no)"

# R1-F1's OWN CLAIM, MEASURED: the write happened DURING npm's invocation,
# which happened DURING the dispatch this Stop just performed, so it landed
# strictly between VERIFY_FP_PRE/VERIFY_HASH_PRE's read and
# record_verified_state's own post-run read. Nothing else touches $FIX_K
# between Stop 1 and Stop 2 below.
STATE_GLOB_K=$(cd "$FIX_K" && ls .claude/.qa-tracking/last-verified-state.* 2>/dev/null | head -1)
assert_eq "K: FIXED BEHAVIOUR — Stop 1 persisted NO skip-state record: record_verified_state's post-run reading disagreed with the pre-dispatch reading (the mid-run write moved tree_fingerprint) and it refused to persist rather than blessing content the suite did not measure end-to-end" \
    "no" "$([ -n "$STATE_GLOB_K" ] && [ -s "$FIX_K/$STATE_GLOB_K" ] && echo yes || echo no)"

# --- Stop 2: nothing further has touched the tree since Stop 1 ended. If
# R1-F1 were still live, Stop 1's post-mutation tree would have been
# persisted as "verified", Stop 2 would read the identical (still
# post-mutation) tree and skip — replaying a result the suite never measured
# end-to-end. The fix means there is no record to match against, so Stop 2
# must run for real. This IS "the following Stop re-runs for real" — QA's own
# specified acceptance for R1-F1.
printf 'src/handler.ts\n' > "$TRACK_K/changed-files.txt"
fire "$VBS_K"
assert_decision "K: Stop 2 (nothing touched since Stop 1) still blocks" "$STOP_OUT" "block"
NPM_K2=$(grep -c . "$NPM_LOG_K" 2>/dev/null || echo 0)
NPM_K2=$(printf '%s' "$NPM_K2" | tr -d '[:space:]')
assert_eq "K: Stop 2 DID re-invoke npm (2) — a false skip here would leave NPM_K2 at 1" \
    "2" "$NPM_K2"
assert_eq "K: ...and never claims the tree/change-set-unchanged skip reason" \
    "0" "$(count_in "$STOP_REASON" 'tree and change-set unchanged')"

# ===========================================================================
# META K — restore the PRE-FIX record_verified_state (the pre/post comparison
# this round added is neutralised to `if false; then`, so the function always
# persists its own post-run reading regardless of what the caller measured
# before dispatch — exactly R1-F1's shape) in a copy of the REAL, unmodified
# verify-before-stop.sh. Driven through the IDENTICAL mid-run-mutating shim,
# Stop 1 must now persist a record despite the mid-run write, and Stop 2 must
# WRONGLY skip — reproducing R1-F1 exactly, and proving Leg K's Stop 2
# assertion above is the one QA's finding depended on, not an artifact of
# fixture shape.
# ===========================================================================
REAL_VBS_K=$(readlink "$FIX_K/.claude/scripts/verify-before-stop.sh" \
    || printf '%s' "$FIX_K/.claude/scripts/verify-before-stop.sh")
VBS_KM="$FIX_K/.claude/scripts/vbs-r1f1-unconditional-persist.sh"
sed 's/if \[ "\$fp_pre" != "\$fp_post" \] || \[ "\$hash_pre" != "\$hash_post" \]; then/if false; then/' \
    "$REAL_VBS_K" > "$VBS_KM"
chmod +x "$VBS_KM"
if assert_mutant_applied "j7kk META-K R1-F1 unconditional-persist mutant" "$REAL_VBS_K" "$VBS_KM"; then
    assert_eq "META K: mutated gate parses" "0" \
        "$(bash -n "$VBS_KM" 2>/dev/null && echo 0 || echo 1)"
    # WHICH mutation landed, the same discriminator style 0in1's META-I and
    # this file's own 6M/META-J use: the specific comparison is gone and the
    # unconditional-persist replacement stands in its place.
    # shellcheck disable=SC2016  # matching literal source text, not expanding.
    assert_eq "META K: non-vacuity — the specific pre/post comparison is gone from the mutant" \
        "0" "$(grep -c 'if \[ "\$fp_pre" != "\$fp_post" \]' "$VBS_KM" | tr -d '[:space:]')"
    assert_eq "META K: ...and the unconditional-persist replacement landed" \
        "1" "$(grep -c 'if false; then' "$VBS_KM" | tr -d '[:space:]')"

    TID_KM=$(cd "$FIX_K" && bd create "skip-when-unchanged mid-run write under R1-F1 mutant" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_K" enter "$TID_KM" >/dev/null
    bd label add "$TID_KM" qa-pending >/dev/null 2>&1
    bash "$CT_K" set "$TID_KM" >/dev/null 2>&1
    printf 'export function handler() { return 9; }\n' > "$FIX_K/src/handler.ts"
    (cd "$FIX_K" && git add -A && git commit -qm "META K baseline" 2>/dev/null) || true
    printf 'src/handler.ts\n' > "$TRACK_K/changed-files.txt"

    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_KM" >/dev/null 2>&1
    NPM_KM1=$(grep -c . "$NPM_LOG_K" 2>/dev/null || echo 0)
    NPM_KM1=$(printf '%s' "$NPM_KM1" | tr -d '[:space:]')
    STATE_GLOB_KM=$(cd "$FIX_K" && ls ".claude/.qa-tracking/last-verified-state.$(san "$TID_KM")" 2>/dev/null)
    assert_eq "META K: SPECIFIC MISBEHAVIOUR — under the R1-F1 mutant, Stop 1 DID persist a skip-state record despite the mid-run write (Leg K's own 'FIXED BEHAVIOUR' assertion above would FAIL on this mutant)" \
        "yes" "$([ -n "$STATE_GLOB_KM" ] && [ -s "$FIX_K/$STATE_GLOB_KM" ] && echo yes || echo no)"

    printf 'src/handler.ts\n' > "$TRACK_K/changed-files.txt"
    printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_KM" >/dev/null 2>&1
    NPM_KM2=$(grep -c . "$NPM_LOG_K" 2>/dev/null || echo 0)
    NPM_KM2=$(printf '%s' "$NPM_KM2" | tr -d '[:space:]')
    assert_eq "META K: SPECIFIC MISBEHAVIOUR — Stop 2 under the mutant WRONGLY skips (npm did not run again): the exact R1-F1 defect, replaying a green the suite never measured end-to-end over the mutated tree" \
        "$NPM_KM1" "$NPM_KM2"

    # RESTORE CONTROL: the shipped predicate, an identical mid-run-mutating
    # shim, fresh task — does NOT reproduce the misbehaviour.
    TID_KC=$(cd "$FIX_K" && bd create "skip-when-unchanged mid-run write restore control" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$QG_K" enter "$TID_KC" >/dev/null
    bd label add "$TID_KC" qa-pending >/dev/null 2>&1
    bash "$CT_K" set "$TID_KC" >/dev/null 2>&1
    printf 'export function handler() { return 10; }\n' > "$FIX_K/src/handler.ts"
    (cd "$FIX_K" && git add -A && git commit -qm "KC baseline" 2>/dev/null) || true
    printf 'src/handler.ts\n' > "$TRACK_K/changed-files.txt"
    fire "$VBS_K"
    NPM_KC1=$(grep -c . "$NPM_LOG_K" 2>/dev/null || echo 0)
    NPM_KC1=$(printf '%s' "$NPM_KC1" | tr -d '[:space:]')

    printf 'src/handler.ts\n' > "$TRACK_K/changed-files.txt"
    fire "$VBS_K"
    NPM_KC2=$(grep -c . "$NPM_LOG_K" 2>/dev/null || echo 0)
    NPM_KC2=$(printf '%s' "$NPM_KC2" | tr -d '[:space:]')
    assert_eq "META K: RESTORE CONTROL — the SHIPPED predicate, the identical mid-run-mutating shim, DOES re-invoke npm at the following Stop" \
        "1" "$((NPM_KC2 - NPM_KC1))"
fi

[ "$FAIL" -eq 0 ]
