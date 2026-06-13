# Architecture

Deep dive into the claude-workflow plugin system design.

---

## System Overview

The plugin implements an **orchestrator-first architecture** where:

1. A central orchestrator coordinates all work
2. Specialist agents handle domain-specific tasks
3. A mandatory QA gate enforces quality
4. Beads provides persistent memory

```
┌─────────────────────────────────────────────────────────────────────┐
│                          CLAUDE CODE                                 │
├─────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐          │
│  │  SessionStart │───▶│UserPromptSub │───▶│  PostToolUse │          │
│  │     Hook      │    │    Hook      │    │     Hook     │          │
│  └──────────────┘    └──────────────┘    └──────────────┘          │
│         │                   │                   │                    │
│         │                   │                   │                    │
│         ▼                   ▼                   ▼                    │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                     ORCHESTRATOR                          │      │
│  │  • Analyzes requests                                      │      │
│  │  • Creates hierarchical tasks in Beads                    │      │
│  │  • Delegates to specialists                               │      │
│  └──────────────────────────────────────────────────────────┘      │
│         │                                                            │
│         ├──────────────┬──────────────┬──────────────┐              │
│         ▼              ▼              ▼              ▼              │
│  ┌──────────┐   ┌──────────┐   ┌──────────┐   ┌──────────┐        │
│  │ @backend │   │@frontend │   │ @devops  │   │   @qa    │        │
│  └──────────┘   └──────────┘   └──────────┘   └──────────┘        │
│                                                      │              │
│                                                      │              │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                      STOP HOOK                            │      │
│  │  • Checks for qa-approved label (sole source of truth)   │      │
│  │  • BLOCKS if not approved                                │      │
│  └──────────────────────────────────────────────────────────┘      │
│                              │                                       │
│                              ▼                                       │
│  ┌──────────────────────────────────────────────────────────┐      │
│  │                   SESSION END                             │      │
│  │  • Syncs Beads state                                     │      │
│  └──────────────────────────────────────────────────────────┘      │
│                                                                      │
└─────────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────────┐
│                           BEADS                                      │
│  • Persistent task storage                                          │
│  • Git-synchronized                                                 │
│  • Dependency tracking                                              │
│  • Labels for state                                                 │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Hooks

The plugin wires 6 Claude Code hook events in `.claude/settings.json`
(SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop,
SessionEnd); the plugin-manifest `.claude/hooks/hooks.json` adds a 7th,
SubagentStart, for plugin-scoped installs. The numbered subsections below
cover the load-bearing ones:

### 1. SessionStart

**Trigger**: When a Claude Code session begins

**Purpose**: Initialize context with Beads state and workflow instructions

**What it does**:
```bash
# 1. Verify Beads is available and initialized
bd doctor --quiet

# 2. Get Beads context via bd prime
BD_PRIME=$(bd prime)

