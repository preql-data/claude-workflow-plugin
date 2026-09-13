#!/bin/bash
# SubagentStart Hook (J3 — Phase 6b).
#
# Fires when Claude Code spawns a subagent. We use it to auto-assign the
# active Beads task to the spawned specialist via additionalContext, so the
# orchestrator doesn't need to repeat the task id and a brief in the
# Task() prompt.
#
# Per the Claude Code hooks reference (https://docs.claude.com/en/docs/claude-code/hooks):
#   - SubagentStart input includes `agent_type` (the subagent name like
#     "@backend", "@qa", or built-ins "general-purpose"/"Explore"/"Plan").
#   - SubagentStart hooks CANNOT block subagent creation, but CAN inject
#     `additionalContext` into the spawned subagent's first turn.
#
# Behaviour:
#   1. Read the incoming JSON from stdin; extract `agent_type`.
#   2. If the agent_type is one of our specialist names (backend, frontend,
#      devops, qa — with or without leading @), AND the current-task helper
#      file is non-empty, emit additionalContext containing the task id +
#      a brief summary pulled from `bd show <id>` (header lines only).
#   3. Otherwise emit `{}` and exit cleanly.
#
# V3 (claude-workflow-plugin-jio.1) adds one side effect between 2 and 3: for
# the three IMPLEMENTING roles (backend/frontend/devops — never qa) the hook
# appends an `IMPLEMENTER: role=<r> task=<t> at <ts>` Beads comment, once per
# (role, task, REVIEW CYCLE). That record is the implementer set
# `review-check.sh gate` reads, which `qa-gate.sh approve` and the Stop hook use
# to refuse a self-review — and whose TIMESTAMP the Stop hook's F1 fast path
# compares against the cycle open to refuse speaking for a task an implementer
# is still working on. The cycle in that key is claude-workflow-plugin-qzv.1;
# see the IMPLEMENTER-CYCLE-KEY region below for why (role, task) alone was not
# enough. It is best-effort: a failure logs and never blocks the spawn.
#
# Autonomy: this hook is silent on every error (per principle #3 — full
# autonomy, no user prompts). Failures fall through to the empty-output
# path so subagent creation never gets blocked or noisy.
#
# Phase 6b note: when this script ships before SubagentStart support
# stabilises in the runtime, it is harmless — the hook entry simply
# never fires. CHANGELOG documents the dependency.

set -e

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
QA_TRACKING_DIR="$PROJECT_DIR/.claude/.qa-tracking"
CURRENT_TASK_HELPER="$PROJECT_DIR/.claude/scripts/current-task.sh"
SYNC_ERRORS_LOG="$QA_TRACKING_DIR/sync-errors.log"
# v5 D5 (claude-workflow-plugin-fkm.7): spec injection at spawn shells out to
# these two rather than re-implementing the DESIGN-UNITS parser or the
# record-grammar readers they already own -- see the SPEC INJECTION AT SPAWN
# section below for the full resolution path.
QA_GATE_SCRIPT="$PROJECT_DIR/.claude/scripts/qa-gate.sh"
REVIEW_CHECK_SCRIPT="$PROJECT_DIR/.claude/scripts/review-check.sh"
WORKFLOW_MANIFEST_SCRIPT="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"

# Always emit a non-blocking empty result on any failure path. The function
# is the catch-all for "we couldn't do anything useful, but don't want to
# break subagent creation".
emit_empty() { echo '{}'; exit 0; }

# Best-effort logger. Same shape as verify-before-stop.sh / qa-gate.sh.
log_sync_error() {
    local msg="$1"
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
    printf '%s\t[subagent-start]\t%s\n' "$ts" "$msg" >> "$SYNC_ERRORS_LOG" 2>/dev/null || true
}

# F3 single-source-of-truth read. Empty stdout = no active task.
#
# i8cx wave 2: mirrors verify-before-stop.sh's own get_current_task fix
# (i8cx wave 1 / U7) as closely as this file's shape allows -- see that
# function's header comment for the full defect writeup. Short version: the
# helper call's `|| echo ""` and the fallback's `head | tr ... || echo ""`
# both threw away whatever nonzero rc meant "the marker exists but I could
# not read it" and folded it into the SAME tid="" that "no active task"
# already produces.
#
# Unlike verify-before-stop.sh's F1 fast path (where an unestablished read
# has to fail closed on a RELEASE decision), an empty CURRENT_TASK here was
# ALREADY safe in the narrow sense that it never fabricates a task id or
# crashes the spawn -- it takes the same `emit_empty` exit as a genuinely
# idle session, both before and after this fix. What changes is that a read
# failure is no longer INDISTINGUISHABLE from an idle session in the audit
# trail: pre-fix, that branch was 100% silent, so a spawn whose
# `record_implementer` call got silently skipped (see the call site below --
# emit_empty returns before is_implementer_role/record_implementer ever run)
# left no trace it happened. That matters here specifically because
# `record_implementer`'s output is what review-check.sh:1417's independence
# check reads: a gap in the implementer set left by an unlogged read failure
# is invisible to the very check that is supposed to catch a missing
# implementer record. `log_sync_error` (defined above) is this file's
# existing best-effort trail mechanism -- same one `record_implementer`'s own
# failure path already uses two screens down.
#
# `|| tid_rc=$?` (not `tid=$(cmd); tid_rc=$?`) is required under this file's
# `set -e` (line 42): a bare assignment that fails aborts the WHOLE script at
# that line, before this function ever gets to decide how to degrade -- which
# the hooks contract reads as non-blocking (an aborted hook emits nothing),
# i.e. it would fail OPEN on the read itself. Measured directly while fixing
# the sibling site in current-task.sh: a split `raw=$(head ...); rc=$?` never
# reached its own second line.
get_current_task() {
    local tid="" tid_rc=0
    if [ -x "$CURRENT_TASK_HELPER" ]; then
        tid=$(bash "$CURRENT_TASK_HELPER" get 2>/dev/null) || tid_rc=$?
    elif [ -s "$QA_TRACKING_DIR/current-task" ]; then
        # Producer captured on its own line, same shape as current-task.sh's
        # own cmd_get after i8cx wave 2: the strip pipe below only ever sees
        # an in-memory string (`printf | tr`), so it cannot mask anything the
        # `head` capture above it didn't already surface.
        local raw_tid=""
        raw_tid=$(head -1 "$QA_TRACKING_DIR/current-task" 2>/dev/null) || tid_rc=$?
        if [ "$tid_rc" -eq 0 ]; then
            tid=$(printf '%s' "$raw_tid" | tr -d '\r\n[:space:]') || { tid=""; tid_rc=1; }
        fi
    fi
    if [ "$tid_rc" -ne 0 ]; then
        log_sync_error "current-task read FAILED (exit $tid_rc): the active-task marker exists but could not be read for this spawn (agent_type=${AGENT_TYPE:-<unknown>}) — treated as 'no active task' (no assignment, no IMPLEMENTER record posted) (i8cx wave 2)"
        printf '%s' ""
        return 0
    fi
    printf '%s' "$tid"
}

