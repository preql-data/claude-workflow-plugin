#!/bin/bash
# qa-gate-baseline.sh component spec.
#
# Closes claude-workflow-plugin-0wk.2. Covers the gate-baseline mechanism
# added in claude-workflow-plugin-0wk.18 Block 1: qa-gate.sh approve writes a
# sorted snapshot of `git status --porcelain`; verify-before-stop.sh's git
# fallback diffs current `git status` against that baseline and only treats
# NEW entries as detected changes.
#
# Why this spec exists:
# Before the fix, every Stop hook fired "0 file(s) changed - all require
# QA review" because vbs's git fallback re-detected pre-existing
# uncommitted modifications across sessions. The baseline mechanism is
# the silent state file that lets a fresh Stop know "nothing has been
# touched since the last approval; let the user out".
#
# 3mg.1 MIGRATION (gate-baseline v2). The file moved from the bare-line-list
# `.qa-tracking/approved-baseline` to the headered, versioned
# `.qa-tracking/gate-baseline`, and the writer from write_approved_baseline
# to write_gate_baseline. THIS spec keeps guarding the 0wk.2 regression on the
# v2 file; the v2-specific behaviour (session-start capture, enter's
# write-if-missing + tracker subtraction, legacy fallback reads, linked
# worktrees) is covered by its own spec, gate-baseline-v2.sh.
#
# 8 cases:
#   A. approve writes the v2 baseline (header + sorted git-status body).
#   B. approve truncates changed-files.txt.
#   C. vbs returns {} when current git status matches baseline.
#   D. vbs blocks when a NEW tracked-ext file appears.
#   E. enter is baseline-PRESERVING (write-if-missing) but retires the
#      legacy approved-baseline file. Pre-3mg.1 enter simply deleted.
#   F. write_gate_baseline tolerates missing .git (removes stale).
#   G. vbs falls back gracefully when baseline exists but .git is gone.
#   H. META-TEST: stubbing write_gate_baseline breaks specs A and C.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# The baseline scenarios all exercise qa-gate.sh approve/enter against real
# Beads tasks; the script reads bd state to compute the gate decision.
bd_required_or_skip

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"
BASELINE="$TRACK/gate-baseline"
LEGACY_BASELINE="$TRACK/approved-baseline"
TRACKING_FILE="$TRACK/changed-files.txt"

# baseline_body <file> — the snapshot lines of a v2 baseline, i.e. everything
# after the lone `--` provenance terminator. Mirrors verify-before-stop.sh's
# gate_baseline_entries reader so the spec asserts on the same view the gate
# consumes rather than on the header bytes.
baseline_body() {
    awk 'body { print; next } /^--$/ { body = 1 }' "$1" 2>/dev/null || true
}

# All specs below need a git repo for `git status --porcelain`. Init once.
# Configure a local identity so the wrapper's initial git operations don't
# fail with "Please tell me who you are" (cleaner than the global identity
# being absent in containerised CI environments).
(cd "$FIXTURE" && git init -q && git config user.email "test@local" && git config user.name "Test")

# Plant some committed state plus uncommitted state on top. The committed
# state means git status --porcelain reports specific FILES that change
# (not collapsed-untracked-directory entries), so a fresh file appearing
# later is visible to the porcelain diff. This mirrors the realistic
# scenario: the user has a repo with prior commits, then edits some files
# during a session.
mkdir -p "$FIXTURE/src"
printf 'export const original = 0;\n' > "$FIXTURE/src/committed.ts"
(cd "$FIXTURE" && git add src/committed.ts && git commit -q -m "initial commit")
# Now add an uncommitted modification (mimicking "approved a previous turn,
# uncommitted state still in working tree"). This is the file that
# pre-fix would have falsely re-triggered the gate.
printf 'export const original = 0;\nexport const a = 1;\n' > "$FIXTURE/src/committed.ts"

