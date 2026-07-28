#!/bin/bash
# workflow-doctor.test.sh — L1 unit fixture for .claude/scripts/workflow-doctor.sh
# (v4.1 / claude-workflow-plugin-0fc, epic 2br).
#
# The doctor is the repo's ONLY functional post-install verification surface,
# so its own contract has to be pinned hard. Three properties matter most:
#
#   1. THE CHECK REGISTRY IS THE TEST CONTRACT. Other specs and the
#      /workflow-doctor command assert on the eleven names by name, so the
#      DOCTOR_CHECK_NAMES sentinel block, the runner's case arms, --help and a
#      real --json-out run must all agree exactly. A name that exists in one
#      place and not another is a check that silently never runs.
#
#   2. --skip REJECTS UNKNOWN NAMES. A typo'd skip that silently ran the check
#      (or silently skipped nothing) makes the exit code mean something other
#      than what the operator asked for. And a skipped check must count as
#      SKIPPED, never as passed — otherwise `--skip` is a way to fake green.
#
#   3. THE SANDBOX DESIGN IS LOAD-BEARING AND IS TESTED AS SUCH. session-start.sh
#      wipes .qa-tracking/approved, truncates changed-files.txt, refreshes the
#      gate baseline and calls model-select.sh apply (which REWRITES AGENT
#      FRONTMATTER PINS). A doctor that ran those against the live tree would
#      clear the operator's own QA approval as a side effect of a health check.
#      Section 5 asserts the live repo is byte-identical after a run, and its
#      META proves the preservation comes from the sandbox indirection by
#      showing the SAME seeded state IS destroyed when session-start.sh is
#      invoked directly.
#
# META-TESTs (all anchored to unique TEXT patterns, never line numbers, per
# LESSONS.md; all operate on separate mutant/fixture COPIES so the repo tree
# and each other's fixtures are never poisoned):
#
#   META-TEST 1  removing a name from the DOCTOR_CHECK_NAMES sentinel makes the
#                sentinel-vs-case-arms comparison this spec uses FAIL.
#   META-TEST 2  deleting the --skip validation loop makes the doctor ACCEPT a
#                bogus skip name (exit != 2), proving the rejection is real.
#   META-TEST 3  the seeded gate state the doctor leaves alone IS destroyed by
#                invoking session-start.sh directly — so Section 5's
#                "unchanged" is caused by the sandbox, not by inertness.
#   META-TEST 4  bumping bd-mcp's DOCTOR_TOOL_COUNTS entry by one flips mcp_bd
#                from PASS to FAIL, proving the count check is EXACT equality
#                and not a >= bound.
#   META-TEST 5  a target whose SKILL.md is the fallback-stub shape FAILS the
#                session_start check, while the same target with the real
#                SKILL.md PASSES it.
#
# Exit codes: 0 all assertions pass, 1 otherwise, 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
DOCTOR="$PROJECT_DIR/.claude/scripts/workflow-doctor.sh"

if [ ! -f "$DOCTOR" ]; then
    printf 'workflow-doctor.test: script under test missing: %s\n' "$DOCTOR" >&2
    exit 2
fi
for tool in jq awk sed; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'workflow-doctor.test: %s is required\n' "$tool" >&2
        exit 2
    }
done

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
        printf '  FAIL: %s\n    missing substring: %s\n' "$name" "$needle"
    fi
}

