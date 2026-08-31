#!/bin/bash
# PostToolUse Hook: Tracks file changes for QA review, updates Beads.
#
# Phase 1 changes (claude-workflow-plugin-y4a.5):
#   - B5: emit a valid hookSpecificOutput JSON envelope (not raw markdown).
#   - B6: replace narrow extension allowlist with a denylist over build/lock
#         artifacts; everything else (.md/.json/.yaml/.toml/.tf/.proto/etc.)
#         is tracked.
#   - B9: race-safe dedup using flock when available; otherwise append and
#         rely on `sort -u` at read time. No user prompts.
#   - B10: edit-count is reset by session-start.sh so the every-10-edits
#         cadence resets per session.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
INPUT=$(cat)
# 94d: `.notebook_path` is NotebookEdit's path field — the tool carries neither
# `file_path` nor `path`, so before this the hook matched on the event and then
# extracted nothing, emitted `{}`, and every notebook edit stayed out of the
# tracker AND out of the change-set hash. Bash is deliberately NOT handled here:
# `tool_input.command` carries no path field at all, so no extraction can exist
# for it; that class is reconciled from `git status` by
# `qa-gate.sh reconcile-tracker` instead — PARTIALLY, and the boundary matters:
# that reconcile subtracts the gate baseline over raw porcelain lines, so it
# folds in a Bash-written path that was CLEAN at baseline capture and misses a
# second write to a path the baseline already lists (qa-gate.sh's
# reconcile_tracker header, KNOWN LIMITS; claude-workflow-plugin-dpe). Edits
# through THIS hook are unaffected: the baseline is never consulted here.
#
# THE FIELD NAME IS MEASURED, NOT ASSUMED (fkm.1.15 review). The published hooks
# reference documents `tool_input` per tool but never mentions NotebookEdit, so
# the source is the shipping runtime: Claude Code 2.1.221 (BUILD_TIME
# 2026-08-03T03:19:26Z, GIT_SHA 6efaf12e) declares the tool's input as
# `strictObject({notebook_path: string().describe("The absolute path to the
# Jupyter notebook file to edit (must be absolute, not relative)"), cell_id: …})`
# and constructs every hook payload as `{tool_name: <call>.name, tool_input:
# <call>.input, tool_use_id: …}`. So `tool_input` IS the validated tool input
# object, and `notebook_path` is the only spelling a NotebookEdit payload can
# carry — `strictObject` rejects `file_path` as an alias rather than accepting
# it. Both strings are present in the installed binary (`strings` + grep
# re-confirms on any newer release); the spec's 11a leg proves this hook READS
# the field, which is a different claim from the runtime SENDING it, and this
# note is the second half.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty' 2>/dev/null || echo "")

# sync-errors.log: surface silently-failing best-effort calls so SessionStart
# can present them. Mirrors the pattern in verify-before-stop.sh / B11.
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[post-edit]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# F3 (Phase 4 fix pass): single source of truth for active task id. The
# previous implementation fell back to `bd list --status in_progress |
# jq .[0].id` when the helper file was empty; that defeats F3 entirely
# under parallel epics. New contract: empty helper file means "no active
# task" — we skip the per-10-edits comment rather than guessing.
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        # i8cx: scoped pipefail — without it, a failing `head` (file vanishes
        # mid-read, permission race) is masked by `tr`'s trivial success on
        # whatever partial bytes arrived, and a truncated task id could
        # coincidentally still look shape-valid downstream. Safe to scope
        # here: neither head nor tr has an "expected nonzero" case.
        tid=$( set -o pipefail; head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' ) || tid=""
    fi
    printf '%s' "$tid"
}

# Always emit a valid response (B5 / E9 standardisation). The PostToolUse
# hooks reference allows either `{}` (no-op) or
# `{"hookSpecificOutput":{"hookEventName":"PostToolUse",
# "additionalContext":"..."}}` (context injection). We use `{}` because
# this hook only tracks state — the Stop hook surfaces the review context.
emit_empty() { echo '{}'; }

if [ -z "$FILE_PATH" ]; then
    emit_empty; exit 0
fi

