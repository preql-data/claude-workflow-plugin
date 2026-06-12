# Fault classes — mutation harness catalog

This file is the **reviewable, extensible catalog** the deterministic
mutant generator consults. Each fault class has:

- a stable **id** (used by the survivors report so a downstream gate
  can branch on "this class of regression matters more than that one");
- a one-paragraph **rationale** (what real-world bug shape this models —
  ideally backed by a Beads task id or LESSONS.md entry);
- a worked **example** (before / after);
- the **transform shape** the generator uses (so a reader can predict
  what the harness will produce without running it).

Fault classes touching destructive commands (`rm -rf`, `git push`,
network mutators) are excluded by design. The generator never produces a
mutant that could cause real damage if it escaped its worktree — the
worktree containment is the second line of defence, the catalog is the
first.

## Catalog

### F1 — condition negation

**Rationale.** Most shell guards are a thin `if [ X ]` over a label or
state file; flipping `=` to `!=` (or `-eq` to `-ne`, or removing a `!`)
is the canonical "logic inverted" bug shape. The QA-gate state machine,
the Stop-hook re-entry guard, and the rubric-pending check are all of
this shape. CLAUDE.md's antipattern list explicitly names "Stop hook
without `stop_hook_active` guard" as a known infinite-loop trigger.

**Example.**

```bash
# before
if [ "$stop_hook_active" = "true" ]; then exit 0; fi
# after
if [ "$stop_hook_active" != "true" ]; then exit 0; fi
```

**Transform.** For each `[ X = Y ]` or `[ X == Y ]` token on a line that
is not a comment, emit a candidate that swaps to `!=`; symmetrically
`!=` to `=`. Also `-eq <-> -ne`, `-lt <-> -ge`, `-gt <-> -le`, `-le <->
-gt`, `-ge <-> -lt`.

### F2 — guard deletion (`stop_hook_active`-shaped)

**Rationale.** A correct guard returns/exits early so the rest of the
function does not run. Deleting the guard is structurally the same
mutation as F1 but the catalog separates it because the diff is one
line removed, not one operator flipped — the survivor report wants
to surface "the guard line was removed" as a distinct class.

**Example.**

```bash
# before
[ "$stop_hook_active" = "true" ] && exit 0
# (rest of the hook)
# after
# (rest of the hook)  -- guard deleted
```

**Transform.** For each line matching `(^|\s)(\[\s|test\s|return\s|exit\s).*\$\{?stop_hook_active|^\s*if\s+\[.*qa-approved`,
emit a candidate that comments the line out. The generator scopes this
to identifiable guards by pattern so it does not produce 100 mutants
per file.

### F3 — exit-code swallowing

**Rationale.** A failure surfaces as a non-zero exit code; appending
`|| true` (or replacing the failing call with `:`) silently buries the
failure. Real prior bug shape:
`bd update --notes "..." || true` — when bd was misconfigured the
agent kept going thinking the note had landed. The qa-gate uses an
explicit `log_sync_error + return 1` pattern precisely to *not* swallow
silently; mutating it back to `|| true` is the regression.

**Example.**

```bash
# before
git -C "$PROJECT_DIR" status --porcelain > "$baseline"
# after
git -C "$PROJECT_DIR" status --porcelain > "$baseline" || true
```

**Transform.** For each line ending in a non-trivial command (not a
comment, not blank, not already ending in `|| true` or `|| return`),
append ` || true`. To bound the candidate set the generator only
mutates lines whose first token is in a "known interesting" set:
`bd`, `git`, `jq`, `awk`, `sed`, `grep`, `printf` (when redirecting).

### F4 — variable-default removal

**Rationale.** `"${X:-fallback}"` defends against an unset variable.
Stripping the default to `"$X"` makes a previously-safe call crash
under `set -u` or silently expand to empty under set +u. Real shape
in this codebase: `PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"`.

**Example.**

```bash
# before
local input_path="${2:-}"
# after
local input_path="$2"
```

**Transform.** For each occurrence of `\$\{[A-Za-z_][A-Za-z0-9_]*:-[^}]*\}`,
emit a candidate that replaces it with `$VAR` (just the name).

### F5 — pipeline-segment drop

**Rationale.** `cmd | filter | format` is brittle because dropping
the middle segment often passes a test that only checks the broad
shape of stdout. Real shape: `jq -r '.labels // [] | join(",")'` — if
the `// []` is dropped, a missing labels key sends `null` downstream
instead of an empty string, and the next consumer treats `null` as a
label name. Catching this shape needs tests that go past "stdout is
non-empty".

