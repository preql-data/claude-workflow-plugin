#!/bin/bash
# workflow-doctor.test.sh — L1 unit fixture for .claude/scripts/workflow-doctor.sh
# (v4.1 / claude-workflow-plugin-0fc, epic 2br).
#
# The doctor is the repo's ONLY functional post-install verification surface,
# so its own contract has to be pinned hard. Four properties matter most:
#
#   1. THE CHECK REGISTRY IS THE TEST CONTRACT. Other specs and the
#      /workflow-doctor command assert on the thirteen check names by name, so
#      the DOCTOR_CHECK_NAMES sentinel block, the runner's case arms, --help and a
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
#      gate baseline and calls model-select.sh apply --check (claude-workflow-
#      plugin-j7kk, B2: DETECT-AND-WARN only since the R4-F1 ruling — the
#      write path, `apply` without --check, still REWRITES AGENT FRONTMATTER
#      PINS and is what this note originally described, but nothing calls it
#      automatically any more). A doctor that ran the FIRST THREE against the
#      live tree would clear the operator's own QA approval as a side effect
#      of a health check.
#      Section 5 asserts this in two halves with different owners: 5b seeds the
#      gate artifacts into a COPIED target and asserts they survive, and its
#      META proves the preservation comes from the sandbox indirection by
#      showing the SAME seeded state IS destroyed when session-start.sh is
#      invoked directly; 5a asserts the LIVE repo's agent pins and session
#      marker are unmoved. 5a deliberately carries only that low-volatility
#      residue, and guards even that with a double-snapshot control
#      (claude-workflow-plugin-1nz) — see the long note above 5a for why the
#      gate-state half is 5b's and must not be moved back.
#
#   4. THE REGISTRY SIZE IS A CONTRACT TOO, not just the names (section 7).
#      Docs, component specs, the two installers, the SessionStart degraded
#      block and the Windows CI job's vacuity floor all state how many checks
#      there are. When `beads_ledger` took the count from eleven to twelve, the
#      stale "eleven" survived three review rounds of hand sweeps and left the
#      CI floor asserting a bound the truncation it guards against would clear.
#      Section 7 derives the expected count from the sentinel and scans every
#      tracked surface, so the next registry change goes red instead of quiet.
#      `model_parity` (claude-workflow-plugin-a13r) took the count to
#      thirteen the same disciplined way: every surface Section 7 tracks was
#      updated in the same change, and Section 7 itself needed no code
#      changes to notice a thirteenth name — that is the point of deriving
#      the expected count from the sentinel rather than typing it.
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
#   META-TEST 6  (section 7) the registry-size-vs-prose scan bites in BOTH
#                directions: bumping the sentinel without touching the prose
#                flags every tracked surface; staling ONE surface with the
#                sentinel unchanged flags exactly that one; and restoring the
#                Windows CI job's hardcoded vacuity floor trips the assertion
#                that says it must stay derived.
#   META-TEST 7  (section 5) the double-snapshot control 5a skips on is itself
#                controlled, in both directions: an UNDISTURBED fixture must
#                hold still across two samples (an over-sensitive control would
#                switch 5a off permanently and silently, since a note is not a
#                failure), a perturbed .session-start must move it, and the skip
#                branch that then runs must print a note while moving NEITHER
#                counter — which is what keeps the run's exit code 0.
#   META-TEST 8  (claude-workflow-plugin-j7kk, 39cy, we57, 0cr6) offering a
#                bd/schema pair that is NOT a member of
#                DOCTOR_BD_SCHEMA_VALIDATED, against a freshly bd-init'd
#                fixture whose real pair IS a member (the control), flips
#                `beads` from PASS to FAIL, proving the
#                bd-version-vs-store-schema check is SET MEMBERSHIP — neither a
#                floor (1.2.2 ships schema 53, LOWER than 1.2.1's 65, so the
#                number does not order) nor the single exact pin it replaced —
#                and a target whose .beads/ has no embedded-Dolt store at all
#                still PASSES (DISARMED, never a failure over an environment
#                gap the check cannot evaluate). 8a runs against a
#                `beads`-named store; 8b builds one via plain `bd init` so it
#                is named after its directory, which is the case 0cr6 existed
#                for and which the retired hardcoded path silently disarmed.
#   META-TEST 10 (section 9, claude-workflow-plugin-a13r) `model_parity`
#                actually gates: a target whose model-select cache and agent
#                pins genuinely agree PASSES; a drifted pin FAILs by name
#                with check-parity's own DISAGREEMENT detail; a target with
#                no cache at all SELF-SKIPS (never PASSes, and — measured
#                against install.sh's own --verify block, which runs with no
#                --skip flags at all — never FAILs either, since nothing in
#                the install path ever populates this cache and FAILing here
#                broke every fresh install with no ANTHROPIC_API_KEY) with
#                the UNVERIFIABLE detail, so an unpopulated cache can never
#                look healthy; and a target seeded with a real cache proves
#                mk_probe_sandbox's copy of it is what the sandboxed check
#                actually reads, by removing the LIVE copy after seeding the
#                sandbox source and confirming the verdict still reflects
#                the seeded state, not an empty one.
#   META-TEST 11 (section 9, claude-workflow-plugin-a13r round 3) an
#                unreadable (chmod 000) agent file on the REAL target FAILS
#                model_parity by name, through the DURABLE path — mk_target
#                -> chmod 000 -> the real doctor_run -> the real
#                mk_probe_sandbox, whose `cp -R` silently drops a file it
#                cannot read. A copy of the doctor with only the new
#                fail-closed gate disarmed reproduces the original defect:
#                the sandbox is quietly missing the file, that reads as a
#                legitimate "never installed" exclusion, and the run
#                WRONGLY PASSES; the shipped doctor, identical fixture,
#                still FAILs.
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
# `diff` is required, not optional, and it is listed here rather than guarded at
# its call site on purpose. Section 5a's control reports "the world moved" on any
# non-zero diff exit — which is the right direction for a real difference, but an
# ABSENT diff would report the same thing on every run, and 5a would then skip
# with a note forever. A note is not a failure and nothing counts it, so that
# degradation would be permanent and invisible. Exit 2 here instead: loud, and it
# names the missing tool.
for tool in jq awk sed diff; do
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

# assert_not_contains (i8cx wave 2) — the negation assert_contains never
# needed until Section 8's "the two failure causes must not be conflated"
# checks. Same predicate, inverted; same style as this repo's other spec
# files (model-roles.test.sh carries the identical implementation).
assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden substring present: %s\n' "$name" "$needle"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
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

# --- Section 7 helpers: registry-size claims in prose -----------------------
#
# The vocabulary a REGISTRY-SIZE claim is written in: a count, one or more
# spaces or a hyphen, optional qualifier words, then "check". Deliberately
# narrow at the low end — the spelled alternation starts at "seven" and numerals
# below DOCTOR_CLAIM_FLOOR are dropped — because "at least one check", "the two
# checks below" and "five named checks" are claims about a SUBSET of the
# registry, not about its size, and no plausible subset claim in the tracked
# files reaches seven.
#
# THE TWO BOUNDARIES ARE NOT DECORATION. Each was added after a whole-tree run
# produced a false positive, and each is named here so nobody removes it as
# noise:
#   leading  [^0-9A-Za-z.-]  stops "sections 1-7 check the VERDICTS" reading as
#                            a claim of seven, and "U0.8 checkers" as one of
#                            eight — a hyphenated range and a dotted section
#                            label are not counts.
#   trailing ([^[:alpha:]]|$) stops "the principle 11 checklist" and
#                            "the U0.8 checkers" matching on a mere prefix of
#                            "check".
#
# THERE IS NO EXEMPTION LIST, on purpose. If a legitimate non-registry claim of
# seven-or-more checks ever appears in a tracked file, reword it ("every other
# check in the registry", "a single check") rather than teaching this scanner to
# look away — a guard with an exemption list is a guard someone can turn off one
# line at a time.
DOCTOR_CLAIM_RE='(^|[^0-9A-Za-z.-])(seven|eight|nine|ten|eleven|twelve|thirteen|fourteen|fifteen|sixteen|seventeen|eighteen|nineteen|twenty|[0-9]+)[ -]+((functional|named|doctor|health|registry|workflow)[ -]+)*check(s|\(s\))?([^[:alpha:]]|$)'
DOCTOR_CLAIM_FLOOR=7

# spelled_count <token> — the numeric value of a count token, spelled or not.
# Echoes the token unchanged when it is neither, so the caller's is-it-a-number
# test rejects it.
spelled_count() {
    case "$1" in
        seven) printf '7'  ;; eight)    printf '8'  ;; nine)     printf '9'  ;;
        ten)   printf '10' ;; eleven)   printf '11' ;; twelve)   printf '12' ;;
        thirteen) printf '13' ;; fourteen) printf '14' ;; fifteen)  printf '15' ;;
        sixteen)  printf '16' ;; seventeen) printf '17' ;; eighteen) printf '18' ;;
        nineteen) printf '19' ;; twenty)    printf '20' ;;
        *) printf '%s' "$1" ;;
    esac
}

# count_claims <file> [display-name] — one TSV row per registry-size claim:
#   <display>:<line> <TAB> <numeric value> <TAB> <matched text>
# Empty output means the file makes no claim at all, which Section 7 treats
# differently depending on which tier the file is in.
count_claims() {
    local f="$1" rel="${2:-}"
    [ -n "$rel" ] || rel="${f#"$PROJECT_DIR"/}"
    [ -f "$f" ] || return 0
    grep -oniE "$DOCTOR_CLAIM_RE" "$f" 2>/dev/null | while IFS=: read -r ln raw; do
        local tok n
        tok=$(printf '%s' "$raw" | tr '[:upper:]' '[:lower:]' \
                | sed -E 's/^[^0-9a-z]*//; s/[ -].*$//')
        n=$(spelled_count "$tok")
        case "$n" in ''|*[!0-9]*) continue ;; esac
        [ "$n" -ge "$DOCTOR_CLAIM_FLOOR" ] || continue
        printf '%s:%s\t%s\t%s\n' "$rel" "$ln" "$n" "$raw"
    done
}

# claim_offenders <expected> <file>... — "" when every claim in every file says
# <expected>, otherwise a space-separated list of "path:line=value".
claim_offenders() {
    local want="$1"; shift
    local f loc val out=""
    for f in "$@"; do
        while IFS=$'\t' read -r loc val _; do
            [ -n "$loc" ] || continue
            [ "$val" = "$want" ] || out="$out $loc=$val"
        done < <(count_claims "$f")
    done
    printf '%s' "${out# }"
}

# enum_gaps <file>... — "<path>:<name>" for every registry name a file that is
# supposed to ENUMERATE the check names never mentions. Reads $SENTINEL_LIST,
# which section 2 derives from the sentinel.
#
# File-level rather than row-level on purpose: pinning the exact markup of a
# markdown table cell would break on a reflow and teach nobody anything. The
# weakness is named — a name that appears ELSEWHERE in the file satisfies this
# even if the enumeration omits it — but it is not vacuous for the case that
# actually shipped: pre-fix docs/HOOKS.md contained the string `beads_ledger`
# exactly zero times.
enum_gaps() {
    local f n rel out=""
    for f in "$@"; do
        rel="${f#"$PROJECT_DIR"/}"
        if [ ! -f "$f" ]; then out="$out $rel:<absent>"; continue; fi
        for n in $SENTINEL_LIST; do
            grep -qF -- "$n" "$f" || out="$out $rel:$n"
        done
    done
    printf '%s' "${out# }"
}

