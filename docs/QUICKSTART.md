# Quick Start Guide

Get the Ultimate Workflow Plugin running in 5 minutes.

---

## Step 1: Install Prerequisites

### Beads (Required)

```bash
# macOS / Linux
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash

# Homebrew
brew tap steveyegge/beads && brew install beads

# Windows PowerShell
irm https://raw.githubusercontent.com/steveyegge/beads/main/install.ps1 | iex
```

Verify:
```bash
bd --version
# Should output version number
```

### Other Prerequisites

| Tool | Required | Install |
|------|----------|---------|
| Git | ✅ Yes | [git-scm.com](https://git-scm.com/downloads) |
| jq | ✅ Yes | `brew install jq` / `apt install jq` |

---

## Step 2: Install the Plugin

Navigate to your project directory:

```bash
cd /path/to/your/project
```

### Linux / macOS

```bash
# Option A: Direct install
curl -fsSL https://raw.githubusercontent.com/YOUR_ORG/ultimate-workflow/main/install.sh | bash

# Option B: Download first
wget https://raw.githubusercontent.com/YOUR_ORG/ultimate-workflow/main/install.sh
bash install.sh
```

### Windows

```powershell
# Option A: Direct install
irm https://raw.githubusercontent.com/YOUR_ORG/ultimate-workflow/main/install.ps1 | iex

# Option B: Download first
Invoke-WebRequest -Uri "https://raw.githubusercontent.com/YOUR_ORG/ultimate-workflow/main/install.ps1" -OutFile "install.ps1"
.\install.ps1
```

The installer will:
1. ✅ Check prerequisites (Git, jq, Beads)
2. ✅ Initialize git repository (if needed)
3. ✅ Create `.claude/` directory with agents and scripts
4. ✅ Initialize Beads and install git hooks
5. ✅ Run health check

---

## Step 3: Configure Project Memory

Edit `CLAUDE.md` to describe your project:

```markdown
# Project Memory

## Overview
E-commerce platform with React frontend and Node.js backend.

## Users & Personas
### Primary User: Shopper
- **Who**: Someone buying products online
- **Goal**: Find and purchase items quickly
- **Frustrations**: Slow checkout, unclear pricing

## Critical User Journeys
### Journey 1: Checkout
1. User adds item to cart
2. User proceeds to checkout
3. User enters payment info
4. User sees confirmation

**Failure modes to test**:
- Invalid credit card
- Network error during payment
- Session timeout

## Architecture
- Frontend: React + TypeScript
- Backend: Node.js + Express
- Database: PostgreSQL
- Auth: JWT tokens
```

---

## Step 4: Start Working

```bash
claude
```

Now just describe what you want to build:

```
> Add user authentication with email/password login
```

### What Happens Automatically

1. **Intent Detection**: System recognizes this as a "feature" with "backend" and "frontend" domains

2. **Epic Creation**: Orchestrator creates hierarchical tasks:
   ```
   Epic: User Authentication
   ├─ Backend: Auth API endpoints (backend, qa-pending)
   ├─ Frontend: Login/Register UI (frontend, qa-pending)
   └─ QA: Test auth user journeys (qa)
   ```

3. **Delegation**: Specialists implement each part

4. **File Tracking**: Every edit is tracked for QA review

5. **QA Gate**: When trying to complete:
   ```
   🚫 QA APPROVAL REQUIRED
   15 file(s) changed - ALL require QA review
   ```

6. **QA Review**: You delegate to @qa, who reviews and approves

7. **Completion**: Task closes only after QA approval

---

## Step 5: Verify It's Working

### Check Beads Health

```bash
bd doctor
```

Should show all green checks.

### Check Available Work

```bash
bd ready
```

Shows tasks with no blockers.

### Check Blocked Work

```bash
bd blocked
```

Shows tasks waiting on dependencies.

---

## Common First-Run Issues

### "Beads (bd) not found"

Beads isn't installed or not in PATH. Install it:
```bash
curl -fsSL https://raw.githubusercontent.com/steveyegge/beads/main/scripts/install.sh | bash
```

### "Beads not initialized"

Run in your project directory:
```bash
bd init --quiet
bd hooks install
```

### Scripts not running (Windows)

Scripts require Git Bash. Ensure Git for Windows is installed.

### Hooks not triggering

Check settings.json:
```bash
cat .claude/settings.json | jq '.hooks'
```

Should show SessionStart, UserPromptSubmit, PostToolUse, Stop, SessionEnd hooks.

---

## Next Steps

- 📖 Read [Architecture](ARCHITECTURE.md) to understand how it works
- 🤖 See [Agents Reference](AGENTS.md) for all agent prompts
- 🔧 Check [Beads Integration](BEADS.md) for advanced usage
- ❓ See [Troubleshooting](TROUBLESHOOTING.md) if you hit issues