# Normalize an agent_type into a canonical short name. Strip a leading "@"
# so "@backend" and "backend" map to the same handler. Lowercase to be
# tolerant of case variations.
normalize_agent_type() {
    local raw="$1"
    [ -z "$raw" ] && return 0
    # Strip leading @ (orchestrator-style) and surrounding whitespace.
    local short
    short=$(printf '%s' "$raw" | sed -e 's/^[[:space:]]*@*//' -e 's/[[:space:]]*$//')
    # Lowercase. tr is portable (BSD + GNU).
    printf '%s' "$short" | tr '[:upper:]' '[:lower:]'
}

# Decide if a normalized agent_type is a specialist we want to auto-assign for.
# Built-in agents (general-purpose, Explore, Plan) are not specialists in our
# workflow — they don't claim Beads tasks — so we skip them.
is_specialist() {
    case "$1" in
        backend|frontend|devops|qa) return 0 ;;
        *) return 1 ;;
    esac
}

# V3 (claude-workflow-plugin-jio.1): is this agent_type an IMPLEMENTING role?
#
# The review-separation gate needs to know WHO wrote the code so it can refuse
# an approval whose reviewer is one of them. Only the three implementing
# specialists count. qa (and the grader/judge relays) REVIEW — recording them
# as implementers would make every single-agent review non-independent and the
# gate would refuse every approval.
is_implementer_role() {
    case "$1" in
        backend|frontend|devops) return 0 ;;
        *) return 1 ;;
    esac
}

# record_implementer <role> <task-id> — append the IMPLEMENTER identity record
# that `review-check.sh gate` greps for the implementer set.
#
# Grammar (load-bearing, matched by `^IMPLEMENTER: role=([a-z]+) ` in the
# shipped counter — the trailing space after the role is part of the contract):
#   IMPLEMENTER: role=<backend|frontend|devops> task=<tid> model=<m> pin=<p> at <ISO8601-UTC>
#
# model=/pin= (claude-workflow-plugin-46w9) sit BEFORE `at <ts>`, deliberately —
# review-check.sh's max_record_ts and this file's own max_record_ts_in both
# anchor the timestamp at END OF LINE (` at $QZV_ISO_UTC_RE\$`), structurally
# pinned byte-identical between the two files (review-check.test.sh asserts
# it). Appending model=/pin= AFTER `at <ts>` would put trailing text past that
# anchor and every record would read back as `unparseable` — the exact failure
# the cycle-membership helper further down treats as "fail toward posting a
# duplicate", which is merely noisy, but qzv.1's F1 fast path treats an
# unparseable `latest_implementer_ts` as "cannot establish", which is the
# FAIL-CLOSED direction for a DIFFERENT predicate (never auto-approve a
# doc-only change set while an implementer might be in flight) — so the
# position is not
# cosmetic, it is what keeps both readers answering at all.
#
# WHAT THE TWO FIELDS ARE, and why they are NOT the same value read twice:
#   pin=   the STATIC frontmatter `model:` line in THIS role's own agent file
#          (.claude/agents/<role>.md), read directly — the declared intent.
#   model= the RESOLVED pick for the "implementer" role class from
#          model-roles-resolved.json (schema 2, model-select.sh), as of THIS
#          spawn — what the resolver last computed, which `cmd_apply` is
#          supposed to have already written into the frontmatter.
# Both are read BEFORE the specialist's own turn starts, so NEITHER is a
# confirmed fact about what the spawned session actually ran on — the
# runtime's live model appears nowhere in this hook's stdin, and
# model-select.sh's own header is explicit that whether a frontmatter
# `model:` change is honoured is established nowhere in this tree. What a
# pin/model DIVERGENCE here means is narrower and still real: the on-disk
# frontmatter has drifted from what the resolver last computed (a stale
# artifact, or a hand-edit since the last `cmd_apply`). The DEEPER question —
# did the runtime actually honour either value — is what comparing THIS
# record's fields against the specialist's OWN completion-record self-report
# (F7's model=/pin=, written after the specialist has run and can introspect)
# is for; that comparison is the "direct production measurement" 46w9 exists
# to enable, and it needs a baseline recorded before the fact to compare
# against, which is what this record now is.
#
# CHARACTER CLASS (claude-workflow-plugin-bjx class, applied here for the
# first time to a MODEL id rather than a task id or role): real ids contain
# hyphens, periods, digits AND BRACKETS (`claude-opus-5[1m]` is a real,
# observed runtime id — see the ledger note on claude-workflow-plugin-gz3).
# `unknown_model_class()` below is reject-only, never sanitising, and is
# tested against exactly that corpus, INCLUDING the bracket form, because a
# class that rejects the session's own model id is worse than none.
#
# Contract:
#   - IDEMPOTENT per (role, task, REVIEW CYCLE): a re-spawn of the same
#     specialist inside the SAME review cycle posts nothing; a re-spawn in a
#     LATER cycle posts a fresh record. A multi-domain task spawning backend AND
#     frontend gets ONE record per distinct role per cycle (the gate de-dupes
#     anyway, but a clean audit trail beats a noisy one). The cycle half of that
#     key is claude-workflow-plugin-qzv.1 — see the IMPLEMENTER-CYCLE-KEY region.
#   - BEST-EFFORT: every failure path logs to sync-errors.log and returns
#     non-zero; the caller ignores the result. A SubagentStart hook must never
#     block or slow a spawn, and the additionalContext envelope below is
#     emitted regardless.
# bd_show_with_comments <task-id> — `bd show --json` that always carries
# comment BODIES, across the supported bd range.
#
# bd 1.1.2 stopped inlining comments in `bd show --json`: it returns a
# `comment_count` integer, and the bodies need the new --include-comments flag.
# bd 0.47.x has no such flag and exits 1 ("unknown flag: --include-comments"),
# but inlines .comments already. So try the new form, fall back to the plain
# one — pin the CHAIN, not the leg, the same shape the `bd comments add ||
# bd comment add` call below uses. Callers keep the usual
# `(if type=="array" then .[0].comments else .comments end) // []` accessor,
# which reads both shapes correctly. Never fails the caller.
#
# Only readers of .comments need this. The TASK_LABELS read further down must
# NOT use it: the flag's own help warns it "may be slow on issues with many
# comments", and .labels is unaffected by the change.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

