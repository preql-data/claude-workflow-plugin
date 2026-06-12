---
name: workflow-engine
description: Always-on workflow rules for the claude-workflow-plugin. Use proactively whenever any non-trivial software-engineering work is in flight — defines the orchestrator -> specialist -> QA delegation contract, the Beads task lifecycle, the QA gate states, and the helper scripts Claude invokes. Auto-loaded; do not wait for an explicit trigger.
when_to_use: Any time a user request involves writing, changing, reviewing, or shipping code in this project. Auto-applies on every session.
disable-model-invocation: false
user-invocable: true
---

# Workflow engine

This is the canonical source of truth for the plugin's workflow rules. The
`session-start.sh`, `intent-router.sh`, and `orchestrator.md` files reference
this document rather than embedding their own copies — when this file changes,
the rules change everywhere.

The workflow loads automatically on every session (no slash command, no
keyword trigger). Per cross-cutting principle 4, it is always-on.

## Mandatory roles

The plugin enforces a three-layer role split. The user types intent in plain
English; Claude internally maps to these roles.

- **Orchestrator** — coordinates and delegates. Does NOT write implementation
  code. Tool list omits `Write`/`Edit`/`MultiEdit`; the
  `prevent-orchestrator-edits.sh` PreToolUse hook is a defense-in-depth
  complement.
- **Specialists** — `@backend`, `@frontend`, `@devops`. Implement code in
  their domain. Have full broad tool access.
- **QA** — mandatory gate. No code reaches the user without QA approval. QA
  approves/blocks via the `qa-gate.sh` helper, not manual `bd label add/remove`
  commands.

## Mandatory delegation flow

When the user submits any non-trivial request, the orchestrator:

1. Analyzes the request: type (bug, feature, improvement, testing, planning)
   and domains (backend, frontend, devops — can be multiple).
2. Creates a Beads task (or epic + sub-tasks for multi-domain work).
3. Persists the active task id via `current-task.sh set <id>` so all hooks
   see the same source of truth (F3).
4. Delegates implementation to the appropriate specialist with `Task("@<role>", ...)`.
5. Delegates review to `@qa` after specialists complete work.

You are violating the workflow if you (orchestrator):

- Write implementation code yourself instead of delegating.
- Skip QA review (the Stop hook will block you).
- Forget to create a Beads task (no cross-session traceability).

## Intra-session vs cross-session task tracking

The plugin uses two complementary task systems:

- **Beads (`bd`)** — cross-session, durable. Survives session end. Authority
  for QA gate state, dependencies, epics, and historical record.
- **TaskCreate / TaskUpdate** — intra-session, ephemeral. Breaks the active
  Beads task into in-session steps so progress is visible to the user during
  the turn. Cleared when the session ends.

The orchestrator should open both: `bd create` for the durable task, then
`TaskCreate` for the in-session breakdown. See `orchestrator.md` for concrete
examples.

## Task creation patterns

```bash
# Simple task (one domain)
bd create "Fix: Login timeout" -t bug -p 1 -l backend,qa-pending

# Complex feature (multiple domains) — use an epic
EPIC=$(bd create "Epic: User Auth" -t epic -p 1 --json | jq -r '.id')
bd create "Backend: Auth API" -p 1 --parent $EPIC -l backend,qa-pending
bd create "Frontend: Login UI" -p 1 --parent $EPIC -l frontend,qa-pending
bd create "QA: Test auth flows" -p 1 --parent $EPIC -l qa
```

After creation, persist the active id:

```bash
bash .claude/scripts/current-task.sh set <task-id>
```

## Task documents (J4)

Long-form context attaches to a Beads task via the bd-mcp doc tools. The
orchestrator writes specs and context briefs before spawning a specialist;
the specialist reads them at the top of their turn instead of relying on
the (necessarily summarised) `Task()` prompt.

| Doc name  | Author        | When to write                                                              | When to read                                |
| --------- | ------------- | -------------------------------------------------------------------------- | ------------------------------------------- |
| `spec`    | orchestrator  | Before delegating non-trivial work. Goal + acceptance criteria + constraints. | Specialist reads first.                     |
| `context` | orchestrator  | When pointing the specialist at relevant call sites or prior art.          | Specialist reads after `spec` if referenced. |
| `arch`    | backend/devops | When the change crosses module boundaries.                                | QA reads during the review pass.            |
| `qa-plan` | qa            | At the end of the review.                                                  | QA-of-QA / next-session reviewer reads.    |
| `main`    | (notes field) | Auto-managed by `bd update --notes`.                                       | Default doc readers fall back to it.        |

