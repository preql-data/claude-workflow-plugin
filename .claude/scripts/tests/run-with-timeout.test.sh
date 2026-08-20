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
# A GAP THIS ROUND DELIBERATELY DID NOT CLOSE, filed instead of absorbed
# (claude-workflow-plugin-v4jn): no leg anywhere in this suite proves
# run_with_timeout actually returns 124 for a GENUINE (non-backgrounding-
# trick) hang past the deadline — the single most safety-critical property
# of this function, since classify_test_failure and the FAILED_CHECKS
# branches in verify-before-stop.sh depend on it. The old section 2 got
# there only via the R4-F1 backgrounding exploit, which is a different
# property (group-vs-wrapper detection) and is itself moot against the
# restored plain dispatch. Writing a correct new test needs its own
# skip-when-absent handling (this dev box has neither `timeout` nor
# `gtimeout` on PATH — verified directly, not assumed — so run_with_timeout
# silently takes its unbounded `else` branch here today), which is exactly
# the kind of new machinery this round was told not to add on the strength
# of removing something else. See v4jn for the suggested shape. Section 2
# below is DIFFERENT from, and does not close, this gap: it covers
# DISCLOSURE (does an unbounded run say so?), never genuine-hang-returns-124
# (does the cap actually fire?) — the two are independent properties, and
# v4jn also now records that a host lacking both binaries cannot reach the
# second question at all without a PATH shim, which is exactly what section
# 2 had to build for the first.
#
# ASSERTIONS
#   0. The awk extraction defines run_with_timeout and parses.
#   1. Normal case: exit code passthrough (success and a specific failure
#      code), and the log genuinely captures the command's own output.
#   2. Disclosure (claude-workflow-plugin-gsfd): a host with neither
#      `timeout` nor `gtimeout` on PATH must say so — in the log (appended
#      AFTER the command's own output, never overwriting it) and via the
#      TIMEOUT_NOT_ENFORCED flag that checks_scope_note reads for the
#      operator-facing gate summary. Paired: 2a mutates PATH (the state
#      run_with_timeout reads via `command -v`) to remove both binaries,
#      with an explicit precondition proving the mutation landed; 2b is
#      the restore control — a working `timeout` stub present on PATH —
#      proving the marker does not fire unconditionally. Both legs call
#      the real, awk-extracted, shipped run_with_timeout.
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

# 2a. Absent leg: PATH restricted to a directory holding only `bash` (the
# one external binary run_with_timeout's unbounded branch actually needs —
# the test commands below use only shell builtins) and neither `timeout`
# nor `gtimeout`. The two precondition assertions prove this mutation of
# the STATE run_with_timeout reads (`command -v`) actually landed, per
# .claude/tests/README.md's pairing requirement (part 1, non-vacuity).
mkdir -p "$WORK/notimeout-bin"
REAL_BASH=$(command -v bash 2>/dev/null || true)
if [ -n "$REAL_BASH" ]; then
    ln -sf "$REAL_BASH" "$WORK/notimeout-bin/bash"
fi
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
assert_eq "2a: exit code still passes through unbounded (not swallowed by the trailing printf)" \
    "7" "$RC4"
assert_contains "2a: the command's own output is still captured" \
    "real-output-marker" "$O4_CONTENT"
assert_contains "2a: the log discloses the cap was NOT enforced" \
    "NOT ENFORCED" "$O4_CONTENT"
assert_eq "2a: the disclosure names the specific advertised duration" "yes" \
    "$(printf '%s' "$O4_CONTENT" | grep -qF 'the advertised 5s cap' && echo yes || echo no)"
assert_eq "2a: TIMEOUT_NOT_ENFORCED is set after an unbounded call" "1" "$FLAG4"
# Ordering: the marker must be APPENDED after the real output, never
# overwriting it — the specific hazard both truncations in run_with_timeout
# create for anything written too early (see that function's own header).
O4_REAL_LINE=$(grep -n 'real-output-marker' "$WORK/o4.log" 2>/dev/null | head -1 | cut -d: -f1)
O4_MARKER_LINE=$(grep -n 'NOT ENFORCED' "$WORK/o4.log" 2>/dev/null | head -1 | cut -d: -f1)
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
    "no" "$(printf '%s' "$O5_CONTENT" | grep -qF 'NOT ENFORCED' && echo yes || echo no)"
assert_eq "2b: TIMEOUT_NOT_ENFORCED is NOT set when a timeout binary is present" \
    "<unset>" "$FLAG5"

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