WORK=$(mktemp -d -t workflow-doctor-test.XXXXXX) || {
    printf 'workflow-doctor.test: mktemp failed\n' >&2
    exit 2
}
# cleanup runs only via the EXIT trap; the analyzer can't see that indirection.
# shellcheck disable=SC2329,SC2317
cleanup() { [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# EVERY name in the registry, so a "skip everything" run is cheap and
# environment-independent. Derived from the sentinel so this helper cannot
# drift away from the thing under test.
sentinel_names() {
    sed -n 's/^DOCTOR_CHECK_NAMES="\(.*\)"$/\1/p' "$1" | head -1
}

# The runner's case arms, i.e. the names that actually have an implementation
# bound. Anchored on the unique text `case "$_check" in`, not a line number.
case_arm_names() {
    awk '/^    case "\$_check" in$/ {inb=1; next}
         inb && /^    esac$/ {exit}
         inb {print}' "$1" \
        | sed -n 's/^        \([a-z_]*\)).*/\1/p' | tr '\n' ' ' | sed 's/ *$//'
}

# mk_target <dir> — a minimal but COMPLETE install target: everything the
# doctor's checks read, nothing else. Built from the live repo so the shipped
# scripts under test are the real ones.
mk_target() {
    local d="$1"
    mkdir -p "$d/.claude/.qa-tracking" "$d/.beads" || return 1
    cp -R "$PROJECT_DIR/.claude/agents"  "$d/.claude/" 2>/dev/null || true
    cp -R "$PROJECT_DIR/.claude/skills"  "$d/.claude/" 2>/dev/null || true
    cp -R "$PROJECT_DIR/.claude/hooks"   "$d/.claude/" 2>/dev/null || true
    mkdir -p "$d/.claude/scripts"
    local s
    for s in "$PROJECT_DIR"/.claude/scripts/*.sh; do
        [ -f "$s" ] && cp "$s" "$d/.claude/scripts/" 2>/dev/null
    done
    chmod +x "$d/.claude/scripts"/*.sh 2>/dev/null || true
    cp "$PROJECT_DIR/.claude/settings.json" "$d/.claude/" 2>/dev/null || true
    cp "$PROJECT_DIR/.mcp.json" "$d/" 2>/dev/null || true
    mkdir -p "$d/.claude-plugin"
    cp "$PROJECT_DIR/.claude-plugin/plugin.json" "$d/.claude-plugin/" 2>/dev/null || true
    (
        cd "$d" || exit 1
        git init -q >/dev/null 2>&1
        git -c user.email=t@example.invalid -c user.name=t \
            commit --allow-empty -q -m base >/dev/null 2>&1
    ) || true
    return 0
}

# seed_gate_state <dir> — the four transient gate artifacts session-start.sh
# destroys. Section 5 and META-TEST 3 both use this so the two paths are
# compared over IDENTICAL input.
seed_gate_state() {
    local d="$1/.claude/.qa-tracking"
    mkdir -p "$d"
    printf 'SEEDED-APPROVAL-DO-NOT-DESTROY\n'   > "$d/approved"
    printf 'src/seeded-change.ts\n'             > "$d/changed-files.txt"
    printf '7\n'                                > "$d/edit-count"
    printf 'seeded-task-id\n'                   > "$d/current-task"
}

# gate_state_fingerprint <dir> — one line per seeded artifact: name, whether it
# still exists, and its bytes. Absence is recorded explicitly so a DELETED file
# is visible rather than silently matching another absent file.
gate_state_fingerprint() {
    local d="$1/.claude/.qa-tracking" f
    for f in approved changed-files.txt edit-count current-task; do
        if [ -f "$d/$f" ]; then
            printf '%s\tpresent\t%s\n' "$f" "$(wc -c < "$d/$f" | tr -d ' ')"
        else
            printf '%s\tABSENT\t-\n' "$f"
        fi
    done
}

# doctor_run <doctor-script> <target> <json-out> [args...] -> sets DOCTOR_RC,
# DOCTOR_OUT (combined stdout+stderr text).
DOCTOR_RC=0
DOCTOR_OUT=""
doctor_run() {
    local script="$1" target="$2" json="$3"; shift 3
    DOCTOR_RC=0
    if [ -n "$json" ]; then
        DOCTOR_OUT=$(bash "$script" --target "$target" --json-out "$json" "$@" 2>&1) \
            || DOCTOR_RC=$?
    else
        DOCTOR_OUT=$(bash "$script" --target "$target" "$@" 2>&1) || DOCTOR_RC=$?
    fi
}

# status_of <json> <check-name>
status_of() {
    jq -r --arg n "$2" '(.checks[] | select(.name == $n) | .status) // "<absent>"' \
        "$1" 2>/dev/null || echo "<jq-error>"
}

# has_word <space-separated-list> <word> — print "true"/"false". A function
# rather than an inline `case`: bash 3.2's command-substitution parser mis-reads
# a case pattern's `)` as the closing paren of `$( ... )`, so `$(case ... esac)`
# is a syntax error there (observed, not theoretical).
has_word() {
    case " $1 " in
        *" $2 "*) printf 'true' ;;
        *)        printf 'false' ;;
    esac
}

# sort_words — read a space-separated list on stdin, print it sorted and
# space-joined. Lets the set comparisons below be about SET equality without
# relying on unquoted word splitting.
sort_words() {
    tr ' ' '\n' | grep -v '^$' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# all_but <name...> — the comma-joined skip list covering every registry name
# EXCEPT the ones given. Lets a single-check run finish in ~2s instead of ~12s.
all_but() {
    local keep=" $* " out="" n
    for n in $(sentinel_names "$DOCTOR"); do
        case "$keep" in *" $n "*) continue ;; esac
        out="$out,$n"
    done
    printf '%s' "${out#,}"
}

# ===========================================================================
echo "=== Section 1: --help and usage errors ==="

HELP_RC=0
HELP_OUT=$(bash "$DOCTOR" --help 2>&1) || HELP_RC=$?
assert_eq "help: --help exits 0" "0" "$HELP_RC"
assert_contains "help: documents the air-gapped npm ci recipe" \
    "npm ci --omit=dev --ignore-scripts" "$HELP_OUT"
assert_contains "help: the air-gap recipe names the bd-mcp server dir" \
    ".claude/mcp/bd-mcp" "$HELP_OUT"
assert_contains "help: the air-gap recipe names the code-graph-mcp server dir" \
    ".claude/mcp/code-graph-mcp" "$HELP_OUT"
assert_contains "help: documents the exit-code contract" "exit 2" "$HELP_OUT"

# Every registry name must be documented, or an operator cannot use --skip.
HELP_MISSING=""
for n in $(sentinel_names "$DOCTOR"); do
    printf '%s' "$HELP_OUT" | grep -qF "$n" || HELP_MISSING="$HELP_MISSING $n"
done
assert_eq "help: every registry check name appears in --help" "" "$HELP_MISSING"

BAD_RC=0
BAD_OUT=$(bash "$DOCTOR" --no-such-flag 2>&1) || BAD_RC=$?
assert_eq "usage: an unrecognised flag exits 2" "2" "$BAD_RC"
assert_contains "usage: the refusal names the offending flag" \
    "--no-such-flag" "$BAD_OUT"

MISSVAL_RC=0
bash "$DOCTOR" --target >/dev/null 2>&1 || MISSVAL_RC=$?
assert_eq "usage: --target with no value exits 2" "2" "$MISSVAL_RC"

MISSJSON_RC=0
bash "$DOCTOR" --json-out >/dev/null 2>&1 || MISSJSON_RC=$?
assert_eq "usage: --json-out with no value exits 2" "2" "$MISSJSON_RC"

NODIR_RC=0
NODIR_OUT=$(bash "$DOCTOR" --target "$WORK/definitely-not-here" 2>&1) || NODIR_RC=$?
assert_eq "usage: --target pointing at a nonexistent dir exits 2" "2" "$NODIR_RC"
assert_contains "usage: the refusal says the target is not a directory" \
    "not a directory" "$NODIR_OUT"

# THE skip contract: an unknown name is REJECTED, not ignored.
SKIPBAD_RC=0
SKIPBAD_OUT=$(bash "$DOCTOR" --target "$PROJECT_DIR" --skip gate_stopp 2>&1) || SKIPBAD_RC=$?
assert_eq "usage: --skip with an unknown name exits 2 (rejected, not ignored)" \
    "2" "$SKIPBAD_RC"
assert_contains "usage: the --skip refusal names the unknown check" \
    "gate_stopp" "$SKIPBAD_OUT"
assert_contains "usage: the --skip refusal lists the known check names" \
    "known:" "$SKIPBAD_OUT"

SKIPMIX_RC=0
bash "$DOCTOR" --target "$PROJECT_DIR" --skip deps,not_a_check >/dev/null 2>&1 || SKIPMIX_RC=$?
assert_eq "usage: one bad name in an otherwise-valid --skip list still exits 2" \
    "2" "$SKIPMIX_RC"

SKIPEMPTY_RC=0
bash "$DOCTOR" --target "$PROJECT_DIR" --skip "," >/dev/null 2>&1 || SKIPEMPTY_RC=$?
assert_eq "usage: an empty --skip list exits 2" "2" "$SKIPEMPTY_RC"

# ===========================================================================
echo ""
echo "=== Section 1b: /workflow-doctor command registration ==="
#
# LESSONS.md: "New agent files must be registered in .claude-plugin/plugin.json
# in the same commit that creates them; an unregistered agent is silently
# invisible to the SDK — no error surfaces." Commands have the same property and
# nothing in the suite asserted it generically. `make manifest-validate` checks
# the manifest's SCHEMA, not that the declared paths exist on disk.

MANIFEST="$PROJECT_DIR/.claude-plugin/plugin.json"
CMD_FILE="$PROJECT_DIR/.claude/commands/workflow-doctor.md"

assert_eq "command: .claude/commands/workflow-doctor.md exists" "true" \
    "$([ -f "$CMD_FILE" ] && echo true || echo false)"
assert_eq "command: plugin.json commands[] registers ./.claude/commands/workflow-doctor.md" "true" \
    "$(jq -r '[(.commands // [])[] | select(. == "./.claude/commands/workflow-doctor.md")] | length == 1' \
        "$MANIFEST" 2>/dev/null || echo false)"

# Generic: EVERY declared command must resolve, so the next command added
# cannot go missing the way grader.md did for two releases.
CMD_MISSING=""
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case "$rel" in ./*) rel="${rel#./}" ;; esac
    [ -f "$PROJECT_DIR/$rel" ] || CMD_MISSING="$CMD_MISSING $rel"
done <<EOF
$(jq -r '(.commands // [])[]' "$MANIFEST" 2>/dev/null || echo "")
EOF
assert_eq "command: every plugin.json commands[] entry resolves to a file on disk" "" "$CMD_MISSING"

# Shape parity with the other command files: YAML frontmatter with description.
CMD_FM=$(awk 'NR==1 && /^---[[:space:]]*$/ {inb=1; next}
              inb && /^---[[:space:]]*$/ {exit}
              inb {print}' "$CMD_FILE" 2>/dev/null)
assert_eq "command: workflow-doctor.md carries a description: frontmatter key" "true" \
    "$(printf '%s\n' "$CMD_FM" | grep -q '^description:' && echo true || echo false)"
# The command must actually invoke the script; a command file that documents a
# script it never calls is the /workflow-model failure mode in miniature.
assert_contains "command: workflow-doctor.md invokes .claude/scripts/workflow-doctor.sh" \
    ".claude/scripts/workflow-doctor.sh" "$(cat "$CMD_FILE" 2>/dev/null)"

# CRITICAL for this change: install.sh's plugin_json_version() is a jq-free sed
# anchored on EXACTLY TWO leading spaces. Adding a nested commands[] entry must
# not have reformatted the manifest — if it did, the installer's version banner
# silently degrades to an unnumbered product name.
BRAND_VERSION=$(sed -n 's/^  "version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$MANIFEST" | head -1)
assert_eq "command: install.sh's 2-space-anchored version sed still resolves after the manifest edit" \
    "$(jq -r '.version' "$MANIFEST" 2>/dev/null)" "$BRAND_VERSION"

# ===========================================================================
echo ""
echo "=== Section 2: the check registry is one contract in four places ==="

SENTINEL_BEGIN=$(grep -c '^# BEGIN DOCTOR_CHECK_NAMES' "$DOCTOR" || true)
SENTINEL_END=$(grep -c '^# END DOCTOR_CHECK_NAMES' "$DOCTOR" || true)
assert_eq "registry: exactly one BEGIN DOCTOR_CHECK_NAMES sentinel" "1" "$SENTINEL_BEGIN"
assert_eq "registry: exactly one END DOCTOR_CHECK_NAMES sentinel" "1" "$SENTINEL_END"

SENTINEL_LIST=$(sentinel_names "$DOCTOR")
SENTINEL_COUNT=$(printf '%s' "$SENTINEL_LIST" | wc -w | tr -d ' ')
assert_eq "registry: the sentinel declares 11 check names" "11" "$SENTINEL_COUNT"

# Sorted comparison so the assertion is about SET equality, not ordering.
SENTINEL_SORTED=$(printf '%s' "$SENTINEL_LIST" | sort_words)
CASE_SORTED=$(case_arm_names "$DOCTOR" | sort_words)
assert_eq "registry: sentinel names == runner case arms (no unbound or unreachable check)" \
    "$SENTINEL_SORTED" "$CASE_SORTED"

# The two mcp_* names the tool-count table implies must be registered.
TOOLS_TABLE=$(sed -n 's/^DOCTOR_TOOL_COUNTS="\(.*\)"$/\1/p' "$DOCTOR" | head -1)
IMPLIED_MISSING=""
for pair in $TOOLS_TABLE; do
    dir="${pair%%:*}"
    implied="mcp_$(printf '%s' "${dir%-mcp}" | tr '-' '_')"
    case " $SENTINEL_LIST " in
        *" $implied "*) ;;
        *) IMPLIED_MISSING="$IMPLIED_MISSING $implied" ;;
    esac
done
assert_eq "registry: every DOCTOR_TOOL_COUNTS server implies a registered mcp_* check" \
    "" "$IMPLIED_MISSING"

# ===========================================================================
echo ""
echo "=== Section 3: --json-out schema, over a real full run ==="

FULL_TARGET="$WORK/target-full"
mk_target "$FULL_TARGET"
FULL_JSON="$WORK/full.json"
doctor_run "$DOCTOR" "$FULL_TARGET" "$FULL_JSON"
# NOTE: no assertion on DOCTOR_RC here. Whether the full run is green depends
# on the host (bd on PATH, node_modules installed), and this section is about
# the report's SHAPE, which must hold either way.

assert_eq "json: the report is a single JSON object" "object" \
    "$(jq -r 'type' "$FULL_JSON" 2>/dev/null || echo "<invalid>")"
assert_eq "json: .checks is an array" "array" \
    "$(jq -r '.checks | type' "$FULL_JSON" 2>/dev/null || echo "<invalid>")"
assert_eq "json: .checks has one entry per registry name" "$SENTINEL_COUNT" \
    "$(jq -r '.checks | length' "$FULL_JSON" 2>/dev/null || echo "0")"
assert_eq "json: .checks names match the registry, in registry order" \
    "$SENTINEL_LIST" \
    "$(jq -r '[.checks[].name] | join(" ")' "$FULL_JSON" 2>/dev/null || echo "")"
assert_eq "json: every check carries all four keys (name/status/detail/fix)" "" \
    "$(jq -r '[.checks[] | select((has("name") and has("status") and has("detail") and has("fix")) | not) | .name // "<unnamed>"] | join(",")' "$FULL_JSON" 2>/dev/null || echo "<jq-error>")"
assert_eq "json: every status is PASS, FAIL or SKIP" "" \
    "$(jq -r '[.checks[] | select(.status != "PASS" and .status != "FAIL" and .status != "SKIP") | .name] | join(",")' "$FULL_JSON" 2>/dev/null || echo "<jq-error>")"
assert_eq "json: every FAIL carries a non-empty fix" "" \
    "$(jq -r '[.checks[] | select(.status == "FAIL" and ((.fix // "") | length) == 0) | .name] | join(",")' "$FULL_JSON" 2>/dev/null || echo "<jq-error>")"
assert_eq "json: every check carries a non-empty detail" "" \
    "$(jq -r '[.checks[] | select(((.detail // "") | length) == 0) | .name] | join(",")' "$FULL_JSON" 2>/dev/null || echo "<jq-error>")"
assert_eq "json: passed + failed + skipped == the number of checks" "true" \
    "$(jq -r '(.passed + .failed + .skipped) == (.checks | length)' "$FULL_JSON" 2>/dev/null || echo "false")"
assert_eq "json: .passed equals the number of PASS entries" "true" \
    "$(jq -r '.passed == ([.checks[] | select(.status == "PASS")] | length)' "$FULL_JSON" 2>/dev/null || echo "false")"
assert_eq "json: .failed equals the number of FAIL entries" "true" \
    "$(jq -r '.failed == ([.checks[] | select(.status == "FAIL")] | length)' "$FULL_JSON" 2>/dev/null || echo "false")"

# The human surface: one status line per check, by name, and a fix line under
# every FAIL.
HUMAN_LINES=$(printf '%s\n' "$DOCTOR_OUT" | grep -cE '^(PASS|FAIL|SKIP) ' || true)
assert_eq "human: one PASS/FAIL/SKIP line per check" "$SENTINEL_COUNT" \
    "$(printf '%s' "${HUMAN_LINES:-0}" | tr -d ' ')"
HUMAN_FAILS=$(printf '%s\n' "$DOCTOR_OUT" | grep -cE '^FAIL ' || true)
HUMAN_FIXES=$(printf '%s\n' "$DOCTOR_OUT" | grep -cE '^ +fix: ' || true)
if [ "${HUMAN_FAILS:-0}" -eq 0 ] || [ "${HUMAN_FIXES:-0}" -gt 0 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: human: every FAIL is followed by an indented fix: line (%s FAIL(s), %s fix line(s))\n' \
        "${HUMAN_FAILS:-0}" "${HUMAN_FIXES:-0}"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("human: ${HUMAN_FAILS} FAIL line(s) but no indented fix: line")
    printf '  FAIL: human: %s FAIL line(s) but no indented fix: line\n' "${HUMAN_FAILS:-0}"
fi

# --quiet suppresses PASS/SKIP but never a FAIL.
QUIET_JSON="$WORK/quiet.json"
doctor_run "$DOCTOR" "$FULL_TARGET" "$QUIET_JSON" --quiet --skip "$(all_but deps)"
assert_eq "quiet: --quiet prints no PASS line" "0" \
    "$(printf '%s\n' "$DOCTOR_OUT" | grep -cE '^PASS ' | tr -d ' ')"
assert_eq "quiet: --quiet prints no SKIP line" "0" \
    "$(printf '%s\n' "$DOCTOR_OUT" | grep -cE '^SKIP ' | tr -d ' ')"
assert_contains "quiet: --quiet still prints the summary line" \
    "workflow-doctor:" "$DOCTOR_OUT"

# ===========================================================================
echo ""
echo "=== Section 4: --skip counts as SKIPPED, never as passed ==="

SKIP_JSON="$WORK/skip.json"
doctor_run "$DOCTOR" "$FULL_TARGET" "$SKIP_JSON" --skip "$(all_but deps)"
assert_eq "skip: the kept check still ran (deps has a non-SKIP status)" "false" \
    "$([ "$(status_of "$SKIP_JSON" deps)" = "SKIP" ] && echo true || echo false)"
assert_eq "skip: a skipped check's status is SKIP" "SKIP" \
    "$(status_of "$SKIP_JSON" gate_stop)"
assert_eq "skip: .skipped counts every skipped name" "10" \
    "$(jq -r '.skipped' "$SKIP_JSON" 2>/dev/null || echo "-1")"
assert_eq "skip: a skipped check is NOT counted in .passed" "true" \
    "$(jq -r '.passed <= 1' "$SKIP_JSON" 2>/dev/null || echo "false")"

# Skipping everything is the environment-independent proof that SKIP != PASS:
# the run must exit 0 with zero passes.
ALL_SKIP_JSON="$WORK/all-skip.json"
doctor_run "$DOCTOR" "$FULL_TARGET" "$ALL_SKIP_JSON" \
    --skip "$(printf '%s' "$SENTINEL_LIST" | tr ' ' ',')"
assert_eq "skip: skipping every check exits 0" "0" "$DOCTOR_RC"
assert_eq "skip: skipping every check yields passed=0" "0" \
    "$(jq -r '.passed' "$ALL_SKIP_JSON" 2>/dev/null || echo "-1")"
assert_eq "skip: skipping every check yields failed=0" "0" \
    "$(jq -r '.failed' "$ALL_SKIP_JSON" 2>/dev/null || echo "-1")"
assert_eq "skip: skipping every check yields skipped=11" "11" \
    "$(jq -r '.skipped' "$ALL_SKIP_JSON" 2>/dev/null || echo "-1")"

# ===========================================================================
echo ""
echo "=== Section 5: NON-MUTATION — the sandbox design is load-bearing ==="
#
# SCOPE OF THE CLAIM, and why it is written down here (R1-F1). The doctor's
# guarantee is NOT "the run writes nothing anywhere" — that was the original
# wording and QA falsified it: `beads` runs `bd doctor` against the real target,
# which can checkpoint the SQLite WAL and so rewrites .beads/beads.db and
# .beads/beads.db-shm. The guarantee that IS made, and that Section 5 pins, is:
# no source file, config file, agent prompt, hook script, skill, manifest or
# gate artifact is modified. Every run below therefore skips `beads` on purpose
# — and Section 5c asserts that the exception is disclosed in all three
# documentation surfaces AND is real in the code, so the claim and the
# behaviour cannot drift apart again in either direction.

# 5a: the LIVE repo. The doctor is expected to be run mid-session by a human
# asking "is my install healthy?"; if that clears their QA approval or re-pins
# their agents, the feature is worse than useless.
LIVE_BEFORE="$WORK/live-before.sha"
LIVE_AFTER="$WORK/live-after.sha"
snapshot_live() {
    {
        # Agent frontmatter: model-select.sh apply rewrites `model:` pins.
        for f in "$PROJECT_DIR"/.claude/agents/*.md; do
            [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" \
                "$(sed -n 's/^model:[[:space:]]*//p' "$f" | head -1)"
        done
        # Transient gate state: session-start.sh removes/truncates these.
        for f in approved changed-files.txt edit-count gate-baseline current-task; do
            if [ -f "$PROJECT_DIR/.claude/.qa-tracking/$f" ]; then
                printf 'qa-tracking/%s\tpresent\t%s\n' "$f" \
                    "$(wc -c < "$PROJECT_DIR/.claude/.qa-tracking/$f" | tr -d ' ')"
            else
                printf 'qa-tracking/%s\tABSENT\t-\n' "$f"
            fi
        done
        # The session marker: session-start.sh touches it.
        if [ -f "$PROJECT_DIR/.claude/.session-start" ]; then
            printf 'session-start-marker\t%s\n' \
                "$(( $(date +%s) - $(stat -f %m "$PROJECT_DIR/.claude/.session-start" 2>/dev/null \
                    || stat -c %Y "$PROJECT_DIR/.claude/.session-start" 2>/dev/null || echo 0) ))000"
        else
            printf 'session-start-marker\tABSENT\n'
        fi
    } > "$1"
}
# The marker snapshot records AGE, not mtime, so it changes if (and only if)
# the file is touched — the age arithmetic would otherwise drift by seconds
# between the two snapshots. Round to a coarse bucket to absorb that drift
# while still catching a `touch` (which resets the age to ~0).
snapshot_live "$LIVE_BEFORE"
doctor_run "$DOCTOR" "$PROJECT_DIR" "" --quiet \
    --skip "$(all_but session_start gate_stop gate_pretooluse)"