# 3. Load project memory (CLAUDE.md)
# 4. Show blocked issues (bd blocked)
# 5. Show tasks awaiting QA (label: qa-pending)
# 6. Inject workflow instructions
```

**Output**: JSON with `additionalContext` containing all context

### 2. UserPromptSubmit

**Trigger**: When user submits a prompt

**Purpose**: Surface the workflow contract so Claude routes the work by
intent — NOT by keyword matching.

**What it does**: `intent-router.sh` injects the orchestrator-first
workflow guidance (delegation contract, specialist roles, the QA gate)
into the prompt as `additionalContext`. It does **not** grep the prompt
for `bug|api|deploy`-style keywords and pick a specialist; the earlier
v2 keyword-routing design was **removed** (principle 5: intent-based
routing, never keyword-based — keyword routers misfire under paraphrase).
Claude's own language understanding selects the specialist from the
injected contract. (Verified: `intent-router.sh` contains no
work-type/domain keyword regex; see HOOKS.md "Intent Router" and the H4
ledger row.)

```bash
# 1. Read the user prompt from stdin
# 2. Emit additionalContext describing the orchestrator -> specialist
#    -> QA workflow and the available specialist roles
# 3. Let Claude route by intent (no keyword regex, no forced specialist)
```

**Output**: JSON with `additionalContext` carrying the workflow contract

### 3. PostToolUse

**Trigger**: After Write, Edit, or MultiEdit tools

**Purpose**: Track file changes for QA review

**What it does**:
```bash
# 1. Extract file path from tool input (.tool_input.file_path // .path)
# 2. Apply a build-artifact DENYLIST (node_modules/, dist/, build/,
#    *.lock, *.min.js, lockfiles, ...) — everything NOT matched is
#    tracked, including .md/.json/.yaml/.toml/.tf/.proto. (Not an
#    extension allowlist: a narrow allowlist was the B6 antipattern this
#    hook was rewritten to avoid — see CLAUDE.md and HOOKS.md.)
# 3. Add to tracking file (deduplicated, flock-guarded when available)
# 4. Trim only when the file exceeds 1000 entries, keeping the last 500
#    (race-tolerant: 2x headroom so concurrent appenders don't lose data)
# 5. Update Beads with progress (batched every 10 edits)
```

**Output**: `{}` — a valid empty `hookSpecificOutput` no-op. This hook only
records state; the Stop hook surfaces the "changes require QA review"
context. (`post-edit.sh:53` `emit_empty() { echo '{}'; }`.)

### 4. Stop

**Trigger**: When Claude attempts to complete/stop

**Purpose**: ENFORCE QA GATE

**What it does**:
```bash
# 1. Skip if user_interrupt or max_turns
# 2. Check if code files were changed
# 3. Run technical checks (tests, lint)
# 4. Check for QA approval:
#    - Look for qa-approved label on task (sole source of truth;
#      no comment-text or marker-file fallback — both deleted,
#      verify-before-stop.sh:20-22)
# 5. If not approved: BLOCK with instructions
# 6. If approved: Allow completion
```

**Output**: Either `{}` (allow) or `{"decision": "block", "reason": "..."}` 

### 5. SessionEnd

**Trigger**: When session ends

**Purpose**: Ensure Beads state is persisted

**What it does**:
```bash
bd sync
```

---

## Agents

### Orchestrator

The central coordinator that:
- Analyzes user requests
- Creates hierarchical tasks (epics with children)
- Sets labels and dependencies
- Delegates to specialists
- Tracks progress

### Domain Specialists

| Agent | Domain | Responsibilities |
|-------|--------|------------------|
| @backend | API, DB, auth | REST/GraphQL, business logic, data modeling |
| @frontend | UI, UX | Components, styling, accessibility |
| @devops | CI/CD, infra | Pipelines, containers, deployment |

All specialists:
- Claim tasks with `bd update $ID --status in_progress`
- Update notes with structured format
- Add `qa-pending` label when done

### QA Agent

The mandatory quality gate that:
- Reviews all changed files
- Tests USER BEHAVIOR (not implementation)
- Writes E2E tests for critical journeys
- Approves or blocks with specific feedback

Approval process — use the atomic helper, which sets the `qa-approved`
label (the sole gate signal), drops `qa-pending`/`qa-gate-entered`, and
writes the audit comment in one operation (and refuses unless a current
impact report exists):
```bash
bash .claude/scripts/qa-gate.sh approve $ID '<summary>'
```
The summary lands as an audit comment; the **label** is what releases the
Stop hook. Setting the label by hand without going through `qa-gate.sh`
skips the impact-report check, so it is not the supported path.

---

## Data Flow

### Task Creation Flow

```
User Request
    │
    ▼
┌─────────────────────────────────────┐
│ Orchestrator analyzes request       │
│ Identifies: type=feature,           │
│ domains=[backend, frontend]         │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Create Epic in Beads                │
│ bd create "Epic: ..." -t epic -p 1  │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Create Subtasks with labels         │
│ bd create "Backend: ..." --parent   │
│   $EPIC -l backend,qa-pending       │
└─────────────────────────────────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Set Dependencies                    │
│ bd dep add $QA_TASK $IMPL_TASK      │
│ (QA waits for implementation)       │
└─────────────────────────────────────┘
```

### QA Approval Flow

```
Implementation Complete
    │
    ▼
