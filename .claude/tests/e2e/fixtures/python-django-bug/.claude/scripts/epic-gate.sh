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
#   plan-batches <epic-id> [--design <path>]
#     v5 D4b (claude-workflow-plugin-fkm.6). Computes a dependency-
#     respecting, file-set-non-intersecting parallel batch plan over an
#     epic's design units — non-intersection scoped to a NAMED residual
#     (R5-F3): see "WHAT THE FILE-SET CLAIM IS ESTABLISHED OVER" in the
#     contract header. See `usage()` below and the header comment
#     immediately above `cmd_plan_batches` for the full contract — it is
#     long enough to deserve its own block rather than a repeat here.
#
# All output is JSON on stdout; errors go to stderr.
#
# Exit codes:
#   0   success
#   1   usage / argument error
#   2   bd unavailable / lookup failure

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# v5 D4b (claude-workflow-plugin-fkm.6). plan-batches shells out to both —
# neither script is sourceable (no bd-compat library exists; review-check.sh
# is the ONE DESIGN-UNITS parser and qa-gate.sh is the ONE authoritative
# reader of compute_design_satisfied/latest_design_unit_binding). Same
# "shell out, never re-implement" discipline cmd_design_unit_bind already
# uses for review-check.sh (qa-gate.sh:7818 REVIEW_CHECK_SCRIPT).
QA_GATE_SCRIPT="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
REVIEW_CHECK_SCRIPT="$PROJECT_DIR/.claude/scripts/review-check.sh"
WORKFLOW_MANIFEST_SCRIPT="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"