# IMPLEMENTER-CYCLE-KEY BEGIN (qzv.1)
#
# THE IDEMPOTENCY KEY HAS TO INCLUDE THE REVIEW CYCLE, or the record cannot
# express the thing the Stop hook asks of it.
#
# THE DEFECT, REPRODUCED END TO END (claude-workflow-plugin-qzv.1; QA's
# two-cycle run against the real scripts, 2026-08-04). The guard below used to
# be `grep -qE "^IMPLEMENTER: role=${role} "` alone — idempotent per
# (role, task), matching ANY comment on the task ever. So
# `review-check.sh gate`'s `latest_implementer_ts` was that role's FIRST spawn,
# permanently, and the Stop hook's F1 predicate (which refuses to auto-approve a
# doc-only change set while an IMPLEMENTER record is at-or-newer than the most
# recent `QA-GATE: entered at <ts>`) read "previous cycle" from the second cycle
# onward:
#
#   CYCLE 1  QA-GATE: entered  18:31:36Z
#            IMPLEMENTER role=devops 18:31:38Z
#            -> impl > cycle  -> Stop BLOCKS                       (correct)
#   CYCLE 2  qa-gate-entered removed, FRESH enter -> entered 18:32:06Z
#            devops RE-SPAWNS -> posted NOTHING (record count stayed 1)
#            -> impl 18:31:38Z < cycle 18:32:06Z -> Stop ALLOWS
#            -> qa-approved + `reviewed_by=none` mid-implementation
#
# That last line is claude-workflow-plugin-qzv's titular defect verbatim, and
# multi-cycle is this project's normal mode (94d took six). Re-keying on the
# cycle makes the timestamp mean what the predicate already assumed it meant.
#
# WHY RE-KEY RATHER THAN DROP IDEMPOTENCY. Dropping it — one record per spawn —
# also fixes the predicate, and it is smaller. It was rejected because a role is
# re-spawned SEVERAL times inside one cycle as a matter of routine (a stream
# watchdog kill, a mid-task course correction), so per-spawn records put a dozen
# lines of noise into a comment stream that humans and agents read by hand with
# plain `bd show` (claude-workflow-plugin-fkm.1.18) — and it would delete a
# tested property rather than correct it (spec leg I2, and its I8 META).
#
# WHY THE PARSE LIVES HERE and is not read back off `review-check.sh gate`'s
# envelope, which is where every OTHER consumer of these two facts gets them:
#   - The decision is PER-ROLE. `latest_implementer_ts` is the max across ALL
#     roles, so using it would suppress devops's record because backend already
#     posted one this cycle — and the implementer SET is the reason these records
#     exist (jio.1), so losing a role from it would silently re-legalise the
#     self-review `approve` refuses. Nothing in that envelope is per-role.
#   - This script is the grammar's sole WRITER, and it already read its own
#     records back to make this very decision. A writer checking what it wrote
#     is not a second reader of someone else's format.
#   - `review-check.sh` cannot be sourced (its dispatcher runs and exits on an
#     empty subcommand), and a SubagentStart hook must never block or slow a
#     spawn, so adding a subprocess + a new subcommand + a fallback for when that
#     subcommand is missing buys strictly more failure surface than it removes.
# WHAT THE COUPLING COSTS, and how it is pinned rather than hoped for: the
# writer's notion of "current cycle" must agree with the predicate's. Pinned
# BEHAVIOURALLY by the two-cycle legs in the verify-before-stop component spec
# (they drive the real writer and the real predicate over one record stream, so a
# divergence in the dangerous direction goes red), and STRUCTURALLY by
# review-check.test.sh, which asserts this file and review-check.sh carry a
# byte-identical `QZV_ISO_UTC_RE` and a byte-identical extraction pipeline.
#
# THE GRAMMAR IS UNCHANGED. `IMPLEMENTER: role=<r> task=<t> at <ISO8601-UTC>`,
# byte for byte. Every reader keeps working untouched: `max_record_ts`'s
# end-of-line ` at <ts>$` anchor, the `^IMPLEMENTER: role=([a-z]+) ` set
# capture, `is_implementer_role`, and F1's predicate. Only how OFTEN a record is
# written changed.
QZV_ISO_UTC_RE='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# max_record_ts_in <firstlines> <record-prefix-ERE> — the same three answers, the
# same pipeline and the same anchor as `review-check.sh`'s max_record_ts, over a
# STRING of comment first-lines instead of a file (this hook already has them in
# a variable and writing a temp file inside a spawn hook buys nothing):
#   ''            no record of that class exists
#   'unparseable' records exist, none carries a well-formed trailing timestamp
#   <ts>          the LEXICOGRAPHIC MAX, never the last line in comment order
# The third answer is why the empty string is not overloaded: "no record" and "a
# record I cannot read" demand opposite decisions below.
max_record_ts_in() {
    local lines ts
    lines=$(printf '%s\n' "$1" | grep -E "$2" 2>/dev/null) || lines=""
    if [ -z "$lines" ]; then
        printf ''
        return 0
    fi
    ts=$(printf '%s\n' "$lines" \
        | grep -oE " at $QZV_ISO_UTC_RE\$" 2>/dev/null \
        | sed -E 's/^ at //' \
        | LC_ALL=C sort \
        | tail -1) || ts=""
    if [ -z "$ts" ]; then
        printf 'unparseable'
        return 0
    fi
    printf '%s' "$ts"
}

