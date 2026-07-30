# Changelog

All notable changes to the Claude Workflow Plugin are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Versioning

- **Major** (`X.0.0`): Breaking changes to the plugin shape -- the install
  layout, the agent contract, the hook output schema, or the QA gate semantics.
  Operators may need to re-run the installer in fresh mode.
- **Minor** (`x.Y.0`): New capabilities (a new agent, a new slash command, a
  new hook event). Existing installs continue to work; fresh install picks up
  the new feature.
- **Patch** (`x.y.Z`): Bug fixes, doc updates, internal refactors, prompt
  tightening. No behavior changes for the operator.

## [4.1.0] - 2026-07-30

**The verifiable install.** Through 4.0.0 the plugin had no answer to "what
does this ship, and does it work where it landed?" — the shipped surface
existed only as a sequence of `cp` calls, there was no upgrade path off 3.x,
and post-install verification was two `test` calls. This release turns the
surface into a data artifact (`workflow-manifest.sh` plus a frozen per-release
hash table), builds a real v3.5 → v4 upgrade flow on top of it that preserves
operator customizations instead of clobbering them, and replaces
presence-checking with `workflow-doctor.sh` — eleven named checks that assert
FUNCTION rather than existence, two of which spawn the MCP servers over stdio
and assert exact tool counts. That last one earned its keep immediately: it
found a P0 absent from the plan, in which
every `curl | bash` install ran **no workflow at all** — both MCP servers dead
because `--depth 1` never cloned `node_modules`, and SessionStart emitting a
bare `{"error": …}` with no workflow context, no delegation contract and
nothing saying so. Around that, the v4.0.0 follow-up queue was burned down:
the `LABEL_WITHOUT_RECORD` remediation that printed a loop with no exit, three
transient-block race windows, and rubric verdicts that were not bound to the
change set they graded.

**Why this is a minor.** New capabilities, no broken contracts — the
`## Versioning` criteria above, applied literally. The release adds a new
slash command (`/workflow-doctor`, one of that block's own examples of a
minor), three new scripts, a new installer mode (`--upgrade`), a vendored
reference document, and a seventh field on the F7 completion contract. It
does **not** change the install layout, the hook output schema, or the QA
gate's release predicate, and existing installs upgrade in UPDATE mode —
never the fresh-mode re-install the major criterion names. That last point is
the one a reader of 4.0.0's note will want checked, so it is stated
explicitly: **neither `gz3` nor `bjx` adds a condition to the release
predicate.** 4.0.0 was a major precisely because the predicate gained two new
NECESSARY conditions (an independent review artifact, zero unresolved
at-threshold findings). `gz3` makes `approve`'s idempotency hash-aware — it
constrains when approve may *no-op*, and its Stop-side `VANISHED-CHANGE-SET`
arm *releases* a state that previously hung, so both directions are
weakly-or-not-at-all restrictive. `bjx` adds `change_set_hash` to the RUBRIC
record grammar and makes `enter` preserve a satisfied rubric label only on
positive evidence; its approve-side rubric cross-check is deliberately a
WARNING plus a durable `[rubric mismatch: …]` token rather than a refusal,
because `qa.md` 6f forbids a script-side rubric denial as a parallel gate and
`verify-before-stop.sh` reads no rubric state at all. Two honest
counterweights, both in the upgrade note below rather than buried here: the
change-set denylist grew three patterns, so an in-flight review cycle pays a
one-time re-approve; and `node` ≥ 18.17 became a hard, *checked* prerequisite,
so an installer run on a node-less host now aborts where it previously
proceeded — the requirement is not new (both MCP servers have always been
node), only the check is.