# ---------------------------------------------------------------------------
# Spec A: approve writes baseline (sorted git-status content).
# ---------------------------------------------------------------------------
TID_A=$(cd "$FIXTURE" && bd create "baseline write test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
# 3mg.1: enter is now write-if-missing, so it CREATES a baseline when none
# exists. Remove it before the approve leg so this case still measures what
# APPROVE wrote (the enter-side contract is spec E + gate-baseline-v2.sh).
bash "$QG" enter "$TID_A" >/dev/null
rm -f "$BASELINE"
# V3 (jio.1) MIGRATION: approve now refuses without an independent review
# artifact; seed the real records so this baseline spec still reaches approve.
seed_review_records "$TID_A"
assert_eq "baseline-A: baseline absent pre-approve" "1" \
    "$([ -f "$BASELINE" ] && echo 0 || echo 1)"

# Capture what git sees BEFORE approve so we can compare against the
# baseline file. LC_ALL=C to match the writer's collation.
EXPECTED=$(cd "$FIXTURE" && git status --porcelain | LC_ALL=C sort)

bash "$QG" approve "$TID_A" "Test approve writes baseline" >/dev/null

# Spec A.1: baseline file exists after approve.
assert_eq "baseline-A: baseline file created on approve" "0" \
    "$([ -f "$BASELINE" ] && echo 0 || echo 1)"
# Spec A.2: the baseline BODY equals sorted git status --porcelain.
ACTUAL=$(baseline_body "$BASELINE")
assert_eq "baseline-A: baseline body == sorted git status" "$EXPECTED" "$ACTUAL"
# Spec A.3: v2 provenance header is present and names the writer.
assert_eq "baseline-A: v2 version line" "# gate-baseline v1" \
    "$(head -1 "$BASELINE")"
assert_contains "baseline-A: v2 header records the writer" \
    "captured_by=qa-gate-approve" "$(cat "$BASELINE")"

# ---------------------------------------------------------------------------
# Spec B: approve truncates changed-files.txt.
# ---------------------------------------------------------------------------
# Re-seed tracker with stale content as if post-edit.sh had appended.
printf '/path/stale1.ts\n/path/stale2.ts\n' > "$TRACKING_FILE"
TID_B=$(cd "$FIXTURE" && bd create "baseline truncate test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_B" >/dev/null
seed_review_records "$TID_B"   # V3 (jio.1) MIGRATION
bash "$QG" approve "$TID_B" "Test approve truncates tracker" >/dev/null
# Spec B.1: file still exists (post-edit.sh appends to it; it would be
# wasteful to recreate every approval).
assert_eq "baseline-B: changed-files.txt preserved" "0" \
    "$([ -f "$TRACKING_FILE" ] && echo 0 || echo 1)"
# Spec B.2: file is empty (zero bytes).
SIZE=$(wc -c < "$TRACKING_FILE" | tr -d ' ')
assert_eq "baseline-B: changed-files.txt truncated to 0 bytes" "0" "$SIZE"

# ---------------------------------------------------------------------------
# Spec C: vbs returns {} when current git status matches baseline.
# ---------------------------------------------------------------------------
# Pre-condition: B's approve left a baseline matching CURRENT git status.
# No new files since then, so the baseline-diff should be empty.
#
# vbs reads current-task via the helper. approve clears it, so the path
# for "no current task" applies. With CODE_CHANGES_DETECTED=false (no
# tracker entries + baseline-matched fallback), vbs hits the early
# "no changes at all, allow" branch.
OUT_C=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_empty_envelope "baseline-C: vbs {} when status matches baseline" "$OUT_C"

# ---------------------------------------------------------------------------
# Spec D: vbs blocks when a NEW tracked-ext file appears since baseline.
# ---------------------------------------------------------------------------
# Drop a new file. It's not in the baseline; git status reports it as ??.
# is_tracked_change accepts .ts; with no active task vbs should block via
# the "QA approval required" path.
printf 'export const b = 2;\n' > "$FIXTURE/src/new-after-approve.ts"
# Ensure no active task (approve cleared it; double-check).
bash "$CT" clear
OUT_D=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
assert_decision "baseline-D: vbs blocks on new tracked file" "$OUT_D" "block"
REASON_D=$(printf '%s' "$OUT_D" | jq -r '.reason // empty')
assert_contains "baseline-D: block reason mentions QA approval required" \
    "QA approval required" "$REASON_D"

# Cleanup before next spec.
rm -f "$FIXTURE/src/new-after-approve.ts"

# ---------------------------------------------------------------------------
# Spec E: enter PRESERVES an existing v2 baseline, and retires the legacy file.
#
# 3mg.1 rewrote this case. Pre-3mg.1, `enter` simply deleted the baseline so
# the next approve re-snapshotted. That was correct while an approve was the
# ONLY writer, but it is wrong now that session-start captures one on arrival:
# deleting it would hand the cycle back the 0wk.2 symptom (a repo that was
# merely dirty before the session re-blocks every Stop). Enter is therefore
# write-if-missing — it never overwrites — while STILL removing the legacy
# `approved-baseline`, which carries no provenance and must not outlive the
# one-release fallback window.
# ---------------------------------------------------------------------------
# Plant a v2 baseline by hand (cheaper than approve) plus a legacy file.
printf '# gate-baseline v1\nhead=none\ncaptured_at=1970-01-01T00:00:00Z\ncaptured_by=test\n--\nM  /pre-existing-marker\n' > "$BASELINE"
printf 'M  /legacy-marker\n' > "$LEGACY_BASELINE"
assert_eq "baseline-E: pre-condition v2 baseline planted" "0" \
    "$([ -s "$BASELINE" ] && echo 0 || echo 1)"
TID_E=$(cd "$FIXTURE" && bd create "baseline enter preserves test" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_E" >/dev/null
assert_eq "baseline-E: enter keeps the existing v2 baseline (write-if-missing)" "0" \
    "$([ -f "$BASELINE" ] && echo 0 || echo 1)"
assert_eq "baseline-E: enter does not overwrite the planted snapshot" \
    "M  /pre-existing-marker" "$(baseline_body "$BASELINE")"
assert_eq "baseline-E: enter retires the legacy approved-baseline" "1" \
    "$([ -f "$LEGACY_BASELINE" ] && echo 0 || echo 1)"
rm -f "$BASELINE"

# ---------------------------------------------------------------------------
# Spec F: write_gate_baseline tolerates missing .git (removes stale).
# ---------------------------------------------------------------------------
# Plant a stale baseline (both spellings) then remove .git BEFORE approve
# runs. The helper must remove them (so a future git-init wouldn't inherit
# data from a different repo era) and return success.
printf 'M  /stale-from-prior-repo\n' > "$BASELINE"
printf 'M  /stale-legacy-from-prior-repo\n' > "$LEGACY_BASELINE"
GIT_BACKUP=$(mktemp -d -t qg-baseline-git-backup.XXXXXX)
mv "$FIXTURE/.git" "$GIT_BACKUP/.git"
TID_F=$(cd "$FIXTURE" && bd create "baseline no-git tolerance" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG" enter "$TID_F" >/dev/null
seed_review_records "$TID_F"   # V3 (jio.1) MIGRATION
# Run approve - should succeed AND remove the stale baseline.
APPROVE_F=$(bash "$QG" approve "$TID_F" "no-git approve" 2>&1)
APPROVE_F_OK=$(printf '%s' "$APPROVE_F" | tail -1 | jq -r '.ok // "false"' 2>/dev/null || echo "false")
assert_eq "baseline-F: approve succeeds without .git" "true" "$APPROVE_F_OK"
assert_eq "baseline-F: stale baseline removed when no .git" "1" \
    "$([ -f "$BASELINE" ] && echo 0 || echo 1)"
assert_eq "baseline-F: stale LEGACY baseline removed when no .git" "1" \
    "$([ -f "$LEGACY_BASELINE" ] && echo 0 || echo 1)"
# Restore git for the remaining specs.
mv "$GIT_BACKUP/.git" "$FIXTURE/.git"
rmdir "$GIT_BACKUP"

# ---------------------------------------------------------------------------
# Spec G: vbs falls back gracefully when baseline exists but .git is gone.
# ---------------------------------------------------------------------------
# Simulate corruption: baseline left from a prior repo, but .git is gone.
# vbs guards the entire git-fallback branch with has_git_repo (3mg.1; the
# guard was `[ -d "$PROJECT_DIR/.git" ]` before, which mis-answered in linked
# worktrees — see gate-baseline-v2.sh). Either way a stale baseline with no
# repo is effectively ignored: the fallback block doesn't execute,
# CODE_CHANGES_DETECTED stays whatever the tracker said, and the gate
# proceeds. We assert vbs doesn't crash + produces valid JSON.
printf '# gate-baseline v1\nhead=none\ncaptured_at=1970-01-01T00:00:00Z\ncaptured_by=test\n--\nM  /pretend-this-is-from-old-repo\n' > "$BASELINE"
GIT_BACKUP=$(mktemp -d -t qg-baseline-git-backup2.XXXXXX)
mv "$FIXTURE/.git" "$GIT_BACKUP/.git"
: > "$TRACKING_FILE"  # ensure tracker is empty so the early {} branch fires
bash "$CT" clear      # ensure no active task
OUT_G=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS" 2>&1 | tail -1)
# Either {} (no changes) or a valid envelope - the point is "no crash".
# Verify it's at least valid JSON.
G_VALID=$(printf '%s' "$OUT_G" | jq -e '.' >/dev/null 2>&1 && echo "yes" || echo "no")
assert_eq "baseline-G: vbs emits valid JSON when .git is gone + stale baseline" \
    "yes" "$G_VALID"
# Restore git for spec H.
mv "$GIT_BACKUP/.git" "$FIXTURE/.git"
rmdir "$GIT_BACKUP"
rm -f "$BASELINE"

# ---------------------------------------------------------------------------
# Spec H (META-TEST): stub write_gate_baseline to a no-op, confirm
# specs A and C fail. This proves the test is sensitive to the fix being
# in place - if someone reverted the qa-gate.sh change but left the spec
# untouched, the meta-test catches it.
#
# Strategy: build a SECOND fixture, replace its qa-gate.sh symlink with a
# copy that has write_gate_baseline neutralised. Re-run the A/C
# assertions against this stubbed copy. TEXT-anchored on the function
# header, never on a line number.
# ---------------------------------------------------------------------------
mk_fixture
FIXTURE_H="$COMPONENT_FIXTURE_PATH"
QG_H="$FIXTURE_H/.claude/scripts/qa-gate.sh"
VBS_H="$FIXTURE_H/.claude/scripts/verify-before-stop.sh"
CT_H="$FIXTURE_H/.claude/scripts/current-task.sh"
TRACK_H="$FIXTURE_H/.claude/.qa-tracking"
BASELINE_H="$TRACK_H/gate-baseline"

(cd "$FIXTURE_H" && git init -q && git config user.email "test@local" && git config user.name "Test")
mkdir -p "$FIXTURE_H/src"
# Same committed-then-uncommitted pattern as the main fixture (see comment
# above the main `git commit -q`). Required so git status reports a
# specific FILE rather than collapsing the whole src/ dir as untracked.
printf 'export const original = 0;\n' > "$FIXTURE_H/src/h-committed.ts"
(cd "$FIXTURE_H" && git add src/h-committed.ts && git commit -q -m "initial commit")
printf 'export const original = 0;\nexport const a = 1;\n' > "$FIXTURE_H/src/h-committed.ts"

# Replace the qa-gate.sh symlink with a stubbed copy (rm FIRST so the
# rewrite can never travel down the symlink into the real plugin script).
# awk filters the write_gate_baseline function body, replacing it with
# `return 0`. The function's only column-0 `}` is its terminator, so the
# brace-depth-free scan below is exact.
PLUGIN_QG=$(readlink "$QG_H")
rm "$QG_H"
awk '
    BEGIN { in_fn=0; replaced=0 }
    /^write_gate_baseline\(\) \{$/ && !replaced {
        print "write_gate_baseline() {"
        print "    return 0"
        print "}"
        in_fn=1
        replaced=1
        next
    }
    in_fn && /^\}$/ { in_fn=0; next }
    in_fn { next }
    { print }
    END { if (!replaced) exit 7 }
' "$PLUGIN_QG" > "$QG_H"
STUB_RC=$?
chmod +x "$QG_H"
assert_eq "baseline-H: write_gate_baseline found and stubbed (text-anchored)" "0" "$STUB_RC"

# Sanity: confirm the stub took effect (the function body in the file
# should now be just "return 0") and the copy still parses.
STUB_GREP=$(grep -A 2 '^write_gate_baseline()' "$QG_H" | head -3)
assert_match "baseline-H: stub installed (body == return 0)" \
    "return 0" "$STUB_GREP"
STUB_PARSE=0
bash -n "$QG_H" 2>/dev/null || STUB_PARSE=$?
assert_eq "baseline-H: stubbed copy still parses" "0" "$STUB_PARSE"

# Now re-run spec A's check against the stubbed copy. With the stub, the
# baseline file should NOT be written by approve.
TID_HA=$(cd "$FIXTURE_H" && bd create "META: stubbed approve A" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$QG_H" enter "$TID_HA" >/dev/null
seed_review_records "$TID_HA" "qa-claude" "backend" "$FIXTURE_H"   # V3 (jio.1) MIGRATION
bash "$QG_H" approve "$TID_HA" "Stubbed approve - baseline should NOT appear" >/dev/null

# Spec A's invariant: baseline exists. With the stub it does NOT exist.
# We assert the OPPOSITE here to demonstrate spec A would fail.
H_A_BASELINE_PRESENT=$([ -f "$BASELINE_H" ] && echo "yes" || echo "no")
assert_eq "baseline-H: META spec A WOULD fail under stub (no baseline written)" \
    "no" "$H_A_BASELINE_PRESENT"

# Spec C's invariant: with baseline matching git, vbs returns {}. Under
# the stub, no baseline is written, so vbs's fallback treats the
# pre-existing uncommitted .ts file as a NEW change and BLOCKS.
bash "$CT_H" clear
OUT_HC=$(printf '%s' '{"stop_reason":"end_turn"}' | bash "$VBS_H" 2>&1 | tail -1)
H_C_DECISION=$(printf '%s' "$OUT_HC" | jq -r '.decision // empty' 2>/dev/null || echo "")
assert_eq "baseline-H: META spec C WOULD fail under stub (vbs blocks on pre-existing)" \
    "block" "$H_C_DECISION"

[ "$FAIL" -eq 0 ]