snapshot_live "$LIVE_AFTER"

MODEL_PINS_BEFORE=$(grep -v '^session-start-marker' "$LIVE_BEFORE")
MODEL_PINS_AFTER=$(grep -v '^session-start-marker' "$LIVE_AFTER")
assert_eq "non-mutation: the live repo's agent model pins + gate state are byte-identical after a doctor run" \
    "$MODEL_PINS_BEFORE" "$MODEL_PINS_AFTER"

MARKER_AGE_BEFORE=$(grep '^session-start-marker' "$LIVE_BEFORE" | awk -F'\t' '{print $2}')
MARKER_AGE_AFTER=$(grep '^session-start-marker' "$LIVE_AFTER" | awk -F'\t' '{print $2}')
# A `touch` resets the age to ~0; anything else keeps it within a few seconds
# of the original. Compare bucketed-to-minutes so the assertion is about
# "was it touched", not about clock drift.
if [ "$MARKER_AGE_BEFORE" = "ABSENT" ] && [ "$MARKER_AGE_AFTER" = "ABSENT" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: non-mutation: .claude/.session-start was absent before and after (not created)\n'
else
    BEFORE_MIN=$(( ${MARKER_AGE_BEFORE:-0} / 60000 ))
    AFTER_MIN=$(( ${MARKER_AGE_AFTER:-0} / 60000 ))
    assert_eq "non-mutation: .claude/.session-start was not touched by the doctor (age bucket unchanged)" \
        "$BEFORE_MIN" "$AFTER_MIN"
fi

# 5b: a SEEDED copy, so the assertion is not vacuously green just because the
# live repo happened to have no approval on disk at test time.
SEED_A="$WORK/target-seed-doctor"
mk_target "$SEED_A"
seed_gate_state "$SEED_A"
SEED_A_BEFORE=$(gate_state_fingerprint "$SEED_A")
assert_contains "non-mutation: the seeded fixture really carries an approval before the run" \
    "approved	present" "$SEED_A_BEFORE"
doctor_run "$DOCTOR" "$SEED_A" "" --quiet \
    --skip "$(all_but session_start gate_stop gate_pretooluse)"
SEED_A_AFTER=$(gate_state_fingerprint "$SEED_A")
assert_eq "non-mutation: seeded approval / tracker / counter / current-task all survive a doctor run" \
    "$SEED_A_BEFORE" "$SEED_A_AFTER"

echo ""
echo "--- META-TEST 3: the same seeded state IS destroyed without the sandbox ---"
# Discriminates the CAUSE. If session-start.sh were harmless, Section 5's
# "unchanged" would prove nothing about the sandbox. Run the identical hook
# directly against an identically-seeded copy and show the state is gone.
SEED_B="$WORK/target-seed-direct"
mk_target "$SEED_B"
seed_gate_state "$SEED_B"
SEED_B_BEFORE=$(gate_state_fingerprint "$SEED_B")
assert_eq "META-TEST 3: both seeded fixtures start from identical state" \
    "$SEED_A_BEFORE" "$SEED_B_BEFORE"

if ! command -v bd >/dev/null 2>&1; then
    printf '  note: META-TEST 3 direct-invocation leg needs the real bd CLI; bd is absent.\n'
    printf '        session-start.sh exits before the wipe without it, so the leg would\n'
    printf '        prove nothing. Skipping the leg (the state-equality assertions above ran).\n'
else
    ( cd "$SEED_B" && printf '{}' | env \
        "CLAUDE_PROJECT_DIR=$SEED_B" "ANTHROPIC_API_KEY=" \
        "CODEX_USER_CONFIG=$SEED_B/nonexistent.json" "CODEX_DETECT_TIMEOUT_S=1" \
        bash "$SEED_B/.claude/scripts/session-start.sh" >/dev/null 2>&1 ) || true
    SEED_B_AFTER=$(gate_state_fingerprint "$SEED_B")
    if [ "$SEED_B_BEFORE" = "$SEED_B_AFTER" ]; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("META-TEST 3: session-start.sh left the seeded gate state intact — Section 5 proves nothing about the sandbox")
        printf '  FAIL: META-TEST 3: session-start.sh did NOT destroy the seeded gate state;\n'
        printf '        Section 5'"'"'s non-mutation result is therefore not attributable to the sandbox.\n'
    else
        PASS=$((PASS + 1))
        printf '  PASS: META-TEST 3: session-start.sh destroys the seeded gate state when run directly\n'
    fi
    assert_contains "META-TEST 3: the destroyed state specifically includes the approval" \
        "approved	ABSENT" "$SEED_B_AFTER"
fi

echo ""
echo "--- Section 5c: the 'beads' exception is disclosed AND real (R1-F1) ---"
#
# THE DEFECT THIS PINS. The doctor originally claimed, in three places, that
# every dynamic check runs against a throwaway copy and that "nothing in the
# live project is read-modify-written". QA falsified it: `bd doctor` runs
# against the real target and can checkpoint the SQLite WAL, rewriting
# .beads/beads.db and .beads/beads.db-shm. The scope was narrow (exactly one
# file in a 10,358-file target) but the CLAIM was false — and a verification
# tool whose own safety assertion does not hold is the exact defect class this
# task exists to remove.
#
# So both directions are asserted: the three surfaces must NAME the exception
# and describe its actual mechanism, and the code must really HAVE it. If a
# future change sandboxes `beads`, the structural assertion flips and forces the
# docs to be re-broadened; if a future change re-broadens the docs, the disclosure
# assertions flip. Neither can drift silently.
CMD_MD="$PROJECT_DIR/.claude/commands/workflow-doctor.md"
DOCTOR_HELP_TEXT=$(bash "$DOCTOR" --help 2>&1)
DOCTOR_HEADER_TEXT=$(sed -n '1,120p' "$DOCTOR")
CMD_MD_TEXT=$(cat "$CMD_MD" 2>/dev/null || echo "")

# Each surface names `beads` as the exception, in the same canonical wording.
# The needle carries literal backticks (it is prose being matched, not code) —
# hence single quotes and the SC2016 waivers.
# shellcheck disable=SC2016
assert_contains "beads-exception: the script header names the exception" \
    'EXCEPT `beads`' "$DOCTOR_HEADER_TEXT"
# shellcheck disable=SC2016
assert_contains "beads-exception: --help names the exception" \
    'EXCEPT `beads`' "$DOCTOR_HELP_TEXT"
# shellcheck disable=SC2016
assert_contains "beads-exception: the /workflow-doctor command file names the exception" \
    'EXCEPT `beads`' "$CMD_MD_TEXT"

# ...and each describes the real mechanism, so the disclosure is specific rather
# than a vague hedge a reader would skip.
assert_contains "beads-exception: the script header names the WAL checkpoint mechanism" \
    "WAL" "$DOCTOR_HEADER_TEXT"
assert_contains "beads-exception: --help names the WAL checkpoint mechanism" \
    "WAL" "$DOCTOR_HELP_TEXT"
assert_contains "beads-exception: the command file names the WAL checkpoint mechanism" \
    "WAL" "$CMD_MD_TEXT"

# ...and none of them still carries the falsified absolute claim.
FALSE_CLAIMS=""
for phrase in "never the live project" "Nothing in the live project is read-modify-written"; do
    printf '%s' "$DOCTOR_HEADER_TEXT" | grep -qF "$phrase" && FALSE_CLAIMS="$FALSE_CLAIMS header:[$phrase]"
    printf '%s' "$DOCTOR_HELP_TEXT"   | grep -qF "$phrase" && FALSE_CLAIMS="$FALSE_CLAIMS help:[$phrase]"
    printf '%s' "$CMD_MD_TEXT"        | grep -qF "$phrase" && FALSE_CLAIMS="$FALSE_CLAIMS command:[$phrase]"
done
assert_eq "beads-exception: no surface still asserts the falsified absolute non-mutation claim" \
    "" "$FALSE_CLAIMS"

# STRUCTURAL: the exception is real in the code. check_beads must NOT build a
# probe sandbox (that is what makes it the exception), while the checks Section
# 5 relies on MUST. Extracted by function body, anchored on text.
fn_body() {
    awk -v fn="^$2\\\\(\\\\) \\\\{$" '
        $0 ~ fn {inb=1}
        inb {print}
        inb && /^\}$/ {exit}
    ' "$1"
}
BEADS_BODY=$(fn_body "$DOCTOR" "check_beads")
SS_BODY=$(fn_body "$DOCTOR" "check_session_start")
assert_eq "beads-exception: the extraction found a check_beads body (non-vacuity)" "true" \
    "$([ "$(printf '%s' "$BEADS_BODY" | wc -l | tr -d ' ')" -gt 10 ] && echo true || echo false)"
