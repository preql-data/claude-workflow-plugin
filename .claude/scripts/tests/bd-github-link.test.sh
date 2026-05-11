#!/bin/bash
# Unit-test fixture for .claude/scripts/bd-github-link.sh
# Covers the three QA-blocking defects (claude-workflow-plugin-y4a.13):
#
#   - Defect 1 (claude-workflow-plugin-7o7) -- pr-create regex must accept
#     all four ref forms: `#N`, `owner/repo#N`, `https://.../issues/N`,
#     `https://.../pull/N`.
#   - Defect 2 (claude-workflow-plugin-vhm) -- comment body and idempotency
#     grep must agree, so re-firing the close path posts exactly one comment.
#   - Defect 3 (claude-workflow-plugin-68n) -- close-detection must capture
#     the tid in every documented `bd update`/`bd close` shape, including
#     the canonical `bd update <tid> --status closed`, the `=` form,
#     alt flag-order, multi-id, and the flag-before-id `bd close --reason=
#     "x" <tid>`.
#
# Conventions: this script follows phase5-synthetic-tests.sh -- plain bash,
# `set -u`, `assert_eq`/`assert_match` helpers, summary at the end. No bats.
#
# Stubs: `gh` is replaced with a PATH shim that records every invocation to
# a tempfile and returns success without contacting GitHub. `bd` runs for
# real against a sandbox project (init'd in a tempdir) so we can exercise
# the notes-append code path and clean up on exit.
#
# Exit codes:
#   0  all tests passed
#   1  at least one test failed
#
# Usage:
#   bash .claude/scripts/tests/bd-github-link.test.sh
#   bash .claude/scripts/tests/bd-github-link.test.sh --keep   # leave fixture

# shellcheck disable=SC2317
# Helper functions in this file (assert_eq, assert_match, cleanup, and the
# inline test scenarios further down) are invoked via name indirection — by
# the trap (cleanup) and by direct in-script calls whose reachability the
# static analyzer can't follow once `set -u` + early-exit + subshells are
# in play. Older shellchecks (0.9.x, what CI runs) emit SC2317 on every
# line inside those functions; the local 0.11.x is quieter but still flags
# some. Disabled file-wide because the fix-by-fix approach would mean
# annotating ~25 individual lines.

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
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

# shellcheck disable=SC2329  # retained as a test-helper for future probes.
assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' "$name" "$pattern" "$actual"
    fi
}

# ---------------------------------------------------------------------------
# Fixture setup.

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)/.."
PLUGIN_DIR="$(cd "$PLUGIN_DIR" && pwd)"
FIXTURE=$(mktemp -d -t bd-github-link-test.XXXXXX)
GH_LOG="$FIXTURE/gh-invocations.log"

# shellcheck disable=SC2329  # cleanup is invoked via `trap` below.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\n' "$FIXTURE"
    else
        rm -rf "$FIXTURE"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$FIXTURE/bin"

# Copy the script under test plus its dependencies.
cp "$PLUGIN_DIR/.claude/scripts/bd-github-link.sh" "$FIXTURE/.claude/scripts/"
cp "$PLUGIN_DIR/.claude/scripts/current-task.sh"   "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

# Hard preconditions.
if ! command -v bd >/dev/null 2>&1; then
    # Match the L2 spec convention: in BD_SHIM_ONLY=1 mode (CI runner,
    # no public bd installer), skip-with-log instead of hard-fail. The
    # whole fixture is bd-driven — there's no useful partial coverage.
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        echo "SKIPPED: bd-github-link.test.sh (bd not available; CI env BD_SHIM_ONLY=1)"
        exit 0
    fi
    echo "bd CLI not on PATH -- this fixture requires Beads."
    exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH -- bd-github-link.sh depends on jq."
    exit 1
fi

# Sandbox Beads project. We cd into it (the cd persists for the rest of
# the script -- not in a subshell -- so subsequent `bd create` etc. find
# the database) and clean up on trap.
#
# We also wrap `bd` through a PATH shim that injects `--no-daemon` to
# avoid the daemon-autostart race that can hang when many concurrent
# `bd` invocations land on a fresh tempdir database. (Beads 0.47.x can
# stack-overflow inside acquireStartLock under high concurrency from
# unrelated workspaces; the fix is to bypass the daemon entirely for
# this synthetic fixture.) The shim is layered ahead of the gh stub
# below so it must be created first.
#
# Find the real bd and remember its absolute path.
REAL_BD="$(command -v bd 2>/dev/null || true)"
[ -z "$REAL_BD" ] && { echo "FATAL: bd not on PATH at fixture time"; exit 1; }

cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
# bd shim: forward to real bd with --no-daemon to avoid concurrent
# daemon-autostart races during the test run.
exec "$REAL_BD" --no-daemon "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"

# Make the shim available *before* we invoke bd init, so the daemon
# autostart is suppressed end-to-end.
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1

# Fake a github.com `origin` so the script's GITHUB_REMOTE_OK check passes.
# Without this, the close-detection path correctly identifies the tid but
# silently skips the gh comment (logged as `skip post-link comment ...:
# origin not on github.com`), which is fine for production but makes our
# stub-gh-call assertions vacuous.
if command -v git >/dev/null 2>&1; then
    git -C "$FIXTURE" init -q 2>/dev/null || true
    git -C "$FIXTURE" remote add origin https://github.com/example/example.git \
        2>/dev/null || true
fi

export CLAUDE_PROJECT_DIR="$FIXTURE"

# Stub `gh` -- record args to log, exit 0 silently. The stub is on PATH
# *before* the real gh. Note: we keep $* (space-joined) as the argv
# representation in the log AND in the per-call inspection so the
# in-stub `grep -q -- '--json comments'` matches; iterating "$@" with
# %s\n placed each arg on its own line and broke the multi-token grep.
cat > "$FIXTURE/bin/gh" <<'STUB'
#!/bin/bash
# stub: log argv, return success. For `view --json comments`, return an
# empty comments array so the idempotency grep in the script sees no
# pre-existing match. ARGS is the full argv joined by single spaces
# so we can grep for multi-word flag pairs like `--json comments`.
ARGS="$*"
printf '%s\n' "$ARGS" >> "${GH_LOG_FILE}"
case "$1" in
    issue|pr)
        case "$2" in
            view)
                if echo "$ARGS" | grep -q -- '--json comments'; then
                    printf '%s\n' "[]"
                elif echo "$ARGS" | grep -q -- '--json url'; then
                    printf '%s\n' "https://github.com/example/example/pull/1"
                elif echo "$ARGS" | grep -q -- '--json number'; then
                    printf '%s\n' "1"
                else
                    printf '%s\n' "{}"
                fi
                exit 0 ;;
            comment) exit 0 ;;
        esac ;;
    repo)
        if [ "$2" = "view" ]; then
            printf '%s\n' "example/example"
            exit 0
        fi ;;
esac
exit 0
STUB
chmod +x "$FIXTURE/bin/gh"
export GH_LOG_FILE="$GH_LOG"
export PATH="$FIXTURE/bin:$PATH"

# Sanity: the stub takes precedence over any real gh.
ACTUAL_GH=$(command -v gh)
case "$ACTUAL_GH" in
    "$FIXTURE/bin/gh") : ;;
    *) echo "FATAL: gh stub not on PATH (got $ACTUAL_GH)"; exit 1 ;;
esac

# ---------------------------------------------------------------------------
# Helper: drive the hook-mode close-detection by invoking the script with
# a synthetic PostToolUse JSON envelope on stdin. We trace the side effect
# via sync-errors.log -- the script writes one entry per resolution path
# it takes -- and via the gh stub log.
#
# Because the script is pure-stderr-silent on success and all telemetry
# routes through .claude/.qa-tracking/sync-errors.log, we read that file
# to confirm the parser saw the tid we expected. The line shape is:
#   <ts>\t[bd-github-link]\t<msg containing $TASK_TO_CLOSE>
#
# The cleanest way to verify "the parser captured tid X" is to seed a
# real bd task with id X plus a `gh-link:` note and watch the script
# attempt to post (logged to the gh stub). If we did NOT seed gh-link,
# the script will instead try the branch-based fallback. For these
# parser-only assertions we use a different, simpler probe: we add a
# `--debug-emit-tid` short-circuit by setting env BD_GH_LINK_DEBUG=1.
#
# But the script under test does not have that hook today. Instead, we
# rely on the gh stub: when a tid is captured AND a gh-link is present
# on the task notes AND `gh issue/pr view` "succeeds" (our stub always
# does), the script calls `gh issue comment` or `gh pr comment` -- which
# the stub records. The presence of the comment call in the gh log is
# our evidence the parser found the tid.

run_close_hook() {
    local cmd="$1"
    local payload
    payload=$(jq -n --arg c "$cmd" \
        '{tool_name:"Bash", tool_input:{command:$c}}')
    printf '%s' "$payload" | bash "$FIXTURE/.claude/scripts/bd-github-link.sh" \
        >/dev/null 2>&1 || true
}

