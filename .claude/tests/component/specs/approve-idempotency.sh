#!/bin/bash
# approve-idempotency.sh — L2 component spec for claude-workflow-plugin-gz3
# (v4.1 U1): the hash-aware approve guard, the approve-commit ORDER, and the
# approve/Stop race.
#
# WHAT WENT WRONG (two defects, one root disagreement)
# ----------------------------------------------------
# llh.18 moved the Stop hook's release predicate off the qa-approved LABEL and
# onto a RECORD bound to the current change-set hash. `qa-gate.sh approve` kept
# treating the label as proof of approval: `had_approved=1 -> idempotent no-op`.
# Two consequences, both observed live:
#
#   1. DEADLOCK. A Stop blocked with LABEL_WITHOUT_RECORD prints
#      `enter -> impact-report -> approve`. `enter` does not clear qa-approved,
#      so `approve` short-circuited and wrote no new record — following the
#      printed remediation EXACTLY re-blocked, forever. The working recovery was
#      an undocumented `bd label remove <tid> qa-approved` first.
#   2. RACE, in three windows. `approve` runs in another process (the QA
#      subagent) while the Stop hook runs in the parent session, so every
#      intermediate state of cmd_approve is observable:
#        W1  a Stop between the label add and the record write — pre-fix the
#            label went FIRST — sees label-without-record: the forged-label
#            block, for a legitimate in-flight approval.
#        W2  a Stop between clear_current_task and the truncation — pre-fix
#            current-task was cleared FIRST — blocks with "No active Beads
#            task detected" for work that was just approved.
#        W3  a Stop whose OWN two change-set reads (detection stage, then the
#            hash recompute after the test pass) straddle the truncation
#            recomputes the EMPTY-SET hash and matches no record.
#      W3 was observed live during the v4.1 wave: the block reason named
#      `e3b0c44298fc...` (sha256 of the empty list) as the "current" hash, which
#      is this race's fingerprint (occurrence recorded on gz3). All three windows
#      were then reproduced deterministically against the PRE-FIX scripts at the
#      drive points reused below, before any code moved.
#
# The fixes are symmetrical: approve's idempotency is now hash-aware (no-op only
# when a record already binds the change set this approve would bind), approve's
# commit order closes W1 and W2, and the Stop hook re-derives "is there anything
# left to review?" before emitting that block (W3, which no approve-side ordering
# can close).
#
# SECTIONS
#   A. THE PRINTED REMEDIATION RECOVERS. The recipe is EXTRACTED FROM THE BLOCK
#      TEXT and executed verbatim — a wording change that outruns the behaviour
#      fails here.
#   B. The idempotency contract, preserved where it was right: a re-approve
#      whose change set is already bound is still a no-op, on both the
#      re-seeded-tracker path and the post-approve (truncated) tracker path —
#      where the persisted impact report is the only surviving witness.
#   C. ...and NOT preserved where it was wrong: a stale impact report still
#      earns the staleness REFUSAL instead of a silent no-op.
#   D. Reader-grammar parity: the writer reads its own records back with the
#      byte-identical expression the Stop hook releases on.
#   E. Approve-commit ORDER: the record-before-label refusal (E1), the source
#      order the W3 fix depends on (E2), and W1 + W2 at their drive points, each
#      asserted to RELEASE where the pre-fix code blocked (E3, E4).
#   F. W3 at its drive point, the anti-overreach case that must keep blocking,
#      and the META that attributes the release.
#   G. META: revert the guard to had_approved-only in a copy -> section A's
#      recovery stops working (the original deadlock returns).
#   H. The documented RESIDUAL of the empty-tracker reference: a bare approve
#      against a stale persisted report no-ops while the gate still blocks, and
#      the printed remediation still recovers it.
#
# THE DRIVE POINTS — why no sleeps and no concurrency are needed.
#   W3 (section F): verify-before-stop.sh reads the change set at its detection
#   stage, then invokes detect-stack.sh, and only THEN reads the gate label and
#   recomputes the hash. detect-stack.sh is a documented seam every gate spec
#   already stubs, and it sits exactly between the two reads. A stub that runs
#   `qa-gate.sh approve` from there reproduces the live interleaving exactly.
#   W1/W2 (sections E3/E4): the fixture's own `bd` wrapper. It runs the real bd
#   call, fires the Stop hook synchronously, then returns — so the Stop observes
#   cmd_approve frozen at a chosen bd call. Both are single process trees with no
#   timing dependence, which is the only kind of race test worth having.
#
# FIXTURE HYGIENE (read before adding a section). mk_fixture exports
# CLAUDE_PROJECT_DIR and `cd`s into the fixture it just built, so building a
# SECOND fixture silently re-points both at the new one. Every helper here
# therefore threads BOTH explicitly — `( cd "$root" && CLAUDE_PROJECT_DIR="$root"
# ... )` — because `bd` locates its database from cwd while the hooks locate
# their tracking dir from CLAUDE_PROJECT_DIR. Without that, a later section's
# fixture makes an earlier section's task id unresolvable and the failure looks
# like a gate bug rather than a harness bug (it did, once, while this spec was
# being written).

set -u

# ---------------------------------------------------------------------------
# Shared helpers. All of them take the fixture root explicitly.

quiet_stack() {
    local root="$1"
    rm -f "$root/.claude/scripts/detect-stack.sh"
    printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
        > "$root/.claude/scripts/detect-stack.sh"
    chmod +x "$root/.claude/scripts/detect-stack.sh"
}

# gate_fixture — a fresh git fixture with the no-op detect-stack stub every gate
# spec uses (empty test/lint/type commands, so the assertions measure the GATE
# decision rather than a toolchain run). Result in $COMPONENT_FIXTURE_PATH.
#
# THE .gitignore IS LOAD-BEARING (94d). This spec's drive points REWRITE the
# harness's own instrumentation mid-cycle: `drive_point_bd` and the E1 selective
# shim overwrite `bin/bd`, and `racing_stack`/`quiet_stack` overwrite
# `.claude/scripts/detect-stack.sh`. Those writes are real, git-visible,
# un-baselined changes, so once `qa-gate.sh reconcile-tracker` existed they were
# correctly folded into the change set — which moved the change-set hash between
# `enter` and `approve` and made four sections fail for a reason that has nothing
# to do with the gate: E1 refused with impact_report_stale before it ever reached
# the label step it was written to probe, and section A's approval bound a file
# set containing the harness's own scaffolding.
#
# The instrumentation is not the subject matter, so it must not be in the
# fixture's git view. This is the same call the shared denylist already makes for
# the e2e tier — `.claude/tests/e2e/fixtures/<f>/.claude/{scripts,beads}/` is
# denylisted precisely as "churn the harness rewrites mechanically" — applied to
# the L2 tier, whose fixtures are `mktemp -d` roots that no denylist branch can
# name. `.claude/.qa-tracking/` is listed for the same reason the real plugin
# repo gitignores it (per-session ephemera). The spec's SUBJECT — src/*.ts,
# smuggled.ts, helper-written.ts — stays fully tracked and fully reviewable.
gate_fixture() {
    mk_fixture
    bd_required_or_skip
    printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' \
        > "$COMPONENT_FIXTURE_PATH/.gitignore"
    (cd "$COMPONENT_FIXTURE_PATH" && git init -q 2>/dev/null \
        && git config user.email t@t.t && git config user.name t \
        && git add -A && git commit -qm baseline 2>/dev/null) || true
    quiet_stack "$COMPONENT_FIXTURE_PATH"
}

seed_tracker() {
    local root="$1"; shift
    : > "$root/.claude/.qa-tracking/changed-files.txt"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$root/.claude/.qa-tracking/changed-files.txt"; done
}

