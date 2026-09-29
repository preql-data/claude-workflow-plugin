#!/bin/bash
# Statusline (Phase 5 / E4 + I2).
#
# Reads:
#   - .claude/.qa-tracking/current-task     (single source of truth, F3)
#   - bd labels for that task               (qa: pending|approved|blocked|gate-entered|none)
#   - .claude/.qa-tracking/changed-files.txt (file count)
#
# Output (single line):
#   [<task-id>] qa: <state> • N files changed
# When no current-task:
#   (no active task) — N files changed
# When bd unavailable:
#   (bd unavailable) — N files changed
#
# Wired via .claude/settings.json `statusLine` field. Per the Claude Code
# docs (https://docs.claude.com/en/docs/claude-code/statusline), the script
# receives a JSON envelope on stdin describing the session.
#
# v5.0.0 Phase D0: that envelope is now READ rather than drained, because it
# is THE ONLY PLACE the live session model is observable. session-start.sh
# never reads stdin, so the session-model guard has nowhere else to live — see
# the SESSION-MODEL GUARD block below.

set -e

# Capture stdin (don't error if there's nothing, and never block a render on
# it). Everything downstream treats an empty or unparseable envelope as "no
# information", never as evidence of anything.
STDIN_JSON=$(cat 2>/dev/null || true)

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
ORCH_AGENT_FILE="$PROJECT_DIR/.claude/agents/orchestrator.md"
# v4.0.0 Phase V1 (bi3.1): the resolved role->model mapping written by
# model-select.sh apply. Artifact-first render; absent/unparseable falls
# back to today's single orchestrator.md pin (visual v3.5 parity).
ROLES_ARTIFACT="$QA_TRACKING_DIR/model-roles-resolved.json"
# v5.0.0 Phase D0 state files. All three are READ here; only the drift record
# is written, and only when its content would change (see the guard block).
ESCALATION_STATE="$QA_TRACKING_DIR/implementer-escalation.json"
SESSION_DRIFT_FILE="$QA_TRACKING_DIR/session-model-drift.json"

# ROLE_ORDER — the FIXED statusline render order and its short labels, as
# `<role>:<label>` pairs. Order is load-bearing: it decides which group is
# printed first (a group's position is its FIRST member's position here), so
# it must match ALL_ROLES in model-select.sh.
ROLE_ORDER="designer:des design_reviewer:dsr orchestrator:orch implementer:impl reviewer:rev"

# MAX_GROUPS — how many distinct model groups are printed before the render
# collapses the tail into ` +<k> more`. The statusline shares one line with
# the task id, the QA state, the rubric state and the file count, so this is a
# width budget, not a preference.
MAX_GROUPS=3

# Hotfix vlp.1: read the active model pin from orchestrator.md frontmatter
# (no network). All seven agent pins are kept in lockstep by
# workflow-model-apply.sh, so reading one is sufficient. We surface this
# in the statusline so the operator can see at-a-glance which model is
# active for the current session — closes the principle-1 visibility gap
# called out in the hotfix plan.
read_model_pin() {
    [ -f "$ORCH_AGENT_FILE" ] || { printf ''; return; }
    local pin
    pin=$(grep -E '^model:' "$ORCH_AGENT_FILE" 2>/dev/null | head -1 | awk '{print $2}')
    printf '%s' "$pin"
}

# short_id <model-id> — compact a model id for the statusline: strip the
# leading `claude-`, strip a trailing `-2NNNNNNN` release-date suffix
# (preserving any `[1m]` context-window marker), and hard-cap at 16 chars.
# Examples: claude-opus-4-8 -> opus-4-8; claude-opus-4-8[1m] -> opus-4-8[1m];
# claude-opus-4-20260514 -> opus-4; claude-opus-4-20260514[1m] -> opus-4[1m].
short_id() {
    local id="$1"
    id="${id#claude-}"
    id=$(printf '%s' "$id" | sed -E 's/-2[0-9]{7}(\[1m\])?$/\1/')
    if [ "${#id}" -gt 16 ]; then
        id="${id:0:16}"
    fi
    printf '%s' "$id"
}

