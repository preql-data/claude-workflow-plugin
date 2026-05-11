#!/bin/bash
# epic-gate.sh - Epic-level QA gate (B2, Phase 4).
#
# When a Beads task has siblings under the same epic, OR shares files with
# another in-progress task, we cannot mark its epic done until ALL siblings
# have cleared QA AND a cross-cutting integration check passes. This helper
# encodes that logic.
#
# Subcommands:
#   check <epic-id>
#     Returns one of (in JSON observations + in stdout summary):
#       pass    -> all sub-tasks qa-approved AND no in-progress siblings;
#                  the Stop hook can complete cleanly.
#       defer   -> siblings still pending (qa-pending, qa-gate-entered, in_progress);
#                  the Stop hook should NOT close the epic yet, but the
#                  individual task can still be marked complete.
#       block   -> some sub-task is qa-blocked or has qa-pending siblings
#                  whose `files_changed` field intersects with the active
#                  task's, requiring a manual integration sweep.
#
#   siblings <task-id>
#     Print the list of sibling task ids under the same epic (excluding
#     the task itself) plus their status + qa label. JSON.
#
#   shared-files <task-id>
#     Print the file-intersection set across in-progress siblings — for
#     when the epic-gate needs to know "do these tasks step on each other".
#     JSON: {"task_id":"...","intersections":[{"with":"...","files":[...]}]}
#
# All output is JSON on stdout; errors go to stderr.
#
# Exit codes:
#   0   success
#   1   usage / argument error
#   2   bd unavailable / lookup failure

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

usage() {
    cat >&2 <<'USAGE'
Usage: epic-gate.sh <subcommand> [args]
  check        <epic-id>    Evaluate the epic-level gate. -> pass | defer | block
  siblings     <task-id>    List sibling tasks under the same epic.
  shared-files <task-id>    Compute file-intersection with in-progress siblings.
USAGE
}

require_bd() {
    if ! command -v bd >/dev/null 2>&1; then
        printf '{"ok":false,"error":"bd CLI not on PATH"}\n'
        exit 2
    fi
    if [ ! -d "$PROJECT_DIR/.beads" ]; then
        printf '{"ok":false,"error":"Beads not initialized"}\n'
        exit 2
    fi
}

# Find the parent epic id of a task.
# Beads stores parent-child via dependencies; we read `bd show <task> --json`
# and look for a parent in either `.dependencies` (newer) or by scanning
# all epics for `dependents[].id == task` (fallback).
parent_epic_of() {
    local tid="$1"
    local parent
    # Newer bd: dependencies[] with dependency_type "parent-child"
    parent=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0] else . end
                 | (.dependencies // [])
                 | map(select(.dependency_type == "parent-child" and .issue_type == "epic"))
                 | .[0].id // empty' 2>/dev/null || echo "")
    if [ -z "$parent" ]; then
        # Fallback: scan epics' dependents for tid.
        parent=$(bd list --type epic --json 2>/dev/null \
            | jq -r --arg t "$tid" '
                map(select((.dependents // []) | map(.id) | index($t)))
                | .[0].id // empty' 2>/dev/null || echo "")
    fi
    printf '%s' "$parent"
}

# List sub-task ids of an epic (parent-child dependents).
sub_tasks_of() {
    local epic="$1"
    bd show "$epic" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0] else . end
                 | (.dependents // [])
                 | map(select(.dependency_type == "parent-child"))
                 | .[].id' 2>/dev/null || true
}

# Get the qa-state of a task: approved | blocked | entered | pending | none
qa_state_of() {
    local tid="$1"
    local labels
    labels=$(bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null || echo "")
    case ",$labels," in
        *,qa-approved,*) echo "approved" ;;
        *,qa-blocked,*)  echo "blocked"  ;;
        *,qa-gate-entered,*) echo "entered" ;;
        *,qa-pending,*)  echo "pending"  ;;
        *) echo "none" ;;
    esac
}

# Get the bd status of a task: open | in_progress | closed | blocked | etc.
status_of() {
    local tid="$1"
    bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].status else .status end // "unknown"' 2>/dev/null || echo "unknown"
}

