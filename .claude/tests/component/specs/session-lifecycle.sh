#!/bin/bash
# session-lifecycle.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers session-start.sh and
# session-end.sh. Per the docs, SessionStart emits hookSpecificOutput with
# event=SessionStart + additionalContext; SessionEnd emits `{}`.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# session-start.sh queries bd for ready/in-progress task lists; without
# bd the rendered additionalContext is missing the bullets the assertions
# look for.
bd_required_or_skip

SS="$FIXTURE/.claude/scripts/session-start.sh"
SE="$FIXTURE/.claude/scripts/session-end.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# 1. session-start emits SessionStart envelope with additionalContext.
OUT=$(printf '%s' '{}' | bash "$SS" 2>/dev/null)
assert_valid_envelope "session-start: envelope valid" "$OUT"
assert_hook_event "session-start: event=SessionStart" "$OUT" "SessionStart"
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "session-start: context contains workflow_engine" \
    '<workflow_engine source=' "$CTX"

# 2. session-start clears stale QA tracking files (B10 / B11).
# Plant a stale changed-files.txt + edit-count, then run session-start
# and confirm they're gone.
printf '/old/path.ts\n' > "$TRACK/changed-files.txt"
printf '5\n' > "$TRACK/edit-count"
printf '%s' '{}' | bash "$SS" >/dev/null 2>&1
assert_eq "session-start: stale changed-files.txt cleared" "1" \
    "$([ -s "$TRACK/changed-files.txt" ] && echo 0 || echo 1)"
assert_eq "session-start: stale edit-count cleared" "1" \
    "$([ -s "$TRACK/edit-count" ] && echo 0 || echo 1)"

# 3. session-start touches .session-start marker so post-edit etc. can
# see a fresh session.
assert_eq "session-start: .session-start marker created" "0" \
    "$([ -f "$FIXTURE/.claude/.session-start" ] && echo 0 || echo 1)"

# 4. Surfaced bd warnings: plant a stale sync-errors.log, confirm next
# SessionStart surfaces a warning AND truncates the log.
SYNC_LOG="$TRACK/sync-errors.log"
printf '2026-01-01T00:00:00Z\t[verify-before-stop]\tledger export failed: test scenario\n' > "$SYNC_LOG"
OUT=$(printf '%s' '{}' | bash "$SS" 2>/dev/null)
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "session-start: surfaces prior bd-sync error" \
    "Beads sync error" "$CTX"
# Log truncated (size 0).
LOG_SIZE=$(wc -c < "$SYNC_LOG" | tr -d ' ')
assert_eq "session-start: sync log truncated after surfacing" "0" "$LOG_SIZE"

# 5. session-end emits `{}` per the hooks reference (no decision control).
OUT=$(printf '%s' '{"reason":"clear"}' | bash "$SE" 2>/dev/null)
assert_empty_envelope "session-end: returns {}" "$OUT"

# 6. session-end is idempotent — running twice doesn't fail.
RC=0
printf '%s' '{"reason":"clear"}' | bash "$SE" >/dev/null 2>&1 || RC=$?
assert_eq "session-end: idempotent rc=0" "0" "$RC"

# 7. session-end with bd-unavailable PATH still emits {} (graceful degrade).
# Strip the fixture's bin/ from PATH (which has the bd wrapper) for one call.
# We can't easily strip bd from PATH without breaking the parent shell, so
# this is asserted by a sub-bash with cleaned PATH.
OUT=$(PATH=/usr/bin:/bin bash -c "echo '{\"reason\":\"clear\"}' | bash '$SE'" 2>/dev/null)
assert_empty_envelope "session-end: bd-unavailable graceful" "$OUT"

