#!/bin/bash
# scoped-log-dir.test.sh — claude-workflow-plugin-gsfd fix round 1 (R1-F1,
# sol-codex review).
#
# Direct, executable tests of verify-before-stop.sh's run_scoped_log_dir /
# scoped_log_nonce / reap_stale_run_log_dirs, EXTRACTED from the shipped
# script by awk (the doc-only-classifier.test.sh convention: driving the
# shipped DEFINITION rather than a re-typed copy free to drift). Before this
# fix round these three functions had ZERO direct test coverage — despite
# being the mechanism the whole gsfd batch's central claim rests on
# ("nothing else on the machine is ever handed the same scratch path").
#
# THE DEFECT THIS FILE GUARDS AGAINST: `run_scoped_log_dir`'s pre-fix
# implementation degraded, on total directory-creation failure, to
# `dir="$QA_TRACKING_DIR"` — the SAME shared, fixed directory every OTHER
# concurrent run in that same state would ALSO be handed, which is exactly
# the collision this whole member exists to remove. Reachable with nothing
# more exotic than a plain FILE sitting at `<dir>/runs`: that defeats
# `mkdir -p`, `mktemp -d`, and the `$RANDOM` fallback, all nested under the
# same blocked path. The fix adds a second retry tier directly under
# `$QA_TRACKING_DIR` (bypassing the blocked `runs/` entirely), and only on
# TOTAL failure (even that retry fails) returns EMPTY rather than a shared
# path, moving uniqueness from the directory to a per-pid/nonce FILENAME the
# caller builds instead (scoped_log_nonce).
#
# ASSERTIONS
#   0. The awk extraction defines all three functions and parses.
#   1. Normal case (fresh, writable QA_TRACKING_DIR): a real, existing
#      directory under <dir>/runs/, and two consecutive calls are distinct.
#   2. THE R1-F1 REACHABLE DEFECT: a FILE at <dir>/runs (blocking mkdir -p,
#      mktemp -d, and the RANDOM fallback all at once) still yields a real,
#      unique directory — never <dir> itself, never a collision across two
#      calls in the same blocked state.
#   3. Total failure (QA_TRACKING_DIR itself is read-only, so not even the
#      tier-2 retry can create anything): returns EMPTY, never a fabricated
#      or shared path.
#   4. scoped_log_nonce is genuinely per-process unique — the property the
#      caller relies on when run_scoped_log_dir returns empty. Driven across
#      two SEPARATE processes (not two subshells of one), since pid is the
#      discriminating field.
#   META. The historical, PRE-FIX function body (captured verbatim from this
#      task's own starting state, not reconstructed) is driven against the
#      IDENTICAL runs/-blocked fixture from case 2, twice, and shown to
#      return the SAME path both times — the exact collision R1-F1 reports —
#      while the shipped function, same fixture, returns two DISTINCT paths.
#
# Exit codes:
#   0  every assertion passed
#   1  one or more assertions failed
#   2  invocation error (the shipped script is missing, or extraction failed)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"

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

if [ ! -f "$VBS" ]; then
    printf 'scoped-log-dir.test.sh: shipped script missing: %s\n' "$VBS" >&2
    exit 2
fi

