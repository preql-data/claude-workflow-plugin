#!/bin/bash
# green-check.test.sh — v5 D5 piece 3 (claude-workflow-plugin-fkm.7 D5):
# `qa-gate.sh green-check <tid> --phase before|after`.
#
# THE CONTRACT UNDER TEST: green-check runs the test command detect-stack.sh
# resolves (no new runner — see the shipped region's own header) and reports
# green/red/none, posting a durable `GREEN-CHECK v1` comment either way.
# --phase before + result=red + the task IS bound to a design unit REFUSES
# (exit 2, cannot_start_from_green) — docs/plans/v5-design-phase.md Phase
# D5's "a unit that cannot start from green stops and reports; the red
# baseline becomes its own task". An UNBOUND task's red --phase before is
# REPORTED, not refused (an implementer decision named in the shipped
# region's own header, not a claim the plan states outright). --phase after
# never refuses regardless of binding or result — only the START gate blocks.
# An UNREADABLE design-unit binding source is refused
# (design_binding_unreadable), never folded into "unbound".
#
# Sections:
#   1. runner=none (no manifest, no override): both phases report result=none
#   2. Green suite, unbound: reports green, records the durable comment
#   3. Red suite, unbound, --phase before: REPORTS (does not refuse)
#   4. Red suite, unbound, --phase after: same — after never gates
#   5. Red suite, BOUND, --phase before: REFUSES (cannot_start_from_green)
#   6. Red suite, BOUND, --phase after: does NOT refuse (after never gates)
#   7. Green suite, BOUND, --phase before: ok=true, no refusal
#   8. Argument errors: missing task-id, missing/invalid --phase, unknown flag
#   9. design_binding_unreadable: a task id that was never created
#   10. The WATCHDOG arm: the timeout cap is ENFORCED regardless of host
#       (QA round 2, R2-F2), FORCED via PATH_NO_TIMEOUT (QA round 4, R4-F2)
#       rather than left to whether this host happens to lack
#       timeout/gtimeout — a tree-kill leaves no surviving process.
#   11. timed_out on the WATCHDOG arm (QA round 3, R3-F1): `dispatch` alone
#       cannot say WHETHER the cap is why a run ended, only WHICH mechanism
#       was bounding it — reuses 10.1/10.2's fixtures for the positive case
#       and the cap-never-fired control, and adds a `self_124` negative
#       control (a command that calls `exit 124` on its own, well inside
#       the cap, FORCED onto the watchdog arm) to prove timed_out is not
#       just "exit_code==124" in disguise. Airtight on this arm.
#   12. GREEN_CHECK_TIMEOUT_S validation (QA round 3, R3-F3): non-numeric,
#       negative, fractional, and zero overrides are all refused (copied
#       from run-tests.sh's own SPEC_TIMEOUT_S case statement); an empty
#       override is documented as coerced to the default rather than
#       refused (bash's own `:-` semantics, same as SPEC_TIMEOUT_S); a valid
#       override still runs normally.
#   13. The HEURISTIC arm (timeout dispatch), FORCED via a `timeout` PATH
#       shim (QA round 4, R4-F2) so it runs on ANY host — WITHOUT this
#       section, no host tests this arm at all if it happens to lack a real
#       timeout/gtimeout binary, which is exactly how R4-F1's --help
#       overclaim shipped unobserved. Cases A/B/D/E/F are controls with a
#       generous (5s+) margin, deliberately NOT run at the exact cap-1
#       boundary: that boundary is genuinely probabilistic (QA round 5,
#       R5-F1 -- a real duration in (cap-1, cap] can measure AT the cap
#       depending on the start instant's sub-second fraction), so a
#       behavioural leg there would be flaky by construction, not merely in
#       practice. 13.C-STATIC is the ONLY leg that proves the R4-F3 fix (a
#       timing-independent grep of the shipped predicate text); case C
#       itself passes identically against the unfixed predicate and proves
#       nothing about R4-F3 (QA round 5, R5-F6). Case G is the ONE
#       irreducible false positive (self_124 landing AT the cap exactly)
#       that no elapsed heuristic can close, documented rather than hidden.
#   14. tracking_dir_unwritable (QA round 4, R4-F4; extended round 5,
#       R5-F3): an unwritable QA_TRACKING_DIR must REFUSE before ever
#       attempting to run the test command, not silently report a phantom
#       "red" for a suite that never ran at all -- both the "does not exist
#       and cannot be created" case (14.1) and the "already exists but lost
#       its write bit" case R4-F4's own fix did not cover (14.1b) refuse
#       with the same error_key.
#   META-TEST: mutate a COPY of qa-gate.sh so the green/red derivation is
#       hardcoded to "green" regardless of the real exit code — the
#       mechanical form of "stub the suite result to claim green while red".
#       The mutant WRONGLY reports green over an actually-red command, and
#       (worse) would let a BOUND unit proceed past the start gate it should
#       have stopped at; the shipped script, same fixture, still reports red
#       and still refuses.
#
# This spec needs a real bd/Beads fixture (green-check calls require_bd and
# posts durable comments), unlike its sibling
# validate-completion-green-fields.test.sh. Fixture shape mirrors
# review-separation.test.sh exactly.
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/green-check.test.sh
#   bash .claude/scripts/tests/green-check.test.sh --keep

# shellcheck disable=SC2317
# Helpers and scenario bodies are reached through control flow (set -u +
# early-exit + subshells) the static analyzer cannot follow. Disabled
# file-wide, matching the sibling specs in this directory.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

KEEP_FIXTURE=0
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

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
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

PLUGIN_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
FIXTURE=$(mktemp -d -t green-check.XXXXXX)

# shellcheck disable=SC2329  # cleanup invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf 'Fixture kept at: %s\n' "$FIXTURE"
        return
    fi
    [ -d "$FIXTURE" ] && rm -rf "$FIXTURE"
}
trap cleanup EXIT

if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required but not on PATH."
    exit 2
fi
if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — green-check tests require Beads."
    exit 1
fi

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$FIXTURE/bin"
cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1
rm -rf "$FIXTURE/.git"
export CLAUDE_PROJECT_DIR="$FIXTURE"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"

