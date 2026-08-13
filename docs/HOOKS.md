# Hooks Reference

Complete documentation of all hook scripts in the claude-workflow plugin.

---

## Overview

The plugin wires 6 Claude Code hook events in `.claude/settings.json`
(the plugin-manifest `.claude/hooks/hooks.json` adds a 7th, SubagentStart,
for plugin-scoped installs):

| Hook | File | Trigger |
|------|------|---------|
| SessionStart | `session-start.sh` | Session begins |
| UserPromptSubmit | `intent-router.sh` | User submits prompt |
| PreToolUse | `prevent-orchestrator-edits.sh` | Before Write/Edit/MultiEdit (blocks orchestrator edits) |
| PostToolUse | `post-edit.sh` | After Write/Edit/MultiEdit/NotebookEdit tools |
| Stop | `verify-before-stop.sh` | Claude attempts to stop |
| SessionEnd | `session-end.sh` | Session ends |
| SubagentStart (`hooks.json` only) | `subagent-start.sh` | A subagent starts (auto-assign injection) |

---

## Hook Configuration

**File**: `.claude/settings.json`

The shipped `hooks` block wires all six event types (the file also carries
`statusLine`, an `env` block, and a `permissions.allow` list alongside
`hooks` — omitted here for focus):

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-start.sh\"",
            "timeout": 30000
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/intent-router.sh\"",
            "timeout": 10000
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "^(Write|Edit|MultiEdit)$",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/prevent-orchestrator-edits.sh\"",
            "timeout": 5000
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "^(Write|Edit|MultiEdit|NotebookEdit)$",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/post-edit.sh\"",
            "timeout": 10000
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\"",
            "timeout": 1320000
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-end.sh\"",
            "timeout": 15000
          }
        ]
      }
    ]
  }
}
```

> The plugin-manifest `.claude/hooks/hooks.json` mirrors this block. Both files
> now wire `SubagentStart` (`subagent-start.sh`); the ONE remaining difference
> is a second `PostToolUse` matcher (`^Bash$` → `bd-github-link.sh`) that only
> `hooks.json` carries, for plugin-scoped installs.
>
> That difference is the *only* one permitted. `platform-audit.test.sh` checker
> (f) compares the two files' whole hook surface — event set plus per-event deep
> equality — and pins the PostToolUse allowance as exactly "settings' list plus
> that one entry", so drift in any other event, a *different* drift in
> PostToolUse, or an event deleted from **both** files all fail. (Before v4.1
> C1b the checker compared `SubagentStart` alone, and this sentence still
> claimed `SubagentStart` was one of the differences after it had stopped being
> one.)

---

## SessionStart Hook

**File**: `.claude/scripts/session-start.sh`

**Purpose**: Initialize context with Beads state and workflow instructions.

### What It Does

```bash
# 1. Probe the dependencies. THIS HOOK HAS NO EXIT PATH THAT LOSES THE
#    CONTEXT (v4.1 / C0c). It never bails; a missing dependency becomes a
#    <workflow_degraded> block INSIDE the envelope. See "Degraded mode".
BD_ON_PATH=0;   command -v bd >/dev/null 2>&1 && BD_ON_PATH=1
BD_WORKSPACE=0; [ -d "$PROJECT_DIR/.beads" ] && BD_WORKSPACE=1
BD_AVAILABLE=0                       # needs BOTH: the binary and a workspace
[ "$BD_ON_PATH" = 1 ] && [ "$BD_WORKSPACE" = 1 ] && BD_AVAILABLE=1
JQ_ON_PATH=0;   command -v jq >/dev/null 2>&1 && JQ_ON_PATH=1

# 2. Build the degraded block (empty when nothing is missing). Seeded into
#    CONTEXT first so it lands at the TOP of additionalContext.
DEGRADED_BLOCK="<workflow_degraded severity=\"high\">...</workflow_degraded>"

# 3. Run bd doctor silently — gated, like every other bd call below
[ "$BD_AVAILABLE" = 1 ] && bd doctor --quiet

# 4. Create session marker
touch "$PROJECT_DIR/.claude/.session-start"

# 5. Reset QA tracking. ONE read of "is a cycle in flight?" serves BOTH this
#    and 5b — see "The tracker survives a session boundary" below for why two
#    independent reads is itself the bug (94d.1).
SS_ACTIVE_TASK=$(current-task.sh get)
rm -f "$QA_TRACKING_DIR/approved"
if [ -n "$SS_ACTIVE_TASK" ]; then
    : # PRESERVE changed-files.txt: a review cycle is mid-flight and this file
      # is the change set it is reviewing. Reported via workflow_warnings.
else
    rm -f "$QA_TRACKING_DIR/changed-files.txt"
fi
rm -f "$QA_TRACKING_DIR/edit-count"

# 5b. Capture the gate baseline (v4) — ONLY when no review cycle is active,
#     the SAME predicate as 5. Records "this dirt was already here on arrival"
#     so the Stop gate evaluates the session's delta. Fails OPEN: SessionStart
#     must never break a session, so a failure is one sync-errors.log line and
#     nothing more. See "The gate baseline" under the PostToolUse hook.
if [ -z "$SS_ACTIVE_TASK" ]; then
    qa-gate.sh baseline-capture --by session-start
fi

# 6. Get bd prime output (Beads' agent context) — gated on BD_AVAILABLE,
#    as are bd blocked / bd list / bd --version below
[ "$BD_AVAILABLE" = 1 ] && BD_PRIME=$(bd prime)

# 7. Load CLAUDE.md (project memory)
# 8. Get blocked issues (bd blocked)
# 9. Get qa-pending issues
# 10. Inject workflow instructions

# 11. Encode and emit. Three tiers, each still VALID JSON:
#     jq -Rs .  ->  built-in awk encoder  ->  a fixed minimal literal.
CONTEXT_JSON=""
[ "$JQ_ON_PATH" = 1 ] && CONTEXT_JSON=$(printf '%s' "$CONTEXT" | jq -Rs .)
[ -z "$CONTEXT_JSON" ] && CONTEXT_JSON=$(printf '%s' "$CONTEXT" | ss_json_string)
printf '{\n  "hookSpecificOutput": {\n    "hookEventName": "SessionStart",\n    "additionalContext": %s\n  }\n}\n' "$CONTEXT_JSON"
```

### Degraded mode

**This hook never bails and never exits non-zero.** Until v4.1 it had two
hard `exit 1` paths that printed a bare `{"error": "..."}` — not a
`hookSpecificOutput` envelope. Claude Code discards non-envelope hook
output with no diagnostic, so those paths produced a session with the
plugin fully installed, **no `workflow_engine` block, no delegation
contract and no gate instructions**, and nothing anywhere saying so. That
was symptom 1 of the v4.1 P0 (epic `claude-workflow-plugin-2br`) and it is
the worst failure direction the plugin has: a gate that silently ceases to
exist is indistinguishable from a session that never needed one.

Everything after the probe is fail-open and the `<workflow_engine>` block
is unconditional, so those two bails were the only paths that could lose
the context wholesale. They are now replaced by loud degradation.

| Missing | Detected as | Result |
|---------|-------------|--------|
| `bd` not on PATH | `command -v bd` fails **in the hook's shell** | `<workflow_degraded>` naming **PATH divergence first**, with the `bash -lc` vs `bash -c` discriminator |
| `.beads/` absent | directory test | `<workflow_degraded>` naming `bd init` — reported separately, because the PATH advice would be wrong here |
| `jq` not on PATH | `command -v jq` fails | `<workflow_degraded>` naming jq; the envelope is encoded by the built-in awk fallback |

The block is placed at the **top** of `additionalContext`, before
`beads_context` and the issue lists. An LLM that reads 13 KB of workflow
rules before the warning has already decided how to behave by the time the
warning arrives.

It always says three things: **what is missing** (with `fix:` lines that
`workflow-doctor.sh` echoes verbatim in its `session_start` report), **that
the delegation contract is unchanged and still binding**, and **that
enforcement is now advisory** because the Beads-backed state that proves
compliance is what went missing. A session told "degraded" without the
second point will reasonably conclude the contract was lifted.

Two things deliberately keep running in degraded mode:

- **The gate baseline.** `qa-gate.sh baseline-capture` is git-only (it does
  not require bd) and the Stop hook is the only enforcement surface left
  standing, so removing its baseline would make every pre-existing dirty
  path read as this session's unreviewed work.
- **The envelope.** With `jq` absent the old writer emitted
  `"additionalContext": ` followed by nothing — invalid JSON, discarded by
  the runtime, indistinguishable from having no hook at all. The awk
  fallback encoder keeps the full context; a fixed minimal literal carrying
  its own degraded warning is the last resort.

Verify the whole install — including whether this hook's envelope actually
carries the contract — with `bash .claude/scripts/workflow-doctor.sh`.
Regression coverage lives in
`.claude/tests/component/specs/installer-target-functional.sh` section 6,
which runs a rendered target's hook with `PATH=/usr/bin:/bin`. That is the
*only* place the symptom is caught: the doctor's own `session_start` check
runs on a host where bd is present, so it passes against the pre-C0c hook.

### Context Injected

1. **Beads Context** (`<beads_context>`)
   - Output of `bd prime`
   - ~1-2k tokens of agent-optimized context

2. **Project Memory** (`<project_memory>`)
   - Contents of `CLAUDE.md`
   - Project description, users, journeys

3. **Blocked Issues** (`<blocked_issues>`)
   - Output of `bd blocked`
   - Tasks waiting on dependencies

4. **QA Pending** (`<qa_pending>`)
   - Tasks with `qa-pending` label
   - Work awaiting QA review

5. **Workflow Mode** (`<workflow_mode>`)
   - Beads commands cheat sheet
   - Mandatory QA gate reminder
   - Structured notes format

### The tracker survives a session boundary (`TRACKER-PRESERVE`)

Step 5 above used to `rm -f changed-files.txt` unconditionally. That is right for
a new session and wrong for every other reason this hook fires: **SessionStart
runs on `startup`, `resume`, `clear` *and* `compact`**, so a conversation that
compacted in the middle of a QA review deleted the change set out from under the
review that was reading it.

Reproduced live on this repository's own `94d` review: **26 tracked paths → 0**,
then `qa-gate.sh enter`'s reconcile rebuilt **10** of them from `git status` minus
a 35-hour-old, 159-entry gate baseline. Every step reported `ok:true`,
`change_set_hash` moved `01296db9… → 0b5a546e…`, and nothing anywhere said 16
paths had gone. This is strictly worse than the pre-reconcile behaviour it
replaced: a destroyed tracker used to hash to the empty-list `e3b0c442…`, which is
loudly and self-evidently wrong. The reconciler is what made the truncated set
look correct.

**The guard.** `changed-files.txt` is preserved when `current-task` names a task —
**the same predicate step 5b has used for the gate-baseline capture since
3mg.1**, deliberately identical rather than merely similar. Two decisions in one
hook turning on one question must not be able to answer it differently: the
disagreement that matters is "tracker preserved, and then the work it names
baselined as pre-existing", which is the same lost-change-set state by another
route. So the read is hoisted once and both blocks consume it.

Notes on the shape, each of which was a rejected alternative:

- **No bd label read.** An earlier draft required `qa-gate-entered`/`qa-pending`
  as well. That made a decision about a local file depend on bd + jq + a
  `bd show` round-trip (against this hook's whole "a degraded install still
  works" contract), and re-opened the asymmetry from the other end.
  `session-lifecycle.sh` 8.3 pins that the preserve works for a `current-task`
  naming no Beads issue at all.
- **`edit-count` is *not* preserved with it.** Its only consumer is
  `post-edit.sh`'s every-10-edits progress comment; it carries no evidence about
  *which* paths changed, so nothing downstream can certify less because it reset.
- **The stickiness is real and reported, not hidden.** `approve` clears
  `current-task`; `block` deliberately does not (a block/fix loop is one cycle).
  So a session that dies mid-cycle leaves the id set and the tracker pinned open
  until something clears it. That direction is *over*-reporting — it blocks a
  Stop until someone looks, and `current-task.sh clear` resolves it — whereas
  under-reporting certifies a subset of what shipped. It is also not a new
  exposure: step 5b has carried the identical stickiness since 3mg.1.
- **It says so.** A carried-over tracker emits a `workflow_warnings` line naming
  the cycle, the path count, and that recovery command. Invisibility is what made
  94d.1 expensive; a silent preserve would fix the data and still leave the
  operator unable to tell a carried-over tracker from a fresh one.

The region is sentinel-wrapped (`# TRACKER-PRESERVE BEGIN/END (94d.1)`) and the
`rm -f` sits **outside** it behind `if [ "${SS_TRACKER_KEEP:-0}" != "1" ]`, so
excising the region yields an unset variable, a `0` default, and the *pre-fix
unconditional delete* — which is what `session-lifecycle.sh` 8M strips and
measures (tracker destroyed mid-cycle, valid envelope, no warning), with a
restore-control leg. Do not rename the sentinels, and do not fold the `rm` inside
them.

---

## UserPromptSubmit Hook

**File**: `.claude/scripts/intent-router.sh`

**Purpose**: Provide context for LLM-driven work analysis (NOT keyword matching).

### Design Philosophy

**Old approach (removed)**: Keyword matching like `grep -qE '(bug|error|fix)'`
- Brittle - misses nuanced requests
- Limited - can't understand context
- Inflexible - hardcoded patterns

**Current approach**: LLM-driven analysis
- The **Orchestrator agent** analyzes requests intelligently
- Hook provides framework and current task context
- Claude determines work type, domains, and complexity

### What It Does

```bash
# 1. Parse user prompt
INPUT=$(cat)
PROMPT=$(echo "$INPUT" | jq -r '.prompt // empty')

# 2. Get current Beads state (for context, not detection)
CURRENT_TASK=$(bd list --status in_progress --json | jq -r '.[0].id // empty')
if [ -n "$CURRENT_TASK" ]; then
    CURRENT_TASK_INFO=$(bd show "$CURRENT_TASK" | head -30)
fi

# 3. Inject orchestrator instructions (LLM does the analysis)
# 4. Add current task context if exists
# 5. Output JSON for additionalContext
```

### Why LLM-Driven?

| Scenario | Keyword Matching | LLM Analysis |
|----------|------------------|--------------|
| "The login isn't working right" | Might miss | Understands it's a bug |
| "Can we make this faster?" | "improve" not present | Recognizes improvement |
| "Users are complaining about X" | No keywords | Understands context |
| "Continue what we were doing" | No keywords | Checks current task |

### Context Injected

The hook injects `<orchestrator_instructions>` that guide Claude to:

1. **Analyze work type**: bug, feature, improvement, testing, planning
2. **Identify domains**: backend, frontend, devops
3. **Assess complexity**: simple → single task, complex → epic with subtasks
4. **Take action**: Create appropriate Beads tasks, delegate to specialists

The Orchestrator uses its intelligence to understand:
- Nuanced language ("it's broken" → bug)
- Context from current task
- User intent beyond keywords
- When to ask clarifying questions

---

## PostToolUse Hook

**File**: `.claude/scripts/post-edit.sh`

**Purpose**: Track file changes for QA review.

### Matcher

Configured in `settings.json` **and** `.claude/hooks/hooks.json` with matcher
`^(Write|Edit|MultiEdit|NotebookEdit)$` — the two manifests are pinned to agree
by `platform-audit.test.sh` (f), so this matcher is edited in both files or
neither. Those four tools are exactly the ones whose `tool_input` carries a
path: `file_path` for Write/Edit/MultiEdit, `notebook_path` for NotebookEdit
(added in 94d — before that the extraction knew only `file_path`/`path`, so a
notebook edit produced a valid `{}` envelope and tracked nothing at all).

The `notebook_path` spelling is **measured, not assumed** (fkm.1.15 review). The
published hooks reference documents `tool_input` per tool but never mentions
NotebookEdit, so the source is the shipping runtime: Claude Code 2.1.221
(`BUILD_TIME 2026-08-03T03:19:26Z`, `GIT_SHA 6efaf12e`) declares the tool input as
`strictObject({notebook_path: string().describe("The absolute path to the Jupyter
notebook file to edit (must be absolute, not relative)"), cell_id: …})` and builds
every hook payload as `{tool_name: <call>.name, tool_input: <call>.input,
tool_use_id: …}` — so `tool_input` *is* the validated tool input, and
`strictObject` means `file_path` is rejected rather than accepted as an alias.
Both strings are greppable in the installed binary; re-confirm there on a newer
release. Note what the component spec's `11a` leg does and does not prove: it
proves the hook READS the field the test sends, which is not the same claim as the
runtime sending it. The two halves together are the evidence.

**Bash is deliberately not matched here, and cannot be.** `tool_input.command`
is a shell string with no path field, so there is nothing for an extraction to
read; a `^Bash$` matcher would fire and track nothing. Bash-written files are
covered instead by the git-status reconcile described below — **partially**: it
folds in the ones whose path was clean when the gate baseline was captured, and
misses a second write to a path the baseline already lists. See "The tracker
reconcile", the line-granularity limit under "Known limits".