# recorded_in_current_cycle <role> <firstlines> -> 'yes' | 'no'
#
# 'yes' means "this role already has a record the F1 predicate will read as
# in-flight", i.e. posting another adds nothing. Four cases, IN THIS ORDER, and
# the direction of each is chosen so that being WRONG costs comment noise rather
# than a mis-approval:
#
#   THIS ROLE HAS NO RECORD -> 'no' (post). Checked FIRST and not merely for
#     tidiness: with it ordered after the no-cycle case below, a task carrying no
#     records at all answered 'yes' — "already recorded" for a role that had
#     never spawned. The guard never reaches the helper in that state, so it was
#     invisible from the call site and only a direct truth-table probe found it;
#     an unconditional caller added later would have skipped every first spawn.
#   NO CYCLE RECORD AT ALL -> 'yes' (keep the old per-(role, task) key). Nothing
#     for the record to be older than, and F1 already refuses on the record's
#     mere existence in that state ("...and NO review cycle was ever opened on
#     it"). So a second record cannot change any verdict, and posting one on
#     every spawn of a task that has never reached the gate would be pure spam.
#   EITHER SIDE UNPARSEABLE -> 'no' (post). The two cannot be ordered, so the
#     cycle this role last recorded in is unknown; a fresh, well-formed record is
#     the only answer that makes the predicate readable again. F1 refuses on an
#     unparseable stamp anyway, so this cannot buy an approval.
#   OTHERWISE -> compare. 'yes' only when the role's newest record is at-or-newer
#     than the newest cycle open. A SAME-SECOND TIE counts as 'yes' — F1 refuses
#     ties (whole-second stamps cannot order an enter and a spawn), so the
#     existing record already blocks and a duplicate would add a line for nothing.
recorded_in_current_cycle() {
    local role="$1" firstlines="$2" role_ts cycle_ts newest
    role_ts=$(max_record_ts_in "$firstlines" "^IMPLEMENTER: role=${role} ")
    cycle_ts=$(max_record_ts_in "$firstlines" '^QA-GATE: entered at ')
    if [ -z "$role_ts" ]; then
        printf 'no'
        return 0
    fi
    if [ -z "$cycle_ts" ]; then
        printf 'yes'
        return 0
    fi
    if [ "$role_ts" = "unparseable" ] || [ "$cycle_ts" = "unparseable" ]; then
        printf 'no'
        return 0
    fi
    newest=$(printf '%s\n%s\n' "$role_ts" "$cycle_ts" | LC_ALL=C sort | tail -1)
    if [ "$newest" = "$role_ts" ]; then
        printf 'yes'
    else
        printf 'no'
    fi
}
# IMPLEMENTER-CYCLE-KEY END (qzv.1)

# MODEL-PIN-FIELDS BEGIN (claude-workflow-plugin-46w9)

# unknown_model_class <value> -> 0 (matches) | 1 (does not). REJECT-ONLY —
# this function never sanitises, it only says yes/no, matching the codebase's
# bjx convention elsewhere (task_id/role scalars). Bracket expression syntax
# is deliberate: POSIX ERE does not treat `\[`/`\]` as escapes INSIDE a
# bracket expression (measured directly while building this — a
# backslash-escaped form rejected every real id including plain
# "claude-sonnet-5"), so a literal `]` must be the character immediately
# after the opening `[` and a literal `-` must be last. Tested against the
# real corpus this tree actually uses (see the comment on record_implementer)
# — including the bracket form `claude-opus-5[1m]` — precisely because a
# class that rejects the session's own model id is worse than none.
model_id_class_ok() {
    printf '%s' "$1" | grep -qE '^[]A-Za-z0-9._:/[-]+$'
}

# read_role_pin <role> -> the STATIC frontmatter `model:` value from
# .claude/agents/<role>.md, or "unknown" when the file/line is missing or the
# value fails the character class. Mirrors statusline.sh's read_model_pin,
# generalised to any role's own file rather than hardcoding orchestrator.md.
read_role_pin() {
    local role="$1" file pin
    file="$PROJECT_DIR/.claude/agents/${role}.md"
    [ -f "$file" ] || { printf 'unknown'; return 0; }
    pin=$(grep -E '^model:' "$file" 2>/dev/null | head -1 | awk '{print $2}')
    if [ -z "$pin" ] || ! model_id_class_ok "$pin"; then
        printf 'unknown'
        return 0
    fi
    printf '%s' "$pin"
}

# resolved_model_for_class <role-class> -> the RESOLVED pick for that class
# from model-roles-resolved.json (schema 2), or "unknown" when the artifact
# is missing, unparseable, the key is absent, or the value fails the
# character class. Never fails the caller — a missing/stale resolution is
# recorded as "unknown", not silently treated as agreement with the pin.
resolved_model_for_class() {
    local class="$1" artifact model
    artifact="$QA_TRACKING_DIR/model-roles-resolved.json"
    [ -f "$artifact" ] || { printf 'unknown'; return 0; }
    command -v jq >/dev/null 2>&1 || { printf 'unknown'; return 0; }
    model=$(jq -r --arg r "$class" '.roles[$r] // empty' "$artifact" 2>/dev/null || echo "")
    if [ -z "$model" ] || ! model_id_class_ok "$model"; then
        printf 'unknown'
        return 0
    fi
    printf '%s' "$model"
}
# MODEL-PIN-FIELDS END (claude-workflow-plugin-46w9)