# B6: denylist (regex against the path). Anything not matched is tracked.
#
# 3mg.1: the regex now lives in ONE place, shared with impact-report.sh (what
# enters the change-set hash) and verify-before-stop.sh (what needs review).
# Resolved relative to THIS script (BASH_SOURCE), not $PROJECT_DIR — a hook
# may run with CLAUDE_PROJECT_DIR pointing at a different checkout than the
# install it lives in.
#
# Missing lib: TRACK ANYWAY. Over-tracking is the fail-closed side for a hook
# whose output feeds the gate — an untracked edit is an edit the Stop gate
# never sees, while an over-tracked one merely costs a review look. We still
# emit the `{}` envelope so the hook never blocks the user (advisory hook).
_WFDL_DIR=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd) || _WFDL_DIR=""
if [ -n "$_WFDL_DIR" ] && [ -f "$_WFDL_DIR/workflow-denylist.sh" ]; then
    # shellcheck source=.claude/scripts/workflow-denylist.sh
    . "$_WFDL_DIR/workflow-denylist.sh"
fi
if [ -n "${WORKFLOW_DENYLIST_REGEX:-}" ]; then
    DENYLIST_REGEX="$WORKFLOW_DENYLIST_REGEX"
    if [[ "$FILE_PATH" =~ $DENYLIST_REGEX ]]; then
        emit_empty; exit 0
    fi
else
    log_sync_error "workflow-denylist.sh missing or empty (looked in ${_WFDL_DIR:-<unresolvable script dir>}); tracking '$FILE_PATH' with NEITHER filter applied — not the path denylist and not the self-written rule (over-tracking is the fail-closed side for the gate)"
fi

# SELF-WRITTEN-FILTER BEGIN (94d)
# THE SECOND RULE FROM THE SAME LIB, and it has to be applied HERE — at the
# point paths ENTER changed-files.txt — because this is where they originate.
#
# The lib names `.claude/.qa-tracking/**` ("the tracker, the baseline, the
# impact report, THE REVIEW ARTIFACTS") and `.beads/interactions.jsonl` as paths
# the workflow rewrites as a side effect of running, and defines
# workflow_self_written as "keep it OUT of the change set". Until 94d/R2-F5 this
# hook applied only WORKFLOW_DENYLIST_REGEX, so that stated intent held on every
# route into the tracker EXCEPT the primary one. Three consequences, all from
# this single missing filter — which is why the repair is here and not at any of
# the three symptom sites:
#
#   1. THE HASH ABSORBED IT. impact-report.sh hashes the denylist-filtered
#      TRACKER (canonical_changed_files), so a Write-tool edit to
#      .claude/.qa-tracking/ moved change_set_hash. DEMONSTRATED, not reasoned:
#      QA writing its own review artifact to the path qa.md 6p.2 prescribes took
#      the tracker 23 -> 24 paths and the hash abe62c33… -> 752729a4…, after
#      which `qa-gate.sh approve` refused exit 2 error_key=impact_report_stale
#      against the report `enter` had just generated. Every Claude-lane review
#      round paid that, deterministically.
#   2. THE STOP DETECTOR REPORTED IT. reviewable_changes()'s TRACKER half gates
#      on the denylist alone; the rule was applied to its GIT half only. So the
#      gate's own artifact made an otherwise doc-only change set MIXED and killed
#      the F1 fast path — the exact disagreement class the rule was introduced to
#      end, arriving through post-edit instead of the git walk.
#   3. THE TWO WRITERS DISAGREED. qa-gate.sh's reconcile_tracker already refuses
#      to append these paths. One file, two writers, two different filters.
#
# NOT the fix, deliberately: having callers write their artifacts with a Bash
# redirect instead of the Write tool. That is only what HID the defect (round 1
# built its review request with `jq -n … > "$REQ"`, which this hook does not see;
# codex-review.sh writes its artifact by redirect too, which is why the Sol lane
# was immune and the Claude lane was not). It leaves the defect in place and makes
# correctness depend on every future writer picking the right tool.
#
# WHY THIS IS NOT ALSO ADDED TO reviewable_changes()'s tracker half or to
# impact-report.sh: the tracker is the hash's INPUT, and both of those read it.
# Filtering at a reader would make that reader disagree with the other readers
# about a self-written path a PREVIOUS install had already recorded — which is
# the "hash and gate disagree about what the changes are" failure the shared lib
# exists to prevent. Filtering at the writer keeps every reader in agreement by
# construction. Legacy entries already in a tracker stay visible to all of them
# and are cleared the usual way, by approve's truncation.
#
# The `-n` guard stays, but NOT for the reason this comment used to give (QA
# finding R3-F2 / fkm.1.16). It claimed `set -e` would abort the hook on a
# "command not found" with the lib absent. It would not: bash exempts the
# commands in an `if` CONDITION from errexit. Measured on bash 3.2.57 — an
# undefined `workflow_self_written` prints one "command not found" line on
# stderr, evaluates FALSE, and the hook continues and tracks the path (rc 0,
# envelope intact). That is already the documented missing-lib behaviour above
# ("TRACK ANYWAY"), so removing the guard would change no control flow.
#
# What the guard actually buys, both real:
#   1. STDERR HYGIENE. Without it, an install missing the lib prints that line on
#      EVERY edit from a hook whose stdout is a JSON envelope. The condition
#      is already reported once, deliberately, via log_sync_error above.
#   2. IT DOCUMENTS THE RULE-2 COUPLING. The regex and the function must arrive
#      together, from the lib. Note the asymmetry, because it is a live hazard:
#      this tests the REGEX variable and calls the FUNCTION, so a refactor that
#      renamed the variable alone would silently turn the filter into a no-op.
#      What catches that is denylist-source.test.sh assertion 1, which pins both
#      halves by name (:194-197) and says so.
# Same shape verify-before-stop.sh uses at its git half (:453) — that one never
# carried the false mechanism, only this copy did.
if [ -n "${WORKFLOW_SELF_WRITTEN_REGEX:-}" ] && workflow_self_written "$FILE_PATH"; then
    emit_empty; exit 0
