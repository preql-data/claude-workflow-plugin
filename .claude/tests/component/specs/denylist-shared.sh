#!/bin/bash
# denylist-shared.sh component spec — claude-workflow-plugin-3mg.1 (Phase V4),
# extended to the fourth consumer and the second rule in 94d.
#
# ONE definition of "which paths are reviewable", FOUR consumers:
#
#   post-edit.sh           what gets TRACKED into changed-files.txt
#   qa-gate.sh             what reconcile_tracker APPENDS to the same tracker
#                          (94d — the SECOND writer of that file)
#   impact-report.sh       what enters the canonical change set + its HASH
#   verify-before-stop.sh  what the Stop gate treats as needing REVIEW
#
# ...and TWO rules: WORKFLOW_DENYLIST_REGEX ("is this reviewable work?") and
# workflow_self_written ("may this path enter the change set as a side effect of
# the GATE ITSELF running?").
#
# The L1 spec denylist-source.test.sh guards the STRUCTURE (all four source
# `.claude/scripts/workflow-denylist.sh`, none carries a literal copy, and the
# three that write or classify tree state all CALL the second rule). This spec
# guards the BEHAVIOUR: a single edit to the lib must move every consumer at
# once, and each pattern the lib carries must actually change what the gate sees.
#
# WHY IT MATTERS (the defect that motivated the consolidation)
# ------------------------------------------------------------
# Before 3mg.1 only verify-before-stop's copy knew about `.claude/worktrees/`
# and the e2e fixture churn. post-edit therefore TRACKED worktree paths that
# the Stop gate could not SEE: they entered the change-set hash the approval
# is bound to while being invisible to the gate's own view of the change set.
# The hash and the gate disagreed about what "the changes" were, and the only
# symptom was an occasional un-releasable approval nobody could explain.
#
# SECTIONS
#   A. CANARY (the sensitivity proof). One pattern added to the lib, three of
#      the four consumers observed. Each leg is asserted BEFORE the edit
#      (control) and AFTER (effect), then the lib is restored and the control
#      re-asserted — so a green run cannot come from fixture drift. The FOURTH
#      consumer (qa-gate.sh's reconcile) needs a git repo, which section A
#      deliberately does not have, so its canary leg lives in section E1.
#   B. MEMORY PATTERNS (shipped behaviour). MEMORY.md and .claude/memory/
#      leave the reviewable set BEFORE F1 doc-only classification, so a
#      memory-only change set releases with NO gate record instead of being
#      auto-approved as `doc-only`. CLAUDE.md is the anti-overreach control:
#      it is behaviour-bearing and must still gate.
#   C. HASH MIGRATION. Changing the denylist re-hashes recomputed change sets,
#      so an approval recorded before the change no longer matches and the
#      gate re-blocks (LABEL_WITHOUT_RECORD). That is the correct fail-closed
#      direction; this section pins BOTH the block and the recovery. C4 drives
#      the remediation the block reason PRINTS (extracted from the reason text,
#      not paraphrased) and C5 keeps the explicit-label-removal path pinned
#      alongside it. Until gz3, C4 was a KNOWN-GAP pin: the printed recipe could
#      not recover, because approve short-circuited on the stale qa-approved
#      label. It recovers now; the guard's own contract lives in
#      specs/approve-idempotency.sh.
#   D. THE v4.1 LANDING (claude-workflow-plugin-wg6, absorbing prm). A and C
#      use an INVENTED canary, which proves the mechanism but not that the
#      patterns which shipped are the ones driving it. D pins the PRE-LANDING
#      lib — the shipped regex with the three v4.1 alternatives stripped by
#      literal substring — behaves like a v4.0 install under it, then restores
#      the real lib: THAT RESTORE IS THE LANDING. D1 is the discriminating
#      control that stops the strip from silently no-opping.
#   E. THE SECOND RULE AND THE FOURTH CONSUMER (claude-workflow-plugin-94d,
#      closing QA finding R1-F1). E1 extends section A's canary to consumer 4/4,
#      qa-gate.sh's reconcile_tracker. E2 drives workflow_self_written through
#      BOTH writers of changed-files.txt and pins THE BOUNDARY the rule turns on
#      (.beads/interactions.jsonl out, .beads/issues.jsonl in). E3 is B3 for the
#      second rule: with both writers filtering at the source, the hash and the
#      gate agree about what the change set is.
#
# THE SYMLINK HAZARD (read before editing this file)
# --------------------------------------------------
# mk_fixture SYMLINKS the plugin's real scripts into the fixture. An in-place
# `sed -i` against `$FIXTURE/.claude/scripts/workflow-denylist.sh` can rewrite
# THE REAL PLUGIN FILE through the link. Every mutation here goes through
# mutate_denylist_lib (sections A/C) or pin_denylist_regex (section D), each
# of which `rm`s the symlink and `cp`s a private copy FIRST; A5, C2, D2 and D5
# then assert that the real plugin lib is still intact.

set -u

# ---------------------------------------------------------------------------
# Helpers shared by all three sections.

# mutate_denylist_lib <fixture> <extra-alternative>
#   Replace the fixture's workflow-denylist.sh SYMLINK with a private copy
#   whose WORKFLOW_DENYLIST_REGEX gains <extra-alternative> as a leading
#   alternation branch. Prints the real (plugin) path it copied from so the
#   caller can restore the symlink.
mutate_denylist_lib() {
    local root="$1" alt="$2"
    local lib="$root/.claude/scripts/workflow-denylist.sh"
    local real
    real=$(readlink "$lib" 2>/dev/null || printf '%s' "$lib")
    rm -f "$lib"                 # break the link BEFORE writing anything
    cp "$real" "$lib"
    chmod +x "$lib"
    # -i.bak is the spelling both BSD and GNU sed accept.
    sed -i.bak "s#^WORKFLOW_DENYLIST_REGEX='#WORKFLOW_DENYLIST_REGEX='${alt}|#" "$lib"
    rm -f "$lib.bak"
    printf '%s' "$real"
}

restore_denylist_lib() {
    local root="$1" real="$2"
    local lib="$root/.claude/scripts/workflow-denylist.sh"
    rm -f "$lib"
    ln -sf "$real" "$lib"
}

# pin_denylist_regex <fixture> <regex>   (section D)
#   Replace the fixture's workflow-denylist.sh SYMLINK with a private copy
#   whose WORKFLOW_DENYLIST_REGEX line is REWRITTEN to <regex> verbatim.
#   Prints the real (plugin) path it copied from, so the caller can restore
#   the symlink — and in section D that restore IS the landing under test.
#
#   Same cp-before-write symlink discipline as mutate_denylist_lib (see THE
#   SYMLINK HAZARD above): an in-place edit would travel down the link into
#   the real plugin file.
#
#   Deliberately NOT sed, unlike mutate_denylist_lib. mutate_denylist_lib
#   injects a short canary it controls; this one writes a whole ERE full of
#   `&`, `\`, `|`, `/` and `[`, every one of which sed re-interprets on the
#   replacement side. A read-loop plus `case` rewrites exactly one line with
#   no escaping surface at all. The printf format is a %s with the regex as
#   an ARGUMENT, never as the format string.
pin_denylist_regex() {
    local root="$1" regex="$2"
    local lib="$root/.claude/scripts/workflow-denylist.sh"
    local real tmp line
    real=$(readlink "$lib" 2>/dev/null || printf '%s' "$lib")
    rm -f "$lib"                 # break the link BEFORE writing anything
    cp "$real" "$lib"
    tmp="$lib.pin"
    : > "$tmp"
    # `|| [ -n "$line" ]` so a final line without a trailing newline is kept.
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            WORKFLOW_DENYLIST_REGEX=*)
                printf "WORKFLOW_DENYLIST_REGEX='%s'\n" "$regex" >> "$tmp" ;;
            *)
                printf '%s\n' "$line" >> "$tmp" ;;
        esac
    done < "$lib"
    mv "$tmp" "$lib"
    chmod +x "$lib"
    printf '%s' "$real"
}

# strip_alt <regex> <literal-alternative>   (section D)
#   Print <regex> with the FIRST occurrence of "|<literal-alternative>"
#   removed. LITERAL, not glob: every expansion is quoted, so the `[`, `^`,
#   `]` and `+` inside an ERE alternative stay ordinary characters rather
#   than becoming a bracket expression. When the alternative is ABSENT the
#   input is printed unchanged and the rc is 1.
#
#   That absent case is the whole reason section D opens with D1: a silent
#   no-op here would make the "pre-landing" lib byte-identical to the shipped
#   one, and every later D assertion would go green while proving nothing.
strip_alt() {
    local re="$1" needle="|$2" pre post
    case "$re" in
        *"$needle"*) ;;
        *) printf '%s' "$re"; return 1 ;;
    esac
    pre=${re%%"$needle"*}
    post=${re#*"$needle"}
    printf '%s%s' "$pre" "$post"
}

