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

> **One slug, one source.** Every literal `gpt-5.6-sol` below is the same pin: the head of the Codex
> CLI's own preference order on 2026-07-26 (codex-cli 0.145.0), resolved by the one-liner in
> [§5](#5-model-pinning-and-tracking-the-newest-model). Everywhere a literal would be decoration
> rather than something you copy, the examples read `<slug>` — substitute whatever §5 resolves on your
> machine. When the catalog moves, run [§5's recipe](#5-model-pinning-and-tracking-the-newest-model)
> instead of editing this page by hand. Inside a command you would actually paste, the placeholder is
> spelled `YOUR_SLUG` instead: a shell reads `<slug>` as two redirections (`< slug` and `>`), so it
> would never reach `codex` as an argument.

```bash
claude mcp add --scope user codex -- codex -m gpt-5.6-sol mcp-server
```

Read the parts:

| Fragment | Why |
| --- | --- |
| `--scope user` | **Load-bearing — see the warning below.** |
| `codex` (server name) | The probe looks for a server named exactly `codex`. Renaming it disables the lane. |
| `--` | Everything after it is the subprocess command, not a flag for `claude`. |
| `codex -m <slug> mcp-server` | Runs the Codex CLI in stdio MCP-server mode. **`-m` does not choose the model here** — in `mcp-server` mode the model comes from `~/.codex/config.toml` ([§5](#5-model-pinning-and-tracking-the-newest-model)); `-m` is what the plugin records as the artifact's `reviewer_model`, so keep it and keep it in sync. `mcp-server` must come after the flags, and do **not** add `-p` — see [If you use Codex profiles](#if-you-use-codex-profiles). |

stdio is the default transport, so no `--transport` is needed. Verify the entry:

```bash
claude mcp get codex
# codex:
#   Scope: User config (available in all your projects)
#   Status: ✔ Connected
#   Type: stdio
#   Command: codex
#   Args: -m <slug> mcp-server
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

The lane is for hard review, so run the model at its top non-delegating effort. The file to edit is
`~/.codex/config.toml` — the same file that pins the model, so write **both** keys while you are in
there. This is the whole minimal config the lane needs, and it is the same file
[§5](#5-model-pinning-and-tracking-the-newest-model) shows, not a second one:

```toml
model = "gpt-5.6-sol"           # drives the RUN — §5 resolves this slug for you
model_reasoning_effort = "max"
```

> **Setting only the effort key leaves the model unpinned.** Whatever the CLI defaults to then
> reviews your diffs, while the artifact records the registration's `-m` slug — the exact
> record-versus-run mismatch [§5](#5-model-pinning-and-tracking-the-newest-model) warns about. Write
> both keys. `codex doctor --json | jq -r '.checks["config.load"].details.model // empty'` prints the
> literal `<default>` when nothing is pinned, which is the cheapest way to catch this.

If you already have a `config.toml`, back it up before your first edit. This is the most valuable
backup you will make — it is the only copy of your *pre-lane* state, and it is what
[§9](#9-removing-the-lane) restores when you remove the lane:

```bash
BAK=~/.codex/config.toml.bak-$(date +%Y%m%d-%H%M%S)
cp -p ~/.codex/config.toml "$BAK" && ls -l "$BAK" ||
  echo "NO BACKUP — fix that before editing anything"
```

Second granularity rather than day granularity, and `&& ls -l "$BAK"` rather than a bare `cp`, for one
reason each: a same-day re-run of a day-stamped command overwrites the pristine copy with an
already-edited one, and a `cp` whose failure you did not read is indistinguishable from a backup you
never made. Note that it confirms **the one file it just wrote**, not `…bak-*` — a glob would also
match unrelated backups you made by hand and could reassure you about the wrong file. Every backup in
this doc uses the same `%Y%m%d-%H%M%S` suffix, which is what lets the later sections identify their own
backups and leave yours alone.

Verified on this machine against the shipped catalog: `gpt-5.6-sol` advertises
`low, medium, high, xhigh, max, ultra`, where `max` is described as *"Maximum reasoning depth for
the hardest problems."* Ask your own CLI about your own pin rather than trusting this line:

```bash
SLUG=$(codex doctor --json | jq -r '.checks["config.load"].details.model // empty')
codex debug models | jq -r --arg s "$SLUG" '.models[] | select(.slug==$s)
                            | .supported_reasoning_levels[] | "\(.effort)\t\(.description)"'
# No output? Echo "$SLUG": `<default>` means you have not pinned a model yet, and
# empty means the jq path moved (see "If these commands or jq paths moved").
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

The registration above hard-pins one slug with `-m`, and [§4's `config.toml`](#set-reasoning-effort-to-max)
pins the same one. That is correct *today* and stale *tomorrow* — the plugin's own day-zero adoption
policy (`model-select.sh` re-resolves Claude pins at every session start) should extend to the OpenAI
side rather than stopping at the vendor boundary. Two mechanisms, verified:

1. **Ask the catalog which model is current.** `codex debug models` renders the CLI's own catalog,
   ordered by a `priority` field — the CLI's preference order, flagship first. Read the whole list
   before you decide; the one-liner just names the head of it.

   ```bash
   # The full picture (slug, priority, default effort, available efforts):
   codex debug models | jq -r '.models[]
     | select(.visibility=="list")
     | "\(.slug)\tpriority=\(.priority)\tefforts=\(.supported_reasoning_levels|map(.effort)|join(","))"'

   # Just the head of the preference order. `// empty` matters: without it, an empty
   # catalog or a moved field makes `jq -r` print the four-character string `null`,
   # which every downstream test treats as a real slug.
   codex debug models \
     | jq -r '.models | map(select(.visibility=="list")) | sort_by(.priority)
              | .[0].slug // empty'
   # -> gpt-5.6-sol (as of 2026-07-26); blank means the catalog surface moved
   ```

   Put that slug in `~/.codex/config.toml` so every Codex invocation — including your interactive
   sessions, not just this MCP registration — tracks it. This is the same two-key file
   [§4](#set-reasoning-effort-to-max) already showed whole, not a second one:

   ```toml
   model = "<the slug the command above resolved>"
   model_reasoning_effort = "max"
   ```

   You write that line yourself — point 2 is the full procedure, and
   [Why this sweep is not automated](#why-this-sweep-is-not-automated) explains why the doc no longer
   ships a script to do it for you.

2. **Keep `-m <slug>` in the registration — but know what it does and what it does not do.** It does
   **not** select the model: verified live on codex-cli 0.145.0, `mcp-server` mode ignores the
   registration's `-m`, and a `-c model=…` override does not stick either. `config.toml` wins. What
   `-m` is genuinely for is the audit trail — it is where the plugin reads the model id it records in
   the artifact's `reviewer_model` field. `codex-review.sh` resolves that id from `CODEX_MCP_MODEL`,
   else from a `-m` / `--model` pair in the registered args, else it falls back to the literal string
   `codex`. So a registration with no `-m` still *runs* your `config.toml` model, but the audit trail
   records `reviewer_model: "codex"` — true, and useless six months later.

   The corollary is the trap: because `-m` feeds the RECORD while `config.toml` drives the RUN, a
   mismatch between the two produces an artifact naming a model that did not perform the review. So
   the sweep has to touch **both** sides, in that order — config first, verify, then the registration.
   The procedure below does exactly that; running only the `claude mcp` half is how you end up in the
   mismatch state this paragraph is warning about.

   Re-run this when the catalog moves. Every step below is free — no model call anywhere in it — and
   nothing here rewrites your config for you. The write is a one-line edit you make yourself, and the
   oracle is Codex's own TOML parser. [Why this is not automated](#why-this-sweep-is-not-automated)
   explains that choice; it was not the original design.

   ```bash
   # 1. Resolve the head of the CLI's own preference order. Read-only.
   #    `// empty` matters: without it a moved or empty catalog surface prints the
   #    four-character string `null`, which reads like a slug and is not one.
   codex debug models |
     jq -r '.models | map(select(.visibility=="list")) | sort_by(.priority)
            | .[0].slug // empty'
   # -> gpt-5.6-sol.  BLANK means the catalog surface moved — stop, do not guess.
   ```

   ```bash
   # 2. Back up, and CHECK that the backup landed before you touch the original.
   #    A `cp` whose failure you did not read is indistinguishable from a backup you
   #    never made. Keep the name in $BAK; nothing here searches for it later.
   BAK=~/.codex/config.toml.bak-$(date +%Y%m%d-%H%M%S)
   cp -p ~/.codex/config.toml "$BAK" && ls -l "$BAK" || echo "NO BACKUP — stop here"
   ```

   **3. Edit `~/.codex/config.toml` by hand.** Set the top-level `model` to the slug from step 1 —
   one line — and leave everything else alone. If your pin currently sits inside a `[profiles.…]`
   table, move it to the top level while you are in there
   ([why](#if-you-use-codex-profiles)). This is the whole write.

   ```bash
   # 4. Verify, with the parser rather than with your own idea of the file. Two
   #    questions, and they fail independently.

   #    (a) Does it still parse, and does it resolve the slug you meant?
   #        `--strict-config` is a TOP-LEVEL flag — before `doctor`, not after it,
   #        where it errors with "unexpected argument".
   codex --strict-config doctor --json |
     jq -r '.checks["config.load"] | "\(.status)\t\(.details.model // "-")"'
   # -> ok<TAB>gpt-5.6-sol

   #    (b) Did anything ELSE change? Capture the comparison and check its EXIT
   #        STATUS, not only its output: `diff` exits 0 identical, 1 differs, 2 or
   #        more "could not compare at all". Empty output on its own cannot tell
   #        "nothing else moved" from "never compared anything". See the note under
   #        this block for why a file test on $BAK is not enough.
   D=$(diff "$BAK" ~/.codex/config.toml 2>&1); rc=$?
   if [ "$rc" -gt 1 ]; then
       printf 'CANNOT COMPARE (diff exit %s) — this check answers nothing:\n%s\n' "$rc" "$D"
   else
       printf '%s\n' "$D"                                  # read this yourself
       printf '%s\n' "$D" | grep -E '^[<>]' |
         grep -vE '^[<>] *model[[:space:]]*='              # NO OUTPUT = pass
   fi
   ```

   Question (a) cannot see content loss and question (b) cannot see corruption, which is why both are
   here. Measured on the real binary: a config reduced to nothing but the correct `model` line
   **passes** (a) — it is valid TOML resolving exactly the slug you asked for — while (b) prints the
   lines it lost. Conversely a duplicated top-level `model` key, the shape you get if you add the new
   line and forget to delete the old one, is **refused** by (a) while (b) sees only `model` lines
   change. Neither subsumes the other.

   **Why (b) checks `diff`'s status rather than testing `$BAK`.** Because a comparison has two operands,
   and "silence means pass" fails on both of them. Enumerated: fourteen states of the pair, of which
   nine make `diff` exit 2 while printing nothing to stdout — a backup that is missing, a directory,
   unreadable, a dangling symlink, or a symlink to any of those, **and** a `config.toml` that is
   missing, unreadable, or a directory. A guard of `[ -f "$BAK" ] && [ -r "$BAK" ]` closes the first six
   and leaves the last three wide open, which is how you end up fixing an instance instead of a class.
   Checking the status covers all nine with one mechanism and needs no taxonomy of file types. Three
   residuals are worth knowing rather than guarding. An **empty** backup makes (b) report every line as
   added — a false alarm, not a false pass, and the raw diff above it shows you why. A backup that is a
   **FIFO** makes `diff` block forever, which is unpleasant but announces itself, unlike a silent wrong
   answer. And the filtered line is only as trustworthy as `grep` itself: a `grep` that cannot run
   produces no output, which is again this check's pass condition. That one is deliberately not guarded,
   because a check written in `grep` cannot detect `grep`'s absence from inside itself, and because the
   fix is structural rather than defensive — **the raw diff is printed first and unconditionally, so the
   filtered result is never your only evidence.** Read the diff. The `grep` is there to save you from
   missing something in a long one, not to be the thing you trust.

   Do not check the diff by counting its lines, in either direction. The count is not stable: the same
   correct edit prints a different number depending on whether your file ends in a newline, and the
   range markers move with the position of the old key. An earlier revision of this doc asserted
   "exactly two", which turns a healthy sweep into a false alarm and invites rolling back correct work.
   The `grep` above is the invariant that is actually true, and it is true regardless of formatting.

   ```bash
   # 5. Only once BOTH checks pass: bring the RECORD side into line. Read the slug
   #    back out of the RESOLVED config so the record cannot disagree with the run,
   #    and shape-check it — `-m null` is a registration naming a model that does
   #    not exist, and `<default>` means you never pinned anything.
   NEWEST=$(codex doctor --json |
            jq -r '.checks["config.load"].details.model // empty')
   case "$NEWEST" in
       ''|null|'<default>') echo "config resolves no usable model — fix that first" ;;
       *[!A-Za-z0-9._-]*)   echo "implausible model '$NEWEST' — not registering" ;;
       *) claude mcp remove codex -s user
          claude mcp add --scope user codex -- codex -m "$NEWEST" mcp-server ;;
   esac

   # 6. Re-probe the lane.
   bash .claude/scripts/codex-detect.sh detect --refresh     # -> codex
   ```

   **If it went wrong**, `$BAK` is the whole undo — restore it through a temp file and a rename rather
   than copying over the live config. Measured on macOS: a `cp` whose source delivered only part of its
   data left the destination holding that partial content **and exited 0**, so a plain
   `cp backup config.toml` can hand you a silently truncated config plus a success code. Same-directory
   temp plus `mv` is a rename, which either happens completely or not at all.

   ```bash
   t=$(mktemp ~/.codex/config.toml.restore.XXXXXX) &&
     cp -p "$BAK" "$t" && mv "$t" ~/.codex/config.toml ||
     echo "restore did not complete — config.toml untouched"
   ```

   Delete the backup with `rm "$BAK"` once steps 4 and 6 both read the way you want — named, not
   globbed, so you cannot take a hand-made backup with it. One stale `.bak` per sweep is how
   `~/.codex` fills with files you can no longer tell apart.

**Check your config default when you set this up — it is the one that actually runs.** A
`config.toml` carrying an older pin (for example `model = "gpt-5.2-codex"`) is easy to miss and is
the single most likely reason a correctly-registered lane still fails: the registration's `-m` does
*not* mask it, and on a ChatGPT-account login that particular slug is rejected by the backend
outright. This is exactly what broke the first live Sol turn during the v4.0.0 validation — see
[The model pin lives in `config.toml`](#the-model-pin-lives-in-configtoml-not-in-the-registration).

### Why this sweep is not automated

Earlier revisions of this section shipped a `codex_pin_newest` shell function that did steps 1-4 for
you: resolve the slug, back the file up, filter the old `model` line out, write a new one, validate,
and install atomically. It was removed deliberately, and the reasoning is worth more to you than the
function was.

Five review rounds found **thirteen defects in it**, eleven of them in the automation and two in the
surrounding prose. Grouped by the mechanism at fault: three in backup naming and selection, two in the
write path, two in the line filter, two in the validation oracle, one in leftover shell state, one in
the catalog read. Every mechanism in that list except the last exists *only* to do the one thing you
can do by hand in one line — and each fix round added machinery that the next round found defects in.
The last round's example is the one to remember: an aborted re-run left a stale backup path in a shell
variable, the verification could not tell it was stale, and following the doc's own remedy rolled a
*correct* config back to `model = "gpt-5.2-codex"` — the exact broken pin this whole section exists to
prevent.

The trade is explicit. You do one extra edit by hand. In exchange the failure classes are not fixed but
**absent**: no glob, so nothing can match a file you did not mean; no filter, so nothing can delete a
line it misread; no oracle derived from that filter, so validation cannot agree with a broken mutation;
no state between steps, so nothing can go stale; nothing writing your config, so nothing can leave it
half-written. What remains is a read-only command, a one-line edit, and Codex's own parser as the judge.

There is also a durability argument. That function could not be regression-tested where this repository
can see it — the whole blast radius is your home directory, which no CI job touches — so it would have
rotted quietly as `codex-cli` moved, and the banner at the top of this page says how fast that happens.
`codex --strict-config doctor` is one command with one job, and if it moves,
[If these commands or jq paths moved](#if-these-commands-or-jq-paths-moved) already tells you how to
find where it went.

**If you script this yourself** — a reasonable thing to want, and the reason the findings are recorded
here rather than deleted with the code — these are the six traps that actually bit, each one measured
rather than theorised:

- **`config.toml.bak-[0-9]*` is not a dated pattern.** In a glob that is *one digit followed by
  anything*, so it also matches `config.toml.bak-9-keep` and `config.toml.bak-20260728-personal`. It
  selected the wrong baseline and, in an `rm`, put operator files in the kill list. Match the format
  you actually create: `bak-` then eight digits, a dash, six digits, written out literally. A digit
  class held in a shell variable will not do — zsh does not glob-expand the result of a parameter
  expansion, so the same line behaves differently in the two shells your readers use.
- **`jq -r` renders a missing field as the four-character string `null`.** It is non-empty, so it
  passes `[ -n "$x" ]`, and it will be written into a config or a registration as if it were a model
  name. Use `// empty` and then check the value's *shape*, not merely that it exists.
- **A validation built from the mutation's own filter is not a validation.** Two runs of one
  expression agree even when the expression is broken: with `grep` stubbed to fail, a mirror check
  compared a five-line baseline against a one-line wiped candidate and reported them identical. Judge
  the result with something that does not share the mutation's assumptions — for a TOML file, a TOML
  parser.
- **Line filters cannot see TOML multiline strings.** A `"""…"""` block containing a line that reads
  like `model = …` loses that line, the file still parses, and no filter-derived check can attribute
  the damage. Detect the hazard and refuse rather than guess.
- **`cp` over a live file is not atomic and does not report the failure.** A partial source left the
  destination holding partial content with exit status 0. Write to a temp file in the *same directory*
  and `mv`; across filesystems `mv` degrades to copy-then-unlink and the property is lost.
- **`> "$file"` on a command group truncates before the group runs.** Combined with an unguarded
  backup `cp`, that rebuilds the file from a backup that does not exist — measured at 204 bytes down to
  22, with no `.bak` on disk. Check every `cp` you rely on, and never let the destination be the thing
  you are reading.

Two more that are about claims rather than code, and cost the most review time for how small they look:
do not assert an invariant that is only nearly true (**"expect exactly two lines"** was false, and the
sentence after it told the operator to act on the discrepancy), and do not let a comment promise
something the code beside it does not do. In a procedure whose whole thesis is that a check unable to
see its own failure is not a check, a confidently wrong comment is worse than no comment.


### If these commands or jq paths moved

`codex debug models` and `codex doctor --json` are diagnostic surfaces, not a stable API, and the
banner at the top of this doc applies to them as much as to the config reference. Every path above was
verified against **codex-cli 0.145.0**, whose `codex doctor` report declares **`schemaVersion: 1`** —
that field is the version tell to check first. If a path starts returning `null` or nothing, do not
assume the lane is broken: introspect one level up and read the key names off the live binary.

```bash
codex doctor --json | jq -r '.schemaVersion, .codexVersion'   # has the report shape moved?
codex doctor --json | jq '.checks | keys'                      # is the check still called config.load?
codex doctor --json | jq '.checks["config.load"].details'      # what does it expose now?
codex debug models | jq '.models[0] | keys'                    # per-model field names
```

These four are the one place in this doc that deliberately **omits** `// empty`. Everywhere else a bare
`jq -r` is a trap — a missing field renders as the four-character string `null`, which is non-empty and
therefore passes naive tests, and a pipeline that pins `model = "null"` or registers `-m null` looks
like it worked. Here the opposite is true: you are asking *whether* a path still exists, so a printed
`null` is the answer you came for. If you copy one of these lines into something that consumes the
value, add `// empty` and check the result's shape before using it.

Two shape details that are easy to trip over and are unlikely to be stable:

- `config.load.details` keys are **human-readable strings, not identifiers.** On 0.145.0 eight of the
  twelve contain spaces (`"model provider"`, `"config.toml parse"`, `"enabled feature flags"`,
  `"log dir"`, …); one more contains a dot (`"config.toml"`), which dot syntax also cannot reach
  because `jq` would read it as two keys; and only `model`, `cwd`, and `CODEX_HOME` are plain enough
  for `.details.foo`. Bracket-and-quote syntax works for every one of them, so use it throughout
  rather than remembering which category a key falls into.
- `details.model` reports the literal `<default>` — not `null`, not the resolved slug — when
  `config.toml` pins nothing. Treat `<default>` as "unpinned", not as a model name.

`codex doctor` exposes no `model_reasoning_effort`, so there is no local diagnostic for the effort
setting; reading `~/.codex/config.toml` is the check. If the whole `doctor --json` surface disappears,
the fallback is the in-band one — the server's `session_configured` event, described at the end of
[the model-pin section](#the-model-pin-lives-in-configtoml-not-in-the-registration) — at the cost of
starting a session.

### If you use Codex profiles

Codex supports profiles, and on 0.145.0 they **cannot reach this lane** — which is good news for the
mental model in this section but a trap if you assume otherwise. Three verified facts:

1. **A profile is a separate layered file, selected only on the command line.** `-p <name>` layers
   `$CODEX_HOME/<name>.config.toml` on top of the base user config (the binary's own `--help` wording).
   There is no `config.toml` key that selects one.
2. **`mcp-server` rejects `-p` outright — the server does not start.** `codex -p <name> mcp-server`
   exits immediately with this (one line on stderr, wrapped here for width):

   ```
   Error: --profile only applies to runtime commands and `codex mcp`: `codex`, `codex exec`,
   `codex review`, `codex resume`, `codex archive`, `codex delete`, `codex unarchive`, `codex fork`,
   `codex mcp`, `codex sandbox`, and `codex debug prompt-input`.
   ```

   `mcp-server` is not on that list (`codex mcp`, which manages Codex's *own* external MCP servers, is
   a different subcommand). So do not put `-p` in the registration: the process never comes up, and
   the probe reports `handshake-failed` with nothing obviously wrong at the `claude mcp get codex`
   level. The base `~/.codex/config.toml`'s top-level `model` is what the Sol lane runs.
3. **Two legacy spellings behave differently, and only one of them tells you.** A top-level
   `profile = "<name>"` selector key is a hard config-load failure —

   ```
   legacy `profile = "name"` config is no longer supported; use `--profile name` with
   `name.config.toml` instead
   ```

   — and `codex doctor` reports `config could not be loaded` with `details: {}`, which takes the lane
   down with it. A legacy `[profiles.<name>]` **table**, by contrast, parses without complaint and is
   inert: the top-level `model` still wins, and nothing warns you that the table did nothing. If you
   migrated from an older Codex and your pin is inside a `[profiles.…]` table, hoist it to the top
   level.

If you genuinely need a different model for review than for your interactive sessions, the seam is
not a profile. `codex-review.sh` spawns the server with the environment it inherits (it prefixes only
`CLAUDE_PROJECT_DIR`; there is no `env -i`), so an exported `CODEX_HOME` pointing at a second config
directory reaches the server, and `CODEX_MCP_MODEL` overrides the recorded `reviewer_model` to match.
That combination is read off the script rather than exercised end to end — treat it as a starting
point to verify on your machine, not a supported configuration.

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
| Lane stays `claude`, `codex` runs fine by hand | `handshake-failed` | The registered command is not resolvable in the spawned environment (a shell alias, an nvm-shimmed path missing from the hook's `PATH`), the registration carries a flag `mcp-server` rejects (`-p` is the one to check — see [profiles](#if-you-use-codex-profiles)), or the server exited during the handshake. | Register an absolute path to the binary: `claude mcp add --scope user codex -- "$(command -v codex)" -m YOUR_SLUG mcp-server`. Then run the registered command by hand, verbatim, and read stderr — a rejected flag says so on the first line. |
| Lane stays `claude` on a slow machine | `timeout` | The handshake budget (5s default) expired before `tools/list` came back — a cold binary on a slow disk is the usual cause. | Raise it for the probe: `CODEX_DETECT_TIMEOUT_S=15 bash .claude/scripts/codex-detect.sh detect --refresh`. |
| Lane stays `claude`, server connects | `no-codex-tool` | The server answered but advertises no tool named `codex` — usually a wrapper package rather than the official CLI, or a version that renamed the tool. | Use the official CLI's own `codex mcp-server` mode. Confirm the surface: it should advertise exactly `codex` and `codex-reply`. |
| Everything looks right, lane still `claude` | any | `reviewer_lane=claude` is pinned in `.claude/model-roles`, or `WORKFLOW_REVIEWER_LANE` is exported in your environment. Both intentionally force the free lane. | Remove the pin / unset the variable, or leave it — this is the supported opt-out. |
| Probe prints `claude` with no artifact written | n/a | `jq` is missing. The probe cannot parse a registration without it and resolves to `claude` by design. | Install `jq` (the plugin requires it anyway). |
| A relay round returns exit 5 | n/a | The review turn hit the wall-clock cap, the server died mid-turn, **or the model resolved from `~/.codex/config.toml` is one your account cannot use.** No artifact is written. | Discriminate by timing, which is the only reliable tell: a fail *at* the cap (300s by default) is the wall clock — see [Exit 5 at the wall-clock cap](#exit-5-at-the-wall-clock-cap). Instant and every time is the model pin — see [The model pin lives in `config.toml`](#the-model-pin-lives-in-configtoml-not-in-the-registration). Either way nothing is broken: the orchestrator records a degradation note and QA authors the artifact on the Claude lane that round. |

### The model pin lives in `config.toml`, not in the registration

Found the hard way during the v4.0.0 live validation (finding
`claude-workflow-plugin-gl6`, 2026-07-26, codex-cli 0.145.0). Three facts, in the order they bite:

1. **`~/.codex/config.toml`'s `model` is authoritative for `mcp-server` mode.** The registration's
   `-m <slug>` is ignored there, and a `-c model=…` override does not stick either. Established by
   direct JSON-RPC probes against the running server, not inferred: the configured session reported
   the *config file's* model while the registration asked for a different one. Keep `-m` anyway —
   [§5](#5-model-pinning-and-tracking-the-newest-model) explains why (it is the `reviewer_model` the
   artifact records), and keep it equal to the config value.
2. **A model your account cannot use fails the whole turn.** On a ChatGPT-account login,
   `model = "gpt-5.2-codex"` draws
   `400 invalid_request_error: The 'gpt-5.2-codex' model is not supported when using Codex with a
   ChatGPT account.` What you actually observe is `codex-review.sh` exiting 5 with no artifact —
   the error is upstream of the plugin and never reaches your terminal on its own.
3. **Fix in one line, then verify the model that was actually resolved.**

   ```bash
   # 1. Back up first — this file also holds your reasoning-effort setting — and
   #    CHECK the backup landed before you touch the original. A `cp` whose failure
   #    you did not read leaves you editing with no way back.
   BAK=~/.codex/config.toml.bak-$(date +%Y%m%d-%H%M%S)
   cp -p ~/.codex/config.toml "$BAK" && ls -l "$BAK" || echo "NO BACKUP — do not edit yet"

   #    ...then edit it by hand:   model = "SOME_SLUG_YOUR_ACCOUNT_SUPPORTS"
   #    (this doc's own pin is gpt-5.6-sol; yours depends on your account)

   # 2. Confirm what Codex resolved, and that nothing else in the file moved. The
   #    second check is the one that catches a botched edit — a correct `model` line
   #    in an otherwise mangled file passes the first check and fails the lane.
   #    `// empty` because jq renders a missing field as the string "null".
   codex doctor --json | jq -r '.checks["config.load"].details.model // empty'
   # -> the slug you just set.  Empty means the path moved; "<default>" means unpinned.

   #    Same status check as §5 step 4(b), and for the same reason: an unreadable
   #    backup, an unreadable config, or a missing either-side makes `diff` fail to
   #    stderr with nothing on stdout, which a bare `diff` invocation lets you read
   #    as "only the model line differs".
   D=$(diff "$BAK" ~/.codex/config.toml 2>&1); rc=$?
   if [ "$rc" -gt 1 ]; then
       printf 'CANNOT COMPARE (diff exit %s):\n%s\n' "$rc" "$D"
   else
       printf '%s\n' "$D"          # expect: only the model line differs
   fi

   #    Stricter, if you want it: does it still parse cleanly? (--strict-config is a
   #    TOP-LEVEL flag — before `doctor`, not after it.)
   codex --strict-config doctor --json |
     jq -r '.checks["config.load"].status // empty'                 # -> ok

   # 3. Re-check the lane end to end (also free; detect never invokes the tool).
   bash .claude/scripts/codex-detect.sh detect --refresh   # -> codex
   ```

   **Reverting.** If the edit made things worse — or you were only trying the lane out — the backup is
   the whole undo: it holds the exact prior bytes, including any keys this doc never mentioned. Restore
   it through a temp file and a rename rather than copying straight over the live config, for the reason
   [§5](#5-model-pinning-and-tracking-the-newest-model) gives: an interrupted `cp` leaves the
   destination holding partial content and still exits 0.

   ```bash
   t=$(mktemp ~/.codex/config.toml.restore.XXXXXX) &&
     cp -p "$BAK" "$t" && mv "$t" ~/.codex/config.toml || echo "restore failed — config untouched"
   ```

   Re-run step 2 to confirm the old value is back. Delete the backup once step 2 and step 3 both read
   the way you want (`rm "$BAK"` — named, not globbed); leaving one behind per attempt is how
   `~/.codex` accumulates near-identical files that are impossible to tell apart later. If you are
   removing the lane entirely rather than fixing it, [§9](#9-removing-the-lane) has the config cleanup.

   The definitive in-band check is the server's own `session_configured` event, whose `model` field
   names what the session will really use. `codex doctor` is the cheap version of the same question
   and does not start a session; use it first. If a future CLI drops `doctor --json`, see
   [If these commands or jq paths moved](#if-these-commands-or-jq-paths-moved).

**This is an operator-config problem, not a plugin failure, and the plugin's behaviour under it is
the designed one.** Through the whole episode `codex-review.sh` and `codex-detect.sh` were correct:
transport, `.result.content[].text` extraction, and the exit-5 degradation all worked. A rejected
model lands on the same row of the table below as any other mid-flight failure — the turn exits 5,
QA authors the artifact on the Claude lane that round, and the release mechanics do not change. You
lose the second opinion for one round; you lose nothing else.

### Exit 5 at the wall-clock cap

This is the failure you are most likely to meet, and unlike the model pin it is not something you
have misconfigured. Across the v4.1 release wave (2026-07-27, one maintainer's machine) **8 of 9
review cycles ended this way.** Expect it, and know what it does and does not mean.

What it looks like — one line on stderr from the driver, then exit 5, and no artifact file:

```
[codex-review] codex tool call exceeded 300s wall-clock budget (or server exited); no artifact
```

The number is your configured cap, not a constant, and **the parenthesis is not hedging for effect —
the driver genuinely cannot tell the two apart here.** A timed-out wait and a server that exited
mid-turn reach the same line. Timing separates them: a failure *at* the cap is the wall clock, a
failure seconds in is the server dying, and that second case belongs to a different row of the table
above (start with [the model pin](#the-model-pin-lives-in-configtoml-not-in-the-registration)).

What happens next is the designed path, automatically: the orchestrator records a degradation note and
QA authors the review artifact on the Claude lane for that round. **The review still happens.** The
artifact schema, the grading packet's item-8 slot, and the release credential are unchanged — see the
table below. What you lose is the second opinion for that one round.

Where the cap lives: `timeout_seconds` in `.claude/review-config`, default **300**. That file is the
one place the bounded-diligence caps live. Raising it is a one-line change and a real cost decision:
Sol reasons for as long as you allow, the work done before a cap-hit is not recoverable, and whether
your account is billed for a turn killed mid-stream is between you and OpenAI — this doc will not
guess. Raise it deliberately, and only if you are prepared to pay for turns that may still yield
nothing.

**No root cause is claimed here, and the obvious correlate does not hold.** Request size looked like
the explanation and then stopped looking like it: the one cycle that succeeded carried a ~103 KB
review request, while a ~95 KB request — smaller — hit the cap. So "it only fails on big diffs" is not
a rule you can plan around, and trimming the request is not a known fix. The investigation, including
the size-threshold, connection-lifecycle, per-thread-state, and variable-reasoning-length hypotheses,
is tracked as **`claude-workflow-plugin-xo8`**; the running evidence lives on that task rather than in
this doc, because this doc should not grow a theory per data point.

Two things not to do while this is open. Do not read exit 5 as a plugin defect — the driver's
transport, parsing, and degradation were verified live during the v4.0.0 validation and again across
these cycles. And do not disable the lane on the strength of it: a degraded round costs you nothing
that the `claude` lane does not already cover, so leaving it registered keeps the occasional successful
Sol review available at no risk.

### Graceful degradation, in full

Every failure mode collapses to the same place. This is the contract, not a best effort:

| What happened | Resolved lane | What the workflow does |
| --- | --- | --- |
| No registration (`config-absent`) | `claude` | QA authors the artifact itself. No behavioural change. |
| Server unresolvable or crashed (`handshake-failed`) | `claude` | Same. |
| Handshake timed out (`timeout`) | `claude` | Same. |
| Server present, no `codex` tool (`no-codex-tool`) | `claude` | Same. |
| Lane forced off (`model-roles` / env) | `claude` | Same. |
| Review turn hit the wall clock or died mid-flight ([driver exit 5](#exit-5-at-the-wall-clock-cap)) | `claude`, that round | Degradation note on the task; QA authors the artifact that round. |
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

Three levels, all clean. The first two are the plugin's side; the third is your Codex config, which
the plugin never wrote and cannot clean up for you.

```bash
# 1. Keep Codex installed, just stop using it as the reviewer.
printf 'reviewer_lane=claude\n' >> .claude/model-roles
# ...or, for one session only:
export WORKFLOW_REVIEWER_LANE=claude
```

```bash
# 2. Full removal of the registration.
claude mcp remove codex -s user
bash .claude/scripts/codex-detect.sh detect --refresh   # -> claude
rm -f .claude/.qa-tracking/reviewer-lane.json           # optional; regenerated on next detect
```

```bash
# 3. Put ~/.codex/config.toml back. Only step 3 touches a file this doc told you
#    to edit; skip it and you keep an effort/model pin that now only affects your
#    own interactive Codex sessions (harmless, but no longer something you chose).

#    List what you have. THIS glob is deliberately loose — it is a listing, not a
#    selection, so it should show everything: the dated backups this doc recommends,
#    the plain `.bak` earlier revisions asked for, and anything you named by hand.
#    On zsh an unmatched glob is an error, not an empty list — "no matches" here
#    simply means you never made a backup, so use the by-hand path below.
ls -l ~/.codex/config.toml.bak*                         # everything, yours included

#    Restore by NAMING the one you want. The dated suffix is its creation time, so
#    the EARLIEST is your pre-lane state and the latest is merely your most recent
#    edit — "newest" is usually the wrong choice here, which is why this is not
#    automated. Two safety properties in one line: the && means no restore happens
#    unless the safety copy of your current file was made, and the temp-plus-rename
#    means the live config is never the thing being written into. A plain
#    `cp backup config.toml` that is interrupted leaves config.toml holding partial
#    content and exits 0.
cp -p ~/.codex/config.toml ~/.codex/config.toml.before-restore &&
  t=$(mktemp ~/.codex/config.toml.restore.XXXXXX) &&
  cp -p ~/.codex/config.toml.bak-YYYYmmdd-HHMMSS "$t" &&
  mv "$t" ~/.codex/config.toml ||
  echo "restore did not complete — config.toml untouched"

#    ...or, if you would rather keep your later edits (or never made a backup),
#    drop just the two keys the lane asked for and leave the rest of the file
#    alone:
#      model = "…"                      (remove, or set to what you want interactively)
#      model_reasoning_effort = "max"   (remove to fall back to the model's default)

#    Verify the result reads how you intended BEFORE deleting your way back.
codex doctor --json | jq -r '.checks["config.load"].details.model // empty'  # <default> if unpinned
diff ~/.codex/config.toml.before-restore ~/.codex/config.toml        # what you actually changed

#    Clean up, once both lines above read right. The pattern below is the FULL
#    %Y%m%d-%H%M%S shape — eight digits, a dash, six digits — so it matches only the
#    names §4 / §5 / §7 create. `.bak-[0-9]*` would NOT do: in a glob that is one
#    digit followed by anything, so it also matches hand-made names like
#    `config.toml.bak-9-keep` or `config.toml.bak-20260728-personal`, and this is an
#    irreversible `rm`. Whatever is left afterwards is listed for you to judge.
rm -f ~/.codex/config.toml.bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9] \
      ~/.codex/config.toml.before-restore
ls -l ~/.codex/config.toml.bak* 2>/dev/null   # anything still listed is yours to judge
```

`model_reasoning_effort = "max"` is worth a moment's thought before you delete it: it is a global
Codex setting, so it has been shaping your interactive sessions too, and removing it makes them
cheaper and shallower. Keeping it is a legitimate choice — it is not lane machinery.

Beyond that, removal leaves nothing behind in the repo: the registration lived in `~/.claude.json`,
the model and effort settings in `~/.codex/config.toml`, and the only project-local trace is the
gitignored `reviewer-lane.json` probe artifact. Uninstalling the Codex CLI itself (`npm uninstall -g
@openai/codex`, `brew uninstall --cask codex`, or deleting the downloaded binary) is independent of
the plugin — and note that uninstalling the binary does **not** remove `~/.codex`, so step 3 is still
the step that cleans up your config.

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