# claim_count <file>... — how many registry-size claims the files make in total.
# Non-vacuity fuel: a scanner that matches nothing passes every equality test
# ever written against it.
claim_count() {
    local f total=0 n
    for f in "$@"; do
        n=$(count_claims "$f" | grep -c . | tr -d ' ')
        total=$((total + n))
    done
    printf '%s' "$total"
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
assert_eq "registry: the sentinel declares 13 check names" "13" "$SENTINEL_COUNT"

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
# 13 checks in the registry, one kept (deps) => 12 skipped. Bumped from 11
# when model_parity joined the registry (claude-workflow-plugin-a13r); before
# that it was bumped from 10 when beads_ledger joined
# (claude-workflow-plugin-fkm.1.1).
assert_eq "skip: .skipped counts every skipped name" "12" \
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
assert_eq "skip: skipping every check yields skipped=13" "13" \
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
# asking "is my install healthy?"; if that re-pins their agents or touches the
# session marker, the feature is worse than useless.
#
# SCOPE, DELIBERATELY NARROWED (claude-workflow-plugin-1nz). This snapshot used
# to carry a second half — the five .qa-tracking gate artifacts — and that half
# is GONE. Do not restore it. Two reasons, in order of importance:
#
#   IT BOUGHT NO COVERAGE. 5b BELOW OWNS THAT PROPERTY, and owns it better: it
#   seeds approved / changed-files.txt / edit-count / current-task into a COPIED
#   target and asserts all four survive a doctor run, and META-TEST 3 runs
#   session-start.sh directly against an identically-seeded copy and asserts the
#   same four are destroyed. Both directions, over input this spec controls. The
#   live half asserted the same property over input it did NOT control, so it
#   could only ever agree with 5b or be wrong.
#
#   AND IT WAS WRONG OFTEN, in the way that trains people to ignore a red suite.
#   LESSONS.md: "a non-mutation assertion must compare a quantity that moves only
#   when the property is violated." Every one of those five moves in normal
#   operation, by design and often: post-edit.sh appends to changed-files.txt and
#   increments edit-count on EVERY Write/Edit by ANY agent; qa-gate.sh writes
#   current-task and approved on enter/block/approve and rewrites gate-baseline
#   unconditionally on approve. So the assertion failed whenever a review cycle
#   was in flight — which is precisely when the Stop hook runs it. Five recorded
#   instances; the last was the Stop hook racing THE GATE'S OWN STATE MACHINE,
#   and one cost a spurious J21 escalation on a P0 task. A test that fails under
#   a concurrent writer teaches everyone to re-run rather than believe, which is
#   how a real regression eventually gets waved through as flake.
#
#   THE ONE GENUINE COVERAGE LOSS, named rather than left to be discovered:
#   gate-baseline, which was in the live half and is now in neither. What it
#   could catch is a sandbox break in the narrow window where the live repo has
#   NO active cycle — session-start.sh captures the baseline only inside
#   `if [ -z "$SS_ACTIVE_TASK" ]`, so with a cycle in flight (the usual state,
#   and the state during every review) it was already inert. Carrying it into 5b
#   would be vacuous for the same reason: that fixture deliberately seeds
#   current-task, so nothing on that path can move it. A non-vacuous assertion
#   needs a no-active-cycle fixture, which is session-lifecycle.sh's surface and
#   not this spec's. Traded knowingly: a conditional assertion that only bites
#   when the repo is idle, against a spec that failed whenever it was not.

# snapshot_live <out-file> [root] — the LOW-VOLATILITY live state a doctor run
# could plausibly damage: agent frontmatter `model:` pins (model-select.sh apply
# rewrites them) and the session marker's mtime (session-start.sh touches it).
# <root> defaults to the live repo; META-TEST 7 passes a throwaway fixture so
# the control below can be perturbed without ever writing to the checkout.
snapshot_live() {
    local out="$1" root="${2:-$PROJECT_DIR}"
    {
        # Agent frontmatter: model-select.sh apply rewrites `model:` pins.
        for f in "$root"/.claude/agents/*.md; do
            [ -f "$f" ] && printf '%s\t%s\n' "$(basename "$f")" \
                "$(sed -n 's/^model:[[:space:]]*//p' "$f" | head -1)"
        done
        # NOTHING FROM .qa-tracking BELONGS HERE. 5b owns the gate artifacts,
        # over a seeded copy; see the long note above. Adding one back makes
        # this assertion a function of what every other agent in the session is
        # doing (1nz), and a note-and-skip control cannot save it — those files
        # change on every single Write/Edit anywhere in the repo.
        #
        # The session marker: session-start.sh touches it. Record the RAW MTIME,
        # never the age: mtime changes if and only if the file is touched, which
        # is precisely the property under test, whereas age is a function of
        # wall-clock time and so drifts between the two snapshots on its own.
        #
        # GNU `stat -c %Y` MUST be tried first. BSD's `stat -f %m` is not a clean
        # no-op on GNU: there `-f` is --file-system and takes no format argument,
        # so `%m` and the path are parsed as two OPERANDS — `%m` errors (nonzero
        # exit) but the path SUCCEEDS and prints filesystem info beginning
        # `File: "..."` on stdout. The `||` fallback then appends the real mtime
        # to that garbage, and the bare word `File` reaching an arithmetic
        # context under `set -u` is the "File: unbound variable" crash this spec
        # hit on CI. GNU `-c` on BSD fails cleanly by contrast: usage to stderr,
        # nothing on stdout, so this ordering is safe in both directions.
        if [ -f "$root/.claude/.session-start" ]; then
            printf 'session-start-marker\t%s\n' \
                "$(stat -c %Y "$root/.claude/.session-start" 2>/dev/null \
                    || stat -f %m "$root/.claude/.session-start" 2>/dev/null \
                    || echo 0)"
        else
            printf 'session-start-marker\tABSENT\n'
        fi
    } > "$out"
}

# control_held <root> <prefix> [perturb-cmd...] — take TWO snapshots of <root>
# with no doctor run between them, and report whether the world held still.
# Writes <prefix>.a, <prefix>.b and <prefix>.diff. Returns 0 when the samples
# are identical, non-zero when they are not — and also non-zero if diff itself
# errors, which fails toward SKIPPING rather than toward a misattributed FAIL.
# The optional trailing command runs BETWEEN the two samples; only META-TEST 7
# passes one, and that is what makes the moved case reachable on demand.
control_held() {
    local root="$1" pfx="$2"; shift 2
    snapshot_live "$pfx.a" "$root"
    if [ "$#" -gt 0 ]; then "$@" || true; fi
    snapshot_live "$pfx.b" "$root"
    diff "$pfx.a" "$pfx.b" > "$pfx.diff" 2>&1
}

# note_live_control_moved <diff-file> — the ONE branch taken when the control
# moved, factored into a function so META-TEST 7 executes the real thing rather
# than a copy of it. It MOVES NEITHER PASS NOR FAIL on purpose, so a fired
# control cannot fail this spec — that is the property META-TEST 7 pins below,
# and it is unchanged.
#
# What DID change (claude-workflow-plugin-a9hh, and this comment used to assert
# the opposite): run-tests.sh is no longer blind to the note. It has a SKIP
# verb, it reads the executed-assertion count rather than the exit code alone,
# and since a9hh R1-F1 it classifies a passing spec that printed a `note: ...
# SKIPPED` marker as PARTIAL — named under the completeness line, and red under
# STRICT_SECTIONS=1 (which the CI l1-unit job sets). The idiom is still a bare
# note that leaves this spec's own counters alone, the same shape META-TESTs 3,
# 4 and 5 use below; it is simply no longer a note that nothing can see. 5a
# firing in CI would mean something wrote the checkout mid-run, which is worth
# a red rather than a shrug. Consequence, stated because it surprises anyone
# diffing two runs: this spec's total assertion count is NOT a constant. It
# drops by three when the control fires.
note_live_control_moved() {
    printf '  note: 5a SKIPPED - the live repo moved underneath the CONTROL, before the\n'
    printf '        doctor ran at all, so a before/after difference here could not be\n'
    printf '        attributed to the doctor. That is interference, not a regression\n'
    printf '        (claude-workflow-plugin-1nz). 5b below still proves the same\n'
    printf '        property over a seeded copy nothing else can write to.\n'
    printf '        What moved between the two control samples:\n'
    sed 's/^/          /' "$1" 2>/dev/null | head -20
}

# THE CONTROL. Agent pins and the session marker are low-volatility, not
# immovable: an implementer editing .claude/agents/*.md is instance 4 of 1nz and
# it really happened. So sample twice with NOTHING between the samples; if the
# world moved with no doctor running, 5a can attribute nothing and skips. Same
# discriminating-control shape as denylist-shared section D1.
#
# WHAT THIS IS NOT: a lock. There is deliberately no advisory lock in
# run-tests.sh — candidate fix (c) on the filing, ruled out there because a lock
# cannot stop a non-test writer (an installer experiment, an implementer's Edit)
# and the Stop hook fires on every turn regardless.
#
# WHAT IT DOES NOT COVER, said plainly so nobody mistakes it for one: it samples
# a window of a few milliseconds, while the measurement window is the whole
# doctor run. A writer that lands exactly once, inside that run, is still a false
# FAIL. The NARROWING above is what makes 5a reliable; the control is what
# catches a writer that is CONTINUOUSLY active, which is what an agent holding a
# file for minutes looks like.
LIVE_CTRL="$WORK/live-control"
if ! control_held "$PROJECT_DIR" "$LIVE_CTRL"; then
    note_live_control_moved "$LIVE_CTRL.diff"
else
    # The control's SECOND sample IS the measurement's BEFORE. Re-snapshotting
    # would reopen a gap between "the world was quiet" and "the measurement
    # began"; reusing it leaves none.
    LIVE_BEFORE="$LIVE_CTRL.b"
    LIVE_AFTER="$WORK/live-after.sha"
    doctor_run "$DOCTOR" "$PROJECT_DIR" "" --quiet \
        --skip "$(all_but session_start gate_stop gate_pretooluse)"
    snapshot_live "$LIVE_AFTER"

    MODEL_PINS_BEFORE=$(grep -v '^session-start-marker' "$LIVE_BEFORE")
    MODEL_PINS_AFTER=$(grep -v '^session-start-marker' "$LIVE_AFTER")
    # NON-VACUITY, and it is new with the narrowing: with the gate-state half
    # gone, an agents/ glob that matched nothing would leave both sides empty
    # and the comparison green forever. Deliberately family-agnostic — it asks
    # whether a pin was READ, never what the pin says, because the model
    # families are expected to change and a spec that pins them would go red on
    # a rename rather than on a mutation.
    assert_eq "non-mutation: the live snapshot really captured agent model pins (non-vacuity)" \
        "yes" \
        "$(printf '%s\n' "$MODEL_PINS_BEFORE" | awk -F'\t' 'NF==2 && $2 != "" {n++} END {print (n>0 ? "yes" : "no")}')"
    assert_eq "non-mutation: the live repo's agent model pins are byte-identical after a doctor run" \
        "$MODEL_PINS_BEFORE" "$MODEL_PINS_AFTER"

    MARKER_MTIME_BEFORE=$(grep '^session-start-marker' "$LIVE_BEFORE" | awk -F'\t' '{print $2}')
    MARKER_MTIME_AFTER=$(grep '^session-start-marker' "$LIVE_AFTER" | awk -F'\t' '{print $2}')
    if [ "$MARKER_MTIME_BEFORE" = "ABSENT" ] && [ "$MARKER_MTIME_AFTER" = "ABSENT" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: non-mutation: .claude/.session-start was absent before and after (not created)\n'
    else
        assert_eq "non-mutation: .claude/.session-start was not touched by the doctor (mtime unchanged)" \
            "$MARKER_MTIME_BEFORE" "$MARKER_MTIME_AFTER"
    fi
fi

echo ""
echo "--- META-TEST 7: the control 5a skips on is itself controlled ---"
#
# WITHOUT THIS, THE SKIP BRANCH IS CODE THAT HAS NEVER EXECUTED. The live repo
# is quiet during almost every run, so every ordinary run takes the assert path;
# the branch that makes interference non-fatal would ship untested, and it is
# exactly the kind that goes wrong silently — it prints and returns, and nothing
# counts it.
#
# Three legs, and the FIRST is the one that gets left out:
#   quiet   an UNDISTURBED fixture must hold still across two samples. A control
#           that fires on nothing would switch 5a off permanently and invisibly,
#           because a note is not a failure.
#   moved   a .session-start rewritten between the samples must move it.
#   branch  the branch that then runs must print a note and move NEITHER
#           counter. This file's tail exits 1 if and only if FAIL > 0, so
#           "neither counter moved" IS "the run still exits 0" — and the last
#           leg checks that premise instead of assuming it.
#
# The fixture is a throwaway copy under $WORK. Nothing here writes to the
# checkout: perturbing the live .claude/.session-start to test a test would be
# the same class of mistake this section exists to remove.
CTRL7="$WORK/ctrl7-fixture"
mkdir -p "$CTRL7/.claude/agents"
cp "$PROJECT_DIR"/.claude/agents/*.md "$CTRL7/.claude/agents/" 2>/dev/null || true
: > "$CTRL7/.claude/.session-start"

CTRL7_PROBE="$WORK/ctrl7-probe.sha"
snapshot_live "$CTRL7_PROBE" "$CTRL7"
assert_eq "META-TEST 7: the control fixture really carries agent pins (non-vacuity)" "yes" \
    "$(awk -F'\t' '$1 ~ /\.md$/ && $2 != "" {n++} END {print (n>0 ? "yes" : "no")}' "$CTRL7_PROBE")"
assert_eq "META-TEST 7: ...and a session marker with a real mtime (non-vacuity)" "yes" \
    "$(awk -F'\t' '$1 == "session-start-marker" && $2 ~ /^[0-9]+$/ {n++} END {print (n>0 ? "yes" : "no")}' "$CTRL7_PROBE")"

if control_held "$CTRL7" "$WORK/ctrl7-quiet"; then
    PASS=$((PASS + 1))
    printf '  PASS: META-TEST 7 quiet: an undisturbed fixture holds still across two samples\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST 7 quiet: two samples of an UNDISTURBED fixture already differ, so the control fires on nothing and 5a is silently switched off")
    printf '  FAIL: META-TEST 7 quiet: two back-to-back samples of an UNDISTURBED fixture\n'
    printf '        already differ, so the control cannot tell interference from its own\n'
    printf '        noise - and a control that always fires disables 5a silently.\n'
    sed 's/^/          /' "$WORK/ctrl7-quiet.diff" 2>/dev/null | head -10
fi

# `touch -t` with an explicit far-past stamp, never a bare `touch`: two touches
# inside one filesystem timestamp granularity can land on the SAME mtime (HFS+
# is 1s), and a perturbation that did not perturb would make this leg vacuous in
# the direction that looks green.
if control_held "$CTRL7" "$WORK/ctrl7-moved" \
        touch -t 202001010000 "$CTRL7/.claude/.session-start"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST 7 moved: the control did NOT notice a .session-start rewritten between its two samples")
    printf '  FAIL: META-TEST 7 moved: .session-start was rewritten between the two control\n'
    printf '        samples and the control still reported "held" - 5a would go on to blame\n'
    printf '        a concurrent writer on the doctor, which is claude-workflow-plugin-1nz.\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: META-TEST 7 moved: the control notices a .session-start perturbation between samples\n'
fi

# ...and now EXECUTE the branch 5a takes, for real - the same function, not a
# copy of it - reading the counters either side of the call.
M7_PASS_BEFORE=$PASS
M7_FAIL_BEFORE=$FAIL
M7_NOTE="$WORK/ctrl7-note.out"
note_live_control_moved "$WORK/ctrl7-moved.diff" > "$M7_NOTE" 2>&1
M7_PASS_AFTER=$PASS
M7_FAIL_AFTER=$FAIL
assert_eq "META-TEST 7 branch: the skip branch moves NEITHER counter, so a fired control cannot fail the run" \
    "PASS=$M7_PASS_BEFORE FAIL=$M7_FAIL_BEFORE" "PASS=$M7_PASS_AFTER FAIL=$M7_FAIL_AFTER"
assert_contains "META-TEST 7 branch: it announces the skip in the house note: idiom" \
    "note: 5a SKIPPED" "$(cat "$M7_NOTE")"
assert_contains "META-TEST 7 branch: ...and names WHAT moved, so the interference is diagnosable" \
    "session-start-marker" "$(cat "$M7_NOTE")"
# The premise the counter assertion rests on, CHECKED rather than assumed: this
# file's tail exits non-zero if and only if FAIL is non-zero, so a branch that
# moves neither counter cannot change the exit code. Anchored on the tail's own
# text at column 0 — every grep needle in this spec is indented, so the pattern
# cannot match itself and read as satisfied by its own presence.
# shellcheck disable=SC2016
assert_eq "META-TEST 7 branch: ...and the tail exits on FAIL alone, which is what makes 'the run still exits 0' true" \
    "1" "$(grep -c '^if \[ "\$FAIL" -gt 0 \]; then$' "${BASH_SOURCE[0]:-$0}" | tr -d ' ')"

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
    # The word SKIPPED belongs on THIS line, not the third one: run-tests.sh
    # matches section-skip markers at line start (a9hh R1-F1), so a note whose
    # first line does not carry it is a section that vanishes from the tier's
    # completeness accounting. Enforced by runner-completeness.test.sh section 9.
    printf '  note: META-TEST 3 SKIPPED - the direct-invocation leg needs the real bd CLI; bd is absent.\n'
    printf '        session-start.sh exits before the wipe without it, so the leg would\n'
    printf '        prove nothing (the state-equality assertions above ran).\n'
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

# The shim inconsistency QA flagged: check_beads used to bypass the bd wrapper
# every other bd call in the doctor goes through. (The wrapper injected
# --no-daemon until bd 1.1.2 removed the flag; what is asserted is that
# check_beads uses the SHARED shim, not what the shim puts on the command line.)
assert_eq "beads-exception: check_beads routes bd through the shared bd shim" "true" \
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
    # SKIPPED on the marker line — see the META-TEST 3 note above.
    printf '  note: META-TEST 4 SKIPPED - it needs node + %s/node_modules to boot the server.\n' "$MCP_BD_DIR"
    # shellcheck disable=SC2016  # the backticked command is literal text
    printf '        Run `cd %s && npm ci --omit=dev` to enable it.\n' "$MCP_BD_DIR"
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
echo "--- META-TEST 8: bd-version-vs-store-schema is a VALIDATED SET, not a floor or a single pin (claude-workflow-plugin-j7kk, 39cy, we57, 0cr6) ---"
if ! command -v bd >/dev/null 2>&1 || ! command -v dolt >/dev/null 2>&1; then
    printf '  note: META-TEST 8 SKIPPED - it needs both bd and dolt on PATH to build a real embedded-Dolt fixture store.\n'
else
    ONLY_BEADS8=$(all_but beads)

    # A shared schema-bump mutant, used against BOTH fixtures below (8a and
    # 8b): exercises we57's concern (membership, not a floor) independently
    # of 0cr6's (name-independent resolution). Anchored on the VARIABLE via
    # its sentinel line, not the current literal values (unlike META-TEST
    # 4's hardcoded 21->22): DOCTOR_BD_SCHEMA_VALIDATED is expected to change
    # on every deliberate bd upgrade, and a sed anchored to today's exact
    # schema numbers would silently stop mutating (the non-vacuity checks
    # below would catch that, but there is no reason to invite it). Only the
    # SCHEMA half of EACH member is bumped, so this specifically exercises
    # "bd matches one of the validated versions, but neither schema half
    # does" rather than accidentally proving something about the versions.
    MUT8_SCHEMA="$WORK/doctor-mut8-schema.sh"
    sed -E '/^DOCTOR_BD_SCHEMA_VALIDATED=/ s/:[0-9]+/:99/g' "$DOCTOR" > "$MUT8_SCHEMA"
    # DERIVED FROM THE SHIPPED SET, not from today's literal members — the
    # same principle the comment above states for the sed itself. This
    # assertion used to hardcode `1.1.2:99 1.3.0:99`, i.e. exactly two
    # members, and so FAILED the first time a member was added deliberately
    # (1.3.1:66, claude-workflow-plugin-wyt3) while the mutant it checks was
    # correct throughout. A non-vacuity check pinned to the current values of
    # the thing it protects goes red on every legitimate change to that thing.
    MUT8_SHIPPED_SET=$(sed -n 's/^DOCTOR_BD_SCHEMA_VALIDATED="\(.*\)"$/\1/p' "$DOCTOR" | head -1)
    MUT8_MUTANT_SET=$(sed -n 's/^DOCTOR_BD_SCHEMA_VALIDATED="\(.*\)"$/\1/p' "$MUT8_SCHEMA" | head -1)
    assert_eq "META-TEST 8: the shipped validated set is readable and non-empty (else the two checks below are vacuous)" \
        "yes" "$([ -n "$MUT8_SHIPPED_SET" ] && echo yes || echo no)"
    assert_eq "META-TEST 8: the schema-bump mutant changed EVERY member's schema half to :99" \
        "$(printf '%s' "$MUT8_SHIPPED_SET" | sed -E 's/:[0-9]+/:99/g')" "$MUT8_MUTANT_SET"
    assert_eq "META-TEST 8: ...and left every member's VERSION half untouched (only the schema is the variable under test)" \
        "$(printf '%s' "$MUT8_SHIPPED_SET" | sed -E 's/:[0-9]+//g')" "$(printf '%s' "$MUT8_MUTANT_SET" | sed -E 's/:[0-9]+//g')"
    assert_eq "META-TEST 8: the schema-bump mutant differs from the shipped doctor" \
        "differs" "$(cmp -s "$DOCTOR" "$MUT8_SCHEMA" && echo identical || echo differs)"
    assert_eq "META-TEST 8: the schema-bump mutant is still valid bash" "0" \
        "$(bash -n "$MUT8_SCHEMA" 2>/dev/null && echo 0 || echo 1)"

    # A second mutant, targeting 0cr6 specifically: reverts store DISCOVERY
    # to the retired hardcoded assumption (append "/beads" to the resolved
    # base, same effect as the old literal
    # "$TARGET/.beads/embeddeddolt/beads" this task removed) while leaving
    # set-membership logic untouched. Anchored on the function's own base=
    # line so it keeps mutating if that line ever moves, not on a line
    # number.
    MUT8_PATH="$WORK/doctor-mut8-path.sh"
    # [[:space:]]*, not \s: BSD sed's -E does not treat \s as whitespace (it
    # silently matched zero lines when tried — measured directly, not
    # assumed), which would have made this mutation vacuous while still
    # exiting 0. The non-vacuity assertion just below is what would have
    # caught that; POSIX classes are what avoid needing it to.
    # shellcheck disable=SC2016  # $target is literal text matched against the script file, not meant to expand
    sed -E 's#^([[:space:]]*base=")(\$target/\.beads/embeddeddolt)(")$#\1\2/beads\3#' "$DOCTOR" > "$MUT8_PATH"
    # shellcheck disable=SC2016  # same: matching the literal source line, not expanding it
    assert_eq "META-TEST 8: the path-regression mutant's base= line really gained the hardcoded /beads suffix" "true" \
        "$(grep -qE '^[[:space:]]*base="\$target/\.beads/embeddeddolt/beads"$' "$MUT8_PATH" && echo true || echo false)"
    assert_eq "META-TEST 8: the path-regression mutant differs from the shipped doctor" \
        "differs" "$(cmp -s "$DOCTOR" "$MUT8_PATH" && echo identical || echo differs)"
    assert_eq "META-TEST 8: the path-regression mutant is still valid bash" "0" \
        "$(bash -n "$MUT8_PATH" 2>/dev/null && echo 0 || echo 1)"

    # --- 8a: fixture whose store IS named "beads" (--database beads) -------
    SCHEMA_TARGET="$WORK/target-schema-pin"
    mk_target "$SCHEMA_TARGET"
    # --database beads matches THIS repo's OWN embedded-Dolt layout
    # (.beads/embeddeddolt/beads/.dolt) — a fresh `bd init` with no
    # --database names the subdirectory after the CURRENT DIRECTORY instead
    # (measured, claude-workflow-plugin-j7kk/0cr6: a fixture at
    # .../dryrun-fx defaulted to embeddeddolt/dryrun_fx/.dolt), which would
    # silently DISARM the check under test rather than exercise it.
    # mk_target()'s own `.beads/` is an empty placeholder (like
    # mk_probe_sandbox()'s), so it is removed first rather than initialised
    # into.
    rm -rf "$SCHEMA_TARGET/.beads"
    ( cd "$SCHEMA_TARGET" && bd init --database beads --non-interactive >/dev/null 2>&1 )
    if [ ! -d "$SCHEMA_TARGET/.beads/embeddeddolt/beads/.dolt" ]; then
        printf '  note: META-TEST 8a SKIPPED - could not build a real embedded-Dolt fixture store at %s\n' \
            "$SCHEMA_TARGET/.beads/embeddeddolt/beads/.dolt"
    else
        # CONTROL FIRST: the fresh fixture's installed bd/schema is whatever
        # THIS host's bd actually writes on `bd init`, so the control is "the
        # shipped doctor finds this host's live pair in the validated set" —
        # never against a hardcoded expectation this spec would go stale
        # against the day DOCTOR_BD_SCHEMA_VALIDATED is deliberately updated.
        # Unlike the single-pin predecessor this generalises, this control is
        # expected to PASS on EITHER the CI floor (1.1.2:53) or the dev
        # ceiling (1.3.0:66) host — that breadth is the whole point of a set.
        CTRL8A_JSON="$WORK/meta8a-control.json"
        doctor_run "$DOCTOR" "$SCHEMA_TARGET" "$CTRL8A_JSON" --quiet --skip "$ONLY_BEADS8"
        CTRL8A_STATUS=$(status_of "$CTRL8A_JSON" beads)
        assert_eq "META-TEST 8a control: beads PASSES against a freshly bd-init'd 'beads'-named fixture (this host's bd/schema pair is in the validated set by construction)" \
            "PASS" "$CTRL8A_STATUS"
        assert_contains "META-TEST 8a control: ...and the note names the validated set, not just 'OK'" \
            "is in the validated set" \
            "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$CTRL8A_JSON" 2>/dev/null || echo "")"

        # DISCLOSE THE MEASURED BINARY ON BOTH ARMS, pass included. The
        # bd-max lane PASSES this control, and its green is what the claim
        # "1.3.0:66 is validated" rests on — but a pass proves the pair was
        # in the set, not that the pair came from the bd that lane pinned.
        # Those render identically when only failures are diagnosed, which
        # is how the floor lane went green for weeks while (on current
        # evidence) never measuring the floor. A lane that will not say what
        # it measured cannot support a claim about what it validated.
        printf '  [8a] measured: %s\n' \
            "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$CTRL8A_JSON" 2>/dev/null \
                | tr '\n' ' ' | sed 's/  */ /g' | grep -oE '(Measured binary|bd-version-vs-schema)[^|]*' | head -1 | cut -c1-300)"

        if [ "$CTRL8A_STATUS" != "PASS" ]; then
            # NAME THE PAIR THAT WAS ACTUALLY OBSERVED. Without this the
            # control's failure is undiagnosable from a CI log: the doctor
            # DOES compute and report "bd-version-vs-schema DRIFT: installed
            # bd <v> / store schema v<n>", but it lands in a tempdir JSON the
            # assertions read and nothing ever prints. A CI run on 2026-10-01
            # failed here with unchanged code that passed on 2026-09-28, and
            # the log could not say which pair the host had — so the next step
            # had to be guessed rather than read. A check that will not say
            # what it saw cannot be acted on.
            printf '  observed pair (beads detail): %s\n' \
                "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$CTRL8A_JSON" 2>/dev/null | tr '\n' ' ' | sed 's/  */ /g' | cut -c1-400)"
            printf '  validated set: %s\n' \
                "$(sed -n 's/^DOCTOR_BD_SCHEMA_VALIDATED="\(.*\)"$/\1/p' "$DOCTOR" | head -1)"
            # NAME THE BINARY AND EVERY RIVAL ON PATH. The pair alone was not
            # enough. A lane that installs bd 1.1.2 from a pinned,
            # sha256-verified tarball reported "installed bd 1.3.1", and
            # grepping the entire job log showed NO second bd downloaded
            # anywhere — so "which binary answered, and why that one" could
            # not be settled from any artifact the run produced, and each
            # hypothesis cost a 45-minute round. The bd-max lane measures the
            # binary it pinned and passes; this lane does not. That makes the
            # fault lane-specific, which is only actionable if the lane says
            # what it resolved. See claude-workflow-plugin-wyt3.
            printf '  PATH: %s\n' "$PATH"
            printf '  every bd on PATH, in resolution order:\n'
            type -a bd 2>&1 | sed 's/^/    /'
            _bd_n=0
            while IFS= read -r _bd_cand; do
                [ -n "$_bd_cand" ] || continue
                _bd_n=$((_bd_n + 1))
                printf '    [%s] %s -> %s\n' "$_bd_n" "$_bd_cand" \
                    "$("$_bd_cand" --version 2>/dev/null | head -1 | tr -d '\n')"
                if [ "$(head -c 2 "$_bd_cand" 2>/dev/null)" = '#!' ]; then
                    printf '        (script, forwards to) %s\n' \
                        "$(grep -m1 '^exec ' "$_bd_cand" 2>/dev/null)"
                fi
            done < <(type -aP bd 2>/dev/null)
            [ "$_bd_n" -eq 0 ] && printf '    (no bd resolved on PATH at all)\n'
            # The store half is an INDEPENDENT witness: bd 1.1.2 writes
            # schema 53 (measured directly), so a store at v66 was not
            # written by the pinned binary and no version misparse could
            # produce it. Print every store under the fixture, not just the
            # one the doctor resolved, so "resolved the wrong store" and
            # "ran the wrong binary" stay distinguishable.
            printf '  fixture target: %s\n' "$SCHEMA_TARGET"
            printf '  embedded-Dolt stores under it:\n'
            _st_n=0
            while IFS= read -r _st_dot; do
                [ -n "$_st_dot" ] || continue
                _st_n=$((_st_n + 1))
                _st_dir=$(dirname "$_st_dot")
                if command -v dolt >/dev/null 2>&1; then
                    printf '    [%s] %s schema=%s\n' "$_st_n" "$_st_dir" \
                        "$( (cd "$_st_dir" && dolt sql -r csv -q 'SELECT COALESCE(MAX(version),0) FROM schema_migrations' 2>/dev/null | tail -n1) )"
                else
                    printf '    [%s] %s schema=(dolt not on PATH)\n' "$_st_n" "$_st_dir"
                fi
            done < <(find "$SCHEMA_TARGET/.beads" -maxdepth 4 -name '.dolt' -type d 2>/dev/null)
            [ "$_st_n" -eq 0 ] && printf '    (none found)\n'
            printf '  note: META-TEST 8a mutant legs skipped — the control did not pass (this host'\''s bd/schema pair is not in DOCTOR_BD_SCHEMA_VALIDATED), so a mutant FAIL would not be attributable to the pin logic.\n'
        else
            MUT8A_JSON="$WORK/meta8a-mutant.json"
            doctor_run "$MUT8_SCHEMA" "$SCHEMA_TARGET" "$MUT8A_JSON" --quiet --skip "$ONLY_BEADS8"
            assert_eq "META-TEST 8a: a pair outside the validated set flips beads to FAIL (membership, not a floor)" \
                "FAIL" "$(status_of "$MUT8A_JSON" beads)"
            assert_contains "META-TEST 8a: the FAIL detail names the DRIFT and both observed values" \
                "bd-version-vs-schema DRIFT" \
                "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$MUT8A_JSON" 2>/dev/null || echo "")"
            assert_contains "META-TEST 8a: ...names 'not in the validated set', not a stale single-pin phrase" \
                "not in the validated set" \
                "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$MUT8A_JSON" 2>/dev/null || echo "")"
            assert_contains "META-TEST 8a: ...and the fix line tells the operator how to add a new pair deliberately" \
                "DOCTOR_BD_SCHEMA_VALIDATED" \
                "$(jq -r '.checks[] | select(.name == "beads") | .fix' "$MUT8A_JSON" 2>/dev/null || echo "")"
        fi

        # DISARM CONTROL: a target whose .beads/ exists but carries no
        # embedded-Dolt store (mk_target()'s own default shape, and every
        # OTHER section/fixture in this file) must not be penalised by a
        # check this task just added — the pin is informational there, never
        # a FAIL.
        DISARM_JSON="$WORK/meta8-disarm.json"
        doctor_run "$DOCTOR" "$FULL_TARGET" "$DISARM_JSON" --quiet --skip "$ONLY_BEADS8"
        assert_eq "META-TEST 8 disarm: a target with .beads/ but no embedded-Dolt store still PASSES beads (the pin degrades, not fails)" \
            "PASS" "$(status_of "$DISARM_JSON" beads)"
        assert_contains "META-TEST 8 disarm: ...and says so by name" \
            "DISARMED" \
            "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$DISARM_JSON" 2>/dev/null || echo "")"
    fi

    # --- 8b: fixture whose store is NOT named "beads" (claude-workflow-plugin-0cr6) ---
    # THE CASE THAT HAS NEVER BEEN EXERCISED. Every fixture elsewhere in this
    # tier (this file's own 8a above, runner-completeness.test.sh's store
    # canary, model-roles.test.sh's isolation witness) passes `--database
    # beads` deliberately, which matches THIS repo's own layout but is
    # exactly the flag a teammate's target never passes — bd has no
    # awareness of this project's conventions when it is run against a real
    # target the plugin did not create. Omitting the flag here is the point:
    # bd falls back to naming the store after the CURRENT DIRECTORY (non-
    # alphanumerics folded to `_`), reproducing 0cr6's own three-target
    # measurement (`some-real-project` -> `some_real_project`) inside this
    # fixture rather than merely describing it in a comment.
    NONBEADS_TARGET="$WORK/some-real-project"
    mk_target "$NONBEADS_TARGET"
    rm -rf "$NONBEADS_TARGET/.beads"
    ( cd "$NONBEADS_TARGET" && bd init --non-interactive >/dev/null 2>&1 )
    NONBEADS_STORE="$NONBEADS_TARGET/.beads/embeddeddolt/some_real_project"
    if [ ! -d "$NONBEADS_STORE/.dolt" ]; then
        printf '  note: META-TEST 8b SKIPPED - could not build a real embedded-Dolt fixture store at %s (bd may derive a different name on this bd release than the 0cr6 measurement did; if so this skip itself is evidence worth re-measuring, not a fixture bug to route around)\n' \
            "$NONBEADS_STORE"
    else
        # CONTROL FIRST, same discipline as 8a: whatever this host's live
        # bd/schema pair is, it is IDENTICAL to 8a's (same `bd` on PATH) —
        # only the store's DIRECTORY NAME differs between the two fixtures.
        # So this control is expected to reach the exact same verdict 8a's
        # did, and the two assertions below are the direct regression test
        # for 0cr6: NOT disarmed (the defect this task fixes), and REACHING
        # A REAL VERDICT (proving evaluation happened, not a lucky
        # coincidental PASS from a check that silently did nothing).
        CTRL8B_JSON="$WORK/meta8b-control.json"
        doctor_run "$DOCTOR" "$NONBEADS_TARGET" "$CTRL8B_JSON" --quiet --skip "$ONLY_BEADS8"
        CTRL8B_STATUS=$(status_of "$CTRL8B_JSON" beads)
        CTRL8B_DETAIL=$(jq -r '.checks[] | select(.name == "beads") | .detail' "$CTRL8B_JSON" 2>/dev/null || echo "")
        assert_eq "META-TEST 8b control (0cr6): beads reaches the SAME verdict on a non-'beads'-named store as 8a's identically-configured 'beads'-named one" \
            "$CTRL8A_STATUS" "$CTRL8B_STATUS"
        assert_not_contains "META-TEST 8b control (0cr6): THE REGRESSION TEST — a non-'beads'-named target is NOT silently disarmed" \
            "DISARMED" "$CTRL8B_DETAIL"
        assert_contains "META-TEST 8b control (0cr6): ...the store was actually located and evaluated (names the validated set, proving a real comparison ran)" \
            "validated set" "$CTRL8B_DETAIL"

        if [ "$CTRL8B_STATUS" != "PASS" ]; then
            printf '  note: META-TEST 8b mutant legs skipped — the control did not PASS (see 8a'\''s identical gate), so a mutant FAIL would not be attributable to the pin logic.\n'
        else
            # 8b-i: the SAME schema-bump mutant used in 8a, run against the
            # non-'beads' fixture — proves EVALUATION (not just resolution)
            # is name-independent: a validated-set membership failure fires
            # here exactly as it does on a 'beads'-named store.
            MUT8B_SCHEMA_JSON="$WORK/meta8b-mutant-schema.json"
            doctor_run "$MUT8_SCHEMA" "$NONBEADS_TARGET" "$MUT8B_SCHEMA_JSON" --quiet --skip "$ONLY_BEADS8"
            assert_eq "META-TEST 8b-i: a pair outside the validated set flips beads to FAIL on a non-'beads'-named store too" \
                "FAIL" "$(status_of "$MUT8B_SCHEMA_JSON" beads)"
            assert_contains "META-TEST 8b-i: ...naming the DRIFT, not a silent disarm" \
                "bd-version-vs-schema DRIFT" \
                "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$MUT8B_SCHEMA_JSON" 2>/dev/null || echo "")"

            # 8b-ii: THE DIRECT 0cr6 REGRESSION PAIR. The path-regression
            # mutant (store discovery reverted to the retired hardcoded
            # "/beads" assumption) must DISARM FALSELY on this identical
            # fixture, in contrast to the shipped doctor's real PASS above —
            # same input, same host, same live bd/schema pair; the only
            # variable is whether store discovery is resolved or assumed.
            # This is the specific-misbehaviour leg the schema-bump mutant
            # cannot provide: it proves the OLD bug's class is caught, not
            # merely that SOME mutation of this check can be made to fail.
            MUT8B_PATH_JSON="$WORK/meta8b-mutant-path.json"
            doctor_run "$MUT8_PATH" "$NONBEADS_TARGET" "$MUT8B_PATH_JSON" --quiet --skip "$ONLY_BEADS8"
            assert_eq "META-TEST 8b-ii REGRESSION: reverting store discovery to the retired hardcoded assumption DISARMS (falsely) on a non-'beads'-named store" \
                "PASS" "$(status_of "$MUT8B_PATH_JSON" beads)"
            assert_contains "META-TEST 8b-ii REGRESSION: ...and the mutant's note says DISARMED where the shipped doctor's does not (same fixture, same host)" \
                "DISARMED" \
                "$(jq -r '.checks[] | select(.name == "beads") | .detail' "$MUT8B_PATH_JSON" 2>/dev/null || echo "")"
        fi
    fi
