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
| PostToolUse | `post-edit.sh` | After Write/Edit/MultiEdit tools |
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
        "matcher": "^(Write|Edit|MultiEdit)$",
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

> The plugin-manifest `.claude/hooks/hooks.json` mirrors this block and
> additionally wires `SubagentStart` (`subagent-start.sh`) and a second
> `PostToolUse` matcher (`^Bash$` → `bd-github-link.sh`) for
> plugin-scoped installs.

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

# 5. Reset QA tracking
rm -f "$QA_TRACKING_DIR/approved"
rm -f "$QA_TRACKING_DIR/changed-files.txt"

# 5b. Capture the gate baseline (v4) — ONLY when no review cycle is active.
#     Records "this dirt was already here on arrival" so the Stop gate
#     evaluates the session's delta. Fails OPEN: SessionStart must never
#     break a session, so a failure is one sync-errors.log line and nothing
#     more. See "The gate baseline" under the PostToolUse hook.
if [ -z "$(current-task.sh get)" ]; then
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

Configured in `settings.json` with matcher `^(Write|Edit|MultiEdit|Bash)$`.
The Write/Edit/MultiEdit tools trigger tracking of `tool_input.file_path`.
Bash invocations are inspected too (llh.19): a *write-shaped* Bash command
(heredoc-to-file, `>`/`>>` into a path, `tee`, `sed -i`, `dd of=`, or
`cp`/`mv` into the tree) has its target source path(s) recovered and tracked
so a Bash-laundered edit is still visible to the QA change-set. Transient
sinks (`/tmp`, `/dev/null`, …) and read-only Bash (git, reads, test runs)
produce no tracked entry. This recovery is a best-effort heuristic — see the
threat-model boundary note in `prevent-orchestrator-edits.sh`; specialists
should still prefer the Write/Edit tools so the edit surfaces cleanly.

### What It Does