assert_eq "beads-exception: the extraction found a check_session_start body (non-vacuity)" "true" \
    "$([ "$(printf '%s' "$SS_BODY" | wc -l | tr -d ' ')" -gt 10 ] && echo true || echo false)"
assert_eq "beads-exception: check_beads does NOT sandbox (it queries the real .beads/, by design)" "false" \
    "$(printf '%s' "$BEADS_BODY" | grep -q 'mk_probe_sandbox' && echo true || echo false)"
assert_eq "beads-exception: CONTROL — check_session_start DOES sandbox (so the probe is discriminating)" "true" \
    "$(printf '%s' "$SS_BODY" | grep -q 'mk_probe_sandbox' && echo true || echo false)"

# The shim inconsistency QA flagged: check_beads used to bypass the
# `bd --no-daemon` wrapper every other bd call in the doctor goes through.
assert_eq "beads-exception: check_beads routes bd through the shared --no-daemon shim" "true" \
    "$(printf '%s' "$BEADS_BODY" | grep -q 'mk_bd_shim' && echo true || echo false)"

# BEHAVIOURAL: with `--skip beads`, a run leaves .beads/ byte-identical. This is
# the property the narrowed claim actually promises, asserted over a seeded copy
# so it cannot pass by the directory being empty.
SEED_C="$WORK/target-seed-beads"
mk_target "$SEED_C"
printf 'not-a-real-db-just-bytes\n' > "$SEED_C/.beads/beads.db"
printf 'wal-bytes\n'                > "$SEED_C/.beads/beads.db-wal"
printf '{"id":"seed-1"}\n'          > "$SEED_C/.beads/issues.jsonl"
beads_fingerprint() {
    local f
    for f in beads.db beads.db-wal beads.db-shm issues.jsonl; do
        if [ -f "$1/.beads/$f" ]; then
            printf '%s\t%s\n' "$f" "$(wc -c < "$1/.beads/$f" | tr -d ' ')"
        else
            printf '%s\tABSENT\n' "$f"
        fi
    done
}
BEADS_BEFORE=$(beads_fingerprint "$SEED_C")
assert_contains "beads-exception: the seeded fixture really carries a .beads/ payload" \
    "issues.jsonl	" "$BEADS_BEFORE"
