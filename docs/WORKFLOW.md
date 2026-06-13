# Workflow & Labels

Complete guide to the task lifecycle and label conventions.

---

## Task Lifecycle

```
┌──────────────────────────────────────────────────────────────────────┐
│                           TASK LIFECYCLE                              │
└──────────────────────────────────────────────────────────────────────┘

    ┌─────────┐
    │ CREATED │  bd create "Title" -t type -p priority -l labels
    └────┬────┘
         │
         ▼
    ┌─────────────┐
    │    OPEN     │  Status: open, Labels: [domain, qa-pending]
    └──────┬──────┘
           │  bd update $ID --status in_progress
           ▼
    ┌─────────────┐
    │ IN PROGRESS │  Specialist is working on it
    └──────┬──────┘
           │
           ├── Work complete, needs QA ──────────────────────┐
           │                                                  │
           ▼                                                  ▼
    ┌─────────────┐                               ┌─────────────────┐
    │  QA REVIEW  │  Labels: [domain, qa-pending] │  BLOCKED        │
    └──────┬──────┘                               │  (dependencies) │
           │                                       └─────────────────┘
           ├── Approved ───────────────┐
           │                           │
           ├── Blocked ────┐           │
           │               ▼           │
           │    ┌─────────────────┐    │
           │    │ QA BLOCKED      │    │
           │    │ (issues found)  │    │
           │    └────────┬────────┘    │
           │             │             │
           │    Fix issues, retry      │
           │             │             │
           └─────────────┘             │
                                       ▼
                              ┌─────────────────┐
                              │   QA APPROVED   │  Labels: [domain, qa-approved]
                              └────────┬────────┘
                                       │  bd close $ID --reason "..."
                                       ▼
                              ┌─────────────────┐
                              │     CLOSED      │  Task complete
                              └─────────────────┘
```

---

## Status Values

| Status | Meaning | Who Sets It |
|--------|---------|-------------|
| `open` | Ready to be worked on | System (default) |
| `in_progress` | Someone is actively working | Agent claiming task |
| `blocked` | Waiting on dependencies | System (automatic) |
| `closed` | Complete | Agent after QA approval |

### Checking Status

```bash
# All open tasks
bd list --status open

# In progress
bd list --status in_progress

# Blocked
bd blocked

# Closed
bd list --status closed
```

---

## Labels

### Domain Labels

Identify which specialist should work on a task.

| Label | Domain | Examples |
|-------|--------|----------|
| `backend` | Server-side | APIs, database, auth, business logic |
| `frontend` | Client-side | UI components, styling, UX |
| `devops` | Infrastructure | CI/CD, Docker, deployment |
| `qa` | Testing | Test writing, QA ownership |

### QA Status Labels

Track QA review state.

| Label | Meaning | Who Sets |
|-------|---------|----------|
| `qa-pending` | Awaiting QA review | Domain agents |
| `qa-gate-entered` | QA has claimed the task; gate is armed | `qa-gate.sh enter` |
| `qa-approved` | QA has signed off | @qa agent (via `qa-gate.sh approve` / `choose approve`) |
| `qa-blocked` | QA found issues; specialist must fix | @qa agent (via `qa-gate.sh block`) |
| `qa-escalated` | Iteration cap reached (spec 0.2); awaiting a J21 decision | `verify-before-stop.sh` (auto, on first cap hit) |
| `qa-deferred` | J21 option 4 recorded (spec 0.2); Stop hook now allows | `qa-gate.sh choose defer` OR `verify-before-stop.sh` auto-defer |
| `rubric-pending` | Rubric-grader cycle armed (spec Phase A); awaiting a grader verdict | `qa-gate.sh enter` (auto, alongside qa-gate-entered) |
| `rubric-satisfied` | Rubric-grader returned `satisfied`; the verdict-backed audit trail for QA approval | `qa-gate.sh grade-record` (when the verdict JSON is `satisfied`) |

### Work Type Labels

Categorize the type of work.

| Label | Type | Keywords |
|-------|------|----------|
| `bug` | Bug fix | error, fix, broken, crash |
| `feature` | New feature | add, create, build, new |
| `improvement` | Enhancement | improve, optimize, refactor |

### Using Labels

```bash
# Add labels when creating
bd create "Fix login" -t bug -p 1 -l bug,backend,qa-pending

# Add labels later
bd label add $ID qa-pending

# Remove labels
bd label remove $ID qa-pending

# Filter by label
bd list --label backend
bd list --label qa-pending
bd list --label qa-approved
```