fi

echo ""
echo "--- META-TEST 5: session_start is sensitive to a gutted SKILL.md ---"
if ! command -v bd >/dev/null 2>&1; then
    # SKIPPED on the marker line — see the META-TEST 3 note above.
    printf '  note: META-TEST 5 SKIPPED - it needs the real bd CLI (session-start.sh\n'
    printf '        exits before building context without it).\n'
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

# ===========================================================================
echo ""
echo "=== Section 7: the registry SIZE is one number in every surface (+ META-TEST 6) ==="
#
# WHY THIS SECTION EXISTS (claude-workflow-plugin-fkm.1.1)
# Adding `beads_ledger` took the registry from eleven names to twelve, and the
# stale "eleven" survived THREE consecutive remediation rounds — each sweep
# scoped to the vocabulary of the previous fix, each missing a surface the
# previous one had not taught anyone to look at. A code-shaped sweep missed
# prose; a prose-shaped sweep missed the production script's own header and the
# count vocabulary entirely. The last round found stale claims in five files
# nobody had touched, plus a CI vacuity floor still derived from eleven — a
# guard written to catch a truncated report that would have waved through
# exactly the truncation it was written for.
#
# A fourth hand sweep is not a fix. This is: the expected count is DERIVED from
# the sentinel (never typed here), and every tracked surface is scanned for a
# claim that disagrees. Change DOCTOR_CHECK_NAMES without touching the prose and
# this goes red, naming the file and the line.
#
# TWO TIERS, because "makes no claim" means different things:
#   NAMING  the surface's job is to state the count. It must carry AT LEAST ONE
#           claim, so a claim that disappears (reworded, deleted, or wrapped
#           across a line break where a line-oriented scan cannot see it — a
#           real near-miss: INDEX.md's claim was split over two lines) fails
#           here instead of silently leaving the file uncovered.
#   SILENT  a count claim is optional (the doctor script and both installers
#           deliberately say "every other check in the registry" rather than a
#           number) but must be correct if present.
COUNT_SURFACES_NAMING=(
    ".claude/scripts/session-start.sh"              # degraded-session context
    ".claude/commands/workflow-doctor.md"           # the slash command
    ".claude/scripts/tests/workflow-doctor.test.sh" # this spec's own header
    ".claude/scripts/tests/installer-flags.test.sh" # --verify stub rationale
    ".claude/tests/component/specs/installer-target-functional.sh"
    ".claude/tests/component/specs/installer-mcp-config.sh"
    ".claude/tests/component/specs/installer-manifest-parity.sh"
    ".claude/tests/component/specs/installer-v3-upgrade.sh"
    ".claude/tests/component/specs/upgrade-gate-compat.sh"
    "docs/HOOKS.md"                                 # the hook-inventory row
    "docs/QUICKSTART.md"                            # Step 5 + its sample output
    "INDEX.md"                                      # the make doctor bullet
    ".github/workflows/windows-install.yml"         # the vacuity-floor comment
)
COUNT_SURFACES_SILENT=(
    ".claude/scripts/workflow-doctor.sh"            # the WHAT A RUN TOUCHES note
    "install.sh"
    "install.ps1"
)
# NOT tracked, deliberately: CHANGELOG.md, docs/RELEASE_AUDIT.md,
# docs/v4.1-closure.md and docs/plans/v4.1-upgrade-wave.md all say "eleven" and
# all are DATED records of what shipped at v4.1.0, when eleven was true.
# Rewriting history to satisfy a guard would be the worse failure.
#
# HANDOFF.md is the SAME shape, deliberately excluded for the SAME reason,
# not merely forgotten (claude-workflow-plugin-a13r round 3, item 4). Its
# "Verify conditions for v5.0.0 shipped" section quotes TWO LITERAL
# `install.sh --verify` transcripts, captured at HEAD 261e09e and at LIVE-1's
# 2026-09-19 run, when the registry's own summary line reported a
# checks-count of 12 for itself --
# `grep -noniE "$DOCTOR_CLAIM_RE" HANDOFF.md` matches ONLY those two
# quoted-output lines (verified directly, not assumed). The file's several
# OTHER stale "12" mentions are typed as "confirm `12`" / "Expect `12/12`" --
# a shape this regex does not reach at all, adjacent-to-"check" or not -- and
# those were corrected in place with an explicit HISTORICAL pin instead of
# relying on this guard. Tracking the file here would force the two literal
# transcripts to read "13", which they never printed -- the same
# rewriting-history failure the surfaces above exist to avoid.