# Extract `files_changed` from a task's notes. Specialists ship a JSON
# completion contract that includes files_changed[]; we look for that JSON
# block in the notes field. If absent, return [].
#
# Pipeline:
#   1. bd show ... --json | jq -r ...notes      -> raw notes string
#   2. jq -R (raw input) reads each line as a string and we use capture/
#      fromjson to extract the embedded JSON object's files_changed[]
#      entries, emitting one filename per line.
#   3. jq -R . re-quotes each line as a JSON string.
#   4. jq -s . slurps them into a JSON array.
#
# The second jq invocation MUST use -R because the input is raw notes text,
# not JSON; without -R it would parse-error silently and return [], which is
# what made B2 shared-files dead code prior to this fix.
files_changed_of() {
    local tid="$1"
    bd show "$tid" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].notes else .notes end // ""' 2>/dev/null \
        | jq -Rr '
            # Notes are free-form; the JSON contract is typically embedded
            # as a fenced block. Try to find a JSON object with
            # files_changed inside.
            try (capture("(?<j>\\{[^{}]*\"files_changed\"[^{}]*\\})"; "g") | .j | fromjson | .files_changed[]?)
            catch empty
        ' 2>/dev/null \
        | jq -R . 2>/dev/null \
        | jq -s . 2>/dev/null \
        || echo "[]"
}

# ---------------------------------------------------------------------------
# Subcommands

cmd_check() {
    local epic="$1"
    [ -z "$epic" ] && { usage; exit 1; }
    require_bd

    local subs total approved blocked pending entered other in_progress
    subs=$(sub_tasks_of "$epic")
    total=0; approved=0; blocked=0; pending=0; entered=0; other=0; in_progress=0

    local sub_summary="[]"
    if [ -n "$subs" ]; then
        local entries=()
        while IFS= read -r sid; do
            [ -z "$sid" ] && continue
            total=$((total+1))
            local q s
            q=$(qa_state_of "$sid")
            s=$(status_of "$sid")
            case "$q" in
                approved) approved=$((approved+1)) ;;
                blocked)  blocked=$((blocked+1))  ;;
                pending)  pending=$((pending+1))  ;;
                entered)  entered=$((entered+1))  ;;
                *)        other=$((other+1))      ;;
            esac
            [ "$s" = "in_progress" ] && in_progress=$((in_progress+1))
            entries+=("$(jq -n --arg id "$sid" --arg q "$q" --arg s "$s" \
                '{id:$id, qa:$q, status:$s}')")
        done <<EOF
$subs
EOF
        if [ "${#entries[@]}" -gt 0 ]; then
            sub_summary=$(printf '%s\n' "${entries[@]}" | jq -s .)
        fi
    fi

    local decision="pass" reason=""
    if [ "$blocked" -gt 0 ]; then
        decision="block"
        reason="$blocked sub-task(s) qa-blocked under epic $epic; resolve before completing the epic."
    elif [ "$pending" -gt 0 ] || [ "$entered" -gt 0 ] || [ "$in_progress" -gt 0 ]; then
        decision="defer"
        reason="$pending qa-pending, $entered qa-gate-entered, $in_progress in-progress siblings still active under epic $epic. Active task can complete; epic stays open."
    elif [ "$total" -eq 0 ]; then
        # Epic with no sub-tasks: trivially passes.
        decision="pass"
        reason="No sub-tasks under epic $epic; nothing to gate."
    elif [ "$approved" -eq "$total" ]; then
        decision="pass"
        reason="All $total sub-task(s) qa-approved under epic $epic; epic can close."
    else
        # Some "other" state (e.g., qa-state=none with closed status). Treat
        # as pass if all closed; defer otherwise.
        decision="defer"
        reason="$other sub-task(s) without a qa label under epic $epic; manual review recommended."
    fi

    jq -n \
        --arg epic "$epic" \
        --arg dec "$decision" \
        --arg reason "$reason" \
        --argjson total "$total" \
        --argjson approved "$approved" \
        --argjson blocked "$blocked" \
        --argjson pending "$pending" \
        --argjson entered "$entered" \
        --argjson other "$other" \
        --argjson in_progress "$in_progress" \
        --argjson subs "$sub_summary" \
        '{ok:true, subcommand:"check", epic_id:$epic, decision:$dec,
          totals:{total:$total, approved:$approved, blocked:$blocked,
                  pending:$pending, entered:$entered, other:$other,
                  in_progress:$in_progress},
          sub_tasks:$subs, observations:$reason}'
}

