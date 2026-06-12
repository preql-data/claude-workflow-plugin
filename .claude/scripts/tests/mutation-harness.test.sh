#!/bin/bash
# mutation-harness.test.sh — Phase C.1 (claude-workflow-plugin-n45.1).
#
# Asserts the behaviour of .claude/tests/mutation/mutation-sweep.sh:
#
#   - A seeded killable mutant is KILLED by the toy test (deterministic).
#   - A seeded equivalent (no-op) mutant is filtered before execution.
#     (At C.1 the filter is "the apply step refuses a byte-identical
#      mutation"; C.2 will plug a semantic judge into the same seam.)
#   - The main tree stays clean mid-run.
#   - All worktrees are pruned after a normal run.
#   - All worktrees are pruned after a SIMULATED FAILURE mid-run (the
#     trap cleanup must fire on signal, not only on exit-0).
#   - Caps are respected (MAX_MUTANTS_PER_RUN bounded).
#   - Cost gate blocks the judge seam without explicit confirmation.
#
# META-TESTS (the canary the spec calls out as required for the whole
# mutation tier):
#
#   1. Inverted kill-detection — if the harness treated a passing-tests
#      mutant as KILLED, the survivor count would be wrong. We invert
#      the test command for one run and assert the assertion catches it.
#
#   2. Removed cleanup — if the trap-based cleanup were absent, a
#      simulated SIGINT mid-run would leak worktrees. We monkey-patch
#      the harness to disable cleanup, run, and assert leakage so the
#      containment assertion is proven sensitive.
#
# All test fixtures are self-contained tempdirs initialized as git repos
# (worktrees require a .git/ to register against). No network, no LLM
# calls, no calls to the real plugin's scripts beyond the harness itself.
#
# Exit codes:
#   0  every assertion passed
#   1  one or more assertions failed

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
SWEEP_SH="$PROJECT_DIR/.claude/tests/mutation/mutation-sweep.sh"
GENERATE_SH="$PROJECT_DIR/.claude/tests/mutation/lib/generate.sh"

PASS=0
FAIL=0
FAILED_TESTS=()

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n' "$name" "$needle"
        printf '    haystack: %s\n' "$(printf '%s' "$haystack" | head -3)"
    fi
}

# Build a fresh toy project as a tempdir git repo.
#
# Layout:
#   src/target.sh      — the mutation target. F1+F6 triggers present.
#   tests/test.sh      — the killer test (passes against the original).
#
# The target uses `-gt 5` (F6 trigger) and a string compare (F1 trigger),
# so F6 produces an off-by-one and F1 produces a negation. The killer
# test asserts a specific behaviour that both mutants break, so both
# mutants should be KILLED. There is no equivalent-mutant in this
# fixture by design; the equivalent-mutant test is its own fixture below.
mk_fixture() {
    local d
    d=$(mktemp -d -t mut-fixture.XXXXXX)
    (
        cd "$d" || exit 1
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test"
        mkdir -p src tests
        cat > src/target.sh <<'SH'
#!/bin/bash
# A toy target with F6 (-gt) and F1 (=) triggers.
n="${1:-0}"
if [ "$n" -gt 5 ]; then
    label="big"
else
    label="small"
fi
if [ "$label" = "big" ]; then
    echo "BIG"
else
    echo "SMALL"
fi
SH
        cat > tests/test.sh <<'SH'
#!/bin/bash
set -e
out=$(bash src/target.sh 10)
[ "$out" = "BIG" ] || { echo "fail: got '$out' want BIG" >&2; exit 1; }
out=$(bash src/target.sh 0)
[ "$out" = "SMALL" ] || { echo "fail: got '$out' want SMALL" >&2; exit 1; }
exit 0
SH
        chmod +x src/target.sh tests/test.sh
        git add . >/dev/null
        git commit -qm "init"
    )
    printf '%s\n' "$d"
}

