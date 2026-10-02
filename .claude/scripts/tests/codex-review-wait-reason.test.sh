#!/bin/bash
# codex-review-wait-reason.test.sh — L1 unit fixture for codex-review.sh's
# `wait_fail_reason` (claude-workflow-plugin-nq5f / fkm.1.14 fold-in).
#
# THE DEFECT: every wait_id failure site used ONE message conflating two
# distinct outcomes — "the DEADLINE was reached while the server was still
# alive" (wait_id rc=1, a genuine timeout: Sol may still be generating) and
# "the server PROCESS EXITED before answering" (rc=2: not a timeout at all,
# the turn ended abnormally) — as "exceeded budget (or server exited)". A
# failed paid Sol turn therefore gave the caller no way to tell "still
# generating" from "server exited", which are different failures needing
# different follow-ups (raise the budget / accept the wait vs. investigate
# the Codex installation / $ERR).
#
# THE FUNCTION UNDER TEST IS EXTRACTED FROM THE SHIPPED SCRIPT by awk, never
# re-typed here — a re-typed copy would be a second definition free to drift
# from the one the driver actually calls (the same discipline
# doc-only-classifier.test.sh applies to is_doc_only_path).
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
CODEX_REVIEW="$PROJECT_DIR/.claude/scripts/codex-review.sh"

if [ ! -f "$CODEX_REVIEW" ]; then
    printf 'codex-review-wait-reason.test: script under test missing: %s\n' "$CODEX_REVIEW" >&2
    exit 2
fi

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    fi
}
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    unwanted needle present: %s\n    haystack: %s\n' "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

WORK=$(mktemp -d -t codex-review-wait-reason-test.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# extract_wait_fail_reason <src> -> the function body on stdout.
extract_wait_fail_reason() {
    awk '/^wait_fail_reason\(\) \{/,/^\}/' "$1"
}

FN_SRC=$(extract_wait_fail_reason "$CODEX_REVIEW")

echo "=== Section 1: extraction self-check ==="
assert_eq "1.1 the extraction is non-empty" "1" \
    "$([ -n "$FN_SRC" ] && echo 1 || echo 0)"
assert_eq "1.2 the extraction defines wait_fail_reason" "1" \
    "$(printf '%s' "$FN_SRC" | grep -c '^wait_fail_reason() {' | tr -d '[:space:]')"
assert_eq "1.3 the extraction is balanced (closes on its own line)" "1" \
    "$(printf '%s' "$FN_SRC" | grep -c '^}$' | tr -d '[:space:]')"
EXTRACTED_LIB="$WORK/wait-fail-reason-lib.sh"
{
    printf '#!/bin/bash\nset -u\n'
    printf '%s\n' "$FN_SRC"
} > "$EXTRACTED_LIB"
assert_eq "1.4 the extraction parses as bash" "0" \
    "$(bash -n "$EXTRACTED_LIB" 2>/dev/null && echo 0 || echo 1)"

# call_reason <rc> <label> <id> [timeout_s] [lib] -> the function's stdout, run
# in a subshell so TIMEOUT_S never leaks between calls. [lib] defaults to the
# real extraction; Section 3 reuses this with the mutated copy instead of
# duplicating the source/subshell plumbing (and its shellcheck suppressions).
call_reason() {
    local rc="$1" label="$2" id="$3" timeout="${4:-300}" lib="${5:-$EXTRACTED_LIB}"
    (
      # shellcheck disable=SC2034  # read by wait_fail_reason after `source` below
      TIMEOUT_S="$timeout"
      # shellcheck disable=SC1090  # the library path is a runtime-built temp file, not constant
      source "$lib"
      wait_fail_reason "$rc" "$label" "$id"
    )
}

echo ""
echo "=== Section 2: the three outcomes are TEXTUALLY DISTINCT ==="

TIMEOUT_MSG=$(call_reason 1 "codex tool call" 2 300)
SERVEREXIT_MSG=$(call_reason 2 "codex tool call" 2 300)
UNKNOWN_MSG=$(call_reason 9 "codex tool call" 2 300)

# 2.1 rc=1 (deadline reached, server still alive): says ALIVE, names the
# budget, never claims the process exited.
assert_contains "2.1 rc=1: names the server as STILL ALIVE" "STILL ALIVE" "$TIMEOUT_MSG"
assert_contains "2.1 rc=1: states the wall-clock budget" "300s wall-clock budget" "$TIMEOUT_MSG"
assert_not_contains "2.1 rc=1: does NOT claim the process exited" "EXITED" "$TIMEOUT_MSG"
assert_not_contains "2.1 rc=1: does NOT use the old conflated phrasing" "or server exited" "$TIMEOUT_MSG"

# 2.2 rc=2 (server process exited): says EXITED, explicitly says NOT a
# timeout, never claims a wall-clock budget was exceeded.
assert_contains "2.2 rc=2: names the server as EXITED" "EXITED before answering" "$SERVEREXIT_MSG"
assert_contains "2.2 rc=2: explicitly says NOT a timeout" "NOT a timeout" "$SERVEREXIT_MSG"
assert_not_contains "2.2 rc=2: does NOT claim STILL ALIVE" "STILL ALIVE" "$SERVEREXIT_MSG"
assert_not_contains "2.2 rc=2: does NOT cite a wall-clock budget" "wall-clock budget" "$SERVEREXIT_MSG"

# 2.3 the two real outcomes are never the same string.
assert_eq "2.3 rc=1 and rc=2 produce DIFFERENT text (the whole point of the fix)" "1" \
    "$([ "$TIMEOUT_MSG" != "$SERVEREXIT_MSG" ] && echo 1 || echo 0)"

# 2.4 an unrecognised rc is named rather than silently mapped to one of the two
# real outcomes (never fail toward a specific wrong diagnosis).
assert_contains "2.4 an unrecognised rc names itself rather than guessing" "wait_id rc=9" "$UNKNOWN_MSG"
assert_not_contains "2.4 ...and does not claim STILL ALIVE" "STILL ALIVE" "$UNKNOWN_MSG"
assert_not_contains "2.4 ...and does not claim EXITED" "EXITED" "$UNKNOWN_MSG"

# 2.5 the id is threaded through (which RPC frame never got a reply), so a
# reader can tell the init handshake from the main call from a corrective turn.
assert_contains "2.5 rc=1: names which request id never answered" "id=2 never answered" "$TIMEOUT_MSG"
assert_contains "2.5 rc=2: names which request id never got a reply" "id=2 never got a reply" "$SERVEREXIT_MSG"

echo ""
echo "=== Section 3: META (load-bearing) — remove the disambiguating arms ==="
# Delete the "1) printf..." and "2) printf..." case arms (each a two-line
# statement: the printf header, then its argument/;; continuation line) from
# a COPY of the extraction, leaving only the generic fallback arm. This is a
# clean, well-defined mutation of the REAL function — not a hand-authored
# rewrite — and it reproduces the OBSERVABLE property the original conflation
# had: rc=1 and rc=2 both lose their distinguishing language and read alike.
# Deleting a matched line AND unconditionally the one immediately following it
# is more robust here than a single multi-line regex, which is exactly what
# went wrong on the first attempt at this META (see the surrounding session
# notes) — recorded so the fragile approach is not silently reintroduced.
MUT_LIB="$WORK/wait-fail-reason-noarms.sh"
awk '
    /^[[:space:]]*[12]\) printf/ { skip = 1; next }
    skip { skip = 0; next }
    { print }