> **Corrected 94d (prove-or-remove).** This section used to claim the matcher
> was `^(Write|Edit|MultiEdit|Bash)$` and that a *write-shaped* Bash command had
> its target paths "recovered and tracked" (llh.19). That mechanism was
> **REVERTED in `5535a6d`** — the same commit that added this prose — because
> fail-closing on an identity the runtime does not surface to PreToolUse broke
> specialist edits (a P0-class regression for a P2; the shape is recorded in
> `LESSONS.md`). The code went; the paragraph stayed, and for seven weeks the
> docs described coverage that did not exist for the exact class of edit 94d had
> to build a reconcile for. Neither manifest has ever contained `Bash` in this
> matcher, and `post-edit.sh` has never carried a command-string parser.

### What It Does

```bash
# 1. Extract file path from tool input. Three spellings are accepted because
#    different tools expose the field differently: Write/Edit/MultiEdit use
#    `file_path`, some payloads use `path`, NotebookEdit uses `notebook_path`.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // .tool_input.notebook_path // empty')

# 2. Skip when the path is empty (defensive — Edit/MultiEdit always emit a
#    file path, but the hook never errors on unexpected input).
if [ -z "$FILE_PATH" ]; then
    echo '{}'; exit 0
fi

# 3. Apply the THREE filters, in this order. Only the first is shown inline;
#    the regex below is illustrative — the shipped one lives in
#    workflow-denylist.sh (see "The shared denylist"), and the other two
#    filters have their own sections ("The second rule", "The third rule").
#
#    3a. rule 1, the build-artefact denylist. The pre-Phase-1 hook used an
#        extension allowlist (B6) which silently dropped .md, .yaml, .toml,
#        Dockerfile, .tf, .proto, etc. The current hook tracks EVERYTHING
#        except known build/lock noise.
#    3b. rule 2, workflow_self_written — gate state the workflow rewrites as a
#        side effect of running, which must not enter its own change set.
#    3c. rule 3, record-time containment — a path outside $CLAUDE_PROJECT_DIR
#        is dropped AND logged to sync-errors.log.
DENYLIST_REGEX='(^|/)(node_modules|dist|build|coverage|\.git|\.next)/|\.(lock|pyc|map)$|\.min\.(js|css)$|(^|/)(pnpm-lock\.yaml|package-lock\.json|yarn\.lock|Cargo\.lock|poetry\.lock|go\.sum)$'
if [[ "$FILE_PATH" =~ $DENYLIST_REGEX ]]; then
    echo '{}'; exit 0
fi

# 4. Race-safe dedup append. With flock available we take an exclusive lock
#    around grep+append. Without flock (macOS without coreutils), we append
#    unconditionally and rely on `sort -u` at read time. Both strategies
#    preserve correctness; the flock path saves disk on hot loops.
if command -v flock >/dev/null 2>&1; then
    (
        flock -x 9
        if [ ! -f "$TRACKING_FILE" ] || ! grep -qxF "$FILE_PATH" "$TRACKING_FILE"; then
            printf '%s\n' "$FILE_PATH" >> "$TRACKING_FILE"
        fi
    ) 9>"$LOCK_FILE"
else
    printf '%s\n' "$FILE_PATH" >> "$TRACKING_FILE"
fi

# 5. Soft cap at ~500 unique entries; only trim when above 1000 so concurrent
#    appenders don't lose data. FLOCK-ONLY since 94d: the trim is a
#    read-modify-write, and any append landing between its read and its `mv` is
#    DISCARDED — a discarded path is a file the Stop gate never sees and the
#    change-set hash never covers. Without flock there is no way to close that
#    window, so the trim is skipped (and logged) and the file is allowed to grow:
#    an oversized tracker costs disk, a lost path costs an unreviewed change.
if [ "$LINE_COUNT" -gt 1000 ]; then
    if command -v flock >/dev/null 2>&1; then
        ( flock -x 9
          sort -u "$TRACKING_FILE" | tail -500 > "$TRACKING_FILE.tmp"
          mv "$TRACKING_FILE.tmp" "$TRACKING_FILE" ) 9>"$LOCK_FILE"
    else
        log_sync_error "trim SKIPPED at $LINE_COUNT lines: no flock, and a
                        non-atomic trim can drop tracked paths"
    fi
fi

# 6. Edit-count batching: emit a progress comment to Beads every 10 edits.
#    EDIT_COUNT is reset to 0 by session-start.sh so the cadence resets per
#    session. The active task id is sourced via current-task.sh (F3 single
#    source of truth); when empty, we skip the comment rather than guess.
if [ $((EDIT_COUNT % 10)) -eq 0 ] && [ -n "$CURRENT_TASK" ]; then
    bd comments add "$CURRENT_TASK" "Progress: $UNIQUE_COUNT files edited" \
        || log_sync_error "bd comments add failed for $CURRENT_TASK"
fi

# 7. Emit a valid JSON envelope. This hook only tracks state, so it emits
#    `{}` rather than `additionalContext` — the Stop hook surfaces the
#    review context to Claude.
echo '{}'
```

### Output Envelope

Per the Claude Code hooks reference, PostToolUse must emit either `{}`
(no-op) or `{"hookSpecificOutput":{"hookEventName":"PostToolUse",
"additionalContext":"..."}}`. We standardise on `{}` because the gate
surface lives in the Stop hook; emitting an inline reminder on every
edit produces noise and confuses the model's context. (Pre-Phase-1 hooks
emitted raw markdown text, which Claude silently dropped — B5.)

### Tracked File Types

The denylist approach means almost everything is tracked. Tracked files
include source code (`.ts`, `.tsx`, `.js`, `.jsx`, `.py`, `.go`, `.rs`,
`.java`, `.rb`, `.php`, `.vue`, `.svelte`), stylesheets (`.css`, `.scss`),
markup (`.html`, `.md`, `.yaml`, `.toml`), infra (`Dockerfile`, `.tf`,
`.proto`), and config (`.json`, `.env.example`).

There is exactly one authoritative list of what is *denied*, and it is not
this document: `.claude/scripts/workflow-denylist.sh` carries the regex with a
numbered comment block explaining each intent group. Broadly it covers build
and dependency output, lockfiles and compiled/minified artifacts, and
workflow-internal churn (worktrees, e2e fixture sync, agent memory, plan-mode
plan files, the harness session scratchpad, mutation-sweep run state). Read
the lib for the current set — a second enumeration here would drift, which is
the same failure mode that motivated consolidating the regex in the first
place. Note that a denied path is not merely untracked: it never enters
`change_set_hash` either, which is why editing that lib is a migration.

### The shared denylist (`workflow-denylist.sh`)

The denylist is **one definition with four consumers**, and it lives in
`.claude/scripts/workflow-denylist.sh`:

| Consumer | Question it answers |
| --- | --- |
| `post-edit.sh` | what gets TRACKED into `changed-files.txt` |
| `qa-gate.sh` | what `reconcile_tracker` APPENDS to `changed-files.txt` (94d) |
| `impact-report.sh` | what enters the canonical change set and its HASH |
| `verify-before-stop.sh` | what the Stop gate treats as needing REVIEW |

`qa-gate.sh` became the fourth consumer in 94d: `reconcile_tracker` is the
*second writer* of `changed-files.txt`, and two writers of one file applying
different filters is the same drift class this lib exists to prevent — the
reconciler would append build output the other writer is careful to drop. It
consumes the lib for that filter only; canonicalisation still defers to
`impact-report.sh --hash-only` (llh.18), so there is still exactly one hash.

Before v4 each script carried its own copy and they drifted: only the Stop
hook's knew about `.claude/worktrees/` and the e2e fixture churn, so post-edit
tracked worktree paths **into the change-set hash that the gate could not
see**. The hash and the gate disagreed about what "the changes" were, and the
only symptom was an occasional un-releasable approval nobody could explain.

The lib is FLAT under `.claude/scripts/` on purpose: `make sync-fixtures` and
the vitest drift guard enumerate `.claude/scripts/*.sh`, so a nested `lib/`
would silently not sync into the e2e fixtures and their sourced hooks would
break. Each consumer resolves it **relative to its own `${BASH_SOURCE[0]}`**,
never to `$CLAUDE_PROJECT_DIR` — a hook may legitimately run with
`CLAUDE_PROJECT_DIR` pointing at a different checkout than the install the
script lives in.

Beyond build artifacts and lockfiles the regex also drops:

- `.claude/worktrees/` — parallel-agent scratch checkouts. Never a
  deliverable; the worktree's own gate reviews its work in situ.
- `.claude/tests/e2e/fixtures/<f>/{.claude/{scripts,beads},.beads}/` — churn
  the harness rewrites mechanically. Scoped to those subtrees only, so a real
  edit to a fixture's `fixture.yaml` or `src/` is still reviewable.
- `MEMORY.md` and `.claude/memory/` — agent recall state, not deliverables.
  They leave the reviewable set BEFORE the F1 doc-only classification, so a
  memory-only change set is `empty` (release, no gate record) rather than
  `doc-only` (auto-approved WITH a `[review bypass: ...]` record about nothing).
- `.claude/plans/` — plan-mode plan files, matched wherever they live. The
  real shape is `~/.claude/plans/<slug>.md`, **outside the repo**: `post-edit.sh`
  records `tool_input.file_path` verbatim, so the change set was never bounded
  by the project root. A plan is the INPUT to the work, not the work. This one
  was a hard dead end rather than noise — see the v4.1 note under "Denylist
  changes are a hash migration" below. `docs/plans/` is a tracked deliverable
  and does not match.
- `/tmp/claude-<session>/` (and `/private/tmp/...` on macOS) — the harness's own
  per-session scratchpad, where grader verdicts and relay artifacts are written.
  They used to mutate the change-set hash mid-relay. The branch is `^`-anchored
  and absolute so a repo-relative `src/tmp/claude-1/` is untouched.
- `.claude/.mutation-runs/` and `.claude/.mutation-worktrees/` — per-run reports
  and throwaway checkouts from `.claude/tests/mutation/mutation-sweep.sh`.
  Gitignored, but still reachable by `Edit`, because `--keep-worktrees` exists
  so a human can debug a surviving mutant in situ. The harness's own source
  under `.claude/tests/mutation/` is a deliverable and does not match.

Deliberately **not** denylisted: `CLAUDE.md` (behaviour-bearing — SessionStart
injects it), `LESSONS.md` and `HANDOFF.md` (audit deliverables). The `*.md`
doc-only fast path already handles those when they change alone.

Also deliberately not denylisted: **`/tmp` and `/var/folders/` as a class**, and
the reason is mechanical rather than stylistic. Two component specs seed
`changed-files.txt` with ABSOLUTE paths rooted at `mktemp -d`'s parent —
`specs/impact-report-paths.sh` (the project / sibling-worktree / foreign-repo /
non-git-scratch mix that exists to prove path relativisation) and
`specs/worktree-approval-resolution.sh` (the worktree-absolute spellings that
exist to prove the cross-worktree approval bridge). That parent is `/tmp/...` on
a Linux CI job and `/var/folders/...` on a macOS dev box, so either pattern
would silently empty both change sets and both specs would keep passing while
proving nothing. The narrow `/tmp/claude-<session>/` branch above is safe
precisely because those fixtures are created as
`mktemp -d -t component-fixture.XXXXXX`, which never yields a `claude-` prefix.

Agent-chosen scratch outside that prefix (`/tmp/qa-p5n-probe/`, a bare
`/tmp/enc-diff.sh`) is **not this regex's problem, and is no longer unsolved**:
since claude-workflow-plugin-fkm.1.15 it is dropped at record time by
`post-edit.sh`'s containment check — see
["The third rule"](#the-third-rule-record-time-containment) below. That rule
compares the path against `$CLAUDE_PROJECT_DIR` rather than matching a pattern,
which is exactly why it can drop those probes while KEEPING the two specs'
fixture paths: those live *inside* the `mktemp -d` root their own fixture points
`CLAUDE_PROJECT_DIR` at. A regex here cannot tell the two apart; a root
comparison can. Widening this regex is still refused. Prompt guidance (`qa.md`
and the three specialist prompts direct throwaway probes to the session
scratchpad or `.claude/.qa-tracking/`) remains as the belt to that braces.

If the lib is missing, each consumer fails closed in its own idiom:
`impact-report.sh` exits 3 and emits no hash (upstream treats an empty hash as
refuse-to-release); `verify-before-stop.sh` BLOCKS with a remediation reason
(emitted **after** the `stop_hook_active` circuit breaker, never before it);
`qa-gate.sh`'s `reconcile_tracker` REFUSES (`approve` exits 2 with
`error_key: tracker_unreconcilable`, no bypass flag), because an unfiltered
reconcile would append build output to an append-only file with no way back;
`post-edit.sh` tracks the path unfiltered, because for a hook that feeds the
gate, over-tracking is the fail-closed side.

#### The second rule: `workflow_self_written`

The same lib carries a **second, narrower rule**, added in 94d, and it answers a
different question. The denylist answers "is this reviewable work?".
`workflow_self_written` / `WORKFLOW_SELF_WRITTEN_REGEX` answers "**may this path
enter the change set as a side effect of the gate itself running?**" Two members,
and the list is deliberately short — rewritten by the gate's own machinery on
essentially every invocation, and never authored by the work under review:

| Member | Why |
| --- | --- |
| `.claude/.qa-tracking/**` | Gate state: the tracker, the gate baseline, the impact report, the review artifacts. Not gitignored in every install — `install.sh` writes that rule only when the target has no `.gitignore` at all. |
| `.beads/interactions.jsonl` | bd rewrites it on **every** call, including the gate's own `add_comment` and `label add`. |

**`.beads/issues.jsonl` is not a member.** It is the committed ledger, a real
deliverable, and bd 1.1.2 rewrites it only on an explicit export — so its content
is stable across a cycle and it belongs in the change set. That one-file boundary
*is* the rule; `denylist-source.test.sh` and `denylist-shared.sh` section E pin it
from both sides.

It stays **separate from** `WORKFLOW_DENYLIST_REGEX` rather than being folded in,
and that is a classification call, not an accident: denylisting these would drop
them from the change set *entirely*, which flips a beads-only change set from the
`beads-state` fast path (releases **with** a gate record) to `empty` (releases
with none). `workflow_self_written`'s own header in the lib carries the full
argument.

Three places apply it — the two **writers** of `changed-files.txt` and the Stop
hook's git walk:

| Applier | Effect |
| --- | --- |
| `post-edit.sh` | never records a self-written path at all (the sentinel-wrapped `SELF-WRITTEN-FILTER` block) |
| `qa-gate.sh` `reconcile_tracker` | never appends one |
| `verify-before-stop.sh` `reviewable_changes()` | the git half skips them, so the gate's own bookkeeping cannot make somebody else's change set look mixed |

`impact-report.sh` deliberately does **not** apply it. It *reads* the tracker the
other two write, so by hash time a self-written path has already been filtered at
the source; adding the rule at a reader would make that reader disagree with the
other readers about an entry an older install had already recorded, which is the
hash-and-gate-disagree failure this lib exists to prevent.

For the production consequence of the Stop-hook half — why the F1 doc-only fast
path was dead before the rule existed — read the in-code rationale in
`reviewable_changes()` in `verify-before-stop.sh` (the `KNOWN LIMITS` note above
it, and the `skip=0` dedup inside it). It is the authoritative account and is
not restated here.

> **Corrected in 94d (QA finding R2-F5).** The rule shipped with `post-edit.sh`
> **not** applying it, which meant the primary route into the tracker contradicted
> the rule's stated intent. The consequence was deterministic on the Claude review
> lane: a reviewer writing `review-artifact-<tid>-r<n>.json` with the `Write` tool
> moved `change_set_hash`, which made the impact report `enter` had just generated
> stale, which made `approve` refuse with `error_key: impact_report_stale`. The
> reason it went unnoticed for two review rounds is that the *other* writers of
> gate state use shell redirects (`codex-review.sh`, and the review-request
> assembly in `qa.md` 6p.1), and `post-edit.sh` is not wired to `Bash` — so the
> Sol lane was immune by accident and the Claude lane was not. Fixed at the writer;
> pinned by `specs/post-edit.sh` section 12 and its 12M strip-META.

#### The third rule: record-time containment

`post-edit.sh` carries a **third** filter that is NOT in the shared lib, added in
claude-workflow-plugin-fkm.1.15: a path outside `$CLAUDE_PROJECT_DIR` never
enters `changed-files.txt`. It lives in the sentinel-wrapped
`CONTAINMENT-FILTER` region, immediately after the second rule.

**Why it exists.** The 2026-07-29 bug report on 94d documents two failure modes
and closes with two numbered acceptance items. Item (1) — reconcile the tracker
against `git status` — shipped as `reconcile-tracker` above. Item (2), "drop
paths outside `CLAUDE_PROJECT_DIR` at record time", did not, and went unnoticed
through four review rounds. They are the two directions of one defect: item (1)
is under-coverage (the hash certified LESS than the diff), this is
over-coverage (`$FILE_PATH` is recorded verbatim, so the change set was not
bounded by the project at all). The recorded instance: a QA scratch file at
`/tmp/enc-diff.sh`, written with the `Write` tool, moved `change_set_hash`
`a950fa6b… -> cb000516…` and made `qa-gate.sh approve` refuse the *correct*
impact report as stale. Such an entry is also unreviewable by construction —
`impact-report.sh` records it `ok:false` ("outside the analyzed project"), and a
reviewer's `git diff` over the tracker paths cannot show it.

