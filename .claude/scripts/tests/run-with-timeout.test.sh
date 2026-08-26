#!/bin/bash
# run-with-timeout.test.sh — claude-workflow-plugin-gsfd.
#
# Direct, executable tests of verify-before-stop.sh's run_with_timeout,
# EXTRACTED from the shipped script by awk (the scoped-log-dir.test.sh
# convention: driving the shipped DEFINITION rather than a re-typed copy
# free to drift).
#
# DESIGN COLLAPSE (claude-workflow-plugin-gsfd, operator-directed, round 6):
# this file used to carry sections 2-4 (plus their METAs), covering R4-F1 (a
# supervision loop that tested only the wrapper pid, not the process group,
# so backgrounded work could outlive a "successful" return) and R4-F2 (a
# heartbeat that ran synchronously inside the same loop and could block the
# loop's own deadline check). Both defects lived in an IN-PROCESS REWRITE of
# run_with_timeout — a poll loop with its own `kill -0 -- "-$child_pid"`
# group check and a `lease_heartbeat` call fired from inside it. That
# rewrite is gone: run_with_timeout is back to the ORIGINAL, shipped-and-
# reviewed shape (see that function's own header in verify-before-stop.sh),
# a plain `timeout`/`gtimeout` dispatch with no poll loop, no group check,
# and no heartbeat call of any kind. Sections 2-4 therefore tested literals
# that no longer exist in the shipped function:
#   - META 2's `sed 's/kill -0 -- "-\$child_pid"/.../'`  matches nothing —
#     the shipped file no longer contains that literal at all, so the
#     "mutant" was byte-identical to the original (DIFF2 would read 0, not
#     the 2 the landing guard required).
#   - META 3's `sed` over `( lease_heartbeat "$STOP_LEASE_FILE" ) </dev/null
#     ... &` matches nothing for the same reason.
#   - Section 4's heartbeat stub is never invoked at all — the restored
#     run_with_timeout does not call `lease_heartbeat` by name anywhere.
# Every one of those is the exact "mutant guards code that isn't there
# anymore" defect this round exists to catch (R5-F2, same family). Deleted
# with the mechanism rather than repaired, matching tree-lease.test.sh's own
# precedent for the identical situation.
#
# WHAT REMAINS, and why: sections 0-1 test properties that are still true of
# the restored dispatch and do not reference anything heartbeat- or
# group-kill-related — extraction validity, and plain exit-code/log-capture
# passthrough for a quick command. Kept as still-real coverage, not deleted
# along with the rest.
#
# THE GAP ABOVE, CLOSED FOR ONE OF ITS TWO CASES (claude-workflow-plugin-03tf,
# closing part of claude-workflow-plugin-v4jn). v4jn filed exactly the gap
# the previous paragraph describes: no leg anywhere proved run_with_timeout
# returns 124 for a genuine hang, and any test for it needed its own
# skip-when-absent handling because this dev box has neither `timeout` nor
# `gtimeout` on PATH. What changed: 03tf gave the `*)` branch (neither binary
# on PATH) its OWN enforcement — an in-process poll+tree-kill watchdog, ported
# from run-tests.sh's tree_pids()/escalate_kill() rather than reinstating the
# heartbeat rewrite round 6 reverted (see run_with_timeout's own WATCHDOG
# FALLBACK header paragraph for why those are different shapes). That makes
# the "no native binary" case of v4jn's gap trivially reachable RIGHT HERE,
# on THIS host, with no shim needed for the absent-binary half of the setup —
# it is the ambient default, not something section 3 below has to build.
# v4jn's OTHER case — a genuine hang under a REAL `timeout`/`gtimeout`
# binary — is untouched by 03tf (the `timeout)`/`gtimeout)` branches of the
# case statement are not part of this change) and remains open, still needing
# the skip-when-neither-present handling v4jn's own suggested shape describes
# for THAT half.
#
# Section 2 (disclosure) is UPDATED, not replaced, by 03tf: the `*)` branch
# still says something distinct in the log and via TIMEOUT_NOT_ENFORCED when
# neither binary is on PATH, but it no longer says "NOT ENFORCED" — 03tf
# means it now IS enforced, just not by the native binary, and shipping the
# old wording next to real enforcement would be a new dishonesty in the
# opposite direction from the one this whole task exists to fix. Section 3
# is NEW: the genuine-hang-returns-124 leg v4jn asked for, plus the negative
# control the task brief added on top of v4jn's own suggested shape (a
# command that finishes UNDER budget must return its real exit code and must
# NOT be killed — without it, a degenerate "always return 124" implementation
# would pass section 3's positive leg too) and a META that reverts the
# watchdog's cap-check to prove the positive leg's own assertions are
# sensitive to the mechanism actually being there.
#
# ASSERTIONS
#   0. The awk extraction defines run_with_timeout and parses.
#   1. Normal case: exit code passthrough (success and a specific failure
#      code), and the log genuinely captures the command's own output.
#   2. Disclosure (claude-workflow-plugin-gsfd, wording updated by 03tf): a
#      host with neither `timeout` nor `gtimeout` on PATH must say so — in
#      the log (appended AFTER the command's own output, never overwriting
#      it) and via the TIMEOUT_NOT_ENFORCED flag that checks_scope_note
#      reads for the operator-facing gate summary — and must now say it is
#      enforced by the in-process watchdog rather than that the cap was not
#      enforced. Paired: 2a mutates PATH (the state run_with_timeout reads
#      via `command -v`) to remove both binaries, with an explicit
#      precondition proving the mutation landed; 2b is the restore control —
#      a working `timeout` stub present on PATH — proving the marker does
#      not fire unconditionally. Both legs call the real, awk-extracted,
#      shipped run_with_timeout.
#   3. Genuine hang returns 124 (claude-workflow-plugin-03tf, closes v4jn's
#      no-native-binary case). 3a positive: PATH shimmed to resolve neither
#      binary (same non-vacuity precondition as 2a), a command backgrounds a
#      grandchild and then itself sleeps well past a short budget — asserts
#      rc=124, the elapsed wall time is bounded near the budget (not the
#      command's full sleep duration), and the ENTIRE process tree
#      (including the backgrounded grandchild, never a direct child of the
#      wrapper) is actually dead afterward. 3b negative control: same PATH
#      shim, a command that finishes UNDER the budget — must return the
#      command's real exit code, must NOT be killed, and must return in
#      close to real time rather than waiting out the budget; without this
#      leg, a degenerate implementation that always killed at 0s and
#      returned 124 would pass 3a too. 3c restore control: a working
#      `timeout` stub on PATH, same over-budget command as 3a — the
#      `timeout)` branch is untouched by 03tf, so behaviour there must be
#      byte-for-byte what section 2b already proved. 3M META: the SAME
#      over-budget command as 3a, run against a MUTANT that disables the
#      watchdog's cap-check (so it never fires within this test's own
#      patience) — proves 3a's rc/elapsed assertions are sensitive to the
#      mechanism actually being present, not just to the command eventually
#      finishing on its own.
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

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    fi
}