MCP tools (Claude-callable):

```
bd_doc_write(task_id, name="spec", content="...")
bd_doc_read(task_id, name="spec")
bd_doc_read(task_id, list_only=true)   # see what's attached
```

This convention is enforced by prose-only updates to the agent prompts —
specialists `bd_doc_read('spec')` first; the orchestrator `bd_doc_write`s
`spec` before delegating non-trivial work. Trivial work (one-line typo
fixes, README touch-ups) does not require a spec doc; the `Task()` prompt
is the brief.

## SubagentStart auto-assignment (J3)

When a specialist subagent is spawned, the SubagentStart hook
(`subagent-start.sh`) reads the F3 current-task helper and injects an
`additionalContext` block telling the specialist the active task id, a
brief task header, and a pointer to the attached docs. SessionStart shows
pending tasks; SubagentStart auto-assigns the right pending task to the
spawned agent — no need for the orchestrator to repeat the id and brief
in the `Task()` prompt.

## QA gate lifecycle

The gate is Beads-label-driven; there is no marker file, no comment-text
fallback. Use the `qa-gate.sh` helper (Claude-invoked, not human-facing):

```bash
# Enter the gate (start a review)
bash .claude/scripts/qa-gate.sh enter <task-id>

# Check status (approved | blocked | entered | not-entered)
bash .claude/scripts/qa-gate.sh status <task-id>

# Approve atomically: removes qa-pending + qa-gate-entered, adds qa-approved,
# records a comment, clears current-task and iteration counter.
bash .claude/scripts/qa-gate.sh approve <task-id> '<approval summary>'

# Block: adds qa-blocked label and records the reason as a comment.
# Also writes a feedback memory entry (E8) so future sessions pre-warn on
# the same pattern.
bash .claude/scripts/qa-gate.sh block <task-id> '<reason>'
```

Direct `bd label add qa-approved` / `bd label remove qa-pending` calls are
deprecated. Always go through `qa-gate.sh` for atomicity, rollback, and
side-effect bookkeeping.

## Labels convention

| Label              | Meaning                                  |
| ------------------ | ---------------------------------------- |
| `backend`          | Backend domain work                      |
| `frontend`         | Frontend domain work                     |
| `devops`           | DevOps domain work                       |
| `qa`               | QA-owned task                            |
| `qa-pending`       | Awaiting QA review                       |
| `qa-gate-entered`  | QA has begun reviewing                   |
| `qa-approved`      | QA has signed off (gate cleared)         |
| `qa-blocked`       | QA blocked the change                    |
| `bug`              | Bug fix                                  |
| `improvement`      | Enhancement                              |

## Structured notes format

```
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important architectural choices]
```

This format survives Beads compaction and provides context for future sessions.

## Stop-hook gate output shapes

The `verify-before-stop.sh` Stop hook produces several block-reason shapes
the orchestrator and QA agent must recognise. Full details in `qa.md`; the
short summary:

1. **Doc-only fast path (F1)** — auto-approved, no QA action required.
2. **Verification failed (J19)** — test/lint/type failure with iteration
   counter. Run the root-cause framework, then fix or block.
3. **QA approval required (J18)** — checks passed, awaiting QA. Includes an
   intent-routing JSON payload; QA reads the diff and picks review modules.
4. **Iteration >= MAX_ITERATIONS** — adds J21 decision-gate options.
5. **Stop allowed with epic note (B2)** — non-blocking note about parent
   epic state and shared-files siblings.

## Hooks

