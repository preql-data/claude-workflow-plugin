#!/bin/bash
# design-unit-bind-parity.test.sh — claude-workflow-plugin-6im2.
#
# D4a (fkm.6, commit 6d0011f) shipped `qa-gate.sh design-unit-bind` (the
# writer of the DESIGN-UNIT v1 binding record) and `qa-gate.sh design-conform`
# (the reader) together. The reader is fully built and independently tested
# (design-conform.test.sh owns that ground). NOTHING CALLED THE WRITER: no
# agent prompt named `design-unit-bind` anywhere in .claude/agents/, docs/ or
# skills/ (the only hit at HEAD was the review artifact for fkm.6 itself), so
# every real `design-conform` call took the fail-closed `unit_not_in_design`
# path — not because a task violated its unit, but because nothing had ever
# said which unit it was. This spec is the negative control for THAT gap.
#
# WHAT THIS SPEC IS, AND IS DELIBERATELY NOT
# -------------------------------------------
# LESSONS.md entry 6 (claude-workflow-plugin-n6d) is this repo's own measured
# finding that prose cues do not reliably drive subagent tool use: across 4
# live runs QA made zero impact_of calls even with the exact tool name in its
# prompt. So a passing "the orchestrator's prompt names the right command"
# check is NECESSARY evidence that the mechanism is reachable, and it is
# deliberately NOT sufficient evidence that a live orchestrator run will call
# it — that would need a live e2e invariant over a real trace, which this
# spec does not attempt and does not claim to be. What this spec DOES claim,
# narrowly: if the invocation is removed from a carrier that names it today,
# that removal is loud (this spec reddens and names the carrier) rather than
# silent (the D4a shape: design-conform.test.sh's own extensive assertion
# coverage of the READER shipped fine while nothing watched the WRITER's
# call sites at all — no assertion count is repeated here uncited; see that
# file's own header and run it directly, in isolation, for a fresh count).
#
# WHAT IT ASSERTS
#   1. Ground truth from the SHIPPED, RUNNING script. `qa-gate.sh
#      design-unit-bind` with no arguments is APPLICATION-STATE READ-ONLY —
#      cmd_design_unit_bind exits at the missing_task_id check, before
#      require_bd is ever reached: no bd invocation, no repo write, no
#      .qa-tracking write, no lock taken. It is NOT file-creation-free, and
#      this spec no longer claims it is (S6-F2, 6im2 first independent
#      review): before emit_error_json, that branch prints the full usage()
#      text to stderr, and usage() is a `cat >&2 <<'USAGE'` here-document
#      that bash materialises through a temp file (measured: an unwritable
#      TMPDIR alone is survived via bash's /tmp fallback, but a host that
#      denies file creation everywhere — the review sandbox — fails the
#      redirection, and because qa-gate.sh runs under `set -e` the script
#      dies BEFORE emit_error_json: no JSON arrives, this section reddens).
#      So the probe FAILS CLOSED on a genuinely read-only host rather than
#      falsely passing. Rerouting it through a here-document-free shipped
#      path was considered and rejected: the only one reaching the same
#      `.usage` ground truth (the missing_design_task branch) sits BEHIND
#      require_bd, which would trade one probe's file-creation-freedom for
#      a bd+.beads dependency this spec deliberately does not have — and
#      the spec as a whole needs a writable temp dir anyway (mktemp, for
#      the META mutants below), so the trade would extend nothing. The
#      probe's own `usage` field is read back — not re-typed from the
#      source — so every later assertion about "the flags this command
#      takes" is anchored to the script's ACTUAL current behaviour.
#   2. Carrier census: `.claude/agents/orchestrator.md` and
#      `.claude/skills/workflow-engine/SKILL.md` each name
#      `qa-gate.sh design-unit-bind` at least once. A COUNT-shaped assertion
#      (collapsed to yes/no per carrier, same discipline
#      completion-contract-parity.test.sh section 7 uses) rather than "every
#      mention we found is well-formed" — that phrasing is vacuously true of
#      a carrier with ZERO mentions, which is exactly the shape this task's
#      own defect had.
#   3. Every REQUIRED flag the shipped script's own usage field names is
#      also named in both carriers — guards against a rewrite that keeps
#      the bare command name but drops a required flag. The flag set is
#      PARSED from the live `.usage` value read back in section 1, never
#      hardcoded (S6-F3): bracketed `[...]` groups are stripped first so an
#      optional flag can never enter the required set, every `--token` must
#      match a strict shape or the parse REFUSES (exit 7 — a token the
#      parser cannot classify aborts the census, it never silently drops
#      out of it), and an empty or failed parse REFUSES the whole spec —
#      sections 3 and META-B iterate this set, so an empty set would make
#      them pass vacuously, the exact silent-green shape this spec exists
#      to close. The two flags the D4b change shipped (--design-task,
#      --unit-id) are asserted as CONTAINMENT ground truth — that validates
#      the parser against known reality WITHOUT capping the set, so a third
#      required flag added to the shipped usage later automatically joins
#      the census and reddens any carrier that does not name it. The parse
#      pipeline itself runs under pipefail (R8-F4, round 8): in a plain
#      pipeline only the last stage's status is visible, so a
#      preprocessing stage that failed after emitting a tokenisable stream
#      was ACCEPTED and a newly added flag could vanish from the census
#      unseen; now any stage's failure refuses, and a dedicated self-test
#      drives the shipped parser through a truncating stand-in sed exiting
#      9 to prove the refusal is BY STATUS, not by output shape.
#
# META-TESTS (the four-part pairing standard, `.claude/tests/README.md` "The
# pairing requirement"). TWO families, each mutating a COPY under mktemp —
# the live prompt is never touched, because editing the tree under review
# changes the change-set hash out from under whoever is reviewing it. Leg
# (d) EXECUTION (an artifact observed running) is satisfied once for the
# whole file by section 1, which drives the real `qa-gate.sh` subprocess
# directly rather than only ever reading its source; not re-derived per
# cell below.
#
#   A. INVOCATION STRIP, per carrier — the control for section 2:
#      (a) NON-VACUITY: confirm the shipped file names the invocation before
#          mutating anything, strip every line naming it, and confirm the
#          strip both removed lines (the copy is shorter) and landed (the
#          invocation is gone from the copy).
#      (b) SPECIFIC MISBEHAVIOUR: rebuild section 2's own two-carrier census
#          line with ONLY this carrier swapped for its stripped copy, and
#          confirm the composite line names EXACTLY this carrier as missing
#          while its sibling (read from the real, untouched tree) still
#          reports present — the same granularity section 2 itself checks
#          at, so this is a genuine simulation of "section 2 would go red,
#          and here is what it would say", not a restatement of (a).
#      (c) RESTORE CONTROL: the same census function, same file path,
#          untouched — still reports present. Confirms (b)'s "no" was caused
#          by the mutation, not by a checker that always says no.
#
#   B. REQUIRED-FLAG DROP, per carrier x per parsed flag — the control for
#      section 3 (S6-F1, 6im2 first independent review). Family A is NOT a
#      control for section 3, and before this family existed section 3 had
#      none: the invocation and its flags live on different physical lines
#      (both carriers put the flags on a continuation line), so A's
#      line-level strip removes the command name and LEAVES EVERY FLAG
#      BEHIND — measured in that review: after `grep -v 'design-unit-bind'`
#      both --design-task and --unit-id remained in both carriers, so
#      section 3 stayed green under A's mutant and discriminated nothing.
#      Per (carrier, flag) cell:
#      (a) NON-VACUITY: the shipped file names the flag; drop ONLY that
#          flag's token from a copy; prove the drop is a real byte change
#          (cmp, with rc=2 mapped to a REFUSAL value — a missing mutant
#          must never read as the passing "differs") and landed where
#          aimed (the flag is gone from the copy) and STAYED aimed: the
#          invocation needle and every SIBLING flag survive, so the mutant
#          models exactly "kept the command, lost one required flag" — the
#          drift section 2 cannot see and only section 3 catches.
#      (b) SPECIFIC MISBEHAVIOUR: rebuild section 3's own census shape for
#          this flag with ONLY this carrier swapped for its mutant, and
#          require EXACTLY this carrier to report missing while the sibling
#          (real tree) stays present.
#      (c) RESTORE CONTROL: the same census, real tree, untouched — every
#          carrier still reports the flag present.
#
# WHAT THIS SPEC DOES NOT PROVE, stated plainly rather than implied:
#   - That the orchestrator actually calls design-unit-bind in a live run.
#     See the "WHAT THIS SPEC IS" note above.
#   - That design-conform is wired into `approve`. It deliberately is not
#     (qa-gate.sh's own DESIGN-CONFORM header records the deferral). This
#     spec does not touch qa-gate.sh and asserts nothing about that wiring.
#   - That every OTHER place a human might expect this documented (e.g.
#     docs/HOOKS.md, which documents D1-D3's DESIGN-UNITS/DESIGN-DISCIPLINE/
#     GRILLING-PRECONDITION but has no section for design-unit-bind/
#     design-conform at all) carries it. Only the two carriers listed above
#     are in scope for this task; docs/HOOKS.md's gap is pre-existing and
#     unchanged by this spec.
#
# Exit codes: 0 all assertions + both META families passed | 1 an assertion
# failed, or a fail-closed REFUSAL tripped (unparseable/empty required-flag
# set; no writable scratch dir — it carries the R8-F4 PATH shim and the
# META mutants) | 2 invocation error (jq missing).

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"