# ---------------------------------------------------------------------------
# SESSION-MODEL GUARD (v5.0.0 Phase D0)
#
# The root session IS the orchestrator seat, so it should run whatever the
# `orchestrator` role class resolved to. Nothing anywhere else can check that:
# the live session model appears ONLY in this script's stdin envelope, and
# session-start.sh — the natural place for a warning — never reads stdin.
#
# So the comparison happens here and the RESULT is persisted, for
# session-start.sh's Warning 8 to re-validate and report next session.
#
# READ-COMPARE-WRITE ONLY. This script runs on EVERY render. Writing a
# timestamped record each time would churn the file dozens of times a minute
# and make its mtime meaningless, so the record is rewritten only when the
# (expected, live) pair it holds would actually change, and removed only when a
# real, completed comparison says there is no drift.
#
# NEVER BLOCKS, and never guesses. An absent envelope, an absent `.model.id`,
# an absent artifact or a missing jq all mean "no comparison was possible" —
# which is NOT the same as "no drift", so those paths leave any existing record
# exactly as they found it rather than clearing it on no evidence.
#
# THE COMPARISON IS BY MODEL IDENTITY, NOT BY ID STRING (QA R1-F4). It shipped
# as literal string equality, and that made the 1M-context variant of the
# CORRECT model read as drift forever: a session on `claude-fable-5[1m]` against
# a resolved `claude-fable-5` lit `!sess` permanently and printed a fix line
# telling the operator to move to a SMALLER context window. Reproduced by
# feeding the shipped statusline that envelope; the repo's own drift record
# carried exactly that shape. A guard that is permanently lit for a reason the
# operator should not act on is a guard nobody reads.
#
# So a trailing bracketed context-window marker (`[1m]`) is separated from the
# base id, and the rule is deliberately ASYMMETRIC — see session_model_matches.
# A flat "strip the suffix from both sides" would also have deleted a TRUE
# positive: pick_best sorts by `_ctx` DESC, so the resolver CAN legitimately
# resolve to `claude-fable-5[1m]`, and a session on the bare id then really is
# not on what was resolved — with an actionable fix line naming the variant.
#
# Residual, stated rather than papered over: an id whose SHAPE differs from the
# resolved one in any other way (a dated variant, an alias) is still reported as
# drift. That remains the honest answer — this hook cannot know an alias resolves
# to the same weights — and the fix line names the exact id, so acting on it is
# one command either way.
# ---------------------------------------------------------------------------

# live_session_model — the session model id from the stdin envelope, or empty
# when there is no envelope, no jq, or no `.model.id`.
live_session_model() {
    [ -n "$STDIN_JSON" ] || { printf ''; return 0; }
    command -v jq >/dev/null 2>&1 || { printf ''; return 0; }
    printf '%s' "$STDIN_JSON" | jq -r '.model.id // empty' 2>/dev/null || printf ''
}

# session_model_matches <expected> <live> — 0 when <live> IS the model
# <expected> names, 1 when it is a different model. Never writes anything.
#
# The rule, in the order it is applied:
#   1. identical ids                      -> match (the common case);
#   2. different BASE ids                 -> drift (a different model);
#   3. same base, and <expected> named NO variant -> match. The resolver
#      expressed no context-window preference, so a session on a variant of
#      that model cannot be violating one. THIS IS THE R1-F4 CASE;
#   4. same base, and <expected> DID name a variant -> drift. `pick_best`
#      sorts `_ctx` DESC, so a resolved `…[1m]` was a deliberate pick and a
#      session on the bare id (or another variant) is genuinely not on it —
#      and the fix line names the variant, which is actionable.
#
# Rule 4 is why this is not the flat both-sides strip: that would have made
# rules 3 and 4 the same answer and deleted a true positive to fix a false one.
#
# "Variant" is exactly a trailing bracketed marker (`claude-fable-5[1m]`), the
# only shape the runtime and the /v1/models listing use — short_id already
# treats it as one. `${x%%\[*}` is the bash 3.2-safe way to cut at the first
# `[`; the backslash is required, or the `[` opens a bracket expression.
session_model_matches() {
    local expected="$1" live="$2" exp_base live_base
    if [ "$expected" = "$live" ]; then
        return 0
    fi
    exp_base="${expected%%\[*}"
    live_base="${live%%\[*}"
    if [ "$exp_base" != "$live_base" ]; then
        return 1
    fi
    if [ "$exp_base" = "$expected" ]; then
        return 0
    fi
    return 1
}