# ===========================================================================
# SECTION 8 — THE TRACKER SURVIVES A SESSION BOUNDARY WHILE A CYCLE IS IN
# FLIGHT (claude-workflow-plugin-94d.1).
#
# THE DEFECT. Section 2 above pins that SessionStart resets changed-files.txt,
# and that is right for a NEW session. It used to be unconditional — and
# SessionStart fires on `startup`, `resume`, `clear` AND `compact`, so a
# conversation that compacted in the middle of a QA review deleted the change
# set out from under the review reading it. Reproduced live on this repo's own
# 94d review: 26 tracked paths -> 0, then `qa-gate.sh enter`'s reconcile rebuilt
# 10 of them from `git status` minus a 35-hour-old gate baseline. Every step
# reported ok:true and change_set_hash moved 01296db9... -> 0b5a546e...
#
# WHY PREVENTION HAS TO BE HERE AND NOT IN THE RECONCILER. A rebuild from `git
# status` can only ever be a SUBSET of what was lost. Of the 16 paths that went,
# TWO were invisible to git at all: one whose content had been reverted (so it
# was not dirty) and one `.claude/.qa-tracking/` artifact, which the shared
# self-written rule keeps out of the change set by design. No baseline fix and no
# accounting can recover those, so the file must not be deleted in the first
# place.
#
# THE PREDICATE IS `current-task`, IDENTICAL to the one the gate-baseline capture
# in the same hook has used since 3mg.1. Section 8.3 pins that it needs NOTHING
# from bd — no task record, no label read — which is what keeps this decision
# working in a degraded install (the C0c contract) and what stops the two
# decisions in this hook from ever disagreeing about whether a cycle is open.
# ===========================================================================
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACKER="$TRACK/changed-files.txt"

# 8.1 CONTROL, local to this section so the flip below is unambiguous: with no
# cycle in flight the reset still happens (this is section 2's behaviour, and it
# must not have been traded away for the preserve).
bash "$CT" clear >/dev/null 2>&1
printf '/work/one.ts\n/work/two.ts\n' > "$TRACKER"
printf '%s' '{}' | bash "$SS" >/dev/null 2>&1
assert_eq "session-start 8.1: CONTROL — no cycle in flight, the tracker is still reset" "gone" \
    "$([ -s "$TRACKER" ] && echo kept || echo gone)"

# 8.2 THE GUARD. Same input, one variable changed: a cycle is in flight.
printf '/work/one.ts\n/work/two.ts\n' > "$TRACKER"
TRACKER_BEFORE=$(cat "$TRACKER")
bash "$CT" set "session-lifecycle-94d1-task" >/dev/null 2>&1
printf '%s' '{"source":"compact"}' | bash "$SS" >/dev/null 2>&1
assert_eq "session-start 8.2: with a cycle in flight the tracker SURVIVES (was: deleted)" "kept" \
    "$([ -s "$TRACKER" ] && echo kept || echo gone)"
assert_eq "session-start 8.2: ...BYTE-IDENTICAL — preserved, not partially rebuilt" \
    "$TRACKER_BEFORE" "$(cat "$TRACKER" 2>/dev/null || echo '')"
assert_eq "session-start 8.2: ...and it survives a SECOND boundary too (idempotent, not one-shot)" "kept" \
    "$(printf '%s' '{"source":"resume"}' | bash "$SS" >/dev/null 2>&1; [ -s "$TRACKER" ] && echo kept || echo gone)"

# 8.3 THE GUARD NEEDS NOTHING FROM bd. The id set above names no real Beads
# issue, and 8.2 preserved anyway. That is the property that makes this decision
# survive a degraded install — and the reason the predicate is not conjoined with
# a qa-gate-entered/qa-pending label read: a label read would make a decision
# about a local file depend on bd + jq + a `bd show` round-trip, and would ALSO
# re-open the asymmetry from the other end (current-task set, no label => the
# baseline capture skips on the loose predicate while the delete fires on the
# strict one, which is the same lost-change-set state by another route).
assert_eq "session-start 8.3: precondition — the preserved cycle's id is NOT a real Beads issue" "absent" \
    "$(bd show "session-lifecycle-94d1-task" --json >/dev/null 2>&1 && echo present || echo absent)"