COUNT_MISSING=""
COUNT_NAMING_PATHS=()
for _s in "${COUNT_SURFACES_NAMING[@]}"; do
    if [ -f "$PROJECT_DIR/$_s" ]; then
        COUNT_NAMING_PATHS+=("$PROJECT_DIR/$_s")
    else
        COUNT_MISSING="$COUNT_MISSING $_s"
    fi
done
COUNT_SILENT_PATHS=()
for _s in "${COUNT_SURFACES_SILENT[@]}"; do
    if [ -f "$PROJECT_DIR/$_s" ]; then
        COUNT_SILENT_PATHS+=("$PROJECT_DIR/$_s")
    else
        COUNT_MISSING="$COUNT_MISSING $_s"
    fi
done
# The committed fixture copies of session-start.sh carry the same sentence.
# `make sync-fixtures` keeps them byte-identical and an L3 spec guards that, but
# scanning them here means an L1-only run still catches a half-done sync.
for _s in "$PROJECT_DIR"/.claude/tests/e2e/fixtures/*/.claude/scripts/session-start.sh; do
    [ -f "$_s" ] && COUNT_NAMING_PATHS+=("$_s")
done

# 7a: every tracked path resolves. A renamed file must drop out LOUDLY — a
# silently-missing surface is an uncovered surface, which is the whole defect.
assert_eq "count-parity: every tracked surface exists" "" "$COUNT_MISSING"

# 7b: NON-VACUITY. If the pattern stopped matching, 7c would pass over an empty
# set. The floor is a count, not a list, so adding a surface does not churn it.
COUNT_TOTAL=$(claim_count "${COUNT_NAMING_PATHS[@]}" "${COUNT_SILENT_PATHS[@]}")
assert_eq "count-parity: the scan finds a plausible number of claims (>= 15)" "true" \
    "$([ "${COUNT_TOTAL:-0}" -ge 15 ] && echo true || echo false)"

# 7c: THE ASSERTION. Every claim, in either tier, states the registry size.
assert_eq "count-parity: no tracked surface claims a count other than the registry's $SENTINEL_COUNT" \
    "" "$(claim_offenders "$SENTINEL_COUNT" "${COUNT_NAMING_PATHS[@]}" "${COUNT_SILENT_PATHS[@]}")"

# 7d: each NAMING surface actually makes a claim (see the tier note above).
COUNT_SILENT_NAMERS=""
for _p in "${COUNT_NAMING_PATHS[@]}"; do
    [ "$(claim_count "$_p")" != "0" ] || COUNT_SILENT_NAMERS="$COUNT_SILENT_NAMERS ${_p#"$PROJECT_DIR"/}"
done
assert_eq "count-parity: every NAMING surface still states the count" "" "$COUNT_SILENT_NAMERS"

# 7e: the surfaces that spell the names OUT must spell out all of them. The
# count and the list go stale together — docs/HOOKS.md's inventory row carried
# the previous count AND omitted `beads_ledger` from its list, so a count-only
# guard would have caught exactly half of that defect.
COUNT_SURFACES_ENUMERATING=(
    "$PROJECT_DIR/.claude/commands/workflow-doctor.md"
    "$PROJECT_DIR/.claude/scripts/workflow-doctor.sh"
    "$PROJECT_DIR/.claude/tests/component/specs/installer-target-functional.sh"
    "$PROJECT_DIR/docs/HOOKS.md"
)
assert_eq "count-parity: every surface that enumerates the names lists all $SENTINEL_COUNT" \
    "" "$(enum_gaps "${COUNT_SURFACES_ENUMERATING[@]}")"

# --- 7f: the Windows CI vacuity floor, which is the one with teeth -----------
#
# `failed == 0` over a truncated report is green by construction, so that job
# refuses to call a run a pass below a floor. The floor used to be a literal 8,
# written when the registry had eleven names and three were skipped; the
# registry moved to twelve and the literal did not, so a report truncated to 8
# entries — the exact shape the guard exists to catch — passed it. The fix was
# to derive the floor from the sentinel in the doctor the install landed, and
# these assertions are what keep it derived.
WIN_WF="$PROJECT_DIR/.github/workflows/windows-install.yml"
# These patterns are PowerShell source being matched as text, so every `$` in
# them is a literal. Single quotes are mandatory and the SC2016 waivers say so
# once here rather than at each use site.
# shellcheck disable=SC2016
CI_LITERAL_FLOOR_RE='\$checkCount[[:space:]]+-lt[[:space:]]+[0-9]'
# shellcheck disable=SC2016
CI_DERIVED_FLOOR_RE='\$checkCount[[:space:]]+-lt[[:space:]]+\$floor'
# shellcheck disable=SC2016
CI_SKIPARG_RE='\-\-skip[[:space:]]+\$skipArg'
# shellcheck disable=SC2016
CI_SKIPLIST_SED='s/^[[:space:]]*\$skipChecks[[:space:]]*=[[:space:]]*@(\(.*\))[[:space:]]*$/\1/p'
assert_eq "ci-floor: the Windows workflow exists" "true" \
    "$([ -f "$WIN_WF" ] && echo true || echo false)"
if [ -f "$WIN_WF" ]; then
    assert_eq "ci-floor: the vacuity floor is read from the DOCTOR_CHECK_NAMES sentinel" "true" \
        "$(grep -q 'DOCTOR_CHECK_NAMES' "$WIN_WF" && echo true || echo false)"
    # A literal comparison is precisely the defect: the count must be compared
    # against the derived floor, never against a typed number.
    assert_eq "ci-floor: the check count is NOT compared against a hardcoded literal" "0" \
        "$(grep -cE "$CI_LITERAL_FLOOR_RE" "$WIN_WF" | tr -d ' ')"
    assert_eq "ci-floor: ...it is compared against the derived floor" "true" \
        "$(grep -qE "$CI_DERIVED_FLOOR_RE" "$WIN_WF" && echo true || echo false)"
    # The skip list is declared once and joined into --skip, so the floor's
    # subtrahend and the invocation can never disagree.
    assert_eq "ci-floor: --skip is passed the joined variable, not a re-typed list" "true" \
        "$(grep -qE "$CI_SKIPARG_RE" "$WIN_WF" && echo true || echo false)"
    CI_SKIPS=$(sed -n "$CI_SKIPLIST_SED" \
        "$WIN_WF" | head -1 | tr -d '" ' | tr ',' ' ')
    CI_SKIP_N=$(printf '%s' "$CI_SKIPS" | wc -w | tr -d ' ')
    assert_eq "ci-floor: the skip list parses to a non-empty set" "true" \
        "$([ "${CI_SKIP_N:-0}" -ge 1 ] && echo true || echo false)"
    # A skip name the registry does not have makes the doctor exit 2 — on a
    # manual-dispatch-only workflow that is a red nobody sees for months.
    CI_SKIP_UNKNOWN=""
    for _n in $CI_SKIPS; do
        [ "$(has_word "$SENTINEL_LIST" "$_n")" = "true" ] || CI_SKIP_UNKNOWN="$CI_SKIP_UNKNOWN $_n"
    done
    assert_eq "ci-floor: every skipped name is a real registry name" "" "$CI_SKIP_UNKNOWN"
    # And the arithmetic the job will do must leave something to assert with.
    CI_FLOOR=$((SENTINEL_COUNT - CI_SKIP_N))
    assert_eq "ci-floor: registry ($SENTINEL_COUNT) minus skips ($CI_SKIP_N) leaves a floor above zero" "true" \
        "$([ "$CI_FLOOR" -ge 1 ] && echo true || echo false)"
fi

echo ""
echo "--- META-TEST 6: the count-parity scan bites in BOTH directions ---"
#
# Leg A is the regression this section was written for: the registry moves and
# the prose does not. Leg B is its mirror: the prose moves and the registry does
# not. Both operate on COPIES; the repo tree is never touched.

# Leg A — one more registry name, prose untouched.
MUT6="$WORK/doctor-mut6.sh"
sed 's/^DOCTOR_CHECK_NAMES="deps /DOCTOR_CHECK_NAMES="deps synthetic_extra /' "$DOCTOR" > "$MUT6"
MUT6_COUNT=$(printf '%s' "$(sentinel_names "$MUT6")" | wc -w | tr -d ' ')
assert_eq "META-TEST 6A: the mutant registry really declares one more name" \
    "$((SENTINEL_COUNT + 1))" "$MUT6_COUNT"
assert_eq "META-TEST 6A: the mutant is still valid bash" "0" \
    "$(bash -n "$MUT6" 2>/dev/null && echo 0 || echo 1)"
MUT6A_OFFENDERS=$(claim_offenders "$MUT6_COUNT" "${COUNT_NAMING_PATHS[@]}" "${COUNT_SILENT_PATHS[@]}")
assert_eq "META-TEST 6A: bumping the registry WITHOUT touching the prose flags every surface" "true" \
    "$([ -n "$MUT6A_OFFENDERS" ] && echo true || echo false)"
# Every NAMING surface should be among the flagged, not just one of them —
# otherwise the scan is only watching a corner of the tracked set.
MUT6A_N=$(printf '%s' "$MUT6A_OFFENDERS" | wc -w | tr -d ' ')
assert_eq "META-TEST 6A: ...and flags ALL of them, not a lucky one" "$COUNT_TOTAL" "$MUT6A_N"

# Leg B — the prose moves, the registry does not. The target is
# docs/QUICKSTART.md's sample doctor output, one of the surfaces the last review
# round found stale (docs/HOOKS.md's inventory row was the other). Both the
# search and the replacement are BUILT from $SENTINEL_COUNT rather than typed.
# Spelling the previous count out here would plant a stale claim in a tracked
# surface and 7c would flag this spec for describing its own META — which is
# not hypothetical: the first draft of this very comment did exactly that, and
# the section caught it on its first run.
MUT6B_SRC="$PROJECT_DIR/docs/QUICKSTART.md"
MUT6B="$WORK/quickstart-mut6.md"
sed "s/$SENTINEL_COUNT check(s)/$((SENTINEL_COUNT - 1)) check(s)/" "$MUT6B_SRC" > "$MUT6B"
assert_eq "META-TEST 6B: the prose mutant really differs from the original" "1" \
    "$(cmp -s "$MUT6B" "$MUT6B_SRC" && echo 0 || echo 1)"
MUT6B_OFF=$(claim_offenders "$SENTINEL_COUNT" "$MUT6B")
assert_eq "META-TEST 6B: exactly the one mutated claim is flagged" "1" \
    "$(printf '%s' "$MUT6B_OFF" | wc -w | tr -d ' ')"
assert_contains "META-TEST 6B: ...and the report names the wrong value it found" \
    "=$((SENTINEL_COUNT - 1))" "$MUT6B_OFF"
assert_eq "META-TEST 6B control: the UNMUTATED surface is clean" "" \
    "$(claim_offenders "$SENTINEL_COUNT" "$MUT6B_SRC")"

# Leg C — the floor guard. A copy of the workflow with the literal restored must
# fail 7e, so "no hardcoded literal" is a real assertion and not a tautology.
MUT6C="$WORK/windows-install-mut6.yml"
# Same literal-`$` reasoning as the CI_*_RE patterns above: this is PowerShell
# text, and the replacement side has to keep `$checkCount` verbatim.
# shellcheck disable=SC2016
sed 's/\$checkCount -lt \$floor/$checkCount -lt 8/' "$WIN_WF" > "$MUT6C"
assert_eq "META-TEST 6C: the workflow mutant really restored the literal" "1" \
    "$(grep -cE "$CI_LITERAL_FLOOR_RE" "$MUT6C" | tr -d ' ')"
assert_eq "META-TEST 6C control: the shipped workflow has no such literal" "0" \
    "$(grep -cE "$CI_LITERAL_FLOOR_RE" "$WIN_WF" | tr -d ' ')"

# Leg D — the enumeration guard. Delete one name from a copy of the inventory
# row and 7e must name it. This reproduces the shipped defect exactly: the row
# carried the previous count and its list had no `beads_ledger` in it.
MUT6D_SRC="$PROJECT_DIR/docs/HOOKS.md"
MUT6D="$WORK/hooks-mut6d.md"
# Backticks are markdown being matched as text, not command substitution.
# shellcheck disable=SC2016
sed 's/, `beads_ledger`//' "$MUT6D_SRC" > "$MUT6D"
assert_eq "META-TEST 6D: the mutant really dropped the name" "0" \
    "$(grep -cF 'beads_ledger' "$MUT6D" | tr -d ' ')"
assert_contains "META-TEST 6D: the enumeration guard names the dropped check" \
    ":beads_ledger" "$(enum_gaps "$MUT6D")"
assert_eq "META-TEST 6D control: the shipped row has no gaps" "" "$(enum_gaps "$MUT6D_SRC")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: agents — a masked tools_line read must not exempt a core agent from the bd-grant check (claude-workflow-plugin-i8cx wave 2, META-TEST 9) ==="
#
# THE HAZARD. tools_line used to be a bare `sed -n '...p' | head -1` capture.
# Without pipefail the pipe's exit status is head's — and head exits 0 on any
# input, including none, so a masked sed failure produced the SAME empty
# tools_line as a genuinely-absent `tools:` line. Both paths silently
# `continue`d past the bd-grant verification for that agent. For a CORE
# agent (orchestrator/qa/backend/frontend/devops) that is a check reporting
# PASS — "every MCP-granting agent carries both bd tool namespaces" — on
# evidence it never actually read, inside the one tool whose job is to catch
# exactly that. Section 8 drives the SHIPPED doctor with a `sed` on PATH that
# fails like a real read failure (no stdout, non-zero exit); META-TEST 9
# reverts the fix on a mutant copy and shows the false PASS return.

AGENTS_TARGET="$WORK/target-agents-8"
mk_target "$AGENTS_TARGET"
ONLY_AGENTS=$(all_but agents)

# 8.1 CONTROL — the real, shipped agent files, no fault injection: PASS.
# Establishes the fixture is sound before any fault is injected.
CTRL8A_JSON="$WORK/section8-control.json"
doctor_run "$DOCTOR" "$AGENTS_TARGET" "$CTRL8A_JSON" --quiet --skip "$ONLY_AGENTS"
assert_eq "8.1 control: agents PASSES against the real, unmutated agent files" \
    "PASS" "$(status_of "$CTRL8A_JSON" agents)"

if [ "$(status_of "$CTRL8A_JSON" agents)" != "PASS" ]; then
    printf '  note: Section 8 mutant/fault legs skipped — the control did not pass, so a\n'
    printf '        FAIL under fault injection would not be attributable to this guard.\n'
else
    # 8.2 MUTATION — fault injection against the SHIPPED doctor (not a source
    # mutation: the guard is a runtime rc check, only a runtime failure trips
    # it). A `sed` ahead of the real one on PATH that behaves like a genuine
    # read failure: nothing on stdout, non-zero exit.
    FAULT_BIN_8=$(mktemp -d "$WORK/fault-sed-8.XXXXXX")
    FAULT_LOG_8="$WORK/fault-sed-8.log"
    : > "$FAULT_LOG_8"
    cat > "$FAULT_BIN_8/sed" <<STUB
#!/bin/bash
printf 'invoked\n' >> "$FAULT_LOG_8"
exit 9
STUB
    chmod +x "$FAULT_BIN_8/sed"

    MUT8A_JSON="$WORK/section8-fault.json"
    MUT8A_RC=0
    MUT8A_OUT=$(PATH="$FAULT_BIN_8:$PATH" bash "$DOCTOR" --target "$AGENTS_TARGET" \
        --json-out "$MUT8A_JSON" --quiet --skip "$ONLY_AGENTS" 2>&1) || MUT8A_RC=$?
    assert_eq "8.2 non-vacuity: the fault-injected sed was actually invoked" \
        "yes" "$([ -s "$FAULT_LOG_8" ] && echo yes || echo no)"
    # --quiet's own contract (--help) is "FAIL lines... still print" — the
    # human-readable renderer must show this failure too, not just the JSON.
    assert_contains "8.2 SPECIFIC: the --quiet human renderer still prints the FAIL line" \
        "FAIL agents" "$MUT8A_OUT"
    assert_eq "8.2 SPECIFIC: agents flips to FAIL under the read fault (not a silent PASS)" \
        "FAIL" "$(status_of "$MUT8A_JSON" agents)"
    assert_eq "8.2 SPECIFIC: the doctor's own exit code reflects the failure" \
        "1" "$MUT8A_RC"
    MUT8A_DETAIL=$(jq -r '.checks[] | select(.name == "agents") | .detail' "$MUT8A_JSON" 2>/dev/null || echo "")
    # Every CORE agent is named, not just one — the fault hits every
    # extraction attempt, and the message must say WHY (read failure) rather
    # than something that reads like a config problem.
    for core in orchestrator qa backend frontend devops; do
        assert_contains "8.2 SPECIFIC: names $core.md's read failure by the guard's own problem tag" \
            ".claude/agents/$core.md:tools-line-present-but-unreadable" "$MUT8A_DETAIL"
    done

    # 8.3 RESTORE CONTROL — same target, fault-injected sed removed: PASS again.
    CTRL8B_JSON="$WORK/section8-restore.json"
    doctor_run "$DOCTOR" "$AGENTS_TARGET" "$CTRL8B_JSON" --quiet --skip "$ONLY_AGENTS"
    assert_eq "8.3 RESTORE CONTROL: shim removed, same target, agents PASSES again" \
        "PASS" "$(status_of "$CTRL8B_JSON" agents)"

    # 8.4 A GENUINELY-ABSENT tools: line must still `continue` quietly (via
    # the pre-existing no-tools key check) and must NOT pick up the NEW
    # tools-line-present-but-unreadable tag, even with the SAME fault
    # injected — the two causes of "no tools_line" must not be conflated in
    # either direction.
    NOTOOLS_TARGET="$WORK/target-agents-8-notools"
    mkdir -p "$NOTOOLS_TARGET/.claude/agents" "$NOTOOLS_TARGET/.claude-plugin"
    printf -- '---\nname: orchestrator\ndescription: stub\nmodel: claude-base-0\n---\nbody\n' \
        > "$NOTOOLS_TARGET/.claude/agents/orchestrator.md"
    printf '{"agents": [".claude/agents/orchestrator.md"]}' \
        > "$NOTOOLS_TARGET/.claude-plugin/plugin.json"
    NOTOOLS_JSON="$WORK/section8-notools.json"
    # Only the --json-out artifact is inspected here (8.2 already covers the
    # human-readable renderer); stdout+stderr are discarded rather than
    # captured unused.
    PATH="$FAULT_BIN_8:$PATH" bash "$DOCTOR" --target "$NOTOOLS_TARGET" \
        --json-out "$NOTOOLS_JSON" --quiet --skip "$ONLY_AGENTS" >/dev/null 2>&1 || true
    NOTOOLS_DETAIL=$(jq -r '.checks[] | select(.name == "agents") | .detail' "$NOTOOLS_JSON" 2>/dev/null || echo "")
    assert_contains "8.4 a genuinely-absent tools: line is still reported as no-tools (pre-existing check, unaffected)" \
        "orchestrator.md:no-tools" "$NOTOOLS_DETAIL"
    assert_not_contains "8.4 ...and is NEVER tagged tools-line-present-but-unreadable (the two causes must not be conflated)" \
        "tools-line-present-but-unreadable" "$NOTOOLS_DETAIL"
fi

echo ""
echo "--- META-TEST 9: reverting the tools_line guard on a mutant copy reproduces the ORIGINAL false PASS ---"
# Anchored on the sentinel BEGIN/END comment pair (i8cx house rule for new
# guards), found by text and spliced by line number — never a hardcoded line
# number in this file, so the anchor stays valid across unrelated edits.
BEGIN_LN9=$(grep -n '^        # tools_line extraction BEGIN (i8cx wave 2)$' "$DOCTOR" | head -1 | cut -d: -f1)
END_LN9=$(grep -n '^        # tools_line extraction END (i8cx wave 2)$' "$DOCTOR" | head -1 | cut -d: -f1)
if [ -z "$BEGIN_LN9" ] || [ -z "$END_LN9" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST 9: the i8cx wave 2 sentinel pair was not found — the guard's anchor moved or was renamed")
    printf '  FAIL: META-TEST 9: sentinel pair not found; cannot build the mutant\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: META-TEST 9 non-vacuity: the sentinel pair was found (BEGIN line %s, END line %s)\n' \
        "$BEGIN_LN9" "$END_LN9"
    MUT9_REPL="$WORK/mut9-replacement.txt"
    cat > "$MUT9_REPL" <<'REPL'
        tools_line=$(printf '%s\n' "$fm" | sed -n 's/^tools:[[:space:]]*//p' | head -1)