---

## Label Transitions

### Domain Task Flow

```
Created with:        [backend, qa-pending]
                            │
During work:         [backend, qa-pending]
                            │
After QA approval:   [backend, qa-approved]
```

### QA Label Flow

```
Implementation done:     qa-pending added
                              │
                              ▼
QA starts review:       qa-pending (still)
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                                           ▼
    Issues found                              Approved
        │                                           │
        ▼                                           ▼
    qa-pending (still)                   qa-pending → qa-approved
        │
        │ (fix issues)
        │
        └───────────────────────────────────────────┘
```

---

## Complete Workflow Example

### 1. User Request

```
"Add user authentication with email/password"
```

### 2. Orchestrator Creates Epic

```bash
# Create epic
EPIC=$(bd create "Epic: User Authentication" -t epic -p 1 \
    --description "Email/password login with JWT tokens" \
    --json | jq -r '.id')
# Result: bd-abc123
```

### 3. Create Subtasks

```bash
# Backend task
BACKEND=$(bd create "Backend: Auth API endpoints" -p 1 \
    --parent $EPIC \
    --description "POST /auth/login, /auth/register, /auth/refresh" \
    -l backend,qa-pending --json | jq -r '.id')
# Result: bd-abc123.1

# Frontend task
FRONTEND=$(bd create "Frontend: Login/Register UI" -p 1 \
    --parent $EPIC \
    --description "Login form, register form, password reset" \
    -l frontend,qa-pending --json | jq -r '.id')
# Result: bd-abc123.2

# QA task
QA=$(bd create "QA: Test auth user journeys" -p 1 \
    --parent $EPIC \
    -l qa --json | jq -r '.id')
# Result: bd-abc123.3
```

### 4. Set Dependencies

```bash
# QA depends on implementation
bd dep add $QA $BACKEND
bd dep add $QA $FRONTEND
```

### 5. View Structure

```bash
bd dep tree $EPIC
```

Output:
```
bd-abc123: Epic: User Authentication [epic] [P1] (open)
├─ bd-abc123.1: Backend: Auth API endpoints [P1] (open)
│   Labels: backend, qa-pending
├─ bd-abc123.2: Frontend: Login/Register UI [P1] (open)
│   Labels: frontend, qa-pending
└─ bd-abc123.3: QA: Test auth user journeys [P1] (blocked)
    Labels: qa
    Blocked by:
    ↳ bd-abc123.1
    ↳ bd-abc123.2
```

### 6. Backend Implementation

```bash
# Claim task
bd update $BACKEND --status in_progress

# Update notes during work
bd update $BACKEND --notes "IN PROGRESS: Implementing /auth/login endpoint"

# ... implement ...

# Mark complete
bd update $BACKEND --notes "COMPLETED: Auth endpoints /login, /register, /refresh
KEY DECISIONS: JWT with RS256, 15min access token, 7d refresh token
IN PROGRESS: None - ready for QA"
```

### 7. Frontend Implementation

```bash
# Claim task
bd update $FRONTEND --status in_progress

# ... implement ...

# Mark complete
bd update $FRONTEND --notes "COMPLETED: Login form, register form, password visibility toggle
KEY DECISIONS: react-hook-form for validation, Zod schema
IN PROGRESS: None - ready for QA"
```

### 8. QA Review

Now `bd-abc123.3` is unblocked:

```bash
bd ready
# Shows: bd-abc123.3: QA: Test auth user journeys

# Claim QA task
bd update $QA --status in_progress

# ... review and test ...

# APPROVE — qa-gate.sh approve is atomic: it sets the qa-approved label
# (the sole gate signal), drops qa-pending/qa-gate-entered, and records the
# summary as an audit comment in one step. The summary text is free-form.
bash .claude/scripts/qa-gate.sh approve $BACKEND "Auth API verified.
- Login with valid/invalid credentials
- Token refresh flow
- Rate limiting works
Tests: 8 E2E tests added"

bash .claude/scripts/qa-gate.sh approve $FRONTEND "Login UI verified.
- Form validation
- Error messages
- Password visibility
- Accessibility (keyboard, screen reader)
Tests: 12 component tests added"

# Close QA task
bd update $QA --notes "COMPLETED: Full auth flow verified"
bd close $QA --reason "Auth testing complete"
```

### 9. Close Implementation Tasks