# evaluate_session_model <expected-orchestrator-id> — print "1" when the live
# session model differs from <expected>, "" otherwise (including every
# cannot-compare case). Maintains $SESSION_DRIFT_FILE per the contract above.
evaluate_session_model() {
    local expected="$1" live rec_expected rec_live
    live=$(live_session_model)

    if [ -z "$live" ] || [ -z "$expected" ]; then
        # No comparison was possible. Leave any existing record alone.
        printf ''
        return 0
    fi

    if session_model_matches "$expected" "$live"; then
        # A completed comparison found no drift: a stale record is now wrong,
        # so clear it — but only if one exists (no write on the common path).
        # This is also the path that clears a record left by the pre-R1-F4
        # comparison, so an operator who was told to shrink their window and
        # ignored the advice gets the false record removed on the next render.
        [ -f "$SESSION_DRIFT_FILE" ] && rm -f "$SESSION_DRIFT_FILE" 2>/dev/null
        printf ''
        return 0
    fi

    # Drift. Rewrite only when the recorded pair differs from this one.
    rec_expected=""
    rec_live=""
    if [ -f "$SESSION_DRIFT_FILE" ] && command -v jq >/dev/null 2>&1; then
        rec_expected=$(jq -r '.expected // empty' "$SESSION_DRIFT_FILE" 2>/dev/null || true)
        rec_live=$(jq -r '.live // empty' "$SESSION_DRIFT_FILE" 2>/dev/null || true)
    fi
    if [ "$rec_expected" != "$expected" ] || [ "$rec_live" != "$live" ]; then
        mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
        if jq -n --arg e "$expected" --arg l "$live" \
            --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{expected:$e, live:$l, observed_at:$ts,
              fix:("/model " + $e + "   (or: make session)")}' \
            > "$SESSION_DRIFT_FILE.tmp" 2>/dev/null; then
            mv "$SESSION_DRIFT_FILE.tmp" "$SESSION_DRIFT_FILE" 2>/dev/null || true
        else
            rm -f "$SESSION_DRIFT_FILE.tmp" 2>/dev/null || true
        fi
    fi
    printf '1'
    return 0
}

# model_flags <identity-collapse> <session-drift> — the trailing ` !esc !id
# !sess` markers, in that fixed order. Empty when none apply.
#
#   !esc   a per-unit implementer escalation is ACTIVE (the state file exists),
#          so the implementer lane is not on its configured strategy.
#   !id    designer and design_reviewer collapsed to one identity.
#   !sess  the live session model differs from the resolved orchestrator id.
model_flags() {
    local collapse="$1" drift="$2" out=""
    [ -f "$ESCALATION_STATE" ] && out="$out !esc"
    [ "$collapse" = "true" ] && out="$out !id"
    [ "$drift" = "1" ] && out="$out !sess"
    printf '%s' "$out"
}