REPL
    MUT9="$WORK/doctor-mut9.sh"
    {
        sed -n "1,$((BEGIN_LN9 - 1))p" "$DOCTOR"
        cat "$MUT9_REPL"
        sed -n "$((END_LN9 + 1)),\$p" "$DOCTOR"
    } > "$MUT9"
    assert_eq "META-TEST 9: the mutant really differs from the shipped doctor" \
        "differs" "$(cmp -s "$MUT9" "$DOCTOR" && echo same || echo differs)"
    assert_eq "META-TEST 9: the mutant is still valid bash" "0" \
        "$(bash -n "$MUT9" 2>/dev/null && echo 0 || echo 1)"
    assert_not_contains "META-TEST 9: the mutant lost the guard's problem tag entirely" \
        "tools-line-present-but-unreadable" "$(cat "$MUT9")"
    chmod +x "$MUT9"

    if [ -d "${AGENTS_TARGET:-/nonexistent}" ] && [ -d "${FAULT_BIN_8:-/nonexistent}" ]; then
        MUT9_JSON="$WORK/section8-meta9.json"
        MUT9_RC=0
        PATH="$FAULT_BIN_8:$PATH" bash "$MUT9" --target "$AGENTS_TARGET" \
            --json-out "$MUT9_JSON" --quiet --skip "$ONLY_AGENTS" >/dev/null 2>&1 || MUT9_RC=$?
        assert_eq "META-TEST 9: WITHOUT the guard, the identical fault injection is masked -- agents falsely PASSES (the original bug)" \
            "PASS" "$(status_of "$MUT9_JSON" agents)"
        assert_eq "META-TEST 9: ...and the doctor's own exit code says the same (0, healthy)" \
            "0" "$MUT9_RC"
    else
        printf '  note: META-TEST 9 fault-injection leg skipped -- Section 8 fixtures were not built (see the note above).\n'
    fi
