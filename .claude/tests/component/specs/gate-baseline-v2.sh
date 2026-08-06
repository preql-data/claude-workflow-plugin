#!/bin/bash
# gate-baseline-v2.sh component spec — claude-workflow-plugin-3mg.1 (Phase V4).
#
# WHAT A GATE BASELINE IS
# -----------------------
# A snapshot of `git status --porcelain` that says "this dirt was already
# here; it is not this session's work". verify-before-stop.sh's git fallback
# subtracts it, so the Stop gate evaluates the session DELTA rather than the
# whole working tree.
#
# THE BUG THIS CLOSES (transcript scenario 1, section 1 below)
# ------------------------------------------------------------
# 0wk.2 gave the baseline exactly one writer: `qa-gate.sh approve`. So the
# very first session in a repo that was merely dirty on arrival — a
# half-finished refactor, a vendored file, an unstaged config tweak — had no
# baseline at all, and every Stop reported "N file(s) changed - all require
# QA review" for changes the session never made. The only exits were
# approving a task for someone else's work or committing it. 3mg.1 adds two
# more writers (session-start on arrival, qa-gate enter when a cycle opens
# without one) and a versioned, provenanced file format so a snapshot can be
# attributed and diagnosed.
#
# WHAT THIS SPEC COVERS
#   1. TRANSCRIPT SCENARIO 1 — 3 pre-dirty files, session-start baseline,
#      Stop releases; new dirt after the baseline blocks and names ONLY the
#      new path. Both legs fail on pre-3mg.1 code (there was no writer).
#   1M. META (spec-mandated) — truncate the baseline to empty and the
#      exclusion assertions must FAIL: the gate blocks and names all three
#      pre-dirty files again. Without this the section could be green because
#      the gate is releasing for some unrelated reason.
#   2. session-start writes ONLY when no review cycle is active.
#   3. enter — write-if-missing, minus already-tracked files.
#   4. approve — full refresh.
#   5. legacy `approved-baseline` read as a one-release fallback, retired on
#      the first v2 write.
#   6. THE `-d .git` FIX — in a LINKED WORKTREE `.git` is a FILE, so the old
#      `[ -d "$PROJECT_DIR/.git" ]` predicate was false and the baseline
#      writer AND the Stop gate's git fallback both silently disabled
#      themselves: the gate failed OPEN in exactly the topology the plugin
#      tells agents to use. Now both ask `git rev-parse --git-dir`.
#   7. THE TRACKER RECONCILE (94d) — the baseline's other half. The baseline
#      says which git dirt is NOT this session's work; the reconcile says
#      which of the rest the tracker is MISSING, because post-edit.sh only
#      sees Write/Edit/MultiEdit/NotebookEdit and a file written by a Bash
#      redirect never reached changed-files.txt — the file change_set_hash is
#      computed over. Section 7 drives both writers against one tree and pins
#      that the hash moves for the Bash-written file, that neither file is
#      double-counted, and that baselined dirt still stays out.
#   7M. META (spec-mandated) — strip every TRACKER-RECONCILE region from
#      fixture copies of qa-gate.sh and verify-before-stop.sh; the
#      Bash-written file must vanish from the tracker AND from the block
#      reason's absolute-spelled file list. Restore-control re-asserts both.
#   7.6/7.7 THE RESIDUAL AND ITS BOUNDARY (dpe / QA finding R4-F1) — the
#      baseline is subtracted over raw porcelain LINES, so a second write to an
#      already-baselined path is invisible to the reconcile, the hash and the
#      reviewer, with no commit involved; a write to a path that was CLEAN at
#      capture is folded in by the same call. Both directions, one tree.
#   7R. META — one variable (the baseline-subtraction branch forced to its
#      no-baseline arm) flips 7.6, proving the residual is that subtraction
#      rather than an incidental filter.
#   7S. THE DROP IS NO LONGER SILENT (claude-workflow-plugin-94d.1). 7.6 pins
#      that a baselined path stays out of the tracker and the hash. That is the
#      residual, and it is not fixed. What WAS fixed is that the reconcile used
#      to report only what it ADDED, so a call that dropped 16 git-visible paths
#      and a call that dropped none were indistinguishable — `ok:true`,
#      `added=N`, nothing else. 7S pins the accounting (`subtracted=N`, the
#      paths, the sidecar file), the rebuild-from-an-empty-tracker announcement,
#      and the approve refusal (`change_set_reconstructed`) that the three
#      together arm — with the two controls that separate "reconstructed" from
#      "merely subtracted" (7S.4) and from "reconstructed but EMPTY" (7S.6).
#   7SM. META — strip the SUBTRACTION-ACCOUNTING regions alone; the same call
#      reverts to the pre-94d.1 silent success AND approve stops refusing.
#      Restore-control re-asserts both.
#
# The v1 file (`approved-baseline`, a bare line list) is superseded by the v2
# `gate-baseline`:
#     # gate-baseline v1
#     head=<sha|none> / captured_at=<ts> / captured_by=<who>
#     --
#     <LC_ALL=C-sorted porcelain lines>
# The 0wk.2 regression itself still lives in qa-gate-baseline.sh, retargeted
# at the v2 file.

set -u

# ---------------------------------------------------------------------------
# Helpers.

# baseline_body <file> — the snapshot lines (everything after the lone `--`).
# Mirrors verify-before-stop.sh's gate_baseline_entries so the spec reads the
# same view the gate consumes.
baseline_body() {
    awk 'body { print; next } /^--$/ { body = 1 }' "$1" 2>/dev/null || true
}

baseline_header_field() {
    # baseline_header_field <file> <key>
    sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1
}