doctor_run "$DOCTOR" "$SEED_C" "" --quiet --skip "$(all_but session_start gate_stop gate_pretooluse)"
BEADS_AFTER=$(beads_fingerprint "$SEED_C")
assert_eq "beads-exception: with beads skipped, the target's .beads/ is byte-identical after a run" \
    "$BEADS_BEFORE" "$BEADS_AFTER"

# ===========================================================================
echo ""
echo "=== Section 6: META-TESTs 1, 2, 4, 5 (mutant copies; the repo is never touched) ==="

echo ""
echo "--- META-TEST 1: sentinel-vs-case-arms comparison is sensitive ---"
MUT1="$WORK/doctor-mut1.sh"
# Anchored on the unique text of the sentinel assignment, not a line number.
sed 's/^DOCTOR_CHECK_NAMES="deps /DOCTOR_CHECK_NAMES="/' "$DOCTOR" > "$MUT1"
assert_eq "META-TEST 1: the mutant really differs from the original" "1" \
    "$(cmp -s "$MUT1" "$DOCTOR" && echo 0 || echo 1)"
assert_eq "META-TEST 1: the mutant is still valid bash" "0" \
    "$(bash -n "$MUT1" 2>/dev/null && echo 0 || echo 1)"
MUT1_SENTINEL=$(sentinel_names "$MUT1")
assert_eq "META-TEST 1: the mutant's sentinel really lost 'deps'" "false" \
    "$(has_word "$MUT1_SENTINEL" deps)"