record_implementer() {
    local role="$1" tid="$2"
    [ -n "$role" ] && [ -n "$tid" ] || return 1
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$PROJECT_DIR/.beads" ] || return 1

    # Existing records for this task, first line of each comment (all the
    # grammar records are single-line, so line-oriented matching is correct).
    local existing=""
    existing=$(bd_show_with_comments "$tid" \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // []
                 | .[].text | split("\n")[0]' 2>/dev/null || echo "")

    # IMPLEMENTER-IDEMPOTENCY-GUARD, in two halves.
    #
    # HALF ONE, HERE, OUTSIDE the cycle-key region: "does this role have a record
    # at all". This is the PRE-qzv.1 answer in full, and it stays outside the
    # sentinels on purpose — with the region stripped it is the only answer, so the
    # stripped copy is BEHAVIOURALLY IDENTICAL to pre-qzv.1 (with the
    # test-anchored `grep` line below byte-identical to it), and the L2 META
    # therefore measures the cycle key instead of dying on an unset variable. Same
    # discipline as verify-before-stop.sh's F1_BINDING_VERDICT default.
    #
    # "Behaviourally identical" rather than "byte-for-byte": the surrounding code
    # DID move — the old form returned directly, this one sets `skip` — so only
    # that one line is byte-identical. The equivalence is the measured kind: QA
    # compared pre-fix / stripped / shipped across 7 task states (no records,
    # previous cycle, this cycle, never-entered, same-second tie, unparseable
    # stamp, other-role-only); pre-fix and stripped agree on all 7, and shipped
    # differs in exactly two, both RELAXATIONS. No state exists where pre-fix
    # posted and shipped did not.
    #
    # THE `grep` LINE BELOW IS TEST-ANCHORED: the spec's I8 META locates it by its
    # exact text and rewrites it to a constant-false condition, which must make a
    # re-spawn duplicate. Change its wording and that META stops finding it —
    # `assert_mutant_applied`-style, it fails loudly rather than silently, but fix
    # the anchor in the same edit. The pattern mirrors the gate's own capture.
    local skip="no"
    if printf '%s\n' "$existing" | grep -qE "^IMPLEMENTER: role=${role} "; then
        skip="yes"
    fi
    # IMPLEMENTER-CYCLE-KEY BEGIN (qzv.1)
    # HALF TWO: a record from a PREVIOUS cycle does not count. This only ever
    # RELAXES the skip (yes -> no), never tightens it, so it cannot suppress a
    # record the pre-fix guard would have written.
    if [ "$skip" = "yes" ]; then
        skip=$(recorded_in_current_cycle "$role" "$existing")
    fi
    # IMPLEMENTER-CYCLE-KEY END (qzv.1)
    if [ "$skip" = "yes" ]; then
        return 0
    fi

    local ts pin model
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    # "implementer" is the role-CLASS key model-select.sh resolves against
    # (ALL_ROLES has no separate backend/frontend/devops entries — the three
    # share one class, and today one frontmatter value; see model-select.sh's
    # IMPL_AGENT comment). $role picks WHICH file read_role_pin reads, so a
    # future divergence between the three files is still reflected correctly.
    pin=$(read_role_pin "$role")
    model=$(resolved_model_for_class "implementer")
    local record="IMPLEMENTER: role=$role task=$tid model=$model pin=$pin at $ts"
    # Newer Beads: `bd comments add` (plural). Older: `bd comment add`.
    if bd comments add "$tid" "$record" >/dev/null 2>&1 \
        || bd comment add "$tid" "$record" >/dev/null 2>&1; then
        return 0
    fi
    log_sync_error "failed to record implementer identity ($role) on $tid; review-check gate will see an incomplete implementer set"
    return 1
}

# SPEC INJECTION AT SPAWN BEGIN (v5 D5, claude-workflow-plugin-fkm.7)
#
# Phase D5's first piece (docs/plans/v5-design-phase.md:165): "Each
# implementer's packet includes its unit's spec, criterion texts, and
# declared file set read verbatim from the mirrored artifact at spawn time,
# via the existing SubagentStart injection. The implementer never works
# from the orchestrator's paraphrase, and the injected hash is recorded so a
# later mismatch is visible."
#
# RESOLUTION PATH, each step reusing an EXISTING authoritative reader —
# nothing here re-parses the DESIGN-UNITS grammar or any record grammar:
#   1. qa-gate.sh design-unit-show <tid> — the ONE binding accessor (wraps
#      latest_design_unit_binding). Built, by its own header, for exactly
#      this situation: "a SEPARATE process [that] cannot call
#      latest_design_unit_binding ... directly". bound:false is the
#      ORDINARY case (most tasks never carry a design binding) — silent,
#      nothing injected.
#   2. review-check.sh design-unit-json <artifact> <unit-id> — the ONE
#      per-unit content reader (built for design_conflict; i8cx R4-F1's
#      "authoritative fetch": no second read of the artifact, the unit's own
#      canonical body is a straight projection off validate-design's single
#      guarded parse). This is where "verbatim" comes from: unit_json's
#      string VALUES (criterion text, file paths) are untouched by
#      validate-design's canonicalisation, which only re-sorts keys and
#      reformats whitespace — never rewrites content.
#   3. workflow-manifest.sh hash-file, twice: once over a tempfile holding
#      unit_json (unit_hash — the value that actually gates freshness in
#      qa-gate.sh's spec-injection-status, reusing design-conflict's own
#      R2-F3 doctrine: a WHOLE-ARTIFACT hash would flag an amendment to an
#      UNRELATED unit as "this unit changed", a false alarm already paid for
#      and fixed in the sibling feature) and once over the whole artifact
#      (design_hash — provenance only, never what freshness gates on).
#
# THE INJECTED HASH IS RECORDED as a `SPEC-INJECTED v1` Beads comment on the
# spawned task (grammar below), read back by `qa-gate.sh
# spec-injection-status <tid>` — decision #3 of the fkm.7 D5 brief ("an
# injected hash nothing ever compares is decoration"). Nothing GATES on it
# in this slice (that is D5's separate, not-yet-built per-unit alignment
# check) — this is visibility.
#
# FAILURE DIRECTION. A SubagentStart hook CANNOT block subagent creation AT
# ALL (this file's own header, above, quoting the hooks reference) — so
# "refuse the spawn" is not an available verb here, not merely an expensive
# one. Three-way split, matching this file's EXISTING bd-absence precedent
# (the TASK_HEADER block below) rather than inventing a fourth behaviour:
#   - bd / .beads / qa-gate.sh / jq unavailable: SILENT skip — the same
#     bucket the existing TASK_HEADER guard already uses for this exact
#     condition. If bd is gone, the whole workflow is already degraded
#     elsewhere; this is not the layer that should announce it.
#   - ok:true, bound:false: SILENT skip (the ordinary, ubiquitous case —
#     most tasks never carry a design binding at all).
#   - anything else (a binding exists but its content/hash could not be
#     established right now): LOUD degradation notice in additionalContext,
#     never silent — this is exactly the scenario the feature exists to
#     prevent. A silently-dropped injection would leave the implementer
#     doing precisely what the feature exists to stop ("working from the
#     orchestrator's paraphrase") with no sign anything was supposed to be
#     there instead.
#
# GRAMMAR (posted ON the spawned task, one line, no operator-authored free
# text — this is a fully mechanical event record, unlike IMPLEMENTER/
# DESIGN-UNIT/DESIGN-CONFLICT which all carry a human- or agent-authored
# summary as their last field):
#   SPEC-INJECTED v1 task=<tid> design_task=<dt> unit_id=<uid>
#     design_hash=<h> unit_hash=<h2> at <ISO8601-UTC>: injected at spawn
# Read back by qa-gate.sh's latest_spec_injection (the ONE reader for this
# grammar — see that function's header in qa-gate.sh). Best-effort, same
# discipline as record_implementer above: a failed write logs to
# sync-errors.log and is never retried or confirmed — nothing in this slice
# GATES on the write landing, so paying spawn latency for a write-
# confirmation read-back here is not justified the way it is for DESIGN-
# UNIT/DESIGN-CONFLICT (which DO gate `approve`).
#
# design_task's character class is enforced UPSTREAM by design-unit-show's
# own binding-shape classifier (`test("^[A-Za-z0-9._+-]+$")`) before it is
# ever returned with bound:true — no `/` (or `..` as its own path segment)
# can appear in a value from that envelope, so building
# "$PROJECT_DIR/docs/specs/${design_task}.md" directly below can never
# traverse outside docs/specs/. This is RELIED ON, not re-derived:
# qa-gate.sh's own design_path_is_contained is a private, in-process
# function with no CLI exposure, so re-deriving an equivalent check here
# would be a second implementation of a guarantee the upstream reader
# already provides. (Probed directly, not assumed: a design_task value of
# literally ".." cannot introduce a "/" either — the character class has
# none — so the worst case is a harmless literal filename like
# "docs/specs/...md", never a traversal.)

# hash_file_safe <path> -> 64-hex sha256 on stdout, rc 0; rc 1 with no
# stdout on any failure. Thin glue over workflow-manifest.sh hash-file's
# shape check — the SAME kind of tempfile-then-hash glue qa-gate.sh's own
# design_unit_content_hash already duplicates at "three other call sites"
# by its own comment; freely duplicated boilerplate in this tree, NOT the
# DESIGN-UNITS parser (which this function never touches).
hash_file_safe() {
    local path="$1" h="" h_rc=0
    [ -f "$WORKFLOW_MANIFEST_SCRIPT" ] || return 1
    h=$(bash "$WORKFLOW_MANIFEST_SCRIPT" hash-file "$path" 2>/dev/null) || h_rc=$?
    [ "$h_rc" -eq 0 ] || return 1
    printf '%s' "$h" | grep -qE '^[0-9a-fA-F]{64}$' || return 1
    printf '%s' "$h"
    return 0
}

# record_spec_injection <tid> <design_task> <unit_id> <design_hash> <unit_hash>
# Best-effort writer for the SPEC-INJECTED v1 grammar above. Mirrors
# record_implementer's own `bd comments add || bd comment add` fallback
# chain and failure logging; unlike record_implementer this is NOT
# idempotent per cycle — every implementer spawn that resolves a binding
# gets a fresh record, deliberately: a re-spawn should carry the FRESHEST
# read (especially valuable right after a design_conflict amendment), and
# qa-gate.sh spec-injection-status only ever reads the LATEST record, so a
# stale one left in place by skipping the write would be strictly worse.
record_spec_injection() {
    local tid="$1" design_task="$2" unit_id="$3" design_hash="$4" unit_hash="$5"
    command -v bd >/dev/null 2>&1 || return 1
    local ts
    ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo "?")
    local record="SPEC-INJECTED v1 task=$tid design_task=$design_task unit_id=$unit_id design_hash=$design_hash unit_hash=$unit_hash at $ts: injected at spawn"
    if bd comments add "$tid" "$record" >/dev/null 2>&1 \
        || bd comment add "$tid" "$record" >/dev/null 2>&1; then
        return 0
    fi
    log_sync_error "failed to record SPEC-INJECTED ($unit_id under $design_task) on $tid; spec-injection-status will report no record for this spawn"
    return 1
}