# stop_decision / stop_reason <root> — drive the Stop hook of the checkout at
# <root> (which is NOT always the fixture: section 6 drives a worktree).
stop_decision() {
    local root="$1"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/verify-before-stop.sh" 2>/dev/null \
        | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}

stop_reason() {
    local root="$1"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/verify-before-stop.sh" 2>/dev/null \
        | tail -1 | jq -r '.reason // empty' 2>/dev/null
}

# WHY SECTIONS 1-6 MEASURE THE DECISION, NOT THE REASON TEXT
# ----------------------------------------------------------
# The block reason's "Files changed:" list and its `changed_files[]` payload are
# both enumerated from changed-files.txt, never from the git walk. Its
# `diff_summary` field is `git diff --stat HEAD` over the WHOLE tree, so every
# pre-dirty file appears there whether the baseline excluded it or not.
# Asserting "the reason does not mention src/pre1.ts" would therefore be
# unfalsifiable-in-the-wrong-direction: it can never pass, and a naive fix
# (assert it DOES appear) would pass with the baseline mechanism entirely
# removed. The falsifiable observable is the DECISION, so each case in sections
# 1-6 pairs a block with the removal of its cause and asserts the release comes
# back.
#
# Section 7 CAN assert on the reason text, and does, because 94d gave the two
# surfaces different spellings: changed-files.txt holds ABSOLUTE paths (both its
# writers emit them) while the git walk yields repo-relative ones. So
# "$F7/src/b.ts" appearing in the reason proves the path reached the TRACKER —
# the surface change_set_hash is computed over — and not merely the detector.
# That distinction is the whole point of 94d, and it is what makes 7M's strip
# leg falsifiable: with the reconcile stripped the detector still reports
# src/b.ts (the union is not sentinel-wrapped), so only the absolute spelling
# discriminates.

# dirt_lines <root> — non-ignored porcelain entries, for preconditions that
# need to say exactly what the tree is dirty with.
dirt_lines() {
    git -C "$1" status --porcelain 2>/dev/null | LC_ALL=C sort
}

# git_fixture_init <root> — commit the fixture as its baseline HEAD, with the
# gate's own bookkeeping gitignored. `.claude/.qa-tracking/` is gitignored in
# the real plugin repo too (it is per-session ephemera), and leaving it
# tracked here would make the gate's own writes dirty the tree mid-spec: the
# snapshot would go stale the instant it was taken.
git_fixture_init() {
    local root="$1"
    printf '.claude/.qa-tracking/\n.claude/.session-start\n' > "$root/.gitignore"
    (cd "$root" && git init -q && git config user.email t@t.t && git config user.name t \
        && git add -A && git commit -qm baseline) >/dev/null 2>&1
}

fast_stack_stub() {
    local root="$1"
    rm -f "$root/.claude/scripts/detect-stack.sh"
    printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
        > "$root/.claude/scripts/detect-stack.sh"
    chmod +x "$root/.claude/scripts/detect-stack.sh"
}

# ===========================================================================
# SECTION 1 — TRANSCRIPT SCENARIO 1: a repo that was already dirty on arrival.
# ===========================================================================
mk_fixture
F1="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$F1"
BASE1="$F1/.claude/.qa-tracking/gate-baseline"
LEGACY1="$F1/.claude/.qa-tracking/approved-baseline"
TRACK1="$F1/.claude/.qa-tracking/changed-files.txt"
SS1="$F1/.claude/scripts/session-start.sh"
CT1="$F1/.claude/scripts/current-task.sh"
QG1="$F1/.claude/scripts/qa-gate.sh"

# A repo with real history, then THREE files dirtied before the session opens.
# Committed-then-modified (not untracked) so porcelain names each FILE rather
# than collapsing an untracked directory into one entry.
mkdir -p "$F1/src"
printf 'export const a = 0;\n' > "$F1/src/pre1.ts"
printf 'export const b = 0;\n' > "$F1/src/pre2.ts"
printf 'export const c = 0;\n' > "$F1/src/pre3.ts"
git_fixture_init "$F1"
printf 'export const a = 1; // half-finished refactor\n' > "$F1/src/pre1.ts"
printf 'export const b = 1; // vendored tweak\n'         > "$F1/src/pre2.ts"
printf 'export const c = 1; // unstaged config\n'        > "$F1/src/pre3.ts"
bash "$CT1" clear
: > "$TRACK1"

# 1.0 The pre-fix world, reproduced: no baseline -> the gate blocks on dirt
# the session never touched. This is the control the rest of the section is
# measured against.
assert_eq "gbv2-1.0: precondition — the tree is dirty with exactly the 3 pre-existing files" \
    "3" "$(dirt_lines "$F1" | grep -c 'src/pre' | tr -d '[:space:]')"
assert_eq "gbv2-1.0: precondition — nothing else is dirty" \
    "3" "$(dirt_lines "$F1" | grep -c . | tr -d '[:space:]')"
assert_eq "gbv2-1.0: with NO baseline the pre-existing dirt blocks (the 0wk.2 symptom)" \
    "block" "$(stop_decision "$F1")"
assert_contains "gbv2-1.0: ...with the generic QA-required reason" \
    "QA approval required" "$(stop_reason "$F1")"

# 1.1 SessionStart captures the baseline (no active task).
rm -f "$BASE1"
printf '%s' '{}' | CLAUDE_PROJECT_DIR="$F1" bash "$SS1" >/dev/null 2>&1
assert_eq "gbv2-1.1: session-start wrote a gate baseline" "yes" \
    "$([ -f "$BASE1" ] && echo yes || echo no)"
assert_eq "gbv2-1.1: v2 version line" "# gate-baseline v1" "$(head -1 "$BASE1")"
assert_eq "gbv2-1.1: provenance names session-start" \
    "session-start" "$(baseline_header_field "$BASE1" captured_by)"
assert_match "gbv2-1.1: provenance records the HEAD it was taken against" \
    '^[0-9a-f]{7,40}$' "$(baseline_header_field "$BASE1" head)"
B11_BODY=$(baseline_body "$BASE1")
assert_contains "gbv2-1.1: the snapshot carries the pre-dirty files" "src/pre1.ts" "$B11_BODY"
assert_eq "gbv2-1.1: the snapshot carries exactly the 3 pre-dirty entries" "3" \
    "$(printf '%s\n' "$B11_BODY" | grep -c 'src/pre' | tr -d '[:space:]')"

# 1.2 With the baseline in place the Stop RELEASES. (Fails pre-3mg.1: nothing
# wrote a baseline until an approve, so this stayed a block forever.)
: > "$TRACK1"
bash "$CT1" clear
assert_eq "gbv2-1.2: pre-existing dirt no longer gates the session" \
    "ALLOW" "$(stop_decision "$F1")"

# 1.3 NEW dirt after the baseline blocks. The three pre-dirty files are still
# dirty and still excluded, so the ONLY entry the gate can be reacting to is
# the new one — 1.4 proves that by removing it and getting the release back.
printf 'export const n = 1;\n' > "$F1/src/new-after-baseline.ts"
: > "$TRACK1"
bash "$CT1" clear
assert_eq "gbv2-1.3: new dirt after the baseline BLOCKS" "block" "$(stop_decision "$F1")"
assert_eq "gbv2-1.3: precondition — the pre-dirty three are STILL dirty (only the delta gates)" \
    "3" "$(dirt_lines "$F1" | grep -c 'src/pre' | tr -d '[:space:]')"

# 1.4 CAUSATION: remove the new path and the release comes back, with the
# three pre-existing dirty files untouched throughout. Block -> release with
# one variable moved is the falsifiable form of "the reviewer's set is the
# session delta, not the tree".
rm -f "$F1/src/new-after-baseline.ts"
: > "$TRACK1"
bash "$CT1" clear
assert_eq "gbv2-1.4: removing ONLY the new path restores the release" \
    "ALLOW" "$(stop_decision "$F1")"
printf 'export const n = 1;\n' > "$F1/src/new-after-baseline.ts"
: > "$TRACK1"
assert_eq "gbv2-1.4: re-adding it blocks again (the delta is the variable)" \
    "block" "$(stop_decision "$F1")"
rm -f "$F1/src/new-after-baseline.ts"

# ---------------------------------------------------------------------------
# 1M. META (spec-mandated): truncate the baseline to empty. The exclusion is
# the whole point of the section, so removing the baseline's CONTENT must
# make 1.2 and 1.3's exclusion assertions fail — the gate blocks again and
# names all three pre-dirty files. If this META passes while 1.2/1.3 also
# pass, the section is measuring the baseline and nothing else.
#
# Truncating (rather than deleting) is the sharper probe: the FILE still
# exists, so any "does a baseline exist?" short-circuit would still see one.
# Only a reader that actually consumes the lines after `--` changes verdict.
# ---------------------------------------------------------------------------
cp "$BASE1" "$F1/.claude/.qa-tracking/gate-baseline.metabak"
: > "$BASE1"
: > "$TRACK1"
bash "$CT1" clear
# State at this point: NO new dirt at all — only the 3 pre-existing files.
# 1.2 asserted this exact state RELEASES. Under the truncated baseline it must
# block, i.e. the gate is back to blocking on all 3 and 1.2 would fail.
assert_eq "gbv2-1M META: precondition — the only dirt is the 3 pre-existing files" \
    "3" "$(dirt_lines "$F1" | grep -c . | tr -d '[:space:]')"
assert_eq "gbv2-1M META: with the baseline truncated the gate blocks on all 3 (1.2/1.4 WOULD fail)" \
    "block" "$(stop_decision "$F1")"
# Restore and re-assert the release, so a later section cannot inherit the
# truncated state and a silent restore failure cannot pass unnoticed.
mv "$F1/.claude/.qa-tracking/gate-baseline.metabak" "$BASE1"
: > "$TRACK1"
bash "$CT1" clear
assert_eq "gbv2-1M META: restoring the baseline restores the release" \
    "ALLOW" "$(stop_decision "$F1")"

# ===========================================================================
# SECTION 2 — session-start writes ONLY when no review cycle is active.
#
# If current-task names a task, a gate cycle is in flight and its work is (by
# construction) dirty right now. Baselining it would mark that work
# pre-existing and release it unreviewed — so session-start writes nothing.
# ===========================================================================
TID_ACTIVE=$(cd "$F1" && bd create "in-flight cycle across a session boundary" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
bash "$QG1" enter "$TID_ACTIVE" >/dev/null 2>&1
bash "$CT1" set "$TID_ACTIVE"
# Dirty a NEW file, i.e. the in-flight cycle's own work.
printf 'export const inflight = 1;\n' > "$F1/src/inflight.ts"
rm -f "$BASE1"
printf '%s' '{}' | CLAUDE_PROJECT_DIR="$F1" bash "$SS1" >/dev/null 2>&1
assert_eq "gbv2-2.1: session-start writes NO baseline while a cycle is active" "no" \
    "$([ -f "$BASE1" ] && echo yes || echo no)"
# And the in-flight work therefore still gates.
: > "$TRACK1"
assert_eq "gbv2-2.2: the in-flight cycle's work still gates (fail closed)" \
    "block" "$(stop_decision "$F1")"
bash "$CT1" clear
rm -f "$F1/src/inflight.ts"

# ===========================================================================
# SECTION 3 — enter: WRITE-IF-MISSING, minus already-tracked files.
#
# `enter` arms a cycle mid-session. Files the session ALREADY edited are dirty
# in git AND recorded in changed-files.txt; baselining them would hand this
# cycle's own work a free pass. So enter subtracts the tracker before writing,
# and never overwrites an existing baseline.
# ===========================================================================
mk_fixture
F3="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$F3"
BASE3="$F3/.claude/.qa-tracking/gate-baseline"
TRACK3="$F3/.claude/.qa-tracking/changed-files.txt"
QG3="$F3/.claude/scripts/qa-gate.sh"
CT3="$F3/.claude/scripts/current-task.sh"

mkdir -p "$F3/src"
printf 'export const p = 0;\n' > "$F3/src/pre.ts"
printf 'export const e = 0;\n' > "$F3/src/edited.ts"
git_fixture_init "$F3"
# Pre-existing dirt + a file THIS session edited (so it is in the tracker).
printf 'export const p = 1;\n' > "$F3/src/pre.ts"
printf 'export const e = 1;\n' > "$F3/src/edited.ts"
printf 'src/edited.ts\n' > "$TRACK3"
rm -f "$BASE3"

TID3=$(cd "$F3" && bd create "enter baselines the tree minus session work" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
bash "$QG3" enter "$TID3" >/dev/null 2>&1

assert_eq "gbv2-3.1: enter wrote a baseline when none existed" "yes" \
    "$([ -f "$BASE3" ] && echo yes || echo no)"
assert_eq "gbv2-3.1: provenance names qa-gate-enter" \
    "qa-gate-enter" "$(baseline_header_field "$BASE3" captured_by)"
B3_BODY=$(baseline_body "$BASE3")
assert_contains "gbv2-3.2: the baseline keeps the PRE-EXISTING dirt" "src/pre.ts" "$B3_BODY"
assert_not_contains "gbv2-3.2: the baseline EXCLUDES the file this session edited" \
    "src/edited.ts" "$B3_BODY"

# 3.3 The consequence: the session's own edit still gates even though the rest
# of the tree does not. (Tracker cleared so the git fallback — the surface the
# baseline lives on — is the thing under test.) Causation as in 1.4: revert
# ONLY the edited file and the release comes back, while src/pre.ts stays
# dirty the whole time.
: > "$TRACK3"
bash "$CT3" clear
assert_eq "gbv2-3.3: the session's edited file still BLOCKS via the git fallback" \
    "block" "$(stop_decision "$F3")"
printf 'export const e = 0;\n' > "$F3/src/edited.ts"    # revert to HEAD content
: > "$TRACK3"
assert_eq "gbv2-3.3: precondition — src/pre.ts is STILL dirty after the revert" \
    "1" "$(dirt_lines "$F3" | grep -c 'src/pre\.ts' | tr -d '[:space:]')"
assert_eq "gbv2-3.3: reverting ONLY the session's edit restores the release" \
    "ALLOW" "$(stop_decision "$F3")"
printf 'export const e = 1;\n' > "$F3/src/edited.ts"    # re-dirty for §4

# 3.4 WRITE-IF-MISSING: a second enter must not overwrite. Re-enter with a
# tracker naming a DIFFERENT file; if enter refreshed, the body would change.
B3_BEFORE=$(cat "$BASE3")
printf 'src/pre.ts\n' > "$TRACK3"
TID3B=$(cd "$F3" && bd create "second cycle, same session" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
bash "$QG3" enter "$TID3B" >/dev/null 2>&1
assert_eq "gbv2-3.4: a second enter leaves the existing baseline byte-identical" \
    "$B3_BEFORE" "$(cat "$BASE3")"

# ===========================================================================
# SECTION 4 — approve: FULL refresh.
#
# Approve means "everything dirty right now has been reviewed", so the whole
# working tree becomes the new reference point — including the files enter
# deliberately excluded.
# ===========================================================================
# Tracker set BEFORE enter: enter regenerates the impact report for the
# CURRENT change set, and approve refuses on a stale report — so changing the
# tracker after enter would make this section measure the staleness refusal
# instead of the baseline refresh.
printf 'src/edited.ts\n' > "$TRACK3"
bash "$QG3" enter "$TID3" >/dev/null 2>&1
bash "$CT3" set "$TID3"
seed_review_records "$TID3" "qa-claude" "backend" "$F3"
APPROVE4=$(bash "$QG3" approve "$TID3" "reviewed the session's edit" 2>&1 | tail -1)
# Assert the approve actually landed. Without this, every assertion below
# would silently degrade into "enter's baseline is still there".
assert_json_field "gbv2-4.0: approve succeeded" "$APPROVE4" '.status' "approved"
assert_eq "gbv2-4.1: provenance names qa-gate-approve" \
    "qa-gate-approve" "$(baseline_header_field "$BASE3" captured_by)"
B4_BODY=$(baseline_body "$BASE3")
assert_contains "gbv2-4.2: the refreshed baseline now INCLUDES the approved edit" \
    "src/edited.ts" "$B4_BODY"
assert_contains "gbv2-4.2: ...and still the pre-existing dirt" "src/pre.ts" "$B4_BODY"
# 4.3 Consequence: nothing is left to gate.
: > "$TRACK3"
bash "$CT3" clear
assert_eq "gbv2-4.3: after approve the tree matches the baseline and Stop releases" \
    "ALLOW" "$(stop_decision "$F3")"

# ===========================================================================
# SECTION 5 — legacy `approved-baseline`: read for one release, retired on the
# first v2 write. An install that upgrades mid-cycle must not lose its
# reference point and get a spurious full-tree block.
# ===========================================================================
LEGACY3="$F3/.claude/.qa-tracking/approved-baseline"
LEGACY_BODY=$(cd "$F3" && git status --porcelain | LC_ALL=C sort)
rm -f "$BASE3"
printf '%s\n' "$LEGACY_BODY" > "$LEGACY3"
: > "$TRACK3"
bash "$CT3" clear
assert_eq "gbv2-5.1: a v1 approved-baseline is still honoured when no v2 file exists" \
    "ALLOW" "$(stop_decision "$F3")"
# 5.2 A new pre-dirty file is still NEW relative to the legacy snapshot.
printf 'export const post = 1;\n' > "$F3/src/post-legacy.ts"
: > "$TRACK3"
assert_eq "gbv2-5.2: dirt not in the legacy snapshot still blocks" \
    "block" "$(stop_decision "$F3")"
# 5.3 The first v2 write retires the legacy file.
CLAUDE_PROJECT_DIR="$F3" bash "$QG3" baseline-capture --by test-harness >/dev/null 2>&1
assert_eq "gbv2-5.3: the first v2 write created the v2 file" "yes" \
    "$([ -f "$BASE3" ] && echo yes || echo no)"
assert_eq "gbv2-5.3: ...and deleted the legacy approved-baseline" "no" \
    "$([ -f "$LEGACY3" ] && echo yes || echo no)"

# ===========================================================================
# SECTION 6 — THE `-d .git` FIX, in a real linked worktree.
#
# In a linked worktree `.git` is a FILE containing `gitdir: ...`, so the old
# `[ -d "$PROJECT_DIR/.git" ]` predicate answered NO. Two things silently
# switched off there: the baseline writer (approve wrote nothing) and the Stop
# gate's git-status fallback. With an empty changed-files.txt the gate then
# had NO detector at all — it FAILED OPEN and released unreviewed work, in
# exactly the isolation:"worktree" topology the plugin tells agents to use.
# Both predicates now ask `git rev-parse --git-dir`.
#
# The worktree is created OUTSIDE the fixture on purpose: a checkout under
# `.claude/worktrees/` is denylisted, which would mask the very detection
# this section measures.
# ===========================================================================
WT_PARENT=$(mktemp -d -t gbv2-worktree.XXXXXX)
WT="$WT_PARENT/linked"
WT_OK=1
(cd "$F3" && git worktree add -q "$WT" -b gbv2-linked) >/dev/null 2>&1 || WT_OK=0

if [ "$WT_OK" != "1" ] || [ ! -e "$WT/.git" ]; then
    printf 'SKIPPED: gate-baseline-v2 section 6 (git worktree add unavailable in this environment)\n'
else
    # Give the worktree the hook surface a real checkout has.
    mkdir -p "$WT/.claude/scripts" "$WT/.claude/.qa-tracking"
    for s in "$(plugin_root)"/.claude/scripts/*.sh; do
        [ -f "$s" ] || continue
        ln -sf "$s" "$WT/.claude/scripts/$(basename "$s")"
    done
    fast_stack_stub "$WT"
    BASE_WT="$WT/.claude/.qa-tracking/gate-baseline"
    TRACK_WT="$WT/.claude/.qa-tracking/changed-files.txt"
    : > "$TRACK_WT"

    # 6.1 The precondition that broke the old predicate.
    assert_eq "gbv2-6.1: the linked worktree's .git is a FILE, not a directory" "file" \
        "$([ -d "$WT/.git" ] && echo dir || { [ -f "$WT/.git" ] && echo file || echo missing; })"
    assert_eq "gbv2-6.1: ...so the old \`-d .git\` predicate would have said NO" "no" \
        "$([ -d "$WT/.git" ] && echo yes || echo no)"
    assert_eq "gbv2-6.1: ...while rev-parse --git-dir says YES" "yes" \
        "$(git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no)"

    # 6.2 The writer works there now. Pre-fix it took the "no git repo" arm,
    # removed any baseline and returned success — no snapshot, silently.
    printf 'export const w = 1;\n' > "$WT/src/pre.ts"
    CLAUDE_PROJECT_DIR="$WT" bash "$WT/.claude/scripts/qa-gate.sh" \
        baseline-capture --by test-harness >/dev/null 2>&1
    assert_eq "gbv2-6.2: baseline-capture writes a snapshot inside a linked worktree" "yes" \
        "$([ -f "$BASE_WT" ] && echo yes || echo no)"
    assert_contains "gbv2-6.2: the worktree snapshot carries the worktree's dirt" \
        "src/pre.ts" "$(baseline_body "$BASE_WT")"

    # 6.3 With everything baselined the gate releases — no false block.
    : > "$TRACK_WT"
    assert_eq "gbv2-6.3: a fully-baselined worktree releases" "ALLOW" "$(stop_decision "$WT")"

    # 6.4 THE load-bearing assertion. New dirt after the baseline must BLOCK.
    # Pre-fix the fallback never ran in a worktree, so this released: the gate
    # failed OPEN on genuinely unreviewed work.
    printf 'export const unreviewed = 1;\n' > "$WT/src/unreviewed.ts"
    : > "$TRACK_WT"
    assert_eq "gbv2-6.4: unreviewed new work in a linked worktree BLOCKS (was: failed open)" \
        "block" "$(stop_decision "$WT")"
    # Causation, as in 1.4: remove ONLY the unreviewed path; the baselined
    # dirt stays put and the release comes back.
    rm -f "$WT/src/unreviewed.ts"
    : > "$TRACK_WT"
    assert_eq "gbv2-6.4: precondition — the baselined dirt is STILL dirty" \
        "1" "$(dirt_lines "$WT" | grep -c 'src/pre\.ts' | tr -d '[:space:]')"
    assert_eq "gbv2-6.4: removing ONLY the unreviewed path restores the release" \
        "ALLOW" "$(stop_decision "$WT")"

    (cd "$F3" && git worktree remove --force "$WT") >/dev/null 2>&1 || true
fi
rm -rf "$WT_PARENT"

# ===========================================================================
# SECTION 7 — THE TRACKER RECONCILE (claude-workflow-plugin-94d).
#
# THE DEFECT. changed-files.txt has exactly one hook writing it: post-edit.sh,
# on PostToolUse events that carry a path field. A file written by a Bash
# redirect, `cp`, `sed -i` or a generator script therefore never entered it —
# and that file is not just missing from a readout. `change_set_hash()` is a
# sha256 of THIS LIST (impact-report.sh canonical_changed_files), so the gate
# could name N paths and release on an approval binding M < N. Measured live
# four times in two days; the tracker once held 37 of 71 changed files.
#
# THE FIX under test: `qa-gate.sh reconcile-tracker` folds the git-visible
# remainder INTO the tracker (minus the gate baseline, minus the denylist,
# spelled absolutely so the two writers cannot double-count one file), and
# `enter`, `approve` and the Stop hook all call it before anything reads the
# file.
#
# The three files are chosen to separate the three outcomes that must differ:
#   A  written through post-edit.sh   -> was already tracked; must stay ONCE
#   B  written with a plain `printf >`-> the defect; must now be tracked
#   C  dirty BEFORE the baseline      -> must still be excluded (anti-overreach)
# ===========================================================================
mk_fixture
F7="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$F7"
TRACK7="$F7/.claude/.qa-tracking/changed-files.txt"
BASE7="$F7/.claude/.qa-tracking/gate-baseline"
QG7="$F7/.claude/scripts/qa-gate.sh"
PE7="$F7/.claude/scripts/post-edit.sh"
IR7="$F7/.claude/scripts/impact-report.sh"
CT7="$F7/.claude/scripts/current-task.sh"

mkdir -p "$F7/src"
printf 'export const a = 0;\n' > "$F7/src/a.ts"
printf 'export const c = 0;\n' > "$F7/src/c.ts"
git_fixture_init "$F7"

# C goes dirty BEFORE the baseline, so the baseline owns it.
printf 'export const c = 1; // dirty on arrival\n' > "$F7/src/c.ts"
: > "$TRACK7"
bash "$CT7" clear
rm -f "$BASE7"
CLAUDE_PROJECT_DIR="$F7" bash "$QG7" baseline-capture --by test-harness >/dev/null 2>&1
assert_contains "gbv2-7.0: precondition — the baseline owns src/c.ts" \
    "src/c.ts" "$(baseline_body "$BASE7")"

# A is edited THROUGH the hook, exactly as the runtime does it.
printf 'export const a = 1;\n' > "$F7/src/a.ts"
printf '{"tool_input":{"file_path":"%s/src/a.ts"}}' "$F7" \
    | CLAUDE_PROJECT_DIR="$F7" bash "$PE7" >/dev/null
assert_eq "gbv2-7.0: precondition — post-edit tracked A absolutely, once" "1" \
    "$(grep -c -x -F "$F7/src/a.ts" "$TRACK7" | tr -d '[:space:]')"

H_BEFORE=$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)

# 7.1 THE DEFECT, pinned. B is written the way a Bash redirect writes it: no
# tool call, so no PostToolUse, so no tracker entry — and the change-set hash
# does not move. This assertion PASSES on both the broken and the fixed script;
# it is here to name the mechanism 7.2 repairs, and 7.2 is what fails without
# the fix.
printf 'export const b = 1;\n' > "$F7/src/b.ts"
assert_eq "gbv2-7.1: a Bash-written file does NOT reach the tracker on its own" "0" \
    "$(grep -c -x -F "$F7/src/b.ts" "$TRACK7" | tr -d '[:space:]')"
H_STILL=$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)
assert_eq "gbv2-7.1: ...so the change-set hash is BLIND to it (the 94d defect)" \
    "$H_BEFORE" "$H_STILL"
assert_eq "gbv2-7.1: precondition — git DOES see it (so the repair has a source)" "1" \
    "$(dirt_lines "$F7" | grep -c 'src/b\.ts' | tr -d '[:space:]')"

# 7.2 THE REPAIR. One reconcile; B enters, A stays single, C stays out.
RECON7=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
assert_json_field "gbv2-7.2: reconcile-tracker succeeded" "$RECON7" '.status' "reconciled"
assert_eq "gbv2-7.2: B is now tracked, EXACTLY once, absolute-spelled" "1" \
    "$(grep -c -x -F "$F7/src/b.ts" "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7.2: A is STILL tracked exactly once (no relative-spelling double count)" "1" \
    "$(grep -c -x -F "$F7/src/a.ts" "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7.2: no relative spelling of A crept in alongside the absolute one" "0" \
    "$(grep -c -x -F "src/a.ts" "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7.2: ANTI-OVERREACH — baselined src/c.ts did NOT enter the tracker" "0" \
    "$(grep -c 'src/c\.ts' "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7.2: ...and src/c.ts is STILL dirty (it was excluded, not cleaned)" "1" \
    "$(dirt_lines "$F7" | grep -c 'src/c\.ts' | tr -d '[:space:]')"
assert_eq "gbv2-7.2: the tracker holds exactly the two session files" "2" \
    "$(sort -u "$TRACK7" | grep -c . | tr -d '[:space:]')"

# 7.3 THE CONSEQUENCE THAT MATTERS: the hash MOVED, so an approval recorded
# against H_BEFORE can no longer release this tree. That is the fail-closed
# direction and the reason 94d blocks the change-set binding work.
H_AFTER=$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)
assert_eq "gbv2-7.3: the change-set hash MOVED once B was reconciled in" "moved" \
    "$([ "$H_AFTER" != "$H_BEFORE" ] && echo moved || echo unchanged)"
assert_match "gbv2-7.3: ...to a real sha256, not a degraded sentinel" \
    '^([0-9a-f]{64}|sha256-unavailable)$' "$H_AFTER"

# 7.4 Idempotence: a second reconcile adds nothing and leaves the hash put.
CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker >/dev/null 2>&1
assert_eq "gbv2-7.4: a second reconcile adds nothing (unique count unchanged)" "2" \
    "$(sort -u "$TRACK7" | grep -c . | tr -d '[:space:]')"
assert_eq "gbv2-7.4: ...and the hash is stable across reconciles" \
    "$H_AFTER" "$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)"

# 7.5 The Stop hook names B. Its "Files changed:" list is enumerated from the
# tracker, so the ABSOLUTE spelling appearing there is proof the path reached
# the hash-bearing surface (see the header note above).
TID7=$(cd "$F7" && bd create "94d reconcile: bash-written file must gate" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
bash "$QG7" enter "$TID7" >/dev/null 2>&1
bash "$CT7" set "$TID7"
REASON7=$(stop_reason "$F7")
assert_eq "gbv2-7.5: the Stop still BLOCKS (unreviewed work)" "block" "$(stop_decision "$F7")"
assert_contains "gbv2-7.5: the block reason names the Bash-written file, absolutely" \
    "$F7/src/b.ts" "$REASON7"
assert_contains "gbv2-7.5: ...alongside the hook-written one" \
    "$F7/src/a.ts" "$REASON7"
assert_not_contains "gbv2-7.5: ANTI-OVERREACH — the baselined file is not in the tracker list" \
    "$F7/src/c.ts" "$REASON7"

# ---------------------------------------------------------------------------
# 7M. META (spec-mandated): strip every TRACKER-RECONCILE region from fixture
# copies of the two scripts that carry the repair, and the Bash-written file
# must disappear from BOTH the tracker and the block reason's absolute list.
#
# Both scripts, not one: with only verify-before-stop stripped, `enter` would
# still reconcile; with only qa-gate stripped, the Stop hook's call would fail
# and BLOCK on the fail-closed arm instead — a different outcome from the one
# this META is about.
#
# The copies live in the fixture's .claude/scripts/ (replacing the symlinks) so
# they keep resolving their sibling workflow-denylist.sh from their own
# directory; a copy parked anywhere else takes a degraded path and stops being
# a faithful mutant (same constraint as the post-edit.sh spec's META).
# ---------------------------------------------------------------------------
#
# THE PATTERNS ARE ANCHORED (`^ *#`), for the reason QA finding R4-F5 gives for
# the post-edit spec's SECOND-CHANCE strip: unanchored, they match the sentinel
# name ANYWHERE on a line, so a future prose line quoting `TRACKER-RECONCILE
# BEGIN` mid-sentence would start the excision early and delete real code above
# the region. Both scripts already carry prose that names the region outside any
# region (`qa-gate.sh`'s `reconcile_obs` note), which is exactly how such a line
# arrives. Anchoring is behaviour-preserving today — every sentinel is a
# `<indent># TRACKER-RECONCILE BEGIN|END (94d)` line and the stripped output is
# byte-identical either way — and the assertions below could not tell the
# difference on their own: a wild strip still removes lines and still leaves zero
# `reconcile_tracker` references.
strip_reconcile_regions() {
    # strip_reconcile_regions <src> <dst>
    awk '
        /^ *# TRACKER-RECONCILE BEGIN/ { skip = 1; next }
        /^ *# TRACKER-RECONCILE END/   { skip = 0; next }
        !skip { print }
    ' "$1" > "$2"
}

QG7_REAL=$(readlink "$QG7" || printf '%s' "$QG7")
VBS7="$F7/.claude/scripts/verify-before-stop.sh"
VBS7_REAL=$(readlink "$VBS7" || printf '%s' "$VBS7")
META7_DIR="$F7/.claude/.qa-tracking/meta7"
mkdir -p "$META7_DIR"
strip_reconcile_regions "$QG7_REAL"  "$META7_DIR/qa-gate.stripped.sh"
strip_reconcile_regions "$VBS7_REAL" "$META7_DIR/verify-before-stop.stripped.sh"

# THE GUARD FIRST (QA finding R4-F4): a strip that matched nothing leaves the
# copy byte-identical, and then the "with the reconcile stripped" legs below
# measure the SHIPPED scripts while reporting on mutants — a green run that
# proves nothing. The line-count legs that follow catch it for a strip; this
# guard catches it for any mutation, including the substitutions §7R uses.
assert_mutant_applied "gbv2-7M META (qa-gate strip)" "$QG7_REAL" "$META7_DIR/qa-gate.stripped.sh"
assert_mutant_applied "gbv2-7M META (Stop hook strip)" "$VBS7_REAL" "$META7_DIR/verify-before-stop.stripped.sh"

# Sanity: the strip actually removed something from each file, and each copy
# still parses (it must fail for the reason under test, not for a syntax error).
assert_eq "gbv2-7M META: the strip removed lines from qa-gate.sh (non-vacuous)" "smaller" \
    "$([ "$(grep -c . "$META7_DIR/qa-gate.stripped.sh")" -lt "$(grep -c . "$QG7_REAL")" ] && echo smaller || echo same)"
assert_eq "gbv2-7M META: the strip removed lines from verify-before-stop.sh (non-vacuous)" "smaller" \
    "$([ "$(grep -c . "$META7_DIR/verify-before-stop.stripped.sh")" -lt "$(grep -c . "$VBS7_REAL")" ] && echo smaller || echo same)"
# executable_refs <file> <needle> — lines mentioning <needle> that are NOT
# comment-only. THE ANCHOR FOR THE TWO LEGS BELOW, re-cut from a bare text count
# (claude-workflow-plugin-qbhw / P7).
#
# WHAT THESE LEGS ACTUALLY CLAIM, which is what their NAMES have always said: no
# CALL survives the strip. That is the property that matters, because the strip
# deletes the function's definition — a surviving call would make the stripped
# copy a BROKEN script rather than a faithful pre-94d one, and every leg below
# would then be measuring a syntax-or-runtime error instead of the behaviour
# under test.
#
# WHY THE OLD ANCHOR DRIFTED. It was `grep -c 'reconcile_tracker'`, a count of
# TEXT occurrences, standing in for a claim about CODE. Any comment outside the
# sentinel regions that named the function tripped it, and such comments are
# legitimate and expected: code near the reconcile has to explain its
# relationship to it. P7 added exactly one — a header sentence noting that the
# reconciler emits absolute paths — and this leg went red on a change that could
# not affect the property it names. The file was already paying for the
# imprecision: an existing comment contorts itself into prose ("spelled in prose
# rather than with the function's own identifier deliberately") solely to avoid
# this grep.
#
# WHY THE NEW ANCHOR CANNOT DRIFT THE SAME WAY. It asks a question about the
# LINE'S KIND, not about the file's prose: a line that begins with optional
# whitespace and then `#` cannot contain a call, in any shell, ever. Nothing a
# future author writes in a comment can change that, so comments are structurally
# outside the measurement rather than tolerated by an exception list. It stays
# strict where it counts: a trailing comment on a CODE line (`foo  # ...`) is not
# comment-only, so it is still counted — over-strict in that one direction, which
# is the safe one.
#
# It is deliberately NOT a `#`-stripping pass. Stripping comments from shell
# means deciding whether a `#` sits inside a string, a `${var#pat}` expansion, or
# a `$#` — parsing shell with a regex, in a checker whose whole job is to be more
# trustworthy than the thing it checks.
#
# The two legs immediately after this pair prove the anchor is SENSITIVE to a
# real call and INSENSITIVE to prose; without them this would be a guard that was
# loosened and never seen to fire.
executable_refs() {
    grep "$2" "$1" 2>/dev/null | grep -vc '^[[:space:]]*#' | tr -d '[:space:]'
}

assert_eq "gbv2-7M META: no reconcile_tracker call survives in the stripped qa-gate.sh" "0" \
    "$(executable_refs "$META7_DIR/qa-gate.stripped.sh" 'reconcile_tracker')"
assert_eq "gbv2-7M META: no reconcile-tracker invocation survives in the stripped Stop hook" "0" \
    "$(executable_refs "$META7_DIR/verify-before-stop.stripped.sh" 'reconcile-tracker')"

# THE ANCHOR'S OWN SENSITIVITY PROOF. A check that was just relaxed and has never
# been seen to fire is indistinguishable from a check that no longer works, so
# both directions are demonstrated against COPIES.
META7_CALL="$META7_DIR/qa-gate.callsurvives.sh"
cp "$META7_DIR/qa-gate.stripped.sh" "$META7_CALL"
printf 'reconcile_tracker || true\n' >> "$META7_CALL"
assert_eq "gbv2-7M META: the anchor FIRES when a real call survives the strip" "1" \
    "$(executable_refs "$META7_CALL" 'reconcile_tracker')"
META7_PROSE="$META7_DIR/qa-gate.prosesurvives.sh"
cp "$META7_DIR/qa-gate.stripped.sh" "$META7_PROSE"
printf '    # a comment naming reconcile_tracker, which cannot be a call\n' >> "$META7_PROSE"
assert_eq "gbv2-7M META: ...and does NOT fire on a comment naming it (the P7 false positive)" "0" \
    "$(executable_refs "$META7_PROSE" 'reconcile_tracker')"
# CONTROL: the old bare-text anchor would have failed BOTH of the above the same
# way, which is the imprecision being removed — stated as an assertion so the
# claim is measured rather than narrated.
assert_eq "gbv2-7M META: the OLD text anchor could not tell the two apart (both non-zero)" \
    "same" \
    "$([ "$(grep -c 'reconcile_tracker' "$META7_CALL" | tr -d '[:space:]')" -gt 0 ] \
       && [ "$(grep -c 'reconcile_tracker' "$META7_PROSE" | tr -d '[:space:]')" -gt 0 ] \
       && echo same || echo differed)"
assert_eq "gbv2-7M META: the stripped qa-gate.sh still parses" "0" \
    "$(bash -n "$META7_DIR/qa-gate.stripped.sh" 2>/dev/null && echo 0 || echo 1)"
assert_eq "gbv2-7M META: the stripped Stop hook still parses" "0" \
    "$(bash -n "$META7_DIR/verify-before-stop.stripped.sh" 2>/dev/null && echo 0 || echo 1)"

# Rebuild the exact §7 starting state: tracker = A only, B on disk, C baselined.
meta7_reset_state() {
    : > "$TRACK7"
    printf '%s\n' "$F7/src/a.ts" > "$TRACK7"
    printf 'export const b = 1;\n' > "$F7/src/b.ts"
    bash "$CT7" set "$TID7"
}

# --- strip leg ---
rm -f "$QG7" "$VBS7"
cp "$META7_DIR/qa-gate.stripped.sh" "$QG7"
cp "$META7_DIR/verify-before-stop.stripped.sh" "$VBS7"
chmod +x "$QG7" "$VBS7"
meta7_reset_state
REASON7M=$(stop_reason "$F7")
assert_eq "gbv2-7M META: with the reconcile stripped, B never reaches the tracker" "0" \
    "$(grep -c -x -F "$F7/src/b.ts" "$TRACK7" | tr -d '[:space:]')"
assert_not_contains "gbv2-7M META: ...and the block reason's absolute list omits it (7.2/7.5 WOULD fail)" \
    "$F7/src/b.ts" "$REASON7M"
assert_contains "gbv2-7M META: ...while A, which the hook DID record, is still named" \
    "$F7/src/a.ts" "$REASON7M"

# --- restore control: the shipped copies see B again ---
rm -f "$QG7" "$VBS7"
ln -sf "$QG7_REAL" "$QG7"
ln -sf "$VBS7_REAL" "$VBS7"
meta7_reset_state
REASON7C=$(stop_reason "$F7")
assert_eq "gbv2-7M META: restore control — the shipped copies reconcile B back in" "1" \
    "$(grep -c -x -F "$F7/src/b.ts" "$TRACK7" | tr -d '[:space:]')"
assert_contains "gbv2-7M META: restore control — and the block reason names it again" \
    "$F7/src/b.ts" "$REASON7C"

# ---------------------------------------------------------------------------
# 7.6 THE RESIDUAL THE RECONCILE DOES *NOT* CLOSE — pinned, not merely described
# (claude-workflow-plugin-dpe; QA finding R4-F1 against docs/HOOKS.md).
#
# 7.1/7.2 pin what the repair does: a Bash-written file that git can see is
# folded into the tracker, so the change-set hash covers it. That is true for a
# path git had nothing to say about at baseline capture. It is NOT true for a path
# the baseline already carries an entry for, and the difference is invisible.
#
# THE MECHANISM. The baseline is subtracted with `comm -23` over raw
# `git status --porcelain` LINES, which are not content-addressed. A second write
# to an already-dirty path leaves " M src/c.ts" byte-identical, so it is
# subtracted as pre-existing dirt however much the file changed. NO COMMIT is
# involved — asserted below, because the function header's "work already
# COMMITTED is invisible to git status" limit describes a different (narrower)
# shape and a reader can otherwise conclude this one needs a commit too.
#
# WHY IT IS PINNED HERE RATHER THAN LEFT AS PROSE. `docs/HOOKS.md` shipped the
# claim that the reconcile makes a Bash write "reach QA even though nothing
# prevented it" — an assertion of coverage in the UNDER-coverage direction 94d
# exists to close, and the stated reason for not re-scoping
# prevent-orchestrator-edits.sh. A claim about what does and does not reach the
# change set belongs in an assertion. C is the right file for it: the baseline
# owns it (7.0), 7.2 already proves it stays OUT, and this adds the part that
# matters — it stays out even after the session writes to it again.
H_R0=$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)
HEAD_R0=$(git -C "$F7" rev-parse HEAD 2>/dev/null)
BASE_C_LINE=$(baseline_body "$BASE7" | grep 'src/c\.ts')
# The write the reconcile is supposed to catch: no tool call, so no PostToolUse
# event and no tracker entry from post-edit.sh.
printf 'export const c2 = 2; // SECOND write, session work, Bash-mediated\n' >> "$F7/src/c.ts"
assert_eq "gbv2-7.6: precondition — git sees a REAL content delta on the baselined path" "2" \
    "$(git -C "$F7" diff --numstat -- src/c.ts | awk '{print $1}' | tr -d '[:space:]')"
assert_eq "gbv2-7.6: ...while its porcelain line is BYTE-IDENTICAL to the baseline's (the enabling mechanism)" \
    "$BASE_C_LINE" "$(dirt_lines "$F7" | grep 'src/c\.ts')"
RECON76=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
# SUCCESS, and since 94d.1 not a SILENT success. The wording here used to read
# "the miss is silent, which is what makes it dangerous", and that claim is now
# false: §7S below pins that this same call NAMES src/c.ts as subtracted. The
# hole itself is unchanged (the path still misses the tracker, the hash and the
# block reason, and rc is still 0) — only its invisibility closed, so this leg
# keeps measuring rc/ok and hands the readout question to §7S. Correcting the
# text rather than leaving it is the R4-F1 lesson applied to the spec that
# recorded R4-F1.
assert_json_field "gbv2-7.6: the reconcile reports SUCCESS — rc 0 either way, which is why the miss needs the §7S accounting to be visible at all" \
    "$RECON76" '.ok' "true"
assert_contains "gbv2-7.6: ...and folded in NOTHING (added=0)" "(added=0)" "$RECON76"
assert_eq "gbv2-7.6: the second write never reaches the tracker (comm -23 subtracted its unchanged line)" "0" \
    "$(grep -c 'src/c\.ts' "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7.6: ...so the change-set hash is BLIND to it (an approval binds the old value)" \
    "$H_R0" "$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)"
assert_eq "gbv2-7.6: NO COMMIT was involved — this is WIDER than the committed-work limit" \
    "$HEAD_R0" "$(git -C "$F7" rev-parse HEAD 2>/dev/null)"
REASON76=$(stop_reason "$F7")
assert_not_contains "gbv2-7.6: and the Stop's block reason never names it, so no reviewer is pointed at it" \
    "$F7/src/c.ts" "$REASON76"
# ...and that absence is a real absence. The reason's file list is capped at 15
# with "...and N more files", so on a large change set an assert_not_contains
# against it can pass for the truncation instead of for the behaviour — measured:
# under §7R's mutant the tracker inflates past the cap and the leg above passes
# vacuously. Here the tracker holds two paths, and this pins that.
assert_not_contains "gbv2-7.6: ...and that absence is REAL, not the block reason's 15-path truncation" \
    "more files" "$REASON76"

# ---------------------------------------------------------------------------
# 7.7 THE HALF THAT *IS* TRUE, in the same call. Without this leg 7.6 could pass
# against a reconcile that had stopped working altogether, and the corrected
# documentation would swing from over-claiming to under-claiming: a Bash write to
# a path that was CLEAN at baseline capture really is folded in.
printf 'export const e = 1; // Bash-written, clean at baseline capture\n' > "$F7/src/e.ts"
assert_eq "gbv2-7.7: precondition — src/e.ts carries NO baseline entry" "0" \
    "$(baseline_body "$BASE7" | grep -c 'src/e\.ts' | tr -d '[:space:]')"
RECON77=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
assert_contains "gbv2-7.7: the SAME reconcile call folds THAT one in (added=1)" "(added=1)" "$RECON77"
assert_eq "gbv2-7.7: ...tracked exactly once, absolute-spelled" "1" \
    "$(grep -c -x -F "$F7/src/e.ts" "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7.7: ...and the hash MOVED for it" "moved" \
    "$([ "$(CLAUDE_PROJECT_DIR="$F7" bash "$IR7" --hash-only 2>/dev/null)" != "$H_R0" ] && echo moved || echo unchanged)"
assert_eq "gbv2-7.7: while the baselined path is STILL absent — one call, opposite answers" "0" \
    "$(grep -c 'src/c\.ts' "$TRACK7" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 7R META: 7.6 is CAUSED by the baseline subtraction, not by an incidental filter.
#
# ONE VARIABLE: the branch deciding whether the baseline is subtracted at all is
# forced to its "there is no baseline" arm. The `comm -23` call survives in the
# copy, unreachable — so the denylist filter, the already-tracked filter, the
# absolute spelling and the append are all byte-identical to the shipped code.
#
# Text-anchored on the branch, never a line number, and gated on
# assert_mutant_applied — a substitution mutant that matches nothing is a
# byte-identical copy, and this suite has shipped two of those (R4-F4).
#
# The mutant copy lives in the fixture's own `.claude/scripts/` so it keeps
# resolving its sibling `workflow-denylist.sh` (BASH_SOURCE-relative). Parked
# anywhere else it would refuse to run at all, and the flip below would be the
# refusal rather than the missing subtraction.
QG7_NOSUB="$F7/.claude/scripts/qa-gate-nobasesub.sh"
awk '
    !done && /^[[:space:]]*if \[ -z "\$baseline" \]; then[[:space:]]*$/ {
        print "    if true; then"; done=1; next
    }
    { print }
' "$QG7_REAL" > "$QG7_NOSUB"
chmod +x "$QG7_NOSUB"
if assert_mutant_applied "gbv2-7R META" "$QG7_REAL" "$QG7_NOSUB"; then
    assert_eq "gbv2-7R META: the subtraction branch is gone from the copy (the mutation landed where it was aimed)" \
        "0" "$(grep -c 'if \[ -z "\$baseline" \]' "$QG7_NOSUB" | tr -d '[:space:]')"
    assert_eq "gbv2-7R META: ...replaced by exactly one forced branch" "1" \
        "$(grep -c '^    if true; then$' "$QG7_NOSUB" | tr -d '[:space:]')"
    assert_eq "gbv2-7R META: the comm -23 call SURVIVES in the copy (the body is untouched; only its guard moved)" \
        "1" "$(grep -c 'comm -23 <(printf' "$QG7_NOSUB" | tr -d '[:space:]')"
    assert_eq "gbv2-7R META: the copy still parses as bash" "0" \
        "$(bash -n "$QG7_NOSUB" 2>/dev/null && echo 0 || echo 1)"
    # CONTROL FIRST: the mutant must still be a FAITHFUL reconciler in every other
    # respect, or "C came back" could mean "the filters stopped running".
    mkdir -p "$F7/node_modules/dep"
    printf 'module.exports = 1;\n' > "$F7/node_modules/dep/index.js"
    RECON7R=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7_NOSUB" reconcile-tracker 2>&1 | tail -1)
    assert_json_field "gbv2-7R META control: the mutant still reconciles successfully" "$RECON7R" '.ok' "true"
    assert_eq "gbv2-7R META control: ...and still applies the DENYLIST (node_modules stays out)" "0" \
        "$(grep -c 'node_modules' "$TRACK7" | tr -d '[:space:]')"
    # THE FLIP: with the baseline unsubtracted, the second write to the baselined
    # path enters the tracker — so 7.6's absence assertion is caused by the
    # subtraction and nothing else.
    assert_eq "gbv2-7R META: WITHOUT the baseline subtraction the baselined path IS reconciled in (7.6 WOULD fail)" \
        "1" "$(grep -c -x -F "$F7/src/c.ts" "$TRACK7" | tr -d '[:space:]')"
    # RESTORE CONTROL: same tree, same dirt, shipped script — C drops out again.
    printf '%s\n%s\n%s\n' "$F7/src/a.ts" "$F7/src/b.ts" "$F7/src/e.ts" > "$TRACK7"
    CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker >/dev/null 2>&1
    assert_eq "gbv2-7R META: restore control — the shipped script leaves it out again" "0" \
        "$(grep -c -x -F "$F7/src/c.ts" "$TRACK7" | tr -d '[:space:]')"
    rm -rf "$F7/node_modules"
fi

# ---------------------------------------------------------------------------
# 7S THE DROP IS NO LONGER SILENT — the visibility half of
# claude-workflow-plugin-94d.1.
#
# WHAT WENT WRONG, on this repo's own 94d review. A conversation compacted;
# SessionStart's unconditional `rm -f changed-files.txt` fired; `qa-gate.sh
# enter` then rebuilt the tracker from `git status` minus a 35-hour-old,
# 159-entry gate baseline. 26 paths became 10. change_set_hash moved
# 01296db9... -> 0b5a546e... EVERY STEP REPORTED ok:true, and the reconcile's
# readout was `+10 git-visible path(s) ... (added=10)` — which is exactly what a
# healthy call looks like. That is worse than the empty-set case it replaced:
# before P1 a destroyed tracker hashed to e3b0c442... (the empty list), which is
# loudly, self-announcingly wrong. P1's reconciler is what made the truncated
# set look correct.
#
# WHAT IS PINNED HERE, and what deliberately is NOT. The residual 7.6 measures is
# unchanged and unfixed: a baselined path still misses the tracker, the hash and
# the block reason. What 7S pins is that the miss is now COUNTED and NAMED, that
# a rebuild from an empty tracker SAYS SO, and that the two together refuse an
# approve — because the thing that made the loss expensive was not the loss, it
# was that nothing in any readout mentioned it.
#
# The state is the one 7R's restore-control left: src/c.ts baselined and written
# a second time, absent from the tracker; a.ts / b.ts / e.ts tracked.
assert_eq "gbv2-7S.0: precondition — the baselined path is still absent from the tracker" "0" \
    "$(grep -c 'src/c\.ts' "$TRACK7" | tr -d '[:space:]')"
assert_eq "gbv2-7S.0: precondition — and git still sees it as dirty" "1" \
    "$(dirt_lines "$F7" | grep -c 'src/c\.ts' | tr -d '[:space:]')"

RECON7S=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
SUBFILE7="$F7/.claude/.qa-tracking/reconcile-subtracted.txt"
# THE LEG THAT WOULD HAVE CAUGHT 94d.1. `added=0` may not stand alone.
assert_contains "gbv2-7S.1: the readout COUNTS what the baseline subtracted (added=0 no longer stands alone)" \
    "SUBTRACTED 1 git-visible path(s)" "$RECON7S"
assert_contains "gbv2-7S.1: ...and NAMES it, absolute-spelled, the way the tracker would have" \
    "$F7/src/c.ts" "$RECON7S"
assert_contains "gbv2-7S.1: ...saying which question it CANNOT answer about that path" \
    "CANNOT distinguish pre-existing arrival dirt from session work whose tracker entry was lost" "$RECON7S"
assert_json_field "gbv2-7S.1: ...while still succeeding (rc 0 is deliberate: subtraction is the baseline's job)" \
    "$RECON7S" '.ok' "true"
assert_eq "gbv2-7S.1: the full list is durable too — the sidecar holds exactly that path" "1" \
    "$(grep -c -x -F "$F7/src/c.ts" "$SUBFILE7" 2>/dev/null | tr -d '[:space:]')"
# ANTI-OVERREACH: a path the tracker ALREADY covers is not reported as dropped.
# Without this, "subtracted" could just be "everything the baseline holds", which
# would bury the one entry that matters under every pre-existing dirty path.
assert_eq "gbv2-7S.1: ANTI-OVERREACH — a tracked path is NOT reported as subtracted" "0" \
    "$(grep -c -x -F "$F7/src/a.ts" "$SUBFILE7" 2>/dev/null | tr -d '[:space:]')"

# 7S.2 THE REBUILD ANNOUNCEMENT. reconcile cannot tell "no tool edit has happened
# yet" from "the tracker was destroyed" — so it must say which it assumed. This is
# the leg that speaks to the 94d.1 sequence directly: the tracker was gone, and
# the rebuild presented itself as a normal reconcile.
: > "$TRACK7"
RECON7S2=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
assert_contains "gbv2-7S.2: a rebuild from an EMPTY tracker announces itself" \
    "REBUILT FROM AN EMPTY TRACKER" "$RECON7S2"
assert_contains "gbv2-7S.2: ...naming the assumption it made rather than implying certainty" \
    "ASSUMPTION MADE" "$RECON7S2"
assert_contains "gbv2-7S.2: ...and stating it is not a recovery path (Channel B is unrecoverable here)" \
    "NOT a recovery path" "$RECON7S2"
assert_contains "gbv2-7S.2: ...with the durable line in sync-errors.log, because a cycle is in flight" \
    "absent-or-empty while a gate cycle was in flight" \
    "$(cat "$F7/.claude/.qa-tracking/sync-errors.log" 2>/dev/null || echo '')"

# 7S.3 THE REFUSAL. fkm.1.2 half (b) asked approve to refuse on an EMPTY change
# set; post-P1 that state is unreachable (the reconcile fills the tracker), so the
# predicate is "reconstructed AND provably short" instead. Both inputs come from
# outside the tracker's contents — which is the point: the impact-report freshness
# check compares two hashes BOTH derived from the truncated tracker, so it sees
# drift and is blind to loss.
: > "$TRACK7"
bash "$CT7" set "$TID7" >/dev/null 2>&1
RC7S3=0
# Captured RAW and split afterwards, not through `| tail -1`: a pipeline's exit
# status is the LAST command's, so `... | tail -1) || RC=$?` records tail's 0 and
# the rc assertion can never fail. Same shape as approve-idempotency.sh's H2.
RAW7S3=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" approve "$TID7" "reviewed" 2>&1) || RC7S3=$?
OUT7S3=$(printf '%s\n' "$RAW7S3" | tail -1)
assert_eq "gbv2-7S.3: approve REFUSES a reconstructed, provably-short change set (exit 2)" "2" "$RC7S3"
assert_json_field "gbv2-7S.3: ...with error_key=change_set_reconstructed" \
    "$OUT7S3" '.error_key' "change_set_reconstructed"
assert_contains "gbv2-7S.3: ...naming the dropped path so the operator can decide" \
    "$F7/src/c.ts" "$OUT7S3"
assert_contains "gbv2-7S.3: ...and printing the bypass, so a legitimate case is not deadlocked" \
    "--accept-reconstructed" "$OUT7S3"

# 7S.4 THE CONTROL THAT MAKES 7S.3 MEAN SOMETHING. Same tree, same baselined
# src/c.ts, same subtraction — only the tracker is non-empty. The refusal must NOT
# fire, or it would be "subtracted>0" (which every dirty-on-arrival repo produces
# on every call) rather than "the change set was reconstructed".
printf '%s\n' "$F7/src/a.ts" > "$TRACK7"
bash "$CT7" set "$TID7" >/dev/null 2>&1
RC7S4=0
OUT7S4=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" approve "$TID7" "reviewed" 2>&1 | tail -1) || RC7S4=$?
assert_eq "gbv2-7S.4: CONTROL — with a NON-empty tracker the reconstruction refusal does not fire" \
    "no" "$(printf '%s' "$OUT7S4" | jq -r '.error_key // "none"' 2>/dev/null | grep -q change_set_reconstructed && echo yes || echo no)"
RECON7S4=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
assert_contains "gbv2-7S.4: ...while the subtraction is STILL reported (reporting is not gated on the refusal)" \
    "SUBTRACTED" "$RECON7S4"
assert_eq "gbv2-7S.4: ...and rebuild-from-empty is NOT claimed for a populated tracker" "0" \
    "$(printf '%s' "$RECON7S4" | grep -c 'REBUILT FROM AN EMPTY TRACKER' | tr -d '[:space:]')"

# 7S.5 THE AUDITED BYPASS. The observation is inferential — a destroyed tracker
# and an all-Bash session in a repo dirty on arrival are identical to the
# reconcile — so a human verdict has to be able to clear it, with the reason
# recorded. Asserted as "this gate is no longer what refuses": the fixture has no
# review artifact, so approve correctly stops at the NEXT precondition.
: > "$TRACK7"
bash "$CT7" set "$TID7" >/dev/null 2>&1
OUT7S5=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" approve "$TID7" \
    --accept-reconstructed 'measured: the dropped path is pre-existing arrival dirt' \
    "reviewed" 2>&1 | tail -1) || true
assert_eq "gbv2-7S.5: --accept-reconstructed clears THIS refusal (approve moves on to the next precondition)" \
    "no" "$(printf '%s' "$OUT7S5" | jq -r '.error_key // "none"' 2>/dev/null | grep -q change_set_reconstructed && echo yes || echo no)"
# The empty reason is spelled `''`, not omitted: the flag takes the NEXT argument
# whatever it is, so `--accept-reconstructed "reviewed"` swallows the summary and
# fails on usage instead — which would pass an `error_key` assertion for entirely
# the wrong reason. This is the shape the other two bypasses are tested in too.
OUT7S5B=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" approve "$TID7" --accept-reconstructed '' "reviewed" 2>&1 | tail -1) || true
assert_json_field "gbv2-7S.5: ...and an UNEXPLAINED bypass is refused, like the other two" \
    "$OUT7S5B" '.error_key' "bypass_reason_required"

# ---------------------------------------------------------------------------
# 7SM META: strip the SUBTRACTION-ACCOUNTING regions ALONE and the same call goes
# back to the pre-94d.1 silent success.
#
# The accounting has its OWN sentinels, nested inside TRACKER-RECONCILE, precisely
# so this META can excise the reporting while leaving the reconcile itself
# byte-identical. `account_obs` is declared OUTSIDE those sentinels (see the
# comment at its declaration), so the stripped copy is coherent and every
# observation reverts to its exact pre-94d.1 text rather than dying on an unset
# variable — which would make this META pass for the wrong reason.
#
# It also flips the REFUSAL, because RECONCILE_SUBTRACTED / _REBUILT_FROM_EMPTY
# are only ever set inside the region: with it gone they keep their function-top
# zeros and cmd_approve's guard is inert. One strip, both halves of 94d.1's
# visibility, which is the honest shape — the refusal has no independent evidence.
strip_subtraction_accounting() {
    # strip_subtraction_accounting <src> <dst>. Anchored `^ *#` for the reason
    # R4-F5 gives: unanchored, a future prose line naming the sentinel mid-
    # sentence would start the excision early and delete real code above it.
    awk '
        /^ *# SUBTRACTION-ACCOUNTING BEGIN/ { skip = 1; next }
        /^ *# SUBTRACTION-ACCOUNTING END/   { skip = 0; next }
        !skip { print }
    ' "$1" > "$2"
}
QG7_NOACC="$F7/.claude/scripts/qa-gate-noaccount.sh"
strip_subtraction_accounting "$QG7_REAL" "$QG7_NOACC"
chmod +x "$QG7_NOACC"
if assert_mutant_applied "gbv2-7SM META" "$QG7_REAL" "$QG7_NOACC"; then
    assert_eq "gbv2-7SM META: the strip removed lines (non-vacuous)" "smaller" \
        "$([ "$(grep -c . "$QG7_NOACC")" -lt "$(grep -c . "$QG7_REAL")" ] && echo smaller || echo same)"
    assert_eq "gbv2-7SM META: no comm -12 complement survives in the copy (the mutation landed where it was aimed)" \
        "0" "$(grep -c 'comm -12' "$QG7_NOACC" | tr -d '[:space:]')"
    assert_eq "gbv2-7SM META: the comm -23 SUBTRACTION itself survives (only the accounting was removed)" \
        "1" "$(grep -c 'comm -23 <(printf' "$QG7_NOACC" | tr -d '[:space:]')"
    assert_eq "gbv2-7SM META: account_obs is still DECLARED, so the copy is coherent rather than crashing" \
        "1" "$(grep -c 'local account_obs=""' "$QG7_NOACC" | tr -d '[:space:]')"
    assert_eq "gbv2-7SM META: the copy still parses as bash" "0" \
        "$(bash -n "$QG7_NOACC" 2>/dev/null && echo 0 || echo 1)"

    # THE FLIP, half 1: the readout. Same tree, same subtraction, same emptied
    # tracker as 7S.2 — and the mutant says nothing about either.
    : > "$TRACK7"
    RECON7SM=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7_NOACC" reconcile-tracker 2>&1 | tail -1)
    assert_json_field "gbv2-7SM META control: the mutant still reconciles successfully" \
        "$RECON7SM" '.ok' "true"
    assert_eq "gbv2-7SM META control: ...and still folds the un-baselined paths in (it is a faithful reconciler)" \
        "1" "$(grep -c -x -F "$F7/src/b.ts" "$TRACK7" | tr -d '[:space:]')"
    assert_eq "gbv2-7SM META: with the accounting stripped the drop is SILENT again (7S.1 WOULD fail)" "0" \
        "$(printf '%s' "$RECON7SM" | grep -c 'SUBTRACTED' | tr -d '[:space:]')"
    assert_eq "gbv2-7SM META: ...not even the bare count survives (7S.1 WOULD fail)" "0" \
        "$(printf '%s' "$RECON7SM" | grep -c 'subtracted=' | tr -d '[:space:]')"
    assert_eq "gbv2-7SM META: ...and the rebuild is not announced (7S.2 WOULD fail)" "0" \
        "$(printf '%s' "$RECON7SM" | grep -c 'REBUILT FROM AN EMPTY TRACKER' | tr -d '[:space:]')"

    # THE FLIP, half 2: the refusal goes inert.
    : > "$TRACK7"
    bash "$CT7" set "$TID7" >/dev/null 2>&1
    OUT7SM=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7_NOACC" approve "$TID7" "reviewed" 2>&1 | tail -1) || true
    assert_eq "gbv2-7SM META: ...so approve stops refusing a reconstructed change set (7S.3 WOULD fail)" \
        "no" "$(printf '%s' "$OUT7SM" | jq -r '.error_key // "none"' 2>/dev/null | grep -q change_set_reconstructed && echo yes || echo no)"

    # RESTORE CONTROL: identical state, shipped script, both halves return.
    : > "$TRACK7"
    RECON7SC=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
    assert_contains "gbv2-7SM META: restore control — the shipped script counts the drop again" \
        "SUBTRACTED" "$RECON7SC"
    : > "$TRACK7"
    bash "$CT7" set "$TID7" >/dev/null 2>&1
    RC7SC=0
    OUT7SC=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" approve "$TID7" "reviewed" 2>&1 | tail -1) || RC7SC=$?
    assert_json_field "gbv2-7SM META: restore control — and refuses again" \
        "$OUT7SC" '.error_key' "change_set_reconstructed"
fi

# ---------------------------------------------------------------------------
# 7S.6 THE THIRD CONDITION, pinned — an EMPTY rebuilt set is NOT refused.
#
# The refusal needs a NON-EMPTY reconstruction (`added > 0`), and that clause is
# not decorative. Without it the same predicate fires on `added=0, subtracted>0`
# — an empty change set with baselined dirt around it — which is the normal shape
# of a task closed with no code change, of the doc-only fast path, and of any
# session that did nothing in a checkout that was dirty on arrival. Measured, not
# hypothesised: that state broke the L1 qa-gate-choose and qa-gate-grade-record
# fixtures (30 and 90 assertions) when the clause was absent, and their single
# "subtracted" entry was the fixture's own untracked .claude/scripts/ directory.
#
# LAST in the section deliberately: producing `added=0` means baselining the WHOLE
# dirty tree, which would invalidate every leg above that depends on a.ts / b.ts /
# e.ts being un-baselined.
: > "$TRACK7"
rm -f "$BASE7"
CLAUDE_PROJECT_DIR="$F7" bash "$QG7" baseline-capture --by test-harness >/dev/null 2>&1
RECON7S6=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" reconcile-tracker 2>&1 | tail -1)
assert_contains "gbv2-7S.6: precondition — with everything baselined the rebuild adds NOTHING" \
    "(added=0)" "$RECON7S6"
assert_contains "gbv2-7S.6: precondition — while still reporting what it subtracted" \
    "SUBTRACTED" "$RECON7S6"
assert_contains "gbv2-7S.6: precondition — and still announcing the rebuild-from-empty" \
    "REBUILT FROM AN EMPTY TRACKER" "$RECON7S6"
: > "$TRACK7"
bash "$CT7" set "$TID7" >/dev/null 2>&1
OUT7S6=$(CLAUDE_PROJECT_DIR="$F7" bash "$QG7" approve "$TID7" "reviewed" 2>&1 | tail -1) || true
assert_eq "gbv2-7S.6: an EMPTY reconstructed change set is NOT refused (the third condition)" \
    "no" "$(printf '%s' "$OUT7S6" | jq -r '.error_key // "none"' 2>/dev/null | grep -q change_set_reconstructed && echo yes || echo no)"

# ===========================================================================
# SECTION 8 — AN EMPTY SNAPSHOT IS A VALID BASELINE (94d).
#
# THE DEFECT. write_gate_baseline built the file with a brace group whose last
# command was `[ -n "$status_out" ] && printf '%s\n' "$status_out"`. A group takes
# the exit status of its last command, so on an EMPTY snapshot the false test made
# the whole group "fail": the error handler deleted the tmp file it had just
# written correctly, logged "could not write", and returned 1.
#
# An empty snapshot is not an exotic state — it is the normal state of a CLEAN
# tree, and of an `--exclude-tracked` capture where every dirty path is already
# in the tracker. So exactly those cases silently got NO baseline: `enter
# --if-missing` could never find one to skip, and `baseline-capture` answered
# ok:false / exit 2 on a clean checkout, i.e. the mechanism reported itself broken
# in the one situation where nothing was wrong.
#
# Found while giving the L2 gate fixtures a .gitignore for 94d — the fixtures had
# always been dirty enough to hide it. Reproduced with ONE variable isolated
# (clean tree fails, one dirty file succeeds), which is what section 8.2 pins.
# ===========================================================================
mk_fixture
F8="$COMPONENT_FIXTURE_PATH"
BASE8="$F8/.claude/.qa-tracking/gate-baseline"
QG8="$F8/.claude/scripts/qa-gate.sh"

# A repo whose tree is genuinely CLEAN: everything the fixture ships is either
# committed or gitignored.
printf '.claude/\nbin/\n' > "$F8/.gitignore"
printf 'export const s = 0;\n' > "$F8/src8.ts"
(cd "$F8" && git init -q && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline) >/dev/null 2>&1
assert_eq "gbv2-8.0: precondition — the tree is CLEAN (empty porcelain)" "0" \
    "$(dirt_lines "$F8" | grep -c . | tr -d '[:space:]')"

rm -f "$BASE8"
CAP8=$(CLAUDE_PROJECT_DIR="$F8" bash "$QG8" baseline-capture --by test-harness 2>&1 | tail -1)
assert_json_field "gbv2-8.1: baseline-capture on a clean tree SUCCEEDS (was ok:false, exit 2)" \
    "$CAP8" '.status' "captured"
assert_json_field "gbv2-8.1: ...and reports ok:true" "$CAP8" '.ok' "true"
assert_eq "gbv2-8.1: ...and the file EXISTS (was deleted by its own error handler)" "yes" \
    "$([ -f "$BASE8" ] && echo yes || echo no)"
assert_eq "gbv2-8.1: ...with the v2 header intact" "# gate-baseline v1" "$(head -1 "$BASE8")"
assert_eq "gbv2-8.1: ...provenance recorded" "test-harness" "$(baseline_header_field "$BASE8" captured_by)"
assert_eq "gbv2-8.1: ...and an EMPTY snapshot body, which is the correct answer" "0" \
    "$(baseline_body "$BASE8" | grep -c . | tr -d '[:space:]')"
# `grep -c` on a MISSING file prints nothing at all (it errors), so the count has
# to be defaulted — otherwise the healthiest possible state, no log file, reads as
# an empty string and fails. The `|| true` keeps the no-match exit 1 from
# aborting under the runner's shell.
CW8=$(grep -c 'could not write' "$F8/.claude/.qa-tracking/sync-errors.log" 2>/dev/null || true)
CW8=$(printf '%s' "$CW8" | head -1 | tr -d '[:space:]')
assert_eq "gbv2-8.1: ...and sync-errors.log carries no 'could not write' line" "0" "${CW8:-0}"

# 8.2 THE DISCRIMINATOR: one dirty file is the only variable between the failing
# and passing states, and the non-empty case must still behave. Without this, 8.1
# would also pass against a writer that ignored $status_out entirely.
printf 'export const d = 1;\n' > "$F8/dirty8.ts"
rm -f "$BASE8"
CLAUDE_PROJECT_DIR="$F8" bash "$QG8" baseline-capture --by test-harness >/dev/null 2>&1
assert_eq "gbv2-8.2: with ONE dirty file the snapshot carries exactly that entry" "1" \
    "$(baseline_body "$BASE8" | grep -c 'dirty8\.ts' | tr -d '[:space:]')"
assert_eq "gbv2-8.2: ...and nothing else" "1" \
    "$(baseline_body "$BASE8" | grep -c . | tr -d '[:space:]')"

# 8.3 The consequence `--if-missing` depends on: an empty baseline is a PRESENT
# baseline, so a later enter must not overwrite it. Pre-fix there was no file to
# find, so every enter re-captured — against a tree that had meanwhile changed.
rm -f "$F8/dirty8.ts" "$BASE8"
CLAUDE_PROJECT_DIR="$F8" bash "$QG8" baseline-capture --by test-harness >/dev/null 2>&1
B8_BEFORE=$(cat "$BASE8")
printf 'export const later = 1;\n' > "$F8/later8.ts"
CLAUDE_PROJECT_DIR="$F8" bash "$QG8" baseline-capture --by second-writer --if-missing >/dev/null 2>&1
assert_eq "gbv2-8.3: an EMPTY baseline still satisfies --if-missing (byte-identical)" \
    "$B8_BEFORE" "$(cat "$BASE8")"
assert_eq "gbv2-8.3: ...so the later dirt is NOT baselined and still gates" "0" \
    "$(baseline_body "$BASE8" | grep -c 'later8\.ts' | tr -d '[:space:]')"

[ "$FAIL" -eq 0 ]