# compute_model_suffix — the " • model: ..." / " • <labels>:<id> ..." segment
# appended to every statusline branch.
#
# Artifact-first, FIVE roles since D0. Rules, in order:
#   1. All present roles share one display value AND both lanes are claude ->
#      collapse to ` • model: <short>` (visual v3.5 parity).
#   2. Otherwise group roles by identical display value, join each group's
#      labels with `+`, and print the groups space-separated in fixed
#      ROLE_ORDER (a group's position is its first member's position).
#   3. At most MAX_GROUPS groups are printed; the tail becomes ` +<k> more`.
#   4. Render over the roles PRESENT in `.roles` — so a leftover THREE-role v4
#      artifact renders exactly as it did before, with no upgrade step. This is
#      the rule that keeps the statusline honest across a version boundary:
#      absent is absent, not an empty label.
#   5. Flags are appended last, in the fixed order `!esc !id !sess`.
#
# A non-claude CODE-review lane substitutes the literal `sol` for that lane's
# id, because on that lane the reviewing identity genuinely is not the Claude
# model the pin names -- codex-review.sh drives it.
#
# THE DESIGN LANE IS DIFFERENT AND DOES NOT DO THIS (claude-workflow-plugin-
# yvpe). No script drives design review through Codex, so a non-claude DESIGN
# lane still means a Claude reviewer; printing `sol` there named a reviewer
# that does not exist and, worse, displayed the designer and its reviewer as
# two distinct identities precisely when they resolve to the same model.
# `design_reviewer` therefore always renders its resolved id.
# Artifact missing/unparseable -> today's orchestrator.md-pin fallback.
compute_model_suffix() {
    local collapse="false" drift="" flags=""
    if [ -f "$ROLES_ARTIFACT" ] && command -v jq >/dev/null 2>&1 \
        && jq -e . "$ROLES_ARTIFACT" >/dev/null 2>&1; then
        local rlane dlane orch_id pair role label id disp
        rlane=$(jq -r '.reviewer_lane // "claude"' "$ROLES_ARTIFACT" 2>/dev/null || true)
        dlane=$(jq -r '.design_reviewer_lane // "claude"' "$ROLES_ARTIFACT" 2>/dev/null || true)
        [ -z "$rlane" ] && rlane="claude"
        [ -z "$dlane" ] && dlane="claude"
        if [ "$(jq -r '.identity_collapse // false' "$ROLES_ARTIFACT" 2>/dev/null || true)" = "true" ]; then
            collapse="true"
        fi
        orch_id=$(jq -r '.roles.orchestrator // empty' "$ROLES_ARTIFACT" 2>/dev/null || true)
        drift=$(evaluate_session_model "$orch_id")
        flags=$(model_flags "$collapse" "$drift")

        # Group in fixed order. Parallel indexed arrays, not an associative
        # array: bash 3.2 is the floor and has none.
        local g_values=() g_labels=() i found total out
        for pair in $ROLE_ORDER; do
            role="${pair%%:*}"
            label="${pair##*:}"
            id=$(jq -r --arg r "$role" '.roles[$r] // empty' "$ROLES_ARTIFACT" 2>/dev/null || true)
            [ -n "$id" ] || continue
            case "$role" in
                reviewer)        [ "$rlane" = "claude" ] && disp=$(short_id "$id") || disp="sol" ;;
                # design_reviewer ALWAYS renders the resolved Claude id, never
                # `sol` (claude-workflow-plugin-yvpe). The `reviewer` arm above
                # is correct because the CODE-review Sol lane is genuinely
                # wired (codex-review.sh drives it). There is NO design
                # equivalent: codex-review.sh has no design handling, and
                # design-reviewer.md instructs the reviewer to emit
                # `design-claude` unconditionally because it cannot read this
                # lane. Rendering `sol` here showed the designer and its
                # reviewer as two distinct identities at exactly the moment
                # they are the SAME model -- asserting the opposite of the
                # truth, continuously, on screen. This arm was copied from the
                # `reviewer` arm, where the conditional does hold.
                design_reviewer) disp=$(short_id "$id") ;;
                *)               disp=$(short_id "$id") ;;
            esac
            found=-1
            i=0
            while [ "$i" -lt "${#g_values[@]}" ]; do
                if [ "${g_values[$i]}" = "$disp" ]; then
                    found=$i
                    break
                fi
                i=$((i + 1))
            done
            if [ "$found" -ge 0 ]; then
                g_labels[found]="${g_labels[found]}+$label"
            else
                g_values+=("$disp")
                g_labels+=("$label")
            fi
        done

        total=${#g_values[@]}
        if [ "$total" -gt 0 ]; then
            if [ "$total" -eq 1 ] && [ "$rlane" = "claude" ] && [ "$dlane" = "claude" ]; then
                printf ' • model: %s%s' "${g_values[0]}" "$flags"
                return 0
            fi
            out=""
            i=0
            while [ "$i" -lt "$total" ] && [ "$i" -lt "$MAX_GROUPS" ]; do
                out="$out ${g_labels[$i]}:${g_values[$i]}"
                i=$((i + 1))
            done
            if [ "$total" -gt "$MAX_GROUPS" ]; then
                out="$out +$((total - MAX_GROUPS)) more"
            fi
            printf ' •%s%s' "$out" "$flags"
            return 0
        fi
    fi
    # Fallback: today's single orchestrator.md pin (unchanged). No artifact
    # means no resolved orchestrator id to compare a session model against, so
    # only the file-derived !esc flag can apply here.
    flags=$(model_flags "false" "")
    local pin
    pin=$(read_model_pin)
    printf ' • model: %s%s' "${pin:-(no model pin)}" "$flags"
}