assert_eq "session-start 8.3: ...so the preserve cannot have come from a label read" "kept" \
    "$([ -s "$TRACKER" ] && echo kept || echo gone)"

# 8.4 IT SAYS SO. Invisibility is what made 94d.1 expensive: whoever resumed the
# review read a smaller, well-formed change set with nothing anywhere reporting
# the shrink. A silent preserve would fix the data and leave the operator with no
# way to tell a carried-over tracker from a fresh one.
OUT8=$(printf '%s' '{"source":"compact"}' | bash "$SS" 2>/dev/null)
assert_valid_envelope "session-start 8.4: the envelope is still valid with the preserve active" "$OUT8"
CTX8=$(printf '%s' "$OUT8" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_contains "session-start 8.4: the context REPORTS the carry-over" \
    "change-set tracker CARRIED OVER" "$CTX8"
assert_contains "session-start 8.4: ...naming the cycle it is held for" \
    "session-lifecycle-94d1-task" "$CTX8"
assert_contains "session-start 8.4: ...and the count, so a reader can compare it against the review" \
    "2 path(s)" "$CTX8"
assert_contains "session-start 8.4: ...and the recovery for a cycle that is actually finished" \
    "current-task.sh clear" "$CTX8"

# 8.5 THE DISCRIMINATOR. Clear the cycle, change nothing else, and the reset
# comes back — so 8.2 is caused by the in-flight cycle and not by the guard
# having simply stopped deleting.
bash "$CT" clear >/dev/null 2>&1
printf '%s' '{}' | bash "$SS" >/dev/null 2>&1
assert_eq "session-start 8.5: clearing the cycle restores the reset (8.2 is caused by the cycle)" "gone" \
    "$([ -s "$TRACKER" ] && echo kept || echo gone)"

# 8.6 THE READ ITSELF MUST NOT BE THE WEAK LINK (claude-workflow-plugin-94d.1.1,
# QA finding R6-F1). The guard above decides on `current-task`, but it used to
# LEARN that fact only through `[ -f .claude/scripts/current-task.sh ]` — a probe
# for the sibling HELPER, not for the state file the helper writes. Reproduced by
# QA: state file says a cycle is in flight, helper moved aside, SS_ACTIVE_TASK
# empty, tracker destroyed, silently, with a valid envelope.
#
# It is a real degraded install rather than a hypothetical: `qa-gate.sh`'s
# write_current_task explicitly supports the helper-absent case with a direct
# write, and reconcile_tracker reads the same file directly — so two other
# consumers already treat the state file as the source of truth and tolerate the
# helper's absence. Only this read did not.
#
# Both consumers of the hoisted read are covered by one fix, which is why the
# fallback is to the FACT and not to a "preserve when the probe fails" flag: a
# flag honoured by the tracker guard but not by the baseline capture would
# re-open the very asymmetry the hoisting closed.
CT_REAL=$(readlink "$CT" 2>/dev/null || printf '%s' "$CT")
bash "$CT" set "session-lifecycle-94d11-task" >/dev/null 2>&1
printf '/degraded/one.ts\n/degraded/two.ts\n' > "$TRACKER"
TRACKER_BEFORE_DEGRADED=$(cat "$TRACKER")
rm -f "$CT"
assert_eq "session-start 8.6: precondition — the helper really is absent" "absent" \
    "$([ -e "$CT" ] && echo present || echo absent)"
assert_eq "session-start 8.6: precondition — and the state file still names a cycle" "yes" \
    "$([ -s "$TRACK/current-task" ] && echo yes || echo no)"
OUT86=$(printf '%s' '{"source":"compact"}' | bash "$SS" 2>/dev/null)
assert_eq "session-start 8.6: helper absent + cycle in flight -> the tracker SURVIVES (was: destroyed)" \
    "kept" "$([ -s "$TRACKER" ] && echo kept || echo gone)"
assert_eq "session-start 8.6: ...BYTE-IDENTICAL, so it was preserved and not rebuilt" \
    "$TRACKER_BEFORE_DEGRADED" "$(cat "$TRACKER" 2>/dev/null || echo '')"
assert_valid_envelope "session-start 8.6: ...on a still-valid envelope (the hook never blocks)" "$OUT86"
CTX86=$(printf '%s' "$OUT86" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_contains "session-start 8.6: ...and the carry-over is still REPORTED in a degraded install" \
    "change-set tracker CARRIED OVER" "$CTX86"
assert_contains "session-start 8.6: ...naming the cycle it read from the state file" \
    "session-lifecycle-94d11-task" "$CTX86"
# 8.6b DISCRIMINATOR: helper still absent, but the state file no longer names a
# cycle. The reset must come back — so 8.6 is caused by the file's CONTENT and not
# by the helper's absence having become a blanket "always preserve".
: > "$TRACK/current-task"
printf '/degraded/one.ts\n' > "$TRACKER"
printf '%s' '{}' | bash "$SS" >/dev/null 2>&1
assert_eq "session-start 8.6b: helper absent + NO cycle -> the reset still happens (not a blanket preserve)" \
    "gone" "$([ -s "$TRACKER" ] && echo kept || echo gone)"
ln -sf "$CT_REAL" "$CT"
bash "$CT" clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 8M META (spec-mandated): strip the TRACKER-PRESERVE region from a fixture copy
# of session-start.sh and the tracker must be DESTROYED mid-cycle again.
#
# The region is arranged so that stripping it yields the PRE-FIX code rather than
# a no-op: the `rm -f` lives OUTSIDE the sentinels behind
# `if [ "${SS_TRACKER_KEEP:-0}" != "1" ]`, so with the region gone the variable is
# unset, the default is 0, and the delete is unconditional — byte-for-byte what
# shipped before 94d.1. Same construction as post-edit.sh's `_PE_RESOLVED=""`
# ahead of its SECOND-CHANCE region. A strip that merely removed the `rm` would
# make the tracker survive for the WRONG reason and this META would pass against
# a broken hook.
#
# The copy replaces the fixture's symlink in `.claude/scripts/` so it keeps
# resolving its siblings (current-task.sh, qa-gate.sh) BASH_SOURCE-relative, the
# same constraint gate-baseline-v2.sh's 7M and post-edit.sh's METAs work under.
# Anchored patterns (`^ *#`) for the R4-F5 reason: unanchored, a prose line
# naming the sentinel mid-sentence would start the excision early.
strip_tracker_preserve() {
    awk '
        /^ *# TRACKER-PRESERVE BEGIN/ { skip = 1; next }
        /^ *# TRACKER-PRESERVE END/   { skip = 0; next }
        !skip { print }
    ' "$1" > "$2"
}
SS_REAL=$(readlink "$SS" || printf '%s' "$SS")
META8_DIR="$TRACK/meta8"
mkdir -p "$META8_DIR"
strip_tracker_preserve "$SS_REAL" "$META8_DIR/session-start.stripped.sh"

# THE GUARD FIRST (R4-F4): a strip that matched nothing leaves a byte-identical
# copy, and then every leg below measures the SHIPPED hook while reporting on a
# mutant — a green run that proves nothing.
if assert_mutant_applied "session-start 8M META" "$SS_REAL" "$META8_DIR/session-start.stripped.sh"; then
    assert_eq "session-start 8M META: the strip removed lines (non-vacuous)" "smaller" \
        "$([ "$(grep -c . "$META8_DIR/session-start.stripped.sh")" -lt "$(grep -c . "$SS_REAL")" ] && echo smaller || echo same)"
    assert_eq "session-start 8M META: no SS_TRACKER_KEEP assignment survives (the mutation landed where it was aimed)" \
        "0" "$(grep -c 'SS_TRACKER_KEEP=' "$META8_DIR/session-start.stripped.sh" | tr -d '[:space:]')"
    # Counted on the CODE line, not on the identifier: the paragraph above the
    # guard quotes `${SS_TRACKER_KEEP:-0}` in prose to explain why the default is
    # there, so a bare identifier grep answers 2 and this leg would fail for a
    # reason that has nothing to do with the mutation.
    assert_eq "session-start 8M META: ...while the rm's guard SURVIVES, defaulting to DELETE (only the decision was removed)" \
        "1" "$(grep -c -x -F 'if [ "${SS_TRACKER_KEEP:-0}" != "1" ]; then' "$META8_DIR/session-start.stripped.sh" | tr -d '[:space:]')"
    assert_eq "session-start 8M META: ...and the rm itself survives inside it" "1" \
        "$(grep -c 'rm -f "\$QA_TRACKING_DIR/changed-files.txt"' "$META8_DIR/session-start.stripped.sh" | tr -d '[:space:]')"
    assert_eq "session-start 8M META: the stripped copy still parses" "0" \
        "$(bash -n "$META8_DIR/session-start.stripped.sh" 2>/dev/null && echo 0 || echo 1)"

    # --- strip leg: the 94d.1 failure, reproduced ---
    rm -f "$SS"
    cp "$META8_DIR/session-start.stripped.sh" "$SS"
    chmod +x "$SS"
    printf '/work/one.ts\n/work/two.ts\n' > "$TRACKER"
    bash "$CT" set "session-lifecycle-94d1-task" >/dev/null 2>&1
    OUT8M=$(printf '%s' '{"source":"compact"}' | bash "$SS" 2>/dev/null)
    assert_eq "session-start 8M META: with the guard stripped the tracker is DESTROYED mid-cycle (8.2 WOULD fail)" \
        "gone" "$([ -s "$TRACKER" ] && echo kept || echo gone)"
    assert_valid_envelope "session-start 8M META: ...and the hook still emitted a valid envelope, so the loss is silent" \
        "$OUT8M"
    CTX8M=$(printf '%s' "$OUT8M" | jq -r '.hookSpecificOutput.additionalContext // empty')
    assert_not_contains "session-start 8M META: ...with nothing anywhere reporting it (8.4 WOULD fail)" \
        "change-set tracker CARRIED OVER" "$CTX8M"

    # --- restore control: same state, shipped hook, the tracker survives again ---
    rm -f "$SS"
    ln -sf "$SS_REAL" "$SS"
    printf '/work/one.ts\n/work/two.ts\n' > "$TRACKER"
    bash "$CT" set "session-lifecycle-94d1-task" >/dev/null 2>&1
    printf '%s' '{"source":"compact"}' | bash "$SS" >/dev/null 2>&1
    assert_eq "session-start 8M META: restore control — the shipped hook preserves it again" "kept" \
        "$([ -s "$TRACKER" ] && echo kept || echo gone)"
fi
bash "$CT" clear >/dev/null 2>&1

# ---------------------------------------------------------------------------
# 8.6M META (QA finding R7-F3): strip the STATE-FILE-FALLBACK region and leg 8.6
# must go blind again — the tracker destroyed mid-cycle because the sibling helper
# was unreadable.
#
# WHY THIS EXISTS SEPARATELY FROM 8M. 8M strips the DECISION (TRACKER-PRESERVE);
# this strips the READ the decision is made on. They fail in the same visible way
# — tracker gone, valid envelope, nothing reported — from opposite causes, and
# only this one proves leg 8.6 is SENSITIVE to the fallback rather than passing
# because something else in the fixture happened to preserve the file. 94d.1.1
# shipped without it, with 8.6/8.6b as its only guard.
#
# The region is arranged so the strip yields the PRE-94d.1.1 read: the helper
# probe and the `SS_ACTIVE_TASK=""` default live OUTSIDE the sentinels, so the
# stripped copy still parses and simply has no second source of the fact.
strip_state_file_fallback() {
    awk '
        /^ *# STATE-FILE-FALLBACK BEGIN/ { skip = 1; next }
        /^ *# STATE-FILE-FALLBACK END/   { skip = 0; next }
        !skip { print }
    ' "$1" > "$2"
}
META86_DIR="$TRACK/meta86"
mkdir -p "$META86_DIR"
strip_state_file_fallback "$SS_REAL" "$META86_DIR/session-start.stripped.sh"
if assert_mutant_applied "session-start 8.6M META" "$SS_REAL" "$META86_DIR/session-start.stripped.sh"; then
    assert_eq "session-start 8.6M META: no state-file read survives (the strip landed where it was aimed)" \
        "0" "$(grep -c 'QA_TRACKING_DIR/current-task"' "$META86_DIR/session-start.stripped.sh" | tr -d '[:space:]')"
    # On the CODE line, not the identifier: the surviving prose names the variable
    # repeatedly, so a bare identifier grep would answer >1 and this leg would fail
    # for a reason unrelated to the mutation.
    assert_eq "session-start 8.6M META: ...while the empty DEFAULT survives outside it (so the copy is coherent)" \
        "1" "$(grep -c -x -F 'SS_ACTIVE_TASK=""' "$META86_DIR/session-start.stripped.sh" | tr -d '[:space:]')"
    assert_eq "session-start 8.6M META: ...and the TRACKER-PRESERVE decision is untouched by this strip" \
        "1" "$(grep -c -x -F 'if [ "${SS_TRACKER_KEEP:-0}" != "1" ]; then' "$META86_DIR/session-start.stripped.sh" | tr -d '[:space:]')"
    assert_eq "session-start 8.6M META: the stripped copy still parses" "0" \
        "$(bash -n "$META86_DIR/session-start.stripped.sh" 2>/dev/null && echo 0 || echo 1)"

    # --- strip leg: leg 8.6's exact state, with the fallback removed ---
    CT_REAL_86=$(readlink "$CT" 2>/dev/null || printf '%s' "$CT")
    bash "$CT" set "session-lifecycle-86m-task" >/dev/null 2>&1
    printf '/degraded/one.ts\n/degraded/two.ts\n' > "$TRACKER"
    rm -f "$SS"
    cp "$META86_DIR/session-start.stripped.sh" "$SS"
    chmod +x "$SS"
    rm -f "$CT"
    assert_eq "session-start 8.6M META: precondition — helper absent, state file still names a cycle" \
        "yes" "$([ ! -e "$CT" ] && [ -s "$TRACK/current-task" ] && echo yes || echo no)"
    OUT86M=$(printf '%s' '{"source":"compact"}' | bash "$SS" 2>/dev/null)
    assert_eq "session-start 8.6M META: with the fallback stripped the tracker is DESTROYED (8.6 WOULD fail)" \
        "gone" "$([ -s "$TRACKER" ] && echo kept || echo gone)"
    assert_valid_envelope "session-start 8.6M META: ...on a valid envelope, so the loss is silent" "$OUT86M"

    # --- restore control: the shipped hook, identical degraded state, survives ---
    rm -f "$SS"
    ln -sf "$SS_REAL" "$SS"
    printf '/degraded/one.ts\n/degraded/two.ts\n' > "$TRACKER"
    printf '%s' '{"source":"compact"}' | bash "$SS" >/dev/null 2>&1
    assert_eq "session-start 8.6M META: restore control — the shipped hook reads the state file and preserves it" \
        "kept" "$([ -s "$TRACKER" ] && echo kept || echo gone)"
    ln -sf "$CT_REAL_86" "$CT"
    bash "$CT" clear >/dev/null 2>&1
fi

[ "$FAIL" -eq 0 ]
