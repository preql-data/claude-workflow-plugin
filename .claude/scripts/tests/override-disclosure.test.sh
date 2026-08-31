#!/bin/bash
# override-disclosure.test.sh — L1 unit fixture for claude-workflow-plugin-yzo9:
# the narrowed Stop tier and the disclosure it depends on.
#
# TWO DEFECTS, ONE TASK, BOTH MEASURED BEFORE THIS FILE EXISTED:
#
#   1. detect-stack.sh:177-178 has said, since F8/J17, that its override
#      booleans are "tracked so the Stop hook can surface 'you are using an
#      override' in the block reason." Nothing ever read them --
#      `grep -c override .claude/scripts/verify-before-stop.sh` returned 0 on
#      every commit before this task. An override silently swapped
#      TEST_CMD/LINT_CMD/TYPE_CMD and the gate reported its verdict with no
#      indication it had run anything other than the project's own detected
#      default. Fixed by wiring detect-stack.sh's `overrides` object into two
#      new surfaces: the short claim (checks_scope_claim) and the RAN block +
#      summary paragraph (checks_scope_note), via one shared helper
#      (override_scope_names) so the two callers cannot say different things
#      about the same run — the same discipline CHECK-SCOPE (fkm.1.11,
#      verify-before-stop.sh) already applies to claim vs. note themselves.
#
#   2. detect-stack.sh's read_override was i8cx shape 1: a bare pipeline as a
#      function's return value. `[ -s "$f" ]` proves the override file EXISTS
#      and is non-empty; it proves nothing about whether it can be READ. With
#      no `set -o pipefail` anywhere in that file, `head -1 "$f" | tr -d '\r'
#      | sed -e '...'` returned SED's exit status alone. A `head` that fails
#      to read $f — permission denied, an I/O error, or, reproduced directly,
#      a `head` on PATH that exits nonzero regardless of input — hands
#      `tr`/`sed` a genuinely empty stdin, and `sed` over an empty stream is
#      not an error: it exits 0 having printed nothing. Measured at 2eced52
#      with a `head` shim exiting 9: rc=0, value=`''`, INDISTINGUISHABLE from
#      the healthy case's exit status except that the value is silently
#      wrong — the caller (`if v=$(read_override ...); then TEST_CMD="$v";
#      fi`) reads that as success and blanks an already auto-detected
#      TEST_CMD, which verify-before-stop.sh's `[ -n "$TEST_CMD" ]` dispatch
#      then reads as "nothing to run." Fixed by capturing the pipeline's real
#      exit status through a SCOPED `set -o pipefail` (subshell-local to the
#      one command substitution — the epic-gate.sh ~:2053 template).
#
# WHY BOTH ARE IN ONE TASK, AND THIS FILE COVERS BOTH: yzo9 narrows THIS
# repo's own Stop tier by ARMING an override (.claude/test-cmd ->
# `make test-fast`), so from this task forward the override machinery runs on
# EVERY Stop, not hypothetically. Fix 2 is what makes depending on it safe;
# fix 1 is what makes doing so honest. A regression in either defeats the
# other's purpose: an honestly-disclosed override that silently blanks itself
# on a bad read is not narrowed, it is DISABLED; a correctly-read override
# that discloses nothing is the exact defect this release is named for.
#
# PAIRING (.claude/tests/README.md, "The pairing requirement"). Every guard
# below carries all four parts: a mutation with an explicit non-vacuity leg,
# an assertion naming the specific misbehaviour the mutation reproduces, a
# restore control on the shipped artifact, and at least one leg that
# OBSERVES THE SHIPPED ARTIFACT RUNNING — extracted functions driven directly
# (Sections A/B), and Section C drives the REAL, UNMODIFIED
# verify-before-stop.sh end to end against a sandboxed project tree, piped
# stdin, real stdout capture, matching the mk_sb/run_hook convention already
# proven in change-set-undeterminable.test.sh (this file does not import that
# one — it is under concurrent edit elsewhere in this change; the pattern is
# reproduced here, self-contained, rather than coupled to a file this task
# does not own).
#
# Sections:
#   A   detect-stack.sh's read_override — the fail-open fix (i8cx shape 1)
#   B   verify-before-stop.sh's override_scope_names / checks_scope_claim /
#       checks_scope_note — the disclosure that was promised and never built
#   C   the REAL Stop hook, end to end, narrowed vs. not
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
DETECT_STACK="$PROJECT_DIR/.claude/scripts/detect-stack.sh"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"
DENY="$PROJECT_DIR/.claude/scripts/workflow-denylist.sh"
CTH="$PROJECT_DIR/.claude/scripts/current-task.sh"
TREE_LEASE="$PROJECT_DIR/.claude/scripts/tree-lease.sh"
MAKEFILE="$PROJECT_DIR/Makefile"
# claude-workflow-plugin-i8cx R2-F5 (Section D): the release-leg sandbox
# needs the REAL impact-report.sh so its pre-computed change_set_hash agrees
# with what the shipped hook independently recomputes at release time —
# duplicating that algorithm here would test a copy of it, not the shipped
# one.
IMPACT="$PROJECT_DIR/.claude/scripts/impact-report.sh"

for f in "$DETECT_STACK" "$VBS" "$DENY" "$CTH" "$MAKEFILE" "$IMPACT"; do
    if [ ! -f "$f" ]; then
        printf 'override-disclosure.test: artifact under test missing: %s\n' "$f" >&2
        exit 2
    fi
done

REAL_GIT=$(command -v git) || {
    printf 'override-disclosure.test: git not on PATH\n' >&2
    exit 2
}

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
    fi
}

# Counts rather than `grep -q`: a haystack piped into `grep -q` closes the
# pipe on first match, which can print a broken-pipe complaint mid-run on a
# large haystack (the same reason gate-claim-honesty.test.sh counts).
contains_count() {
    printf '%s' "$2" | grep -cF -- "$1" 2>/dev/null || true
}

assert_contains() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -gt 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected to CONTAIN: %s\n' "$name" "$needle"
    fi
}

assert_absent() {
    local name="$1" needle="$2" hay="$3" n
    n=$(contains_count "$needle" "$hay" | tr -d '[:space:]')
    if [ "${n:-0}" -eq 0 ]; then
        PASS=$((PASS + 1)); printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1)); FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected NOT to contain: %s (found %s time(s))\n' "$name" "$needle" "$n"
    fi
}

WORK=$(mktemp -d "${TMPDIR:-/tmp}/override-disclosure.XXXXXX")
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# extract_region_fn <src> <fn-name> <out> — extract a top-level function
# definition by an EXACT string match on its signature line ("<fn-name>() {"
# through the matching top-level "}"). String equality, not a regex match, so
# none of the four target function names need escaping. Text-anchored, never
# line-numbered, and it REPORTS A MISS: exit 7 when the signature is absent,
# so a rename cannot turn this file into a set of vacuous passes over an
# empty extraction (.claude/tests/README.md pairing part 1, applied to this
# test's own dependency, matching gate-claim-honesty.test.sh's extract_region
# convention).
extract_region_fn() {
    local src="$1" fn="$2" out="$3"
    awk -v sig="${fn}() {" '
        $0 == sig { inr = 1; found = 1 }
        inr { print }
        inr && /^}$/ { inr = 0 }
        END { if (!found) exit 7 }
    ' "$src" > "$out"
}

# ===========================================================================
# Section A: detect-stack.sh's read_override (i8cx shape 1, fixed)
# ===========================================================================
printf '\n--- Section A: read_override fails closed on an unreadable override ---\n'

extract_region_fn "$DETECT_STACK" "read_override" "$WORK/ro-shipped.sh"
RC_A_EXTRACT=$?
assert_eq "A0 non-vacuity: read_override extracted from the shipped script" "0" "$RC_A_EXTRACT"
assert_eq "A0b the extraction is non-empty" "yes" "$([ -s "$WORK/ro-shipped.sh" ] && echo yes || echo no)"
assert_eq "A0c the shipped extraction parses" "0" "$(bash -n "$WORK/ro-shipped.sh" 2>/dev/null; echo $?)"

# The mutant: strip the pipefail scoping that carries this fix, reverting the
# pipeline to exactly the pre-fix shape (its own exit status is sed's alone).
sed 's/set -o pipefail; //' "$WORK/ro-shipped.sh" > "$WORK/ro-mutant.sh"
assert_eq "A1 non-vacuity: the mutant differs from shipped (byte-for-byte)" "differs" \
    "$(diff -q "$WORK/ro-shipped.sh" "$WORK/ro-mutant.sh" >/dev/null 2>&1 && echo identical || echo differs)"