# A second probe: check sync-errors.log for the literal tid string. The
# script logs "skipping duplicate gh comment for <tid>..." on idempotent
# re-fires, and "posted gh link comment for <tid>..." on first fire.
# shellcheck disable=SC2329  # retained as a test-helper for future probes.
sync_log_contains_tid() {
    local tid="$1"
    grep -qE "[[:space:]]${tid}[[:space:]]|[[:space:]]${tid}\$|${tid}\$" \
        "$FIXTURE/.claude/.qa-tracking/sync-errors.log" 2>/dev/null
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: close-detection captures tid (Defect 3) ==="

# We seed two real Beads tasks: one for the canonical/equals/alt-order
# probes (TID_A) and one for multi-id (TID_C). Each carries a `gh-link:`
# note pointing at example/example#1 so the script will try to post via
# the stub when the parser correctly captures the tid.
TID_A=$(bd create "Defect 3 close test A" -t task -p 1 --json | jq -r '.id')
TID_B=$(bd create "Defect 3 close test B" -t task -p 1 --json | jq -r '.id')
TID_C=$(bd create "Defect 3 close test C" -t task -p 1 --json | jq -r '.id')

bd update "$TID_A" --notes "gh-link: example/example#1" >/dev/null 2>&1
bd update "$TID_B" --notes "gh-link: example/example#1" >/dev/null 2>&1
bd update "$TID_C" --notes "gh-link: example/example#1" >/dev/null 2>&1

# Helper: count how many times the gh stub was called with `comment <num>`
# referencing a specific tid in the body. The body is built by the script
# from $tid; we grep the gh log for the literal tid string. Always emits
# a single integer with no trailing data even when grep finds nothing.
count_gh_comments_for() {
    local tid="$1"
    local n
    n=$(grep -cE "comment [0-9]+ --repo .* --body .*${tid}" "$GH_LOG" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# Reset the gh log between shapes so we can attribute calls.
reset_gh_log() {
    : > "$GH_LOG"
    rm -f "$FIXTURE/.claude/.qa-tracking/sync-errors.log"
}

# 1.1 Canonical: bd update <tid> --status closed
reset_gh_log
run_close_hook "bd update $TID_A --status closed"
N=$(count_gh_comments_for "$TID_A" | tr -d ' ')
assert_eq "close: canonical 'bd update <tid> --status closed'" "1" "$N"

# 1.2 Equals form: bd update <tid> --status=closed
reset_gh_log
run_close_hook "bd update $TID_A --status=closed"
N=$(count_gh_comments_for "$TID_A" | tr -d ' ')
assert_eq "close: equals form 'bd update <tid> --status=closed'" "1" "$N"

# 1.3 Alt order: bd update --status closed <tid>
reset_gh_log
run_close_hook "bd update --status closed $TID_A"
N=$(count_gh_comments_for "$TID_A" | tr -d ' ')
assert_eq "close: alt-order 'bd update --status closed <tid>'" "1" "$N"

# 1.4 Alt order with extra flags: bd update --reason=foo --status closed <tid>
reset_gh_log
run_close_hook "bd update --reason=foo --status closed $TID_A"
N=$(count_gh_comments_for "$TID_A" | tr -d ' ')
assert_eq "close: alt-order with extra flag" "1" "$N"

# 1.5 bd close <tid>
reset_gh_log
run_close_hook "bd close $TID_B"
N=$(count_gh_comments_for "$TID_B" | tr -d ' ')
assert_eq "close: 'bd close <tid>'" "1" "$N"

# 1.6 bd close --reason="x" <tid>  (flag with attached value, then tid)
reset_gh_log
run_close_hook "bd close --reason=\"x\" $TID_B"
N=$(count_gh_comments_for "$TID_B" | tr -d ' ')
assert_eq "close: 'bd close --reason=\"x\" <tid>'" "1" "$N"

# 1.7 Multi-id: bd close <tid1> <tid2>  -- first wins
reset_gh_log
run_close_hook "bd close $TID_C $TID_A"
N1=$(count_gh_comments_for "$TID_C" | tr -d ' ')
N2=$(count_gh_comments_for "$TID_A" | tr -d ' ')
assert_eq "close: multi-id picks first tid" "1" "$N1"
assert_eq "close: multi-id ignores second tid" "0" "$N2"

# 1.8 Negative: bd update XYZ --status open  (not a close)
reset_gh_log
run_close_hook "bd update $TID_A --status open"
N=$(count_gh_comments_for "$TID_A" | tr -d ' ')
assert_eq "close: --status open is NOT a close" "0" "$N"

# 1.9 Negative: completely unrelated command
reset_gh_log
run_close_hook "echo hello world"
TOTAL=$(wc -l < "$GH_LOG" 2>/dev/null | tr -d ' ')
assert_eq "close: unrelated command does not call gh" "0" "$TOTAL"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: pr-create accepts all 4 ref forms (Defect 1) ==="

TID_PR=$(bd create "Defect 1 pr-create test" -t task -p 1 --json | jq -r '.id')
bash "$FIXTURE/.claude/scripts/current-task.sh" set "$TID_PR" >/dev/null 2>&1

# Each ref form goes through manual mode pr-create against a tempfile,
# then we read the task notes and assert the normalized gh-link line
# appears.

probe_pr_create() {
    local ref_line="$1" expected_norm="$2" name="$3"
    local body_file
    body_file=$(mktemp -t bd-pr-body.XXXXXX)
    printf '%s\n' "$ref_line" > "$body_file"
    bash "$FIXTURE/.claude/scripts/bd-github-link.sh" --manual pr-create "$body_file" \
        >/dev/null 2>&1 || true
    local notes
    notes=$(bd show "$TID_PR" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].notes else .notes end // ""')
    rm -f "$body_file"
    if printf '%s' "$notes" | grep -qF "gh-link: $expected_norm"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected gh-link: %s\n    notes:\n%s\n' \
            "$name" "$expected_norm" "$notes"
    fi
}

# 2.1 #N short form
probe_pr_create "Closes #42" "#42" "pr-create: 'Closes #N' short form"

# Reset task notes so subsequent probes start clean. (append_gh_link_to_notes
# is idempotent on the SAME ref but additive across DIFFERENT refs, so we
# wipe between probes for clarity.)
bd update "$TID_PR" --notes "" >/dev/null 2>&1

# 2.2 owner/repo#N
probe_pr_create "Fixes owner/repo#7" "owner/repo#7" "pr-create: 'Fixes owner/repo#N'"
bd update "$TID_PR" --notes "" >/dev/null 2>&1

# 2.3 issues URL
probe_pr_create "Resolves https://github.com/x/y/issues/3" "x/y#3" \
    "pr-create: 'Resolves https://.../issues/N'"
bd update "$TID_PR" --notes "" >/dev/null 2>&1

# 2.4 pull URL
probe_pr_create "Closes https://github.com/x/y/pull/9" "x/y#9" \
    "pr-create: 'Closes https://.../pull/N'"
bd update "$TID_PR" --notes "" >/dev/null 2>&1

# Negative: a verb that isn't in our keyword set
body_neg=$(mktemp)
printf 'See #99 for context\n' > "$body_neg"
bash "$FIXTURE/.claude/scripts/bd-github-link.sh" --manual pr-create "$body_neg" >/dev/null 2>&1 || true
notes=$(bd show "$TID_PR" --json 2>/dev/null \
    | jq -r 'if type == "array" then .[0].notes else .notes end // ""')
rm -f "$body_neg"
if ! printf '%s' "$notes" | grep -qF "gh-link: #99"; then
    PASS=$((PASS + 1))
    echo "  PASS: pr-create: bare 'See #99' does NOT add gh-link"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("pr-create: bare 'See #99' must not add gh-link")
    echo "  FAIL: pr-create: bare 'See #99' incorrectly added gh-link"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: idempotency (Defect 2) ==="

# Re-fire the same close hook twice for a task that has a gh-link. The
# stub returns an empty comments array on the FIRST `gh issue view --json
# comments` call (so the script posts) and we then mutate the stub so the
# SECOND call sees the just-posted comment in the listing -- otherwise we
# can never test the idempotency path against a stub.
#
# Approach: replace the stub with one that returns the bd-link line as if
# it were the only comment on the issue, and assert the second close fire
# does NOT post (count of `gh issue comment` invocations stays at 1).

TID_IDEM=$(bd create "Defect 2 idempotency test" -t task -p 1 --json | jq -r '.id')
bd update "$TID_IDEM" --notes "gh-link: example/example#1" >/dev/null 2>&1

# Helper: count `gh ... comment` invocations regardless of tid in body.
count_total_gh_comments() {
    local n
    n=$(grep -cE "^(issue|pr) comment " "$GH_LOG" 2>/dev/null) || n=0
    printf '%s' "$n"
}

# Stub variant 1: stub claims a bd-link comment ALREADY exists on the
# issue. The script's idempotency grep should match it on every fire,
# so zero comment posts occur. This proves Defect 2's fix: the body
# emitted by gh_link_comment_body() byte-aligns with the grep -F
# pattern in post_link_comment(). If they ever drift again (e.g.,
# someone re-adds the bold markers around the backtick), this test
# fails immediately.
#
# Implementation note: the heredoc uses an UNQUOTED delimiter so the
# outer shell can interpolate $TID_IDEM into the printf format. The
# literal backticks in the body need to escape past TWO layers (heredoc
# + printf format string), so we write \\\` -- which becomes \` in the
# stub file, and printf treats \` as just `.
cat > "$FIXTURE/bin/gh" <<STUB
#!/bin/bash
ARGS="\$*"
printf '%s\n' "\$ARGS" >> "\${GH_LOG_FILE}"
case "\$1" in
    issue|pr)
        case "\$2" in
            view)
                if echo "\$ARGS" | grep -q -- '--json comments'; then
                    printf 'bd-link: tracked as \`%s\` (claude-workflow-plugin Beads task)\n' "$TID_IDEM"
                elif echo "\$ARGS" | grep -q -- '--json url'; then
                    printf '%s\n' "https://github.com/example/example/pull/1"
                elif echo "\$ARGS" | grep -q -- '--json number'; then
                    printf '%s\n' "1"
                else
                    printf '%s\n' "{}"
                fi
                exit 0 ;;
            comment) exit 0 ;;
        esac ;;
    repo)
        [ "\$2" = "view" ] && { printf '%s\n' "example/example"; exit 0; }
        ;;