┌─────────────────────────────────────┐
│ Stop Hook Triggered                 │
│ Checks: qa-approved label?          │
│ (sole source of truth — no comment- │
│  text or marker-file fallback)      │
└─────────────────────────────────────┘
    │
    ├─── NO ───┐
    │          ▼
    │   ┌─────────────────────────────┐
    │   │ BLOCKED                     │
    │   │ "Must delegate to @qa"      │
    │   └─────────────────────────────┘
    │          │
    │          ▼
    │   ┌─────────────────────────────┐
    │   │ @qa Reviews                 │
    │   │ • Checks changed files      │
    │   │ • Writes tests              │
    │   │ • Verifies behavior         │
    │   └─────────────────────────────┘
    │          │
    │          ▼
    │   ┌─────────────────────────────┐
    │   │ @qa Approves                │
    │   │ qa-gate.sh approve <id> '..'│
    │   │  → sets qa-approved label   │
    │   │    (+ audit comment, atomic)│
    │   └─────────────────────────────┘
    │          │
    └──────────┘
    │
    ▼
┌─────────────────────────────────────┐
│ Task Complete                       │
│ bd close $ID --reason "..."         │
└─────────────────────────────────────┘
```

---

## File Tracking

The `post-edit.sh` script maintains a list of changed files:

```bash
# Location
.claude/.qa-tracking/changed-files.txt

# Format: one file per line
src/auth/login.ts
src/components/LoginForm.tsx
src/api/routes/auth.ts
```

### Deduplication

Files are only added once:
```bash
if ! grep -qxF "$FILE_PATH" "$TRACKING_FILE"; then
    echo "$FILE_PATH" >> "$TRACKING_FILE"
fi
```

### Size Cap

The tracking file is trimmed only when it grows past **1000** entries, and
is then reduced to the last 500 (deduplicated). The 2x headroom is
deliberate: it keeps the trim race-tolerant so concurrent appenders don't
lose data (`post-edit.sh:98-105`):
```bash
if [ "${LINE_COUNT:-0}" -gt 1000 ]; then
    # (flock-guarded when available)
    sort -u "$TRACKING_FILE" | tail -500 > "$TRACKING_FILE.tmp"
    mv "$TRACKING_FILE.tmp" "$TRACKING_FILE"
