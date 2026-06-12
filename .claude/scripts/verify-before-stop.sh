#!/bin/bash
# Stop Hook: MANDATORY QA GATE - Blocks until QA approval via Beads.
#
# Phase 4 (claude-workflow-plugin-y4a.10) - major rewrite layered on top
# of the Phase 1 corrections. New responsibilities:
#
#   F3   Single source of truth for current task id (current-task.sh).
#   B2   Epic-level e2e gate (epic-gate.sh) on task completion.
#   B3   Test/lint/type timeouts: 1200s tests, 300s lint, 600s type;
#        configurable outer wrapper timeout (default 60s wraps just the
#        non-test post-processing; the long ops are timed individually).
#   F8/J17 Polyglot test/lint command via detect-stack.sh.
#   F1   Doc-only fast path: auto-approve when changes are documentation
#        or comment-only.
#   J18  Intent-based specialist recommendation surfaced in block reasons.
#   J19  Iterative loop with regression coverage; iteration counter.
#   J21  Decision-gate options surfaced when there are findings post-pass.
#
# Phase 1 properties retained:
#   B1/D1/J2  Marker file bypass deleted; sole source of truth = qa-approved label.
#   B13       Comment-text fallback removed.
#   B6        Allowlist replaced with denylist over build/lock artifacts.
#   B8        Claude-friendly placeholder when no task is detected.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
TRACKING_FILE="$QA_TRACKING_DIR/changed-files.txt"
QA_GATE="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
EPIC_GATE="$PROJECT_DIR/.claude/scripts/epic-gate.sh"
DETECT_STACK="$PROJECT_DIR/.claude/scripts/detect-stack.sh"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"

# Per-iteration artifacts. The iteration counter is keyed by task_id (Phase 4
# fix pass / MATERIAL 5): a per-task path so abandoning task A at iter=3 and
# switching to task B does NOT make B start at iter=4. Resolved later via
# iteration_file_for() once we know the current task id.
ITERATION_FILE_LEGACY="$QA_TRACKING_DIR/iteration-count"
TEST_LOG="$QA_TRACKING_DIR/last-test-output.log"
LINT_LOG="$QA_TRACKING_DIR/last-lint-output.log"
TYPE_LOG="$QA_TRACKING_DIR/last-type-output.log"

# Sanitize a task id into a filesystem-safe suffix. Beads ids are normally
# already safe (alpha-num + dot + dash) but we belt-and-brace.
sanitize_task_id() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

# Path to the iteration counter for a specific task id. When task is empty
# we fall back to the legacy path (preserves single-task behaviour for users
# with no Beads).
iteration_file_for() {
    local tid="$1"
    if [ -z "$tid" ]; then
        printf '%s' "$ITERATION_FILE_LEGACY"
    else
        printf '%s/iteration-count.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
    fi
}

# Tunable timeouts. The outer wrapper is for post-processing only — the
# long-running test/lint/type subprocesses use their own GNU `timeout`.
STOP_TIMEOUT_FILE="$QA_TRACKING_DIR/stop-timeout"
TEST_TIMEOUT_S=1200
LINT_TIMEOUT_S=300
TYPE_TIMEOUT_S=600

# Maximum iterations before escalating via the decision gate.
MAX_ITERATIONS=3

mkdir -p "$QA_TRACKING_DIR"

# sync-errors.log: surface silently-failing best-effort calls (write_current_task,
# bd update --status closed, qa-gate enter/approve, etc.). SessionStart can
# read this and present recent entries. Mirrors Phase 1 / B11.
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    printf '%s\t[verify-before-stop]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# Denylist (B6).
DENYLIST_REGEX='(^|/)(node_modules|dist|build|coverage|\.git|\.next|\.nuxt|target|__pycache__)/|\.(lock|lockb|map|pyc)$|\.min\.(js|css)$|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|bun\.lockb|Cargo\.lock|poetry\.lock|go\.sum)$'

is_tracked_change() {
    local p="$1"
    [ -z "$p" ] && return 1
    if [[ "$p" =~ $DENYLIST_REGEX ]]; then
        return 1
    fi
    return 0
}