if ! command -v jq >/dev/null 2>&1; then
    printf 'design-unit-bind-parity.test.sh: jq is required but not on PATH\n' >&2
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
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

print_summary() {
    printf '\nTotal: %d  Passed: %d  Failed: %d\n' "$((PASS + FAIL))" "$PASS" "$FAIL"
    if [ "$FAIL" -gt 0 ]; then
        printf 'Failed assertions:\n'
        for t in "${FAILED_TESTS[@]}"; do
            printf '  - %s\n' "$t"
        done
    fi
}

# refuse <why> — fail-closed hard stop. Only ever called right after an
# assert_eq that FAILED (so the summary's Failed count is never 0 on this
# path): a census whose input could not be established must abort loudly,
# never fall through to sections that would then iterate zero times and
# pass vacuously.
refuse() {
    printf '\nREFUSING to continue: %s\n' "$1"
    print_summary
    exit 1
}

# Carriers in scope for THIS task (orchestrator.md's own decomposition flow,
# and the skill doc CLAUDE.md / SKILL.md's own header both point to as the
# canonical rule surface). designer.md and design-reviewer.md are
# deliberately excluded: neither carries a Bash tool grant (designer.md:
# Read, Glob, Grep, LS, Write, WebFetch, WebSearch, AskUserQuestion, mcp bd/
# code-graph; design-reviewer.md: Read, Grep, Glob, LS only), so neither can
# ever invoke qa-gate.sh — the orchestrator is architecturally the only
# actor that can, which is the bug report's own claim, checked here rather
# than taken on trust.
CARRIERS_REL=(
    ".claude/agents/orchestrator.md"
    ".claude/skills/workflow-engine/SKILL.md"
)

