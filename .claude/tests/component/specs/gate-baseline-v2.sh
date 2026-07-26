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

# WHY THE ASSERTIONS BELOW MEASURE THE DECISION, NOT THE REASON TEXT
# ------------------------------------------------------------------
# On the git-status FALLBACK path the block reason does not enumerate paths —
# it renders "Files changed: (check git status)", because the enumerated list
# comes from changed-files.txt, which is empty by construction whenever the
# fallback is what fired. Its `diff_summary` field is `git diff --stat HEAD`
# over the WHOLE tree, so every pre-dirty file appears there whether the
# baseline excluded it or not. Asserting "the reason does not mention
# src/pre1.ts" would therefore be unfalsifiable-in-the-wrong-direction: it can
# never pass, and a naive fix (assert it DOES appear) would pass with the
# baseline mechanism entirely removed. The falsifiable observable is the
# DECISION, so each case below pairs a block with the removal of its cause and
# asserts the release comes back.

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

[ "$FAIL" -eq 0 ]