# mk_notimeout_path <dir> — populate <dir> with symlinks to every external
# binary run_with_timeout's `*)` branch (claude-workflow-plugin-03tf
# watchdog) needs — bash, sleep, ps, awk — while deliberately excluding
# `timeout`/`gtimeout` so `command -v` resolves neither. A PATH holding ONLY
# `bash` (this file's pre-03tf fixture, when the `*)` branch needed nothing
# else) is not a realistic "host with no timeout/gtimeout": every real host
# missing those two still ships `sleep`/`ps`/`awk` (POSIX-mandated); a PATH
# that omits them too makes the watchdog's own `sleep` calls fail ("command
# not found"), which its `|| true` guards tolerate but which then races the
# poll loop into escalating far faster than the advertised budget — a
# DIFFERENT bug from the one this file tests for. Measured directly while
# building this fixture: 5/5 runs against a bash-only PATH printed `sleep:
# command not found` on every poll tick and only self-corrected because the
# wrapped command in that test was already dead by the next `kill -0`
# check — not a guarantee against a genuine hang, and not what section 3
# below is trying to prove.
mk_notimeout_path() {
    local dir="$1" b b_real
    mkdir -p "$dir"
    for b in bash sleep ps awk; do
        b_real=$(command -v "$b" 2>/dev/null || true)
        [ -n "$b_real" ] && ln -sf "$b_real" "$dir/$b"
    done
}