PF_SHIPPED_COUNT=$(grep -c 'set -o pipefail' "$WORK/ro-shipped.sh" 2>/dev/null || true)
PF_MUTANT_COUNT=$(grep -c 'set -o pipefail' "$WORK/ro-mutant.sh" 2>/dev/null || true)
assert_eq "A1b non-vacuity: shipped carries exactly one pipefail scope" "1" "${PF_SHIPPED_COUNT:-0}"
assert_eq "A1c non-vacuity: the mutant's pipefail scope is gone" "0" "${PF_MUTANT_COUNT:-0}"
assert_eq "A1d the mutant still parses" "0" "$(bash -n "$WORK/ro-mutant.sh" 2>/dev/null; echo $?)"

# Fixture: a healthy, single-line override file, and a `head` shim on PATH
# that fails regardless of input — the exact reproduction the task recorded
# (a `head` shim exiting 9 at 2eced52).
mkdir -p "$WORK/ro-proj/.claude" "$WORK/ro-proj-empty/.claude" "$WORK/ro-shim"
printf 'make test-fast\n' > "$WORK/ro-proj/.claude/test-cmd"
printf '#!/bin/bash\nexit 9\n' > "$WORK/ro-shim/head"
chmod +x "$WORK/ro-shim/head"

# A2: shipped, healthy file, REAL head -> correct value, success.
RO_A2_OUT=$(OVERRIDE_DIR="$WORK/ro-proj/.claude" bash -c '. "$1"; if v=$(read_override test-cmd 2>/dev/null); then printf "RC=0 VALUE=%s" "$v"; else printf "RC=1 VALUE="; fi' _ "$WORK/ro-shipped.sh")
assert_eq "A2 shipped + healthy file + real head: succeeds with the right value" "RC=0 VALUE=make test-fast" "$RO_A2_OUT"

# A3: shipped, no override file at all -> failure (regression check: this
# path is unchanged by the fix).
RO_A3_OUT=$(OVERRIDE_DIR="$WORK/ro-proj-empty/.claude" bash -c '. "$1"; if v=$(read_override test-cmd 2>/dev/null); then printf "RC=0 VALUE=%s" "$v"; else printf "RC=1"; fi' _ "$WORK/ro-shipped.sh")
assert_eq "A3 shipped + no override file: fails (unchanged regression behaviour)" "RC=1" "$RO_A3_OUT"

# A4 (the fix, specific misbehaviour PREVENTED): shipped, override file
# present, `head` fails -> must now FAIL, never silently succeed empty.
RO_A4_OUT=$(PATH="$WORK/ro-shim:$PATH" OVERRIDE_DIR="$WORK/ro-proj/.claude" bash -c '. "$1"; if v=$(read_override test-cmd 2>/dev/null); then printf "RC=0 VALUE=%s" "$v"; else printf "RC=1"; fi' _ "$WORK/ro-shipped.sh")
assert_eq "A4 SHIPPED + shimmed head: fails closed, NOT silently empty (the fix)" "RC=1" "$RO_A4_OUT"

# A5 (specific misbehaviour REPRODUCED): the MUTANT, same shimmed-head
# fixture, must reproduce the ORIGINAL bug exactly — rc 0, empty value,
# indistinguishable from success.
RO_A5_OUT=$(PATH="$WORK/ro-shim:$PATH" OVERRIDE_DIR="$WORK/ro-proj/.claude" bash -c '. "$1"; if v=$(read_override test-cmd 2>/dev/null); then printf "RC=0 VALUE=[%s]" "$v"; else printf "RC=1"; fi' _ "$WORK/ro-mutant.sh")
assert_eq "A5 MUTANT + shimmed head: reproduces the pre-fix bug (rc 0, empty)" "RC=0 VALUE=[]" "$RO_A5_OUT"

# A6 (restore control, the task's own words: "restore control proving a
# healthy override still applies"): the SAME shipped artifact, same healthy
# fixture as A2, driven again — directly beside A4/A5 so the shipped
# function's healthy-path behaviour and its failed-path behaviour are both
# demonstrated from the one artifact under test, not inferred from A2 alone.
RO_A6_OUT=$(OVERRIDE_DIR="$WORK/ro-proj/.claude" bash -c '. "$1"; if v=$(read_override test-cmd 2>/dev/null); then printf "RC=0 VALUE=%s" "$v"; else printf "RC=1"; fi' _ "$WORK/ro-shipped.sh")
assert_eq "A6 RESTORE CONTROL: shipped + healthy file, unshimmed PATH, still applies" "RC=0 VALUE=make test-fast" "$RO_A6_OUT"

# ===========================================================================
# Section B: verify-before-stop.sh's override disclosure
# ===========================================================================
printf '\n--- Section B: checks_scope_claim / checks_scope_note name an active override ---\n'

extract_region_fn "$VBS" "override_active" "$WORK/oa-shipped.sh"
RC_B_EXTRACT0=$?
extract_region_fn "$VBS" "override_scope_names" "$WORK/osn-shipped.sh"
RC_B_EXTRACT1=$?
extract_region_fn "$VBS" "checks_scope_claim" "$WORK/csc-shipped.sh"
RC_B_EXTRACT2=$?
extract_region_fn "$VBS" "checks_scope_note" "$WORK/csn-shipped.sh"
RC_B_EXTRACT3=$?
assert_eq "B0 non-vacuity: all four functions extracted from the shipped script" "0 0 0 0" \
    "$RC_B_EXTRACT0 $RC_B_EXTRACT1 $RC_B_EXTRACT2 $RC_B_EXTRACT3"
assert_contains "B0b non-vacuity: the extracted note mentions OVERRIDE at all (the feature exists to extract)" \
    "OVERRIDE" "$(cat "$WORK/csn-shipped.sh")"

# broader_verification_note is checks_scope_note's own trailing dependency
# (a much larger function reading the verification ledger) — irrelevant to
# what this file drives, so it is stubbed rather than pulled in whole; the
# stub is defined BEFORE sourcing the shipped extraction below and is never
# itself part of what is under test.
cat > "$WORK/fn-stub.sh" <<'STUB'
broader_verification_note() { printf ''; }
STUB

# Combine into ONE sourceable file per variant (shipped / mutant), in
# DEFINITION order (override_active first — override_scope_names and both
# callers' per-stage RAN-line tags all depend on it).
cat "$WORK/fn-stub.sh" "$WORK/oa-shipped.sh" "$WORK/osn-shipped.sh" "$WORK/csc-shipped.sh" "$WORK/csn-shipped.sh" > "$WORK/b-shipped.sh"
assert_eq "B0c the combined shipped extraction parses" "0" "$(bash -n "$WORK/b-shipped.sh" 2>/dev/null; echo $?)"

# The mutant: override_active always says NO stage is overridden, regardless
# of OVERRIDE_TEST/LINT/TYPE — the ONE predicate override_scope_names AND
# checks_scope_note's per-stage RAN-line tag both depend on, mutated once. A
# short-circuit `return 1` inserted right after the opening brace, rather
# than rewriting the case arms, so the mutation is a single, obviously-
# unconditional line rather than three parallel edits that could each be
# gotten slightly wrong.
sed '/^override_active() {$/a\
    return 1
' "$WORK/oa-shipped.sh" > "$WORK/oa-mutant.sh"
assert_eq "B1 non-vacuity: the mutant's override_active differs from shipped" "differs" \
    "$(diff -q "$WORK/oa-shipped.sh" "$WORK/oa-mutant.sh" >/dev/null 2>&1 && echo identical || echo differs)"
cat "$WORK/fn-stub.sh" "$WORK/oa-mutant.sh" "$WORK/osn-shipped.sh" "$WORK/csc-shipped.sh" "$WORK/csn-shipped.sh" > "$WORK/b-mutant.sh"
assert_eq "B1b the combined mutant extraction parses" "0" "$(bash -n "$WORK/b-mutant.sh" 2>/dev/null; echo $?)"
B1C_OUT=$(bash -c '. "$1"; OVERRIDE_TEST=true; override_active test && echo active || echo inactive' _ "$WORK/oa-mutant.sh")
assert_eq "B1c specific misbehaviour, isolated: the mutant reports test inactive even when OVERRIDE_TEST=true" "inactive" "$B1C_OUT"