assert_eq "META-TEST 1: the mutant's case arms still HAVE 'deps' (only the sentinel changed)" "true" \
    "$(has_word "$(case_arm_names "$MUT1")" deps)"
MUT1_SENT_SORTED=$(printf '%s' "$MUT1_SENTINEL" | sort_words)
MUT1_CASE_SORTED=$(case_arm_names "$MUT1" | sort_words)
assert_eq "META-TEST 1: the Section-2 parity comparison FAILS on the mutant" "differ" \
    "$([ "$MUT1_SENT_SORTED" = "$MUT1_CASE_SORTED" ] && echo same || echo differ)"
# Control: the same comparison agrees on the unmutated script (already asserted
# in Section 2, restated here so the META reads as a pair).
assert_eq "META-TEST 1 control: the comparison AGREES on the unmutated script" "same" \
    "$([ "$SENTINEL_SORTED" = "$CASE_SORTED" ] && echo same || echo differ)"

echo ""
echo "--- META-TEST 2: --skip rejection is load-bearing ---"
MUT2="$WORK/doctor-mut2.sh"
# Neutralize the `*)` refusal arm of the validation `case` inside the --skip
# loop, turning it into an unconditional accept. Anchored on the unique refusal
# text; the `;;` terminator is preserved so the surrounding case stays valid
# bash (a mutant that merely fails to parse would prove nothing).
awk '
    /usage_error "--skip: unknown check name/ {
        print "            *) SKIP_LIST=\"$SKIP_LIST $_skip_one\" ;;  # META-TEST 2 stub: validation removed"
        found = 1
        next
    }
    { print }
    END { if (!found) exit 7 }