if [ ! -f "$VBS" ]; then
    printf 'run-with-timeout.test.sh: shipped script missing: %s\n' "$VBS" >&2
    exit 2
fi

WORK=$(mktemp -d -t run-with-timeout-test.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    rm -rf "$WORK" 2>/dev/null || true
}
trap cleanup EXIT

SHIPPED_LIB="$WORK/shipped.sh"
awk '/^run_with_timeout\(\) \{/,/^\}/' "$VBS" > "$SHIPPED_LIB"

assert_eq "0.1 the extraction defines run_with_timeout" "1" \
    "$(grep -c '^run_with_timeout() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "0.2 the extraction parses" "0" \
    "$(bash -n "$SHIPPED_LIB" 2>/dev/null && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# 1. Normal case: exit code passthrough, and the log captures real output.
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    rc=0; run_with_timeout 5 "$WORK/o1.log" "exit 0" || rc=$?
    printf 'rc1=%s\n' "$rc"
    rc=0; run_with_timeout 5 "$WORK/o2.log" "exit 13" || rc=$?
    printf 'rc2=%s\n' "$rc"
    rc=0; run_with_timeout 5 "$WORK/o3.log" "echo hello-from-command; exit 0" || rc=$?
    printf 'rc3=%s\n' "$rc"
) > "$WORK/case1.out" 2>&1
RC1=$(sed -n 's/^rc1=//p' "$WORK/case1.out")
RC2=$(sed -n 's/^rc2=//p' "$WORK/case1.out")
RC3=$(sed -n 's/^rc3=//p' "$WORK/case1.out")
assert_eq "1a: a quick, successful command returns 0" "0" "$RC1"
assert_eq "1b: a quick command with a specific exit code preserves it exactly" "13" "$RC2"
# claude-workflow-plugin-gsfd: was assert_eq on the exact string
# "hello-from-command". On a host lacking both `timeout` and `gtimeout`
# (this dev box, verified above) the disclosure fix now appends a marker
# line after every unbounded run's own output — genuinely present in o3.log
# too, since this test never shims PATH away from the ambient one. An exact
# match would go red for a true, in-scope change to this same log's
# content; assert_contains keeps this assertion's actual claim ("the
# command's real output IS in there") true regardless of which branch a
# given host takes. Section 2 below asserts the disclosure text itself.
assert_contains "1c: the log genuinely captures the command's own output" \
    "hello-from-command" "$(cat "$WORK/o3.log" 2>/dev/null)"
assert_eq "1d: the logging command itself also returns 0 (RC3, previously extracted but never asserted)" \
    "0" "$RC3"

# ---------------------------------------------------------------------------
# 2. Disclosure (claude-workflow-plugin-gsfd). See this file's own header
# for the full account; both legs below call the SAME awk-extracted,
# shipped run_with_timeout sourced above as SHIPPED_LIB — no reimplementation
# of the disclosure logic lives in this test.

# 2a. Absent leg: PATH restricted via mk_notimeout_path (bash/sleep/ps/awk
# present, timeout/gtimeout absent — see that function's own header for why
# the pre-03tf bash-only fixture is no longer sufficient). The two
# precondition assertions prove this mutation of the STATE run_with_timeout
# reads (`command -v`) actually landed, per .claude/tests/README.md's
# pairing requirement (part 1, non-vacuity).
mk_notimeout_path "$WORK/notimeout-bin"
REAL_BASH=$(command -v bash 2>/dev/null || true)
assert_eq "2a precondition: the restricted PATH resolves no timeout" "yes" \
    "$(PATH="$WORK/notimeout-bin" command -v timeout >/dev/null 2>&1 && echo no || echo yes)"
assert_eq "2a precondition: the restricted PATH resolves no gtimeout" "yes" \
    "$(PATH="$WORK/notimeout-bin" command -v gtimeout >/dev/null 2>&1 && echo no || echo yes)"