# names_invocation <file> <needle> — yes/no. The ONE implementation of "does
# this file mention X" in this spec; every census and every META-TEST leg
# below calls this same function rather than re-deriving the check.
names_invocation() {
    local f="$1" needle="$2"
    if [ -f "$f" ] && grep -qF -- "$needle" "$f" 2>/dev/null; then
        printf 'yes'
    else
        printf 'no'
    fi
}

# census <needle> — "<label>=<yes|no> <label>=<yes|no>" over CARRIERS_REL,
# reading the REAL shipped files. Factored out so sections 2/3 and the META
# control legs call the exact same code path.
census() {
    local needle="$1" out="" rel label hit
    for rel in "${CARRIERS_REL[@]}"; do
        label="${rel##*/}"
        hit=$(names_invocation "$PROJECT_DIR/$rel" "$needle")
        out="$out $label=$hit"
    done
    printf '%s' "${out# }"
}

# parse_required_flags <usage-line> — one required `--flag` token per line
# on stdout (S6-F3: the required-flag set is READ from the live usage, never
# hardcoded). Steps:
#   1. strip bracketed [...] groups, so an OPTIONAL flag can never enter the
#      REQUIRED set (the missing_task_id usage line carries no brackets
#      today; the full usage() text spells the optional flag as
#      [--rebind '<reason>'], and this strip is what keeps it out if the
#      .usage field ever grows the same notation);
#   2. keep whitespace-delimited tokens that start with `--`;
#   3. FAIL CLOSED on anything unclassifiable: a token starting with `--`
#      that does not match ^--[a-z][a-z0-9-]*$ in full (an equals-form
#      --flag=<v>, a bare `--` separator, uppercase) exits 7 — it must
#      abort the census, never silently drop out of it;
#   4. dedupe, preserving first-seen order;
#   5. (R8-F4, round 8) the WHOLE pipeline runs under pipefail, scoped to
#      a subshell because bash 3.2 (macOS /bin/bash) has no `local -`. In
#      a plain pipeline the exit status is the LAST stage's alone, so a
#      sed that emitted a tokenisable stream and then FAILED was accepted
#      whenever awk liked what survived — reproduced on the unfixed
#      parser: a truncating sed stand-in exiting 9 gave rc=0 over the
#      valid nonempty subset "--req-a", i.e. a newly added required flag
#      could silently vanish from the census while the containment
#      assertions below stayed green. Under pipefail the rightmost
#      nonzero status wins: awk's own refusal still reads as 7, and any
#      upstream failure propagates instead of masking — the caller
#      refuses on ANY nonzero, whatever the output looked like.
parse_required_flags() {
    (
        set -o pipefail
        printf '%s\n' "$1" | sed 's/\[[^][]*\]//g' | awk '
            {
                for (i = 1; i <= NF; i++) {
                    if ($i ~ /^--/) {
                        if ($i !~ /^--[a-z][a-z0-9-]*$/) exit 7
                        if (!seen[$i]++) print $i
                    }
                }
            }'
    )
}