# drive_bc <combined-fn-file> <TEST_CMD> <LINT_CMD> <TYPE_CMD> <OVERRIDE_TEST>
#          <OVERRIDE_LINT> <OVERRIDE_TYPE> <RUNNER>
# Sources the combined function file with every variable checks_scope_claim/
# checks_scope_note reference explicitly set (this file's own `set -u`
# discipline, matching gate-claim-honesty.test.sh's "drive shipped functions"
# section), calls both, and prints CLAIM=<...> / NOTE=<...> on separate
# lines so the caller can grep either half independently.
drive_bc() {
    local fnfile="$1" test_cmd="$2" lint_cmd="$3" type_cmd="$4" ot="$5" ol="$6" oy="$7" runner="$8"
    bash -c '
        . "$1"
        SUITE_REUSED=false
        TEST_CMD="$2"; LINT_CMD="$3"; TYPE_CMD="$4"
        OVERRIDE_TEST="$5"; OVERRIDE_LINT="$6"; OVERRIDE_TYPE="$7"
        RUNNER="$8"
        TIMEOUT_NOT_ENFORCED=""
        printf "CLAIM=%s\n" "$(checks_scope_claim)"
        printf "NOTE=%s\n" "$(checks_scope_note)"
    ' _ "$fnfile" "$test_cmd" "$lint_cmd" "$type_cmd" "$ot" "$ol" "$oy" "$runner"
}

# B2: SHIPPED, an override active on test only.
B2_OUT=$(drive_bc "$WORK/b-shipped.sh" "bash run-tests.sh --filter fast" "cd /p && make lint" "" \
    true false false make)
assert_contains "B2 shipped claim: names the override" "NARROWED via override: test" "$B2_OUT"
assert_contains "B2b shipped note: tags the overridden RAN line" "[OVERRIDE: .claude/test-cmd" "$B2_OUT"
assert_contains "B2c shipped note: the summary paragraph names the stage" "OPERATOR OVERRIDE IN EFFECT for: test" "$B2_OUT"
assert_absent "B2d shipped note: the UNTOUCHED lint line carries no override tag" "lint  [OVERRIDE" "$B2_OUT"

# B3 (specific misbehaviour REPRODUCED): the MUTANT, IDENTICAL fixture —
# override_scope_names always says "no override active", so both callers
# fall silent exactly like the pre-yzo9 shipped code did on a real override.
B3_OUT=$(drive_bc "$WORK/b-mutant.sh" "bash run-tests.sh --filter fast" "cd /p && make lint" "" \
    true false false make)
assert_absent "B3 MUTANT claim: says nothing about the override (reproduces the pre-fix silence)" "NARROWED" "$B3_OUT"
assert_absent "B3b MUTANT note: no [OVERRIDE tag despite OVERRIDE_TEST=true" "[OVERRIDE" "$B3_OUT"
assert_absent "B3c MUTANT note: no summary paragraph either" "OPERATOR OVERRIDE" "$B3_OUT"

# B4 (restore control): SAME fixture as B2/B3, SHIPPED artifact again,
# directly beside the mutant's silence above.
B4_OUT=$(drive_bc "$WORK/b-shipped.sh" "bash run-tests.sh --filter fast" "cd /p && make lint" "" \
    true false false make)
assert_contains "B4 RESTORE CONTROL: shipped discloses the override again" "NARROWED via override: test" "$B4_OUT"

# B5 (the negative control the task asks for at the function level — the
# end-to-end version is Section C2): SHIPPED artifact, an ORDINARY
# auto-detected run with every override flag false. Nothing about overrides
# may appear anywhere in either surface.
B5_OUT=$(drive_bc "$WORK/b-shipped.sh" "cd /p && make test" "cd /p && make lint" "" \
    false false false make)
assert_absent "B5 NEGATIVE CONTROL: unnarrowed run's claim mentions no override" "OVERRIDE" "$B5_OUT"
assert_absent "B5b NEGATIVE CONTROL: unnarrowed run's RAN block mentions no override" "[OVERRIDE" "$B5_OUT"
assert_contains "B5c ...and the claim is the exact pre-yzo9 literal, unmodified" "tests + lint passed — and nothing else ran" "$B5_OUT"

# B6: an override active but resolved to an EMPTY command (a blank
# .claude/test-cmd) is a DIFFERENT fact than "no runner detected" — the
# empty-command branch must say so rather than blame detect-stack.sh for
# something an override actually caused.
B6_OUT=$(drive_bc "$WORK/b-shipped.sh" "" "" "" true false false make)
assert_contains "B6 override resolved empty: the claim names the override, not detect-stack.sh" \
    "override(s) active for test resolved to an empty command" "$B6_OUT"
assert_absent "B6b ...and does NOT blame detect-stack.sh for finding nothing" "detect-stack.sh resolved no test" "$B6_OUT"

# ===========================================================================
# Section C: the REAL Stop hook, end to end
# ===========================================================================
printf '\n--- Section C: verify-before-stop.sh, driven for real, narrowed vs. not ---\n'

# build_sandbox <root> <override_test_bool> — a project tree carrying the
# REAL, UNMODIFIED verify-before-stop.sh (this task's fix included) plus its
# real collaborators, a stub qa-gate.sh (no bd/.beads anywhere, so the
# bd-backed gate region self-skips — the same "no active Beads task" shape
# change-set-undeterminable.test.sh's own SB1/run_hook proves reaches the
# ordinary "QA approval required" reason), and a detect-stack.sh stub that
# reports a fast, deterministic test_cmd ("true") with `overrides.test` set
# to the given bool. One tracked-by-the-tracker file makes CHANGE_COUNT > 0.
build_sandbox() {
    local root="$1" ot="$2"
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src"
    cp "$VBS" "$DENY" "$CTH" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    printf '#!/bin/bash\nexit 0\n' > "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":$ot,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/qa-gate.sh" "$root/.claude/scripts/detect-stack.sh"
    ( cd "$root" \
        && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com \
        && "$REAL_GIT" config user.name t \
        && printf '.claude/\nnotes/\n' > .gitignore \
        && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null \
        && "$REAL_GIT" commit -qm init >/dev/null )
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
}