(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    rc=0
    PATH="$WORK/notimeout-bin" run_with_timeout 5 "$WORK/o4.log" "echo real-output-marker; exit 7" || rc=$?
    printf 'rc4=%s\n' "$rc"
    printf 'flag4=%s\n' "${TIMEOUT_NOT_ENFORCED:-<unset>}"
) > "$WORK/case2a.out" 2>&1
RC4=$(sed -n 's/^rc4=//p' "$WORK/case2a.out")
FLAG4=$(sed -n 's/^flag4=//p' "$WORK/case2a.out")
O4_CONTENT=$(cat "$WORK/o4.log" 2>/dev/null)
assert_eq "2a: exit code still passes through (not swallowed by the trailing printf, and not overridden to 124 -- this command finishes well under budget)" \
    "7" "$RC4"
assert_contains "2a: the command's own output is still captured" \
    "real-output-marker" "$O4_CONTENT"
assert_contains "2a: the log discloses the watchdog fallback (claude-workflow-plugin-03tf: neither binary present, but the cap IS enforced -- by the in-process watchdog, not by 'NOT ENFORCED')" \
    "WATCHDOG FALLBACK ENFORCED" "$O4_CONTENT"
assert_eq "2a: the disclosure names the specific advertised duration" "yes" \
    "$(printf '%s' "$O4_CONTENT" | grep -qF 'the advertised 5s cap' && echo yes || echo no)"
assert_eq "2a: TIMEOUT_NOT_ENFORCED is set when neither binary is on PATH (name predates 03tf -- see run_with_timeout's own header: it now means 'not enforced by the NATIVE binary', not 'not enforced at all')" \
    "1" "$FLAG4"
# Ordering: the marker must be APPENDED after the real output, never
# overwriting it — the specific hazard both truncations in run_with_timeout
# create for anything written too early (see that function's own header).
O4_REAL_LINE=$(grep -n 'real-output-marker' "$WORK/o4.log" 2>/dev/null | head -1 | cut -d: -f1)
O4_MARKER_LINE=$(grep -n 'WATCHDOG FALLBACK ENFORCED' "$WORK/o4.log" 2>/dev/null | head -1 | cut -d: -f1)
assert_eq "2a: the disclosure marker lands AFTER the command's own output, never before it" \
    "yes" "$([ -n "$O4_REAL_LINE" ] && [ -n "$O4_MARKER_LINE" ] && [ "$O4_MARKER_LINE" -gt "$O4_REAL_LINE" ] && echo yes || echo no)"

# 2b. Restore control: a working `timeout` on PATH. Same shipped function,
# same call shape as 2a — only the PATH differs — so a disclosure firing
# here would be attributable to the assertion, not the environment.
mkdir -p "$WORK/faketimeout-bin"
if [ -n "$REAL_BASH" ]; then
    ln -sf "$REAL_BASH" "$WORK/faketimeout-bin/bash"
fi
cat > "$WORK/faketimeout-bin/timeout" <<'SHIM'
#!/bin/bash
# Minimal test double for GNU/BSD `timeout`: drop the duration argument and
# exec the rest, preserving its exit code exactly. Restore-control purposes
# only — it does not itself enforce any bound, so it proves run_with_timeout's
# ENFORCED branch is what suppresses the disclosure, not that this stub
# genuinely bounds a hang (claude-workflow-plugin-v4jn tracks that separate,
# still-open gap).
shift
exec "$@"
SHIM
chmod +x "$WORK/faketimeout-bin/timeout"
assert_eq "2b precondition: the restore-control PATH DOES resolve timeout" "yes" \
    "$(PATH="$WORK/faketimeout-bin" command -v timeout >/dev/null 2>&1 && echo yes || echo no)"

(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    rc=0
    PATH="$WORK/faketimeout-bin" run_with_timeout 5 "$WORK/o5.log" "echo real-output-marker; exit 7" || rc=$?
    printf 'rc5=%s\n' "$rc"
    printf 'flag5=%s\n' "${TIMEOUT_NOT_ENFORCED:-<unset>}"
) > "$WORK/case2b.out" 2>&1
RC5=$(sed -n 's/^rc5=//p' "$WORK/case2b.out")
FLAG5=$(sed -n 's/^flag5=//p' "$WORK/case2b.out")
O5_CONTENT=$(cat "$WORK/o5.log" 2>/dev/null)
assert_eq "2b: exit code still passes through with a timeout binary present" \
    "7" "$RC5"