**Why it is not in the shared lib**, in one line each: exactly one applier by
construction (the other tracker writer, `reconcile_tracker`, derives its paths
from `git status --porcelain` inside the repo and *cannot* emit an out-of-project
path); the readers must not apply it, for the same reason they must not apply
rule 2; and it is not a path pattern at all but a comparison against a runtime
root, while the lib is deliberately root-agnostic — every consumer sources it
`BASH_SOURCE`-relative precisely so it never depends on `$CLAUDE_PROJECT_DIR`.

**How it decides**, biased to be reluctant to drop (a false drop is
under-coverage, the failure 94d exists to close):

| Input | Verdict |
| --- | --- |
| relative path | kept, resolved against the root — that is how every reader already interprets a relative tracker entry |
| absolute, under the root in either spelling (as given, or `pwd -P`) | kept; macOS hands out `/var/folders/…` while the physical path is `/private/var/folders/…` and either can arrive |
| absolute, outside both — but whose own **directory** resolves back inside | kept; one `cd` on the drop path only. The dirname is resolved physically and the leaf is reattached by name, never followed |
| absolute, outside after all of the above | **dropped, and logged** |
| project root unresolvable | tracked, and logged — over-tracking is the fail-closed side for a hook that feeds the gate |

Normalisation is lexical (`.`, `..`, `//` collapsed, no filesystem access), so a
`..` escape that is string-prefixed by the root is still caught and a
just-deleted path still classifies.

**No symlink is ever resolved on the keep path**, so a symlink that crosses the
project boundary is kept in *either* direction. Nothing in the hook follows a
link: no executable line calls `readlink`, `realpath` or `stat`, and none tests
`-L`. `pwd -P` runs in exactly two places and both are `cd <directory> && pwd -P`
— never the edited leaf. All three shapes below are tracked, and none writes a
`sync-errors.log` line — measured on the canonical hook with `CLAUDE_PROJECT_DIR`
pointed at a scratch tree (`$ROOT` is the project root, `$OUT` a directory
outside it):

| Shape | Verdict |
| --- | --- |
| in-repo **directory** symlink whose target is outside — `$ROOT/dirlink/g.ts` | tracked; the lexical comparison answers "inside" first, so the `cd` retry never runs |
| in-repo **file** symlink whose target is outside — `$ROOT/filelink.ts` | tracked; same first comparison, and the retry would keep it regardless — it resolves the dirname and reattaches the leaf by name |
| out-of-repo symlink pointing **into** the project — `$OUT/inlink/x.ts` | tracked; the one shape the retry exists for, and the only one whose verdict it changes |

> **Corrected in 94d (QA finding R5-F1, `claude-workflow-plugin-dmi`).** This
> section and the in-code header both used to state the opposite for the first
> shape — "a symlink *inside* the repo whose target is outside resolves to the
> target and is dropped". Measurement contradicts it: the path is spelled through
> the root, so it is judged inside on the first, lexical comparison and the
> physical retry never runs. The direction of the error was safe — over-tracking
> is this rule's own fail-closed side — so the documented limit was corrected to
> match the code rather than the code changed to match the limit. Pinned by
> `specs/post-edit.sh` section `13e`, with `13N` excising the retry alone to show
> it is the third row's cause and nothing else's, and `13R` forcing the retry to
> run for every path — which is what pins the *counterfactual* in the second row
> (the two in-repo shapes diverge under the retry: the directory shape drops, the
> file shape does not). `13N` on its own cannot say that: it shows only that
> neither in-repo shape *reaches* the retry, which is symmetric. That gap was
> QA finding R4-F3 — the claim was true and the coverage for it was prose.

**The drop is always logged** to `sync-errors.log`, which SessionStart surfaces.
That is what separates this rule from the other two: rules 1 and 2 drop
known-inert classes, while this one can drop a file somebody genuinely edited, so
it must never do it silently. Pinned by `specs/post-edit.sh` section 13 (in-repo
keeps in `13a`, four out-of-repo drops in `13b`, the envelope in `13c`, the log in
`13d`, the three symlink shapes above in `13e`, two strip-METAs — `13M` for
the whole region, `13N` for the retry alone — and `13R`, which forces the retry
instead of excising it) and by `specs/denylist-shared.sh`
D4, which asserts both halves: rule 1 still *keeps* `/tmp/qa-p5n-probe/notes.md`
while the hook drops it.

#### Denylist changes are a hash migration

`change_set_hash` is a sha256 over the **denylist-filtered** changed-files
list, so **two** independent things move it and both are hash migrations:

1. **Editing the regex** changes the recomputed hash of any change set
   containing a newly-(un)matched path.
2. **Changing what reaches `changed-files.txt` in the first place.** 94d added
   `reconcile_tracker` (the git-visible paths no Write/Edit hook recorded) and
   widened `post-edit.sh` to `NotebookEdit`. Any session with git-visible dirt
   beyond what its tracker already held hashes differently afterwards, with the
   regex untouched. The list is the hash's input; growing the input is the same
   migration as re-filtering it.

Either way an approval recorded before the change no longer matches what the
Stop hook recomputes after it, so the gate emits `LABEL_WITHOUT_RECORD` and
re-blocks.

That is the correct direction — a stale approval must not release — but it is
user-visible friction, so **ship each kind of change in ONE landing**: one
landing costs in-flight cycles exactly one migration.

Recovery for a cycle caught mid-flight is exactly what the block reason prints —
no extra step:

```bash
bash .claude/scripts/qa-gate.sh enter <task-id>
bash .claude/scripts/impact-report.sh <task-id>
bash .claude/scripts/qa-gate.sh approve <task-id> '<approval summary>'
```