# run_stop_hook <root> — one real Stop fire. Output on stdout; rc discarded
# (the hook's own exit code is not what these assertions are about — its
# printed content is).
run_stop_hook() {
    # run_stop_hook <root> [extra-PATH-dir] — the second argument is Section
    # D's addition (claude-workflow-plugin-i8cx R2-F5): a directory prepended
    # to PATH ahead of the real one, matching change-set-undeterminable.test.
    # sh's own run_hook convention, so a sandboxed `bd` stub can be found
    # without shadowing anything Section A/B/C's calls (which never pass it)
    # rely on.
    local root="$1" xp="${2:-}"
    ( cd "$root" && printf '{"stop_hook_active": false}' \
        | env ${xp:+PATH="$xp:$PATH"} CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/verify-before-stop.sh" 2>"$WORK/stderr.$$" )
}

SBC1="$WORK/sbc1"
build_sandbox "$SBC1" "true"
OUT_C1=$(run_stop_hook "$SBC1")
assert_contains "C1 real hook, narrowed: decision is block (nothing failed, still awaiting QA)" '"decision":"block"' "$OUT_C1"
assert_contains "C1b real hook, narrowed: the claim header names the override" "NARROWED via override: test" "$OUT_C1"
assert_contains "C1c real hook, narrowed: the RAN block tags the overridden command" "RAN      tests       true  [OVERRIDE: .claude/test-cmd" "$OUT_C1"
assert_contains "C1d real hook, narrowed: the summary paragraph is present — the operator's own acceptance criterion" \
    "OPERATOR OVERRIDE IN EFFECT for: test" "$OUT_C1"
assert_contains "C1e ...and it says SUBSET, not full coverage, in so many words" \
    "a SUBSET of what this project runs without the" "$OUT_C1"

SBC2="$WORK/sbc2"
build_sandbox "$SBC2" "false"
OUT_C2=$(run_stop_hook "$SBC2")
assert_contains "C2 NEGATIVE CONTROL: real hook, unnarrowed: still an ordinary block" '"decision":"block"' "$OUT_C2"
assert_absent "C2b NEGATIVE CONTROL: unnarrowed real hook output names no override anywhere" "OVERRIDE" "$OUT_C2"
assert_contains "C2c ...and the claim reads the exact pre-yzo9 literal" "tests passed — and nothing else ran)." "$OUT_C2"

# ===========================================================================
# Section D: claude-workflow-plugin-i8cx R2-F5 — override disclosure on the
# SUITE_REUSED replay path and the release path, which Sections A-C above
# never drove: Section B always sets SUITE_REUSED=false directly; Section C
# fires only ONE Stop per sandbox (never enough for a replay to become
# possible) and never carries a matching approval (never enough to release).
# Sol's finding, reproduced structurally: the SUITE_REUSED branch of
# checks_scope_claim/checks_scope_note used to return before ever consulting
# override state (OVERRIDE_TEST/LINT/TYPE are parsed only in the
# fresh-dispatch branch), and the release path built its output without
# calling either function at all.
#
# D1-D3 drive the REPLAY leg, the UNESTABLISHED leg and the REPLAY's negative
# control against a bd-less, git-only sandbox — VERIFY_SKIP_UNCHANGED is a
# pure git+file-content predicate (see verify-before-stop.sh's own
# SKIP-UNCHANGED region), so no bd/.beads fixture is needed to reach a
# replay, only an active task marker (VERIFY_SKIP_UNCHANGED is explicitly
# scoped to one) and the REAL impact-report.sh (current_change_set_hash
# refuses to persist/compare without it — Section C's sandboxes never copied
# it because Section C never needed a second Stop fire). D4-D5 drive the
# RELEASE leg and its negative control, which DO need a real approval to
# reach: built the same way change-set-undeterminable.test.sh's SB4 builds
# one (a stubbed `bd show` returning a fabricated `QA-GATE APPROVED`
# comment), with `[review bypass:]`/`[design bypass:]` markers so the
# review- and design-discipline re-checks — unrelated to this fix — skip
# cleanly rather than needing their own real predicates faked too.
# ===========================================================================
printf '\n--- Section D: SUITE_REUSED replay and the release path name the override (or its absence) ---\n'

# build_sandbox_task <root> <override_test_bool> — Section C's build_sandbox
# PLUS an active task id (no current-task.sh copied in, so get_current_task
# falls back to reading .claude/.qa-tracking/current-task directly) PLUS the
# REAL impact-report.sh (so current_change_set_hash — and therefore
# record_verified_state / verified_state_unchanged — actually has something
# to compute rather than refusing on a missing script). Section C's own
# sandboxes had neither, because reaching SUITE_REUSED was never Section C's
# job.
build_sandbox_task() {
    local root="$1" ot="$2"
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src"
    cp "$VBS" "$DENY" "$IMPACT" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    printf '#!/bin/bash\nexit 0\n' > "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":$ot,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/qa-gate.sh" "$root/.claude/scripts/detect-stack.sh"
    ( cd "$root" \
        && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com \
        && "$REAL_GIT" config user.name t \
        && printf '.claude/\nnotes/\n' > .gitignore \
        && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null \
        && "$REAL_GIT" commit -qm init >/dev/null )
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk1\n' > "$root/.claude/.qa-tracking/current-task"
}

# override_state_cache_for <root> — the exact path last_override_state_file_
# for/replay_cached_override_for names for task "tsk1" in this sandbox,
# reproduced by literal path construction (sanitize_task_id is a no-op on an
# already-alnum id, per the shipped function's own body) rather than by
# sourcing the shipped helper — this test does not depend on that helper's
# own internals to find the file it is asserting the presence/absence of.
override_state_cache_for() {
    printf '%s/.claude/.qa-tracking/last-override-state.tsk1' "$1"
}

# ---------------------------------------------------------------------------
# D1. THE REPLAY LEG: two real Stop fires, unchanged tree in between, override
# armed — so the SECOND fire is a genuine SUITE_REUSED reuse of a NARROWED
# first run. This is the operator's own reproduction, structurally: iteration
# N (fresh, narrowed) then iteration N+1 (cached replay of it).
# ---------------------------------------------------------------------------
SBD1="$WORK/sbd1"
build_sandbox_task "$SBD1" "true"
OUT_D1_FRESH=$(run_stop_hook "$SBD1")
assert_contains "D1.0 sanity: the FIRST (fresh) call is narrowed, same shape as C1" \
    "NARROWED via override: test" "$OUT_D1_FRESH"
assert_eq "D1.1 non-vacuity: the fresh run persisted an override-state cache file" \
    "yes" "$([ -s "$(override_state_cache_for "$SBD1")" ] && echo yes || echo no)"
assert_eq "D1.2 non-vacuity: the persisted cache records the override as active" \
    "true" "$(awk '{print $1}' "$(override_state_cache_for "$SBD1")" 2>/dev/null)"

OUT_D1_REPLAY=$(run_stop_hook "$SBD1")
assert_contains "D1.3 non-vacuity: the second call is really a SUITE_REUSED reuse" \
    "checks NOT re-run this loop — cached result replayed" "$OUT_D1_REPLAY"
assert_contains "D1.4 THE FIX: the replayed CLAIM now names the override" \
    "the REPLAYED run was NARROWED via override: test" "$OUT_D1_REPLAY"
assert_contains "D1.5 THE FIX: the replayed NOTE carries the summary paragraph too" \
    "OPERATOR OVERRIDE WAS IN EFFECT on the run being replayed, for: test" "$OUT_D1_REPLAY"
assert_contains "D1.6 ...and it says never a wider or equal-coverage substitute, same phrase the fresh-run wording uses" \
    "without the override, never a wider or equal-coverage substitute for it." "$OUT_D1_REPLAY"
assert_absent "D1.7 the replay is KNOWN, not unestablished — no UNDETERMINED text" \
    "UNDETERMINED" "$OUT_D1_REPLAY"
assert_absent "D1.8 WORDING FIX: 'the last full run' is never asserted (it may not have been full)" \
    "last full run" "$OUT_D1_REPLAY"
assert_absent "D1.8b ...nor its sibling in the detail sentence" \
    "full run recorded" "$OUT_D1_REPLAY"
assert_contains "D1.9 ...replaced by a claim that never asserts fullness either way" \
    "last recorded run" "$OUT_D1_REPLAY"

# ---------------------------------------------------------------------------
# D2. THE UNESTABLISHED LEG: same sandbox shape, but the override-state cache
# is missing at replay time (a cache predating this fix, or a failed write) —
# the OTHER cached instruments (tree fingerprint + change-set hash) are
# untouched, so the replay still fires; only the override answer is gone.
# ---------------------------------------------------------------------------
SBD2="$WORK/sbd2"
build_sandbox_task "$SBD2" "true"
run_stop_hook "$SBD2" >/dev/null
assert_eq "D2.0 non-vacuity: the fresh run left a cache to delete" \
    "yes" "$([ -s "$(override_state_cache_for "$SBD2")" ] && echo yes || echo no)"
rm -f "$(override_state_cache_for "$SBD2")"
assert_eq "D2.1 non-vacuity: the cache is really gone before the replay fires" \
    "no" "$([ -e "$(override_state_cache_for "$SBD2")" ] && echo yes || echo no)"
OUT_D2_REPLAY=$(run_stop_hook "$SBD2")
assert_contains "D2.2 the replay still fires (the OTHER two instruments are untouched)" \
    "checks NOT re-run this loop — cached result replayed" "$OUT_D2_REPLAY"
assert_contains "D2.3 THE FIX: the CLAIM says the override state is UNKNOWN, not confirmed either way" \
    "override state on the REPLAYED run is UNKNOWN" "$OUT_D2_REPLAY"
assert_contains "D2.4 ...and the NOTE spells out why" \
    "OVERRIDE STATE UNDETERMINED for the run being replayed" "$OUT_D2_REPLAY"
assert_contains "D2.5 ...naming explicitly that unknown must never read as the reassuring case" \
    "that is UNKNOWN, and unknown must never be read as" "$OUT_D2_REPLAY"
assert_absent "D2.6 THE DISCRIMINATOR: unknown must NEVER be asserted as a CONFIRMED override (the reassuring-for-the-wrong-reason failure mode)" \
    "OPERATOR OVERRIDE WAS IN EFFECT" "$OUT_D2_REPLAY"
assert_absent "D2.7 ...nor confirmed as narrowed in the short claim either" \
    "the REPLAYED run was NARROWED" "$OUT_D2_REPLAY"

# ---------------------------------------------------------------------------
# D3. NEGATIVE CONTROL (replay): the SAME two-call replay shape, override
# NEVER armed. Must add ZERO "OVERRIDE" bytes and must still name the
# recorded-run wording this fix corrected (never asserting fullness it did
# not check) — so this fix has not made the disclosure fire unconditionally.
# ---------------------------------------------------------------------------
SBD3="$WORK/sbd3"
build_sandbox_task "$SBD3" "false"
run_stop_hook "$SBD3" >/dev/null
OUT_D3_REPLAY=$(run_stop_hook "$SBD3")
assert_contains "D3.0 sanity: this is really a replay too" \
    "checks NOT re-run this loop — cached result replayed" "$OUT_D3_REPLAY"
assert_absent "D3.1 NEGATIVE CONTROL: an unnarrowed replay names no override anywhere" \
    "OVERRIDE" "$OUT_D3_REPLAY"
assert_contains "D3.2 ...and still carries the corrected (non-'full') wording" \
    "tree and change-set unchanged since the last recorded run" "$OUT_D3_REPLAY"

# ---------------------------------------------------------------------------
# build_sandbox_release <root> <override_test_bool> — a sandbox that actually
# RELEASES: GATE_STATUS=approved (stubbed qa-gate.sh) plus a change-set-bound
# `QA-GATE APPROVED` record (stubbed `bd show`) whose change_set_hash is
# PRE-COMPUTED with the REAL, copied-in impact-report.sh — the same script
# and same env var the shipped hook itself uses (current_change_set_hash),
# so this does not duplicate the hashing algorithm, it reuses it. The
# approval record also carries `[review bypass:]`/`[design bypass:]`
# markers (the audited escape qa-gate.sh approve --no-review/--no-design
# writes) so the review- and design-discipline re-checks — a different
# subsystem than this fix — skip cleanly instead of needing review-check.sh
# and a real design verdict faked too.
# ---------------------------------------------------------------------------
build_sandbox_release() {
    local root="$1" ot="$2" h
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src" \
        "$root/.beads" "$root/bin"
    cp "$VBS" "$DENY" "$IMPACT" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  *) exit 0 ;;
esac
QG
    chmod +x "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":$ot,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/detect-stack.sh"
    printf '.claude/\nnotes/\nbin/\n.beads/\n' > "$root/.gitignore"
    ( cd "$root" \
        && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com \
        && "$REAL_GIT" config user.name t \
        && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null \
        && "$REAL_GIT" commit -qm init >/dev/null )
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk1\n' > "$root/.claude/.qa-tracking/current-task"
    # Pre-compute the REAL change-set hash the shipped hook will
    # independently recompute at release time, using the identical script +
    # env var (current_change_set_hash's own body). Nothing touches
    # changed-files.txt between this call and run_stop_hook, so the two
    # reads agree.
    h=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
    cat > "$root/bin/bd" <<BDSTUB
#!/bin/bash
if [ "\${1:-}" = "show" ]; then
    printf '%s' '{"comments":[{"text":"QA-GATE APPROVED change_set_hash=$h reviewed_by=test-fixture [review bypass: test fixture, nothing to review] [design bypass: test fixture, no design phase]"}]}'
    exit 0
fi
exit 0
BDSTUB
    chmod +x "$root/bin/bd"
}