assert_contains "2b: the command's own output is still captured" \
    "real-output-marker" "$O5_CONTENT"
assert_eq "2b: the disclosure marker does NOT appear when a timeout binary is present" \
    "no" "$(printf '%s' "$O5_CONTENT" | grep -qF 'WATCHDOG FALLBACK ENFORCED' && echo yes || echo no)"
assert_eq "2b: TIMEOUT_NOT_ENFORCED is NOT set when a timeout binary is present" \
    "<unset>" "$FLAG5"

# ---------------------------------------------------------------------------
# 3. Genuine hang returns 124 (claude-workflow-plugin-03tf, closes
# claude-workflow-plugin-v4jn's no-native-binary case). See this file's own
# header for the full account. All legs below call the SAME awk-extracted,
# shipped run_with_timeout sourced as SHIPPED_LIB — no reimplementation of
# the watchdog lives in this test.

# 3a. Positive: PATH via mk_notimeout_path (neither timeout nor gtimeout).
# The wrapped command backgrounds a grandchild sleep — never a direct child
# of the wrapper, the exact shape `make` spawning run-tests.sh spawning a
# per-spec `bash` has — and then itself sleeps well past a short 2s budget.
GCHILD_PIDFILE="$WORK/3a-gchild.pid"
SELF_PIDFILE="$WORK/3a-self.pid"
rm -f "$GCHILD_PIDFILE" "$SELF_PIDFILE" "$WORK/o6.log"
CMD3A="echo \$\$ > '$SELF_PIDFILE'; ( sleep 20 & echo \$! > '$GCHILD_PIDFILE' ); sleep 20; echo SHOULD_NOT_APPEAR_3A"

START3A=$(date +%s)
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    rc=0
    PATH="$WORK/notimeout-bin" run_with_timeout 2 "$WORK/o6.log" "$CMD3A" || rc=$?
    printf 'rc6=%s\n' "$rc"
) > "$WORK/case3a.out" 2>&1
END3A=$(date +%s)
ELAPSED3A=$((END3A - START3A))
RC6=$(sed -n 's/^rc6=//p' "$WORK/case3a.out")
O6_CONTENT=$(cat "$WORK/o6.log" 2>/dev/null)

assert_eq "3a positive: a genuine hang past the 2s budget returns 124" "124" "$RC6"
assert_eq "3a positive: the command's own output ends before the post-hang line -- it was killed, not merely outrun" \
    "no" "$(printf '%s' "$O6_CONTENT" | grep -qF 'SHOULD_NOT_APPEAR_3A' && echo yes || echo no)"
# Bounded near the budget (2s) + the watchdog's own 2s grace + a couple of
# seconds of process/test overhead -- nowhere near the command's own 20s
# sleep. Generous on purpose: this is a wall-clock assertion on a shared
# CI/dev box, not a precise timing test (measured on this host: 5s).
assert_eq "3a positive: elapsed wall time is bounded near the budget, not the command's full 20s duration" \
    "yes" "$([ "$ELAPSED3A" -le 12 ] && echo yes || echo no)"
assert_eq "3a precondition: the grandchild actually started (the tree existed to be killed, not that nothing ever ran)" \
    "yes" "$([ -s "$GCHILD_PIDFILE" ] && echo yes || echo no)"
SELF_PID3A=$(cat "$SELF_PIDFILE" 2>/dev/null || true)
GCHILD_PID3A=$(cat "$GCHILD_PIDFILE" 2>/dev/null || true)
assert_eq "3a positive: the top-level wrapped process is dead after the timeout" \
    "yes" "$([ -n "$SELF_PID3A" ] && ! kill -0 "$SELF_PID3A" 2>/dev/null && echo yes || echo no)"
assert_eq "3a positive: the BACKGROUNDED grandchild (never a direct child of the wrapper) is ALSO dead, not just the top-level process" \
    "yes" "$([ -n "$GCHILD_PID3A" ] && ! kill -0 "$GCHILD_PID3A" 2>/dev/null && echo yes || echo no)"