**Example.**

```bash
# before
labels=$(bd show "$tid" --json | jq -r '... // [] | join(",")')
# after
labels=$(bd show "$tid" --json | jq -r '... | join(",")')
```

**Transform.** For each pipeline of >= 3 segments on a single line, emit
a candidate that drops the middle segment. The generator limits this
to a single drop per line (no exponential combinations) and skips
lines whose middle segment is a comment or empty.

### F6 — comparison-operator flip

**Rationale.** An off-by-one or polarity flip on a numeric guard.
The escalation cap (`MAX_ITERATIONS=3`), the file-tracking cap (500),
and any timeout comparison are all of this shape.

**Example.**

```bash
# before
if [ "$iter" -gt "$MAX_ITERATIONS" ]; then escalate; fi
# after
if [ "$iter" -ge "$MAX_ITERATIONS" ]; then escalate; fi
```

**Transform.** For each `-gt` / `-lt` / `-ge` / `-le` operator inside
a numeric `[ ]` test, emit a candidate that swaps to the off-by-one
neighbour (`-gt` -> `-ge`, `-ge` -> `-gt`, etc.). Distinct from F1
because the production assertion may catch flipped-equality without
catching off-by-one.

### F7 — string-literal mutation (label / sentinel)

**Rationale.** Beads labels and sentinel strings are spelled by hand;
typos and renames are a common regression shape. The seeded LESSONS.md
entry on rendered-fixture pinning came from exactly this — a label
spelt one way in the helper but another in the test.

**Example.**

```bash
# before
add_label "$tid" "qa-approved"
# after
add_label "$tid" "qa-aproved"
```

**Transform.** For each occurrence of a known sentinel string (`qa-pending`,
`qa-approved`, `qa-blocked`, `qa-gate-entered`, `qa-deferred`, `qa-escalated`,
`rubric-pending`, `rubric-satisfied`, `qa-pending`, `bug`, `improvement`,
`backend`, `frontend`, `devops`), emit a candidate that swaps it for
a known-wrong neighbour from the same family (`qa-approved` -> `qa-approve`
or `qa-aproved`). The list of sentinels is configurable via
`.claude/tests/mutation/mutation.conf` (key `sentinels`).

### F8 — arithmetic off-by-one on caps and counters

**Rationale.** `+ 1` becomes `+ 2`, `- 1` becomes `+ 1`. Counter
arithmetic on the iteration counter, the file-tracking cap, and any
batched-flush counter are all of this shape. Survives a "passes when
called once" test but breaks under sustained load.

**Example.**

```bash
# before
TOTAL=$((TOTAL + 1))
# after
TOTAL=$((TOTAL + 2))
```

**Transform.** For each `\$\(\(.*[+\-]\s*1.*\)\)` arithmetic expansion
on a line, emit a candidate that swaps the increment (`+ 1 -> + 2`,
`- 1 -> + 1`). Distinct from F6 (F6 is the comparison; F8 is the
arithmetic feeding the comparison).

## Selection bias

The generator does **not** attempt to enumerate every possible mutant
in a file. Each fault class has a per-line trigger pattern, and per-run
caps limit the total candidate set (see `mutation.conf`). The bias is
deliberate: a curated catalog of likely-impactful bug shapes catches
more real regressions than an exhaustive permutation that drowns the
judge in noise.

## Adding a fault class

1. Append a section to this file with id, rationale, example, transform.
2. Add the matching shell transform to `lib/generate.sh` (the dispatch
   table at the top maps fault id -> generator function).
3. Add at least one L1 test that asserts the new class produces a
   killable mutant under a toy target + toy test pair (see
   `tests/L1/mutation-harness.test.sh` for the existing pattern).

The catalog drives the generator; never the other way around. If the
generator emits mutants of a shape not documented here, that is a bug
in the generator, not a feature.

## Excluded by design

These would generate destructive or network-touching mutants and are
therefore **never** synthesised by this harness:

- mutating `rm`, `mv`, `cp` targets (path-traversal, accidental delete)
- mutating `git push`, `git reset --hard`, `git checkout`, `git branch -D`
- mutating `curl`, `wget`, `gh`, `bd sync` (network-touching)
- mutating anything that writes to `$HOME` outside the worktree

The generator's pattern list explicitly skips any line whose first
token is in the exclusion set (`mutation.conf` key `command_exclusions`).
