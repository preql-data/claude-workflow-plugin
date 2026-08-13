<!--
MIRRORED, 2026-08-12 (claude-workflow-plugin-omiv). Source:
~/.claude/plans/v5-0-0-design-stateless-wilkinson.md. Everything below this
comment is that file, byte-for-byte.

WHY THIS FILE EXISTS. `v5-design-phase.md` beside it is the DIRECTIVE — the
input this plan was written against — plus a fourteen-line SUMMARY of the
corrections. THIS file is the plan: the corrections in full, and the per-phase
detail established from source (Phase P's P0-P9 breakdown, D1's artifact
schema and record grammars, D2's DS1-DS8 rubric, the D7 release checklist).
Every specialist brief that cited a section by name — "Corrections to the
directive", "Phase D0 - role classes 3 to 5" — was citing THIS document while
pointing at the other one. Neither file is scanned by workflow-manifest.sh, so
neither is an install row.

WHERE THEY DISAGREE, THIS FILE WINS, and the directive is preserved as the
record of what was asked for.
-->

# v5.0.0 — Design as a first-class, reviewed, continuously-enforced phase

## Context

The plugin enforces orchestrator → specialist → QA. Every downstream guarantee — the
rubric grader, the independent reviewer, the change-set-bound approval — verifies that
**the work matches the plan**. Nothing verifies the plan, and nothing notices when the
plan quietly stops governing the work. The orchestrator both designs and delegates, and
nobody reviews the design.

v5.0.0 separates design from orchestration, gives design its own review loop, stores the
artifact where humans read and revise it, keeps it binding at every delegation boundary
rather than only at the end, and makes design ↔ tests ↔ code verifiably describe the same
system.

It carries a blocking prerequisite. The v4.1.0 closure recorded six ways the plugin's own
signals claimed more confidence than their evidence supported, and one finding:
**a gate that reports confidently on unverified evidence is worse than no gate, because it
is trusted.** v5 adds three more trusted signals (`design-satisfied`, the `design_artifact`
hash binding, the coherence count) on top of that instrumentation. Phase P fixes the
substrate first.

Target runtime flow:

```
grill → design → review design (2–3 iters) → artifact
  → orchestrate from the artifact: task per unit, dependency order, parallel batches
  → implement each unit in its own worktree, green-to-green, spec injected at spawn
  → per-unit alignment → review → coherence rollup → gate
```

---

## Decisions locked

| # | Decision |
|---|---|
| 1 | **Phase P folds into v5.0.0.** One release; P's epics close inside the v5 arc. |
| 2 | **The `v4.1.0` tag stays put.** No tag move, no `v4.1.1`. `ce5` is resolved by scoping the assert to the tag plus a guard, not by regenerating a frozen table. |
| 3 | **Identity separation is role-level.** `reviewer_identity` is a lane/role string like the existing `sol-codex` / `qa-claude`. Model-family collapse is a loud warning + statusline flag, **never a block**. Design-reviewer lane: **Sol via Codex first, Claude fallback.** |
| 4 | **Linear ships as an unproven adapter.** `docs/specs/<task-id>.md` is the artifact. The Linear path is written and unit-tested behind the degradation contract, shipped explicitly UNVERIFIED, and its live validation is recorded **NOT-PROVEN** — not PROVEN-WITH-CAVEAT, because there is no artifact at all. |
| 5 | **Branch: pull `main`, cut v5 off it.** Verified: `origin/main` is at `bb8fce7` (the PR #4 merge), contains `v4.1.0`, and is 2 commits ahead of `origin/gauntlet/v4.0.0`. |
| 6 | **The Codex-connected live arc will be run.** Cost derived from measured token flows before spending, per the LESSONS entry on the 10× estimate error. |

---

## Corrections to the directive — read before starting

These are established from source, not inferred. Each changes what gets built.

1. **`orchestrator.md:97-99` forbids exactly what decision 4 requires.** It says the design lands via `bd_doc_write(name="spec")` and *"never in a file under `docs/`, which belongs to the operator."* Rewrite it in D1, not on discovery in D4. Keep the clause count at three so `vendored-skills.test.sh:166`'s `"Three clauses override that file wherever it disagrees"` sentinel still matches.

2. **`required_fixes`, not `required_changes`.** The grader's actual field is `required_fixes` (`grader.md:87`) and `cmd_grade_record:2258-2270` keys on that literal. Two near-identical validation ladders disagreeing on one key name is the drift class `completion-contract-parity.test.sh` exists to catch.

3. **"Both manifests" is not a versioning claim.** `HANDOFF.md:305-313`: there is exactly ONE version-carrying manifest (`.claude-plugin/plugin.json`); the idiom means `.mcp.json` and `plugin.json` must agree on MCP server definitions.

4. **`1nz` does not really block `2ty`.** The fix is not to lock the iteration counter, it is to stop the counter being authoritative. Recut the Beads edge with that reason; otherwise you build a lock and then delete it.

5. **`enter` is the wrong runtime-validation point.** It is documented tolerant (`qa-gate.sh:1102-1106`, "enter never fails because of it") and F1 itself invokes it (`verify-before-stop.sh:887`) on exactly the classes that have no completion payload. A refusal there deadlocks every doc-only Stop. Enforce at **`approve`**, where the bypass grammar, error envelope, and META pattern already exist.

6. **A `^Bash$` PostToolUse matcher for `post-edit.sh` is unbuildable.** `tool_input.command` has no path field; extracting written paths from a shell command is undecidable. The matcher fix is real for `NotebookEdit` only. A reconciler is the answer for Bash — a command parser here is the harness the directive forbids.

7. **`fable-class` must not be the design-lane fallback strategy.** A family-pinned strategy freezes the design lanes to Fable and kills day-zero adoption of a new top family (`pick_best:407` class-0 rule, proven by `ms-T3`). `top` is the correct expression of the intent: it resolves to Fable today *and* auto-adopts. Ship `<family>-class` as legal grammar; do not use it as the design default.

8. **Do not wire `SubagentStop`.** It breaks the pinned literal at `platform-audit.test.sh:274-275` and reopens the (f) documented-difference contract v4.1 just narrowed. A per-subagent gate that cannot block a release is decoration; `design-conform` at approve does the job.

9. **Do not path-scope `prevent-orchestrator-edits.sh`.** `LESSONS.md` records the P0 verbatim: fail-closing that hook on ambiguous identity denied legitimate specialist edits because the runtime does not surface `subagent_name` to PreToolUse. Use the tools-list omission (airtight) plus a phase-scoped consequence check.

10. **Sol-first must never touch the three gate scripts.** `reviewer-lane-degradation.sh:33-38` asserts zero `codex|reviewer[._]lane` matches in `qa-gate.sh`, `verify-before-stop.sh`, `review-check.sh`, with a live META. Lane selection lives in `orchestrator.md`'s relay step reading `codex-detect.sh status`.

11. **Rubric criterion ids are `DS1..DS8`**, not `D1..Dn` — the latter collides with these phase names.

12. **`docs/ARCHITECTURE.md:70-74` is wrong** beyond what the directive claims. Verified: `jq '.hooks|keys[]' .claude/settings.json` returns **seven** events including SubagentStart; the prose says six and that `hooks.json` "adds a 7th."

13. **Whether the runtime honours a mid-session frontmatter `model:` change is unverifiable offline** and is established nowhere in this tree. Per-unit escalation must be claimed as *a declared, audited, reversible pin change*, never as "the unit ran on Opus."

14. **`.claude/model-roles` is manifest class `operator`** (`workflow-manifest.sh:339`), so an *edited* copy gets a `.new` sidecar and never receives the v5 defaults — that install silently stays on `implementer=opus-class`. Verified: the repo's copy hashes `be920fb1…`, byte-identical to `manifests/v4.1.0.sha256:81`.

---

## Setup

```bash
git checkout main && git pull            # → bb8fce7, contains v4.1.0
git checkout -b v5/design-phase
cp <this directive> docs/plans/v5-design-phase.md
```

Index it in `docs/plans/README.md` following the v4.1 entry's format (filename, scope
sentence, phase enumeration with Beads ids, bolded `**Status**:` block). Open one Beads
task per phase — this repo has **zero `epic`-type issues** and models epics as dotted child
ids (`0wk.n`), so follow that convention, do not "fix" it.

---

## Phase P — prerequisite hardening

Ordering. Hard edges: **P2 after P1** (F1's hash binding is meaningless until the tracker is
complete); **P9 last** (everything before it touches manifest-covered files). Soft edge:
P3 → P2 → P7 all edit `cmd_approve`; serialise or expect merge pain. Fully parallel:
P0, P4, P5, P6, P8.

### P0 — Beads hygiene
Close the 19 approved-never-closed tasks (`y4a.13`, `y4a.14`, `0wk.1`, `0wk.9`–`0wk.29`,
`llh.23`) with a reason naming the release that shipped them. Close the five 2026-05-09
test detritus tasks (`0pj`, `6dk`, `f8r`, `t0l`, `wmj`). Leave `bt7`. Merge the `8zi`/`2j6`
duplicate. **Guard:** `session-start.sh:625-667` already lists `qa-deferred` and
`qa-pending`; add a third list from `bd list --status in_progress --label qa-approved`,
same shape, same `|| echo "[]"` degradation. Test: extend
`specs/session-lifecycle.sh` with a seeded case plus an anti-vacuity case.
*Verify:* `bd list --status in_progress --json | jq length` → `1`.

### P1 — `94d`: the tracker under-covers
**Reconcile into the tracker; do not make `reviewable_changes` a read-time union.** A union
fixes the detector and leaves `change_set_hash()` (`impact-report.sh:287`) tracker-only,
producing a gate that names 14 paths and releases on an approval binding 9. That hole is
already reachable on the git-fallback path via the empty-set hash (`e3b0c442…`, named at
`verify-before-stop.sh:1412`); a union makes it common rather than rare.

- New `qa-gate.sh reconcile-tracker` + `reconcile_tracker()`, modelled on
  `gate_baseline_exclude_tracked()` (`:264-298`) — its absolute/relative matching and
  `R old -> new` handling are the template. Non-git → no-op. `git status` failure →
  return 1 (the divergence signal). Subtract the gate baseline with `comm -23` under
  `LC_ALL=C` both sides. Emit **absolute** paths (post-edit records `tool_input.file_path`
  verbatim; a relative spelling double-counts). Include `??` untracked and `D` deletions.
  Filter through `workflow-denylist.sh`. Append only what is absent (`grep -qxF`).
  No `require_bd`. Sentinels `# TRACKER-RECONCILE BEGIN (94d)` / `END`.
- Call sites: `cmd_enter` before `generate_impact_report` on **both** arms (`:1050`, `:1106`);
  `cmd_approve` immediately before `IMPACT-REPORT-REFUSAL` (`:1290`) with a
  `tracker_unreconcilable` exit-2 refusal; `verify-before-stop.sh` at the top of the
  detection stage (before `:778-784`), fail-closed via `emit_block`.
- Delete the `[ "$found" = "1" ] && return 0` short-circuit at `verify-before-stop.sh:381`
  and update the now-false ORDER MATTERS comment at `:358-363`.
- `NotebookEdit` into the PostToolUse matcher in **both** `.claude/settings.json:63` and
  `.claude/hooks/hooks.json:50` (`platform-audit.test.sh` pins the pair, so a one-sided
  edit goes red); add `// .tool_input.notebook_path` to `post-edit.sh:20`.
- Delete the **no-flock** trim at `post-edit.sh:125` — a non-atomic read-modify-write whose
  failure mode is losing tracked paths. Keep the flocked trim.
- Add the reconciler as a second migration source in `workflow-denylist.sh:76-86`.

**Migration:** any session with git-visible dirt beyond the tracker gets a different hash;
in-flight approvals stop matching → `LABEL_WITHOUT_RECORD` → the already-printed
remediation. Fail-closed direction. Ship in one landing; say "hash migration" in the
CHANGELOG.

*Tests.* L2 `specs/gate-baseline-v2.sh` §7: git-init, baseline, drive `post-edit.sh` for A,
create B with plain `printf >` (the Bash case), assert both are tracked exactly once
absolute-spelled, assert the hash moved, assert a baseline-captured dirty file C did **not**
enter (anti-overreach), assert the Stop block reason names B. **META (required):** strip
between the sentinels in a fixture copy, assert B is absent from tracker and reason; control
leg proves the shipped copy sees B. L1 `impact-report.test.sh` §6 pins the empty-set hash
constant. L2 `specs/post-edit.sh`: notebook payload tracked; a Bash-shaped payload with no
path field still emits `{}`.

### P2 — `qzv`: F1 labels a task, binds a change set
Three fixes, two subtractive.

1. **Bind the hash.** `cmd_approve` gains `--expect-hash <h>`, mirroring
   `grade-record --graded-hash`; after `approved_hash=$(compute_change_set_hash)` (`:1354`),
   inside `# EXPECTED-HASH-REFUSAL BEGIN (qzv)` / `END`, a mismatch is
   `expected_hash_mismatch` + exit 2 naming both hashes. F1 passes the hash of the set it
   classified at `verify-before-stop.sh:896`.
2. **Stop closing the task.** Delete `bd update --status closed` at
   `verify-before-stop.sh:911-914`. A doc-only Stop is not evidence a task is finished.
3. **The binding predicate**, one precondition on `case "$GATE_STATUS"` (`:884`), wrapped
   `# F1-CHANGE-SET-BINDING BEGIN (qzv)` / `END`: *auto-approve only when no
   `IMPLEMENTER: role=… task=…` record on `$CURRENT_TASK` is newer than the most recent
   `QA-GATE: entered at <ts>`.* Both grammars exist and are single-line ISO-8601-UTC, so
   this is a lexicographic compare over firstlines. Expose `latest_implementer_ts` and
   `cycle_opened_ts` from the **existing** `review-check.sh cmd_gate` envelope — no second
   parser. Do **not** require an IMPLEMENTER record: doc-only work is orchestrator-authored
   and requiring one deadlocks every documentation commit.
   **When the predicate cannot be established** (bd absent, unparseable timestamps,
   `review-check.sh` missing): fall through to the QA-required block naming why — not
   auto-approve, not allow.
4. **Containment**, as prose in the four specialist prompts: re-read task state at
   completion and reconcile it against what you actually passed. Not an eighth F7 field —
   that would break the key-order assertion across seven fences and twelve carriers.

*Tests.* L2 `specs/verify-before-stop.sh`: implementer-newer → blocks, status stays
`in_progress`, no label; implementer-older → approves with a matching hash; no implementer
→ approves (anti-overreach); bd shimmed to fail → blocks. **META:** strip the binding
sentinels, assert leg 1 now approves. L2 `specs/approve-idempotency.sh` for `--expect-hash`
plus its own META.
*Verify:* `grep -c 'bd update .* --status closed' .claude/scripts/verify-before-stop.sh` → `0`.

**Known residual, file as a v5 follow-up:** an F1 approve still runs
`truncate_changed_files_tracker` (`:1740`) and `clear_current_task` (`:1752`), wiping an
in-flight implementer's tracker. The gz3 ordering note at `:1722-1725` says the pairing is
load-bearing, so do not reorder it inside Phase P.

### P3 — `8zi` / `2j6` / `jue` / `l1r.3`: the label lifecycle
- `set_terminal_label <tid> <terminal>` beside `remove_escalation_labels` (`:371`), sentinels
  `# TERMINAL-LABEL-SWEEP BEGIN (8zi)` / `END`. Cycle set: `qa-approved`, `qa-blocked`,
  `qa-gate-entered`, `qa-pending`, `qa-escalated`, `qa-deferred`, `rubric-pending`.
  **`rubric-satisfied` deliberately excluded** — it is the audit trail of the verdict that
  backed the approval (`:1701-1706`).
- Snapshot labels before the sweep; restore exactly on failure, `exit 3`, matching steps 3/4
  (`:1662-1694`). Replace steps 3, 4, `:1699` and `:1706` in `cmd_approve` with one call; same
  for `cmd_block`. **Preserve the literal envelope tokens `removed qa-gate-entered=` and
  `removed qa-pending=`** (`:1792`) — specs and operators grep them.
- `remove_label` (`:888`) verifies: run the removal, then `has_label`, return non-zero if it
  survived. Without this every rollback block above is decorative.
- `cmd_enter` fresh-cycle arm removes a prior-cycle `qa-approved` (`jue`) — same reasoning as
  the legacy-baseline removal at `:1072`.

*Tests.* L2 `specs/qa-gate.sh`: seed the live `y4a.13` five-label shape, approve, assert the
set is exactly `{qa-approved, devops}` (+ `rubric-satisfied` if seeded); block leg;
enter-after-approve leg; rollback leg with a shimmed second-call failure asserting
byte-identical restoration and exit 3. **META:** strip the sentinels, assert `qa-blocked`
survives an approve.

### P4 — `2ty`: the J21 counter
- Move the bump from `verify-before-stop.sh:946` to **after** the escalation read
  (`:953-957`), and bump only when this Stop will actually run the suite. On escalated /
  deferred paths use the existing non-writing `read_iteration` (`:455-462`).
- `review-check.sh cmd_gate` gains optional `--change-set-hash <h>` and emits `rounds` in its
  envelope: the count of `REVIEW-ARTIFACT v1` firstlines whose `reviewed_hash=` matches.
  The `iteration=` token is already written and already parsed — a count over the same grep.
- Hoist the existing `review-check.sh gate` call (currently `:1326`) above the escalation
  logic, store once, reuse. Escalate on `max(ITER, ROUNDS)`. Zero review records → `ROUNDS=0`
  → today's behaviour. Never fail open.
- **Recut the `1nz` → `2ty` Beads edge** with the reason.

*Tests.* Five Stops with no review record recorded between them do not escalate (the bug);
three rounds against one `reviewed_hash` do; a fourth against a different hash resets.
**META:** revert the bump to unconditional-at-`:946`, assert the poll-only leg escalates.

### P5 — `1nz`: the doctor's live-repo assertion
Narrow the snapshot, then add the control. **No lock.** `snapshot_live()`
(`workflow-doctor.test.sh:481-533`) covers two surfaces with different owners; the
`.qa-tracking` half (`:489-496`) is already fully covered by §5b's seeded copy (`:541-553`)
plus META-TEST 3. Keeping it in 5a buys zero coverage and imports every concurrent writer
including the Stop hook and the gate itself.
- Remove the `.qa-tracking` loop; keep agent `model:` pins and the `.session-start` mtime.
  Comment naming 5b as owner of the removed half, so nobody "restores" it.
- Double-snapshot control for the residue: snapshot twice with no doctor run between; if the
  control moved, print a `note:` and skip.
- **There is no skip verb** in `run-tests.sh` (PASS/FAIL/FAILED_TESTS only). Use the house
  idiom — a bare `printf '  note: …'` that moves neither counter (`workflow-doctor.test.sh:567-570`).
  Do not add a verb. Consequence for the CHANGELOG: the total assertion count is not a
  constant when the control fires.
- Add a control-of-the-control: deliberately perturb `.claude/.session-start` between the two
  control snapshots and assert the skip path fires and the run still exits 0 — otherwise the
  skip branch is code that has never executed.

### P6 — `dxz`: code-graph flake
The disagreement is **when**, not where. `resolve.js:24-35` is identical for both tools;
`server.js:59-62` uses stock stdio transport with no serialization; `specs/code-graph-mcp.sh:198-204`
sends `code_search` (id:2) and `code_index_health` (id:3) into the **same process** 50 ms
apart, and search must finish walk + tree-sitter + resolveEdges/resolveImports +
`db.persist()` (`indexer.js:170`, temp+renameSync) before the file exists. That explains
nondeterminism in both directions; a path bug cannot.

Fix spec-side, reusing `mcp_call` unchanged: split round 3 into two processes, with a bounded
poll (~20 × 0.25 s) for `index.db` between them. **Timeout is a FAIL naming "the lazy build
did not persist within N s"**, not a flake. Do not raise the sleep. Do not touch `server.js`
— `orchestrator.md:139` and `qa.md:192` already tell agents that empty/missing health is the
expected pre-build state, so there is no agent-facing blast radius. §4's corrupt-DB META
becomes deterministic for free.

**Coupling for D4:** `impact-report.sh:43-50` already defines the degradation vocabulary
(`server:"absent"`, `impact:null`). D4 reuses it rather than minting a second one.
*Verify:* `run.sh --filter code-graph-mcp` green ten consecutive runs.

### P7 — runtime contract validation
Three pieces, each mirroring an existing one, all landing at **`approve`**.
1. `review-check.sh validate-completion <file>` — mirrors `cmd_validate_artifact:130-246`:
   required-key loop over the canonical seven, the control-character scan (`:170-188`) over
   grammar-bearing scalars only, per-field type checks, `emit_validate`. Introduces no
   reviewer/lane reference, so the structural-purity test still passes.
2. `qa-gate.sh completion-record <tid> [--file <path>]` — mirrors `cmd_review_record:2556-2658`
   including the subprocess call to the ONE validator. Grammar:
   `COMPLETION v1 task=<tid> role=<r> fields=<csv> payload_sha=<sha256> at <ts>: <n> file(s), <m> test(s)`.
   **The bjx grammar-injection class applies:** every interpolated scalar must match
   `^[A-Za-z0-9._+-]+$`; reject, never sanitise. The four free-form fields are never
   interpolated — only their presence and the payload digest.
3. A refusal in `cmd_approve` inside `# COMPLETION-CONTRACT-REFUSAL BEGIN` / `END`, sited
   after REVIEW-SEPARATION (`:1412+`), with an audited `--no-completion '<reason>'` bypass
   parsed in the same loop as `--no-impact-report` / `--no-review`. F1 passes
   `--no-completion "F1 <class> fast path: no specialist, no completion payload"`.

Land both halves together — the four specialist prompts and `qa.md` gain the call as their
last action, or the refusal fires on every flow.

*Tests.* L1: **rewrite the HONEST CEILING paragraph at `completion-contract-parity.test.sh:85-90`**
— this change makes its verbatim text false, and that file is the repo's own record of what
is enforced. New §7 asserts each carrier names the invocation. L2 `specs/qa-gate.sh`: valid
payload records and approves; `missing_key:context_coverage`; newline in `role` →
`scalar_contains_control_char`; a crafted `role` containing `: ` rejected by the char class,
with the injection reproduction as the leg's name; no record → approve refuses;
`--no-completion ''` exits 1. **META:** strip the sentinels, assert approve succeeds with no
record.
*Verify:* `grep -c completion .claude/scripts/qa-gate.sh` → non-zero (it is **zero** today).

### P8 — `LESSONS.md` scoping
**Tags in a third HTML comment. Not sections.** `grader.md:111` and the default rubric cite
lessons by **ordinal position** ("lesson 1", "lesson 2"); any reordering silently breaks
those references. Tags leave line order untouched.
- Grammar: `- <text> <!-- sources: … --> <!-- tags: gate, testing --> <!-- recorded: … -->`.
- `lessons.sh cmd_add` gains a **required** repeatable `--tag`; `extract_tags`/`merge_tags`
  twin the existing source helpers. **Injection rule:** each tag must match
  `^[a-z0-9][a-z0-9-]*$` — a tag containing `-->` terminates the comment early and relocates
  every downstream field on read-back. Reject with a structured error.
- `cmd_list` gains `[--tag <t>] [--untagged] [--since <date>] [--limit <n>]`. `--since` reads
  the existing `recorded:` comment; no new state.
- Backfill all 71 entries in the same landing. Closed vocabulary of ~6 tags declared in the
  preamble: `gate`, `testing`, `packaging`, `agents`, `evidence`, `process`.
- Consumers: `qa.md:511-514` swaps `cat LESSONS.md` for a scoped `list`; `orchestrator.md:75`
  uses `--since`/`--limit`; **`grader.md` keeps the full ledger** — lessons are
  criteria-by-reference, and narrowing the grader's view narrows the criteria. D1/D2's new
  packets get scoped reads from day one.
- **Injection stays prompt-only.** Adding programmatic injection to session-start /
  subagent-start / SKILL.md is the new harness.

*Tests.* `lessons.test.sh`: `add` without `--tag` exits 1; a `-->` tag is rejected and the
ledger is byte-unchanged; `--untagged` returns zero (the backfill-completeness invariant);
all 71 original prose strings appear exactly once; ordinal stability for the two `grader.md`
cites. **META:** a fixture with one untagged entry must be flagged.

### P9 — `ce5`, scoped to the tag (LAST)
The tag stays. Nothing here moves it.
- **Scope the assert.** `HANDOFF.md:385-391` compares `generate .` at HEAD to a table frozen
  at `57fb888` — red today by construction. Rewrite to generate over the tag's tree via
  `git archive v4.1.0 | tar -x -C <tmp>` then `cmp`. This will be green: only `LESSONS.md`
  differs, and it is the one manifest-covered path in `git diff v4.1.0..HEAD`.
- `manifests/v4.1.0.sha256` is **not** touched — it is correct for the tree it names.
- **The guard**, as a new §6 in `workflow-manifest.test.sh` (which today pins format only,
  against v3.5.0): for the **current** release's table, `git archive <tag>` into a tempdir,
  run the current generator, `cmp`. Tag absent (shallow clone) → `note:` skip.
  **Scope it to the current release only** — running today's generator over the v3.5.0 tree
  is unverified, and a red there would be unrelated to `ce5`. If it happens to reproduce,
  pin it and say so.
- **Do not build a HEAD-vs-frozen guard.** `plugin.json` at HEAD carries the frozen table's
  own version for the entire development period after every release, so such a check is red
  always — the `hbr` pathology, a check that can never go green.
- **META:** mutate one hash in a copy of the frozen table and assert the comparator flags it.

---

## Phase D0 — role classes 3 → 5

### Config grammar
```
designer        = top
design_reviewer = top
orchestrator    = top
implementer     = sonnet-class
reviewer        = top

implementer_class_high = opus-class     # not a role: owns no agent files,
                                        # never appears under `roles` in the artifact
reviewer_lane        = auto
design_reviewer_lane = auto             # Sol-first is already `auto` semantics
```

`design_reviewer` is **both** a strategy (the Anthropic frontmatter pin) and a lane (who is
engaged). Lane resolution mirrors `detect_reviewer_lane` (`model-select.sh:538-566`) with a
`WORKFLOW_DESIGN_REVIEWER_LANE` env seam. **Memoise the probe** in a script-scope variable —
it must run once per invocation, not once per lane.

### Generalising the strategy
`opus-class` is a literal in three places (`:504-511` enum, `:572` jq filter, `:578`/`:585`
warnings). Replace with `^[a-z][a-z0-9]*-class$`: `family="${strategy%-class}"`,
`prefix="claude-$family-"`. `sonnet-class` / `fable-class` / `haiku-class` then exist for
free. Add a **typo guard**: empty subset *and* `claude-$family` absent from the ranking tiers
→ the warning also says "not a known tier — check for a typo". Do not gate selection on the
tier list; that kills day-zero adoption.

`sonnet-class` is still generation-aware **within** the family — the trade is tier, not
adoption. Rider to record: track grader rounds per implementation task before and after; if
rounds rise materially, `implementer=opus-class` is a one-line revert and the observation
belongs in `LESSONS.md`.

### Structural changes
- `ALL_ROLES="designer design_reviewer orchestrator implementer reviewer"` defined once near
  `:114-119`; `cmd_status:915` and `cmd_roles:956` iterate it.
- **`cmd_apply:798-880`**: replace nine flat variables with a TSV scratch file
  (`role\tstrategy\tpick\tfallback`) built by one loop, then a single jq pass. Bash 3.2 — no
  associative arrays.
- **`current_pin():638-652` has an `orchestrator|*)` catch-all** — an unhandled role silently
  reads `orchestrator.md`, so `_apply_role` would compare the new lanes against the
  orchestrator pin and skip the rewrite with **no error**. Add `DESIGNER_AGENT` /
  `DESIGN_REVIEWER_AGENT` constants and explicit arms; make the catch-all warn.
- Artifact **schema 2**: five `roles`, five `strategies`, five `fallbacks`,
  `reviewer_lane`, `design_reviewer_lane`, `escalation:{strategy,resolved}`,
  `identity_collapse:<bool>`, `missing_keys:[…]`. **Retain the top-level
  `implementer_fallback` boolean** — `ms-R1`/`ms-R2` read it. Keeping the escalation out of
  `roles` means `check_parity` in `specs/model-roles-parity.sh:104-121` needs no change.

### Statusline — five roles
Fixed order `des dsr orch impl rev`; a non-`claude` lane substitutes the literal `sol`.
1. All values equal and both lanes `claude` → `" • model: <short>"`.
2. Otherwise group by identical value, `+`-joined labels, space-separated groups.
3. `MAX_GROUPS=3`, then ` +<k> more`.
4. Render over roles **present** in `.roles`, so a leftover v4 three-role artifact still works.
5. Flags appended: `!esc`, `!id`, `!sess`.

| Condition | Rendered |
|---|---|
| both lanes claude | ` • des+dsr+orch+rev:fable-5 impl:sonnet-5` |
| both lanes codex | ` • des+orch:fable-5 dsr+rev:sol impl:sonnet-5` |
| design codex, review claude | ` • des+orch+rev:fable-5 dsr:sol impl:sonnet-5` |
| all equal, lanes claude | ` • model: fable-5` |
| escalation active | ` • des+dsr+orch+rev:fable-5 impl:opus-5 !esc` |
| collapse + drift | ` • des+dsr+orch+rev:fable-5 impl:sonnet-5 !id !sess` |
| four distinct | ` • des:fable-5 dsr:sol orch:mythos-2 +2 more` |

Effect on `model-roles.test.sh:226-267`: `4.1`, `4.2`, `4.5`, `4.6` unchanged (rule 4 saves
`4.2`); **`4.3` changes** to `• orch+rev:fable-9 impl:opus-5-0`; `4.4` tightens to the exact
string; add `4.7`–`4.12`.

### Per-unit escalation
Declared per unit in the design artifact (`implementer_class: high`) and **mechanised as the
Beads label `impl-class-high`** — only the label is a machine surface.
`model-select.sh escalate <task-id>` resolves `implementer_class_high` through the same
`role_strategy` + `pick_for_role` over the cached listing, writes
`.claude/.qa-tracking/implementer-escalation.json` atomically **before** the rewrite, then
calls `workflow-model-apply.sh --role implementer <id>`. Idempotent.
`model-select.sh restore` reverses it. Three restore paths so a crash self-heals:
`session-end.sh` best-effort, the next SessionStart `cmd_apply`, and explicit `restore`.
Deliberately **not** wired into `qa-gate.sh` — the gate stays free of model concerns.

**Honesty constraint (correction 13).** Offline tests assert file state, artifact content,
and reversibility only — never "the unit ran on Opus." RELEASE_AUDIT gets two rows: the
mechanism (PROVEN) and the runtime-honouring leg (NOT-PROVEN, with the experiment named).
No CHANGELOG/README/Slack line may claim escalation changes the model a subagent runs on.

### Identity collapse
`identity_collapse` = designer id == design_reviewer id **and** the design lane is `claude`.
On collapse: the `!id` statusline flag, a warning in the resolver observations, and a
`design-family-collapse` flag file. **Exit 0, pins written.** Note the consequence of the
locked default: a stock install without Codex has the flag permanently lit. Document the two
clearances in the `model-roles` header — install Codex (lane flips, no collapse) or set
`design_reviewer=opus-class`.

### Session-model guard
The live session model is observable **only** in the statusline stdin envelope;
`session-start.sh` never reads stdin. So: `statusline.sh` captures stdin, reads
`.model.id`, compares against `.roles.orchestrator`, and on mismatch writes
`session-model-drift.json` (read-compare-write only, since the statusline runs every render)
and renders `!sess`. `session-start.sh` Warning 7 re-validates the flag against the current
artifact and emits the fix verbatim (`/model <resolved>` or `make session`). Never blocks.
`intent-router.sh` surfaces it in-session too.
**Do not route this through `_warn`** — `session-start.sh:402` keeps only the *last*
`^model-select:` line, so a new loud warning there is swallowed. New notices ride the
artifact (`missing_keys`, `identity_collapse`) and get their own SessionStart warnings.

### Hardcoded-7 sites
**Convert to discovery:** `model-select.sh:915`/`:956`/`:798-880` (ALL_ROLES + TSV);
`:942-943` `_drift_check` (derive from `--print-role-map`); `workflow-model-apply.sh:156`
(drop the name test, print one `skipped: N agent file(s) not present (a, b)` summary);
`session-start.sh:531` (build from `.claude/agents/*.md`); `model-roles.test.sh:99`/`:200-204`/`:208-214`;
`no-nested-spawn-instructions.test.sh:74-81` (glob minus `orchestrator.md`);
`specs/model-select.sh` loops; `specs/model-roles-parity.sh:15,51`;
`specs/installer-mcp-config.sh:215-225`.

**Bump deliberately** (each is a manifest or an audited literal whose value is being exact):
`.claude-plugin/plugin.json:20-28`; `agent-mcp-tools-parity.test.sh:63-74` (add
**`design-reviewer` only**, with a justification line — `designer` carries MCP grants and is
not exempt); `completion-contract-parity.test.sh:240-241`/`:248-256`;
`install.sh:579-583` + `install.ps1:493-497` required lists; `docs/AGENTS.md:9-19`;
`README.md:300`; `SKILL.md:28,:39`.

**Leave alone:** `agent-time-budget.test.sh:63`, `agents-manifest-parity.test.sh`,
`install.sh:1663`, `workflow-manifest.sh:306` — already discovery.
**`workflow-doctor.sh:726 DOCTOR_CORE_AGENTS` must NOT gain `design-reviewer`** — the
rationale block at `:700-724` is explicit that requiring bd grants on a read-only agent makes
the doctor FAIL a correct install.

**Both new agent files must carry the `"Depth beats speed"` time-budget block and be
registered in `plugin.json`,** or `agent-time-budget.test.sh` and
`agents-manifest-parity.test.sh` go red with zero code changes. D0 owns the frontmatter and
registration; D1/D2 own the prompt bodies.

---

## Phases D1–D6 — the design phase

Every item is a new agent file, a new rubric, a new subcommand on an existing script, a new
field on an existing contract, or a new condition in an existing gate. **No new harnesses.**

### D1 — designer, artifact, hash, edit ban
**Storage.** `docs/specs/<task-id>.md`, committed, one file per epic. Path root is
`${DESIGN_SPEC_DIR:-$PROJECT_DIR/docs/specs}` — the env seam the L2 fixture uses.

**The `spec` bd_doc is retained and demoted to a pointer**, not deleted. It cannot be the
artifact (`bd_doc.js:21-28` makes every non-`main` doc a new versioned comment per write, and
D2 requires in-place revision), but three shipped readers point at it —
`subagent-start.sh:260-267`, grading-packet item 2, and rubric C1. Its new body:
```
DESIGN-POINTER v1
artifact: docs/specs/<task-id>.md
design_hash: <h>
unit_id: <U-n>
```
Append-only becomes a feature: the version sequence is a free audit trail of which hash was
current at each delegation. Mirror the same three lines into `bd update --design`. **Do not**
mirror the artifact body — two mutable copies of the design is the failure being prevented.
`--external-ref` carries `linear:<issue-id>` on the Linear path.

**Artifact shape.** Human prose (`Problem` / `Approaches considered` (≥2, with technical
rejection reasons) / `Chosen approach` / `Units` / `Global constraints` verbatim /
`Out of scope` / `Verification plan` / `Revision log`) plus **one** machine block between
`<!-- DESIGN-UNITS BEGIN -->` / `END` sentinels containing fenced JSON. Extraction is `awk`
between sentinels, strip the fences, `jq` — the same discipline as `files_changed_of`
(`epic-gate.sh:131-145`). No YAML parser.

```json
{ "contract_version":"1", "task_id":"…", "designer_identity":"designer",
  "designer_model":"…", "grilling_ref":"<ts>",
  "global_constraints":[…], "out_of_scope":[…], "open_questions":[],
  "units":[{ "unit_id":"U1", "task_id":"<child-beads-id>", "role":"backend|frontend|devops",
    "title":"…", "goal":"…",
    "acceptance":["falsifiable; names an artefact, command, or record"],
    "files":["relative/path/a.sh"], "interfaces":["…"], "verification":"<command>",
    "depends_on":["U0"], "out_of_scope":[…], "risks":[…],
    "implementer_class":"high|standard", "escalation_reason":"…" }] }
```
`files` is the load-bearing field: D4's prospective intersection input and D5's conformance
input.

**Hash.** New `impact-report.sh --hash-file <path>`:
`sed -e 's/\r$//' -e 's/[[:space:]]*$//' | sha256_stdin`, reusing `sha256_stdin:272-284` and
inheriting the `sha256-unavailable` sentinel. Normalisation is not cosmetic — the artifact
gets edited on both platforms and a CRLF-only diff must not read as a design change.

**Binding.** The reviewer's verdict names the bytes it read, via the *identical* three-source
authority ladder as `grade-record:2455-2490`. **The approval record gets no fourth machine
token** — `qa-gate.sh:1594-1597` is explicit that every token since llh.18 goes after
`change_set_hash`, and `worktree=` already spent that budget. The design binding goes in the
**bracketed-suffix space**: ` [design: <h>]`, via the same `comment_suffix` mechanism that
already carries `[impact-report bypass:]`, `[review bypass:]`, `[rubric mismatch:]`
(`:1613-1637`). Byte-safe, zero reader changes.

**Continuous enforcement is the live recompute, not a label.** `review-check.sh design-gate`
recomputes `--hash-file` on every call. A one-byte post-approval edit to the artifact
re-arms the gate exactly the way a post-approval code edit does. That is what makes "silent
deviation is illegitimate" true rather than aspirational.

**Edit ban — two layers, no PreToolUse path scope (correction 9).**
1. *Structural, airtight:* `designer.md` omits `Edit`, `MultiEdit`, and `Bash`.
2. *Consequence, phase-scoped:* `design-record` refuses when `--file` does not resolve under
   `$DESIGN_SPEC_DIR` (`artifact_outside_spec_dir`), and when the change set contains any
   path outside `docs/specs/` **while no implementer record yet exists on the task**
   (`designer_touched_source`, naming the paths). Once implementation starts, the check is off.

Residual, stated in the register of `qa-gate.sh:1573-1583`: a designer holding `Write` can
create a source file; the design record then cannot be written, so nothing releases. This
raises the bar; it is not a sandbox.

**Also in D1:** rewrite `orchestrator.md:97-99` (correction 1) and `docs/AGENTS.md:739-751`
("Adding a New Agent" is stale) — D1 is the moment that list is freshly correct.

### D2 — the design review loop
`.claude/agents/design-reviewer.md` — grader's exact read-only tool set, strict-JSON output,
"Uncertainty is a fail", fresh context.

`.claude/rubrics/design.md`, `version: 1`, `applies_to: design`, **standalone — not
`extends: default`** (pulling code criteria into a design review is a category error).
Criteria `DS1`–`DS8`: acceptance criteria observable and falsifiable; decomposition complete
and disjoint (every criterion owned by exactly one unit, no two units declaring the same
file); every unit declares `files`/`interfaces`/`verification`; ≥2 approaches with technical
rejection reasons; `out_of_scope` non-empty; global constraints copied verbatim; **DS7 —
reuse before building**, every new file/script the design introduces carries a one-line
justification for why an existing one could not be extended; DS8 — contradicts no
`LESSONS.md` entry and no existing record grammar. DS7 mechanises the release's own
non-negotiable constraint as a rubric criterion.

**`qa-gate.sh design-record <tid> --file <artifact> [--verdict-file|stdin] [--design-hash <h>] [--no-grilling '<reason>']`**
```
DESIGN-REVIEW v1 iteration=<n> reviewer=<id> model=<m> design_hash=<h> verdict=<approved|needs_revision>
criteria_failed=[<DSn>,…] at <ts>: <summary>[ [amends: <prev-hash>]][ [reviewer-family-collapse: …]][ [grilling bypass: …]]
```
**Writer-side character classes are mandatory** — the bjx lesson applied prospectively, inside
`# DESIGN-SCALAR-CLASS BEGIN/END`: `iteration` `^[0-9]+$`, `reviewer` `^[A-Za-z0-9._-]+$`,
`design_hash` `^[A-Za-z0-9-]+$`. Reject, never sanitise. The reader
`latest_approved_design_hash()` carries the **same** classes and anchors with
`startswith("DESIGN-REVIEW ")` + a single `capture(...)` so first/last cannot diverge.

Labels: `approved` → `-design-pending +design-approved`; `needs_revision` → `+design-pending`,
nothing removed. Loop cap in `.claude/rubric-config` (default 2, cap 3); on cap, escalate
through the existing J21 `qa-gate.sh choose`.

**Independence is free.** Adding `designer` to `subagent-start.sh:100-105` makes every
designer spawn post `IMPLEMENTER: role=designer …` via the existing `record_implementer()`.
`review-check.sh design-gate` reuses `cmd_gate:409-420`'s exact computation. Zero new
identity machinery.

**Amendments** are the same subcommand at `iteration=n+1` against an artifact revised
**in place** whose Revision log gained a row (so the hash moved); `design-record` writes
` [amends: <prev-hash>]`. Duplicate artifacts are refused structurally: `--file` must be the
path the previous record named for that `task_id`, else `artifact_path_changed`.

**Enforcement, three sites.**
- *Binding:* `qa-gate.sh approve`, a `# DESIGN-SEPARATION BEGIN/END` block after
  REVIEW-SEPARATION (`:1506`), delegating to `review-check.sh design-gate`. **Exit 5** (4 is
  taken). Keys: `design_record_missing`, `design_hash_stale`,
  `design_reviewer_not_independent`, `design_conflict_open`, `unit_not_in_design`,
  `undeclared_files`, `design_check_unavailable` (fails closed). Bypass `--no-design '<reason>'`.
- *Second reader:* `verify-before-stop.sh:1326`, alongside the existing `review-check.sh gate`,
  so a hand-written label is still caught. Exactly two readers — `qa.md:462` warns against a third.
- *Ordering (pre-delegation, NOT Stop):* `orchestrator.md` §4a runs
  `qa-gate.sh design-gate-precheck <epic-id>` before the first `Task()`. It is a real script
  exiting non-zero. It cannot *force* the orchestrator to call it — nothing can — which is
  why the binding site exists.

### D3 — grilling record + vendored-doc integrity
**`qa-gate.sh grilling-record <tid> --rounds <n> --questions <n> --approaches <n> --unresolved <n> '<summary>'`**
```
GRILLING v1 rounds=<n> questions=<n> approaches=<n> unresolved=<n> vendor_hash=<h> at <ts>: <summary>
```
Same validation-ladder shape; `approaches >= 2` (the vendored method's own bar) else
`insufficient_approaches`. Written by the **orchestrator at root** — it ran the dialogue.

`vendor_hash = --hash-file .claude/vendor/superpowers/brainstorming/SKILL.md`. This is the
integrity half `e2j` asks for: the record names *which method text was in force*, so later
drift cannot retroactively validate a dialogue that never followed it. `MANIFEST.md` gains
the recorded hash and `vendored-skills.test.sh` asserts it equals the live one, with a META
perturbing a copy; bump `EXPECTED_ASSERTIONS` **deliberately**.

Precondition: `design-record` refuses with `grilling_record_missing` when no `GRILLING v1`
record exists on the task or its parent epic, inside `# GRILLING-PRECONDITION BEGIN/END`.
This is the pre-delegation path and it is a script, so the check is mechanical — not at Stop,
for the reason the v4.1 closure already states. Carve-out `--no-grilling '<reason>'` for the
F1 doc-only class and the single-line-typo path.

### D4 — task per unit, conformance, batching
**`epic-gate.sh plan-batches <epic-id> [--design <path>]`** → `{units, batches, degraded,
degradation_reason}`. Greedy first-fit in artifact order using the **existing** intersection
primitive verbatim (`epic-gate.sh:287-290`: `jq -nc '$a as $A | $b as $B | $A - ($A - $B)'`).
Deterministic given artifact order; document that it is greedy, not optimal.

**Visible degradation is the release-defining assertion.** `cmd_shared_files` is
retrospective and its `no-notes → 0 intersections` behaviour (asserted at
`specs/epic-gate.sh:84-88`) is safe retrospectively and **lethal prospectively** — an empty
plan reads as "everything can run in parallel." So inside
`# PLAN-BATCHES-NO-DESIGN-GUARD BEGIN/END`, any of {no approved record, artifact unreadable,
hash stale, fence absent or unparseable, any unit with empty `files`, `jq` unavailable} sets
`degraded:true` with a named reason and collapses to **one unit per batch**. Serial is always
safe. Reuse `impact-report.sh:43-50`'s existing degradation vocabulary for the graph half.
`cmd_shared_files` and its spec are **untouched**.

Output persists to `$QA_TRACKING_DIR/design-batch.json` — the manifest D5 consumes, as a
byproduct of a check the orchestrator already runs.

**`qa-gate.sh design-conform <task-id>`** — deterministic, no LLM: resolve artifact + approved
hash; recompute (`design_hash_stale`); find the unit whose `task_id` matches
(`unit_not_in_design`); compute `undeclared = actual − declared` and `unbuilt = declared − actual`
over the denylist-filtered change set. **`undeclared` non-empty is the only failure**; an
extra file is scope the design never reviewed, while a missing file is under-delivery the
acceptance criteria already catch. `undeclared_files` has exactly **two** remedies — drop the
file, or land an amendment. No overrule path, deliberately.

### D5 — spec injection, green-to-green, `design_conflict`
**The per-unit injection problem and its resolution.** `current-task` is a single global slot;
`subagent-start.sh` reads only `agent_type` (`:167`) and there is no evidence in this tree
that SubagentStart carries the Task prompt or any per-spawn key; for worktree-isolated
specialists the hook fires in the parent session with the primary's slot. A spawn-intent FIFO
was considered and **rejected**: it is correct only if runtime dispatch order equals
intent-write order, which is unspecified, and its failure mode is *mis-assignment* — unit B's
spec injected into unit A's spawn — a silent wrong-context failure strictly worse than no
injection.

**Decision.** The problem dissolves at D4 and the residue closes at approve:
1. Task-per-unit means per-unit identity *is* a task id, and the spec sits at a deterministic
   path derived from it.
2. The hook injects a **bounded batch manifest, never spec bodies** — epic id, approved hash,
   and one line per unit (`unit_id · task_id · role · declared files · spec path`). Every
   spawn gets the same true document, so **mis-assignment is structurally impossible**; the
   worst case is under-specificity. Cap at `design_batch_max_units=8`; above it, inject the
   count and path only, keeping the injection conservative in the sense `:216-217` means.
3. **The mechanical closure is `design-conform` at approve, not the injection.** Per the
   LESSONS entry that prose cues do not drive tool use, a required read is enforced by
   consequence: a specialist that ignored its unit spec produces a diverging file set and
   `approve` refuses with `undeclared_files`. The injection makes the right thing easy; the
   refusal makes the wrong thing unshippable.
4. Degradation: manifest absent → **byte-identical output to today**; manifest present with a
   stale hash → a `DESIGN-BATCH STALE` notice naming both hashes, then fallback. Every new
   step wrapped `|| true`; the never-block invariant is preserved.

Implemented as `# DESIGN-BATCH-INJECT BEGIN/END` between `:213` and `:215`, plus `designer`
added to `is_specialist()` and `is_implementer_role()`. **`design-reviewer` is added to
neither** — packet-only, like grader and judge, for the documented reason at `:96-99`.

**Green-to-green is a consequence of task-per-unit, not new machinery.** Each unit is a task
and already passes its own Stop-time test gate. The only new thing: the unit declares its own
`verification` command, and `design-conform` checks the named test file appears in
`tests_added`. **Do not add an F7 field** — that touches the census literal and all seven
fences for no enforcement gain.

**`design_conflict` is a record, not a free-form blocker:**
`DESIGN-CONFLICT <unit-id> design_hash=<h> at <ts>: <statement>`, written by
`qa-gate.sh design-conflict`, read by `design-gate` as `design_conflict_open`. **The single
legal clearing path is a superseding approved `DESIGN-REVIEW` whose unit entry changed** —
i.e. an amendment. Not `arbitrate`: that is keyed to REVIEW-ARTIFACT finding ids via
`finding_id_in_latest_artifact:2539`, and a second id-space breaks that reader.

### D6 — coherence rollup
**`qa-gate.sh design-rollup <epic-id>`**:
```
DESIGN-ROLLUP v1 reviewer=<id> model=<m> design_hash=<h> units=<n>/<n> verdict=<coherent|incoherent> gaps=[…] at <ts>: <summary>
```
Produced by a second, cheaper `design-reviewer` spawn at root against a rollup packet (the
artifact, every unit's F7 contract, the union diff, every conflict and amendment record),
scoped to the whole-system criteria DS1/DS2/DS8 — the per-unit ones are already discharged.

Enforced on two **existing** surfaces: `epic-gate.sh cmd_check:150-215` gains a branch
returning `block` when all children are approved but no matching coherent rollup exists (its
consumer at `verify-before-stop.sh:2004-2022` already surfaces that); and, because that path
is advisory for the active task, `qa-gate.sh approve` on an epic-typed task additionally
requires the coherent rollup → `design_rollup_missing`, exit 5.

**The rollup is only as good as the tracker**, which is why P1 is blocking. Add the assertion
the directive names: the rollup's file set must match the repository diff for the bound change
set, so under-coverage surfaces as a failure rather than a pass.

---

## Phase D7 — release 5.0.0

**Version.** One line: `.claude-plugin/plugin.json:3` → `"5.0.0"`, **preserving exactly
two-space top-level indentation** (`install.sh:96-101` is a jq-free `sed` anchored on two
spaces). Installers carry zero non-comment version literals. State in the CHANGELOG **which**
major criterion from `CHANGELOG.md:9-17` is being claimed — the agent-contract change — rather
than asserting "major" unmapped.

**Docs.** `WORKFLOW.md:157-177` label-flow diagram rebuilt from the state table at
`HOOKS.md:1113-1119` and pointing at it as normative; `ARCHITECTURE.md:70-74` corrected per
correction 12 plus the two missing subsections; `AGENTS.md:9-19` 7→9 and `:739-751` rewritten;
`tests/README.md:3` "Four-tier"→"Five-tier" reconciled with `HOOKS.md:1250`;
`README.md:300`; `SKILL.md:20-44`; `.claude/model-ranking:20-25` (stale pre-en9 sort
description); the `model-roles` header.

**Upgrade.** No installer change is needed for old-table selection — `install.sh:1316-1319`
already picks `manifests/v$V3_DETECTED_VERSION.sha256`, and `specs/installer-v3-upgrade.sh:1275-1279`
reads the expected name from the source tree. **The real gap is correction 14:** an edited
`.claude/model-roles` gets a `.new` sidecar and stays on Opus with no v5 keys. Mitigated by
`missing_keys` in the artifact + SessionStart Warning 8 + an explicit CHANGELOG UPGRADE NOTE.
If the Linear adapter widens the MCP surface, `workflow-doctor.sh:94 DOCTOR_TOOL_COUNTS`
("bd-mcp:21 code-graph-mcp:7") and both server READMEs must change in the **same commit** or
every v5 install exits 3.

**Manifest.** Generate `manifests/v5.0.0.sha256` **after** the version bump and all surface
changes (the table records `plugin.json`'s own hash). Prove determinism by regenerating into
a second file and `cmp`. The v4.1.0 and v3.5.0 tables are **not** regenerated; prove they
still reproduce via `git archive <tag>`.

**RELEASE_AUDIT.** **Re-scope the v4.1.0 awk ranges FIRST** (`:622-626`) from `,0` to
`/^## v5\.0\.0 claims ledger/`, re-run each, and confirm the published numbers are unchanged
(13/3/0/0/16). Then fix `HANDOFF.md:375-376`, which asserts those ranges "legitimately end at
`,0` because v4.1.0 is currently the last section" — false in the same commit. New
`## v5.0.0 claims ledger` section with the directive's rows plus: five role classes resolve
independently; `<family>-class` generalises with no per-family case; escalation is scoped and
reversible (PROVEN) **and** runtime-honoured (**NOT-PROVEN**, experiment named); identities
never silently collapse; Sol-first with Claude fallback probing once; the session guard warns
and never blocks; the census is gone or bumped (three measured counts equal 9); upgrade
preserves operator files; `--verify` exits 0 at 11/11 and exactly 21/7.

**Live validations.**
- **LIVE-1 (upgrade + verify), RUN.** Install v4.1.0 from the tag into a scratch target, edit
  one operator file and leave another stock, `--upgrade`, then `--verify`. Record the
  classification line, the verdict counts, the exact `.new` sidecar list (must include
  `model-roles.new` for the edited case and must **not** for the stock case), both new agents
  present, and the doctor's eleven-line block with its exit code.
- **LIVE-2 (full Codex-connected arc), RUN — cost-gated.** grill → design → one review
  revision → artifact → conformance → two parallel worktree batches → seeded
  `design_conflict` → amendment → review → coherence → release. **Derive the estimate from
  measured token flows and stop at a confirmation gate before spending** (the v4 A/B was
  estimated at $10–20 and cost ~$206). Record fixtures, invariants, and actual cost.
- **LIVE-3 (Linear-connected), NOT RUN.** Status **NOT-PROVEN**, not PROVEN-WITH-CAVEAT —
  there is no artifact at all. Verification-method column reads "live run against a
  Linear-connected workspace — NOT RUN". A matching residual names the experiment that would
  close it. **Section-preamble rule: no line in CHANGELOG, README, docs, or Slack may assert
  the Linear path works.** The CHANGELOG says verbatim: *"The Linear adapter ships unproven —
  no live validation was run."* The honesty is made mechanical by `specs/design-degradation.sh`,
  cloned from `reviewer-lane-degradation.sh`: STRUCTURAL (zero `linear` references in the
  three gate scripts, with a META injection) + BEHAVIOURAL (byte-identical records and
  envelopes with and without `DESIGN_STORE=linear`).

**CHANGELOG / HANDOFF / Slack.** `## [5.0.0]` in house voice with the major-criterion mapping,
Added/Changed, and a four-point UPGRADE NOTE (operator-owned `model-roles`; the implementer
tier moved and how to revert; Linear unproven; re-run `--verify`). New HANDOFF verify section
above `:278`, newest-first, every condition a runnable command with expected output —
including that `git rev-parse v4.1.0` is unmoved and its manifest still reproduces. Slack
draft in the established style, delivered in chat, **not posted**; the "Heads-up" section
carries the three honest items (edited `model-roles` stays on Opus until merged; Linear
unproven; escalation's runtime leg unproven).

---

## Verification

Per phase: `make test` (L1) · `make test-component` (L2) · `make test-e2e-unit` (L3) ·
`make lint` · `make check` · `make manifest-validate`. `make test-ci` is the local mirror of
CI. Read the **completeness lines** (`Total: N Passed: N Failed: 0`), never the absence of
`FAIL`.

Whole-release gates:
```bash
node -e 'console.log(JSON.parse(require("fs").readFileSync(".claude-plugin/plugin.json","utf8")).version)'  # 5.0.0
grep -c '^  "version": "5\.0\.0",$' .claude-plugin/plugin.json                                              # 1
bash install.sh --help | head -1                                                                            # …v5.0.0 installer
bash .claude/scripts/workflow-model-apply.sh --print-role-map | wc -l                                       # 9
jq '.agents|length' .claude-plugin/plugin.json                                                              # 9
bd list --status in_progress --json | jq length                                                             # 1
grep -c completion .claude/scripts/qa-gate.sh                                                               # non-zero (0 today)
bash .claude/scripts/lessons.sh list --untagged | grep -c '^- '                                             # 0
bash .claude/scripts/workflow-manifest.sh generate . | cmp - manifests/v5.0.0.sha256                        # silent
bash install.sh --verify                                                                                    # exit 0, 11/11
```
Assertion counts **will** move (P1 changes hashes, P5 can skip, P8 rewrites a
manifest-covered file). State the new numbers as measured — no release note may quote
"2,002" as a constant.

---

## Risks

| Risk | Handling |
|---|---|
| The P1 hash migration breaks in-flight approvals | Fail-closed direction; the block already prints its own remediation. One landing, called out in the CHANGELOG. |
| Per-unit escalation may be decorative if the runtime caches agent definitions | Claimed only as a reversible pin change; the runtime leg ships NOT-PROVEN with its experiment named. |
| Stock no-Codex installs light `!id` permanently | Documented with two clearances in the `model-roles` header. A flag users learn to ignore is worth revisiting if it persists. |
| Sonnet-class implementers reduce quality | Tracked as grader rounds per task, before and after. One-line revert; observation goes to `LESSONS.md`. |
| The design phase front-loads time on small work | The F1 doc-only class and the single-line-typo carve-out both bypass via `--no-grilling`. |
| LIVE-2 cost overruns | Estimate derived from measured token flows, hard confirmation gate before spending. |