```bash
bd close $BACKEND --reason "Auth API implemented and QA approved"
bd close $FRONTEND --reason "Auth UI implemented and QA approved"
bd close $EPIC --reason "User authentication complete"
```

---

## Priority Levels

| Priority | Label | Use For |
|----------|-------|---------|
| P0 | `-p 0` | Critical/urgent, production down |
| P1 | `-p 1` | High priority, current sprint |
| P2 | `-p 2` | Normal priority |
| P3 | `-p 3` | Low priority, nice to have |
| P4 | `-p 4` | Backlog |

```bash
# Create P0 task
bd create "Hotfix: Login broken" -t bug -p 0 -l bug,backend,qa-pending

# Filter by priority
bd list --priority 0
bd ready --priority 1
```

---

## Task Types

| Type | Flag | Use For |
|------|------|---------|
| `task` | `-t task` | General work item |
| `bug` | `-t bug` | Bug fix |
| `feature` | `-t feature` | New feature |
| `epic` | `-t epic` | Container for related tasks |

```bash
bd create "Fix login" -t bug -p 1
bd create "Add dark mode" -t feature -p 2
bd create "Epic: Auth System" -t epic -p 1
```

---

## Blocked Tasks

Tasks become blocked when dependencies aren't complete.

### View Blocked Tasks

```bash
bd blocked
```

Output:
```
bd-xyz789: Deploy to production [P0] [blocked]
  Blocked by:
  ↳ bd-abc123: Run integration tests [P1] [in_progress]
  ↳ bd-def456: Fix failing tests [P1] [open]
```

### Understanding Blockers

```bash
# View full details
bd show bd-xyz789

# See dependency tree
bd dep tree bd-xyz789
```

### Resolving Blockers

Complete the blocking tasks first:
1. Fix `bd-def456` (failing tests)
2. Complete `bd-abc123` (integration tests)
3. `bd-xyz789` becomes unblocked automatically

---

## QA Gate Enforcement

The Stop hook enforces QA approval:

### What Gets Blocked

- Any task with reviewable code-file changes that does **not** carry the
  `qa-approved` label.

### What Allows Completion

Exactly two paths (`verify-before-stop.sh:982-992` and the F1 fast path at
`:616-691`):

- The task has the **`qa-approved` label** (the single source of truth, set
  by `qa-gate.sh approve`), OR
- **Nothing reviewable changed** — every changed path is doc-only, Beads /
  gate bookkeeping (`.beads/*.jsonl`, `beads.db`, `.qa-tracking/*`), or the
  change-set is empty after the build-artifact denylist (the F1 fast path,
  which auto-approves with an audited comment).

There is **no** "comment containing QA APPROVED" path. The comment-text
fallback was deleted (`verify-before-stop.sh:20-22`); a comment whose body
says "QA APPROVED" does not release the gate. Likewise there is no marker
file: `.qa-tracking/approved` is never read.

### Bypass (Emergency Only)

User can `Ctrl+C` to interrupt, but this is tracked and visible.

---

## Best Practices

### 1. Always Use Labels

```bash
# Good
bd create "Fix API timeout" -t bug -p 1 -l bug,backend,qa-pending

# Bad (no labels)
bd create "Fix API timeout" -t bug -p 1
```

### 2. Update Notes Regularly

```bash
# During work
bd update $ID --notes "IN PROGRESS: Fixing timeout handling"

# When done
bd update $ID --notes "COMPLETED: Added timeout config, retry logic
KEY DECISIONS: 30s timeout, 3 retries with exponential backoff"
```

### 3. Use Hierarchical Issues for Features

```bash
# Good - organized
EPIC=$(bd create "Epic: Payment Integration" -t epic -p 1 --json | jq -r '.id')
bd create "Backend: Stripe API" --parent $EPIC -l backend,qa-pending
bd create "Frontend: Checkout UI" --parent $EPIC -l frontend,qa-pending

# Bad - flat
bd create "Stripe API" -l backend,qa-pending
bd create "Checkout UI" -l frontend,qa-pending
```

### 4. Close with Reason

```bash
# Good
bd close $ID --reason "Implemented Stripe integration, verified with test transactions"

# Bad
bd close $ID
```

### 5. Link Discovered Bugs

```bash
# When finding bugs during other work
bd create "Bug: Edge case in validation" -t bug -p 1 \
    --deps discovered-from:$CURRENT_TASK \
    -l bug,qa-pending
```