# ---------------------------------------------------------------------------
# TWO PATH OVERRIDES (QA round 4, R4-F2): green_check_run has TWO dispatch
# arms -- the heuristic (timeout/gtimeout binary) and the watchdog (neither
# on PATH) -- and WHICH ONE a bare `command -v timeout` check picks is
# entirely a property of the HOST, not of this spec. QA measured that on
# this authoring host (neither binary present) every prior assertion ran
# the WATCHDOG arm; the heuristic arm (qa-gate.sh's elapsed-time predicate,
# the exact code R4-F1's --help claim is about) executed ZERO times, and on
# a host WITH a real timeout/gtimeout the reverse would be true. An
# identical assertion count over DIFFERENT code is the misleading shape
# LESSONS.md:282 describes. Both PATH values below force one arm
# DETERMINISTICALLY regardless of what this host happens to have
# installed, so every host that runs this file exercises BOTH.
#
# PATH_WITH_TIMEOUT forces the HEURISTIC arm: a deterministic,
# marker-based `timeout` shim (same disambiguation technique
# green_check_run's own watchdog already uses) lives in its OWN directory,
# separate from $FIXTURE/bin's bd wrapper -- so PATH_NO_TIMEOUT below can
# filter out "any directory containing timeout/gtimeout" without also
# losing the bd wrapper. It models GNU timeout's one observable contract
# exactly: exit 124 when ITS OWN deadline ends the run, propagate the
# child's real exit status otherwise -- INCLUDING when that status is
# itself 124, the exact collision R4-F1/R4-F3 are about.
mkdir -p "$FIXTURE/bin-timeout-shim"
cat > "$FIXTURE/bin-timeout-shim/timeout" <<'SHIMEOF'
#!/bin/bash
dur="${1%s}"; shift
marker=$(mktemp -u -t timeoutshim.XXXXXX)
rm -f "$marker" 2>/dev/null
"$@" &
cpid=$!
(
    sleep "$dur"
    : > "$marker" 2>/dev/null
    kill -TERM "$cpid" 2>/dev/null
    sleep 0.2
    kill -KILL "$cpid" 2>/dev/null
) &
killer=$!
wait "$cpid" 2>/dev/null; rc=$?
kill "$killer" 2>/dev/null
wait "$killer" 2>/dev/null
if [ -f "$marker" ]; then
    rm -f "$marker" 2>/dev/null
    exit 124
fi
rm -f "$marker" 2>/dev/null
exit "$rc"
SHIMEOF
chmod +x "$FIXTURE/bin-timeout-shim/timeout"
PATH_WITH_TIMEOUT="$FIXTURE/bin-timeout-shim:$PATH"