esac
exit 0
STUB
chmod +x "$FIXTURE/bin/gh"

reset_gh_log
run_close_hook "bd update $TID_IDEM --status closed"
run_close_hook "bd update $TID_IDEM --status closed"
COMMENT_CALLS=$(count_total_gh_comments)
assert_eq "idempotency: pre-existing bd-link blocks all posts (body/grep agree)" "0" "$COMMENT_CALLS"

# Stub variant 2: stateful. Returns empty comments on the first view,
# then replays the canonical body once a comment has been posted. This
# exercises the end-to-end "fire many, post once" claim.
cat > "$FIXTURE/bin/gh" <<STUB
#!/bin/bash
ARGS="\$*"
printf '%s\n' "\$ARGS" >> "\${GH_LOG_FILE}"
STATE_FILE="\${GH_LOG_FILE}.posted"
case "\$1" in
    issue|pr)
        case "\$2" in
            view)
                if echo "\$ARGS" | grep -q -- '--json comments'; then
                    if [ -f "\$STATE_FILE" ]; then
                        printf 'bd-link: tracked as \`%s\` (claude-workflow-plugin Beads task)\n' "$TID_IDEM"
                    else
                        printf '%s\n' ""
                    fi
                elif echo "\$ARGS" | grep -q -- '--json url'; then
                    printf '%s\n' "https://github.com/example/example/pull/1"
                elif echo "\$ARGS" | grep -q -- '--json number'; then
                    printf '%s\n' "1"
                else
                    printf '%s\n' "{}"
                fi
                exit 0 ;;
            comment)
                touch "\$STATE_FILE"
                exit 0 ;;
        esac ;;
    repo)
        [ "\$2" = "view" ] && { printf '%s\n' "example/example"; exit 0; }
        ;;