fi
# SELF-WRITTEN-FILTER END (94d)

# CONTAINMENT-FILTER BEGIN (fkm.1.15)
# THE THIRD RULE, and the second half of the acceptance list this hook was
# rewritten for. The 2026-07-29 15:52 bug report on 94d closes with two numbered
# items: (1) reconcile the tracker against `git status` — shipped as
# `qa-gate.sh reconcile-tracker`; (2) "drop paths outside CLAUDE_PROJECT_DIR at
# record time" — this block. Item (2) went unshipped and unmentioned across four
# review rounds by two reviewers until the rubric grader read the acceptance list
# back, which is why it lands under its own id.
#
# The two items are the two directions of ONE defect. Item (1) was
# under-coverage: git-visible work no Write/Edit hook recorded, so the hash
# certified LESS than the diff. This is over-coverage: `$FILE_PATH` is recorded
# VERBATIM, so the change set was never bounded by the project at all, and the
# hash certified paths that are not part of the work. Measured before the fix,
# six shapes all TRACKED: a bare `/tmp/enc-diff.sh`, a path in a different repo,
# an agent's `mktemp -d` probe, a lexical `..` escape, `/etc/hosts`, and
# `~/.claude/settings.json`.
#
# WHAT IT COST, from the report: a QA scratch file at `/tmp/enc-diff.sh`, written
# with the Write tool, moved change_set_hash a950fa6b… -> cb000516…, after which
# `qa-gate.sh approve` refused the CORRECT impact report as stale. The reviewer
# had to hand-edit the tracker. Two further recorded instances were
# `/tmp/qa-p5n-probe/`-shaped. And such a path is not merely noise in the hash:
# `impact-report.sh:502` already records it `ok:false` ("outside the analyzed
# project … cannot be in this project code-graph index"), and a reviewer's
# `git diff` over the tracker paths cannot show it either. It is an entry that
# moves the certification while being unreviewable BY CONSTRUCTION.
#
# WHY AT THE WRITER, AND WHY NOT IN THE SHARED LIB (three reasons, not taste):
#   1. ONE APPLIER, BY CONSTRUCTION. The tracker has two writers. The other,
#      `qa-gate.sh`'s reconcile_tracker, derives its paths from
#      `git status --porcelain` inside the repo, so it CANNOT emit an
#      out-of-project path — there is no second applier for the lib to serve.
#   2. THE READERS MUST NOT APPLY IT. Identical argument to rule 2's, at
#      :143-150 above; it is not restated here. Filtering at a reader would make
#      that reader disagree with the others about an out-of-project entry an
#      older install already recorded.
#   3. IT IS NOT A PATH PATTERN. Rules 1 and 2 are EREs and answer the same way
#      in every checkout; this one compares against a RUNTIME root. The lib is
#      deliberately root-agnostic — every consumer sources it BASH_SOURCE-relative
#      precisely so it never depends on $CLAUDE_PROJECT_DIR (3mg.2: the primary's
#      hook legitimately runs with that variable pointing at a worktree).
#
# THIS IS NOT THE `/tmp` DENYLIST WIDENING THE LIB REFUSES, and the distinction
# is mechanical. The lib's "WHAT IS DELIBERATELY *NOT* DENYLISTED" block rejects
# a /tmp or /var/folders branch because `specs/impact-report-paths.sh` and
# `specs/worktree-approval-resolution.sh` SEED changed-files.txt with absolute
# paths rooted at `mktemp -d`'s parent (verified: both write the tracker
# directly, not through this hook) — either pattern would empty both change sets
# and both specs would keep passing while proving nothing. Containment asks a
# different question, "is this path inside the project THIS session is
# certifying?", and for those paths the answer is YES: they sit inside the
# `mktemp -d` root their own fixture points CLAUDE_PROJECT_DIR at. Both /tmp pins
# in denylist-source.test.sh stay green and untouched — they pin the LIB's
# answer, which has not changed.
#
# HOW IT DECIDES, biased to be RELUCTANT to drop (a false drop is the
# under-coverage this task exists to close):
#   - RELATIVE paths are kept, resolved against the root. That is how every
#     reader already interprets a relative tracker entry (impact-report.sh
#     relativises; porcelain hands them relative). The runtime spells these
#     absolute anyway — NotebookEdit's own schema says "must be absolute".
#   - Normalisation is LEXICAL (`.`, `..`, `//` collapsed; no filesystem access),
#     so it works for a path whose file was just deleted, and a `..` escape that
#     is string-prefixed by the root is still caught.
#   - The comparison runs against BOTH spellings of the root — as given, and
#     `pwd -P` — because macOS hands out `/var/folders/…` while the physical path
#     is `/private/var/folders/…`, and either can arrive.
#   - Only if both miss do we resolve the path's OWN ancestry physically and try
#     once more — the DIRNAME's ancestry, with `basename` reattached UNRESOLVED.
#     That is the `SECOND-CHANCE` region below; it covers the converse spelling
#     and a symlinked ancestor, at the cost of one `cd` on the drop path only.
#
# NO SYMLINK IS EVER RESOLVED ON THE KEEP PATH, so a symlink crossing the
# boundary is KEPT IN EITHER DIRECTION. Nothing in this hook follows a link: no
# executable line calls `readlink`, `realpath` or `stat`, and none tests `-L` or
# `-h` (the only occurrences of those words in this file are in comments, this
# sentence included — check the code, not a bare grep). `pwd -P` runs in exactly
# two places, once on `$PROJECT_DIR` to build `_PE_ROOT_PHYSICAL` and once inside
# `SECOND-CHANCE`, and both are `cd <DIRECTORY> && pwd -P` — never the edited
# leaf. Measured on the canonical hook over a scratch tree, all three shapes
# tracked with no log line:
#
#   in-repo DIRECTORY symlink pointing out   $ROOT/dirlink/g.ts   -> TRACKED
#   in-repo FILE symlink pointing out        $ROOT/filelink.ts    -> TRACKED
#   out-of-repo symlink pointing IN          $OUT/inlink/x.ts     -> TRACKED
#
# THIS CORRECTS A FALSE CLAIM THIS COMMENT USED TO MAKE (QA finding R5-F1,
# claude-workflow-plugin-dmi). It said an in-repo symlink whose target is outside
# "resolves to the target and is DROPPED". It is not dropped, and the two in-repo
# shapes are kept by two DIFFERENT mechanisms — which is the part the old claim
# reasoned past:
#   - The FIRST `_pe_within "$_PE_CANDIDATE"` test already answers "inside" for
#     both, because the path is spelled through the root, so `SECOND-CHANCE`
#     never runs at all.
#   - Had it run, the two shapes would still differ: the DIRECTORY symlink's
#     dirname resolves OUTSIDE and would have been dropped, while the FILE
#     symlink's dirname resolves to the root itself and would have been kept
#     regardless — the `_PE_RESOLVED` line reattaches the leaf by NAME, so a leaf
#     symlink's target is never consulted on any path through this region.
#     That counterfactual is ASSERTED, not just reasoned: `specs/post-edit.sh`
#     13R forces this guard true so the retry runs for every path, and the two
#     in-repo shapes then diverge — the DIRECTORY symlink drops, the FILE symlink
#     stays tracked, with the retry region byte-identical and every control
#     holding. 13N cannot say that (it shows only that neither shape REACHES the
#     retry, which is symmetric); claiming otherwise was QA finding R4-F3.
# The surviving residual is narrower than "macOS only", which is what the fix
# round shipped as its largest unknown. The shape that reaches the retry is a
# symlink crossing the project boundary, and nothing about it depends on the
# `/private` spelling macOS produces: the region carries no platform conditional,
# and `cd <symlink> && pwd -P` is POSIX. So the retry is not macOS-only — but
# STATED PRECISELY, this was measured on darwin only; 13e's third leg is the
# assertion that will run it on whatever CI uses. (13a's `CT_PHYS` leg IS the
# macOS-specific one, and it exercises `_PE_ROOT_PHYSICAL`, a different path
# through this region.) Pinned by `specs/post-edit.sh` 13e (the three keeps),
# 13N, whose META excises the `SECOND-CHANCE` region alone and flips the
# out-of-repo-symlink leg to dropped with every control holding, and 13R, which
# forces the guard instead of excising the region and separates the two in-repo
# shapes from each other.
#
# NO LINE NUMBERS ABOVE, deliberately. The first draft of this correction cited
# the three sites by line, and its own insertion had already invalidated all
# three — one more false claim, inside the comment correcting the last one, caught
# only by re-measuring before reporting. Anchor on sentinel and identifier names,
# which move with the code. Same rule LESSONS.md carries for mutation METAs,
# applied to prose.
#
# The over-tracking this leaves is the fail-closed side for a hook that feeds the
# gate, per the paragraph below, so the DOCUMENTED limit was corrected to match
# the code rather than the code changed to match the limit.
#
# FAIL-OPEN when the root itself is unresolvable: track and log. Over-tracking is
# the fail-closed side for a hook that feeds the gate, exactly as for the missing
# lib at :89-92. And the DROP is LOGGED, always: an untracked edit is an edit the
# Stop gate never sees, so this rule must never remove a path silently. That is
# what makes it different from rules 1 and 2, which drop known-inert classes.
_PE_NORM=""
# _pe_norm <path> — lexically normalised path into $_PE_NORM. Writes a global
# rather than stdout: this runs on every edit and a command substitution would
# cost a fork per call. No word splitting (a segment containing a glob character
# would otherwise be expanded), no external process, bash 3.2 safe.
_pe_norm() {
    local rest="$1" out="" seg
    while [ -n "$rest" ]; do
        seg="${rest%%/*}"
        if [ "$seg" = "$rest" ]; then rest=""; else rest="${rest#*/}"; fi
        case "$seg" in
            ''|.) ;;
            ..)   out="${out%/*}" ;;
            *)    out="$out/$seg" ;;
        esac
    done
    _PE_NORM="${out:-/}"
}