' "$DOCTOR" > "$MUT2"
MUT2_AWK_RC=$?
if [ "$MUT2_AWK_RC" -ne 0 ] || ! grep -qF 'META-TEST 2 stub: validation removed' "$MUT2"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST 2: the stub did NOT install (refusal text moved or was reworded) — the rejection is unverified")
    printf '  FAIL: META-TEST 2: stub did not install; the --skip rejection is unverified\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: META-TEST 2: stub installed (validation replaced with an unconditional accept)\n'
    assert_eq "META-TEST 2: the mutant is still valid bash" "0" \
        "$(bash -n "$MUT2" 2>/dev/null && echo 0 || echo 1)"
    # Keep the run cheap AND environment-independent: the bogus name plus every
    # real name, so the mutant has nothing left to execute.
    MUT2_RC=0
    bash "$MUT2" --target "$FULL_TARGET" --quiet \
        --skip "not_a_real_check,$(printf '%s' "$SENTINEL_LIST" | tr ' ' ',')" \
        >/dev/null 2>&1 || MUT2_RC=$?
    assert_eq "META-TEST 2: WITHOUT the validation the mutant ACCEPTS a bogus --skip name (no exit 2)" \
        "false" "$([ "$MUT2_RC" = "2" ] && echo true || echo false)"
    # Control: the real script refuses the identical invocation.
    CTRL_RC=0
    bash "$DOCTOR" --target "$FULL_TARGET" --quiet \
        --skip "not_a_real_check,$(printf '%s' "$SENTINEL_LIST" | tr ' ' ',')" \
        >/dev/null 2>&1 || CTRL_RC=$?
    assert_eq "META-TEST 2 control: the real script exits 2 on the identical invocation" \
        "2" "$CTRL_RC"
fi

echo ""
echo "--- META-TEST 4: the MCP tool count is EXACT, not a >= bound ---"
MCP_BD_DIR="$PROJECT_DIR/.claude/mcp/bd-mcp"
if ! command -v node >/dev/null 2>&1 || [ ! -d "$MCP_BD_DIR/node_modules" ]; then
    printf '  note: META-TEST 4 needs node + %s/node_modules to boot the server.\n' "$MCP_BD_DIR"
    # shellcheck disable=SC2016  # the backticked command is literal text
    printf '        Run `cd %s && npm ci --omit=dev` to enable it. Skipping.\n' "$MCP_BD_DIR"