# ---------------------------------------------------------------------------
echo "=== Section 1: ground truth from the SHIPPED, RUNNING script ==="

# APPLICATION-STATE READ-ONLY, and only that — see header item 1 (S6-F2).
# With no <task-id>, cmd_design_unit_bind prints usage() (a here-document,
# materialised via a temp file) to stderr, emits the JSON error envelope on
# stdout, and exits 1 before require_bd is ever reached: no bd call, no repo
# or .qa-tracking write. On a host that denies file creation everywhere the
# heredoc redirection fails and qa-gate.sh (set -e) dies before the JSON is
# emitted, so this section reddens: fail closed, never falsely green.
RAW_RC=0
RAW_OUTPUT=$(bash "$PROJECT_DIR/.claude/scripts/qa-gate.sh" design-unit-bind 2>/dev/null) || RAW_RC=$?

assert_eq "shipped script: no-args call exits 1 (usage/argument error)" \
    "1" "$RAW_RC"
assert_eq "shipped script: no-args output parses as JSON" \
    "yes" "$(printf '%s' "$RAW_OUTPUT" | jq -e . >/dev/null 2>&1 && echo yes || echo no)"
assert_eq "shipped script: subcommand field names design-unit-bind" \
    "design-unit-bind" "$(printf '%s' "$RAW_OUTPUT" | jq -r '.subcommand // ""' 2>/dev/null)"

SHIPPED_USAGE=$(printf '%s' "$RAW_OUTPUT" | jq -r '.usage // ""' 2>/dev/null)
assert_eq "shipped script's own usage field is non-empty" \
    "yes" "$([ -n "$SHIPPED_USAGE" ] && echo yes || echo no)"

# The spec's ONE scratch root — created HERE rather than at META-A because
# the R8-F4 parser self-test below needs a PATH shim on disk; the META
# mutants reuse the same directory later.
META_DIR=$(mktemp -d -t dubp-meta.XXXXXX) || META_DIR=""
assert_eq "scratch: mktemp -d produced a writable directory (R8-F4 PATH shim now, META mutants later)" \
    "yes" "$([ -n "$META_DIR" ] && [ -d "$META_DIR" ] && echo yes || echo no)"
if [ -z "$META_DIR" ] || [ ! -d "$META_DIR" ]; then
    refuse "no scratch directory — the R8-F4 parser self-test and every META mutation below need one; mutating the live tree instead is not an option (it would move the change-set hash out from under whoever is reviewing it)"