# ---------------------------------------------------------------------------
# Helpers

# F3 single source of truth read. Mirrors the helper in intent-router.sh and
# verify-before-stop.sh: prefer the helper script, fall back to direct read,
# never fall back to `bd list --status in_progress` (would resurrect the F3
# anti-pattern the gate redesign was meant to eliminate).
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null \
            | tr -d '\r\n[:space:]' || echo "")
    fi
    printf '%s' "$tid"
}

# Count unique tracked file changes (sort -u handles the no-flock B9 path).
count_changed_files() {
    if [ ! -f "$TRACKING_FILE" ]; then
        echo "0"
        return
    fi
    local count
    # `sort -u` + `wc -l` is portable and always exits 0; trim macOS BSD `wc -l` leading spaces.
    count=$(sort -u "$TRACKING_FILE" 2>/dev/null | wc -l | tr -d '[:space:]')
    echo "${count:-0}"
}

# Read a task's QA state from its labels. Returns one of:
#   approved | blocked | gate-entered | pending | none
# Precedence (most decisive first): approved > blocked > gate-entered > pending.
qa_state_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf 'none'; return; }
    if ! command -v bd >/dev/null 2>&1; then
        printf 'bd-unavailable'
        return
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        printf 'no-beads'
        return
    fi
    # `bd show <id> --json` returns either an object or a 1-element array
    # depending on bd version; `// []` and the `.[0].labels else .labels`
    # branch handle both. (Phases 0-4 used the array form; we keep it.)
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo "")
    case ",$labels," in
        *,qa-approved,*)      printf 'approved' ;;
        *,qa-blocked,*)       printf 'blocked' ;;
        *,qa-gate-entered,*)  printf 'gate-entered' ;;
        *,qa-pending,*)       printf 'pending' ;;
        *)                    printf 'none' ;;
    esac
}

# Spec Phase A: read a task's rubric state from its labels. Cheap-only —
# we share the labels string fetched by qa_state_for via the caller's
# RUBRIC_STATE_LABELS variable (see Main). No extra `bd show` call: the
# fetch is already paid for. Returns one of:
#   satisfied | pending | none
# Precedence: satisfied > pending > none. Matches qa-gate.sh status
# precedence (label semantics are the source of truth).
rubric_state_for_labels() {
    local labels="$1"
    case ",$labels," in
        *,rubric-satisfied,*) printf 'satisfied' ;;
        *,rubric-pending,*)   printf 'pending' ;;
        *)                    printf 'none' ;;
    esac
}