# 3b. Negative control: same PATH shim (neither binary present), a command
# that finishes UNDER the budget. Without this leg, a degenerate
# implementation that always killed at 0s and returned 124 unconditionally
# would pass 3a too — this is what specifically rules that out.
START3B=$(date +%s)
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    rc=0
    PATH="$WORK/notimeout-bin" run_with_timeout 5 "$WORK/o7.log" "echo real-output-3b; exit 9" || rc=$?
    printf 'rc7=%s\n' "$rc"
) > "$WORK/case3b.out" 2>&1
END3B=$(date +%s)
ELAPSED3B=$((END3B - START3B))
RC7=$(sed -n 's/^rc7=//p' "$WORK/case3b.out")
O7_CONTENT=$(cat "$WORK/o7.log" 2>/dev/null)
assert_eq "3b negative control: a command that finishes under budget returns its REAL exit code, not 124" \
    "9" "$RC7"
assert_contains "3b negative control: the command's own output is captured" \
    "real-output-3b" "$O7_CONTENT"
assert_eq "3b negative control: it returns promptly, NOT after waiting out the 5s budget (proves it was not killed and left to time out)" \
    "yes" "$([ "$ELAPSED3B" -le 3 ] && echo yes || echo no)"

# 3c. Restore control: a working `timeout` on PATH (the SAME pass-through
# stub 2b uses — 2b already established real dispatch + disclosure
# suppression for it; a stub that genuinely bounds a hang would be testing
# the STUB's own correctness, not whether 03tf leaked outside the `*)`
# branch, and claude-workflow-plugin-v4jn tracks that separate, still-open
# question). This leg reuses 3a's exact over-budget command shape, shortened
# so the pass-through's total run stays fast, and proves the `timeout)`
# branch (byte-for-byte unmodified by 03tf) shows NONE of the `*)` branch's
# new artifacts — the mutation is confined to the branch it claims to be.
mkdir -p "$WORK/faketimeout-bin-3c"
# The wrapped command below runs via `bash -c "$*"`, which inherits this
# SAME restricted PATH — it needs `sleep` resolvable too, or "sleep 3"
# fails ("command not found") and is silently skipped by the `;` separator,
# making the command return near-instantly for the wrong reason and
# invalidating the elapsed-time assertion below. Measured directly: this
# fixture originally symlinked only bash+timeout and the elapsed assertion
# went red at ~0s, not because dispatch was wrong but because `sleep` was
# never found. bash+sleep only (not ps/awk) — this leg never reaches the
# `*)` branch's watchdog, so it never needs those.
REAL_SLEEP=$(command -v sleep 2>/dev/null || true)
[ -n "$REAL_BASH" ] && ln -sf "$REAL_BASH" "$WORK/faketimeout-bin-3c/bash"
[ -n "$REAL_SLEEP" ] && ln -sf "$REAL_SLEEP" "$WORK/faketimeout-bin-3c/sleep"
cat > "$WORK/faketimeout-bin-3c/timeout" <<'SHIM'
#!/bin/bash
# Same restore-control double as section 2b: drops the duration argument
# and execs the rest, enforcing nothing itself.
shift
exec "$@"
SHIM
chmod +x "$WORK/faketimeout-bin-3c/timeout"
START3C=$(date +%s)
(
    # shellcheck disable=SC1090
    . "$SHIPPED_LIB"
    rc=0
    PATH="$WORK/faketimeout-bin-3c" run_with_timeout 1 "$WORK/o8.log" "sleep 3; echo real-output-3c; exit 0" || rc=$?
    printf 'rc8=%s\n' "$rc"
    printf 'flag8=%s\n' "${TIMEOUT_NOT_ENFORCED:-<unset>}"
) > "$WORK/case3c.out" 2>&1
END3C=$(date +%s)
RC8=$(sed -n 's/^rc8=//p' "$WORK/case3c.out")
FLAG8=$(sed -n 's/^flag8=//p' "$WORK/case3c.out")
O8_CONTENT=$(cat "$WORK/o8.log" 2>/dev/null)
assert_eq "3c restore control: dispatched through timeout), a command past the NOMINAL budget still runs to its real completion (the stub enforces nothing, matching 2b) -- proves this path is not secretly also going through the *) watchdog" \
    "0" "$RC8"
assert_contains "3c restore control: the command's real output is present (it was never killed)" \
    "real-output-3c" "$O8_CONTENT"