# qg <root> <args...> / ct <root> <args...> / ir <root> <args...> — the three
# gate scripts, always with cwd + CLAUDE_PROJECT_DIR pinned to <root>.
qg() { local root="$1"; shift; ( cd "$root" && CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" "$@" ); }
ct() { local root="$1"; shift; ( cd "$root" && CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/current-task.sh" "$@" ); }
ir() { local root="$1"; shift; ( cd "$root" && CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" "$@" ); }
bdq() { local root="$1"; shift; ( cd "$root" && bd "$@" ); }

# stop_json <root> [hook-path] — the Stop hook's final envelope.
stop_json() {
    local root="$1" hook="${2:-$1/.claude/scripts/verify-before-stop.sh}"
    ( cd "$root" && printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$root" bash "$hook" 2>/dev/null | tail -1 )
}
stop_decision() { printf '%s' "$(stop_json "$@")" | jq -r '.decision // "ALLOW"' 2>/dev/null; }
json_field() { printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null || echo ""; }

# approval_records <root> <tid> — every QA-GATE APPROVED comment, one per line,
# from the same source the Stop hook reads.
approval_records() {
    bd_show_with_comments "$2" "$1" \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
        | grep '^QA-GATE APPROVED ' || true
}
record_count() { approval_records "$1" "$2" | grep -c . | tr -d '[:space:]'; }
record_hash() { approval_records "$1" "$2" | sed -nE 's/.*change_set_hash=([A-Za-z0-9-]+).*/\1/p' | tail -1; }
labels_of() {
    bdq "$1" show "$2" --json 2>/dev/null \
        | jq -r 'if type=="array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null || echo ""
}
new_task() { bdq "$1" create "$2" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty'; }

# armed_cycle <root> <tid> <path>... — everything a legitimate approve needs: the
# tracked change set, an armed gate, the independent-review records and a fresh
# impact report. Leaves current-task pointing at <tid>.
armed_cycle() {
    local root="$1" tid="$2"; shift 2
    seed_tracker "$root" "$@"
    qg "$root" enter "$tid" >/dev/null 2>&1
    ct "$root" set "$tid" >/dev/null 2>&1
    seed_review_records "$tid" "qa-claude" "backend" "$root" >/dev/null 2>&1
    ir "$root" "$tid" >/dev/null 2>&1
}

# ===========================================================================
# SECTION A — the printed remediation RECOVERS (the gz3 acceptance criterion).
# ===========================================================================
gate_fixture
FA="$COMPONENT_FIXTURE_PATH"

TID_A=$(new_task "$FA" "gz3: printed remediation recovers")
armed_cycle "$FA" "$TID_A" "src/a.ts"
# claude-workflow-plugin-rqer (v5 D2): capture the FULL tracker verbatim
# BEFORE approve — armed_cycle's own seed_review_records call already
# reconciled its canonical artifact in (AC-4), so this is exactly the set
# approve is about to bind. A `reconcile-tracker` call AFTER approve cannot
# recover it: approve's own baseline refresh is a FULL, unconditional
# snapshot of everything dirty at that instant (0wk.2 — "everything dirty
# right now has been reviewed"), so by the time a later reconcile runs, the
# artifact (and any other incidental fixture dirt already swept in by an
# earlier `enter`) reads as ALREADY BASELINED, pre-existing, and reconcile
# adds nothing — measured directly: the "restore the same 2 files, then
# reconcile" shape recomputed a DIFFERENT hash than the one just approved.
TID_A_TRACKER_SNAPSHOT=$(cat "$FA/.claude/.qa-tracking/changed-files.txt" 2>/dev/null)
qg "$FA" approve "$TID_A" "reviewed a.ts" >/dev/null 2>&1
printf '%s\n' "$TID_A_TRACKER_SNAPSHOT" > "$FA/.claude/.qa-tracking/changed-files.txt"
ct "$FA" set "$TID_A" >/dev/null 2>&1
# claude-workflow-plugin-rqer round 2 (QA R1-F4): this section used to carry
# two "DEBUG A0" lines here that fired a FULL, unasserted verify-before-stop.sh
# invocation before the one below. That extra call is itself a successful
# release on the matching-approval path, and a successful release TRUNCATES
# changed-files.txt (verify-before-stop.sh's own "Clean up tracking" section,
# by design — the same tracker reset qa-gate.sh approve does). So the debug
# call silently consumed the tracker this assertion depends on, and the ONE
# call actually measured below had to reconstruct the change set from `git
# status` instead (qa-gate.sh reconcile_tracker's absent-tracker fallback) —
# a DIFFERENT, DEGRADED arm that still returns ALLOW even when the intended
# "labeled, hash-matching approval" path is broken. Measured directly: with
# the debug lines in place, sync-errors.log recorded a
# "reconcile_tracker: changed-files.txt was absent-or-empty ... REBUILT from
# git status alone" line between the debug call and this one; with them
# removed, this ONE call produces no such line and changed-files.txt still
# holds the FULL restored snapshot right up to the call it makes. Do not
# reintroduce a probe call here: any extra Stop invocation before this
# assertion reproduces the same masking.
assert_eq "approve-idem-A0: control — the matching approval RELEASES" \
    "ALLOW" "$(stop_decision "$FA")"

# A post-approval edit shifts the current hash away from the recorded one.
seed_tracker "$FA" "src/a.ts" "src/b.ts"
ct "$FA" set "$TID_A" >/dev/null 2>&1
A_JSON=$(stop_json "$FA")
A_REASON=$(json_field "$A_JSON" '.reason')
assert_eq "approve-idem-A1: a post-approval edit BLOCKS" "block" "$(json_field "$A_JSON" '.decision')"
assert_contains "approve-idem-A1: ...on the LABEL_WITHOUT_RECORD branch" \
    "no change-set-bound approval record matches" "$A_REASON"

# Extract every `bash .claude/scripts/...` line from the reason, in order, and
# run exactly those. Bounded to BEFORE the disclosure tail checks_scope_note
# appends (claude-workflow-plugin-i8cx R5-F2): that function's own
# broader_verification_note() prints a separate, generic "record a broader
# verification run" suggestion whenever the ledger is empty (the case in this
# fixture, which never calls record-verification), and its example line
# (`... record-verification '<command>' <exit-code>`) also matches this grep
# even though it is advisory boilerplate about an unrelated axis, not a step
# in "the WHOLE recipe" the block text closes above it. Verified live: A4
# below still releases the gate having run only the 3 lines this bound
# extracts, and the unbounded 4th line would misparse if actually eval'd —
# `<exit-code>` is unquoted, unlike the two placeholders this spec DOES
# substitute ($CURRENT_TASK, '<approval summary>'), so bash reads it as an
# input redirection from a file named exit-code rather than a placeholder.
# "WHAT THIS GATE RAN, EXACTLY." is checks_scope_note's own first line, shared
# by all three emit_block sites it was added to, so this bound is not
# specific to the LABEL_WITHOUT_RECORD wording tested here.
REMEDY_FILE="$FA/.claude/.qa-tracking/printed-remediation.txt"
printf '%s\n' "$A_REASON" | sed '/^WHAT THIS GATE RAN, EXACTLY\.$/,$d' \
    | grep -E '^[[:space:]]*bash \.claude/scripts/' \
    | sed 's/^[[:space:]]*//' > "$REMEDY_FILE"
assert_eq "approve-idem-A2: the block prints a 3-command remediation" \
    "3" "$(grep -c . "$REMEDY_FILE" | tr -d '[:space:]')"
assert_eq "approve-idem-A2: ...and still prints no 'bd label remove' step" \
    "0" "$(grep -c 'bd label remove' "$REMEDY_FILE" | tr -d '[:space:]')"
assert_contains "approve-idem-A2: ...and says so explicitly (do NOT remove the label first)" \
    "do NOT remove the qa-approved label first" "$A_REASON"

A_APPROVE_OUT=""
A_ENTER_OUT=""
while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    cmd=${cmd//\'<approval summary>\'/\'re-reviewed after the post-approval edit\'}
    OUT_LINE=$( cd "$FA" && CLAUDE_PROJECT_DIR="$FA" eval "$cmd" 2>&1 | tail -1 )
    case "$cmd" in
        *"qa-gate.sh approve"*) A_APPROVE_OUT="$OUT_LINE" ;;
        *"qa-gate.sh enter"*)   A_ENTER_OUT="$OUT_LINE" ;;
    esac
done < "$REMEDY_FILE"

assert_json_field "approve-idem-A3: the printed approve SUCCEEDS" "$A_APPROVE_OUT" '.status' "approved"
assert_not_contains "approve-idem-A3: ...and is NOT reported as an idempotent no-op" \
    "idempotent no-op" "$A_APPROVE_OUT"
# 8zi/jue: WHICH of the two closures does the work on THIS path, asserted rather
# than assumed. The printed remediation runs `enter` first, and `enter` now clears
# a prior cycle's qa-approved (jue) — so by the time approve runs there is no
# stale label left to re-bind, and the envelope must NOT claim one. The
# `stale-label re-bind` diagnostic belongs to the plain re-run path with no
# intervening enter, and is asserted there, in section G's shipped-guard leg.
assert_contains "approve-idem-A3: the remediation's ENTER step clears the prior cycle's qa-approved (jue)" \
    "cleared a prior cycle's qa-approved" "$A_ENTER_OUT"
assert_not_contains "approve-idem-A3: ...so the approve that follows is a clean re-bind, NOT a stale-label one" \
    "stale-label re-bind" "$A_APPROVE_OUT"
assert_contains "approve-idem-A3: ...and re-verified the impact report rather than skipping it" \
    "impact-report verified" "$A_APPROVE_OUT"
assert_contains "approve-idem-A3: ...and re-verified the independent review rather than skipping it" \
    "independent review verified" "$A_APPROVE_OUT"
assert_eq "approve-idem-A3: ...writing a SECOND, freshly-bound record" \
    "2" "$(record_count "$FA" "$TID_A")"

seed_tracker "$FA" "src/a.ts" "src/b.ts"
ct "$FA" set "$TID_A" >/dev/null 2>&1
assert_eq "approve-idem-A4: THE ACCEPTANCE — following the printed remediation RELEASES the gate" \
    "ALLOW" "$(stop_decision "$FA")"

# ===========================================================================
# SECTION B — the idempotency contract, preserved where it was right.
#
# `bd_qa_approve` advertises "re-approving an already-approved task is a success
# no-op". That is correct whenever a record already binds the change set the
# re-approve would bind, in both spellings of that state.
# ===========================================================================
gate_fixture
FB="$COMPONENT_FIXTURE_PATH"

TID_B=$(new_task "$FB" "gz3: matching-hash re-approve")
armed_cycle "$FB" "$TID_B" "src/b1.ts"
# claude-workflow-plugin-rqer (v5 D2): capture the FULL tracker verbatim
# BEFORE approve — see the A0 note above for why a POST-approve
# `reconcile-tracker` cannot recover it (approve's own baseline refresh
# consumes the "newness" of everything dirty at that instant, including
# armed_cycle's canonical review artifact).
TID_B_TRACKER_SNAPSHOT=$(cat "$FB/.claude/.qa-tracking/changed-files.txt" 2>/dev/null)
qg "$FB" approve "$TID_B" "reviewed b1.ts" >/dev/null 2>&1
assert_eq "approve-idem-B0: precondition — one bound record after the first approve" \
    "1" "$(record_count "$FB" "$TID_B")"

# B1. The same change set back in the tracker: the live recompute matches the
# recorded hash -> no-op.
printf '%s\n' "$TID_B_TRACKER_SNAPSHOT" > "$FB/.claude/.qa-tracking/changed-files.txt"
B1_OUT=$(qg "$FB" approve "$TID_B" "same approval again" 2>&1 | tail -1)
assert_json_field "approve-idem-B1: a matching-hash re-approve still succeeds" "$B1_OUT" '.status' "approved"
assert_contains "approve-idem-B1: ...as an explicit idempotent no-op" "idempotent no-op" "$B1_OUT"
assert_contains "approve-idem-B1: ...naming the record that already binds this change set" \
    "an approval record already binds this change set" "$B1_OUT"
assert_eq "approve-idem-B1: ...and writes NO second record" "1" "$(record_count "$FB" "$TID_B")"

# B2. The post-approve state: approve truncated the tracker, so a recompute here
# answers with the empty-set hash. The persisted impact-report-<tid>.json is what
# keeps this a no-op (LESSONS.md: read the persisted record, never recompute).
: > "$FB/.claude/.qa-tracking/changed-files.txt"
assert_eq "approve-idem-B2: precondition — the tracker is empty (as approve leaves it)" \
    "empty" "$([ -s "$FB/.claude/.qa-tracking/changed-files.txt" ] && echo populated || echo empty)"
B2_REPORT="$FB/.claude/.qa-tracking/impact-report-$(printf '%s' "$TID_B" | tr -c 'A-Za-z0-9._-' '_').json"
B2_REPORT_HASH=$(jq -r '.change_set_hash // empty' "$B2_REPORT" 2>/dev/null || echo "")
B2_LIVE_HASH=$(ir "$FB" --hash-only 2>/dev/null || echo "")
assert_eq "approve-idem-B2: precondition — the live recompute NO LONGER equals the approved hash" \
    "differs" "$([ -n "$B2_REPORT_HASH" ] && [ "$B2_REPORT_HASH" != "$B2_LIVE_HASH" ] && echo differs || echo same)"
B2_OUT=$(qg "$FB" approve "$TID_B" "double approve, truncated tracker" 2>&1 | tail -1)
assert_json_field "approve-idem-B2: a plain double approve still succeeds" "$B2_OUT" '.status' "approved"
assert_contains "approve-idem-B2: ...as an idempotent no-op, via the PERSISTED report hash" \
    "idempotent no-op" "$B2_OUT"
assert_contains "approve-idem-B2: ...bound to the approved hash, not the empty-set hash" \
    "change_set_hash=$B2_REPORT_HASH" "$B2_OUT"
assert_eq "approve-idem-B2: ...and writes NO second record" "1" "$(record_count "$FB" "$TID_B")"

# ===========================================================================
# SECTION C — ...and NOT preserved where it was wrong.
#
# The guard must not become a way to skip the checks. With the label set, the
# change set MOVED and the impact report NOT regenerated, the old code answered
# "idempotent no-op" (silently hiding a stale artifact); the new code proceeds
# and hits the staleness REFUSAL, whose remediation names the regeneration the
# printed recipe performs.
# ===========================================================================
seed_tracker "$FB" "src/b1.ts" "src/b2-added-later.ts"
C_RC=0
# NB: capture the rc WITHOUT a pipe — `cmd | tail` yields tail's status, which is
# always 0 and would pass this assertion whatever approve did.
C_RAW=$(qg "$FB" approve "$TID_B" "stale report, moved change set" 2>&1) || C_RC=$?
C_OUT=$(printf '%s\n' "$C_RAW" | tail -1)
assert_eq "approve-idem-C1: a stale report + moved change set is REFUSED (exit 2), not no-op'd" "2" "$C_RC"
assert_json_field "approve-idem-C1: ...with error_key=impact_report_stale" \
    "$C_OUT" '.error_key' "impact_report_stale"
assert_contains "approve-idem-C1: ...steering to the regeneration the printed recipe runs" \
    "impact-report.sh" "$C_OUT"
assert_eq "approve-idem-C1: ...and still no second record" "1" "$(record_count "$FB" "$TID_B")"

# ===========================================================================
# SECTION D — reader-grammar parity.
#
# qa-gate.sh now READS the approval records it writes, to decide whether an
# approval already covers the change set. If its extraction differed from the
# expression verify-before-stop.sh RELEASES on, writer and reader could disagree
# about what counts as an approval — the class of bug gz3 is. Compared as text,
# extracted from the two shipped scripts.
#
# claude-workflow-plugin-yrij (APPROVAL-SELECTOR-ANCHOR): the selector itself
# — `select(test("^QA-GATE APPROVED .*change_set_hash="))` — is now ANCHORED
# at `^` in both files (it used to be unanchored: a comment whose first line
# was prose and whose LATER line fabricated a record satisfied it with no
# `qa-gate.sh approve` ever having run). D1's count-check below is updated to
# the anchored string so it does not itself go stale the moment the fix
# lands; D1b is NEW — the original section only ever compared the CAPTURE
# expression across files (D1 proper), never the SELECTOR that gates it, so
# a drift in `select(...)` specifically could pass D1 unnoticed. Same
# text-extracted-and-compared discipline as D1, applied to the clause D1
# skipped.
# ===========================================================================
PLUGIN_D=$(plugin_root)
QG_CAPTURE=$(grep -o 'capture("change_set_hash=(?<h>\[A-Za-z0-9-\]+)")\.h' "$PLUGIN_D/.claude/scripts/qa-gate.sh" | sort -u)
VBS_CAPTURE=$(grep -o 'capture("change_set_hash=(?<h>\[A-Za-z0-9-\]+)")\.h' "$PLUGIN_D/.claude/scripts/verify-before-stop.sh" | sort -u)
assert_eq "approve-idem-D1: qa-gate.sh carries the hash-capture expression at all" \
    "yes" "$([ -n "$QG_CAPTURE" ] && echo yes || echo no)"
assert_eq "approve-idem-D1: ...byte-identical to verify-before-stop.sh's release expression" \
    "$VBS_CAPTURE" "$QG_CAPTURE"
assert_eq "approve-idem-D1: ...and the same record selector" "1" \
    "$(grep -c 'select(test("\^QA-GATE APPROVED .\*change_set_hash="))' "$PLUGIN_D/.claude/scripts/qa-gate.sh" | tr -d '[:space:]')"
QG_SELECTOR=$(grep -o 'select(test("\^QA-GATE APPROVED .\*change_set_hash="))' "$PLUGIN_D/.claude/scripts/qa-gate.sh" | sort -u)
VBS_SELECTOR_TASK_HAS=$(sed -n '/^task_has_matching_approval_record()/,/^}/p' "$PLUGIN_D/.claude/scripts/verify-before-stop.sh" \
    | grep -o 'select(test("\^QA-GATE APPROVED .\*change_set_hash="))' | sort -u)
assert_eq "approve-idem-D1b: qa-gate.sh's selector is ANCHORED (yrij APPROVAL-SELECTOR-ANCHOR)" \
    "yes" "$([ -n "$QG_SELECTOR" ] && echo yes || echo no)"
assert_eq "approve-idem-D1b: ...byte-identical to task_has_matching_approval_record's own selector" \
    "$VBS_SELECTOR_TASK_HAS" "$QG_SELECTOR"

# ===========================================================================
# SECTION E — the approve-commit ORDER.
#
# E1 is functional: with `bd label add <tid> qa-approved` forced to fail, the
# approval RECORD must already be on the task — only true if the record is
# written BEFORE the label. That closes the window where a concurrent Stop saw
# the label with no record (the forged-label message, for a legitimate in-flight
# approval).
#
# E2 is structural, deliberately: the remaining invariants are about states that
# exist for milliseconds inside another process, which no black-box assertion in
# this tier can observe. What CAN be pinned is the source order the reasoning
# depends on — above all baseline-before-truncate, which the Stop hook's
# vanished-change-set re-read relies on.
# ===========================================================================
gate_fixture
FE="$COMPONENT_FIXTURE_PATH"

TID_E=$(new_task "$FE" "gz3: record before label")
armed_cycle "$FE" "$TID_E" "src/e.ts"
# Selective bd shim: delegate to the real bd EXCEPT `label add <tid> qa-approved`,
# which exits 1. Same idiom as qa-gate.sh spec's Step-3 rollback case; the real
# bd path is read out of the existing wrapper because $FE/bin is already first on
# PATH (so `command -v bd` resolves to the wrapper itself).
# The extraction is anchored on the trailing `"$@"`, NOT on any bd flag: the
# wrapper used to end `--no-daemon "$@"` until bd 1.1.2 removed that flag, and a
# pattern keyed to it silently returns empty on the new wrapper. That is not a
# harmless miss — the `command -v bd` fallback below resolves to $FE/bin (first
# on PATH), i.e. to THIS wrapper, so the regenerated file would exec itself
# forever. The failure mode is a spec that hangs printing nothing (the runner
# captures stdout in a command substitution). See lib/shim.sh's gz3 guard.
REAL_BD_E=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$FE/bin/bd" 2>/dev/null | tr -d '"' | head -1)
[ -z "$REAL_BD_E" ] && REAL_BD_E=$(command -v bd)
cat > "$FE/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "label" ] && [ "\$2" = "add" ] && [ "\$4" = "qa-approved" ]; then exit 1; fi
exec $REAL_BD_E "\$@"
EOF
chmod +x "$FE/bin/bd"
E_RC=0
E_RAW=$(qg "$FE" approve "$TID_E" "label add will fail" 2>&1) || E_RC=$?
E_OUT=$(printf '%s\n' "$E_RAW" | tail -1)
# Restore the plain wrapper from the saved real-bd path. NOT via mk_bd_shim: it
# would resolve `command -v bd` to this very file and generate a wrapper that
# execs itself (it refuses loudly now — see the guard in lib/shim.sh — but the
# restore still has to be done by hand).
cat > "$FE/bin/bd" <<EOF
#!/bin/bash
exec $REAL_BD_E "\$@"
EOF
chmod +x "$FE/bin/bd"
assert_eq "approve-idem-E1: a failed qa-approved add exits 3 (atomic refusal)" "3" "$E_RC"
assert_json_field "approve-idem-E1: ...with status=error" "$E_OUT" '.status' "error"
assert_not_contains "approve-idem-E1: ...and the label really is absent" \
    "qa-approved" "$(labels_of "$FE" "$TID_E")"
assert_eq "approve-idem-E1: THE ORDER — the approval record was already written (record precedes label)" \
    "1" "$(record_count "$FE" "$TID_E")"
assert_contains "approve-idem-E1: ...and the envelope says the record is inert without the label" \
    "inert without the label" "$E_OUT"

# E2. Source-order invariants inside cmd_approve. Anchored on the CALL sites
# (leading indentation), never on the function definitions at column 0.
QG_REAL="$PLUGIN_D/.claude/scripts/qa-gate.sh"
line_of() { grep -n -- "$2" "$1" | head -1 | cut -d: -f1; }
L_RECORD=$(line_of "$QG_REAL" '    add_comment "$tid" "QA-GATE APPROVED ')
# 8zi re-pointed this anchor. The INVARIANT is untouched — the record is still
# written before the qa-approved label, and the tracking-state finalization still
# comes after the rollback-capable label steps — but the statement that writes the
# label is no longer a bare `add_label`: approve now performs the whole terminal
# transition (add qa-approved, clear every other cycle label, restore exactly on
# failure) through one call. Anchored WITHOUT the trailing `"${sweep_clear[@]}"`
# because line_of greps a BRE and the `[...]` would be read as a bracket
# expression rather than a literal.
L_LABEL=$(line_of "$QG_REAL" '    if ! set_terminal_label "$tid" "qa-approved"')
L_BASELINE=$(line_of "$QG_REAL" '    if ! write_gate_baseline "qa-gate-approve"; then')
L_TRUNCATE=$(grep -n '^    truncate_changed_files_tracker$' "$QG_REAL" | head -1 | cut -d: -f1)
L_CLEARTASK=$(grep -n '^    clear_current_task$' "$QG_REAL" | head -1 | cut -d: -f1)
assert_eq "approve-idem-E2: every ordered statement was located in cmd_approve" "yes" \
    "$([ -n "$L_RECORD" ] && [ -n "$L_LABEL" ] && [ -n "$L_BASELINE" ] && [ -n "$L_TRUNCATE" ] && [ -n "$L_CLEARTASK" ] && echo yes || echo no)"
assert_eq "approve-idem-E2: the RECORD is written before the qa-approved LABEL" "yes" \
    "$([ "${L_RECORD:-0}" -lt "${L_LABEL:-0}" ] && echo yes || echo no)"
assert_eq "approve-idem-E2: the gate BASELINE is refreshed before the TRACKER is truncated" "yes" \
    "$([ "${L_BASELINE:-0}" -lt "${L_TRUNCATE:-0}" ] && echo yes || echo no)"
assert_eq "approve-idem-E2: current-task is cleared only AFTER the tracker is truncated" "yes" \
    "$([ "${L_TRUNCATE:-0}" -lt "${L_CLEARTASK:-0}" ] && echo yes || echo no)"
assert_eq "approve-idem-E2: the tracking-state finalization stays AFTER the rollback-capable label steps" "yes" \
    "$([ "${L_LABEL:-0}" -lt "${L_BASELINE:-0}" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# E3 / E4 — W1 and W2 at their drive points, functionally.
#
# The fixture's bd wrapper freezes cmd_approve at a chosen bd call, fires the
# Stop hook there, and returns; the Stop therefore observes a genuine
# mid-approve state. Against the PRE-FIX scripts both drive points BLOCK (W1:
# the forged-label message; W2: "No active Beads task detected"), which is how
# they were found. Here they must RELEASE — and each case first asserts the
# state that makes the drive point the right one, so a wrapper that silently
# stopped firing cannot pass this by releasing for the ordinary reason.
#
# drive_point_bd <root> <argv1> <argv2> <argv4>: wrap bd so the FIRST call
# matching (argv1, argv2, argv4) runs for real, snapshots what a Stop would see,
# runs the Stop hook, and stores its envelope. Everything else passes through.
# Anchored on the trailing `"$@"`, never on a bd flag — see the note at the E1
# wrapper above for why a missed match here hangs the spec instead of failing it.
real_bd_of() {
    local p
    p=$(sed -n 's/^exec \(.*\) "\$@".*/\1/p' "$1/bin/bd" 2>/dev/null | tr -d '"' | head -1)
    [ -z "$p" ] && p=$(command -v bd)
    printf '%s' "$p"
}
drive_point_bd() {
    local root="$1" a1="$2" a2="$3" a4="$4"
    local real; real=$(real_bd_of "$root")
    rm -f "$root/.claude/.qa-tracking/.drive-fired" "$root/.claude/.qa-tracking/.drive-stop.json"
    cat > "$root/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "$a1" ] && [ "\$2" = "$a2" ] && [ "\$4" = "$a4" ] && [ ! -f "$root/.claude/.qa-tracking/.drive-fired" ]; then
    : > "$root/.claude/.qa-tracking/.drive-fired"
    $real "\$@"; rc=\$?
    $real show "\$3" --json --include-comments 2>/dev/null \\
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \\
        | grep -c '^QA-GATE APPROVED ' > "$root/.claude/.qa-tracking/.drive-records" 2>/dev/null
    if [ -f "$root/.claude/.qa-tracking/current-task" ]; then
        printf 'present\n' > "$root/.claude/.qa-tracking/.drive-current-task"
    else
        printf 'cleared\n' > "$root/.claude/.qa-tracking/.drive-current-task"
    fi
    if [ -s "$root/.claude/.qa-tracking/changed-files.txt" ]; then
        printf 'populated\n' > "$root/.claude/.qa-tracking/.drive-tracker"
    else
        printf 'empty\n' > "$root/.claude/.qa-tracking/.drive-tracker"
    fi
    ( cd "$root" && printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \\
        | CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/verify-before-stop.sh" 2>/dev/null \\
        | tail -1 > "$root/.claude/.qa-tracking/.drive-stop.json" )
    exit \$rc
fi
exec $real "\$@"
EOF
    chmod +x "$root/bin/bd"
}
# Restore the plain wrapper by hand (never via mk_bd_shim — see its guard).
restore_bd() {
    local root="$1" real; real=$(real_bd_of "$root")
    printf '#!/bin/bash\nexec %s "$@"\n' "$real" > "$root/bin/bd"
    chmod +x "$root/bin/bd"
}
drive_read() { tr -d '[:space:]' < "$1/.claude/.qa-tracking/$2" 2>/dev/null || printf 'missing'; }
drive_stop_json() { tail -1 "$1/.claude/.qa-tracking/.drive-stop.json" 2>/dev/null || echo ""; }
# decision_of <envelope> — the same normalization stop_decision applies: a
# releasing hook emits `{}` (no .decision), which reads as ALLOW. NOT `sed` on
# an empty string: `printf '%s' ""` yields zero lines, so a substitution
# anchored on ^$ never runs and the result would be empty either way.
decision_of() { printf '%s' "$1" | jq -r '.decision // "ALLOW"' 2>/dev/null || echo ""; }

# E3 — W1: a Stop at the `bd label add <tid> qa-approved` call.
TID_E3=$(new_task "$FE" "gz3: W1 drive point (label add)")
armed_cycle "$FE" "$TID_E3" "src/e3.ts"
drive_point_bd "$FE" label add qa-approved
E3_APPROVE=$(qg "$FE" approve "$TID_E3" "approve observed at the label add" 2>&1 | tail -1)
restore_bd "$FE"
E3_STOP=$(drive_stop_json "$FE")
assert_json_field "approve-idem-E3: the observed approve completed" "$E3_APPROVE" '.status' "approved"
assert_eq "approve-idem-E3: the drive point really fired (a Stop ran mid-approve)" \
    "yes" "$([ -n "$E3_STOP" ] && echo yes || echo no)"
assert_eq "approve-idem-E3: at that instant the RECORD already existed (pre-fix: 0)" \
    "1" "$(drive_read "$FE" .drive-records)"
assert_eq "approve-idem-E3: ...and the tracker was still populated, so the Stop had work to gate" \
    "populated" "$(drive_read "$FE" .drive-tracker)"
assert_eq "approve-idem-E3: W1 CLOSED — the mid-approve Stop RELEASES (pre-fix: forged-label block)" \
    "ALLOW" "$(decision_of "$E3_STOP")"
assert_not_contains "approve-idem-E3: ...and never on the forged-label branch" \
    "no change-set-bound approval record matches" "$(json_field "$E3_STOP" '.reason')"

# E4 — W2: a Stop at the `bd label remove <tid> rubric-pending` call, which
# approve runs after remove_escalation_labels and before the baseline refresh.
# Pre-fix, clear_current_task had already run by then.
TID_E4=$(new_task "$FE" "gz3: W2 drive point (rubric-pending removal)")
armed_cycle "$FE" "$TID_E4" "src/e4.ts"
drive_point_bd "$FE" label remove rubric-pending
E4_APPROVE=$(qg "$FE" approve "$TID_E4" "approve observed at the rubric-pending removal" 2>&1 | tail -1)
restore_bd "$FE"
E4_STOP=$(drive_stop_json "$FE")
assert_json_field "approve-idem-E4: the observed approve completed" "$E4_APPROVE" '.status' "approved"
assert_eq "approve-idem-E4: the drive point really fired (a Stop ran mid-approve)" \
    "yes" "$([ -n "$E4_STOP" ] && echo yes || echo no)"
assert_eq "approve-idem-E4: at that instant current-task was STILL set (pre-fix: cleared)" \
    "present" "$(drive_read "$FE" .drive-current-task)"
assert_eq "approve-idem-E4: ...and the tracker still populated, so the Stop had work to gate" \
    "populated" "$(drive_read "$FE" .drive-tracker)"
assert_eq "approve-idem-E4: W2 CLOSED — the mid-approve Stop RELEASES (pre-fix: 'No active Beads task')" \
    "ALLOW" "$(decision_of "$E4_STOP")"
assert_not_contains "approve-idem-E4: ...and never on the no-active-task branch" \
    "No active Beads task" "$(json_field "$E4_STOP" '.reason')"

# ===========================================================================
# SECTION F — THE RACE.
# ===========================================================================
gate_fixture
FF="$COMPONENT_FIXTURE_PATH"
TRACKF="$FF/.claude/.qa-tracking"

# racing_stack <root> <tid> — detect-stack.sh that lands a full approve on its
# FIRST invocation, then answers like the quiet stub. The marker file makes it
# fire exactly once per arming.
racing_stack() {
    local root="$1" tid="$2"
    rm -f "$root/.claude/scripts/detect-stack.sh" "$root/.claude/.qa-tracking/.race-fired"
    cat > "$root/.claude/scripts/detect-stack.sh" <<EOF
#!/bin/bash
if [ ! -f "$root/.claude/.qa-tracking/.race-fired" ]; then
    : > "$root/.claude/.qa-tracking/.race-fired"
    cd "$root" || exit 0
    CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/qa-gate.sh" approve "$tid" \
        'reviewed mid-Stop (the racing approve)' > "$root/.claude/.qa-tracking/.race-approve.json" 2>&1
fi
printf '%s' '{"runner":"npm","test_cmd":"","lint_cmd":"","type_cmd":""}'
EOF
    chmod +x "$root/.claude/scripts/detect-stack.sh"
}
# racing_approve_json <root> — what the injected approve reported. Prints a
# diagnostic when it did not land, so a broken arming can never masquerade as
# evidence about the gate.
racing_approve_json() {
    local out
    out=$(tail -1 "$1/.claude/.qa-tracking/.race-approve.json" 2>/dev/null || echo "")
    if [ "$(json_field "$out" '.status')" != "approved" ]; then
        printf '  diagnostic: the injected approve did NOT land: %s\n' "$out" >&2
    fi
    printf '%s' "$out"
}

# The canonical empty-set hash, from the ONE implementation (--hash-only against
# a project dir with no tracker) rather than a hardcoded literal.
EMPTY_PROJECT=$(mktemp -d -t gz3-empty.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$EMPTY_PROJECT")
EMPTY_SET_HASH=$(CLAUDE_PROJECT_DIR="$EMPTY_PROJECT" bash "$FF/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
assert_eq "approve-idem-F0: the canonical EMPTY-SET hash is computable (the race's fingerprint)" \
    "yes" "$([ -n "$EMPTY_SET_HASH" ] && echo yes || echo no)"

TID_F=$(new_task "$FF" "gz3: approve races the Stop hook")
printf 'export const f = 1;\n' > "$FF/src-f.ts"
armed_cycle "$FF" "$TID_F" "src-f.ts"
F_ARMED_HASH=$(ir "$FF" --hash-only 2>/dev/null || echo "")
assert_eq "approve-idem-F1: precondition — the armed change set is NOT the empty set" "differs" \
    "$([ -n "$F_ARMED_HASH" ] && [ "$F_ARMED_HASH" != "$EMPTY_SET_HASH" ] && echo differs || echo same)"
assert_eq "approve-idem-F1: precondition — the live baseline is the enter-time one" \
    "qa-gate-enter" "$(sed -n 's/^captured_by=//p' "$TRACKF/gate-baseline" 2>/dev/null | head -1)"
assert_eq "approve-idem-F1: precondition — no approval record yet" "0" "$(record_count "$FF" "$TID_F")"

racing_stack "$FF" "$TID_F"
F1_DECISION=$(stop_decision "$FF")
F1_APPROVE=$(racing_approve_json "$FF")
# The injected approve really succeeded — this is not a broken-fixture pass.
assert_json_field "approve-idem-F1: the racing approve landed mid-Stop" "$F1_APPROVE" '.status' "approved"
assert_eq "approve-idem-F1: ...it truncated the tracker under the running hook" \
    "empty" "$([ -s "$TRACKF/changed-files.txt" ] && echo populated || echo empty)"
assert_eq "approve-idem-F1: ...and refreshed the baseline (order: baseline before truncate)" \
    "qa-gate-approve" "$(sed -n 's/^captured_by=//p' "$TRACKF/gate-baseline" 2>/dev/null | head -1)"
assert_eq "approve-idem-F1: ...binding the reviewed change set, not the empty set" \
    "$F_ARMED_HASH" "$(record_hash "$FF" "$TID_F")"
assert_eq "approve-idem-F1: THE RACE — the straddling Stop RELEASES instead of a transient block" \
    "ALLOW" "$F1_DECISION"

# F3 (before F2, so it shares FF while it is still the newest fixture).
# META — strip the VANISHED-CHANGE-SET block from a COPY of the hook and re-run
# the drive point on a fresh task. The copy lives in `.claude/scripts/` because a
# hook parked elsewhere cannot find its workflow-denylist.sh sibling and would
# block on THAT instead (3mg.1), which would make this META pass for the wrong
# reason.
VBS_REAL=$(readlink "$FF/.claude/scripts/verify-before-stop.sh" 2>/dev/null || printf '%s' "$FF/.claude/scripts/verify-before-stop.sh")
VBS_MUT="$FF/.claude/scripts/vbs-novanish.sh"
VANISH_STRIP_RC=0
awk '
    /# VANISHED-CHANGE-SET BEGIN/ { skipping=1; found=1; next }
    /# VANISHED-CHANGE-SET END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$VBS_REAL" > "$VBS_MUT" || VANISH_STRIP_RC=$?
chmod +x "$VBS_MUT"
assert_eq "approve-idem-F3 META: VANISHED-CHANGE-SET sentinels present in verify-before-stop.sh" \
    "0" "$VANISH_STRIP_RC"
VBS_MUT_PARSE=0
bash -n "$VBS_MUT" 2>/dev/null || VBS_MUT_PARSE=$?
assert_eq "approve-idem-F3 META: the stripped copy still parses" "0" "$VBS_MUT_PARSE"
# Discriminator: the copy still sources the shared denylist, so a block from it
# cannot be the missing-lib arm. Counted with grep against the FILE rather than
# passing the whole hook as a haystack string: assert_contains pipes its haystack
# into `grep -q`, which closes the pipe on first match, and a file-sized haystack
# makes that a "printf: write error: Broken pipe" line in the middle of the run.
assert_eq "approve-idem-F3 META: the stripped copy still sources the shared denylist" \
    "yes" "$(grep -q 'workflow-denylist.sh' "$VBS_MUT" && echo yes || echo no)"

TID_F3=$(new_task "$FF" "gz3: race with the vanished-check stripped")
printf 'export const f3 = 1;\n' > "$FF/src-f3.ts"
armed_cycle "$FF" "$TID_F3" "src-f3.ts"
racing_stack "$FF" "$TID_F3"
F3_JSON=$(stop_json "$FF" "$VBS_MUT")
F3_APPROVE=$(racing_approve_json "$FF")
assert_json_field "approve-idem-F3 META: the racing approve landed under the mutant too" \
    "$F3_APPROVE" '.status' "approved"
assert_eq "approve-idem-F3 META: WITHOUT the block the raced Stop BLOCKS again (F1 WOULD fail)" \
    "block" "$(json_field "$F3_JSON" '.decision')"
assert_contains "approve-idem-F3 META: ...with the empty-set hash as the 'current' one (the race fingerprint)" \
    "current change-set hash is $EMPTY_SET_HASH" "$(json_field "$F3_JSON" '.reason')"
# The SAME state releases under the shipped hook, so the difference is the block
# and nothing about the fixture.
assert_eq "approve-idem-F3 META: the SAME state releases under the shipped hook" \
    "ALLOW" "$(stop_decision "$FF")"

# F2. ANTI-OVERREACH. The release must key on "nothing left to review", never on
# "the tracker is empty": work written by a helper rather than the Edit tool
# never reaches changed-files.txt (LESSONS.md / bi3.2), and that work is exactly
# what the git-status half of the predicate exists to catch.
gate_fixture
FG2="$COMPONENT_FIXTURE_PATH"
TID_F2=$(new_task "$FG2" "gz3: empty tracker, real un-baselined dirt")
: > "$FG2/.claude/.qa-tracking/changed-files.txt"
qg "$FG2" enter "$TID_F2" >/dev/null 2>&1
ct "$FG2" set "$TID_F2" >/dev/null 2>&1
printf 'export const smuggled = 1;\n' > "$FG2/smuggled.ts"
assert_eq "approve-idem-F2: control — un-baselined dirt with no approval BLOCKS" \
    "block" "$(stop_decision "$FG2")"
bdq "$FG2" label add "$TID_F2" qa-approved >/dev/null 2>&1
ct "$FG2" set "$TID_F2" >/dev/null 2>&1
F2_JSON=$(stop_json "$FG2")
assert_eq "approve-idem-F2: a forged label + EMPTY tracker + real dirt STILL BLOCKS" \
    "block" "$(json_field "$F2_JSON" '.decision')"
assert_contains "approve-idem-F2: ...on the LABEL_WITHOUT_RECORD branch (the release did not swallow it)" \
    "no change-set-bound approval record matches" "$(json_field "$F2_JSON" '.reason')"
# Causation: remove the cause, the release returns.
#
# 94d CHANGED WHAT "THE CAUSE" IS, and the probe has to follow. The Stop above
# ran `qa-gate.sh reconcile-tracker`, which folded smuggled.ts INTO
# changed-files.txt — so deleting the file no longer restores the release on its
# own: the tracker remembers it. That stickiness is deliberate and is exactly the
# semantics post-edit.sh has always had (Write a file, delete it with Bash, and
# the path still gates until an approve truncates the tracker); reconciled paths
# now behave the same way, and pruning the tracker to "fix" it would reintroduce
# the lose-a-tracked-path failure mode that cost post-edit.sh its unlocked trim.
# So the causation probe removes BOTH halves of the cause — the file and the
# tracker entry the reconcile derived from it — which is the state a fresh cycle
# reaches anyway, and asserts the release returns. The stickiness itself is
# asserted first so it is recorded behaviour rather than an incidental detail.
rm -f "$FG2/smuggled.ts"
ct "$FG2" set "$TID_F2" >/dev/null 2>&1
assert_eq "approve-idem-F2: 94d — a reconciled path is STICKY: deleting the file alone still blocks" \
    "block" "$(stop_decision "$FG2")"
assert_eq "approve-idem-F2: ...because the reconcile recorded it in the tracker" "1" \
    "$(grep -c 'smuggled\.ts' "$FG2/.claude/.qa-tracking/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
: > "$FG2/.claude/.qa-tracking/changed-files.txt"
ct "$FG2" set "$TID_F2" >/dev/null 2>&1
assert_eq "approve-idem-F2: removing the dirt AND its tracker entry restores the release (block was attributable)" \
    "ALLOW" "$(stop_decision "$FG2")"

# ===========================================================================
# SECTION G — META: revert the guard to had_approved-only.
#
# Section A's recovery must depend on the hash-aware guard and nothing else that
# changed. A copy whose guard short-circuits unconditionally must reproduce the
# original deadlock: approve reports an idempotent no-op and the gate stays
# blocked.
#
# 8zi/jue UPDATE — WHY THIS FLOW NO LONGER RUNS `enter`, and what that costs.
#
# The deadlock this META reproduces now has TWO independent closures in the tree,
# and they overlap on exactly one path:
#   gz3  approve refuses to no-op when no record binds the current change set;
#   jue  `enter` clears a prior cycle's qa-approved, in both of its arms.
# The printed remediation is `enter` -> `impact-report.sh` -> `approve`, so after
# the jue fix the label is already GONE by the time approve runs on that path:
# had_approved is 0, the idempotency guard is not reached at all, and a mutant of
# that guard cannot express anything. Driving the mutant through `enter` would
# therefore assert nothing about the guard — a green leg measuring an unreachable
# branch, which is the failure mode this whole spec exists to prevent.
#
# So this flow drops the `enter` step and keeps the other two. That is not a
# weaker scenario: it is the plain re-run — edit, regenerate the report, approve
# again — where qa-approved is still set, the change set has moved, and the
# hash-aware guard is the ONLY thing standing between the operator and the
# original deadlock. One variable, and it is the guard.
#
# WHAT IS NO LONGER COVERED HERE, named rather than left implicit: the
# enter-mediated recovery under a label-only guard. It is covered instead by the
# jue legs in specs/qa-gate.sh (jue-4a/4b and jue-META), which pin the enter-side
# clear and show a mutant of it leaving the label behind.
# ===========================================================================
gate_fixture
FH="$COMPONENT_FIXTURE_PATH"
QG_REAL_H=$(readlink "$FH/.claude/scripts/qa-gate.sh" 2>/dev/null || printf '%s' "$FH/.claude/scripts/qa-gate.sh")
QG_MUT="$FH/.claude/scripts/qa-gate-labelonly.sh"
GUARD_MUT_RC=0
awk '
    /if \[ -n "\$idem_ref" \] && task_has_approval_record_for "\$tid" "\$idem_ref"; then/ {
        print "        if true; then"; found=1; next
    }
    { print }
    END { if (!found) exit 7 }
' "$QG_REAL_H" > "$QG_MUT" || GUARD_MUT_RC=$?
chmod +x "$QG_MUT"
assert_eq "approve-idem-G META: the hash-aware guard was located and mutated" "0" "$GUARD_MUT_RC"
assert_eq "approve-idem-G META: ...the mutation landed in the copy" "1" \
    "$(grep -c '^        if true; then$' "$QG_MUT" | tr -d '[:space:]')"
G_MUT_PARSE=0
bash -n "$QG_MUT" 2>/dev/null || G_MUT_PARSE=$?
assert_eq "approve-idem-G META: the mutated copy still parses" "0" "$G_MUT_PARSE"

TID_G=$(new_task "$FH" "gz3 META: label-only guard deadlocks")
armed_cycle "$FH" "$TID_G" "src/g.ts"
( cd "$FH" && CLAUDE_PROJECT_DIR="$FH" bash "$QG_MUT" approve "$TID_G" "first approval" >/dev/null 2>&1 )
assert_eq "approve-idem-G META: precondition — the mutant's first approve wrote a record" \
    "1" "$(record_count "$FH" "$TID_G")"
# The post-approval edit, then the plain re-run (regenerate the report, approve
# again) driven against the mutant. NO `enter` — see the section header: with the
# jue fix an intervening enter clears qa-approved, so had_approved is 0 and the
# mutated guard is never reached.
seed_tracker "$FH" "src/g.ts" "src/g2.ts"
ct "$FH" set "$TID_G" >/dev/null 2>&1
assert_eq "approve-idem-G META: precondition — the mutant's post-edit state BLOCKS" \
    "block" "$(stop_decision "$FH")"
assert_contains "approve-idem-G META: precondition — qa-approved is still SET (so the guard is reachable)" \
    "qa-approved" "$(labels_of "$FH" "$TID_G")"
ir "$FH" "$TID_G" >/dev/null 2>&1
G_APPROVE=$( cd "$FH" && CLAUDE_PROJECT_DIR="$FH" bash "$QG_MUT" approve "$TID_G" "re-approved after the edit" 2>&1 | tail -1 )
assert_contains "approve-idem-G META: under the label-only guard approve is an idempotent no-op (A3 WOULD fail)" \
    "idempotent no-op" "$G_APPROVE"
assert_eq "approve-idem-G META: ...it writes no fresh record" "1" "$(record_count "$FH" "$TID_G")"
seed_tracker "$FH" "src/g.ts" "src/g2.ts"
ct "$FH" set "$TID_G" >/dev/null 2>&1
assert_eq "approve-idem-G META: ...and the gate is STILL blocked (A4 WOULD fail — the original deadlock)" \
    "block" "$(stop_decision "$FH")"
# The shipped script recovers the identical state, so the difference is the guard.
G_SHIPPED=$( qg "$FH" approve "$TID_G" "shipped guard recovers" 2>&1 | tail -1 )
# 8zi/jue moved this assertion here from A3/H3. On THIS path — a plain re-run with
# no intervening enter — qa-approved is still set and no record binds the current
# change set, so the hash-aware guard falls through loudly and NAMES it. That is
# the only remaining place the literal is reachable, which is exactly why the
# assertion has to live here now rather than be dropped.
assert_contains "approve-idem-G META: the SHIPPED guard names the stale-label re-bind in the audit trail" \
    "stale-label re-bind" "$G_SHIPPED"
assert_not_contains "approve-idem-G META: ...and does NOT report an idempotent no-op" \
    "idempotent no-op" "$G_SHIPPED"
seed_tracker "$FH" "src/g.ts" "src/g2.ts"
ct "$FH" set "$TID_G" >/dev/null 2>&1
assert_eq "approve-idem-G META: the SHIPPED guard recovers the identical state" \
    "ALLOW" "$(stop_decision "$FH")"

# ===========================================================================
# SECTION H — the empty-tracker reference: its residual, and how 94d closed it.
#
# The empty-tracker arm of set_idempotency_reference reads the PERSISTED impact
# report, because after an approve the tracker no longer witnesses what was
# approved (section B2 depends on that). Before 94d that carried a bounded
# residual, found by probing this arm rather than by waiting for it in the field:
#
#   tracker empty + real UN-BASELINED dirt (work written by a helper, never seen
#   by post-edit.sh — LESSONS.md/bi3.2) => the Stop hook blocks on the git half
#   of its predicate, while the persisted report still witnesses the PREVIOUS
#   approval. A bare `approve` therefore no-op'd and the block stood.
#
# 94d CLOSED IT, and from an unexpected direction. The no-op depended on the
# tracker still being EMPTY at approve time; the Stop hook now runs
# `qa-gate.sh reconcile-tracker` before it reads anything, so the helper-written
# file is in the tracker by the time approve runs. set_idempotency_reference
# therefore takes its LIVE-RECOMPUTE arm, no record binds that hash, and approve
# PROCEEDS into its preconditions — where the persisted report is correctly
# refused as STALE. The operator gets a precise refusal naming both hashes and
# the regenerate step, instead of a "success" that leaves the gate blocked.
#
# H2 below asserts that new behaviour; H3 (unchanged) still proves the printed
# remediation recovers the state. Note that the OLD justification for leaving the
# residual open — "fixing the no-op inside approve would require a second copy of
# the Stop hook's baseline-relative git walk" — no longer holds either:
# reconcile_tracker IS that walk, in a single callable definition. Moving
# approve's own reconcile above the idempotency check would close the remaining
# sliver (approve invoked with an empty tracker and no Stop in between); that is
# a deliberate decision for the approve-idempotency work, not a side effect of
# the tracker fix, so this spec pins the behaviour as shipped.
# ===========================================================================
gate_fixture
FR="$COMPONENT_FIXTURE_PATH"
TID_R=$(new_task "$FR" "gz3: residual — empty tracker, stale persisted report")
armed_cycle "$FR" "$TID_R" "src/r.ts"
qg "$FR" approve "$TID_R" "reviewed r.ts" >/dev/null 2>&1
assert_eq "approve-idem-H1: precondition — approve left the tracker empty" \
    "empty" "$([ -s "$FR/.claude/.qa-tracking/changed-files.txt" ] && echo populated || echo empty)"
# Dirt that never reaches the tracker, exactly like a helper-written file.
printf 'export const smuggled = 1;\n' > "$FR/helper-written.ts"
ct "$FR" set "$TID_R" >/dev/null 2>&1
H_JSON=$(stop_json "$FR")
assert_eq "approve-idem-H1: un-baselined dirt after an approval BLOCKS (the git half still sees it)" \
    "block" "$(json_field "$H_JSON" '.decision')"
# The Stop above reconciled the helper-written file into the tracker (94d), which
# is what takes the no-op off the table. Asserted first, because every H2 claim
# below follows from it.
assert_eq "approve-idem-H2: 94d — the Stop reconciled the helper-written file into the tracker" \
    "1" "$(grep -c 'helper-written\.ts' "$FR/.claude/.qa-tracking/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
H2_RC=0
H2_RAW=$(qg "$FR" approve "$TID_R" "bare approve, no regenerated report" 2>&1) || H2_RC=$?
H2_OUT=$(printf '%s\n' "$H2_RAW" | tail -1)
assert_eq "approve-idem-H2: a bare approve now REFUSES (exit 2) instead of no-op'ing" "2" "$H2_RC"
assert_json_field "approve-idem-H2: ...with status=error" "$H2_OUT" '.status' "error"
assert_json_field "approve-idem-H2: ...on the impact-report staleness check, not the idempotency guard" \
    "$H2_OUT" '.error_key' "impact_report_stale"
assert_not_contains "approve-idem-H2: ...and is NOT reported as an idempotent no-op (the pre-94d residual)" \
    "idempotent no-op" "$H2_OUT"
assert_contains "approve-idem-H2: ...steering to the step that resolves it" \
    "impact-report.sh" "$H2_OUT"
ct "$FR" set "$TID_R" >/dev/null 2>&1
assert_eq "approve-idem-H2: ...and the gate still blocks (nothing was released on a stale binding)" \
    "block" "$(stop_decision "$FR")"
# H3. The printed remediation — all three lines — still recovers this state.
# Bounded before the checks_scope_note disclosure tail, same reasoning as A2's
# extraction above (i8cx R5-F2's broader_verification_note "record one"
# suggestion is not part of this recipe).
H3_REMEDY="$FR/.claude/.qa-tracking/printed-remediation.txt"
printf '%s\n' "$(json_field "$(stop_json "$FR")" '.reason')" \
    | sed '/^WHAT THIS GATE RAN, EXACTLY\.$/,$d' \
    | grep -E '^[[:space:]]*bash \.claude/scripts/' | sed 's/^[[:space:]]*//' > "$H3_REMEDY"
assert_eq "approve-idem-H3: the still-blocking Stop prints the same 3-command remediation" \
    "3" "$(grep -c . "$H3_REMEDY" | tr -d '[:space:]')"
H3_APPROVE=""
H3_ENTER=""
while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    cmd=${cmd//\'<approval summary>\'/\'re-reviewed including the helper-written file\'}
    LINE=$( cd "$FR" && CLAUDE_PROJECT_DIR="$FR" eval "$cmd" 2>&1 | tail -1 )
    case "$cmd" in
        *"qa-gate.sh approve"*) H3_APPROVE="$LINE" ;;
        *"qa-gate.sh enter"*)   H3_ENTER="$LINE" ;;
    esac
done < "$H3_REMEDY"
assert_not_contains "approve-idem-H3: with step 2 run, approve is NOT a no-op" \
    "idempotent no-op" "$H3_APPROVE"
# 8zi/jue, same reasoning as A3: the remediation's own `enter` step removes the
# stale label, so the approve after it re-binds against the regenerated report
# WITHOUT a stale-label note. The step that made that true is asserted directly.
assert_contains "approve-idem-H3: the remediation's ENTER step clears the prior cycle's qa-approved (jue)" \
    "cleared a prior cycle's qa-approved" "$H3_ENTER"
assert_not_contains "approve-idem-H3: ...so the approve re-binds cleanly, with no stale-label note" \
    "stale-label re-bind" "$H3_APPROVE"
ct "$FR" set "$TID_R" >/dev/null 2>&1
assert_eq "approve-idem-H3: ...and the gate releases (residual is recoverable, not a deadlock)" \
    "ALLOW" "$(stop_decision "$FR")"

# ===========================================================================
# SECTION I — `--expect-hash`: did the CALLER'S verdict cover the set being
# bound? (claude-workflow-plugin-qzv)
#
# THE DEFECT. `verify-before-stop.sh`'s F1 fast path classifies a change set
# ("doc-only — nothing reviewable here") and THEN calls approve. Two reads, two
# instants, with `enter` — which reconciles the tracker and regenerates the impact
# report — in between. A path arriving in that window is inside what approve binds
# and outside what F1 judged. On the v4.1.0 release task the recorded approval
# bound `9942b2bd` while the work that shipped hashed to `914ceeff`.
#
# `--expect-hash <h>` makes the caller STATE the set it judged, and approve
# refuses when that is not the set it would bind. Mirrors `grade-record
# --graded-hash` in argument handling; the refusal names BOTH hashes, because
# "they differ" does not tell an operator which one is stale.
#
# WHAT SECTION I DOES NOT CLAIM. The check proves bound == classified. It does NOT
# prove the set is COMPLETE: both sides come from one canonicalisation of one
# tracker, so it detects drift and is structurally blind to loss
# (claude-workflow-plugin-fkm.1.20). No assertion below implies otherwise.
# ===========================================================================
gate_fixture
FI="$COMPONENT_FIXTURE_PATH"

TID_I=$(new_task "$FI" "qzv: --expect-hash binds the classified set")
armed_cycle "$FI" "$TID_I" "src/i.ts"
I_HASH=$(ir "$FI" --hash-only 2>/dev/null || echo "")
assert_eq "approve-idem-I0: precondition — the armed change set has a computable hash" \
    "yes" "$([ -n "$I_HASH" ] && echo yes || echo no)"

# I1. The MATCHING expectation approves, and says so in the audit trail.
I1_OUT=$(qg "$FI" approve "$TID_I" --expect-hash "$I_HASH" "reviewed i.ts" 2>&1 | tail -1)
assert_json_field "approve-idem-I1: a matching --expect-hash approves" "$I1_OUT" '.status' "approved"
assert_contains "approve-idem-I1: ...naming the verified expectation in the envelope" \
    "expected-hash verified" "$I1_OUT"
assert_contains "approve-idem-I1: ...and NOT claiming completeness (it binds, it does not witness)" \
    "NOT a completeness claim" "$I1_OUT"
assert_eq "approve-idem-I1: ...writing exactly one bound record" "1" "$(record_count "$FI" "$TID_I")"
assert_eq "approve-idem-I1: ...bound to the expected hash" "$I_HASH" "$(record_hash "$FI" "$TID_I")"

# I2. THE HEADLINE: a MISMATCHED expectation is REFUSED, nothing is written, and
# both hashes are named. Driven exactly as the live defect arrives — the caller
# classified set A, a path landed, and the set approve would bind is A+B.
TID_I2=$(new_task "$FI" "qzv: --expect-hash refuses a moved change set")
armed_cycle "$FI" "$TID_I2" "src/i2.ts"
I2_CLASSIFIED=$(ir "$FI" --hash-only 2>/dev/null || echo "")
# The path that arrives after the caller classified the set.
seed_tracker "$FI" "src/i2.ts" "src/i2-arrived-late.ts"
ir "$FI" "$TID_I2" >/dev/null 2>&1          # a FRESH report, so staleness is not the refusal
I2_BOUND=$(ir "$FI" --hash-only 2>/dev/null || echo "")
assert_eq "approve-idem-I2: precondition — the classified and bindable sets really differ" \
    "differ" "$([ -n "$I2_CLASSIFIED" ] && [ "$I2_CLASSIFIED" != "$I2_BOUND" ] && echo differ || echo same)"
I2_RC=0
# NB: capture the rc WITHOUT a pipe — `cmd | tail` yields tail's status, which is
# always 0 and would pass this assertion whatever approve did.
I2_RAW=$(qg "$FI" approve "$TID_I2" --expect-hash "$I2_CLASSIFIED" "doc-only verdict over a moved set" 2>&1) || I2_RC=$?
I2_OUT=$(printf '%s\n' "$I2_RAW" | tail -1)
assert_eq "approve-idem-I2: a mismatched --expect-hash is REFUSED (exit 2)" "2" "$I2_RC"
assert_json_field "approve-idem-I2: ...with error_key=expected_hash_mismatch" \
    "$I2_OUT" '.error_key' "expected_hash_mismatch"
assert_contains "approve-idem-I2: ...naming the hash the caller CLASSIFIED" "$I2_CLASSIFIED" "$I2_OUT"
assert_contains "approve-idem-I2: ...and the hash it would have BOUND" "$I2_BOUND" "$I2_OUT"
assert_contains "approve-idem-I2: ...and steering to the recompute that resolves it" \
    "impact-report.sh --hash-only" "$I2_OUT"
assert_contains "approve-idem-I2: ...while refusing to imply the binding proves completeness" \
    "does NOT prove that set is complete" "$I2_OUT"
assert_eq "approve-idem-I2: ...writing NO approval record" "0" "$(record_count "$FI" "$TID_I2")"
assert_not_contains "approve-idem-I2: ...and adding NO qa-approved label" \
    "qa-approved" "$(labels_of "$FI" "$TID_I2")"
# The refusal is not the impact-report staleness check wearing a different name:
# the report was regenerated above, so that check passes and this one is what
# fires. Asserted so a future reordering cannot make I2 pass for the wrong reason.
assert_not_contains "approve-idem-I2: ...and it is NOT the staleness refusal in disguise" \
    "impact_report_stale" "$I2_OUT"

# I3/I4. Argument handling, mirroring --graded-hash. Both are USAGE errors (exit
# 1) and must be distinguishable from a real mismatch — a shell-mangled value
# reported as `expected_hash_mismatch` would look like a genuine drift detection.
I3_RC=0
I3_RAW=$(qg "$FI" approve "$TID_I2" --expect-hash 2>&1) || I3_RC=$?
assert_eq "approve-idem-I3: --expect-hash with no value is a usage error (exit 1)" "1" "$I3_RC"
assert_json_field "approve-idem-I3: ...with error_key=missing_expected_hash" \
    "$(printf '%s\n' "$I3_RAW" | tail -1)" '.error_key' "missing_expected_hash"
I4_RC=0
I4_RAW=$(qg "$FI" approve "$TID_I2" --expect-hash "not a hash" "summary" 2>&1) || I4_RC=$?
assert_eq "approve-idem-I4: a non-hash --expect-hash value is a usage error (exit 1)" "1" "$I4_RC"
assert_json_field "approve-idem-I4: ...with error_key=expected_hash_invalid_chars" \
    "$(printf '%s\n' "$I4_RAW" | tail -1)" '.error_key' "expected_hash_invalid_chars"
assert_contains "approve-idem-I4: ...explicitly NOT reported as a change-set mismatch" \
    "NOT a change-set mismatch" "$(printf '%s\n' "$I4_RAW" | tail -1)"

# I5. ABSENT flag -> unchanged behaviour. The refusal must not become a new
# mandatory precondition: every existing caller passes no --expect-hash.
I5_OUT=$(qg "$FI" approve "$TID_I2" "no expectation stated" 2>&1 | tail -1)
assert_json_field "approve-idem-I5: with no --expect-hash, approve still approves" \
    "$I5_OUT" '.status' "approved"
assert_not_contains "approve-idem-I5: ...and says nothing about an expectation it was not given" \
    "expected-hash verified" "$I5_OUT"
assert_eq "approve-idem-I5: ...binding the current set" "$I2_BOUND" "$(record_hash "$FI" "$TID_I2")"

# ---------------------------------------------------------------------------
# SECTION IM — META: strip the EXPECTED-HASH-REFUSAL region and I2 goes green
# for the wrong reason, i.e. the mismatched expectation APPROVES.
#
# The region is arranged so stripping it yields the PRE-QZV function rather than a
# syntax error: the flag's parse arm, the refusal and the audit-observation
# assignment are all inside sentinels, and the envelope reads
# `${expect_hash_obs:-}` so the stripped copy still composes.
# ---------------------------------------------------------------------------
gate_fixture
FIM="$COMPONENT_FIXTURE_PATH"
QG_REAL_IM=$(readlink "$FIM/.claude/scripts/qa-gate.sh" 2>/dev/null || printf '%s' "$FIM/.claude/scripts/qa-gate.sh")
QG_IM_MUT="$FIM/.claude/scripts/qa-gate-noexpect.sh"
awk '
    /^ *# EXPECTED-HASH-REFUSAL BEGIN/ { skip = 1; next }
    /^ *# EXPECTED-HASH-REFUSAL END/   { skip = 0; next }
    !skip { print }
' "$QG_REAL_IM" > "$QG_IM_MUT"
chmod +x "$QG_IM_MUT"
if assert_mutant_applied "approve-idem-IM META" "$QG_REAL_IM" "$QG_IM_MUT"; then
    # Counted on the CODE line, not on the identifier — the same trap the 8M META
    # records. `expected_hash_mismatch` is also named in the `usage` text and in
    # the parse arm's explanatory comment, both DELIBERATELY outside the sentinels
    # (the usage block documents the flag for a human; excising it would make the
    # stripped copy advertise a flag it no longer has). A bare identifier grep
    # therefore answers 3 and this leg would fail for a reason that has nothing to
    # do with the mutation. Measured, not predicted: it did.
    #
    # COUNTS UPDATED for claude-workflow-plugin-k6re R6-F2 (measured red against
    # the shipped fix before this update: expected 0/1, got 1/2). Before that fix
    # there was exactly one `emit_error_json ... "expected_hash_mismatch"` call
    # site in the whole script — this block's own, inside EXPECTED-HASH-REFUSAL.
    # R6-F2 added a SECOND, independent one inside emit_approve_success
    # (APPROVE-SUCCESS-GATE-EXPECT-HASH, above cmd_approve) — same error_key, same
    # remediation text, on purpose (see that block's own header: "a caller or test
    # keyed on error_key must not care which of cmd_approve's two success exits
    # caught the mismatch" — the identical reasoning A2 already established for
    # design_conflict_open). This mutant strips ONLY the EXPECTED-HASH-REFUSAL
    # sentinel region, which — per this section's own header above — also removes
    # the ARG-PARSE arm (`--expect-hash)` itself lives inside these sentinels), so
    # $expect_hash_arg never becomes non-empty under the mutant and
    # emit_approve_success's OWN (untouched, unrelated) check never has anything
    # to compare — it is not "bypassed", it simply never receives an argument.
    # The shipped script's total is therefore 2, not 1; the stripped copy's
    # surviving count is 1 (emit_approve_success's own site), not 0 — both counts
    # moved for the SAME reason, not because either emit site relocated.
    assert_eq "approve-idem-IM META: THIS block's own emit site is gone (the strip landed where it was aimed)" \
        "1" "$(grep -c 'emit_error_json "approve" "\$tid" "expected_hash_mismatch"' "$QG_IM_MUT" | tr -d '[:space:]')"
    assert_eq "approve-idem-IM META: ...and the shipped script now carries TWO such emit sites (k6re R6-F2's independent second one, not a strip failure)" \
        "2" "$(grep -c 'emit_error_json "approve" "\$tid" "expected_hash_mismatch"' "$QG_REAL_IM" | tr -d '[:space:]')"
    assert_eq "approve-idem-IM META: ...and the ONE site surviving the strip is emit_approve_success's, not a duplicate of this block's" \
        "1" "$(grep -c '^emit_approve_success() {' "$QG_IM_MUT" | tr -d '[:space:]')"
    assert_eq "approve-idem-IM META: ...and the --expect-hash parse arm is gone with it" \
        "0" "$(grep -c -- '--expect-hash)' "$QG_IM_MUT" | tr -d '[:space:]')"
    assert_eq "approve-idem-IM META: the stripped copy still parses" "0" \
        "$(bash -n "$QG_IM_MUT" 2>/dev/null && echo 0 || echo 1)"
    TID_IM=$(new_task "$FIM" "qzv META: stripped refusal approves a moved set")
    armed_cycle "$FIM" "$TID_IM" "src/im.ts"
    IM_CLASSIFIED=$(ir "$FIM" --hash-only 2>/dev/null || echo "")
    seed_tracker "$FIM" "src/im.ts" "src/im-arrived-late.ts"
    # claude-workflow-plugin-rqer (v5 D2): reconcile BEFORE regenerating, so
    # armed_cycle's own canonical review artifact (still real and uncommitted
    # on disk) is folded back into the "bindable" set this leg's whole point
    # is to classify — the shipped qa-gate.sh's reconcile, since the IM
    # mutation touches only the --expect-hash refusal, never this.
    qg "$FIM" reconcile-tracker >/dev/null 2>&1
    ir "$FIM" "$TID_IM" >/dev/null 2>&1
    IM_BOUND=$(ir "$FIM" --hash-only 2>/dev/null || echo "")
    assert_eq "approve-idem-IM META: precondition — classified and bindable sets differ" \
        "differ" "$([ -n "$IM_CLASSIFIED" ] && [ "$IM_CLASSIFIED" != "$IM_BOUND" ] && echo differ || echo same)"
    # Under the stripped copy `--expect-hash <h>` is not a known flag, so the
    # pre-qzv parser folds it into the SUMMARY — which is precisely the pre-qzv
    # world: the caller's expectation is inert and the approval binds whatever the
    # set happens to be now.
    IM_RC=0
    IM_RAW=$( cd "$FIM" && CLAUDE_PROJECT_DIR="$FIM" bash "$QG_IM_MUT" approve "$TID_IM" \
        --expect-hash "$IM_CLASSIFIED" "doc-only verdict over a moved set" 2>&1 ) || IM_RC=$?
    IM_OUT=$(printf '%s\n' "$IM_RAW" | tail -1)
    assert_eq "approve-idem-IM META: with the refusal stripped the mismatched expectation APPROVES (I2 WOULD fail)" \
        "0" "$IM_RC"
    assert_json_field "approve-idem-IM META: ...with status=approved" "$IM_OUT" '.status' "approved"
    assert_eq "approve-idem-IM META: ...binding the set the caller never classified" \
        "$IM_BOUND" "$(record_hash "$FIM" "$TID_IM")"
    # Restore control: the SHIPPED script refuses the identical state.
    TID_IMC=$(new_task "$FIM" "qzv META: shipped refusal refuses the same state")
    armed_cycle "$FIM" "$TID_IMC" "src/imc.ts"
    IMC_CLASSIFIED=$(ir "$FIM" --hash-only 2>/dev/null || echo "")
    seed_tracker "$FIM" "src/imc.ts" "src/imc-arrived-late.ts"
    # claude-workflow-plugin-rqer (v5 D2): same reconcile-before-regenerate
    # reasoning as TID_IM above.
    qg "$FIM" reconcile-tracker >/dev/null 2>&1
    ir "$FIM" "$TID_IMC" >/dev/null 2>&1
    IMC_RC=0
    ( cd "$FIM" && CLAUDE_PROJECT_DIR="$FIM" bash "$FIM/.claude/scripts/qa-gate.sh" approve "$TID_IMC" \
        --expect-hash "$IMC_CLASSIFIED" "doc-only verdict over a moved set" >/dev/null 2>&1 ) || IMC_RC=$?
    assert_eq "approve-idem-IM META: restore control — the shipped script refuses it (exit 2)" "2" "$IMC_RC"
    assert_eq "approve-idem-IM META: ...and wrote no record" "0" "$(record_count "$FIM" "$TID_IMC")"
fi

# ===========================================================================
# SECTION J — `--expect-hash` on the IDEMPOTENT NO-OP PATH
# (claude-workflow-plugin-k6re R6-F2, the SECOND independently-found
# reach-around of the SAME hash-aware idempotency arm A2/i8cx already had to
# patch once, for a DIFFERENT precondition).
#
# THE DEFECT. Section I proves --expect-hash refuses a moved change set on
# the FRESH (non-idempotent) approval path. It says nothing about the
# hash-aware IDEMPOTENCY no-op (SECTION B/G, above): that arm reports
# status=approved and `return 0`s from a point in cmd_approve well BEFORE
# the EXPECTED-HASH-REFUSAL check (Section I's own subject) ever runs. A
# caller passing --expect-hash to an ALREADY-approved task whose bound
# record covers a DIFFERENT hash than expected therefore got an unqualified
# success envelope — the exact contract violation --expect-hash exists to
# prevent, on the one path nobody had driven it against. Fixed in qa-gate.sh
# by emit_approve_success (APPROVE-SUCCESS-GATE, immediately above
# cmd_approve): both of cmd_approve's success-reporting exits now call the
# same function, which refuses on a mismatch no matter which one is firing.
# ===========================================================================
gate_fixture
FJ="$COMPONENT_FIXTURE_PATH"

TID_J=$(new_task "$FJ" "k6re R6-F2: --expect-hash on the idempotent no-op path")
armed_cycle "$FJ" "$TID_J" "src/j1.ts"
qg "$FJ" approve "$TID_J" "first approval" >/dev/null 2>&1
assert_eq "approve-idem-J0: precondition — one bound record after the first approve" \
    "1" "$(record_count "$FJ" "$TID_J")"
J_BOUND=$(record_hash "$FJ" "$TID_J")
assert_eq "approve-idem-J0b: precondition — the bound hash is computable" \
    "yes" "$([ -n "$J_BOUND" ] && echo yes || echo no)"

# J1. A re-approve with the CORRECT --expect-hash on an already-approved,
# unchanged task: still a genuine no-op — the essential anti-overreach
# companion to J2 (a fix that re-verified EVERYTHING on the idempotent path
# would also satisfy J2 while breaking this).
J1_OUT=$(qg "$FJ" approve "$TID_J" --expect-hash "$J_BOUND" "re-approve, correct expectation" 2>&1 | tail -1)
assert_json_field "approve-idem-J1: a MATCHING --expect-hash on the idempotent no-op path still succeeds" \
    "$J1_OUT" '.status' "approved"
assert_contains "approve-idem-J1: ...still reported as an idempotent no-op" "idempotent no-op" "$J1_OUT"
assert_contains "approve-idem-J1: ...and names the verified expectation" "expected-hash verified" "$J1_OUT"
assert_eq "approve-idem-J1: ...and writes NO second record" "1" "$(record_count "$FJ" "$TID_J")"

# J2. THE HEADLINE: a MISMATCHED --expect-hash on the already-approved,
# unchanged task must now REFUSE — not silently no-op, which was the R6-F2
# defect. Driven exactly as A2's own repro shape: nothing about the FILES
# changed (idem_ref is unchanged from J0), only the CALLER's stated
# expectation is wrong.
J2_RC=0
J2_RAW=$(qg "$FJ" approve "$TID_J" \
    --expect-hash "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
    "re-approve, WRONG expectation" 2>&1) || J2_RC=$?
J2_OUT=$(printf '%s\n' "$J2_RAW" | tail -1)
assert_eq "approve-idem-J2: a MISMATCHED --expect-hash on the idempotent no-op path is REFUSED (exit 2) — THE R6-F2 FIX" \
    "2" "$J2_RC"
assert_json_field "approve-idem-J2: ...with error_key=expected_hash_mismatch (identical to the fresh-path refusal)" \
    "$J2_OUT" '.error_key' "expected_hash_mismatch"
assert_contains "approve-idem-J2: ...naming the hash it would have bound" "$J_BOUND" "$J2_OUT"
assert_contains "approve-idem-J2: ...naming the hash the caller wrongly expected" \
    "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" "$J2_OUT"
assert_eq "approve-idem-J2: ...and writes NO second record" "1" "$(record_count "$FJ" "$TID_J")"
assert_not_contains "approve-idem-J2: ...and it is NOT reported as an idempotent no-op in disguise" \
    "idempotent no-op" "$J2_OUT"

# J3. ABSENT flag on the idempotent path: unchanged behaviour — the second
# essential anti-overreach control. The refusal must not become a new
# mandatory precondition: every existing caller of a repeat approve passes
# no --expect-hash at all.
J3_OUT=$(qg "$FJ" approve "$TID_J" "re-approve, no expectation stated" 2>&1 | tail -1)
assert_json_field "approve-idem-J3: with NO --expect-hash, the idempotent no-op still succeeds" \
    "$J3_OUT" '.status' "approved"
assert_contains "approve-idem-J3: ...still an idempotent no-op" "idempotent no-op" "$J3_OUT"
assert_not_contains "approve-idem-J3: ...and says nothing about an expectation it was not given" \
    "expected-hash verified" "$J3_OUT"
assert_eq "approve-idem-J3: ...and still writes NO second record" "1" "$(record_count "$FJ" "$TID_J")"

# ---------------------------------------------------------------------------
# SECTION JM — META: strip emit_approve_success's --expect-hash check from a
# COPY and watch J2's exact scenario go green for the wrong reason (the
# mismatched expectation silently APPROVES again) — the anchor-revert control
# that would have caught R6-F2 itself.
#
# The region is sentinel-delimited inside emit_approve_success specifically
# so this strip removes ONLY the mismatch check, not the function's own
# success emission — a copy with the whole function gone would not parse.
# ---------------------------------------------------------------------------
gate_fixture
FJM="$COMPONENT_FIXTURE_PATH"
QG_REAL_JM=$(readlink "$FJM/.claude/scripts/qa-gate.sh" 2>/dev/null || printf '%s' "$FJM/.claude/scripts/qa-gate.sh")
QG_JM_MUT="$FJM/.claude/scripts/qa-gate-noapprovegate.sh"
awk '
    /# APPROVE-SUCCESS-GATE-EXPECT-HASH BEGIN/{s=1}
    !s{print}
    /# APPROVE-SUCCESS-GATE-EXPECT-HASH END/{s=0}
' "$QG_REAL_JM" > "$QG_JM_MUT"
STRIP_DELTA_JM=$(( $(wc -l < "$QG_REAL_JM") - $(wc -l < "$QG_JM_MUT") ))
assert_eq "approve-idem-JM META: the region strip actually removed lines" "yes" \
    "$([ "$STRIP_DELTA_JM" -gt 3 ] && echo yes || echo no)"
chmod +x "$QG_JM_MUT"
if assert_mutant_applied "approve-idem-JM META" "$QG_REAL_JM" "$QG_JM_MUT"; then
    assert_eq "approve-idem-JM META: the stripped copy still parses" "0" \
        "$(bash -n "$QG_JM_MUT" 2>/dev/null && echo 0 || echo 1)"

    TID_JM=$(new_task "$FJM" "k6re R6-F2 META: stripped gate approves a mismatched idempotent no-op")
    armed_cycle "$FJM" "$TID_JM" "src/jm1.ts"
    ( cd "$FJM" && CLAUDE_PROJECT_DIR="$FJM" bash "$QG_JM_MUT" approve "$TID_JM" "first approval, mutant" >/dev/null 2>&1 )
    assert_eq "approve-idem-JM META: precondition — the mutant's first approve wrote a record" \
        "1" "$(record_count "$FJM" "$TID_JM")"
    JM_BOUND=$(record_hash "$FJM" "$TID_JM")
    assert_eq "approve-idem-JM META: precondition — the mutant's bound hash is computable" \
        "yes" "$([ -n "$JM_BOUND" ] && echo yes || echo no)"

    JM_RAW=$( cd "$FJM" && CLAUDE_PROJECT_DIR="$FJM" bash "$QG_JM_MUT" approve "$TID_JM" \
        --expect-hash "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
        "re-approve, WRONG expectation, mutant" 2>&1 ); JM_RC=$?
    JM_OUT=$(printf '%s\n' "$JM_RAW" | tail -1)
    assert_eq "approve-idem-JM META: with the gate's check stripped, the MISMATCHED expectation APPROVES (J2 WOULD fail) — the exact R6-F2 forgery reproduced" \
        "0" "$JM_RC"
    assert_json_field "approve-idem-JM META: ...with status=approved" "$JM_OUT" '.status' "approved"
    assert_contains "approve-idem-JM META: ...silently reported as an idempotent no-op, over a hash the caller explicitly rejected" \
        "idempotent no-op" "$JM_OUT"
    assert_eq "approve-idem-JM META: ...and STILL writes no second record (only the caller's expectation was wrong, not the arm's no-op-ness)" \
        "1" "$(record_count "$FJM" "$TID_JM")"

    # Restore control: the SHIPPED script refuses the identical state.
    JMC_RC=0
    ( cd "$FJM" && CLAUDE_PROJECT_DIR="$FJM" bash "$FJM/.claude/scripts/qa-gate.sh" approve "$TID_JM" \
        --expect-hash "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" \
        "re-approve, WRONG expectation, shipped" >/dev/null 2>&1 ) || JMC_RC=$?
    assert_eq "approve-idem-JM META: restore control — the shipped script refuses the identical state (exit 2)" "2" "$JMC_RC"
    assert_eq "approve-idem-JM META: ...and still wrote no second record" "1" "$(record_count "$FJM" "$TID_JM")"
fi
rm -f "$QG_JM_MUT"

[ "$FAIL" -eq 0 ]