# Variant of qa_state_for that ALSO surfaces the labels string so the
# caller can derive rubric state from the same `bd show` response. Returns
# the QA state on stdout and writes the raw labels into the global var
# named in arg 2 (caller passes the variable name). We split the work
# this way to keep qa_state_for's existing signature stable for any
# external consumer and avoid a second `bd show` call.
# Variant of qa_state_for that prints BOTH the QA state AND the raw
# labels string on stdout, separated by a single tab. The caller splits
# the result with `cut -f1` / `cut -f2`. We use this shape instead of a
# pass-by-name variable because `qa_state_for_with_labels` is invoked via
# command substitution — the subshell would discard any eval-into-var
# write. The single `bd show` call is shared between the QA state read
# and the rubric state derivation, so this stays within the cheap-only
# budget (no extra round-trip).
#
# Output shape:
#   <qa-state>\t<labels-csv>
# where <qa-state> is one of {approved, blocked, gate-entered, pending,
# none, bd-unavailable, no-beads} and <labels-csv> is the comma-joined
# label list (or empty when the read failed).
qa_state_for_with_labels() {
    local tid="$1"
    if [ -z "$tid" ]; then
        printf 'none\t'
        return
    fi
    if ! command -v bd >/dev/null 2>&1; then
        printf 'bd-unavailable\t'
        return
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        printf 'no-beads\t'
        return
    fi
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo "")
    local state
    case ",$labels," in
        *,qa-approved,*)      state="approved" ;;
        *,qa-blocked,*)       state="blocked" ;;
        *,qa-gate-entered,*)  state="gate-entered" ;;
        *,qa-pending,*)       state="pending" ;;
        *)                    state="none" ;;
    esac
    printf '%s\t%s' "$state" "$labels"
}

# ---------------------------------------------------------------------------
# Main

CURRENT_TASK=$(get_current_task)
FILE_COUNT=$(count_changed_files)
# Strip whitespace from `wc -l` output on macOS.
FILE_COUNT=$(printf '%s' "$FILE_COUNT" | tr -d '[:space:]')
[ -z "$FILE_COUNT" ] && FILE_COUNT=0

# Hotfix vlp.1 + V1 (bi3.1): compute the model segment once and append it
# to every branch below so visibility is consistent across task-active /
# no-active-task / bd-unavailable states. Artifact-first (role view) with a
# fallback to the single orchestrator.md pin -> "(no model pin)".
MODEL_SUFFIX=$(compute_model_suffix)

if [ -z "$CURRENT_TASK" ]; then
    # No active task — still report file count (useful when changes are
    # accumulating but no task has been claimed yet).
    printf '(no active task) — %s files changed%s\n' "$FILE_COUNT" "$MODEL_SUFFIX"
    exit 0
fi

# Spec Phase A: use the labels-surfacing helper so we can derive the
# rubric state from the SAME `bd show` response — no extra round-trip.
# qa_state_for_with_labels prints "state\tlabels"; split on the tab.
QA_OUT=$(qa_state_for_with_labels "$CURRENT_TASK")
QA_STATE=$(printf '%s' "$QA_OUT" | cut -f1)
RUBRIC_STATE_LABELS=$(printf '%s' "$QA_OUT" | cut -f2-)
RUBRIC_STATE=$(rubric_state_for_labels "$RUBRIC_STATE_LABELS")

case "$QA_STATE" in
    bd-unavailable)
        printf '(bd unavailable) — %s files changed%s\n' "$FILE_COUNT" "$MODEL_SUFFIX"
        ;;
    no-beads)
        printf '[%s] (.beads missing) — %s files changed%s\n' "$CURRENT_TASK" "$FILE_COUNT" "$MODEL_SUFFIX"
        ;;
    *)
        # Surface rubric state only when present (pending/satisfied). The
        # 'none' state means this task pre-dates Phase A or the gate is
        # not yet entered — suppressing it keeps the line short for the
        # common case (intent-router fires before qa-gate enter).
        if [ "$RUBRIC_STATE" = "satisfied" ] || [ "$RUBRIC_STATE" = "pending" ]; then
            printf '[%s] qa: %s • rubric: %s • %s files changed%s\n' \
                "$CURRENT_TASK" "$QA_STATE" "$RUBRIC_STATE" "$FILE_COUNT" "$MODEL_SUFFIX"
        else
            printf '[%s] qa: %s • %s files changed%s\n' \
                "$CURRENT_TASK" "$QA_STATE" "$FILE_COUNT" "$MODEL_SUFFIX"
        fi
        ;;
esac
