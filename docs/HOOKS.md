# Hooks Reference

Complete documentation of all hook scripts in the Ultimate Workflow Plugin.

---

## Overview

The plugin uses 5 Claude Code hooks:

| Hook | File | Trigger |
|------|------|---------|
| SessionStart | `session-start.sh` | Session begins |
| UserPromptSubmit | `intent-router.sh` | User submits prompt |
| PostToolUse | `post-edit.sh` | After Write/Edit tools |
| Stop | `verify-before-stop.sh` | Claude attempts to stop |
| SessionEnd | `session-end.sh` | Session ends |

---

## Hook Configuration

**File**: `.claude/settings.json`

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
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/intent-router.sh\""
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Write|Edit|MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/post-edit.sh\""
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/verify-before-stop.sh\""
          }
        ]
      }
    ],
    "SessionEnd": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/scripts/session-end.sh\""
          }
        ]
      }
    ]
  }
}
```

---

## SessionStart Hook

**File**: `.claude/scripts/session-start.sh`

**Purpose**: Initialize context with Beads state and workflow instructions.

### What It Does

```bash
# 1. Verify Beads is available
if ! command -v bd &> /dev/null; then
    echo '{"error": "Beads (bd) not found"}'
    exit 1
fi

# 2. Verify Beads is initialized
if [ ! -d "$PROJECT_DIR/.beads" ]; then
    echo '{"error": "Beads not initialized. Run: bd init"}'
    exit 1
fi

# 3. Run bd doctor silently
bd doctor --quiet

# 4. Create session marker
touch "$PROJECT_DIR/.claude/.session-start"

# 5. Reset QA tracking
rm -f "$QA_TRACKING_DIR/approved"
rm -f "$QA_TRACKING_DIR/changed-files.txt"

# 6. Get bd prime output (Beads' agent context)
BD_PRIME=$(bd prime)

# 7. Load CLAUDE.md (project memory)
# 8. Get blocked issues (bd blocked)
# 9. Get qa-pending issues
# 10. Inject workflow instructions

# 11. Output JSON for additionalContext
cat << EOF
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": "..."
  }
}
EOF
```

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

Configured in `settings.json` with matcher `^(Write|Edit|MultiEdit)$`. Only
these three tools trigger the hook — every other tool invocation is a
no-op. Bash edits (e.g., `sed -i`) are intentionally untracked because
specialists should be using the Write/Edit tools directly so the file
appears in the QA review surface.

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

### Tracking File Location

```
.claude/.qa-tracking/
├── changed-files.txt        # Deduplicated list of changed files (one per line)
├── edit-count               # Counter for the every-10-edits batched bd comments
├── current-task             # Single source of truth: active task id (F3)
├── current-task.repo        # Repo fingerprint at set time (I8 cross-repo guard)
├── approved-baseline        # git status --porcelain snapshot at approval time (0wk.2)
├── sync-errors.log          # Best-effort bd-call failures surfaced by SessionStart
└── .changed-files.lock      # flock target (only on systems with flock)
```

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

# 2. Check for tracked changes
if [ -f "$TRACKING_FILE" ] && [ -s "$TRACKING_FILE" ]; then
    CODE_CHANGES_DETECTED=true
fi

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
| `qa-gate.sh` | QA gate state machine. Subcommands: `enter`, `status`, `approve`, `block`, `choose` (spec 0.2). Single source of truth: Beads labels (`qa-gate-entered`, `qa-pending`, `qa-approved`, `qa-blocked`, plus `qa-escalated` and `qa-deferred` after spec 0.2). On `approve` writes `approved-baseline` snapshot + truncates `changed-files.txt` (closes 0wk.2). |
| `current-task.sh` | F3 single source of truth for the active Beads task id. Subcommands: `set`, `get`, `get-repo`. Persists task id at `.qa-tracking/current-task` plus repo fingerprint at `.qa-tracking/current-task.repo` (I8 cross-repo guard). |
| `prevent-orchestrator-edits.sh` | PreToolUse hook blocking Write/Edit/MultiEdit when the active subagent is `orchestrator`. Emits `hookSpecificOutput.permissionDecision: deny` with a "delegate to specialist" reason. Defense in depth — the orchestrator's tool list already omits Write/Edit. |
| `epic-gate.sh` | Epic-level QA gate (B2). Subcommands: `check`, `siblings`, `shared-files`. Returns `pass`/`defer`/`block` based on sibling status and file-intersection across in-progress tasks under the same epic. |
| `subagent-start.sh` | J3 cross-session auto-assign. SubagentStart hook: when the spawned subagent is a specialist AND `current-task` is non-empty, injects `additionalContext` with the task id + brief summary so the orchestrator doesn't need to repeat the brief. |
| `tech-debt.sh` | TECHNICAL_DEBT.md append (J22). Subcommands: `add <severity> <file:line> <effort> <description>`, `list`. Optional `--bd-task` creates a paired Beads task with `--deps blocks:<active-task>`. |
| `bd-github-link.sh` | I3 Beads ↔ GitHub auto-link. PostToolUse hook on Bash invocations. When a Beads task closes, posts a `gh issue comment` linking back; when `gh pr create` runs, parses `Closes #N` and writes `gh-link:` into the task notes. |
| `detect-stack.sh` | F8/J17 polyglot test runner detection. Emits JSON `{runner, test_cmd, lint_cmd, type_cmd, manifest, overrides}`. Supports npm, pytest, go, cargo, maven, gradle, phpunit, rake, swift, dotnet, make, plus `.claude/test-cmd` overrides. |
| `statusline.sh` | E4/I2 statusline. Reads `current-task`, the task's bd labels, and the changed-files count. Emits `[<task-id>] qa: <state> · N files changed`. Drains stdin (Claude Code passes a session envelope it doesn't need). |

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