```bash
# 1. Extract file path from tool input. Both `.file_path` and `.path` are
#    accepted because different tools expose the field differently.
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty')

# 2. Skip when the path is empty (defensive — Edit/MultiEdit always emit a
#    file path, but the hook never errors on unexpected input).
if [ -z "$FILE_PATH" ]; then
    echo '{}'; exit 0
fi

# 3. Apply the build-artefact denylist. The pre-Phase-1 hook used an
#    extension allowlist (B6) which silently dropped .md, .yaml, .toml,
#    Dockerfile, .tf, .proto, etc. The current hook tracks EVERYTHING
#    except known build/lock noise.
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
#    appenders don't lose data.
if [ "$LINE_COUNT" -gt 1000 ]; then
    sort -u "$TRACKING_FILE" | tail -500 > "$TRACKING_FILE.tmp"
    mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
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
`.proto`), and config (`.json`, `.env.example`). What's denied: anything
inside `node_modules/`, `dist/`, `build/`, `coverage/`, `.git/`, `.next/`,
plus `*.lock`, `*.pyc`, `*.map`, `*.min.{js,css}`, and the major lockfiles.

### The shared denylist (`workflow-denylist.sh`)

The denylist is **one definition with three consumers**, and it lives in
`.claude/scripts/workflow-denylist.sh`:

| Consumer | Question it answers |
| --- | --- |
| `post-edit.sh` | what gets TRACKED into `changed-files.txt` |
| `impact-report.sh` | what enters the canonical change set and its HASH |
| `verify-before-stop.sh` | what the Stop gate treats as needing REVIEW |

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

Deliberately **not** denylisted: `CLAUDE.md` (behaviour-bearing — SessionStart
injects it), `LESSONS.md` and `HANDOFF.md` (audit deliverables). The `*.md`
doc-only fast path already handles those when they change alone.

If the lib is missing, each consumer fails closed in its own idiom:
`impact-report.sh` exits 3 and emits no hash (upstream treats an empty hash as
refuse-to-release); `verify-before-stop.sh` BLOCKS with a remediation reason
(emitted **after** the `stop_hook_active` circuit breaker, never before it);
`post-edit.sh` tracks the path unfiltered, because for a hook that feeds the
gate, over-tracking is the fail-closed side.

#### Denylist changes are a hash migration

`change_set_hash` is a sha256 over the **denylist-filtered** changed-files
list. Editing the regex therefore changes the recomputed hash of any change
set containing a newly-(un)matched path. An approval recorded before the edit
no longer matches what the Stop hook recomputes after it, so the gate emits
`LABEL_WITHOUT_RECORD` and re-blocks.

That is the correct direction — a stale approval must not release — but it is
user-visible friction, so **ship every denylist addition in ONE landing**: one
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

### Tracking File Location

```
.claude/.qa-tracking/
├── changed-files.txt        # Deduplicated list of changed files (one per line)
├── edit-count               # Counter for the every-10-edits batched bd comments
├── current-task             # Single source of truth: active task id (F3)
├── current-task.repo        # Repo fingerprint at set time (I8 cross-repo guard)
├── gate-baseline            # Versioned git-status snapshot the Stop gate subtracts (v4)
├── approved-baseline        # LEGACY (0wk.2) pre-v4 snapshot; read for one release, then deleted
├── impact-report-<tid>.json # Mechanical impact_of artifact; SURVIVES approve, so it is
│                            # also the approved-file-set record another checkout reads
│                            # (see "Cross-worktree approval resolution")
├── sync-errors.log          # Best-effort bd-call failures surfaced by SessionStart
└── .changed-files.lock      # flock target (only on systems with flock)
```

Everything here is **per-checkout**. A linked worktree has its own
`.claude/.qa-tracking/`, hence its own tracker, hash, baseline and impact
report — which is exactly why a cross-checkout approval needs the resolution
step described under the Stop hook.

### The gate baseline (`gate-baseline`)

A snapshot of `git status --porcelain` that says "this dirt was already here;
it is not this session's work". The Stop hook's git-status fallback subtracts
it, so the gate evaluates the session **delta** rather than the whole working
tree. Without one, opening a session in a repo that is merely dirty — a
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
| `session-start.sh` | full snapshot, **only when no review cycle is active** | an in-flight cycle's work is dirty right now; baselining it would release it unreviewed |
| `qa-gate.sh enter` | **write-if-missing**, minus paths already in `changed-files.txt` | a cycle opened mid-session must not baseline the edits that session already made |
| `qa-gate.sh approve` | full refresh | approve means "everything dirty right now has been reviewed" |

`qa-gate.sh baseline-capture [--by <who>] [--if-missing] [--exclude-tracked]`
is the entry point session-start calls; it takes no task id and touches no
labels.

There is deliberately **no hash-side subtraction**. `changed-files.txt` is fed
only by post-edit from actual tool edits, so pre-existing dirt cannot enter it,
and an edit to an already-dirty file must still gate.

Both the writer and the Stop hook's fallback ask `git rev-parse --git-dir`
rather than testing `-d "$PROJECT_DIR/.git"`. In a linked worktree `.git` is a
FILE, so the old test answered "not a git repo" and silently switched off both
the snapshot and the fallback — with an empty `changed-files.txt` the gate then
had no detector at all and failed OPEN.

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

# 2. Check for tracked changes. `reviewable_changes` is the ONE definition of
#    "what counts as a change right now": the denylist-filtered tracker, or —
#    only when that yields nothing — 2b's git fallback. Step 6a re-reads it.
while IFS= read -r f; do CODE_CHANGES_DETECTED=true; done < <(reviewable_changes)

# 2b. Fallback (inside reviewable_changes): git status MINUS the gate baseline,
#     so only entries NEW since the baseline count. Requires
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
#    read through qa-gate.sh status (verify-before-stop.sh:982-992).
QA_APPROVED=false
GATE_STATUS=$("$QA_GATE" status "$TASK" | jq -r '.status')
if [ "$GATE_STATUS" = "approved" ]; then
    QA_APPROVED=true
fi
# There is NO comment-text fallback and NO marker file. Both were deleted
# (verify-before-stop.sh:20-22); a comment that merely says "QA APPROVED"
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
#    approval source (verify-before-stop.sh:1177-1181).
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
`qa-gate.sh status` (`verify-before-stop.sh:982-992`). The label is set
atomically by `qa-gate.sh approve` (which also drops `qa-pending` /
`qa-gate-entered` and writes an audit comment). There is no comment-text
fallback and no marker-file fallback — both were deleted
(`verify-before-stop.sh:20-22`):

- A comment whose body contains the literal text "QA APPROVED" does **not**
  release the gate. The earlier comment-text method (B13) was removed so the
  gate has a single deterministic signal.
- The legacy `.claude/.qa-tracking/approved` marker is **never read**. The
  Stop hook `rm`s it defensively (`verify-before-stop.sh:1177-1181`) only to
  clear stale files left by pre-v3 installs.

The gate also auto-approves without QA when there is nothing reviewable to
review — the **F1 fast path** (`verify-before-stop.sh:616-691`), which fires
when every changed path is doc-only, is Beads/gate bookkeeping
(`.beads/*.jsonl`, `beads.db`, `.qa-tracking/*`), or the change-set is empty
after the build-artifact denylist. A mixed diff (bookkeeping **plus** one
real source file) is not fast-path eligible and still requires the label.

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
`ARBITRATION ... decision=overrule`. The implementer records are written by
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
of the spec below): if the tracker is empty *and* real un-baselined dirt exists —
work written by a helper rather than the Edit tool, which never reaches
`changed-files.txt` — the Stop hook blocks on the git half of its predicate while
the persisted report still witnesses the *previous* approval, so a bare `approve`
no-ops and the block stands. Run the remediation the block prints, all three
lines of it: step 2 (`impact-report.sh`) re-persists the report, after which no
record binds it and `approve` proceeds. Closing this inside `approve` would mean a
second copy of the Stop hook's baseline-relative git walk, and that walk lives in
exactly one place (`reviewable_changes`) on purpose.

The contract change is reflected in the `bd_qa_approve` MCP tool description and
pinned by `.claude/tests/component/specs/approve-idempotency.sh` (sections A-C
and H, plus a META that reverts the guard and shows the deadlock return).

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
exists (work written by a helper rather than the Edit tool never reaches the
tracker), because the git half of `reviewable_changes` still reports it.

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
`.qa-tracking/iteration-count.<task-id>`. The counter bumps on every Stop
fire that detects tracked changes. When the counter reaches
`MAX_ITERATIONS` (default 3) the gate transitions into an `escalated`
state to prevent the runaway loop captured in the bug report (iteration
7+ still re-running the suite with no behavioral consequence).

States — each row lists the trigger, label set, and Stop-hook behaviour:

| State | Trigger | Labels on task | Stop hook |
| ----- | ------- | -------------- | --------- |
| `pending` | normal review cycle | `qa-pending` (+ `qa-gate-entered`) | Run full suite each loop; block until approved |
| `escalated` | iteration counter reaches `MAX_ITERATIONS` | `+qa-escalated` | Skip full suite; reuse cached failure; block with "record a J21 choice" wording; post J21 options comment exactly once |
| `deferred` | `qa-gate.sh choose defer` OR one more Stop while escalated with no recorded choice (auto-defer) | `+qa-deferred` (qa-pending preserved) | Allow Stop immediately — the single audited escape valve permitted by principle 6 |

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

**Purpose**: Sync Beads state before session ends.

### What It Does

```bash
# Guard cwd: a missing PROJECT_DIR no longer corrupts state.
cd "$PROJECT_DIR" || { echo '{}'; exit 0; }

# Run bd sync and capture stderr for sync-errors.log so SessionStart can
# surface a one-line warning next session.
SYNC_ERR_FILE="$(mktemp -t bd-sync.XXXXXX)"
if ! bd sync >/dev/null 2>"$SYNC_ERR_FILE"; then
    TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    ERR_LINE=$(head -1 "$SYNC_ERR_FILE" | tr -d '\n')
    printf '%s\tbd sync failed: %s\n' "$TS" "${ERR_LINE:-unknown error}" \
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

### sync-errors.log Surfacing

When `bd sync` fails (typically because the bd daemon is unreachable —
see bug 0wk.5), the failure is appended to
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
| `qa-gate.sh` | QA gate state machine. Subcommands: `enter`, `status`, `approve`, `block`, `choose` (spec 0.2), `baseline-capture` (v4). Single source of truth: Beads labels (`qa-gate-entered`, `qa-pending`, `qa-approved`, `qa-blocked`, plus `qa-escalated` and `qa-deferred` after spec 0.2). `enter` writes the `gate-baseline` snapshot if one is missing (minus already-tracked paths); `approve` refreshes it in full + truncates `changed-files.txt` (closes 0wk.2). See "The gate baseline". |
| `workflow-denylist.sh` | Not a hook and not executable on its own — the ONE definition of which paths the workflow treats as reviewable (`WORKFLOW_DENYLIST_REGEX` + `workflow_denylisted`). Sourced BASH_SOURCE-relative by `post-edit.sh`, `impact-report.sh` and `verify-before-stop.sh`. Editing it is a change-set-hash migration; see "Denylist changes are a hash migration". |
| `current-task.sh` | F3 single source of truth for the active Beads task id. Subcommands: `set`, `get`, `get-repo`. Persists task id at `.qa-tracking/current-task` plus repo fingerprint at `.qa-tracking/current-task.repo` (I8 cross-repo guard). |
| `prevent-orchestrator-edits.sh` | PreToolUse hook (matcher `^(Write\|Edit\|MultiEdit\|Bash)$`) blocking code edits by the `orchestrator`. Denies the Write/Edit/MultiEdit tools AND *write-shaped* Bash (redirection into source, `tee`, `sed -i`, `dd of=`, `cp`/`mv` into the tree) so the orchestrator cannot launder a write through Bash (llh.19). Legitimate orchestrator Bash (git/bd/reads/test-runs, redirects into `/tmp`/`/dev/null`) is allowed (anti-overreach). For a WRITE with no probeable agent identity it fails CLOSED (deny) — an unattributed write is treated as a possible mis-attributed orchestrator edit. Emits `hookSpecificOutput.permissionDecision: deny`. Defense in depth (the Bash detector is a raise-the-bar heuristic, not airtight); the primary guard is the orchestrator's omitted Write/Edit tools. |
| `epic-gate.sh` | Epic-level QA gate (B2). Subcommands: `check`, `siblings`, `shared-files`. Returns `pass`/`defer`/`block` based on sibling status and file-intersection across in-progress tasks under the same epic. |
| `subagent-start.sh` | J3 cross-session auto-assign. SubagentStart hook: when the spawned subagent is a specialist AND `current-task` is non-empty, injects `additionalContext` with the task id + brief summary so the orchestrator doesn't need to repeat the brief. |
| `tech-debt.sh` | TECHNICAL_DEBT.md append (J22). Subcommands: `add <severity> <file:line> <effort> <description>`, `list`. Optional `--bd-task` creates a paired Beads task with `--deps blocks:<active-task>`. |
| `bd-github-link.sh` | I3 Beads ↔ GitHub auto-link. PostToolUse hook on Bash invocations. When a Beads task closes, posts a `gh issue comment` linking back; when `gh pr create` runs, parses `Closes #N` and writes `gh-link:` into the task notes. |
| `detect-stack.sh` | F8/J17 polyglot test runner detection. Emits JSON `{runner, test_cmd, lint_cmd, type_cmd, manifest, overrides}`. Supports npm, pytest, go, cargo, maven, gradle, phpunit, rake, swift, dotnet, make, plus `.claude/test-cmd` overrides. |
| `statusline.sh` | E4/I2 statusline. Reads `current-task`, the task's bd labels, and the changed-files count. Emits `[<task-id>] qa: <state> · N files changed`. Drains stdin (Claude Code passes a session envelope it doesn't need). |
| `workflow-doctor.sh` | v4.1 FUNCTIONAL post-install verification (C0a) — an operator CLI, not a hook, and the only surface that asks whether an install *runs* rather than whether its files exist. Eleven named checks (`deps`, `agents`, `skill`, `mcp_config`, `settings_hooks`, `beads`, `session_start`, `mcp_bd`, `mcp_code_graph`, `gate_pretooluse`, `gate_stop`), each PASS/FAIL/SKIP with its own `fix:` line. It EXECUTES the SessionStart hook and asserts the emitted envelope carries the delegation contract, BOOTS both MCP servers over stdio and asserts `tools/list` returns exactly 21 / 7, and drives both gate hooks. Flags: `--target`, `--json-out`, `--skip <names>` (unknown names are rejected with exit 2 so a typo can never look like a pass), `--quiet`. Exit 0 / 1 / 2. Three front doors: `bash install.sh --verify`, `/workflow-doctor`, direct invocation. Safe mid-session — every dynamic check runs in a throwaway sandbox EXCEPT `beads`, which runs `bd doctor` against the real target on purpose and therefore rewrites `.beads/beads.db{,-shm,-wal}`; `--skip beads` is the run that provably touches nothing. |

Each helper is independently testable via the L1 bash unit tier
(`.claude/scripts/tests/*.sh`) — see `.claude/tests/README.md` for the
five-tier pyramid that exercises them.

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