# ---------------------------------------------------------------------------
# D4. THE RELEASE LEG: a FRESH (not replayed) narrowed run that PASSES and
# releases against an already-matching approval. Sol's finding, verbatim:
# "a narrowed override run that passes with an already matching approval
# releases with no override notice." Assert on the actual emitted text.
# ---------------------------------------------------------------------------
SBD4="$WORK/sbd4"
build_sandbox_release "$SBD4" "true"
OUT_D4=$(run_stop_hook "$SBD4" "$SBD4/bin")
assert_absent "D4.0 non-vacuity: this really released (no block decision)" \
    '"decision":"block"' "$OUT_D4"
assert_contains "D4.1 non-vacuity: this really is the release envelope" \
    "QA gate cleared" "$OUT_D4"
assert_contains "D4.2 THE FIX: the release discloses the override" \
    "OPERATOR OVERRIDE IN EFFECT for: test" "$OUT_D4"
assert_contains "D4.3 ...and names what kind of run it was" \
    "This release ran a DELIBERATELY NARROWED command in place of the" "$OUT_D4"

# ---------------------------------------------------------------------------
# D5. NEGATIVE CONTROL (release): the SAME release sandbox, override NEVER
# armed. Must add ZERO "OVERRIDE" bytes — the release note must not fire
# unconditionally just because the release path now calls it.
# ---------------------------------------------------------------------------
SBD5="$WORK/sbd5"
build_sandbox_release "$SBD5" "false"
OUT_D5=$(run_stop_hook "$SBD5" "$SBD5/bin")
assert_absent "D5.0 non-vacuity: this really released too (no block decision)" \
    '"decision":"block"' "$OUT_D5"
assert_contains "D5.1 non-vacuity: this really is the release envelope" \
    "QA gate cleared" "$OUT_D5"
assert_absent "D5.2 NEGATIVE CONTROL: an unnarrowed release names no override anywhere" \
    "OVERRIDE" "$OUT_D5"

# ===========================================================================
# Section E: claude-workflow-plugin-i8cx R5-F1 / R5-F2 / R5-F3 (independent
# review round 5, reviewed_hash 222877b5). Sections A-D above covered the
# ordinary block path and the ordinary release path (R2-F5, round 1). Round 5
# found three MORE paths that release or replay without disclosing an active
# override, plus a cache-validation gap that lets a corrupt replay cache
# present as the reassuring "known, not narrowed" case instead of UNKNOWN:
#
#   R5-F1  two early-exit RELEASE paths (VANISHED-CHANGE-SET, WORKTREE-
#          RESOLUTION) built their output without ever calling
#          override_release_note.
#   R5-F2  three blocking REPLAY paths (label-without-record, review-
#          discipline, design-discipline) call emit_block directly, never
#          checks_scope_claim/checks_scope_note, so a SUITE_REUSED=true replay
#          discloses nothing about the cached run behind it.
#   R5-F3  replay_cached_override_for treated "nonempty" as "established" --
#          `false false t` passed the old guard and was read back as
#          known-not-narrowed.
#
# E1 drives R5-F3 at the function level (extracted, mutated, restored). E2-E6
# drive R5-F1/R5-F2 end to end against the REAL, unmodified verify-before-
# stop.sh, each with a narrowed-run leg and a negative-control leg. E7 drives
# R5-F3 end to end: a CORRUPT (not missing) cache on a real replay.
# ===========================================================================
printf '\n--- Section E: R5-F1/F2/F3 - five more release/block paths, and cache validation ---\n'

# ---------------------------------------------------------------------------
# E1. R5-F3: replay_cached_override_for must treat "nonempty" as insufficient.
# Each field must be EXACTLY "true" or "false" -- Sol's reproduction is
# `false false t`; extra fields and partial writes must fail identically.
# ---------------------------------------------------------------------------
extract_region_fn "$VBS" "sanitize_task_id" "$WORK/e-stid.sh"
RC_E0_0=$?
extract_region_fn "$VBS" "last_override_state_file_for" "$WORK/e-losf.sh"
RC_E0_1=$?
extract_region_fn "$VBS" "replay_cached_override_for" "$WORK/e-rcof-shipped.sh"
RC_E0_2=$?
assert_eq "E0 non-vacuity: all three functions extracted from the shipped (fixed) script" "0 0 0" \
    "$RC_E0_0 $RC_E0_1 $RC_E0_2"
assert_contains "E0b non-vacuity: the shipped extraction carries the R5-F3 sentinel span" \
    "OVERRIDE-CACHE-FIELD-VALIDATION-BEGIN" "$(cat "$WORK/e-rcof-shipped.sh")"
cat "$WORK/e-stid.sh" "$WORK/e-losf.sh" "$WORK/e-rcof-shipped.sh" > "$WORK/e-shipped.sh"
assert_eq "E0c the combined shipped extraction parses" "0" "$(bash -n "$WORK/e-shipped.sh" 2>/dev/null; echo $?)"

# The mutant: replace ONLY the sentinel-wrapped per-field validation span with
# the pre-R5-F3 condition it replaced (a single `-n` conjunction over all
# three fields) -- the EXACT text this fix removed, restored via awk rather
# than typed from memory, so the mutant is provably the historical shape
# rather than an approximation of it.
awk '
    /--- OVERRIDE-CACHE-FIELD-VALIDATION-BEGIN/ {
        print
        print "        if [ \"$rc\" -eq 0 ] && [ -n \"${OVERRIDE_TEST:-}\" ] && [ -n \"${OVERRIDE_LINT:-}\" ] && [ -n \"${OVERRIDE_TYPE:-}\" ]; then"
        print "            : # pre-R5-F3 shape: nonempty was treated as established"
        print "        else"
        print "            rc=1"
        print "        fi"
        skip = 1
        next
    }
    /--- OVERRIDE-CACHE-FIELD-VALIDATION-END/ { skip = 0; print; next }
    skip { next }
    { print }
' "$WORK/e-rcof-shipped.sh" > "$WORK/e-rcof-mutant.sh"
assert_eq "E1.0 non-vacuity: the mutant differs from shipped (byte-for-byte)" "differs" \
    "$(diff -q "$WORK/e-rcof-shipped.sh" "$WORK/e-rcof-mutant.sh" >/dev/null 2>&1 && echo identical || echo differs)"
assert_absent "E1.0b non-vacuity: the mutant no longer carries the per-field case guards" \
    "case \"\$OVERRIDE_TEST\"" "$(cat "$WORK/e-rcof-mutant.sh")"
