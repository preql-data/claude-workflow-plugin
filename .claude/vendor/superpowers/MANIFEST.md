# Vendored `brainstorming` skill

One upstream skill is committed to this repo so the plugin's planning step has
a design-dialogue method with zero external fetch and zero marketplace
dependency. Total on-disk size: **~31 KB** across 3 files (verify with
`du -sh .claude/vendor/superpowers && wc -c .claude/vendor/superpowers/*.* .claude/vendor/superpowers/*/*.md`;
measured 2026-07-30).

This tree is REFERENCE MATERIAL, not a registered skill. See
"Why a reference doc and not a registered skill" below — that choice is load-
bearing, and a test enforces it.

## Source

Vendored from [`obra/superpowers`](https://github.com/obra/superpowers) at pin
**`3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9`** (40-hex commit, not a tag — tags
move). Licence: MIT, Copyright (c) 2025 Jesse Vincent; the upstream text is
committed verbatim beside this file as `LICENSE.upstream`.

Raw URLs at the pin:

```
https://raw.githubusercontent.com/obra/superpowers/3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9/skills/brainstorming/SKILL.md
https://raw.githubusercontent.com/obra/superpowers/3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9/LICENSE
```

### Do NOT install upstream from the marketplace

Installing the upstream plugin instead of vendoring this one file is not a
shortcut — it is a different product. The pin carries **14** skills (verified
`gh api repos/obra/superpowers/git/trees/<pin>?recursive=1 | grep -c SKILL.md`,
2026-07-30), and a marketplace install registers all 14 session-wide, in every
session, for every agent. Thirteen of them encode an execution and approval
model that competes with this plugin's:

| Upstream mechanism | What it collides with here |
| --- | --- |
| User-approval gates in prose ("present a design and get approval before any implementation action") | The only release authority here is plan-mode exit plus the change-set-hash-bound `qa-approved` record (`.claude/scripts/qa-gate.sh`). A second, prose-only authority is unauditable — it writes no record and no gate can see it. |
| Self-directed commits ("Commit the design document to git"; a `git commit` step per planning task) | No shipped agent prompt in this repo instructs an agent to commit; `.claude/skills/workflow-engine/SKILL.md` contains the word zero times. The five agent prompts use "commit" only as a NOUN (a SHA to cite as evidence — `orchestrator.md:670`, the `--fix '<commit sha or path:line>'` example), never as an imperative. |
| Specialist-spawns-specialist relays (subagent-driven development, parallel-agent dispatch) | `.claude/settings.json:8` pins `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` and `session-start.sh:533` warns when that pin moves; `no-nested-spawn-instructions.test.sh` is a standing regression guard. Subagents cannot spawn subagents in this runtime at all — the grader and judge are root-orchestrated relays for exactly this reason. |

Vendoring ONE file, modified, is what lets the plugin take the method without
the model.

## Provenance

| File | Size | Upstream path at the pin | `cmp` against upstream |
| --- | --- | --- | --- |
| `LICENSE.upstream` | 1,070 B | `LICENSE` | **MUST PASS.** Byte-identical, deliberately. A licence you have edited is a licence you are no longer complying with. |
| `brainstorming/SKILL.md` | 14,023 B | `skills/brainstorming/SKILL.md` | **FAILS BY DESIGN.** Upstream is 10,047 B / 151 lines; ours is 14,023 B / 235 lines. Ten modifications were applied (table below) and each one is annotated in place with a `> **LOCAL MODIFICATION (n)**` blockquote. A passing `cmp` here would mean the conflict pass was skipped. |
| `MANIFEST.md` | this file | (none) | N/A — written here, no upstream counterpart. |

Honesty note on the modification annotations: they are inline in the vendored
file, not stripped into a sidecar. That makes the file longer than upstream and
makes the diff noisier, and it is the right trade — an agent reading the file
at runtime sees WHY a sentence is missing at the point where it is missing,
which is the only place that information does any good.

Honesty note on the frontmatter: the two-key frontmatter (`name`,
`description`) is kept **verbatim**, including its `You MUST use this before any
creative work` phrasing. It is inert here — nothing parses it, because this is
not a registered skill — and keeping it byte-identical is what makes
re-vendoring a one-line `curl | diff` instead of a merge.

## The ten local modifications

Every row is a real needle: the "upstream count" column records how many LINES
of the upstream file matched (`grep -cF` — matching lines, not occurrences),
measured at the pin on 2026-07-30. A ban with count 0 would be a ban on
nothing, so the counts are part of the record;
`.claude/scripts/tests/vendored-skills.test.sh` carries the same column in its
`BANNED_PHRASES` array and documents a runnable one-liner that regenerates it
from upstream, so the column is checkable rather than asserted.

Line-counting semantics are load-bearing in at least one row: `<HARD-GATE>` is
**1**, not 2, because upstream's closing tag is `</HARD-GATE>` and does not
contain the needle.

| # | Upstream text (short quote) | Upstream count | Why it conflicts (plugin rule) | What it became |
| --- | --- | --- | --- | --- |
| 1 | `<HARD-GATE>` … "until you have presented a design and **the user has approved it** … applies to EVERY project **regardless of perceived simplicity**" | 1 / 1 / 1 lines | A second, prose-only release authority. This plugin has exactly one: plan-mode exit (`orchestrator.md:10`, `:55-63`) plus the change-set-hash-bound `qa-approved` record (`qa-gate.sh:465` reads it back by the exact `QA-GATE APPROVED ... change_set_hash=` shape). | A `> **LOCAL MODIFICATION (1)**` blockquote naming the single authority and stating that no prose — vendored material included — creates, substitutes for, or waives `qa-approved`. |
| 2 | "get user approval after each section"; the flow diamond `User approves design?` | 1 / 4 lines | Borrows the vocabulary of a mechanical record for conversation. `orchestrator.md:60` is where a plan is actually accepted. | The check-in is KEPT as dialogue ("Ask after each section whether it looks right so far"; "checking after each section that it still matches what the user meant"). The approval vocabulary is struck; the diamond becomes `Design matches intent?`. |
| 3 | `docs/superpowers/specs/YYYY-MM-DD-<topic>-design.md` | 2 lines | `install.sh:617` says in as many words that "the plugin borrows exactly these two filenames in it" — `docs/` in an install target is the OPERATOR's directory. A third borrowed path is a packaging change — new mkdir, new required-source row, new `workflow-manifest.sh` row, new uninstall scope — not a prose change. | `bd_doc_write(task_id="<id>", name="spec", content="…")` per `orchestrator.md:241` (section 4a), with the doc-name conventions cited. |
| 4 | "…and commit"; "Commit the design document to git"; "Spec written and committed to `<path>`" | 3 violating lines of 5 total containing `commit` | The orchestrator does not commit — it delegates, and the operator decides when work lands. No shipped agent prompt instructs a commit. | Enforced as a LINE-LEVEL INVARIANT rather than three fixed-string bans: every line containing `commit` (case-insensitive) must also contain `recent commits`. That kills all three instructions and preserves the two genuinely useful explore-context lines ("check files, docs, recent commits"), and it forbids commit instructions nobody has written yet. |
| 5 | Three invocations of the sibling `writing-plans` skill; "Do NOT invoke `frontend-design`, `mcp-builder`, or any other implementation skill" | 6 / 1 / 1 lines | `writing-plans` is not vendored, so all three are dead pointers. | Rewritten to `orchestrator.md` section 4a (write the spec) then section 4 (`Task()` delegation). **The negative sentence is DELETED outright, not rewritten** — see the named finding below. |
| 6 | "You MUST create a task for each of these items" | 1 line | Beads tasks are for delegable units that carry their own QA gate (`orchestrator.md:143`, section 2). A task per checklist row floods the ledger with rows no gate can clear. | "Work these in order" — steps of one turn, not nine Beads rows. |
| 7 | "Wait for the user's response … Only proceed once the user approves"; "**This offer MUST be its own message.**" | 2 / 3 lines | Plan mode IS this plugin's user-review checkpoint (`orchestrator.md:10` frontmatter, `:55-63` prose fallback). A second prose-only wait is invisible to every gate and leaves no record to audit. | A `Plan-mode review` subsection stating the plan is the review artifact, plus a pointer to `AskUserQuestion` for genuine mid-design judgement calls — a real tool call with a real answer. |
| 8 | `elements-of-style:writing-clearly-and-concisely` | 1 line | Not vendored; dead pointer. | `CLAUDE.md`'s doc-style rules. |
| 9 | The whole `## Visual Companion` section + its checklist row | 2 / 1 lines | Dead pointer to an unvendored `visual-companion.md`, AND it instructs starting a browser server with `--open` — an unreviewed side effect in a workflow whose premise is that side effects are gated. | Deleted, with a blockquote recording both reasons. |
| 10 | "Every project goes through this process. A todo list, a single-function utility, a config change — all of them." | 1 line | The sharpest conflict. Directly contradicts the fast-path carve-out at `orchestrator.md:139` ("Trivial single-line changes (typo fixes, README tweaks) skip impact analysis"), `orchestrator.md:314` ("For genuinely trivial work (single-line typo fix, README touch-up)"), and `.claude/skills/workflow-engine/SKILL.md:110`. | Rewritten to keep the true insight — "simple" work is where unexamined assumptions cause the most wasted work — bound to the plugin's own literal phrasing: the carve-out is a **`single-line typo fix`**, a README touch-up, or an F1 doc-only change. That literal is the POSITIVE sentinel the test asserts, because bans alone cannot prove a replacement landed rather than a section being silently deleted. |

### Named finding: `frontend-design` is LIVE in this environment

Modification 5 deletes the sentence "Do NOT invoke frontend-design, mcp-builder,
or any other implementation skill" rather than rewriting it, and that is a
deliberate, checked call:

```
$ ls ~/.claude/plugins/cache/claude-plugins-official/frontend-design/unknown/skills/
frontend-design/SKILL.md
$ jq '.plugins | keys' ~/.claude/plugins/installed_plugins.json
[ "frontend-design@claude-plugins-official", ... ]     # scope: user
```

`frontend-design` is an installed, user-scoped, registered skill here. Shipping
a vendored file that says "do NOT invoke frontend-design" would actively
suppress a legitimate skill on exactly the work it exists for — UI changes
routed to `@frontend`. A vendored reference doc must never reach outside its
own subject to veto its host's skill set; the correct scope of a vendored file
is what IT does, not what the host may do.

## Re-vendoring procedure

Runnable end to end. It does not auto-apply the modifications — it shows you
exactly what a new pin changed so you can re-apply them deliberately.

```bash
cd "$(git rev-parse --show-toplevel)"
PIN=3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9      # <- bump to the new pin
RAW="https://raw.githubusercontent.com/obra/superpowers/$PIN"
WORK=$(mktemp -d)

# 1. Fetch upstream at the pin.
curl -sfL -o "$WORK/SKILL.md"        "$RAW/skills/brainstorming/SKILL.md"
curl -sfL -o "$WORK/LICENSE"         "$RAW/LICENSE"

# 2. The licence MUST be byte-identical. A diff here is a licence change and
#    stops the re-vendor until a human reads it.
cmp "$WORK/LICENSE" .claude/vendor/superpowers/LICENSE.upstream \
    || { echo "LICENCE CHANGED — stop and read it"; exit 1; }

# 3. Diff the skill. This diff is EXPECTED to be large: it contains our ten
#    modifications plus whatever upstream changed. Read it; do not apply it.
diff -u "$WORK/SKILL.md" .claude/vendor/superpowers/brainstorming/SKILL.md | less

# 4. Re-apply the ten modifications to the new upstream text, using the table
#    above row by row. Update every "upstream count" that moved.
#    Then update the pin in THIS file (one occurrence) and in the test.

# 5. Prove it.
bash .claude/scripts/tests/vendored-skills.test.sh
bash .claude/scripts/tests/run-tests.sh
```

Step 4 is manual on purpose. An automated patch-apply would silently succeed
against text whose surrounding meaning had changed, which is the failure mode a
vendoring record exists to prevent.

## Why a reference doc and not a registered skill

The file lives under `.claude/vendor/`, not `.claude/skills/`, and
`.claude-plugin/plugin.json`'s `skills[]` array stays length **1**.

- **It is loaded where it is wired, not everywhere.** An explicit
  `Read .claude/vendor/superpowers/brainstorming/SKILL.md` instruction in
  `orchestrator.md` section 1 loads it at the one moment it is useful.
  Registration would surface it in every session for every agent.
- **Registration would not reach subagent prompts anyway.** The wire-in target
  is a subagent definition; a session-wide skill registration does not inject
  itself into one.
- **It preserves an exact invariant.** "Everything under `.claude/skills/` is
  registered in `plugin.json`" is currently true with no exceptions, and an
  exception-free invariant is worth more than the convenience it costs.
- **It keeps an existing scan honest.** `platform-audit.test.sh:203` scans
  `.claude/agents/*.md`, `.claude/commands/*.md`, and THE ONE `SKILL` — that
  third element is a single `$SKILL` variable, not a glob. A second registered
  skill would silently escape that scan rather than failing it.
- **Registration is not free.** It would need a frontmatter rewrite (upstream's
  two keys are not this repo's skill schema — compare
  `.claude/skills/workflow-engine/SKILL.md`, which carries `when_to_use`,
  `disable-model-invocation`, `user-invocable`), a `plugin.json` entry, an
  installer entry, and a parity test. All of that to make a document load in
  sessions that do not want it.

Adding a SECOND vendored skill is a five-step change:

1. Fetch it at the pin into `.claude/vendor/superpowers/<name>/SKILL.md`.
2. Run the conflict pass over it: the two line-level invariants (`approv` /
   `qa-approved`, `commit` / `recent commits`), the alternate-authority scan,
   and the second-debug-protocol scan. Anything that fires is a modification to
   make, not a test to relax.
3. Add a Provenance row above, and one row per modification to the ten-row
   table (which stops being ten rows — rename it).
4. Wire it in: an explicit `Read` instruction in the agent prompt that needs it.
   A vendored file nothing reads is dead weight with a licence attached.
5. Extend `.claude/scripts/tests/vendored-skills.test.sh` — its bans, its
   wiring sentinel, and the SKILL.md counts (`find` returns 3, not 2).

Nothing else. No `plugin.json` change, no `install.sh` change, no
`workflow-manifest.sh` change: the vendor tree is copied by a `find`-driven walk
and classified by `scan_tree`, both of which pick up new files with no edit.
That is the payoff of registering a TREE rather than a list of filenames, and it
is why this change also retired the installer's last name-by-name skills copy.

## Verification

Confirm this tree from a clean checkout:

```bash
# The licence is byte-identical to upstream at the pin.
curl -sfL "https://raw.githubusercontent.com/obra/superpowers/3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9/LICENSE" \
    | cmp - .claude/vendor/superpowers/LICENSE.upstream && echo "licence OK"

# The skill is NOT byte-identical, and that is the point (see Provenance).
# The mechanical check is the test, which asserts the ten modifications landed:
bash .claude/scripts/tests/vendored-skills.test.sh
```

### Deliberately NOT done, and why

- **No pristine second copy of upstream's SKILL.md.** Two copies are two things
  to drift, and the second one has no consumer: nothing at runtime reads it,
  and the re-vendoring procedure re-fetches from the pin anyway, which is a
  fresher source than a stored copy could ever be. The upstream text is
  reachable in one `curl` and is not lost.
- **No `.patch` file.** A patch would rot against the next upstream refactor —
  it applies to line offsets, not to meaning — and would silently apply with
  fuzz to text whose surrounding argument had changed. The modification table
  above is a patch expressed as INTENT, which is what a human re-applying it
  actually needs.
- **No upstream SHA-256 ledger.** The 40-hex pin IS the identity: it names one
  immutable commit, from which every byte is re-derivable. A sha of our
  modified file would only assert that our file is our file.
- **No `cmp` gate on `SKILL.md` in CI.** It would fail permanently by design.
  The test asserts the ten modifications by their content instead — sixteen
  measured bans, two line-level invariants, and a positive sentinel, because
  bans alone cannot distinguish "the conflict was fixed" from "the section was
  deleted".