esac
exit 0
STUB
chmod +x "$FIXTURE/bin/gh"

reset_gh_log
rm -f "$GH_LOG.posted"
run_close_hook "bd update $TID_IDEM --status closed"
run_close_hook "bd update $TID_IDEM --status closed"
run_close_hook "bd update $TID_IDEM --status closed"
COMMENT_CALLS=$(count_total_gh_comments)
assert_eq "idempotency: 3 close fires => exactly 1 post" "1" "$COMMENT_CALLS"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: graceful degradation ==="

# 4.1 Tool != Bash -> emits {} silently
OUT=$(jq -n '{tool_name:"Read", tool_input:{file_path:"/x"}}' \
    | bash "$FIXTURE/.claude/scripts/bd-github-link.sh" 2>/dev/null)
assert_eq "graceful: non-Bash tool emits {} envelope" "{}" "$OUT"

# 4.2 Empty stdin -> emits {}
OUT=$(printf '' | bash "$FIXTURE/.claude/scripts/bd-github-link.sh" 2>/dev/null)
assert_eq "graceful: empty stdin emits {} envelope" "{}" "$OUT"

# 4.3 Manual mode rejects unknown action
if ! bash "$FIXTURE/.claude/scripts/bd-github-link.sh" --manual nonsense 2>/dev/null; then
    PASS=$((PASS + 1))
    echo "  PASS: graceful: --manual nonsense exits non-zero"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("graceful: --manual nonsense exits non-zero")
    echo "  FAIL: graceful: --manual nonsense should exit non-zero"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Summary ==="
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    echo "Failed tests:"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
exit 0