' "$EXTRACTED_LIB" > "$MUT_LIB"
assert_eq "3.1 META: the mutation applied (mutant differs from the extraction)" "1" \
    "$(cmp -s "$EXTRACTED_LIB" "$MUT_LIB" && echo 0 || echo 1)"
assert_eq "3.1b META: both disambiguating arms are gone from the mutant" "0" \
    "$(grep -cE '^[[:space:]]*[12]\) printf' "$MUT_LIB" | tr -d '[:space:]')"
assert_eq "3.1c META: the fallback arm survives (this is a targeted removal, not a gutting)" "1" \
    "$(grep -c '^[[:space:]]*\*) printf' "$MUT_LIB" | tr -d '[:space:]')"
assert_eq "3.2 META: mutated lib parses" "0" \
    "$(bash -n "$MUT_LIB" 2>/dev/null && echo 0 || echo 1)"

MUT_TIMEOUT_MSG=$(call_reason 1 "codex tool call" 2 300 "$MUT_LIB")
MUT_SERVEREXIT_MSG=$(call_reason 2 "codex tool call" 2 300 "$MUT_LIB")
# 3.3 WITHOUT the arms, BOTH rc=1 and rc=2 lose the disambiguating language
# entirely — reproducing the OBSERVABLE symptom of the pre-fix conflation
# (a reader cannot tell "still generating" from "server exited" from either
# message any more), even though the exact WORDING differs from the historical
# single hardcoded string (this mutation removes the distinction structurally
# rather than re-typing the old string, which is the more faithful test of
# "is section 2 sensitive to the case arms actually being there").
assert_not_contains "3.3 META: WITHOUT the arms, rc=1 no longer claims STILL ALIVE (repro (a))" \
    "STILL ALIVE" "$MUT_TIMEOUT_MSG"
assert_not_contains "3.3 META: ...nor does rc=2 claim EXITED (repro (b))" \
    "EXITED" "$MUT_SERVEREXIT_MSG"
# "Read alike": both now hit the SAME fallback TEMPLATE (only the embedded rc
# digit differs) — checked by stripping the one varying token and comparing
# what remains, rather than requiring byte-for-byte equality of two calls
# that were given different rc arguments on purpose.
MUT_TIMEOUT_SHAPE=$(printf '%s' "$MUT_TIMEOUT_MSG" | sed -E 's/rc=[0-9]+/rc=N/')
MUT_SERVEREXIT_SHAPE=$(printf '%s' "$MUT_SERVEREXIT_MSG" | sed -E 's/rc=[0-9]+/rc=N/')
assert_eq "3.3 META: rc=1 and rc=2 now read alike (same fallback template, rc digit aside)" \
    "1" "$([ "$MUT_TIMEOUT_SHAPE" = "$MUT_SERVEREXIT_SHAPE" ] && echo 1 || echo 0)"
# Discriminator: the mutant still ran the real function (not some earlier
# exit) — the fallback arm still names the rc it received.
assert_contains "3.4 META: the mutant ran the real function (fallback names rc=1)" \
    "wait_id rc=1" "$MUT_TIMEOUT_MSG"
assert_contains "3.4 META: ...and rc=2" "wait_id rc=2" "$MUT_SERVEREXIT_MSG"

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