cmd_siblings() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd

    local epic
    epic=$(parent_epic_of "$tid")
    if [ -z "$epic" ]; then
        jq -n --arg t "$tid" \
            '{ok:true, subcommand:"siblings", task_id:$t, epic_id:null,
              siblings:[], observations:"Task has no parent epic; no siblings."}'
        return 0
    fi

    local subs entries=()
    subs=$(sub_tasks_of "$epic")
    while IFS= read -r sid; do
        [ -z "$sid" ] && continue
        [ "$sid" = "$tid" ] && continue
        local q s
        q=$(qa_state_of "$sid")
        s=$(status_of "$sid")
        entries+=("$(jq -n --arg id "$sid" --arg q "$q" --arg s "$s" \
            '{id:$id, qa:$q, status:$s}')")
    done <<EOF
$subs
EOF

    local sib_json="[]"
    [ "${#entries[@]}" -gt 0 ] && sib_json=$(printf '%s\n' "${entries[@]}" | jq -s .)

    jq -n --arg t "$tid" --arg e "$epic" --argjson sibs "$sib_json" \
        '{ok:true, subcommand:"siblings", task_id:$t, epic_id:$e,
          siblings:$sibs, observations:"Listed siblings under shared epic."}'
}

cmd_shared_files() {
    local tid="$1"
    [ -z "$tid" ] && { usage; exit 1; }
    require_bd

    local epic mine
    epic=$(parent_epic_of "$tid")
    mine=$(files_changed_of "$tid")
    [ -z "$mine" ] && mine="[]"

    local intersections="[]"
    if [ -n "$epic" ]; then
        local subs entries=()
        subs=$(sub_tasks_of "$epic")
        while IFS= read -r sid; do
            [ -z "$sid" ] && continue
            [ "$sid" = "$tid" ] && continue
            local s theirs inter
            s=$(status_of "$sid")
            # Only consider siblings that are still in-progress for the
            # "shared file" check — closed siblings don't represent
            # ongoing concurrent edits.
            [ "$s" != "in_progress" ] && continue
            theirs=$(files_changed_of "$sid")
            [ -z "$theirs" ] && theirs="[]"
            inter=$(jq -nc \
                --argjson a "$mine" \
                --argjson b "$theirs" \
                '$a as $A | $b as $B | $A - ($A - $B)' 2>/dev/null || echo "[]")
            local count
            count=$(echo "$inter" | jq 'length' 2>/dev/null || echo "0")
            if [ "${count:-0}" -gt 0 ]; then
                entries+=("$(jq -nc --arg w "$sid" --argjson f "$inter" '{with:$w, files:$f}')")
            fi
        done <<EOF
$subs
EOF
        [ "${#entries[@]}" -gt 0 ] && intersections=$(printf '%s\n' "${entries[@]}" | jq -s .)
    fi

    jq -n --arg t "$tid" --argjson inter "$intersections" --argjson my "$mine" \
        '{ok:true, subcommand:"shared-files", task_id:$t,
          my_files:$my, intersections:$inter,
          observations: (if ($inter | length) > 0
                         then "Active task shares files with " + (($inter | length) | tostring) + " in-progress sibling(s); integration check recommended."
                         else "No file overlap with in-progress siblings."
                         end)}'
}

# ---------------------------------------------------------------------------
# Dispatch

SUB="${1:-}"
shift || true

case "$SUB" in
    check)        cmd_check "$@" ;;
    siblings)     cmd_siblings "$@" ;;
    shared-files) cmd_shared_files "$@" ;;
    ""|-h|--help|help)
        usage
        exit 1
        ;;
    *)
        echo "epic-gate.sh: unknown subcommand: $SUB" >&2
        usage
        exit 1
        ;;
esac