Do **not** remove the `qa-approved` label first. Until v4.1 that removal was
mandatory and undocumented in the block reason (`enter` does not clear
`qa-approved`, and `approve` short-circuited as an "idempotent no-op" while it
was present, so the printed recipe wrote no new record and the gate stayed
blocked — claude-workflow-plugin-gz3). `approve`'s idempotency is now hash-aware,
so a stale label no longer stops it; see
[Approve idempotency is hash-aware](#approve-idempotency-is-hash-aware).
Re-review the change set before re-approving: the guard removes a dead end, it
does not waive a check. (Pinned by
`.claude/tests/component/specs/denylist-shared.sh` C4/C5, which drive the
commands extracted from the block text.)

**Landings so far.** v4.0.0 (2026-07-26) consolidated three drifted copies into
one lib and added `.claude/worktrees/`, the e2e fixture churn, `MEMORY.md` and
`.claude/memory/`. v4.1.0 (2026-07-29) added three more **together, in one
commit**, because the change set turned out never to have been bounded by the
repo: `(^|/)\.claude/plans/`, `^(/private)?/tmp/claude-[^/]+/`, and
`(^|/)\.claude/\.mutation-(runs|worktrees)/`. Sections C and D of
`denylist-shared.sh` split the proof between them: **C** drives an invented
canary and shows that editing the lib moves the consumers it drives and re-blocks a
stale approval; **D** pins the *pre-landing* lib — the shipped regex with those
three alternatives stripped by literal substring — records an honest approval
under it, and then restores the real lib, so the restore *is* the v4.1 landing.
D's first assertions are a discriminating control: they fail loudly if a future
rename makes the strip a silent no-op, because a "pre-landing" lib identical to
the shipped one would let every other D assertion pass while proving nothing.

### Tracking File Location

```
.claude/.qa-tracking/
├── changed-files.txt        # The change set: one ABSOLUTE path per line, deduped at
│                            # read time (sort -u). TWO writers — post-edit.sh (tool
│                            # edits) and qa-gate.sh reconcile_tracker (the git-visible
│                            # remainder, 94d). This file is what change_set_hash is
│                            # computed over, so a path missing here is a path no
│                            # approval covers. See "The tracker reconcile".
│                            # PRESERVED across a session boundary while a cycle is
│                            # in flight (94d.1) — SessionStart used to delete it
│                            # unconditionally, including on `compact`
├── reconcile-subtracted.txt # What the LAST reconcile dropped as already-baselined and
│                            # NOT covered by the tracker: one ABSOLUTE path per line,
│                            # rewritten (and truncated) on every reconcile. The durable
│                            # half of the 94d.1 accounting — RECONCILE_OBS carries only
│                            # the first 12, and the Stop hook discards the string
│                            # entirely on its success path
├── edit-count               # Counter for the every-10-edits batched bd comments
├── current-task             # Single source of truth: active task id (F3)
├── current-task.repo        # Repo fingerprint at set time (I8 cross-repo guard)
├── gate-baseline            # Versioned git-status snapshot the Stop gate subtracts (v4)
├── approved-baseline        # LEGACY (0wk.2) pre-v4 snapshot; read for one release, then deleted
├── impact-report-<tid>.json # Mechanical impact_of artifact; SURVIVES approve, so it is
│                            # also the approved-file-set record another checkout reads
│                            # (see "Cross-worktree approval resolution")
├── sync-errors.log          # Best-effort bd-call failures surfaced by SessionStart
├── worktree-sweep.log       # SessionEnd's REPORT-ONLY worktree-sweep count, surfaced
│                            # (and truncated) by SessionStart. Its own file, NOT
│                            # sync-errors.log — see "SessionEnd Hook" below
└── .changed-files.lock      # flock target (only on systems with flock)
```

Everything here is **per-checkout**. A linked worktree has its own
`.claude/.qa-tracking/`, hence its own tracker, hash, baseline and impact
report — which is exactly why a cross-checkout approval needs the resolution
step described under the Stop hook.

### The gate baseline (`gate-baseline`)

A snapshot of `git status --porcelain` that says "this dirt was already here;
it is not this session's work". Both git-side readers subtract it — the Stop
hook's git walk and `reconcile_tracker` — so the gate evaluates the session
**delta** rather than the whole working tree. Without one, opening a session in a repo that is merely dirty — a
half-finished refactor, a vendored file, an unstaged config tweak — made every
Stop report "N file(s) changed - all require QA review" for changes the
session never made.

```
# gate-baseline v1
head=<sha|none>
captured_at=<ISO-8601 UTC>
captured_by=session-start|qa-gate-enter|qa-gate-approve
--
<LC_ALL=C-sorted `git status --porcelain` lines>
```

`LC_ALL=C` is load-bearing on both ends: the reader uses `comm -23`, which
requires both inputs in the same collation.

Three writers, each with a different rule:

| Writer | Rule | Why |
| --- | --- | --- |
| `session-start.sh` | full snapshot, **only when no review cycle is active** | an in-flight cycle's work is dirty right now; baselining it would release it unreviewed. Since 94d.1 the SAME predicate also decides whether `changed-files.txt` is reset, from one hoisted read — two independent reads could preserve the tracker and then baseline the work it names |
| `qa-gate.sh enter` | **write-if-missing**, minus paths already in `changed-files.txt` | a cycle opened mid-session must not baseline the edits that session already made |
| `qa-gate.sh approve` | full refresh | approve means "everything dirty right now has been reviewed" |

`qa-gate.sh baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]`
is the entry point session-start calls; it takes no task id and touches no
labels.

There is deliberately **no hash-side subtraction**, and 94d did not add one — it
moved *where* the subtraction happens. `changed-files.txt` now has two writers:
`post-edit.sh` (actual tool edits, unfiltered by the baseline, so an edit to an
already-dirty file must still gate) and `qa-gate.sh reconcile-tracker` (the
git-visible remainder, which subtracts the baseline before appending).
Pre-existing dirt still cannot enter the tracker from either writer, which is
the property the no-subtraction rule rests on.

Both the writer and the Stop hook's git walk ask `git rev-parse --git-dir`
rather than testing `-d "$PROJECT_DIR/.git"`. In a linked worktree `.git` is a
FILE, so the old test answered "not a git repo" and silently switched off both
the snapshot and the walk — with an empty `changed-files.txt` the gate then
had no detector at all and failed OPEN.

### The tracker reconcile (`reconcile-tracker`)

The baseline's other half, and most of the reason the change-set hash can be
trusted — bounded by one named residual under "Known limits, named rather than
latent" below, which is worth reading before treating this section as a coverage
guarantee.

**The defect (claude-workflow-plugin-94d).** `changed-files.txt` had exactly one
writer: `post-edit.sh`, on PostToolUse events carrying a path. A file written by
a Bash redirect, `cp`, `mv`, `sed -i`, or a generator script never entered it.
That was never merely a readout problem, because four different consumers read
that one file:

| Consumer | What it derives from the tracker |
| --- | --- |
| `verify-before-stop.sh` | `CHANGE_COUNT` and the block reason's `Files changed:` list |
| `verify-before-stop.sh` | `compute_intent_payload`'s `changed_files[]` (J18 routing) |
| `impact-report.sh` | the canonical change set the impact analysis covers |
| `impact-report.sh` | **`change_set_hash`** — the value an approval record binds |

So an under-covering tracker let the gate name N paths and **release on an
approval binding M < N**. Measured live four times over two days; at one point
the tracker held **37 of 71** changed files. The empty-set case is the extreme
of the same bug: a tracker wiped mid-cycle hashes to `e3b0c442…` (pinned as a
constant by `impact-report.test.sh` section 6) and a cycle bound a hollow
approval over zero files while looking perfectly valid.

**The repair.** `qa-gate.sh reconcile-tracker` takes `git status --porcelain`,
subtracts the gate baseline (`comm -23`, `LC_ALL=C` on both sides), subtracts
the shared denylist, subtracts what the tracker already holds, and appends the
remainder as **absolute** paths under the same `flock` `post-edit.sh` uses.
It only ever grows the reviewed set.

That baseline subtraction compares raw porcelain **lines**, not content, which is
where the line-granularity limit below comes from: a path the baseline already
lists cannot come back, however much it changes afterwards. So this repair is
complete for paths that were **clean when the baseline was captured**, and
partial for the rest.

**It is not a recovery path, and that is structural (94d.1).** If
`changed-files.txt` is *lost*, what this rebuilds is necessarily a **subset** of
what was lost — no refinement of the baseline, the `comm`, or the filters changes
that. The loss that produced 94d.1 went through two channels, and only the first
is even addressable here:

| Channel | What went | Visible to `git status`? |
| --- | --- | --- |
| A | 14 paths whose porcelain line was byte-identical to a baseline entry, so `comm -23` subtracted them | yes — reportable, and now reported |
| B | 2 paths that existed **only** in the tracker: `.claude/review-config`, whose content had been reverted so it was not dirty, and a `.claude/.qa-tracking/review-artifact-*.json`, which the self-written rule keeps out of the change set by design | **no** |

Channel B is why prevention lives at the deleter and not here, and why this
function's job is to *announce* that it reconstructed rather than to imply that
it restored. A rebuild from an absent-or-empty tracker says so in its
observations, names the assumption it made ("no tool edit had happened yet" — it
cannot tell that from "the tracker was destroyed"), and writes a
`sync-errors.log` line when a cycle was in flight at the time.

Called at three points, all of them *before* anything reads the tracker:

| Caller | When | On failure |
| --- | --- | --- |
| `qa-gate.sh enter` | before `generate_impact_report`, on both the fresh and re-enter arms | tolerant (`enter` is documented tolerant); warns in `observations` |
| `qa-gate.sh approve` | immediately before the impact-report refusal | **REFUSES**, exit 2, `error_key: tracker_unreconcilable` — no bypass flag |
| `verify-before-stop.sh` | top of the detection stage | **BLOCKS** (after the `stop_hook_active` circuit breaker) |

`approve` has no bypass for this and `--no-impact-report` does not cover it:
that flag waives an *analysis* whose degradation is documented, whereas an
unreconcilable tracker means the change set itself is unknown, so every
credential the approval writes would be a claim about an unknown quantity.

**`approve` also refuses a change set that was *reconstructed and is provably
short*** — `error_key: change_set_reconstructed`, exit 2, immediately after the
reconcile and *before* the impact-report refusal. Three conditions, none of them
read from the tracker's own contents:

1. the tracker was **absent-or-empty** when the reconcile ran, so every path in
   the set being bound came from `git status` rather than from a recorded edit;
2. the rebuild produced a **non-empty** set, so this approve is certifying actual
   work;
3. it **also dropped** git-visible reviewable paths as already-baselined — so
   what is being certified is a proven *subset* of the working tree.

The live 94d.1 occurrence sits exactly there (`added=10`, `subtracted=16`).
Condition 2 is measured, not decorative: without it the refusal also fires on
`added=0, subtracted>0`, which is an **empty** change set with baselined dirt
around it — a task closed with no code change, a doc-only fast path, or a session
that did nothing in a checkout that was dirty on arrival. That state broke the L1
`qa-gate-choose` and `qa-gate-grade-record` fixtures before condition 2 existed
(their single "subtracted" entry is the fixture's own untracked
`.claude/scripts/` directory), and the gate treats an empty change set as
"nothing to review" everywhere else.

**What condition 2 leaves open, deliberately.** A session whose work was
*entirely* Bash-written to paths that were *all* already dirty at baseline
capture reads as `added=0` and is not refused, even though its change set is
hollow. That is `fkm.1.2`'s original empty-binding concern, and this predicate
cannot separate it from the legitimate empty cases above — the observations are
identical. It is **reported** either way (`subtracted=N`, the paths, and the
rebuild announcement); escalating to a refusal there would block every no-op
approve in a dirty checkout.

This is `claude-workflow-plugin-fkm.1.2` half (b), generalised. Its original form
— "refuse when the change set is EMPTY while git shows un-baselined dirt" — is
**unreachable** post-94d: the reconcile folds un-baselined dirt in, so `approve`
can never observe that pair. The failure changed shape rather than going away:
the same trigger now yields a non-empty, plausible, 10-of-26-path set. There is
no zero left to trip on, hence "materially short" rather than "empty".

Why not simply compare two counts? Because both counts a truncated tracker can
offer are derived from the truncated tracker — which is exactly how the
impact-report freshness check missed this: `recorded_hash == current_hash` holds
when *both* describe the shrunken set, so that check detects **drift** and is
blind to **loss**.

Unlike `tracker_unreconcilable`, this one **has** a bypass —
`--accept-reconstructed '<reason>'`, recorded in the approval comment as
`[reconstructed change set accepted: …]` and in the gate JSON. The difference is
what each predicate can prove: "git status failed" is mechanical and no human
judgement can supply the answer, whereas "the tracker was empty and N paths were
subtracted" is *inferential* — a destroyed tracker and an all-Bash session in a
repo that was dirty on arrival look identical to the reconcile, and a human
reading the named paths can tell them apart. Refusing with no exit would deadlock
the second case with nothing to fix. Pinned by `gate-baseline-v2.sh` 7S.3 (the
refusal), 7S.4 (the control: a non-empty tracker with the same subtraction does
*not* refuse), 7S.5 (the bypass, and that an unexplained one is rejected) and
7SM (strip the accounting: the refusal goes inert and the drop goes silent).

Details worth knowing:

- **Absolute paths, deliberately.** `post-edit.sh` records
  `tool_input.file_path` verbatim and the runtime passes absolute paths, so a
  repo-relative spelling here would double-count into the hash (`sort -u`
  collapses duplicates, not two spellings of one file). The prefix is
  `$PROJECT_DIR` when it *is* the working-tree root, and git's
  `--show-toplevel` when `$PROJECT_DIR` sits below it (porcelain paths are
  root-relative). The two are compared through `pwd -P`, because git returns
  symlink-resolved paths while `CLAUDE_PROJECT_DIR` may not —
  `/var/folders/…` vs `/private/var/folders/…` on macOS is exactly how a
  mixed-spelling double count would arrive.
- **`??` untracked and `D` deletions both count.** Git collapses an untracked
  directory into one `?? dir/` entry, so a surviving collapsed entry is
  expanded with `status --porcelain -uall` run from the working-tree root.
  Without that, a file added later *inside* an already-listed directory would
  not move the hash.
- **The gate's own state is excluded**, and not for tidiness. `install.sh`
  writes the `.qa-tracking/` gitignore rule only when the target has no
  `.gitignore` at all, so in many real installs the gate's own state is
  git-visible. Reconciling it would make the change-set hash a function of the
  gate's own progress and deadlock every cycle by construction: `enter`
  reconciles and *then* writes `impact-report-<tid>.json`; `approve` reconciles,
  sees that file as new, appends it, and the report it just checked for freshness
  is now stale against a hash the check itself moved.

  Which paths those are is **not** a local decision here — it is the shared
  `workflow_self_written` rule, described under
  ["The second rule"](#the-second-rule-workflow_self_written) above:
  `.claude/.qa-tracking/**` and `.beads/interactions.jsonl`, and nothing else.
  In particular **`.beads/issues.jsonl` is *not* excluded** — it is the committed
  ledger, a real deliverable, and bd 1.1.2 rewrites it only on an explicit export,
  so it reconciles in like any other changed file. (An earlier draft of this
  bullet said `.beads/*.jsonl` was not excluded, full stop. That was wrong for
  `interactions.jsonl`, and wrong in the same change set that introduced the rule
  — QA finding R1-F2.)
- **Non-git tree: no-op.** There is no delta to reconcile against.
- **Known limits, named rather than latent.** Three, and the first one bounds
  every coverage claim this section makes:

  1. **The baseline is subtracted at LINE granularity, so a re-write of an
     already-baselined path is invisible.** `comm -23` compares raw porcelain
     lines, which are not content-addressed. If a path was dirty when the
     baseline was captured, a further write of any size leaves ` M path`
     byte-identical and is subtracted as pre-existing dirt: it reaches neither
     the tracker, nor the change-set hash, nor the block reason, nor the
     reviewer, and `reconcile-tracker` still returns success. **No commit is
     required**; a second write in the same session is enough, which makes this
     strictly wider than limit 3 below (and wider than
     `claude-workflow-plugin-dpe`, which frames the hole as needing an
     intervening commit). The collapsed `?? dir/` case is the same mechanism —
     a file created inside an already-baselined untracked directory does not
     surface — and the Stop hook's git walk shares the blind spot, because it
     subtracts the same file the same way.

     **It is no longer SILENT, which is a different claim from "it is fixed"
     (94d.1).** This paragraph used to end "nothing in the readout says a path
     was dropped", and that was true and was the expensive part. Every
     observation now carries `subtracted=N` beside `denylisted=N`, names the
     dropped paths (inline up to 12, in full in
     `.claude/.qa-tracking/reconcile-subtracted.txt`), and says which question
     the reconcile cannot answer about them — it cannot tell pre-existing
     arrival dirt from session work whose tracker entry was lost. `added=0` can
     no longer stand alone as the whole story. The hole itself is unchanged.

     **The magnitude, and the trigger that actually produces it.** This limit
     was written for an *incremental* second write to one path. Measured, the
     shape that matters is a **session boundary**: SessionStart deleted
     `changed-files.txt` unconditionally (including on `compact`), and the next
     reconcile re-derived the *whole* change set through this subtraction at
     once. On 94d's own review that cost **16 of 26 paths (62%)** in a single
     step — 54% by QA's independent count of the same tree (60 git-visible, 29
     baseline-identical, 21 denylisted, 10 recovered) — and the readout was
     `+10 git-visible path(s) … (added=10)`, indistinguishable from a healthy
     call. It scales with **baseline age**, not with write count: every path
     that has been dirty since the last capture is a line the subtraction
     matches, and that baseline was ~35 hours old, written by an earlier cycle's
     approve. The deletion half is fixed at the deleter (see "The tracker
     survives a session boundary"); what remains is this limit, now bounded by
     baseline age and reported rather than silent.

     **What that means for the writes this reconcile exists to catch** (a Bash
     redirect, `cp`, `mv`, `sed -i`, a generator script — everything no
     PostToolUse event covers): it folds in the ones whose path was **clean at
     baseline capture**, or whose porcelain status code has changed since, and
     only those. It is not a general answer to "did every byte of `git diff`
     reach QA". Tool edits are unaffected — `post-edit.sh` records those
     unconditionally, without consulting the baseline, which is why an Edit to
     an already-dirty file still gates.

     Both directions are pinned rather than described:
     `gate-baseline-v2.sh` 7.6 (the baselined path stays out, hash unmoved, no
     commit involved), 7.7 (a path clean at capture is folded in by the same
     call), and 7R, which forces the subtraction branch alone and flips 7.6.
     Tracked as `claude-workflow-plugin-dpe` and **not** fixed here:
     content-addressing the baseline is a change-set-hash migration of its own,
     and the cheaper candidate — invalidating baseline entries against the
     recorded `head` — closes only the committed variant while leaving this one
     open and looking closed.
  2. **A path git *quotes*** (`"src/na\303\257ve.ts"`, control characters) is
     appended in its quoted spelling, because the baseline is written with the
     same quoting and `comm -23` needs identical bytes. The result over-reports
     a literal path that does not exist, which is fail-closed, and it is logged.
  3. **Work already committed is invisible to `git status`**, so a tracker
     destroyed after a commit cannot be recovered here.

`reconcile_tracker`'s regions in both scripts are wrapped in
`# TRACKER-RECONCILE BEGIN/END (94d)` sentinels; section 7M of
`gate-baseline-v2.sh` strips every region from fixture copies of both files and
asserts the Bash-written file disappears from the tracker and from the block
reason's absolute-spelled list, with a restore-control leg. Do not rename them.

**This landing is a hash migration.** Any session with git-visible dirt beyond
what its tracker already held hashes differently afterwards, so in-flight
approvals stop matching and the gate emits `LABEL_WITHOUT_RECORD` with the
recovery it already prints. Same fail-closed direction and same one-landing rule
as a denylist edit — see "Denylist changes are a hash migration".

---

## Stop Hook

**File**: `.claude/scripts/verify-before-stop.sh`

**Purpose**: **ENFORCE QA GATE** - Block completion until QA approves.

### What It Does

```bash
# 1. Skip for user interrupt
if [[ "$STOP_REASON" == "user_interrupt" ]]; then
    echo "{}"; exit 0
fi

# 1b. Fail closed if the shared denylist lib is unreachable — without it,
#     "which paths are reviewable" is unknowable. Emitted AFTER the
#     stop_hook_active circuit breaker above, never before it (a block
#     ahead of that guard re-enters the Stop hook forever).
if [ -z "$WORKFLOW_DENYLIST_REGEX" ]; then emit_block "..."; fi

# 1c. Reconcile the tracker against git BEFORE anything reads it (94d), so the
#     block reason, the J18 payload, the impact analysis and the change-set
#     hash all describe the same change set. BLOCKS when it cannot run — see
#     "The tracker reconcile".
qa-gate.sh reconcile-tracker || emit_block "..."

# 2. Check for tracked changes. `reviewable_changes` is the ONE definition of
#    "what counts as a change right now": the denylist-filtered tracker UNION
#    2b's git walk — both halves, always. It used to short-circuit on the
#    tracker, which made the detector a strict subset of git whenever even one
#    tool edit had been recorded (94d). Step 6a re-reads it.
while IFS= read -r f; do CODE_CHANGES_DETECTED=true; done < <(reviewable_changes)

# 2b. The git half (inside reviewable_changes): git status MINUS the gate
#     baseline, so only entries NEW since the baseline count, and MINUS
#     anything the tracker half already emitted (in either spelling — the
#     tracker is absolute, porcelain is relative, and an unfiltered union
#     would report both spellings of every file). Requires
#     `git rev-parse --git-dir`, not `-d .git` (linked worktrees). See "The gate
#     baseline".
#     comm -23 <(git status --porcelain | LC_ALL=C sort) \
#              <(gate_baseline_entries | LC_ALL=C sort)

# 3. If no changes, allow
if [ "$CODE_CHANGES_DETECTED" = false ]; then
    echo "{}"; exit 0
fi

# 4. Run technical checks (tests, lint)
if ! npm test; then
    FAILED_CHECKS+="Tests failing\n"
fi

# 5. If checks fail, block
if [ -n "$FAILED_CHECKS" ]; then
    echo '{"decision": "block", "reason": "..."}'
    exit 0
fi

# 6. Check for QA approval — SINGLE source of truth: the qa-approved label,
#    read through qa-gate.sh status (see the `GATE_STATUS=` reads in
#    verify-before-stop.sh).
QA_APPROVED=false
GATE_STATUS=$("$QA_GATE" status "$TASK" | jq -r '.status')
if [ "$GATE_STATUS" = "approved" ]; then
    QA_APPROVED=true
fi
# There is NO comment-text fallback and NO marker file. Both were deleted
# (the B1/D1/J2 and B13 lines in verify-before-stop.sh's header); a comment
# that merely says "QA APPROVED"
# does NOT release the gate, and `.qa-tracking/approved` is never read.

# 6a. Label present but no record matches? Re-read reviewable_changes from
#     FRESH state first: if there is nothing left to review, an `approve` landed
#     while this hook was running and the block would be transient noise.
#     See "The vanished-change-set release" below.

# 6b. Still blocking? Try to bind the approval to another WORKTREE of the same
#     repo (read-only, bounded, fail-closed). See "Cross-worktree approval
#     resolution" below.

# 7. If not approved, BLOCK
if [ "$QA_APPROVED" = false ]; then
    echo '{"decision": "block", "reason": "QA approval required..."}'
    exit 0
fi

# 8. If approved, allow and clean up. The legacy `approved` marker is rm'd
#    defensively (to clean stale files from old installs) but is never an
#    approval source (the `Clean up tracking` block at the end of the approved
#    path).
rm -f "$QA_TRACKING_DIR/approved"
rm -f "$QA_TRACKING_DIR/changed-files.txt"
echo "{}"
```

Note that `qa-gate.sh approve` itself refuses (exit 2) unless a
hash-current per-file impact report exists at
`.qa-tracking/impact-report-<task>.json`, so setting the label is gated on
the regression-impact artifact as well (see the QA agent's 3a step and
`docs/MCP_SERVERS.md`).

### Block Message

When QA hasn't approved, shows:

```
QA approval required.

15 file(s) changed - all require QA review.

Files changed:
src/auth/login.ts
src/components/LoginForm.tsx
... and 13 more files

Required: delegate to @qa now.

Cannot complete without QA approval.
```

### Approval Detection

**One source of truth: the `qa-approved` Beads label**, read via
`qa-gate.sh status` (the `GATE_STATUS=` reads in `verify-before-stop.sh`). The
label is set
atomically by `qa-gate.sh approve` (which also drops `qa-pending` /
`qa-gate-entered` and writes an audit comment). There is no comment-text
fallback and no marker-file fallback — both were deleted (the `B1/D1/J2` and
`B13` lines in `verify-before-stop.sh`'s header):

- A comment whose body contains the literal text "QA APPROVED" does **not**
  release the gate. The earlier comment-text method (B13) was removed so the
  gate has a single deterministic signal.
- The legacy `.claude/.qa-tracking/approved` marker is **never read**. The
  Stop hook `rm`s it defensively (the `Clean up tracking` block at the end of
  the approved path) only to clear stale files left by pre-v3 installs.

The gate also auto-approves without QA when there is nothing reviewable to
review — the **F1 fast path** (`verify-before-stop.sh`, the block guarded by
`FASTPATH_CLASS`), which fires when every changed path is doc-only, is
Beads/gate bookkeeping (`.beads/*.jsonl`, `beads.db`, `.qa-tracking/*`), or the
change-set is empty after the build-artifact denylist. A mixed diff
(bookkeeping **plus** one real source file) is not fast-path eligible and still
requires the label.

**Neither a file's position nor a name glob confers documentation status**
(`claude-workflow-plugin-bbh`). `is_doc_only_path` carried two arms that decided
content type from path SHAPE, and each was a release-authorising bypass needing
no privilege beyond where a file sat or what it was called:

| arm | reach | measured |
| --- | --- | --- |
| `*/docs/*\|docs/*` | any path under any `docs/` directory, any depth, any tree | `docs/deploy.sh`, `docs/scripts/migrate.py`, `docs/Dockerfile`, `docs/.github/workflows/ci.yml`, `src/docs/handler.ts` all classified as documentation |
| `LICENSE.*` | any extension after that one name, **root only** (no `*/` prefix) | `LICENSE.sh` and `LICENSE.py` were documentation while `src/LICENSE.sh` was not |

Both are **removed**, not narrowed. Requiring a documentation extension *inside*
the `docs/` arm — the obvious narrowing — is an exclusion list, i.e. a new place
for the next extension to be missing, and it is also inert: `docs/guide.md`
already matches `*.md`, so the arm's entire marginal contribution was the files
that match nothing else. Measured over a 1120-path cross product, removing both
arms moves **438 paths** from doc-only to reviewable and **0** the other way.

Two further properties, both pinned by
`.claude/scripts/tests/doc-only-classifier.test.sh`:

- **An affirmative content veto.** The surviving arms still read a type off a
  name, so a matching name is necessary and no longer sufficient: a file whose
  **executable bit is set**, or whose **first two bytes are `#!`**, is never
  doc-only whatever it is called. That reasons about the file rather than its
  spelling, and it is what covers the extension-less `LICENSE` / `CHANGELOG` /
  `NOTICE` / `AUTHORS` arms. Each veto writes a `sync-errors.log` line naming the
  path and the evidence, because an unexplained block is a dead end.
- **Positive evidence only.** A path that does not resolve to a regular file —
  a deletion, a rename's old side, a tracker entry spelled from another
  worktree — is no evidence either way, and the name arms decide as before. The
  stricter reading (unresolvable ⇒ reviewable) would deadlock every
  documentation *deletion* while buying nothing: a deleted file ships no
  content. So the veto can only narrow the name arms, never widen them.

**What it costs.** A `docs/` tree carrying non-prose files stops fast-pathing:
`docs/img/diagram.png`, `docs/fixtures/payload.json`, an extension-less
`docs/Makefile` or `docs/README` now need a QA round when they change alone.
That is the correct direction — F1's whole licence is that there is nothing to
review — and `docs/README` is now merely consistent with the repo-root `README`,
which never had an arm.

**A document the project declares as its own surface is not documentation about
the system — it IS the system** (`claude-workflow-plugin-s5qf`). `bbh` closed
the shape half and disclosed the half it could not: an agent prompt, a rubric,
`CLAUDE.md` and the lessons ledger are markdown carrying neither an exec bit nor
a `#!`, so the content veto correctly has no opinion about them and the `*.md`
arm called them documentation. They are executable policy in prose — the runtime
loads `.claude/agents/*.md` as the agent, the grader reads `.claude/rubrics/*.md`
as its criteria and `LESSONS.md` as criteria by reference. The live illustration
is on `bbh`'s own change set: `.claude/agents/qa.md` was a member of it, and had
that edit landed alone F1 would have released an unreviewed change to the QA
agent's own prompt.

The fix adds **no third path arm** — that would be `bbh`'s inference wearing a
new suffix. It asks a question with a factual answer instead: *is this path one
the project declares it ships?* The answer already exists, in
`workflow-manifest.sh` — the enumeration `install.sh` copies from and every
frozen table under `manifests/` is cut from. A new `governing <source-root>`
subcommand re-serves it without hashes as `<path><TAB><origin>`, plus the named
runtime-contract files the plugin does not ship but whose content governs it
(`CLAUDE.md`, which Claude Code auto-loads into every agent's context).
`is_doc_only_path` looks the path up by exact equality and vetoes on a hit,
logging the path and the origin.

| property | behaviour |
| --- | --- |
| covered today | `.claude/agents/*.md`, `.claude/rubrics/*.md`, `.claude/commands/*.md`, `.claude/skills/**`, `.claude/vendor/**`, `LESSONS.md`, `docs/HOOKS.md`, `docs/CODEX_SETUP.md`, `CLAUDE.md` |
| generalises | a NEW declared artifact is covered with no list edited anywhere — create `.claude/agents/designer.md` and it is disqualified on the next Stop |
| anti-overreach | an ordinary doc is untouched, *including in the same directory*: `.claude/agents/notes.txt` still fast-paths, because the manifest scans that directory for `*.md` and does not declare it |
| fails OPEN | if the query cannot run (manifest script absent, or it failed) the set is empty, nothing is vetoed, and F1 behaves exactly as before — logged once to `sync-errors.log`, never silent |
| never an install row | `CLAUDE.md` reaches the governing set only through `governing`; `generate` still omits it, so no upgrade verdict and no uninstall walk sees it |
| cost | maxdepth-1 scans plus three pruned walks over `.claude/`, no digests, at most once per Stop: **0.032s / 134 rows** on this repo at `b8f0095`, versus 0.339s for the hashed `generate` |

**Availability, measured rather than assumed** — over this repo's whole history
at `b8f0095`, 142 non-merge commits, classifier extracted from the shipped hook
and driven per path, manifest regenerated from each commit's own tree via `git
archive`: **7** commits were doc-only (F1-eligible) and **1** of those also
touched a governing artifact (`ea6ae385`, `docs/HOOKS.md` alone). Counted from
churn instead: **60** commits touched a veto-reachable governing artifact and
**59** carried a reviewable path anyway, so F1 was never available to them. These
files change constantly here (`LESSONS.md` 37, `docs/HOOKS.md` 23,
`.claude/agents/qa.md` 22) and essentially never alone.

**What still cannot be seen.** For anything not affirmatively executable and not
declared, the classifier still reads content type off the NAME: a `.txt` that is
a golden test assertion, a bare `LICENSE` that is really a data file, and any
behaviour-bearing document an install target keeps where the manifest does not
look. One specific residual:

- a **deletion** of a declared path, which resolves to no file and so is not in
  the enumeration. The same asymmetry, and the same defence, as the content
  veto's deletion contract above; a *correct* deletion of a plugin-owned
  artifact also moves `.claude-plugin/plugin.json` or a frozen table, neither of
  which is doc-named. **This one is now MEASURED rather than described** —
  `doc-only-classifier.test.sh` section 6h.3 drives the deletion of an agent
  prompt, a rubric, `CLAUDE.md` and a design artifact and pins the current
  DOC-ONLY verdict, with a surviving declared sibling as the discriminator, so
  closing it is a loud test change rather than a silent drift. Tracked as
  `claude-workflow-plugin-e4ox`, which also carries the costed design (the
  declaration's *rules* rather than its results) and the reason it was filed
  instead of half-built.

**The design artifact was the other residual, and v5 D1
(`claude-workflow-plugin-fkm.3`) closed it.** `docs/specs/*.md` is now declared
in `runtime_contract_rows` beside `CLAUDE.md`, with origin `design-artifact`, so
a change set consisting of exactly the design document no longer auto-approves
with `reviewed_by=none`. It is the same mechanism as `CLAUDE.md` — a fact the
project states about its own layout, inside the function `generate_rows` never
calls, so still no install row, no upgrade verdict and no uninstall walk — with
one difference stated plainly: `CLAUDE.md` is a named file and this is a
**declared directory**, because the artifact is named for the task it designs
and the set is only knowable at scan time. It remains a declaration rather than
the path inference `bbh` removed: the row exists because the workflow writes its
design artifact there, not because the name ends in `.md` or sits under `docs/`.
An operator's own `docs/architecture.md`, and every other file in `docs/`, are
untouched. Availability cost: one QA round per design revision, which is the
review the design phase mandates anyway.

**The declared directory is scanned for ENTRIES, not for regular files** (QA
round 2 on that task, finding R2-F2). `scan_flat`, which builds the shipped
surface, uses `find -maxdepth 1 -type f` — and that **excludes symlinks**, so a
`docs/specs/<task-id>.md` pointing anywhere emitted no governing row at all and
the fast path reopened for the design artifact itself. The declaration therefore
has its own scanner, `scan_declared_dir`, which enumerates entries and declares a
symlink — dangling ones included, on the same "an absent target is not evidence"
reasoning the deletion residual above states. `scan_flat` is deliberately
unchanged: it builds the surface whose output is frozen per release under
`manifests/`, and `install.sh` copies files rather than links, so widening it
would move frozen rows for a case no install path produces. The boundary is
asserted from both sides — a symlink in the declared directory IS governing, a
symlink in `.claude/agents/` leaves `generate` byte-identical.

**The declared directory itself is scanned even when it is a symlink, and a
directory it cannot READ is a failure rather than an empty answer** (QA round 4
on the same task, findings R4-F3 and R4-F2). `find` will not descend a final
directory-symlink operand without `-H`/`-L` — the same on BSD find and GNU
findutils — while the `[ -d ]` guard above it does follow, so a `docs/specs`
that is a symlink passed the guard and produced a silently empty scan. The
scanner passes `-H`, which follows command-line operands only, leaving entries
*inside* the directory reported as themselves. And the enumeration's exit status
is now read: it used to run inside a process substitution with `2>/dev/null`, so
a directory that is searchable but not listable (mode `0311`) returned zero rows
at rc 0 while the artifact stayed readable by name. `governing` now exits
non-zero and quotes find's own diagnostic. **Operationally that means one thing
worth knowing:** if the declared directory's permissions are broken, the whole
governing query fails, and `load_governing_set` logs
`F1: the governing-artifact query failed …` to `sync-errors.log` and classifies
as it did before the declaration existed. That is the documented fail-open on an
*unanswerable* query; what changed is that an unreadable directory is now
unanswerable instead of answering "nothing is declared".

**An exact-path match over un-normalised strings is not an exact match over
paths** (`claude-workflow-plugin-mdnc`). The declaration's membership test is
exact string equality — deliberately, because a pattern match would widen the
veto — but until this fix the *reduction* that produced the string chained its
attempts with `elif`, so the first attempt that produced **any** string won and
the rest were never tried. Producing a string is not finding the artifact, and a
bare `.` was enough to defeat the whole veto. Measured, with the canonical
spellings reading `reviewable` beside them and every anti-overreach control
holding:

| spelling | verdict before |
| --- | --- |
| `$ROOT/./docs/specs/T-1.md` | `DOC-ONLY` |
| `docs/./specs/T-1.md` | `DOC-ONLY` |
| `docs/specs/../specs/T-1.md` | `DOC-ONLY` |
| `.claude/agents/../agents/qa.md` | `DOC-ONLY` |

uniformly across **every** declared path — agent prompts, rubrics, `CLAUDE.md`
and the design artifact. Anything that records a path with a dot in it reached
the ungated exit, which made two shipped announcements false at once: `bbh`
announced path-shape inference was gone, and `s5qf` announced governing
artifacts are disqualified from the fast path.

The fix is **every reduction is a candidate and any hit wins**, with three of
the six candidates handed to the shell's own path machinery rather than to
string surgery. All three are different functions of the same input, and none
subsumes the others:

| # | reduction | what only it can answer |
| --- | --- | --- |
| 4 | `cd -P` on the parent — **kernel-physical** | a symlinked directory mid-path *inside* the tree (`docs/speclink/T-1.md`) |
| 5 | `cd` on the parent — **logical** | an artifact under a declared directory that is itself a symlink *out* of the tree; resolve that physically and the answer leaves the root |
| 6 | `cd` then `cd -P .` — **physical resolution of the logical collapse** | a path reaching the tree through an alias with a `..` after a symlink, and a `CLAUDE_PROJECT_DIR` containing `..` |

The leaf name is never resolved: a declared artifact may itself be a symlink and
is declared under its own name, which is also why a **hardlink** to a governing
artifact under an undeclared name still fast-paths. This veto asks what the
project declares about a path, never what inode sits behind it. Every `cd`
capture uses a sentinel byte (`printf '%sX'`, then `${…%X}`) because `$( )` eats
trailing newlines and cannot tell one that ends the output from one that is the
last byte of a directory name.

**Candidate 6 is `s5qf`'s own reduction, kept rather than replaced, and the
reason it is called out is that the first cut of this fix DELETED it.** `cd -P
"$d"` was substituted for `cd "$d" && pwd -P` at two sites — the parent
reduction and `_GOV_ROOT_PHYS` itself — on the reading that `-P` was a
*correction*. It is not; it is a second question, and the two answers diverge
exactly when a symlink precedes a `..`. The substitution therefore removed a
reduction, and the removal failed **open**: measured on macOS bash 3.2.57 and
ubuntu bash 5.2.21 aarch64, `$P/alias/.claude/x/../agents/qa.md` went back to
`DOC-ONLY`, and with `CLAUDE_PROJECT_DIR` spelled `$R/.claude/x/../..` the root
itself resolved outside the tree so **every** absolute governing path missed
every candidate. The rule the region now states: **never remove a reduction,
only add one.** The original defect was removal by short-circuit (`elif`); this
would have been removal by substitution.

Operationally: the fork-free candidates answer the common cases (a relative path
from `git status`, an absolute path from `post-edit.sh`), so the three `cd`
subshells run only on a path that already missed — i.e. on ordinary
documentation, of which a doc-only change set has a handful.

Both vetoes are pinned by
`.claude/scripts/tests/doc-only-classifier.test.sh` (sections 4-10, including a
strip-the-region META for each) and at the hook level by
`.claude/tests/component/specs/verify-before-stop.sh` legs 9-10; the query
itself by `.claude/scripts/tests/workflow-manifest.test.sh` section 1g. Section
6h drives the full spelling matrix — `./`, `../`, a leaf symlink, a directory
symlink mid-path, a hardlink, a root and leaves containing **spaces** and
**non-ASCII** characters — each paired with the identical spelling aimed at an
ordinary document, which must still fast-path. The space-and-unicode root is not
padding: a character-class filter proposed during this arc read correct and
would have refused every project living under `/My Drive`, and only measurement
caught it.

**Section 10 is the leg that catches a reduction being removed, and it exists
because sections 1-9 structurally could not.** Every one of them drives *one*
artifact — 6h runs the shipped bytes, 9 runs the shipped bytes against a
region-stripped copy of themselves — while monotonicity is a claim about the
DIFFERENCE between the old artifact and the new one. 109 green assertions were
compatible with the fail-open above. Section 10 therefore runs BOTH: a
sha256-pinned frozen copy of the pre-`mdnc` classifier
(`.claude/scripts/tests/fixtures/gov-classifier-baseline-s5qf.sh`, never
maintained, never refreshed) and — while the tree is dirty — the same extraction
from `git show HEAD:`, sweeping 1219 paths across 9 project roots and asserting
that **zero** of them lose the veto. Its negative control is the defect itself:
strip the `GOV-LPHYS` region and the differential must name the alias route and
the three artifacts under the `..`-bearing root.

**The fast path is bound to the change set it judged, and it no longer speaks
for a task an implementer is working on** (`claude-workflow-plugin-qzv`, the
`F1-CHANGE-SET-BINDING` and `EXPECTED-HASH-REFUSAL` regions). The defect: F1's
verdict is a statement about a CHANGE SET ("no reviewable source changed") while
its `qa-approved` label is a statement about a TASK, so any doc-only Stop that
landed while a task was open converted the first into the second. It fired four
times live, the last on the `v4.1.0` release task 22 seconds into its
implementer's spawn, binding a *previous* task's doc-only change set. Three
things changed:

- **A binding predicate.** F1 may auto-approve only when no `IMPLEMENTER:
  role=… task=… at <ts>` record on the active task is at-or-newer than the most
  recent `QA-GATE: entered at <ts>`. Both timestamps come from
  `review-check.sh gate`'s envelope — `cycle_opened_ts` and
  `latest_implementer_ts`, resolved before that subcommand's artifact gate so
  they are present on the `review_artifact_missing` envelope F1 always gets —
  so there is no second parser for either grammar. **No implementer record is
  SAFE, not unknown:** doc-only work is orchestrator-authored and never produces
  one, and requiring one would deadlock every documentation commit. A tie on the
  same whole second is refused, because whole-second stamps cannot order it.
- **The record the predicate reads is re-written per review CYCLE**
  (`claude-workflow-plugin-qzv.1`, the `IMPLEMENTER-CYCLE-KEY` region in
  `subagent-start.sh`). `record_implementer` was idempotent per `(role, task)` —
  its guard matched any comment on the task ever — so `latest_implementer_ts` was
  that role's **first** spawn permanently, and from the second cycle onward the
  predicate compared a stale record against a fresh cycle open, read "previous
  cycle", and auto-approved mid-implementation: the same defect, one cycle later.
  QA reproduced it end to end (cycle 1 entered 18:31:36Z / spawned 18:31:38Z
  blocked; a fresh enter at 18:32:06Z plus a re-spawn that posted nothing
  released, stamping `qa-approved reviewed_by=none`). The key is now
  `(role, task, cycle)`: a record is skipped only when that role already has one
  at-or-newer than the newest `QA-GATE: entered` — which reuses the two facts the
  predicate already compares, so it adds no state and no third parser. The
  **grammar is unchanged**, so every reader (`max_record_ts`'s end-of-line
  anchor, the `^IMPLEMENTER: role=([a-z]+) ` set capture, `is_implementer_role`)
  is untouched; only how often a record is written changed. The anti-spam intent
  survives — re-spawns inside one cycle still post nothing — and a task that has
  never opened a cycle keeps the old per-`(role, task)` behaviour, because in
  that state the predicate already refuses on the record's mere existence.
- **The `qa` role is out of scope for the predicate, deliberately.**
  `is_implementer_role` is `backend|frontend|devops` only, so a QA agent — which
  holds `Write`/`Edit`/`MultiEdit` — writes no `IMPLEMENTER` record and the
  in-flight check has nothing of QA's to see. Recording it was considered and is
  worse twice over: the record would outlive its cycle for every task QA has ever
  reviewed, so F1 would refuse on any task with QA history (deadlocking the
  documentation commits it exists for), and `qa` would enter the implementer
  **set** `approve`'s review-separation reads, where it can only refuse an
  approval that should stand. **What the exemption leaves open is `DOC_ONLY`,
  and the only accurate statement of which paths those are is
  `is_doc_only_path` itself** — read it at the top of `verify-before-stop.sh`,
  or generate the answer:
  `.claude/scripts/tests/doc-only-classifier.test.sh` drives it over 1120 paths.
  This sentence used to enumerate the *complement* in English ("only a file
  placed elsewhere — a test at `tests/`, a hook at `.claude/scripts/` — makes
  `DOC_ONLY` false"); that enumeration shipped false in three consecutive
  rounds and was falsified by both of its own examples (`tests/spec.txt` and
  `.claude/scripts/hook.txt` are doc-only via the extension arm, at any
  location). Do not write a fourth one.
- **A refusal at `approve`, not a trust at `enter`.** F1 passes `--expect-hash
  <h>` naming the set it classified, captured *before* the `enter` that
  reconciles the tracker and regenerates the impact report. `approve` compares it
  against the hash it is about to bind and refuses (exit 2,
  `expected_hash_mismatch`) on a mismatch, naming **both** hashes. This is why
  the check lives at `approve` rather than `enter` — `enter` is documented
  tolerant, and F1 calls it on exactly the classes with no completion payload.
- **Unestablishable is a refusal, not a pass.** `review-check.sh` missing, an
  envelope without the two fields (a pre-qzv or partially-synced copy), a record
  whose timestamp is not single-line ISO-8601-UTC, `bd`/`jq` off the hook's PATH,
  or the label saying a cycle is open while no `QA-GATE: entered` record comes
  back (the bd-1.1.2 comment-inlining failure) all fall through to the
  QA-required block with the cause named in the reason. The exit code is
  deliberately **not** the discriminator: F1 fires on change sets with nothing to
  review, so `review-check.sh gate` exits 4 on the normal path here, and keying
  on rc would refuse every doc-only Stop.
- **A REFUSED approval blocks and keeps the change set**
  (`claude-workflow-plugin-qzv.3`). The arm used to run `approve … >/dev/null
  2>&1 || log_sync_error`, then fall straight through to the tracker cleanup and
  `echo "{}"`. Any non-zero `approve` was logged and ignored, so the gate
  released a change set, recorded **no** approval for it, and truncated the
  tracker that named it — reproduced with `impact-report.sh` removed (a
  partially-synced install): decision `ALLOW`, 0 `QA-GATE APPROVED` records,
  `changed-files.txt` **wiped**, one line in `sync-errors.log`. Now `approve`'s
  stdout+stderr are captured, a non-zero exit emits a block naming the
  `error_key` and the refusal's own `observations`, and the `rm -f` cleanup is
  scoped to a **successful** approval so the change set survives for the retry.
  Three refusals reach it in practice — `impact_report_*` (degraded install),
  `expected_hash_mismatch` (a path arrived after F1 classified; qzv's own guard,
  which until this landed also ended in a silent release) and exit 3 (a
  rolled-back label write). `change_set_reconstructed` and
  `tracker_unreconcilable` do not: the hook's own unconditional
  `reconcile-tracker` fail-closes first, so the in-arm `enter` is an idempotent
  reconcile. Nothing in `qa-gate.sh`'s `APPROVE-COMMIT ORDER` moved — approve's
  refusals all exit before that finalization.
- **`approve`'s `impact_report_unverifiable` refusal is now reachable at all**
  (same task, second defect). `qa-gate.sh` runs under `set -e` and
  `compute_change_set_hash` returns 1 when `impact-report.sh` is missing, so the
  bare assignment `current_hash=$(compute_change_set_hash)` aborted the script
  three lines above the refusal written for that exact condition. Measured
  two-arm: shipped/`set -e` gave rc=1 with **empty stdout and empty stderr**;
  the same call under `set +e` gave rc=2 with
  `error_key=impact_report_unverifiable`. The same slip sat on the second call
  site (`approved_hash`), which is the one the audited `--no-impact-report`
  bypass reaches — so the documented exit from a missing artifact was itself
  unusable when the artifact was missing. Both are now `|| var=""`, matching the
  three call sites in the file that always were.

**What that does NOT establish.** Binding a verdict to the change set it judged
proves *bound == classified*. It does **not** prove the set is COMPLETE: both
sides come from one canonicalisation of one tracker, so the comparison detects
drift and is structurally blind to loss (`claude-workflow-plugin-fkm.1.20`). An
independent witness for completeness — cross-checking against the F7 contract's
`files_changed` — is separate work and is not in this mechanism.

**The Stop hook no longer sets `status=closed`.** Both call sites are gone (the
F1 fast path's and the end-of-QA-approved-flow's), and the reasoning is recorded
at each. An approval binds a CHANGE SET; closing is a claim about the TASK's
work, and nothing in a change set can tell you whether a task's acceptance
criteria are met — so the close was structurally a guess, and it silently
overrode whatever the caller intended. `docs/WORKFLOW.md`'s status table has
always said `closed` is set by the agent after QA approval; that is now the only
writer. The release path emits the close command as a non-blocking
`additionalContext` note (`CLOSE_HINT_NOTE`) rather than dropping the affordance
silently. Nothing was lost mechanically: `bd-github-link.sh` recognises
`bd update <tid> --status closed` but is keyed on `tool_name == "Bash"`, and this
call ran inside the hook process, never as a Bash tool call; and
`epic-gate.sh check`'s verdict is computed *above* the removed line, so the
active task already counted as `in_progress` on its own Stop.

One more precondition on the label itself: `qa-gate.sh approve` refuses
(exit 2) unless a hash-current per-file impact report exists at
`.claude/.qa-tracking/impact-report-<task>.json`. So the only way to set
`qa-approved` (short of the audited `approve --no-impact-report '<reason>'`
override) is with the regression-impact artifact present and current.

**Review separation (v4 V3).** A second precondition: approve also refuses
(exit 4) unless the task carries an independent review. The predicate is the
one shipped counter, `review-check.sh gate <task-id>`, which reads the record
comments and answers three questions — is there a `REVIEW-ARTIFACT v1` record
at all, is its `reviewer_identity` different from every `IMPLEMENTER: role=...`
record on the task, and is every finding at or above the artifact's
`risk_threshold` either `RESOLVED` (with fix + test evidence) or
`ARBITRATION ... decision=overrule`. Since 2ty it also answers a fourth,
non-gating question for the Stop hook's escalation basis — how many
`REVIEW-ARTIFACT v1` firstlines carry `reviewed_hash=<h>` (`rounds` /
`rounds_hash`, optional `--change-set-hash <h>`); see "Escalation State
Machine". The implementer records are written by
`subagent-start.sh` at spawn time for the three implementing roles only
(backend / frontend / devops — `qa` reviews, so recording it would make every
single-agent review non-independent). The approval comment names the reviewer
and, since v4 pt2, **where** the review happened:

```
QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> worktree=<tok> at <ts>: <summary>
```

`worktree=<tok>` is the approving checkout's git toplevel with `%` → `%25`,
spaces → `%20` and tabs → `%09` so it stays one space-terminated token; off a
git checkout it records `none` rather than being omitted, so a reader can tell
"no worktree recorded" (a pre-v4-pt2 record) from "recorded but unresolvable".
Every token added since llh.18 goes *after* the `change_set_hash` token,
separated by a space — that ordering is the compatibility contract, and it is
why the v3.5 hash reader and the V3 `reviewed_by` reader still extract the same
values from both record shapes.

The Stop hook re-runs the same predicate before releasing (the
`REVIEW-DISCIPLINE` block in `verify-before-stop.sh`), because findings can be
recorded *after* an approval — a second review round, a re-opened issue — and
the approval record, written once, cannot know about them. Both sides fail
CLOSED: a missing or unrunnable `review-check.sh` refuses/blocks rather than
waving the change through.

### What a change-set-bound approval attests

**Membership plus review-at-review-time.** These paths were the change set, and
a reviewer looked at them then. **It does not attest content.**

`change_set_hash` is a sha256 over the sorted, denylist-filtered **path list**
(`impact-report.sh` `change_set_hash` / `canonical_changed_files`); the bytes in
those files are never hashed. Measured against the shipped script: a tracked
file rewritten from end to end produced a byte-identical hash. Three record
types inherit this today — `QA-GATE APPROVED`, `REVIEW-ARTIFACT reviewed_hash`,
and `RUBRIC` — because all three bind the same one definition. That is
deliberate: a second, content-aware canonicalisation invented at one of the
consumers is the duplicate-definition failure `llh.18` exists to forbid, so any
repair belongs at that single definition or nowhere.

What the binding still catches, all four blocking:

| Attack / accident | Why it is caught |
| --- | --- |
| a bare `bd label add <tid> qa-approved` | no record exists at all |
| approving a decoy task and redirecting `current-task` | the record binds the decoy's path set |
| a path entering or leaving the change set after approval | the path list, and so the hash, differs |
| a denylist edit, or a change to what reaches the tracker | the whole set re-hashes (see "Denylist changes are a hash migration") |

What it does not catch:

- **Hand-forged records.** An agent with arbitrary shell can reproduce the
  comment. Tamper-*evident*, not a cryptographic sandbox (`llh.18`).
- **Re-editing exactly the approved set.** `approve` truncates the tracker, so
  the live hash afterwards covers the paths touched *since*. Touch precisely the
  approved set again and the hash returns to the approved value, and that new
  content is not re-reviewed. Reachable in one step whenever the approved change
  set is a single file. Measured on the shipped `impact-report.sh --hash-only`;
  filed, and scheduled as a prerequisite of the v5 coherence claim, because
  coherence is a content assertion and a membership-only binding cannot support
  one.

The operator-facing statement of the same thing is the closing note of the
`LABEL_WITHOUT_RECORD` block reason in `verify-before-stop.sh`, and that note is
what `.claude/scripts/tests/gate-claim-honesty.test.sh` pins: it asserts the
text the shipped function EMITS against the *measured* behaviour of the shipped
hash rather than against a fixed string — so if the hash ever becomes
content-sensitive, the assertion flips with it instead of going quietly stale.
This section is prose and is **not** pinned: no test asserts anything about its
wording, so it is kept true by review.

### Approve idempotency is hash-aware

`qa-gate.sh approve` used to no-op whenever the `qa-approved` label was already
present. That made the LABEL mean "already approved" on the writer side while the
Stop hook had moved to a RECORD bound to the current change-set hash — and the
disagreement deadlocked recovery. A `LABEL_WITHOUT_RECORD` block prints
`enter -> impact-report -> approve`; `enter` does not clear `qa-approved`; so
`approve` short-circuited, wrote no fresh record, and the same block fired again
forever. The only escape was an undocumented `bd label remove <tid> qa-approved`
(claude-workflow-plugin-gz3).

Since v4.1 the guard compares hashes:

| State | Behaviour |
| --- | --- |
| label set **and** a `QA-GATE APPROVED` record binds the change set this approve would bind | success **no-op** (`observations` say `idempotent no-op`), no second record |
| label set, no record binds it (post-approval edit, denylist hash migration, forged/stale label) | **proceeds**: re-runs the impact-freshness refusal, the independent-review refusal and the rubric snapshot, then writes a FRESH bound record (`observations` say `stale-label re-bind`) |
| label set, change set moved, impact report NOT regenerated | still **refused** (exit 2, `impact_report_stale`) — the guard removes a dead end, it does not skip a check |

"The change set this approve would bind" is the live `--hash-only` recompute,
except when `changed-files.txt` is empty — the state a previous `approve` leaves
behind, since it truncates the tracker. There the persisted
`impact-report-<tid>.json` is the only surviving witness of the approved change
set, so that is what the comparison reads. This is why a plain double `approve`
is still a no-op rather than a staleness refusal, and it is the same
read-the-persisted-record rule the cross-worktree resolution follows. Both
envelopes name which of the two references they compared against, so the
comparison is never invisible.

**Known residual of the empty-tracker arm** (reproduced and pinned as section H
of the spec below): if the tracker is empty *and* real un-baselined dirt exists,
the Stop hook blocks on the git half of its predicate while the persisted report
still witnesses the *previous* approval, so a bare `approve` no-ops and the block
stands. Run the remediation the block prints, all three lines of it: step 2
(`impact-report.sh`) re-persists the report, after which no record binds it and
`approve` proceeds.

94d **narrowed** this without closing it. The trigger used to be routine — a
helper-written file never reached `changed-files.txt` at all — and now
`reconcile_tracker` puts it there, so `enter` and every Stop fire leave the
tracker non-empty. What remains is the case where `approve` is called with an
empty tracker and un-baselined dirt still present, because
`set_idempotency_reference` runs *before* approve's reconcile.

94d also **invalidated the reason recorded here for leaving it open**. That reason
was "closing this inside `approve` would mean a second copy of the Stop hook's
baseline-relative git walk" — true when the walk existed only inside
`reviewable_changes`, and no longer true now that `reconcile_tracker` is exactly
that walk in a callable, single-definition form. Moving approve's reconcile above
the idempotency check would close the residual; it would also change behaviour
that section H pins deliberately, so it is a decision for the approve-idempotency
work (`nnr`), not a side effect of the tracker fix.

The contract change is reflected in the `bd_qa_approve` MCP tool description and
pinned by `.claude/tests/component/specs/approve-idempotency.sh` (sections A-C
and H, plus a META that reverts the guard and shows the deadlock return).

**Interaction with the `change_set_reconstructed` refusal (94d.1).** That refusal
sits *after* this idempotency guard, so a genuine no-op — label set and a record
already binding the change set this approve would bind — short-circuits before it
and is never refused. The refusal can therefore only fire on a `approve` that is
actually about to write a record. That ordering is deliberate: re-refusing an
approval that already exists would break the printed
`enter → impact-report → approve` remediation for the second time, which is the
deadlock `gz3` closed.

### Rubric verdicts are bound to the change set they graded

`qa-gate.sh enter` used to clear `rubric-satisfied` unconditionally, on the
principle that a satisfied verdict from a previous change set must never carry
into a new review cycle. The principle is right; the implementation could not
tell "previous" from "this one, thirty seconds ago".

That mattered because of *where* `enter` gets called. `grade-record` runs in the
orchestrator's turn (RUBRIC-RELAY step C) and QA acts on the verdict in a later
spawn (step D). Any Stop in between blocks and **prints** `qa-gate.sh enter <id>`
— both the QA-required block ("when entering review, mark the gate") and the
`LABEL_WITHOUT_RECORD` remediation do. Following the gate's own printed
instruction destroyed the verdict recorded seconds earlier against the identical
diff, and the `approve` that followed warned *"no satisfied verdict on file"* —
false, and the thing `qa.md` 6f answers with a written OVERRIDE reason. The gate
was manufacturing overrides against its own audit trail and driving paid
re-grades of an already-graded change set (claude-workflow-plugin-bjx).

Since v4.1 `grade-record` writes the change set into the record, exactly as
`approve` binds `change_set_hash` and `review-record` binds `reviewed_hash`:

```
RUBRIC <version> iteration <n>: <verdict> change_set_hash=<h> — <summary>
```

The token sits between the verdict and the em-dash — ahead of all grader-authored
free text, so every existing reader that keys on the prefix through the verdict
still matches, and the machine field is never buried inside prose. It is recorded
on both verdicts: "which change set was found wanting" is as much an audit
question as "which one passed". It is omitted, not faked, when the hash cannot be
computed.

`enter` then decides rather than wipes. It keeps `rubric-satisfied` only when
**both** hold:

| Test | Why |
| --- | --- |
| the gate is already open (`qa-gate-entered` set) | a fresh `enter` opens a NEW cycle and always clears — unchanged behaviour, and the case the original clear existed for. `approve` deliberately leaves `rubric-satisfied` behind as audit trail, so a surviving label is the normal input here |
| the latest RUBRIC record is a `satisfied` one whose `change_set_hash` equals the hash right now | a verdict recorded before the specialist touched three more files does not cover them |

Preservation needs positive evidence, so every way of failing to produce it
degrades to the old behaviour: a pre-v4.1 record carries no token, a `satisfied`
superseded by a later `needs_revision` does not answer, a version outside the
validated class does not parse, and an unavailable hash — in either spelling,
see below — is refused. All of them clear. When the label is kept,
`rubric-pending` is deliberately *not* re-armed — a graded cycle is not awaiting
anything, and both labels at once would tell `qa-gate.sh status` the wrong thing.

Both outcomes are named in `enter`'s `observations` (`kept rubric-satisfied — the
recorded verdict binds this exact change set` / `cleared stale rubric-satisfied
(...)`), so the decision is never invisible.

**`rubric_version` is validated, and that is a security boundary, not tidiness.**
It is the only machine-prefix field that comes from the grader, and it is
interpolated into the record with a space on each side. Validated merely as
"non-empty string" it was a **grammar injection**: the reader parses the verdict
from immediately after the record's first colon, so a version of the form
`1 iteration 1: satisfied change_set_hash=<real>` relocated that colon into the
injected text and a `needs_revision` verdict was read back as `satisfied` **and**
bound to the current change set. `grade-record` now refuses any version outside
`^[A-Za-z0-9._+-]+$` with `error_key: rubric_version_invalid_chars`; the class
has no space and no colon, so nothing that passes can move a field boundary. The
reader carries the same class for parity. (A hand-written `bd comments add` can
still fabricate a record — that is the llh.18 threat-model boundary, unchanged.
What is closed is forging through the tool's own validated input.)

**Two spellings of "no hash", both refused.** `impact-report.sh` returns empty
when it cannot run, and the literal `sha256-unavailable` on a host carrying
neither `shasum` nor `sha256sum`. The second is a non-empty *constant*, so it
would be recorded as a binding and then compare equal to itself at `enter` time
— preserving every verdict on the one class of machine where the hash means
nothing. The writer omits the token for both, and `enter` refuses both.

**Known limit, inherited and deliberately not narrowed here.** The hash is over
the changed-file **list**, not file contents. Rewriting an already-tracked file
after grading does not move it, so a verdict can be preserved over content the
grader never saw. That is the single canonicalisation shared with the
`qa-approved` record (llh.18) and `reviewed_hash` (jio.1); computing a content
hash inside `cmd_enter` would be a fourth definition of "the change set", which
is what llh.18 exists to forbid. It is pinned as documented behaviour (section
B3) rather than left latent.

**Where the graded hash comes from.** `grade-record` runs *after* QA assembled
the packet and *after* the grader ran, so a live recompute at record time is not
"the change set that was graded" — a path landing in between was silently folded
in, and a verdict for set A was recorded as covering A+B (R2-F1; a **path** leak,
distinct from the content-only limit below). Three sources, in descending
authority:

1. `--graded-hash`, passed by the relay from the packet's `Graded change set:`
   header (`orchestrator.md` 5a step C). The only value that witnesses what the
   grader was shown. Deliberately not read from the grader's own JSON — that
   would let the graded party state what it graded.
2. A live recompute **corroborated** by the persisted impact report. If the
   report the packet was built from still describes the current change set,
   nothing was added in between. This keeps the ordinary relay binding without
   the flag.
3. Nothing. If they disagree, the record is written **unbound**, with both
   hashes named. `enter` then treats it as stale and clears — the pre-bjx
   behaviour, and the next relay round re-grades.

**`approve` cross-checks the verdict it cites.** The rubric audit line used to be
emitted from the *label*, so this purely sequential flow produced an approval
claiming a verdict it did not have: grade set A → `enter` (preserves, correctly)
→ add path B → regenerate the report → `approve` binds A+B and reports
"rubric-satisfied preserved (audit trail)" (R2-F2). `cmd_approve` now compares
`approved_hash` against the satisfied verdict's binding and reports one of three
states — verified, unbound-so-uncheckable, or **mismatch**. A mismatch warns and
is recorded in the durable approval comment as
`[rubric mismatch: graded=<h> approved=<h>]`; it does **not** refuse. That is
deliberate: `qa.md` 6f states that script-side rubric denial "would create a
parallel gate and violate principle 6", `verify-before-stop.sh` reads neither
rubric label nor RUBRIC comment, and the only remediations a refusal could print
are a paid re-grade or the label-removal dead end 3.5.0/gz3 eliminated. The harm
was the audit trail lying; that is what is fixed.

**Superseded verdicts.** The reader selects the **latest** RUBRIC record and then
parses it. It used to `capture` across every comment and take the last *result*,
so an unparseable latest record fell out and the reader answered with an older
one — a `satisfied` followed by a `needs_revision` at iteration `1.5` kept the
stale hash (R2-F3). `iteration` is now validated as a non-negative integer at the
writer too, but that half is defence-in-depth: it cannot reach a record the
writer never created (a legacy one, a hand-written comment), and that case
reproduced on the shipped script. The selector is the load-bearing half.

Pinned by `.claude/tests/component/specs/rubric-binding.sh` (sections A-L, plus
METAs that revert each half of the preservation fix, the version validation, and
the sentinel refusals, and a reader differential that attributes R2-F3 to the
selector rather than to the writer check).

### The vanished-change-set release (`VANISHED-CHANGE-SET`)

The Stop hook reads the change set **twice**: once at its detection stage, and
again — after the test/lint pass — when it recomputes the hash to match against
the approval record. `qa-gate.sh approve` runs in a different process (the QA
subagent) and finishes by truncating `changed-files.txt` and refreshing the gate
baseline. A Stop whose two reads straddle that finalization recomputes the
**empty-list** hash, matches no record, and prints the forged-label block for an
approval that landed seconds earlier. Observed live during the v4.1 upgrade wave
(recorded on `claude-workflow-plugin-gz3`) and since reproduced deterministically
at a drive point; the empty-set hash `e3b0c44298fc…` appearing as the *current*
hash in a block reason is the fingerprint.

So before emitting that block the hook re-derives `reviewable_changes` from fresh
state and releases when it is empty — the same decision the detection stage makes
on the next fire. It grants nothing new: "nothing to review -> allow" is already
the detection stage's rule, reached before any label is consulted. In particular
it does **not** release when the tracker is empty but real un-baselined dirt
exists, because the git half of `reviewable_changes` still reports it — and
since 94d that half runs on every call rather than only when the tracker is
empty, so the probe cannot be fooled by a tracker holding one stale entry
either.

Three ordering rules in `qa-gate.sh approve` support this (see its
`APPROVE-COMMIT ORDER` note; all three are pinned by
`specs/approve-idempotency.sh` section E — the two reorderings functionally at
their drive points, the source order structurally):

- the **record** is written before the `qa-approved` **label** (changed in v4.1),
  so a concurrent Stop never sees the label without a record;
- the gate **baseline** is refreshed before the **tracker** is truncated
  (unchanged since 0wk.2, but now load-bearing), so an empty tracker always pairs
  with a fresh baseline — flipping those two lines re-opens the race;
- and `current-task` is cleared **after** the truncation (changed in v4.1), so a
  mid-approve Stop cannot block with "No active Beads task detected".

The tracking-state finalization deliberately stays **after** every step that can
roll back: a rollback that had already truncated the tracker would leave the
session's work invisible to the gate, i.e. fail OPEN on the next "no changes"
fast path.

### Cross-worktree approval resolution (`WORKTREE-RESOLUTION`)

The change-set hash is **per-checkout** — it hashes that checkout's own
`changed-files.txt`. The tri-model workflow runs implementers and reviewers in
linked worktrees, so a review performed in `wt-<task>` records a hash the
primary checkout can never reproduce. Before v4 pt2 the primary's Stop then
reported "qa-approved label present but no change-set-bound approval record
matches" forever: the work *was* reviewed, the record *was* on the task, and
nothing done in the primary checkout could make the hashes agree.

**Verified topology.** A worktree-isolated specialist's tool-call hooks fire in
the PARENT session (`CLAUDE_PROJECT_DIR=<primary>`, so `post-edit.sh` records
absolute paths that point *into* the worktree), while gate commands run against
the worktree get `CLAUDE_PROJECT_DIR=<worktree>` and therefore keep their
tracking dir, their change-set hash, their impact report and their gate baseline
*there*. One Beads database is shared, so the approval record is visible from
both. The L2 spec
`.claude/tests/component/specs/worktree-approval-resolution.sh` drives this
against a **real** `git worktree add` (never a simulated one) and is the
empirical probe for it.

**The bridge.** Only on the already-blocking `LABEL_WITHOUT_RECORD` path, the
Stop hook tries to bind the approval to another worktree of the same repo. It
tries the recorded `worktree=` token first (O(1) in the common case), then
`git worktree list --porcelain`, skipping the current checkout and capped at 16
candidates. A candidate `W` releases only when **all** of these are positively
proven:

| Requirement | Evidence |
| --- | --- |
| `W` is a worktree of *this* repo | symlink-resolved `--git-common-dir` identity (never a `--show-toplevel` string compare) |
| the approval really happened in `W` | `W/.claude/.qa-tracking/impact-report-<tid>.json` exists and its `.change_set_hash` is one a real `QA-GATE APPROVED` record on the task carries |
| nothing changed in `W` after the approval | `W`'s `git status --porcelain` minus `W`'s own `gate-baseline` is empty |
| this checkout ships nothing extra | every reviewable path here is inside that report's `.files[].file` set, compared repo-relative |
| the review is still clean | the same `review-check.sh gate` predicate the same-checkout path re-runs, with the same `[review bypass:` escape |

**Record-based, never recomputed.** `approve` truncates `changed-files.txt` in
the approving checkout, so re-running `impact-report.sh --hash-only` in `W`
returns the sha256 of the empty list — the approved hash is unreproducible even
there. The persisted `impact-report-<tid>.json` survives approve and is the
evidence; that is why the resolution reads a record instead of recomputing.

**Read-only and fail-closed.** The resolution only reads files and runs
`git worktree list` / `git rev-parse` / `git status` / `jq`. It writes nothing —
in particular nothing inside the candidate worktree — and never boots the
code-graph MCP server. Every error, unreadable artifact or ambiguity falls
through to the block; a resolution must be proven, never assumed. When the
recorded worktree has been **removed**, the block names it explicitly
("bound in worktree `<path>`, which no longer exists — re-enter + re-review
here") instead of leaving the operator with an unreproducible hash; otherwise
the reason gains "(checked N worktree(s))" so the search is visible.

The block is sentinel-wrapped (`# WORKTREE-RESOLUTION BEGIN` … `END`) and an L2
META-TEST strips it to prove the cross-worktree release depends on it.

The audited escape is `approve --no-review '<reason>'`, which records
`reviewed_by=none` plus a `[review bypass: <reason>]` marker on the approval
comment; the Stop hook honours that marker and skips its re-check. The F1 fast
path above uses it automatically (a doc-only change has no implementer and
nothing to review, so without the flag every documentation commit would
deadlock on the review refusal).

**Clearing a disputed finding.** Only two records clear an open at-threshold
finding, and both are written by existing `qa-gate.sh` subcommands:

```bash
# 1. The finding is right — fix it and cite the evidence (both refs mandatory).
bash .claude/scripts/qa-gate.sh resolve-finding <tid> <finding-id> \
    --fix '<commit or path:line>' --test '<test that proves it>' '<summary>'

# 2. The finding is disputed — the ORCHESTRATOR adjudicates and records why.
bash .claude/scripts/qa-gate.sh arbitrate <tid> <finding-id> \
    <overrule|sustain> '<rationale citing BOTH positions>'
```

`overrule` clears the finding in the gate count; `sustain` deliberately does
NOT — it is the audit record of a dispute that was heard and upheld, so the
gate stays shut until the implementer resolves it. The LATEST decision per
finding id wins. Arbitration is an orchestrator responsibility (the reviewer
and the author are the two parties to the dispute); the procedure and the
rationale shape live in `.claude/agents/orchestrator.md` section 5d. Note that
`qa-gate.sh choose approve` routes through the same `cmd_approve`, so a J21
escalation does not bypass any of this.

Live runs are audited by the `approval-cites-independent-review` invariant
(`.claude/tests/e2e/lib/invariants.ts`), which replays this chain over the
recorded trace: every `QA-GATE APPROVED` record must cite an independent
reviewer and leave zero at-threshold findings open. It is a second,
independent implementation of the `review-check.sh gate` predicate — the two
agreeing on a real run is the evidence; a trace recorded before the harness
captured bd comments skips rather than retro-failing.

### Escalation State Machine (spec 0.2)

The Stop hook tracks a per-task iteration counter at
`.qa-tracking/iteration-count.<task-id>`. When the escalation BASIS reaches
`MAX_ITERATIONS` (default 3) the gate transitions into an `escalated`
state to prevent the runaway loop captured in the bug report (iteration
7+ still re-running the suite with no behavioral consequence).

**The basis is `max(verification iterations, review rounds)`, not the Stop count**
(`claude-workflow-plugin-2ty`). Three measured instances in one session had the
cap firing on tasks where nothing had failed and, twice, where nobody had
reviewed anything: the counter used to bump once per Stop fire, and an
orchestrator waiting on a long review — or interrupted by infrastructure — Stops
repeatedly. That is not a bookkeeping error, because reaching the cap forces a
J21 decision whose DEFAULT (no choice recorded by the next Stop) is *defer*,
which sets `qa-deferred` and lets the following Stop release. An over-charging
counter therefore steers work toward release-without-approval on a timer. Three
rules make the counter non-authoritative:

1. **The iteration counter charges verification iterations only.** It bumps when
   this Stop will actually run a verification pass, and reads without writing
   otherwise: not while `qa-escalated` (the escalation contract does not re-run
   the suite), not while `qa-deferred` (the Stop is allowed through), and not
   when no test/lint/type command is configured at all (there is no suite, so a
   Stop was never an iteration). On a project with no runner the basis is
   therefore review rounds alone.
2. **Review rounds count records, not polls.** `review-check.sh gate <id>
   --change-set-hash <h>` reports `rounds` — the number of `REVIEW-ARTIFACT v1`
   FIRSTLINES whose `reviewed_hash=` equals `<h>` — plus `rounds_hash`. The count
   is anchored on the firstline grammar (`^[[:space:]]*REVIEW-ARTIFACT v1 `)
   because prose mentions are the normal case on any task with review history: on
   `8zi`, before any artifact existed, an unanchored `grep -c REVIEW-ARTIFACT`
   returned 1 and the hit was a reviewer's own sentence *"zero REVIEW-ARTIFACT
   firstlines"*. Rounds reset when the change set moves, which is correct — a new
   change set has needed no rounds yet.
3. **Escalation is suppressed while a review is in flight.** When a cycle is open
   (the `qa-gate-entered` label agrees with a `QA-GATE: entered` record), zero
   artifacts exist for the current hash, and no technical check is failing, the
   cap does not fire and the J21 options are not offered: a reviewer has claimed
   the cycle and not yet spoken, so nobody has disagreed with anything. The
   scope — *no technical check failing* — is load-bearing. A red suite is its own
   evidence and must still reach J21; a cycle is open during almost all
   implementation work, so an unscoped suppression would delete the J21 escape
   from the failing-test loop entirely.

   **Suppression governs whether an escalation STARTS, not whether a live one
   continues.** `qa-escalated` is sticky: once set it survives until `approve`,
   `enter`, or a `choose` records a decision. So a task can be escalated *and*
   subsequently enter the review-in-flight state — most easily by moving its
   change set, which drops `rounds` to 0 — and in that state the J21 options are
   still offered (the escalation is live and has to be answerable) while the
   suppression paragraph is not printed (an escalated task is not suppressed).
   The auto-defer chain also still runs from there; that residual is filed as
   part of `claude-workflow-plugin-2ty`'s QA round and pinned by an L2 leg
   (`escalation-basis.sh`, `H-RESIDUAL(R1-F3)`) so closing it turns a test red
   rather than going unnoticed.

If `rounds` cannot be established (no active task, no `review-check.sh`, no
computable change-set hash, or an envelope with no `rounds` key — a pre-2ty or
partially-synced copy), the basis falls back to the iteration count alone,
suppression does not apply, and the machinery behaves as it did before. An
unavailable new signal must never disable the old one.

**What the block reasons claim, and what they do not.** Every block reason on the
capped paths names the basis it used and both components, and the `QA-GATE
ESCALATED` record carries the same triple. The escalation banners state the
*relationship* to the cap rather than asserting it: `basis N >= 3; cap reached`
when the cap is currently met, and `escalated on an earlier Stop at basis M; the
current basis N is BELOW the cap of 3` when it is not. Both forms are computed
from the live basis plus the triggering basis persisted in
`.qa-tracking/escalation-posted.<task-id>` at the moment of escalation; when that
marker
predates this change it is empty, and the phrasing drops the number rather than
inventing one. The claim these sentences make is exactly "here is what was
compared" — they do not claim the count is a complete history of the task, and a
`rounds` reset after a change-set move is a real drop, not a lost round.

States — each row lists the trigger, label set, and Stop-hook behaviour:

| State | Trigger | Labels on task | Stop hook |
| ----- | ------- | -------------- | --------- |
| `pending` | normal review cycle | `qa-pending` (+ `qa-gate-entered`) | Run full suite each loop; block until approved |
| `escalated` | `max(iterations, rounds)` reaches `MAX_ITERATIONS`, and no review is in flight (or a check is failing) | `+qa-escalated` | Skip full suite; reuse cached failure; block with "record a J21 choice" wording; post J21 options comment exactly once |
| `deferred` | `qa-gate.sh choose defer` OR `AUTO_DEFER_AFTER_ESCALATED_STOPS` (2) Stops fired while escalated with no recorded choice (auto-defer) | `+qa-deferred` (qa-pending preserved) | Allow Stop immediately — the single audited escape valve permitted by principle 6 |

**Auto-defer counts Stops, on its own counter**
(`.qa-tracking/escalated-stops.<task-id>`), and that separation is deliberate.
Auto-defer asks "how many chances has the agent had to answer?", which is
legitimately a Stop count; the iteration counter asks "how many verification
passes has this taken?". They used to be the same number
(`ITER > MAX_ITERATIONS + 1`), so once the iteration counter stopped charging
Stops that run nothing it would have frozen at the cap and auto-defer — a
documented escape — would have become silently unreachable. Timing is unchanged
Stop-for-Stop: the cap-hit Stop shows the J21 options, the first escalated Stop
after it still blocks, the second auto-defers. The counter is wiped by the same
`wipe_iteration_state` that clears the iteration counter (`enter`, `approve`,
`choose continue`, `choose tech-debt`), because a count that survived a fresh
cycle would auto-defer on that cycle's FIRST escalated Stop.

Exit transitions:

- `qa-gate.sh approve` (or `choose approve`) — drops escalation/deferred,
  wipes counter, sets `qa-approved` per the existing atomic flow.
- `qa-gate.sh choose continue '<note>'` — clears `qa-escalated`, resets
  iteration counter to 0; the next Stop runs the suite fresh.
- `qa-gate.sh choose tech-debt '<description>' [severity] [file:line] [effort]`
  — calls `tech-debt.sh add --bd-task`, clears `qa-escalated`, resets counter.
- `qa-gate.sh enter <task-id>` — a fresh enter on a `qa-deferred` or
  `qa-escalated` task clears both labels and wipes per-iteration cache
  files, resuming normal gating. This is the "I'm starting a new review
  cycle after fixing things" signal.

Failure classification (spec 0.2): when tests fail, the block message
distinguishes "Test suite failed to run (environment/runner issue)" from
"Tests failing" so the next iteration targets the right surface. The
heuristic is conservative — exit codes 126/127 and unambiguous patterns
(`command not found`, `Cannot find module`, missing npm script,
testcontainers TypeError) classify as runner-failure; everything else is
assertion-failure.

Iteration counters are per-task keyed (`iteration-count.<task-id>`), so
switching active tasks naturally reads a different counter file — a Stop
on task B does NOT pick up where task A left off.

---

## SessionEnd Hook

**File**: `.claude/scripts/session-end.sh`

**Purpose**: Detect a Beads JSONL ledger divergence before the session ends. It writes nothing.

### What It Does

```bash
# Guard cwd: a missing PROJECT_DIR no longer corrupts state.
cd "$PROJECT_DIR" || { echo '{}'; exit 0; }

# CHECK the JSONL ledger and capture output for sync-errors.log so
# SessionStart can surface a one-line warning next session.
#
# This hook no longer WRITES the ledger (R4-F1). It ran `bd sync` until bd
# 1.1.2 removed that command, then `beads-ledger.sh export`, then the
# classifier-driven `refresh`; five defects came out of an unattended hook
# deciding to write, so the automatic write was removed. `check` is read-only,
# and repair is an explicit `beads-ledger.sh reconcile --apply`.
LEDGER_SH="$PROJECT_DIR/.claude/scripts/beads-ledger.sh"
SYNC_ERR_FILE="$(mktemp -t bd-ledger.XXXXXX)"
LEDGER_RC=0
bash "$LEDGER_SH" check >"$SYNC_ERR_FILE" 2>&1 || LEDGER_RC=$?
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ "$LEDGER_RC" = "1" ] || [ "$LEDGER_RC" = "3" ]; then
    printf '%s\tledger NOT written — it diverges from the database and no hook may repair that automatically. Run: bash .claude/scripts/beads-ledger.sh reconcile --apply\n' \
        "$TS" >> "$SYNC_LOG"
elif [ "$LEDGER_RC" != "0" ]; then
    printf '%s\tledger check failed: %s\n' "$TS" "$(head -1 "$SYNC_ERR_FILE" | tr -d '\n')" \
        >> "$SYNC_LOG"
fi
rm -f "$SYNC_ERR_FILE"

echo "{}"
```

### No Decision Side Effects

Per the Claude Code hooks reference, SessionEnd cannot block session
termination — its output and exit code are ignored. We emit `{}` for
clarity, even though stdout is not consumed. Any cleanup that needs to
happen MUST happen before this hook runs (verify-before-stop is the
canonical gate point); SessionEnd is best-effort persistence only.

### Worktree sweep (report-only)

**SessionEnd cannot enforce anything.** Its output and its exit code are
ignored and it cannot block termination, so nothing it decides can be relied
on. That is the whole reason the worktree sweep runs here in
**`--report-only`** mode and `--apply` is **never** passed from a hook:
removing an operator's checkout is a decision, and a hook whose verdict nobody
reads is the worst place to make one.

What it does: runs `worktree-sweep.sh --report-only --json` under `timeout 8s`
(where a `timeout`/`gtimeout` binary exists; the script is bounded internally by
`SWEEP_MAX_CANDIDATES=16` either way), does **no network I/O**, and — only when
the count is non-zero — appends one `<ts>\t<message>` line to
`.claude/.qa-tracking/worktree-sweep.log`. SessionStart snapshots and truncates
that file and renders warning 6, so the notice fires once per event.

**Its own log file, deliberately.** `session-start.sh` renders
`sync-errors.log`'s head line verbatim as *"Last session logged a Beads sync
error at …"* regardless of how the line is tagged, so a sweep line landing
there first would be reported to the operator as a Beads failure.

`session-end.sh` runs under `set -e`, so every leg of the sweep block is
`|| true`-guarded: an unguarded failure would kill the hook before its
`echo "{}"`. The component spec pins that a *failing* sweeper and an *absent*
one both still leave `{}` on stdout.

Acting on the report is manual:

```bash
bash .claude/scripts/worktree-sweep.sh            # dry run — the default
bash .claude/scripts/worktree-sweep.sh --apply    # actually remove
```

### sync-errors.log Surfacing

When the ledger export fails, the failure is appended to
`.claude/.qa-tracking/sync-errors.log` rather than swallowed silently.
SessionStart reads recent entries from this file on the next session and
surfaces a one-line `<sync_warnings>` block in `additionalContext` so
Claude can mention the issue early in the next turn. The log is
truncated to the last 100 entries to bound disk usage.

---

## Helper Scripts

The hooks above orchestrate a set of helper scripts in `.claude/scripts/`
that handle the structural state-keeping. None of them are wired as
hooks; they are invoked by hooks, slash commands, and specialist agents.

| Script | Purpose |
|--------|---------|
| `qa-gate.sh` | QA gate state machine. Subcommands: `enter`, `status`, `approve`, `block`, `choose` (spec 0.2), `baseline-capture` (v4), `reconcile-tracker` (94d). Single source of truth: Beads labels (`qa-gate-entered`, `qa-pending`, `qa-approved`, `qa-blocked`, plus `qa-escalated` and `qa-deferred` after spec 0.2). `enter` writes the `gate-baseline` snapshot if one is missing (minus already-tracked paths); `approve` refreshes it in full + truncates `changed-files.txt` (closes 0wk.2). Both reconcile the tracker against `git status` before the change-set hash is computed, and `approve` REFUSES (exit 2, `tracker_unreconcilable`, no bypass) when it cannot — and separately (exit 2, `change_set_reconstructed`, bypass `--accept-reconstructed '<reason>'`) when the set it would bind was rebuilt from an absent-or-empty tracker AND that rebuild dropped git-visible paths as already-baselined (94d.1). See "The gate baseline" and "The tracker reconcile". |
| `workflow-denylist.sh` | Not a hook and not executable on its own — the ONE definition of which paths the workflow treats as reviewable. TWO rules: `WORKFLOW_DENYLIST_REGEX` + `workflow_denylisted` ("is this reviewable work?") and, since 94d, `WORKFLOW_SELF_WRITTEN_REGEX` + `workflow_self_written` ("may this path enter the change set as a side effect of the gate running?" — `.claude/.qa-tracking/**` and `.beads/interactions.jsonl`, but **not** `.beads/issues.jsonl`). Sourced BASH_SOURCE-relative by FOUR consumers: `post-edit.sh`, `qa-gate.sh` (94d — `reconcile_tracker` is the second writer of `changed-files.txt` and must apply the same filters as the first), `impact-report.sh` and `verify-before-stop.sh`; the second rule is applied by the first, second and fourth of those. A THIRD filter — record-time containment against `$CLAUDE_PROJECT_DIR` (fkm.1.15) — deliberately does **not** live here: it is not a path pattern but a comparison against a runtime root, and it has exactly one applier (`post-edit.sh`), because the only other tracker writer derives its paths from `git status` inside the repo. Editing either rule here is a change-set-hash migration; so is changing what reaches the tracker in the first place. See "The second rule: `workflow_self_written`", "The third rule: record-time containment" and "Denylist changes are a hash migration". |
| `current-task.sh` | F3 single source of truth for the active Beads task id. Subcommands: `set`, `get`, `get-repo`. Persists task id at `.qa-tracking/current-task` plus repo fingerprint at `.qa-tracking/current-task.repo` (I8 cross-repo guard). |
| `prevent-orchestrator-edits.sh` | PreToolUse hook (matcher `^(Write\|Edit\|MultiEdit)$`) blocking code edits by the `orchestrator`. Emits `hookSpecificOutput.permissionDecision: deny`. Defense in depth only — **the primary guard is the orchestrator's omitted Write/Edit tools.** Bash is NOT matched and there is no write-shaped-Bash detector: llh.19 added one and `5535a6d` **reverted it**, because failing closed on an identity the runtime does not surface to PreToolUse broke specialist edits (P0-class regression for a P2; `LESSONS.md` records the shape, and v5 plan correction 9 forbids re-scoping this hook). The Bash write vector is therefore an accepted, documented residual at *this* hook, and the net downstream is **partial, not complete**: `qa-gate.sh reconcile-tracker` folds git-visible paths into the change set, so a Bash write to a path that was **clean at gate-baseline capture** does still reach QA even though nothing prevented it — while a Bash write to a path the baseline already lists does **not**. The baseline is subtracted over raw porcelain lines, so the second write leaves ` M path` byte-identical and `comm -23` removes it as pre-existing dirt; no commit is needed, and the reconcile reports success either way — `added=0` when that was the only pending write, and a count that silently omits it when it was not. Reproduced and pinned by `gate-baseline-v2.sh` 7.6/7.7/7R; tracked as `claude-workflow-plugin-dpe`; see "The tracker reconcile", the line-granularity limit under "Known limits". Accepting this residual therefore means accepting that the part of it landing on already-baselined paths is invisible — not that every Bash write is visible. Corrected twice in 94d: this row first described the reverted mechanism, and then (QA finding R4-F1) asserted a coverage the reconcile does not have. |
| `epic-gate.sh` | Epic-level QA gate (B2). Subcommands: `check`, `siblings`, `shared-files`. Returns `pass`/`defer`/`block` based on sibling status and file-intersection across in-progress tasks under the same epic. |
| `subagent-start.sh` | J3 cross-session auto-assign. SubagentStart hook: when the spawned subagent is a specialist AND `current-task` is non-empty, injects `additionalContext` with the task id + brief summary so the orchestrator doesn't need to repeat the brief. |
| `tech-debt.sh` | TECHNICAL_DEBT.md append (J22). Subcommands: `add <severity> <file:line> <effort> <description>`, `list`. Optional `--bd-task` creates a paired Beads task and links it to the active task with an explicit `bd dep add` (it used `--deps blocks:` until bd 1.1.2, which records that edge backwards). |
| `bd-github-link.sh` | I3 Beads ↔ GitHub auto-link. PostToolUse hook on Bash invocations. When a Beads task closes, posts a `gh issue comment` linking back; when `gh pr create` runs, parses `Closes #N` and writes `gh-link:` into the task notes. |
| `detect-stack.sh` | F8/J17 polyglot test runner detection. Emits JSON `{runner, test_cmd, lint_cmd, type_cmd, manifest, overrides}`. Supports npm, pytest, go, cargo, maven, gradle, phpunit, rake, swift, dotnet, make, plus `.claude/test-cmd` overrides. |
| `statusline.sh` | E4/I2 statusline. Reads `current-task`, the task's bd labels, and the changed-files count. Emits `[<task-id>] qa: <state> · N files changed`, plus the model segment described below. **Reads** stdin (it did drain it until v5.0.0 / D0): the session envelope is the ONLY place the live session model is observable, so the session-model guard has to live here. |
| `worktree-sweep.sh` | v4.1 (C1b) sweeper for the subagent worktrees at `.claude/worktrees/<name>`. Ones with NO changes are auto-removed when the subagent finishes; ones WITH changes survive, and until this script nothing removed them. **Dry run is the default; `--apply` is the only thing that removes**, and removal is `git worktree remove` + `git worktree prune` — there is no `rm -rf` in the file and `worktree remove` is never `--force`d (both asserted structurally by `worktree-sweep.test.sh`). A worktree is removable only if ALL of: (1) its `cd … && pwd -P`-**resolved** path is physically inside the resolved `.claude/worktrees/` — a string-prefix test is not a containment guard, and this is what excludes an operator's sibling checkout whose name merely *extends* the root's; (2) same repo by `--git-common-dir` identity; (3) `git status --porcelain` empty; (4) `@{upstream}..HEAD` == 0 commits, else `merge-base --is-ancestor <branch> <default>` — **decided locally, never a fetch**; (5) directory mtime older than `--age-days` (default 7); (6) a Beads task resolved from EVIDENCE (the worktree's own `.qa-tracking/current-task`, else a task-shaped branch token bd actually knows) that bd reports `closed`. Any error, unreadable path or ambiguity is NOT a candidate, and each keeper prints its FIRST failing gate. Worktree NAMING is deliberately off the safety path. Flags: `--apply`, `--age-days N`, `--report-only` (wins over `--apply`), `--json`, `--max-candidates N` (default 16, the same bound as the Stop hook's `WTRES_MAX_CANDIDATES`), `--help`. Exit 0 / 1 (a removal failed) / 2 (bad invocation). Invoked report-only by `session-end.sh`; see "Worktree sweep (report-only)". |
| `workflow-doctor.sh` | v4.1 FUNCTIONAL post-install verification (C0a) — an operator CLI, not a hook, and the only surface that asks whether an install *runs* rather than whether its files exist. Twelve named checks (`deps`, `agents`, `skill`, `mcp_config`, `settings_hooks`, `beads`, `beads_ledger`, `session_start`, `mcp_bd`, `mcp_code_graph`, `gate_pretooluse`, `gate_stop`), each PASS/FAIL/SKIP with its own `fix:` line. It EXECUTES the SessionStart hook and asserts the emitted envelope carries the delegation contract, BOOTS both MCP servers over stdio and asserts `tools/list` returns exactly 21 / 7, and drives both gate hooks. Flags: `--target`, `--json-out`, `--skip <names>` (unknown names are rejected with exit 2 so a typo can never look like a pass), `--quiet`. Exit 0 / 1 / 2. Three front doors: `bash install.sh --verify`, `/workflow-doctor`, direct invocation. Safe mid-session — every dynamic check runs in a throwaway sandbox EXCEPT `beads`, which runs `bd doctor` against the real target on purpose and therefore rewrites `.beads/beads.db{,-shm,-wal}`; `--skip beads` is the run that provably touches nothing. |

Each helper is independently testable via the L1 bash unit tier
(`.claude/scripts/tests/*.sh`) — see `.claude/tests/README.md` for the
five-tier pyramid that exercises them.

### The statusline model segment and the session-model guard (v5.0.0 / D0)

`statusline.sh` renders the resolved role→model mapping from
`.claude/.qa-tracking/model-roles-resolved.json`, grouped so five roles fit on a
shared line: roles with the same model are joined with `+` in the fixed order
`des dsr orch impl rev`, groups are space-separated, and at most three groups
print before the tail becomes ` +<k> more`. All roles equal with both review
lanes on Claude collapses to ` • model: <short>`. A non-Claude lane substitutes
the literal `sol` for that lane. **The render iterates the roles PRESENT in
`.roles`**, so a leftover three-role v4 artifact still renders correctly with no
upgrade step.

Three flags may follow, in this order:

| Flag | Source | Meaning |
| --- | --- | --- |
| `!esc` | `.claude/.qa-tracking/implementer-escalation.json` exists | A per-unit implementer escalation is active, so the implementer lane is not on its configured strategy. Reverse with `model-select.sh restore`. |
| `!id` | `.identity_collapse` in the artifact | `designer` and `design_reviewer` resolved to the same model on the Claude design lane. Reported, never blocking; the two clearances are in the `.claude/model-roles` header. |
| `!sess` | `.claude/.qa-tracking/session-model-drift.json` | The live session model differs from the resolved `orchestrator` id. |

**The session-model guard is read-compare-write only.** The statusline runs on
every render, so the drift record is rewritten only when the `(expected, live)`
pair it holds would change, and removed only when a *completed* comparison finds
no drift. An absent envelope, an absent `.model.id`, an absent artifact or a
missing `jq` all mean "no comparison was possible", which is **not** the same as
"no drift" — those paths leave any existing record exactly as they found it.
`session-start.sh` Warning 8 re-validates the record against the current
artifact (a record whose `expected` no longer matches is stale and is not
reported) and emits the fix verbatim. Nothing here ever blocks.

**The comparison is by model identity, not by id string.** A trailing bracketed
context-window marker (`claude-fable-5[1m]`) is separated from the base id
before comparing, and the rule is asymmetric:

| resolved `orchestrator` | live session model | verdict |
| --- | --- | --- |
| `claude-fable-5` | `claude-fable-5[1m]` | **no drift** — same model, and the resolver named no variant to violate |
| `claude-fable-5[1m]` | `claude-fable-5` | **drift** — `pick_best` sorts `_ctx` DESC, so a resolved `[1m]` was a deliberate pick, and the fix line names it |
| `claude-fable-5` | `claude-opus-4-5[1m]` | **drift** — different model |

Row 1 is why this exists: as literal equality the guard reported the 1M variant
of the *correct* model as drift on every render, with a fix line that moved the
operator to a smaller context window. Row 2 is why both sides are not simply
stripped — that would trade a true positive away to fix the false one. Sharp
edge that remains: an id differing in any other way (a dated variant, an alias)
is still reported as drift; this hook cannot know an alias resolves to the same
weights, and the fix line names the exact id either way.

Warnings 9 and 10 carry the other two D0 notices — identity collapse, and the
`missing_keys` list that makes an un-upgraded `operator`-class
`.claude/model-roles` visible. **None of the three routes through
`model-select.sh`'s `_warn`**: Warning 2 keeps only the LAST `^model-select:`
line, so a new loud warning added to the helper is swallowed by whatever the
helper prints afterwards. Each notice rides the artifact or its own state file
and is read from disk at SessionStart, where it gets its own line.

---

## Debugging Hooks

### Check if hooks are configured

```bash
cat .claude/settings.json | jq '.hooks'
```

### Test hooks manually

```bash
# Test session-start
echo '{}' | bash .claude/scripts/session-start.sh

# Test intent-router
echo '{"prompt": "Add user authentication"}' | bash .claude/scripts/intent-router.sh

# Test post-edit
echo '{"tool_input": {"file_path": "src/test.ts"}}' | bash .claude/scripts/post-edit.sh

# Test verify-before-stop
echo '{"stop_reason": "end_turn"}' | bash .claude/scripts/verify-before-stop.sh
```

### Common Issues

**Hook not triggering**:
- Check `settings.json` has the hook configured
- Verify script has execute permission: `chmod +x .claude/scripts/*.sh`
- Check for bash availability (Windows needs Git Bash)

**jq errors**:
- Ensure jq is installed: `jq --version`
- Check JSON input is valid

**Beads errors**:
- Verify Beads is installed: `bd --version`
- Check Beads is initialized: `ls .beads/`
- Run health check: `bd doctor`
