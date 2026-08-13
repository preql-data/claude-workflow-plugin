# Tests

Four-tier test pyramid for the claude-workflow-plugin. Each tier catches a
different failure mode; together they form the gate that a change has to
clear before it ships. The live tier is manual-only and invariant-based as
of v3.1.0 (spec item 0.8) — see [Live e2e (manual, invariant-based)](#live-e2e-manual-invariant-based)
below.

## Overview

| Tier | Lives at | What it proves | Live? | Where it runs |
| ---- | -------- | -------------- | ----- | ------------- |
| L1 — bash unit | `.claude/scripts/tests/*.sh` | Individual hook script logic with crafted stdin payloads | Offline | `make test`, CI |
| L2 — component | `.claude/tests/component/specs/*.sh` | Hook pipelines end-to-end with tempdir fixtures | Offline | `make test-component`, CI |
| L3 — vitest unit | `.claude/tests/e2e/specs/*.unit.spec.ts` | Harness internals: trace schema, normalization, custom matchers, the invariant engine | Offline | `make test-e2e-unit`, CI |
| L3 — live e2e | `.claude/tests/e2e/specs/<fixture>.spec.ts` | Plugin behaviour end-to-end against real Claude, asserted via fixture-declared invariants | Live (~$5–10 per fixture) | `make test-live FIXTURE=<name>` (manual only) |

The tiers above are a statement about WHAT is covered. Where they RUN is a
second axis, and it is not free: every one of them is authored and measured on
macOS while CI runs Linux. `make test-linux` re-runs L1 (and L2) unchanged
inside an `ubuntu:24.04` container so that difference is measurable before a
push rather than after one — see
[The Linux tier](#the-linux-tier-make-test-linux) below.

The retired L4 daily drift watch and any automatic L3-live PR/cron runs
were removed in v3.1.0 spec item 0.8. CI consumes zero API spend on a
normal PR or push run.

## When to add a test at which tier

Use the first row that matches:

| You changed... | Add the test at... | Why |
| -------------- | ------------------ | --- |
| A single hook script's logic (input → output JSON) | L1 | Cheap, fast, the contract is a JSON envelope |
| Hook pipeline behaviour — e.g. how `qa-gate.sh` interacts with `current-task.sh` and `verify-before-stop.sh` | L2 | L2 has the fixture scaffolding to chain hooks; L1 stops at one script |
| `runFixture` / `trace.ts` / `invariants.ts` / harness internals | L3-unit | Pure logic, no model calls needed |
| Orchestrator → specialist → QA chain, or any behaviour that requires the model to decide something | L3-live | These are the assertions the L1/L2 tiers can't reach; gated on invariants from fixture.yaml |

If a test could plausibly live at two tiers, prefer the lower one (cheaper,
faster, more deterministic). The Phase D failure-injection specs are
a worked example: they sit at L3-unit (`_failure-regression-coverage.unit.spec.ts`,
`_gate-sanity.unit.spec.ts`) because the gate's contract is testable via
synthetic Trace mutation; no new $5–10 live run is needed to re-prove
what 4ms of deterministic logic can prove.

## Local commands

```
make test              # L1 bash unit tests
make test-component    # L2 component tier
make test-all          # L1 + L2 (the offline gate)
make test-linux        # L1 inside a Linux container (GNU tooling; needs docker)
make test-linux-all    # L1 + L2 inside the container
make test-e2e-unit     # L3 vitest unit tier (offline; includes the invariant engine specs)
make manifest-validate # Zod-replica check of .claude-plugin/plugin.json
make test-ci           # L1 + L2 + L3-unit + manifest (what CI runs)
make test-live FIXTURE=<name> [CONFIRM=1] [RECORD=1]
                       # L3 live tier — manual only; requires FIXTURE= and ANTHROPIC_API_KEY
make test-e2e-install  # one-shot npm install for the e2e harness
make cassette-diff     # diff the most recent replay vs its committed golden (debugging tool)
```

`make test-ci` is the local mirror of what the GitHub Actions
`tests` workflow runs. Mirroring is why `test-ci` — and only `test-ci`, not
`make test` — exports `STRICT_SECTIONS=1`: the CI `l1-unit` job sets it, so
without it here a skipped section would be green locally and red in CI, which is
the direction that costs a push. The price is that `test-ci` wants what CI
provisions — `npm ci` in **both** `.claude/mcp/bd-mcp` and
`.claude/mcp/code-graph-mcp` — and says which one is missing when it is not
there.

**`test-ci` mirrors CI's TIER SET, not CI's PLATFORM, and that gap is real
rather than theoretical.** This paragraph used to read "if `test-ci` is green
locally, CI will be green too"; the first time the tiers were actually run on
Linux, at `0de5ceb`, that sentence was false in three separate places at once —
`design-artifact.test.sh` red on GNU `sha256sum`'s filename escaping,
`doc-only-classifier.test.sh` PARTIAL (and therefore red under
`STRICT_SECTIONS=1`) because its symlink-spelling arm keys on `mktemp`'s root,
and two specs failing rather than skipping on an absent `python3`. Every one of
those is invisible to a green macOS run by construction. `make test-linux` is
what closes the gap; run it before a push, not instead of `test-ci`.

### The Linux tier (`make test-linux`)

Everything above runs on the developer's own box, which here is macOS: BSD
`find`, BSD `sed`, `shasum`, bash 3.2. CI runs ubuntu-latest: GNU findutils, GNU
coreutils, `sha256sum`, bash 5.2. `make test-linux` runs the **same tier bytes**
against the second set inside a container, so a red CI run is one unknown rather
than two.

- **`.claude/tests/linux/Dockerfile`** provisions what the CI `l1-unit` job
  provisions — `ubuntu:24.04`, bd 1.1.2 and node 20 from pinned,
  sha256-verified artifacts, a non-root default user — and its header lists,
  explicitly, every way it still differs from CI (architecture is the big one:
  it builds native, so an Apple Silicon box runs `linux/arm64` while CI is
  `linux/amd64`; pass `CWP_LINUX_PLATFORM=linux/amd64` to cross-check under
  emulation).
- **The repo is bind-mounted READ-ONLY**, and the mount is *verified* every run:
  `repo-bytes.sh` hashes the tracked working tree on both sides and the run
  refuses a mismatch, so "the real bytes, not a copy" is a checked claim rather
  than an asserted one. Read-only means the target is safe to run mid-session —
  a container cannot write into `.beads/` or `.claude/.qa-tracking/`, and cannot
  leave root-owned files in your checkout. Measured: the whole L1 tier runs to
  completion against it, because every spec builds its fixtures under the
  container's own `/tmp`.
- **The report names every tier's status, including the ones that did not run.**
  A container target that silently runs a subset is the exact defect this
  convention exists to prevent, so `NOT RUN` is a first-class row and is never
  scored as a pass.
- **Exit codes are three-valued**, matching the L1 runner's outcome discipline:
  `0` every requested tier ran and passed, `1` a tier ran and failed, `2` the
  tier could **not** be measured (no docker, no daemon, a build failure, a byte
  mismatch, a byte check that could not be *performed*, a tree edited under the
  run, or docker's own `125`/`126`/`127`). A missing docker prints a named skip
  and exits 2 — never a silent green.
- **A stale image is detected, not trusted.** The image carries the sha256 of
  the Dockerfile that built it as a label, and the default mode rebuilds when
  they disagree. This is here because it bit on the second run: the Dockerfile
  gained a package, the image already existed, the run reused it, and the tier
  reported a result for bytes that were not being shipped. On a host with no
  `sha256sum`/`shasum` the report says `staleness UNCHECKED` rather than
  claiming a digest match it did not compute.

**All four of those checks are PAIRED, by
`.claude/scripts/tests/linux-tier-driver.test.sh`** — mount identity, mid-run
drift, stale-image detection, and tier-status/exit discipline, each driven
beside the same cell with its condition removed. That spec runs the **real
driver bytes** through the `${DOCKER:-docker}` seam with a recorded stub and the
**real `repo-bytes.sh`** over a three-file git fixture, so leg 4 (an executable
observed running) is present rather than claimed.

It exists because the tier shipped without it and the first control found a
false green: when the byte verification could not **run** — as distinct from
running and disagreeing — the driver fell through, printed `VERDICT: every
requested tier ran on Linux and passed`, and exited 0, while the same condition
also switched off the moved-under-the-run detector that had been added because
it bit. Both are fixed (`claude-workflow-plugin-mdnc` R1-F2/F3/F4); the point
worth keeping is that **a target whose stated purpose is "every failure mode is
loud" is exactly the kind of thing that ships with no leg watching a failure
mode being loud.** Nothing in the four checks is declared UNPAIRED.

### Runner outcome semantics (a9hh / mwrb)

Both bash-tier runners classify every spec into one of THREE outcomes —
three outcomes, three reasons:

- **PASSED** — exited 0 AND executed at least one assertion.
- **FAILED** — exited non-zero, or was killed at the per-spec wall-clock cap
  (`SPEC_TIMEOUT_S`; default 900s at L1, 3600s at L2 — no "0 disables it"
  arm, an unbounded spec is the mwrb defect), or **returned while background
  work from its own process group was still alive** (a9hh R2-F2 — a late line
  can be a `FAIL:` or a `SKIPPED:`, so a transcript with live writers cannot
  be classified; the runner kills the leftovers and says so), or **exited 0
  while its own record says otherwise** (a9hh R4-F1/R4-F2): a `FAIL:` line
  in the transcript the exit code never carried — a backgrounded assertion
  that fails and finishes inside the sweep's grace, or broken exit-code
  plumbing — is a FAILURE in both runners, and at L2 so is a summary that
  counted failed assertions under rc=0 (an early `exit 0` bypassing the
  fail gate) or a missing `__SPEC_SUMMARY__` line altogether (an
  exec-replacement, or a spec-level EXIT trap that failed to chain
  `__spec_wrapper_exit`). A timeout is a FAILURE with a distinct reason,
  never a pass and never a skip, and per-spec elapsed time is printed so a
  slow tier is diagnosable in seconds rather than hours.
- **SKIPPED** — exited 0 having executed ZERO assertions (and, at L2, said
  so in its summary — the wrapper's EXIT trap prints `pass=0 fail=0` even
  when a skip gate exits early). Never a pass: a measurement that did not
  happen must not look like one that passed. A spec that runs assertions
  and THEN hits a skip gate is PASSED with its executed count — a9hh R4-F1:
  the pre-fix wrapper lost the whole summary to the gate's `exit 0`, so a
  spec with a failing assertion before its `bd_required_or_skip` call was
  scored SKIPPED, `Failed: 0`, rc=0, on the CI path.

Both runners launch each spec as its **own process group** (`set -m`; a9hh
R2-F2/R2-F3). At the cap, one shared escalation (`escalate_kill`) TERMs a
**ppid-tree snapshot taken before the polite pass** plus the group, waits a
grace, **re-walks once from every snapshot member still alive** (a9hh
R6-F1: a TERM handler can spawn a NEW child during the grace — absent from
the snapshot, outside the group, reachable only through its still-live
parent), then KILLs the union and the group (a9hh R4-F4: the group KILL
alone cannot reach a TERM-immune descendant that left the group). The
escalation **names what refused TERM before KILLing it**, and — because the
set is two bounded walks, NOT a closed world — **names anything it could
not kill** as a `survivor:` line instead of claiming a clean tree: a
process that both leaves the group and outlives its parent chain before a
walk reaches it (a double-forked daemon; a handler that spawns and dies) is
out of reach short of the machine-global scan R1-F2 banned, and the
deliberate design choice is ONE bounded re-walk, never a chase loop. After
every spec the runner additionally sweeps the group (short grace so
in-flight output still lands and counts, then TERM/KILL), fails a spec that
left work running, and names every survivor it kills (pid/ppid/pgid/args
under the verdict line, control bytes stripped). An interrupt (^C, `make`
TERM — and SIGHUP, the closed-terminal path, a9hh R7-F3) runs the same
escalation against the active spec before the runner exits 130; the
pre-R6-F1 runner also TERMed its own watchdog the moment `wait` returned,
which cut the KILL pass short whenever the spec's leader died politely —
reproduced: a TERM-trapping shell AND the child its trap spawned both
outlived the entire tier.
Backgrounding is fine — *returning over live work* is the offence: a
spec that `wait`s for its own children before exiting is a clean PASS. Known,
stated limit: a double-forking daemon (new session, parent chain gone — bd's
own daemon, measured) is outside any supervisor's reach and is shared
infrastructure, not a spec's leak. bd's **telemetry flusher** is the measured
counter-shape (a9hh R3-F1): `bd send-metrics` detaches to ppid=1 *without*
`setsid`, so it stays in the spec's group and a slow endpoint carries it past
the sweep's grace — both runners therefore export `BD_DISABLE_METRICS=1`,
which prevents the spawn at the source (an argv-based sweep exemption was
rejected as forgeable). One more consequence of `set -m`, handled at the
launch site: each spec's stdin is **explicitly** redirected from `/dev/null`
(a9hh R3-F2 — job control makes a background job *inherit* the runner's
stdin, and under a terminal a stdin-reading spec SIGTTIN-stops into a
full-cap TIMEOUT; with the redirect it sees instant EOF).

**Neither runner arms an EXIT trap** (a9hh R5-F1). The scratch dir used to
be removed by one, and on Linux bash 5.2 (the CI platform family) that trap
nondeterministically fired **inside forked children** under load, deleting
the scratch mid-tier: every later spec failed rc=1 with 0 assertions
(`cat: …/spec-out.N: No such file`) over specs that ran and passed —
measured on the pre-fix runners at 29-35/40 runs under CPU contention and
up to 40/40 at L2, and invisible on macOS bash 3.2. In-trap guards do not
fix it, and the R7-F1 factorial (independent builds by QA and by us,
byte-identical harness, full table in `run-tests.sh`'s header and the a9hh
Beads record) replaced the earlier account with the measured one: a
BASHPID guard evaluated as the trap's FIRST command **misevaluates** and
fails 25-37/40; an in-trap **write never masks the defect** — it records
the foreign firings at baseline BAD rate (QA's rm→log control read clean
because removing the `rm` removes the *deleter*, a correct inference this
README previously miscalled a probe effect); and the one shape that reads
clean with the trap still armed — a write placed BEFORE the guard — is an
order-sensitive interaction nobody has explained, not a fix. Cleanup now
happens at explicit terminal exits (`finish`), so a child that wrongly
executes leftover trap machinery has nothing to execute; HUP/INT/TERM are
trapped and clean, and the residual (a `set -u` abort or SIGKILL) leaks
one bounded /tmp dir. Consequence for spec authors at L2: the wrapper owns
the EXIT trap for the summary line — a spec that re-arms EXIT for its own
teardown must end its trap command with `__spec_wrapper_exit` (see
`beads-ledger.sh`; dropping the chain is loud — the runner FAILS an exit-0
spec with no summary line, QA-verified against real evasions, and THAT is
the guarantee). `runner-completeness.test.sh` 12.42 additionally lints the
shapes a static scan can see — canonical, multi-signal, numeric-0 and
trailing-comment forms (12.43a-e pin each) — while a variable-spelled
signal stays invisible to any static scan and is caught at runtime by the
missing-summary arm.

…and **one annotation on top of those three**, because the three are
spec-granular:

- **PARTIAL** — a spec that PASSED but also printed a section-level skip
  marker, so it measured only part of itself. It is counted (`Partial: N` in
  the summary), named with its own marker text, and the completeness line
  carries the qualification. At L1, under `STRICT_SECTIONS=1`, it makes the
  tier **red**. Since a9hh R7-F2 the L2 runner carries the same annotation
  with the same `SECTION_SKIP_RE` (measured need: under `BD_SHIM_ONLY=1` CI,
  `post-edit.sh` was an unqualified `PASSED (101 assertion(s))` out of a
  115-assertion full run, its `SKIPPED:` marker named nowhere — the a9hh
  section-skip defect one tier down); L2 has no strict mode, matching its
  skip policy.

The L1 runner additionally enforces a **completeness floor**
(`EXPECTED_SPECS` in `run-tests.sh`): an unfiltered run fails when the
discovered spec set shrinks, and any skip makes the tier red. The floor is
the **negative control for the completeness line** — the pairing
convention's first application (see below): `Total: N  Passed: N  Failed: 0`
is a claim, and the floor is what makes that claim falsifiable. **When you
add or remove an L1 spec, update `EXPECTED_SPECS` in the same change.** The
pair for all of this is `runner-completeness.test.sh`, which drives both
shipped runners — and TWELVE excision mutants of them: L1 un-floored, L1
without the section refusal, each runner without its survivor sweep, each
without its telemetry disarm, each with the spec stdin redirect stripped,
L1 without the transcript-fail arm, L2 without the filter zero-match
guard, L2 without its accounting (summary trap + failed-accounting
arms), and L2 without its PARTIAL annotation — against shrunken, skipping,
section-skipping, deliberately hanging, background-leaking, stdin-loaded,
telemetry-shaped, early-exiting, transcript-contradicting,
interrupt-stranding and grace-window-respawning fixtures. Five further
reddening mutations are hand-run and recorded per round rather than
committed (they need live process timing): the pre-widening trap-scan
regex, the RESNAPSHOT excision, the watchdog-wait reversion, HUP
untrapped, and the silent-kill report strip — each observed to redden
exactly its legs in the a9hh R6/R7 record.

**`STRICT_SECTIONS` and why the floor is not enough on its own.** The floor
counts spec FILES. a9hh's own first fix round shipped a green
`Total: 36  Passed: 36  Failed: 0  Skipped: 0` /
`Completeness floor: HELD (36/36 specs discovered and executed)`, rc=0, over
15 assertions that never executed: `impact-report.test.sh` ran 24 of 39 and
printed `SKIPPED: section 4 (code-graph-mcp not installed …)`, because the
job installed one MCP server's `node_modules` and not the other's. Nothing
in the runner could see it. Now:

- the runner recognises the four section-skip marker shapes the tier prints
  (`SKIPPED: …`, `  SKIPPED: …`, `  SKIP: …`, `  note: … SKIPPED …`) — and,
  since a9hh R2-F1, **any line-initial `note:` at all**, with or without a
  skip word on that line and regardless of how it was emitted (printf,
  heredoc, cat of a file — detection reads the spec's *output*, where every
  emission mechanism converges). The two-line shape `note: section 4 needs X`
  / `… Skipping.` used to evade both the runtime match and the source scan at
  once when it arrived via a heredoc. **If you add a section arm, print one
  of the four shapes with the skip word on the marker line** — that keeps the
  marker legible to a human reading a log, and `runner-completeness.test.sh`
  section 9 still lints the sources for it (now including heredoc bodies) —
  but the runner no longer depends on the convention being followed;
- the summary prints `Assertions executed: N`, the number that actually moves
  when a section is lost (measured at a9hh round 1, tree `535c89a` + change
  set `5b47c019`: 2501 local vs 2486 in the CI shape — same 36 specs, same
  green line);
- `STRICT_SECTIONS=1` — set by the CI `l1-unit` job, which provisions bd,
  node, and BOTH MCP servers' `node_modules` — makes a skipped section fail
  the tier. It is unset by default because a dev machine legitimately lacks
  some prerequisites, and a control that goes red on every laptop is a
  control people stop reading. An unrecognised value is an invocation error,
  never a silent "off".

The L2 runner reports skips honestly (they leave the `Passed` column and the
summary carries a `COMPLETENESS:` caveat naming the executed subset) but
still exits 0 on skips, and has no section-level detection: in
`BD_SHIM_ONLY=1` CI, 37 of 44 specs skip, so an L2 floor is inseparable from
installing bd in that job — the recorded follow-up on a9hh (`u84b`),
deliberately not a side effect of the L1 round. It **does** share the
process-group mechanics above (group-wide kill escalation, survivor sweep,
interrupt reaping): those close leaks, not skip policy, and L2 had the
identical holes. And its **instrument honesty** is now L1's equal (a9hh
R4/R5): a `--filter` that matches nothing is rc=2, never a green
`Total: 0` (both runners filter with BRE `grep`, so an ERE alternation like
`a|b` matches no basename — loudly now), and the accounting arms above mean
an early-exit spec can neither hide a failure as a skip nor lose its
executed assertions.

**Spec stdin is `/dev/null`.** Both runners now launch each spec as a
background job so a watchdog can poll it, and POSIX gives an async command
`/dev/null` on stdin unless it is redirected. No spec read stdin before or
after this change, and `installer-flags.test.sh` already redirected
`</dev/null` explicitly — but a future spec that expects an interactive
stdin will see EOF, not a prompt.

## Live e2e (manual, invariant-based)

Live runs hit real Claude. They are not on a schedule and not on any PR
gate. Run them deliberately during a development cycle when you need to
validate that a change in the plugin surface still produces the right
multi-agent workflow.

```
make test-live FIXTURE=node-react-auth         # one fixture
make test-live FIXTURES="a b c"                 # multiple
make test-live FIXTURE=node-react-auth CONFIRM=1 # skip the prompt
```

`test-live` requires a `FIXTURE=` (or `FIXTURES=`) argument and prints
the estimated cost before starting. Without explicit `CONFIRM=1` it
waits for a y/N confirmation.

### Per-fixture cost (estimates)

All estimates derive from the G8 runs in 2026-05. Real cost depends on
the active model snapshot and whether QA's block-then-recover loop
fires. Values are USD; the active model is whichever the SessionStart
resolver pins (see `.claude/scripts/model-select.sh` and the statusline
output).

| Fixture | Estimated cost | Estimated time | Notes |
| ------- | -------------- | -------------- | ----- |
| node-react-auth | $5-10 | 13-17 min | Canonical two-domain happy path; longest baseline |
| go-cli-refactor | $5-10 | 13-17 min | Single-domain refactor with regression-coverage check |
| monorepo-frontend-only | $5-10 | 13-17 min | Scoped single-domain change |
| multi-domain-signup | $5-10 | 13-17 min | Three-domain epic; can run longer |
| python-django-bug | $5-10 | 13-17 min | Single-domain bug fix with debugger framework |
| qa-block-recovery | $5-10 | 13-17 min | Often higher — recovery loops add iterations |

### Invariants (model-agnostic gate)

Live specs gate on invariants, not golden-trace equality. Each
fixture's `fixture.yaml` declares an `invariants:` block; the spec
asserts every declared invariant passes. Invariants are properties of
the workflow contract (orchestrator never edits, QA approval gates
Stop, declared specialists are the only ones invoked), so they hold
across model versions by construction — no cassette refresh cycle.

Schema:

```yaml
invariants:
  - name: stop-requires-approval
  - name: orchestrator-no-edits
  - name: completion-contract
  - name: label-milestones
    params:
      milestones:
        - qa-pending
        - qa-approved
  - name: declared-subagents-only
    params:
      declared:
        - backend
        - qa
```

### Built-in invariants

| Name | What it asserts | Implementation notes |
| ---- | --------------- | -------------------- |
| `stop-requires-approval` | A Stop hook never allowed completion without `qa-approved` (or `qa-deferred` per 0.2) appearing on at least one task | Approximation — the trace records label transitions as a single before/after diff per task, not interleaved with hook events, so we assert the strongest checkable form (presence of qa-approved given any Stop:allow). Documented in `invariants.ts`. |
| `orchestrator-no-edits` | No Write / Edit / MultiEdit toolCall is attributable to the orchestrator (root-level call outside any subagent's parent chain) | Trace-level proof that `prevent-orchestrator-edits.sh` did its job that run |
| `completion-contract` | Every specialist completion payload carries all seven F7 fields | Implemented as `skipped` with a documented trace-gap reason — the trace doesn't capture structured completion payloads yet. Faking it would make the gate worthless. The v4.1 addition of `context_coverage` widens what the invariant *would* check; it does not narrow the trace gap, so the row stays `skipped` |
| `label-milestones` | Fixture-declared milestone labels all appear as label adds across the run | Replaces `expected_label_progression` exact-equality. Extra intermediate adds are allowed |
| `declared-subagents-only` | Every subagent invocation matches the fixture's declared specialist set | Plugin-qualifier tolerant (`backend` matches `claude-workflow:backend`); orchestrator and `general-purpose` are always allowed |
| `qa-queried-impact-of` | QA consulted the mechanical impact report before approving (n6d artifact footprint + an unbypassed approve) | Skips when code-graph is absent, when there is no diff, or on pre-n6d recordings; fails on a `--no-impact-report` bypass without a code-graph-absent reason |
| `approval-cites-independent-review` | Every `QA-GATE APPROVED` record names a reviewer who is not a recorded implementer, cites an EARLIER `REVIEW-ARTIFACT v1`, and leaves zero findings open at/above its `risk_threshold` | Reads `trace.beadsComments` (V3 / jio.2) — a deliberate second implementation of `review-check.sh gate`. `RESOLVED … fix= test=` and a latest `ARBITRATION … decision=overrule` clear a finding; `sustain` does not. The audited `[review bypass:` marker exempts a record. Skips when the trace carries no `beadsComments` or when no approval names a `reviewed_by=` (pre-V3 recording) |

### Adding an invariant

1. Implement the function in `lib/invariants.ts` matching the
   `InvariantImpl` signature: `(trace, params?) => {pass, detail}`.
2. Register it in the `INVARIANTS` map at the bottom of the same file.
3. Add it to the relevant fixtures' `invariants:` blocks in
   `fixture.yaml`.
4. Add at least one POSITIVE case and one META-TEST in
   `specs/_invariants.unit.spec.ts`. The META-TEST must mutate a
   known-good trace to violate the new invariant and assert the engine
   catches it by name.

The unit tier validates the engine on every PR (offline, free); see
`specs/_invariants.unit.spec.ts` for the existing META-TEST pattern.

## Adding a new fixture

1. Create the directory at `.claude/tests/e2e/fixtures/<name>/`
   with the skeleton the existing fixtures use (compare
   `node-react-auth/` for the canonical shape). At minimum:
   `fixture.yaml`, `.claude/settings.json`, any project files the prompt
   expects to find.

2. Pre-install the bd shim at `.claude/bin/bd` (a 2-line script that
   exec's `bd --no-daemon "$@"` — see `node-react-auth/.claude/bin/bd`
   as the template) and inline its parent directory on the `PATH` for
   every hook command in `.claude/settings.json`. The inline form is
   required because Claude Code does not expand `${VAR}` inside
   `settings.json` env blocks
   ([anthropics/claude-code#4276](https://github.com/anthropics/claude-code/issues/4276)).

3. Initialize `.git/` with a single commit. The canonical state is
   what `runFixture.ts` stashes/restores around each run; a clean git
   baseline is required.

4. Initialize `.beads/` with `bd init` (the shim handles the
   `--no-daemon` invocation transparently).

5. Write `fixture.yaml` with `name`, `description`, `prompt`,
   `expected_subagents`, `expected_hooks`, `expected_label_progression`,
   an `invariants:` block (see the schema above), and any `notes:` that
   explain non-obvious choices.

6. Write the spec at `.claude/tests/e2e/specs/<name>.spec.ts`. Start
   from `happy-path.spec.ts`; replace the fixture path and the
   structural assertions for what your fixture is meant to exercise.
   End the spec with
   `await expect(trace).satisfiesInvariants(FIXTURE_YAML)`.

7. Run live once to validate during the development cycle:

   ```
   make test-live FIXTURE=<name>
   ```

## Golden cassettes (debugging only)

After v3.1.0 spec item 0.8, golden cassettes are not a gate. The
existing files under `cassettes/golden/` are retained as a seed corpus
for testing the invariant engine itself (see `_invariants.unit.spec.ts`)
and as debugging references. To inspect the structural shape of the
most recent replay against its committed golden:

```
make cassette-diff FIXTURE=<name>
```

This prints a structural diff. It does not gate, does not refresh
anything, and is safe to ignore in normal CI flow.

`cassette-diff` normalizes both sides before comparing. The normalization
strips drift we don't care about and preserves the structural fingerprint:

| Preserved | Normalized away |
| --------- | --------------- |
| Tool name sequence | Tool durations, costs, token counts |
| Subagent tree shape (who-spawned-whom) | Subagent run IDs, UUIDs |
| Hook firing sequence (event[:decision]) | Hook response bodies, timestamps |
| File-write paths + change types | Raw file contents written |
| Permission denials by tool, with counts | Free-form prose in reasons |
| Beads task IDs created | Created-at timestamps |
| Beads label transitions (`+added -removed`) | Note text in `bd update --notes` |
| Plugin loader status (names + errors) | Load timing |

## Interpreting cassette drift

When `make cassette-diff` surfaces a difference, it is informational
only. Interpret it like this:

- Tool sequence drift — the orchestrator (or a specialist) reached
  for a different tool, or in a different order. Usually a model-output
  shift; not a gate fail.
- Subagent tree drift — the routing changed. If you intended to add a
  specialist or change the orchestrator's Domain → Delegate table, this
  is your evidence; otherwise investigate.
- Hook firing drift — a hook that used to fire isn't, or vice versa.
  Hooks are deterministic given the same tool sequence, so this is
  worth investigating even though the live gate no longer fails on it.
- Label transition drift — Beads label flow changed. Compare against
  the QA convention: `qa-pending → qa-approved`, never the reverse.

The live gate fails on invariants (see above), not on drift. Use drift
as a debugging signal, not as a regression detector.

## The META-TEST convention

A META-TEST is an assertion that proves the test itself is sensitive
to the failure it claims to catch — not just that the system under test
is currently passing. They live next to the regular assertions in L1, L2,
and L3-unit specs, prefixed with the word `META-TEST` in the test name.

Why this matters: a passing assertion is consistent with two states —
either the SUT is correct, or the assertion is too weak to catch the bug.
META-TESTs disambiguate by mutating the trace (or hook envelope) in a
way that should trip the assertion, and checking that it does.

The CI workflow tallies META-TEST pass/fail counts as a distinct line
in the L2 job summary so regression-injection sensitivity stays
visible. If a META-TEST starts passing through when it should fail, the
test has gone soft and the gate doesn't actually guard the thing it
names.

### The pairing requirement — a new check ships with its negative control

**A new check cannot ship without a paired negative control.** This is a
closeout requirement, not a preference: at closeout, every check added by the
change is either paired to the standard below or listed as UNPAIRED with a
reason. It exists because 26 separate instances were recorded of a check that
claimed more than it verified, and every fix until now was instance-shaped.
This one targets the generator.

A pair is PAIRED only when all four parts are present:

1. **Non-vacuity.** A mutation of the shipped artifact — or of the state it
   reads — with an **explicit leg proving the mutation landed where it was
   aimed**. An `awk` strip that matched nothing, a `sed` that substituted
   nothing, and a fixture that was never written all produce a mutant identical
   to the original, and a "control" over an unmutated artifact passes for the
   wrong reason. Prove the hit: an `END { if (!found) exit 7 }` on the strip, a
   byte-comparison of mutant against shipped, a `bash -n` on the result.
2. **Specific misbehaviour.** An assertion that the mutant fails *in the way
   the guard prevents*, **naming the check that would fail**. "The mutant is
   different" is not it; "the mutant releases a change set with no bound
   approval record, so assertion X goes green while the defect is live" is.
3. **Restore control.** The shipped artifact, same inputs, same call shape,
   behaving correctly. Without it the mutant's failure could be an artefact of
   the harness rather than of the mutation.
4. **Execution.** **At least one leg observes the shipped artifact *running*.**

**Leg 4 is the discriminator, and it is the one that gets skipped.** *A
three-leg triad over markdown byte-equality is a triad over markdown.* The
census that produced this requirement measured the tier **bimodal**, and the
split is predicted almost perfectly by one variable — is the artifact under
test an EXECUTABLE or a DOCUMENT:

- Every PAIRED row drives a shipped script, a shipped JS module, or a function
  extracted verbatim from one.
- Every FALSE-PAIR row compares bytes in markdown, in JSON, or in a script's
  *comment text*.
- **Not one document check reached leg 4. Not one executable check failed it.**

That makes the fix targetable rather than diffuse: if the thing you are
checking is prose, either find the executable whose behaviour that prose
describes and drive it, or **declare the check UNPAIRED and say what the
control is instead**. An honest UNPAIRED row is worth more than a
byte-comparison dressed as a pair, because the byte-comparison is a claim
nothing checks — which is the defect being censused.

Two failure modes earned their own line, both from live incidents:

- **Do not count text to prove a claim about code.** A grep tally over a
  document is evidence about the document.
- **Do not verify a removal by grepping for the removed pattern.** The region
  header documenting a deleted arm contains the pattern, so it survives as
  prose in the very file that removed it. Compare hashes, or drive the
  function.

Worked examples in this repo, both executable:

- `.claude/tests/component/specs/approve-idempotency.sh` F3 — strips a
  sentinel-wrapped region from a copy of `verify-before-stop.sh`, asserts the
  strip landed (`exit 7` if the sentinels are absent), asserts the copy still
  parses, asserts a discriminator that rules out the wrong-reason block, then
  DRIVES both the mutant and the shipped hook.
- `.claude/scripts/tests/doc-only-classifier.test.sh` — extracts
  `is_doc_only_path` from the shipped script by `awk` and runs it over a
  cross-product of paths, so the thing under test is the shipped definition
  rather than a re-typed copy free to drift.

**The honest ceiling of the census that produced this, stated so it is not
over-read:** it was run by the same process it was auditing, so it is subject
to the gap it measures. Two runs, both partial — the first contaminated by a
concurrent writer (seven files moved under it mid-run), the second delivered
2 of 6 chunks, leaving L2's 44 specs and L3's 22 files never censused. **No
tier-wide coverage percentage is published, deliberately**, because a total
whose rows were never delivered is exactly the claim this convention forbids.
The pairing inventory is a standing invariant maintained one tier at a time
through ordinary reviewed work, not a snapshot; covering the population is a
side effect of maintaining it.

#### This convention is itself UNPAIRED, and that is the declaration it asks for

The rule above is prose. There is no shipped executable whose behaviour changes
when this section changes, so **there is no execution leg available and none is
claimed.** A check that read these paragraphs and asserted their wording would
be a byte-comparison over markdown — leg 4 absent, and precisely the false pair
the census named. Writing one would make the convention self-refuting.

So, stated plainly rather than papered over — **what the control actually is:**

1. **The convention binds at review, not at runtime.** Its enforcement point is
   the closeout checklist and the reviewer reading it, which is a human control
   with a human control's reliability. That is a weaker guarantee than a test,
   and saying so is the point.
2. **Its worked examples carry the execution legs it cannot.** The rule is only
   as real as the pairs shipped under it, and those are executable and pinned:
   `.claude/scripts/tests/gate-claim-honesty.test.sh` (ten guards, each with a
   mutation that lands, a named misbehaviour, a restore control, and a leg that
   runs the shipped artifact — the count is checkable by counting META blocks,
   one per guard: `2M`, `3M`, `4M`, `4N`, `4P`, `4Q`, `4R`, `4S`, `4T`, `5M`.
   Ten guards and five numbered sections, and the two numbers are *not* meant
   to agree: section 1 is a MEASUREMENT, not a guard, and carries no mutation,
   while section 4 carries seven — the tree fingerprint's content sensitivity,
   the readout's provenance claim, the fingerprint's *invariant*, the per-path
   fallback over the untracked set, the diff flags that keep drivers out of
   input 2, the fallback's quoting convention, and the untracked hashes'
   filter bypass. This paragraph's counts have now been stale once (`4S`
   shipped in round 7 and was not added here until round 8 — recorded as
   R8-F3), which is this file's own subject applied to itself: a count the
   text invites the reader to verify mechanically, failing when verified. The
   fifth guard shipped
   in QA round 3, after a mutant proved a corrected sentence had no control at
   all; the sixth in round 4, after review found the fingerprint degrading to a
   CONSTANT on a host carrying no sha256 tool — so two of them compared equal
   and the readout stated UNCHANGED over a rewritten tree, a false match from
   inside the block promising the design never produces one. Round 5 turned that
   sixth guard from a refusal of *one remembered* degradation into an invariant
   over all of them, after three more inputs were measured degrading the same
   way: it asserts four sandboxes against a single refusal, and its `4P`
   carries two mutations under one banner because the invariant has two halves —
   an input must carry content wherever its producer can read the repository,
   and the function must refuse when a producer fails. Round 6 added the seventh
   and eighth, and they are separate guards rather than further mutations of
   `4P` for a reason worth stating: the seventh (`4Q`) covers a defect that
   *survived* the invariant, in the one call round 5 deliberately exempted from
   it, where one dangling symlink froze the whole fingerprint across an
   end-to-end rewrite; the eighth (`4R`) covers one that **cannot be refused at
   all** — a `textconv` driver that is installed, working and lossy leaves the
   producer exiting 0 and the digest 64 valid hex characters, so no guard has
   anything to detect and the cure is `--no-ext-diff --no-textconv`, which stops
   the degradation instead of catching it. Round 7 added the ninth (`4S`), a
   cross-model review find after six same-family rounds ran 194 assertions
   green over it: the per-path fallback consumed C-quoted names as argv, so a
   readable newline-named file read as UNREADABLE — 4R's signature again,
   nothing failed and nothing malformed, cured by keeping the consumer in the
   producer's quoting convention rather than by any guard. Round 8 added the
   tenth (`4T`), the same shape one input over: a lossy-but-working `clean`
   filter (an nbstripout analogue) made `hash-object` return one constant
   object id across an end-to-end rewrite of an untracked file, and the cure —
   `--no-filters` on both hash-object calls — is deliberately ASYMMETRIC,
   because `git diff` has no such flag: input 3 is cured, input 2's half of
   the filter family is a measured KNOWN LIMITS bullet in the region and a
   pinned measurement (leg 4.63), not a guard. That is also why the round-5
   wording
   of `4P`'s second half was corrected above: "an input must carry content in
   every configuration" was itself false while `.gitattributes` could decide what
   the diff showed),
   `approve-idempotency.sh` F3, and
   `doc-only-classifier.test.sh`. Read those to see what a pair looks like; the
   prose here only describes them.
3. **One mechanical arm exists and is narrow.** `specs/_invariants.unit.spec.ts`
   enumerates `listInvariants()` and fails when a registered invariant has no
   `it("META-TEST: …")`. That is a real, executing coverage check — for
   invariants only. Nothing equivalent exists for L1 or L2 assertions, and no
   claim is made that one does.

The honest form of the gap, for anyone who wants to close it: a mechanical arm
for the other tiers would have to enumerate checks the way `listInvariants()`
enumerates invariants, which needs a registry that does not exist. Until it
does, this convention is maintained, not enforced.

### Invariant META-TEST pattern

The invariant engine carries the META-TEST convention into L3-unit. For
every invariant in `lib/invariants.ts`, `specs/_invariants.unit.spec.ts`
holds at least:

- One POSITIVE case: a synthetic (or retained-replay) `Trace` that
  satisfies the invariant; the engine returns `pass: true`.
- One META-TEST: a deliberate mutation of that trace that violates the
  invariant; the engine returns `pass: false` and the failure detail
  cites the invariant by name.

Example pattern (see the file for live code):

```ts
it("META-TEST: fails when a root-level Write is injected (orchestrator-attributable)", () => {
  const t = goodTrace();
  t.toolCalls.push({
    id: "rogue-write",
    name: "Write",
    input: { file_path: "rogue.md" },
    parentToolUseId: null, // root level == orchestrator scope
    durationMs: 0,
  });
  const agg = evaluateAll(t, [{ name: "orchestrator-no-edits" }]);
  expect(agg.allPassed).toBe(false);
  expect(agg.results[0].result.detail).toMatch(/Write\(rogue\.md\)/);
});
```

Every invariant must arrive with this pair. Adding a check without its
META-TEST is the same gap as a regular assertion without one — and since
v4.0.0 Phase V3 that rule is MECHANICAL, not prose: the
`invariant engine: META-TEST coverage` block in the same file enumerates
`listInvariants()` and fails when a registered invariant has no
`it("META-TEST: …")` inside its `describe("invariant: <name> …")` block.
The only escape is a documented row in that file's `META_EXEMPT` map, and
the only defensible reason for one is "there is no observable property to
violate" (today: `completion-contract`, which is always skipped).

## Known gotchas

- **bd daemon stack-overflow.** `bd 0.47.1`'s daemon-autostart path
  crashes (`cmd/bd/daemon_autostart.go:228`). Every fixture pre-installs
  a `bd` shim at `.claude/bin/bd` that exec's `bd --no-daemon "$@"`. If
  your hook subprocess can't find `bd`, you forgot to inline the bin/
  prefix on the hook command's `PATH`.
- **`cassettes/replays/` is gitignored, `cassettes/golden/` is committed.**
  Replays are debug artifacts; goldens are evidence. Don't `git add`
  replays.
- **Vitest runs single-fork** (`singleFork: true` in `vitest.config.ts`).
  The Claude Agent SDK shares process-global state (HOME, cwd via env)
  and parallel runs race on it. Higher-level parallelism is the job of
  Promptfoo, one process per slot.
- **Stop hooks signal "allow" by absence.** A Stop hook returning `{}`
  (or no `decision` key) means *allow stop*. Only `decision: "block"`
  blocks. There is no "approve" decision.
- **`includeHookEvents: true` is required** to capture non-`SessionStart`
  hook events in the SDK's stream. `runFixture.ts` sets this; if you
  build a custom run path, set it there too or hooks won't appear in
  the trace.
- **`${VAR}` in `settings.json` env does NOT expand.** Each hook command
  must inline its `PATH` prefix
  ([anthropics/claude-code#4276](https://github.com/anthropics/claude-code/issues/4276)).
- **Hook subprocesses need the fixture's bd shim on `PATH`.** That's the
  whole reason for the inline-PATH-per-command pattern above. If a new
  hook lands in `settings.json`, make sure its command line starts with
  `PATH="$CLAUDE_PROJECT_DIR/.claude/bin:$PATH" bash ...`.