# inject_unit_spec <tid> -> the additionalContext fragment to splice into
# <subagent_assignment> for an IMPLEMENTER spawn, on stdout; "" when there
# is nothing to say (bd/.beads/qa-gate.sh/jq unavailable, or no binding —
# both silent by design, see the header above). Never fails the caller in a
# way that matters: every reachable branch `printf`s something (possibly
# empty) and returns 0; the trailing `|| return 0` guards are defensive
# only, matching this file's `set -e` discipline elsewhere (a bare
# assignment that fails aborts the WHOLE script under `set -e` — see
# get_current_task's own header — so every command substitution below that
# can plausibly fail is paired with `|| var=...`, never left bare).
inject_unit_spec() {
    local tid="$1"
    command -v bd >/dev/null 2>&1 || return 0
    [ -d "$PROJECT_DIR/.beads" ] || return 0
    [ -f "$QA_GATE_SCRIPT" ] || return 0
    command -v jq >/dev/null 2>&1 || return 0

    local show_out="" show_rc=0 show_ok="false" bound="false"
    show_out=$(bash "$QA_GATE_SCRIPT" design-unit-show "$tid" 2>/dev/null) || show_rc=$?
    show_ok=$(printf '%s' "$show_out" | jq -r '(.ok == true) as $b | if $b then "true" else "false" end' 2>/dev/null) || show_ok="false"
    if [ "$show_ok" != "true" ]; then
        log_sync_error "spec injection DEGRADED for $tid: design-unit-show did not return ok:true (exit=$show_rc)"
        local msg=""
        read -r -d '' msg <<EOF || true
SPEC INJECTION DEGRADED for ${tid}: the DESIGN-UNIT binding could not be
read right now (design-unit-show exit=${show_rc:-?}). This packet may be
missing a governing unit spec that actually exists -- do NOT assume no
design applies. Re-check yourself (bd_doc_read, or
"qa-gate.sh design-unit-show ${tid}") before treating this task as unbound,
and file a design_conflict if you establish a unit whose criteria conflict
with reality rather than improvising.
EOF
        printf '%s' "$msg"
        return 0
    fi
    bound=$(printf '%s' "$show_out" | jq -r '(.bound == true) as $b | if $b then "true" else "false" end' 2>/dev/null) || bound="false"
    if [ "$bound" != "true" ]; then
        # Ordinary case: most tasks are never bound to a design unit at all.
        printf ''
        return 0
    fi

    local design_task="" unit_id=""
    design_task=$(printf '%s' "$show_out" | jq -r '.design_task // ""' 2>/dev/null) || design_task=""
    unit_id=$(printf '%s' "$show_out" | jq -r '.unit_id // ""' 2>/dev/null) || unit_id=""
    if [ -z "$design_task" ] || [ -z "$unit_id" ]; then
        log_sync_error "spec injection DEGRADED for $tid: design-unit-show reported bound:true with an empty design_task/unit_id"
        local msg=""
        read -r -d '' msg <<EOF || true
SPEC INJECTION DEGRADED for ${tid}: design-unit-show reported bound:true
but returned an empty design_task/unit_id -- a malformed response, not a
determined binding. Do not assume no unit governs this task.
EOF
        printf '%s' "$msg"
        return 0
    fi

    local artifact="$PROJECT_DIR/docs/specs/${design_task}.md"
    if [ ! -f "$artifact" ]; then
        log_sync_error "spec injection DEGRADED for $tid: bound to unit_id=$unit_id under design_task=$design_task but $artifact does not exist"
        local msg=""
        read -r -d '' msg <<EOF || true
SPEC INJECTION DEGRADED for ${tid}: bound to unit_id=${unit_id} under
design_task=${design_task}, but the mirrored artifact is not currently
readable at ${artifact}. Do NOT proceed as if no design governs this task --
read docs/specs/${design_task}.md yourself (or bd_doc_read the design
task), and file a design_conflict (qa-gate.sh design-conflict ${tid} --unit
${unit_id} "<statement>") if it genuinely cannot be found.
EOF
        printf '%s' "$msg"
        return 0
    fi

    if [ ! -f "$REVIEW_CHECK_SCRIPT" ]; then
        printf ''
        return 0
    fi

    local uj_out="" uj_rc=0 uj_ok="false"
    uj_out=$(bash "$REVIEW_CHECK_SCRIPT" design-unit-json "$artifact" "$unit_id" 2>/dev/null) || uj_rc=$?
    # Mirrors qa-gate.sh's own design_unit_json() wrapper: only attempt the
    # parse when the subprocess actually exited 0 with something on stdout —
    # jq's own `// "false"` defaulting would likely catch a crash anyway, but
    # gating on rc+non-empty first is the established, explicit shape rather
    # than relying on that as a second line of defense.
    if [ "$uj_rc" -eq 0 ] && [ -n "$uj_out" ]; then
        uj_ok=$(printf '%s' "$uj_out" | jq -r '(.ok == true) as $b | if $b then "true" else "false" end' 2>/dev/null) || uj_ok="false"
    fi
    if [ "$uj_ok" != "true" ]; then
        local uj_ekey="unknown" uj_obs=""
        uj_ekey=$(printf '%s' "$uj_out" | jq -r '.error_key // "unknown"' 2>/dev/null) || uj_ekey="unknown"
        uj_obs=$(printf '%s' "$uj_out" | jq -r '.observations // ""' 2>/dev/null) || uj_obs=""
        log_sync_error "spec injection DEGRADED for $tid: design-unit-json($artifact, $unit_id) error_key=$uj_ekey"
        local msg=""
        read -r -d '' msg <<EOF || true
SPEC INJECTION DEGRADED for ${tid}: bound to unit_id=${unit_id} under
design_task=${design_task}, but its content could not be read from the
CURRENT artifact (error_key=${uj_ekey}${uj_obs:+: ${uj_obs}}). The unit may
have been amended or removed since binding. Do NOT improvise -- read
docs/specs/${design_task}.md yourself, and file a design_conflict if the
unit genuinely no longer matches what you were asked to build.
EOF
        printf '%s' "$msg"
        return 0
    fi

    local unit_json=""
    unit_json=$(printf '%s' "$uj_out" | jq -r '.unit_json // ""' 2>/dev/null) || unit_json=""
    if [ -z "$unit_json" ]; then
        log_sync_error "spec injection DEGRADED for $tid: design-unit-json($artifact, $unit_id) returned ok:true with empty unit_json"
        local msg=""
        read -r -d '' msg <<EOF || true
SPEC INJECTION DEGRADED for ${tid}: the design-unit-json read for
unit_id=${unit_id} under design_task=${design_task} came back empty despite
ok:true -- a malformed response. Do not treat this as a confirmed absence
of the unit.
EOF
        printf '%s' "$msg"
        return 0
    fi

    local unit_pretty=""
    unit_pretty=$(printf '%s' "$unit_json" | jq . 2>/dev/null) || unit_pretty="$unit_json"

    local tmpf="" unit_hash="" design_hash=""
    tmpf=$(mktemp -t spec-inject-unit.XXXXXX 2>/dev/null) || tmpf="$QA_TRACKING_DIR/.spec-inject-unit-$$.json"
    if printf '%s\n' "$unit_json" > "$tmpf" 2>/dev/null; then
        unit_hash=$(hash_file_safe "$tmpf") || unit_hash=""
    fi
    rm -f "$tmpf" 2>/dev/null || true
    design_hash=$(hash_file_safe "$artifact") || design_hash=""

    if [ -n "$unit_hash" ] && [ -n "$design_hash" ]; then
        record_spec_injection "$tid" "$design_task" "$unit_id" "$design_hash" "$unit_hash" || true
    else
        log_sync_error "spec injection for $tid: content delivered but NOT recorded (unit_hash='${unit_hash:-<empty>}' design_hash='${design_hash:-<empty>}') -- staleness will not be checkable via spec-injection-status for this spawn"
    fi

    local hash_note="unit_hash could not be computed this spawn (traceability unavailable; the content above is still verbatim)"
    if [ -n "$unit_hash" ]; then
        hash_note="unit_hash=${unit_hash}"
        [ -n "$design_hash" ] && hash_note="${hash_note}, design_hash=${design_hash}"
        hash_note="${hash_note} (recorded on this task; compare later via qa-gate.sh spec-injection-status ${tid})"
    fi

    local msg=""
    read -r -d '' msg <<EOF || true
SPEC INJECTION (v5 D5, claude-workflow-plugin-fkm.7): ${tid} is bound to
unit_id=${unit_id} in the design governed by ${design_task} (mirrored at
docs/specs/${design_task}.md). The declaration below is read VERBATIM from
that artifact at THIS spawn -- never the orchestrator's paraphrase. Build
exactly this. If it conflicts with what you find in the code, or its
acceptance criteria cannot be satisfied as written, file a design_conflict
(qa-gate.sh design-conflict ${tid} --unit ${unit_id} "<statement>") and
stop rather than improvising or partially satisfying it:

${unit_pretty}

(${hash_note})
EOF
    printf '%s' "$msg"
    return 0
}
# SPEC INJECTION AT SPAWN END (v5 D5, claude-workflow-plugin-fkm.7)