fi

# ===========================================================================
echo ""
echo "=== Section 9: model_parity actually gates (claude-workflow-plugin-a13r, META-TEST 10) ==="
#
# WHY THIS EXISTS. claude-workflow-plugin-a13r's round-2 independent review
# found the check-parity FIX real but unwired: nothing but a human running
# model-select.sh by hand ever saw its exit code, so a drifted pin could sit
# forever behind a doctor that only ever asked file-existence questions.
# model_parity closes that gap; this section proves the closure is real,
# not merely present. mk_target() does NOT copy .claude/model-roles or the
# model-select cache (neither is part of what the doctor's OTHER checks
# read), so every role in these fixtures uses the fail-open `top` default
# deliberately -- the point here is the GATE'S plumbing (a real drift
# reaching the doctor's own FAIL/exit code, and an unverifiable cache
# reaching an honest SKIP rather than either extreme), not model-roles'
# parsing, which Section 14 of model-roles.test.sh already owns in full.
#
# seed_model_pins <dir> <id> -- rewrite EVERY copied agent's model: line to
# <id>, so a target's agreement/drift shape is deterministic regardless of
# what the live repo's own pins currently are.
seed_model_pins() {
    local d="$1" id="$2" f tmp
    for f in "$d"/.claude/agents/*.md; do
        [ -f "$f" ] || continue
        tmp="$f.tmp.$$"
        sed "s/^model:.*/model: $id/" "$f" > "$tmp" && mv "$tmp" "$f"
    done
}

# seed_cache <dir> <id> -- a minimal, valid model-select cache listing
# exactly one candidate, so `top` resolves to <id> unambiguously with no
# ranking file needed.
seed_cache() {
    local d="$1" id="$2"
    mkdir -p "$d/.claude/.qa-tracking"
    cat > "$d/.claude/.qa-tracking/model-select-cache.json" <<JSON
{"timestamp": $(date +%s), "models": [{"id":"$id","max_input_tokens":400000,"created_at":"2026-07-01T00:00:00Z"}]}
JSON
}

# write_helperfail_stub <dir> -- install a role/agent map helper that prints
# a COMPLETE, correctly-agreeing map (so a naive reader could mistake it for
# healthy data -- the coincidental-OK trap) and then exits nonzero anyway.
# model-roles.test.sh's 14.11 already proves check-parity itself catches
# this shape; 9.5 / META-TEST 12 below prove what happens ONE LEVEL UP, at
# this doctor (claude-workflow-plugin-a13r round 4, item (b)).
write_helperfail_stub() {
    local d="$1"
    cat > "$d/.claude/scripts/workflow-model-apply.sh" <<'STUB'
#!/bin/bash
printf 'designer\tdesigner\n'
printf 'design_reviewer\tdesign-reviewer\n'
printf 'orchestrator\torchestrator\n'
printf 'implementer\tbackend\n'
printf 'implementer\tfrontend\n'
printf 'implementer\tdevops\n'
printf 'reviewer\tqa\n'
printf 'reviewer\tgrader\n'
printf 'reviewer\tjudge\n'
exit 7
STUB
    chmod +x "$d/.claude/scripts/workflow-model-apply.sh"
}

ONLY_MP="$(all_but model_parity)"

# --- 9.1 POSITIVE: every agent pin agrees with the seeded cache -------------
MP_AGREE="$WORK/mp-agree"
mk_target "$MP_AGREE"
seed_model_pins "$MP_AGREE" "claude-sec9-agree"
seed_cache "$MP_AGREE" "claude-sec9-agree"
MP1_JSON="$WORK/mp1.json"
doctor_run "$DOCTOR" "$MP_AGREE" "$MP1_JSON" --quiet --skip "$ONLY_MP"
assert_eq "9.1 a target whose agent pins agree with the seeded cache PASSES model_parity" \
    "PASS" "$(status_of "$MP1_JSON" model_parity)"