WORK=$(mktemp -d -t scoped-log-dir-test.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    # A read-only fixture directory (case 3) must be restored to writable
    # before rm -rf can remove it.
    chmod -R u+w "$WORK" 2>/dev/null || true
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

extract_scoped_log_funcs() {
    local src="$1" out="$2"
    {
        awk '/^run_scoped_log_dir\(\) \{/,/^\}/' "$src"
        printf '\n'
        awk '/^scoped_log_nonce\(\) \{/,/^\}/' "$src"
        printf '\n'
        awk '/^reap_stale_run_log_dirs\(\) \{/,/^\}/' "$src"
    } > "$out"
}

SHIPPED_LIB="$WORK/shipped.sh"
extract_scoped_log_funcs "$VBS" "$SHIPPED_LIB"

assert_eq "0.1 the extraction defines run_scoped_log_dir" "1" \
    "$(grep -c '^run_scoped_log_dir() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "0.2 the extraction defines scoped_log_nonce" "1" \
    "$(grep -c '^scoped_log_nonce() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "0.3 the extraction defines reap_stale_run_log_dirs" "1" \
    "$(grep -c '^reap_stale_run_log_dirs() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "0.4 the extraction parses" "0" \
    "$(bash -n "$SHIPPED_LIB" 2>/dev/null && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# 1. Normal case: a fresh, writable QA_TRACKING_DIR.
D1="$WORK/t1"; mkdir -p "$D1"
(
    QA_TRACKING_DIR="$D1"
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    R1=$(run_scoped_log_dir)
    R2=$(run_scoped_log_dir)
    printf 'R1=%s\nR2=%s\n' "$R1" "$R2"
) > "$WORK/case1.out"
R1_VAL=$(sed -n 's/^R1=//p' "$WORK/case1.out")
R2_VAL=$(sed -n 's/^R2=//p' "$WORK/case1.out")
assert_eq "1a: returns a real, existing directory" \
    "yes" "$([ -n "$R1_VAL" ] && [ -d "$R1_VAL" ] && echo yes || echo no)"
assert_eq "1b: the directory lives under <dir>/runs/" \
    "yes" "$(printf '%s' "$R1_VAL" | grep -q "^$D1/runs/" && echo yes || echo no)"
assert_eq "1c: two consecutive calls return DISTINCT directories" \
    "distinct" "$([ "$R1_VAL" != "$R2_VAL" ] && echo distinct || echo COLLIDED)"

# ---------------------------------------------------------------------------
# 2. claude-workflow-plugin-gsfd R1-F1: the reachable defect. A plain FILE at
# <dir>/runs defeats `mkdir -p "$base"`, and everything nested under it
# (`mktemp -d "$base/..."`, the RANDOM fallback's own `mkdir -p "$dir"`)
# fails for the identical reason, since $base is not a directory at all.
D2="$WORK/t2"; mkdir -p "$D2"
: > "$D2/runs"
(
    QA_TRACKING_DIR="$D2"
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    R1=$(run_scoped_log_dir)
    R2=$(run_scoped_log_dir)
    printf 'R1=%s\nR2=%s\n' "$R1" "$R2"
) > "$WORK/case2.out"
R1_VAL=$(sed -n 's/^R1=//p' "$WORK/case2.out")
R2_VAL=$(sed -n 's/^R2=//p' "$WORK/case2.out")
assert_eq "2a: with runs/ blocked by a file, a real directory is still returned" \
    "yes" "$([ -n "$R1_VAL" ] && [ -d "$R1_VAL" ] && echo yes || echo no)"
assert_eq "2b: ...and it is NOT the shared QA_TRACKING_DIR itself" \
    "yes" "$([ "$R1_VAL" != "$D2" ] && echo yes || echo no)"
assert_eq "2c: ...it is a NEW directory directly under QA_TRACKING_DIR, bypassing the blocked runs/" \
    "$D2" "$(dirname "$R1_VAL")"
assert_eq "2d: two calls in the SAME blocked state still return DISTINCT directories (the R1-F1 collision, closed)" \
    "distinct" "$([ "$R1_VAL" != "$R2_VAL" ] && echo distinct || echo COLLIDED)"

# ---------------------------------------------------------------------------
# 3. Total failure: QA_TRACKING_DIR itself cannot hold a new directory
# (read-only — no tier can succeed, including the R1-F1 retry). The
# function must return EMPTY, never a fabricated or shared path.
D3="$WORK/t3"; mkdir -p "$D3"
chmod 555 "$D3" 2>/dev/null
(
    QA_TRACKING_DIR="$D3"
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    R1=$(run_scoped_log_dir)
    printf 'R1=[%s]\n' "$R1"
) > "$WORK/case3.out" 2>/dev/null
chmod 755 "$D3" 2>/dev/null
assert_eq "3a: total failure returns EMPTY, not a fabricated or shared path" \
    "yes" "$(grep -qx 'R1=\[\]' "$WORK/case3.out" && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 4. scoped_log_nonce is genuinely per-process unique — the property the
# caller relies on when run_scoped_log_dir returns empty. Two SEPARATE
# processes (real distinct pids), not two subshells of the same one.
(
    QA_TRACKING_DIR="$WORK/unused-t4"
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    scoped_log_nonce
) > "$WORK/nonce1.out"
(
    QA_TRACKING_DIR="$WORK/unused-t4"
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    scoped_log_nonce
) > "$WORK/nonce2.out"
NONCE1=$(cat "$WORK/nonce1.out")
NONCE2=$(cat "$WORK/nonce2.out")
assert_eq "4a: nonce is non-empty" "yes" "$([ -n "$NONCE1" ] && echo yes || echo no)"
assert_eq "4b: two separate processes' nonces are distinct (different pid)" \
    "distinct" "$([ "$NONCE1" != "$NONCE2" ] && echo distinct || echo COLLIDED)"

# ---------------------------------------------------------------------------
# 5. reap_stale_run_log_dirs sweeps all THREE shapes the R1-F1 fix can now
# leave behind: an old runs/ scratch dir, an old tier-2 qa-run.* dir
# (bypassing runs/), and an old flat-file fallback log — non-vacuity via
# file/dir counts, and a FRESH one of each survives (restore control).
D5="$WORK/t5"; mkdir -p "$D5/runs"
mkdir -p "$D5/runs/run.old" "$D5/runs/run.fresh"
mkdir -p "$D5/qa-run.old" "$D5/qa-run.fresh"
: > "$D5/last-test-output.pid1.111.222.log"
: > "$D5/last-test-output.pid2.333.444.log"
touch -t 202001010000 "$D5/runs/run.old" "$D5/qa-run.old" "$D5/last-test-output.pid1.111.222.log" 2>/dev/null \
    || touch -d '2020-01-01' "$D5/runs/run.old" "$D5/qa-run.old" "$D5/last-test-output.pid1.111.222.log" 2>/dev/null
(
    QA_TRACKING_DIR="$D5"
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    reap_stale_run_log_dirs
)
assert_eq "5a: the old runs/ scratch dir is reaped" "no" "$([ -d "$D5/runs/run.old" ] && echo yes || echo no)"
assert_eq "5b: ...the fresh one survives" "yes" "$([ -d "$D5/runs/run.fresh" ] && echo yes || echo no)"
assert_eq "5c: the old tier-2 qa-run.* dir is reaped" "no" "$([ -d "$D5/qa-run.old" ] && echo yes || echo no)"
assert_eq "5d: ...the fresh one survives" "yes" "$([ -d "$D5/qa-run.fresh" ] && echo yes || echo no)"
assert_eq "5e: the old flat-file fallback log is reaped" "no" "$([ -f "$D5/last-test-output.pid1.111.222.log" ] && echo yes || echo no)"
assert_eq "5f: ...the fresh one survives" "yes" "$([ -f "$D5/last-test-output.pid2.333.444.log" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# META-TEST: the historical, PRE-FIX function body — captured VERBATIM from
# this task's own starting state (git-status-shown as the "M" diff base for
# verify-before-stop.sh before this fix round), not reconstructed from
# memory — driven against the IDENTICAL runs/-blocked fixture from case 2,
# twice, to prove the EXACT collision R1-F1 reports: both calls return the
# SAME shared path. The shipped function, same fixture, does not (case 2
# above already showed this; this restates it in the same run as the
# specific-misbehaviour leg so the pairing is self-contained).
HISTORICAL_LIB="$WORK/historical.sh"
cat > "$HISTORICAL_LIB" <<'HISTORICAL'
run_scoped_log_dir() {
    local base="$QA_TRACKING_DIR/runs" dir=""
    mkdir -p "$base" 2>/dev/null || true
    if command -v mktemp >/dev/null 2>&1; then
        dir=$(mktemp -d "$base/run.XXXXXX" 2>/dev/null) || dir=""
    fi
    if [ -z "$dir" ]; then
        dir="$base/run.pid$$.$(date +%s 2>/dev/null || echo 0).${RANDOM:-0}"
        mkdir -p "$dir" 2>/dev/null || dir=""
    fi
    if [ -z "$dir" ] || [ ! -d "$dir" ]; then
        dir="$QA_TRACKING_DIR"
    fi
    printf '%s' "$dir"
}
HISTORICAL
rc_hit=1
# shellcheck disable=SC2016  # single quotes intentional: literal text to
# find in the historical file, not an expression for THIS shell to expand.
grep -qF 'dir="$QA_TRACKING_DIR"' "$HISTORICAL_LIB" && rc_hit=0
assert_eq "META: the historical body is the pre-fix collapse-to-shared-dir shape (non-vacuity)" \
    "0" "$rc_hit"
bash -n "$HISTORICAL_LIB" 2>/dev/null
assert_eq "META: the historical body parses" "0" "$?"

D2H="$WORK/t2-historical"; mkdir -p "$D2H"
: > "$D2H/runs"
(
    # Consumed inside the dynamically-sourced $HISTORICAL_LIB
    # (run_scoped_log_dir reads $QA_TRACKING_DIR), which shellcheck cannot
    # see into — same reason the earlier cases' QA_TRACKING_DIR assignments
    # need no such note (shellcheck happens not to flag those).
    # shellcheck disable=SC2034
    QA_TRACKING_DIR="$D2H"
    # shellcheck disable=SC1090
    . "$HISTORICAL_LIB"
    R1=$(run_scoped_log_dir)
    R2=$(run_scoped_log_dir)
    printf 'R1=%s\nR2=%s\n' "$R1" "$R2"
) > "$WORK/meta-case2.out"
MR1_VAL=$(sed -n 's/^R1=//p' "$WORK/meta-case2.out")
MR2_VAL=$(sed -n 's/^R2=//p' "$WORK/meta-case2.out")
assert_eq "META: the historical body collapses to the shared QA_TRACKING_DIR itself" \
    "$D2H" "$MR1_VAL"
assert_eq "META: ...so two calls in the SAME blocked state COLLIDE (specific misbehaviour, the exact R1-F1 defect)" \
    "COLLIDED" "$([ "$MR1_VAL" = "$MR2_VAL" ] && echo COLLIDED || echo distinct)"

# ---------------------------------------------------------------------------
if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0