assert_eq "3c restore control: none of the *) branch's watchdog disclosure appears on the timeout) path" \
    "no" "$(printf '%s' "$O8_CONTENT" | grep -qF 'WATCHDOG FALLBACK ENFORCED' && echo yes || echo no)"
assert_eq "3c restore control: TIMEOUT_NOT_ENFORCED is not set on the timeout) path" \
    "<unset>" "$FLAG8"
assert_eq "3c restore control: elapsed reflects the command's real ~3s run, not an early *) -style cutoff near the 1s nominal budget" \
    "yes" "$([ "$((END3C - START3C))" -ge 2 ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
# 3M. META — mutate the shipped, awk-extracted run_with_timeout so the
# watchdog's cap-check never fires within this test's own patience, and
# prove 3a's own assertions (rc=124, bounded elapsed) are SENSITIVE to that
# mechanism actually being present — not a coincidence of the command
# happening to finish, and not (per .claude/tests/README.md's pairing
# requirement, part 1) a vacuous mutation that changed nothing.
RWT_MUT3="$WORK/rwt-mut3.sh"
# shellcheck disable=SC2016  # single quotes are intentional: this is a sed
# script matching a LITERAL bash conditional in the target file, not an
# expression for THIS shell to expand (same convention as gate-claim-honesty
# .test.sh's 8M META directive, and tree-lease.test.sh's META 2 before it).
sed 's/while \[ "\$waited" -lt "\$secs" \]; do/while [ "$waited" -lt "999999" ]; do/' \
    "$SHIPPED_LIB" > "$RWT_MUT3"
assert_eq "3M.0a non-vacuity: the mutant differs from the shipped extraction" \
    "yes" "$([ "$(shasum -a 256 "$RWT_MUT3" | awk '{print $1}')" != "$(shasum -a 256 "$SHIPPED_LIB" | awk '{print $1}')" ] && echo yes || echo no)"
# shellcheck disable=SC2016  # same reasoning: the needle is a literal string
# to grep for in the mutant's own text, not an expression to expand here.
assert_contains "3M.0b non-vacuity: the mutant's cap-check now reads the disabled literal" \
    'while [ "$waited" -lt "999999" ]; do' "$(cat "$RWT_MUT3")"
assert_eq "3M.0c the mutant is still valid bash" \
    "0" "$(bash -n "$RWT_MUT3" 2>/dev/null; echo $?)"

# The wrapped command here has a BOUNDED natural duration (~3s) so the
# mutant's disabled cap-check does not hang this test suite — it proves the
# same point (the advertised budget no longer binds) without needing to
# wait out an actual unbounded hang.
START3M=$(date +%s)
(
    # shellcheck disable=SC1090
    . "$RWT_MUT3"
    rc=0
    PATH="$WORK/notimeout-bin" run_with_timeout 1 "$WORK/o9.log" "sleep 3; echo natural-end-3m; exit 0" || rc=$?
    printf 'rc9=%s\n' "$rc"
) > "$WORK/case3m.out" 2>&1
END3M=$(date +%s)
RC9=$(sed -n 's/^rc9=//p' "$WORK/case3m.out")
O9_CONTENT=$(cat "$WORK/o9.log" 2>/dev/null)
assert_eq "3M SPECIFIC MISBEHAVIOUR: with the cap-check disabled, the SAME 1s budget no longer binds -- the command runs to its real ~3s completion and returns 0, never 124" \
    "0" "$RC9"
assert_contains "3M SPECIFIC MISBEHAVIOUR: ...and the command's real output proves it ran to completion rather than being cut off" \
    "natural-end-3m" "$O9_CONTENT"
assert_eq "3M SPECIFIC MISBEHAVIOUR: ...elapsed reflects the command's real duration, not the now-ineffective 1s budget (this is the pre-03tf bug, reproduced on demand)" \
    "yes" "$([ "$((END3M - START3M))" -ge 2 ] && echo yes || echo no)"
assert_eq "3M RESTORE CONTROL: the SAME command and budget against the SHIPPED (unmutated) code returns 124, not 0 -- already proven above at 3a, restated here for the side-by-side contrast" \
    "124" "$RC6"

printf '\nTotal: %d assertion(s)\n' "$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