else
    ONLY_BD=$(all_but mcp_bd)
    # The target here is the REPO, not $FULL_TARGET: mk_target deliberately does
    # not copy .claude/mcp/ (which is what makes the Section-3 human-output
    # "every FAIL has a fix line" assertion non-vacuous), so a synthetic target
    # has no server to boot.
    #
    # Why running against the repo is safe HERE specifically (narrow claim, not
    # a general one — Section 5 skips the `beads` check, so it proves nothing
    # about `bd doctor`): every check but mcp_bd is skipped, and mcp_bd spawns
    # the server with CLAUDE_PROJECT_DIR pointed at a throwaway sandbox and
    # issues only initialize + tools/list. No tool call, so no lazy index build,
    # no file written under the repo.
    MCP_TARGET="$PROJECT_DIR"
    # Control FIRST: the unmutated doctor must PASS mcp_bd here, or the mutant's
    # FAIL would prove nothing (it could be failing for an unrelated reason).
    CTRL4_JSON="$WORK/meta4-control.json"
    doctor_run "$DOCTOR" "$MCP_TARGET" "$CTRL4_JSON" --quiet --skip "$ONLY_BD"
    CTRL4_STATUS=$(status_of "$CTRL4_JSON" mcp_bd)
    assert_eq "META-TEST 4 control: mcp_bd PASSES with the real tool count" "PASS" "$CTRL4_STATUS"

    if [ "$CTRL4_STATUS" != "PASS" ]; then
        printf '  note: META-TEST 4 mutant leg skipped — the control did not pass, so a\n'
        printf '        mutant FAIL would not be attributable to the count change.\n'
    else
        MUT4="$WORK/doctor-mut4.sh"
        # Anchored on the unique table text. 21 -> 22 is the smallest change
        # that a >= bound would wave through and an == bound must catch.
        sed 's/^DOCTOR_TOOL_COUNTS="bd-mcp:21 /DOCTOR_TOOL_COUNTS="bd-mcp:22 /' "$DOCTOR" > "$MUT4"
        assert_eq "META-TEST 4: the mutant's table really says bd-mcp:22" "true" \
            "$(grep -q '^DOCTOR_TOOL_COUNTS="bd-mcp:22 ' "$MUT4" && echo true || echo false)"
        assert_eq "META-TEST 4: the mutant is still valid bash" "0" \
            "$(bash -n "$MUT4" 2>/dev/null && echo 0 || echo 1)"
        MUT4_JSON="$WORK/meta4-mutant.json"
        doctor_run "$MUT4" "$MCP_TARGET" "$MUT4_JSON" --quiet --skip "$ONLY_BD"
        assert_eq "META-TEST 4: an off-by-one expected count flips mcp_bd to FAIL (equality, not >=)" \
            "FAIL" "$(status_of "$MUT4_JSON" mcp_bd)"
        assert_contains "META-TEST 4: the FAIL detail names both the observed and expected counts" \
            "expected exactly 22" \
            "$(jq -r '.checks[] | select(.name == "mcp_bd") | .detail' "$MUT4_JSON" 2>/dev/null || echo "")"
    fi
fi

echo ""
echo "--- META-TEST 5: session_start is sensitive to a gutted SKILL.md ---"
if ! command -v bd >/dev/null 2>&1; then
    printf '  note: META-TEST 5 needs the real bd CLI (session-start.sh exits before\n'
    printf '        building context without it). Skipping.\n'
else
    ONLY_SS=$(all_but session_start)
    # Control FIRST: an intact target must PASS, or the stub target's FAIL is
    # not attributable to the stub.
    CTRL5_JSON="$WORK/meta5-control.json"
    doctor_run "$DOCTOR" "$FULL_TARGET" "$CTRL5_JSON" --quiet --skip "$ONLY_SS"
    CTRL5_STATUS=$(status_of "$CTRL5_JSON" session_start)
    assert_eq "META-TEST 5 control: session_start PASSES against an intact target" \
        "PASS" "$CTRL5_STATUS"

    STUB_TARGET="$WORK/target-stub-skill"
    mk_target "$STUB_TARGET"
    # The exact shape session-start.sh's fallback produces: a file whose
    # post-frontmatter body is a stub. Assert the fixture is really in that
    # state BEFORE asserting the checker flags it.
    printf -- '---\nname: workflow-engine\n---\nstub\n' \
        > "$STUB_TARGET/.claude/skills/workflow-engine/SKILL.md"
    STUB_BODY_BYTES=$(awk 'BEGIN{n=0} /^---[[:space:]]*$/{n++; next} n>=2{print}' \
        "$STUB_TARGET/.claude/skills/workflow-engine/SKILL.md" | wc -c | tr -d ' ')
    assert_eq "META-TEST 5: the stub fixture's SKILL.md body really is tiny (< 500B)" "true" \
        "$([ "${STUB_BODY_BYTES:-0}" -lt 500 ] && echo true || echo false)"
    assert_eq "META-TEST 5: the stub fixture's SKILL.md really lacks the delegation marker" "false" \
        "$(grep -qF 'Mandatory delegation flow' "$STUB_TARGET/.claude/skills/workflow-engine/SKILL.md" \
            && echo true || echo false)"

    STUB_JSON="$WORK/meta5-stub.json"
    doctor_run "$DOCTOR" "$STUB_TARGET" "$STUB_JSON" --quiet --skip "$(all_but session_start skill)"
    assert_eq "META-TEST 5: a gutted SKILL.md flips session_start to FAIL" "FAIL" \
        "$(status_of "$STUB_JSON" session_start)"
    assert_eq "META-TEST 5: ...and flips the skill check to FAIL too" "FAIL" \
        "$(status_of "$STUB_JSON" skill)"
    assert_contains "META-TEST 5: the session_start FAIL detail points at SKILL.md, not at the hook" \
        "SKILL.md" \
        "$(jq -r '.checks[] | select(.name == "session_start") | .detail' "$STUB_JSON" 2>/dev/null || echo "")"
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