assert_contains "9.1 ...and the detail carries check-parity's own OK marker" \
    "check-parity: OK" "$(jq -r '(.checks[]|select(.name=="model_parity").detail)//""' "$MP1_JSON")"

# --- 9.2 NEGATIVE: one agent's pin is deliberately drifted, landing-proven --
MP_DRIFT="$WORK/mp-drift"
mk_target "$MP_DRIFT"
seed_model_pins "$MP_DRIFT" "claude-sec9-agree"
seed_cache "$MP_DRIFT" "claude-sec9-agree"
DRIFT_TMP="$MP_DRIFT/.claude/agents/qa.md.tmp"
sed "s/^model:.*/model: claude-sec9-DRIFTED/" "$MP_DRIFT/.claude/agents/qa.md" > "$DRIFT_TMP" \
    && mv "$DRIFT_TMP" "$MP_DRIFT/.claude/agents/qa.md"
assert_eq "9.2 landing proof: qa.md is genuinely drifted from the seeded id before the doctor ever runs" \
    "model: claude-sec9-DRIFTED" "$(grep '^model:' "$MP_DRIFT/.claude/agents/qa.md")"
MP2_JSON="$WORK/mp2.json"
doctor_run "$DOCTOR" "$MP_DRIFT" "$MP2_JSON" --quiet --skip "$ONLY_MP"
assert_eq "9.2 a genuinely drifted agent pin FAILS model_parity, and the doctor's own exit code says so" \
    "1" "$DOCTOR_RC"
assert_eq "9.2 ...specifically, model_parity itself is the FAIL" \
    "FAIL" "$(status_of "$MP2_JSON" model_parity)"
MP2_DETAIL=$(jq -r '(.checks[]|select(.name=="model_parity").detail)//""' "$MP2_JSON")
assert_contains "9.2 ...naming check-parity's own DISAGREEMENT verdict" \
    "CONFIG/FILE DISAGREEMENT" "$MP2_DETAIL"
assert_contains "9.2 ...and the SPECIFIC file, reviewer/qa" \
    "reviewer/qa: agent file has 'claude-sec9-DRIFTED'" "$MP2_DETAIL"
MP2_FIX=$(jq -r '(.checks[]|select(.name=="model_parity").fix)//""' "$MP2_JSON")
assert_contains "9.2 ...and the FAIL carries a fix: line naming model-select.sh apply" \
    "model-select.sh apply" "$MP2_FIX"

# --- 9.3 UNVERIFIABLE: no cache at all -- SELF-SKIPS, never a silent PASS --
#
# SKIP, not FAIL. MEASURED (not assumed): install.sh's own functional-
# verification block invokes the target's workflow-doctor.sh with NO --skip
# flags at all (see install.sh's "Functional verification" section), and
# nothing in the install path ever populates the model-select cache — so a
# FAIL mapping here broke "installed, verification FAILED" (exit 3) for
# EVERY fresh install with no ANTHROPIC_API_KEY, which is this plugin's
# common case (Claude Code's typical auth is subscription/OAuth, not a raw
# API key). SKIP still satisfies "never read as a pass" — this file's own
# header: "a skipped check must count as SKIPPED, never as passed".
MP_NOCACHE="$WORK/mp-nocache"
mk_target "$MP_NOCACHE"
seed_model_pins "$MP_NOCACHE" "claude-sec9-agree"
assert_eq "9.3 landing proof: mk_target genuinely leaves no model-select cache behind" \
    "no" "$([ -f "$MP_NOCACHE/.claude/.qa-tracking/model-select-cache.json" ] && echo yes || echo no)"
MP3_JSON="$WORK/mp3.json"
doctor_run "$DOCTOR" "$MP_NOCACHE" "$MP3_JSON" --quiet --skip "$ONLY_MP"
assert_eq "9.3 an unpopulated cache SELF-SKIPs model_parity (never FAILs the install, never a silent PASS)" \
    "SKIP" "$(status_of "$MP3_JSON" model_parity)"
assert_eq "9.3 ...and the doctor's OWN exit code stays 0 (a fresh install with no API key must still verify clean)" \
    "0" "$DOCTOR_RC"
MP3_DETAIL=$(jq -r '(.checks[]|select(.name=="model_parity").detail)//""' "$MP3_JSON")
assert_contains "9.3 ...says UNVERIFIABLE" "UNVERIFIABLE" "$MP3_DETAIL"
assert_contains "9.3 ...specifically tagged NO-DATA, not HELPER-FAILURE (claude-workflow-plugin-a13r round 4, item (b))" \
    "UNVERIFIABLE:NO-DATA" "$MP3_DETAIL"
assert_not_contains "9.3 ...and is never mistaken for a pass" "check-parity: OK" "$MP3_DETAIL"
MP3_FIX=$(jq -r '(.checks[]|select(.name=="model_parity").fix)//""' "$MP3_JSON")
assert_contains "9.3 ...and the fix: line (carried in the JSON regardless of status) explains how to populate the cache with the command that actually works (round 4 MEDIUM: status only reads, resolve populates)" \
    "model-select.sh resolve" "$MP3_FIX"

# --- 9.4 DOCTOR-LEVEL CHMOD CONTROL (round 3, item 2) -----------------------
#
# WHY THIS EXISTS. model-roles.test.sh Section 14.9 already proves
# model-select.sh ITSELF folds an unreadable agent file into DISAGREEMENT
# rather than silently excluding it -- but that test drives model-select.sh
# DIRECTLY against a hand-built sandbox that already has the file in place,
# unreadable. It never exercises mk_probe_sandbox's own `cp -R`, which is
# the ACTUAL path a real target's chmod-000 file travels through before
# model_parity ever sees it, and `cp -R ... 2>/dev/null || true` silently
# DROPS a file it cannot read (confirmed directly: `cp -R` on this platform
# exits 1, prints "Permission denied", and the destination directory simply
# never gets the file -- readable siblings still copy). Absent reads as a
# LEGITIMATE "never installed" exclusion (14.6's shape), not a permission
# problem -- the original false-success shape reappearing at THIS
# integration boundary, invisible to a unit test that skips the boundary
# entirely. This is the DURABLE path: mk_target -> chmod 000 -> the REAL
# doctor_run, which calls the REAL workflow-doctor.sh, which calls its own
# REAL mk_probe_sandbox.
if [ "$(id -u)" = "0" ]; then
    printf '  note: 9.4 SKIPPED - running as root, chmod 000 does not block a read, so this trigger cannot fire here\n'
else
    MP_UNREADABLE="$WORK/mp-unreadable"
    mk_target "$MP_UNREADABLE"
    seed_model_pins "$MP_UNREADABLE" "claude-sec9-agree"
    seed_cache "$MP_UNREADABLE" "claude-sec9-agree"
    chmod 000 "$MP_UNREADABLE/.claude/agents/qa.md"
    assert_eq "9.4 landing proof: qa.md is genuinely unreadable by this process before the doctor ever runs" \
        "no" "$([ -r "$MP_UNREADABLE/.claude/agents/qa.md" ] && echo yes || echo no)"
    MP4_JSON="$WORK/mp4.json"
    doctor_run "$DOCTOR" "$MP_UNREADABLE" "$MP4_JSON" --quiet --skip "$ONLY_MP"
    chmod 644 "$MP_UNREADABLE/.claude/agents/qa.md"
    assert_eq "9.4 SPECIFIC MISBEHAVIOUR (of the OLD sandbox copy): an unreadable agent file on the REAL target FAILS model_parity, not a silent PASS" \
        "FAIL" "$(status_of "$MP4_JSON" model_parity)"
    assert_eq "9.4 ...and the doctor's own exit code says so" "1" "$DOCTOR_RC"
    MP4_DETAIL=$(jq -r '(.checks[]|select(.name=="model_parity").detail)//""' "$MP4_JSON")
    assert_contains "9.4 ...naming the SPECIFIC file the sandbox could not copy" \
        "qa.md" "$MP4_DETAIL"
    assert_contains "9.4 ...and saying WHY (unreadable, not just absent)" \
        "unreadable file(s) that the probe sandbox could not copy" "$MP4_DETAIL"
    MP4_FIX=$(jq -r '(.checks[]|select(.name=="model_parity").fix)//""' "$MP4_JSON")
    assert_contains "9.4 ...and the fix: line names the actual remedy (chmod), not model-select.sh apply" \
        "chmod +r" "$MP4_FIX"
fi

# --- 9.5 UNVERIFIABLE:HELPER-FAILURE FAILs, not SKIPs (round 4, item (b)) --
#
# WHY THIS EXISTS. Round 4's independent review found that check-parity
# correctly returns 2 (UNVERIFIABLE) on a nonzero or partial
# --print-role-map, but this doctor mapped EVERY rc=2 to SKIP regardless of
# WHY -- so "a broken --print-role-map produces zero failed checks and
# doctor exit 0", indistinguishable from the normal cold-cache SKIP proven
# in 9.3. check-parity's detail line now carries a machine-readable tag
# (UNVERIFIABLE:NO-DATA vs UNVERIFIABLE:HELPER-FAILURE); this doctor's rc=2
# handling branches on it. This is the DURABLE path: mk_target -> a broken
# workflow-model-apply.sh -> the REAL doctor_run.
MP_HELPERFAIL="$WORK/mp-helperfail"
mk_target "$MP_HELPERFAIL"
seed_model_pins "$MP_HELPERFAIL" "claude-sec9-agree"
seed_cache "$MP_HELPERFAIL" "claude-sec9-agree"
write_helperfail_stub "$MP_HELPERFAIL"
assert_eq "9.5 landing proof: the stub genuinely exits nonzero" \
    "7" "$(bash "$MP_HELPERFAIL/.claude/scripts/workflow-model-apply.sh" --print-role-map >/dev/null 2>&1; echo $?)"
assert_eq "9.5 landing proof: the stub's map is genuinely COMPLETE (all 9 members, the coincidental-OK trap if the exit code were ignored)" \
    "9" "$(bash "$MP_HELPERFAIL/.claude/scripts/workflow-model-apply.sh" --print-role-map 2>/dev/null | grep -c . | tr -d '[:space:]')"
MP5_JSON="$WORK/mp5.json"
doctor_run "$DOCTOR" "$MP_HELPERFAIL" "$MP5_JSON" --quiet --skip "$ONLY_MP"
assert_eq "9.5 a detected helper failure FAILS model_parity, and the doctor's own exit code says so" \
    "1" "$DOCTOR_RC"
assert_eq "9.5 ...specifically, model_parity itself is the FAIL, not a SKIP" \
    "FAIL" "$(status_of "$MP5_JSON" model_parity)"
MP5_DETAIL=$(jq -r '(.checks[]|select(.name=="model_parity").detail)//""' "$MP5_JSON")
assert_contains "9.5 ...naming check-parity's own HELPER-FAILURE tag" \
    "UNVERIFIABLE:HELPER-FAILURE" "$MP5_DETAIL"
assert_contains "9.5 ...and the nonzero exit itself" \
    "print-role-map exited 7" "$MP5_DETAIL"
MP5_FIX=$(jq -r '(.checks[]|select(.name=="model_parity").fix)//""' "$MP5_JSON")
assert_contains "9.5 ...and the fix: line names the ACTUAL remedy (read the helper's own failure), not a cache to populate" \
    "workflow-model-apply.sh --print-role-map" "$MP5_FIX"
assert_not_contains "9.5 ...and the fix: line does NOT send the operator chasing a cache that was never the problem" \
    "model-select.sh resolve" "$MP5_FIX"

echo ""
echo "--- META-TEST 11: the unreadable-agent-file gate is what actually blocks the false PASS ---"
#
# A COPY of the shipped doctor with ONLY the new fail-closed gate in
# check_model_parity disarmed (mk_probe_sandbox's own detection is left
# running and still writes the sentinel; this mutant just never reads it)
# reproduces the ORIGINAL defect exactly: the sandbox is quietly missing
# qa.md, model-select.sh's own missing-agent-file exclusion (legitimate for
# a role that was never installed) cannot tell that apart from a
# permission problem, every OTHER file still agrees, and the run reports a
# clean PASS over a target that, in reality, has a file nobody could read.
if [ "$(id -u)" = "0" ]; then
    printf '  note: META-TEST 11 SKIPPED - running as root, chmod 000 does not block a read, so this trigger cannot fire here\n'
