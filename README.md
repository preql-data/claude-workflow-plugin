# Ultimate Workflow Plugin

<div align="center">

**Orchestrator-first development workflow for Claude Code with mandatory QA gates**

[![Beads Required](https://img.shields.io/badge/Beads-Required-blue)](https://github.com/steveyegge/beads)
[![Claude Code](https://img.shields.io/badge/Claude%20Code-Compatible-green)](https://claude.ai)
[![License](https://img.shields.io/badge/License-MIT-yellow)](LICENSE)

[Quick Start](#-quick-start) •
[Features](#-features) •
[Architecture](#-architecture) •
[Documentation](#-documentation) •
[FAQ](#-faq)

</div>

---

## 🎯 What Is This?

The Ultimate Workflow Plugin transforms Claude Code into an **orchestrator-first development system** where:

- 🤖 **AI agents are automatically invoked** based on work type and domain
- 🚫 **No code ships without QA approval** - enforced at the system level
- 📊 **Tasks persist across sessions** via Beads integration
- 🔄 **Quality gates cannot be bypassed** - the system blocks completion

### The Problem It Solves

| Without This Plugin | With This Plugin |
|---------------------|------------------|
| AI skips testing "to save time" | Tests are mandatory, enforced by QA gate |
| Context lost between sessions | Beads persists tasks, notes, decisions |
| No visibility into blocked work | `bd blocked` shows what's waiting |
| Flat task lists | Hierarchical epics organize complex features |
| QA is optional | QA approval required to complete ANY task |

---

## ⚡ Quick Start

### Prerequisites

```bash
# 1. Install Beads (REQUIRED)
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# 2. Verify installation
bd --version
```

### Installation

**Linux / macOS:**
```bash
cd /path/to/your/project
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/ultimate-workflow/main/install.sh | bash
```

**Windows (PowerShell):**
```powershell
cd C:\Projects\myproject
irm https://raw.githubusercontent.com/YOUR_ORG/ultimate-workflow/main/install.ps1 | iex
```

### First Run

```bash
cd your-project
claude

# Just describe what you want:
> Add user authentication with JWT tokens
```

The system automatically:
1. Creates a hierarchical epic with subtasks
2. Labels tasks with domains (`backend`, `frontend`) and `qa-pending`
3. Delegates to specialist agents
4. **Blocks completion until @qa approves**

---

## ✨ Features

### 🤖 Automatic Agent Delegation

The orchestrator analyzes your request and delegates to specialists:

| Domain Detected | Agent | Expertise |
|-----------------|-------|-----------|
| API, database, auth | `@backend` | REST/GraphQL, SQL, business logic |
| UI, components, styling | `@frontend` | React, CSS, accessibility |
| CI/CD, Docker, infra | `@devops` | Pipelines, containers, IaC |
| Testing, verification | `@qa` | E2E tests, edge cases, approval |

### 🚫 Mandatory QA Gate

**Every code change requires QA approval.** The Stop hook blocks task completion until:

```bash
# QA adds approval comment
bd comments add $TASK "QA APPROVED: Verified login flow, added 8 E2E tests"

# QA updates labels
bd label remove $TASK qa-pending
bd label add $TASK qa-approved
```

Without approval, the system shows:

```
🚫 QA APPROVAL REQUIRED
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
15 file(s) changed - ALL require QA review
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
REQUIRED: Delegate to @qa NOW
```

### 📊 Full Beads Integration

| Feature | How We Use It |
|---------|---------------|
| `bd prime` | Context injection at session start |
| `bd ready` | Find available work |
| `bd blocked` | Surface blocked issues |
| Hierarchical issues | Epics for complex features |
| Labels | Domain tracking, QA status |
| Structured notes | Survive compaction |
| Git hooks | Auto-sync on commit/push |

### 🔄 Persistent Memory

Notes survive Beads compaction with structured format:

```
COMPLETED: JWT auth endpoints with refresh tokens
IN PROGRESS: None - ready for QA
BLOCKED: None
KEY DECISIONS: Using RS256, 15min access / 7d refresh
```

---

## 🏗 Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER REQUEST                              │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  SessionStart Hook                                               │
│  ├─ Runs bd prime (Beads context)                               │
│  ├─ Shows bd blocked (blocked issues)                           │
│  └─ Injects workflow instructions                                │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  UserPromptSubmit Hook                                           │
│  ├─ Detects work type (bug/feature/improvement)                 │
│  └─ Detects domains (backend/frontend/devops)                   │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  ORCHESTRATOR → Creates epic → Delegates to specialists         │
└─────────────────────────────────────────────────────────────────┘
                                │
              ┌─────────────────┼─────────────────┐
              ▼                 ▼                 ▼
       [@backend]         [@frontend]        [@devops]
              │                 │                 │
              └─────────────────┼─────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  PostToolUse Hook → Tracks all changed files                    │
└─────────────────────────────────────────────────────────────────┘
                                │
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Stop Hook - QA GATE                                             │
│  ├─ Checks for qa-approved label OR "QA APPROVED" comment       │
│  ├─ If NO: BLOCKS completion                                     │
│  └─ If YES: Allows completion                                    │
└─────────────────────────────────────────────────────────────────┘
                                │
                    ┌───────────┴───────────┐
                    ▼                       ▼
            [Not Approved]            [Approved]
                    │                       │
                    ▼                       ▼
              Must delegate           ✅ COMPLETE
              to @qa first            Task closes
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the complete architecture diagram.

---

## 📁 Project Structure

```
your-project/
├── .beads/                      # Beads database
├── .claude/
│   ├── agents/                  # AI agent definitions
│   │   ├── orchestrator.md      # Main coordinator
│   │   ├── backend.md           # API/DB specialist
│   │   ├── frontend.md          # UI/UX specialist
│   │   ├── devops.md            # CI/CD specialist
│   │   └── qa.md                # Quality gate
│   ├── scripts/                 # Hook scripts
│   ├── hooks/                   # Hook configuration
│   ├── skills/                  # Workflow documentation
│   └── settings.json            # Claude Code settings
├── CLAUDE.md                    # Project memory
└── .gitignore
```

---

## 📖 Documentation

| Document | Description |
|----------|-------------|
| [Quick Start](docs/QUICKSTART.md) | Get running in 5 minutes |
| [Architecture](docs/ARCHITECTURE.md) | Deep dive into system design |
| [Agents Reference](docs/AGENTS.md) | All agent prompts documented |
| [Hooks Reference](docs/HOOKS.md) | Hook scripts explained |
| [Beads Integration](docs/BEADS.md) | How we use Beads |
| [Workflow & Labels](docs/WORKFLOW.md) | Labels, statuses, lifecycle |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | Common issues & fixes |

---

## 🏷️ Labels Convention

| Label | Meaning | Set By |
|-------|---------|--------|
| `backend` | Backend domain work | Orchestrator |
| `frontend` | Frontend domain work | Orchestrator |
| `devops` | DevOps domain work | Orchestrator |
| `qa-pending` | Awaiting QA review | Domain agents |
| `qa-approved` | QA has signed off | @qa agent |
| `bug` | Bug fix | Auto-detected |
| `feature` | New feature | Auto-detected |

---

## 🔧 Beads Commands Cheat Sheet

```bash
# Finding Work
bd ready                      # Tasks with no blockers
bd blocked                    # Tasks waiting on dependencies
bd list --label qa-pending    # Awaiting QA

# Creating Tasks
bd create "Title" -t task -p 1 -l backend,qa-pending
bd create "Epic" -t epic -p 1 --description "..."

# QA Approval
bd comments add $ID "QA APPROVED: summary"
bd label remove $ID qa-pending
bd label add $ID qa-approved

# Health
bd doctor                     # Check Beads health
```

---

## ❓ FAQ

<details>
<summary><b>Why is Beads required?</b></summary>

Beads provides persistent memory across sessions, dependency tracking, and labels for QA tracking. Without it, context is lost between sessions.

</details>

<details>
<summary><b>Can I skip the QA gate?</b></summary>

**No.** The QA gate is enforced at the system level. The only ways to complete are: QA approval, user interrupt (`Ctrl+C`), or no code changes.

</details>

<details>
<summary><b>What if I'm working alone?</b></summary>

You still delegate to `@qa`, which is an AI agent that reviews your changes and writes tests.

</details>

<details>
<summary><b>Does this work with existing projects?</b></summary>

Yes! Run the installer and choose option 2 (Update mode) to preserve existing configurations.

</details>

---

<div align="center">

[Report Bug](../../issues) • [Request Feature](../../issues) • [Documentation](docs/)

</div>
