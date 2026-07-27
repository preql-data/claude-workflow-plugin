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
gate_fixture() {
    mk_fixture
    bd_required_or_skip
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
    bdq "$1" show "$2" --json 2>/dev/null \
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
qg "$FA" approve "$TID_A" "reviewed a.ts" >/dev/null 2>&1
seed_tracker "$FA" "src/a.ts"
ct "$FA" set "$TID_A" >/dev/null 2>&1
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
# run exactly those.
REMEDY_FILE="$FA/.claude/.qa-tracking/printed-remediation.txt"
printf '%s\n' "$A_REASON" | grep -E '^[[:space:]]*bash \.claude/scripts/' \
    | sed 's/^[[:space:]]*//' > "$REMEDY_FILE"
assert_eq "approve-idem-A2: the block prints a 3-command remediation" \
    "3" "$(grep -c . "$REMEDY_FILE" | tr -d '[:space:]')"
assert_eq "approve-idem-A2: ...and still prints no 'bd label remove' step" \
    "0" "$(grep -c 'bd label remove' "$REMEDY_FILE" | tr -d '[:space:]')"
assert_contains "approve-idem-A2: ...and says so explicitly (do NOT remove the label first)" \
    "do NOT remove the qa-approved label first" "$A_REASON"

A_APPROVE_OUT=""
while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    cmd=${cmd//\'<approval summary>\'/\'re-reviewed after the post-approval edit\'}
    OUT_LINE=$( cd "$FA" && CLAUDE_PROJECT_DIR="$FA" eval "$cmd" 2>&1 | tail -1 )
    case "$cmd" in *"qa-gate.sh approve"*) A_APPROVE_OUT="$OUT_LINE" ;; esac
done < "$REMEDY_FILE"

assert_json_field "approve-idem-A3: the printed approve SUCCEEDS" "$A_APPROVE_OUT" '.status' "approved"
assert_not_contains "approve-idem-A3: ...and is NOT reported as an idempotent no-op" \
    "idempotent no-op" "$A_APPROVE_OUT"
assert_contains "approve-idem-A3: ...it names the stale-label re-bind in the audit trail" \
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
qg "$FB" approve "$TID_B" "reviewed b1.ts" >/dev/null 2>&1
assert_eq "approve-idem-B0: precondition — one bound record after the first approve" \
    "1" "$(record_count "$FB" "$TID_B")"

# B1. The same change set back in the tracker: the live recompute matches the
# recorded hash -> no-op.
seed_tracker "$FB" "src/b1.ts"
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
# ===========================================================================
PLUGIN_D=$(plugin_root)
QG_CAPTURE=$(grep -o 'capture("change_set_hash=(?<h>\[A-Za-z0-9-\]+)")\.h' "$PLUGIN_D/.claude/scripts/qa-gate.sh" | sort -u)
VBS_CAPTURE=$(grep -o 'capture("change_set_hash=(?<h>\[A-Za-z0-9-\]+)")\.h' "$PLUGIN_D/.claude/scripts/verify-before-stop.sh" | sort -u)
assert_eq "approve-idem-D1: qa-gate.sh carries the hash-capture expression at all" \
    "yes" "$([ -n "$QG_CAPTURE" ] && echo yes || echo no)"
assert_eq "approve-idem-D1: ...byte-identical to verify-before-stop.sh's release expression" \
    "$VBS_CAPTURE" "$QG_CAPTURE"
assert_eq "approve-idem-D1: ...and the same record selector" "1" \
    "$(grep -c 'select(test("QA-GATE APPROVED .\*change_set_hash="))' "$PLUGIN_D/.claude/scripts/qa-gate.sh" | tr -d '[:space:]')"

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
REAL_BD_E=$(sed -n 's/^exec \(.*\) --no-daemon.*/\1/p' "$FE/bin/bd" 2>/dev/null | tr -d '"' | head -1)
[ -z "$REAL_BD_E" ] && REAL_BD_E=$(command -v bd)
cat > "$FE/bin/bd" <<EOF
#!/bin/bash
if [ "\$1" = "label" ] && [ "\$2" = "add" ] && [ "\$4" = "qa-approved" ]; then exit 1; fi
exec $REAL_BD_E --no-daemon "\$@"
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
exec $REAL_BD_E --no-daemon "\$@"
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
L_LABEL=$(line_of "$QG_REAL" '    if ! add_label "$tid" "qa-approved"; then')
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
real_bd_of() {
    local p
    p=$(sed -n 's/^exec \(.*\) --no-daemon.*/\1/p' "$1/bin/bd" 2>/dev/null | tr -d '"' | head -1)
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
    $real --no-daemon "\$@"; rc=\$?
    $real --no-daemon show "\$3" --json 2>/dev/null \\
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
exec $real --no-daemon "\$@"
EOF
    chmod +x "$root/bin/bd"
}
# Restore the plain wrapper by hand (never via mk_bd_shim — see its guard).
restore_bd() {
    local root="$1" real; real=$(real_bd_of "$root")
    printf '#!/bin/bash\nexec %s --no-daemon "$@"\n' "$real" > "$root/bin/bd"
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
rm -f "$FG2/smuggled.ts"
ct "$FG2" set "$TID_F2" >/dev/null 2>&1
assert_eq "approve-idem-F2: removing the un-baselined dirt restores the release (block was attributable)" \
    "ALLOW" "$(stop_decision "$FG2")"

# ===========================================================================
# SECTION G — META: revert the guard to had_approved-only.
#
# Section A's recovery must depend on the hash-aware guard and nothing else that
# changed. A copy whose guard short-circuits unconditionally must reproduce the
# original deadlock: approve reports an idempotent no-op and the gate stays
# blocked.
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
# The post-approval edit, then the printed remediation, driven against the mutant.
seed_tracker "$FH" "src/g.ts" "src/g2.ts"
ct "$FH" set "$TID_G" >/dev/null 2>&1
assert_eq "approve-idem-G META: precondition — the mutant's post-edit state BLOCKS" \
    "block" "$(stop_decision "$FH")"
( cd "$FH" && CLAUDE_PROJECT_DIR="$FH" bash "$QG_MUT" enter "$TID_G" >/dev/null 2>&1 )
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
qg "$FH" approve "$TID_G" "shipped guard recovers" >/dev/null 2>&1
seed_tracker "$FH" "src/g.ts" "src/g2.ts"
ct "$FH" set "$TID_G" >/dev/null 2>&1
assert_eq "approve-idem-G META: the SHIPPED guard recovers the identical state" \
    "ALLOW" "$(stop_decision "$FH")"

# ===========================================================================
# SECTION H — the RESIDUAL of the empty-tracker reference, pinned as reality.
#
# The empty-tracker arm of set_idempotency_reference reads the PERSISTED impact
# report, because after an approve the tracker no longer witnesses what was
# approved (section B2 depends on that). The cost is a bounded residual, found by
# probing this arm rather than by waiting for it in the field:
#
#   tracker empty + real UN-BASELINED dirt (work written by a helper, never seen
#   by post-edit.sh — LESSONS.md/bi3.2) => the Stop hook blocks on the git half
#   of its predicate, while the persisted report still witnesses the PREVIOUS
#   approval. A bare `approve` therefore no-ops and the block stands.
#
# This is pinned, not papered over, and it is NOT the gz3 deadlock: the printed
# remediation still recovers, because its step 2 (impact-report.sh) re-persists
# the report — after which no record binds it and approve proceeds. H3 proves
# exactly that. Fixing the no-op inside approve would require a second copy of
# the Stop hook's baseline-relative git walk (reviewable_changes), which is the
# drift the one-definition rule exists to prevent; the chosen mitigation is that
# the no-op NAMES the reference it matched, asserted in H2.
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
H2_OUT=$(qg "$FR" approve "$TID_R" "bare approve, no regenerated report" 2>&1 | tail -1)
assert_json_field "approve-idem-H2: THE RESIDUAL — a bare approve reports success..." \
    "$H2_OUT" '.status' "approved"
assert_contains "approve-idem-H2: ...as an idempotent no-op against the previous approval" \
    "idempotent no-op" "$H2_OUT"
assert_contains "approve-idem-H2: ...NAMING the persisted report as the reference it matched" \
    "persisted impact report" "$H2_OUT"
assert_contains "approve-idem-H2: ...and steering to the step that resolves it" \
    "re-run impact-report.sh" "$H2_OUT"
ct "$FR" set "$TID_R" >/dev/null 2>&1
assert_eq "approve-idem-H2: ...so the gate still blocks (the residual, stated as reality)" \
    "block" "$(stop_decision "$FR")"
# H3. The printed remediation — all three lines — still recovers this state.
H3_REMEDY="$FR/.claude/.qa-tracking/printed-remediation.txt"
printf '%s\n' "$(json_field "$(stop_json "$FR")" '.reason')" \
    | grep -E '^[[:space:]]*bash \.claude/scripts/' | sed 's/^[[:space:]]*//' > "$H3_REMEDY"
assert_eq "approve-idem-H3: the still-blocking Stop prints the same 3-command remediation" \
    "3" "$(grep -c . "$H3_REMEDY" | tr -d '[:space:]')"
H3_APPROVE=""
while IFS= read -r cmd; do
    [ -z "$cmd" ] && continue
    cmd=${cmd//\'<approval summary>\'/\'re-reviewed including the helper-written file\'}
    LINE=$( cd "$FR" && CLAUDE_PROJECT_DIR="$FR" eval "$cmd" 2>&1 | tail -1 )
    case "$cmd" in *"qa-gate.sh approve"*) H3_APPROVE="$LINE" ;; esac
done < "$H3_REMEDY"
assert_not_contains "approve-idem-H3: with step 2 run, approve is NOT a no-op" \
    "idempotent no-op" "$H3_APPROVE"
assert_contains "approve-idem-H3: ...it re-binds against the regenerated report" \
    "stale-label re-bind" "$H3_APPROVE"
ct "$FR" set "$TID_R" >/dev/null 2>&1
assert_eq "approve-idem-H3: ...and the gate releases (residual is recoverable, not a deadlock)" \
    "ALLOW" "$(stop_decision "$FR")"

[ "$FAIL" -eq 0 ]