> **UPGRADE NOTE — two things to act on, in this order.**
>
> **1. Node is now a checked prerequisite and dependencies install in the
> target.** Every `curl | bash` install of 4.0.0 shipped both MCP servers
> DEAD: the source is a `git clone --depth 1`, `.gitignore` excludes
> `node_modules`, so the clone never had dependencies to copy and both
> launchers died at `ERR_MODULE_NOT_FOUND`. The installer now requires
> `node` ≥ 18.17 and `npm` (checked BEFORE the clone, so it aborts before
> writing anything) and runs `npm ci --omit=dev --ignore-scripts` per server
> in the TARGET after the copy. A run that installs the tree but cannot
> verify it exits **3** — distinct from `1`, which means "aborted, nothing
> written". **Existing 4.0.0 installs do not self-heal.** Re-run the
> installer in update mode, or do it by hand in the installed project:
>
> ```bash
> ( cd .claude/mcp/bd-mcp         && npm ci --omit=dev --ignore-scripts )
> ( cd .claude/mcp/code-graph-mcp && npm ci --omit=dev --ignore-scripts )
> ```
>
> Then confirm with `bash .claude/scripts/workflow-doctor.sh` (or
> `bash install.sh --verify`, or `/workflow-doctor`), which spawns both
> servers over stdio and asserts `tools/list` returns EXACTLY 21 and EXACTLY
> 7. "The config parses" is precisely what passed while this was broken, so
> the doctor does not check that.
>
> **2. One-time hash migration. The change set was never bounded
> by the repo.** `post-edit.sh` records `tool_input.file_path` VERBATIM, so any
> absolute path an agent wrote entered `changed-files.txt`, the change-set
> hash, and the Stop gate — including files outside the repository entirely.
> Three patterns join the shared denylist in this release:
>
> - `(^|/)\.claude/plans/` — plan-mode plan files wherever they live;
>   `~/.claude/plans/<slug>.md`, outside the repo, is the real shape.
> - `^(/private)?/tmp/claude-[^/]+/` — the harness's own per-session
>   scratchpad (grader verdict files, relay artifacts).
> - `(^|/)\.claude/\.mutation-(runs|worktrees)/` — `mutation-sweep.sh` per-run
>   reports and the throwaway checkouts `--keep-worktrees` leaves behind.
>
> `change_set_hash` is a sha256 over the DENYLIST-FILTERED changed-files list,
> so an approval recorded before this landing no longer matches the hash the
> Stop hook recomputes after it: the gate emits `LABEL_WITHOUT_RECORD` and
> re-blocks. That is the correct fail-closed direction — a stale approval must
> not release. All three patterns ship in ONE landing, so an in-flight cycle
> pays the migration exactly once. Recovery for a cycle caught mid-flight:
>
> ```bash
> bash .claude/scripts/qa-gate.sh enter <task-id>
> bash .claude/scripts/impact-report.sh <task-id>
> bash .claude/scripts/qa-gate.sh approve <task-id> '<summary>'
> ```
>
> That is the whole recipe — the same three commands the block reason prints,
> and no `bd label remove` step (`approve`'s idempotency has been hash-aware
> since 4.0.0's `gz3` fix).
>
> **What this fixes.** Six recorded instances in a single release. The worst
> was a hard dead end rather than friction: a plan-mode plan file blocked a
> TASK-LESS session across three Stop iterations up to J21 escalation. The file
> is `.md`, so F1 classified the change set doc-only — but F1's doc-only fast
> path auto-approves only WITH an active task, and plan mode forbids creating
> one. There was no exit. The other five were harness scratchpad verdicts
> mutating the hash mid-relay, two agent-chosen `/tmp` probes (one of which
> entered an approval's bound change set), and the two `mutation-sweep`
> directories — gitignored, but reachable by `Edit`.
>
> **What it deliberately does NOT cover, and why.** `/tmp` and `/var/folders/`
> as a class. The reason is mechanical, not stylistic: two component specs seed
> `changed-files.txt` with ABSOLUTE paths rooted at `mktemp -d`'s parent —
> `/tmp/...` on a Linux CI job, `/var/folders/...` on a macOS dev box — so
> either pattern would silently empty the change set of the spec that exists to
> prove path relativisation AND the spec that exists to prove the cross-worktree
> approval bridge. Both would keep passing while proving nothing. The narrow
> `/tmp/claude-<session>/` form is safe because those fixtures are created as
> `mktemp -d -t component-fixture.XXXXXX`. Agent-chosen scratch outside that
> prefix is addressed by PROMPT guidance instead — `qa.md` and the three
> specialist prompts send throwaway probes to the session scratchpad or
> `.claude/.qa-tracking/`. Pinned by
> `.claude/tests/component/specs/denylist-shared.sh`: **section D** drives the
> migration for the patterns that actually shipped (it pins the PRE-landing lib
> and then restores the real one, so the restore *is* the landing), while
> **section C** keeps the invented canary that proves the mechanism itself.

### Added

#### The v3.5 → v4 upgrade path (Phase U0, epic `0jk`)

- **`.claude/scripts/workflow-manifest.sh`** — the one machine-readable
  enumeration of the shipped surface. `generate <root>` emits a sorted,
  header-free, timestamp-free TSV of `<path><TAB><class><TAB><sha256>`
  mirroring `install.sh`'s copy loops one-for-one; `classify` produces a
  six-verdict upgrade decision table from an old hash table, a target and a
  source. Three classes: `workflow` (plugin-owned, replaced wholesale),
  `operator` (seeded once, never clobbered), `merged` (jq key-wise, never a
  copy). Hash chain `sha256sum` → `shasum` → `openssl`. Determinism is
  load-bearing — downstream specs regenerate the output and compare it
  byte-for-byte.
- **`manifests/v3.5.0.sha256`** — the frozen table for the last v3 release,
  generated from the real `v3.5.0` tag (117 rows, byte-reproducible), and
  **`manifests/v4.1.0.sha256`** for this one. `install.sh` picks
  `manifests/v<detected>.sha256` automatically, so a stock target of a
  released version classifies against its OWN hashes rather than falling back
  to v3.5's and reporting every unchanged file as customized.
- **`install.sh --upgrade` / `--mode <fresh|update>`**, mutually exclusive and
  validated before prerequisites. `detect_v3_install` reads `plugin.json` 3.x
  as the primary signal with a marker-absent fallback; a dotfile-inclusive
  `.claude-v3-backup-<timestamp>/` is taken; copies are verdict-driven
  (preserve-custom writes a `.new` sidecar alongside, replace-custom warns and
  backs up, merges go through the shared jq expressions); an
  `.claude/install-manifest` is written on every path; the run ends with a
  verdict-count readout and an `upgrade-report.txt`.
- **Idempotent re-runs.** Mode-2 UPDATE consumes the target's own
  `install-manifest` as `classify`'s old-table, so operator customizations
  survive a re-run (the re-clobber gap was reproduced before it was fixed;
  a legacy plain-copy fallback covers targets with no manifest). A
  sentinel-guarded no-change probe skips backup creation on genuine no-ops.
- **Manifest-driven uninstall.** `uninstall.sh` consumes the
  `install-manifest` — unmodified plugin-owned root files are trashed,
  customized ones are left with a note, and v2/v3 backups are listed. Both
  uninstallers enforce physical parent containment (`cd && pwd -P`, never a
  string prefix).
- **`install.ps1` carries the whole upgrade machinery**: `-Upgrade`, the
  detection ladder, exclusivity, PowerShell-native generate/classify/hash
  producing byte-compatible TSV, an LF-only `install-manifest`, the verdict
  walk, probe and report with rendered-sentence parity against bash, and the
  same manifest-driven uninstall.
- **Two shipped docs join the installed surface** (`docs/CODEX_SETUP.md`,
  `docs/HOOKS.md`), named file by file rather than by a `docs/` scan — an
  install target's `docs/` belongs to the operator.

#### Installed targets that actually orchestrate (Phase C0, epic `2br` — unplanned P0)

- **`.claude/scripts/workflow-doctor.sh`** — eleven named checks, each
  `PASS`/`FAIL`/`SKIP` with a `fix:` line, plus `--json-out` and exit `0/1/2`.
  Three front doors: `install.sh --verify`, the new `/workflow-doctor` slash
  command, and direct invocation. Two checks carry the phase: `session_start`
  pipes a synthetic payload through the REAL hook and asserts the emitted
  envelope CONTAINS the workflow context; `mcp_bd` / `mcp_code_graph` spawn
  each server over stdio and assert `tools/list` returns EXACTLY 21 / EXACTLY
  7 (probed with a stub at 0/20/21/22 tools → FAIL/FAIL/PASS/FAIL — exact
  equality is what catches "boots but registers nothing"). Every dynamic check
  runs in a throwaway sandbox; the `beads` check is the one documented
  exception, disclosed in all three operator-facing surfaces, because
  `bd doctor` must open the real database to mean anything.
- **MCP dependencies are installed in the target** — `npm ci --omit=dev
  --ignore-scripts` per server, with `< /dev/null` (under `curl | bash` stdin
  is the script text, and an npm prompt would eat it). `node` ≥ 18.17 and
  `npm` are hard prerequisites checked before the clone. Preserve-and-restore
  around the install, because `npm ci` removes `node_modules` first and a
  failing re-install would otherwise destroy the operator's tree. New flags
  `--verify`, `--skip-mcp-deps`, `--skip-verify` with env forms for
  `curl | bash`.
- **SessionStart degrades loudly instead of vanishing.** The full envelope is
  emitted always, with a `<workflow_degraded severity="high">` block SEEDED at
  the TOP of the context rather than appended. bd-off-PATH and missing-`.beads`
  are separate reasons. An EXIT trap enforces the guarantee at the exit rather
  than at each call site, so the next unanticipated death is also covered, and
  the jq-absent path gets a real awk JSON encoder rather than a truncated
  literal.

#### Gate follow-up burn-down (Phase U1, epic `waz`)

- **Hash-aware approve idempotency.** `approve` no-ops ONLY when an existing
  record binds the hash this approve would bind; otherwise it re-verifies every
  precondition and writes a fresh bound record. This closes a printed
  remediation that could not work (`enter` never removed `qa-approved` and
  `approve` short-circuited on its mere presence, so following the printed
  commands was a no-op loop). Three transient-block race windows close with it:
  record-before-label, clear-after-truncate, and a Stop-side
  `VANISHED-CHANGE-SET` release for the two-read straddle no approve-side
  ordering can fix.
- **Rubric verdicts are bound to the change set they graded.** RUBRIC records
  carry `change_set_hash`; `enter` preserves a `rubric-satisfied` label only on
  positive evidence (gate open, latest record satisfied, hash equal to now) and
  degrades to the old clear otherwise. The hash comes from three sources in
  descending authority — `--graded-hash` from the packet, else a live recompute
  corroborated by the persisted report, else explicitly unbound naming both —
  and deliberately never from the grader's own JSON, which would let the graded
  party state what it graded.
- **`docs/CODEX_SETUP.md` gains the hand-edit model-pin procedure**, a revert
  path, a moved-CLI-surface introspection ladder, and exit-5/exit-6 lane
  troubleshooting. The profiles section was CORRECTED rather than written: on
  codex-cli 0.145.0 a profile cannot reach the `mcp-server` lane at all, so the
  doc defends the single top-level model key instead of qualifying it.

#### Worktree sweeper and out-of-repo scratch (Phase U2, epic `0yg`)

- **`.claude/scripts/worktree-sweep.sh`** — a report-only sweeper for
  platform-created worktrees under `.claude/worktrees/` that carry changes and
  therefore survive subagent teardown. Dry-run is the default and `--apply` is
  the only thing that removes; removal requires ALL of physical containment,
  same-repo identity via `--git-common-dir`, a clean `status --porcelain`,
  locally-decidable pushed-or-merged, age past `--age-days` (default 7), and a
  task id resolved FROM EVIDENCE that `bd` reports closed. Each rejected
  candidate prints its FIRST failing reason. SessionEnd runs it
  `--report-only` under a bound, never `--apply`, and writes its own log which
  SessionStart surfaces as a fourth warning.
- **Three patterns join the shared denylist** — see the upgrade note above.

#### The seventh contract field (Phase U3, REDUCED, epic `gio`)

- **`context_coverage`** is appended SEVENTH and last to the F7 completion
  contract in all four specialist carriers plus `docs/AGENTS.md` — never
  inserted mid-list, because `qa.md` section 10 promises the base fields keep
  canonical names AND ordering. Convention: what you read to ground the change
  / what you deliberately did NOT read and why / the largest remaining unknown
  you are shipping on.
- **Rubric criterion C8** with an empty/boilerplate/detached taxonomy mirroring
  `grader.md`; `.claude/rubrics/default.md` goes to version 2.
- **The contract's claimed enforcement now exists.** `docs/AGENTS.md` asserted
  the contract was enforced because "the QA agent's review checklist asks 'did
  the specialist return all six fields?'" — and `qa.md` section 3's checklist
  had six items, none of them that. It is now written, and AGENTS.md names
  `qa.md` section 3 so the citation is checkable.

#### A vendored design method, and one debugging protocol (Phase U4, REDUCED, epic `q37`)

- **`.claude/vendor/superpowers/brainstorming/SKILL.md`** — vendored from
  `obra/superpowers` at pin `3dcbd5c4` (MIT) as a REFERENCE DOC, not a
  registered skill. It loads exactly where wired (an explicit `Read` in
  `orchestrator.md` section 1) rather than session-wide, and it preserves
  "everything under `.claude/skills/` is registered in `plugin.json`" as an
  exact, exception-free invariant. Ten surgical local modifications, each with
  a measured upstream count, are annotated in the sibling `MANIFEST.md` —
  including the deletion of a `<HARD-GATE>` demanding user approval for every
  project (a second, prose-only release authority) and of a sentence
  suppressing `frontend-design`, which is a LIVE registered skill here.
- **EBF-CORE** — upstream `systematic-debugging` is MERGED into the existing
  evidence-before-fix protocol rather than shipped beside it as a competing
  voice. A delimited region is byte-identical across `qa.md`, `backend.md`,
  `frontend.md` and `devops.md`, carrying a precedence clause and a
  bounce-twice supremacy rule stated in-text as deliberately stricter than
  upstream's "3+ fixes".
- **Root `LICENSE` and `THIRD_PARTY.md`** — `plugin.json` declared MIT with no
  backing file.

#### Tests

Every count below was re-executed on **2026-07-30** for this release audit on
`gauntlet/v4.0.0`; see `docs/RELEASE_AUDIT.md` rows `UW1`-`UW12` for the
per-claim evidence pointers.

- **Nine new L1 specs** (the full delta against the `v4.0.0` tag, derived by
  `git ls-tree` rather than recalled): `packaging-parity.test.sh` (**623** — it
  extracts the merge expressions FROM source between literal sentinels and
  compares bash↔ps1 token identity; closes `bzy`),
  `workflow-manifest.test.sh` (131), `installer-flags.test.sh` (94),
  `workflow-doctor.test.sh` (94), `vendored-skills.test.sh` (94),
  `mcp-deps.test.sh` (55), `mcp-deps-preserve.test.sh` (49),
  `completion-contract-parity.test.sh` (45), `worktree-sweep.test.sh` (34).
  Of the existing specs, `denylist-source.test.sh` went 20 → **32**.
- **Eight new L2 specs**, likewise the full delta:
  `installer-v3-upgrade.sh` (**235** — the flagship, built on a genuine v3.5
  fixture rendered by **v3.5.0's own installer**),
  `rubric-binding.sh` (149), `installer-manifest-parity.sh` (139),
  `installer-target-functional.sh` (138 assertions across 968 lines and 41
  METAs — its section 6, `PATH=/usr/bin:/bin`, is the ONLY thing in the repo
  that can catch the SessionStart P0, because the doctor's own `session_start`
  check passes on a host that has `bd`), `approve-idempotency.sh` (93),
  `upgrade-gate-compat.sh` (89), `worktree-sweep.sh` (55), and `bd-mcp.sh`
  (28) — **there was no bd-mcp spec at all before this release, which is half
  of why the dead-server symptom shipped.** Of the existing specs,
  `denylist-shared.sh` gained section D, 36 → **79**.
- Suite totals moved L1 **23 → 32 files / 1,540 assertions**, L2 **33 → 41
  specs / 1,011 → 1,983 assertions**, L3 unit **430 → 444 passed / 5 skipped**.
  (The L1 file count includes the pre-existing `phase5-synthetic-tests.sh`,
  which the runner discovers because it globs `*.sh`, not `*.test.sh`; all
  nine additions are `.test.sh` files.)
- **Load-bearing METAs were verified by removal, not assertion.** The EBF-CORE
  identity check has a 40-non-blank-line floor plus both sentinels required
  inside the region, because two EMPTY regions compare equal — identity alone
  would be one `sed` away from meaningless. The reviewer reproduced this on the
  live files: identity-alone PASSED all three emptied comparisons while the
  region checker REJECTED all four.

### Changed

- **`make install-test` verifies function, not presence.** It was literally two
  `test` calls. It now runs `workflow-doctor.sh` against a rendered target and
  went from 9 passed / 2 failed to **11 / 0** — the P0 verified fixed by the
  check that was catching it.
- **`.gitignore` is healed rather than only seeded.** `npm ci` writes ~13,700
  files and the installer previously wrote a `.gitignore` only when the target
  had none, so a Go or Python operator saw every one of them untracked. The
  heredoc also closes the CHANGELOG-3.4.0 divergence and the backup/sidecar
  noise, with line-for-line ps1 parity via `Write-LfFile`.
- **Installer branding is version-dynamic**, read from `plugin.json` by a
  deliberately jq-free `sed` anchored on exactly two spaces — the top-level
  depth of the 2-space-indented manifest. A looser `[[:space:]]*` anchor took
  the FIRST own-line `version` key at ANY depth and would brand every run with
  a nested one.
- **`.claude/settings.json` and `.claude/hooks/hooks.json` parity is checked
  across the full event set**, not just SubagentStart. Generalising that
  checker immediately found a real divergence: `hooks.json` wires
  `^Bash$ → bd-github-link.sh` and `settings.json` does not, so the
  Beads↔GitHub auto-link has never fired in this repo's own sessions.
  Behaviour is unchanged and the allowance is pinned exactly; the decision is
  filed as `claude-workflow-plugin-eo8`.
- **`run_bounded` kills the process group** (`set -m` plus
  `kill -TERM -$pid`). The previous watchdog orphaned grandchildren — measured
  at 3 per timeout — and the bounded calls wrap node MCP servers and the Stop
  hook, so every timeout left the wedged process alive.
- **`docs/TROUBLESHOOTING.md` gains 191 lines** and had ZERO occurrences of
  "MCP" before this release; QUICKSTART makes the doctor the primary
  verification step; `docs/MCP_SERVERS.md` gains a Dependencies section.

### Fixed

- **A failing `npm ci` destroyed the operator's working tree (data loss).**
  `npm ci` removes `node_modules` before installing, so a failed re-install
  took a measured 3,909 files / 98 `package.json` down to 94 empty directories
  / 0. Fixed with skip-when-current plus preserve-and-restore, verified by
  construction: the shipped installer restores byte-for-byte while a
  set-aside-removed mutant takes both trees to 0/0. Found only because the
  first verification run used `--skip-mcp-deps` — the one flag that disables
  the code path capable of causing the harm.
- **A failed dependency install printed a green tail.** The failure printed
  `FAILED npm ci`, then "Installation complete." in green, then advertised
  "Two MCP servers", and exited 0. Now a three-arm headline, a qualified
  advert, and a `DEPENDENCY UPDATE DID NOT FINISH` block naming each server
  and its fix command. Related: a failed `npm ci` leaves `node_modules` as an
  empty husk (94 directories, 0 files), so `[ -d node_modules ]` answered TRUE
  for a tree that cannot boot — replaced by `mcp_server_has_deps`.
- **An upgrade could destroy operator bytes while reporting them safe.** The
  shipped-docs surface was extended without backup legs across three arms plus
  an uncited v2 leg, so the report said "yours is in the backup" over files
  that had none. Fixed structurally with a derived `$SHIPPED_DOCS` and one
  shared backup helper across seven legs, with a META proving the report string
  was never an oracle for recoverability.
- **`install.ps1` was already WinPS-5.1 parse-broken at 4.0.0.** The
  `windows-install.yml` evidence is pwsh-7-only, so the breakage was invisible.
  Repaired across seven sites with an ASCII guard and METAs to prevent
  regression. This is a source-level repair; see the residual below.
- **A CI-red and a ~8 % flake at one line.** `workflow-doctor.test.sh`'s
  non-mutation assertion compared file AGE, which is a function of wall-clock
  time and changed with zero mutation whenever a run crossed a minute boundary;
  and `stat -f %m` is the BSD spelling, where GNU's `-f` is
  `--file-system` and writes 248 bytes of unrelated output to stdout that a
  `$(A || B)` capture then concatenates onto the fallback's answer. Both close
  by snapshotting raw mtime, GNU-first. Discrimination is retained: touching
  the marker still FAILS on both platforms.
- **`.claude/worktrees/` is gitignored at the project root.** It had been
  denylisted since v4 but never ignored (`:71` covered only the e2e-fixture
  nesting), so a leftover worktree was invisible to the gate AND visible in
  `git status`.

### Not shipped, and why

No claim in this release covers any of the following. They are recorded here
because a plan that is silently under-executed is indistinguishable from one
that failed.

- **U5, staging e2e QA with injected auth (epic `f2t`) — CANCELLED, not
  deferred.** There is no date at which it becomes correct. Four reasons in
  order of weight: it has the most external dependencies of any phase in this
  release; the largest security surface, since injected auth means credentials
  in a harness the plugin drives unattended; it is the only phase requiring
  live paid runs to verify, so its evidence would be the weakest in a release
  whose standing rule is that no adjective ships without an artifact; and the
  provider abstraction it implies stays speculative until a SECOND project
  validates the shape. Revisit when that project exists.
- **U3's ledger and frontier harness (epic `gio`) — DEFERRED on
  `claude-workflow-plugin-gio.1`**, behind an evidence bar of three closed
  tasks exhibiting the same blind spot. What shipped is the `context_coverage`
  field and rubric C8, above. The motivating problem — a 14-PR speculative-fix
  chain — is already solved by evidence-before-fix, which is shipped and
  mechanically guarded, so building the harness now would be machinery ahead of
  evidence. There is no `.claude/context-config`, no `context-ledger.sh` and no
  orchestrator wiring.
- **U6, the nested-spawn depth-3 migration (`7be`) — CLOSED as
  need-triggered.** `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` stays pinned.
  Depth-1 is not a limitation awaiting removal; it is itself an enforcement
  mechanism, because a subagent that cannot spawn subagents structurally cannot
  procure its own review — which is exactly the separation the gate's
  independence predicate exists to guarantee. Migrating would mean building a
  parent-role guard to restore in software a property the platform default
  gives for free. **The 2026-08-23 next-check date recorded on that task is
  RETIRED and is not a live date**; the standing task
  `claude-workflow-plugin-1bn` states the trigger as a condition — raise the
  pin WHEN a concrete workflow needs nested spawn — never as an elapsed month.
- **`wearclair-module`**, named in the original U4 request, remains
  unidentified after two independent checks (not among the 14 `SKILL.md` files
  at the pin, no web presence). Recorded as a skip.

## [4.0.0] - 2026-07-26

**The tri-model workflow.** The orchestrator plans on the newest, most
capable Claude family; implementation specialists build on the newest
Opus-class model; an optional external reviewer lane reads the same diff on
a second model family (Sol, through the Codex CLI's MCP-server mode). The
governing rule is **nobody signs off on their own work**, and as of this
release that is mechanical rather than advisory: `qa-gate.sh approve`
REFUSES unless the task carries a review artifact whose reviewer identity
differs from every recorded implementer, and the Stop hook re-runs the same
predicate before releasing. The change-set-hash-bound `qa-approved` record
from 3.5.0 remains the **only** release credential — the Sol lane, the
second opinion, and arbitration are inputs feeding that one gate, never a
parallel approval path. Alongside it, the gate learned to evaluate work
*where it happened*: baseline-scoped change sets, one shared denylist, and
a cross-worktree approval bridge, because the tri-model loop runs
implementers and reviewers in parallel linked worktrees.

**Why this is a major.** The Stop-gate release predicate gained two new
necessary conditions (an independent review artifact whose reviewer is not
an implementer, and zero unresolved at-or-above-threshold findings), and
the change-set denylist changed — so an approval recorded under 3.5.0 no
longer releases without a re-approve. Operators of installed projects
should re-run the installer in update mode to pick up the settings
migration below.

> **UPGRADE NOTE — one-time hash migration.** The change-set denylist changed,
> so the Stop hook recomputes a DIFFERENT `change_set_hash` for any change set
> containing a newly-filtered path. An approval recorded before this landing no
> longer matches that hash: the gate emits `LABEL_WITHOUT_RECORD` and re-blocks
> until the cycle is re-approved. That is the correct fail-closed direction — a
> stale approval must not release — and every denylist addition in this release
> ships in ONE landing, so an in-flight cycle pays the migration exactly once.
> Recovery for a cycle caught mid-flight (see `docs/HOOKS.md`, "Denylist changes
> are a hash migration"):
>
> ```bash
> bash .claude/scripts/qa-gate.sh enter <task-id>
> bash .claude/scripts/impact-report.sh <task-id>
> bash .claude/scripts/qa-gate.sh approve <task-id> '<summary>'
> ```
>
> That is the whole recipe — the same three commands the block reason prints, and
> no `bd label remove` step. On 4.0.0 exactly, retiring the stale `qa-approved`
> label first WAS required, because `enter` does not clear it and `approve`
> short-circuited on its mere presence; `approve`'s idempotency is now hash-aware,
> so a stale label no longer stops it (see `docs/HOOKS.md`, "Approve idempotency
> is hash-aware", and `claude-workflow-plugin-gz3`). Both routes are pinned by
> `denylist-shared.sh` section C: C4 drives the commands extracted from the block
> reason, C5 keeps the explicit-label-removal variant working.

### Added

#### Role-aware model selection (Phase V1, epic `bi3`)

- `.claude/model-roles` config maps each ROLE to a selection STRATEGY —
  `orchestrator=top` (the resolver's single best pick: newest, most capable
  family), `implementer=opus-class` (the newest `claude-opus-*` in the
  listing, falling back to `top` when none is listed), `reviewer=top`.
  Setting every role to `top` reproduces v3.5 single-pin behavior exactly;
  a missing file, missing key, or unrecognised value fails open to `top`.
- `model-select.sh` resolves per role behind an all-or-nothing MANUAL gate
  and writes `.claude/.qa-tracking/model-roles-resolved.json` atomically
  (stale beats none); it gains a `roles` subcommand and per-role `status`.
  `workflow-model-apply.sh` gains `--role <role> <id>` and
  `--print-role-map` (a bare `<id>` remains the pin-everything rollback).
  The statusline renders `orch:/impl:/rev:` when the roles diverge and
  collapses to the v3.5 single-model display when they don't.
- Day-zero adoption is preserved *within* each class: newest by release
  metadata, largest context variant, ranking file as override/exclusion
  only, unrecognized families as first-class candidates, and a Beads
  meta-task comment with a rollback command on every switch.
- The `!claude-fable` regional exclusion was lifted from
  `.claude/model-ranking` (evidence-gated, dated, with a rollback line;
  `!claude-mythos` kept).

#### The optional Sol reviewer lane (Phase V2, epic `1vq`)

- An **advisory, strictly optional** external reviewer lane: GPT-5.6-Sol
  reached through the Codex CLI's MCP-server mode. Absent, failed, or
  timed-out Codex behaves identically to "not connected" — the plugin's
  fresh-context Claude review path covers the reviewer role, proven
  byte-identical by a dedicated degradation spec. Sol writes no labels and
  records no approval; its artifact is grading-packet item 8.
- Helpers: `codex-detect.sh` (a layered, bounded, fail-open feature-detect
  writing an atomic reviewer-lane flag), `.claude/review-config` (the ONE
  place bounded-diligence caps live), `review-check.sh`
  (`validate-request` / `validate-artifact` / `gate` — the one counter,
  structurally codex-free), and `codex-review.sh` (a FIFO JSON-RPC driver
  with caps, cap-truncation, and a timeout).
- **Bounded diligence is mechanical.** Every review delegation carries a
  mandatory `risk_threshold` and `stop_condition` (the harness rejects a
  request missing either), and the caps in `.claude/review-config`
  (`max_findings`, `max_review_iterations`, `timeout_seconds`,
  `malformed_retry`) bound the turn: hitting one sets the artifact's
  `stopped_by` (`cap:max_findings` | `cap:max_review_iterations` |
  `cap:timeout`) instead of looping.
- Review artifact schema, strict JSON, recorded on the Beads task:
  `{reviewer_identity, reviewer_model, findings:[{severity, location,
  evidence, description}], verdict, iterations, stopped_by}`.
- Prompt wiring: `qa.md` §6-prime (the advisory review-artifact step),
  `orchestrator.md` §5c REVIEW-RELAY (paid, cost-confirmed), and the
  grading packet reconciled to eight items (item 8 advisory,
  non-criterion).
- `docs/CODEX_SETUP.md` — the operator setup doc, a first-class
  deliverable: every command live-verified; both auth paths and their
  billing implications; user-scope registration (mechanically required —
  the detector reads only top-level `.mcpServers.codex`); model-pinning
  guidance that extends day-zero adoption across the vendor boundary;
  verification and troubleshooting tables.
- **The Codex model pin lives in `~/.codex/config.toml`, not in the
  registration** (`docs/CODEX_SETUP.md` §5 and §7; finding
  `claude-workflow-plugin-gl6`, from the live validation below). codex-cli
  0.145.0's `mcp-server` mode ignores the registration's `-m <slug>` flag,
  and a `-c model=…` override does not stick either — the config file is
  authoritative, while `-m` only supplies the `reviewer_model` string the
  artifact records. A slug the ChatGPT-account backend rejects (e.g.
  `gpt-5.2-codex`, HTTP 400 "not supported when using Codex with a ChatGPT
  account") therefore fails the review turn with `codex-review.sh` exit 5.
  That path degrades to the Claude lane with zero behaviour change, as
  designed, so this is an operator-config trap rather than a plugin defect —
  the setup doc now carries the diagnosis, the one-line fix, and a free
  `codex doctor --json` check for the resolved model.

#### Sign-off separation and arbitration (Phase V3, epic `jio`)

- **Nobody signs off on their own work, enforced by the gate.**
  `qa-gate.sh approve` now REFUSES (exit 4) unless the task carries a
  review artifact whose `reviewer_identity` differs from every recorded
  implementer AND has zero findings at/above the artifact's
  `risk_threshold` still open. `verify-before-stop.sh` re-runs the SAME
  predicate before releasing, because findings can be recorded AFTER an
  approval and the write-once approval record cannot know about them. Both
  ends CALL the one shipped counter (`review-check.sh gate`) — there is no
  second implementation of the counting.
- Implementer identity is recorded at spawn: `subagent-start.sh` appends
  `IMPLEMENTER: role=<backend|frontend|devops> task=<tid> at <ts>` (once
  per role+task, best-effort, never blocks a spawn). `qa` is deliberately
  excluded — it reviews, and recording it would make every single-agent
  review non-independent.
- Approval records name the reviewer:
  `QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> at <ts>: <summary>`.
  The new token is space-separated AFTER the hash, so the llh.18 hash
  capture is byte-compatible (pinned by a test running the Stop hook's
  exact `jq`).
- Audited bypass `approve --no-review '<reason>'` (mirrors
  `--no-impact-report`; an empty reason exits 1). It stamps
  `[review bypass: <reason>]` on the approval record, which is the marker
  the Stop hook's discipline check skips on. The F1 doc-only /
  beads-state / empty fast path uses it automatically — a doc-only change
  has no implementer and nothing to review.
- Both new checks FAIL CLOSED: a missing or unrunnable `review-check.sh`
  refuses at approve and blocks at Stop. `review-check.sh` and
  `impact-report.sh` joined the installers' critical-path file list, so a
  partial install fails loudly at install time instead of deadlocking the
  gate later.
- **Arbitration of disputed findings** (`orchestrator.md` §5d). When the
  implementing specialist disputes an at-threshold finding, exactly two
  things clear it: RESOLVE with evidence (`qa-gate.sh resolve-finding
  <tid> <fid> --fix '<ref>' --test '<ref>' '<summary>'` — both refs
  mandatory, evidence-before-fix as a record) or ARBITRATE (`qa-gate.sh
  arbitrate <tid> <fid> <overrule|sustain> '<rationale>'`). `overrule`
  clears the gate count; `sustain` keeps the finding OPEN as the audit
  record of a dispute that was heard and upheld — which is what makes an
  overrule mean anything. Arbitration is the ORCHESTRATOR's job: the
  reviewer and the author are the two parties, so only the third can
  adjudicate, and the rationale must cite both positions. The prompt is
  guidance; the enforcement is the gate count.
- **Live-harness invariant `approval-cites-independent-review`** — the
  trace-side proof that the mechanism held during a real run. For EVERY
  `QA-GATE APPROVED` record: it names a reviewer (or carries the audited
  `[review bypass:` marker), an EARLIER `REVIEW-ARTIFACT v1` exists whose
  `reviewer=` is not one of the task's `IMPLEMENTER: role=` identities,
  and replaying the preceding records leaves zero open at-threshold
  findings (`RESOLVED … fix= test=` and a latest `ARBITRATION …
  decision=overrule` clear; `sustain` does not). It is a deliberate SECOND
  implementation of `review-check.sh gate`'s predicate, in TypeScript over
  a different input — if the shell counter is subverted or a fixture ships
  a stale copy of the gate, the two disagree and that disagreement is the
  signal. Declared in all seven fixture `invariants:` blocks.
- The e2e trace gained an OPTIONAL `beadsComments` field
  (`{task, text, order}`), captured post-run by `readBeadsComments()` from
  the same already-flushed `.beads/issues.jsonl` the label capture reads
  (no extra `bd` invocation). ABSENT means "not captured" and the
  invariant SKIPS (pre-jio.2 traces are not retro-failed); an EMPTY ARRAY
  means "captured, bd held nothing". Approvals with no `reviewed_by=`
  token skip as a pre-V3 recording.

#### Worktree-aware gate scoping (Phase V4, epic `3mg`)

The tri-model loop runs implementers and reviewers in parallel worktrees, so
the gate must evaluate work where it happened. Three production transcript
scenarios are closed.

- **Approval records name the approving checkout.** `qa-gate.sh approve`
  appends a `worktree=<tok>` token — the checkout's git toplevel, spaces
  `%20`-encoded so it stays ONE space-terminated token, `none` off a git
  checkout (never omitted: a stable grammar is what lets a reader tell "no
  worktree recorded" from "recorded but unresolvable"). Every approve path
  reaches the one record writer, including the F1 fast path and both
  audited bypasses:

  ```
  QA-GATE APPROVED change_set_hash=<h> reviewed_by=<id> worktree=<tok> at <ts>: <summary>
  ```

  Token ORDER is the compatibility contract: every addition since llh.18
  goes AFTER the hash token, space-separated, so the v3.5
  `change_set_hash` and V3 `reviewed_by` captures extract identical values
  from the old and new shapes. Pinned by a differential META
  (`review-separation.test.sh` 4.2b) that strips the `WORKTREE-TOKEN`
  sentinels from a copy of `qa-gate.sh`, approves with it, and runs BOTH
  reader expressions over BOTH record shapes plus a renamed token.
- **The Stop hook resolves cross-worktree approvals**
  (`WORKTREE-RESOLUTION` in `verify-before-stop.sh`). This closes the
  deadlock where a review performed in a linked worktree recorded a
  change-set hash the primary checkout could never reproduce, so its Stop
  hook reported "qa-approved label present but no change-set-bound
  approval record matches" forever. Only on the path that already blocks,
  the hook tries the recorded token first (O(1)), then `git worktree list
  --porcelain`, skipping the current checkout, capped at 16 candidates. A
  candidate releases only when ALL of these are positively proven: it is a
  worktree of this repo (symlink-resolved `--git-common-dir`, never a
  toplevel string compare); its persisted `impact-report-<tid>.json`
  carries a `change_set_hash` that a real approval record on the task
  cites; its own `git status` minus its own `gate-baseline` is empty (no
  post-approval drift there); every reviewable path in THIS checkout is
  inside that report's approved file set, compared repo-relative; and the
  V3 `review-check.sh gate` predicate is still clean (same audited
  `[review bypass:` escape) — so a finding recorded after the approval
  re-arms this path too.
- **Record-based, not recomputed.** `approve` truncates
  `changed-files.txt` in the approving checkout, so a recompute there
  returns the sha256 of the empty list — the approved hash is
  unreproducible even in the worktree that produced it. The resolution
  therefore reads the persisted impact report, which survives approve. The
  L2 spec asserts both the truncation and the diverging recompute, so
  making that truncation conditional fails loudly instead of silently
  disabling resolution.
- **Read-only, fail-closed, no MCP boot.** File reads plus `git worktree
  list` / `git rev-parse` / `git status` / `jq`. Nothing is written
  anywhere (the spec re-checksums the candidate worktree), and the
  code-graph MCP server is never booted (asserted with an armed canary
  that is proved live on an `enter` and silent on every Stop). Any error,
  unreadable artifact, or ambiguity falls through to the block. A removed
  worktree is named in the block reason ("bound in worktree `<path>`,
  which no longer exists"); otherwise the reason gains "(checked N
  worktree(s))".

#### Platform restore and the effort verdict (Phase V0, epic `cnz`)

- Effort-verdict launch wiring: a committed `.claude/effort-verdict`
  (verdict `max`, recorded by the cnz.2 A/B interference test), a
  `make session` launch target that execs `claude --effort <verdict>`, and
  session-start Warning 4 verdict reconciliation plus Warning 5 platform
  guards (`CLAUDE_CODE_SUBAGENT_MODEL` override, subagent spawn-depth
  drift).
- Subagent spawn evidence log
  (`.claude/.qa-tracking/subagent-spawns.log`, written by
  `subagent-start.sh`) and SubagentStart wiring in `settings.json` (parity
  with `hooks.json`).
- `docs/EFFORT-AB-TEST.md` runbook and the recorded A/B outcome:
  ultracode showed ZERO orchestration interference (the pre-registered
  expectation was NOT confirmed), but `max` remains the verdict per the
  runbook's conjunctive rule — criteria 2-3 were not fully re-verified
  under the operator's time-box and no benefit was observed, since
  ultracode runs the model at a fixed `xhigh` proxy below the `max` this
  verdict pins. Details on meta-task `claude-workflow-plugin-4o2`.

#### Tests

Every count below was re-executed on 2026-07-26 for the release audit; see
`docs/RELEASE_AUDIT.md` rows TM1-TM14 for the per-claim evidence pointers.

- New L1: `model-roles.test.sh` (40), `review-check.test.sh` (39),
  `review-count.test.sh` (38), `review-separation.test.sh` (60 incl. the
  strip-META and the 4.2b differential token META),
  `denylist-source.test.sh` (20 incl. 4 METAs), `platform-audit.test.sh`
  (18 incl. two META groups), `make-session.test.sh` (7 incl. the
  verdict-ignoring-stub META). `effort-fail-open.test.sh` (14) was
  inverted to the new no-env-pin baseline.
- New L2: `codex-detect.sh` (24), `codex-review.sh` (25),
  `reviewer-lane-degradation.sh` (8), `review-separation-records.sh` (16),
  `verify-review-discipline.sh` (24), `arbitration-acceptance.sh` (33),
  `model-roles-parity.sh` (10 incl. the liar-misroute META),
  `denylist-shared.sh` (33), `gate-baseline-v2.sh` (46),
  `worktree-approval-resolution.sh` (**67 assertions authored, 65
  executed** against a REAL `git worktree add` — the two `wtres-2.1`
  pre-fix legs are conditional on the committed HEAD predating the fix and
  are permanently superseded by the section-8 sentinel-strip META; this
  corrects the pre-release dev note's "55", 3mg.2 QA finding R1-F1).
  `model-select.sh` grew the `ms-R1..R6` role cases and the `ms-T1..T5`
  tier-vs-recency regression (88 total); `subagent-start.sh` grew 13
  identity assertions incl. an idempotency-break META (30 total);
  `failure-cross-repo.sh` gained the worktree cases (19);
  `qa-gate-baseline.sh` was retargeted at the v2 baseline file (23).
- L3 unit: `_invariants.unit.spec.ts` (102) covers
  `approval-cites-independent-review` with both plan-mandated METAs plus a
  mechanical META-COVERAGE assertion — every `INVARIANTS` row must ship a
  META-TEST or a documented exemption (only `completion-contract`, which
  is always skipped). Sensitivity was proven by mutation: neutering
  independence, making open findings non-fatal, letting `sustain` clear,
  flipping the skip to a silent pass, and registering a META-less
  invariant each turned the matching test red; every mutation was
  byte-restored. `_beads-capture.unit.spec.ts` gained a real-`bd` round
  trip proving the three record grammars survive capture in write order.
- Load-bearing METAs were verified by removal, not assertion: both
  sentinel blocks and the `subagent-start.sh` idempotency guard were
  stripped from the real scripts to prove the protected assertions go red
  — 25 / 10 / 4 failures respectively, as recorded by the implementing
  tasks (`jio.1`/`jio.2`) at the time; the release audit re-ran the suites
  green rather than re-running those one-off mutations. Four existing
  METAs that copied a hook to a fixture ROOT now copy it into
  `.claude/scripts/` — outside that directory the copy cannot find the
  shared denylist lib and blocks for the wrong reason, a silent false
  pass.
- Existing approve-reaching specs migrated to seed real review records via
  a shared `seed_review_records` fixture helper.
- **Live tri-model validation ran 2026-07-26
  (`claude-workflow-plugin-d2j.2`) — both legs PASSED.** Codex CONNECTED:
  `codex-review.sh` drove the REAL Codex MCP server on `gpt-5.6-sol`
  (read-only sandbox, no subagent spawning), Sol returned a schema-valid
  `verdict=findings` artifact with a genuine medium finding, and the real
  gate scripts BLOCKED it (`independent:true`, one open at-threshold
  finding) until an orchestrator `arbitrate … overrule` cleared the count.
  Codex ABSENT: feature-detect resolved `reviewer_lane=claude` and a
  same-schema `qa-claude`/`claude-fable-5` artifact drove the IDENTICAL
  sequence. Reviewer identity, model and finding quality differed; the gate
  DECISIONS were byte-identical — which is the release claim, confirmed
  live rather than only by the offline degradation spec. Scope stated
  plainly: the subject was a small synthetic harness driven through the gate
  scripts directly, not a full specialist→QA→grader cycle, so no e2e trace
  was captured and the `approval-cites-independent-review` invariant remains
  proven offline only. `docs/RELEASE_AUDIT.md` rows TM7/TM14 carry the
  result and that caveat.

### Changed

- **ONE denylist, three consumers.** New
  `.claude/scripts/workflow-denylist.sh` defines
  `WORKFLOW_DENYLIST_REGEX` + `workflow_denylisted()`; `post-edit.sh`
  (what gets TRACKED), `impact-report.sh` (what enters the change set and
  its HASH) and `verify-before-stop.sh` (what needs REVIEW) all source it,
  BASH_SOURCE-relative. The three copies had drifted: only the Stop hook's
  knew about `.claude/worktrees/` and the e2e fixture churn, so post-edit
  tracked worktree paths INTO the hash that the gate could not see — the
  hash and the gate disagreed about what "the changes" were. Now
  guaranteed to move together: harness-worktree paths leave the tracked
  set, the hash and the gate's view agree, and a change set of only
  build/workflow churn is `empty` rather than half-visible.
- **Memory files are no longer reviewable work.** `MEMORY.md` and
  `.claude/memory/` join the denylist, so they exit the change set BEFORE
  F1 doc-only classification: a memory-only change set now takes the
  `empty` fast path (release, no gate record) instead of being
  auto-approved as `doc-only` with a `[review bypass: F1 doc-only ...]`
  record about agent recall state. `CLAUDE.md` (behaviour-bearing —
  session-start injects it), `LESSONS.md` and `HANDOFF.md` (audit
  deliverables) are deliberately NOT denylisted.
- **Missing-lib behaviour is fail-closed per consumer**: `impact-report.sh`
  exits 3 (no hash, which upstream already treats as refuse-to-release),
  `verify-before-stop.sh` BLOCKS with a remediation reason (after the
  `stop_hook_active` circuit breaker, never before it), and `post-edit.sh`
  tracks the path unfiltered — over-tracking is the fail-closed side for a
  hook whose output feeds the gate.
- **gate-baseline v2.** `.claude/.qa-tracking/approved-baseline` (a bare
  line list, one writer) is superseded by
  `.claude/.qa-tracking/gate-baseline`, a versioned file with a provenance
  header (`head=`, `captured_at=`, `captured_by=`) over the
  `LC_ALL=C`-sorted `git status --porcelain` snapshot. Three writers now:
  `session-start.sh` on arrival (only when no review cycle is active —
  baselining an in-flight cycle would release its work unreviewed),
  `qa-gate.sh enter` (write-if-missing, minus paths already in
  `changed-files.txt` so the session's own edits are never baselined), and
  `qa-gate.sh approve` (full refresh, as before). New subcommand
  `qa-gate.sh baseline-capture [--by <who>] [--if-missing]
  [--exclude-tracked]` so session-start has one implementation to call.
  The legacy file is read as a fallback for one release and deleted on the
  first v2 write. This closes the "session opened in an already-dirty repo
  blocks on dirt the session never made" case; there is deliberately NO
  hash-side subtraction (the baseline is subtracted only in the git
  fallback, so editing an already-dirty file still gates).
- **`-d "$PROJECT_DIR/.git"` replaced by `git rev-parse --git-dir`** in
  `verify-before-stop.sh` and `qa-gate.sh`. In a LINKED WORKTREE `.git` is
  a FILE, so the old predicate answered "not a git repo" and silently
  disabled both the baseline writer and the Stop gate's git-status
  fallback — with an empty `changed-files.txt` the gate then had no
  detector at all and FAILED OPEN, in exactly the
  `isolation: "worktree"` topology the plugin tells agents to use.
- **The I8 cross-repo guard compares REPOSITORY identity, not checkout
  identity.** `detect_cross_repo` used `git rev-parse --show-toplevel`,
  which is per-checkout, so a Stop fired from a linked worktree of the
  SAME repo the task was claimed in tripped the cross-repo block. It now
  compares the symlink-resolved `git rev-parse --git-common-dir`, which
  every worktree of a repo shares and which differs across repos. A
  genuinely different repo still blocks; a recorded repo path that no
  longer resolves is still a mismatch (fail closed).
- **`qa-gate.sh choose approve` is no longer an unconditional escape**
  (J21 correction, `orchestrator.md` / `qa.md`). It delegates to the same
  `cmd_approve` as a direct approve, so it refuses while an at-threshold
  finding is open — a cap-hit escalation does not dissolve a dispute;
  arbitrate or resolve first. The same correction was applied to the
  rubric override in `qa.md` 6f (a judgment override does not satisfy a
  mechanical gate) and to the then-stale V2 scope notes in
  `orchestrator.md` 5c / `qa.md` 6p.3.
- `settings.json`: removed `env.CLAUDE_CODE_EFFORT_LEVEL` (a non-xhigh
  value there deactivates ultracode's orchestration layer per the live
  docs, leaving `effortLevel: "xhigh"` as the durable floor); pinned
  `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1` (v2.1.219 flipped the platform
  default to depth 3; the relay architecture assumes depth 1).
- Installers (`install.sh` / `install.ps1`): the update-mode settings
  merge now deletes the legacy `env.CLAUDE_CODE_EFFORT_LEVEL` key (with a
  one-line notice), so installed projects migrate on their next update;
  the operator's own `env` keys and the `effortLevel` floor survive the
  merge and the deletion is idempotent. Both installers ship the new
  configs (`.claude/model-roles`, `.claude/review-config`,
  `.claude/effort-verdict`).
- `docs/MCP_SERVERS.md`: bd-mcp troubleshooting for installed projects
  (v2.1.196 workspace-trust behavior, the `${CLAUDE_PROJECT_DIR:-.}`
  form), cross-linked from README Caveats. The CONTRIBUTING effort recipe
  was rewritten to the three-layer model (floor `effortLevel: xhigh` /
  session verdict via `make session` / frontmatter `effort: max` ceiling).
- `docs/HOOKS.md` documents the verified cross-worktree topology, the
  fail-closed guarantee, and "Denylist changes are a hash migration".

### Fixed

- **The model resolver ranked recency above capability class (bug `en9`).**
  `pick_best` sorted by recency FIRST, so a newer but less capable family
  took the `top` lane: with `claude-opus-5` (created 2026-07-24) in the
  same listing as `claude-fable-5` (2026-06-07), orchestrator/qa/grader/
  judge were dragged onto Opus and the v4 role split collapsed to a single
  model. The sort is now `[._class, -(._ts), -(._ctx)]` — capability class
  (the family's position in `.claude/model-ranking`) PRIMARY, recency only
  WITHIN a class. An UNKNOWN family is ranked in the TOP class, so
  day-zero adoption of a genuinely-new above-Fable tier still wins on
  recency; the documented residual (a new BELOW-Fable family also landing
  in the top class) is covered by the unknown-family warning and a
  `!<family>` exclusion. Exclusions still filter first; the MANUAL-adopt
  and fail-open contracts are unchanged. Verified RED against the pre-fix
  resolver (pass=76 fail=12) and GREEN after (pass=88 fail=0), with the
  required `ms-TM` META — a `pick_best` reverted to the recency-primary
  sort must make `ms-T1` fail. `ms-Y` was re-scoped from cross-family to
  intra-class recency (it asserted the pre-en9 contract) and passes
  against both resolvers.
- **Two mid-review defects in the Sol lane** — a silently-non-executing
  test and a gate finding-suppression hole — were found during 1vq.1 and
  closed with load-bearing METAs.
- **PR #2 (`impact-report.sh` path relativisation) reconciled.**
  `impact-report.test.sh` section 4 still asserted the pre-PR#2 contract
  and only ran where a code-graph server is present (it skips in CI, so
  the divergence was invisible there). Out-of-project and
  unanchorable-relative entries are now recorded as explicit
  `skipped: path is outside the analyzed project ...` entries rather than
  being sent to the tool, so the report can no longer contain the server's
  absolute-path validation error.

## [3.5.0] - 2026-06-14

The **Release Acceptance Gauntlet**. Epic `claude-workflow-plugin-llh`
put every shipped claim through an adversarial certification —
operating rules: no adjective without artifact, prove-or-remove,
mechanics over prompts, dogfood throughout, hard $80 paid cap. The
output is a 121-row claims ledger (`docs/RELEASE_AUDIT.md`) re-tallied
mechanically at the verdict to **PROVEN 51 / PROVEN-WITH-CAVEAT 47 /
REMOVED 23 / NOT-PROVEN 0**. The gauntlet found and fixed a release-gate
P0 (a forgeable approval label that released unreviewed code), hardened
the Stop invariant against it, removed 13 stale-doc claims that no longer
matched the code, and red-team-certified that the gate does not leak
under live load — confirmed on two paid runs ($10.15 of $80): a
node-react-auth feature shipped end-to-end through the gate, and a
python-django-bug bugfix run whose unreviewed change the hardened gate
correctly BLOCKED. The guarantee: **51 claims proven by executed tests,
47 caveats documented and tracked, zero unproven claims shipped.** The
release rule (NOT-PROVEN = 0 AND Stage-3 P0/P1 closed) is MET.

### Added

- **Change-set-hash-bound QA approval — the P0 fix (llh.18).** The Stop
  gate no longer releases on the bare `qa-approved` label. `qa-gate.sh
  approve` now writes a tamper-evident approval record carrying
  `change_set_hash` — the sha256 of the sorted, denylist-filtered diff
  via `impact-report.sh --hash-only` (`qa-gate.sh:230,730-749`) — and
  `verify-before-stop.sh` requires a record whose hash matches the
  *current* change-set, not the label
  (`task_has_matching_approval_record`, release predicate
  `:1101-1146`). A bare label-add writes no record → block; a decoy-task
  approval has a different hash → block; any post-approval edit changes
  the hash → re-block. The release predicate fails CLOSED on a missing or
  unrecomputable hash. A load-bearing META-test proves the check is
  load-bearing (neutralize the hash comparison → a forged label
  releases).
- **`impact-report.sh` — mechanical impact analysis (G2.n6d, llh.2).**
  A deterministic driver that runs code-graph `impact_of` over the
  changed files at gate-enter and writes
  `.qa-tracking/impact-report-<task>.json`
  (`{generated_at, task_id, change_set_hash, files:[{file,impact}],
  server}`). `qa-gate.sh approve` REFUSES (exit 2) without a
  hash-current artifact; the documented bypass `approve
  --no-impact-report '<reason>'` lands in the audit trail. L1
  `impact-report.test.sh`.
- **bd-compatibility L2 spec (G2.bd-compat, llh.6).** `bd-compat.sh`
  pins 32 distinct `bd` command+flag invocations — inventoried from
  every hook script, bd-mcp, and the e2e capture lib — each run against
  the installed `bd` (0.47.1) and asserted to the EXACT output shape the
  caller parses (verbatim production `jq`). 71 assertions / 0 fail,
  auto-discovered into `make test-all`. Three load-bearing contract
  subtleties are pinned (create returns an OBJECT vs show/update
  1-element ARRAYS; `bd close` on a BLOCKED issue is an exit-0 no-op;
  `bd list --type epic --json` carries no `.dependents` on 0.47.1). A
  non-vacuity META-test fails loudly with a supported-range banner on
  shape mismatch.
- **`windows-install.yml` CI job (G2.ps1, llh.7) — dispatch-only.**
  `.github/workflows/windows-install.yml` (windows-latest,
  `workflow_dispatch` only, zero API spend) ports 27 parity assertions
  from `installer-mcp-config.sh` and includes a code-graph-mcp stdio
  `initialize` boot-check validated locally on macOS
  (`serverInfo={code-graph-mcp,1.0.0}`). It is authored but undispatched
  — gh's token scopes (`gist, read:org, repo`) lack `workflow`, so
  `install.ps1` is verified by parity inspection + local boot, not
  Windows execution (see Security/residuals).
- **Claims ledger (`docs/RELEASE_AUDIT.md`).** The 121-row artifact of
  the gauntlet: every README / QUICKSTART / docs / installer / agent-
  prompt claim plus the seven implicit gauntlet-spec claims, each with a
  verification method, an evidence pointer, and a status. Re-tallied
  mechanically at the verdict (grep over end-anchored status cells).

### Changed

- **Stop-requires-approval invariant hardened (llh.25 disposition).**
  The live `invStopRequiresApproval` check now excludes H3
  `stop_hook_active` re-entry guards (16ms `{}`-and-exit-0 anti-loop
  bail-outs were being mis-counted as approval leaks) and skips on
  bd-unavailable (a crashed bd daemon zeroes out label writes, which is
  an infra failure, not a gate leak).
- **Label-event deriver matches var-bound `bd` (llh.23).** The e2e
  label-transition deriver maps the variable-bound `bd` command shapes
  the live workflow emits, not only the literal seed-fixture forms, so
  `qa-pending → qa-approved` milestones derive from real runs.
- **Stop-hook fast-path extended (G2.gate-friction, llh.3/llh.17).**
  The doc-only fast path now also short-circuits beads-state-only diffs,
  empty post-denylist change-sets, and transient e2e fixture-script
  churn — the false-block cases the original fast path missed,
  reproduced as L2 cases first.
- **`bd close` stdout no longer pollutes the verdict (llh.20).** The
  `✓ Updated issue` banner bd prints on close is suppressed/redirected
  before `verify-before-stop.sh` emits its `{}` verdict, so the Stop
  hook's JSON is not corrupted by bd's success chatter.

### Fixed

- **Red-team P0: forgeable approval label (llh.18).** A bare `bd label
  add <task> qa-approved` (every agent has `bd`) released unreviewed
  code because the Stop predicate reduced to `has_label qa-approved`,
  skipping the impact-report refusal, audit comment, and rubric that
  `qa-gate.sh approve` enforces. Closed by the change-set-hash-bound
  approval record (see Added).
- **Red-team P1: decoy current-task redirect (llh.18).** The gate
  checked approval of whatever `current-task` pointed at and never bound
  it to the tracked changed files — approve a trivial decoy, repoint
  `current-task`, ship unrelated unreviewed code. Closed by binding the
  approval record to the change-set hash.
- **Fail-open in the P0 fix (llh.18).** The first iteration of the
  hash-bound check could pass when the hash was missing/unrecomputable;
  the release predicate now fails CLOSED in that case.
- **13 stale-doc claims (prove-or-remove).** Claims contradicted by the
  current code/config were removed or rewritten: the hook-event count
  (5 → 6 in settings.json + a 7th, SubagentStart, in hooks.json:
  H1/AR1/Q6/H2); the embedded agent-prompt blocks relabeled "Full
  Prompt" → excerpt (A2); the live-fixture count (six → seven, adding
  `rubric-revision-loop`: M4/AR10); the PostToolUse extension-allowlist
  description corrected to the actual build-artifact denylist + `{}`
  emit (AR2); the file-tracking trim threshold (500 → 1000 with 2x
  headroom: AR4); the golden-cassette PR-diff framing → debugging-
  reference framing (AR11); stale "Ultimate Workflow Plugin" branding +
  the unmeasured "in 5 minutes" claim (Q2); the "`bd doctor` all green"
  overclaim caveated to the CORE SYSTEM + GIT INTEGRATION must-pass set
  (Q4); and the hardcoded "v3.0.0" installer banner dropped in favor of
  pointing at the manifest (I7).

### Security

- **Red-team certification — the gate does not leak under live load.**
  The three mandatory red-team attacks (forge the label via `bd`
  directly; recreate the legacy marker file; interrupt the hook
  mid-evaluation) were reproduced and DEFEATED, and the failed attacks
  are the evidence (the marker is never read; the interrupt is a
  deliberate `{}`-and-exit-0 anti-loop pass-through that leaves prior
  gate state intact). Forensically confirmed on the paid python-django-
  bug run (llh.25): the gate BLOCKED the unreviewed `models.py` change
  on every Stop reaching change-set logic; the only "allow" Stops were
  H3 re-entry guards, and no unaudited completion path survived.
- **Residual threat boundary documented.** The fix raises the bar from a
  trivially-forgeable label to a change-set-bound record; it is not a
  cryptographic sandbox. An agent with arbitrary shell can still
  reproduce the hash-bound comment by hand (`bd comment add "QA-GATE
  APPROVED change_set_hash=$(impact-report.sh --hash-only)"`) — a stated
  THREAT-MODEL BOUNDARY at both the producer (`qa-gate.sh:730`) and
  consumer (`verify-before-stop.sh:1146`) sites; the full-shell-autonomy
  model precludes an HMAC keyed on a withheld secret. The orchestrator
  Bash-write vector is the related residual: Write/Edit/MultiEdit are
  structurally omitted from the orchestrator tool list and
  hook-blocked, but a write-shaped Bash command is not — closing it
  mechanically needs runtime-surfaced subagent identity this environment
  does not provide.

### Reverted

- **llh.19 (orchestrator Bash-write fail-closed).** The mechanical
  attempt to fail CLOSED on write-shaped Bash from the orchestrator was
  reverted to HEAD: `prevent-orchestrator-edits.sh` cannot attribute the
  caller in this identity-less runtime, so failing closed broke
  legitimate specialist Bash. The Bash-write vector is carried as a
  documented residual (see Security) rather than fixed.

## [3.4.1] - 2026-06-13

Hotfix release for the v3.4.0 line: model resolution was selecting the
stale `claude-opus-4-7` pin instead of the newest catalogue entry, and
the effort-default story was muddled by working-tree drift after the
`/effort` exposure. Three child tasks under epic
`claude-workflow-plugin-vlp` — `vlp.1` (resolver), `vlp.2` (effort
defaults), and the discovered-from defect
`claude-workflow-plugin-3fn` (manual-adopt subshell-loss) — all
`qa-approved` on `main` by 2026-06-13. First real-world adoption
recorded the same day: all seven agent pins moved
`claude-opus-4-7 → claude-fable-5`; the switch is logged on
meta-task `claude-workflow-plugin-4o2` (`Model selection log`,
comment 278) with the rollback command `/workflow-model
claude-opus-4-7`. Operator pain summary: zero — the switch was
quiet, the statusline now displays the active pin, and
SessionStart names the applied effort level.

### Fixed

- **Model resolver: generation-aware, never family-gated (vlp.1).**
  `.claude/scripts/model-select.sh` `pick_best` rewritten. Sort is now
  `created_at` DESC → `max_input_tokens` DESC → ranking-file position
  ASC. The family-gated `startswith` jq filter that silently dropped
  unknown families is removed; unknown families are first-class
  candidates and trigger an advisory warning, not exclusion. The
  `.claude/model-ranking` header rewritten end-to-end: `!prefix`
  lines are exclusions, non-`!` lines are tertiary tie-breakers, and
  the tier list itself is preserved. Regression test: spec X in
  `.claude/tests/component/specs/model-select.sh` exercises a
  faked listing with `claude-zenith-6` (unknown family, newest
  `created_at`) and asserts the resolver picks it; the META-TEST
  spec I proves a stub picker propagates to the agent pin (sensitivity).
- **Manual-adopt gate stdout-sentinel fix (3fn).** Defect filed
  during QA review of `vlp.1`: `MANUAL_ADOPT_REQUIRED=...` inside
  `pick_best` was a subshell-local assignment lost by `$(...)`
  command substitution, so the gate at `cmd_apply` was dead code
  and the LOUD adopt notice fired _while_ the pin was rewritten
  anyway — a 100 % silent-stale-pin contract violation on every
  unparseable `created_at`. Fix changes `pick_best`'s stdout
  contract to encode the signal: happy path emits `<id>\n`,
  manual-adopt path emits `MANUAL\t<id>\n`. `cmd_apply`,
  `cmd_resolve`, and `cmd_status` all parse the `MANUAL$'\t'*`
  prefix; `cmd_apply` short-circuits BEFORE `current_pin`
  comparison or rewrite. Tab byte is unambiguous — model ids are
  restricted to `[a-z0-9-]+` so no collision. Dead parent-shell
  global removed; file-header contract comment updated (lines 49–67).
  Regression: Spec M block (`ms-M` / `ms-ME` / `ms-MT` / `ms-MC` /
  `ms-MX`) adds 20 assertions including a META-TEST proving the new
  gate is sensitive (stripped `cmd_apply` rewrites the pin; honest
  `cmd_apply` does not).
- **`--refresh` flag bypasses the 1-hour listing cache (vlp.1).**
  `model-select.sh resolve --refresh` / `apply --refresh` forces a
  live `/v1/models` GET; `cache_fresh` returns false when
  `REFRESH=1`. Documented in the resolver header.
- **Statusline shows the active model pin (vlp.1).**
  `.claude/scripts/statusline.sh` appends `• model: <id>` to every
  output branch; the id is read from `orchestrator.md` frontmatter
  (no network). Fallback `(no model pin)` when the frontmatter line
  is absent. Two new assertions in
  `.claude/scripts/tests/phase5-synthetic-tests.sh` cover both the
  pin-present and pin-absent branches.
- **Six stale `Opus 4.7` doc references (vlp.1).** Model-agnostic
  prose now lands in `README.md:180`, `docs/ARCHITECTURE.md:419`,
  `CONTRIBUTING.md:34/61/208`, and `.claude/tests/README.md:79`.
  Historical references inside dated CHANGELOG sections (e.g. the
  `[3.0.0]` entry) are preserved as accurate snapshots of what
  shipped at the time.

### Changed

- **Effort default landed at the maximum persistable level (vlp.2).**
  `.claude/settings.json` carries `effortLevel: "xhigh"` (the cap
  accepted by the `effortLevel` field per
  `docs.claude.com/en/docs/claude-code/settings` — `"max"` is
  invalid in this field and is rejected at load) plus
  `env.CLAUDE_CODE_EFFORT_LEVEL: "max"` (the env var DOES accept
  `max` and persists across sessions per
  `docs.claude.com/en/docs/claude-code/env-vars`). Working-tree
  drift (`effortLevel: "max"` + deleted env var) reverted via
  deliberate Write. All seven agent frontmatter `effort: max` lines
  unchanged — `max` is the highest subagent-frontmatter value per
  `docs.claude.com/en/docs/claude-code/sub-agents`. SessionStart
  now emits a one-line note naming the applied level + the
  `/effort ultracode` opt-in path; the env value takes precedence
  per the cited docs, and the message names both when they differ.
  Ultracode itself is documented as a runtime opt-in (via `/effort
  ultracode`, `--settings`, or the SDK control request), not a
  durable default, because the docs explicitly state ultracode
  cannot be persisted in settings. CONTRIBUTING.md carries the
  verbatim docs quote and the three persistable knobs.
- **First real-world model adoption recorded (vlp.1, vlp.2).**
  2026-06-13: all seven agent pins moved from `claude-opus-4-7` to
  `claude-fable-5` (newest `created_at` in the live `/v1/models`
  listing). Settings `env.CLAUDE_LATEST_OPUS` updated. Audit comment
  on `claude-workflow-plugin-4o2` (`Model selection log`) records
  the transition plus the rollback `/workflow-model
  claude-opus-4-7`. Statusline now displays `• model:
  claude-fable-5`.

### Verification

- `make test` (L1 bash unit): **15 specs**, 0 fail.
- `make test-all` (L1 + L2 component): **21 specs / 454 assertions**,
  0 fail (+20 over the v3.4.0 baseline of 434; the M-block
  manual-adopt regression coverage).
- `cd .claude/tests/e2e && npm run test:unit`: **158 passed / 5
  skipped** (unchanged from v3.4.0 — the five skips are honest
  invariant-engine + trace-anchor artifact-missing skips, not
  green-washed).
- `make lint`: clean.
- `make check` (AgentLint): **87/100** core (composition stable
  post-pin change — the only S7 line that shifted is a new fixture
  path in `.claude/tests/component/specs/model-select.sh`, which
  matches the documented S7 fixture override convention; the
  numeric score is unchanged).
- Plugin manifest: `node -e JSON.parse(...)` confirms valid + version
  `3.4.1`.
- Guard suites green: `agents-manifest-parity`, `agent-time-budget`,
  `agent-mcp-tools-parity`, `no-nested-spawn-instructions`.

## [3.4.0] - 2026-06-12

Phase C of the verification-suite plan (`docs/plans/verification-suite.md`):
the mutation-testing tier (L3.5). Ships an on-demand sweep that generates
fault-class mutants for hook scripts, contains them in throwaway git
worktrees, runs the free L1/L2 tiers against each, and filters surviving
mutants through a separate-context `@judge` subagent calibrated against a
hand-labeled set (precision 0.9412 on the 24-mutant corpus, threshold
0.8). Every step is dev-cycle-manual — `make mutate` or `/mutation-sweep`
— with zero CI wiring, zero scheduled jobs, and zero automatic paid
calls. The acceptance sweep over `verify-before-stop.sh` + `post-edit.sh`
produced 32 mutants (4 killed by the existing suite, 28 survived); the
judge classified 27 genuine + 1 equivalent; survivor 12 (a cache-replay
control-flow regression that bypassed the test suite while still
reporting "technical checks passed") was killed with 8 new L2
assertions, and the 26-survivor backlog is tracked as
`claude-workflow-plugin-6ix`. All five Phase C child tasks
(`claude-workflow-plugin-n45.1` harness, `n45.2` judge + calibration,
`n45.3` acceptance sweep, `n45.5` exclusion-bypass + JUDGE-RELAY fix,
`n45.4` closeout) were `qa-approved` on `main` by 2026-06-12.

### Added

- **Mutation-testing harness (C.1).** New tier under
  `.claude/tests/mutation/`: `mutation-sweep.sh` entry point,
  `fault-classes.md` catalog (F1 doc-only / F2 inverted conditional /
  F3 off-by-one / F4 swapped sentinel / F5 dropped jq fallback /
  F6 wrong hook envelope key / F7 removed regex anchor / F8 removed
  flock — destructive command classes excluded by design),
  `mutation.conf` caps (`MAX_MUTANTS_PER_FILE=24`,
  `MAX_MUTANTS_PER_RUN=60`, `MUTANT_TEST_TIMEOUT_S=60`,
  `SWEEP_TIMEOUT_S=1800`, `COMMAND_EXCLUSIONS` covering `rm mv cp curl
  wget gh push reset checkout`, `JUDGE_PRECISION_MIN=0.8`),
  `lib/generate.sh` (deterministic awk/sed generators — all 8 generators
  now uniformly call `should_skip` after n45.5; fault-class catalog
  parity is enforced at L1), `lib/rank-targets.sh` (`impact_of` when
  code-graph index present, lines × test-references fallback
  otherwise — graceful-degradation proven by the L1 test fixture
  running with no DB). 18-assertion L1 suite
  (`mutation-harness.test.sh`) with two META-TESTs (inverted
  kill-detection and trap-stripped containment leak).
- **Worktree containment (C.1).** Every mutant applied inside a
  fresh `git worktree --detach HEAD` under
  `.claude/.mutation-worktrees/m-<run_ts>-<idx>/`; main checkout is
  never touched. Three-layer cleanup: per-mutant
  `git worktree remove --force`, EXIT/INT/TERM trap, and final
  `git worktree prune`. Both `.claude/.mutation-runs/` and
  `.claude/.mutation-worktrees/` are gitignored. Containment proof
  is the L1 suite section 3 (HEAD + tracked-file hashes unchanged
  after sweep) + section 4 (zero worktrees in directory and registry)
  + section 9 META-TEST (trap-stripped harness leaks at least one
  worktree).
- **Cost-confirmation gate (C.1).** After the deterministic pass the
  harness prints a survivor count + judge cost estimate (survivors
  × `JUDGE_COST_PER_CALL_USD`); the judge step gates behind
  `--confirm-judge` (CI / scripted) or an interactive y/N prompt.
  EOF stdin defaults to N (no paid call without explicit
  confirmation). `--no-judge` skips the gate entirely. Mirrors the
  0.8 manual-only-live-testing convention.
- **`/mutation-sweep` Claude-invokable command (C.1).** New
  `.claude/commands/mutation-sweep.md` — thin wrapper that asks
  Claude to pick targets and forward to `mutation-sweep.sh`.
  Registered in `plugin.json` commands[] in the same commit per the
  manifest-parity lesson.
- **Judge subagent (C.2).** New `.claude/agents/judge.md` —
  read-only tools (`Read, Grep, Glob, LS`), strict-JSON output
  (`{verdict: equivalent|genuine, confidence, justification}`),
  three worked examples (equivalent counter, genuine label-typo,
  subtle defended-caller default removal), `proactive: false`
  (spawned only from the root via JUDGE-RELAY). Carries the shared
  `effort: max` + time-budget block. Calibration design bias is
  precision over recall — better to miss an equivalent than to bury
  a real regression. Registered in `plugin.json` agents[] in the
  same commit (manifest-parity lesson; now 7 agents total).
- **Calibration set + precision gate (C.2).** Hand-labeled corpus at
  `.claude/tests/mutation/calibration/calibration-set.json`: 24
  entries (≥20 per spec headroom), all 8 fault classes represented
  (≥5 equivalents so precision has a real denominator),
  per-entry `ground_truth` + `label_rationale`. The L1 suite
  (`judge-calibration.test.sh`, 65 assertions, 2 META-TESTs)
  validates the shape, the ≥20 / ≥5 contracts, and the precision/
  recall math. `judge-gate.sh` runs precision/recall against the set:
  exit 0 iff `precision >= JUDGE_PRECISION_MIN` (default 0.8). Recall
  is reported alongside but is not a gating threshold. Exit codes
  0 / 1 / 2 / 3 cover pass, below-threshold, malformed input, and
  undefined precision respectively.
- **Calibration round result (C.2).** First calibration sweep ran
  2026-06-12 (root-orchestrated relay, in-session, zero API spend
  via the operator's existing Claude session): TP 16, FP 1, FN 1,
  TN 6, **precision 0.9412 / recall 0.9412 — GATE PASSED** (0.8
  threshold). One FP (id 8 — ARG_MAX/PATH-stub jq failure surface
  argued constructible; ground truth holds it unconstructible) and
  one FN (id 12 per the confusion matrix). Run artefacts:
  `calibration/runs/2026-06-12-{calibration-report,verdict}.json`
  (tracked); raw run dir gitignored.
- **JUDGE-RELAY procedure (C.2, n45.5).** Orchestrator section 5b
  (`JUDGE-RELAY: judging-relay`) — judge is always spawned from the
  root conversation, never by another subagent (`code.claude.com/docs/
  en/sub-agents`: `Agent(agent_type)` has no effect in a subagent
  definition). The harness writes `judge-packet.json` on disk; the
  orchestrator reads it, spawns `@judge` once via `Task`, captures
  stdout to `verdict.json`, then runs `judge-gate.sh`. Guarded at L1
  by `no-nested-spawn-instructions.test.sh`. Mirrors the 5a
  RUBRIC-RELAY shape introduced in v3.2.0.
- **Acceptance sweep results (C.3).** First sweep over
  `.claude/scripts/verify-before-stop.sh` + `.claude/scripts/post-edit.sh`
  ran 2026-06-12 (`/mutation-sweep`, throwaway worktrees,
  `--no-judge` deterministic pass + JUDGE-RELAY for survivors).
  **32 mutants generated, 4 killed by the existing suite, 28
  survived** (87.5 % survival rate before triage). The judge
  classified **27 genuine / 1 equivalent** (id 27 — printf-rc
  masking, unconstructible failure surface). Killing-test target:
  id 12 (line 657 `=` → `!=`) — the failing test suite was replayed
  from cache while the gate reported "technical checks passed", a
  false-positive everything-is-fine verdict on a session that
  actually had a failing suite. Survivor 12 was killed by 8 new L2
  assertions on `.claude/tests/component/specs/verify-before-stop.sh`
  testing the suite-actually-ran invariant via on-disk tracking
  artefacts (`last-test-rc.<TID>`, `last-test-output.log`,
  `last-runner.<TID>`) plus negative-wording assertions on the block
  reason (no "QA approval required" / "technical checks passed" when
  tests fail). The remaining 26 genuine survivors are tracked as
  `claude-workflow-plugin-6ix` with seven theme groupings
  (A: block-reason wording paths; B: F1 doc-only fast path;
  C: cross-repo detection; D: git-status fallback; E: escalation
  boundary; F: post-edit tracking/cadence; G: post-edit doc filter)
  and two `TECHNICAL_DEBT.md` rows.
- **Installer surface expanded for the v3.4.0 manifest (C.4).**
  `install.sh` + `install.ps1` now ship every agent declared in
  `plugin.json` agents[] (was hardcoded to the five v3.0 roles,
  silently dropped `grader.md` from v3.2.0 and `judge.md` from
  v3.4.0). Glob-copy under `.claude/agents/*.md` replaces the
  fixed list. Additionally ships `.claude/rubrics/*.md` +
  `.claude/rubric-config` (Phase A surface), `.claude/tests/mutation/`
  excluding `runs/` + `*.log` (Phase C surface),
  `.claude/model-ranking` + `LESSONS.md` + `.worktreeinclude` (Phase 0
  surface). Ten new assertions in `installer-mcp-config.sh` cover the
  full Phase A + Phase C presence (grader.md, judge.md,
  rubrics/default.md, rubric-config, mutation-sweep.sh, judge-gate.sh,
  calibration-set.json, mutation-sweep.md command, LESSONS.md,
  model-ranking).

### Changed

- **`mutation.conf` documents the default test-cmd tier (C.4).** The
  `MUTANT_TEST_TIMEOUT_S` block now documents that the harness
  defaults to the L1 unit subset
  (`bash .claude/scripts/tests/run-tests.sh`) and recommends a
  per-target `--test-cmd 'L1 && L2'` override for hook-script targets
  whose primary coverage lives in L2 component specs. Originates
  from the C.3 acceptance sweep where survivor 12 needed L2
  assertions to be killable — the L1 default would have left it
  survived. The README "Per-target test-cmd overrides" section
  carries the operator-facing variant.

### Migration

- **Existing v3.3.0 installs missing the v3.2.0 grader + v3.4.0
  judge files: re-run the installer.** `bash install.sh` (or the
  curl-pipe form) over the existing target copies the missing
  agents, rubrics, mutation tier, and supporting config files. No
  manual editing required; Beads data, settings, hooks, and MCP
  config are preserved (merge-aware copy). The `update` mode is
  conservative — workflow-owned keys are refreshed, non-workflow
  keys (and any local customizations under `.claude/`) are kept.
- **Mutation tier is gitignored at runtime.** `.claude/.mutation-runs/`
  and `.claude/.mutation-worktrees/` are added to the install-time
  `.gitignore`. Calibration `runs/` artefacts are tracked
  per-checkpoint; only the live run dirs are excluded.

## [3.3.0] - 2026-06-12

Phase B of the verification-suite plan (`docs/plans/verification-suite.md`):
the code-graph MCP server. Replaces `code-context-mcp` (3 git-grep tools)
with `code-graph-mcp` (7 graph tools backed by tree-sitter + SQLite).
Adds impact-analysis surfaces to the orchestrator pre-delegation step
and the QA regression scan, with measured ~67.5 % context efficiency
on a representative QA workload. Both child tasks
(`claude-workflow-plugin-366.1` server build, `366.2` integration +
migration) were `qa-approved` on `main` by 2026-06-12. Phase C
shipped immediately after, as v3.4.0 — see the entry above.

### Added

- **`code-graph-mcp` server (B.1).** New tree-sitter + SQLite code
  graph server under `.claude/mcp/code-graph-mcp/`. Seven tools:
  `code_search`, `code_context`, `symbol_callers` (byte-compatible
  trio with the retired engine on inputs and primary output keys —
  the `tool` / `backend` strings change to `"graph-index"`), plus
  `impact_of`, `dead_code`, `dependency_path`, `code_index_health`
  (the new analysis surface). Lazy index at
  `.claude/.code-graph/index.db` (gitignored), incremental by content
  hash, built on first tool call so SessionStart pays no parse cost.
  Ships 10 vendored wasm grammars (JS/TS/TSX/Python/Go/Rust/Bash/
  Ruby/Java/C). 31 server tests (7 indexer + 15 tools + 9 server).
- **Agent wiring for impact analysis (B.2).** `orchestrator.md`
  section 1a queries `impact_of` for likely-touched symbols/files
  during pre-delegation and attaches the result to the SPEC doc;
  `qa.md` section 3a queries `impact_of` for every changed symbol
  in the diff and treats high-fan-in callers as mandatory regression
  candidates (extends J19). Both calls degrade gracefully when the
  server is unavailable (logged in `llm_observations`).
  `docs/AGENTS.md` mirrors the new behaviors (orchestrator + QA
  Key Behaviors each gain item 6).
- **`qa-queried-impact-of` invariant + fixture declaration (B.2).**
  New live-test invariant asserts QA queried `impact_of` for every
  changed symbol during a regression pass; declared on the
  `node-react-auth` fixture's `fixture.yaml`. Composes with the
  existing four active invariants.
- **`agent-mcp-tools-parity.test.sh` L1 test (366.6).** New L1
  parity test asserts every non-exempt agent file with a `tools:`
  frontmatter line enumerates each `mcp__*` tool its prompt body
  references. Carries four META-TESTs (gap trips checker;
  server-grant passes; exempt short-circuit; no-tools-line
  inherits). `grader.md` is exempt-by-design (read-only tools,
  no MCP body references); the exemption is encoded in
  `EXEMPT_AGENTS` with a justification.
- **L2 installer assertions for the new server (B.2).** Five new
  assertions in `.claude/tests/component/specs/installer-mcp-config.sh`:
  `code-graph` args reference the launcher path and use the
  `${CLAUDE_PROJECT_DIR:-.}` default form; the retired `code-context`
  entry is absent from the rendered `.mcp.json`; the rendered install
  has `.claude/mcp/code-graph-mcp/` and a vendored wasm grammar
  (typescript spot-check on the rsync exclude behavior); the
  `.claude/mcp/code-context-mcp/` directory is gone. The two
  META-TESTs (bare-form rejected, default-form accepted) are
  unchanged.

### Changed

- **Measured context efficiency: 259,744 → 84,442 bytes
  (~67.5 % reduction).** Offline output-size proxy on a
  representative QA regression workload (decomposition target:
  change `qa-gate.sh`'s grade-record action format; symbol seed
  `cmd_grade_record`). BEFORE figure is the minimum file-read
  cost an orchestrator would pay without `impact_of` (23 files at
  ~256 KB); AFTER is `code_search` + `code_context` + `impact_of`
  seed. Tokens are bytes/4, conservative for JSON. Method,
  raw 23-file list, and caveats documented in
  `.claude/mcp/code-graph-mcp/README.md` under "Before/after token
  comparison".

### Removed

- **`code-context-mcp` retired (B.2).** `.claude/mcp/code-context-mcp/`
  deleted; the `code-context` server entry removed from both
  `.mcp.json` and `.claude-plugin/plugin.json` in the same commit
  the new server was wired in. The `_phase7_codebase_graph_target`
  forward-pointer block in `.mcp.json` is gone now that it is
  filled. Beads data and the QA gate semantics are untouched.

### Migration — code-context-mcp retired (3.3.0)

Phase B of the verification-suite plan (v3.3.0) replaces
`code-context-mcp` with `code-graph-mcp`, a tree-sitter + SQLite
code-graph server. For existing installs:

- **Easy path: re-run the installer.** `bash install.sh` (or the
  curl-pipe form) over the existing target rewrites `.mcp.json` and
  `.claude-plugin/plugin.json` to wire `code-graph` and drops the
  retired `code-context` entry. The `${CLAUDE_PROJECT_DIR:-.}`
  default form from 3.1.0 is preserved.
- **Manual path: edit `.mcp.json` in place.** Swap the
  `code-context` entry's `command` / `args` to point at
  `${CLAUDE_PROJECT_DIR:-.}/.claude/mcp/code-graph-mcp/bin/code-graph-mcp.js`
  and rename the key from `code-context` to `code-graph`. Keep the
  `${VAR:-.}` default form (the 3.1.0 hotfix).
- **First tool call builds the index lazily.** No SessionStart
  parse cost; the first `code_search` / `code_context` /
  `impact_of` call pays the build (~tens of ms per kLOC for the
  vendored grammars). Subsequent calls are incremental by content
  hash.
- **Beads data unaffected.** Task state, labels, comments, gate
  semantics are all unchanged — the swap is MCP-layer only.

`code_search` and `code_context` keep their input schemas and
primary output keys; only the `tool` / `backend` value strings
change (`"git-grep"` → `"graph-index"`). `code_index_health` is
intentionally an **Add** rather than byte-compat — the old engine
reported git-grep environment health, the new engine reports
staleness, per-language coverage, last index time, and DB size.
No live consumer reads the old health fields. The full migration
detail is in `docs/MCP_SERVERS.md`.

### Fixed

- **`docs/MCP_SERVERS.md` fabricated example corrected (B.1 QA
  follow-up, `byj`).** The "Concrete example" paragraph cited a
  non-existent fixture symbol (`auth-handler`) and a non-existent
  invariant name. The fix implemented the real
  `qa-queried-impact-of` invariant (declared on `node-react-auth`'s
  `fixture.yaml`) and rewrote the example around the real
  `createApp` symbol (the Express app factory in
  `server/index.js`).
- **Stale fixture `SKILL.md` references swept (B.2).** Every
  fixture under `.claude/skills/workflow-engine/SKILL.md` and the
  seven fixture variants were rewritten to reference `code-graph`
  in their MCP server table row.
- **`make test-live FIXTURE=<fixture>` spec resolution (366.4).**
  The recipe assumed 1:1 fixture-to-spec naming and failed with
  "No test files found" for `FIXTURE=node-react-auth` (the lone
  scenario-named spec, `happy-path.spec.ts`). New
  `.claude/scripts/resolve-fixture-spec.sh` scans each spec's
  `FIXTURE_PATH` constant for the requested fixture; the Makefile
  resolves before the cost prompt, prints the resolved spec(s),
  and unknown fixtures now fail fast with a listing of available
  fixtures.
- **Harness Beads capture #2 (366.5).** `bd 0.47.1`'s
  `sync --flush-only` short-circuits with "auto-import skipped,
  JSONL unchanged (hash match)" when `issues.jsonl` is absent and
  `sync_base.jsonl`'s hash matches `metadata.jsonl_content_hash`
  in `beads.db` — the live-fixture restore pattern hits this
  every run, leaving `issues.jsonl` unmaterialized so the Phase B
  live trace reported zero created tasks. `lib/beadsCapture.ts`
  now falls back to `bd export --force -o .beads/issues.jsonl` to
  force materialization; `happy-path.spec.ts:90` adopted the
  multi-domain-signup OR-shape assertion (harness diff OR
  `bd_create_(task|epic)` MCP OR Bash `bd create`); the Phase B
  live trace was committed as the seed regression anchor with a
  dedicated `_phase-b-trace.unit.spec.ts`.
- **Subagent MCP tool allowlists (366.6).** Subagent `tools:`
  frontmatter is an allowlist, and per
  `code.claude.com/docs/en/sub-agents` it structurally strips MCP
  tools when no `mcp__*` entry is enumerated — so QA and the
  three specialists could not reach the `code-graph` / `bd` MCP
  servers at all. Server-level grants
  (`mcp__plugin_claude-workflow_code-graph`,
  `mcp__plugin_claude-workflow_bd`, `mcp__code-graph`, `mcp__bd`)
  were added under both the plugin and project prefixes for all
  five non-grader agents. QA section 3a + orchestrator section 1a
  wording was tightened so an empty/missing index is a lazy-build
  signal (PROCEED) rather than a degradation reason — degrade
  only when `code-graph` is structurally absent from the surface.
  `lib/runFixture.ts` gained `HARNESS_METADATA_FILES` +
  `snapshotHarnessMetadata` / `restoreHarnessMetadata` so
  operator-authored `fixture.yaml` content survives the
  reset/clean/pop restore cycle (new
  `_fixture-restore.unit.spec.ts`, 4 specs).

## [3.2.0] - 2026-06-11

Phase A of the verification-suite plan (`docs/plans/verification-suite.md`):
the rubric-grader QA loop. Adds a separate-context `grader` subagent, a
versioned rubric set (default + backend/frontend/devops domain overlays
+ bugfix overlay), `qa-gate.sh grade-record` lifecycle with
`rubric-pending`/`rubric-satisfied` labels, the QA grading loop with a
binding iteration cap that engages the 0.2 escalation path, and a
statusline rubric segment. Both Phase A child tasks
(`claude-workflow-plugin-l1r.1` plumbing, `l1r.2` grader + wiring) were
`qa-approved` on `main` by 2026-06-11. Validated 2026-06-11 — 3 runs
(~$15-30), relay demonstrated end-to-end in run 3, trace anchored
offline in `_phase-a-trace.unit.spec.ts` + seed cassette; two
live-found defects fixed (grader manifest registration; nested-spawn
relay redesign). Phases B/C remain pending and will ship as
v3.3.0 / v3.4.0.

### Added

- **Grader subagent (A.2).** New `.claude/agents/grader.md` — read-only
  tools (`Read, Grep, Glob, LS`), non-proactive (spawned deliberately by
  the QA agent), carrying the shared `effort: max` + time-budget block.
  Strict-JSON output contract (`verdict`, `criterion_results`,
  `required_fixes`, `iteration`, `rubric_version`); separate context
  prevents self-critique contamination.
- **Versioned rubric set (A.1).** `.claude/rubrics/default.md` (v1,
  C1–C7: SPEC fidelity, user-behavior tests, F7 with substantive
  `llm_observations`, no unrelated scope, J26 modules addressed, docs
  updated, boundary-mock fidelity citing `LESSONS.md` lesson 2);
  `backend.md` / `frontend.md` / `devops.md` (each extends default
  with four domain criteria); `bugfix.md` overlay (applies_to: bug,
  G1–G4 enforcing spec 0.5 evidence-before-fix protocol).
- **`qa-gate.sh grade-record` (A.1).** New subcommand that reads a
  strict-JSON verdict from `--file <path>` or stdin, validates the
  shape (rejecting malformed input with a structured `error_key`
  envelope), appends a `RUBRIC <version> iteration <n>: <verdict>`
  Beads comment, and on `satisfied` flips `rubric-pending` →
  `rubric-satisfied`. On `needs_revision` labels are unchanged — the
  `qa-blocked` round-trip is the QA agent's move per principle 7.
- **QA grading loop with binding cap (A.2).** New section 6 in
  `qa.md` (subsections 6a–6f: packet assembly → spawn grader →
  record → needs_revision round-trip → cap → override-reason rule).
  Cap reads from `.claude/rubric-config` (`iteration_cap=3` default);
  hitting the cap engages the 0.2 escalation path
  (`qa-escalated` + J21 decision) rather than looping further.
  Mirrored into `docs/AGENTS.md` (5 → 6 agents).
- **Statusline rubric segment (A.2).** `.claude/scripts/statusline.sh`
  now emits `qa: <state> • rubric: <state> • N files changed` when a
  rubric label is present, using the existing `bd show` round-trip
  (no new fetch). Suppresses the rubric segment when no rubric label
  is set, to keep the line short.
- **`rubric-revision-loop` live fixture (A.2).** Full e2e fixture
  under `.claude/tests/e2e/fixtures/rubric-revision-loop/` with a
  prompt that deliberately under-tests its change, forcing C2 to
  fail on iteration 1 so the loop exercises the needs_revision
  → re-grade → satisfied path. Validated live 2026-06-12 (3 runs,
  ~$15-30; relay demonstrated in run 3; trace anchored offline in
  `_phase-a-trace.unit.spec.ts` + seed cassette).

### Changed

- **`qa-gate.sh enter` arms `rubric-pending` (A.1).** Fresh and
  idempotent paths both set `rubric-pending` alongside
  `qa-gate-entered`; re-entry clears any stale `rubric-satisfied`
  from a prior cycle. `cmd_status` now reports
  `rubric=<pending|satisfied|none>` in `observations`.
- **`qa-gate.sh approve` warns on un-graded approvals (A.1).** Per
  principle 6 the approve path does NOT hard-gate on
  `rubric-satisfied`; it warns loudly in `observations` when
  `rubric-pending` is still set, and the QA agent's prompt (6f)
  enforces the explicit override-reason rule. Approve drops
  `rubric-pending` (cycle ends) and preserves `rubric-satisfied`
  as the audit trail.

## [3.1.0] - 2026-06-11

Phase 0 of the verification-suite plan (`docs/plans/verification-suite.md`).
Two production hotfixes (MCP loader, QA-gate escalation cap), five agent
policy upgrades (best-model auto-selection, max effort + time budget,
evidence-before-fix protocol, parallel-specialist worktree isolation,
lessons ledger), and a live-test economics rework (retire golden-cassette
equality, manual invariant-based live testing only, zero-API CI). All
eight child tasks (`claude-workflow-plugin-e0d.1` through `e0d.8`) were
`qa-approved` on `main` by 2026-06-11. Phases A/B/C remain pending and
will ship as v3.2.0 / v3.3.0 / v3.4.0.

### Fixed

- **MCP path resolution in installed projects (0.1).** `.mcp.json` server
  entries now use `${CLAUDE_PROJECT_DIR:-.}` default form so both `bd` and
  `code-context` servers load in installed targets, not just the plugin's
  own repo. Verified against the Claude Code MCP configuration docs
  (project-scoped variables) and covered by a new L2 installer spec that
  asserts no unresolved `${...}` refs in a rendered fresh install.
- **QA-gate escalation cap is now binding (0.2).** Adds `qa-escalated`
  state (J21 comment + label at cap-hit, suite re-runs skipped while
  escalated), `qa-deferred` auto-defer escape valve on the next choiceless
  Stop (the single audited bypass under principle 6), and runner-vs-
  assertion failure classification so environment errors route to
  "fix the environment" instead of looping on code. Previously a live
  transcript showed `ESCALATION: Iteration 7 (>= 3)` re-running the suite
  on every loop with no behavioral consequence.

### Added

- **Automatic best-model selection on every SessionStart (0.3).** New
  `.claude/scripts/model-select.sh` resolves available models via the
  free `GET /v1/models` listing, ranks by `.claude/model-ranking`
  (family preference + unknown-newer heuristic + largest-context
  variant), and rewrites agent `model:` fields through the shared
  `workflow-model-apply.sh` helper. 1-hour cache; fail-open on
  missing key or network failure. Every switch records a Beads
  comment on a standing meta-task with the `/workflow-model` rollback
  command.
- **Maximum effort and high time budget (0.4).** `effortLevel: xhigh`
  (the highest persisted value) in `settings.json`,
  `CLAUDE_CODE_EFFORT_LEVEL=max` in the `env` block (env wins per the
  Claude Code env-vars docs), and `effort: max` in every agent's
  frontmatter. Shared time-budget block added to all six agent prompts
  with principle-3 language ("Depth beats speed in every trade"). L1
  test discovers agents via glob so future additions get covered
  automatically.
- **Evidence-before-fix protocol (0.5).** Merged into qa.md's J27
  framework as 6 numbered steps (deterministic repro, failing test
  first, root-cause statement with cited evidence, declare confidence
  or ask, fix flips the failing test, two-bounce mandatory return to
  evidence mode). Mirrored in `backend.md`, `frontend.md`, `devops.md`
  with voice-appropriate tooling references. The "symptom-patching
  chains" anti-pattern is named explicitly in all four agent files
  and in `docs/AGENTS.md`. Bug-typed tasks only.
- **Worktree isolation for parallel specialists (0.6).** Orchestrator
  delegation rule: 2+ concurrent specialists every get
  `isolation: "worktree"` on the Task call. Serial single-specialist
  delegation unchanged. New `.worktreeinclude` at repo root covers
  env files so worktrees are runnable. Cited against the Claude Code
  sub-agents and worktrees docs.
- **Lessons ledger (0.7).** New `.claude/scripts/lessons.sh add
  '<text>' --source <task-id>` helper with normalized-text dedup;
  prints structured JSON output. `LESSONS.md` at repo root seeded
  with the two production lessons (worktree contamination,
  boundary-mock fidelity sourced from a real producer spec).
  `CLAUDE.md` conditional-loading row points the orchestrator to
  read it before non-trivial planning. `qa.md` epic-close step now
  emits candidate-lesson `lessons.sh add` calls instead of chat
  prose.
- **Invariant engine for manual live testing (0.8).** New
  `lib/invariants.ts` over normalized traces with 4 active
  invariants (orchestrator-no-edits, qa-approved-required,
  milestone-subsequence, declared-subagents-only) plus 1 honestly
  skipped (F7 completion contract, surfaced as `skipped` in matcher
  output rather than green-washed). Every fixture's `fixture.yaml`
  declares an `invariants:` block; `satisfiesInvariants` matcher
  replaces `matchesGolden` across all 6 live specs. New L2
  installer-config spec asserts no unresolved variables in
  rendered fresh installs.

### Changed

- **Manual-only live testing, zero-API CI (0.8).** L4 daily drift
  cron and per-PR live CI removed from `.github/workflows/test.yml`.
  `l3-live` is now `workflow_dispatch`-only. `make test-live` requires
  an explicit `FIXTURE=<name>` (or `FIXTURES="a b c"`), validates
  `ANTHROPIC_API_KEY`, prints a per-fixture cost estimate, and gates
  on `CONFIRM=1` for the y/N prompt. CI now consumes zero API spend
  on every PR.

### Removed

- **Golden-cassette equality as a gate (0.8).** `matchesGolden` is
  deprecated to a manual debugging reference; gating is invariant-
  based after this release. The retained recorded cassettes seed the
  invariant-engine self-tests. `make test-e2e` and
  `make test-e2e-record` are deprecated aliases that exit 2 with a
  pointer to `make test-live`.

## [3.0.0] - 2026-05-11

This release is the v2 -> v3 upgrade (Phases 0-7 of the consolidated v3 plan
at `docs/plans/v3-upgrade.md`), plus the G8 end-to-end test harness epic
and a post-G8 closeout pass. All work was merged to `main` by
2026-05-11. The release covers the plugin manifest, model pinning,
auto-loaded skill, statusline, two bundled MCP servers, the GitHub-link
hook, the AgentLint sweep, the five-tier test pyramid (L1 bash unit ->
L4 daily drift), a v2 -> v3 migrator, and a README rewrite. See the
sub-headers below for the per-phase breakdown.

### Added (v3 upgrade -- Phase 0, Foundation)

- `.claude-plugin/plugin.json` -- first-class Claude Code plugin manifest
  declaring `name`, `version`, `agents`, `hooks`, `commands`, `skills`, and a
  placeholder `mcpServers` block (Phase 6 populated). (E1)
- `.claude/commands/workflow-model.md` -- Claude-invokable slash command that
  rewrites the `model:` field across all five agents and updates the
  `CLAUDE_LATEST_OPUS` env hint in `settings.json`. (A5)
- `model:` field on every agent (`orchestrator`, `qa`, `backend`, `frontend`,
  `devops`), pinned to `claude-opus-4-7`. (A1, A3)
- `MAX_THINKING_TOKENS=64000` and `CLAUDE_LATEST_OPUS=claude-opus-4-7` in
  `.claude/settings.json` `env` block. (A2)
- `additionalDirectories: ["../"]` in `.claude/settings.json` so Claude has
  parent-folder read access by default. (E16)
- Extended-thinking instruction (`Use extended thinking for all non-trivial
  work.`) in every agent prompt, near the role intro. (A2)
- SessionStart hook now warns (non-blocking) when:
  - `bd --version` is older than the pinned minimum (currently `0.47`). (D6)
  - Any agent's `model:` field doesn't match `${CLAUDE_LATEST_OPUS}`,
    prompting the operator to run `/workflow-model`. (A1)
- `install.sh` and `install.ps1` enforce the minimum `bd` version at install
  time (fail-fast with a clear upgrade message). (D6)
- `uninstall.sh` and `uninstall.ps1` -- safe uninstall that *moves* the plugin
  files to a trash directory (`.claude-uninstall-trash-<timestamp>/`) instead
  of deleting them, and optionally restores from the latest
  `.claude-backup-*/`. (G5)
- `CHANGELOG.md` -- this file. (G6)
- `CONTRIBUTING.md` -- how to add a specialist agent, extend hooks, and where
  to look for the deferred testing strategy. (G7)

### Added (v3 upgrade -- Phase 5, Best-practice integrations)

- `.claude/skills/workflow-engine/SKILL.md` rewritten as the canonical
  source of truth for workflow rules. Frontmatter declares `name`,
  `description`, `when_to_use`, and explicit `disable-model-invocation:
  false` so Claude auto-loads it on session start without a slash trigger.
  (E2 / E15, principle 4 -- always-on workflow)
- `.claude/scripts/statusline.sh` -- single-line statusline rendering
  `[<task-id>] qa: <state> N files changed`, with graceful fallbacks for
  no-active-task and bd-unavailable cases. Reads from
  `.claude/.qa-tracking/current-task` (F3 single source of truth) and
  the task's labels for state. (E4 / I2)
- `.claude/settings.json` `statusLine` field wires the script into Claude
  Code's status bar. (E4 / I2)
- `.mcp.json` placeholder at project root with `_phase6_*` keys describing
  the bd-mcp (J29) and codebase-graph (J30) servers Phase 6 filled in.
  (E5)
- Memory bridge: `qa-gate.sh block <task> <reason>` now writes a
  `feedback`-typed memory entry to
  `~/.claude/projects/<project-slug>/memory/qa-block-<fp>.md` and updates
  `MEMORY.md` index. The fingerprint is a SHA1 of the first 80 chars of
  the reason so repeat-blocks of the same pattern collapse to one file
  (with appended `Last seen` timestamps). Across sessions, recurring QA
  patterns become memory the orchestrator can read. (E8, principle 5 --
  intent-based)
- TaskCreate / TaskUpdate dual-tracking section in `orchestrator.md`:
  documents Beads as cross-session and TaskCreate as intra-session, with
  a concrete worked example for an Epic + sub-tasks. (E13)

### Added (v3 upgrade -- Phase 6, MCP servers)

- bd-mcp MCP server (21 typed Beads tools) wired via `.mcp.json` with
  `${CLAUDE_PLUGIN_ROOT}` substitution. (J29)
- code-context-mcp MCP server (3 search tools: `code_search`,
  `code_context`, `symbol_callers`). (J30)
- Phase 6b: `bd-github-link.sh` (I3 -- auto-link Beads tasks to
  GitHub PRs/issues), cross-repo guard in `verify-before-stop.sh` and
  `current-task.sh` (I8), `docs/MCP_SERVERS.md` doc convention.

### Added (v3 upgrade -- Phase 7, AgentLint sweep)

- AgentLint sweep (61 -> 90 score climb); added `CLAUDE.md`, `HANDOFF.md`,
  `INDEX.md`, `SECURITY.md`, `Makefile`, `.gitignore`, `tests/` symlink,
  `.claude/scripts/tests/run-tests.sh` runner, and `stop_hook_active`
  circuit breaker in the Stop hook.

### Added (G8 test harness)

- L1 bash unit tests (49 assertions across `.claude/scripts/tests/`).
- L2 component tier (15 specs, 243 assertions, including the new
  `qa-gate-baseline` spec that codifies the 0wk.2 fix).
- L3 vitest unit tier (55 tests covering trace schema, normalization,
  golden compare, fixture init, custom matchers).
- L3 live e2e tier: 6 fixtures + golden cassettes -- `node-react-auth`,
  `python-django-bug`, `go-cli-refactor`, `monorepo-frontend-only`,
  `multi-domain-signup`, `qa-block-recovery`.
- L4 daily drift watch (GitHub Actions cron in `.github/workflows/test.yml`).
- GitHub Actions CI with 7 jobs: `lint`, `l1-unit`, `l2-component`,
  `l3-vitest-unit`, `manifest-validate`, `l3-live`, `l4-drift-watch`.
- Cassette-diff bot + PR summary tool with META-TEST tally surfacing.
- Failure-injection coverage: `orchestrator-restriction`, `cross-repo`,
  `hook-crash`, `regression-coverage`, `block-and-recover`.

### Added (post-G8 closeout)

- **README rewrite**: 325 -> 164 lines, value-forward pitch with
  install + upgrade + customize sections and copy-pasteable commands.
- **`install.sh --upgrade`**: detects v2 installs via three signals
  (agents lack `model:`, no `.claude-plugin/plugin.json`, no
  `.claude/mcp/` or `.claude/skills/workflow-engine/`), backs up to
  `.claude-v2-backup-<timestamp>/`, runs the v3 install, prints a
  "what changed" summary. Curl-pipe friendly:
  `... | bash -s -- --upgrade`.
- **`install.ps1` v2 redirect**: detects v2 and redirects to
  `install.sh` via Git Bash / WSL / curl instead of re-implementing
  the migration in PowerShell.
- **`CONTRIBUTING.md` quick-start**: mirror paragraph pointing at
  README's Customize section.
- **CI**: `npm ci --include=optional` plus glibc-binary verification
  step in `l3-live` and `l3-vitest-unit` jobs (SDK was resolving the
  `linux-x64-musl` variant on ubuntu-latest).

### Changed (v3 upgrade -- Phase 5)

- `intent-router.sh` and `session-start.sh` no longer embed the workflow
  rules text. Both now load
  `.claude/skills/workflow-engine/SKILL.md`, strip the YAML frontmatter,
  and inject the body via the `<workflow_engine>` envelope. When SKILL.md
  changes, the rules change everywhere. Fallback stub is in place if
  the skill file is missing. (E2 / E15)
- `orchestrator.md` opens with a pointer to the canonical SKILL.md and
  treats its own role-specific guidance as additive. (E2 / E15)
- All hook scripts standardised on the `hookSpecificOutput` envelope per
  the Claude Code hooks reference, with the documented exception of
  hooks that use top-level `decision/reason` (Stop, UserPromptSubmit,
  PostToolUse, PreCompact). `prevent-orchestrator-edits.sh` migrated
  from top-level `decision: block` to
  `hookSpecificOutput.permissionDecision: deny` per the PreToolUse spec.
  Documentation comments at the top of each script now spell out which
  shape is intentional. (E9)
- `qa-gate.sh block` returns a slightly richer `observations` field
  including whether the memory entry was written successfully. (E8)

### Changed (v3 upgrade -- Phase 0)

- `install.sh` and `install.ps1` rewritten to use the canonical files in the
  repo as the single source of truth. They `cp` / `Copy-Item` from the local
  clone (or freshly clone the repo to a temp dir if piped from
  `curl ... | bash`). The PowerShell installer no longer ships a truncated
  copy of the agent prompts. (G4)
- Tone-down pass on `docs/*.md` and `.claude/scripts/*.sh`: emoji limited to
  H1/H2 markers, ASCII separator bars (`---`-style) removed from script
  output. Agent prompts are not touched in this pass; that was Phase 2 (C6).
  (G9)

### Fixed (Phase 6b)

- 3 regex bugs in `bd-github-link.sh` (URL ref form, idempotency,
  close-detection); replaced with a token-walker parser.

### Fixed (Phase 7 / 0wk.9)

- `plugin.json` manifest schema for the SDK plugin loader (paths
  prefixed with `./`, hooks as string, skills as directory, MCP servers
  inline). Specialists now register as `claude-workflow:<role>` instead
  of falling back to `general-purpose`.

### Fixed (G8 / 0wk.2)

- `qa-gate.sh approve` now writes `approved-baseline` + truncates
  `changed-files.txt`; `verify-before-stop.sh` diffs git status against
  the baseline so we no longer see false-positive "0 files changed"
  demands on fresh sessions.
- Mid-G8: SDK `includeHookEvents: true`, `hookFired` matcher for the
  Claude Code Stop contract (no-decision = approve), HEAD-SHA capture
  before fixture run.

### Fixed (post-G8 closeout)

- **`statusline.sh::count_changed_files`** "00" bug: `grep -c .`
  exited non-zero on empty input and the `|| echo "0"` fallback ran
  on top of grep's own "0" output. Switched to `sort -u | wc -l`.
- **L1 `phase5-synthetic-tests.sh` statusline expectations**: updated
  to cover the full 0wk.2 transition (`gate-entered - 2 files` ->
  `approved - 0 files`) rather than the pre-0wk.2 state.
- **CI portability** (`BD_SHIM_ONLY=1` env opt): L1+L2 bd-dependent
  specs skip-with-log on the GitHub Actions runner (no `bd` CLI).
  Dev-machine paths unchanged.
- **L3 vitest unit specs**: replaced hardcoded `/Users/edk0/...`
  paths in `_lib.unit.spec.ts` with `import.meta.url`-relative
  resolution; replay-file reference replaced with the committed
  golden cassette.
- **shellcheck**: SC2015 refactor at `qa-gate.sh:340`
  (A && B || C -> if/then/fi); file-wide `# shellcheck disable=SC2317`
  in `bd-github-link.test.sh` and `phase5-synthetic-tests.sh` for
  source-pattern false positives.

### Closed bugs

- `0wk.7` -- zero subagent invocations (resolved by 0wk.9 plugin.json
  fix).
- `0wk.8` -- SDK doesn't register plugin agents (resolved by 0wk.9).
- `0wk.2` -- `qa-gate.sh approve` didn't clear `changed-files.txt`
  (resolved in the closeout pass).

### Known limitations

- L3 live runs cost ~$5-10/fixture; gated on `ANTHROPIC_API_KEY`
  secret. Now actually fires on every PR since the secret is
  configured.
- L3-live golden cassettes drift periodically as the model evolves;
  re-record via `RECORD_GOLDEN=1 npm run test:run` from the fixture
  dir.
- 0wk.4: vitest SIGKILL bypasses try/finally cleanup (mitigated by
  self-heal-on-entry in `runFixture.ts`).
- 0wk.5: bd daemon stack-overflow on stale locks (upstream beads CLI
  bug; workaround in production via `--db --allow-stale`).
- 8oz / a7y: SHA-pin GitHub Actions (+4 AgentLint Safety), gitleaks
  CI job (+2). Both P2 follow-ups in the AgentLint roadmap.

### Notes

- I1 was verified during Phase 5 (no leftover manual
  `bd label add/remove` ceremonies in `qa.md` or `orchestrator.md`;
  the `bd label add qa-pending` calls in specialist agent files are
  correct usage -- those add the *handoff* label that QA acts on, not
  the gate-state labels qa-gate.sh manages).
- The Phase 0 plan intentionally left the QA gate semantics, hook
  payload schema, and tool-list narrowing to later phases. Existing
  installs continue to work after upgrading to v3.0.0.

## [2.0.0] - 2026-05-08

Last commit before the v3 work began: `7dda421 fix installation command`.

This is the baseline this changelog is being backfilled from. Reconstructed
from `git log --oneline` and the README/docs as they stood at that commit.

### Added
- Mandatory orchestrator -> specialists -> QA workflow with five agents:
  `orchestrator`, `qa`, `backend`, `frontend`, `devops`.
- Beads (`bd`) integration as a hard requirement: `bd prime` for context,
  `bd ready` / `bd blocked` surfaced at SessionStart, hierarchical issues
  (epics + subtasks), labels for domain (`backend`, `frontend`, `devops`)
  and QA state (`qa-pending`, `qa-approved`).
- Stop-hook QA gate: blocks task completion until `qa-approved` label or
  "QA APPROVED" comment is recorded on the active task.
- LLM-driven intent discovery in `intent-router.sh` (replacing keyword
  matching) with mandatory delegation framing in the
  `<mandatory_delegation>` context block.
- Hook scripts: `session-start.sh`, `intent-router.sh`, `post-edit.sh`,
  `verify-before-stop.sh`, `session-end.sh`.
- `install.sh` (Linux/macOS) and `install.ps1` (Windows) with backup,
  update, and merge modes.
- `workflow-engine` skill with workflow documentation.
- Documentation set under `docs/`: `QUICKSTART.md`, `ARCHITECTURE.md`,
  `AGENTS.md`, `HOOKS.md`, `BEADS.md`, `WORKFLOW.md`, `TROUBLESHOOTING.md`.
- `CLAUDE.md` template for project memory (users, journeys, conventions,
  known mistakes).

### Known limitations (resolved in v3)
- Installer scripts embedded the agent prompts as heredocs, so the
  PowerShell version drifted to a much shorter copy than the bash version
  (resolved in v3 Phase 0 / G4).
- No model pinning -- agents inherited whatever model the runtime decided
  (resolved in v3 Phase 0 / A1).
- No plugin manifest, so the install was not a "plugin" by Claude Code's
  formal definition (resolved in v3 Phase 0 / E1).
- `verify-before-stop.sh` had a marker-file bypass and a `$TASK_ID`
  placeholder bug; `post-edit.sh` emitted raw text instead of JSON; QA
  approval was decided by comment-text fallback (resolved in v3 Phase 1).

## [1.0.0] - earlier

Initial commit (`1909ebf initial commit`). Pre-Beads experimental layout;
not separately documented because v2 superseded it before any external
release.

[Unreleased]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.4.0...HEAD
[3.4.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.3.0...v3.4.0
[3.3.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.2.0...v3.3.0
[3.2.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.1.0...v3.2.0
[3.1.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v3.0.0...v3.1.0
[3.0.0]: https://github.com/preql-data/claude-workflow-plugin/compare/v2.0.0...v3.0.0
[2.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v2.0.0
[1.0.0]: https://github.com/preql-data/claude-workflow-plugin/releases/tag/v1.0.0