# _pe_within <normalised-path> — 0 when it is the project root or under it, for
# either spelling of the root. The `/` case is not decoration: with a root of `/`
# the `"$r"/*` pattern would be `//*` and match nothing.
_pe_within() {
    local p="$1" r
    for r in "$_PE_ROOT_LOGICAL" "$_PE_ROOT_PHYSICAL"; do
        [ -n "$r" ] || continue
        [ "$r" = "/" ] && return 0
        case "$p" in
            "$r"|"$r"/*) return 0 ;;
        esac
    done
    return 1
}

_PE_ROOT_LOGICAL=""
case "$PROJECT_DIR" in
    # A relative CLAUDE_PROJECT_DIR has no meaning to compare an absolute path
    # against; the physical spelling below is then the only usable root.
    /*) _pe_norm "$PROJECT_DIR"; _PE_ROOT_LOGICAL="$_PE_NORM" ;;
esac
_PE_ROOT_PHYSICAL=$(cd "$PROJECT_DIR" 2>/dev/null && pwd -P) || _PE_ROOT_PHYSICAL=""

if [ -z "$_PE_ROOT_LOGICAL" ] && [ -z "$_PE_ROOT_PHYSICAL" ]; then
    log_sync_error "project root '$PROJECT_DIR' could not be resolved (CLAUDE_PROJECT_DIR unset or gone); tracking '$FILE_PATH' with NO containment check applied — over-tracking is the fail-closed side for the gate"
else
    case "$FILE_PATH" in
        /*) _pe_norm "$FILE_PATH" ;;
        *)  _pe_norm "${_PE_ROOT_LOGICAL:-$_PE_ROOT_PHYSICAL}/$FILE_PATH" ;;
    esac
    _PE_CANDIDATE="$_PE_NORM"
    if ! _pe_within "$_PE_CANDIDATE"; then
        # Initialised OUTSIDE the sentinels deliberately: with the region excised
        # (the 13N META) _PE_RESOLVED must still be the EMPTY STRING and not
        # UNSET, so the drop below fires for a stated reason rather than resting
        # on this hook never gaining `set -u`. Moving it here is a reordering of
        # one initialisation and changes no behaviour — nothing between here and
        # the `if` reads it.
        _PE_RESOLVED=""
        # SECOND-CHANCE BEGIN (fkm.1.15)
        # Second chance before dropping: resolve the path's own ancestry. The
        # DIRNAME's ancestry, physically — the leaf is reattached by NAME on the
        # next line and never followed, which is why a symlinked FILE pointing
        # out of the repo is kept rather than dropped (see the header).
        #
        # This branch is the ONLY thing an out-of-repo symlink pointing INTO the
        # project reaches, and it is the whole behavioural consequence of the
        # branch: `specs/post-edit.sh` 13N excises exactly this region and that
        # one leg flips TRACKED -> dropped while every control holds. Keep the
        # sentinels; they are what makes that META line-number-independent.
        _PE_DIR=$(cd "$(dirname "$_PE_CANDIDATE")" 2>/dev/null && pwd -P) || _PE_DIR=""
        [ -n "$_PE_DIR" ] && _PE_RESOLVED="${_PE_DIR%/}/$(basename "$_PE_CANDIDATE")"
        # SECOND-CHANCE END (fkm.1.15)
        if [ -z "$_PE_RESOLVED" ] || ! _pe_within "$_PE_RESOLVED"; then
            log_sync_error "'$FILE_PATH' is OUTSIDE the project root '$PROJECT_DIR' and was NOT tracked (fkm.1.15, acceptance item 2 of the 2026-07-29 report). An out-of-project entry moves change_set_hash — one recorded instance staled the impact report and made \`approve\` refuse it — and no reviewer can git-diff it. If this file is a deliverable it belongs inside the repo; if it is a throwaway probe, write it to the session scratchpad or .claude/.qa-tracking/, which the two earlier rules already filter."
            emit_empty; exit 0
        fi
    fi
fi
# CONTAINMENT-FILTER END (fkm.1.15)

mkdir -p "$QA_TRACKING_DIR"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
LOCK_FILE="$QA_TRACKING_DIR/.changed-files.lock"

# B9: race-safe append. Two strategies:
#   - flock available: take an exclusive lock around dedup-then-append.
#   - no flock: append unconditionally; readers always `sort -u` (callers
#     already do, see verify-before-stop.sh and the unique count below).
append_dedup_locked() {
    # Run under flock. Stdin/stdout already inherited.
    if [ ! -f "$TRACKING_FILE" ] || ! grep -qxF "$FILE_PATH" "$TRACKING_FILE" 2>/dev/null; then
        printf '%s\n' "$FILE_PATH" >> "$TRACKING_FILE"
    fi
}

if command -v flock >/dev/null 2>&1; then
    # flock takes a file descriptor; open the lock fd and run under it.
    (
        flock -x 9
        append_dedup_locked
    ) 9>"$LOCK_FILE"
else
    # No flock available (e.g., macOS without coreutils). Append blindly;
    # readers normalize via `sort -u`. This trades a small amount of disk
    # for guaranteed safety with no prompts.
    printf '%s\n' "$FILE_PATH" >> "$TRACKING_FILE"
fi

# Cap tracking file size at 500 unique lines (also race-tolerant: we only
# trim if the current file is over 2x that threshold so concurrent appenders
# don't lose data).
#
# 94d: THE NO-FLOCK BRANCH IS GONE, AND THE TRIM IS NOW FLOCK-ONLY. The trim is
# a read-modify-write (`sort -u | tail -500 > tmp && mv`) whose failure mode is
# LOSING TRACKED PATHS: any append landing between the read and the `mv` is
# discarded, and a discarded path is a file the Stop gate never sees and the
# change-set hash never covers — the exact class of under-coverage this task
# closes. Under flock that window is closed against the other writers of this
# file (this hook's own append and qa-gate.sh's reconcile_tracker, which takes
# the same lock). Without flock there is no way to close it, so we skip the trim
# and let the file grow: an oversized tracker costs disk and a longer readout,
# while a lost path costs an unreviewed change. macOS ships no flock, so this is
# the LIVE path on a dev box, not a theoretical one — the skip is logged rather
# than silent so an operator who ever does see a huge tracker can find out why.
if [ -f "$TRACKING_FILE" ]; then
    # i8cx: scoped pipefail on the count feeding the trim-threshold check. A
    # masked `wc` failure here already degraded SAFE (empty -> `${LINE_COUNT:-0}`
    # reads as 0 -> trim skipped, never triggered wrongly) but a failing `wc`
    # whose PARTIAL bytes `tr` still transforms could in principle emit a
    # garbled-but-numeric-looking string instead of empty; guard closes that.
    LINE_COUNT=$( set -o pipefail; wc -l < "$TRACKING_FILE" 2>/dev/null | tr -d ' ' ) || LINE_COUNT=""
    if [ "${LINE_COUNT:-0}" -gt 1000 ]; then
        if command -v flock >/dev/null 2>&1; then
            (
                flock -x 9
                sort -u "$TRACKING_FILE" | tail -500 > "$TRACKING_FILE.tmp" && mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
            ) 9>"$LOCK_FILE"
        else
            log_sync_error "changed-files.txt is at ${LINE_COUNT} lines and the 500-unique trim was SKIPPED: flock is not on PATH, and the trim is a read-modify-write that would silently drop any path appended during it (a dropped path is an unreviewed change). Install flock (util-linux) to re-enable trimming, or truncate the tracker yourself at a point where no edit is in flight."
        fi
    fi
fi

# Update Beads task with progress (batched to avoid spam).
if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    EDIT_COUNT_FILE="$QA_TRACKING_DIR/edit-count"
    EDIT_COUNT=$(cat "$EDIT_COUNT_FILE" 2>/dev/null || echo "0")
    EDIT_COUNT=$((EDIT_COUNT + 1))
    echo "$EDIT_COUNT" > "$EDIT_COUNT_FILE"

    if [ $((EDIT_COUNT % 10)) -eq 0 ]; then
        CURRENT_TASK=$(get_current_task)
        if [ -n "$CURRENT_TASK" ]; then
            UNIQUE_COUNT=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d ' ')
            (bd comments add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited" >/dev/null 2>&1 \
                || bd comment add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited" >/dev/null 2>&1) \
                || log_sync_error "bd comments add failed for $CURRENT_TASK (progress comment, $UNIQUE_COUNT files)"
        fi
        # If CURRENT_TASK is empty here we don't log on every edit — only
        # the Stop hook surfaces "no active task" since edit-volume noise
        # would dominate sync-errors.log.
    fi
fi

# Per principle (Phase 1 cosmetic): the additionalContext is informational
# only. We choose the simplest valid response — `{}` — and let the Stop hook
# surface the full review context. (B5 alternative: keep an envelope but no
# user-facing markdown.)
emit_empty