| Hook                | Script                              | Purpose                                                        |
| ------------------- | ----------------------------------- | -------------------------------------------------------------- |
| SessionStart        | `session-start.sh`                  | `bd prime`, blocked issues, qa-pending list, workflow context. |
| UserPromptSubmit    | `intent-router.sh`                  | Mandatory delegation enforcement.                              |
| SubagentStart       | `subagent-start.sh`                 | Auto-assigns active task to spawned specialist (J3).           |
| PreToolUse          | `prevent-orchestrator-edits.sh`     | Blocks orchestrator from writing code.                         |
| PostToolUse         | `post-edit.sh` + `github-link.sh`   | Tracks changed files (Edit*); auto-links Beads <-> GitHub PRs (Bash gh*) (I3). |
| Stop                | `verify-before-stop.sh`             | Polyglot test/lint/type, QA gate, epic gate (multi-repo aware: I8). |
| SessionEnd          | `session-end.sh`                    | `bd sync` with error logging.                                  |

## Plugin scripts (Claude-invoked)

```bash
bash .claude/scripts/current-task.sh set <id> | get | clear
bash .claude/scripts/qa-gate.sh enter | status | approve | block <id> [args]
bash .claude/scripts/epic-gate.sh check | siblings | shared-files <id>
bash .claude/scripts/detect-stack.sh
bash .claude/scripts/tech-debt.sh add <severity> <file:line> <effort> '<desc>' [--bd-task]
bash .claude/scripts/statusline.sh   # rendered in the Claude Code statusline
bash .claude/scripts/github-link.sh pr_created <pr-url> | task_closed <id>   # I3
```

## MCP servers (Claude-invoked)

| Server           | Tools                                                    | Notes                                       |
| ---------------- | -------------------------------------------------------- | ------------------------------------------- |
| `bd-mcp`         | bd_create_task, bd_create_epic, bd_show_task, bd_list_tasks, bd_update_task, bd_close_task, bd_add_label, bd_remove_label, bd_list_labels, bd_add_comment, bd_list_comments, bd_add_dep, bd_list_deps, bd_get_ready, bd_get_blocked, bd_doc_write, bd_doc_read, bd_qa_enter, bd_qa_status, bd_qa_approve, bd_qa_block | Phase 6a / J29.                             |
| `code-graph-mcp`   | code_search, code_context, symbol_callers, impact_of, dead_code, dependency_path, code_index_health | Phase B / v3.3.0 (tree-sitter + SQLite). Stable surface (`code_search` / `code_context` / `code_index_health`) is byte-compatible with the retired `code-context-mcp`; impact-analysis tools are new. Orchestrator pre-delegation queries `impact_of` for likely-touched symbols; QA queries `impact_of` for every changed symbol during regression assessment (extends J19). |

## Beads features used

| Feature             | How we use it                                    |
| ------------------- | ------------------------------------------------ |
| `bd prime`          | Context injection at session start.              |
| `bd ready`          | Find available work.                             |
| `bd blocked`        | Show blocked issues.                             |
| Hierarchical issues | Epics for complex features.                      |
| Labels              | QA gate state, domain tracking.                  |
| Structured notes    | COMPLETED / IN PROGRESS / BLOCKED format.        |
| Dependencies        | QA depends on implementation.                    |
| `bd hooks install`  | Auto-sync with git.                              |
| `bd doctor`         | Health checks.                                   |

## Workflow example

```bash
# 1. Orchestrator creates an epic for a multi-domain feature
EPIC=$(bd create "Epic: User Auth" -t epic -p 1 \
    --description "Add user authentication" --json | jq -r '.id')

# 2. Sub-tasks
bd create "Backend: Auth API" -p 1 --parent $EPIC -l backend,qa-pending
bd create "Frontend: Login UI" -p 1 --parent $EPIC -l frontend,qa-pending

# 3. Persist active id
bash .claude/scripts/current-task.sh set <subtask-id>

# 4. Delegate
#    Task("@backend", "Implement POST /auth/login with JWT...")
#    Task("@frontend", "Build LoginForm with validation...")

# 5. Specialist updates Beads as work progresses
bd update $TASK --status in_progress
bd update $TASK --notes "IN PROGRESS: Implementing JWT endpoints"
bd update $TASK --notes "COMPLETED: JWT auth endpoints"

# 6. QA enters the gate, runs review modules, approves atomically
bash .claude/scripts/qa-gate.sh enter $TASK
bash .claude/scripts/qa-gate.sh approve $TASK 'Verified: login, logout, token refresh'

# 7. Beads task closes when Stop hook clears (verify-before-stop.sh handles
#    the bd update --status closed call).
```