else
    MUT11="$WORK/doctor-mut11.sh"
    # shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
    sed 's/if \[ -s "\$unreadable_marker" \]; then/if false; then/' "$DOCTOR" > "$MUT11"
    # shellcheck disable=SC2016
    assert_eq "META-TEST 11 non-vacuity: the fail-closed gate was found and disarmed" \
        "0" "$(grep -c 'if \[ -s "\$unreadable_marker" \]; then' "$MUT11" | tr -d '[:space:]')"
    assert_eq "META-TEST 11 non-vacuity: the mutant differs from the shipped doctor" \
        "differs" "$(cmp -s "$MUT11" "$DOCTOR" && echo same || echo differs)"
    assert_eq "META-TEST 11 non-vacuity: the mutant is still valid bash" "0" \
        "$(bash -n "$MUT11" 2>/dev/null && echo 0 || echo 1)"
    chmod +x "$MUT11"

    MP_UNREADABLE_M="$WORK/mp-unreadable-mut"
    mk_target "$MP_UNREADABLE_M"
    seed_model_pins "$MP_UNREADABLE_M" "claude-sec9-agree"
    seed_cache "$MP_UNREADABLE_M" "claude-sec9-agree"
    chmod 000 "$MP_UNREADABLE_M/.claude/agents/qa.md"
    MUT11_JSON="$WORK/mut11.json"
    doctor_run "$MUT11" "$MP_UNREADABLE_M" "$MUT11_JSON" --quiet --skip "$ONLY_MP"
    chmod 644 "$MP_UNREADABLE_M/.claude/agents/qa.md"
    assert_eq "META-TEST 11 SPECIFIC MISBEHAVIOUR: WITHOUT the gate, the identical unreadable-file target WRONGLY PASSES model_parity" \
        "PASS" "$(status_of "$MUT11_JSON" model_parity)"
    assert_eq "META-TEST 11 ...and the mutant's own exit code says healthy (0), over a target with a file nobody could read" \
        "0" "$DOCTOR_RC"

    # RESTORE CONTROL: identical fixture shape, freshly built, the SHIPPED
    # doctor -- still correctly FAILs.
    MP_UNREADABLE_MC="$WORK/mp-unreadable-ctrl"
    mk_target "$MP_UNREADABLE_MC"
    seed_model_pins "$MP_UNREADABLE_MC" "claude-sec9-agree"
    seed_cache "$MP_UNREADABLE_MC" "claude-sec9-agree"
    chmod 000 "$MP_UNREADABLE_MC/.claude/agents/qa.md"
    MUT11C_JSON="$WORK/mut11-ctrl.json"
    doctor_run "$DOCTOR" "$MP_UNREADABLE_MC" "$MUT11C_JSON" --quiet --skip "$ONLY_MP"
    chmod 644 "$MP_UNREADABLE_MC/.claude/agents/qa.md"
    assert_eq "META-TEST 11 RESTORE CONTROL: the SHIPPED doctor, identical fixture shape, still FAILS model_parity" \
        "FAIL" "$(status_of "$MUT11C_JSON" model_parity)"
    assert_eq "META-TEST 11 RESTORE CONTROL: ...and the doctor's own exit code is 1" "1" "$DOCTOR_RC"
fi

echo ""
echo "--- META-TEST 10: mk_probe_sandbox's cache copy is what model_parity actually reads ---"
#
# claude-workflow-plugin-a13r taught mk_probe_sandbox to copy
# .claude/.qa-tracking/model-select-cache.json (check-parity NEVER fetches —
# it is the only external input this check has besides the config/agent
# files the sandbox already copied). A COPY of the shipped doctor with that
# one addition removed, run against 9.1's own AGREEING fixture, must turn a
# real PASS into a SKIP (the sandbox's cache is genuinely gone, so
# check-parity is honestly UNVERIFIABLE, not agreeing by luck) -- proving
# the copy is what lets the sandboxed check see the target's real cache at
# all, not an accident of some other copy loop already covering it. The
# observable is SKIP, not FAIL: rc=2 self-skips regardless of WHY the cache
# is missing (see 9.3's own header), so a mutant that removes the copy is
# indistinguishable, per-check, from a target that genuinely has no cache —
# which is exactly why the aggregate .passed/.skipped counts, not the
# doctor's own exit code (0 either way once every OTHER check is skipped),
# are what this META asserts on.
MUT10_DIR=$(mktemp -d "$WORK/doctor-mut10.XXXXXX")
MUT10="$MUT10_DIR/workflow-doctor.sh"
sed "/model-select.sh's local cache, read-only/,/^    fi\$/d" "$DOCTOR" > "$MUT10"
# `$TARGET` is a literal to match in the doctor's own source text, not a
# variable to expand — single quotes are deliberate.
# shellcheck disable=SC2016
assert_eq "META-TEST 10: the cache-copy block was found and removed" \
    "0" "$(grep -c 'cp "\$TARGET/.claude/.qa-tracking/model-select-cache.json"' "$MUT10" | tr -d '[:space:]')"
assert_eq "META-TEST 10: the mutant differs from the shipped doctor" \
    "differs" "$(cmp -s "$MUT10" "$DOCTOR" && echo same || echo differs)"
assert_eq "META-TEST 10: the mutant is still valid bash" "0" \
    "$(bash -n "$MUT10" 2>/dev/null && echo 0 || echo 1)"
chmod +x "$MUT10"

MUT10_JSON="$WORK/mut10.json"
# The mutant's own exit code is NOT asserted on: SKIP never fails the
# doctor (by design — see 9.3's header), so it is 0 whether the copy is
# present or not once every OTHER check is skipped. The observable
# difference is the model_parity STATUS itself and the aggregate counts,
# both asserted below.
bash "$MUT10" --target "$MP_AGREE" --json-out "$MUT10_JSON" --quiet --skip "$ONLY_MP" \
    >/dev/null 2>&1 || true
assert_eq "META-TEST 10: WITHOUT the cache copy, the SAME agreeing fixture loses its PASS (SKIP, not the real OK)" \
    "SKIP" "$(status_of "$MUT10_JSON" model_parity)"
assert_contains "META-TEST 10: ...specifically because the sandbox's cache is missing, not because pins disagree" \
    "UNVERIFIABLE" "$(jq -r '(.checks[]|select(.name=="model_parity").detail)//""' "$MUT10_JSON")"
# .skipped is the GLOBAL aggregate over all 13 checks, not model_parity's
# own contribution alone: the 12 OTHER checks are skipped via --skip
# "$ONLY_MP", and model_parity's own self-skip (the mutation under test)
# is the 13th -- so the mutant shows 0 passed, 13 skipped, where the
# shipped script (below) shows 1 passed, 12 skipped. That one-check shift
# IS the mutation's observable effect.
assert_eq "META-TEST 10: ...and the mutant's own summary counts it as skipped, not passed, for a fixture that is actually healthy" \
    "0 13" "$(jq -r '"\(.passed) \(.skipped)"' "$MUT10_JSON" 2>/dev/null || echo "?")"

# RESTORE CONTROL: the identical fixture (9.1's, not rebuilt — proving this
# is the copy mechanism and not some other difference between two builds),
# the SHIPPED doctor, still PASSes.
MUT10C_JSON="$WORK/mut10-ctrl.json"
doctor_run "$DOCTOR" "$MP_AGREE" "$MUT10C_JSON" --quiet --skip "$ONLY_MP"
assert_eq "META-TEST 10 RESTORE CONTROL: the SHIPPED doctor, identical fixture, still PASSES model_parity" \
    "PASS" "$(status_of "$MUT10C_JSON" model_parity)"
# 1 passed (model_parity itself), 12 skipped (the OTHER checks, via --skip
# "$ONLY_MP" -- see the mutant's own comment above for why .skipped is the
# 13-check aggregate, not model_parity's own count).
assert_eq "META-TEST 10 RESTORE CONTROL: ...and the summary counts it as passed, with only the OTHER checks skipped" \
    "1 12" "$(jq -r '"\(.passed) \(.skipped)"' "$MUT10C_JSON" 2>/dev/null || echo "?")"

echo ""
echo "--- META-TEST 12: the HELPER-FAILURE routing is what makes 9.5 a FAIL (round 4, item (b), direction 1) ---"
#
# Disarm ONLY the new tag-based routing (the HELPER-FAILURE case arm is
# rewritten so it can never match, so EVERY rc=2 falls through to the SKIP
# arm below it -- reproducing the ORIGINAL, pre-round-4 doctor exactly) and
# prove the EXACT regression the review found: "a broken --print-role-map
# produces zero failed checks and doctor exit 0".
MUT12="$WORK/doctor-mut12.sh"
# shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
sed "s/\*'UNVERIFIABLE:HELPER-FAILURE'\*)/'NEVER-MATCHES-A13R-MUT12')/" "$DOCTOR" > "$MUT12"
assert_eq "META-TEST 12 non-vacuity: the HELPER-FAILURE case arm was found and disarmed" \
    "0" "$(grep -c "'UNVERIFIABLE:HELPER-FAILURE'" "$MUT12" | tr -d '[:space:]')"
assert_eq "META-TEST 12 non-vacuity: the mutant differs from the shipped doctor" \
    "differs" "$(cmp -s "$MUT12" "$DOCTOR" && echo same || echo differs)"
assert_eq "META-TEST 12 non-vacuity: the mutant is still valid bash" "0" \
    "$(bash -n "$MUT12" 2>/dev/null && echo 0 || echo 1)"
chmod +x "$MUT12"

MP_HELPERFAIL_M="$WORK/mp-helperfail-mut"
mk_target "$MP_HELPERFAIL_M"
seed_model_pins "$MP_HELPERFAIL_M" "claude-sec9-agree"
seed_cache "$MP_HELPERFAIL_M" "claude-sec9-agree"
write_helperfail_stub "$MP_HELPERFAIL_M"
MUT12_JSON="$WORK/mut12.json"
doctor_run "$MUT12" "$MP_HELPERFAIL_M" "$MUT12_JSON" --quiet --skip "$ONLY_MP"
assert_eq "META-TEST 12 SPECIFIC MISBEHAVIOUR: WITHOUT the routing, the identical helper-failure target WRONGLY SKIPS model_parity" \
    "SKIP" "$(status_of "$MUT12_JSON" model_parity)"
assert_eq "META-TEST 12 ...and the mutant's own exit code says healthy (0), over a target whose role/agent map helper is broken" \
    "0" "$DOCTOR_RC"

# RESTORE CONTROL: identical fixture shape, freshly built, the SHIPPED
# doctor -- still correctly FAILs.
MP_HELPERFAIL_MC="$WORK/mp-helperfail-ctrl"
mk_target "$MP_HELPERFAIL_MC"
seed_model_pins "$MP_HELPERFAIL_MC" "claude-sec9-agree"
seed_cache "$MP_HELPERFAIL_MC" "claude-sec9-agree"
write_helperfail_stub "$MP_HELPERFAIL_MC"
MUT12C_JSON="$WORK/mut12-ctrl.json"
doctor_run "$DOCTOR" "$MP_HELPERFAIL_MC" "$MUT12C_JSON" --quiet --skip "$ONLY_MP"
assert_eq "META-TEST 12 RESTORE CONTROL: the SHIPPED doctor, identical fixture shape, still FAILS model_parity" \
    "FAIL" "$(status_of "$MUT12C_JSON" model_parity)"
assert_eq "META-TEST 12 RESTORE CONTROL: ...and the doctor's own exit code is 1" "1" "$DOCTOR_RC"

echo ""
echo "--- META-TEST 13: the SKIP branch is what keeps a cold cache from FAILING the doctor (round 4, item (b), direction 2) ---"
#
# The OPPOSITE mistake: force EVERY rc=2 to FAIL unconditionally (the
# HELPER-FAILURE pattern is widened to a bare catch-all, so it matches
# BEFORE the SKIP arm ever gets a chance -- case takes the FIRST matching
# arm) and prove that a hypothetical "just FAIL every UNVERIFIABLE" reading
# of the review would have broken the exact case 9.3 exists to protect: a
# fresh install with no ANTHROPIC_API_KEY.
MUT13="$WORK/doctor-mut13.sh"
# shellcheck disable=SC2016  # matching LITERAL shell-source text, not expanding this script's own vars
sed "s/\*'UNVERIFIABLE:HELPER-FAILURE'\*)/*)/" "$DOCTOR" > "$MUT13"
assert_eq "META-TEST 13 non-vacuity: the HELPER-FAILURE arm was found and widened to an unconditional catch-all" \
    "0" "$(grep -c "'UNVERIFIABLE:HELPER-FAILURE'" "$MUT13" | tr -d '[:space:]')"
assert_eq "META-TEST 13 non-vacuity: the mutant differs from the shipped doctor" \
    "differs" "$(cmp -s "$MUT13" "$DOCTOR" && echo same || echo differs)"
assert_eq "META-TEST 13 non-vacuity: the mutant is still valid bash" "0" \
    "$(bash -n "$MUT13" 2>/dev/null && echo 0 || echo 1)"
chmod +x "$MUT13"

MP_NOCACHE_M="$WORK/mp-nocache-mut"
mk_target "$MP_NOCACHE_M"
seed_model_pins "$MP_NOCACHE_M" "claude-sec9-agree"
assert_eq "META-TEST 13 landing proof: mk_target genuinely leaves no model-select cache behind" \
    "no" "$([ -f "$MP_NOCACHE_M/.claude/.qa-tracking/model-select-cache.json" ] && echo yes || echo no)"
MUT13_JSON="$WORK/mut13.json"
doctor_run "$MUT13" "$MP_NOCACHE_M" "$MUT13_JSON" --quiet --skip "$ONLY_MP"
assert_eq "META-TEST 13 SPECIFIC MISBEHAVIOUR: WITHOUT the SKIP branch reachable, a plain cold cache WRONGLY FAILS model_parity" \
    "FAIL" "$(status_of "$MUT13_JSON" model_parity)"
assert_eq "META-TEST 13 ...and the mutant's own exit code says unhealthy (1), over a target whose ONLY issue is 'no key ever set'" \
    "1" "$DOCTOR_RC"

# RESTORE CONTROL: identical fixture shape, freshly built, the SHIPPED
# doctor -- still correctly SKIPs, exit 0.
MP_NOCACHE_MC="$WORK/mp-nocache-ctrl"
mk_target "$MP_NOCACHE_MC"
seed_model_pins "$MP_NOCACHE_MC" "claude-sec9-agree"
MUT13C_JSON="$WORK/mut13-ctrl.json"
doctor_run "$DOCTOR" "$MP_NOCACHE_MC" "$MUT13C_JSON" --quiet --skip "$ONLY_MP"
assert_eq "META-TEST 13 RESTORE CONTROL: the SHIPPED doctor, identical fixture shape, still SKIPS model_parity" \
    "SKIP" "$(status_of "$MUT13C_JSON" model_parity)"
assert_eq "META-TEST 13 RESTORE CONTROL: ...and the doctor's own exit code stays 0" "0" "$DOCTOR_RC"

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