cat "$WORK/e-stid.sh" "$WORK/e-losf.sh" "$WORK/e-rcof-mutant.sh" > "$WORK/e-mutant.sh"
assert_eq "E1.0c the combined mutant parses" "0" "$(bash -n "$WORK/e-mutant.sh" 2>/dev/null; echo $?)"

# drive_rcof <fnfile> <qa-tracking-dir> <tid> <content> [mode]
# mode: write (default, appends \n) | rawbytes (no trailing newline) | absent
drive_rcof() {
    local fnfile="$1" qtd="$2" tid="$3" content="$4" mode="${5:-write}"
    mkdir -p "$qtd"
    local cachefile="$qtd/last-override-state.$tid"
    case "$mode" in
        absent)   rm -f "$cachefile" ;;
        rawbytes) printf '%s' "$content" > "$cachefile" ;;
        *)        printf '%s\n' "$content" > "$cachefile" ;;
    esac
    bash -c '
        QA_TRACKING_DIR="$1"
        . "$2"
        replay_cached_override_for "$3"
        printf "KNOWN=%s TEST=%s LINT=%s TYPE=%s\n" \
            "$SUITE_REUSE_OVERRIDE_KNOWN" "${OVERRIDE_TEST:-<unset>}" "${OVERRIDE_LINT:-<unset>}" "${OVERRIDE_TYPE:-<unset>}"
    ' _ "$qtd" "$fnfile" "$tid"
}

E_QTD_S="$WORK/e-qtd-shipped"
E_QTD_M="$WORK/e-qtd-mutant"

# E1.1 healthy cache -> known, exact values restored (baseline / restore control)
E1_1=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t1" "true false false")
assert_eq "E1.1 SHIPPED, healthy cache: known=true, values restored exactly" \
    "KNOWN=true TEST=true LINT=false TYPE=false" "$E1_1"

# E1.2 Sol's exact reproduction against the SHIPPED (fixed) extraction: must
# now be UNKNOWN, not known-inactive.
E1_2=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t2" "false false t")
assert_eq "E1.2 THE FIX, SHIPPED: 'false false t' is UNKNOWN, never read as known-inactive" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_2"

# E1.2m SPECIFIC MISBEHAVIOUR: the MUTANT (pre-R5-F3 shape), IDENTICAL input
# -- must reproduce Sol's exact finding: known=true, OVERRIDE_TYPE carrying
# the corrupt "t" value, which override_active's `= "true"` compare would
# then silently read as inactive (the reassuring-silence defect).
E1_2M=$(drive_rcof "$WORK/e-mutant.sh" "$E_QTD_M" "t2m" "false false t")
assert_eq "E1.2m SPECIFIC MISBEHAVIOUR: pre-fix shape accepts 'false false t' as known (the live defect)" \
    "KNOWN=true TEST=false LINT=false TYPE=t" "$E1_2M"

# E1.3 extra field, folded into the third by read's word-splitting -- SHIPPED
E1_3=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t3" "true false true extra")
assert_eq "E1.3 THE FIX, SHIPPED: an extra field is UNKNOWN, not silently accepted" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_3"
# ...and the MUTANT accepts it (same underlying defect, different byte string)
E1_3M=$(drive_rcof "$WORK/e-mutant.sh" "$E_QTD_M" "t3m" "true false true extra")
assert_eq "E1.3m SPECIFIC MISBEHAVIOUR: pre-fix shape accepts the extra-field line as known" \
    "KNOWN=true TEST=true LINT=false TYPE=true extra" "$E1_3M"

# E1.4 partially-written: fewer than three fields, but a real trailing newline
# (read succeeds, rc=0, third field is simply empty) -- SHIPPED
E1_4=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t4" "true false")
assert_eq "E1.4 partially-written (2 fields, real newline), SHIPPED: UNKNOWN" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_4"
# the pre-fix shape ALREADY caught this one (the old code's own -n check),
# so this is a regression control, not a misbehaviour reproduction: both
# shapes must agree here.
E1_4M=$(drive_rcof "$WORK/e-mutant.sh" "$E_QTD_M" "t4m" "true false")
assert_eq "E1.4m regression control: pre-fix shape ALSO rejects a short field (unchanged by this fix)" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_4M"

# E1.5 partially-written: truncated mid-token, NO trailing newline at all --
# read itself returns nonzero. Pre-existing guard, both shapes must agree.
E1_5=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t5" "true fal" "rawbytes")
assert_eq "E1.5 partially-written (no newline, read fails), SHIPPED: UNKNOWN" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_5"
E1_5M=$(drive_rcof "$WORK/e-mutant.sh" "$E_QTD_M" "t5m" "true fal" "rawbytes")
assert_eq "E1.5m regression control: pre-fix shape ALSO rejects a truncated write (unchanged)" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_5M"

# E1.6 empty cache file (unchanged behaviour: the [ -s ] guard)
: > "$E_QTD_S/last-override-state.t6"
E1_6=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t6" "" "rawbytes")
assert_eq "E1.6 empty cache file, SHIPPED: UNKNOWN (unchanged regression behaviour)" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_6"

# E1.7 missing file entirely (unchanged behaviour)
E1_7=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t7" "" "absent")
assert_eq "E1.7 missing cache file, SHIPPED: UNKNOWN (unchanged regression behaviour)" \
    "KNOWN=false TEST=<unset> LINT=<unset> TYPE=<unset>" "$E1_7"

# E1.8 RESTORE CONTROL: the shipped artifact, healthy input, one more time --
# directly beside the mutant's misbehaviour above, same discipline Section A's
# A6/Section B's B4 use.
E1_8=$(drive_rcof "$WORK/e-shipped.sh" "$E_QTD_S" "t8" "true true false")
assert_eq "E1.8 RESTORE CONTROL: shipped + healthy cache, unmutated, still applies" \
    "KNOWN=true TEST=true LINT=true TYPE=false" "$E1_8"

# ---------------------------------------------------------------------------
# Shared sandbox builders for E2-E6 (R5-F1/R5-F2), reusing Section C/D's own
# conventions (build_sandbox_task, build_sandbox_release, run_stop_hook) --
# same repo layout, same stubbing style, so nothing here is a second way to
# build a sandbox, only a second CONFIGURATION of the same one.
# ---------------------------------------------------------------------------

# override_state_cache_for is already defined above (Section D); reused as-is.

# init_repo <root> -- the git init half every builder below shares verbatim.
init_repo() {
    local root="$1"
    ( cd "$root" \
        && "$REAL_GIT" init -q \
        && "$REAL_GIT" config user.email t@example.com \
        && "$REAL_GIT" config user.name t \
        && printf 'code\n' > src/app.ts \
        && "$REAL_GIT" add .gitignore src >/dev/null \
        && "$REAL_GIT" commit -qm init >/dev/null )
}

# ---------------------------------------------------------------------------
# E2. R5-F1 leg 1: VANISHED-CHANGE-SET release names the override.
#
# Reproduces gz3's own race WITHOUT needing real concurrency: detect-stack.sh
# (a script this hook already calls once, well after the first
# reviewable_changes() read and well before the vanished-change-set re-read)
# truncates changed-files.txt as a side effect before printing its JSON --
# exactly what a concurrent `qa-gate.sh approve` does in production. bd's
# stub returns zero matching comments, so GATE_STATUS=approved plus no
# matching record is LABEL_WITHOUT_RECORD=true regardless of the hash; the
# truncation is what makes the SECOND reviewable_changes() read (inside
# VANISHED-CHANGE-SET) come back empty while the FIRST one (CODE_CHANGES_
# DETECTED) was real.
# ---------------------------------------------------------------------------
build_sandbox_vanished() {
    local root="$1" ot="$2"
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src" \
        "$root/.beads" "$root/bin"
    cp "$VBS" "$DENY" "$IMPACT" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  *) exit 0 ;;
esac
QG
    chmod +x "$root/.claude/scripts/qa-gate.sh"
    # detect-stack.sh's side effect IS the reproduction: truncate the tracker
    # the moment this Stop consults the detector, simulating a concurrent
    # approve landing between the two reviewable_changes() reads.
    cat > "$root/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
: > "\$CLAUDE_PROJECT_DIR/.claude/.qa-tracking/changed-files.txt"
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":$ot,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/detect-stack.sh"
    printf '.claude/\nnotes/\nbin/\n.beads/\n' > "$root/.gitignore"
    init_repo "$root"
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk1\n' > "$root/.claude/.qa-tracking/current-task"
    cat > "$root/bin/bd" <<'BDSTUB'
#!/bin/bash
if [ "${1:-}" = "show" ]; then
    printf '%s' '{"comments":[]}'
    exit 0