# Read the input. If stdin is empty (script invoked manually for testing),
# fall through to the empty-output path.
INPUT=$(cat 2>/dev/null || echo "")
if [ -z "$INPUT" ]; then
    emit_empty
fi

# Extract agent_type. The official input field per the docs is `agent_type`.
# We also accept `subagent_type` for forward compatibility (an earlier
# proposal used that name).
AGENT_TYPE=""
if command -v jq >/dev/null 2>&1; then
    AGENT_TYPE=$(printf '%s' "$INPUT" | jq -r '.agent_type // .subagent_type // empty' 2>/dev/null || echo "")
fi
if [ -z "$AGENT_TYPE" ]; then
    # Without jq, or with malformed JSON, we can't reliably extract the
    # field. Emit empty rather than guessing.
    emit_empty
fi

# V0 (cnz.1): fail-open spawn-evidence log. Append one TSV line
# "<utc-ts>\t<agent_type>" for EVERY spawn (specialists AND built-ins like
# general-purpose/Explore/Plan/grader/judge) — the effort A/B interference
# test (cnz.2) reads this to prove which agent types the runtime spawned and
# to catch ultracode's dynamic workflow layer spawning generic agents. This
# runs BEFORE the is_specialist filter on purpose. It never blocks the spawn:
# any failure is swallowed and the existing JSON output below is unchanged.
mkdir -p "$QA_TRACKING_DIR" 2>/dev/null || true
printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '?')" "$AGENT_TYPE" \
    >> "$QA_TRACKING_DIR/subagent-spawns.log" 2>/dev/null || true