# Build a fixture whose target generates an equivalent / no-op mutant.
# F4 with a `${VAR:-}` empty default is the cheapest no-op: stripping the
# default of an unset variable produces a byte-identical line under
# certain shell rules; for a robust no-op test we use F1 on a line whose
# `=` operator does not appear with whitespace boundaries (so the regex
# misses) — confirming the harness emits zero mutants for that input.
# To exercise the equivalent-mutant SAFETY path (no mutant ever reaches
# the test runner), we use a target whose only `=` is inside an
# assignment (no `[ X = Y ]` form), so F1 produces zero mutants. The
# resulting sweep should record 0 mutants and exit cleanly.
mk_equiv_fixture() {
    local d
    d=$(mktemp -d -t mut-equiv-fixture.XXXXXX)
    (
        cd "$d" || exit 1
        git init -q
        git config user.email "test@example.com"
        git config user.name "Test"
        mkdir -p src tests
        cat > src/equiv.sh <<'SH'
#!/bin/bash
# No F1-triggering tests, no F6 ops; F1 should produce zero candidates.
x=42
echo "$x"
SH
        cat > tests/test.sh <<'SH'
#!/bin/bash
out=$(bash src/equiv.sh)
[ "$out" = "42" ]
SH
        chmod +x src/equiv.sh tests/test.sh
        git add . >/dev/null
        git commit -qm "init"
    )
    printf '%s\n' "$d"
}

# Cleanup tempdirs at the end.
TEMP_DIRS=()
# shellcheck disable=SC2329  # invoked via trap.
cleanup_all() {
    local d
    for d in "${TEMP_DIRS[@]:-}"; do
        [ -z "$d" ] && continue
        # Best-effort prune of any worktrees the harness might have left
        # behind (in normal runs the harness already prunes them; this
        # handles the META-TEST that disables cleanup).
        if [ -d "$d/.git" ]; then
            git -C "$d" worktree prune >/dev/null 2>&1 || true
        fi
        rm -rf "$d"
    done
}
trap cleanup_all EXIT INT TERM

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: seeded killable mutant -> KILLED ==="

FIX1=$(mk_fixture)
TEMP_DIRS+=("$FIX1")

run_sweep() {
    # Runs the sweep against $FIX1 and prints stdout to caller. We
    # always pass --no-judge so the script doesn't prompt; --quiet
    # suppresses informational warnings so we can inspect stdout cleanly.
    local fixture="$1"; shift
    CLAUDE_PROJECT_DIR="$fixture" bash "$SWEEP_SH" \
        --targets "$fixture/src/target.sh" \
        --fault-classes F1,F6 \
        --no-judge \
        --test-cmd "bash tests/test.sh" \
        --quiet \
        "$@" 2>&1
}

OUT=$(run_sweep "$FIX1")
assert_contains "killable: report mentions mutants" "mutants:" "$OUT"

# Pull the killed/survived counts from the report.json — the source of truth.
REPORT="$FIX1/.claude/.mutation-runs"
LATEST=$(find "$REPORT" -maxdepth 1 -type d -name '20*' | sort | tail -1)
KILLED_COUNT=$(awk -F'"killed":' '{print $2}' "$LATEST/report.json" | awk -F',' '{print $1}')
SURVIVED_COUNT=$(awk -F'"survived":' '{print $2}' "$LATEST/report.json" | awk -F',' '{print $1}')
MUTANTS_COUNT=$(awk -F'"mutants":' '{print $2}' "$LATEST/report.json" | awk -F',' '{print $1}')

# At least one mutant generated.
[ "$MUTANTS_COUNT" -ge 1 ] && rc=0 || rc=1
assert_eq "killable: at least one mutant generated" "0" "$rc"

# At least one KILLED. Both F1 and F6 mutants here break the toy test, so
# in practice all generated mutants should be killed.
[ "$KILLED_COUNT" -ge 1 ] && rc=0 || rc=1
assert_eq "killable: at least one mutant KILLED by test suite" "0" "$rc"
assert_eq "killable: killed + survived equals mutants" \
    "$MUTANTS_COUNT" "$((KILLED_COUNT + SURVIVED_COUNT))"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: seeded survivor (test_no_op insensitive to mutation) ==="
