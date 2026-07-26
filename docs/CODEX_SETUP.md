# Codex setup — the optional Sol reviewer lane

> **Moving surface — re-verify before you edit this doc.** Every command below was verified against
> **codex-cli 0.145.0** and **Claude Code 2.1.220** on 2026-07-26, against the live OpenAI docs at
> `learn.chatgpt.com/docs` and against the shipped binary's own model catalog. Two things move fast
> here: the Codex CLI itself (the published config reference already lags the shipped binary — see
> [Set reasoning effort to `max`](#set-reasoning-effort-to-max)), and the fact that *Claude Code
> driving Codex as an MCP server* is community wiring rather than an OpenAI-supported integration.
> `codex mcp-server` is documented upstream and is not labelled experimental, but nothing guarantees
> its tool names or schema across minor versions. If you change this file, re-run the verification
> steps and re-check the live docs first.

---

## 1. What this is, and why it is optional

The plugin's QA gate records an **independent review artifact** for every change set before QA
approves (`.claude/agents/qa.md` section 6-prime). Two lanes can produce that artifact, and they
produce the *same* strict-JSON schema:

| Lane | Reviewer | Cost | Needs this doc |
| --- | --- | --- | --- |
| `claude` (default) | the plugin's own fresh-context Claude review path — QA authors the artifact | none | no |
| `codex` (optional) | **Sol** — OpenAI's flagship model, reached through the Codex CLI's MCP-server mode | PAID, on **your** OpenAI account | yes |

**With Codex absent, nothing changes.** `codex-detect.sh` is a fail-open probe: absence,
misconfiguration, a crash, a hang, or a server that speaks MCP but exposes no `codex` tool all
resolve to `reviewer_lane=claude`, and the review happens on the Claude lane instead. The plugin
proves this rather than asserting it — `.claude/tests/component/specs/reviewer-lane-degradation.sh`
runs the identical record/gate sequence with and without a Codex registration and diffs the outputs
byte-for-byte, and greps `qa-gate.sh`, `verify-before-stop.sh`, and `review-check.sh` for zero
references to Codex or to the lane.

**Sol is advisory, always.** Its artifact is grading-packet item 8. It writes no labels, records no
approval, and the Stop hook does not consider it. The change-set-hash-bound `qa-approved` record
stays the only thing that can release a task. What you get for the money is a second pair of eyes
from a different model family on the same diff — not a second way to ship.

Set this up if you want that second opinion and you are willing to pay for it on your own OpenAI
account. Skip it otherwise; you lose no functionality.

---

## 2. Install the Codex CLI

Pick one. All three install the same binary.

```bash
# npm
npm install -g @openai/codex

# Homebrew
brew install --cask codex

# curl installer (macOS / Linux)
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

Windows (PowerShell):

```powershell
powershell -ExecutionPolicy ByPass -c "irm https://chatgpt.com/codex/install.ps1 | iex"
```

Confirm it is on your `PATH` — the plugin spawns `codex` by name, so a binary that only works
inside your shell's aliases will not be found:

```bash
command -v codex && codex --version     # expect: codex-cli 0.145.0 (or newer)
```

---

## 3. Authenticate — and understand what you are paying for

Two paths. Both work for MCP-server mode; they bill differently.

### Option A — ChatGPT plan (recommended for interactive use)

```bash
codex login          # opens a browser; the browser returns credentials to Codex
codex login status   # expect: Logged in using ChatGPT
```

Usage draws on your ChatGPT plan (Plus / Pro / Business / Edu / Enterprise) credits and follows
your workspace's permissions and admin settings.

### Option B — API key (recommended for scripted or CI-shaped use)

```bash
printenv OPENAI_API_KEY | codex login --with-api-key
codex login status
```

OpenAI bills API-key usage through your OpenAI **Platform** account at standard API rates, not
against ChatGPT plan credits. Some ChatGPT-workspace-dependent features are limited or unavailable
on this path.

### Billing, stated plainly

Sol reviews meter against **your own OpenAI account**, entirely separate from your Anthropic /
Claude Code spend. Nothing in this plugin runs a Sol review automatically:

- The review turn only happens when the reviewer lane is `codex` **and** the root orchestrator runs
  `codex-review.sh` — which is a manual, cost-confirmed, dev-cycle step, exactly like the rubric
  grader's and mutation judge's paid runs (v3 principle 9: *no automatic paid runs*).
- There is no CI wiring, no scheduled job, and no hook that calls it. CI still costs zero dollars on
  both vendors.
- Bounded diligence caps the spend per turn: `.claude/review-config` sets `max_findings`,
  `max_review_iterations`, and a `timeout_seconds` wall clock. A cap-hit stops the turn and is
  recorded in the artifact's `stopped_by` field. The reviewer never loops.

Do not put a key in the repo. `OPENAI_API_KEY` belongs in your shell environment or a secrets
manager; `codex login --with-api-key` reads it from **stdin** precisely so it never lands in your
shell history or in a config file the plugin can see.

---

## 4. Register Codex — at USER scope only

```bash
claude mcp add --scope user codex -- codex -m gpt-5.6-sol mcp-server
```

Read the parts:

| Fragment | Why |
| --- | --- |
| `--scope user` | **Load-bearing — see the warning below.** |
| `codex` (server name) | The probe looks for a server named exactly `codex`. Renaming it disables the lane. |
| `--` | Everything after it is the subprocess command, not a flag for `claude`. |
| `codex -m gpt-5.6-sol mcp-server` | Runs the Codex CLI in stdio MCP-server mode, pinning the model for this invocation. `mcp-server` must come after the flags. |

stdio is the default transport, so no `--transport` is needed. Verify the entry:

```bash
claude mcp get codex
# codex:
#   Scope: User config (available in all your projects)
#   Status: ✔ Connected
#   Type: stdio
#   Command: codex
#   Args: -m gpt-5.6-sol mcp-server
```

> ### Never commit the codex entry to the project `.mcp.json`
>
> **Do not** add `codex` to this repo's `.mcp.json` or to `.claude-plugin/plugin.json`, and do not
> use `--scope project`. A project-scoped entry is committed and shared, so every teammate without
> the Codex CLI installed would get a permanently failed MCP server on every session — a broken
> workspace as the price of an optional feature.
>
> There is a second, mechanical reason. `codex-detect.sh` discovers the registration by reading
> `.mcpServers.codex` from `~/.claude.json`, which is where **user** scope writes. `--scope local`
> writes to `.projects["<path>"].mcpServers` in the same file, and `--scope project` writes to the
> repo's `.mcp.json` — the probe sees neither, reports `method=config-absent`, and silently leaves
> you on the Claude lane. If you registered Codex and the lane still says `claude`, this is almost
> always why.

### Set reasoning effort to `max`

The lane is for hard review, so run the model at its top non-delegating effort. Edit
`~/.codex/config.toml`:

```toml
model_reasoning_effort = "max"
```

Verified on this machine against the shipped catalog: `gpt-5.6-sol` advertises
`low, medium, high, xhigh, max, ultra`, where `max` is described as *"Maximum reasoning depth for
the hardest problems."* Check what your CLI and model actually accept rather than trusting this
line:

```bash
codex debug models | jq -r '.models[] | select(.slug=="gpt-5.6-sol")
                            | .supported_reasoning_levels[] | "\(.effort)\t\(.description)"'
```

Two caveats worth knowing:

- **The published config reference lags the binary.** At the time of writing, the docs list
  `minimal | low | medium | high | xhigh` for `model_reasoning_effort` and do not mention `max`,
  while the shipped 0.145.0 binary and its catalog accept it. If `max` is rejected on your version,
  fall back to `xhigh` — the lane works fine either way.
- **Do not use `ultra`.** The catalog defines it as *"Maximum reasoning with automatic task
  delegation"*, and the CLI's own guidance describes it as the setting for proactive multi-agent
  behaviour. Automatic delegation is exactly what bounded diligence forbids here: the review turn
  has an explicit `risk_threshold` and `stop_condition` and hard caps on findings and iterations,
  and a reviewer that spawns its own sub-work escapes those bounds. `max` gives you the depth
  without the delegation.

---

## 5. Model pinning, and tracking the newest model

The registration above hard-pins `gpt-5.6-sol` with `-m`. That is correct *today* and stale
*tomorrow* — the plugin's own day-zero adoption policy (`model-select.sh` re-resolves Claude pins at
every session start) should extend to the OpenAI side rather than stopping at the vendor boundary.
Two mechanisms, verified:

1. **Ask the catalog which model is current.** `codex debug models` renders the CLI's own catalog,
   ordered by a `priority` field — the CLI's preference order, flagship first. Read the whole list
   before you decide; the one-liner just names the head of it.

   ```bash
   # The full picture (slug, priority, default effort, available efforts):
   codex debug models | jq -r '.models[]
     | select(.visibility=="list")
     | "\(.slug)\tpriority=\(.priority)\tefforts=\(.supported_reasoning_levels|map(.effort)|join(","))"'

   # Just the head of the preference order:
   codex debug models \
     | jq -r '.models | map(select(.visibility=="list")) | sort_by(.priority) | .[0].slug'
   # -> gpt-5.6-sol (as of 2026-07-26)
   ```

   Put that slug in `~/.codex/config.toml` so every Codex invocation — including your interactive
   sessions, not just this MCP registration — tracks it:

   ```toml
   model = "gpt-5.6-sol"
   model_reasoning_effort = "max"
   ```

2. **Keep `-m <slug>` in the registration anyway.** It overrides the config default per invocation,
   and — this is the part that is easy to get wrong — it is also where the plugin reads the model id
   it records in the artifact's `reviewer_model` field. `codex-review.sh` resolves that id from
   `CODEX_MCP_MODEL`, else from a `-m` / `--model` pair in the registered args, else it falls back to
   the literal string `codex`. So a registration with no `-m` still *runs* your `config.toml` model,
   but the audit trail records `reviewer_model: "codex"` — true, and useless six months later.

   Re-running one command when the catalog moves keeps the record precise:

   ```bash
   NEWEST=$(codex debug models \
     | jq -r '.models | map(select(.visibility=="list")) | sort_by(.priority) | .[0].slug')
   claude mcp remove codex -s user
   claude mcp add --scope user codex -- codex -m "$NEWEST" mcp-server
   bash .claude/scripts/codex-detect.sh detect --refresh     # -> codex
   ```

**Check your config default when you set this up.** A `config.toml` carrying an older pin (for
example `model = "gpt-5.2-codex"`, a slug that is no longer even in the catalog) is easy to miss
because the registration's `-m` masks it for MCP runs while every *interactive* `codex` session
keeps using the stale model. Reconcile both.

---

## 6. Verify the lane is live

Four checks, in order. None of them invokes the `codex` tool, so none of them costs money.

```bash
# 1. Claude Code sees the server, at user scope, connected.
claude mcp get codex          # Status: ✔ Connected
#    In an interactive session, `/mcp` lists it the same way. If it shows
#    "⏸ Pending approval", accept workspace trust first (see Troubleshooting).

# 2. Codex itself is authenticated.
codex login status            # Logged in using ChatGPT   (or: using an API key)

# 3. The plugin's probe resolves the lane. `detect` spawns the server, runs
#    initialize + tools/list, requires a tool literally named `codex`, and
#    always kills what it spawned. It never invokes the tool.
bash .claude/scripts/codex-detect.sh detect --refresh
# -> codex

# 4. The recorded artifact says so. (`status` pretty-prints the whole file —
#    reviewer_lane, method, codex_cmd, codex_args, detected_at.)
bash .claude/scripts/codex-detect.sh status | jq -c '{reviewer_lane, method}'
# {"reviewer_lane":"codex","method":"handshake"}
```

After a session restart (SessionStart re-runs detection and refreshes the role artifact), the
statusline reviewer segment collapses to the literal `sol`:

```
 • orch:<orchestrator-role pick> impl:<implementer-role pick> rev:sol
```

The two Claude segments render whatever `model-select.sh` resolved for the `orchestrator` and
`implementer` roles on this machine (`bash .claude/scripts/model-select.sh roles` prints the live
mapping; see `.claude/model-roles`) — they are resolver output, not a pin, and they will change as
your account listing does. Only `rev:sol` is the signal this section is about. `rev:` showing a
Claude model id instead means the lane resolved to `claude` — walk the troubleshooting table.

The SessionStart probe is bounded at 5 seconds and fails open: a Codex binary that is slow to boot
costs you a few seconds of session start and a non-blocking warning, never a hung session. On a
machine without Codex registered the probe short-circuits on the missing registration and spawns no
process at all.

---

## 7. Troubleshooting

| Symptom | `method` in `status` | Cause | Fix |
| --- | --- | --- | --- |
| `/mcp` shows **"⏸ Pending approval"** | n/a | Since Claude Code v2.1.196, self-approved project-scope servers are not spawned in an untrusted workspace. | Re-accept workspace trust (reopen the folder and confirm the prompt, or approve from `/mcp`). User-scope servers are not subject to this, which is another reason to use `--scope user`. |
| Lane stays `claude` right after registering | `config-absent` | Registered at the wrong scope (`local` or `project`), or the server is named something other than `codex`. | `claude mcp remove codex` then re-add with `--scope user` and the exact name `codex`. Confirm with `jq '.mcpServers.codex' ~/.claude.json`. |
| Lane stays `claude`, `codex` runs fine by hand | `handshake-failed` | The registered command is not resolvable in the spawned environment (a shell alias, an nvm-shimmed path missing from the hook's `PATH`), or the server exited during the handshake. | Register an absolute path to the binary: `claude mcp add --scope user codex -- "$(command -v codex)" -m gpt-5.6-sol mcp-server`. |
| Lane stays `claude` on a slow machine | `timeout` | The handshake budget (5s default) expired before `tools/list` came back — a cold binary on a slow disk is the usual cause. | Raise it for the probe: `CODEX_DETECT_TIMEOUT_S=15 bash .claude/scripts/codex-detect.sh detect --refresh`. |
| Lane stays `claude`, server connects | `no-codex-tool` | The server answered but advertises no tool named `codex` — usually a wrapper package rather than the official CLI, or a version that renamed the tool. | Use the official CLI's own `codex mcp-server` mode. Confirm the surface: it should advertise exactly `codex` and `codex-reply`. |
| Everything looks right, lane still `claude` | any | `reviewer_lane=claude` is pinned in `.claude/model-roles`, or `WORKFLOW_REVIEWER_LANE` is exported in your environment. Both intentionally force the free lane. | Remove the pin / unset the variable, or leave it — this is the supported opt-out. |
| Probe prints `claude` with no artifact written | n/a | `jq` is missing. The probe cannot parse a registration without it and resolves to `claude` by design. | Install `jq` (the plugin requires it anyway). |
| A relay round returns exit 5 | n/a | The review turn timed out or the server died mid-turn. No artifact is written. | Nothing to repair — the orchestrator records a degradation note and QA authors the artifact on the Claude lane that round. Raise `timeout_seconds` in `.claude/review-config` if it recurs on large diffs. |

### Graceful degradation, in full

Every failure mode collapses to the same place. This is the contract, not a best effort:

| What happened | Resolved lane | What the workflow does |
| --- | --- | --- |
| No registration (`config-absent`) | `claude` | QA authors the artifact itself. No behavioural change. |
| Server unresolvable or crashed (`handshake-failed`) | `claude` | Same. |
| Handshake timed out (`timeout`) | `claude` | Same. |
| Server present, no `codex` tool (`no-codex-tool`) | `claude` | Same. |
| Lane forced off (`model-roles` / env) | `claude` | Same. |
| Review turn timed out mid-flight (driver exit 5) | `claude`, that round | Degradation note on the task; QA authors the artifact that round. |
| Review iteration above the cap (driver exit 6) | n/a | No paid call. J21 escalation; the loop stops rather than iterating. |

In every row the artifact schema, the `REVIEW-ARTIFACT v1` record grammar, the grading packet's item
8 slot, and the release credential are identical. That is the whole point of the design.

---

## 8. Optional: Playwright for UI verification

When a review's scope includes frontend changes and you have a headless Playwright MCP server
configured on your machine, the reviewer may drive it to check rendered behaviour instead of
reasoning about the diff alone. It is manual-gated and cost-confirmed like every paid activity, it
is **never** a required dependency, and the plugin neither ships nor registers it. With it absent
the review proceeds on the diff, unchanged.

---

## 9. Removing the lane

Two levels, both clean.

```bash
# Keep Codex installed, just stop using it as the reviewer.
printf 'reviewer_lane=claude\n' >> .claude/model-roles
# ...or, for one session only:
export WORKFLOW_REVIEWER_LANE=claude
```

```bash
# Full removal.
claude mcp remove codex -s user
bash .claude/scripts/codex-detect.sh detect --refresh   # -> claude
rm -f .claude/.qa-tracking/reviewer-lane.json           # optional; regenerated on next detect
```

Removal leaves nothing behind in the repo: the registration lived in `~/.claude.json`, the effort
setting in `~/.codex/config.toml`, and the only project-local trace is the gitignored
`reviewer-lane.json` probe artifact. Uninstalling the Codex CLI itself (`npm uninstall -g
@openai/codex`, `brew uninstall --cask codex`, or deleting the downloaded binary) is independent of
the plugin.

---

## Where to read more

- [`AGENTS.md`](AGENTS.md) — the QA independent-review step, the eight-item grading packet, and the
  relay contract.
- [`MCP_SERVERS.md`](MCP_SERVERS.md) — the two servers the plugin *does* ship, and the general MCP
  troubleshooting section.
- `.claude/agents/qa.md` section 6-prime — how QA builds the review request and branches on the lane.
- `.claude/agents/orchestrator.md` section 5c — the `REVIEW-RELAY: review-relay` procedure, the cost
  gate, and the driver's exit-code contract.
- `.claude/review-config` — the one place the bounded-diligence caps live.
- [Codex documentation](https://learn.chatgpt.com/docs/codex) — upstream; the
  [MCP server page](https://learn.chatgpt.com/docs/mcp-server) documents `codex mcp-server` and its
  `codex` / `codex-reply` tools.