fi
```

---

## Beads Integration

### Why Beads?

| Need | Beads Feature |
|------|---------------|
| Persistent memory | Issues stored in git-tracked JSONL |
| Context injection | `bd prime` provides optimized context |
| Dependency tracking | `bd dep add` links related tasks |
| State tracking | Labels (`qa-pending`, `qa-approved`) |
| Progress notes | `--notes` field survives compaction |
| Auto-sync | Git hooks sync on commit/push |

### Structured Notes

Notes use a format that survives Beads compaction:

```
COMPLETED: [Specific deliverables]
IN PROGRESS: [Current work + next step]
BLOCKED: [What's preventing progress]
KEY DECISIONS: [Important architectural choices]
```

This ensures future sessions have context even after compaction.

---

## Security Considerations

### Permissions model

The shipped `settings.json` carries an **allow-list only** — there is no
`permissions.deny` block (`.claude/settings.json:85-99`):
```json
{
  "permissions": {
    "allow": [
      "Read", "Write", "Edit", "MultiEdit", "Glob",
      "Grep", "LS", "Bash", "Task", "WebFetch", "WebSearch"
    ]
  }
}
```

This is deliberate. Principle 3 of the workflow is **full autonomy, no
permission prompts**: specialists must run unattended, so every `deny` rule
would become a future user-facing approval prompt. `CLAUDE.md` explicitly
forbids adding a `deny` block. Dangerous-operation containment is therefore
**not** a settings-level denylist — it comes from the structural guards
(the orchestrator's tool list omits Write/Edit; `prevent-orchestrator-edits.sh`
blocks edits from the orchestrator role; the QA gate blocks completion) plus
the operator's own environment, not from `permissions.deny`.

### Tracking Data

QA tracking data is session-local:
```
.claude/.qa-tracking/
├── changed-files.txt    # Cleared each session
├── approved             # Marker file
└── edit-count           # Counter for batching
```

This data is gitignored and not persisted.

---

## Performance

### Context Efficiency

- `bd prime` produces a compact context block — measured at ~740 tokens on
  this repo (2961 bytes ÷ 4-bytes-per-token heuristic; `bd prime | wc -c`,
  bd 0.47.1, 2026-06-13). The output scales with the number of ready/blocked
  tasks, so a busy repo lands in the low thousands; the point is it is an
  order of magnitude smaller than loading equivalent state through MCP.
- Blocked issues capped at 20 entries
- QA pending issues capped at 10 entries

### File Tracking

- Deduplication prevents unbounded growth
- Tracking file trimmed to the last 500 entries once it exceeds 1000
- Beads updates batched (every 10 edits)

### Git Hooks

- `bd hooks install` adds auto-sync on commit/push

---

## Test Pyramid

The plugin is gated by its own five-tier test pyramid. Each tier catches a
different failure mode; together they form the gate that a change has to
clear before it ships. The full reference is in
[`.claude/tests/README.md`](../.claude/tests/README.md); the architectural
shape is:

| Tier | Lives at | Catches | Cost |
|------|----------|---------|------|
| **L1 — bash unit** | `.claude/scripts/tests/*.sh` | Hook script logic with crafted stdin payloads | Free, <1s |
| **L2 — component** | `.claude/tests/component/specs/*.sh` | Hook pipelines end-to-end with tempdir fixtures | Free, <10s |
| **L3 — vitest unit** | `.claude/tests/e2e/specs/*.unit.spec.ts` | Harness internals: trace schema, normalization, golden compare | Free, <30s |
| **L3 — live e2e** | `.claude/tests/e2e/specs/<fixture>.spec.ts` | Plugin behaviour against the auto-selected model (see `model-select.sh`; whichever model the resolver picks at SessionStart) | ~$5–10 per fixture |

There is no L4 tier. An earlier design had an **L4 daily drift watch** (the
L3-live specs on a `cron` schedule, catching model-output drift on `main`),
but it was **retired**: per phase 0.8 there are no automatic paid runs —
`test.yml` has no `schedule:` trigger, the live tier is `workflow_dispatch`
only, and the goldens are kept as debugging-only references
(`.github/workflows/test.yml:13,19`). A normal PR or push consumes zero API
spend.

### Seven live fixtures

L3-live runs against seven representative fixtures:

1. `node-react-auth` — end-to-end happy path (orchestrator → backend +
   frontend → QA on a JWT-auth feature).
2. `python-django-bug` — bug-fix path with regression test coverage.
3. `go-cli-refactor` — single-specialist refactor with no domain split.
4. `monorepo-frontend-only` — frontend-only delegation in a multi-package
   workspace (proves the orchestrator doesn't fan out to backend
   unnecessarily).
5. `multi-domain-signup` — three-way delegation (backend + frontend +
   devops) on a signup epic.
6. `qa-block-recovery` — QA blocks, specialist iterates, QA re-approves
   (proves the gate's `qa-blocked` → `qa-approved` round-trip).
7. `rubric-revision-loop` — exercises the rubric grader relay (grade →
   `rubric-pending`/`rubric-satisfied` → revision loop).

### Golden cassettes (debugging references)

Each live fixture has a committed `cassettes/golden/<fixture>.jsonl`
capturing the structural fingerprint of a known-good run (tool sequence,
subagent tree shape, hook firing sequence, label transitions, Beads task
IDs created, plugin loader status), with the noise normalised away (tool
durations, costs, token counts, run IDs, raw file contents, free-form
prose). Per phase 0.8 the **live gate is invariant-based, not
cassette-diff-based**: the spec invariants (orchestrator never edits, QA
approval gates Stop, only declared specialists run) are what a live run is
judged against, and the goldens are kept as **debugging-only references**
for inspecting a run by hand — not a PR-time artifact. There is no
PR-time cassette diff because there is no PR-time live run (the live tier
is `workflow_dispatch`-only, zero API spend per PR; see
`.github/workflows/test.yml:13,19`). `cassette-diff` remains available as
a manual debugging aid.

The CI workflow tallies META-TEST pass/fail counts as a distinct line in
the L2 job summary. A META-TEST is a self-test that proves the assertion
is sensitive to the failure it claims to catch — if it stops failing when
the trace is mutated, the test has gone soft and the gate doesn't actually
guard the thing it names.

For the canonical reference (how to add a fixture, refresh a golden, read
a structural diff, and the META-TEST convention), see
[`.claude/tests/README.md`](../.claude/tests/README.md).