usage() {
    cat >&2 <<'USAGE'
Usage: epic-gate.sh <subcommand> [args]
  check        <epic-id>    Evaluate the epic-level gate. -> pass | defer | block
  siblings     <task-id>    List sibling tasks under the same epic.
  shared-files <task-id>    Compute file-intersection with in-progress siblings.
  plan-batches <epic-id> [--design <path>]
                             v5 D4b: compute a dependency-respecting,
                             file-set-non-intersecting parallel batch plan
                             over an epic's children, from the epic's
                             design (docs/plans/v5-design-phase.md:158-159).
                             File-set non-intersection is established up
                             to ONE named residual (R5-F3, disclosed in
                             the contract header): two declared spellings
                             that are Unicode-normalisation-equivalent or
                             non-ASCII-case-equivalent, where NEITHER
                             path exists yet and no symlink is involved,
                             are not detected and can co-batch.
                             Every guard-list degradation (including
                             jq_unavailable, R1-F7) exits 0 with a full
                             envelope — never a crash a `|| echo '{}'`
                             caller could misread as permissive. Only a
                             pure usage error (missing <epic-id>, an
                             unrecognised flag) exits nonzero, matching
                             every other subcommand's convention, with a
                             minimal envelope that has no plan to report. `parallel_safe` is the safe-default
                             flag (true ONLY when positively established);
                             `degradation_reason` names why otherwise.
                             Degraded batches collapse to one task per
                             batch ONLY when the child ids and a
                             dependency-safe order over them are both
                             available; otherwise batches is explicitly
                             [] (R7-F8 — see the contract header's
                             degraded-batches note for the [] paths). The
                             `impact_of` half is deferred (claude-workflow-
                             plugin-l7gd); `graph_intersection_computed` is
                             always false this release and is independent
                             of `parallel_safe` — file-set-only batching is
                             a real, usable answer, just a narrower one.
                             `--design <path>` ASSERTS the derived artifact
                             path (docs/specs/<epic-id>.md or its repo-
                             relative spelling) the same way qa-gate.sh
                             design-record's `--file` does; it is never a
                             second source for the artifact location.
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
#
# i8cx: both `bd ... | jq ...` pipes below are restructured so `bd`'s own
# failure is observed BEFORE jq ever runs, rather than letting jq's empty-
# input non-error (jq on truly empty stdin exits 0 with no output) stand in
# for it. jq now runs on an in-memory-captured string (printf producer,
# cannot itself mask a pipe stage), so the only remaining fallible step is
# `bd` itself, and its rc gates whether jq is even invoked. Fixed as a
# judgement call: this helper is shared with cmd_shared_files (out of scope
# per this task's constraints), but the change is failure-path-only — the
# happy path (bd succeeds) is byte-identical — so cmd_shared_files' own
# behaviour is unaffected on any input it is tested against; see the
# completion report for the full reasoning.
parent_epic_of() {
    local tid="$1"
    local parent="" show_out="" rc=0
    # Newer bd: dependencies[] with dependency_type "parent-child"
    show_out=$(bd show "$tid" --json 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$show_out" ]; then
        parent=$(printf '%s' "$show_out" | jq -r 'if type == "array" then .[0] else . end
                 | (.dependencies // [])
                 | map(select(.dependency_type == "parent-child" and .issue_type == "epic"))
                 | .[0].id // empty' 2>/dev/null) || parent=""
    fi
    if [ -z "$parent" ]; then
        # Fallback: scan epics' dependents for tid.
        local list_out="" lrc=0
        list_out=$(bd list --type epic --json 2>/dev/null) || lrc=$?
        if [ "$lrc" -eq 0 ] && [ -n "$list_out" ]; then
            parent=$(printf '%s' "$list_out" | jq -r --arg t "$tid" '
                map(select((.dependents // []) | map(.id) | index($t)))
                | .[0].id // empty' 2>/dev/null) || parent=""
        fi
    fi
    printf '%s' "$parent"
}

# bd_show_with_dependents <id> — `bd show --json` that always carries the
# REVERSE edges (.dependents), across the supported bd range.
#
# Same break as .comments, different field: bd 1.1.2 stopped inlining
# .dependents in `bd show --json` (it returns a `dependent_count` integer) and
# needs the new --include-dependents flag for the array. bd 0.47.x has no such
# flag and exits 1 on it, but inlines .dependents already — so try the new
# form, fall back to the plain one. Pin the CHAIN, not the leg.
#
# Without this, sub_tasks_of() returns EMPTY for every epic under 1.1.2, and an
# epic with unapproved children reads as an epic with no children — the gate
# would pass vacuously. Note parent_epic_of() does NOT need this: it reads
# .dependencies (FORWARD edges), which 1.1.2 still inlines. Its `bd list --type
# epic` fallback does scan .dependents, but list entries never carried them on
# either version (bd-compat.sh pin #21), so that leg stays a no-op as designed.
bd_show_with_dependents() {
    bd show "$1" --json --include-dependents 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

# List sub-task ids of an epic (parent-child dependents).
sub_tasks_of() {
    local epic="$1"
    bd_show_with_dependents "$epic" \
        | jq -r 'if type == "array" then .[0] else . end
                 | (.dependents // [])
                 | map(select(.dependency_type == "parent-child"))
                 | .[].id' 2>/dev/null || true
}

# Get the qa-state of a task: approved | blocked | entered | pending | none
#
# i8cx: `bd show` is the fallible producer; jq is last, so its own failure
# already fell through `|| echo ""` correctly — but a FAILED `bd show`
# (task deleted mid-scan, a transient bd hiccup) produced the SAME empty
# `labels` as a genuinely-labelless task, because jq on truly empty stdin
# exits 0 printing nothing (no error to trip the `||`). Restructured so bd's
# own rc gates whether jq runs at all, making the two cases distinguishable
# in principle. In cmd_check specifically this masked case already fell
# through the qa_state `*) other` bucket into `decision="defer"` (never a
# false "pass"), so this closes an information loss, not a live pass/fail
# defect in the one caller that gates anything — see the completion report.
qa_state_of() {
    local tid="$1"
    local labels="" show_out="" rc=0
    show_out=$(bd show "$tid" --json 2>/dev/null) || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$show_out" ]; then
        labels=$(printf '%s' "$show_out" | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null) || labels=""
    fi
    case ",$labels," in
        *,qa-approved,*) echo "approved" ;;
        *,qa-blocked,*)  echo "blocked"  ;;
        *,qa-gate-entered,*) echo "entered" ;;
        *,qa-pending,*)  echo "pending"  ;;
        *) echo "none" ;;
    esac
}

# Get the bd status of a task: open | in_progress | closed | blocked | etc.
#
# i8cx: same shape as qa_state_of above. Previously, a FAILED `bd show`
# produced jq-on-empty-stdin (exits 0, prints nothing) rather than the
# documented "unknown" fallback — the `// "unknown"` default only fires for a
# present-but-null `.status` field, never for zero bytes of input, so the
# `|| echo "unknown"` was dead for this exact case. Restructured so a failed
# bd read is observable and produces the documented "unknown" for real.
status_of() {
    local tid="$1"
    local show_out="" rc=0
    show_out=$(bd show "$tid" --json 2>/dev/null) || rc=$?
    if [ "$rc" -ne 0 ] || [ -z "$show_out" ]; then
        printf '%s' "unknown"
        return 0
    fi
    printf '%s' "$show_out" | jq -r 'if type == "array" then .[0].status else .status end // "unknown"' 2>/dev/null || printf '%s' "unknown"
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
# plan-batches (v5 D4b, claude-workflow-plugin-fkm.6)
#
# docs/plans/v5-design-phase.md:158-159 (the release-defining spec; the
# implementation-plan doc's own D4 section is stale — see the delegation
# brief filed on this task). Computes which of an epic's children can run
# CONCURRENTLY: their design units' declared file sets must not intersect,
# and (docs/plans/v5-design-phase.md:158) their impact_of sets must not
# intersect either — deferred to claude-workflow-plugin-l7gd; this slice is
# FILE-SET-ONLY, and that narrowing is NAMED on every envelope
# (graph_intersection_computed:false), never silent. Dependency order is
# REQUIRED (":159"), not optional.
#
# WHAT THE FILE-SET CLAIM IS ESTABLISHED OVER (R5-F3, independent review
# xsu1 round 5 — the CLAIM is narrowed to the code, the code is not
# widened to the claim). "File sets must not intersect" is established
# exactly over these alias classes — two declared spellings are recognised
# as the same file when ANY of the following holds:
#   - they are byte-identical (the batching reduce's own intersection);
#   - either spelling is, or passes through, a symlink — leaf or ancestor,
#     dangling or not (alias pass 1, -L: the whole plan degrades);
#   - both spellings already exist on disk and name one device+inode
#     (alias pass 2, -ef — this also covers Unicode/case aliasing whenever
#     at least one side exists on a filesystem that folds them, because
#     the folding filesystem resolves the other spelling to the same
#     inode);
#   - they are ASCII-case-equivalent (the case-collision gate;
#     ascii_downcase folds exactly ASCII).
# NOT CAUGHT, disclosed rather than implied closed: two spellings that
# are Unicode-normalisation-equivalent (NFC/NFD) or non-ASCII-case-
# equivalent (e.g. Cyrillic case folding) where NEITHER path exists yet
# and NO symlink is involved. Those can co-batch even though a
# normalising/folding filesystem will later treat them as one file.
# DECIDED (R5-F3, operator call): this residual is DISCLOSED, not
# degraded on — failing closed on every non-ASCII declared path would
# cost any project with a single non-ASCII filename ALL parallel
# batching, and bash 3.2 offers no reliable NFC/NFD fold with which to
# narrow that over-degradation later. `parallel_safe:true` therefore
# means: positively established up to exactly this named residual,
# nothing wider — a residual bounded to the real limit is honest, where
# one drawn wider than the code would hide fixable defects behind an
# unfixable one.
#
# FOUR DECISIONS, SETTLED (not re-litigated here):
#   1. The manifest ($QA_TRACKING_DIR/design-batch-<epic>.json) is a
#      REGENERABLE CACHE, never an authority — it carries design_hash so a
#      consumer can detect staleness and re-run plan-batches rather than
#      trust it. $QA_TRACKING_DIR is per-checkout and gitignored (same
#      directory impact-report.sh and qa-gate.sh already use for the same
#      reason); a stale/absent manifest means regenerate, never guess.
#   2. `parallel_safe` (not `degraded`) is the safe-default boolean: it is
#      true ONLY when positively established, so `.parallel_safe // false`
#      (the house `$(cmd) || echo '{}'` consumer idiom,
#      verify-before-stop.sh:6145-6153) reads a crash, an absent field, or
#      a malformed response as UNSAFE — never as "fully parallel", which is
#      what `.degraded // false` would have yielded for the same inputs.
#      `degradation_reason` carries the machine token; prose lives in
#      `observations` (qa-gate.sh:130-131's split).
#   3. The impact_of half is out of scope (l7gd); `graph_intersection_
#      computed:false` and `graph_degradation_reason:"code_graph_absent"`
#      are ALWAYS present (this release never attempts the call, which the
#      consumer-facing outcome of "attempted and found absent" already
#      covers). This does NOT force `parallel_safe:false` — file-set-only
#      batching is a real, correct, USABLE answer, just a narrower one than
#      the full spec envisions; see the guard-list note below on why this
#      condition is structurally different from the OTHERS (a deliberate
#      qualifier, never a fixed count -- R2-F6/R3-F4, independent review:
#      this guard list has already grown twice under review, and a bare
#      cardinality claim here is exactly the drift docs/HOOKS.md's own
#      description was rewritten to stop repeating).
#   4. NO LOCK. This subcommand is computation plus bd/subprocess reads plus
#      one cache write; the write is tmp-then-`mv -f` (qa-gate.sh:339,365's
#      idiom — no flock on this host, post-edit.sh:440), never flock.
#      `_design_unit_lock_root` is NOT lifted here — that closes a
#      different, write-side rebind race this subcommand does not have.
#
# WHY THIS SUBCOMMAND ALONE NEVER USES `require_bd` OR EXITS NONZERO FOR
# ANYTHING BUT A PURE USAGE ERROR. Every OTHER infra guard in this file and
# in qa-gate.sh treats "bd unavailable" / "validator missing" as a hard
# refusal (exit 2, a DIFFERENT and narrower envelope shape with no
# `parallel_safe` key). For a hard GATE (design-conform, approve) that is
# correct: a gate that cannot check must not silently pass. plan-batches is
# not a gate, it is a SCHEDULING ADVISORY whose safe fallback (serial, one
# task per batch) is ALWAYS available regardless of what failed — so making
# every failure mode collapse into the SAME full envelope with
# `parallel_safe:false` is what keeps a crashed or degraded run from ever
# reading, through the house `|| echo '{}'` idiom, as "everything can run in
# parallel". "Serial is always safe. A non-degraded wrong plan is the only
# dangerous outcome" (the delegation brief, verbatim).
#
# TWO SENTINELS, NOT ONE. # PLAN-BATCHES-NO-DESIGN-GUARD BEGIN/END below
# delimits the WHOLE guard ladder for readability; it is NOT itself a clean
# strip target — every check inside it is independently fail-closed against
# a DIFFERENT structural failure (verified empirically: stripping the
# design-status check alone still degrades via validate-design's own
# missing-file check; stripping that too still degrades via the TOCTOU
# re-hash; stripping the WHOLE outer region breaks the function's own brace
# matching and does not even parse). R1-F5/R2-F1 found FIVE checks with NO
# redundant downstream backup — an unbound/stale/orphaned child binding, a
# zero-children epic, a non-canonical path spelling, a symlink/inode alias,
# and a multiply-bound unit each simply vanish or misresolve silently rather
# than tripping any OTHER shape/rc check — and each is narrowly sentinelled
# on its own, so a mutant can isolate exactly one:
# # PLAN-BATCHES-EPIC-CHILDREN-GATE, # PLAN-BATCHES-CANONICAL-PATH-GATE,
# # PLAN-BATCHES-ALIAS-GATE, # PLAN-BATCHES-CHILD-BINDING-GATE (this file's
# Mutant 3 target), and # PLAN-BATCHES-MULTIBIND-GATE, all BEGIN/END further
# down. This list grew twice already (R1-F5 added four, R2-F1 added the
# fifth), and round 4 added two more of exactly the predicted shape:
# # PLAN-BATCHES-CONTROL-CHAR-GATE (R4-F3 — a control character in a
# declared path is visible to nothing else once command substitution has
# stripped it) and # PLAN-BATCHES-ALIAS-CARDINALITY-GATE (R4-F1 — a
# successful-but-empty flattening is visible to nothing else once the alias
# arrays are simply short) — a future finding of the same shape gets its
# own sentinel, not a footnote here.
#
# THE GUARD LIST (# PLAN-BATCHES-NO-DESIGN-GUARD BEGIN/END below). Every one
# of these — EXCEPT the graph-intersection note (#3 above, which qualifies a
# real answer rather than discarding it) — collapses the ENTIRE run to
# `parallel_safe:false`. The degraded `batches` field then takes exactly ONE
# of two shapes (R7-F8 reconciled this wording with what the code has done
# since the round-5/round-7 refusals landed; docs/HOOKS.md carries the same
# statement):
#   - ONE TASK PER BATCH, DETERMINISTICALLY ordered (never bd's own
#     unsorted child-enumeration order — see _pb_degrade's own header for
#     the LC_ALL=C-sort-plus-topological schedule it computes), emitted
#     ONLY when the child ids could be enumerated AND a dependency-safe
#     order over them is computable from the published binding and
#     dependency data;
#   - EXPLICITLY [], with an annotated observations line, whenever either
#     half is unavailable: degradations that fire before children can be
#     enumerated (bd unusable, an unreadable or child-less epic), the
#     jq_unavailable and envelope-construction fallbacks, a failed
#     (unit_id, task_id) pair encoding after the bindings were read, a
#     failed re-extraction of the validated design's own
#     unit_ids/unit_files/unit_deps declarations (R8-F1 — the dependency
#     data is unreadable, so no order can be trusted), and
#     the schedule construction's own refusals — an input-cardinality
#     mismatch, a residual cycle, or (R7-F1) a bound unit whose design
#     dependency has no bound implementing task. An ordering that could
#     not be computed, or that would erase a known design edge, is never
#     emitted as a runnable one.
# Never a partial/mixed plan. A single bad child degrades the whole plan
# rather than being quietly excluded, because "some of this batch plan is
# trustworthy" is exactly the confidence a consumer of a `|| echo
# '{}'`-guarded advisory cannot safely act on selectively:
#   epic_children_unreadable    bd absent, or a plain `bd show <epic>` did
#                                not return a real task (folds "bd totally
#                                missing" and "this specific read failed"
#                                into ONE reason, matching how sub_tasks_of
#                                already can't tell them apart internally —
#                                epic-gate.sh:93-98's own header records the
#                                cmd_check precedent for NOT doing this)
#   epic_has_no_children         the epic was confirmed readable but has
#                                zero parent-child dependents. Deliberately
#                                NOT cmd_check's "nothing to gate -> pass"
#                                (:214-217) — that shape shipped once
#                                already as the live defect its own header
#                                warns about; the two states are otherwise
#                                indistinguishable in the envelope
#   validator_unavailable       review-check.sh missing
#   qa_gate_unavailable         qa-gate.sh missing (design-status /
#                                design-unit-show both shell out to it)
#   hash_tool_unavailable       workflow-manifest.sh missing (the TOCTOU
#                                re-hash bracket needs it)
#   <compute_design_satisfied's key, VERBATIM> no_design_attempted /
#                                design_verdict_missing / design_not_
#                                satisfied / design_hash_unreadable /
#                                design_artifact_unreadable /
#                                design_verdict_stale — read through
#                                qa-gate.sh design-status, which is
#                                DELIBERATELY not design-gate-precheck: that
#                                subcommand's `no_design_attempted` ->
#                                "ready" leniency is the correct, documented
#                                choice for ITS caller (most tasks never
#                                have a design phase) and would be
#                                indistinguishable-from-satisfied here,
#                                where "no design" means "no units to
#                                batch", which must degrade
#   design_status_unavailable   the design-status call itself did not
#                                return a well-formed answer
#   artifact_path_not_derived   --design was given and disagrees with the
#                                DERIVED artifact path (docs/specs/<epic-
#                                id>.md or its repo-relative spelling) —
#                                the SAME "assertion, never a source"
#                                convention as qa-gate.sh design-record's
#                                --file (qa-gate.sh:6683-6712); --design
#                                is never a second way to point the plan at
#                                an unreviewed artifact outside docs/specs/
#   <validate-design's error_key, VERBATIM>  any schema/sentinel/fence/
#                                cycle failure on the design artifact
#   validate_design_unavailable the validate-design call failed (nonzero
#                                rc — R4-F2: the exit status counts even
#                                when the printed envelope parses,
#                                matching the design-status ladder) or did
#                                not return a well-formed answer
#   design_verdict_stale        THE CLOSING BRACKET — the artifact's live
#                                hash, re-checked AFTER validate-design, no
#                                longer matches design-status's confirmed-
#                                fresh hash (the same TOCTOU discipline as
#                                design-record's and design-conform's own
#                                pre/post brackets — fkm.3 R2-F3/R3-F4,
#                                reused not reinvented)
#   set_computation_failed      any jq call in the fold — the defensive
#                                unit_files/unit_deps presence check, the
#                                control-character check, the
#                                canonical-path check, the alias-flattening
#                                and its cardinality verification (R4-F1:
#                                the flattened pair count must equal the
#                                sum of every declared files[] length — a
#                                successful-but-EMPTY or PARTIAL result is
#                                a computation that did not happen, never
#                                "nothing to check"), the validated
#                                design's declaration re-extraction
#                                (R8-F1: rc-AND-shape checked, never the
#                                pre-round-8 substituted []/{} that told
#                                the degrade path "no edges"), the (unit_id,
#                                task_id) pair encoding (R5-F2/R5-F4: ONE
#                                guarded, cardinality-checked program; if
#                                it fails after the bindings were read,
#                                the degrade passes NO child ids, so no
#                                serial order is emitted that could
#                                contradict an edge the artifact
#                                declares), the resolvable-set
#                                derivation, the duplicate-binding check, or
#                                the batching computation itself — returned
#                                a nonzero rc OR a wrong-shaped result.
#                                NEVER `... 2>/dev/null || echo "[]"` (the
#                                fail-OPEN wrapper at epic-gate.sh:311 this
#                                subcommand must not inherit); every call is
#                                `cmd || rc=$?` (never `x=$(cmd); rc=$?`,
#                                which trips errexit AT THE ASSIGNMENT under
#                                this file's `set -e`) and checked on BOTH
#                                rc and the shape of what it produced,
#                                matching qa-gate.sh:8391-8426's discipline
#   unit_files_missing_for_declared_unit  a unit_id in unit_ids has no
#                                entry in unit_files or unit_deps. Should be
#                                unreachable given validate-design's own
#                                schema guarantee on a .ok==true artifact —
#                                checked anyway, because `null - []` is a jq
#                                ERROR (rc 5, probed) that would abort the
#                                WHOLE fold, turning one malformed unit into
#                                "everything parallel" if unguarded
#   declared_path_contains_control_chars  a declared file in ANY unit's
#                                `files[]` contains a control character
#                                (0x00-0x1f or 0x7f) — most sharply a
#                                TRAILING NEWLINE, which every command
#                                substitution strips, so the alias passes
#                                would check a different spelling than the
#                                byte-exact one the batching intersection
#                                compares (R4-F3, independent review xsu1
#                                round 4). Rejected, never sanitised (the
#                                bjx class); validate-design itself accepts
#                                these (its nonempty_string only rejects
#                                the all-whitespace case), so this gate is
#                                the only detection point
#   declared_paths_not_canonical  a declared file in ANY unit's `files[]`
#                                is absolute, contains a `.`/`..` segment,
#                                a `//`, or a trailing `/`. Byte-equality
#                                intersection over such spellings can read
#                                two writers of one file as disjoint
#                                (src/a.sh vs ./src/a.sh vs an absolute
#                                path). Chosen resolution (one of two the
#                                brief names as acceptable): DEGRADE rather
#                                than normalize — impact-report.sh's own
#                                relativizer is built for TRACKED, on-disk
#                                change-set paths (qa-gate.sh:8143-8161) and
#                                design-time `files[]` declarations carry no
#                                such guarantee. Case is DELIBERATELY NOT
#                                folded: two differently-cased paths are
#                                genuinely different files on a
#                                case-sensitive filesystem (this repo's own
#                                Linux CI tier), and folding them would be
#                                WRONG there even though doing so would be
#                                safer on this host's default
#                                case-insensitive APFS
#   declared_paths_case_collision  two declared paths differ ONLY in case
#                                (R1-F3, independent review xsu1 round 1)
#                                -- a genuine collision on a case-
#                                insensitive filesystem (this host's
#                                default APFS), even though case is never
#                                folded generally (see the entry above)
#   declared_path_traverses_symlink  a declared file, or an ancestor
#                                directory strictly between it and
#                                $PROJECT_DIR, is a symlink -- tested with
#                                -L, true regardless of whether the
#                                target exists (R3-F1/R3-F2, independent
#                                review xsu1 round 3, replacing round 2's
#                                resolve-a-key-and-compare
#                                _pb_canonical_key, removed). NOT a claim
#                                that two specific declarations collide;
#                                a refusal to reason about file-set
#                                disjointness at all once a symlink is
#                                anywhere in a declared path, dangling or
#                                not
#   declared_paths_alias_same_file  two declared paths that ALREADY BOTH
#                                EXIST on disk are the same file by
#                                device+inode (-ef) regardless of
#                                spelling mechanism -- case-insensitive
#                                folding, Unicode NFC/NFD normalisation,
#                                a hard link, anything the OS itself
#                                already treats as one file (R2-F1's pass
#                                2, unchanged in mechanism since round 2;
#                                only its own extraction discipline was
#                                fixed in round 3, R3-F1)
#   design_unit_show_unavailable  a child's design-unit-show call itself
#                                did not return a well-formed answer —
#                                distinct from a CLEAN bound:false read
#   design_unit_binding_missing  a child has no DESIGN-UNIT v1 binding at
#                                all — "an unconstrained writer invisible
#                                to the plan" (the brief, verbatim); NOT
#                                unified with unit_not_in_design below,
#                                unlike design-conform's own choice to unify
#                                "never bound" and "bound-but-stale" for
#                                ITS different, per-task caller — an
#                                epic-wide caller benefits from the two
#                                remedies (bind it / re-bind after an
#                                amendment) staying distinguishable
#   unit_not_in_design           a child's bound unit_id is not among the
#                                CURRENT artifact's declared units (an
#                                amendment likely dropped or renamed it) —
#                                reusing design-conform's own token
#                                (qa-gate.sh:8318-8324) since it is the
#                                identical actionable fact
#   binding_design_hash_stale     a child's binding names a design_hash
#                                that differs from the current governing
#                                hash. THIS CHECK DID NOT EXIST ANYWHERE
#                                BEFORE THIS SLICE (verified: binding_json's
#                                design_hash is read in exactly one place
#                                pre-D4b, qa-gate.sh design-conform:8320,
#                                and only to INTERPOLATE into an error
#                                string — never compared)
#   unit_bound_to_multiple_tasks  two (or more) children resolve cleanly to
#                                the SAME unit_id. The rebind gate
#                                (qa-gate.sh design-unit-bind) is keyed
#                                per-TASK only (`latest_design_unit_binding
#                                "$tid"`, :7963-7972/:7986-7995) — nothing
#                                scans other tasks for the same unit, so
#                                this is the first place this conflict is
#                                even detectable
#   unit_depends_on_unresolved_unit  a RESOLVABLE unit (one with a clean
#                                implementing child) depends_on a unit with
#                                NO implementing child at all (R1-F1,
#                                independent review xsu1 round 1). A
#                                missing prerequisite is missing
#                                INFORMATION about whether that
#                                prerequisite is even started, not an
#                                absent dependency safe to schedule
#                                around — see the note just below on why
#                                this is never silently dropped
#
# UNITS WITH NO IMPLEMENTING CHILD YET are NOT a guard condition — ordinary,
# incremental task-per-unit progress, not a defect (`design-unit-bind` has
# no live caller yet at all — claude-workflow-plugin-6im2 — so a partially-
# bound epic is the ONLY shape this can be exercised against today). They
# are named under `unresolved_unit_ids` and simply excluded from the
# resolvable set R that batching computes over.
#
# A dependency edge FROM a unit in R TO a unit NOT in R is NEVER silently
# dropped and continued (R1-F1, independent review xsu1 round 1): the unit
# on the R side of that edge is detected as `blocked` and degrades the WHOLE
# PLAN (`unit_depends_on_unresolved_unit`, the same whole-run collapse every
# other guard in this list uses) — because a missing prerequisite is missing
# INFORMATION about whether that prerequisite is even started, not an absent
# dependency safe to schedule around. The batching computation's own input
# derivation (`$ud_r`, right before the batching reduce) still filters each
# surviving unit's dependency list down to edges that land inside R — but by
# the time that computation runs, `blocked` being empty has already proven
# every such edge lands inside R, so that filter is defensive redundancy on
# the clean path, not the mechanism that keeps a real out-of-R edge from
# being silently ignored. That mechanism is `blocked` above it.
#
# THE BATCHING ALGORITHM. Greedy first-fit over R in WAVES derived from the
# (filtered) dependency graph: each wave is every not-yet-placed unit whose
# dependencies are all already placed, processed IN ARTIFACT ORDER (R is
# built by filtering unit_ids, which preserves relative order, so no
# separate index-tracking/sort is needed — a wave, itself a filtered
# comprehension over the order-preserving `remaining` array, is already in
# artifact order). Within a wave, each unit's eligible batch range starts
# STRICTLY AFTER the latest batch any of its dependencies landed in
# (min_start), and the first batch at-or-after min_start whose ACCUMULATED
# FILE UNION (never just its first or most recent member — the union is
# carried and grown as `.files` on the batch object) does not intersect the
# candidate's files gets it; if none do, a new batch opens. Bounded by
# `range(0; N+1)` waves (N = |R|) rather than an unbounded `until`, so a
# residual cycle within R — which should be impossible, since R's
# dependency graph is an induced subgraph of the whole artifact's already-
# verified-acyclic graph (validate-design's own Kahn check) — surfaces as
# `set_computation_failed` rather than hanging.
#
# DETERMINISM. Iterates `unit_ids` (artifact order) and `keys_unsorted`
# (never `keys`, which SORTS — probed divergent on this exact shape) for
# every map read; no timestamp anywhere in the envelope (the manifest and
# stdout are the SAME bytes); heredoc-fed bash arrays, never a pipe, for
# every accumulating loop (children_arr; the binding loop's bound_units/
# bound_tasks and problem_tasks/reasons/details arrays are plain +=);
# `cmd || rc=$?` throughout, never `x=$(cmd); rc=$?`.
# ---------------------------------------------------------------------------

# _pb_path_has_symlink <declared-relative-path> (R3-F1/R3-F2, independent
# review xsu1 round 3 -- REPLACES the round-2 `_pb_canonical_key`, removed).
#
# R1-F3's case-collision check is a pure STRING comparison and cannot see
# that two BYTE-DIFFERENT declared paths identify the SAME filesystem entry
# through a SYMLINKED ancestor directory -- this repo's own `tests ->
# .claude/scripts/tests` is exactly this shape (confirmed with `readlink
# tests`). Round 2 closed this with a "resolve a canonical key, group,
# compare" chain (`_pb_canonical_key`, since removed). Round 3 found two
# problems with that chain, not one: (a) it used -d/-e throughout, which
# FOLLOW a symlink to its target and therefore cannot distinguish "a
# symlink to a directory" from "a DANGLING symlink whose target does not
# exist at all" from "not a symlink" -- so `alias.sh -> real.sh` where
# `real.sh` does not exist yet went undetected on EITHER side (R3-F2); and
# (b) every jq extraction added to resolve-and-compare-keys was its own
# new fail-open opportunity if it failed (the FOURTH instance of that exact
# class in this slice, R3-F1) -- the pass kept growing extractions, and an
# ever-growing chain on the parallel_safe:true safety path is the wrong
# direction to keep pushing a fix in.
#
# The REPLACEMENT is deliberately smaller: it does not try to establish
# THAT two specific declarations collide. It asks only whether a declared
# path, or any ancestor directory strictly between it and $PROJECT_DIR,
# is a symlink AT ALL -- tested with -L, which (unlike -d/-e) is true for
# a symlink regardless of whether its target exists, is a directory, or is
# a plain file. If so, the caller refuses to reason about file-set
# disjointness for the WHOLE plan and degrades unconditionally -- no
# resolved key, no cross-file grouping, no comparison, nothing left in
# this specific check for a failed extraction to silently drop. The
# DELIBERATE cost, matching the four settled decisions ("serial is always
# safe; a non-degraded wrong plan is the only dangerous outcome"): a unit
# declaring `tests/...` in THIS repo now always degrades the plan to
# serial, even against a sibling unit that shares no real file with it --
# precision traded for a mechanism with no chain left to have a bug in.
#
# This DOES fully close R3-F2 as a structural consequence, not a special
# case: -L answers "is this a symlink" without ever needing the target to
# exist, so a dangling symlink (leaf or ancestor) is caught exactly the
# same way a resolving one is. What it deliberately does NOT see: two
# spellings that are Unicode-normalisation-equivalent or non-ASCII-case-
# equivalent where NEITHER exists yet and NEITHER involves a symlink at
# all -- closing THAT needs either assumed filesystem state a design-time
# declaration cannot rely on, or a Unicode-normalisation dependency this
# script does not carry. See the ALIAS-GATE block below for how that
# residual is now scoped (narrower than before this fix: dangling symlinks
# are no longer part of it).
#
# Never fails the caller: the loop is bounded by reaching $PROJECT_DIR
# (which always exists, by construction of $PROJECT_DIR itself) or `/`;
# worst case (no symlink anywhere in the path) returns 1 (false), exactly
# the answer a path with nothing aliasing it should get.
_pb_path_has_symlink() {
    local rel="$1"
    local candidate="$PROJECT_DIR/$rel"
    while [ "$candidate" != "$PROJECT_DIR" ] && [ "$candidate" != "/" ]; do
        [ -L "$candidate" ] && return 0
        candidate=$(dirname "$candidate")
    done
    return 1
}

# _pb_manifest_path <epic-id> -- $QA_TRACKING_DIR/design-batch-<sanitized>.json
# Same sanitisation formula as qa-gate.sh's impact_report_path_for /
# design_artifact_path_for (`tr -c 'A-Za-z0-9._-' '_'`) — a filename-safety
# transform, not a second parser, so a copy of this one-line idiom in a
# second script is consistent with existing practice (already duplicated at
# least twice in qa-gate.sh) rather than a new drift surface.
_pb_manifest_path() {
    local sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/design-batch-%s.json' "$QA_TRACKING_DIR" "$sanitized"
}

# _pb_persist <path> <content> -- best-effort tmp-then-`mv -f` (decision #4:
# no lock; qa-gate.sh:339,365's idiom; no flock on this host,
# post-edit.sh:440). A persist failure never changes the STDOUT answer —
# the manifest is a regenerable CACHE (decision #1); a later reader that
# finds it absent or stale simply re-runs plan-batches.
_pb_persist() {
    local path="$1" content="$2" tmp
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    tmp="${path}.tmp.$$"
    if printf '%s\n' "$content" > "$tmp" 2>/dev/null; then
        mv -f "$tmp" "$path" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# emit_plan_batches <epic> <parallel_safe> <reason> <obs> <design_hash>
#                   <unit_ids_json> <unresolved_json> <unit_task_map_json>
#                   <batches_json> <manifest_path>
# One envelope shape for BOTH the clean and the degraded path — a consumer
# branches on `parallel_safe`, never on which keys are present.
emit_plan_batches() {
    local epic="$1" safe="$2" reason="$3" obs="$4" dh="$5" uids="$6" \
          unresolved="$7" map="$8" batches="$9" mpath="${10}"
    jq -nc \
        --arg epic "$epic" \
        --argjson safe "$safe" \
        --arg reason "$reason" \
        --arg obs "$obs" \
        --arg dh "$dh" \
        --argjson uids "$uids" \
        --argjson unresolved "$unresolved" \
        --argjson map "$map" \
        --argjson batches "$batches" \
        --arg mpath "$mpath" \
        '{ok:true, subcommand:"plan-batches", epic_id:$epic,
          parallel_safe:$safe, degradation_reason:$reason,
          observations:$obs, design_hash:$dh,
          graph_intersection_computed:false,
          graph_degradation_reason:"code_graph_absent",
          unit_ids:$uids, unresolved_unit_ids:$unresolved,
          unit_task_map:$map, batches:$batches, manifest_path:$mpath}'
}

# _pb_finish <epic> <safe> <reason> <obs> <dh> <uids> <unresolved> <map>
#            <batches> <mpath> — build, VALIDATE, persist, print, exit 0.
# Never returns. If emit_plan_batches itself fails (jq broke AFTER already
# being confirmed present — practically unreachable, guarded anyway) this
# is the ONE path that can still exit non-zero, because there is genuinely
# no envelope to hand back.
_pb_finish() {
    local epic="$1" safe="$2" reason="$3" obs="$4" dh="$5" uids="$6" \
          unresolved="$7" map="$8" batches="$9" mpath="${10}"
    local out="" out_rc=0
    out=$(emit_plan_batches "$epic" "$safe" "$reason" "$obs" "$dh" "$uids" "$unresolved" "$map" "$batches" "$mpath") || out_rc=$?
# PLAN-BATCHES-FINISH-FALLBACK-GATE BEGIN
    # R2-F4 (independent review, xsu1 round 2): a PRESENT-but-BROKEN jq (a
    # shadowing function, a corrupted binary -- `command -v jq` at the top
    # of cmd_plan_batches only proves jq was FOUND, never that it WORKS)
    # reaches this exact branch, since emit_plan_batches is itself
    # jq-dependent and every jq call downstream funnels its failure here
    # eventually. This used to be a bare, minimal literal with no
    # parallel_safe/graph fields and exit 2 -- the SAME narrowed-contract
    # violation R1-F7 fixed for jq's ABSENCE, one level further in: "the
    # guard that detects jq's absence cannot detect its malfunction." Same
    # fix, same reasoning: hand-built, jq-free, full shape, exit 0 -- a
    # malfunctioning jq degrades this subcommand exactly like every other
    # guard-list condition, never exits differently depending on WHICH way
    # jq failed to help.
    #
    # R5-F5 (independent review, xsu1 round 5) WIDENED the trigger: the old
    # test was `[ -z "$out" ]` alone, so a jq that exited 0 while printing
    # whitespace, [], null, or any malformed text was PERSISTED AND PRINTED
    # as the envelope -- a successful-looking wrong output bypassed the
    # fallback the exit-1 shape reached. Now the emit's rc AND the complete
    # envelope shape (object; ok:true; the exact subcommand; every field
    # present with its exact type -- boolean parallel_safe, string
    # epic_id/reasons/hash/paths, array unit_ids/unresolved_unit_ids/
    # batches, object unit_task_map; graph_intersection_computed
    # hard-false this release) are checked before anything is persisted.
    # The shape check itself runs jq -- circular against a jq that lies
    # CONSISTENTLY on every call, but that adversary was never in this
    # guard's contract; the test suite's fault injection is call-site-
    # targeted (a shim that sabotages ONE program and passes every other
    # call through to the real jq), which is also the realistic corruption
    # shape: one program tripping a bug, not a binary that coherently
    # forges arbitrary envelopes.
    #
    # The WHOLE block (validation AND fallback, not just the fallback's
    # body) is inside this sentinel -- matching PLAN-BATCHES-MULTIBIND-
    # GATE's own precedent -- so this is this file's mutant target for
    # R2-F4/R5-F5: stripping it removes both checks entirely, and
    # execution falls straight through to persist-and-print of whatever
    # emit produced -- an empty line for the exit-1 injection, the raw
    # malformed bytes for the rc-0 injection -- with exit 0, directly
    # reproducing "there is nothing here a consumer can safely read"
    # in both injected shapes.
    local out_shape_ok="false"
    if [ "$out_rc" -eq 0 ] && [ -n "$out" ] && printf '%s' "$out" | jq -e '
        type == "object"
        and (.ok == true) and (.subcommand == "plan-batches")
        and ((.epic_id | type) == "string")
        and ((.parallel_safe | type) == "boolean")
        and ((.degradation_reason | type) == "string")
        and ((.observations | type) == "string")
        and ((.design_hash | type) == "string")
        and (.graph_intersection_computed == false)
        and ((.graph_degradation_reason | type) == "string")
        and ((.unit_ids | type) == "array")
        and ((.unresolved_unit_ids | type) == "array")
        and ((.unit_task_map | type) == "object")
        and ((.batches | type) == "array")
        and ((.manifest_path | type) == "string")
    ' >/dev/null 2>&1; then
        out_shape_ok="true"
    fi
    if [ "$out_shape_ok" != "true" ]; then
        printf '{"ok":true,"subcommand":"plan-batches","epic_id":null,"error_key":"envelope_construction_failed","observations":"the plan-batches envelope itself could not be constructed -- jq is on PATH but did not behave as expected (present-but-malfunctioning, not absent); refusing rather than silently reporting an empty (vacuously parallel-safe) plan","parallel_safe":false,"degradation_reason":"envelope_construction_failed","design_hash":"","graph_intersection_computed":false,"graph_degradation_reason":"code_graph_absent","unit_ids":[],"unresolved_unit_ids":[],"unit_task_map":{},"batches":[],"manifest_path":null}\n'
        exit 0
    fi
# PLAN-BATCHES-FINISH-FALLBACK-GATE END
    _pb_persist "$mpath" "$out"
    printf '%s\n' "$out"
    exit 0
}

# _pb_degrade <epic> <reason> <obs> <dh> <uids> <unresolved> <map> <mpath>
#             [child-task-id ...] — the SHARED degrade path. Batches
# collapse to one singleton batch per given child, in an order that is a
# pure function of the ids and the known dependency data: an `LC_ALL=C
# sort` of the given child ids first (R1-F4, independent review xsu1
# round 1 — never bd's own unsorted .dependents order), then ONE guarded
# jq program topologically orders that sorted list using whatever
# (task_id, unit_id) bindings and unit dependency data have reached THIS
# specific call (globals _PB_DEGRADE_BINDINGS_JSON / _PB_DEGRADE_DEPS_JSON).
#
# THE CALLER INVARIANT THOSE GLOBALS NOW CARRY (R5-F4, independent review
# xsu1 round 5). Both globals are empty ONLY at calls that fire before the
# design artifact's declarations are read — where the deps global is empty
# too, so there are no known edges to honour and the sorted order is a
# genuinely constraint-free serial schedule, not a claim of dependency
# order. Round 5 found the window where that reasoning silently broke:
# cmd_plan_batches used to publish dependencies right after validate-design
# but bindings only after the per-child loop much further down, so every
# guard between them (the defense check, control-char, canonical-path,
# case-collision, and alias gates) degraded with REAL edges in the deps
# global and an EMPTY bindings global — this program then mapped every
# child to null, derived every dependency list as empty, and emitted plain
# sorted order over edges it could have honoured, placing a dependent's
# task before its own prerequisite's while the binding records sat READ-
# ABLE but unread in bd. The fix is in the CALLER, not here: the binding-
# resolution loop now runs immediately after the deps publish, so both
# globals are populated together before any of those guards can fire. The
# one call site left between the two publishes — the pair ENCODING failing
# after the bindings were read — refuses a schedule outright by passing NO
# child ids (batches [] with its own explanatory observations), because an
# order computed while known bindings exist but could not be fed to this
# program is exactly the wrong-order hazard this invariant exists to
# prevent. A PARTIAL bindings global splits TWO ways (R7-F1, independent
# review xsu1 round 7, CORRECTING this header's round-6 claim that any
# partial mapping was safe to schedule over):
#   - a BOUND child whose unit's depends_on names a unit with NO bound
#     implementing task is REFUSED outright (the construction's own
#     resolve gate; batches stays []). The design RECORDS that edge; only
#     the task mapping is missing, and erasing a known design edge
#     because its task cannot be resolved is a failed computation reading
#     as "no constraint" — the round-6 `// empty` lookup did exactly
#     that, emitting the dependent as runnable (and, sorted, possibly
#     FIRST) while its prerequisite had no task at all. The refusal also
#     matches the clean path, which has refused to BATCH this exact shape
#     since round 1 (unit_depends_on_unresolved_unit).
#   - a child with NO binding at all imposes nothing knowable: its unit —
#     hence which design edges could even apply to it — is unknown, so it
#     is placed in sorted order among the others while every edge whose
#     BOTH ends are bound is still honoured. This is why the 9j/9n
#     fixtures (two bound children with a real edge, one unbound third)
#     still get a complete, correctly ordered serial schedule.
#
# R4-F4/R4-F5 (independent review, xsu1 round 4) REWORKED this body —
# SMALLER, not more guarded. The old shape was seven jq call sites (four
# unguarded under `set -e`, so a jq failure exited BEFORE _pb_finish and
# its advertised envelope fallback — R4-F4), and on any topological-
# computation failure it fell back to the plain lexical sort, emitting a
# dependent's task before its own prerequisite's even though the edge was
# KNOWN (R4-F5). The degradation path is the safety net for the clean
# path and must be SIMPLER than what it protects, so instead of guarding
# seven sites the seven became two:
#   1. ONE jq program (the schedule construction below) goes straight
#      from sorted raw-line ids to the finished batches array. It
#      verifies its own input cardinality ($expected_n — ids lost to a
#      broken sort, dropped by the read loop, or split by an embedded
#      newline all surface as the program's input-cardinality refusal
#      token rather than as a schedule quietly missing tasks, the same
#      failed-computation-reads-as-empty class as R4-F1, closed here
#      preemptively), topologically orders in bounded waves
#      (range(0; N+1), same shape as the clean path's reducer), and
#      refuses (ok:false, the unorderable token) on a residual cycle or
#      count mismatch — and (R7-F1) refuses outright, BEFORE ordering,
#      when any bound child's unit depends_on a unit with no bound
#      implementing task; those resolve clauses sit inside their own
#      jq-comment sentinel (PLAN-BATCHES-DEGRADE-DEP-RESOLVE-GATE) so
#      the paired mutant strips exactly them. The why: tokens are
#      deliberately spelled ONLY in the program text — the test suite
#      proves the injectable ones source-unique and uses them as
#      fault-injection markers (plan-batches.test.sh 9n), so this
#      comment must not repeat them.
#   2. ONE guarded extraction pulls `.batches` out — and (R5-F6,
#      independent review xsu1 round 5) VALIDATES it against the expected
#      ids rather than merely typing it: the construction's output used to
#      be accepted on "nonempty shell text" alone, so a malfunctioning jq
#      exiting 0 with {ok:true, batches:[]} handed a positive child count
#      an empty schedule with NO refusal annotation. The extraction filter
#      now re-reads the sorted ids from stdin and accepts ONLY an array of
#      exactly that many singleton batches, each a one-object array with
#      unit_id null and a string task_id, whose task_id multiset equals
#      the expected ids exactly — no omissions, no extras, no duplicates.
#      (Deliberately NOT an order check: the construction is the orderer;
#      re-deriving its edge logic here would be a second implementation of
#      the thing under guard.) The validation clauses sit inside their own
#      jq-comment sentinel (PLAN-BATCHES-SCHED-SHAPE-GATE) so the paired
#      mutant can strip exactly them, reverting to the round-4 acceptance.
# Both are `cmd || rc=$?`-guarded (never `x=$(cmd); rc=$?`, the errexit-
# at-the-assignment trap LESSONS.md records). On ANY failure — nonzero
# rc, wrong shape, wrong cardinality, ok:false — this function REFUSES to
# emit a runnable schedule: batches stays [], the caller's
# degradation_reason is preserved (it names the actionable root cause),
# and `observations` is annotated that even the serial schedule could not
# be computed. An ordering that could not be computed is never emitted as
# a runnable one; the lexical fallback R4-F5 caught is GONE, so "wrong
# order over known edges" is structurally unrepresentable here rather
# than guarded against — provided the caller invariant above holds, which
# is what the re-targeted 9f mutant (strip the bindings publish, watch a
# genuine wrong order emerge in the R5-F4 window) now demonstrates. The
# jq-INDEPENDENT final refusal R4-F4 requires is _pb_finish's own
# PLAN-BATCHES-FINISH-FALLBACK-GATE, which every call now provably
# reaches because nothing in this function can errexit past it any more.
#
# unit_id is deliberately null on every degraded member — the whole point
# of degrading is not trusting the unit mapping enough to use it for
# BATCHING (file-conflict-freedom); using it for ORDERING among tasks
# already known to run serially is a strictly smaller claim.
_pb_degrade() {
    local epic="$1" reason="$2" obs="$3" dh="$4" uids="$5" unresolved="$6" map="$7" mpath="$8"
    shift 8 || true
    local batches="[]"
# PLAN-BATCHES-TOPO-ORDER-GATE BEGIN
    # R2-F3/R4-F5: the WHOLE degraded-schedule construction (the whole
    # if/fi, matching PLAN-BATCHES-FINISH-FALLBACK-GATE's own precedent so
    # the strip still parses), kept sentinel-strippable — the convention
    # this block has carried since round 2. Stripping it leaves batches at
    # its [] default: an epic with children and NO schedule — the SAFE
    # refusal, not a wrong order, because after R4-F5 no code path exists
    # that emits an order the topological computation did not produce.
    # NO LONGER A MUTANT TARGET (round 5, vacuity finding 9f.9): precisely
    # because a strip here reproduces the safe refusal, it cannot
    # discriminate a dependency-order violation, so section 9f's mutant
    # was re-targeted at PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE in the
    # R5-F4 window, where a strip DOES produce a genuine wrong order. The
    # sentinel markers stay: they still delimit the construction for
    # readability and remain available to future mutants of the refusal
    # behaviour itself (which 9n's injections currently cover).
    if [ "$#" -gt 0 ]; then
        # R1-F4: LC_ALL=C sort first (locale-independent — the determinism
        # table's own rule) so the input to the schedule construction is a
        # pure function of the ids themselves, never bd's own row order.
        #
        # i8cx: this used to be `done < <(printf ... | sort)` — a process
        # substitution, which discards `sort`'s exit status structurally (no
        # pipefail scope reaches across a `< <(...)` boundary at all). This is
        # THE reproducer this task's audit was filed against: a `sort` shim
        # that copies stdin and exits nonzero used to be invisible here.
        # Restructured to match this file's own DETERMINISM discipline
        # ("heredoc-fed bash arrays, never a pipe, for every accumulating
        # loop"): `sort`'s output is captured via command substitution (rc
        # directly observable, `printf` producing it cannot itself fail) and
        # the read loop only runs when sort succeeded. Belt-and-suspenders:
        # even without this fix, a failed/truncated sort was ALREADY caught
        # one line below by the pre-existing `${#sorted_ids[@]} -eq "$#"`
        # cardinality check, which routes to the fail-closed `sched_rc=1`
        # branch — this fix makes the failure observable at the SOURCE
        # instead of relying solely on that downstream invariant holding.
        local cid sorted_ids=() sort_out="" sort_rc=0
        sort_out=$( set -o pipefail; printf '%s\n' "$@" | LC_ALL=C sort ) || sort_rc=$?
        if [ "$sort_rc" -eq 0 ]; then
            while IFS= read -r cid; do
                [ -n "$cid" ] && sorted_ids+=("$cid")
            done <<EOF
$sort_out
EOF
        fi

        # The schedule construction. -Rn + [inputs]: raw id lines in, so
        # no separate jq call is needed to build the id array (the old
        # first unguarded site). The two why: tokens are also this
        # program's unique fault-injection markers (plan-batches.test.sh
        # section 9n; uniqueness asserted there before use).
        local sched_rc=0 sched_extract_rc=0 sched_result="" sched_batches=""
        if [ "${#sorted_ids[@]}" -eq "$#" ]; then
            sched_result=$(printf '%s\n' "${sorted_ids[@]}" | jq -Rnc \
                --argjson expected_n "$#" \
                --argjson bindings "${_PB_DEGRADE_BINDINGS_JSON:-[]}" \
                --argjson deps "${_PB_DEGRADE_DEPS_JSON:-\{\}}" \
                '
                [inputs] as $children
                | if ($children | length) != $expected_n then {ok:false, why:"degrade_input_cardinality"}
                  else
                    ( $bindings | map({key: .task_id, value: .unit_id}) | from_entries ) as $t2u
                    | ( $bindings | map({key: .unit_id, value: .task_id}) | from_entries ) as $u2t
                    | ($children | length) as $n
                    | { go: true }
# PLAN-BATCHES-DEGRADE-DEP-RESOLVE-GATE BEGIN
                    | if ( [ $children[] as $c
                             | ($t2u[$c] // null) as $cu
                             | select($cu != null)
                             | ($deps[$cu] // [])[]
                             | select( ($u2t[.] // null) == null )
                           ] | length ) > 0
                      then { go: false }
                      else .
                      end
# PLAN-BATCHES-DEGRADE-DEP-RESOLVE-GATE END
                    | if (.go | not) then {ok:false, why:"degrade_dep_unresolvable"}
                      else reduce range(0; $n + 1) as $wave (
                        { placed: {}, order: [], remaining: $children, stuck: false };
                        . as $s
                        | if ($s.remaining | length) == 0 or $s.stuck then $s
                          else
                            ( [ $s.remaining[] as $c
                                | ( ($t2u[$c] // null) as $u
                                    | if $u == null then []
                                      else [ ($deps[$u] // [])[] | ($u2t[.] // empty) ]
                                      end ) as $dep_tasks
                                | select( ($dep_tasks | map(select(($s.placed[.] // null) == null)) | length) == 0 )
                                | $c
                              ] ) as $ready
                            | if ($ready | length) == 0 then ($s + {stuck:true})
                              else
                                { placed: ($s.placed + (reduce $ready[] as $r ({}; . + {($r):true}))),
                                  order: ($s.order + $ready),
                                  remaining: [ $s.remaining[] | select( . as $rc | ($ready|index($rc)) == null ) ],
                                  stuck: false }
                              end
                          end
                      )
                    | if (.remaining | length) == 0 and (.stuck | not) and ((.order | length) == $expected_n)
                      then {ok: true, batches: [ .order[] | [ {unit_id: null, task_id: .} ] ]}
                      else {ok:false, why:"degrade_unorderable"}
                      end
                      end
                  end
                ' 2>/dev/null) || sched_rc=$?
            if [ "$sched_rc" -eq 0 ]; then
                # R5-F6: the extraction VALIDATES, never just types. The
                # sorted ids are fed back in as raw lines and the filter
                # accepts only a complete serial schedule over exactly
                # them (see the header, point 2). $sched_result rides in
                # via --argjson so text that does not even parse as JSON
                # is a nonzero rc here, and -e makes an empty (refused)
                # output rc 4 rather than a silent success. The inner
                # jq-comment sentinel is the R5-F6 mutant's strip target:
                # without those clauses this reverts to the round-4
                # acceptance (any ok:true object with an array .batches).
                sched_batches=$(printf '%s\n' "${sorted_ids[@]}" | jq -Rnc -e --argjson res "$sched_result" '
                    [inputs] as $expected
                    | $res
                    | if (type == "object") and ((.ok // false) == true) and ((.batches | type) == "array")
# PLAN-BATCHES-SCHED-SHAPE-GATE BEGIN
                         and ((.batches | length) == ($expected | length))
                         and ([ .batches[] | select( (type == "array") and (length == 1)
                                and ((.[0] | type) == "object") and (.[0].unit_id == null)
                                and ((.[0].task_id | type) == "string") ) ] | length == ($expected | length))
                         and ((.batches | map(.[0].task_id) | sort) == ($expected | sort))
# PLAN-BATCHES-SCHED-SHAPE-GATE END
                      then .batches
                      else empty
                      end
                ' 2>/dev/null) || sched_extract_rc=$?
            fi
        else
            # The sort/read loop itself lost or gained ids — refuse below.
            sched_rc=1
        fi
        if [ "$sched_rc" -eq 0 ] && [ "$sched_extract_rc" -eq 0 ] && [ -n "$sched_batches" ]; then
            batches="$sched_batches"
        else
            # R4-F5: fail CLOSED. The caller's reason/detail already name
            # the actionable root cause, so both are preserved; this
            # annotation adds the fact that even the serial schedule could
            # not be computed, and batches stays [] — a consumer gets
            # "there are children and no runnable schedule", never an
            # order that may contradict a known dependency edge.
            obs="$obs; additionally, the serial one-task-per-batch schedule for these ${#} child task(s) could not be computed (schedule rc=$sched_rc, extraction rc=$sched_extract_rc) -- an ordering that could not be computed over the known dependency data is refused rather than emitted, so batches is [] even though children exist"
        fi
    fi
# PLAN-BATCHES-TOPO-ORDER-GATE END
    _pb_finish "$epic" "false" "$reason" "$obs" "$dh" "$uids" "$unresolved" "$map" "$batches" "$mpath"
}

cmd_plan_batches() {
    # jq AVAILABILITY IS CHECKED FIRST, hand-built literal, no jq — the
    # SAME reason design-conform's own first line has (qa-gate.sh:8213-
    # 8216): every OTHER path through this function builds JSON via jq, so
    # discovering jq missing and then trying to REPORT that fact through
    # the same jq-dependent machinery produces invalid JSON. epic-gate.sh
    # has ZERO jq guards anywhere else (22 call sites, `set -e` at :37 — a
    # missing jq kills the script at the first `jq -n` with EMPTY STDOUT,
    # which verify-before-stop.sh:6152-6153's `|| echo '{}'` idiom reads
    # PERMISSIVELY). Every field here is a fixed literal or []/{}}/false —
    # nothing for a missing jq to have to escape.
    # R1-F7 (independent review, xsu1): this is guard condition 1 of the
    # NO-DESIGN-GUARD ladder, and every other member of that ladder exits
    # 0 with ok:true (a degraded plan IS a determined answer, never an
    # infra failure to the CALLER). This literal used to exit 2 with
    # ok:false, contradicting that contract (stated at the top of this
    # file and in docs/HOOKS.md) and, under the house `$(cmd || echo
    # '{}')` idiom, printing a well-formed envelope AND THEN triggering the
    # fallback -- two JSON values concatenated into one captured string.
    if ! command -v jq >/dev/null 2>&1; then
        printf '{"ok":true,"subcommand":"plan-batches","epic_id":null,"error_key":"jq_unavailable","observations":"jq is required to compute the batch plan and is not on PATH; refusing rather than silently reporting an empty (vacuously parallel-safe) plan","parallel_safe":false,"degradation_reason":"jq_unavailable","design_hash":"","graph_intersection_computed":false,"graph_degradation_reason":"code_graph_absent","unit_ids":[],"unresolved_unit_ids":[],"unit_task_map":{},"batches":[],"manifest_path":null}\n'
        exit 0
    fi

    # R2-F3 (independent review, xsu1 round 2): best-effort dependency
    # information for _pb_degrade's topological ordering. GLOBAL (not
    # local) because _pb_degrade is a separate top-level function and
    # cannot see cmd_plan_batches' own locals; reset at the top of every
    # call so a PRIOR invocation's data can never leak into this one.
    # Empty defaults mean "no dependency information reached this
    # degrade point yet" -- _pb_degrade's own fallback for that case is
    # unchanged from before this fix (LC_ALL=C task-id sort).
    _PB_DEGRADE_DEPS_JSON="{}"
    _PB_DEGRADE_BINDINGS_JSON="[]"

    local epic="${1:-}"
    if [ -z "$epic" ]; then
        usage
        jq -n '{"ok":false,"subcommand":"plan-batches","epic_id":null,"error_key":"missing_epic_id","observations":"plan-batches requires <epic-id> as first positional argument","usage":"epic-gate.sh plan-batches <epic-id> [--design <path>]","graph_intersection_computed":false,"graph_degradation_reason":"code_graph_absent"}'
        exit 1
    fi
    shift || true

    local design_flag=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --design)
                design_flag="${2:-}"
                if [ -z "$design_flag" ]; then
                    jq -n --arg e "$epic" '{"ok":false,"subcommand":"plan-batches","epic_id":$e,"error_key":"missing_design_path","observations":"--design requires a path argument","usage":("epic-gate.sh plan-batches " + $e + " --design <path>"),"graph_intersection_computed":false,"graph_degradation_reason":"code_graph_absent"}'
                    exit 1
                fi
                shift 2 || true
                ;;
            -h|--help) usage; exit 1 ;;
            *)
                jq -n --arg e "$epic" --arg a "$1" '{"ok":false,"subcommand":"plan-batches","epic_id":$e,"error_key":"unknown_flag","observations":("unknown argument " + $a + "; plan-batches takes <epic-id> and an optional --design <path>"),"usage":"epic-gate.sh plan-batches <epic-id> [--design <path>]","graph_intersection_computed":false,"graph_degradation_reason":"code_graph_absent"}'
                exit 1
                ;;
        esac
    done

    local manifest_path
    manifest_path=$(_pb_manifest_path "$epic")

    # From here on EVERY failure DEGRADES (parallel_safe:false, exit 0) —
    # see the header above and docs/HOOKS.md's consumer-idiom note. This is
    # a deliberate departure from require_bd's classic exit-2 shape.
    local children_arr=()
    local _pb_cid

# PLAN-BATCHES-NO-DESIGN-GUARD BEGIN
    # --- bd availability -------------------------------------------------
    if ! command -v bd >/dev/null 2>&1 || [ ! -d "$PROJECT_DIR/.beads" ]; then
        _pb_degrade "$epic" "epic_children_unreadable" \
            "bd is not usable from here (not on PATH, or $PROJECT_DIR/.beads is missing); cannot enumerate this epic's children, so nothing is batched. Serial is always safe" \
            "" "[]" "[]" "{}" "$manifest_path"
    fi

    # --- confirm the epic itself is a real, readable task ---------------
    # (a plain `bd show`, not sub_tasks_of — sub_tasks_of's own `|| true`
    # swallows exactly the failure this needs to detect; see its header at
    # epic-gate.sh:93-98. This positively distinguishes "the epic could not
    # be read" from "the epic was read and genuinely has zero children" —
    # cmd_check conflates them, and its own header records that shape as a
    # live defect once already.)
    local epic_show epic_show_rc=0
    epic_show=$(bd show "$epic" --json 2>/dev/null) || epic_show_rc=$?
    local epic_readable="false"
    if printf '%s' "$epic_show" | jq -e 'if type=="array" then .[0] else . end | (.id // "") | length > 0' >/dev/null 2>&1; then
        epic_readable="true"
    fi
    if [ "$epic_show_rc" -ne 0 ] || [ "$epic_readable" != "true" ]; then
        _pb_degrade "$epic" "epic_children_unreadable" \
            "bd show $epic did not return a readable task (rc=$epic_show_rc); cannot confirm this epic exists or enumerate its children. Serial is always safe" \
            "" "[]" "[]" "{}" "$manifest_path"
    fi

    # --- enumerate children (REUSE sub_tasks_of verbatim; heredoc-fed,
    # never a pipe, so the accumulator survives; never let bd's own
    # unsorted order reach the plan — this array is for LOOKUP only, the
    # plan's own order comes from the design artifact's unit_ids) --------
    local subs
    subs=$(sub_tasks_of "$epic")
    while IFS= read -r _pb_cid; do
        [ -n "$_pb_cid" ] && children_arr+=("$_pb_cid")
    done <<EOF
$subs
EOF
# PLAN-BATCHES-EPIC-CHILDREN-GATE BEGIN
    # R1-F5 (independent review, xsu1): NO redundant backup either. With
    # this removed, an empty children_arr flows straight through -- the
    # per-child loop below never iterates, the bound/problem arrays all
    # stay empty, unit_task_map_json becomes {}, every unit in the
    # artifact reads as unresolved, and the batching reduce over an EMPTY
    # $r_ids_json terminates immediately with .ok=true, batches=[] --
    # parallel_safe:true over a design with real units but zero assigned
    # children. Verified by stripping this exact block.
    if [ "${#children_arr[@]}" -eq 0 ]; then
        _pb_degrade "$epic" "epic_has_no_children" \
            "epic $epic has no parent-child dependents; nothing to batch. Unlike cmd_check's own 'nothing to gate -> pass' precedent for this exact shape (which this file's own header records as a defect once shipped), plan-batches does not read an empty children list as a permissive answer" \
            "" "[]" "[]" "{}" "$manifest_path"
    fi
# PLAN-BATCHES-EPIC-CHILDREN-GATE END

    # --- required subprocess scripts ------------------------------------
    if [ ! -f "$QA_GATE_SCRIPT" ]; then
        _pb_degrade "$epic" "qa_gate_unavailable" \
            "cannot check design-satisfaction or unit bindings: qa-gate.sh is missing at $QA_GATE_SCRIPT" \
            "" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        _pb_degrade "$epic" "validator_unavailable" \
            "cannot validate the design artifact: review-check.sh is missing at $REVIEW_CHECK_SCRIPT" \
            "" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    if [ ! -f "$WORKFLOW_MANIFEST_SCRIPT" ]; then
        _pb_degrade "$epic" "hash_tool_unavailable" \
            "cannot verify the design artifact's hash: workflow-manifest.sh is missing at $WORKFLOW_MANIFEST_SCRIPT" \
            "" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # --- design-status on the epic itself (compute_design_satisfied,
    # UNFILTERED — no leniency on no_design_attempted; see the header) ---
    local status_json status_rc=0
    status_json=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$QA_GATE_SCRIPT" design-status "$epic" 2>/dev/null) || status_rc=$?
    local status_shape_ok="false"
    # R5-F1 (independent review, xsu1 round 5): EXACT TYPES, never mere
    # presence. has() plus a textual `jq -r` comparison to "true" accepted
    # satisfied:"true" (a JSON STRING) exactly like a boolean, so a
    # malformed status source could push the run past this gate. Every
    # field this ladder consumes is now type-checked to what
    # cmd_design_status actually emits on every path (satisfied via
    # --argjson, the rest via --arg): boolean satisfied, string error_key/
    # design_hash/artifact_path. A missing key types as "null" and fails
    # the same check, so the has() form is subsumed, not weakened.
    if printf '%s' "$status_json" | jq -e 'type=="object" and (.satisfied|type)=="boolean" and (.error_key|type)=="string" and (.design_hash|type)=="string" and (.artifact_path|type)=="string"' >/dev/null 2>&1; then
        status_shape_ok="true"
    fi
    if [ "$status_rc" -ne 0 ] || [ "$status_shape_ok" != "true" ]; then
        _pb_degrade "$epic" "design_status_unavailable" \
            "qa-gate.sh design-status $epic did not return a well-formed answer (rc=$status_rc); cannot establish whether this epic's design is satisfied" \
            "" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local satisfied status_key status_obs artifact_path
    satisfied=$(printf '%s' "$status_json" | jq -r '.satisfied' 2>/dev/null || echo "false")
    status_key=$(printf '%s' "$status_json" | jq -r '.error_key // ""' 2>/dev/null || echo "")
    [ -n "$status_key" ] || status_key="design_status_unavailable"
    status_obs=$(printf '%s' "$status_json" | jq -r '.observations // ""' 2>/dev/null || echo "")
    artifact_path=$(printf '%s' "$status_json" | jq -r '.artifact_path // ""' 2>/dev/null || echo "")
    if [ "$satisfied" != "true" ]; then
        _pb_degrade "$epic" "$status_key" "$status_obs" "" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local expected_design_hash
    expected_design_hash=$(printf '%s' "$status_json" | jq -r '.design_hash // ""' 2>/dev/null || echo "")

    # --- --design ASSERTION (D1 convention: --file/--design asserts the
    # derivation, never a second source — qa-gate.sh:6683-6712's
    # design-record precedent) -------------------------------------------
    if [ -n "$design_flag" ]; then
        local derived_rel
        derived_rel="${artifact_path#"$PROJECT_DIR"}"
        derived_rel="${derived_rel#/}"
        if [ "$design_flag" != "$artifact_path" ] && [ "$design_flag" != "$derived_rel" ]; then
            _pb_degrade "$epic" "artifact_path_not_derived" \
                "--design names '$design_flag', which is not the artifact this epic's plan is computed from. The artifact is derived from the task id, never supplied: $artifact_path (or its repo-relative spelling $derived_rel). --design ASSERTS that derivation the same way qa-gate.sh design-record's --file does; it cannot point the plan at other bytes" \
                "$expected_design_hash" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
        fi
    fi

    # --- validate-design (the ONE validator) ----------------------------
    local vout vout_rc=0
    vout=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" validate-design "$artifact_path" 2>/dev/null) || vout_rc=$?
    local vshape_ok="false"
    # R5-F1: EXACT TYPES here too — ok:"true" (a JSON STRING) used to pass
    # has("ok") and then satisfy the textual `jq -r` comparison below,
    # letting a malformed validator supply usable unit data and reach
    # parallel_safe:true. emit_validate_design guarantees these types on
    # EVERY path (bare true/false interpolation for ok; [] / {} defaults
    # for the declaration fields), so boolean ok, array unit_ids, object
    # unit_files/unit_deps is what a healthy validator always produces,
    # and anything else is refused as not-well-formed rather than read.
    if printf '%s' "$vout" | jq -e 'type=="object" and (.ok|type)=="boolean" and (.unit_ids|type)=="array" and (.unit_files|type)=="object" and (.unit_deps|type)=="object"' >/dev/null 2>&1; then
        vshape_ok="true"
    fi
    # R4-F2 (independent review, xsu1 round 4): rc AND shape, matching the
    # design-status ladder 40-odd lines above — two ladders in one file
    # must not disagree on whether the exit status counts. A validator
    # that prints a shape-valid ok:true object and exits nonzero is
    # reporting its OWN failure out-of-band; trusting the parsed body over
    # the exit status batches on the say-so of a command that just said it
    # failed.
    if [ "$vout_rc" -ne 0 ] || [ "$vshape_ok" != "true" ]; then
        _pb_degrade "$epic" "validate_design_unavailable" \
            "review-check.sh validate-design $artifact_path failed or did not return a well-formed answer (rc=$vout_rc); a nonzero exit is not trusted even when the printed envelope parses (R4-F2)" \
            "$expected_design_hash" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local vok
    vok=$(printf '%s' "$vout" | jq -r '.ok' 2>/dev/null || echo "false")
    if [ "$vok" != "true" ]; then
        local vkey vobs
        vkey=$(printf '%s' "$vout" | jq -r '.error_key // "invalid_design_artifact"' 2>/dev/null || echo "invalid_design_artifact")
        [ -n "$vkey" ] || vkey="invalid_design_artifact"
        vobs=$(printf '%s' "$vout" | jq -r '.observations // ""' 2>/dev/null || echo "")
        _pb_degrade "$epic" "$vkey" "$vobs" "$expected_design_hash" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # --- CLOSING BRACKET: re-hash NOW, refuse if the artifact moved
    # between design-status's read and this validate-design read (fkm.3/
    # fkm.6's TOCTOU discipline, reused not reinvented) -------------------
    local post_hash post_hash_rc=0
    post_hash=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$WORKFLOW_MANIFEST_SCRIPT" hash-file "$artifact_path" 2>/dev/null) || post_hash_rc=$?
    if [ "$post_hash_rc" -ne 0 ] || ! printf '%s' "$post_hash" | grep -qE '^[0-9a-fA-F]{64}$' || [ "$post_hash" != "$expected_design_hash" ]; then
        _pb_degrade "$epic" "design_verdict_stale" \
            "the design artifact governing $epic changed between the satisfaction check and the declarations read (expected design_hash=$expected_design_hash, now ${post_hash:-<unreadable, rc=$post_hash_rc>}); refusing rather than computing batches over declarations no reviewer confirmed" \
            "$expected_design_hash" "[]" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # R8-F1 (independent review, xsu1 round 8): these re-extractions used
    # to be `|| unit_ids_json="[]"` / `|| ..."{}"` -- fail-open
    # SUBSTITUTIONS, and the substituted {} was then published as the
    # degrade path's dependency data, so a failed unit_deps read told the
    # degraded-schedule construction "no edges" and it could order a
    # dependent's task before its own prerequisite's: R7-F1's defect one
    # level UPSTREAM (round 7 closed the constructor; the data feeding it
    # was still substitutable, surfacing only later as
    # unit_files_missing_for_declared_unit -- after the wrong order had
    # already been emitted). Now: ONE guarded jq call extracts all three
    # fields as three compact lines (one call site instead of three; its
    # program text is unique across epic-gate.sh, qa-gate.sh AND
    # review-check.sh -- asserted by the suite -- so fault injection
    # cannot strand at review-check.sh's textually-identical
    # single-field extractions), each line is rc-AND-shape checked, and
    # on ANY failure the degrade passes NO child ids: with the dependency
    # data unreadable, ANY serial order could contradict edges the
    # artifact declares, so batches stays [] -- the same refusal shape as
    # the pair-encoding site below.
    local unit_ids_json="" unit_files_json="" unit_deps_json=""
    local vex_out="" vex_rc=0
    vex_out=$(printf '%s' "$vout" | jq -c '.unit_ids, .unit_files, .unit_deps' 2>/dev/null) || vex_rc=$?
    { IFS= read -r unit_ids_json; IFS= read -r unit_files_json; IFS= read -r unit_deps_json; } <<EOF || true
$vex_out
EOF
    if [ "$vex_rc" -ne 0 ] \
        || ! printf '%s' "$unit_ids_json" | jq -e 'type=="array"' >/dev/null 2>&1 \
        || ! printf '%s' "$unit_files_json" | jq -e 'type=="object"' >/dev/null 2>&1 \
        || ! printf '%s' "$unit_deps_json" | jq -e 'type=="object"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "the validated design's unit_ids/unit_files/unit_deps could not be re-extracted (jq exited $vex_rc, or a field was not its exact declared type -- never substituted with an empty []/{} as before round 8). No serial schedule is emitted either: the dependency data is unreadable, so any order could contradict an edge the artifact declares -- batches is [] even though ${#children_arr[@]} child task(s) exist" \
            "$expected_design_hash" "[]" "[]" "{}" "$manifest_path"
    fi
    # R2-F3: from here on, ANY subsequent degrade knows the FULL
    # dependency graph (even though the unit<->task mapping may still be
    # partial or absent) -- _pb_degrade uses this for best-effort
    # topological ordering rather than a bare task-id sort. R8-F1: this
    # publish happens only AFTER the validation above -- never a
    # substituted empty.
    _PB_DEGRADE_DEPS_JSON="$unit_deps_json"

    # --- resolve every enumerated child's DESIGN-UNIT binding ------------
    # MOVED (R5-F4, independent review xsu1 round 5) from below the alias
    # gates to HERE, immediately after the dependency publish above, so no
    # guard can ever fire knowing the artifact's edges but not the binding
    # records that make them honourable: round 5 found that the defense,
    # control-char, canonical-path, case-collision and alias degradations
    # all fell in exactly that window and emitted plain sorted order over
    # a KNOWN edge while the binding records sat readable-but-unread in
    # bd. The loop itself only ACCUMULATES — every per-child failure below
    # is a problem ENTRY, never a mid-loop degrade — so the reason
    # precedence the guard ladder had before this move is unchanged: the
    # path gates still degrade before PLAN-BATCHES-CHILD-BINDING-GATE
    # (which stays at its original position further down) ever reads these
    # arrays.
    #
    # R5-F2 (same round): the old loop encoded each problem/bound entry
    # with its own UNGUARDED `array+=("$(jq ...)")` — under `set -e` a
    # command substitution failing inside an array assignment exits the
    # script AT the assignment, before _pb_degrade/_pb_finish, so a
    # targeted jq failure produced NO envelope at all (the reviewer's
    # probe: `set -e; a+=("$(false)")` exits 1). Rather than guard five
    # encoder call sites, the machinery is REMOVED: problems accumulate in
    # three plain bash arrays (task/reason/detail — no JSON is ever built
    # for them, because their one consumer only ever needed the first
    # entry and the count), and the bound pairs are encoded ONCE, below,
    # by a single guarded, cardinality-checked jq program. The problems
    # path now has no jq call left to fail; the bound path has exactly
    # one, and its failure degrades with an explicit envelope instead of
    # dying.
    local problem_tasks=() problem_reasons=() problem_details=()
    local bound_units=() bound_tasks=()
    local cid show_json show_rc bound_flag u_id d_hash u_in_design
    for cid in "${children_arr[@]}"; do
        show_rc=0
        show_json=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$QA_GATE_SCRIPT" design-unit-show "$cid" 2>/dev/null) || show_rc=$?
        # R5-F1's class, applied here too: .bound must be a real BOOLEAN
        # (cmd_design_unit_show emits it via --argjson on every path), so
        # a malformed bound:"true" string cannot pass the textual
        # comparison below as if the binding had been read.
        if [ "$show_rc" -ne 0 ] || ! printf '%s' "$show_json" | jq -e 'type=="object" and (.bound|type)=="boolean"' >/dev/null 2>&1; then
            problem_tasks+=("$cid")
            problem_reasons+=("design_unit_show_unavailable")
            problem_details+=("design-unit-show $cid did not return a well-formed answer (rc=$show_rc)")
            continue
        fi
        bound_flag=$(printf '%s' "$show_json" | jq -r '.bound' 2>/dev/null || echo "false")
        if [ "$bound_flag" != "true" ]; then
            problem_tasks+=("$cid")
            problem_reasons+=("design_unit_binding_missing")
            problem_details+=("$cid has no DESIGN-UNIT v1 binding; an unconstrained writer would be invisible to this plan")
            continue
        fi
        u_id=$(printf '%s' "$show_json" | jq -r '.unit_id // ""' 2>/dev/null || echo "")
        d_hash=$(printf '%s' "$show_json" | jq -r '.design_hash // ""' 2>/dev/null || echo "")
        u_in_design=$(jq -nc --argjson ids "$unit_ids_json" --arg u "$u_id" '$ids | index($u) != null' 2>/dev/null || echo "false")
        if [ "$u_in_design" != "true" ]; then
            problem_tasks+=("$cid")
            problem_reasons+=("unit_not_in_design")
            problem_details+=("$cid is bound to unit_id=$u_id, which is not declared in the current design artifact -- likely amended without re-binding")
            continue
        fi
        if [ "$d_hash" != "$expected_design_hash" ]; then
            problem_tasks+=("$cid")
            problem_reasons+=("binding_design_hash_stale")
            problem_details+=("$cid is bound to unit_id=$u_id at design_hash=$d_hash, which differs from the current governing design_hash=$expected_design_hash")
            continue
        fi
        bound_units+=("$u_id")
        bound_tasks+=("$cid")
    done

    # ONE guarded encoding of the (unit_id, task_id) pairs (R5-F2),
    # cardinality-checked the same way _pb_degrade's own construction is:
    # ids ride in as raw alternating lines (unit, then task, per pair), so
    # an id split by an embedded newline or a pair lost in transit
    # surfaces as the program's own line-count refusal, never as a
    # silently shorter binding set.
    local bound_pairs_json="[]"
    if [ "${#bound_units[@]}" -gt 0 ]; then
        local bound_pairs_rc=0 _pb_bi
        bound_pairs_json=$( { for _pb_bi in "${!bound_units[@]}"; do printf '%s\n' "${bound_units[$_pb_bi]}" "${bound_tasks[$_pb_bi]}"; done; } | jq -Rnc --argjson n "${#bound_units[@]}" '
            [inputs] as $lines
            | if ($lines | length) != ($n * 2) then error("bound pair line-count mismatch")
              else [ range(0; $n) | {unit_id: $lines[2*.], task_id: $lines[2*.+1]} ]
              end
        ' 2>/dev/null) || bound_pairs_rc=$?
        if [ "$bound_pairs_rc" -ne 0 ] || ! printf '%s' "$bound_pairs_json" | jq -e --argjson n "${#bound_units[@]}" 'type=="array" and length == $n' >/dev/null 2>&1; then
            # R5-F4's one residual site: the bindings were READ but could
            # not be ENCODED, so the dependency data is known while the
            # task-to-unit mapping is unavailable. NO child ids are passed
            # — a serial order computed without the read bindings could
            # contradict an edge the artifact declares, so no schedule is
            # emitted at all (batches []), and this observation says so
            # explicitly instead of leaving an unexplained empty schedule.
            _pb_degrade "$epic" "set_computation_failed" \
                "could not encode the ${#bound_units[@]} resolved (unit_id, task_id) binding pair(s) (jq exited $bound_pairs_rc, or produced a wrong-shaped or wrong-sized result). The bindings were read but could not be fed to the degraded-schedule construction, so even the serial one-task-per-batch schedule is refused: an ordering computed without them could contradict a dependency edge the artifact declares -- batches is [] even though ${#children_arr[@]} child task(s) exist" \
                "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path"
        fi
    fi
# PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE BEGIN
    # R3-F3 (round 3) put this publish AHEAD of the CHILD-BINDING-GATE;
    # R5-F4 (round 5) moved loop and publish together AHEAD OF EVERY
    # POST-VALIDATION GUARD, because the round-3 placement still left the
    # defense/control-char/canonical/case-collision/alias degradations
    # firing with dependencies published but bindings not — _pb_degrade's
    # topological reorder then saw an empty binding set at exactly the
    # call sites that needed it and emitted plain sorted order over a
    # KNOWN edge (probed both rounds: empty bindings emit the dependent
    # before its own prerequisite; published bindings emit the reverse).
    # NO redundant backup: nothing else publishes this global, which is
    # what makes this its own sentinel — and the section-9f mutant strips
    # exactly this block to demonstrate the wrong order the publish
    # prevents, while section 9j's mutant does the same at the
    # CHILD-BINDING-GATE call site further down.
    _PB_DEGRADE_BINDINGS_JSON="$bound_pairs_json"
# PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE END

    # --- DEFENSIVE: every declared unit_id has an entry in BOTH
    # unit_files and unit_deps. Should be unreachable given validate-
    # design's own schema guarantee on a .ok==true artifact — checked
    # anyway because `null - []` is a jq ERROR (rc 5, probed) that aborts
    # the WHOLE fold, not one comparison. -------------------------------
    local defense_json defense_rc=0
    defense_json=$(jq -nc --argjson ids "$unit_ids_json" --argjson uf "$unit_files_json" --argjson ud "$unit_deps_json" '
        ( $ids - ($uf | keys_unsorted) ) as $missing_f
        | ( $ids - ($ud | keys_unsorted) ) as $missing_d
        | { missing_files: $missing_f, missing_deps: $missing_d }
    ' 2>/dev/null) || defense_rc=$?
    if [ "$defense_rc" -ne 0 ] || ! printf '%s' "$defense_json" | jq -e '(.missing_files|type)=="array" and (.missing_deps|type)=="array"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not verify every declared unit_id has a files/deps entry (jq exited $defense_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local missing_f_n missing_d_n
    missing_f_n=$(printf '%s' "$defense_json" | jq -r '.missing_files | length' 2>/dev/null || echo "1")
    missing_d_n=$(printf '%s' "$defense_json" | jq -r '.missing_deps | length' 2>/dev/null || echo "1")
    if [ "$missing_f_n" != "0" ] || [ "$missing_d_n" != "0" ]; then
        local missing_detail
        missing_detail=$(printf '%s' "$defense_json" | jq -r '"unit_id(s) declared without a files or depends_on entry: " + ((.missing_files + .missing_deps) | unique | join(", "))' 2>/dev/null) || missing_detail="a declared unit_id has no files/deps entry"
        _pb_degrade "$epic" "unit_files_missing_for_declared_unit" "$missing_detail" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # --- control-character check across ALL declared files (R4-F3,
    # independent review xsu1 round 4). Runs BEFORE the canonical-form
    # check: a control character is the more fundamental malformation.
    # Every downstream consumer of a declared filename that goes through
    # command substitution ($(...) strips trailing newlines — the
    # reviewer's own probe: original_len=6, extracted_len=5) checks a
    # DIFFERENT spelling than the one the batching reducer keeps, so a
    # path ending in a newline can pass -L and -ef under its stripped
    # spelling while co-batching under its original bytes. validate-design
    # does NOT reject these (its nonempty_string only rejects the
    # all-whitespace case — probed). REJECT, never sanitise (the bjx
    # class): stripping or normalising the character would just move the
    # two-spellings problem, not close it. ------------------------------
    local ctrl_json ctrl_rc=0
    ctrl_json=$(printf '%s' "$unit_files_json" | jq -c '
        [ to_entries[] | .key as $u | .value[]
          | select( test("[\\x00-\\x1f\\x7f]") )
          | {unit_id: $u, file: .} ]
    ' 2>/dev/null) || ctrl_rc=$?
    if [ "$ctrl_rc" -ne 0 ] || ! printf '%s' "$ctrl_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not check declared file paths for control characters (jq exited $ctrl_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local ctrl_n
    ctrl_n=$(printf '%s' "$ctrl_json" | jq -r 'length' 2>/dev/null || echo "1")
# PLAN-BATCHES-CONTROL-CHAR-GATE BEGIN
    # R4-F3: NO redundant backup — a declared path containing a control
    # character (most sharply a TRAILING NEWLINE, which every command
    # substitution silently strips) is checked by the alias pass under a
    # different spelling than the one the batching reducer intersects, so
    # nothing downstream ever notices the two spellings are one file. The
    # offending path is displayed @json-escaped in the observations: the
    # refusal names the exact bytes without ever emitting a raw control
    # character into the envelope's prose.
    if [ "$ctrl_n" != "0" ]; then
        local ctrl_detail
        ctrl_detail=$(printf '%s' "$ctrl_json" | jq -r '"declared path(s) contain control characters (any byte in 0x00-0x1f or 0x7f, e.g. a trailing newline), which command substitution strips -- the alias checks would test a different spelling than the batching intersection compares: " + ([.[] | .unit_id + ":" + (.file | @json)] | join(", "))' 2>/dev/null) || ctrl_detail="a declared path contains control characters"
        _pb_degrade "$epic" "declared_path_contains_control_chars" "$ctrl_detail" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
# PLAN-BATCHES-CONTROL-CHAR-GATE END

    # --- canonical-path check across ALL declared files. Degrade rather
    # than normalize; case deliberately NOT folded — see the header. ----
    local canon_json canon_rc=0
    canon_json=$(jq -nc --argjson uf "$unit_files_json" '
        [ $uf | to_entries[] | .key as $u | .value[]
          | select( test("^/") or test("(^|/)\\.\\.?(/|$)") or test("//") or test("/$") )
          | {unit_id: $u, file: .} ]
    ' 2>/dev/null) || canon_rc=$?
    if [ "$canon_rc" -ne 0 ] || ! printf '%s' "$canon_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not check declared file paths for canonical form (jq exited $canon_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local canon_n
    canon_n=$(printf '%s' "$canon_json" | jq -r 'length' 2>/dev/null || echo "1")
# PLAN-BATCHES-CANONICAL-PATH-GATE BEGIN
    # R1-F5: also has no redundant backup -- a non-canonical spelling (an
    # absolute path, a ./ or ../ segment, //, a trailing /) that byte-
    # differs from another unit's spelling of the SAME file is never
    # caught by any OTHER check; the batching reduce's own intersection is
    # exact byte-equality and would simply see two disjoint strings.
    if [ "$canon_n" != "0" ]; then
        local canon_detail
        canon_detail=$(printf '%s' "$canon_json" | jq -r '"non-canonical declared path(s) (absolute, ./ or ../, //, or trailing /) would compare as disjoint from an equivalent canonical spelling under byte-equality intersection: " + ([.[] | .unit_id + ":" + .file] | join(", "))' 2>/dev/null) || canon_detail="non-canonical declared path(s) found"
        _pb_degrade "$epic" "declared_paths_not_canonical" "$canon_detail" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
# PLAN-BATCHES-CANONICAL-PATH-GATE END

    # --- R1-F3 (independent review, xsu1): case-COLLISION detection.
    # The canonical-form check above says nothing about case, deliberately
    # (case is NOT folded anywhere in this file -- a case-sensitive
    # filesystem, e.g. this repo's own Linux CI tier, genuinely treats
    # differently-cased paths as different files, and folding case would
    # be WRONG there). But on a case-INSENSITIVE filesystem (this dev
    # host's default APFS) two declarations that collide only in case name
    # the SAME file, and byte-equality intersection reads them as disjoint
    # -- confirmed: both `src/A.js` and `src/a.js` pass the canonical-form
    # check above unmodified. Detecting a COLLISION (never folding case
    # generally) is safe on both platforms: a spurious degrade on Linux
    # (still serial-safe), the only thing standing between the plan and a
    # real collision on APFS.
    local caseco_json caseco_rc=0
    caseco_json=$(jq -nc --argjson uf "$unit_files_json" '
        [ $uf | to_entries[] | .key as $u | .value[] | {unit_id: $u, file: .} ]
        | group_by(.file | ascii_downcase)
        | map(select( ([.[].file] | unique | length) > 1 ))
    ' 2>/dev/null) || caseco_rc=$?
    if [ "$caseco_rc" -ne 0 ] || ! printf '%s' "$caseco_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not check declared file paths for case-insensitive collisions (jq exited $caseco_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local caseco_n
    caseco_n=$(printf '%s' "$caseco_json" | jq -r 'length' 2>/dev/null || echo "1")
    if [ "$caseco_n" != "0" ]; then
        local caseco_detail
        caseco_detail=$(printf '%s' "$caseco_json" | jq -r '[.[] | ([.[] | .unit_id + ":" + .file] | join(" == "))] | join("; ")' 2>/dev/null) || caseco_detail="two declared paths collide case-insensitively"
        _pb_degrade "$epic" "declared_paths_case_collision" "$caseco_detail" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

# PLAN-BATCHES-ALIAS-GATE BEGIN
    # R2-F1 (independent review, xsu1 round 2): neither check above can
    # see a SYMLINK-mediated alias (this repo's own `tests ->
    # .claude/scripts/tests`) or a pre-existing file reachable under two
    # BYTE-DIFFERENT spellings (Unicode normalisation, non-ASCII case).
    #
    # R3-F1/R3-F2 (independent review xsu1 round 3) REWORKED this block:
    # the round-2 pass 1 (resolve a canonical key per file, group, compare)
    # used -d/-e throughout and so could not see a DANGLING symlink (R3-F2),
    # and every jq extraction it added was its own new fail-open
    # opportunity if it failed silently (R3-F1 -- the fourth instance of
    # that class in this slice). Weighed the reviewer's offered alternative
    # ("degrade on anything not provably distinct, no resolution chain") and
    # chose it FOR PASS 1 SPECIFICALLY: see _pb_path_has_symlink's own
    # header for the full reasoning. Pass 2 keeps its ORIGINAL mechanism
    # (-ef is not a resolution chain -- it is one kernel-verified pairwise
    # check) with its extraction discipline fixed instead of removed.
    #
    #   1. _pb_path_has_symlink: if ANY declared file (or an ancestor
    #      directory strictly between it and $PROJECT_DIR) is a symlink --
    #      tested with -L, true regardless of whether the target exists --
    #      the WHOLE plan degrades unconditionally. Not a claim that two
    #      specific declarations collide; a refusal to try to prove they
    #      do not, once a symlink is anywhere in play. Structurally closes
    #      R3-F2 (a dangling symlink is still a symlink under -L) as a
    #      consequence, not a special case.
    #   2. For declared files whose FULL path ALREADY exists on disk
    #      (regardless of spelling), `-ef` (same device+inode) catches an
    #      already-existing Unicode/case alias directly, with no Unicode
    #      library dependency. Every extraction feeding this pass is now
    #      plain bash array indexing (alias_units/alias_files/alias_abs,
    #      built ONCE below with a checked-rc-AND-shape jq read per field)
    #      -- there is no remaining jq call in pass 2 itself for a failure
    #      to hide behind.
    #
    # What NEITHER pass can see, disclosed rather than silently assumed
    # closed (narrower than before this fix -- dangling symlinks are no
    # longer part of this residual at all): two declared paths that are
    # Unicode-normalisation-equivalent (NFC/NFD) OR non-ASCII-case-
    # equivalent (e.g. Cyrillic case folding) where NEITHER spelling
    # exists yet on disk AND neither involves a symlink. Closing that
    # needs either assumed filesystem state a design-time declaration
    # cannot rely on, or a Unicode-normalisation dependency this script
    # does not carry.
    #
    # flat_pairs uses the SAME newline-delimited-compact-JSON technique as
    # round 2 (jq -c never embeds a literal newline inside one object's own
    # serialization, so this splits safely on ANY declared path) -- but its
    # OWN construction is now checked (flat_rc), and each line's `.u`/`.f`
    # are extracted as TWO INDEPENDENT rc-AND-shape-checked reads (matching
    # this file's discipline everywhere else) rather than `|| ""`: a
    # failure BREAKS the loop and degrades `set_computation_failed` instead
    # of silently `continue`-ing past the entry (R3-F1's exact named bug).
    local flat_pairs flat_rc=0
    flat_pairs=$(printf '%s' "$unit_files_json" | jq -c 'to_entries[] | .key as $u | .value[] | {u:$u, f:.}' 2>/dev/null) || flat_rc=$?
    if [ "$flat_rc" -ne 0 ]; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not flatten declared (unit, file) pairs for alias checking (jq exited $flat_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local -a alias_units=() alias_files=() alias_abs=()
    local line u u_rc f f_rc line_extract_failed=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        u_rc=0
        u=$(printf '%s' "$line" | jq -r 'if (type=="object" and (.u|type)=="string" and (.u|length)>0) then .u else empty end' 2>/dev/null) || u_rc=$?
        f_rc=0
        f=$(printf '%s' "$line" | jq -r 'if (type=="object" and (.f|type)=="string" and (.f|length)>0) then .f else empty end' 2>/dev/null) || f_rc=$?
        if [ "$u_rc" -ne 0 ] || [ -z "$u" ] || [ "$f_rc" -ne 0 ] || [ -z "$f" ]; then
            line_extract_failed=1
            break
        fi
        alias_units+=("$u")
        alias_files+=("$f")
        alias_abs+=("$PROJECT_DIR/$f")
    done <<EOF
$flat_pairs
EOF
    if [ "$line_extract_failed" -eq 1 ]; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not safely extract a declared (unit, file) pair while checking for aliasing -- refusing rather than silently excluding it from the check" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

# PLAN-BATCHES-ALIAS-CARDINALITY-GATE BEGIN
    # R4-F1 (independent review, xsu1 round 4): the checks above verify
    # every line that ARRIVED was extracted safely, but say nothing about
    # whether every declared pair arrived at all. A flat_pairs that
    # succeeded (rc 0) with EMPTY or PARTIAL output runs that many fewer
    # loop bodies, never trips line_extract_failed, and leaves the alias
    # arrays short — so the alias check silently happens over a SUBSET of
    # the declared files (over none, in the empty case) and aliased units
    # can co-batch. This is the FIFTH instance in this slice of a failed
    # or absent computation reading as "nothing to check" rather than
    # "could not check", per the round-4 review's own count. The fix is
    # cardinality, not shape: the number of extracted pairs must equal the
    # sum of every unit's files[] length, computed independently from the
    # SAME unit_files_json the flattening consumed. NO redundant backup —
    # nothing downstream ever compares the alias arrays against the
    # declarations again.
    local expected_pairs expected_pairs_rc=0
    expected_pairs=$(printf '%s' "$unit_files_json" | jq -r '[ .[] | length ] | add // 0' 2>/dev/null) || expected_pairs_rc=$?
    if [ "$expected_pairs_rc" -ne 0 ] || ! printf '%s' "$expected_pairs" | grep -qE '^[0-9]+$'; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not count the declared (unit, file) pairs to verify the alias-check flattening was complete (jq exited $expected_pairs_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    if [ "${#alias_units[@]}" -ne "$expected_pairs" ] || [ "${#alias_files[@]}" -ne "$expected_pairs" ] || [ "${#alias_abs[@]}" -ne "$expected_pairs" ]; then
        _pb_degrade "$epic" "set_computation_failed" \
            "the alias-check flattening produced ${#alias_files[@]} of $expected_pairs declared (unit, file) pair(s) -- an empty or partial flattening would silently skip the alias check for the missing pairs, so this degrades rather than reading an incomplete set as 'nothing to check'" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
# PLAN-BATCHES-ALIAS-CARDINALITY-GATE END

    # Pass 1: any declared file traversing a symlink (leaf or ancestor,
    # dangling or not) degrades unconditionally -- see _pb_path_has_symlink.
    local symlink_hit="" _pb_idx
    for _pb_idx in "${!alias_files[@]}"; do
        if _pb_path_has_symlink "${alias_files[$_pb_idx]}"; then
            symlink_hit="${alias_units[$_pb_idx]}:${alias_files[$_pb_idx]}"
            break
        fi
    done
    if [ -n "$symlink_hit" ]; then
        _pb_degrade "$epic" "declared_path_traverses_symlink" \
            "$symlink_hit declares a path that is (or passes through) a symlink; file-set disjointness cannot be established across a symlinked path -- dangling or not -- so this plan degrades rather than risk two declarations that alias the same file" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # Pass 2: any two declared files whose FULL paths already exist on
    # disk, compared pairwise by device+inode (-ef) -- catches an
    # already-existing alias regardless of spelling mechanism, with no
    # Unicode library needed, since the OS already knows they are one file.
    # Every value used here is plain bash array indexing into the arrays
    # built above -- no jq call left in this pass for a failure to hide in.
    local -a existing_idx=()
    for _pb_idx in "${!alias_abs[@]}"; do
        [ -e "${alias_abs[$_pb_idx]}" ] && existing_idx+=("$_pb_idx")
    done
    if [ "${#existing_idx[@]}" -gt 1 ]; then
        local i j ii jj
        for ((i = 0; i < ${#existing_idx[@]}; i++)); do
            for ((j = i + 1; j < ${#existing_idx[@]}; j++)); do
                ii="${existing_idx[$i]}"
                jj="${existing_idx[$j]}"
                [ "${alias_files[$ii]}" = "${alias_files[$jj]}" ] && continue
                if [ "${alias_abs[$ii]}" -ef "${alias_abs[$jj]}" ]; then
                    _pb_degrade "$epic" "declared_paths_alias_same_file" \
                        "${alias_units[$ii]}:${alias_files[$ii]} and ${alias_units[$jj]}:${alias_files[$jj]} already exist on disk under different spellings and are the SAME file (device+inode identical)" \
                        "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
                fi
            done
        done
    fi
# PLAN-BATCHES-ALIAS-GATE END

# PLAN-BATCHES-CHILD-BINDING-GATE BEGIN
    # THE NON-REDUNDANT ENFORCEMENT POINT for guards 9/10/11 (an unbound
    # child, a binding to a unit the current artifact no longer declares,
    # or a stale design_hash). The RESOLUTION ran much earlier (right
    # after the declarations were read — R5-F4's move), but the
    # ENFORCEMENT deliberately stays here, after the path gates, so the
    # guard ladder's reason precedence is what it always was: a bad
    # declared path names the path problem, a bad binding names the
    # binding problem. Unlike the design-status/validate-design/TOCTOU
    # checks earlier in this function — each independently fail-closed
    # against a DIFFERENT structural failure, so removing any ONE of them
    # still degrades via another (verified: stripping the design-status
    # check alone still degrades via validate-design's own missing-file
    # check; stripping that too still degrades via the TOCTOU re-hash) —
    # nothing else downstream notices a problem child. A problem child is
    # simply never added to the bound arrays, so without THIS check it
    # becomes silently invisible to `unit_task_map` and the batching
    # computation runs over the REMAINING children as if the problem one
    # never existed: an unconstrained writer, dropped from the plan rather
    # than degrading it. This is the sentinel this file's own Mutant 3
    # (the pairing suite) strips. R5-F2: everything read here is a plain
    # bash array — no jq call left in this gate for a failure to hide in.
    if [ "${#problem_tasks[@]}" -gt 0 ]; then
        _pb_degrade "$epic" "${problem_reasons[0]}" \
            "${#problem_tasks[@]} of ${#children_arr[@]} child task(s) could not be cleanly resolved to a design unit; the first: ${problem_details[0]}. Serial is always safe -- a non-degraded wrong plan is the only dangerous outcome" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
# PLAN-BATCHES-CHILD-BINDING-GATE END

    # --- multiply-bound detection ---------------------------------------
    # bound_pairs_json and _PB_DEGRADE_BINDINGS_JSON were already computed
    # and published immediately after the declarations were read (R3-F3,
    # moved further up with the whole loop by R5-F4) -- reused here
    # unchanged, never recomputed.
    local unit_task_map_json="{}"
# PLAN-BATCHES-MULTIBIND-GATE BEGIN
    # R1-F5: also has no redundant backup -- with this removed,
    # unit_task_map_json's own `from_entries` (below) silently keeps
    # whichever of the two conflicting bindings sorts LAST in
    # bound_pairs_json (bd's own child-enumeration order, not a
    # deliberate choice), and the other task's claim on the same unit
    # simply vanishes rather than degrading the plan.
    #
    # R7-F3 (independent review, xsu1 round 7) REMOVED the jq from the
    # DECISION: the old shape asked one jq program to enumerate duplicate
    # bindings and trusted its rc-0 answer, so a malfunctioning jq
    # printing [] with rc 0 sailed through the array-shape gate and let a
    # multiply-bound unit vanish through exactly the from_entries
    # collapse this gate exists to prevent. Multiply-bound is a pure
    # cardinality fact this function already holds in bash -- it is TRUE
    # iff bound_units contains fewer DISTINCT ids than entries -- and
    # unit ids are validated single-line tokens ([A-Za-z0-9._-]+,
    # design-unit-show's own classifier, so sort/grep line counting
    # cannot be split by an embedded newline). jq now appears only INSIDE
    # the already-degrading branch, to NAME the conflict; its failure can
    # weaken the message, never the decision.
    #
    # R8-F2 (round 8): the round-7 pipeline escaped the unguarded-jq
    # channel by landing in the unguarded-PIPELINE channel
    # (claude-workflow-plugin-i8cx: no script here sets pipefail, so a
    # pipeline's status is its LAST stage's) -- a sort that copied stdin
    # through unsorted and exited 9 left grep counting the raw lines
    # with rc 0, entries == "distinct", and the duplicate branch SKIPPED
    # (reviewer-reproduced). The command substitution now runs under its
    # own scoped `set -o pipefail` (subshell-local; nothing else in the
    # script changes), so EVERY stage's failure -- printf, sort, or
    # grep -- surfaces in distinct_rc and degrades set_computation_failed.
    local distinct_bound_units=0 distinct_rc=0
    if [ "${#bound_units[@]}" -gt 0 ]; then
        distinct_bound_units=$(set -o pipefail; printf '%s\n' "${bound_units[@]}" | LC_ALL=C sort -u | grep -c .) || distinct_rc=$?
    fi
    if [ "$distinct_rc" -ne 0 ]; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not count the distinct bound unit ids for the multiply-bound check (sort/grep pipeline rc=$distinct_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    if [ "$distinct_bound_units" -ne "${#bound_units[@]}" ]; then
        local dup_detail
        dup_detail=$(jq -rn --argjson pairs "$bound_pairs_json" '[ $pairs | group_by(.unit_id) | .[] | select(length > 1) | .[0].unit_id + " -> " + (map(.task_id) | join(" AND ")) ] | join("; ")' 2>/dev/null) || dup_detail=""
        [ -n "$dup_detail" ] || dup_detail="a unit_id is bound to more than one task (${#bound_units[@]} clean bindings resolve to only $distinct_bound_units distinct unit id(s))"
        _pb_degrade "$epic" "unit_bound_to_multiple_tasks" "$dup_detail" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
# PLAN-BATCHES-MULTIBIND-GATE END

    # R1-F2 (independent review, xsu1): rebuild fail-CLOSED (checked rc AND
    # shape, never a silent {} on failure) and R1-F4: key order now derived
    # from $ids (ARTIFACT order), never from $pairs' own insertion order --
    # bound_pairs_json is built by iterating children_arr, which is bd's
    # own unsorted enumeration order, so the OLD from_entries(.,.) shape
    # made the envelope's serialized bytes a function of bd row order, not
    # of the design artifact alone.
    local unit_task_map_rc=0
    unit_task_map_json=$(jq -nc --argjson pairs "$bound_pairs_json" --argjson ids "$unit_ids_json" '
        ( $pairs | map({key: .unit_id, value: .task_id}) | from_entries ) as $m
        | [ $ids[] | select( ($m[.] // null) != null ) | {key: ., value: $m[.]} ] | from_entries
    ' 2>/dev/null) || unit_task_map_rc=$?
    if [ "$unit_task_map_rc" -ne 0 ] || ! printf '%s' "$unit_task_map_json" | jq -e 'type=="object"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not build the unit-to-task map (jq exited $unit_task_map_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
# PLAN-BATCHES-NO-DESIGN-GUARD END

    # --- derive R (resolvable units), detect units BLOCKED on an
    # unresolved dependency (R1-F1), and drop out-of-R edges only for
    # units that are NOT blocked ------------------------------------------
    # R1-F1 (independent review, xsu1): a resolvable unit whose OWN
    # depends_on names a unit with NO implementing task yet is MISSING
    # INFORMATION about whether that prerequisite is even started, not a
    # unit with no dependency at all. The prior shape silently dropped any
    # edge pointing outside R and let the unit become immediately ready,
    # which is safe ONLY for a unit that has no dependency in the first
    # place -- not for one whose real dependency simply has no task yet.
    # Detected as $blocked below and treated as a whole-plan degrade, the
    # same collapse every other Category-C guard uses.
    local batching_inputs batching_rc=0
    batching_inputs=$(jq -nc --argjson ids "$unit_ids_json" --argjson map "$unit_task_map_json" --argjson ud "$unit_deps_json" '
        ( [ $ids[] | select( ($map[.] // null) != null ) ] ) as $r
        | ( $ids - $r ) as $unresolved
        | ( [ $r[] | select( ( ($ud[.] // []) - $r ) != [] ) ] ) as $blocked
        | ( [ $r[] as $u | { key: $u, value: [ ($ud[$u] // [])[] | select( . as $d | ($r | index($d)) != null ) ] } ] | from_entries ) as $ud_r
        | { r: $r, unresolved: $unresolved, blocked: $blocked, ud_r: $ud_r }
    ' 2>/dev/null) || batching_rc=$?
    # R7-F3: the shape check also verifies the PARTITION -- r + unresolved
    # must equal unit_ids exactly (multiset equality via sort, so overlap,
    # omission and invention all fail together) -- because a
    # malfunctioning jq printing {r:[],unresolved:[],blocked:[],ud_r:{}}
    # with rc 0 passed the four type checks and silently dropped every
    # unit from the plan.
    # R8-F3 (round 8, the cheap half): the partition alone still accepted
    # a semantically-wrong reshuffle -- {r:[], unresolved:<all units>}
    # partitions ids perfectly while reclassifying every BOUND unit as
    # unresolved -- so r is now also pinned to unit_task_map's own keys
    # (both derive from $ids filtered by the same mapped-predicate in the
    # same order, so honest runs are EXACTLY equal, order included).
    # unresolved is pinned transitively by the partition. ud_r is NOT
    # re-validated here: checking its edges against unit_deps would be
    # dependency-order re-validation of the algorithm under guard,
    # deferred by operator decision to the follow-up task.
    if [ "$batching_rc" -ne 0 ] || ! printf '%s' "$batching_inputs" | jq -e --argjson ids "$unit_ids_json" --argjson map "$unit_task_map_json" '(.r|type)=="array" and (.unresolved|type)=="array" and (.blocked|type)=="array" and (.ud_r|type)=="object" and (((.r + .unresolved) | sort) == ($ids | sort)) and (.r == ($map | keys_unsorted))' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not derive the resolvable unit set for batching (jq exited $batching_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    # R1-F2: each extraction below is checked on ITS OWN rc AND shape, not
    # allowed to fall back to an empty map/array silently -- the prior
    # `|| x="[]"`/`|| x="{}"` shape is exactly the fail-open wrapper this
    # subcommand exists to refuse.
    local r_ids_json unresolved_json blocked_json ud_filtered_json extract_rc=0
    r_ids_json=$(printf '%s' "$batching_inputs" | jq -c '.r' 2>/dev/null) || extract_rc=$?
    unresolved_json=$(printf '%s' "$batching_inputs" | jq -c '.unresolved' 2>/dev/null) || extract_rc=$?
    blocked_json=$(printf '%s' "$batching_inputs" | jq -c '.blocked' 2>/dev/null) || extract_rc=$?
    ud_filtered_json=$(printf '%s' "$batching_inputs" | jq -c '.ud_r' 2>/dev/null) || extract_rc=$?
    if [ "$extract_rc" -ne 0 ] \
        || ! printf '%s' "$r_ids_json" | jq -e 'type=="array"' >/dev/null 2>&1 \
        || ! printf '%s' "$unresolved_json" | jq -e 'type=="array"' >/dev/null 2>&1 \
        || ! printf '%s' "$blocked_json" | jq -e 'type=="array"' >/dev/null 2>&1 \
        || ! printf '%s' "$ud_filtered_json" | jq -e 'type=="object"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not extract the already-validated resolvable-set fields (rc=$extract_rc)" \
            "$expected_design_hash" "$unit_ids_json" "[]" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # R1-F1's actual enforcement: any blocked unit degrades the WHOLE plan
    # (never just excludes itself) -- the same collapse guards 9-12 use.
    local blocked_n
    blocked_n=$(printf '%s' "$blocked_json" | jq -r 'length' 2>/dev/null || echo "1")
    if [ "$blocked_n" != "0" ]; then
        local blocked_detail
        blocked_detail=$(jq -nc --argjson blocked "$blocked_json" --argjson ud "$unit_deps_json" --argjson r "$r_ids_json" \
            '[ $blocked[] as $u | $u + " -> " + ((($ud[$u] // []) - $r) | join(",")) ] | join("; ")' 2>/dev/null) \
            || blocked_detail="a resolvable unit depends on a unit with no implementing task yet"
        _pb_degrade "$epic" "unit_depends_on_unresolved_unit" \
            "dependency order cannot be established: $blocked_detail. An unresolved dependency is missing information about whether that prerequisite is even started, not an absent dependency" \
            "$expected_design_hash" "$unit_ids_json" "$unresolved_json" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    # --- THE BATCHING COMPUTATION — bounded waves, greedy first-fit
    # against the FULL ACCUMULATED UNION of each batch's members, fail-
    # closed on both rc and shape. See the header for the algorithm. ----
    local batch_result batch_rc=0
    batch_result=$(jq -nc \
        --argjson ids "$r_ids_json" \
        --argjson uf "$unit_files_json" \
        --argjson ud "$ud_filtered_json" \
        --argjson map "$unit_task_map_json" \
        '
        ($ids | length) as $n
        | reduce range(0; $n + 1) as $wave (
            { placed: {}, batches: [], remaining: $ids, stuck: false };
            . as $s
            | if ($s.remaining | length) == 0 or $s.stuck then $s
              else
                ( [ $s.remaining[] | select( ( ($ud[.] // []) - ($s.placed | keys_unsorted) ) == [] ) ] ) as $ready
                | if ($ready | length) == 0 then
                    ($s + { stuck: true })
                  else
                    ( reduce $ready[] as $u (
                        { batches: $s.batches, placed: $s.placed };
                        . as $ws
                        | ($uf[$u] // []) as $ufiles
                        | ( [ ($ud[$u] // [])[] | ($ws.placed[.]) ] ) as $dep_batches
                        | ( if ($dep_batches | length) == 0 then 0 else (($dep_batches | max) + 1) end ) as $min_start
                        | ( [ range($min_start; ($ws.batches | length)) as $i
                              | select( ( ($ws.batches[$i].files) - (($ws.batches[$i].files) - $ufiles) ) == [] )
                              | $i ] | first ) as $fit
                        | if $fit == null then
                            ($ws.batches | length) as $newidx
                            | $ws
                              | .batches += [ { members: [ {unit_id: $u, task_id: ($map[$u] // null)} ], files: $ufiles } ]
                              | .placed[$u] = $newidx
                          else
                            $ws
                              | .batches[$fit].members += [ {unit_id: $u, task_id: ($map[$u] // null)} ]
                              | .batches[$fit].files += $ufiles
                              | .placed[$u] = $fit
                          end
                      )
                    ) as $after
                    | { placed: $after.placed,
                        batches: $after.batches,
                        remaining: [ $s.remaining[] | select( . as $r2 | ($ready | index($r2)) == null ) ],
                        stuck: false }
                  end
              end
          )
        | { ok: ((.remaining | length) == 0 and (.stuck | not)),
            batches: [ .batches[] | .members ] }
        ' 2>/dev/null) || batch_rc=$?
    # R7-F3: when ok is true, the emitted batches must place EVERY
    # resolvable unit exactly once (multiset equality of the flattened
    # member unit_ids against R) -- a malfunctioning jq printing
    # {ok:true,batches:[]} with rc 0 passed the two type checks and
    # reached parallel_safe:true with every unit silently dropped.
    # R8-F3 (round 8, the cheap half): every member's task_id must also
    # equal unit_task_map's value for its unit_id -- a correct unit-id
    # multiset carrying FORGED task ids passed the round-7 check. What
    # this deliberately does NOT do (deferred by operator decision to the
    # follow-up task): independently re-validate file-conflict freedom or
    # dependency order of the batching output -- either would be a second
    # implementation of the algorithm under guard.
    if [ "$batch_rc" -ne 0 ] || ! printf '%s' "$batch_result" | jq -e --argjson r "$r_ids_json" --argjson map "$unit_task_map_json" '(.ok|type)=="boolean" and (.batches|type)=="array" and (if .ok == true then ((([ .batches[][] | .unit_id ] | sort) == ($r | sort)) and (all(.batches[][]; .task_id == ($map[.unit_id] // null)))) else true end)' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "the batching computation itself failed (jq exited $batch_rc) -- refusing rather than reporting an assumed-empty or partial plan" \
            "$expected_design_hash" "$unit_ids_json" "$unresolved_json" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    local batch_ok
    batch_ok=$(printf '%s' "$batch_result" | jq -r '.ok' 2>/dev/null || echo "false")
    if [ "$batch_ok" != "true" ]; then
        _pb_degrade "$epic" "set_computation_failed" \
            "the batching computation did not terminate cleanly (a residual dependency cycle within the resolvable unit set, which should be impossible given validate-design's own acyclicity check on the full artifact -- surfaced rather than trusted)" \
            "$expected_design_hash" "$unit_ids_json" "$unresolved_json" "{}" "$manifest_path" "${children_arr[@]}"
    fi
    # R1-F2's fourth site: this extraction is checked on its own rc AND
    # shape too, even though $batch_result already passed a shape check
    # above -- the same "never trust a re-extraction silently" discipline
    # applied to r_ids_json/unresolved_json/blocked_json/ud_filtered_json.
    local batches_json batches_extract_rc=0
    batches_json=$(printf '%s' "$batch_result" | jq -c '.batches' 2>/dev/null) || batches_extract_rc=$?
    if [ "$batches_extract_rc" -ne 0 ] || ! printf '%s' "$batches_json" | jq -e 'type=="array"' >/dev/null 2>&1; then
        _pb_degrade "$epic" "set_computation_failed" \
            "could not extract the already-validated batches array (rc=$batches_extract_rc)" \
            "$expected_design_hash" "$unit_ids_json" "$unresolved_json" "{}" "$manifest_path" "${children_arr[@]}"
    fi

    local batch_count unresolved_count final_obs
    batch_count=$(printf '%s' "$batches_json" | jq -r 'length' 2>/dev/null || echo "?")
    unresolved_count=$(printf '%s' "$unresolved_json" | jq -r 'length' 2>/dev/null || echo "0")
    final_obs="parallel-safe batch plan computed over ${#bound_units[@]} resolvable unit(s) across $batch_count batch(es); dependency order respected; file-set intersection only (impact_of half deferred, claude-workflow-plugin-l7gd)"
    if [ "$unresolved_count" != "0" ]; then
        local unresolved_list
        unresolved_list=$(printf '%s' "$unresolved_json" | jq -r 'join(", ")' 2>/dev/null || echo "")
        final_obs="$final_obs; $unresolved_count declared unit(s) have no implementing child yet, excluded from this plan: $unresolved_list"
    fi

    _pb_finish "$epic" "true" "" "$final_obs" "$expected_design_hash" "$unit_ids_json" "$unresolved_json" "$unit_task_map_json" "$batches_json" "$manifest_path"
}

# ---------------------------------------------------------------------------
# Dispatch

SUB="${1:-}"
shift || true

case "$SUB" in
    check)        cmd_check "$@" ;;
    siblings)     cmd_siblings "$@" ;;
    shared-files) cmd_shared_files "$@" ;;
    plan-batches) cmd_plan_batches "$@" ;;
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