CANON=$(normalize_agent_type "$AGENT_TYPE")
if ! is_specialist "$CANON"; then
    # Not a specialist. Nothing to inject.
    emit_empty
fi

CURRENT_TASK=$(get_current_task)
if [ -z "$CURRENT_TASK" ]; then
    # No active task to assign. Don't surface anything; the spawned
    # specialist will see SessionStart's pending list and pick on its own.
    emit_empty
fi

# V3 (claude-workflow-plugin-jio.1): record WHO is about to implement.
#
# This is the input half of "nobody signs off on their own work". The spawn is
# the only moment the workflow knows, mechanically, which role touched the
# task — an after-the-fact heuristic (label, comment prose, git author) is
# guessable at best and forgeable at worst. `qa-gate.sh approve` and the Stop
# hook both refuse when the recorded reviewer is in this set.
#
# `|| true` is load-bearing under `set -e` (line 31): a bd hiccup here must
# NEVER block a subagent spawn. record_implementer already logs its own
# failures to sync-errors.log; the additionalContext emission below is
# unaffected either way.
if is_implementer_role "$CANON"; then
    record_implementer "$CANON" "$CURRENT_TASK" || true
fi

# v5 D5 (claude-workflow-plugin-fkm.7): spec injection at spawn. Same
# implementer-only scope as record_implementer above (qa reviews, it does
# not implement a design unit) — see inject_unit_spec's own header for the
# full resolution path and failure-direction rationale. `|| SPEC_INJECTION_
# BLOCK=""` is defensive: inject_unit_spec is designed to always return 0
# with SOME stdout (possibly empty), but this runs inside a command
# substitution's own subshell, so even an unexpected internal abort under
# `set -e` can only ever leave this empty, never crash the spawn.
SPEC_INJECTION_BLOCK=""
if is_implementer_role "$CANON"; then
    SPEC_INJECTION_BLOCK=$(inject_unit_spec "$CURRENT_TASK") || SPEC_INJECTION_BLOCK=""
fi

# Pull a short summary of the task. We keep this conservative — no full
# bd show dump (that can be hundreds of lines), just the header lines + the
# notes. The specialist can run bd_show_task or bd_doc_read for the rest.
TASK_HEADER=""
TASK_NOTES_TAIL=""
TASK_LABELS=""
if command -v bd >/dev/null 2>&1 && [ -d "$PROJECT_DIR/.beads" ]; then
    SHOW_OUT=$(bd show "$CURRENT_TASK" 2>/dev/null || echo "")
    if [ -n "$SHOW_OUT" ]; then
        # First 8 lines: typically id, title, owner, type, created, updated.
        TASK_HEADER=$(printf '%s\n' "$SHOW_OUT" | head -8)
    fi
    # Last 30 lines of NOTES section if present. We don't try to parse the
    # exact section boundaries — head/tail of the full output is good enough.
    if [ -n "$SHOW_OUT" ]; then
        # Look for a "NOTES" line and grab up to 30 lines after it.
        TASK_NOTES_TAIL=$(printf '%s\n' "$SHOW_OUT" | awk '/^NOTES[[:space:]]*$/{found=1; next} found{print}' | head -30 || echo "")
    fi
    # Labels from --json (if available).
    LABELS_JSON=$(bd show "$CURRENT_TASK" --json 2>/dev/null || echo "")
    if [ -n "$LABELS_JSON" ] && command -v jq >/dev/null 2>&1; then
        TASK_LABELS=$(printf '%s' "$LABELS_JSON" | jq -r '
            (if type == "array" then .[0] else . end)
            | .labels // []
            | join(", ")
        ' 2>/dev/null || echo "")
    fi
fi

# Build the additionalContext envelope. We keep this short and structured
# so the specialist sees it instantly without needing to scroll.
CONTEXT=""
read -r -d '' CONTEXT <<EOF || true
<subagent_assignment>
You are spawning as the @${CANON} specialist. The orchestrator's currently
active Beads task is: ${CURRENT_TASK}

${TASK_HEADER:+Task header:
${TASK_HEADER}}

${TASK_LABELS:+Labels: ${TASK_LABELS}}

${TASK_NOTES_TAIL:+Recent notes (last 30 lines):
${TASK_NOTES_TAIL}}

Action: claim or continue this task. The Phase 6a J29/J4 convention is
that the orchestrator may have written a SPEC doc on this task before
spawning you — read it FIRST via the bd_doc_read MCP tool:

  bd_doc_read(task_id="${CURRENT_TASK}", name="spec")

(Or, if the orchestrator chose a different name, list what's attached
first via bd_doc_read(task_id="${CURRENT_TASK}", list_only=true).)

If no spec/context doc is attached, the Task() prompt is your full brief.

${SPEC_INJECTION_BLOCK:+
${SPEC_INJECTION_BLOCK}
}
</subagent_assignment>
EOF

# Emit the additionalContext envelope. SubagentStart accepts the standard
# JSON-output additionalContext field per the hooks reference.
if command -v jq >/dev/null 2>&1; then
    JSON_CONTEXT=$(printf '%s' "$CONTEXT" | jq -Rs .)
    cat <<EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SubagentStart",
    "additionalContext": $JSON_CONTEXT
  }
}
EOF
    exit 0
fi

# jq absent — fall back to empty rather than emitting malformed JSON.
log_sync_error "jq not available; cannot emit SubagentStart additionalContext for $CURRENT_TASK -> @${CANON}"
emit_empty