fi

# The parser is exercised on synthetic inputs BEFORE it is trusted with the
# shipped usage: "REFUSES on unclassifiable input" is itself a check, and a
# refusal nothing has ever observed firing is exactly the class of unchecked
# claim this spec exists to close.
assert_eq "parser self-test: optional [--flag] groups never enter the required set" \
    "--req-a,--req-c," \
    "$(parse_required_flags "cmd <id> --req-a <x> [--opt-b '<r>'] --req-c <y>" | tr '\n' ',')"
assert_eq "parser self-test: an unclassifiable --token REFUSES (exit 7), never silently drops" \
    "7" "$(parse_required_flags 'cmd --Bad_Flag <x>' >/dev/null 2>&1; echo $?)"
assert_eq "parser self-test: a flagless usage parses to an EMPTY set (the gate below refuses it)" \
    "" "$(parse_required_flags 'cmd <id> <positional>')"

# R8-F4: the masking probe, against the SHIPPED parser. The three tests
# above all exercise awk — the LAST stage, whose status a plain pipeline
# already surfaces — so none of them could see a PREPROCESSING failure.
# This one can: a sed stand-in that TRUNCATES its input (so its output is
# distinguishable from the real sed's — a pass-through shim proves nothing
# on bracket-free input) and then exits 9. Its output is the exact trap
# shape, a valid nonempty PARTIAL flag set: judged by output alone it is
# indistinguishable from health, so only status propagation can refuse it.
# Reproduced on the unfixed parser before this fix landed: rc=0,
# out=--req-a — the 9 swallowed, --req-b silently gone from the census.
SHIM_DIR="$META_DIR/shim"
mkdir -p "$SHIM_DIR"
printf '#!/bin/sh\ncut -d" " -f1-3\nexit 9\n' > "$SHIM_DIR/sed"
chmod +x "$SHIM_DIR/sed"

shim_rc=0
shim_out=$(PATH="$SHIM_DIR:$PATH" parse_required_flags 'cmd <id> --req-a <x> --req-b <y>') || shim_rc=$?
assert_eq "parser self-test (R8-F4): a preprocessing stage that FAILS after emitting a tokenisable stream is REFUSED — its status (9) propagates through pipefail" \
    "9" "$shim_rc"
assert_eq "parser self-test (R8-F4): the trap shape is real — that run still emitted a valid nonempty PARTIAL set (--req-b silently gone), so ONLY the propagated status refused it" \
    "--req-a," "$(printf '%s\n' "$shim_out" | tr '\n' ',')"

PARSE_RC=0
FLAGS_RAW=$(parse_required_flags "$SHIPPED_USAGE") || PARSE_RC=$?
assert_eq "shipped usage parses cleanly (rc=0 — no token the parser had to refuse)" \
    "0" "$PARSE_RC"

REQUIRED_FLAGS=()
if [ "$PARSE_RC" -eq 0 ] && [ -n "$FLAGS_RAW" ]; then
    while IFS= read -r tok; do
        [ -n "$tok" ] && REQUIRED_FLAGS+=("$tok")
    done < <(printf '%s\n' "$FLAGS_RAW")
fi