fi
exit 0
BDSTUB
    chmod +x "$root/bin/bd"
}

SBE2="$WORK/sbe2"
build_sandbox_vanished "$SBE2" "true"
OUT_E2=$(run_stop_hook "$SBE2" "$SBE2/bin")
assert_absent "E2.0 non-vacuity: this really released (no block decision)" \
    '"decision":"block"' "$OUT_E2"
assert_contains "E2.1 non-vacuity: this really is the vanished-change-set release" \
    "the change set vanished concurrently" "$OUT_E2"
assert_contains "E2.2 THE FIX: the release discloses the override" \
    "OPERATOR OVERRIDE IN EFFECT for: test" "$OUT_E2"
assert_contains "E2.3 ...and says SUBSET of what this project runs, not full coverage" \
    "a SUBSET of what this project runs without the override, never a" "$OUT_E2"
assert_contains "E2.3b ...continued past the wrap: never a wider or equal-coverage substitute" \
    "wider or equal-coverage" "$OUT_E2"

SBE2N="$WORK/sbe2n"
build_sandbox_vanished "$SBE2N" "false"
OUT_E2N=$(run_stop_hook "$SBE2N" "$SBE2N/bin")
assert_absent "E2N.0 NEGATIVE CONTROL non-vacuity: this still released" \
    '"decision":"block"' "$OUT_E2N"
# NEGATIVE CONTROL: emit_release's own contract (see its header) is to fall
# through to a BARE `{}` when override_release_note has nothing to disclose --
# unlike the bottom release, this one carries no close-hint/epic-defer note of
# its own, so an unnarrowed vanished-change-set release is silent by design,
# not merely free of "OVERRIDE" text. Assert the exact bare envelope rather
# than expecting narrative that only exists when there IS something to say.
assert_eq "E2N.1 NEGATIVE CONTROL: the exact bare envelope, nothing appended" \
    '{}' "$OUT_E2N"
assert_absent "E2N.2 NEGATIVE CONTROL: an unnarrowed vanished-change-set release names no override anywhere" \
    "OVERRIDE" "$OUT_E2N"

# ---------------------------------------------------------------------------
# E3. R5-F1 leg 2: WORKTREE-RESOLUTION release names the override.
#
# A REAL second git worktree of the same repo carries the persisted approval
# evidence try_worktree_resolution trusts (RECORD-BASED, NOT RECOMPUTED --
# its own header): impact-report-tsk1.json citing a fixture hash, and a
# minimal v2 gate-baseline proving no post-approval drift. root's own bd stub
# cites the SAME fixture hash with a `worktree=` token, so the ONLY way this
# checkout can release is via cross-worktree resolution (root's own
# recomputed hash is a real sha256, which will never equal the placeholder).
# ---------------------------------------------------------------------------
build_sandbox_worktree_release() {
    local root="$1" wt="$2" ot="$3"
    local h="wtres-fixture-hash-r5f1"
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src" \
        "$root/.beads" "$root/bin"
    cp "$VBS" "$DENY" "$IMPACT" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  *) exit 0 ;;
esac
QG
    chmod +x "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":$ot,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/detect-stack.sh"
    printf '.claude/\nnotes/\nbin/\n.beads/\n' > "$root/.gitignore"
    init_repo "$root"
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk1\n' > "$root/.claude/.qa-tracking/current-task"
    cat > "$root/bin/bd" <<BDSTUB
#!/bin/bash
if [ "\${1:-}" = "show" ]; then
    printf '%s' '{"comments":[{"text":"QA-GATE APPROVED change_set_hash=$h reviewed_by=test-fixture worktree=$wt [review bypass: test fixture, nothing to review] [design bypass: test fixture, no design phase]"}]}'
    exit 0
fi
exit 0
BDSTUB
    chmod +x "$root/bin/bd"

    "$REAL_GIT" -C "$root" worktree add -q -b "wtres-fixture-branch" "$wt" >/dev/null 2>&1
    mkdir -p "$wt/.claude/.qa-tracking"
    printf '{"change_set_hash":"%s","files":[{"file":"notes/impl.ts"}]}' "$h" \
        > "$wt/.claude/.qa-tracking/impact-report-tsk1.json"
    printf 'gate-baseline v2\n--\n' > "$wt/.claude/.qa-tracking/gate-baseline"
}

SBE3="$WORK/sbe3"
SBE3_WT="$WORK/sbe3-wt"
build_sandbox_worktree_release "$SBE3" "$SBE3_WT" "true"
OUT_E3=$(run_stop_hook "$SBE3" "$SBE3/bin")
assert_absent "E3.0 non-vacuity: this really released (no block decision)" \
    '"decision":"block"' "$OUT_E3"
assert_contains "E3.1 non-vacuity: this really is the worktree-resolution release" \
    "cross-worktree resolution" "$OUT_E3"
assert_contains "E3.2 THE FIX: the release discloses the override" \
    "OPERATOR OVERRIDE IN EFFECT for: test" "$OUT_E3"
assert_contains "E3.3 ...and names what kind of run it was" \
    "This release ran a DELIBERATELY NARROWED command in place of the" "$OUT_E3"

SBE3N="$WORK/sbe3n"
SBE3N_WT="$WORK/sbe3n-wt"
build_sandbox_worktree_release "$SBE3N" "$SBE3N_WT" "false"
OUT_E3N=$(run_stop_hook "$SBE3N" "$SBE3N/bin")
assert_absent "E3N.0 NEGATIVE CONTROL non-vacuity: this still released" \
    '"decision":"block"' "$OUT_E3N"
# NEGATIVE CONTROL: same reasoning as E2N.1 -- emit_release falls through to a
# BARE `{}` when there is nothing to disclose; the worktree-resolution release
# carries no other note of its own, so silence IS the correct, exact envelope.
assert_eq "E3N.1 NEGATIVE CONTROL: the exact bare envelope, nothing appended" \
    '{}' "$OUT_E3N"
assert_absent "E3N.2 NEGATIVE CONTROL: an unnarrowed worktree-resolution release names no override anywhere" \
    "OVERRIDE" "$OUT_E3N"

# ---------------------------------------------------------------------------
# Shared sandbox builder for E4-E6 (R5-F2): GATE_STATUS=approved, override
# armed, driven TWICE against an unchanged tree so the SECOND fire is a
# genuine SUITE_REUSED replay (same mechanism as Section D's D1) -- then one
# of three approval shapes decides which discipline block fires:
#   kind=none         no matching comment at all -> LABEL_WITHOUT_RECORD
#   kind=review-fail   matching hash, no bypass markers, review-check.sh
#                      ABSENT -> REVIEW_DISCIPLINE_BLOCKED (deterministic
#                      review_check_unavailable)
#   kind=design-fail   matching hash, [review bypass:] present (skips review-
#                      discipline cleanly), qa-gate.sh's own
#                      design-gate-precheck stubbed to fail -> DESIGN_
#                      DISCIPLINE_BLOCKED
# ---------------------------------------------------------------------------
build_sandbox_discipline() {
    local root="$1" ot="$2" kind="$3" h=""
    mkdir -p "$root/.claude/scripts" "$root/.claude/.qa-tracking" "$root/notes" "$root/src" \
        "$root/.beads" "$root/bin"
    cp "$VBS" "$DENY" "$IMPACT" "$root/.claude/scripts/"
    [ -f "$TREE_LEASE" ] && cp "$TREE_LEASE" "$root/.claude/scripts/"
    if [ "$kind" = "design-fail" ]; then
        cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  design-gate-precheck) printf '{"error_key":"design_not_satisfied"}\n'; exit 1 ;;
  *) exit 0 ;;
esac
QG
    else
        cat > "$root/.claude/scripts/qa-gate.sh" <<'QG'
#!/bin/bash
case "${1:-}" in
  status) printf '{"status":"approved"}\n' ;;
  *) exit 0 ;;
esac
QG
    fi
    chmod +x "$root/.claude/scripts/qa-gate.sh"
    cat > "$root/.claude/scripts/detect-stack.sh" <<DS