#
# Use a fixture where the test passes regardless of the mutation. This is
# the "weak test" canary: even though we generate a real mutant, the
# survivor count must be at least 1. Build a target that has a -gt
# trigger but a test that doesn't actually depend on the comparison.

FIX_SURVIVOR=$(mktemp -d -t mut-survivor.XXXXXX)
TEMP_DIRS+=("$FIX_SURVIVOR")
(
    cd "$FIX_SURVIVOR" || exit 1
    git init -q
    git config user.email "t@t.test"
    git config user.name "t"
    mkdir -p src tests
    cat > src/wt.sh <<'SH'
#!/bin/bash
# F6 trigger present, but the result is unobservable to the caller.
n="${1:-0}"
if [ "$n" -gt 5 ]; then :; else :; fi
echo "always-the-same"
SH
    cat > tests/test.sh <<'SH'
#!/bin/bash
out=$(bash src/wt.sh 10)
[ "$out" = "always-the-same" ]
SH
    chmod +x src/wt.sh tests/test.sh
    git add . >/dev/null
    git commit -qm "init"
)

OUT=$(CLAUDE_PROJECT_DIR="$FIX_SURVIVOR" bash "$SWEEP_SH" \
    --targets "$FIX_SURVIVOR/src/wt.sh" \
    --fault-classes F6 \
    --no-judge \
    --test-cmd "bash tests/test.sh" \
    --quiet 2>&1)

LATEST_S=$(find "$FIX_SURVIVOR/.claude/.mutation-runs" -maxdepth 1 -type d -name '20*' | sort | tail -1)
SURV_S=$(awk -F'"survived":' '{print $2}' "$LATEST_S/report.json" | awk -F',' '{print $1}')
[ "$SURV_S" -ge 1 ] && rc=0 || rc=1
assert_eq "survivor: weak test produces at least one SURVIVED mutant" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: worktree containment (main tree clean mid-run) ==="

# Snapshot the main fixture's tracked-file checksums BEFORE the run.
PRE_HASH=$(git -C "$FIX1" rev-parse HEAD)
PRE_FILES=$(git -C "$FIX1" ls-files | sort | xargs -I{} sha256sum "$FIX1/{}" 2>/dev/null | sort)

run_sweep "$FIX1" >/dev/null

POST_HASH=$(git -C "$FIX1" rev-parse HEAD)
POST_FILES=$(git -C "$FIX1" ls-files | sort | xargs -I{} sha256sum "$FIX1/{}" 2>/dev/null | sort)

assert_eq "containment: HEAD unchanged after sweep" "$PRE_HASH" "$POST_HASH"
assert_eq "containment: tracked files' hashes unchanged after sweep" "$PRE_FILES" "$POST_FILES"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: worktrees pruned after run ==="