assert_eq "parsed required-flag set is NON-EMPTY (an empty census asserts nothing)" \
    "yes" "$([ "${#REQUIRED_FLAGS[@]}" -gt 0 ] && echo yes || echo no)"

if [ "$PARSE_RC" -ne 0 ] || [ "${#REQUIRED_FLAGS[@]}" -eq 0 ]; then
    refuse "required-flag set unavailable (parse rc=$PARSE_RC, count=${#REQUIRED_FLAGS[@]}) — section 3 and META-B iterate this set, so continuing would run them zero times and score the flag census green having checked nothing"
fi

# set_contains <flag> — yes/no over REQUIRED_FLAGS (exact token match).
set_contains() {
    local needle="$1" f
    for f in "${REQUIRED_FLAGS[@]}"; do
        if [ "$f" = "$needle" ]; then
            printf 'yes'
            return 0
        fi
    done
    printf 'no'
}

# Containment ground truth, NOT a cap (S6-F3): these two validate the parser
# against the contract this task shipped. A third required flag added to the
# shipped usage later passes both, joins REQUIRED_FLAGS, and is censused
# against the carriers below with no edit here.
assert_eq "parsed set contains --design-task (containment ground truth, not a cap)" \
    "yes" "$(set_contains '--design-task')"
assert_eq "parsed set contains --unit-id (containment ground truth, not a cap)" \
    "yes" "$(set_contains '--unit-id')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: carrier census — the invocation is REACHABLE from both docs ==="

assert_eq "invocation census: every carrier names 'qa-gate.sh design-unit-bind'" \
    "orchestrator.md=yes SKILL.md=yes" "$(census 'qa-gate.sh design-unit-bind')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: every required flag the shipped usage names is named by every carrier ==="

# Driven by REQUIRED_FLAGS, parsed from the live .usage in section 1 — never
# hardcoded (S6-F3).
for flag in "${REQUIRED_FLAGS[@]}"; do
    assert_eq "flag census: every carrier names '$flag'" \
        "orchestrator.md=yes SKILL.md=yes" "$(census "$flag")"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST A: invocation strip, per carrier ==="

for rel in "${CARRIERS_REL[@]}"; do
    label="${rel##*/}"
    src="$PROJECT_DIR/$rel"
    stripped="$META_DIR/$label.stripped"

    # (a) NON-VACUITY: the mutation is real, and it landed.
    assert_eq "META-A $label: pre-mutation sanity — the shipped file names the invocation" \
        "yes" "$(names_invocation "$src" 'qa-gate.sh design-unit-bind')"
    grep -v 'design-unit-bind' "$src" > "$stripped"
    assert_eq "META-A $label: the strip removed lines (stripped copy is shorter than shipped)" \
        "shorter" "$([ "$(wc -l < "$stripped")" -lt "$(wc -l < "$src")" ] && echo shorter || echo same)"
    assert_eq "META-A $label: the strip landed (stripped copy no longer names the invocation)" \
        "no" "$(names_invocation "$stripped" 'qa-gate.sh design-unit-bind')"

    # (b) SPECIFIC MISBEHAVIOUR: rebuild section 2's exact census shape with
    # ONLY this carrier swapped for its stripped copy. The composite line
    # must name EXACTLY this carrier as missing while its sibling (read from
    # the real, untouched tree) stays present.
    mut_out=""
    expect_out=""
    for rel2 in "${CARRIERS_REL[@]}"; do
        label2="${rel2##*/}"
        if [ "$rel2" = "$rel" ]; then
            hit=$(names_invocation "$stripped" 'qa-gate.sh design-unit-bind')
            mut_out="$mut_out $label2=$hit"
            expect_out="$expect_out $label2=no"
        else
            hit=$(names_invocation "$PROJECT_DIR/$rel2" 'qa-gate.sh design-unit-bind')
            mut_out="$mut_out $label2=$hit"
            expect_out="$expect_out $label2=yes"
        fi
    done
    assert_eq "META-A $label: the section-2-shaped census names EXACTLY this carrier as missing" \
        "${expect_out# }" "${mut_out# }"

    # (c) RESTORE CONTROL: the same function, same real path, untouched —
    # still reports present. Proves (b)'s "no" was the mutation, not a
    # checker that always answers no.
    assert_eq "META-A $label: control — re-checking the real shipped file (no mutation) reports present" \
        "yes" "$(names_invocation "$src" 'qa-gate.sh design-unit-bind')"
done

# ---------------------------------------------------------------------------
echo ""
echo "=== META-TEST B: required-flag drop, per carrier x per parsed flag ==="

# Section 3's own negative control (S6-F1) — family A cannot be it: both
# carriers put the flags on a continuation line that survives A's
# `grep -v 'design-unit-bind'` strip, so under A's mutant section 3 stays
# green and discriminates nothing. Every cell below is its own four-part
# pair; leg (d) execution is section 1's, once for the whole file, as in A.

for rel in "${CARRIERS_REL[@]}"; do
    label="${rel##*/}"
    src="$PROJECT_DIR/$rel"

    for flag in "${REQUIRED_FLAGS[@]}"; do
        dropped="$META_DIR/$label.${flag#--}.dropped"

        # (a) NON-VACUITY: present before the drop...
        assert_eq "META-B $label x $flag: pre-mutation sanity — the shipped file names the flag" \
            "yes" "$(names_invocation "$src" "$flag")"

        # ...drop ONLY this flag's token, everywhere it appears (substring
        # removal: the parser validated the token to ^--[a-z][a-z0-9-]*$,
        # which is sed-BRE-inert and cannot collide with the <placeholder>
        # spellings, which carry no leading --).
        sed "s/$flag//g" "$src" > "$dropped"

        # ...and the drop is a REAL byte change. cmp's rc is mapped
        # exactly: 0=identical, 1=differs, anything else (missing or
        # unreadable mutant) = a REFUSAL value that can never satisfy the
        # expected "differs" — a failed subprocess must never read as the
        # passing answer.
        cmp_rc=0
        cmp -s "$src" "$dropped" 2>/dev/null || cmp_rc=$?
        if [ "$cmp_rc" -eq 0 ]; then
            byte_state="identical"
        elif [ "$cmp_rc" -eq 1 ]; then
            byte_state="differs"
        else
            byte_state="unreadable(cmp rc=$cmp_rc)"
        fi
        assert_eq "META-B $label x $flag: the drop is a real mutation (mutant differs byte-wise from shipped)" \
            "differs" "$byte_state"
        assert_eq "META-B $label x $flag: the drop landed where aimed (mutant no longer names the flag)" \
            "no" "$(names_invocation "$dropped" "$flag")"

        # Mutation SPECIFICITY — the mutant must model exactly the drift
        # section 3 exists to catch BEYOND section 2: command kept, one
        # required flag lost. If either leg fails, the drop over-cut and
        # (b) below would redden for the wrong reason.
        assert_eq "META-B $label x $flag: the mutant STILL names 'qa-gate.sh design-unit-bind' (section 2 cannot see this mutant)" \
            "yes" "$(names_invocation "$dropped" 'qa-gate.sh design-unit-bind')"

        sibling_count=0
        siblings_state="intact"
        for other in "${REQUIRED_FLAGS[@]}"; do
            [ "$other" = "$flag" ] && continue
            sibling_count=$((sibling_count + 1))
            if [ "$(names_invocation "$dropped" "$other")" != "yes" ]; then
                # Reachable if one flag's token is a substring of another's
                # (a prefix collision the substring drop would mangle) — loud
                # here rather than a silent wrong-reason census in (b).
                siblings_state="damaged($other)"
            fi
        done
        expected_siblings="intact"
        if [ "$sibling_count" -eq 0 ]; then
            siblings_state="none-to-check"
            expected_siblings="none-to-check"
        fi
        assert_eq "META-B $label x $flag: every SIBLING required flag survives the drop" \
            "$expected_siblings" "$siblings_state"

        # (b) SPECIFIC MISBEHAVIOUR: section 3's own census shape for this
        # flag, with ONLY this carrier swapped for its mutant — EXACTLY this
        # carrier must report missing while the sibling carrier (read from
        # the real, untouched tree) stays present.
        mut_out=""
        expect_out=""
        for rel2 in "${CARRIERS_REL[@]}"; do
            label2="${rel2##*/}"
            if [ "$rel2" = "$rel" ]; then
                hit=$(names_invocation "$dropped" "$flag")
                mut_out="$mut_out $label2=$hit"
                expect_out="$expect_out $label2=no"
            else
                hit=$(names_invocation "$PROJECT_DIR/$rel2" "$flag")
                mut_out="$mut_out $label2=$hit"
                expect_out="$expect_out $label2=yes"
            fi
        done
        assert_eq "META-B $label x $flag: the section-3-shaped census names EXACTLY this carrier as missing" \
            "${expect_out# }" "${mut_out# }"

        # (c) RESTORE CONTROL: same census function, real tree, untouched —
        # every carrier still reports the flag present. Proves (b)'s "no"
        # was the mutation, not a checker that always answers no.
        assert_eq "META-B $label x $flag: control — the real tree still reports the flag present in every carrier" \
            "orchestrator.md=yes SKILL.md=yes" "$(census "$flag")"
    done
done

rm -rf "$META_DIR"

# --- Summary -------------------------------------------------------------

print_summary

if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