#!/bin/bash
printf '%s' '{"runner":"npm","test_cmd":"true","lint_cmd":"","type_cmd":"","overrides":{"test":$ot,"lint":false,"type":false}}'
DS
    chmod +x "$root/.claude/scripts/detect-stack.sh"
    printf '.claude/\nnotes/\nbin/\n.beads/\n' > "$root/.gitignore"
    init_repo "$root"
    printf 'x\n' > "$root/notes/impl.ts"
    printf '%s\n' "$root/notes/impl.ts" > "$root/.claude/.qa-tracking/changed-files.txt"
    printf 'tsk1\n' > "$root/.claude/.qa-tracking/current-task"

    local comment_json='{"comments":[]}'
    case "$kind" in
        review-fail)
            h=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
            comment_json="{\"comments\":[{\"text\":\"QA-GATE APPROVED change_set_hash=$h reviewed_by=test-fixture\"}]}"
            # review-check.sh deliberately NOT copied in: forces the
            # deterministic review_check_unavailable error_key.
            ;;
        design-fail)
            h=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
            comment_json="{\"comments\":[{\"text\":\"QA-GATE APPROVED change_set_hash=$h reviewed_by=test-fixture [review bypass: test fixture, nothing to review]\"}]}"
            ;;
    esac
    cat > "$root/bin/bd" <<BDSTUB
#!/bin/bash
if [ "\${1:-}" = "show" ]; then
    printf '%s' '$comment_json'
    exit 0
fi
exit 0
BDSTUB
    chmod +x "$root/bin/bd"
}

# ---------------------------------------------------------------------------
# E4. R5-F2 leg 1: label-without-record REPLAY block discloses.
# ---------------------------------------------------------------------------
SBE4="$WORK/sbe4"
build_sandbox_discipline "$SBE4" "true" "none"
run_stop_hook "$SBE4" "$SBE4/bin" >/dev/null
OUT_E4=$(run_stop_hook "$SBE4" "$SBE4/bin")
assert_contains "E4.0 non-vacuity: the second call is really a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E4"
assert_contains "E4.1 non-vacuity: this really is the label-without-record block" \
    "qa-approved label present but no change-set-bound approval record matches" "$OUT_E4"
assert_contains "E4.2 THE FIX: the replayed block discloses the override" \
    "OPERATOR OVERRIDE WAS IN EFFECT on the run being replayed, for: test" "$OUT_E4"

SBE4N="$WORK/sbe4n"
build_sandbox_discipline "$SBE4N" "false" "none"
run_stop_hook "$SBE4N" "$SBE4N/bin" >/dev/null
OUT_E4N=$(run_stop_hook "$SBE4N" "$SBE4N/bin")
assert_contains "E4N.0 NEGATIVE CONTROL non-vacuity: still a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E4N"
assert_contains "E4N.1 NEGATIVE CONTROL non-vacuity: still the label-without-record block" \
    "qa-approved label present but no change-set-bound approval record matches" "$OUT_E4N"
assert_absent "E4N.2 NEGATIVE CONTROL: an unnarrowed replay names no override anywhere" \
    "OVERRIDE" "$OUT_E4N"

# ---------------------------------------------------------------------------
# E5. R5-F2 leg 2: review-discipline REPLAY block discloses.
# ---------------------------------------------------------------------------
SBE5="$WORK/sbe5"
build_sandbox_discipline "$SBE5" "true" "review-fail"
run_stop_hook "$SBE5" "$SBE5/bin" >/dev/null
OUT_E5=$(run_stop_hook "$SBE5" "$SBE5/bin")
assert_contains "E5.0 non-vacuity: the second call is really a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E5"
assert_contains "E5.1 non-vacuity: this really is the review-discipline block" \
    "the INDEPENDENT REVIEW is not clean" "$OUT_E5"
assert_contains "E5.1b non-vacuity: for the deterministic reason this fixture forces" \
    "review_check_unavailable" "$OUT_E5"
assert_contains "E5.2 THE FIX: the replayed block discloses the override" \
    "OPERATOR OVERRIDE WAS IN EFFECT on the run being replayed, for: test" "$OUT_E5"

SBE5N="$WORK/sbe5n"
build_sandbox_discipline "$SBE5N" "false" "review-fail"
run_stop_hook "$SBE5N" "$SBE5N/bin" >/dev/null
OUT_E5N=$(run_stop_hook "$SBE5N" "$SBE5N/bin")
assert_contains "E5N.0 NEGATIVE CONTROL non-vacuity: still a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E5N"
assert_contains "E5N.1 NEGATIVE CONTROL non-vacuity: still the review-discipline block" \
    "the INDEPENDENT REVIEW is not clean" "$OUT_E5N"
assert_absent "E5N.2 NEGATIVE CONTROL: an unnarrowed replay names no override anywhere" \
    "OVERRIDE" "$OUT_E5N"

# ---------------------------------------------------------------------------
# E6. R5-F2 leg 3: design-discipline REPLAY block discloses.
# ---------------------------------------------------------------------------
SBE6="$WORK/sbe6"
build_sandbox_discipline "$SBE6" "true" "design-fail"
run_stop_hook "$SBE6" "$SBE6/bin" >/dev/null
OUT_E6=$(run_stop_hook "$SBE6" "$SBE6/bin")
assert_contains "E6.0 non-vacuity: the second call is really a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E6"
assert_contains "E6.1 non-vacuity: this really is the design-discipline block" \
    "DESIGN-SATISFIED no longer holds" "$OUT_E6"
assert_contains "E6.1b non-vacuity: for the deterministic reason this fixture forces" \
    "design_not_satisfied" "$OUT_E6"
assert_contains "E6.2 THE FIX: the replayed block discloses the override" \
    "OPERATOR OVERRIDE WAS IN EFFECT on the run being replayed, for: test" "$OUT_E6"

SBE6N="$WORK/sbe6n"
build_sandbox_discipline "$SBE6N" "false" "design-fail"
run_stop_hook "$SBE6N" "$SBE6N/bin" >/dev/null
OUT_E6N=$(run_stop_hook "$SBE6N" "$SBE6N/bin")
assert_contains "E6N.0 NEGATIVE CONTROL non-vacuity: still a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E6N"
assert_contains "E6N.1 NEGATIVE CONTROL non-vacuity: still the design-discipline block" \
    "DESIGN-SATISFIED no longer holds" "$OUT_E6N"
assert_absent "E6N.2 NEGATIVE CONTROL: an unnarrowed replay names no override anywhere" \
    "OVERRIDE" "$OUT_E6N"

# ---------------------------------------------------------------------------
# E7. R5-F3 end to end: a CORRUPT (not missing) cache on a real replay must
# report UNKNOWN, never silence -- the exact "false false t" reproduction,
# driven through the REAL shipped hook rather than the extracted function.
# ---------------------------------------------------------------------------
SBE7="$WORK/sbe7"
build_sandbox_discipline "$SBE7" "true" "none"
run_stop_hook "$SBE7" "$SBE7/bin" >/dev/null
E7_CACHE=$(override_state_cache_for "$SBE7")
assert_eq "E7.0 non-vacuity: the fresh run left a healthy cache to corrupt" \
    "yes" "$([ -s "$E7_CACHE" ] && echo yes || echo no)"
printf 'false false t\n' > "$E7_CACHE"
OUT_E7=$(run_stop_hook "$SBE7" "$SBE7/bin")
assert_contains "E7.1 non-vacuity: the corrupted-cache call is still a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E7"
assert_contains "E7.2 THE FIX: a corrupt cache reports UNKNOWN, not known-inactive" \
    "OVERRIDE STATE UNDETERMINED for the run being replayed" "$OUT_E7"
assert_contains "E7.3 ...naming explicitly that unknown must never read as the reassuring case" \
    "that is UNKNOWN, and unknown must never be read as" "$OUT_E7"
assert_absent "E7.4 THE DISCRIMINATOR: a corrupt cache must NEVER be asserted as a confirmed override" \
    "OPERATOR OVERRIDE WAS IN EFFECT" "$OUT_E7"
assert_absent "E7.5 ...nor confirmed as narrowed in the short claim either" \
    "the REPLAYED run was NARROWED" "$OUT_E7"

# E7b: a partially-written cache (fewer than three fields) on a real replay --
# the OTHER malformed shape the task named explicitly.
SBE7B="$WORK/sbe7b"
build_sandbox_discipline "$SBE7B" "true" "none"
run_stop_hook "$SBE7B" "$SBE7B/bin" >/dev/null
E7B_CACHE=$(override_state_cache_for "$SBE7B")
printf 'true false\n' > "$E7B_CACHE"
OUT_E7B=$(run_stop_hook "$SBE7B" "$SBE7B/bin")
assert_contains "E7B.0 non-vacuity: still a SUITE_REUSED reuse" \
    "The suite was NOT re-run this loop" "$OUT_E7B"
assert_contains "E7B.1 THE FIX: a partially-written (2-field) cache reports UNKNOWN too" \
    "OVERRIDE STATE UNDETERMINED for the run being replayed" "$OUT_E7B"
assert_absent "E7B.2 ...never asserted as a confirmed override" \
    "OPERATOR OVERRIDE WAS IN EFFECT" "$OUT_E7B"

# ===========================================================================
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