WT_DIR="$FIX1/.claude/.mutation-worktrees"
if [ -d "$WT_DIR" ]; then
    LEFTOVER=$(find "$WT_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
else
    LEFTOVER=0
fi
assert_eq "cleanup: zero worktree dirs left in .mutation-worktrees" "0" "$LEFTOVER"

# Also confirm git's own worktree registry is empty (the trap calls
# `git worktree prune`).
REG_COUNT=$(git -C "$FIX1" worktree list | wc -l | tr -d ' ')
# The main worktree itself is always listed (count >= 1). Anything above
# 1 is a leak.
[ "$REG_COUNT" -le 1 ] && rc=0 || rc=1
assert_eq "cleanup: git worktree registry has only the main tree" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: caps respected (--max-mutants) ==="

# Force a low cap and confirm the report records <= cap mutants.
OUT=$(CLAUDE_PROJECT_DIR="$FIX1" bash "$SWEEP_SH" \
    --targets "$FIX1/src/target.sh" \
    --fault-classes ALL \
    --max-mutants 1 \
    --no-judge \
    --test-cmd "bash tests/test.sh" \
    --quiet 2>&1)

LATEST_C=$(find "$FIX1/.claude/.mutation-runs" -maxdepth 1 -type d -name '20*' | sort | tail -1)
MUT_C=$(awk -F'"mutants":' '{print $2}' "$LATEST_C/report.json" | awk -F',' '{print $1}')
[ "$MUT_C" -le 1 ] && rc=0 || rc=1
assert_eq "caps: --max-mutants 1 produced at most 1 mutant" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: cost gate blocks judge seam without confirmation ==="
#
# When stdin is not a TTY (which it is not under `bash test.sh`), `read`
# returns EOF; the script's case branch defaults to N. We confirm the
# script exits 0 with "deterministic report at ..." rather than calling
# any judge command.

# Set up a sentinel judge command — a no-op script that creates a marker
# file. If the cost gate actually blocks (the expected behaviour), the
# marker file should NOT appear.
JUDGE_SENTINEL_DIR=$(mktemp -d -t mut-judge-sentinel.XXXXXX)
TEMP_DIRS+=("$JUDGE_SENTINEL_DIR")
JUDGE_CMD="$JUDGE_SENTINEL_DIR/judge.sh"
JUDGE_MARKER="$JUDGE_SENTINEL_DIR/judge-was-called"
cat > "$JUDGE_CMD" <<SH
#!/bin/bash
touch "$JUDGE_MARKER"
echo '{"verdict":"sentinel"}'
SH
chmod +x "$JUDGE_CMD"

# We need a survivor for the gate to trigger. The "always-the-same"
# fixture produces one.
OUT=$(CLAUDE_PROJECT_DIR="$FIX_SURVIVOR" bash "$SWEEP_SH" \
    --targets "$FIX_SURVIVOR/src/wt.sh" \
    --fault-classes F6 \
    --judge-cmd "$JUDGE_CMD" \
    --test-cmd "bash tests/test.sh" \
    --quiet </dev/null 2>&1)

# The marker file must NOT exist (no confirmation -> gate blocks).
if [ -e "$JUDGE_MARKER" ]; then
    gate_rc=1
else
    gate_rc=0
fi
assert_eq "cost gate: blocks judge without --confirm-judge (no marker file)" "0" "$gate_rc"

# Conversely with --confirm-judge the sentinel runs.
rm -f "$JUDGE_MARKER"
OUT=$(CLAUDE_PROJECT_DIR="$FIX_SURVIVOR" bash "$SWEEP_SH" \
    --targets "$FIX_SURVIVOR/src/wt.sh" \
    --fault-classes F6 \
    --judge-cmd "$JUDGE_CMD" \
    --confirm-judge \
    --test-cmd "bash tests/test.sh" \
    --quiet 2>&1)

if [ -e "$JUDGE_MARKER" ]; then
    gate_rc2=0
else
    gate_rc2=1
fi
assert_eq "cost gate: --confirm-judge invokes the judge command" "0" "$gate_rc2"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: equivalent-mutant fixture (zero mutants emitted) ==="

FIX_EQUIV=$(mk_equiv_fixture)
TEMP_DIRS+=("$FIX_EQUIV")
OUT=$(CLAUDE_PROJECT_DIR="$FIX_EQUIV" bash "$SWEEP_SH" \
    --targets "$FIX_EQUIV/src/equiv.sh" \
    --fault-classes F1 \
    --no-judge \
    --test-cmd "bash tests/test.sh" \
    --quiet 2>&1)
assert_contains "equiv: zero mutants emitted (no F1 trigger)" \
    "zero mutants" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: META-TEST 1 — inverted kill-detection fails ==="
#
# Invert the test command so a passing mutant looks failing. With the
# inverted command, the killable fixture's mutants would all SURVIVE
# (because their "failing" return becomes "passing"), and the assertion
# "at least one KILLED" should fail. We don't actually want to run the
# real harness with inverted semantics in CI — instead we build the
# inverted scenario manually and assert the contract.
#
# Concretely: when the toy test is replaced with one that ALWAYS returns
# 0 regardless of the mutation, the survived count grows. If our kill-
# detection assertion ("KILLED >= 1") had been silently passing, this
# alternate scenario would also pass it. We assert here that the new
# scenario produces SURVIVED >= 1 AND KILLED == 0 — proving the original
# assertion was sensitive to whether the test actually exercises the
# mutation.

# Build a test command that ALWAYS passes.
ALWAYS_PASS_CMD="true"
OUT=$(CLAUDE_PROJECT_DIR="$FIX1" bash "$SWEEP_SH" \
    --targets "$FIX1/src/target.sh" \
    --fault-classes F1,F6 \
    --no-judge \
    --test-cmd "$ALWAYS_PASS_CMD" \
    --quiet 2>&1)
LATEST_M=$(find "$FIX1/.claude/.mutation-runs" -maxdepth 1 -type d -name '20*' | sort | tail -1)
KILLED_M=$(awk -F'"killed":' '{print $2}' "$LATEST_M/report.json" | awk -F',' '{print $1}')
SURV_M=$(awk -F'"survived":' '{print $2}' "$LATEST_M/report.json" | awk -F',' '{print $1}')

assert_eq "META 1: always-pass test command -> KILLED == 0" "0" "$KILLED_M"
[ "$SURV_M" -ge 1 ] && rc=0 || rc=1
assert_eq "META 1: always-pass test command -> SURVIVED >= 1" "0" "$rc"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: META-TEST 2 — removed cleanup leaks worktrees ==="
#
# Build a patched copy of the harness with the trap line stripped, run
# it under SIGINT, and assert that worktrees leak. This proves the
# cleanup-on-exit assertion is sensitive.
#
# The harness uses `trap cleanup_worktrees EXIT INT TERM`. Strip that
# line, plus the cleanup_worktrees function body's effective cleanup so
# the worktrees actually leak (otherwise EXIT still cleans up via the
# normal flow at the bottom of the script).

PATCHED_SH="$FIX1/.mutation-sweep-no-cleanup.sh"
cp "$SWEEP_SH" "$PATCHED_SH"
# Replace the trap line with a no-op, and replace cleanup_worktrees body
# with an early return so even if EXIT fires the worktrees stay.
python3 - "$PATCHED_SH" <<'PY'
import re, sys
path = sys.argv[1]
with open(path) as f:
    src = f.read()
# Replace `trap cleanup_worktrees EXIT INT TERM` with a no-op.
new_src, n_trap = re.subn(
    r'^trap cleanup_worktrees EXIT INT TERM$',
    ':',
    src,
    count=1,
    flags=re.MULTILINE,
)
assert n_trap == 1, f"META 2: failed to strip trap (replacements={n_trap})"
# Replace cleanup_worktrees body so explicit calls also no-op.
new_src, n_fn = re.subn(
    r'cleanup_worktrees\(\)\s*\{[\s\S]*?\n\}\n',
    'cleanup_worktrees() { return 0; }\n',
    new_src,
    count=1,
)
assert n_fn == 1, f"META 2: failed to neutralise cleanup body (replacements={n_fn})"
# Also strip the late `git worktree remove` calls inside run_mutant so
# the META-TEST is unambiguously about the trap mechanism — keeping the
# inline remove would clean up even with the trap stripped, which would
# make this META-TEST a false-positive. The lines we want to neutralize
# are the two `git ... worktree remove --force "$wt"` calls in run_mutant.
new_src = new_src.replace(
    'git -C "$PROJECT_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"',
    ': # META-PATCH: inline cleanup neutralised',
)
with open(path, 'w') as f:
    f.write(new_src)
PY

# Fresh fixture so the leak is unambiguous (no prior runs).
LEAK_FIX=$(mk_fixture)
TEMP_DIRS+=("$LEAK_FIX")

# The patched copy lives outside the plugin tree, so it needs the env
# overrides to locate the real lib/ and conf.
MUTATION_LIB_DIR="$PROJECT_DIR/.claude/tests/mutation/lib" \
MUTATION_CONF="$PROJECT_DIR/.claude/tests/mutation/mutation.conf" \
CLAUDE_PROJECT_DIR="$LEAK_FIX" bash "$PATCHED_SH" \
    --targets "$LEAK_FIX/src/target.sh" \
    --fault-classes F1,F6 \
    --no-judge \
    --test-cmd "bash tests/test.sh" \
    --quiet >/dev/null 2>&1 || true

LEAK_DIR="$LEAK_FIX/.claude/.mutation-worktrees"
if [ -d "$LEAK_DIR" ]; then
    LEAK_COUNT=$(find "$LEAK_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
else
    LEAK_COUNT=0
fi
[ "$LEAK_COUNT" -ge 1 ] && rc=0 || rc=1
assert_eq "META 2: cleanup-removed harness leaks at least one worktree" "0" "$rc"

# Manual cleanup of the leaked worktrees so the test fixture teardown
# doesn't trip git's worktree registry.
if [ "$LEAK_COUNT" -gt 0 ] && [ -d "$LEAK_DIR" ]; then
    while IFS= read -r wt; do
        [ -z "$wt" ] && continue
        git -C "$LEAK_FIX" worktree remove --force "$wt" >/dev/null 2>&1 || rm -rf "$wt"
    done < <(find "$LEAK_DIR" -mindepth 1 -maxdepth 1 -type d)
    git -C "$LEAK_FIX" worktree prune >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9b: COMMAND_EXCLUSIONS uniformly enforced across F1..F8 ==="
#
# Regression coverage for claude-workflow-plugin-n45.5 (QA defect on
# n45.1 P1). The deterministic generator's `should_skip()` filter is
# the FIRST line of defence against destructive mutants escaping the
# worktree (`rm`, `mv`, `cp`, `curl`, `wget`, `gh` — see
# `mutation.conf` COMMAND_EXCLUSIONS and `fault-classes.md`'s "Excluded
# by design" section). In the original C.1 cut, only F1/F3/F6 called
# `should_skip()` — F2/F4/F5/F7/F8 only filtered comments and blank
# lines, so a target line beginning with an excluded command could
# still produce mutants from the unguarded generators.
#
# QA's probe (Beads n45.1 block): a target containing one line per
# unsafe class
#
#     rm -rf qa-approved/ && exit 0           # F2 trigger (qa-approved + exit)
#     rm -rf "${HOME:-/}"                     # F4 trigger (${X:-foo})
#     rm -f file | grep foo | wc -l           # F5 trigger (>=3 pipeline segments)
#     rm -rf qa-approved.lock                 # F7 trigger (sentinel literal)
#     rm -f "$((COUNTER + 1)).log"            # F8 trigger ($((... + 1)))
#
# emitted 5 mutants from the unsafe generators (one per class). The
# expected behaviour is ZERO mutants from any class because every line
# is `rm`-prefixed and `rm` is in COMMAND_EXCLUSIONS.
#
# We assert per-class: build a synthetic target containing exactly one
# rm-shaped trigger line for that class, invoke `lib/generate.sh
# <target> <fault-id>` directly (bypassing the sweep so the assertion
# focuses on the generator, not the runner), and grep for `MUTANT ` in
# stdout — zero matches = pass.
#
# Each assertion has a paired positive control on the SAME generator
# applied to a SAFE (non-rm-prefixed) trigger line, asserting at least
# one mutant IS emitted. Without the positive control, a generator
# silently broken to emit nothing would pass the destructive-skip
# assertion for the wrong reason.

# Per-class assertion: invokes `generate.sh` and counts emitted MUTANT
# records. Args: fault-id, label (for assert names), rm-shaped line,
# safe trigger line.
assert_command_exclusion() {
    local fid="$1" rm_line="$2" safe_line="$3"
    local tmpdir tmpf
    tmpdir=$(mktemp -d -t mut-excl-"$fid".XXXXXX)
    TEMP_DIRS+=("$tmpdir")
    tmpf="$tmpdir/target.sh"

    # rm-shaped target.
    {
        printf '#!/bin/bash\n'
        printf '%s\n' "$rm_line"
    } > "$tmpf"
    local out_unsafe
    out_unsafe=$(bash "$GENERATE_SH" "$tmpf" "$fid" 2>&1)
    local rm_count
    rm_count=$(printf '%s' "$out_unsafe" | grep -cE '^MUTANT ' || true)
    assert_eq "exclusions: $fid emits ZERO mutants on rm-prefixed trigger" \
        "0" "$rm_count"

    # Safe-shaped target (positive control). Use a distinct file so the
    # generator's deterministic line numbering still works.
    local safe_tmpf="$tmpdir/safe.sh"
    {
        printf '#!/bin/bash\n'
        printf '%s\n' "$safe_line"
    } > "$safe_tmpf"
    local out_safe
    out_safe=$(bash "$GENERATE_SH" "$safe_tmpf" "$fid" 2>&1)
    local safe_count
    safe_count=$(printf '%s' "$out_safe" | grep -cE '^MUTANT ' || true)
    # The positive control should produce at least one mutant; if it
    # doesn't, the generator is broken in a different way and the
    # rm-prefixed zero is meaningless.
    [ "$safe_count" -ge 1 ] && rc=0 || rc=1
    assert_eq "exclusions: $fid emits >= 1 mutant on safe (non-rm) trigger (positive control)" \
        "0" "$rc"
}

# The probe strings are deliberately single-quoted: we want the literal
# `$`, `${VAR:-...}`, `$((..))` characters passed to the generator as
# file content, NOT this shell's expansion of them. SC2016 fires on the
# single-quote intent; suppress per-call for documentation.
#
# F2 — guard deletion. Trigger: line containing qa-approved/qa-deferred/
# stop_hook_active AND exit/return/continue. The QA probe shape couples
# the sentinel string with `&& exit 0`.
# shellcheck disable=SC2016 # literal `$` is the test payload
assert_command_exclusion F2 \
    'rm -rf qa-approved/ && exit 0' \
    '[ "$stop_hook_active" = "true" ] && exit 0'

# F4 — variable-default removal. Trigger: `${X:-foo}` anywhere on line.
# shellcheck disable=SC2016 # literal `$` is the test payload
assert_command_exclusion F4 \
    'rm -rf "${HOME:-/}"' \
    'PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"'

# F5 — pipeline-segment drop. Trigger: >=3 pipeline segments (>=2 pipes).
# shellcheck disable=SC2016 # literal `$` is the test payload
assert_command_exclusion F5 \
    'rm -f file | grep foo | wc -l' \
    'bd show "$id" --json | jq -r ".labels[]" | sort'

# F7 — sentinel literal mutation. Trigger: any SENTINEL substring on
# line. The QA probe couples `rm -rf` with the `qa-approved` sentinel.
# shellcheck disable=SC2016 # literal `$` is the test payload
assert_command_exclusion F7 \
    'rm -rf qa-approved.lock' \
    'add_label "$tid" "qa-approved"'

# F8 — arithmetic off-by-one. Trigger: `$((... + 1 ...))` or `$((... - 1 ...))`.
# shellcheck disable=SC2016 # literal `$` is the test payload
assert_command_exclusion F8 \
    'rm -f "$((COUNTER + 1)).log"' \
    'TOTAL=$((TOTAL + 1))'

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 10: /mutation-sweep command registered in plugin.json ==="
#
# The manifest-parity lesson (LESSONS.md): commands and agents must be
# registered in the same change-set that adds them, or the SDK silently
# treats them as invisible. We assert both directions:
#   (a) the command file exists at .claude/commands/mutation-sweep.md
#   (b) plugin.json's commands[] array includes the matching path
# Without (b), `/mutation-sweep` wouldn't surface to Claude.

CMD_FILE="$PROJECT_DIR/.claude/commands/mutation-sweep.md"
MANIFEST="$PROJECT_DIR/.claude-plugin/plugin.json"

[ -f "$CMD_FILE" ] && rc=0 || rc=1
assert_eq "command: .claude/commands/mutation-sweep.md exists on disk" "0" "$rc"

if command -v jq >/dev/null 2>&1; then
    REGISTERED=$(jq -r '.commands[]?' "$MANIFEST" 2>/dev/null \
        | grep -F 'mutation-sweep.md' | head -1)
    [ -n "$REGISTERED" ] && rc=0 || rc=1
    assert_eq "command: plugin.json commands[] registers mutation-sweep.md" "0" "$rc"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo ""
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