# PATH_NO_TIMEOUT forces the WATCHDOG arm -- an ALLOWLIST, not a denylist
# (QA round 5, R5-F2). The ORIGINAL approach here filtered the ambient PATH
# down to directories that do not contain a real timeout/gtimeout binary.
# THAT CANNOT BE MADE CORRECT: on a normal Unix layout, coreutils
# co-locate -- Ubuntu's /usr/bin (this repo's OWN CI, ubuntu-latest,
# .github/workflows/test.yml:114/:263) holds bash, jq, date, sleep, ps AND
# timeout together, so "exclude any directory containing timeout" excludes
# the ENTIRE toolchain this test file itself needs, not just the one
# binary. MEASURED (QA): the denylist, run against a synthetic directory
# holding timeout alongside date/jq/ps/sleep/mktemp/bash, removed all of
# them; Section 10.1's exact invocation then failed with rc=127 "command
# not found: bash" -- a total, not a partial, failure, and one this
# authoring host's own PATH (which has neither timeout nor gtimeout at all)
# could never surface, because the filter was a byte-identical no-op here.
#
# THE FIX: build a directory of symlinks to EXACTLY the tools this test
# file's own invocations need, resolved via `command -v` against the
# CURRENT (unfiltered) PATH before timeout/gtimeout are ever considered,
# and set PATH to JUST that directory -- there is nowhere left for a real
# timeout/gtimeout to hide, on ANY host, and nothing else is silently lost
# either. The list below is not asserted correct by construction; NO_
# TIMEOUT_SELFCHECK a few lines down is the negative control that actually
# proves it (the check whose absence let the denylist ship unnoticed --
# "a non-vacuity check that the failure mode satisfies is not a non-vacuity
# check").
NO_TIMEOUT_ALLOWDIR="$FIXTURE/bin-no-timeout"
mkdir -p "$NO_TIMEOUT_ALLOWDIR"
# The list: bash/jq/bd (this file's own direct callers), date/sleep/ps/mkdir
# (green_check_run and _gc_tree_pids call these directly), rm/cat/printf/tr
# (green_check_run's log and marker handling -- printf is a bash builtin
# and needs no entry, kept in the comment for completeness), head/sed/tr
# (detect-stack.sh's read_override, which resolves .claude/test-cmd before
# any manifest-probing runs), git (Beads is git-backed), sort/head/tail/wc/
# cmp/chmod/dirname/basename/awk/grep/mktemp (this SPEC's own assertions
# and fixture helpers, which also run with PATH overridden inside the
# subshells that capture $OUT10/$OUT11/etc.) -- verified by RUNNING the
# full suite under this exact PATH and observing zero "command not found"
# failures, not merely by this list looking plausible.
NO_TIMEOUT_TOOLS="bash jq bd date sleep ps mkdir rm cat tr head sed git sort tail wc cmp chmod dirname basename awk grep mktemp"
for _nt_tool in $NO_TIMEOUT_TOOLS; do
    _nt_resolved=$(command -v "$_nt_tool" 2>/dev/null) || continue
    case "$_nt_resolved" in
        /*) ln -sf "$_nt_resolved" "$NO_TIMEOUT_ALLOWDIR/$_nt_tool" 2>/dev/null || true ;;
        *) : ;; # a shell builtin/keyword (e.g. a `kill`-alike) -- resolved
                 # by bash itself, never via PATH, so no symlink is needed
                 # or possible for it.
    esac
done
unset _nt_tool _nt_resolved
PATH_NO_TIMEOUT="$NO_TIMEOUT_ALLOWDIR"

# NO_TIMEOUT_SELFCHECK: the filter's OWN negative control (R5-F2's binding
# repair, part 2) -- after building PATH_NO_TIMEOUT, assert that EVERY
# listed tool still resolves under it. Pairs with 10.0 below (which checks
# the two names that must be ABSENT) the same way 10.1/11.x already pair
# with it by observing the shipped artifact actually run: this is the leg
# that would have caught the denylist's failure BEFORE it ever reached a
# real invocation, on ANY host, including this one.
NO_TIMEOUT_SELFCHECK_MISSING=""
for _nt_tool in $NO_TIMEOUT_TOOLS; do
    if ! PATH="$PATH_NO_TIMEOUT" command -v "$_nt_tool" >/dev/null 2>&1; then
        NO_TIMEOUT_SELFCHECK_MISSING="$NO_TIMEOUT_SELFCHECK_MISSING $_nt_tool"
    fi
done
unset _nt_tool

bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

comments_of() {
    bd_show_with_comments "$1" \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

new_task() {
    bd create "$1" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty'
}

# bind_task_to_unit <tid> <design_task> <unit_id> <design_hash> — posts the
# DESIGN-UNIT v1 record directly. latest_design_unit_binding only PARSES
# this comment grammar (a regex over the comment stream); it does not care
# how the comment got there, so this is a legitimate, minimal way to put a
# task into the "bound" state for THIS spec without standing up a full
# design artifact + design-unit-bind precondition chain that green-check
# itself never reads.
bind_task_to_unit() {
    local tid="$1" dtask="$2" uid="$3" dhash="$4" ts
    ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    bd comments add "$tid" \
        "DESIGN-UNIT v1 task=$tid design_task=$dtask unit_id=$uid design_hash=$dhash at $ts: bound" \
        >/dev/null 2>&1
}

set_test_cmd() {
    printf '%s\n' "$1" > "$FIXTURE/.claude/test-cmd"
}
clear_test_cmd() {
    rm -f "$FIXTURE/.claude/test-cmd"
}

DH64="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

# ---------------------------------------------------------------------------
echo "=== Section 1: runner=none (no manifest, no override) ==="

clear_test_cmd
TID1=$(new_task "GC: no runner resolved")
OUT=$(bash "$QG" green-check "$TID1" --phase before 2>/dev/null); RC1=$?
assert_eq "1.1 no test command resolved, --phase before: rc=0" "0" "$RC1"
assert_eq "1.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
assert_eq "1.1 ...result=none" "none" "$(printf '%s' "$OUT" | jq -r '.result')"
assert_eq "1.1 ...unit_bound=false" "false" "$(printf '%s' "$OUT" | jq -r '.unit_bound')"
assert_eq "1.1 ...exit_code=-1 (nothing ran)" "-1" "$(printf '%s' "$OUT" | jq -r '.exit_code')"

OUT=$(bash "$QG" green-check "$TID1" --phase after 2>/dev/null); RC1B=$?
assert_eq "1.2 no test command resolved, --phase after: rc=0" "0" "$RC1B"
assert_eq "1.2 ...result=none" "none" "$(printf '%s' "$OUT" | jq -r '.result')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: green suite, unbound ==="

set_test_cmd "true"
TID2=$(new_task "GC: green suite, unbound")
OUT=$(bash "$QG" green-check "$TID2" --phase before 2>/dev/null); RC2=$?
assert_eq "2.1 green suite, --phase before: rc=0" "0" "$RC2"
assert_eq "2.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
assert_eq "2.1 ...result=green" "green" "$(printf '%s' "$OUT" | jq -r '.result')"
assert_eq "2.1 ...exit_code=0" "0" "$(printf '%s' "$OUT" | jq -r '.exit_code')"
assert_eq "2.1 ...unit_id=\"\" (unbound)" "" "$(printf '%s' "$OUT" | jq -r '.unit_id')"
CMTS2=$(comments_of "$TID2")
assert_contains "2.2 a durable GREEN-CHECK v1 record was posted" \
    "GREEN-CHECK v1 task=$TID2 unit_id=none phase=before result=green exit_code=0" "$CMTS2"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: red suite, unbound, --phase before — REPORTS, does not refuse ==="

set_test_cmd "false"
TID3=$(new_task "GC: red suite, unbound, before")
OUT=$(bash "$QG" green-check "$TID3" --phase before 2>/dev/null); RC3=$?
assert_eq "3.1 red suite, unbound, --phase before: rc=0 (NOT refused)" "0" "$RC3"
assert_eq "3.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
assert_eq "3.1 ...result=red" "red" "$(printf '%s' "$OUT" | jq -r '.result')"
assert_eq "3.1 ...exit_code=1" "1" "$(printf '%s' "$OUT" | jq -r '.exit_code')"
CMTS3=$(comments_of "$TID3")
assert_contains "3.2 the durable record still carries result=red" \
    "GREEN-CHECK v1 task=$TID3 unit_id=none phase=before result=red exit_code=1" "$CMTS3"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: red suite, unbound, --phase after — same, after never gates ==="

TID4=$(new_task "GC: red suite, unbound, after")
OUT=$(bash "$QG" green-check "$TID4" --phase after 2>/dev/null); RC4=$?
assert_eq "4.1 red suite, unbound, --phase after: rc=0" "0" "$RC4"
assert_eq "4.1 ...result=red" "red" "$(printf '%s' "$OUT" | jq -r '.result')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: red suite, BOUND, --phase before — REFUSES ==="

TID5=$(new_task "GC: red suite, bound, before")
bind_task_to_unit "$TID5" "some-design-task" "U-1" "$DH64"
OUT=$(bash "$QG" green-check "$TID5" --phase before 2>/dev/null); RC5=$?
assert_eq "5.1 red suite, BOUND, --phase before: rc=2 (REFUSED)" "2" "$RC5"
assert_eq "5.1 ...ok=false" "false" "$(printf '%s' "$OUT" | jq -r '.ok')"
assert_eq "5.1 ...error_key=cannot_start_from_green" \
    "cannot_start_from_green" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_eq "5.1 ...unit_bound=true" "true" "$(printf '%s' "$OUT" | jq -r '.unit_bound')"
assert_eq "5.1 ...unit_id=U-1" "U-1" "$(printf '%s' "$OUT" | jq -r '.unit_id')"
assert_contains "5.2 the refusal names the remedy (open the red baseline as its own task)" \
    "Open the red baseline as its own task" "$(printf '%s' "$OUT" | jq -r '.observations')"
CMTS5=$(comments_of "$TID5")
assert_contains "5.3 the durable record was STILL written despite the refusal" \
    "GREEN-CHECK v1 task=$TID5 unit_id=U-1 phase=before result=red exit_code=1" "$CMTS5"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: red suite, BOUND, --phase after — does NOT refuse ==="

TID6=$(new_task "GC: red suite, bound, after")
bind_task_to_unit "$TID6" "some-design-task" "U-2" "$DH64"
OUT=$(bash "$QG" green-check "$TID6" --phase after 2>/dev/null); RC6=$?
assert_eq "6.1 red suite, BOUND, --phase after: rc=0 (after never gates)" "0" "$RC6"
assert_eq "6.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
assert_eq "6.1 ...result=red" "red" "$(printf '%s' "$OUT" | jq -r '.result')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: green suite, BOUND, --phase before — ok, no refusal ==="

set_test_cmd "true"
TID7=$(new_task "GC: green suite, bound, before")
bind_task_to_unit "$TID7" "some-design-task" "U-3" "$DH64"
OUT=$(bash "$QG" green-check "$TID7" --phase before 2>/dev/null); RC7=$?
assert_eq "7.1 green suite, BOUND, --phase before: rc=0" "0" "$RC7"
assert_eq "7.1 ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
assert_eq "7.1 ...result=green" "green" "$(printf '%s' "$OUT" | jq -r '.result')"
assert_eq "7.1 ...unit_id=U-3" "U-3" "$(printf '%s' "$OUT" | jq -r '.unit_id')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: argument errors ==="

RC8A=0
bash "$QG" green-check >/dev/null 2>&1 || RC8A=$?
assert_eq "8.1 missing task-id: rc=1" "1" "$RC8A"

TID8=$(new_task "GC: arg errors")
RC8B=0
OUT8B=$(bash "$QG" green-check "$TID8" 2>/dev/null) || RC8B=$?
assert_eq "8.2 missing --phase entirely: rc=1" "1" "$RC8B"
assert_eq "8.2 ...error_key=missing_phase" "missing_phase" "$(printf '%s' "$OUT8B" | jq -r '.error_key')"

RC8C=0
OUT8C=$(bash "$QG" green-check "$TID8" --phase sideways 2>/dev/null) || RC8C=$?
assert_eq "8.3 invalid --phase value: rc=1" "1" "$RC8C"
assert_eq "8.3 ...error_key=invalid_phase" "invalid_phase" "$(printf '%s' "$OUT8C" | jq -r '.error_key')"

RC8D=0
OUT8D=$(bash "$QG" green-check "$TID8" --phase 2>/dev/null) || RC8D=$?
assert_eq "8.4 --phase with no value: rc=1" "1" "$RC8D"
assert_eq "8.4 ...error_key=missing_phase" "missing_phase" "$(printf '%s' "$OUT8D" | jq -r '.error_key')"

RC8E=0
OUT8E=$(bash "$QG" green-check "$TID8" --phase before --bogus 2>/dev/null) || RC8E=$?
assert_eq "8.5 unknown flag: rc=1" "1" "$RC8E"
assert_eq "8.5 ...error_key=unknown_flag" "unknown_flag" "$(printf '%s' "$OUT8E" | jq -r '.error_key')"

# The loop-safety check: an unrecognised flag must not spin forever. If it
# did, the assertion above would simply never return — bounding the harness
# call with `timeout` (when available) turns a hang into a clean failure
# instead of a wedged test run.
if command -v timeout >/dev/null 2>&1; then
    RC8F=0
    timeout 10s bash "$QG" green-check "$TID8" --phase before --bogus >/dev/null 2>&1 || RC8F=$?
    assert_eq "8.6 unknown flag does not hang (bounded call completes, rc!=124)" \
        "not-124" "$([ "$RC8F" = "124" ] && echo "124-TIMEOUT" || echo "not-124")"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: design_binding_unreadable — a task id that was never created ==="

BOGUS_TID="does-not-exist-9999"
RC9=0
OUT9=$(bash "$QG" green-check "$BOGUS_TID" --phase before 2>/dev/null) || RC9=$?
assert_eq "9.1 a never-created task id: rc=2" "2" "$RC9"
assert_eq "9.1 ...error_key=design_binding_unreadable" \
    "design_binding_unreadable" "$(printf '%s' "$OUT9" | jq -r '.error_key')"
assert_eq "9.1 ...NOT folded into unbound (unit_bound=false is fine, but ok must be false)" \
    "false" "$(printf '%s' "$OUT9" | jq -r '.ok')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 10: the WATCHDOG arm -- the timeout cap is ENFORCED"
echo "regardless of host (QA round 2, R2-F2), FORCED via PATH_NO_TIMEOUT so"
echo "this arm runs on ANY host, not just one that happens to lack"
echo "timeout/gtimeout (QA round 4, R4-F2) ==="

# 10.0 self-check on the override itself, non-vacuity for PATH_NO_TIMEOUT:
# neither timeout nor gtimeout may resolve under it, on ANY host. QA round
# 5, R5-F2: THIS CHECK ALONE IS SATISFIED MOST STRONGLY BY THE PATHOLOGICAL
# CASE -- the whole directory removed, which is exactly what the old
# denylist did on a normal Unix layout. "A non-vacuity check that the
# failure mode satisfies is not a non-vacuity check." 10.0b below is the
# check that actually distinguishes "the two names are gone because
# everything is gone" from "the two names are gone and only the two names
# are gone" -- do not treat 10.0 alone as sufficient ever again.
NT_TIMEOUT_RC=0; PATH="$PATH_NO_TIMEOUT" command -v timeout >/dev/null 2>&1 || NT_TIMEOUT_RC=$?
NT_GTIMEOUT_RC=0; PATH="$PATH_NO_TIMEOUT" command -v gtimeout >/dev/null 2>&1 || NT_GTIMEOUT_RC=$?
assert_eq "10.0 PATH_NO_TIMEOUT: 'timeout' does not resolve under it" \
    "true" "$([ "$NT_TIMEOUT_RC" -ne 0 ] && echo true || echo false)"
assert_eq "10.0 ...neither does 'gtimeout'" \
    "true" "$([ "$NT_GTIMEOUT_RC" -ne 0 ] && echo true || echo false)"

# 10.0b THE ALLOWLIST'S OWN NEGATIVE CONTROL (R5-F2's binding repair, part
# 2): every OTHER tool this test file needs must STILL resolve under
# PATH_NO_TIMEOUT. Computed at fixture-setup time (NO_TIMEOUT_SELFCHECK_
# MISSING, above); asserted here so a failure surfaces as a named,
# specific FAIL line rather than a confusing downstream "command not
# found" three sections later.
assert_eq "10.0b ALLOWLIST self-check: every required tool still resolves under PATH_NO_TIMEOUT (empty = none missing)" \
    "" "$NO_TIMEOUT_SELFCHECK_MISSING"

# 10.1: the cap actually fires. A command that sleeps far longer than the
# cap must be killed and reported red well before its own natural finish,
# via the in-process watchdog fallback (ported from verify-before-stop.sh's
# run_with_timeout, 03tf) -- FORCED by PATH_NO_TIMEOUT, not left to whether
# this host happens to lack timeout/gtimeout.
set_test_cmd "sleep 20; echo should-not-finish"
TID10=$(new_task "GC: timeout cap enforced (10.1)")
T10_START=$(date +%s)
OUT10=$(PATH="$PATH_NO_TIMEOUT" GREEN_CHECK_TIMEOUT_S=2 bash "$QG" green-check "$TID10" --phase after 2>/dev/null)
RC10=$?
T10_END=$(date +%s)
T10_ELAPSED=$((T10_END - T10_START))
assert_eq "10.1 green-check itself still succeeds (rc=0) -- it is the COMMAND that timed out, not the tool reporting it" \
    "0" "$RC10"
assert_eq "10.1 ...result=red (a timeout is derived as red, same as any other non-zero exit)" \
    "red" "$(printf '%s' "$OUT10" | jq -r '.result')"
assert_eq "10.1 ...exit_code=124 (the 124-means-timeout convention this codebase uses everywhere else)" \
    "124" "$(printf '%s' "$OUT10" | jq -r '.exit_code')"
DISPATCH10=$(printf '%s' "$OUT10" | jq -r '.dispatch')
assert_eq "10.1 ...dispatch is exactly 'watchdog' (FORCED via PATH_NO_TIMEOUT, not host luck)" \
    "watchdog" "$DISPATCH10"
assert_eq "10.1 ...BOUNDED: elapsed wall time is well under the 20s sleep (proves the cap actually cut it short, not that the sleep happened to finish on its own)" \
    "true" "$([ "$T10_ELAPSED" -lt 15 ] && echo true || echo false)"
assert_eq "10.1 ...and not suspiciously immediate either (the command genuinely ran for a while before being cut off, not refused before starting at all)" \
    "true" "$([ "$T10_ELAPSED" -ge 1 ] && echo true || echo false)"
assert_eq "10.1b ...timed_out=true on the watchdog arm (the marker file is the only way rc is ever forced to 124 here -- airtight, per R3-F1)" \
    "true" "$(printf '%s' "$OUT10" | jq -r '.timed_out')"

# 10.2 NEGATIVE CONTROL: the SAME small cap over a command that finishes
# well inside it must NOT be treated as a timeout. Without this leg, a
# green-check that treated EVERY run as a timeout would also pass 10.1.
set_test_cmd "true"
TID10C=$(new_task "GC: timeout cap does not fire on a fast command (10.2 CONTROL)")
OUT10C=$(PATH="$PATH_NO_TIMEOUT" GREEN_CHECK_TIMEOUT_S=2 bash "$QG" green-check "$TID10C" --phase after 2>/dev/null)
assert_eq "10.2 CONTROL: a fast command under the SAME small cap reports green, not red" \
    "green" "$(printf '%s' "$OUT10C" | jq -r '.result')"
assert_eq "10.2 ...exit_code=0 (not 124 -- the cap correctly did not fire)" \
    "0" "$(printf '%s' "$OUT10C" | jq -r '.exit_code')"
assert_eq "10.2 ...timed_out=false (nothing to be true about)" \
    "false" "$(printf '%s' "$OUT10C" | jq -r '.timed_out')"

# 10.3: the killed command leaves NO surviving process -- the tree-kill
# actually worked, not merely that green-check REPORTED red while the sleep
# silently kept running in the background (a leak that would still show
# result=red and so would be invisible to 10.1 alone).
sleep 1
LEAKED=$(pgrep -f "sleep 20; echo should-not-finish" 2>/dev/null | wc -l | tr -d '[:space:]')
assert_eq "10.3 the killed command leaves NO surviving process (tree-kill actually worked, not just reported)" \
    "0" "${LEAKED:-0}"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 11: timed_out on the WATCHDOG arm disambiguates a"
echo "cap-caused 124 from a self-inflicted one (QA round 3, R3-F1) -- FORCED"
echo "via PATH_NO_TIMEOUT (QA round 4, R4-F2); see Section 13 for the SAME"
echo "disambiguation on the HEURISTIC arm, where it is NOT airtight ==="

# 11.1: the SAME capped, killed run 10.1 already produced -- dispatch alone
# cannot say the cap is why it ended (dispatch=timeout/gtimeout/watchdog
# looks identical either way); timed_out is the field that can.
assert_eq "11.1 the run 10.1 already captured (cap-killed) reports timed_out=true" \
    "true" "$(printf '%s' "$OUT10" | jq -r '.timed_out')"

# 11.2 CONTROL: the SAME small cap over a command that finishes on its own
# (10.2's fixture) must report timed_out=false -- the cap never fired.
assert_eq "11.2 CONTROL: a fast, un-capped command (10.2's OUT10C) reports timed_out=false" \
    "false" "$(printf '%s' "$OUT10C" | jq -r '.timed_out')"

# 11.3 NEGATIVE CONTROL (self_124): a command that calls `exit 124` ON ITS
# OWN, well inside the cap, must NOT be reported as timed_out. Without this
# leg, a green-check that treated EVERY exit_code=124 as a cap-caused
# timeout would also pass 11.1 -- this is the leg that proves it does not.
set_test_cmd "exit 124"
TID11=$(new_task "GC: self_124 negative control (11.3)")
T11_START=$(date +%s)
OUT11=$(PATH="$PATH_NO_TIMEOUT" GREEN_CHECK_TIMEOUT_S=20 bash "$QG" green-check "$TID11" --phase after 2>/dev/null)
T11_END=$(date +%s)
T11_ELAPSED=$((T11_END - T11_START))
assert_eq "11.3 self_124: result=red (exit_code=124 either way -- this is still a failing suite)" \
    "red" "$(printf '%s' "$OUT11" | jq -r '.result')"
assert_eq "11.3 ...exit_code=124 (the command's OWN exit code, not yet a cap conclusion)" \
    "124" "$(printf '%s' "$OUT11" | jq -r '.exit_code')"
assert_eq "11.3 ...timed_out=false (the 20s cap never fired -- the command exited on its own)" \
    "false" "$(printf '%s' "$OUT11" | jq -r '.timed_out')"
assert_eq "11.3 ...and it genuinely finished fast, nowhere near the 20s cap (proves this IS the self-exit case, not a lucky race at the boundary)" \
    "true" "$([ "$T11_ELAPSED" -lt 10 ] && echo true || echo false)"
assert_eq "11.3 ...dispatch=watchdog (FORCED, confirms this ran the arm this section claims)" \
    "watchdog" "$(printf '%s' "$OUT11" | jq -r '.dispatch')"

# 11.4: runner=none (Section 1's shape) reports timed_out=false, matching
# dispatch=n/a's own "nothing ran" reasoning -- nothing ran, so nothing
# could have timed out.
clear_test_cmd
TID11B=$(new_task "GC: timed_out=false when runner=none (11.4)")
OUT11B=$(bash "$QG" green-check "$TID11B" --phase before 2>/dev/null)
assert_eq "11.4 runner=none: timed_out=false" \
    "false" "$(printf '%s' "$OUT11B" | jq -r '.timed_out')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 12: GREEN_CHECK_TIMEOUT_S validation (QA round 3, R3-F3) ==="
echo "    same two rejected shapes as run-tests.sh's own SPEC_TIMEOUT_S."

set_test_cmd "true"
TID12=$(new_task "GC: timeout config validation (Section 12)")

# 12.1: an EMPTY override is NOT reachable as invalid_timeout_config -- the
# script's own "${GREEN_CHECK_TIMEOUT_S:-540}" default-assignment resolves
# an empty value to 540 before the validation case statement ever runs
# (bash's `:-` triggers on unset OR empty, identically to how
# run-tests.sh's SPEC_TIMEOUT_S already behaves). Documented as a passing
# assertion instead of silently omitted, so this is a recorded fact, not an
# assumption: an empty override behaves exactly like an absent one.
RC12A=0
OUT12A=$(GREEN_CHECK_TIMEOUT_S="" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12A=$?
assert_eq "12.1 an EMPTY override is coerced to the 540s default before validation runs (rc=0, NOT invalid_timeout_config)" \
    "0" "$RC12A"
assert_eq "12.1 ...result=green (the actual command still ran)" \
    "green" "$(printf '%s' "$OUT12A" | jq -r '.result')"

RC12B=0
OUT12B=$(GREEN_CHECK_TIMEOUT_S="abc" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12B=$?
assert_eq "12.2 non-numeric GREEN_CHECK_TIMEOUT_S: rc=2" "2" "$RC12B"
assert_eq "12.2 ...error_key=invalid_timeout_config" \
    "invalid_timeout_config" "$(printf '%s' "$OUT12B" | jq -r '.error_key')"

RC12C=0
OUT12C=$(GREEN_CHECK_TIMEOUT_S="-5" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12C=$?
assert_eq "12.3 negative GREEN_CHECK_TIMEOUT_S: rc=2 (the leading '-' fails the digit-only pattern)" \
    "2" "$RC12C"
assert_eq "12.3 ...error_key=invalid_timeout_config" \
    "invalid_timeout_config" "$(printf '%s' "$OUT12C" | jq -r '.error_key')"

RC12D=0
OUT12D=$(GREEN_CHECK_TIMEOUT_S="3.5" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12D=$?
assert_eq "12.4 fractional GREEN_CHECK_TIMEOUT_S: rc=2" "2" "$RC12D"
assert_eq "12.4 ...error_key=invalid_timeout_config" \
    "invalid_timeout_config" "$(printf '%s' "$OUT12D" | jq -r '.error_key')"

# 12.4b the EXACT case QA's R3-F3 finding measured: an "s"-suffixed value,
# the typo the code's own `"${GREEN_CHECK_TIMEOUT_S}s"` interpolation style
# invites (someone writes the override the way they'd write it in the
# `timeout` invocation itself).
RC12D2=0
OUT12D2=$(GREEN_CHECK_TIMEOUT_S="4500s" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12D2=$?
assert_eq "12.4b the 's'-suffix typo (4500s): rc=2" "2" "$RC12D2"
assert_eq "12.4b ...error_key=invalid_timeout_config" \
    "invalid_timeout_config" "$(printf '%s' "$OUT12D2" | jq -r '.error_key')"

RC12E=0
OUT12E=$(GREEN_CHECK_TIMEOUT_S="0" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12E=$?
assert_eq "12.5 GREEN_CHECK_TIMEOUT_S=0: rc=2 (0/no-cap is refused, matching SPEC_TIMEOUT_S's own mwrb reasoning)" \
    "2" "$RC12E"
assert_eq "12.5 ...error_key=timeout_disabled_not_offered" \
    "timeout_disabled_not_offered" "$(printf '%s' "$OUT12E" | jq -r '.error_key')"

# 12.6 RESTORE CONTROL: a valid override still runs the command normally --
# the validation above rejects garbage without also rejecting good input.
RC12F=0
OUT12F=$(GREEN_CHECK_TIMEOUT_S="30" bash "$QG" green-check "$TID12" --phase before 2>/dev/null) || RC12F=$?
assert_eq "12.6 CONTROL: a valid GREEN_CHECK_TIMEOUT_S=30 still runs normally: rc=0" "0" "$RC12F"
assert_eq "12.6 ...result=green (the actual command ran, unaffected by validation)" \
    "green" "$(printf '%s' "$OUT12F" | jq -r '.result')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 13: the HEURISTIC arm (timeout dispatch), FORCED via a PATH"
echo "shim so it runs on ANY host (QA round 4, R4-F2) -- this is the arm"
echo "R4-F1's --help claim was actually about, and the ONLY arm where"
echo "timed_out is a best-effort inference rather than airtight (R4-F3) ==="

# 13.0 self-check, non-vacuity for PATH_WITH_TIMEOUT: 'timeout' MUST
# resolve under it, on ANY host (real binary present or not -- the shim
# shadows it either way, being first on PATH).
WT_TIMEOUT_RC=0; PATH="$PATH_WITH_TIMEOUT" command -v timeout >/dev/null 2>&1 || WT_TIMEOUT_RC=$?
assert_eq "13.0 PATH_WITH_TIMEOUT: 'timeout' resolves (the shim)" \
    "true" "$([ "$WT_TIMEOUT_RC" -eq 0 ] && echo true || echo false)"

# 13.A the cap genuinely fires over a real hang -- same shape as 10.1, now
# on the HEURISTIC arm specifically. TEXTUALLY DISTINCT from 10.1's command
# (QA round 5, R5-F5): this shim TERM/KILLs only the process it directly
# forked, not the whole tree (faithful to a real `timeout` without
# --kill-after/--foreground -- not a defect in the shipped code), so a
# `sleep 20` grandchild can outlive the kill and be reparented to ppid 1.
# 10.3 greps for 10.1's exact command string via `pgrep -f`; reusing that
# SAME string here would let a leaked 13.A orphan from one concurrent run
# of this spec falsely trip 10.3 in ANOTHER concurrent run. One word
# ("finish" -> "complete") is the whole fix.
set_test_cmd "sleep 20; echo should-not-complete"
TID13A=$(new_task "GC-HEUR: cap fires over a hang (13.A)")
OUT13A=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=3 bash "$QG" green-check "$TID13A" --phase after 2>/dev/null)
assert_eq "13.A dispatch=timeout (the shim was actually used)" \
    "timeout" "$(printf '%s' "$OUT13A" | jq -r '.dispatch')"
assert_eq "13.A ...exit_code=124" "124" "$(printf '%s' "$OUT13A" | jq -r '.exit_code')"
assert_eq "13.A ...timed_out=true (the deadline genuinely ended this run)" \
    "true" "$(printf '%s' "$OUT13A" | jq -r '.timed_out')"

# 13.B self_124, WAY under the cap -- the discrimination the feature
# claims: an ordinary self-inflicted 124 nowhere near the deadline.
set_test_cmd "exit 124"
TID13B=$(new_task "GC-HEUR: self_124 far under cap (13.B)")
OUT13B=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=20 bash "$QG" green-check "$TID13B" --phase after 2>/dev/null)
assert_eq "13.B dispatch=timeout" "timeout" "$(printf '%s' "$OUT13B" | jq -r '.dispatch')"
assert_eq "13.B ...exit_code=124 (the command's own code)" \
    "124" "$(printf '%s' "$OUT13B" | jq -r '.exit_code')"
assert_eq "13.B ...timed_out=false (correct -- nowhere near the cap)" \
    "false" "$(printf '%s' "$OUT13B" | jq -r '.timed_out')"

# 13.C self_124 with a generous (5s) real margin under the cap. THIS CASE
# DOES NOT PROVE THE R4-F3 FIX (QA round 5, R5-F6, correcting this
# comment's own prior framing): at cap=8 it passes identically against the
# UNFIXED predicate too (elapsed=3 is still < 7 under the old `>= cap-1`),
# so it is a control demonstrating "comfortably under the cap reads false",
# the same shape as 13.B/13.D, not a regression test for the boundary
# R4-F3 changed. It is deliberately NOT run at the exact cap-1 boundary:
# `date +%s` truncation plus this shim's own fork/wait/kill overhead can
# push a 1-second-margin case's MEASURED elapsed a full second either way
# (measured directly: this exact case at cap=3/sleep=2 once read elapsed=3
# on a loaded host, flipping the assertion that used to live here). Given
# R5-F1's own finding -- a real duration in (cap-1, cap] is GENUINELY
# probabilistic, not merely hard to time -- a behavioural leg at that
# boundary would be flaky by construction, not just in practice, so one is
# deliberately not attempted. 13.C-STATIC below is the ONLY leg that
# proves R4-F3, and it needs no wall-clock at all.
set_test_cmd "sleep 3; exit 124"
TID13C=$(new_task "GC-HEUR: self_124 with real margin under cap (13.C)")
OUT13C=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=8 bash "$QG" green-check "$TID13C" --phase after 2>/dev/null)
assert_eq "13.C dispatch=timeout" "timeout" "$(printf '%s' "$OUT13C" | jq -r '.dispatch')"
assert_eq "13.C ...exit_code=124 (the command's own code, cap=8 never actually fired)" \
    "124" "$(printf '%s' "$OUT13C" | jq -r '.exit_code')"
assert_eq "13.C ...timed_out=false (5s of real margin under the cap -- true under BOTH the old and new predicate, proves nothing about R4-F3 alone; see 13.C-STATIC)" \
    "false" "$(printf '%s' "$OUT13C" | jq -r '.timed_out')"

# 13.C-STATIC THE ONLY LEG THAT PROVES THE R4-F3 FIX (QA round 5, R5-F6):
# a timing-independent grep confirming the shipped predicate no longer
# subtracts 1 from the cap. Before this fix, an INTEGER elapsed reading of
# exactly cap-1 was treated as cap-caused in addition to elapsed>=cap; a
# textual check of the shipped source proves that specific band is gone
# deterministically (grep, not a race against the clock) -- the one
# instrument this file has that a real-duration boundary test (R5-F1)
# cannot be, on bash 3.2 with no portable sub-second clock.
# shellcheck disable=SC2016  # single-quoted deliberately: these are the
# LITERAL source-text patterns to grep the shipped script for, not
# expressions to shell-expand (same discipline as design-conform.test.sh's
# own MUT_LINE, this file's established precedent for this exact idiom).
STATIC_TOLERANCE_HITS=$(grep -cE 'elapsed" -ge \$\(\(GREEN_CHECK_TIMEOUT_S - 1\)\)' "$QG")
assert_eq "13.C-STATIC the shipped predicate no longer subtracts 1 from the cap (0 occurrences of the old '-1' pattern)" \
    "0" "$STATIC_TOLERANCE_HITS"
# shellcheck disable=SC2016
STATIC_EXACT_CAP_HITS=$(grep -cE 'elapsed" -ge "\$GREEN_CHECK_TIMEOUT_S"' "$QG")
assert_eq "13.C-STATIC ...and the exact-cap predicate IS present, twice (timeout branch + gtimeout branch)" \
    "2" "$STATIC_EXACT_CAP_HITS"

# 13.D self_124 well before the cap -- unaffected by the R4-F3 fix either
# way (correct under both the old and new predicate), a plainer instance
# of the same correct case as 13.B. Same generous margin as 13.C, for the
# same reason.
set_test_cmd "sleep 1; exit 124"
TID13D=$(new_task "GC-HEUR: self_124 well before cap (13.D)")
OUT13D=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=8 bash "$QG" green-check "$TID13D" --phase after 2>/dev/null)
assert_eq "13.D timed_out=false" "false" "$(printf '%s' "$OUT13D" | jq -r '.timed_out')"

# 13.E / 13.F: plain controls -- green and a non-124 red, neither ever
# timed_out regardless of arm.
set_test_cmd "true"
TID13E=$(new_task "GC-HEUR: green control (13.E)")
OUT13E=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=3 bash "$QG" green-check "$TID13E" --phase after 2>/dev/null)
assert_eq "13.E result=green, timed_out=false" \
    "green false" "$(printf '%s' "$OUT13E" | jq -r '.result + " " + (.timed_out|tostring)')"

set_test_cmd "false"
TID13F=$(new_task "GC-HEUR: plain red control, not 124 (13.F)")
OUT13F=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=3 bash "$QG" green-check "$TID13F" --phase after 2>/dev/null)
assert_eq "13.F exit_code=1, timed_out=false" \
    "1 false" "$(printf '%s' "$OUT13F" | jq -r '(.exit_code|tostring) + " " + (.timed_out|tostring)')"

# 13.G THE IRREDUCIBLE CASE, documented rather than hidden: self_124 at
# EXACTLY the cap. No elapsed-time reading can tell "the deadline fired at
# t=cap" apart from "the command finished, coincidentally, at t=cap" --
# this is NOT a regression the R4-F3 fix introduces; it is the one false
# positive that fix explicitly does NOT and cannot purchase away, called
# out at qa-gate.sh's own predicate comments and in the --help text (R4-F1).
set_test_cmd "sleep 3; exit 124"
TID13G=$(new_task "GC-HEUR: self_124 AT the cap, irreducible (13.G)")
OUT13G=$(PATH="$PATH_WITH_TIMEOUT" GREEN_CHECK_TIMEOUT_S=3 bash "$QG" green-check "$TID13G" --phase after 2>/dev/null)
assert_eq "13.G dispatch=timeout" "timeout" "$(printf '%s' "$OUT13G" | jq -r '.dispatch')"
assert_eq "13.G ...exit_code=124 (the command's own code -- the cap never actually had to act)" \
    "124" "$(printf '%s' "$OUT13G" | jq -r '.exit_code')"
assert_eq "13.G ...timed_out=true -- IRREDUCIBLE, documented, not a defect: an elapsed heuristic cannot distinguish this from a genuine cap-fire" \
    "true" "$(printf '%s' "$OUT13G" | jq -r '.timed_out')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 14: tracking_dir_unwritable (QA round 4, R4-F4) -- a suite"
echo "that never ran must REFUSE, not silently report a phantom red ==="

# 14.1 the MISSING-directory case: chmod the FIXTURE's own .claude to 500
# (read+execute, no write) so mkdir -p on a not-yet-created .qa-tracking
# genuinely fails. Removes .qa-tracking first so this is a FRESH-directory
# failure (mkdir -p succeeds trivially on an ALREADY-existing directory
# regardless of its own permission bits -- that is 14.1b below, a
# DIFFERENT case this leg cannot exercise).
set_test_cmd "true"
TID14=$(new_task "GC: tracking_dir_unwritable, missing dir (14.1)")
rm -rf "$FIXTURE/.claude/.qa-tracking"
chmod 500 "$FIXTURE/.claude"
RC14=0
OUT14=$(bash "$QG" green-check "$TID14" --phase before 2>/dev/null) || RC14=$?
chmod 700 "$FIXTURE/.claude"
assert_eq "14.1 an unwritable QA_TRACKING_DIR REFUSES: rc=2" "2" "$RC14"
assert_eq "14.1 ...error_key=tracking_dir_unwritable" \
    "tracking_dir_unwritable" "$(printf '%s' "$OUT14" | jq -r '.error_key')"
assert_eq "14.1 ...ok=false (NOT a phantom red -- the suite never ran at all)" \
    "false" "$(printf '%s' "$OUT14" | jq -r '.ok')"
assert_eq "14.1 ...result is empty, not 'red' (a red claim would assert the suite ran and failed; it did not run)" \
    "" "$(printf '%s' "$OUT14" | jq -r '.result')"

# 14.1b THE CASE R4-F4's OWN FIX DID NOT COVER (QA round 5, R5-F3): the
# directory ALREADY EXISTS (mkdir -p FIRST, so it is genuinely present),
# and only THEN loses its write bit (chmod 500 the directory itself, not
# its parent) -- exactly the scenario R4-F4's own evidence measured
# ("Log directory present but NOT writable"), and exactly the normal state
# of a real project (post-edit.sh and `qa-gate.sh enter` both create
# .qa-tracking on first use, so "already exists" is the common case, not
# the exception). `mkdir -p` on an existing directory returns 0 regardless
# of its permissions -- the R4-F4 guard alone does not fire here; the
# writability probe added this round (`: > "$log_path"`) is what catches
# it.
TID14C=$(new_task "GC: tracking_dir_unwritable, existing dir loses write bit (14.1b)")
mkdir -p "$FIXTURE/.claude/.qa-tracking"
chmod 500 "$FIXTURE/.claude/.qa-tracking"
RC14C=0
OUT14C=$(bash "$QG" green-check "$TID14C" --phase before 2>/dev/null) || RC14C=$?
chmod 700 "$FIXTURE/.claude/.qa-tracking"
assert_eq "14.1b an EXISTING-but-now-unwritable QA_TRACKING_DIR ALSO refuses: rc=2" \
    "2" "$RC14C"
assert_eq "14.1b ...error_key=tracking_dir_unwritable (same key -- one problem, not two)" \
    "tracking_dir_unwritable" "$(printf '%s' "$OUT14C" | jq -r '.error_key')"
assert_eq "14.1b ...ok=false" "false" "$(printf '%s' "$OUT14C" | jq -r '.ok')"

# 14.2 RESTORE CONTROL: the identical fixture, a writable tracking dir,
# runs and reports green normally -- covers BOTH negative legs above (the
# same "everything is fine" state either would have been refused against).
TID14B=$(new_task "GC: tracking_dir writable, restore control (14.2)")
OUT14B=$(bash "$QG" green-check "$TID14B" --phase before 2>/dev/null)
assert_eq "14.2 CONTROL: writable tracking dir reports green normally" \
    "green" "$(printf '%s' "$OUT14B" | jq -r '.result')"

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST: hardcode the green/red derivation on a COPY -> the mutant"
echo "claims green over an actually-red command, and (worse) lets a BOUND unit"
echo "past the start gate it should have stopped at ================================"

META_QG="$FIXTURE/.claude/scripts/qa-gate-green-mutant.sh"
# shellcheck disable=SC2016  # single quotes are deliberate: $rc must stay
# LITERAL in the sed pattern/replacement (matching the shipped script's own
# source text), never shell-expanded.
sed 's/if \[ "\$rc" -eq 0 \]; then result="green"; else result="red"; fi/result="green"  # MUTATED: hardcoded, ignores $rc/' \
    "$QG" > "$META_QG"
chmod +x "$META_QG" 2>/dev/null || true

assert_eq "META.1 non-vacuity: the mutant DIFFERS from the shipped script" \
    "differs" "$(cmp -s "$QG" "$META_QG" && echo identical || echo differs)"
GREP_HIT=$(grep -c 'result="green"  # MUTATED' "$META_QG" | tr -d '[:space:]')
assert_eq "META.2 non-vacuity: the mutation landed — exactly one hardcoded result=\"green\" line" \
    "1" "$GREP_HIT"
BASH_N_RC=0
bash -n "$META_QG" 2>/dev/null || BASH_N_RC=$?
assert_eq "META.3 the mutant still parses (bash -n rc=0)" "0" "$BASH_N_RC"

# SPECIFIC MISBEHAVIOUR 1: an UNBOUND red suite now WRONGLY reports green.
set_test_cmd "false"
TIDM1=$(new_task "GC-META: unbound red, mutant claims green")
MOUT1=$(bash "$META_QG" green-check "$TIDM1" --phase before 2>/dev/null); MRC1=$?
assert_eq "META.4 MUTANT: an unbound red command is reported as green (rc=0)" "0" "$MRC1"
assert_eq "META.4 ...result=green (WRONG — the real command exited nonzero)" \
    "green" "$(printf '%s' "$MOUT1" | jq -r '.result')"

# RESTORE CONTROL: the identical fixture state, shipped script -> red.
TIDM1B=$(new_task "GC-META: unbound red, shipped control")
SOUT1=$(bash "$QG" green-check "$TIDM1B" --phase before 2>/dev/null); SRC1=$?
assert_eq "META.5 RESTORE CONTROL: the shipped script, same command, reports red (rc=0)" "0" "$SRC1"
assert_eq "META.5 ...result=red (correct)" "red" "$(printf '%s' "$SOUT1" | jq -r '.result')"

# SPECIFIC MISBEHAVIOUR 2 (the named consequence): a BOUND unit's red
# baseline, which the shipped script REFUSES to let start on, is WRONGLY
# allowed to proceed by the mutant — the exact failure the plan's own
# "a unit that cannot start from green stops and reports" line exists to
# prevent, reproduced live.
TIDM2=$(new_task "GC-META: bound red, mutant lets it proceed")
bind_task_to_unit "$TIDM2" "some-design-task" "U-META" "$DH64"
MOUT2=$(bash "$META_QG" green-check "$TIDM2" --phase before 2>/dev/null); MRC2=$?
assert_eq "META.6 MUTANT: a BOUND red baseline is WRONGLY allowed to proceed (rc=0, not refused)" \
    "0" "$MRC2"
assert_eq "META.6 ...ok=true (should have been the cannot_start_from_green refusal)" \
    "true" "$(printf '%s' "$MOUT2" | jq -r '.ok')"

# RESTORE CONTROL for misbehaviour 2: same fixture, shipped script -> refuses.
TIDM2B=$(new_task "GC-META: bound red, shipped control refuses")
bind_task_to_unit "$TIDM2B" "some-design-task" "U-META2" "$DH64"
SOUT2=$(bash "$QG" green-check "$TIDM2B" --phase before 2>/dev/null); SRC2=$?
assert_eq "META.7 RESTORE CONTROL: the shipped script, same fixture, REFUSES (rc=2)" "2" "$SRC2"
assert_eq "META.7 ...error_key=cannot_start_from_green" \
    "cannot_start_from_green" "$(printf '%s' "$SOUT2" | jq -r '.error_key')"

# --- Summary -------------------------------------------------------------

printf '\nTotal: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf 'Failed assertions:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