# shipped_regex_of <lib-path> — the ERE the lib actually assigns, unquoted.
# Parameter expansion rather than sed for the same escaping reason as above.
shipped_regex_of() {
    local line
    line=$(grep -m1 "^WORKFLOW_DENYLIST_REGEX='" "$1" 2>/dev/null) || return 1
    line=${line#*=\'}
    printf '%s' "${line%\'}"
}

# hash_of <fixture> <line>...  — the canonical change-set hash impact-report.sh
# computes for a tracker containing exactly <line>... This is the same
# `--hash-only` entry point qa-gate.sh approve and the Stop gate use, so the
# assertions below measure the shipping hash, not a re-implementation.
hash_of() {
    local root="$1"; shift
    local tracker="$root/.claude/.qa-tracking/changed-files.txt"
    : > "$tracker"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$tracker"; done
    CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo ""
}

# track_path <fixture> <path> — drive post-edit.sh exactly as the PostToolUse
# hook does and report whether the path landed in changed-files.txt.
track_path() {
    local root="$1" p="$2"
    local tracker="$root/.claude/.qa-tracking/changed-files.txt"
    : > "$tracker"
    printf '{"tool_input":{"file_path":"%s"}}' "$p" \
        | CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/post-edit.sh" >/dev/null 2>&1
    if grep -qxF "$p" "$tracker" 2>/dev/null; then printf 'tracked'; else printf 'skipped'; fi
}

# stop_decision <fixture> — the Stop hook's verdict, "ALLOW" when it releases.
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

# seed_tracker <fixture> <line>... — set changed-files.txt to exactly these.
seed_tracker() {
    local root="$1"; shift
    local tracker="$root/.claude/.qa-tracking/changed-files.txt"
    : > "$tracker"
    local l
    for l in "$@"; do printf '%s\n' "$l" >> "$tracker"; done
}

# claude-workflow-plugin-rqer (v5 D2), AC-4/AC-6: every seed_tracker call
# below that runs AFTER an approve on $TID_MIG also names
# docs/reviews/$TID_MIG-r1.json (the canonical review artifact
# seed_review_records wrote and reconciled in). That file is real,
# uncommitted and part of what THAT approval actually bound — it is
# deliberately NOT cleared by a fresh approve's baseline-write, exactly like
# any other reviewable path — so a "restore the live session's change set"
# reset that omits it no longer reproduces the approved hash. The ONE
# seed_tracker call BEFORE the first review/approve (immediately below) is
# deliberately NOT touched: the artifact does not exist yet at that point.
#
# claude-workflow-plugin-fkm.4 (v5 D2): docs/specs/$TID_MIG.md (the design
# doc seed_review_records also writes, via seed_design_verdict) gets the
# SAME treatment ONLY at the FIRST post-approve restore (C1) — NOT at every
# later one. Reasoning, verified by reading reconcile_tracker and
# write_gate_baseline: approve does a FULL, unconditional gate-baseline
# refresh, so after C1's approve the baseline already carries the collapsed
# `?? docs/specs/` porcelain line. The doc's bytes never change again for
# this task, so every LATER reconcile (C4, C5, C6) sees the identical
# collapsed line, subtracts it as already-baselined, and does not re-add it
# — correctly: nothing about it is new. Adding docs/specs to those LATER
# restores would therefore make them stop matching what those approvals
# actually bind. Only C1's (and, in section D5 below, D5's own first
# restore) genuinely needs it.

# fast_stack_stub <fixture> — a detect-stack.sh that reports no test/lint/type
# commands, so the technical-check pass is a no-op and the specs below measure
# the GATE decision rather than a toolchain run.
fast_stack_stub() {
    local root="$1"
    rm -f "$root/.claude/scripts/detect-stack.sh"
    printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
        > "$root/.claude/scripts/detect-stack.sh"
    chmod +x "$root/.claude/scripts/detect-stack.sh"
}

# harness_gitignore <root> — keep this spec's own INSTRUMENTATION out of the
# fixture's git view. Call it BEFORE `git init` so the ignore rules are in place
# for the baseline commit.
#
# WHY (94d). This spec rewrites the fixture's `.claude/scripts/workflow-denylist.sh`
# mid-cycle — that is its entire method: `mutate_denylist_lib` and
# `pin_denylist_regex` swap the symlink for a private copy so a landing can be
# simulated. Those writes are real, git-visible, un-baselined changes, so once
# `qa-gate.sh reconcile-tracker` existed they were correctly folded into the
# change set: section C's post-migration approve bound a file set containing the
# spec's own mutated lib, and C4's re-seed of the two subject paths no longer
# matched it. The instrumentation is not the subject matter, so it must not be in
# the fixture's git view.
#
# Same call the shared denylist already makes for the e2e tier —
# `.claude/tests/e2e/fixtures/<f>/.claude/{scripts,beads}/` is denylisted as
# "churn the harness rewrites mechanically" — applied to the L2 tier, whose
# fixtures are `mktemp -d` roots no denylist branch can name. The SUBJECT paths
# (src/*.ts, harness3mg1/z.ts, MEMORY.md, .claude/plans/...) stay fully tracked.
harness_gitignore() {
    printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$1/.gitignore"
}

# ===========================================================================
# SECTION A — the canary: ONE edit to the lib, THREE of the FOUR consumers.
#
# The fourth (qa-gate.sh's reconcile_tracker, added in 94d) is measured in E1,
# not here: it walks `git status`, and this fixture is deliberately not a git
# repo (see the note below). Consumer COUNT is load-bearing in this file — the
# whole cost of QA finding R1-F1 was a canary that said "three" after the lib had
# grown a fourth writer. If you add a consumer, add a leg.
# ===========================================================================
#
# DELIBERATELY NOT A GIT REPO. Section A measures ONE variable — what the
# denylist says — across the three consumers it covers. In a git fixture the mutation
# itself is a working-tree change (the symlink becomes a regular file), so
# the Stop hook's git-status fallback would report the LIB as new dirt and
# block for a reason that has nothing to do with the canary. The gate's git
# fallback and its baseline are covered where they belong, in section B's
# mixed case and in gate-baseline-v2.sh; here they are noise. (Non-git
# projects are a supported configuration — has_git_repo exists precisely to
# answer this — so the fixture is realistic, not contrived.)
mk_fixture
FA="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$FA"
bash "$FA/.claude/scripts/current-task.sh" clear
assert_eq "denylist-A0: section-A fixture is intentionally NOT a git repo (isolates the denylist)" \
    "no" "$(git -C "$FA" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no)"

CANARY="canary3mg1/x.ts"
PLAIN="src/a.ts"

# A0. Precondition: the fixture's lib really is a symlink to the plugin's
# file, so the cp-before-sed discipline in mutate_denylist_lib is load-bearing
# rather than decorative. If mk_fixture ever switches to copies this assertion
# fails loudly instead of the spec silently losing its safety property.
assert_eq "denylist-A0: fixture lib is a symlink to the real plugin lib" "yes" \
    "$([ -L "$FA/.claude/scripts/workflow-denylist.sh" ] && echo yes || echo no)"

# --- CONTROL (canary NOT in the lib): all three of A's consumers see it. ----
assert_eq "denylist-A1 control: post-edit TRACKS the canary path" \
    "tracked" "$(track_path "$FA" "$CANARY")"

H_BOTH_PRE=$(hash_of "$FA" "$PLAIN" "$CANARY")
H_PLAIN_PRE=$(hash_of "$FA" "$PLAIN")
assert_eq "denylist-A2 control: the canary CHANGES the change-set hash" "differs" \
    "$([ -n "$H_BOTH_PRE" ] && [ "$H_BOTH_PRE" != "$H_PLAIN_PRE" ] && echo differs || echo same)"

seed_tracker "$FA" "$CANARY"
assert_eq "denylist-A3 control: Stop sees the canary and BLOCKS" \
    "block" "$(stop_decision "$FA")"

# --- THE ONE EDIT ----------------------------------------------------------
DL_REAL=$(mutate_denylist_lib "$FA" '(^|/)canary3mg1/')

# A5 (SAFETY, listed here because it must run immediately after the write):
# the mutation must NOT have travelled down the symlink into the plugin's own
# workflow-denylist.sh. A spec that silently edits the script under test
# poisons every later run on the machine.
assert_eq "denylist-A5 safety: the REAL plugin lib is untouched by the mutation" "0" \
    "$(grep -c 'canary3mg1' "$DL_REAL" | tr -d '[:space:]')"
assert_eq "denylist-A5 safety: the fixture copy is no longer a symlink" "no" \
    "$([ -L "$FA/.claude/scripts/workflow-denylist.sh" ] && echo yes || echo no)"

# --- EFFECT: the same single edit moves all three of A's consumers. --------
assert_eq "denylist-A6 effect: post-edit no longer tracks the canary (consumer 1/3)" \
    "skipped" "$(track_path "$FA" "$CANARY")"

H_BOTH_POST=$(hash_of "$FA" "$PLAIN" "$CANARY")
H_PLAIN_POST=$(hash_of "$FA" "$PLAIN")
assert_eq "denylist-A7 effect: --hash-only excludes the canary (consumer 2/3)" "same" \
    "$([ -n "$H_BOTH_POST" ] && [ "$H_BOTH_POST" = "$H_PLAIN_POST" ] && echo same || echo differs)"

seed_tracker "$FA" "$CANARY"
assert_eq "denylist-A8 effect: Stop no longer sees the canary and RELEASES (consumer 3/3)" \
    "ALLOW" "$(stop_decision "$FA")"

# --- RESTORE + re-assert the control --------------------------------------
# Without this leg a bug that made the fixture permanently un-blockable would
# read as a pass. The control must come BACK when the lib comes back.
restore_denylist_lib "$FA" "$DL_REAL"
seed_tracker "$FA" "$CANARY"
assert_eq "denylist-A9: restoring the lib restores the block (the lib is the cause)" \
    "block" "$(stop_decision "$FA")"

# ===========================================================================
# SECTION B — the memory patterns 3mg.1 added, and the anti-overreach control.
#
# `MEMORY.md` (the auto-memory index) and `.claude/memory/` are agent-written
# recall state, not deliverables. They must leave the reviewable set BEFORE
# F1's doc-only classification: as *.md files they used to satisfy doc-only,
# so a memory-only change set was AUTO-APPROVED — qa-gate.sh approve ran,
# a `[review bypass: F1 doc-only ...]` record was written, and (with an
# active task) the task could be closed. For a file the agent rewrites as a
# side effect of thinking, that is a gate record about nothing.
# ===========================================================================
mk_fixture
FB="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$FB"
harness_gitignore "$FB"
(cd "$FB" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
CT_B="$FB/.claude/scripts/current-task.sh"
QG_B="$FB/.claude/scripts/qa-gate.sh"

# B1. Memory-only change set with an ACTIVE, entered task: the gate releases
# and writes NOTHING. The task must not come out approved.
TID_MEM=$(cd "$FB" && bd create "memory-only change set" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
seed_tracker "$FB" "MEMORY.md" ".claude/memory/x.md"
bash "$QG_B" enter "$TID_MEM" >/dev/null 2>&1
bash "$CT_B" set "$TID_MEM"
seed_tracker "$FB" "MEMORY.md" ".claude/memory/x.md"
assert_eq "denylist-B1: memory-only change set RELEASES (empty after the denylist)" \
    "ALLOW" "$(stop_decision "$FB")"
MEM_STATUS=$(bash "$QG_B" status "$TID_MEM" 2>/dev/null | jq -r '.status // "error"')
assert_eq "denylist-B1: and does NOT auto-approve the task (was: F1 doc-only)" \
    "entered" "$MEM_STATUS"
MEM_COMMENTS=$(bd_show_with_comments "$TID_MEM" "$FB" \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | map(.text) | join("\n")')
assert_not_contains "denylist-B1: no F1 doc-only bypass record was written" \
    "[review bypass: F1 doc-only" "$MEM_COMMENTS"

# B2. Mixed memory + real source: the source still gates, and the block reason
# names ONLY the reviewable path. Reviewers act on the list in that reason;
# padding it with recall-state churn is how a real change hides in the noise.
bash "$CT_B" clear
seed_tracker "$FB" "MEMORY.md" ".claude/memory/x.md" "src/a.ts"
B2_DECISION=$(stop_decision "$FB")
B2_REASON=$(stop_reason "$FB")
assert_eq "denylist-B2: mixed memory + source still BLOCKS (anti-overreach)" \
    "block" "$B2_DECISION"
assert_contains "denylist-B2: the block reason lists the reviewable source path" \
    "src/a.ts" "$B2_REASON"
assert_not_contains "denylist-B2: the block reason does NOT list MEMORY.md" \
    "MEMORY.md" "$B2_REASON"
assert_not_contains "denylist-B2: the block reason does NOT list .claude/memory/" \
    ".claude/memory/" "$B2_REASON"

# B3. The hash agrees with the gate — the whole point of one shared lib.
H_MEM=$(hash_of "$FB" "MEMORY.md" ".claude/memory/x.md" "src/a.ts")
H_SRC=$(hash_of "$FB" "src/a.ts")
assert_eq "denylist-B3: the change-set hash excludes the memory lines" "same" \
    "$([ -n "$H_MEM" ] && [ "$H_MEM" = "$H_SRC" ] && echo same || echo differs)"

# B4. post-edit never records them in the first place.
assert_eq "denylist-B4: post-edit skips MEMORY.md" "skipped" "$(track_path "$FB" "MEMORY.md")"
assert_eq "denylist-B4: post-edit skips .claude/memory/notes.md" \
    "skipped" "$(track_path "$FB" ".claude/memory/notes.md")"

# B5. ANTI-OVERREACH: CLAUDE.md is behaviour-bearing (session-start injects
# it) and LESSONS.md / HANDOFF.md are audit deliverables. None is denylisted;
# they reach the gate and are handled by the *.md doc-only fast path.
assert_eq "denylist-B5: post-edit still tracks CLAUDE.md" \
    "tracked" "$(track_path "$FB" "CLAUDE.md")"
assert_eq "denylist-B5: post-edit still tracks LESSONS.md" \
    "tracked" "$(track_path "$FB" "LESSONS.md")"
assert_eq "denylist-B5: post-edit still tracks HANDOFF.md" \
    "tracked" "$(track_path "$FB" "HANDOFF.md")"
H_CLAUDE=$(hash_of "$FB" "CLAUDE.md" "src/a.ts")
assert_eq "denylist-B5: CLAUDE.md still enters the change-set hash" "differs" \
    "$([ -n "$H_CLAUDE" ] && [ "$H_CLAUDE" != "$H_SRC" ] && echo differs || echo same)"

# ===========================================================================
# SECTION C — the hash migration.
#
# change_set_hash is a sha256 over the DENYLIST-FILTERED changed-files list,
# so editing the lib changes the hash of any change set containing a
# newly-(un)matched path. An approval recorded before the edit no longer
# matches what the Stop hook recomputes after it: the gate emits
# LABEL_WITHOUT_RECORD and re-blocks. That is CORRECT (a stale approval must
# not release) and it is why every denylist addition ships in ONE landing —
# in-flight cycles pay the migration exactly once.
# ===========================================================================
mk_fixture
FC="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$FC"
harness_gitignore "$FC"
(cd "$FC" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
QG_C="$FC/.claude/scripts/qa-gate.sh"
CT_C="$FC/.claude/scripts/current-task.sh"

MIGRATE_PATH="harness3mg1/z.ts"
TID_MIG=$(cd "$FC" && bd create "in-flight approval across a denylist landing" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')

# C1. A normal, honest approval of a two-file change set, then the release.
# (approve truncates the tracker and clears current-task; the session is still
# holding the same change set, so we restore both — the llh.18 specs model a
# live cycle the same way.)
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH"
bash "$QG_C" enter "$TID_MIG" >/dev/null 2>&1
bash "$CT_C" set "$TID_MIG"
seed_review_records "$TID_MIG" "qa-claude" "backend" "$FC"
bash "$QG_C" approve "$TID_MIG" "reviewed both files; ships" >/dev/null 2>&1
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH" "$FC/docs/reviews/$TID_MIG-r1.json" "$FC/docs/specs/$TID_MIG.md"
bash "$CT_C" set "$TID_MIG"
assert_eq "denylist-C1: a matching approval record RELEASES (pre-migration control)" \
    "ALLOW" "$(stop_decision "$FC")"

# C2/C3. The denylist landing re-hashes the change set -> the recorded hash no
# longer matches -> fail closed.
#
# claude-workflow-plugin-fkm.4 (v5 D2): the two seed_tracker calls below are
# DELIBERATELY NOT given docs/specs/$TID_MIG.md, unlike C1's restoration
# above. Measured, not assumed: this file's `seed_tracker` is a full
# OVERWRITE of changed-files.txt, not a discovery walk — reconcile_tracker's
# "already baselined, correctly excluded" reasoning (which lets a LATER
# cycle on the SAME task skip a re-review of an unchanged file) never gets
# a chance to apply here, because whatever a `seed_tracker` call places in
# the tracker persists VERBATIM into whichever `enter`/`approve` call reads
# it next — including C4's recipe below, which does not re-seed anything.
# Adding docs/specs here changes what THAT enter+approve cycle binds, not
# just what this section's own "block" check compares against (block is
# unaffected either way, since the denylist mutation alone already forces
# a mismatch) — and a staged, isolated re-run caught exactly that: with
# docs/specs added here, denylist-C4 (and D5's analogous step) flipped from
# passing to failing, block-for-block identical inputs otherwise. Reverted
# to the pre-fkm.4 two-item form; only C1's restoration (the one assertion
# actually proven broken) changed.
DL_REAL_C=$(mutate_denylist_lib "$FC" '(^|/)harness3mg1/')
assert_eq "denylist-C2 safety: the REAL plugin lib is untouched" "0" \
    "$(grep -c 'harness3mg1' "$DL_REAL_C" | tr -d '[:space:]')"
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH" "$FC/docs/reviews/$TID_MIG-r1.json"
bash "$CT_C" set "$TID_MIG"
C3_DECISION=$(stop_decision "$FC")
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH" "$FC/docs/reviews/$TID_MIG-r1.json"
bash "$CT_C" set "$TID_MIG"
C3_REASON=$(stop_reason "$FC")
assert_eq "denylist-C3: the pre-migration approval no longer releases (fail closed)" \
    "block" "$C3_DECISION"
assert_contains "denylist-C3: the block names the change-set binding, not a generic QA-required" \
    "no change-set-bound approval record matches" "$C3_REASON"

# C4. THE PRINTED REMEDIATION RECOVERS (claude-workflow-plugin-gz3).
#
# This was pinned as a KNOWN GAP by 3mg.1: the block reason above printed
#     qa-gate.sh enter <id> ; impact-report.sh <id> ; qa-gate.sh approve <id>
# and that sequence could not recover, because `enter` does not clear
# `qa-approved` and `approve` short-circuited as an "idempotent no-op" whenever
# that label was present — so no new change-set-bound record was written and the
# gate stayed blocked on a correct-looking recipe. A denylist landing is the
# event that puts EVERY in-flight cycle on that path at once, which is why the
# gap was pinned here rather than papered over.
#
# gz3 made approve's idempotency HASH-AWARE (it no-ops only when a record
# already binds the current change set), so the printed recipe is now a real
# recovery. The commands below are EXTRACTED FROM THE BLOCK REASON captured in
# C3 and executed verbatim — the assertion is about the recipe the operator is
# actually handed, not a paraphrase of it. The explicit-label-removal path stays
# pinned in C5; the guard's own contract (matching-hash re-approve is still a
# no-op) and the approve/Stop race live in
# .claude/tests/component/specs/approve-idempotency.sh.
C4_REMEDY="$FC/.claude/.qa-tracking/c4-printed-remediation.txt"
printf '%s\n' "$C3_REASON" | grep -E '^[[:space:]]*bash \.claude/scripts/' \
    | sed 's/^[[:space:]]*//' > "$C4_REMEDY"
assert_eq "denylist-C4: the migration block prints a 3-command remediation" \
    "3" "$(grep -c . "$C4_REMEDY" | tr -d '[:space:]')"
assert_eq "denylist-C4: ...and it needs no 'bd label remove' step" \
    "0" "$(grep -c 'bd label remove' "$C4_REMEDY" | tr -d '[:space:]')"
C4_APPROVE=""
while IFS= read -r c4_cmd; do
    [ -z "$c4_cmd" ] && continue
    c4_cmd=${c4_cmd//\'<approval summary>\'/\'re-reviewed against the post-migration change set\'}
    C4_LINE=$(cd "$FC" && CLAUDE_PROJECT_DIR="$FC" eval "$c4_cmd" 2>&1 | tail -1)
    case "$c4_cmd" in *"qa-gate.sh approve"*) C4_APPROVE="$C4_LINE" ;; esac
done < "$C4_REMEDY"
assert_contains "denylist-C4: the printed approve writes a freshly-bound record (was: idempotent no-op)" \
    "change-set-bound approval record written" "$C4_APPROVE"
assert_not_contains "denylist-C4: ...and is NOT reported as an idempotent no-op" \
    "idempotent no-op" "$C4_APPROVE"
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH" "$FC/docs/reviews/$TID_MIG-r1.json"
bash "$CT_C" set "$TID_MIG"
assert_eq "denylist-C4: ...so following the printed remediation RELEASES the migrated cycle" \
    "ALLOW" "$(stop_decision "$FC")"

# C5. The OTHER recovery, still supported: retire the stale label explicitly,
# then re-enter, re-review, re-approve. Since gz3 this is no longer the ONLY way
# out (C4 covers the printed recipe), but it stays pinned — an operator who has
# already dropped the label, or a cycle that genuinely wants to start from a
# not-approved state, must still land on a release. The new record is bound to
# the POST-migration hash either way.
(cd "$FC" && bd label remove "$TID_MIG" qa-approved >/dev/null 2>&1)
bash "$QG_C" enter "$TID_MIG" >/dev/null 2>&1
bash "$CT_C" set "$TID_MIG"
seed_review_records "$TID_MIG" "qa-claude" "backend" "$FC"
bash "$QG_C" approve "$TID_MIG" "re-reviewed against the post-migration change set" >/dev/null 2>&1
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH" "$FC/docs/reviews/$TID_MIG-r1.json"
bash "$CT_C" set "$TID_MIG"
assert_eq "denylist-C5: a fresh cycle (drop label -> enter -> approve) recovers" \
    "ALLOW" "$(stop_decision "$FC")"

# C6. ONE landing = ONE migration: with the lib now stable, the recovered
# approval keeps releasing. A second Stop must not re-block.
seed_tracker "$FC" "src/a.ts" "$MIGRATE_PATH" "$FC/docs/reviews/$TID_MIG-r1.json"
bash "$CT_C" set "$TID_MIG"
assert_eq "denylist-C6: the recovered approval keeps releasing (one landing, one migration)" \
    "ALLOW" "$(stop_decision "$FC")"

restore_denylist_lib "$FC" "$DL_REAL_C"

# ===========================================================================
# SECTION D — the v4.1 landing, for the patterns that ACTUALLY SHIPPED
# (claude-workflow-plugin-wg6, absorbing prm).
#
# Section C proves the migration MECHANISM with an invented canary: a pattern
# is ADDED to the lib and the gate is watched. That is a fine proof of "editing
# the lib moves the gate" and it stays untouched. It cannot prove that the
# alternatives which actually shipped are the ones that move it.
#
# Section D therefore runs the other way round, in the direction the operator
# experiences: it PINS THE PRE-LANDING LIB — a private copy whose regex is the
# shipped one with the three v4.1 alternatives REMOVED by literal substring —
# behaves like a v4.0 install under it, and then restores the real lib.
# THAT RESTORE IS THE LANDING.
#
# WHY THIS BUG (what post-edit.sh did, and what it cost)
# ------------------------------------------------------
# post-edit.sh records `tool_input.file_path` VERBATIM. The change set was
# therefore never bounded by the repo: any absolute path an agent wrote
# entered changed-files.txt, the change-set hash, and the Stop gate. Six live
# instances in one release. The worst is the one D2/D3 drive end to end: a
# plan-mode plan file at ~/.claude/plans/<slug>.md hard-blocked a TASK-LESS
# session across three Stop iterations to J21 escalation, because the file is
# .md (so F1 classifies the set doc-only) and F1's doc-only fast path
# auto-approves only WITH an active task — which plan mode forbids creating.
# There was no exit.
#
# SINCE claude-workflow-plugin-fkm.1.15 the "never bounded by the repo" half is
# closed at the writer: post-edit.sh applies a record-time containment check
# against $CLAUDE_PROJECT_DIR (its `CONTAINMENT-FILTER` region), so an
# out-of-repo path no longer reaches the tracker whatever rule 1 says. That
# changes WHERE two of D2's three shapes can be reproduced, not whether the
# v4.1 denylist landing still matters — see the note above D2's legs. It does
# not touch this section's method: `seed_tracker` and `hash_of` write
# changed-files.txt DIRECTLY, exactly as `specs/impact-report-paths.sh` does,
# so every reader-side leg here is unaffected by a writer-side filter.
#
# WHAT SHIPPED, in one landing:
#   (^|/)\.claude/plans/                      plan-mode plan files, anywhere.
#   ^(/private)?/tmp/claude-[^/]+/            the harness session scratchpad.
#   (^|/)\.claude/\.mutation-(runs|worktrees)/   mutation-sweep per-run state.
#
# D1 the discriminating control   D2 pre-landing   D3 the landing
# D4 anti-overreach               D5 the in-flight approval migration
# ===========================================================================

# --- the three alternatives, as LITERAL strings ---------------------------
# Single-quoted, so what is written here is exactly what must appear in the
# shipped regex. D1 proves that claim rather than assuming it.
D_ALT_PLANS='(^|/)\.claude/plans/'
D_ALT_SCRATCH='^(/private)?/tmp/claude-[^/]+/'
D_ALT_MUTATION='(^|/)\.claude/\.mutation-(runs|worktrees)/'

# --- the shapes under test -------------------------------------------------
# The plan file is spelled ABSOLUTE and OUTSIDE any repo on purpose: that is
# the shape post-edit.sh actually recorded, and the shape no repo-relative
# pattern could ever have caught.
#
# Built from $HOME rather than a literal, for two reasons. A hardcoded absolute
# home prefix is exactly what CLAUDE.md and AgentLint S7 forbid in source. And
# $HOME is the REAL prefix — a macOS dev box and a Linux CI runner spell it
# differently — so this exercises the actual out-of-repo spelling on whichever
# machine runs the suite. The assertion does not depend on the value: the
# alternative anchors on (^|/), so any prefix matches, and D1 pins that
# alternative's presence independently.
D_PLAN_ABS="${HOME:-/nonexistent-home}/.claude/plans/v4-1-0-upgrade-gleaming-karp.md"
D_PLAN_REL='.claude/plans/v4-1-0-upgrade-gleaming-karp.md'
D_SCRATCH='/private/tmp/claude-501/sess-a/scratchpad/grader-verdict.json'
D_SCRATCH_LINUX='/tmp/claude-501/sess-a/scratchpad/grader-verdict.json'
D_MUT_RUN='.claude/.mutation-runs/2026-07-29T12-00-00/report.json'
D_MUT_WT='.claude/.mutation-worktrees/mut-014/src/a.ts'

mk_fixture
FD="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$FD"
bash "$FD/.claude/scripts/current-task.sh" clear

# ---------------------------------------------------------------------------
# D1 — THE DISCRIMINATING CONTROL. Read this before trusting anything below.
#
# The pre-landing regex is built by stripping three literal substrings. If a
# future landing renames or rewords any of them, the strip SILENTLY NO-OPS:
# the "pre-landing" lib becomes byte-identical to the shipped one, D2's
# "tracked" and D3's "skipped" both keep measuring the same lib, and the whole
# section goes green having proved nothing. So D1 asserts, per alternative,
# that the strip actually removed something — LESSONS.md's rule that a test
# whose acceptance is an ABSENCE needs a control that discriminates the cause.
#
# The fixture is DELIBERATELY NOT A GIT REPO, and D3 is why. D3 seeds a
# tracker whose ONLY line is denylisted; reviewable_changes() then finds
# nothing in the tracker (found=0) and FALLS THROUGH to the git-status
# fallback. In a git fixture we would be measuring that fallback, not the
# denylist. With no git repo has_git_repo returns non-zero, the fallback is
# skipped, and the change set is genuinely `empty`. (Non-git projects are a
# supported configuration — has_git_repo exists to answer exactly this.)
assert_eq "denylist-D1: the drop/keep fixture is intentionally NOT a git repo (isolates the denylist)" \
    "no" "$(git -C "$FD" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no)"

D_LIB_LINK="$FD/.claude/scripts/workflow-denylist.sh"
D_LIB_REAL=$(readlink "$D_LIB_LINK" 2>/dev/null || printf '%s' "$D_LIB_LINK")
D_SHIPPED=$(shipped_regex_of "$D_LIB_REAL")
assert_eq "denylist-D1: the shipped WORKFLOW_DENYLIST_REGEX was extracted" \
    "yes" "$([ -n "$D_SHIPPED" ] && echo yes || echo no)"

# Per alternative: removing it must CHANGE the regex. This is the leg that
# fails loudly if a pattern is renamed out from under this spec.
assert_eq "denylist-D1 control: the shipped regex really carries the plans/ alternative (strip is not a no-op)" \
    "differs" "$([ "$(strip_alt "$D_SHIPPED" "$D_ALT_PLANS")" != "$D_SHIPPED" ] && echo differs || echo same)"
assert_eq "denylist-D1 control: ...and the session-scratchpad alternative" \
    "differs" "$([ "$(strip_alt "$D_SHIPPED" "$D_ALT_SCRATCH")" != "$D_SHIPPED" ] && echo differs || echo same)"
assert_eq "denylist-D1 control: ...and the mutation-harness alternative" \
    "differs" "$([ "$(strip_alt "$D_SHIPPED" "$D_ALT_MUTATION")" != "$D_SHIPPED" ] && echo differs || echo same)"

# Build the pre-landing regex: all three removed.
D_PRE="$D_SHIPPED"
D_PRE=$(strip_alt "$D_PRE" "$D_ALT_PLANS")
D_PRE=$(strip_alt "$D_PRE" "$D_ALT_SCRATCH")
D_PRE=$(strip_alt "$D_PRE" "$D_ALT_MUTATION")

# ...and it must really be pre-landing: none of the three may survive.
assert_eq "denylist-D1: the pre-landing regex no longer carries plans/" "0" \
    "$(printf '%s' "$D_PRE" | grep -cF -- "$D_ALT_PLANS" | tr -d '[:space:]')"
assert_eq "denylist-D1: ...nor the session scratchpad" "0" \
    "$(printf '%s' "$D_PRE" | grep -cF -- "$D_ALT_SCRATCH" | tr -d '[:space:]')"
assert_eq "denylist-D1: ...nor the mutation-harness dirs" "0" \
    "$(printf '%s' "$D_PRE" | grep -cF -- "$D_ALT_MUTATION" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# D2 — PRE-LANDING. Pin the reduced regex; the fixture is now a v4.0 install.
D_REAL=$(pin_denylist_regex "$FD" "$D_PRE")

# SAFETY, immediately after the write (mirrors A5/C2): the pin must NOT have
# travelled down the symlink into the plugin's own lib. A spec that edits the
# script under test poisons every later run on the machine.
assert_eq "denylist-D2 safety: the REAL plugin lib still carries all three v4.1 alternatives" "3" \
    "$(( $(grep -cF -- "$D_ALT_PLANS" "$D_LIB_REAL" | tr -d '[:space:]') \
       + $(grep -cF -- "$D_ALT_SCRATCH" "$D_LIB_REAL" | tr -d '[:space:]') \
       + $(grep -cF -- "$D_ALT_MUTATION" "$D_LIB_REAL" | tr -d '[:space:]') ))"
assert_eq "denylist-D2 safety: the fixture copy is no longer a symlink" "no" \
    "$([ -L "$D_LIB_LINK" ] && echo yes || echo no)"

# THE SECOND DISCRIMINATING CONTROL, and it is not optional. Everything D2
# asserts next is an ABSENCE of filtering ("tracked"), and a pinned lib that
# does not parse, does not source, or carries a MALFORMED ERE produces exactly
# that same observable: workflow_denylisted would fail for every path and every
# "tracked" would pass while proving nothing about the pre-landing regex. So
# prove the pinned lib is still a WORKING denylist first, on a control path
# both regexes drop. A "drop" here means it parsed, sourced silently enough to
# define the function, and matched — all four properties in one assertion.
assert_eq "denylist-D2 control: the pinned pre-landing lib is still a WORKING denylist (the strip did not corrupt the ERE)" \
    "drop" "$(bash -c '. "$1"; workflow_denylisted "$2" && echo drop || echo keep' \
        _pinned "$D_LIB_LINK" 'node_modules/x.js' 2>/dev/null)"

# post-edit TRACKED all of it — the defect, reproduced.
#
# WHICH CONSUMER EACH SHAPE IS REPRODUCED AT, and why they are not all the hook
# any more (fkm.1.15). post-edit.sh now applies a record-time containment check,
# so the two ABSOLUTE OUT-OF-REPO shapes are dropped at the hook by that rule
# whatever the denylist says — a hook-level "tracked" is no longer obtainable for
# them under ANY lib, and asserting one would be asserting a fiction. Reproducing
# them at the hook would also stop being a pin on rule 1 at all, which is the
# same silent-decay trap D1 exists to prevent.
#
# So each shape is reproduced at a consumer that can still see it:
#   • repo-relative plan file      -> the HOOK (containment keeps relative paths;
#                                     they are resolved against the root)
#   • mutation-sweep run report    -> the HOOK (repo-relative too)
#   • out-of-repo plan file        -> the HASH, seeded directly
#   • session scratchpad verdict   -> the HASH, seeded directly
# The hash is not a consolation prize: it is where rule 1 still MUST hold for
# these shapes, because a tracker written by an older install (or by any future
# direct writer, as two component specs already are) can still contain them, and
# `impact-report.sh` deliberately applies rule 1 and nothing else.
assert_eq "denylist-D2 pre-landing: post-edit TRACKS the repo-relative plan file" \
    "tracked" "$(track_path "$FD" "$D_PLAN_REL")"
assert_eq "denylist-D2 pre-landing: post-edit TRACKS a mutation-sweep run report" \
    "tracked" "$(track_path "$FD" "$D_MUT_RUN")"

# The two out-of-repo shapes, at the hash. One variable per pair: the same two
# seeds are re-measured under the restored lib in D3, so the difference is the
# lib and nothing else.
D2_H_SRC=$(hash_of "$FD" "src/a.ts")
D2_H_PLAN=$(hash_of "$FD" "src/a.ts" "$D_PLAN_ABS")
D2_H_SCRATCH=$(hash_of "$FD" "src/a.ts" "$D_SCRATCH")
assert_eq "denylist-D2 pre-landing: the out-of-repo plan file ENTERS the change-set hash" "differs" \
    "$([ -n "$D2_H_PLAN" ] && [ "$D2_H_PLAN" != "$D2_H_SRC" ] && echo differs || echo same)"
assert_eq "denylist-D2 pre-landing: ...and so does the session scratchpad verdict" "differs" \
    "$([ -n "$D2_H_SCRATCH" ] && [ "$D2_H_SCRATCH" != "$D2_H_SRC" ] && echo differs || echo same)"
# ...and the pinned lib itself says "keep" for both, so the hash legs above are
# reporting the regex rather than some other filter in impact-report.sh.
d2_pinned_verdict() {
    bash -c '. "$1"; workflow_denylisted "$2" && echo drop || echo keep' \
        _pinned "$D_LIB_LINK" "$1" 2>/dev/null
}
assert_eq "denylist-D2 pre-landing: the pinned lib KEEPS the out-of-repo plan file (rule 1 is the variable)" \
    "keep" "$(d2_pinned_verdict "$D_PLAN_ABS")"
assert_eq "denylist-D2 pre-landing: ...and KEEPS the session scratchpad verdict" \
    "keep" "$(d2_pinned_verdict "$D_SCRATCH")"

# THE DEAD END, end to end. Plan file alone, NO active task (plan mode cannot
# create one). The set is doc-only, so F1 is reached — and F1 auto-approves
# only WITH a task, so it falls straight through to the hard QA-required block.
seed_tracker "$FD" "$D_PLAN_ABS"
D2_DECISION=$(stop_decision "$FD")
seed_tracker "$FD" "$D_PLAN_ABS"
D2_REASON=$(stop_reason "$FD")
assert_eq "denylist-D2 pre-landing: a plan-file-only, task-less Stop BLOCKS (the recorded J21 dead end)" \
    "block" "$D2_DECISION"
assert_contains "denylist-D2 pre-landing: ...and the block names the out-of-repo plan file" \
    "$D_PLAN_ABS" "$D2_REASON"
assert_contains "denylist-D2 pre-landing: ...and demands a Beads task the plan-mode session cannot create" \
    "No active Beads task detected" "$D2_REASON"

# ---------------------------------------------------------------------------
# D3 — THE LANDING. Restoring the real lib IS the v4.1 landing.
restore_denylist_lib "$FD" "$D_REAL"

# READ THE PAIRING BEFORE THE LEGS (fkm.1.15). For the two ABSOLUTE OUT-OF-REPO
# shapes — the plan file and the scratchpad verdict — this hook-level "skipped"
# is now OVER-DETERMINED: post-edit's containment rule drops them too, so these
# three legs would pass with the plans/ and scratchpad alternatives deleted from
# the regex. They are kept because "the hook must not track them" is still a
# contract worth pinning, but they are NOT the discriminating half of the pair
# any more. The discriminating pin for those two shapes is the HASH: D2 measured
# both entering it under the pre-landing lib, and the six-shape leg below
# measures both absent under the restored one. One variable, the lib, either way.
# The relative and mutation-sweep shapes below remain discriminating at the hook,
# because containment keeps relative paths.
assert_eq "denylist-D3 landing: post-edit no longer tracks the out-of-repo plan file" \
    "skipped" "$(track_path "$FD" "$D_PLAN_ABS")"
assert_eq "denylist-D3 landing: ...nor a repo-relative .claude/plans/ file (still discriminating: containment keeps relative paths)" \
    "skipped" "$(track_path "$FD" "$D_PLAN_REL")"
assert_eq "denylist-D3 landing: ...nor the macOS session scratchpad (/private/tmp/claude-<sess>/)" \
    "skipped" "$(track_path "$FD" "$D_SCRATCH")"
# CI is Linux, where there is no /private prefix — the (/private)? optionality
# is only half-proven without this leg.
assert_eq "denylist-D3 landing: ...nor the Linux session scratchpad (/tmp/claude-<sess>/)" \
    "skipped" "$(track_path "$FD" "$D_SCRATCH_LINUX")"
assert_eq "denylist-D3 landing: ...nor a mutation-sweep run report" \
    "skipped" "$(track_path "$FD" "$D_MUT_RUN")"
assert_eq "denylist-D3 landing: ...nor a --keep-worktrees mutation worktree" \
    "skipped" "$(track_path "$FD" "$D_MUT_WT")"

# The same task-less Stop that had no exit now releases: the set is `empty`
# after the denylist, not `doc-only`, so F1's no-task branch allows.
seed_tracker "$FD" "$D_PLAN_ABS"
assert_eq "denylist-D3 landing: the same task-less plan-file Stop now RELEASES (the dead end is gone)" \
    "ALLOW" "$(stop_decision "$FD")"

# ...and consumer 2/3 agrees: none of the six shapes enters the hash.
D3_H_ALL=$(hash_of "$FD" "src/a.ts" "$D_PLAN_ABS" "$D_PLAN_REL" "$D_SCRATCH" \
    "$D_SCRATCH_LINUX" "$D_MUT_RUN" "$D_MUT_WT")
D3_H_SRC=$(hash_of "$FD" "src/a.ts")
assert_eq "denylist-D3 landing: the change-set hash excludes all six shapes" "same" \
    "$([ -n "$D3_H_ALL" ] && [ "$D3_H_ALL" = "$D3_H_SRC" ] && echo same || echo differs)"

# ---------------------------------------------------------------------------
# D4 — ANTI-OVERREACH, under the SHIPPED lib. Each of these must stay
# reviewable, and each would be taken out by a DIFFERENT over-broad rewrite of
# one of the three alternatives.

# The project's own planning deliverables. `docs/plans/` is not `.claude/plans/`.
assert_eq "denylist-D4: docs/plans/ stays reviewable (a deliverable, not a plan-mode file)" \
    "tracked" "$(track_path "$FD" "docs/plans/v4.1-upgrade-wave.md")"
# Only the harness's per-run OUTPUT is dropped; its source is shipped code.
assert_eq "denylist-D4: the mutation harness SOURCE stays reviewable" \
    "tracked" "$(track_path "$FD" ".claude/tests/mutation/mutation-sweep.sh")"

# POSITIVE PINS OF THE DELIBERATE LIMIT (workflow-denylist.sh, "WHAT IS
# DELIBERATELY *NOT* DENYLISTED"). Two of the six recorded instances were
# agent-chosen /tmp paths — /tmp/qa-p5n-probe/ and a bare /tmp/enc-diff.sh
# that entered an APPROVAL's bound change set.
#
# THE CLASS IS NOW FIXED — but not here, and the difference is the whole point
# (claude-workflow-plugin-fkm.1.15). THIS REGEX still does not name /tmp or
# /var/folders, and must not: a general pattern would also filter this suite's
# own fixture paths, which is the very next assertion. What closed the class is
# post-edit.sh's record-time CONTAINMENT check, which asks a different question —
# "is this path inside the project this session is certifying?" — and answers YES
# for the fixture paths, because they live inside the `mktemp -d` root the fixture
# points CLAUDE_PROJECT_DIR at. So both halves are pinned separately below: rule
# 1 KEEPS these paths (the limit is intact, no regex widened) and the HOOK drops
# them (the class is closed). Prompt guidance remains as the belt to that braces —
# `qa.md` and the three specialist prompts still send probes to the session
# scratchpad — but it is no longer the only mechanism.
d4_lib_verdict() {
    bash -c '. "$1"; workflow_denylisted "$2" && echo drop || echo keep' \
        _shipped "$FD/.claude/scripts/workflow-denylist.sh" "$1" 2>/dev/null
}
assert_eq "denylist-D4: rule 1 still KEEPS agent-chosen /tmp scratch (the regex limit is deliberate and unwidened)" \
    "keep" "$(d4_lib_verdict "/tmp/qa-p5n-probe/notes.md")"
assert_eq "denylist-D4: ...including a BARE file at /tmp root (no directory to anchor on)" \
    "keep" "$(d4_lib_verdict "/tmp/enc-diff.sh")"
assert_eq "denylist-D4: ...and the HOOK drops both anyway, by containment (fkm.1.15 — the class IS closed)" \
    "skipped:skipped" \
    "$(track_path "$FD" "/tmp/qa-p5n-probe/notes.md"):$(track_path "$FD" "/tmp/enc-diff.sh")"

# THE MECHANICAL REASON, pinned with the realest possible witness: this
# fixture's own path. mk_fixture is `mktemp -d -t component-fixture.XXXXXX`,
# so $FD is /tmp/... on Linux CI and /var/folders/... on a macOS dev box —
# exactly the roots impact-report-paths.sh and worktree-approval-resolution.sh
# seed into changed-files.txt as ABSOLUTE paths. A /tmp or /var/folders
# pattern would empty those change sets and both specs would pass vacuously.
#
# This leg now carries a SECOND load (fkm.1.15): it is also the proof that
# containment did not smuggle in the /tmp pattern by the back door. The path is
# under the same /tmp or /var/folders root as the two dropped probes above and it
# stays TRACKED, because CLAUDE_PROJECT_DIR points at it. If containment ever
# starts matching a literal prefix rather than the runtime root, this fails.
assert_eq "denylist-D4: this spec's own mktemp -d fixture path stays reviewable (why /tmp is rejected — and why containment is safe)" \
    "tracked" "$(track_path "$FD" "$FD/src/a.ts")"
# The ^ anchor is scoped to its own ERE branch, so a repo-relative source path
# that merely CONTAINS tmp/claude- is not the session scratchpad.
assert_eq "denylist-D4: a repo-relative src/tmp/claude-*/ path stays reviewable (^ anchor holds)" \
    "tracked" "$(track_path "$FD" "src/tmp/claude-501/x/y.ts")"

# ...and the gate agrees, not just the tracker: a mixed set still blocks and
# the reason names ONLY the reviewable path. Reviewers act on that list.
seed_tracker "$FD" "$D_PLAN_ABS" "$D_MUT_RUN" "src/a.ts"
D4_DECISION=$(stop_decision "$FD")
seed_tracker "$FD" "$D_PLAN_ABS" "$D_MUT_RUN" "src/a.ts"
D4_REASON=$(stop_reason "$FD")
assert_eq "denylist-D4: a mixed scratch + source change set still BLOCKS" "block" "$D4_DECISION"
assert_contains "denylist-D4: ...and the reason lists the reviewable source path" \
    "src/a.ts" "$D4_REASON"
assert_not_contains "denylist-D4: ...and does NOT list the plan file" \
    "$D_PLAN_ABS" "$D4_REASON"

# ===========================================================================
# D5 — THE IN-FLIGHT APPROVAL MIGRATION, for the real patterns.
#
# C3-C6 prove the migration for a canary. D5 proves it for the landing that
# actually shipped, and in the operator's direction: an honest approval is
# recorded under the PRE-LANDING lib, the real lib is restored (the landing),
# and the cycle must fail closed and then recover on the printed recipe.
#
# This one NEEDS a git repo with a committed baseline (bd + a full gate cycle),
# mirroring section C's fixture. The tracker always carries a reviewable path
# here, so reviewable_changes() never reaches the git fallback — the git repo
# is scaffolding for the gate cycle, not part of what is measured.
# ===========================================================================
mk_fixture
FD5="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$FD5"
harness_gitignore "$FD5"
(cd "$FD5" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true
QG_D="$FD5/.claude/scripts/qa-gate.sh"
CT_D="$FD5/.claude/scripts/current-task.sh"

TID_D5=$(cd "$FD5" && bd create "in-flight approval across the v4.1 denylist landing" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')

D5_REAL=$(pin_denylist_regex "$FD5" "$D_PRE")
assert_eq "denylist-D5 safety: the REAL plugin lib is untouched by the pin" "3" \
    "$(( $(grep -cF -- "$D_ALT_PLANS" "$D5_REAL" | tr -d '[:space:]') \
       + $(grep -cF -- "$D_ALT_SCRATCH" "$D5_REAL" | tr -d '[:space:]') \
       + $(grep -cF -- "$D_ALT_MUTATION" "$D5_REAL" | tr -d '[:space:]') ))"

# An honest v4.0 approval: the change set is the real deliverable PLUS the plan
# file the agent wrote while planning it. That is what v4.0 tracked, so that is
# what the approval binds. (approve truncates the tracker and clears
# current-task; the session still holds the same change set, so both are
# restored afterwards — the same way section C models a live cycle.)
seed_tracker "$FD5" "src/a.ts" "$D_PLAN_ABS"
bash "$QG_D" enter "$TID_D5" >/dev/null 2>&1
bash "$CT_D" set "$TID_D5"
seed_review_records "$TID_D5" "qa-claude" "backend" "$FD5"
bash "$QG_D" approve "$TID_D5" "reviewed under the pre-landing denylist" >/dev/null 2>&1
# claude-workflow-plugin-fkm.4 (v5 D2): docs/specs/$TID_D5.md gets the SAME
# treatment as docs/reviews' own canonical artifact, and for the SAME
# fixture-lifetime reason denylist-C1's header comment gives — this is the
# FIRST post-approve restore for $TID_D5, so its design doc is still a
# genuine survivor of reconcile_tracker's baseline subtraction. Do not add
# it to a LATER restore in this section by symmetry; see that header.
seed_tracker "$FD5" "src/a.ts" "$D_PLAN_ABS" "$FD5/docs/reviews/$TID_D5-r1.json" "$FD5/docs/specs/$TID_D5.md"
bash "$CT_D" set "$TID_D5"
assert_eq "denylist-D5: the pre-landing approval RELEASES (control)" \
    "ALLOW" "$(stop_decision "$FD5")"

# --- THE LANDING -----------------------------------------------------------
restore_denylist_lib "$FD5" "$D5_REAL"

# claude-workflow-plugin-fkm.4 (v5 D2): the two seed_tracker calls below are
# deliberately NOT given docs/specs/$TID_D5.md — same reasoning as
# denylist-shared.sh's C2/C3 header a few hundred lines up: this is a full
# tracker OVERWRITE, not a discovery walk, so whatever it places here
# persists verbatim into the printed-remediation approve a few lines below,
# which does not re-seed anything. Confirmed by a staged re-run: adding it
# here left the block check (unaffected, since the landing alone forces the
# mismatch) but flipped the LATER "printed recovery RELEASES" assertion from
# passing to failing.
seed_tracker "$FD5" "src/a.ts" "$D_PLAN_ABS" "$FD5/docs/reviews/$TID_D5-r1.json"
bash "$CT_D" set "$TID_D5"
D5_DECISION=$(stop_decision "$FD5")
seed_tracker "$FD5" "src/a.ts" "$D_PLAN_ABS" "$FD5/docs/reviews/$TID_D5-r1.json"
bash "$CT_D" set "$TID_D5"
D5_REASON=$(stop_reason "$FD5")
assert_eq "denylist-D5: after the landing the pre-landing approval no longer releases (fail closed)" \
    "block" "$D5_DECISION"
assert_contains "denylist-D5: the block names the change-set binding, not a generic QA-required" \
    "no change-set-bound approval record matches" "$D5_REASON"
assert_not_contains "denylist-D5: ...and the plan file has already left the reviewable set" \
    "$D_PLAN_ABS" "$D5_REASON"

# The printed recovery, extracted from the block reason and run VERBATIM — the
# assertion is about the recipe the operator is handed, not a paraphrase.
D5_REMEDY="$FD5/.claude/.qa-tracking/d5-printed-remediation.txt"
printf '%s\n' "$D5_REASON" | grep -E '^[[:space:]]*bash \.claude/scripts/' \
    | sed 's/^[[:space:]]*//' > "$D5_REMEDY"
assert_eq "denylist-D5: the migration block prints a 3-command remediation" \
    "3" "$(grep -c . "$D5_REMEDY" | tr -d '[:space:]')"
assert_eq "denylist-D5: ...and it needs no 'bd label remove' step" \
    "0" "$(grep -c 'bd label remove' "$D5_REMEDY" | tr -d '[:space:]')"
D5_APPROVE=""
while IFS= read -r d5_cmd; do
    [ -z "$d5_cmd" ] && continue
    d5_cmd=${d5_cmd//\'<approval summary>\'/\'re-reviewed against the post-landing change set\'}
    D5_LINE=$(cd "$FD5" && CLAUDE_PROJECT_DIR="$FD5" eval "$d5_cmd" 2>&1 | tail -1)
    case "$d5_cmd" in *"qa-gate.sh approve"*) D5_APPROVE="$D5_LINE" ;; esac
done < "$D5_REMEDY"
assert_contains "denylist-D5: the printed approve writes a freshly-bound record" \
    "change-set-bound approval record written" "$D5_APPROVE"
seed_tracker "$FD5" "src/a.ts" "$D_PLAN_ABS" "$FD5/docs/reviews/$TID_D5-r1.json"
bash "$CT_D" set "$TID_D5"
assert_eq "denylist-D5: ...so the printed recovery RELEASES the migrated cycle (one landing, one migration)" \
    "ALLOW" "$(stop_decision "$FD5")"

# ===========================================================================
# SECTION E — THE SECOND RULE AND THE FOURTH CONSUMER
# (claude-workflow-plugin-94d; closes QA finding R1-F1, and pins the rule whose
#  absence from post-edit.sh was R2-F5).
#
# 94d gave the lib a SECOND rule and a FOURTH consumer, and extended neither
# canary. What that cost, concretely: post-edit.sh — the PRIMARY writer of
# changed-files.txt, and a file the same change set modified — never applied
# workflow_self_written, so a Write-tool edit to `.claude/.qa-tracking/` entered
# the tracker, the change-set hash, and the Stop detector, in direct
# contradiction of the rule's own stated intent ("keep it OUT of the change
# set"). Measured, not inferred: writing the review artifact took the tracker
# 23 -> 24 paths and moved change_set_hash abe62c33… -> 752729a4…, after which
# `approve` refused exit 2 impact_report_stale against a report `enter` had just
# generated. A rule with four relevant writers, asserted against three.
#
#   E1  the canary at CONSUMER 4/4 — one lib edit, observed at reconcile_tracker
#   E2  RULE 2 at both writers, plus THE BOUNDARY it turns on
#   E3  B3 for rule 2 — the hash and the gate agree
#
# THIS FIXTURE IS A GIT REPO, and its `.claude/.qa-tracking/` is deliberately
# NOT gitignored. Both are load-bearing. reconcile_tracker walks `git status`
# and no-ops on a non-git tree, so a non-git fixture could not measure consumer
# 4 at all. And `install.sh` writes the `.qa-tracking/` ignore rule only when the
# target has no `.gitignore` at all, so in many real installs the gate's own
# state IS git-visible — which is the exact condition rule 2 exists for. A
# fixture that hid it would make every assertion below vacuous.
#
# What IS gitignored is only this section's own instrumentation: `bin/` and
# `.claude/scripts/`, because E1 rewrites the fixture's workflow-denylist.sh
# mid-cycle (that is its method) and those writes are real, git-visible,
# un-baselined changes the reconciler would otherwise correctly fold in. Same
# call harness_gitignore makes for sections B/C/D5, minus the `.qa-tracking/`
# line. The SUBJECT paths stay fully visible.
# ===========================================================================
mk_fixture
FE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$FE"
QG_E="$FE/.claude/scripts/qa-gate.sh"
TRACK_E="$FE/.claude/.qa-tracking/changed-files.txt"

# Deliberately NOT harness_gitignore: see the section header for why
# `.claude/.qa-tracking/` must stay git-visible here.
printf 'bin/\n.claude/scripts/\n' > "$FE/.gitignore"
(cd "$FE" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# reconcile_e — run the subcommand form (the one verify-before-stop.sh calls)
# against a CLEAN tracker and print its rc. Truncating first isolates each leg:
# the reconciler is append-only and never removes, so a leftover entry from a
# previous leg would satisfy the next one.
reconcile_e() {
    : > "$TRACK_E"
    local rc=0
    CLAUDE_PROJECT_DIR="$FE" bash "$QG_E" reconcile-tracker >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}
# tracked_e <path> — is <path> in the tracker, as a whole line?
tracked_e() {
    if grep -qxF -- "$1" "$TRACK_E" 2>/dev/null; then printf 'tracked'; else printf 'skipped'; fi
}

assert_eq "denylist-E0: the section-E fixture IS a git repo (reconcile_tracker no-ops otherwise)" \
    "yes" "$(git -C "$FE" rev-parse --git-dir >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "denylist-E0: ...and its .qa-tracking/ is git-VISIBLE (the condition rule 2 exists for)" \
    "visible" "$(grep -q 'qa-tracking' "$FE/.gitignore" && echo ignored || echo visible)"
assert_eq "denylist-E0: fixture lib is still a symlink to the real plugin lib" "yes" \
    "$([ -L "$FE/.claude/scripts/workflow-denylist.sh" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# E1 — THE CANARY AT CONSUMER 4/4. Section A's structure exactly: control, ONE
# edit, effect, restore, control again.
E_CANARY_REL="canary94d/x.ts"
E_CANARY_ABS="$FE/$E_CANARY_REL"
mkdir -p "$FE/canary94d"
printf 'export const x = 1;\n' > "$E_CANARY_ABS"

assert_eq "denylist-E1 control: reconcile-tracker succeeds (rc=0)" "0" "$(reconcile_e)"
assert_eq "denylist-E1 control: reconcile APPENDS the canary path, absolute-spelled" \
    "tracked" "$(tracked_e "$E_CANARY_ABS")"

DL_REAL_E=$(mutate_denylist_lib "$FE" '(^|/)canary94d/')
assert_eq "denylist-E1 safety: the REAL plugin lib is untouched by the mutation" "0" \
    "$(grep -c 'canary94d' "$DL_REAL_E" | tr -d '[:space:]')"
assert_eq "denylist-E1 safety: the fixture copy is no longer a symlink" "no" \
    "$([ -L "$FE/.claude/scripts/workflow-denylist.sh" ] && echo yes || echo no)"

assert_eq "denylist-E1 effect: reconcile still succeeds after the edit (rc=0)" "0" "$(reconcile_e)"
assert_eq "denylist-E1 effect: ...and no longer appends the canary (CONSUMER 4/4)" \
    "skipped" "$(tracked_e "$E_CANARY_ABS")"

restore_denylist_lib "$FE" "$DL_REAL_E"
reconcile_e >/dev/null
assert_eq "denylist-E1: restoring the lib restores the append (the lib is the cause)" \
    "tracked" "$(tracked_e "$E_CANARY_ABS")"

# ---------------------------------------------------------------------------
# E2 — RULE 2 AT BOTH WRITERS OF changed-files.txt, AND THE BOUNDARY.
#
# One file, two writers. If they apply different filters they disagree about
# what belongs in the file they share — the drift class the shared lib exists to
# prevent, and the one R2-F5 turned out to be a live instance of.
E_ART="$FE/.claude/.qa-tracking/review-artifact-cwp-94d-r1.json"
E_SRC_REL="src/e2.ts"
E_SRC_ABS="$FE/$E_SRC_REL"
E_INTER="$FE/.beads/interactions.jsonl"
E_LEDGER="$FE/.beads/issues.jsonl"

mkdir -p "$FE/src"
printf 'export const e2 = 1;\n' > "$E_SRC_ABS"
printf '{"contract_version":"1"}\n' > "$E_ART"
# Both ledgers made git-DIRTY on purpose, so the boundary is measured on paths
# git actually reports. Appending a blank line rather than rewriting: bd 1.1.2's
# primary store is .beads/embeddeddolt (gitignored) and these JSONL files are
# read only on an explicit import, where a blank line is a no-op — so the tree
# is dirtied without corrupting anything a later bd call could read.
printf '\n' >> "$E_INTER"
printf '\n' >> "$E_LEDGER"

assert_eq "denylist-E2: reconcile succeeds on the mixed tree (rc=0)" "0" "$(reconcile_e)"
# The reconcile DID work — without this the two "skipped" legs below could come
# from a reconcile that did nothing at all.
assert_eq "denylist-E2 control: the genuine source path IS reconciled in" \
    "tracked" "$(tracked_e "$E_SRC_ABS")"
# RULE 2, at writer 2/2.
assert_eq "denylist-E2: reconcile refuses to append the REVIEW ARTIFACT (rule 2, writer 2/2)" \
    "skipped" "$(tracked_e "$E_ART")"
assert_eq "denylist-E2: ...nor changed-files.txt itself" \
    "skipped" "$(tracked_e "$TRACK_E")"
assert_eq "denylist-E2: ...nor bd's interaction log" \
    "skipped" "$(tracked_e "$E_INTER")"
# THE BOUNDARY. One character of regex separates these two files, and nothing
# asserted it before 94d/R1-F1. issues.jsonl is the committed ledger — a real
# deliverable — and a rule that swallowed it would erase the audit trail from
# every change set.
assert_eq "denylist-E2 BOUNDARY: .beads/issues.jsonl IS reconciled in (committed ledger)" \
    "tracked" "$(tracked_e "$E_LEDGER")"

# RULE 2, at writer 1/2 (post-edit.sh). track_path truncates the tracker itself,
# so these are independent of everything above.
assert_eq "denylist-E2: post-edit refuses to track the review artifact (rule 2, writer 1/2)" \
    "skipped" "$(track_path "$FE" "$E_ART")"
assert_eq "denylist-E2: ...nor bd's interaction log" \
    "skipped" "$(track_path "$FE" "$E_INTER")"
assert_eq "denylist-E2 BOUNDARY: post-edit still tracks .beads/issues.jsonl" \
    "tracked" "$(track_path "$FE" "$E_LEDGER")"
# ANTI-OVERREACH at the writer: neither anchor may be widened silently.
assert_eq "denylist-E2: src/.qa-tracking/x.ts stays reviewable (.claude/ segment required)" \
    "tracked" "$(track_path "$FE" "src/.qa-tracking/x.ts")"
assert_eq "denylist-E2: .beads/interactions.jsonl.bak stays reviewable (\$ anchor holds)" \
    "tracked" "$(track_path "$FE" ".beads/interactions.jsonl.bak")"

# ---------------------------------------------------------------------------
# E3 — B3 FOR THE SECOND RULE: THE HASH AGREES WITH THE GATE.
#
# B3's assertion is "the change-set hash excludes the memory lines — the whole
# point of one shared lib". This is the same assertion for rule 2, and it is the
# one R1-F1 named as missing. The mechanism differs in an important way, and the
# comment records it so a future reader does not "fix" the asymmetry by accident:
# the denylist is applied by the READERS (impact-report.sh filters the tracker it
# hashes), while rule 2 is applied by the WRITERS. So there is nothing to filter
# at hash time — the proof is that after BOTH writers have run over a tree
# containing gate state, the tracker, the hash, and the Stop detector all name
# exactly the reviewable path and nothing else.
bash "$FE/.claude/scripts/current-task.sh" clear
: > "$TRACK_E"
# Writer 1: the runtime's PostToolUse call for the real edit...
printf '{"tool_input":{"file_path":"%s"}}' "$E_SRC_ABS" \
    | CLAUDE_PROJECT_DIR="$FE" bash "$FE/.claude/scripts/post-edit.sh" >/dev/null 2>&1
# ...and for the gate's own artifact, which a reviewer authoring it with the
# Write tool really does produce. This is R2-F5's exact reproduction.
printf '{"tool_input":{"file_path":"%s"}}' "$E_ART" \
    | CLAUDE_PROJECT_DIR="$FE" bash "$FE/.claude/scripts/post-edit.sh" >/dev/null 2>&1
# Writer 2: the reconcile, over the same tree.
CLAUDE_PROJECT_DIR="$FE" bash "$QG_E" reconcile-tracker >/dev/null 2>&1 || true

assert_eq "denylist-E3: the tracker holds the source path after BOTH writers ran" \
    "tracked" "$(tracked_e "$E_SRC_ABS")"
assert_eq "denylist-E3: ...and NOT the review artifact, from either writer" \
    "skipped" "$(tracked_e "$E_ART")"
assert_eq "denylist-E3: ...and NOT bd's interaction log" \
    "skipped" "$(tracked_e "$E_INTER")"

# THE HASH MOVES IF THE ARTIFACT GETS IN — one variable, isolated. The hash is
# computed through impact-report.sh --hash-only, the same entry point
# `qa-gate.sh approve` and the Stop gate use, so this measures the shipping hash
# rather than a re-implementation. Both operands are the tracker AS IT STANDS,
# differing by exactly one appended line, which is the shape of the live
# reproduction (tracker 23 -> 24, hash abe62c33… -> 752729a4…).
hash_now_e() {
    CLAUDE_PROJECT_DIR="$FE" bash "$FE/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo ""
}
E3_CLEAN_HASH=$(hash_now_e)
cp "$TRACK_E" "$TRACK_E.e3bak"
printf '%s\n' "$E_ART" >> "$TRACK_E"
E3_POLLUTED_HASH=$(hash_now_e)
mv "$TRACK_E.e3bak" "$TRACK_E"
assert_eq "denylist-E3: the change-set hash was computed" "yes" \
    "$([ -n "$E3_CLEAN_HASH" ] && echo yes || echo no)"
assert_eq "denylist-E3: appending the artifact MOVES the hash (the R2-F5 consequence)" \
    "differs" \
    "$([ -n "$E3_POLLUTED_HASH" ] && [ "$E3_POLLUTED_HASH" != "$E3_CLEAN_HASH" ] && echo differs || echo same)"
assert_eq "denylist-E3: ...and removing it again restores the ORIGINAL hash (nothing else moved)" \
    "$E3_CLEAN_HASH" "$(hash_now_e)"

# ...and the GATE agrees with the hash, which is the whole point of one shared
# lib. Same tracker, no reseeding: the Stop hook runs its own reconcile at the
# top of the detection stage, so this reads the union the gate really sees.
#
# ASSERTED AGAINST `changed_files`, NOT AGAINST THE WHOLE REASON TEXT, and the
# distinction is not pedantry — it was measured. The block reason also carries a
# J18 `diff_summary` field built from `git diff --stat HEAD`
# (compute_intent_payload, verify-before-stop.sh:768-770), which summarises the
# RAW diff and therefore does mention `.beads/interactions.jsonl` when that file
# is dirty. That field is advisory context for the LLM's review-pass choice; it
# certifies nothing. `changed_files` is the certification surface, and it is
# built from the TRACKER — which is precisely why fixing rule 2 at the WRITER
# rather than at each reader closes this site too, without it needing its own
# filter. (Three readers were enumerated in QA's R2-F5; this is a fourth.)
E3_REASON=$(stop_reason "$FE")
# reason_changed_files — the authoritative change-set list, extracted from the
# embedded J18 payload. Compact one-line JSON by construction (`jq -nc`), so a
# single greedy match is safe.
reason_changed_files() {
    printf '%s' "$1" | grep -o '{"changed_files":.*}' | head -1 \
        | jq -r '.changed_files[]?' 2>/dev/null
}
E3_FILES=$(reason_changed_files "$E3_REASON")
assert_eq "denylist-E3: the gate's changed_files was extracted (payload present)" "yes" \
    "$([ -n "$E3_FILES" ] && echo yes || echo no)"
assert_contains "denylist-E3: the gate's changed_files names the reviewable source path" \
    "$E_SRC_REL" "$E3_FILES"
assert_not_contains "denylist-E3: ...and does NOT name the review artifact" \
    "review-artifact-cwp-94d-r1.json" "$E3_FILES"
assert_not_contains "denylist-E3: ...and does NOT name bd's interaction log" \
    "interactions.jsonl" "$E3_FILES"
# ANTI-OVERREACH on the gate side, mirroring E2's boundary: the committed ledger
# is still reviewable, so it MUST appear.
assert_contains "denylist-E3 BOUNDARY: ...but DOES name .beads/issues.jsonl (reviewable)" \
    ".beads/issues.jsonl" "$E3_FILES"
# The human-facing list in the reason prose must agree with the payload.
assert_contains "denylist-E3: the block reason's own file list names the source path too" \
    "$E_SRC_REL" "$E3_REASON"

[ "$FAIL" -eq 0 ]