# Doc-only patterns (F1). A change matches doc-only if EVERY modified file
# matches one of these patterns AND no other tracked code changes are
# present. We keep this conservative: README, CHANGELOG, LICENSE, and
# anything under docs/ counts; .json/.yaml/.toml do NOT (they often
# influence behavior).
is_doc_only_path() {
    local p="$1"
    [ -z "$p" ] && return 1
    case "$p" in
        *.md|*.markdown|*.mdx|*.rst|*.txt) return 0 ;;
        */LICENSE|LICENSE|LICENSE.*) return 0 ;;
        # .md variants of CHANGELOG are already covered by *.md above; keep
        # the extension-less forms here so e.g. plain `CHANGELOG` still wins.
        */CHANGELOG|CHANGELOG) return 0 ;;
        */NOTICE|NOTICE|*/AUTHORS|AUTHORS) return 0 ;;
        */docs/*|docs/*) return 0 ;;
    esac
    return 1
}

# F3 (Phase 4 fix pass): the persisted helper file is the single source of
# truth for the active task id. The previous implementation fell back to
# `bd list --status in_progress | jq .[0].id` when the file was empty, but
# that defeats F3 entirely under parallel epics: it would silently grab an
# arbitrary in_progress task and let the gate operate on the wrong row.
#
# New contract: empty helper file means "no active task". The caller MUST
# treat that as a hard signal (no auto-approve, no auto-close). When this
# happens we record an entry in sync-errors.log so SessionStart can surface
# it - the most common cause is a previous `qa-gate enter` whose
# best-effort `write_current_task` failed silently.
get_current_task() {
    local tid=""
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null || echo "")
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null | tr -d '\r\n[:space:]' || echo "")
    fi
    if [ -z "$tid" ]; then
        # No fallback: previous bd-list fallback was the F3 anti-pattern.
        # Surface the missing helper to the user once per Stop fire.
        log_sync_error "current-task helper file empty or missing; treating as 'no active task' (no fallback to bd list)."
    fi
    printf '%s' "$tid"
}

# I8 (Phase 6b): repo-aware helpers. The current-task helper records the
# repo fingerprint at `set` time; here we read it back and compare to the
# running cwd's repo toplevel.
get_recorded_repo() {
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        bash "$CURRENT_TASK_HELPER" get-repo 2>/dev/null || echo ""
    elif [ -s "$QA_TRACKING_DIR/current-task.repo" ]; then
        head -1 "$QA_TRACKING_DIR/current-task.repo" 2>/dev/null | tr -d '\r\n[:space:]' || echo ""
    fi
}

# Returns the current cwd's git toplevel. Empty if not a git repo.
get_current_repo_root() {
    if command -v git >/dev/null 2>&1; then
        git -C "$PROJECT_DIR" rev-parse --show-toplevel 2>/dev/null || echo ""
    fi
}

# Decide whether the active task is cross-repo relative to the cwd. We
# return the recorded repo path when there's a mismatch, empty otherwise.
# A missing recorded repo (i.e., set under pre-I8 schema) is NOT a mismatch
# -- we degrade silently to the legacy single-repo behaviour.
detect_cross_repo() {
    local recorded current
    recorded=$(get_recorded_repo)
    [ -z "$recorded" ] && return 0   # no recorded repo -> no mismatch claim
    current=$(get_current_repo_root)
    [ -z "$current" ] && return 0    # cwd not a git repo -> no mismatch claim

    # Normalize trailing slashes before comparing.
    recorded="${recorded%/}"
    current="${current%/}"
    if [ "$recorded" != "$current" ]; then
        printf '%s' "$recorded"
        return 1
    fi
    return 0
}

# Run a command with optional `timeout` if available. Returns the
# command's exit code. Streams combined stdout+stderr to the given log file.
run_with_timeout() {
    local secs="$1" log="$2"; shift 2
    : > "$log"
    if command -v timeout >/dev/null 2>&1; then
        timeout "${secs}s" bash -c "$*" >"$log" 2>&1
    elif command -v gtimeout >/dev/null 2>&1; then
        gtimeout "${secs}s" bash -c "$*" >"$log" 2>&1
    else
        # No timeout available - run unbounded; log indicates this.
        bash -c "$*" >"$log" 2>&1
    fi
}

# Tail a log to the last N lines (default 50). Used to surface failures
# in block-reason text without overwhelming Claude's context window.
log_tail() {
    local file="$1" n="${2:-50}"
    [ -f "$file" ] || { echo "(no log)"; return; }
    tail -n "$n" "$file"
}

# Read the configurable outer timeout (default 60s).
read_stop_timeout() {
    local v=60
    if [ -s "$STOP_TIMEOUT_FILE" ]; then
        local raw
        raw=$(head -1 "$STOP_TIMEOUT_FILE" | tr -dc '0-9' || echo "")
        [ -n "$raw" ] && v="$raw"
    fi
    printf '%s' "$v"
}

# Increment the iteration counter at $1 (a per-task path); print the new
# value. The counter file is task-keyed (see iteration_file_for) so leaks
# across tasks no longer happen.
bump_iteration() {
    local file="$1"
    local n=0
    if [ -s "$file" ]; then
        n=$(head -1 "$file" | tr -dc '0-9' || echo "0")
        n="${n:-0}"
    fi
    n=$((n + 1))
    printf '%s\n' "$n" > "$file"
    printf '%s' "$n"
}

# Read the iteration counter at $1 without bumping.
read_iteration() {
    local file="$1"
    if [ -s "$file" ]; then
        head -1 "$file" | tr -dc '0-9'
    else
        printf '0'
    fi
}

# J21 decision-gate options block (Phase 4 fix pass / MATERIAL 6).
#
# Previously this block only fired on the FAILED_CHECKS path. The more
# common case — technical checks pass but no QA approval at iter>=3 —
# never saw the options. Factored into a helper so we can append it to
# either reason string. $1 = task id (may be "<TASK_ID_NEEDED>").
#
# Spec 0.2: this block is now driven by qa-gate.sh choose <choice>; the
# direct `qa-gate.sh approve` form still works (`choose approve` is a
# thin wrapper around it). Wording mirrors the spec.
j21_options_block() {
    local tid="$1"
    cat <<EOF

ESCALATION: Iteration $ITER (>= $MAX_ITERATIONS). Use the J21 decision gate
options to choose a path forward (record via \`qa-gate.sh choose ...\` so
the gate exits escalation):

Options:
  1. approve  — \`bash .claude/scripts/qa-gate.sh choose approve $tid '<summary>'\`
                (only if you genuinely accept the findings as known/non-blocking)
  2. continue — \`bash .claude/scripts/qa-gate.sh choose continue $tid '<note>'\`
                fix the underlying issue and re-run; clears qa-escalated and resets the iteration counter.
  3. tech-debt — \`bash .claude/scripts/qa-gate.sh choose tech-debt $tid '<description>' [severity] [file:line] [effort]\`
                 records a TECHNICAL_DEBT.md row + bd task, clears qa-escalated.
  4. defer — \`bash .claude/scripts/qa-gate.sh choose defer $tid '<note>'\`
             stops iteration; sets qa-deferred so the next Stop is allowed.

If no choice is recorded by the NEXT Stop, the gate auto-selects option 4
(defer) and surfaces the task on the next SessionStart.
EOF
}

# Spec 0.2 helpers ------------------------------------------------------------
#
# Cache + label inspection for the escalation state machine. The verify
# script uses these to:
#   - read qa-escalated / qa-deferred labels on the active task
#   - cache the most-recent test run so escalated Stops don't re-run the
#     full suite each loop (the production bug we're fixing)
#   - distinguish runner-failure ("environment broke") from
#     assertion-failure ("the code is wrong") in the block reason
#
# State files live alongside the iteration counter (per-task keyed). They
# survive across Stop fires until qa-gate.sh wipes them on
# approve / re-enter / choose continue / choose tech-debt.

# Path helpers ---------------------------------------------------------------
last_test_rc_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-test-rc"; return; }
    printf '%s/last-test-rc.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
last_failed_checks_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-failed-checks"; return; }
    printf '%s/last-failed-checks.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
last_runner_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/last-runner"; return; }
    printf '%s/last-runner.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}
escalation_posted_file_for() {
    local tid="$1"
    [ -z "$tid" ] && { printf '%s' "$QA_TRACKING_DIR/escalation-posted"; return; }
    printf '%s/escalation-posted.%s' "$QA_TRACKING_DIR" "$(sanitize_task_id "$tid")"
}

# task_has_label <task-id> <label> - 0 if present, 1 if absent or bd unavailable.
# Mirrors qa-gate.sh's has_label but lives here so verify-before-stop can
# read labels without sourcing qa-gate.sh.
task_has_label() {
    local tid="$1" label="$2"
    [ -z "$tid" ] && return 1
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$PROJECT_DIR/.beads" ] || return 1
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo "")
    echo ",$labels," | grep -q ",$label,"
}

# Spec 0.2: classify a test failure as a runner/infrastructure issue vs.
# assertion failure. Conservative heuristic — when in doubt we say
# "assertion" (the existing wording) so we never mis-direct an
# assertion failure to "fix the environment".
#
# Inputs:
#   $1 - test exit code (numeric)
#   $2 - tail of the test log
#
# Returns:
#   prints "runner" or "assertion" on stdout.
classify_test_failure() {
    local rc="$1" tail_log="$2"
    # Timeout has its own wording upstream; classify as assertion so the
    # callsite keeps the dedicated "Tests timed out" message.
    [ "$rc" = "124" ] && { printf 'assertion'; return; }
    # Exit 127 = command not found; 126 = found but not executable.
    # These are unambiguously environment problems — the runner itself
    # did not start.
    if [ "$rc" = "127" ] || [ "$rc" = "126" ]; then
        printf 'runner'; return
    fi
    # Pattern probe over the log tail. Conservative — only patterns that
    # are unambiguous runner-infra signals.
    if [ -n "$tail_log" ] && printf '%s' "$tail_log" \
            | grep -qE 'command not found|Cannot find module|No such file or directory|npm ERR! Missing script|No rule to make target|TS5057: Cannot find a tsconfig\.json|Error: Cannot find package|ENOENT.*node_modules|testcontainers.*TypeError'; then
        printf 'runner'; return
    fi
    printf 'assertion'
}

# Compute a JSON-encoded summary of changes for J18 intent-routing context.
# Shape: {"changed_files":[...], "diff_summary":"...", "recommended_focus":"<llm-fills>"}
compute_intent_payload() {
    local files_json
    if [ -f "$TRACKING_FILE" ]; then
        files_json=$(sort -u "$TRACKING_FILE" 2>/dev/null \
            | while IFS= read -r f; do
                if is_tracked_change "$f"; then printf '%s\n' "$f"; fi
              done \
            | jq -R . 2>/dev/null \
            | jq -s . 2>/dev/null \
            || echo "[]")
    else
        files_json="[]"
    fi
    [ -z "$files_json" ] && files_json="[]"

    # Generate a small diff summary if git is available. Cap at 80 lines so
    # we don't blow up the block reason. Set principled output: file:lines.
    local summary=""
    if [ -d "$PROJECT_DIR/.git" ] && command -v git >/dev/null 2>&1; then
        summary=$(git -C "$PROJECT_DIR" diff --stat HEAD 2>/dev/null | head -80 || echo "")
        [ -z "$summary" ] && summary=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | head -80 || echo "")
    fi
    [ -z "$summary" ] && summary="(no diff stats available)"

    # Use -c (compact) for RFC-8259-clean output. Pretty-printed JSON could
    # contain literal newlines inside strings (the diff_summary), which the
    # outer block-reason envelope handles via jq -Rs but the LLM might
    # still extract the inner block as text and re-parse it. Compact form
    # avoids any control-character risk.
    jq -nc \
        --argjson files "$files_json" \
        --arg summary "$summary" \
        '{changed_files:$files, diff_summary:$summary,
          recommended_focus:"<<orchestrator-or-qa-fills-this: read the diff and decide which review pass to invoke; do NOT use regex over filenames>>"}'
}

# Emit a block-reason JSON envelope.
#
# E9 standardisation note: the Stop hook uses the **top-level** decision
# pattern per the Claude Code hooks reference — i.e., {"decision":"block",
# "reason":"..."} — NOT the hookSpecificOutput envelope. The hooks docs
# reserve hookSpecificOutput for PreToolUse/PermissionRequest/PermissionDenied
# /WorktreeCreate/Elicitation/ElicitationResult and use top-level decision
# for UserPromptSubmit/PostToolUse/Stop/SubagentStop/ConfigChange/PreCompact.
# The non-blocking note path below DOES use hookSpecificOutput because it's
# carrying additionalContext, not a decision.
emit_block() {
    local reason="$1"
    printf '{"decision":"block","reason":%s}\n' \
        "$(printf '%s' "$reason" | jq -Rs .)"
    exit 0
}

# ---------------------------------------------------------------------------
# Begin main flow.

INPUT=$(cat)
STOP_REASON=$(echo "$INPUT" | jq -r '.stop_reason // empty' 2>/dev/null || echo "")
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo "false")

# Circuit breaker (AgentLint H3): when stop_hook_active is true Claude is already
# in a forced-continuation state from a previous block. Returning exit 0 here
# prevents the hook from re-blocking and producing an infinite loop.
if [[ "$STOP_HOOK_ACTIVE" == "true" ]]; then
    echo "{}"; exit 0
fi

# Skip for user interrupt / max turns.
if [[ "$STOP_REASON" == "user_interrupt" ]] || [[ "$STOP_REASON" == "max_turns" ]]; then
    echo "{}"; exit 0
fi

# Detect tracked changes via tracking file (post-edit.sh) first, then git.
CODE_CHANGES_DETECTED=false
ALL_CHANGED_FILES=()
DOC_ONLY=true   # F1: stays true only if every changed file is doc-only.

if [ -f "$TRACKING_FILE" ] && [ -s "$TRACKING_FILE" ]; then
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if is_tracked_change "$line"; then
            CODE_CHANGES_DETECTED=true
            ALL_CHANGED_FILES+=("$line")
            if ! is_doc_only_path "$line"; then
                DOC_ONLY=false
            fi
        fi
    done < <(sort -u "$TRACKING_FILE" 2>/dev/null)
fi

# 0wk.2 fix: git-status fallback - but ONLY surface entries NEW since the
# last qa-gate approval. The approved-baseline (written by qa-gate approve)
# captures the git state that was approved. Subsequent stops are allowed
# to slip through if the working tree matches the baseline (i.e., the
# user opened the session, the gate fires, but nothing has been edited
# since the last approval). Without this, every Stop hook fired
# "0 file(s) changed - all require QA review" against the same
# pre-existing uncommitted state -- the bug 0wk.2 closed.
#
# Strategy: diff CURRENT git status against BASELINE. If a line is in
# current but not in baseline, it's a NEW change requiring review.
# `comm -23 <a> <b>` prints lines in a but not in b; we sort both inputs.
# Bash 3.2 supports process substitution (verified on macOS bash 3.2.57).
if [ "$CODE_CHANGES_DETECTED" = false ] && [ -d "$PROJECT_DIR/.git" ]; then
    baseline_file="$QA_TRACKING_DIR/approved-baseline"
    baseline=""
    [ -f "$baseline_file" ] && baseline=$(cat "$baseline_file" 2>/dev/null || echo "")

    current=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | sort)

    # Diff: only entries in current that aren't in baseline.
    if [ -z "$baseline" ]; then
        # No baseline - any git-detected change is "new". This preserves
        # the pre-0wk.2 behaviour for users who haven't yet approved
        # anything (the gate fires on first edit, as expected).
        new_entries=$(printf '%s\n' "$current" | grep -v '^$' || true)
    else
        new_entries=$(comm -23 <(printf '%s\n' "$current") <(printf '%s\n' "$baseline") | grep -v '^$' || true)
    fi

    if [ -n "$new_entries" ]; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            path="${line#???}"
            if is_tracked_change "$path"; then
                CODE_CHANGES_DETECTED=true
                ALL_CHANGED_FILES+=("$path")
                if ! is_doc_only_path "$path"; then
                    DOC_ONLY=false
                fi
            fi
        done <<< "$new_entries"
    fi
fi

# If no changes at all, allow.
if [ "$CODE_CHANGES_DETECTED" = false ]; then
    echo "{}"; exit 0
fi

# Resolve current task id once.
CURRENT_TASK=$(get_current_task)

# I8 (Phase 6b): cross-repo detection. If the active task was claimed in a
# different repo than the cwd's, we treat that as a hard "do not auto-mark
# complete" signal: a Stop fired in repo Y must NOT silently close a task
# tracked in repo X's Beads database (or against repo X's HEAD). We:
#   - skip the F1 doc-only auto-approve fast path (kept for same-repo only)
#   - skip the post-approval `bd update --status closed` short-circuit
#   - surface a clearly-formatted block reason explaining the mismatch
# Single-repo users see no behaviour change because get_recorded_repo
# returns empty for them (the helper file simply doesn't carry repo data).
CROSS_REPO_PEER=""
# detect_cross_repo prints the recorded repo when it differs from cwd's
# repo, exit code 1; prints nothing + exit 0 on match (or pre-I8 schema).
# We swallow the non-zero rc so `set -e` doesn't abort the gate.
cross_rc=0
cross_check=$(detect_cross_repo) || cross_rc=$?
if [ "$cross_rc" -ne 0 ] && [ -n "$cross_check" ]; then
    CROSS_REPO_PEER="$cross_check"
fi

if [ -n "$CROSS_REPO_PEER" ]; then
    # The CWD is in a different repo than the recorded task. Surface a
    # block reason; do not auto-approve, do not auto-close.
    CURRENT_REPO_ROOT=$(get_current_repo_root)
    REASON="Cross-repo Stop detected (I8).

The active Beads task ($CURRENT_TASK) was claimed in repo:
  $CROSS_REPO_PEER

But this Stop hook fires from the cwd-rooted repo:
  ${CURRENT_REPO_ROOT:-(no git repo detected in cwd)}

The QA gate will not auto-mark the task complete from a foreign repo. Pick one:

  1. cd into $CROSS_REPO_PEER and re-run the Stop flow there. Tests/lint
     for the task's actual repo run against the right HEAD.
  2. If the work genuinely spans both repos, treat each repo's gate
     independently: claim a sibling task in the cwd's repo, do its review
     there, then return to $CROSS_REPO_PEER for the original task's gate.
  3. If this is a mis-recorded task (rare; usually means current-task.repo
     drifted), reset via:
       bash .claude/scripts/current-task.sh clear
       bash .claude/scripts/qa-gate.sh enter $CURRENT_TASK   # rewrites repo
     -- but only after confirming the task really lives in the cwd's repo.

The gate state for $CURRENT_TASK is preserved (no labels touched, no
status changes). The intent is: humans/Claude must explicitly handle the
cross-repo case, never the gate."
    log_sync_error "cross-repo Stop blocked for $CURRENT_TASK: recorded=$CROSS_REPO_PEER cwd=${CURRENT_REPO_ROOT:-unknown}"
    emit_block "$REASON"
fi

# F1: Doc-only fast path. Auto-approve via qa-gate.sh and short-circuit.
# This MUST run before test/lint to avoid spending 1200s on README updates.
if [ "$DOC_ONLY" = true ] && [ ${#ALL_CHANGED_FILES[@]} -gt 0 ]; then
    if [ -n "$CURRENT_TASK" ] && [ -x "$QA_GATE" ]; then
        # Auto-approve only if the task is currently pending (not already
        # approved/blocked). This idempotency is enforced inside qa-gate.sh
        # too, but we check here to keep observations clear.
        GATE_STATUS=$("$QA_GATE" status "$CURRENT_TASK" 2>/dev/null | jq -r '.status // "error"' 2>/dev/null || echo "error")
        case "$GATE_STATUS" in
            not-entered|entered|pending)
                # Ensure the gate is entered first (so approve is well-formed).
                "$QA_GATE" enter "$CURRENT_TASK" >/dev/null 2>&1 || log_sync_error "qa-gate enter failed during F1 doc-only fast path for $CURRENT_TASK"
                "$QA_GATE" approve "$CURRENT_TASK" "Auto-approved: doc-only changes detected (F1 fast path)" >/dev/null 2>&1 || log_sync_error "qa-gate approve failed during F1 doc-only fast path for $CURRENT_TASK"
                # Mark task as closed if bd is available. Beads 0.47.x uses
                # status=closed (not "completed"); using the wrong value used
                # to silently fail under `|| true`, so we log to sync-errors.log.
                if command -v bd >/dev/null 2>&1; then
                    bd update "$CURRENT_TASK" --status closed 2>/dev/null \
                        || log_sync_error "bd update --status closed failed for $CURRENT_TASK during F1 doc-only fast path"
                fi
                # Clean up tracking artifacts. Includes per-task iteration
                # counter (legacy unscoped path is also cleared so users
                # upgrading don't keep stale state).
                rm -f "$QA_TRACKING_DIR/changed-files.txt" 2>/dev/null || true
                rm -f "$QA_TRACKING_DIR/edit-count" 2>/dev/null || true
                rm -f "$(iteration_file_for "$CURRENT_TASK")" 2>/dev/null || true
                rm -f "$ITERATION_FILE_LEGACY" 2>/dev/null || true
                echo "{}"; exit 0
                ;;
        esac
    fi
    # No active task - we can't auto-approve, but we can still skip
    # the test/lint pass since the changes are doc-only. Fall through to
    # the QA-required messaging with a hint.
fi

# B3 + MATERIAL 5 fix: increment iteration counter for THIS task's stop fire.
# The counter is keyed by CURRENT_TASK so abandoning task A at iter=3 and
# switching to task B does NOT make B start at iter=4. When CURRENT_TASK
# is empty we still use the legacy path (single-task / no-Beads users).
ITERATION_FILE=$(iteration_file_for "$CURRENT_TASK")
ITER=$(bump_iteration "$ITERATION_FILE")

# Spec 0.2: escalation state machine. Read once and act before the suite
# runs so we never repeat the four-loops-past-the-cap behaviour the bug
# report captured. The label reads are best-effort — if bd is missing or
# the task id is empty we fall through to the legacy "always run tests"
# path so single-repo / no-Beads users see no regression.
QA_DEFERRED=false
QA_ESCALATED=false
if [ -n "$CURRENT_TASK" ]; then
    if task_has_label "$CURRENT_TASK" "qa-deferred"; then QA_DEFERRED=true; fi
    if task_has_label "$CURRENT_TASK" "qa-escalated"; then QA_ESCALATED=true; fi
fi

# Spec 0.2 escape valve: if qa-deferred is set on the active task, allow
# this Stop immediately. The user explicitly recorded "defer" (or the
# gate auto-deferred after escalation went unanswered) — re-running the
# block here would defeat the choice. Principle 6 says this is the
# single audited Stop-hook escape; we don't touch labels or counters,
# so a future re-enter on this task naturally resumes normal gating.
if [ "$QA_DEFERRED" = "true" ]; then
    log_sync_error "Stop allowed under qa-deferred label for $CURRENT_TASK (iteration $ITER)"
    echo "{}"; exit 0
fi

# Spec 0.2 auto-defer: if qa-escalated has been set for at least one
# prior Stop AND no recorded J21 choice has arrived in time, auto-pick
# option 4 (defer). The threshold is one buffer iteration past the cap
# — cap-hit (ITER=MAX) shows the J21 options, ITER=MAX+1 still blocks
# under the escalation wording (giving the agent one more chance to
# record a choice), and ITER>=MAX+2 auto-defers. This matches the L2
# acceptance ("lands on a recorded J21 decision by iteration 5 at the
# latest" with MAX=3 and a one-iteration warning buffer).
if [ "$QA_ESCALATED" = "true" ] && [ -n "$CURRENT_TASK" ] && [ "$ITER" -gt $((MAX_ITERATIONS + 1)) ]; then
    if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
        bd label add "$CURRENT_TASK" qa-deferred >/dev/null 2>&1 \
            || log_sync_error "auto-defer: bd label add qa-deferred failed for $CURRENT_TASK"
        # Use bd comments (qa-gate.sh's add_comment wraps this pair) so
        # the audit trail mirrors a manual `qa-gate.sh choose defer`.
        AUTO_DEFER_TS=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
        AUTO_DEFER_NOTE="QA-GATE AUTO-DEFER at $AUTO_DEFER_TS: auto-deferred at iteration $ITER after escalation went unanswered; task remains qa-pending"
        bd comments add "$CURRENT_TASK" "$AUTO_DEFER_NOTE" >/dev/null 2>&1 \
            || bd comment add "$CURRENT_TASK" "$AUTO_DEFER_NOTE" >/dev/null 2>&1 \
            || log_sync_error "auto-defer: comment add failed for $CURRENT_TASK"
    fi
    log_sync_error "Stop auto-deferred for $CURRENT_TASK at iteration $ITER (qa-escalated unanswered)"
    echo "{}"; exit 0
fi

# F8/J17 + B3: detect runner and run test/lint/type-check with timeouts.
# Spec 0.2: while qa-escalated is set we MUST NOT re-run the full suite;
# we reuse whatever the cap-hit Stop cached. This was the production bug.
RUNNER="none"
TEST_CMD=""
LINT_CMD=""
TYPE_CMD=""

FAILED_CHECKS=""
TEST_FAIL_TAIL=""
LINT_FAIL_TAIL=""
TYPE_FAIL_TAIL=""
TEST_FAIL_CLASS=""        # "runner" | "assertion" | "" (set when we re-run or replay)
SUITE_REUSED=false        # true when this Stop reused cached results

if [ "$QA_ESCALATED" = "true" ]; then
    # Replay the cached state. If anything is missing we fall back to
    # treating this as a generic block — better than running the suite
    # under escalation, which would reintroduce the bug. We do not
    # currently consume last-test-rc on the replay path (the cached
    # FAILED_CHECKS already carries the rendered wording), but the file
    # exists for diagnostics / future use.
    LFC_FILE=$(last_failed_checks_file_for "$CURRENT_TASK")
    LRN_FILE=$(last_runner_file_for "$CURRENT_TASK")
    if [ -s "$LFC_FILE" ]; then
        # Prefer the literal-newline form of the previously rendered
        # FAILED_CHECKS so we don't need to re-derive the tail. The
        # file may contain plain text including the rendered tails;
        # we just slurp it.
        FAILED_CHECKS=$(cat "$LFC_FILE" 2>/dev/null || echo "")
    fi
    [ -s "$LRN_FILE" ] && RUNNER=$(head -1 "$LRN_FILE" | tr -d '\r\n')
    SUITE_REUSED=true
else
    if [ -x "$DETECT_STACK" ]; then
        DETECT_JSON=$("$DETECT_STACK" 2>/dev/null || echo "{}")
        RUNNER=$(echo "$DETECT_JSON" | jq -r '.runner // "none"' 2>/dev/null || echo "none")
        TEST_CMD=$(echo "$DETECT_JSON" | jq -r '.test_cmd // ""' 2>/dev/null || echo "")
        LINT_CMD=$(echo "$DETECT_JSON" | jq -r '.lint_cmd // ""' 2>/dev/null || echo "")
        TYPE_CMD=$(echo "$DETECT_JSON" | jq -r '.type_cmd // ""' 2>/dev/null || echo "")
    fi

    # J19: regression-coverage framing. We always run the FULL test suite
    # + FULL type-check (when configured), not just for changed files.
    # This is essential because changes in module A might break module B's
    # contract; only running A's tests would miss B's failure. Document
    # this in the block reason when checks fail so the operator (or
    # Claude) understands why the suite is wider than the diff.
    #
    # NOTE on capturing exit codes under `set -e`:
    #   The pattern `if ! cmd; then rc=$?; fi` is BROKEN under `set -e`
    #   because the `if !` branch resets `$?` to 0 before the inner block
    #   runs. We must capture rc in the same statement as the call
    #   itself, e.g.:
    #       rc=0; cmd || rc=$?
    #   This preserves the real exit code (124 for GNU `timeout`, anything
    #   else for genuine failures) so downstream branches can distinguish
    #   timeout from failure.

    test_rc=0
    if [ -n "$TEST_CMD" ]; then
        run_with_timeout "$TEST_TIMEOUT_S" "$TEST_LOG" "$TEST_CMD" || test_rc=$?
        if [ "$test_rc" -ne 0 ]; then
            TEST_FAIL_TAIL=$(log_tail "$TEST_LOG" 50)
            # Spec 0.2: classify runner-vs-assertion BEFORE composing
            # the failure header so we lead with the right wording.
            TEST_FAIL_CLASS=$(classify_test_failure "$test_rc" "$TEST_FAIL_TAIL")
            if [ "$test_rc" = "124" ]; then
                FAILED_CHECKS+="- Tests timed out after ${TEST_TIMEOUT_S}s — see $TEST_LOG\n"
            elif [ "$TEST_FAIL_CLASS" = "runner" ]; then
                # Lead with the environment/runner hint per spec 0.2 so
                # the next iteration targets the environment first.
                FAILED_CHECKS+="- Test suite failed to run (environment/runner issue — fix the environment before changing code): exit $test_rc — see $TEST_LOG\n"
            else
                FAILED_CHECKS+="- Tests failing (exit $test_rc) — see $TEST_LOG\n"
            fi
        fi
    fi

    if [ -n "$LINT_CMD" ]; then
        lint_rc=0
        run_with_timeout "$LINT_TIMEOUT_S" "$LINT_LOG" "$LINT_CMD" || lint_rc=$?
        if [ "$lint_rc" -ne 0 ]; then
            if [ "$lint_rc" = "124" ]; then
                FAILED_CHECKS+="- Lint timed out after ${LINT_TIMEOUT_S}s — see $LINT_LOG\n"
            else
                FAILED_CHECKS+="- Lint errors (exit $lint_rc) — see $LINT_LOG\n"
            fi
            LINT_FAIL_TAIL=$(log_tail "$LINT_LOG" 50)
        fi
    fi

    if [ -n "$TYPE_CMD" ]; then
        type_rc=0
        run_with_timeout "$TYPE_TIMEOUT_S" "$TYPE_LOG" "$TYPE_CMD" || type_rc=$?
        if [ "$type_rc" -ne 0 ]; then
            if [ "$type_rc" = "124" ]; then
                FAILED_CHECKS+="- Type-check timed out after ${TYPE_TIMEOUT_S}s — see $TYPE_LOG\n"
            else
                FAILED_CHECKS+="- Type-check failing (exit $type_rc) — see $TYPE_LOG\n"
            fi
            TYPE_FAIL_TAIL=$(log_tail "$TYPE_LOG" 50)
        fi
    fi

    # Spec 0.2: persist what we just observed so the next Stop, if it
    # arrives while qa-escalated, can replay without re-running the
    # suite. We persist regardless of pass/fail — qa-gate.sh wipes the
    # files on approve/enter/choose so a stale cache can't follow a
    # task across cycles.
    if [ -n "$CURRENT_TASK" ]; then
        printf '%s' "$test_rc" > "$(last_test_rc_file_for "$CURRENT_TASK")" 2>/dev/null || true
        printf '%s' "$RUNNER" > "$(last_runner_file_for "$CURRENT_TASK")" 2>/dev/null || true
        # We persist the rendered failure body (already includes the
        # leading "- " bullets and the trailing newline). Including the
        # tails would bloat the cache — they get re-derived from the
        # log files which we leave on disk in the same dir.
        if [ -n "$FAILED_CHECKS" ]; then
            printf '%s' "$FAILED_CHECKS" > "$(last_failed_checks_file_for "$CURRENT_TASK")" 2>/dev/null || true
        else
            # Tech-checks passed; clear any stale cache so a future
            # cap-hit while passing tech checks doesn't replay an old
            # failure summary.
            rm -f "$(last_failed_checks_file_for "$CURRENT_TASK")" 2>/dev/null || true
        fi
    fi
fi

# Spec 0.2: at the moment we first reach the cap, record qa-escalated +
# post the J21 options comment exactly once. The comment marker file
# prevents re-posting on subsequent escalated loops (idempotent).
mark_escalation_if_capped() {
    local tid="$1"
    [ -z "$tid" ] && return 0
    if [ "$ITER" -lt "$MAX_ITERATIONS" ]; then
        return 0
    fi
    if [ "$QA_ESCALATED" = "true" ]; then
        return 0  # already escalated; no relabel, no relog
    fi
    if ! command -v bd >/dev/null 2>&1 || [ ! -d "$PROJECT_DIR/.beads" ]; then
        return 0
    fi
    # Label.
    bd label add "$tid" qa-escalated >/dev/null 2>&1 \
        || log_sync_error "mark_escalation: bd label add qa-escalated failed for $tid"
    # One comment, idempotent via marker file.
    local marker
    marker=$(escalation_posted_file_for "$tid")
    if [ ! -f "$marker" ]; then
        local ts options_text
        ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
        options_text=$(j21_options_block "$tid")
        bd comments add "$tid" "QA-GATE ESCALATED at $ts (iteration $ITER >= $MAX_ITERATIONS).$options_text" >/dev/null 2>&1 \
            || bd comment add "$tid" "QA-GATE ESCALATED at $ts (iteration $ITER >= $MAX_ITERATIONS).$options_text" >/dev/null 2>&1 \
            || log_sync_error "mark_escalation: comment add failed for $tid"
        : > "$marker" 2>/dev/null || true
    fi
    QA_ESCALATED=true
}

# J19: iterative loop. If checks fail, surface tail + iteration count +
# escalation hint when MAX_ITERATIONS is reached.
if [ -n "$FAILED_CHECKS" ]; then
    # Spec 0.2: at cap-hit, transition to escalated state (idempotent).
    # We do this BEFORE composing REASON so the wording can branch on
    # the post-transition QA_ESCALATED.
    mark_escalation_if_capped "${CURRENT_TASK:-}"

    if [ "$QA_ESCALATED" = "true" ]; then
        # Spec 0.2 wording: "escalated — record a J21 choice before
        # iterating further." Lead with the escalation banner; include
        # the cached failure summary so the agent still sees why.
        REASON="Verification gate ESCALATED (iteration $ITER of $MAX_ITERATIONS; cap reached) — record a J21 choice before iterating further."
        if [ "$SUITE_REUSED" = "true" ]; then
            REASON="$REASON

Cached failure summary (test suite NOT re-run this loop per the
escalation contract — see qa-gate.sh choose ...):

$FAILED_CHECKS"
        else
            REASON="$REASON

Last failure summary:

$FAILED_CHECKS"
        fi
    else
        REASON="Verification failed (iteration $ITER of $MAX_ITERATIONS).

$FAILED_CHECKS

Regression coverage note: this gate runs the FULL test suite + FULL
type-check on every iteration, not just tests for changed files. Changes
to module A might break module B's contract; only running A's tests
would miss B's failure."
    fi

    REASON="$REASON

Detected runner: $RUNNER"

    if [ -n "$TEST_FAIL_TAIL" ]; then
        REASON="$REASON

--- last 50 lines of test output ---
$TEST_FAIL_TAIL"
    fi
    if [ -n "$LINT_FAIL_TAIL" ]; then
        REASON="$REASON

--- last 50 lines of lint output ---
$LINT_FAIL_TAIL"
    fi
    if [ -n "$TYPE_FAIL_TAIL" ]; then
        REASON="$REASON

--- last 50 lines of type-check output ---
$TYPE_FAIL_TAIL"
    fi

    REASON="$REASON

The gate is idempotent: fix the issue, then this Stop hook re-evaluates
on the next attempt. The iteration counter resets on QA approval."

    if [ "$ITER" -ge "$MAX_ITERATIONS" ]; then
        REASON="$REASON
$(j21_options_block "${CURRENT_TASK:-<TASK_ID_NEEDED>}")"
    fi

    emit_block "$REASON"
fi

# All technical checks passed. Now check QA approval.
QA_APPROVED=false

if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    if [ -n "$CURRENT_TASK" ] && [ -x "$QA_GATE" ]; then
        GATE_STATUS=$("$QA_GATE" status "$CURRENT_TASK" 2>/dev/null | jq -r '.status // "error"' 2>/dev/null || echo "error")
        if [ "$GATE_STATUS" = "approved" ]; then
            QA_APPROVED=true
        fi
    fi
fi

if [ "$QA_APPROVED" = false ]; then
    # Spec 0.2: at cap-hit, transition to escalated state (idempotent).
    # The QA-required path is the more common cap-hit case (clean tech
    # checks waiting on QA), so escalation must fire here too — without
    # this, an iteration-7 transcript like the bug report shows the
    # J21 options block but no qa-escalated label.
    mark_escalation_if_capped "${CURRENT_TASK:-}"

    # J18: surface intent-routing payload (LLM, not regex, decides scope).
    INTENT_JSON=$(compute_intent_payload)

    # Get changed files for display.
    CHANGED_FILES=""
    CHANGE_COUNT=0
    if [ -f "$TRACKING_FILE" ]; then
        FILTERED=$(sort -u "$TRACKING_FILE" 2>/dev/null | while IFS= read -r f; do
            if is_tracked_change "$f"; then
                printf '%s\n' "$f"
            fi
        done || true)
        CHANGE_COUNT=$(printf '%s\n' "$FILTERED" | grep -c . || true)
        CHANGE_COUNT="${CHANGE_COUNT:-0}"
        if [ "$CHANGE_COUNT" -gt 15 ]; then
            CHANGED_FILES=$(printf '%s\n' "$FILTERED" | head -15)
            CHANGED_FILES="$CHANGED_FILES
...and $((CHANGE_COUNT - 15)) more files"
        else
            CHANGED_FILES="$FILTERED"
        fi
    else
        CHANGED_FILES="(check git status)"
        CHANGE_COUNT="?"
    fi

    if [ -n "$CURRENT_TASK" ]; then
        TASK_ID="$CURRENT_TASK"
        NO_TASK_NOTE=""
    else
        TASK_ID="<TASK_ID_NEEDED>"
        NO_TASK_NOTE="

No active Beads task detected. Create one (and write its id via
\`.claude/scripts/current-task.sh set <id>\`) before re-running, e.g.:
  bd create '...' -t task -p 1 -l <domain>,qa-pending
  bash .claude/scripts/qa-gate.sh enter <id>
"
    fi

    # J18: include the intent payload as a JSON block. The orchestrator/QA
    # agent reads this to decide which review pass to invoke (security,
    # perf, a11y, etc.) — driven by reading the diff, NOT regex.
    # Spec 0.2: when escalated, lead with the escalation wording (the cap
    # is what we're enforcing; the suite-reuse note disambiguates from
    # the FAILED_CHECKS path which DOES surface a failure summary).
    if [ "$QA_ESCALATED" = "true" ]; then
        REASON="QA approval required — gate ESCALATED (iteration $ITER of $MAX_ITERATIONS; cap reached) — record a J21 choice before iterating further. Test suite NOT re-run this loop per the escalation contract (runner=$RUNNER, technical checks previously passed).

$CHANGE_COUNT file(s) changed - all require QA review.$NO_TASK_NOTE"
    else
        REASON="QA approval required (iteration $ITER, runner=$RUNNER, technical checks passed).

$CHANGE_COUNT file(s) changed - all require QA review.$NO_TASK_NOTE"
    fi
    REASON="$REASON

Files changed:
$CHANGED_FILES

Intent-routing payload (J18) — orchestrator/QA reads this to pick the
review pass; the \`recommended_focus\` field is for the LLM to fill in,
NOT for a regex over filenames:

\`\`\`json
$INTENT_JSON
\`\`\`

Required: delegate to @qa now.

Task(\"@qa\", \"Mandatory review before delivery:

Files to review:
$CHANGED_FILES

Read the intent payload above and decide which review modules to run
(security/perf/a11y/etc.) based on what the diff means, not which words
appear in filenames.

Checklist:
- FIRST: for every changed file or exported symbol in the diff, query
  impact_of (code-graph MCP — mcp__plugin_claude-workflow_code-graph)
  BEFORE writing the review notes, and fold the high-fan-in callers it
  surfaces into the regression assessment. If the code-graph tools are
  NOT in your tool list this spawn, say so explicitly in llm_observations
  and fall back to grep/code_search; do not silently skip the impact pass.
- Tests cover user behavior (not implementation)
- Critical user journeys tested
- Failure modes handled
- All tests pass (already verified by gate)

When entering review, mark the gate:
  bash .claude/scripts/qa-gate.sh enter $TASK_ID

If approved (atomic — sets qa-approved, drops qa-pending and qa-gate-entered):
  bash .claude/scripts/qa-gate.sh approve $TASK_ID '<approval summary>'

If not approved:
  bash .claude/scripts/qa-gate.sh block $TASK_ID '<reason>'\")

Cannot complete without QA approval."

    # MATERIAL 6 fix: J21 decision-gate options must surface on the
    # QA-required path too, not just the FAILED_CHECKS path. This is the
    # MORE common case (clean tech-checks waiting on QA), so without it
    # users hit iter>=3 with no escalation guidance.
    if [ "$ITER" -ge "$MAX_ITERATIONS" ]; then
        REASON="$REASON
$(j21_options_block "$TASK_ID")"
    fi

    emit_block "$REASON"
fi

# QA approved - check epic-level e2e gate (B2) before allowing the stop.
EPIC_DEFER_NOTE=""
if [ -n "$CURRENT_TASK" ] && [ -x "$EPIC_GATE" ] && command -v bd >/dev/null 2>&1; then
    SIBLINGS_JSON=$("$EPIC_GATE" siblings "$CURRENT_TASK" 2>/dev/null || echo '{}')
    EPIC_ID=$(echo "$SIBLINGS_JSON" | jq -r '.epic_id // empty' 2>/dev/null || echo "")
    SHARED_JSON=$("$EPIC_GATE" shared-files "$CURRENT_TASK" 2>/dev/null || echo '{}')
    SHARED_COUNT=$(echo "$SHARED_JSON" | jq '.intersections | length // 0' 2>/dev/null || echo "0")

    if [ -n "$EPIC_ID" ]; then
        EPIC_CHECK=$("$EPIC_GATE" check "$EPIC_ID" 2>/dev/null || echo '{}')
        EPIC_DEC=$(echo "$EPIC_CHECK" | jq -r '.decision // "pass"' 2>/dev/null || echo "pass")
        EPIC_REASON=$(echo "$EPIC_CHECK" | jq -r '.observations // ""' 2>/dev/null || echo "")

        case "$EPIC_DEC" in
            block)
                # Sibling is qa-blocked — the active task can still complete,
                # but we surface this prominently so the orchestrator
                # doesn't accidentally close the epic.
                EPIC_DEFER_NOTE="

Epic gate (B2): $EPIC_REASON
The active task can complete; the parent epic ($EPIC_ID) cannot close until
the blocked sibling clears."
                ;;
            defer)
                EPIC_DEFER_NOTE="

Epic gate (B2): $EPIC_REASON
The active task can complete; the parent epic ($EPIC_ID) stays open."
                ;;
            pass)
                EPIC_DEFER_NOTE="

Epic gate (B2): all sub-tasks under $EPIC_ID qa-approved; the epic can close."
                ;;
        esac

        if [ "${SHARED_COUNT:-0}" -gt 0 ]; then
            EPIC_DEFER_NOTE="$EPIC_DEFER_NOTE

Shared-files notice: this task overlaps with $SHARED_COUNT in-progress
sibling(s). An integration check is recommended before the epic closes.
Run \`bash .claude/scripts/epic-gate.sh shared-files $CURRENT_TASK\`
for the file list."
        fi
    fi
fi

# Mark the task closed (idempotent if already closed). Beads 0.47.x rejects
# "completed" — valid status is "closed".
if [ -n "$CURRENT_TASK" ] && command -v bd >/dev/null 2>&1; then
    bd update "$CURRENT_TASK" --status closed 2>/dev/null \
        || log_sync_error "bd update --status closed failed for $CURRENT_TASK at end of QA-approved flow"
fi

# Clean up tracking. Note: the legacy .qa-tracking/approved marker is no
# longer authoritative (B1/D1/J2). We still rm it to clean up stale files
# from older installs. Iteration counter cleanup covers both the per-task
# path (Phase 4 fix MATERIAL 5) and the legacy unscoped path.
rm -f "$QA_TRACKING_DIR/approved" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/changed-files.txt" 2>/dev/null || true
rm -f "$QA_TRACKING_DIR/edit-count" 2>/dev/null || true
rm -f "$ITERATION_FILE" 2>/dev/null || true
rm -f "$ITERATION_FILE_LEGACY" 2>/dev/null || true
# Spec 0.2: clear per-task escalation cache so a future cycle starts fresh.
if [ -n "$CURRENT_TASK" ]; then
    rm -f "$(last_test_rc_file_for "$CURRENT_TASK")" 2>/dev/null || true
    rm -f "$(last_failed_checks_file_for "$CURRENT_TASK")" 2>/dev/null || true
    rm -f "$(last_runner_file_for "$CURRENT_TASK")" 2>/dev/null || true
    rm -f "$(escalation_posted_file_for "$CURRENT_TASK")" 2>/dev/null || true
fi

# B2: if the epic gate had something to surface, emit it as a non-blocking
# note via additionalContext. Otherwise emit a clean {}.
if [ -n "$EPIC_DEFER_NOTE" ]; then
    NOTE_TEXT="QA gate cleared for $CURRENT_TASK.$EPIC_DEFER_NOTE"
    cat <<EOF
{"hookSpecificOutput":{"hookEventName":"Stop","additionalContext":$(printf '%s' "$NOTE_TEXT" | jq -Rs .)}}
EOF
    exit 0
fi

echo "{}"
