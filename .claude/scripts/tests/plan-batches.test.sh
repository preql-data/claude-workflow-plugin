#!/bin/bash
# plan-batches.test.sh — v5 Phase D4b (claude-workflow-plugin-fkm.6):
# epic-gate.sh plan-batches.
#
# BD-FREE BY DESIGN. Every other L1 spec touching qa-gate.sh's DESIGN-*
# records drives a REAL `bd` against a throwaway, `cd`-isolated fixture
# store (design-conform.test.sh's own convention). This spec instead
# writes canned per-task JSON directly (bd_fixture_write below) behind a
# hand-authored `bd` shim placed first on PATH, for two reasons specific
# to this subcommand:
#
#   1. The batching PRIMITIVE (the greedy first-fit computation this
#      file's mutants target) needs only a design ARTIFACT — a plain file
#      — plus a unit_id->task_id map. review-check.sh validate-design is
#      already 100% bd-free; going through real `bd create` +
#      design-record + design-review-record + design-unit-bind for every
#      one of the ~15 scenarios below (positive arm, 5 mutants, the
#      determinism leg, several guard probes) would multiply this spec's
#      wall-clock cost for no additional coverage of the thing under test.
#   2. The unit<->task mapping path (design-unit-show, and therefore every
#      Category-C guard: 9 unbound / 10 unit_not_in_design / 11 stale-hash
#      / 12 multiply-bound) has NO LIVE CALLER anywhere in this tree yet
#      (claude-workflow-plugin-6im2: design-unit-bind was uncalled from
#      any agent prompt until a sibling task wired the orchestrator to it;
#      no run has ever produced a real DESIGN-UNIT record). This spec's
#      coverage of that path is necessarily FIXTURE-ONLY — built here
#      explicitly, not implied as live-data coverage.
#
# The fake `bd` supports exactly the one operation epic-gate.sh and
# qa-gate.sh's design-status/design-unit-show issue: `bd show <id> --json
# [--include-dependents|--include-comments]`. It answers identically
# regardless of which flag is passed (both are always present in the
# canned JSON) — the compat-fallback CHAIN those two flags exist for
# (bd 1.1.2 vs 0.47.x) is a bd-version concern, not a plan-batches concern,
# and is exercised for real by design-conform.test.sh's own bd-backed
# fixture.
#
# WHAT THIS COVERS:
#   Section 1: the POSITIVE ARM (built first — degradation collapses to
#     one-unit-per-batch by construction, so without a real multi-unit
#     batch every mutant below would be vacuous: a function that always
#     degrades would pass them all).
#   Section 2: determinism (byte-identical manifest==stdout across two
#     runs; a reorder of the SAME units changes the plan, proving artifact
#     order — not `unit_files | keys`, which SORTS — is genuinely read).
#   Section 3: Mutant 1 — the union-accumulation bug (compare a candidate
#     against a batch's FULL accumulated file union, never just its most
#     recently added member).
#   Section 4: Mutant 2 — THE META-TEST docs/plans/v5-design-phase.md:159
#     pre-specifies verbatim ("stub the intersection check to always
#     return empty — the batching assertion must fail").
#   Section 5: Mutant 3 — the # PLAN-BATCHES-NO-DESIGN-GUARD sentinel.
#   Section 6: Mutant 4 — jq absence.
#   Section 7: Mutant 5 — dependency order.
#   Section 8: additional guard-list probes (6/9/10/11/12/13) not already
#     covered by a mutant above, run directly against the shipped script.
#   Section 9: independent cross-family review findings.
#     Round 1 (9a-9e): R1-F1 (a resolvable unit depending on an unresolved
#     one degrades, never silently drops the edge), R1-F3 (a
#     case-insensitive collision between two declared paths degrades even
#     though case is never folded), R1-F4 (unit_task_map's key order is
#     artifact order, proven stable across reversed child
#     enumeration/binding order), R1-F2 widened (three MORE fail-open sites
#     Mutant 2 alone could not reach — unit_task_map_json's construction,
#     the .ud_r extraction, the final .batches extraction — each
#     independently verified fail-closed under an actual induced jq
#     failure), and a new four-part-paired mutant for the
#     PLAN-BATCHES-MULTIBIND-GATE sentinel (R1-F5: guard 12 also has no
#     redundant downstream backup).
#     Round 2 (9f-9h): R2-F3 (9f — degraded batches respect a KNOWN
#     dependency order via a best-effort topological pass, never just a
#     lexicographic id sort that can place a dependent's task before its
#     own prerequisite's; mutant target is the new
#     PLAN-BATCHES-TOPO-ORDER-GATE sentinel, a behaviour-preserving
#     refactor of _pb_degrade's ordering step made specifically to be
#     sentinel-strippable), R2-F1 (9g/9g2 — two byte-different declared
#     paths that identify the SAME file through an existing symlinked
#     ancestor directory, reproducing the review's own `tests ->
#     .claude/scripts/tests` illustration with a fixture-local symlink;
#     9g2 additionally direct-verifies the complementary -ef device+inode
#     pass for an already-existing file-level alias; mutant target is the
#     new PLAN-BATCHES-ALIAS-GATE sentinel), and R2-F4 (9h — a
#     PRESENT-but-MALFUNCTIONING jq, found on PATH but failing every
#     invocation, degrades this subcommand exactly like every other
#     guard-list condition rather than the narrower ok:false/exit 2 shape
#     this used to fall back to; mutant target is the new
#     PLAN-BATCHES-FINISH-FALLBACK-GATE sentinel around _pb_finish's own
#     fallback literal). R2-F2 and R2-F5/R2-F6 needed no new fixture
#     coverage — R2-F2 is covered by 9d's own rewrite (exact-match shim +
#     uniqueness preconditions), and R2-F5/R2-F6 were documentation/spec-
#     hygiene fixes with no assertable runtime behaviour of their own.
#     Round 3 (9g/9g2/9g3/9g4/9i/9j — 9g and 9g2 REWORKED in place, not
#     appended, since the code they test was replaced rather than
#     extended): R3-F1 and R3-F2 together prompted a SMALLER pass 1 —
#     _pb_canonical_key's resolve-a-key-and-compare chain (round 2) is
#     GONE, replaced by _pb_path_has_symlink, an unconditional "does any
#     component of this declared path resolve as a symlink" check with no
#     cross-file comparison left to have a bug in. 9g now targets that
#     replacement directly (mutant: PLAN-BATCHES-ALIAS-GATE, unchanged
#     sentinel, new expected reason declared_path_traverses_symlink); 9g2
#     switched its own fixture from a file-level symlink (now caught by
#     the new pass 1 itself, so it no longer distinctly exercised pass 2)
#     to a hard link, which shares an inode without being a symlink at
#     all; 9g3/9g4 are new coverage for R3-F2 specifically — a DANGLING
#     symlink (target does not exist) now degrades, where the old
#     -d/-e-based resolver could not see it, covering BOTH shapes the
#     finding named: a dangling LEAF (9g3, alias.sh -> real.sh) and a
#     dangling ANCESTOR two levels deep (9g4, a symlinked directory to a
#     nonexistent target used as a path prefix, where nothing under it
#     can exist either). R3-F1's OTHER half — the alias pass's own
#     per-line (.u, .f) extraction reading a failure as "nothing to
#     check" rather than "could not check", the reviewer's own probe
#     against the 9g fixture — is 9i, a direct rc-AND-shape fail-closed
#     verification of both fields independently (this file's fourth
#     instance of exactly this bug class caught by review, per the
#     finding's own count). R3-F3 (9j) is a new mutant for
#     PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE: two children bind cleanly
#     with a real dependency while a third is simply unbound, which
#     degrades at the CHILD-BINDING-GATE call site specifically — earlier
#     than 9f's own unit_depends_on_unresolved_unit call site — and the
#     R2-F3 topological reducer needs its bindings published before THAT
#     point to get the order right. R3-F4 needed no new fixture coverage
#     (a second stale-cardinality-claim removal, no assertable behaviour).
#     Round 4 (R4): R4-F6 changed the HARNESS ITSELF — EG now names
#     $CANON/epic-gate.sh (the SHIPPED repository artifact, leg 4 of the
#     four-part pairing standard) rather than a fixture copy; the fixture
#     copies remain only as the SUPPORT scripts (qa-gate.sh,
#     review-check.sh, workflow-manifest.sh) each run resolves via
#     CLAUDE_PROJECT_DIR, and Section 8's unmutated roots likewise run
#     $EG now. Section 4 was split (R4-F7): 4A mutates the intersection
#     PREDICATE itself to select( true ) and asserts the mutant
#     CO-BATCHES two units declaring the same file — the META-TEST the
#     plan doc pre-specifies verbatim — while 4B keeps the original
#     fail-open-on-jq-failure mutant under an honest label (it guards
#     the batch reduce's failure HANDLING, a distinct property). 9f was
#     reworked in place (the code it targeted was replaced — the 9g
#     precedent): after R4-F5 removed _pb_degrade's lexical fallback,
#     stripping PLAN-BATCHES-TOPO-ORDER-GATE loses the degraded schedule
#     entirely (batches=[]) instead of emitting a wrong order, and 9f.9
#     asserts exactly that. New sections: 9k (R4-F2 — a validator
#     printing shape-valid ok:true JSON but exiting nonzero is refused;
#     lying-validator stub + awk exact-line-replacement mutant), 9l
#     (R4-F3 — a declared path with a trailing newline degrades at the
#     new PLAN-BATCHES-CONTROL-CHAR-GATE; reachability preconditions
#     prove validate-design itself ACCEPTS the path, so the gate is the
#     only detection point), 9m (R4-F1 — the alias flattening's
#     CARDINALITY is verified against the sum of declared files[]
#     lengths; successful-but-EMPTY and successful-but-PARTIAL jq shims
#     plus a PLAN-BATCHES-ALIAS-CARDINALITY-GATE strip mutant over a
#     real symlinked collision), and 9n (R4-F4/R4-F5/R4-F8 —
#     _pb_degrade's two remaining jq sites each injected independently
#     against a fixture with real children and a KNOWN dependency edge,
#     asserting the fail-closed refusal: envelope still emitted, exit 0,
#     root-cause reason preserved, batches=[] rather than a lexical
#     order over the known edge; 9h's own comment now discloses that its
#     nonexistent-epic control reaches _pb_degrade with ZERO children).
#     Sections 4 and 7 now RECORD a python3-absent skip
#     (SKIPPED_SECTIONS plus a line-initial `  SKIP:` marker the
#     runner's SECTION_SKIP_RE counts) instead of passing silently, and
#     the spec ends with a Total/Passed/Failed/Skipped-sections
#     completeness line.
#     Round 5 (R5): 9f's mutant RE-TARGETED in place a second time (the
#     round-5 vacuity sweep: after R4-F5, stripping TOPO-ORDER-GATE
#     yields batches=[] -- the SAFE refusal -- so that leg no longer
#     discriminated a dependency-order violation). It now strips
#     PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE over a fixture that
#     degrades INSIDE the R5-F4 window (a non-canonical declared path
#     with every child cleanly bound), where the shipped script -- with
#     the binding loop moved ahead of every post-validation guard --
#     emits the topologically correct serial schedule and the mutant
#     emits a GENUINE wrong order over a known edge; the shipped-control
#     legs double as the R5-F4 regression guard. 9h extended for R5-F5
#     with a call-site-targeted rc-0-malformed emit shim (prints [] and
#     exits 0 for the one program matching a source-unique marker,
#     passes everything else to real jq): the shipped script's new
#     envelope-shape validation routes it to the jq-independent
#     fallback, and the already-stripped FINISH-FALLBACK-GATE mutant
#     persists and prints the malformed bytes. 9n extended for R5-F6
#     with injection C (the construction SUCCEEDS with
#     {"ok":true,"batches":[]} over 3 real children): the validating
#     extraction refuses on cardinality with the annotation, and a new
#     PLAN-BATCHES-SCHED-SHAPE-GATE strip mutant (jq-comment sentinels
#     INSIDE the extraction filter) reverts to round-4 acceptance and
#     silently adopts the empty schedule -- annotation absent. 9n's
#     extraction marker changed with the filter (now a source-unique
#     SUBSTRING of the multiset validation, since the old whole-argument
#     program no longer exists). New sections 9o/9p pair R5-F1's strict
#     type gates: lying stubs whose ONLY malformation is a string-typed
#     satisfied/ok (all other fields genuinely typed, exit 0), refused
#     by the shipped script as *_unavailable, and awk exact-line-revert
#     mutants (9k's ENVIRON technique) that trust the string and compute
#     full clean plans -- over a never-reviewed design in 9o's case,
#     from the malformed validator's own unit data in 9p's.
#     Round 7 (R7): R7-F1 CORRECTED round 6's partial-mapping reasoning
#     -- a BOUND unit whose design dependency has no bound implementing
#     task is now REFUSED by the degraded-schedule construction
#     (PLAN-BATCHES-DEGRADE-DEP-RESOLVE-GATE, a jq-comment sentinel
#     like round 5's shape gate): the design RECORDS the edge, only the
#     task mapping is missing, and the old // empty lookup erased it,
#     reading a failed resolution as "no constraint". 9f.1-9f.3b
#     reworked in place (that fixture's bound-unit-with-orphan-dep
#     shape now refuses instead of ordering the other two tasks; the
#     ordering property moved to 9j.9/9n.3/9f.6, which all bind both
#     edge ends); 9r is the previously-unexercised shape the round-7
#     reviewer reproduced (dependent bound, PREREQUISITE unbound), with
#     the strip mutant emitting the dependent's task first. 9s probes
#     R7-F3's three rc-0-wrong-shape cases at their exact call sites
#     (the multiply-bound decision is now jq-free bash cardinality; the
#     resolvable-set gate verifies the r+unresolved partition against
#     unit_ids; the batching gate verifies the ok:true member multiset
#     against R); the general guarded-envelope form for every safety
#     computation stays deferred to claude-workflow-plugin-uopo by
#     operator decision. R7-F8 reconciled the one-task-per-batch claim
#     (this header, epic-gate.sh's usage and contract header, and
#     docs/HOOKS.md) with the refusal paths rounds 5-7 added: singleton
#     serial batches only when child ids AND a dependency-safe order
#     are both available, explicitly [] otherwise.
#     Round 8 (R8): R8-F2 -- the round-7 multiply-bound decision had
#     escaped the unguarded-jq channel (uopo) into the unguarded-
#     PIPELINE channel (i8cx); its counting pipeline now runs under a
#     scoped `set -o pipefail`, and 9t injects the reviewer's exact
#     sort sabotage (copy stdin, exit 9) with a line-revert mutant that
#     skips the duplicate branch and reports parallel_safe=true. R8-F1
#     -- the validated design's unit_ids/unit_files/unit_deps
#     re-extractions no longer substitute []/{} on failure (R7-F1 one
#     level upstream); they are ONE guarded jq call, rc-AND-shape
#     checked per field, refusing with batches=[] and NO child ids, and
#     its program text is proven unique across every script the run
#     executes (9u.0b) because review-check.sh carries textually
#     identical single-field extractions a shim would strand at. R8-F3
#     (the cheap half only; file-conflict and dependency-order
#     re-validation of the batching output are a second implementation
#     of the algorithm under guard, deferred by operator decision):
#     the resolvable-set gate pins r to unit_task_map's keys (9s.6) and
#     the batching gate pins every member's task_id to the map (9s.7);
#     4B's forged fallback consequently had to become fully
#     map-consistent, its marker moving to an extra member key.
#
# `cmd_shared_files` and its own L2 spec are UNTOUCHED — this file adds
# coverage, it does not modify either.
#
# Exit codes: 0 all assertions passed | 1 one or more failed.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()
# R4 vacuity sweep: a section that cannot run (python3 absent) is RECORDED,
# never silently passed over. Each skipped section prints a line-initial
# `  SKIP:` marker (one of run-tests.sh's four recognised SECTION_SKIP_RE
# shapes) and moves this counter, which the final completeness line names.
SKIPPED_SECTIONS=0
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"
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

json_field() {
    # json_field <jq-filter> <json>
    printf '%s' "$2" | jq -r "$1" 2>/dev/null
}

REAL_JQ=$(command -v jq)
if [ -z "$REAL_JQ" ]; then
    echo "FATAL: jq not on PATH; this harness itself needs it" >&2
    exit 2
fi

# Same derivation as design-conform.test.sh's own PLUGIN_DIR: $0, three
# levels up from .claude/scripts/tests/.
PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
CANON="$PLUGIN_DIR/.claude/scripts"

FIXTURE=$(mktemp -d -t plan-batches.XXXXXX)

# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\n' "$FIXTURE"
    else
        chmod -R u+rwX "$FIXTURE" 2>/dev/null || true
        rm -rf "$FIXTURE"
    fi
}
trap cleanup EXIT

SCRIPTS="$FIXTURE/.claude/scripts"
mkdir -p "$SCRIPTS" "$FIXTURE/docs/specs" "$FIXTURE/.beads" "$FIXTURE/bd-fixture" "$FIXTURE/fake-bd"
cp "$CANON/"*.sh "$SCRIPTS/"
chmod 0755 "$SCRIPTS"/*.sh

cat > "$FIXTURE/fake-bd/bd" <<FAKEBD
#!/bin/bash
# Fake bd — see this spec's own header for what it supports and why.
case "\${1:-}" in
    show)
        tid="\${2:-}"
        f="\$BD_FIXTURE_DIR/\$(printf '%s' "\$tid" | tr -c 'A-Za-z0-9._-' '_').json"
        if [ -f "\$f" ]; then
            cat "\$f"
            exit 0
        fi
        printf '{"error":"no such fixture task: %s"}\n' "\$tid" >&2
        exit 1
        ;;
    *)
        printf 'fake-bd: unsupported invocation: %s\n' "\$*" >&2
        exit 1
        ;;
esac
FAKEBD
chmod 0755 "$FIXTURE/fake-bd/bd"

export CLAUDE_PROJECT_DIR="$FIXTURE"
export BD_FIXTURE_DIR="$FIXTURE/bd-fixture"
export PATH="$FIXTURE/fake-bd:$PATH"

# R4-F6 (independent review, xsu1 round 4): EG names the CANONICAL
# repository artifact — the thing this spec exists to test — NEVER a
# fixture copy. Before this fix every leg labelled SHIPPED ran the copy
# made by the `cp` above (`grep -c '$CANON/epic-gate.sh'` over this spec
# returned 0), so leg 4 of the four-part pairing standard (at least one
# leg observes the SHIPPED artifact RUNNING) was absent while the labels
# asserted otherwise. The copies under $SCRIPTS remain — as the SUPPORT
# scripts (qa-gate.sh, review-check.sh, workflow-manifest.sh) that
# epic-gate.sh resolves from CLAUDE_PROJECT_DIR at runtime — so every run
# below still keeps its supporting scripts and data fixture-local while
# executing the real artifact. Mutant sections keep their own EG_M copies;
# that is the point of a mutant.
EG="$CANON/epic-gate.sh"
WFM="$SCRIPTS/workflow-manifest.sh"

# --- fixture-writing helpers -----------------------------------------------
# Every helper below takes the bd-fixture directory and/or artifact root
# EXPLICITLY (never a hidden global) — the mutant sections (3, 4, 5, 7) each
# need their own, fully self-contained fixture root (own .claude/scripts/,
# own docs/specs/, own bd-fixture/), per this file's own header note on why
# a sibling mutant must not accidentally re-use an unmutated shared copy.

# bd_fixture_write <bd-fixture-dir> <id> <dependents-json-array> <comments-json-array-of-strings>
bd_fixture_write() {
    local bdfix="$1" id="$2" deps="$3" comments="$4" f
    f="$bdfix/$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_').json"
    # shellcheck disable=SC2016
    "$REAL_JQ" -n --arg id "$id" --argjson deps "$deps" --argjson comments "$comments" \
        '{id:$id, status:"open", labels:[], dependents:$deps,
          comments: ($comments | map({text:.}))}' > "$f"
}

# write_artifact <path> <task-id> <units-json>
write_artifact() {
    local path="$1" tid="$2" units="$3" block
    # shellcheck disable=SC2016
    block=$("$REAL_JQ" -n --arg t "$tid" --argjson u "$units" \
        '{contract_version:"1", task_id:$t, designer_identity:"designer", units:$u}')
    cat > "$path" <<ART
## Problem
p
## Approaches considered
a1
a2
## Chosen approach
c
## Units
u
## Global constraints
g
## Out of scope
o
## Verification plan
v
## Revision log
r

<!-- DESIGN-UNITS BEGIN -->
\`\`\`json
$block
\`\`\`
<!-- DESIGN-UNITS END -->
ART
}

design_hash_of() {
    # design_hash_of <workflow-manifest.sh-path> <artifact-path>
    bash "$1" hash-file "$2"
}

# seed_epic <root> <bd-fixture-dir> <wfm-path> <epic-id> <units-json>
#           <child-ids-csv-or-empty>
# Writes the artifact under <root>/docs/specs/, its DESIGN-ARTIFACT +
# DESIGN-REVIEW (satisfied) comments, and the epic's own fixture record
# naming its children as parent-child dependents. Prints the design_hash.
seed_epic() {
    local root="$1" bdfix="$2" wfm="$3" epic="$4" units="$5" children_csv="${6:-}"
    local apath dh ts c1 c2 comments deps
    apath="$root/docs/specs/$epic.md"
    mkdir -p "$root/docs/specs"
    write_artifact "$apath" "$epic" "$units"
    dh=$(design_hash_of "$wfm" "$apath")
    ts="2026-01-01T00:00:00Z"
    # shellcheck disable=SC2016
    c1="DESIGN-ARTIFACT v1 task=$epic designer=designer design_hash=$dh units=$("$REAL_JQ" -n --argjson u "$units" '$u|length') at $ts: seeded"
    c2="DESIGN-REVIEW v1 task=$epic reviewer=design-reviewer verdict=satisfied design_hash=$dh iteration=1 rubric_version=1 at $ts: seeded"
    # shellcheck disable=SC2016
    comments=$("$REAL_JQ" -nc --arg a "$c1" --arg b "$c2" '[$a,$b]')
    deps="[]"
    if [ -n "$children_csv" ]; then
        # shellcheck disable=SC2016
        deps=$("$REAL_JQ" -nc --arg csv "$children_csv" \
            '$csv | split(",") | map({id:., dependency_type:"parent-child"})')
    fi
    bd_fixture_write "$bdfix" "$epic" "$deps" "$comments"
    printf '%s' "$dh"
}

# bind_child <bd-fixture-dir> <task-id> <design-task-id> <unit-id> <design-hash>
bind_child() {
    local bdfix="$1" tid="$2" design_task="$3" unit_id="$4" dh="$5" ts comment
    ts="2026-01-01T00:05:00Z"
    comment="DESIGN-UNIT v1 task=$tid design_task=$design_task unit_id=$unit_id design_hash=$dh at $ts: seeded"
    # shellcheck disable=SC2016
    bd_fixture_write "$bdfix" "$tid" "[]" "$("$REAL_JQ" -nc --arg c "$comment" '[$c]')"
}

# unbound_child <bd-fixture-dir> <task-id> -- a real, enumerable child with
# NO binding at all.
unbound_child() {
    bd_fixture_write "$1" "$2" "[]" "[]"
}

# new_fixture_root <name> -- a FRESH, fully self-contained fixture root
# under $FIXTURE/roots/<name>: its own .claude/scripts/ (a full copy of
# every canonical script — sections mutate epic-gate.sh within THIS copy
# only), docs/specs/, and bd-fixture/. Sets ROOT/BDFIX/EG_M/QAG_M/WFM_M.
new_fixture_root() {
    local name="$1"
    ROOT="$FIXTURE/roots/$name"
    mkdir -p "$ROOT/.claude/scripts" "$ROOT/docs/specs" "$ROOT/.beads" "$ROOT/bd-fixture"
    cp "$CANON/"*.sh "$ROOT/.claude/scripts/"
    chmod 0755 "$ROOT/.claude/scripts/"*.sh
    BDFIX="$ROOT/bd-fixture"
    EG_M="$ROOT/.claude/scripts/epic-gate.sh"
    WFM_M="$ROOT/.claude/scripts/workflow-manifest.sh"
}

u() {
    # u <unit_id> <files-csv> <deps-csv-or-empty> -> one unit object (JSON)
    local id="$1" files_csv="$2" deps_csv="${3:-}"
    # shellcheck disable=SC2016
    "$REAL_JQ" -nc --arg id "$id" --arg fc "$files_csv" --arg dc "$deps_csv" \
        '{unit_id:$id, goal:("goal-"+$id), verification:("verify-"+$id),
          files: ($fc | split(",") | map(select(length>0))),
          acceptance: [{id:("AC-"+$id), text:("text-"+$id)}],
          depends_on: (if $dc == "" then [] else ($dc | split(",")) end)}'
}

units_of() {
    # units_of <unit-json...> -> combine into one JSON array
    "$REAL_JQ" -sc . <<< "$(printf '%s\n' "$@")"
}

printf '\n=== plan-batches.test.sh: fixture ready at %s ===\n' "$FIXTURE"

# R4-F6: pin the shipped-artifact convention mechanically, so re-pointing
# EG at a copy (the exact defect round 4 found) fails a leg instead of
# silently demoting every SHIPPED label below to a fiction.
assert_eq "0.1 R4-F6: EG is the canonical repository artifact (\$CANON/epic-gate.sh), not a fixture copy" \
    "$CANON/epic-gate.sh" "$EG"

# ===========================================================================
printf '\n=== Section 1: the POSITIVE ARM ===\n'
# ===========================================================================
U1=$(u U1 "a.sh")
U2=$(u U2 "a.sh,b.sh")
U3=$(u U3 "c.sh")
UNITS=$(units_of "$U1" "$U2" "$U3")
DH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-POS" "$UNITS" "T-U1,T-U2,T-U3")
bind_child "$FIXTURE/bd-fixture" "T-U1" "EPIC-POS" "U1" "$DH"
bind_child "$FIXTURE/bd-fixture" "T-U2" "EPIC-POS" "U2" "$DH"
bind_child "$FIXTURE/bd-fixture" "T-U3" "EPIC-POS" "U3" "$DH"

POS_OUT=$(bash "$EG" plan-batches "EPIC-POS")
assert_eq "1.1 positive arm: ok=true" "true" "$(json_field '.ok' "$POS_OUT")"
assert_eq "1.2 positive arm: parallel_safe=true" "true" "$(json_field '.parallel_safe' "$POS_OUT")"
assert_eq "1.3 positive arm: no degradation_reason" "" "$(json_field '.degradation_reason' "$POS_OUT")"
# shellcheck disable=SC2016
U1_BATCH=$(json_field '[.batches[] | . as $b | select(any($b[]; .unit_id=="U1")) ] | length > 0' "$POS_OUT")
U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$POS_OUT")
U2_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U2")] | index(true)' "$POS_OUT")
U3_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U3")] | index(true)' "$POS_OUT")
assert_contains "1.4 U1 placed in some batch" "true" "$U1_BATCH"
if [ "$U1_IDX" = "$U2_IDX" ]; then U1_U2_SAME="same"; else U1_U2_SAME="different"; fi
assert_eq "1.5 U1 and U2 land in DIFFERENT batches" "different" "$U1_U2_SAME"
if [ "$U3_IDX" = "$U1_IDX" ] || [ "$U3_IDX" = "$U2_IDX" ]; then U3_SHARES="true"; else U3_SHARES="false"; fi
assert_eq "1.6 U3 shares a batch with U1 or U2 (a REAL multi-unit batch formed)" "true" "$U3_SHARES"
# R1-F6 (independent review, xsu1): captured so Section 2's reorder check
# can ANCHOR the original composition, not just assert the reordered
# case's own outcome in isolation (which an "always prefer U2" bug would
# also satisfy).
if [ "$U3_IDX" = "$U1_IDX" ]; then POS_U3_PARTNER="U1"; else POS_U3_PARTNER="U2"; fi
BATCH_COUNT=$(json_field '.batches | length' "$POS_OUT")
assert_eq "1.7 exactly 2 batches (not one-per-unit)" "2" "$BATCH_COUNT"
assert_eq "1.8 graph_intersection_computed is false (l7gd deferred) even on a clean plan" \
    "false" "$(json_field '.graph_intersection_computed' "$POS_OUT")"
assert_eq "1.9 graph_degradation_reason names the deferral" \
    "code_graph_absent" "$(json_field '.graph_degradation_reason' "$POS_OUT")"


# ===========================================================================
printf '\n=== Section 2: determinism ===\n'
# ===========================================================================
RUN_A=$(bash "$EG" plan-batches "EPIC-POS")
RUN_B=$(bash "$EG" plan-batches "EPIC-POS")
assert_eq "2.1 two runs over an unchanged artifact are byte-identical" "$RUN_A" "$RUN_B"
MPATH=$(json_field '.manifest_path' "$RUN_A")
assert_eq "2.2 the persisted manifest is byte-identical to stdout" "$RUN_A" "$(cat "$MPATH" 2>/dev/null)"
assert_eq "2.3 no generated_at/timestamp key leaked into the envelope" "false" "$(json_field 'has("generated_at")' "$RUN_A")"

# Same three units, SAME conflict shape, but declared [U2, U1, U3] instead of
# [U1, U2, U3] — proves artifact order (not `unit_files | keys`, which SORTS
# and would read U1 before U2 regardless of declaration order) is genuinely
# what greedy first-fit iterates over.
U1R=$(u U1 "a.sh")
U2R=$(u U2 "a.sh,b.sh")
U3R=$(u U3 "c.sh")
UNITS_REORDERED=$(units_of "$U2R" "$U1R" "$U3R")
DHR=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-REORDER" "$UNITS_REORDERED" "T-U1,T-U2,T-U3")
bind_child "$FIXTURE/bd-fixture" "T-U1" "EPIC-REORDER" "U1" "$DHR"
bind_child "$FIXTURE/bd-fixture" "T-U2" "EPIC-REORDER" "U2" "$DHR"
bind_child "$FIXTURE/bd-fixture" "T-U3" "EPIC-REORDER" "U3" "$DHR"
REORDER_OUT=$(bash "$EG" plan-batches "EPIC-REORDER")
assert_eq "2.4 reordered artifact still parallel_safe=true" "true" "$(json_field '.parallel_safe' "$REORDER_OUT")"
assert_eq "2.5 unit_ids on the envelope reflect the NEW declared order"     "U2,U1,U3" "$(json_field '.unit_ids | join(",")' "$REORDER_OUT")"
# batch composition for U3 flips: with [U1,U2,U3] U3 shares with U1 (Section
# 1); with [U2,U1,U3] U2 is placed first and wins the shared batch with U3.
REORDER_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$REORDER_OUT")
REORDER_U2_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U2")] | index(true)' "$REORDER_OUT")
REORDER_U3_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U3")] | index(true)' "$REORDER_OUT")
if [ "$REORDER_U2_IDX" = "$REORDER_U3_IDX" ]; then REORDER_U2_U3_SAME="same"; else REORDER_U2_U3_SAME="different"; fi
assert_eq "2.6 reordering CHANGES which unit shares a batch with U3 (U2 now, not U1) -- proving artifact order is genuinely read"     "same" "$REORDER_U2_U3_SAME"
# R1-F6 fix: the assertion above alone is satisfiable by an implementation
# that ALWAYS prefers U2 regardless of artifact order (the positive arm
# permits U3-with-EITHER U1-or-U2, so "U3 is with U2" here proves nothing
# on its own). Anchor against Section 1's own recorded composition and
# assert the REORDERED run's U3 partner actually DIFFERS from it -- this
# is what genuinely distinguishes "artifact order is the input" from "U2
# is always preferred".
if [ "$REORDER_U1_IDX" = "$REORDER_U3_IDX" ]; then REORDER_U3_PARTNER="U1"; else REORDER_U3_PARTNER="U2"; fi
assert_contains "2.6b R1-F6: reordering actually CHANGES U3's partner from Section 1's own recorded composition ($POS_U3_PARTNER -> $REORDER_U3_PARTNER), ruling out a fixed U2 preference"     "different" "$([ "$POS_U3_PARTNER" != "$REORDER_U3_PARTNER" ] && echo different || echo same)"
RUN_C=$(bash "$EG" plan-batches "EPIC-REORDER")
assert_eq "2.7 the reordered plan is ALSO deterministic across repeat runs" "$REORDER_OUT" "$RUN_C"


# ===========================================================================
printf '\n=== Section 3: Mutant 1 -- union accumulation ===\n'
# ===========================================================================
# Greedy first-fit is only safe if a candidate is tested against a batch's
# FULL ACCUMULATED file union. Mutate the one line that accumulates it
# (`.files += $ufiles`, a UNION) into an OVERWRITE (`.files = $ufiles`),
# simulating "compare against only the most recently added member".
new_fixture_root "mutant1"
# shellcheck disable=SC2016
M1_OLD_COUNT_BEFORE=$(grep -cF '.batches[$fit].files += $ufiles' "$EG_M")
# shellcheck disable=SC2016
sed -i '' 's/\.batches\[\$fit\]\.files += \$ufiles/.batches[$fit].files = $ufiles/' "$EG_M"
# shellcheck disable=SC2016
M1_OLD_COUNT_AFTER=$(grep -cF '.batches[$fit].files += $ufiles' "$EG_M")
# shellcheck disable=SC2016
M1_NEW_COUNT_AFTER=$(grep -cF '.batches[$fit].files = $ufiles' "$EG_M")
assert_eq "3.1 NON-VACUITY: the union-accumulation line existed exactly once before mutation" "1" "$M1_OLD_COUNT_BEFORE"
assert_eq "3.2 NON-VACUITY: the union form is GONE from the mutant" "0" "$M1_OLD_COUNT_AFTER"
assert_eq "3.3 NON-VACUITY: the mutant now contains the overwrite instead" "1" "$M1_NEW_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "3.4 NON-VACUITY: the mutant still parses" "0" "$?"

# U1=[a], U2=[b] (disjoint from U1, so U1+U2 share a batch), U3=[a] (conflicts
# with U1's 'a' but NOT with U2's 'b' -- the discriminating shape: only a
# check against the FULL union, not just U2 the most-recent member, catches
# the U1 conflict).
M1U1=$(u U1 "a.sh")
M1U2=$(u U2 "b.sh")
M1U3=$(u U3 "a.sh")
M1UNITS=$(units_of "$M1U1" "$M1U2" "$M1U3")
M1DH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-M1" "$M1UNITS" "T-U1,T-U2,T-U3")
bind_child "$BDFIX" "T-U1" "EPIC-M1" "U1" "$M1DH"
bind_child "$BDFIX" "T-U2" "EPIC-M1" "U2" "$M1DH"
bind_child "$BDFIX" "T-U3" "EPIC-M1" "U3" "$M1DH"

M1_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-M1")
M1_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$M1_MUTANT_OUT")
M1_U3_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U3")] | index(true)' "$M1_MUTANT_OUT")
if [ "$M1_U1_IDX" = "$M1_U3_IDX" ]; then M1_SAME="same"; else M1_SAME="different"; fi
assert_eq "3.5 SPECIFIC MISBEHAVIOUR: mutant places U1 and U3 in the SAME batch (conflict missed -- Mutant-1's target defect)" \
    "same" "$M1_SAME"
assert_eq "3.6 SPECIFIC MISBEHAVIOUR: mutant reports parallel_safe=true over a real file conflict" \
    "true" "$(json_field '.parallel_safe' "$M1_MUTANT_OUT")"

# RESTORE CONTROL: the SHIPPED (unmutated) script, run over the IDENTICAL
# fixture data (same bd-fixture dir, same artifact), must keep U1/U3 apart.
M1_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-M1")
M1C_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$M1_CONTROL_OUT")
M1C_U3_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U3")] | index(true)' "$M1_CONTROL_OUT")
if [ "$M1C_U1_IDX" = "$M1C_U3_IDX" ]; then M1C_SAME="same"; else M1C_SAME="different"; fi
assert_eq "3.7 RESTORE CONTROL: the SHIPPED (unmutated) script, run over the identical fixture, keeps U1 and U3 SEPARATE" \
    "different" "$M1C_SAME"
assert_eq "3.8 RESTORE CONTROL: shipped script ALSO reports parallel_safe=true (batching succeeds, just places U3 correctly)" \
    "true" "$(json_field '.parallel_safe' "$M1_CONTROL_OUT")"
assert_eq "3.9 EXECUTION: the control run actually executed the shipped artifact, producing 2 real batches" \
    "true" "$(json_field '(.batches | length) == 2' "$M1_CONTROL_OUT")"


# ===========================================================================
printf '\n=== Section 4: Mutant 2 -- THE META-TEST (docs/plans/v5-design-phase.md:159) ===\n'
# ===========================================================================
# R4-F7 (independent review, xsu1 round 4): the ORIGINAL Section 4 never
# mutated the intersection predicate it is named for -- it replaced the
# batching command's `|| batch_rc=$?` failure handler and killed the whole
# jq reducer via a shim, so it would have passed identically if the
# intersection guard were deleted (non-discriminating for the property it
# names). It is now TWO mutants:
#
#   4A -- THE META-TEST the plan doc pre-specifies verbatim ("stub the
#         intersection check to always return empty -- the batching
#         assertion must fail"): the intersection expression ITSELF (the
#         `select( (batch.files) - ((batch.files) - $ufiles) == [] )`
#         first-fit filter, epic-gate.sh's batching reduce) is mutated to
#         `select( true )` -- always-no-conflict -- and the mutant must
#         CO-BATCH two units that declare the SAME file, failing in the
#         guard's SPECIFIC way while the control keeps them separate.
#   4B -- the original fail-open-on-jq-failure mutant, relabelled
#         honestly: it guards the `|| batch_rc=$?` failure HANDLING at
#         the batching reduce (a real, distinct property -- reintroducing
#         epic-gate.sh:311's fail-open shape at that one site must be
#         caught), not the intersection predicate 4A now covers.
#
# Both mutations need python3 (exact .replace() -- the mutation text
# embeds single AND double quotes, braces and `$`, too awkward to
# hand-escape safely as a sed BRE; design-conform.test.sh's own
# precedent). When python3 is unavailable the section is a RECORDED skip
# (SKIPPED_SECTIONS + a SECTION_SKIP_RE-recognised marker), never a
# silent pass -- the round-4 vacuity sweep's own finding.
if ! command -v python3 >/dev/null 2>&1; then
    printf '  SKIP: Section 4 (Mutants 2a/2b, the intersection META-TEST) needs python3 (not found) -- NOT RUN; its assertions are absent from the totals below\n'
    SKIPPED_SECTIONS=$((SKIPPED_SECTIONS + 1))
else

# --- 4A: mutate the intersection predicate itself --------------------------
new_fixture_root "mutant2a"
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
M2A_TARGET_OLD='| select( ( ($ws.batches[$i].files) - (($ws.batches[$i].files) - $ufiles) ) == [] )'
M2A_TARGET_NEW='| select( true )'
M2A_OLD_COUNT_BEFORE=$(grep -cF "$M2A_TARGET_OLD" "$EG_M")
assert_eq "4A.1 NON-VACUITY: the intersection predicate existed exactly once before mutation" "1" "$M2A_OLD_COUNT_BEFORE"
python3 -c "
import sys
path = sys.argv[1]
old = sys.argv[2]
new = sys.argv[3]
with open(path) as f:
    c = f.read()
assert c.count(old) == 1, f'expected exactly 1, found {c.count(old)}'
c = c.replace(old, new)
with open(path, 'w') as f:
    f.write(c)
" "$EG_M" "$M2A_TARGET_OLD" "$M2A_TARGET_NEW"
M2A_OLD_COUNT_AFTER=$(grep -cF "$M2A_TARGET_OLD" "$EG_M")
M2A_NEW_COUNT_AFTER=$(grep -cF "$M2A_TARGET_NEW" "$EG_M")
assert_eq "4A.2 NON-VACUITY: the intersection predicate is GONE from the mutant" "0" "$M2A_OLD_COUNT_AFTER"
assert_eq "4A.3 NON-VACUITY: the always-no-conflict form landed exactly once" "1" "$M2A_NEW_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "4A.4 NON-VACUITY: the mutant still parses" "0" "$?"

# Two units declaring the SAME file -- the one shape the intersection
# predicate exists to keep apart. No dependency edge, so nothing else
# separates them.
M2AU1=$(u U1 "a.sh")
M2AU2=$(u U2 "a.sh")
M2AUNITS=$(units_of "$M2AU1" "$M2AU2")
M2ADH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-M2A" "$M2AUNITS" "T-U1,T-U2")
bind_child "$BDFIX" "T-U1" "EPIC-M2A" "U1" "$M2ADH"
bind_child "$BDFIX" "T-U2" "EPIC-M2A" "U2" "$M2ADH"

M2A_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-M2A")
M2A_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$M2A_MUTANT_OUT")
M2A_U2_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U2")] | index(true)' "$M2A_MUTANT_OUT")
if [ "$M2A_U1_IDX" = "$M2A_U2_IDX" ]; then M2A_SAME="same"; else M2A_SAME="different"; fi
assert_eq "4A.5 SPECIFIC MISBEHAVIOUR: the no-conflict mutant CO-BATCHES two units declaring the same file (the batching assertion the plan doc says must fail)" \
    "same" "$M2A_SAME"
assert_eq "4A.6 SPECIFIC MISBEHAVIOUR: mutant reports parallel_safe=true over that real conflict" \
    "true" "$(json_field '.parallel_safe' "$M2A_MUTANT_OUT")"
assert_eq "4A.7 SPECIFIC MISBEHAVIOUR: mutant collapses to a single batch (the conflict is invisible)" \
    "1" "$(json_field '.batches | length' "$M2A_MUTANT_OUT")"

M2A_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-M2A")
M2AC_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$M2A_CONTROL_OUT")
M2AC_U2_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U2")] | index(true)' "$M2A_CONTROL_OUT")
if [ "$M2AC_U1_IDX" = "$M2AC_U2_IDX" ]; then M2AC_SAME="same"; else M2AC_SAME="different"; fi
assert_eq "4A.8 RESTORE CONTROL: the SHIPPED script keeps the two units in SEPARATE batches over the identical fixture" \
    "different" "$M2AC_SAME"
assert_eq "4A.9 RESTORE CONTROL: shipped script still reports parallel_safe=true (the conflict is HANDLED by separation, not refused)" \
    "true" "$(json_field '.parallel_safe' "$M2A_CONTROL_OUT")"
assert_eq "4A.10 EXECUTION: the control run actually executed the shipped artifact, producing 2 real batches" \
    "2" "$(json_field '.batches | length' "$M2A_CONTROL_OUT")"

# --- 4B: the original fail-open-on-jq-failure mutant, relabelled -----------
# Reintroduce epic-gate.sh:311's ORIGINAL fail-open shape at the batching
# computation's own checked assignment: on a jq FAILURE, substitute a
# well-shaped, ok:true, fully-merged fallback instead of degrading. A jq
# SHIM forces an ACTUAL failure at exactly that one call (matched on a
# marker string, "stuck: true", unique to the batching reduce's own
# program text -- asserted below, not just claimed: _pb_degrade's own
# schedule program deliberately spells its variant without the space) so
# the mutation is observably REACHED rather than dormant.
new_fixture_root "mutant2b"
M2B_STUCK_COUNT=$(grep -cF 'stuck: true' "$EG")
assert_eq "4B.0 PRECONDITION: the 'stuck: true' shim marker is unique to the batching reduce in the shipped source (a second occurrence would strand the shim at the wrong call)" \
    "1" "$M2B_STUCK_COUNT"
# Round 7 note: the substituted fallback must be MULTISET-CONSISTENT with
# the fixture's resolvable units (R7-F3's gate checks the ok:true member
# multiset against R, and the mutation below replaces only the rc-guard,
# never that gate). Round 8 narrowed the smuggle-space AGAIN: R8-F3 pins
# every member's task_id to unit_task_map, so the forged answer must now
# name the real unit ids AND the real task ids, and the marker's only
# remaining home is an extra member key no gate reads. Each narrowing is
# evidence the gates work: a fail-open path can no longer smuggle an
# arbitrary answer, only a fully map-consistent one -- whose one
# expressible damage over this fixture is co-batching the two REAL
# same-file units, exactly what 4B.6 asserts.
M2B_TARGET_OLD="' 2>/dev/null) || batch_rc=\$?"
M2B_TARGET_NEW="' 2>/dev/null) || batch_result='{\"ok\":true,\"batches\":[[{\"unit_id\":\"U1\",\"task_id\":\"T-U1\",\"mutant\":\"MUTANT-MERGED\"},{\"unit_id\":\"U2\",\"task_id\":\"T-U2\",\"mutant\":\"MUTANT-MERGED\"}]]}'"
M2B_OLD_COUNT_BEFORE=$(grep -cF "$M2B_TARGET_OLD" "$EG_M")
assert_eq "4B.1 NON-VACUITY: the fail-closed batch_rc assignment existed exactly once before mutation" "1" "$M2B_OLD_COUNT_BEFORE"
python3 -c "
import sys
path = sys.argv[1]
old = sys.argv[2]
new = sys.argv[3]
with open(path) as f:
    c = f.read()
assert c.count(old) == 1, f'expected exactly 1, found {c.count(old)}'
c = c.replace(old, new)
with open(path, 'w') as f:
    f.write(c)
" "$EG_M" "$M2B_TARGET_OLD" "$M2B_TARGET_NEW"
M2B_OLD_COUNT_AFTER=$(grep -cF "$M2B_TARGET_OLD" "$EG_M")
M2B_NEW_COUNT_AFTER=$(grep -cF "MUTANT-MERGED" "$EG_M")
assert_eq "4B.2 NON-VACUITY: the fail-closed form is GONE from the mutant" "0" "$M2B_OLD_COUNT_AFTER"
assert_eq "4B.3 NON-VACUITY: the mutant's fail-OPEN fallback landed (MUTANT-MERGED marker present)" "1" "$M2B_NEW_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "4B.4 NON-VACUITY: the mutant still parses" "0" "$?"

# The jq SHIM: fails ONLY the batching reduce's own jq invocation (matched
# on "stuck: true", 4B.0's asserted-unique marker), delegating every other
# call to the real jq unchanged -- so every OTHER computation in
# cmd_plan_batches (design-status, validate-design, the per-child loop,
# and _pb_degrade's own schedule construction) keeps working normally, and
# only the ONE targeted call sees a failure.
mkdir -p "$FIXTURE/m2b-stuck-shim-bin"
cat > "$FIXTURE/m2b-stuck-shim-bin/jq" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        *'stuck: true'*) exit 1 ;;
    esac
done
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/m2b-stuck-shim-bin/jq"

M2BU1=$(u U1 "a.sh")
M2BU2=$(u U2 "a.sh")
M2BUNITS=$(units_of "$M2BU1" "$M2BU2")
M2BDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-M2B" "$M2BUNITS" "T-U1,T-U2")
bind_child "$BDFIX" "T-U1" "EPIC-M2B" "U1" "$M2BDH"
bind_child "$BDFIX" "T-U2" "EPIC-M2B" "U2" "$M2BDH"

M2B_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" PATH="$FIXTURE/m2b-stuck-shim-bin:$PATH" bash "$EG_M" plan-batches "EPIC-M2B")
assert_eq "4B.5 SPECIFIC MISBEHAVIOUR: mutant + induced failure -> parallel_safe=TRUE (the danger: a crash reads as fully parallel)" \
    "true" "$(json_field '.parallel_safe' "$M2B_MUTANT_OUT")"
assert_eq "4B.6 SPECIFIC MISBEHAVIOUR: mutant's batches carry the fallback's marker (an extra member key -- rounds 7-8 pinned unit_id AND task_id to the real map, so a forgery has nowhere else to sign itself) AND co-batch the two same-file units in one 2-member batch, proving the FAIL-OPEN PATH produced this answer" \
    "MUTANT-MERGED|2" "$(json_field '.batches[0][0].mutant' "$M2B_MUTANT_OUT")|$(json_field '.batches[0] | length' "$M2B_MUTANT_OUT")"

M2B_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" PATH="$FIXTURE/m2b-stuck-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-M2B")
assert_eq "4B.7 RESTORE CONTROL: SHIPPED script + the SAME induced failure -> parallel_safe=false (fail-closed, as designed)" \
    "false" "$(json_field '.parallel_safe' "$M2B_CONTROL_OUT")"
assert_eq "4B.8 RESTORE CONTROL: shipped script names the failure explicitly (set_computation_failed), naming the check that would have gone wrong" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$M2B_CONTROL_OUT")"
assert_eq "4B.9 EXECUTION: the control run actually executed the shipped artifact end to end (a real epic_id echoed back)" \
    "EPIC-M2B" "$(json_field '.epic_id' "$M2B_CONTROL_OUT")"
# The shipped script's degraded envelope still carries the full serial
# schedule here -- the induced failure hit the batching reduce, not
# _pb_degrade's own schedule construction (whose program deliberately
# avoids the marker), so the R4-F5 refusal does not fire on this leg.
assert_eq "4B.10 RESTORE CONTROL: the degraded envelope still carries the serial one-per-batch schedule (the induced failure did not reach the degrade path's own schedule)" \
    "2" "$(json_field '.batches | length' "$M2B_CONTROL_OUT")"

# Sanity: WITHOUT the induced failure, the mutant behaves identically to
# shipped (the fail-open `||` branch is dormant when the underlying call
# succeeds) -- confirms the defect is specifically about FAILURE HANDLING.
M2B_MUTANT_NOSHIM_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-M2B")
assert_eq "4B.11 without an induced failure, the mutant's \`||\` branch is dormant and it matches shipped behaviour" \
    "true" "$(json_field '.parallel_safe' "$M2B_MUTANT_NOSHIM_OUT")"
fi

# ===========================================================================
printf '\n=== Section 5: Mutant 3 -- the child-binding guard sentinel ===\n'
# ===========================================================================
# Strip # PLAN-BATCHES-CHILD-BINDING-GATE BEGIN/END. This is the ONE guard
# with no redundant downstream backup (verified during this file's own
# development: the design-status/validate-design/TOCTOU checks are each
# independently fail-closed against a DIFFERENT structural failure, so
# stripping any ONE of those still degrades via another; stripping the
# WHOLE outer PLAN-BATCHES-NO-DESIGN-GUARD region breaks the function's own
# brace matching and does not even parse). An unbound child is simply never
# added to unit_task_map either way -- without this check, that omission
# never trips a degrade, and the OTHER, cleanly-bound children batch
# together as if the unconstrained writer did not exist.
new_fixture_root "mutant3"
awk '
  /# PLAN-BATCHES-CHILD-BINDING-GATE BEGIN/ { found_begin=1 }
  /# PLAN-BATCHES-CHILD-BINDING-GATE END/   { found_end=1; skip=0; next }
  /# PLAN-BATCHES-CHILD-BINDING-GATE BEGIN/ { skip=1 }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
M3_AWK_RC=$?
assert_eq "5.1 NON-VACUITY: the awk strip found BOTH sentinels (exit 7 would mean it did not)" "0" "$M3_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
grep -qE "# PLAN-BATCHES-CHILD-BINDING-GATE (BEGIN|END)" "$EG_M"
assert_eq "5.2 NON-VACUITY: the sentinel markers THEMSELVES (not just the header's prose mention of the name) are gone from the mutant" "1" "$?"
bash -n "$EG_M"
assert_eq "5.3 NON-VACUITY: the mutant still parses" "0" "$?"
M3_LINES_SHIPPED=$(wc -l < "$EG")
M3_LINES_MUTANT=$(wc -l < "$EG_M")
if [ "$M3_LINES_MUTANT" -lt "$M3_LINES_SHIPPED" ]; then M3_SHRUNK="true"; else M3_SHRUNK="false"; fi
assert_eq "5.4 NON-VACUITY: the mutant is measurably smaller than the shipped script (the strip removed real content)" \
    "true" "$M3_SHRUNK"

# Satisfied, valid, single-unit design; the ONE child is left UNBOUND
# (guard 9's own scenario).
M3U1=$(u U1 "a.sh")
M3UNITS=$(units_of "$M3U1")
# Design is satisfied (seed_epic's job); the hash itself is not needed by
# this scenario, since the one child is left deliberately unbound below.
seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-M3" "$M3UNITS" "T-U1" >/dev/null
unbound_child "$BDFIX" "T-U1"

M3_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-M3")
assert_eq "5.5 SPECIFIC MISBEHAVIOUR: mutant emits parallel_safe=TRUE on an epic whose only child is unbound" \
    "true" "$(json_field '.parallel_safe' "$M3_MUTANT_OUT")"
assert_eq "5.6 SPECIFIC MISBEHAVIOUR: the unconstrained child is invisible -- no batches at all reference it" \
    "0" "$(json_field '[.batches[][] | select(.task_id=="T-U1")] | length' "$M3_MUTANT_OUT")"

M3_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-M3")
assert_eq "5.7 RESTORE CONTROL: the SHIPPED script correctly degrades on the identical fixture" \
    "false" "$(json_field '.parallel_safe' "$M3_CONTROL_OUT")"
assert_eq "5.8 RESTORE CONTROL: shipped script names the reason (design_unit_binding_missing)" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$M3_CONTROL_OUT")"
assert_eq "5.9 EXECUTION: the control run actually executed the shipped artifact (a real epic_id echoed back)" \
    "EPIC-M3" "$(json_field '.epic_id' "$M3_CONTROL_OUT")"


# ===========================================================================
printf '\n=== Section 6: Mutant 4 -- jq absence ===\n'
# ===========================================================================
# A curated PATH carrying everything epic-gate.sh needs EXCEPT jq (grep,
# awk, sed, bash itself, coreutils) -- confirms the hand-built literal at
# the top of cmd_plan_batches is reached and well-formed, not that the
# whole process merely fails to start.
NOJQ_BIN="$FIXTURE/nojq-bin"
mkdir -p "$NOJQ_BIN"
for tool in bash sh grep awk sed cat tr head tail cut date mktemp wc printf basename dirname env true false rm mkdir ls; do
    for cand in "/usr/bin/$tool" "/bin/$tool"; do
        if [ -x "$cand" ]; then
            ln -sf "$cand" "$NOJQ_BIN/$tool"
            break
        fi
    done
done
NOJQ_OUT=$(env -i PATH="$NOJQ_BIN" HOME="$HOME" "$NOJQ_BIN/bash" "$EG" plan-batches "any-epic" 2>&1)
NOJQ_RC=$?
# R1-F7 (independent review, xsu1): jq_unavailable is guard condition 1 of
# the NO-DESIGN-GUARD ladder and every member of that ladder exits 0 --
# the OLD exit-2 expectation here PINNED the exact contract violation the
# review found (a well-formed envelope printed, then a nonzero exit, which
# the house `$(cmd || echo '{}')` idiom concatenates with a second `{}`).
assert_eq "6.1 jq-absent: exits 0 (guard-list contract, not an infra-failure exit)" "0" "$NOJQ_RC"
assert_eq "6.2 jq-absent: stdout is well-formed JSON (re-parsed with the REAL jq)" \
    "true" "$(printf '%s' "$NOJQ_OUT" | "$REAL_JQ" -e 'type=="object"' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "6.3 jq-absent: parallel_safe is explicitly false, not merely absent" \
    "false" "$(printf '%s' "$NOJQ_OUT" | "$REAL_JQ" -r '.parallel_safe' 2>/dev/null)"
assert_eq "6.4 jq-absent: degradation_reason names it" \
    "jq_unavailable" "$(printf '%s' "$NOJQ_OUT" | "$REAL_JQ" -r '.degradation_reason' 2>/dev/null)"
assert_eq "6.5 jq-absent: batches is an empty array, never omitted" \
    "[]" "$(printf '%s' "$NOJQ_OUT" | "$REAL_JQ" -c '.batches' 2>/dev/null)"
assert_eq "6.6 jq-absent: stdout is genuinely non-empty (the hazard this guards: set -e death produces EMPTY stdout)" \
    "true" "$([ -n "$NOJQ_OUT" ] && echo true || echo false)"

# ===========================================================================
printf '\n=== Section 7: Mutant 5 -- dependency order ===\n'
# ===========================================================================
# Two units, DISJOINT files, U2 depends_on U1. File-set intersection alone
# would happily co-batch them; only consulting unit_deps prevents it.
new_fixture_root "mutant5"
if ! command -v python3 >/dev/null 2>&1; then
    # R4 vacuity sweep: a RECORDED skip (counter + SECTION_SKIP_RE-shaped
    # marker), never a silent pass over an absent mutation tool.
    printf '  SKIP: Section 7 (Mutant 5, dependency order) needs python3 (not found) -- NOT RUN; its assertions are absent from the totals below\n'
    SKIPPED_SECTIONS=$((SKIPPED_SECTIONS + 1))
else
# shellcheck disable=SC2016
M5_TARGET_OLD='( [ ($ud[$u] // [])[] | ($ws.placed[.]) ] ) as $dep_batches'
# shellcheck disable=SC2016
M5_TARGET_NEW='( [] ) as $dep_batches'
M5_OLD_COUNT_BEFORE=$(grep -cF "$M5_TARGET_OLD" "$EG_M")
assert_eq "7.1 NON-VACUITY: the dependency-consulting line existed exactly once before mutation" "1" "$M5_OLD_COUNT_BEFORE"
python3 -c "
import sys
path = sys.argv[1]
old = sys.argv[2]
new = sys.argv[3]
with open(path) as f:
    c = f.read()
assert c.count(old) == 1, f'expected exactly 1, found {c.count(old)}'
c = c.replace(old, new)
with open(path, 'w') as f:
    f.write(c)
" "$EG_M" "$M5_TARGET_OLD" "$M5_TARGET_NEW"
M5_OLD_COUNT_AFTER=$(grep -cF "$M5_TARGET_OLD" "$EG_M")
assert_eq "7.2 NON-VACUITY: the dependency-consulting form is GONE from the mutant" "0" "$M5_OLD_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "7.3 NON-VACUITY: the mutant still parses" "0" "$?"

M5U1=$(u U1 "a.sh")
M5U2=$(u U2 "b.sh" "U1")
M5UNITS=$(units_of "$M5U1" "$M5U2")
M5DH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-M5" "$M5UNITS" "T-U1,T-U2")
bind_child "$BDFIX" "T-U1" "EPIC-M5" "U1" "$M5DH"
bind_child "$BDFIX" "T-U2" "EPIC-M5" "U2" "$M5DH"

M5_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-M5")
M5_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$M5_MUTANT_OUT")
M5_U2_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U2")] | index(true)' "$M5_MUTANT_OUT")
if [ "$M5_U1_IDX" = "$M5_U2_IDX" ]; then M5_SAME="same"; else M5_SAME="different"; fi
assert_eq "7.4 SPECIFIC MISBEHAVIOUR: mutant co-batches U1 and U2 despite the dependency (disjoint files, no order enforced)" \
    "same" "$M5_SAME"
assert_eq "7.5 SPECIFIC MISBEHAVIOUR: mutant reports parallel_safe=true" \
    "true" "$(json_field '.parallel_safe' "$M5_MUTANT_OUT")"

M5_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-M5")
M5C_U1_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U1")] | index(true)' "$M5_CONTROL_OUT")
M5C_U2_IDX=$(json_field '[.batches[] | any(.[]; .unit_id=="U2")] | index(true)' "$M5_CONTROL_OUT")
assert_eq "7.6 RESTORE CONTROL: shipped script places U1 STRICTLY before U2 (different, ordered batches)" \
    "true" "$([ "$M5C_U1_IDX" -lt "$M5C_U2_IDX" ] 2>/dev/null && echo true || echo false)"
assert_eq "7.7 RESTORE CONTROL: shipped script ALSO reports parallel_safe=true (ordering respected, not merely refused)" \
    "true" "$(json_field '.parallel_safe' "$M5_CONTROL_OUT")"
assert_eq "7.8 EXECUTION: the control run actually executed the shipped artifact (2 distinct batches)" \
    "2" "$(json_field '.batches | length' "$M5_CONTROL_OUT")"
fi


# ===========================================================================
printf '\n=== Section 8: additional guard-list probes (run directly against the SHIPPED script) ===\n'
# ===========================================================================
# R4-F6: the banner's claim is now mechanically true — every probe below
# runs $EG (the canonical artifact, pinned by assertion 0.1). The
# new_fixture_root calls remain purely for ISOLATION (each probe gets its
# own bd-fixture/ and docs/specs/, resolved via CLAUDE_PROJECT_DIR); their
# epic-gate.sh copies are never executed here.

# --- 8a: guard 4, no_design_attempted -- propagated WITHOUT design-gate-
# precheck's own leniency (an epic with real children but NO design record
# at all must degrade, not read as "ready"). ------------------------------
new_fixture_root "g4"
G4_EPIC="EPIC-G4"
bd_fixture_write "$BDFIX" "$G4_EPIC" '[{"id":"T-G4","dependency_type":"parent-child"}]' '[]'
bd_fixture_write "$BDFIX" "T-G4" '[]' '[]'
G4_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "$G4_EPIC")
assert_eq "8a.1 guard 4: no design at all -> parallel_safe=false" "false" "$(json_field '.parallel_safe' "$G4_OUT")"
assert_eq "8a.2 guard 4: reason is no_design_attempted VERBATIM (not laundered to 'ready')" \
    "no_design_attempted" "$(json_field '.degradation_reason' "$G4_OUT")"

# --- 8b: guard 6, epic_has_no_children (a REAL, readable epic; zero
# dependents). -------------------------------------------------------------
new_fixture_root "g6"
G6_EPIC="EPIC-G6"
bd_fixture_write "$BDFIX" "$G6_EPIC" '[]' '[]'
G6_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "$G6_EPIC")
assert_eq "8b.1 guard 6: zero children -> parallel_safe=false" "false" "$(json_field '.parallel_safe' "$G6_OUT")"
assert_eq "8b.2 guard 6: reason is epic_has_no_children (NOT cmd_check's own vacuous pass)" \
    "epic_has_no_children" "$(json_field '.degradation_reason' "$G6_OUT")"
assert_eq "8b.3 guard 6: batches is empty, not a fabricated pass" "[]" "$(json_field '.batches' "$G6_OUT")"

# --- 8c: guard 10, unit_not_in_design (bound to a unit an amendment
# dropped -- the artifact no longer declares it). --------------------------
new_fixture_root "g10"
G10U1=$(u U1 "a.sh")
G10UNITS=$(units_of "$G10U1")
G10DH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-G10" "$G10UNITS" "T-G10")
bind_child "$BDFIX" "T-G10" "EPIC-G10" "U2-GHOST" "$G10DH"
G10_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-G10")
assert_eq "8c.1 guard 10: bound to a unit_id absent from the CURRENT artifact -> parallel_safe=false" \
    "false" "$(json_field '.parallel_safe' "$G10_OUT")"
assert_eq "8c.2 guard 10: reason is unit_not_in_design" \
    "unit_not_in_design" "$(json_field '.degradation_reason' "$G10_OUT")"

# --- 8d: guard 11, binding_design_hash_stale (a real unit_id, but the
# binding's own design_hash does not match the current governing hash --
# simulating a binding recorded against an artifact amended since). -------
new_fixture_root "g11"
G11U1=$(u U1 "a.sh")
G11UNITS=$(units_of "$G11U1")
# The REAL hash is discarded on purpose: bind_child below is given a
# deliberately WRONG one, to simulate a binding gone stale.
seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-G11" "$G11UNITS" "T-G11" >/dev/null
bind_child "$BDFIX" "T-G11" "EPIC-G11" "U1" "0000000000000000000000000000000000000000000000000000000000000000"
G11_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-G11")
assert_eq "8d.1 guard 11: stale binding design_hash -> parallel_safe=false" \
    "false" "$(json_field '.parallel_safe' "$G11_OUT")"
assert_eq "8d.2 guard 11: reason is binding_design_hash_stale" \
    "binding_design_hash_stale" "$(json_field '.degradation_reason' "$G11_OUT")"

# --- 8e: guard 12, unit_bound_to_multiple_tasks. --------------------------
new_fixture_root "g12"
G12U1=$(u U1 "a.sh")
G12UNITS=$(units_of "$G12U1")
G12DH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-G12" "$G12UNITS" "T-G12A,T-G12B")
bind_child "$BDFIX" "T-G12A" "EPIC-G12" "U1" "$G12DH"
bind_child "$BDFIX" "T-G12B" "EPIC-G12" "U1" "$G12DH"
G12_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-G12")
assert_eq "8e.1 guard 12: two tasks bound to the same unit -> parallel_safe=false" \
    "false" "$(json_field '.parallel_safe' "$G12_OUT")"
assert_eq "8e.2 guard 12: reason is unit_bound_to_multiple_tasks" \
    "unit_bound_to_multiple_tasks" "$(json_field '.degradation_reason' "$G12_OUT")"
assert_contains "8e.3 guard 12: observations name BOTH conflicting task ids" "T-G12A" "$(json_field '.observations' "$G12_OUT")"
assert_contains "8e.4 guard 12: observations name BOTH conflicting task ids" "T-G12B" "$(json_field '.observations' "$G12_OUT")"

# --- 8f: guard 13, declared_paths_not_canonical. --------------------------
new_fixture_root "g13"
G13U1=$(u U1 "../escape.sh")
G13UNITS=$(units_of "$G13U1")
G13DH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-G13" "$G13UNITS" "T-G13")
bind_child "$BDFIX" "T-G13" "EPIC-G13" "U1" "$G13DH"
G13_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-G13")
assert_eq "8f.1 guard 13: a ../ path segment -> parallel_safe=false" \
    "false" "$(json_field '.parallel_safe' "$G13_OUT")"
assert_eq "8f.2 guard 13: reason is declared_paths_not_canonical" \
    "declared_paths_not_canonical" "$(json_field '.degradation_reason' "$G13_OUT")"

# --- 8g: --design assertion, both directions (D1 convention: assertion,
# never a source). ---------------------------------------------------------
new_fixture_root "g8g"
G8GU1=$(u U1 "a.sh")
G8GUNITS=$(units_of "$G8GU1")
G8GDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-G8G" "$G8GUNITS" "T-G8G")
bind_child "$BDFIX" "T-G8G" "EPIC-G8G" "U1" "$G8GDH"
G8G_RIGHT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-G8G" --design "$ROOT/docs/specs/EPIC-G8G.md")
assert_eq "8g.1 --design matching the derived path is accepted (still clean)" \
    "true" "$(json_field '.parallel_safe' "$G8G_RIGHT")"
G8G_WRONG=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-G8G" --design "/tmp/not-the-real-one.md")
assert_eq "8g.2 --design disagreeing with the derived path degrades" \
    "false" "$(json_field '.parallel_safe' "$G8G_WRONG")"
assert_eq "8g.3 --design mismatch names the reason" \
    "artifact_path_not_derived" "$(json_field '.degradation_reason' "$G8G_WRONG")"

# ===========================================================================
printf '\n=== Section 9: independent review findings (xsu1-r1) ===\n'
# ===========================================================================

# --- 9a: R1-F1 -- a resolvable unit depending on an UNRESOLVED one must
# degrade the whole plan, not silently drop the edge. -----------------------
R9AU1=$(u U1 "a.sh")
R9AU2=$(u U2 "b.sh" "U1")
R9AUNITS=$(units_of "$R9AU1" "$R9AU2")
R9ADH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9A" "$R9AUNITS" "T-R9A-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9A-U2" "EPIC-R9A" "U2" "$R9ADH"
R9A_OUT=$(bash "$EG" plan-batches "EPIC-R9A")
assert_eq "9a.1 R1-F1: U2 depends_on U1, only U2 has an implementing child -> parallel_safe=false" \
    "false" "$(json_field '.parallel_safe' "$R9A_OUT")"
assert_eq "9a.2 R1-F1: reason names the unresolved dependency, not a silent drop" \
    "unit_depends_on_unresolved_unit" "$(json_field '.degradation_reason' "$R9A_OUT")"
assert_contains "9a.3 R1-F1: observations name the specific blocking pair" "U2 -> U1" "$(json_field '.observations' "$R9A_OUT")"

# --- 9b: R1-F3 -- two declared paths colliding only in case must degrade,
# even though case is (correctly) never folded. -----------------------------
R9BU1=$(u U1 "src/A.js")
R9BU2=$(u U2 "src/a.js")
R9BUNITS=$(units_of "$R9BU1" "$R9BU2")
R9BDH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9B" "$R9BUNITS" "T-R9B-U1,T-R9B-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9B-U1" "EPIC-R9B" "U1" "$R9BDH"
bind_child "$FIXTURE/bd-fixture" "T-R9B-U2" "EPIC-R9B" "U2" "$R9BDH"
R9B_OUT=$(bash "$EG" plan-batches "EPIC-R9B")
assert_eq "9b.1 R1-F3: src/A.js vs src/a.js -> parallel_safe=false" "false" "$(json_field '.parallel_safe' "$R9B_OUT")"
assert_eq "9b.2 R1-F3: reason names the case collision specifically" \
    "declared_paths_case_collision" "$(json_field '.degradation_reason' "$R9B_OUT")"
# Sanity: a genuine, non-colliding pair must still pass clean (case is not
# folded generally -- only a real collision degrades).
R9BSANEU1=$(u U1 "src/A.js")
R9BSANEU2=$(u U2 "src/b.js")
R9BSANEUNITS=$(units_of "$R9BSANEU1" "$R9BSANEU2")
R9BSANEDH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9BSANE" "$R9BSANEUNITS" "T-R9BS-U1,T-R9BS-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9BS-U1" "EPIC-R9BSANE" "U1" "$R9BSANEDH"
bind_child "$FIXTURE/bd-fixture" "T-R9BS-U2" "EPIC-R9BSANE" "U2" "$R9BSANEDH"
R9BSANE_OUT=$(bash "$EG" plan-batches "EPIC-R9BSANE")
assert_eq "9b.3 sanity: src/A.js vs src/b.js (no collision) stays parallel_safe=true" \
    "true" "$(json_field '.parallel_safe' "$R9BSANE_OUT")"

# --- 9c: R1-F4 -- unit_task_map key order must be ARTIFACT order, never
# bd's own child-enumeration order. ------------------------------------------
R9CU1=$(u U1 "x.sh")
R9CU2=$(u U2 "y.sh")
R9CUNITS=$(units_of "$R9CU1" "$R9CU2")
R9CADH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9CA" "$R9CUNITS" "T-R9C-A1,T-R9C-A2")
bind_child "$FIXTURE/bd-fixture" "T-R9C-A1" "EPIC-R9CA" "U1" "$R9CADH"
bind_child "$FIXTURE/bd-fixture" "T-R9C-A2" "EPIC-R9CA" "U2" "$R9CADH"
R9CA_OUT=$(bash "$EG" plan-batches "EPIC-R9CA")
R9CA_KEYS=$(json_field '.unit_task_map | keys_unsorted | join(",")' "$R9CA_OUT")

# SAME units, SAME two bindings, but the epic's children are enumerated in
# the OPPOSITE order (U2's task listed/bound before U1's).
R9CBDH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9CB" "$R9CUNITS" "T-R9C-B2,T-R9C-B1")
bind_child "$FIXTURE/bd-fixture" "T-R9C-B2" "EPIC-R9CB" "U2" "$R9CBDH"
bind_child "$FIXTURE/bd-fixture" "T-R9C-B1" "EPIC-R9CB" "U1" "$R9CBDH"
R9CB_OUT=$(bash "$EG" plan-batches "EPIC-R9CB")
R9CB_KEYS=$(json_field '.unit_task_map | keys_unsorted | join(",")' "$R9CB_OUT")

assert_eq "9c.1 R1-F4: unit_task_map key order is artifact order (U1,U2)" "U1,U2" "$R9CA_KEYS"
assert_eq "9c.2 R1-F4: ...unchanged even when children were enumerated/bound in the OPPOSITE order" "U1,U2" "$R9CB_KEYS"

# --- 9d: R1-F2 widened -- Mutant 2 (Section 4) only forces a failure at
# the main batching reduce. Three MORE sites got the identical fail-open-
# then-fixed treatment (unit_task_map_json, the .ud_r extraction, the
# .batches extraction); each is independently verified fail-closed here
# under an ACTUAL induced failure, not just code review.
#
# R2-F2 (independent review, xsu1 round 2): the FIRST version of this
# section used SUBSTRING matching for every marker, and two of the three
# (.ud_r, .batches) matched an EARLIER call than the one named -- the
# combined shape check just above each extraction embeds the identical
# bare token (".ud_r"/".batches" both appear 2+ and 11+ times respectively
# across the file; confirmed with grep -c below), so the shim tripped
# there first and the test was vacuous for the two sites it most needed to
# prove. THIS is the third instance of a fault-injection marker landing on
# an earlier site than the one it names (claude-workflow-plugin-fkm.6's
# R2-F4 was the first two) -- the fix is the SAME one used there: an
# EXACT-match shim (PB_FAIL_MARKER, whole-argument equality, structurally
# immune to matching a LONGER string that merely contains it) for the two
# short, standalone-argument sites, plus an explicit static uniqueness
# PRECONDITION (not just a claim) for the one site that still needs
# substring matching because its own call passes a long multi-line
# program, never equal to any short marker. Every assertion below ALSO
# checks the SPECIFIC observations text names the INTENDED checkpoint,
# not an earlier one -- the direct, no-isolated-rerun-needed way to prove
# a marker did not strand.
PB_UDR_OCCURRENCES=$(grep -c '\.ud_r' "$EG")
PB_BATCHES_OCCURRENCES=$(grep -c '\.batches' "$EG")
assert_contains "9d.0a PRECONDITION: '.ud_r' is NOT unique in the source (proves substring matching would strand -- exact matching is required)" \
    "true" "$([ "$PB_UDR_OCCURRENCES" -gt 1 ] && echo true || echo false)"
assert_contains "9d.0b PRECONDITION: '.batches' is NOT unique either (same reason)" \
    "true" "$([ "$PB_BATCHES_OCCURRENCES" -gt 1 ] && echo true || echo false)"
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
PB_UTM_MARKER='select( ($m[.] // null) != null ) | {key: ., value: $m[.]}'
PB_UTM_OCCURRENCES=$(grep -cF "$PB_UTM_MARKER" "$EG")
assert_eq "9d.0c PRECONDITION: the unit_task_map_json marker phrase IS unique in the source (substring matching is safe for it)" \
    "1" "$PB_UTM_OCCURRENCES"

mkdir -p "$FIXTURE/m2b-shim-bin"
cat > "$FIXTURE/m2b-shim-bin/jq" <<SHIMEOF
#!/bin/bash
# PB_FAIL_MARKER: WHOLE-ARGUMENT exact match only -- cannot match a longer
# string that merely contains it, so a short marker used here can never
# strand at a call whose own argument is a longer embedding program.
# PB_FAIL_SUBSTRING: substring match, for a marker independently proven
# unique in the source (9d.0c) -- safe because nothing else can contain it.
for a in "\$@"; do
    if [ -n "\$PB_FAIL_MARKER" ] && [ "\$a" = "\$PB_FAIL_MARKER" ]; then
        exit 1
    fi
    if [ -n "\$PB_FAIL_SUBSTRING" ]; then
        case "\$a" in
            *"\$PB_FAIL_SUBSTRING"*) exit 1 ;;
        esac
    fi
done
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/m2b-shim-bin/jq"

R9DU1=$(u U1 "a.sh")
R9DU2=$(u U2 "b.sh")
R9DUNITS=$(units_of "$R9DU1" "$R9DU2")
R9DDH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9D" "$R9DUNITS" "T-R9D-U1,T-R9D-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9D-U1" "EPIC-R9D" "U1" "$R9DDH"
bind_child "$FIXTURE/bd-fixture" "T-R9D-U2" "EPIC-R9D" "U2" "$R9DDH"

R9D_UTM_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" BD_FIXTURE_DIR="$FIXTURE/bd-fixture" PB_FAIL_SUBSTRING="$PB_UTM_MARKER" PATH="$FIXTURE/m2b-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9D")
assert_eq "9d.1 R1-F2 widened: unit_task_map_json construction fail-closed under an induced jq failure" \
    "false" "$(json_field '.parallel_safe' "$R9D_UTM_OUT")"
assert_eq "9d.2 ...names set_computation_failed, not a silent empty map" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9D_UTM_OUT")"
assert_contains "9d.2b NOT STRANDED: observations name the unit-to-task map checkpoint specifically" \
    "could not build the unit-to-task map" "$(json_field '.observations' "$R9D_UTM_OUT")"

R9D_UDR_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" BD_FIXTURE_DIR="$FIXTURE/bd-fixture" PB_FAIL_MARKER='.ud_r' PATH="$FIXTURE/m2b-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9D")
assert_eq "9d.3 R1-F2 widened: the .ud_r extraction (the review's 'most sharply' example) fail-closed" \
    "false" "$(json_field '.parallel_safe' "$R9D_UDR_OUT")"
assert_eq "9d.4 ...names set_computation_failed, not a silent {} erasing every dependency" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9D_UDR_OUT")"
assert_contains "9d.4b NOT STRANDED: observations name the resolvable-set EXTRACTION checkpoint, not the earlier derive-R shape check" \
    "could not extract the already-validated resolvable-set fields" "$(json_field '.observations' "$R9D_UDR_OUT")"

R9D_BATCHES_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" BD_FIXTURE_DIR="$FIXTURE/bd-fixture" PB_FAIL_MARKER='.batches' PATH="$FIXTURE/m2b-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9D")
assert_eq "9d.5 R1-F2 widened: the final .batches extraction fail-closed" \
    "false" "$(json_field '.parallel_safe' "$R9D_BATCHES_OUT")"
assert_eq "9d.6 ...names set_computation_failed, not a silent empty batches array" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9D_BATCHES_OUT")"
assert_contains "9d.6b NOT STRANDED: observations name the final batches-array EXTRACTION checkpoint, not the earlier batch-result shape check" \
    "could not extract the already-validated batches array" "$(json_field '.observations' "$R9D_BATCHES_OUT")"

# Sanity: the SAME fixture, unshimmed, still computes a real plan -- proves
# the shim (with neither env var set) is not itself the reason for a degrade.
R9D_CLEAN_OUT=$(bash "$EG" plan-batches "EPIC-R9D")
assert_eq "9d.7 sanity: the identical fixture with NO induced failure is parallel_safe=true" \
    "true" "$(json_field '.parallel_safe' "$R9D_CLEAN_OUT")"

# --- 9e: R1-F5 -- a new mutant for the multiply-bound sentinel
# (PLAN-BATCHES-MULTIBIND-GATE), the case the review used to illustrate
# that other guards share guard 9-11's "no redundant backup" property. ------
new_fixture_root "mutant9e"
# shellcheck disable=SC2016
R9E_OLD='if [ "$distinct_bound_units" -ne "${#bound_units[@]}" ]; then'
R9E_COUNT_BEFORE=$(grep -cF "$R9E_OLD" "$EG_M")
assert_eq "9e.1 NON-VACUITY: the multiply-bound decision existed exactly once before mutation" "1" "$R9E_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-MULTIBIND-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-MULTIBIND-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9E_AWK_RC=$?
assert_eq "9e.2 NON-VACUITY: the awk strip found both sentinels" "0" "$R9E_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9E_COUNT_AFTER=$(grep -cF "$R9E_OLD" "$EG_M")
assert_eq "9e.3 NON-VACUITY: the multiply-bound decision is GONE from the mutant" "0" "$R9E_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9e.4 NON-VACUITY: the mutant still parses" "0" "$?"

R9EU1=$(u U1 "a.sh")
R9EUNITS=$(units_of "$R9EU1")
R9EDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9E" "$R9EUNITS" "T-R9E-A,T-R9E-B")
bind_child "$BDFIX" "T-R9E-A" "EPIC-R9E" "U1" "$R9EDH"
bind_child "$BDFIX" "T-R9E-B" "EPIC-R9E" "U1" "$R9EDH"

R9E_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9E")
assert_eq "9e.5 SPECIFIC MISBEHAVIOUR: mutant silently keeps ONE of the two conflicting bindings -> parallel_safe=true" \
    "true" "$(json_field '.parallel_safe' "$R9E_MUTANT_OUT")"
assert_eq "9e.6 SPECIFIC MISBEHAVIOUR: exactly one task survives in unit_task_map (the conflict is invisible)" \
    "1" "$(json_field '.unit_task_map | length' "$R9E_MUTANT_OUT")"

R9E_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9E")
assert_eq "9e.7 RESTORE CONTROL: the SHIPPED script correctly degrades on the identical fixture" \
    "false" "$(json_field '.parallel_safe' "$R9E_CONTROL_OUT")"
assert_eq "9e.8 RESTORE CONTROL: reason names the conflict" \
    "unit_bound_to_multiple_tasks" "$(json_field '.degradation_reason' "$R9E_CONTROL_OUT")"
assert_contains "9e.9 RESTORE CONTROL: observations name BOTH conflicting task ids" "T-R9E-A" "$(json_field '.observations' "$R9E_CONTROL_OUT")"
assert_contains "9e.10 RESTORE CONTROL: observations name BOTH conflicting task ids" "T-R9E-B" "$(json_field '.observations' "$R9E_CONTROL_OUT")"

# --- 9f: R2-F3 -- degraded batches must respect a KNOWN dependency order,
# never just a locale-independent id sort that can place a dependent's task
# before its own prerequisite's task. Task ids are chosen so lexicographic
# order is WRONG (T-A-DEPENDENT < T-Z-PREREQ) and only a real topological
# read gets this right. U-orphan has no implementing child at all (the
# same shape as 9a's U1) so U-blocked's dependency on it is unresolved,
# which is what forces the whole plan to degrade in the first place.
# ROUND 7 (R7-F1) CHANGED WHAT THE DEGRADED SCHEDULE DOES HERE: U-blocked
# is a BOUND unit whose design dependency has no bound implementing task,
# so the construction now REFUSES (batches []) instead of ordering the
# other two tasks -- emitting T-M-BLOCKED as runnable while its design
# prerequisite has no task at all was R7-F1's second named hazard. The
# ordering-under-degrade property this section used to pin on THIS
# fixture is pinned at 9j.9/9n.3 (both edge ends bound, unrelated child
# unbound) and 9f.6 below (the window fixture, every child bound); the
# refusal itself is asserted at 9f.3/9f.3b, and the prereq-unbound shape
# nothing exercised before round 7 is section 9r. --------------------------
R9FPREREQ=$(u U-prereq "p.sh")
R9FDEPENDENT=$(u U-dependent "d.sh" "U-prereq")
R9FORPHAN=$(u U-orphan "o.sh")
R9FBLOCKED=$(u U-blocked "b.sh" "U-orphan")
R9FUNITS=$(units_of "$R9FPREREQ" "$R9FDEPENDENT" "$R9FORPHAN" "$R9FBLOCKED")
R9FDH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9F" "$R9FUNITS" "T-A-DEPENDENT,T-M-BLOCKED,T-Z-PREREQ")
bind_child "$FIXTURE/bd-fixture" "T-Z-PREREQ" "EPIC-R9F" "U-prereq" "$R9FDH"
bind_child "$FIXTURE/bd-fixture" "T-A-DEPENDENT" "EPIC-R9F" "U-dependent" "$R9FDH"
bind_child "$FIXTURE/bd-fixture" "T-M-BLOCKED" "EPIC-R9F" "U-blocked" "$R9FDH"

R9F_CONTROL_OUT=$(bash "$EG" plan-batches "EPIC-R9F")
assert_eq "9f.1 sanity: this fixture genuinely degrades (U-blocked depends on unresolved U-orphan)" \
    "false" "$(json_field '.parallel_safe' "$R9F_CONTROL_OUT")"
assert_eq "9f.2 sanity: reason is the R1-F1 unresolved-dependency guard" \
    "unit_depends_on_unresolved_unit" "$(json_field '.degradation_reason' "$R9F_CONTROL_OUT")"
assert_eq "9f.3 R7-F1: the degraded schedule REFUSES (batches=[]) at this call site -- U-blocked is bound and its design dependency U-orphan has no bound implementing task, so no runnable order containing T-M-BLOCKED is emitted" \
    "0" "$(json_field '.batches | length' "$R9F_CONTROL_OUT")"
assert_contains "9f.3b R7-F1: observations carry the refusal annotation" \
    "refused rather than emitted" "$(json_field '.observations' "$R9F_CONTROL_OUT")"

# RE-TARGETED IN ROUND 5 (vacuity finding on the old 9f.9; the 9g "rework
# in place" precedent). The old mutant stripped PLAN-BATCHES-TOPO-ORDER-
# GATE, whose named specific misbehaviour had become batches=[] -- the
# SAFE refusal required when ordering is unavailable -- so the leg no
# longer demonstrated a dependency-order violation at all. The mutant now
# targets PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE inside the R5-F4
# WINDOW: a fixture whose degradation fires at a post-validation path
# gate (declared_paths_not_canonical), where round 5 found dependencies
# published but bindings not yet -- the exact window in which _pb_degrade
# used to map every child to null and emit plain sorted order over a
# KNOWN edge while the binding records sat readable-but-unread in bd.
# After the R5-F4 fix (bindings resolved and published immediately after
# the declarations are read, before any path gate can fire), the SHIPPED
# script emits the topologically correct serial schedule here; stripping
# the publish reproduces the window defect as a GENUINE wrong order --
# T-A-DEPENDENT's batch before its own prerequisite T-Z-PREREQ's -- which
# is the discriminating misbehaviour the old leg lost. The shipped-
# control legs double as the R5-F4 regression guard: moving the binding
# loop back below the path gates fails 9f.6 immediately.
#
# 9j strips the SAME sentinel at a DIFFERENT _pb_degrade call site (the
# CHILD-BINDING-GATE, where a child is genuinely unbound); this leg is
# the window call site, where every child is cleanly bound and only the
# publish timing protects the order.
new_fixture_root "mutant9f"
R9FWPREREQ=$(u U-prereq "p9fw.sh")
R9FWDEPENDENT=$(u U-dependent "d9fw.sh" "U-prereq")
R9FWNONCANON=$(u U-noncanon "./n9fw.sh")
R9FWUNITS=$(units_of "$R9FWPREREQ" "$R9FWDEPENDENT" "$R9FWNONCANON")
R9FW_DH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9FW" "$R9FWUNITS" "T-A-DEPENDENT,T-N-NONCANON,T-Z-PREREQ")
bind_child "$BDFIX" "T-Z-PREREQ" "EPIC-R9FW" "U-prereq" "$R9FW_DH"
bind_child "$BDFIX" "T-A-DEPENDENT" "EPIC-R9FW" "U-dependent" "$R9FW_DH"
bind_child "$BDFIX" "T-N-NONCANON" "EPIC-R9FW" "U-noncanon" "$R9FW_DH"

R9FW_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9FW")
assert_eq "9f.4 RESTORE CONTROL (R5-F4 window): the fixture degrades AT a post-validation path gate (declared_paths_not_canonical), with every child cleanly bound" \
    "declared_paths_not_canonical" "$(json_field '.degradation_reason' "$R9FW_CONTROL_OUT")"
assert_eq "9f.5 RESTORE CONTROL: the SHIPPED script still emits the COMPLETE serial schedule in the window (3 singleton batches)" \
    "3" "$(json_field '.batches | length' "$R9FW_CONTROL_OUT")"
# shellcheck disable=SC2016
R9FW_C_PREREQ_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-Z-PREREQ")] | index(true)' "$R9FW_CONTROL_OUT")
# shellcheck disable=SC2016
R9FW_C_DEPENDENT_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-A-DEPENDENT")] | index(true)' "$R9FW_CONTROL_OUT")
if [ "$R9FW_C_PREREQ_IDX" -lt "$R9FW_C_DEPENDENT_IDX" ] 2>/dev/null; then R9FW_C_ORDER_OK="true"; else R9FW_C_ORDER_OK="false"; fi
assert_eq "9f.6 RESTORE CONTROL / R5-F4 REGRESSION GUARD: T-Z-PREREQ's batch precedes T-A-DEPENDENT's IN THE WINDOW (bindings were resolved and published before the path gate fired)" \
    "true" "$R9FW_C_ORDER_OK"

# NON-VACUITY: the early-publish assignment exists exactly once before
# mutation (the same anchor 9j pins at its own call site).
# shellcheck disable=SC2016
R9FW_ANCHOR='_PB_DEGRADE_BINDINGS_JSON="$bound_pairs_json"'
R9FW_COUNT_BEFORE=$(grep -cF "$R9FW_ANCHOR" "$EG_M")
assert_eq "9f.7 NON-VACUITY: the early bindings-publish assignment existed exactly once before mutation" "1" "$R9FW_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9FW_AWK_RC=$?
assert_eq "9f.8 NON-VACUITY: the awk strip found both sentinels" "0" "$R9FW_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9FW_COUNT_AFTER=$(grep -cF "$R9FW_ANCHOR" "$EG_M")
assert_eq "9f.8b NON-VACUITY: the publish assignment is GONE from the mutant" "0" "$R9FW_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9f.8c NON-VACUITY: the mutant still parses" "0" "$?"

R9FW_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9FW")
assert_eq "9f.9a sanity: mutant still degrades with the window's own reason (the publish is an ORDERING protection, not a safety guard)" \
    "declared_paths_not_canonical" "$(json_field '.degradation_reason' "$R9FW_MUTANT_OUT")"
# shellcheck disable=SC2016
R9FW_M_PREREQ_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-Z-PREREQ")] | index(true)' "$R9FW_MUTANT_OUT")
# shellcheck disable=SC2016
R9FW_M_DEPENDENT_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-A-DEPENDENT")] | index(true)' "$R9FW_MUTANT_OUT")
if [ "$R9FW_M_DEPENDENT_IDX" -lt "$R9FW_M_PREREQ_IDX" ] 2>/dev/null; then R9FW_M_INVERTED="true"; else R9FW_M_INVERTED="false"; fi
assert_eq "9f.9 SPECIFIC MISBEHAVIOUR (re-targeted, round 5): with the publish stripped, the window degrade emits T-A-DEPENDENT's batch BEFORE its own prerequisite T-Z-PREREQ's -- a GENUINE dependency-order violation over a KNOWN edge, not the safe batches=[] refusal" \
    "true" "$R9FW_M_INVERTED"
assert_eq "9f.10 SPECIFIC MISBEHAVIOUR: the wrong order is presented as a complete runnable schedule (3 batches), which is exactly why the publish must precede every post-validation guard" \
    "3" "$(json_field '.batches | length' "$R9FW_MUTANT_OUT")"

# --- 9g: R2-F1, REWORKED for R3-F1/R3-F2 (independent review xsu1 round 3)
# -- two declared paths that are byte-different but identify the SAME file
# through an EXISTING symlinked ancestor directory must degrade; neither
# the canonical-form check (9b's sanity case) nor the case-collision check
# (9b) can see this, since neither string is non-canonical or case-
# differing. Reproduces the review's own illustration (this repo's
# `tests -> .claude/scripts/tests`) with a fixture-local symlink, so the
# scenario is fully portable rather than depending on this repo's own
# directory layout. Round 3 REPLACED pass 1's mechanism (resolve-a-key-
# and-compare -> a single unconditional "is any component a symlink"
# check, _pb_path_has_symlink) after independent review found the
# resolve-and-compare chain both fail-open-prone (R3-F1) and blind to
# dangling symlinks (R3-F2) -- the mutant below now targets the smaller
# replacement, and the expected degradation_reason changed accordingly
# (declared_path_traverses_symlink, not declared_paths_alias_same_file --
# pass 1 no longer claims to have PROVEN a collision, only that it refuses
# to reason past a symlink). ------------------------------------------------
new_fixture_root "mutant9g"
mkdir -p "$ROOT/real-dir"
ln -s real-dir "$ROOT/alias-dir"

R9GU1=$(u U1 "alias-dir/shared.sh")
R9GU2=$(u U2 "real-dir/shared.sh")
R9GUNITS=$(units_of "$R9GU1" "$R9GU2")

# NON-VACUITY: the alias-detection pass exists exactly once before mutation.
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9G_ALIAS_ANCHOR='_pb_path_has_symlink() {'
R9G_ALIAS_COUNT_BEFORE=$(grep -cF "$R9G_ALIAS_ANCHOR" "$EG_M")
assert_eq "9g.1 NON-VACUITY: _pb_path_has_symlink existed exactly once before mutation" "1" "$R9G_ALIAS_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-ALIAS-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-ALIAS-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9G_AWK_RC=$?
assert_eq "9g.2 NON-VACUITY: the awk strip found both sentinels" "0" "$R9G_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
# The ALIAS-GATE sentinel strips the CALL SITE, not the function definition
# itself (which lives above cmd_plan_batches and is now dead code in the
# mutant, harmlessly) -- non-vacuity for THIS mutant is "the call site is
# gone", checked directly below via the actual degrade behaviour, since a
# function definition with no caller proves nothing on its own.
bash -n "$EG_M"
assert_eq "9g.4 NON-VACUITY: the mutant still parses" "0" "$?"

R9GDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9G" "$R9GUNITS" "T-R9G-U1,T-R9G-U2")
bind_child "$BDFIX" "T-R9G-U1" "EPIC-R9G" "U1" "$R9GDH"
bind_child "$BDFIX" "T-R9G-U2" "EPIC-R9G" "U2" "$R9GDH"

R9G_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9G")
assert_eq "9g.5 SPECIFIC MISBEHAVIOUR: mutant silently co-batches U1 and U2 through the symlinked alias -> parallel_safe=true" \
    "true" "$(json_field '.parallel_safe' "$R9G_MUTANT_OUT")"
assert_eq "9g.6 SPECIFIC MISBEHAVIOUR: exactly one batch (the collision is invisible)" \
    "1" "$(json_field '.batches | length' "$R9G_MUTANT_OUT")"

R9G_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9G")
assert_eq "9g.7 RESTORE CONTROL: the SHIPPED script correctly degrades on the identical fixture" \
    "false" "$(json_field '.parallel_safe' "$R9G_CONTROL_OUT")"
assert_eq "9g.8 RESTORE CONTROL: reason names the symlink traversal (R3-F1/R3-F2's smaller pass 1), not the old resolve-and-compare token" \
    "declared_path_traverses_symlink" "$(json_field '.degradation_reason' "$R9G_CONTROL_OUT")"
assert_contains "9g.9 RESTORE CONTROL: observations name the symlinked declaration" "alias-dir/shared.sh" "$(json_field '.observations' "$R9G_CONTROL_OUT")"

# --- 9g2: R2-F1's SECOND, independent pass (-ef device+inode) -- REWORKED
# for round 3: a file-level SYMLINK alias (alias.sh -> real.sh, both
# existing) is now caught by pass 1 itself (a symlink is a symlink whether
# it is a leaf or an ancestor -- _pb_path_has_symlink checks the full path,
# not just directory components), so it no longer distinctly exercises
# pass 2. A HARD LINK does: same device+inode, but -L is false for it (a
# hard link is a second directory entry for the SAME inode, not a special
# symlink file type) -- and a hard link is portable across POSIX
# filesystems, unlike the Unicode-normalisation/non-ASCII-case aliasing
# this pass was ORIGINALLY motivated by, which is real (independently
# reproduced by hand on this exact host: a Cyrillic case variant and an
# NFC/NFD pair of `é.js` both report -ef-identical once written) but is
# APFS-specific and would not alias on this repo's own Linux CI tier,
# making it unsuitable for a portable CI assertion. ---------------------
printf 'real content\n' > "$FIXTURE/hard-real.js"
ln "$FIXTURE/hard-real.js" "$FIXTURE/hard-link.js"
R9G2U1=$(u U1 "hard-real.js")
R9G2U2=$(u U2 "hard-link.js")
R9G2UNITS=$(units_of "$R9G2U1" "$R9G2U2")
R9G2DH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9G2" "$R9G2UNITS" "T-R9G2-U1,T-R9G2-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9G2-U1" "EPIC-R9G2" "U1" "$R9G2DH"
bind_child "$FIXTURE/bd-fixture" "T-R9G2-U2" "EPIC-R9G2" "U2" "$R9G2DH"
R9G2_OUT=$(bash "$EG" plan-batches "EPIC-R9G2")
assert_eq "9g2.0 PRECONDITION: the hard link is genuinely not a symlink (so this exercises pass 2, not pass 1)" \
    "not-a-symlink" "$([ -L "$FIXTURE/hard-link.js" ] && echo "is-a-symlink" || echo "not-a-symlink")"
assert_eq "9g2.1 pass 2 (-ef inode check): an already-existing hard-link alias degrades" \
    "false" "$(json_field '.parallel_safe' "$R9G2_OUT")"
assert_eq "9g2.2 pass 2: reason names the alias, distinct from pass 1's symlink-traversal reason" \
    "declared_paths_alias_same_file" "$(json_field '.degradation_reason' "$R9G2_OUT")"
assert_contains "9g2.3 pass 2's own distinct observations text (device+inode, not pass 1's traversal wording)" \
    "device+inode identical" "$(json_field '.observations' "$R9G2_OUT")"

# --- 9g3: R3-F2 -- a DANGLING symlink (alias.sh -> real.sh where real.sh
# does NOT exist) must ALSO degrade. Before this fix it did not: -d/-e both
# FOLLOW a symlink to its target, so a dangling link's own leaf component
# read as "not a directory, not existing" -- indistinguishable from an
# ordinary not-yet-written path -- and neither declared spelling ever
# reached the (existence-gated) -ef pass either. _pb_path_has_symlink uses
# -L, which is true for a symlink regardless of whether ITS TARGET exists,
# so this is now closed by the SAME mechanism as 9g, not a special case. --
mkdir -p "$FIXTURE/dangling-check"
ln -s does-not-exist.sh "$FIXTURE/dangling-check/dangling-alias.sh"
assert_eq "9g3.0 PRECONDITION: the dangling symlink's target genuinely does not exist" \
    "target-absent" "$([ -e "$FIXTURE/dangling-check/does-not-exist.sh" ] && echo "target-present" || echo "target-absent")"
assert_eq "9g3.0b PRECONDITION: -e on the dangling link itself is false (the OLD -d/-e-based check could not see it)" \
    "e-false" "$([ -e "$FIXTURE/dangling-check/dangling-alias.sh" ] && echo "e-true" || echo "e-false")"
R9G3U1=$(u U1 "dangling-check/dangling-alias.sh")
R9G3U2=$(u U2 "dangling-check/does-not-exist.sh")
R9G3UNITS=$(units_of "$R9G3U1" "$R9G3U2")
R9G3DH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9G3" "$R9G3UNITS" "T-R9G3-U1,T-R9G3-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9G3-U1" "EPIC-R9G3" "U1" "$R9G3DH"
bind_child "$FIXTURE/bd-fixture" "T-R9G3-U2" "EPIC-R9G3" "U2" "$R9G3DH"
R9G3_OUT=$(bash "$EG" plan-batches "EPIC-R9G3")
assert_eq "9g3.1 R3-F2: a dangling symlink alias degrades" "false" "$(json_field '.parallel_safe' "$R9G3_OUT")"
assert_eq "9g3.2 R3-F2: reason names the symlink traversal" \
    "declared_path_traverses_symlink" "$(json_field '.degradation_reason' "$R9G3_OUT")"
assert_contains "9g3.3 R3-F2: observations name the dangling declaration" "dangling-alias.sh" "$(json_field '.observations' "$R9G3_OUT")"

# --- 9g4: R3-F2's OTHER named shape -- "the same applies to a dangling
# symlinked ANCESTOR" (not just a dangling leaf file, 9g3's own case).
# dangling-ancestor is a symlink to a target that does not exist AT ALL,
# used as a DIRECTORY PREFIX two levels deep -- neither
# "dangling-ancestor/deep" nor "dangling-ancestor/deep/file.sh" can exist,
# since you cannot traverse through a symlink to nothing. -L still answers
# correctly on dangling-ancestor ITSELF without ever needing to traverse
# through it, which is exactly why _pb_path_has_symlink's ancestor walk
# (never -d/-e) closes this too. -----------------------------------------
ln -s does-not-exist-either "$FIXTURE/dangling-ancestor"
assert_eq "9g4.0 PRECONDITION: the dangling ancestor's target genuinely does not exist" \
    "target-absent" "$([ -e "$FIXTURE/does-not-exist-either" ] && echo "target-present" || echo "target-absent")"
assert_eq "9g4.0b PRECONDITION: a path traversing the dangling ancestor cannot itself exist (nothing to walk through)" \
    "e-false" "$([ -e "$FIXTURE/dangling-ancestor/deep/file.sh" ] && echo "e-true" || echo "e-false")"
R9G4U1=$(u U1 "dangling-ancestor/deep/file.sh")
R9G4U2=$(u U2 "plain-9g4.sh")
R9G4UNITS=$(units_of "$R9G4U1" "$R9G4U2")
R9G4DH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9G4" "$R9G4UNITS" "T-R9G4-U1,T-R9G4-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9G4-U1" "EPIC-R9G4" "U1" "$R9G4DH"
bind_child "$FIXTURE/bd-fixture" "T-R9G4-U2" "EPIC-R9G4" "U2" "$R9G4DH"
R9G4_OUT=$(bash "$EG" plan-batches "EPIC-R9G4")
assert_eq "9g4.1 R3-F2: a dangling symlinked ANCESTOR (two levels deep) degrades" \
    "false" "$(json_field '.parallel_safe' "$R9G4_OUT")"
assert_eq "9g4.2 R3-F2: reason names the symlink traversal" \
    "declared_path_traverses_symlink" "$(json_field '.degradation_reason' "$R9G4_OUT")"
assert_contains "9g4.3 R3-F2: observations name the declaration that traverses the dangling ancestor" \
    "dangling-ancestor/deep/file.sh" "$(json_field '.observations' "$R9G4_OUT")"

# --- 9h: R2-F4 -- a PRESENT-but-MALFUNCTIONING jq (found on PATH, but every
# invocation fails) must degrade this subcommand exactly like every other
# guard-list condition (full envelope, parallel_safe:false, both graph
# fields present, exit 0) -- the R1-F7 fix covers jq's ABSENCE; this covers
# its malfunction, one level further in ("the guard that detects jq's
# absence cannot detect its malfunction", the review's own words). A shim
# directory containing ONLY a broken `jq` is prepended to the REAL $PATH
# (9d's own technique) so every OTHER tool epic-gate.sh/qa-gate.sh/
# review-check.sh/workflow-manifest.sh shell out to remains available; only
# jq itself is intercepted.
#
# SCOPE (R4-F8, disclosed rather than implied): this control's nonexistent
# epic reaches _pb_degrade with ZERO children — the epic-readable gate
# fires before enumeration, and with jq broken even a real epic would
# enumerate no children — so the jq-dependent schedule construction inside
# _pb_degrade never executes here. What 9h proves is the FINISH fallback
# (envelope construction under a broken jq), nothing about the degrade
# path's own jq discipline. The with-children jq branch is covered by 9n,
# which injects failures into each of _pb_degrade's two jq sites
# individually against a fixture with real children. ----------------------
mkdir -p "$FIXTURE/broken-jq-only"
cat > "$FIXTURE/broken-jq-only/jq" <<'BROKENJQ'
#!/bin/bash
exit 1
BROKENJQ
chmod +x "$FIXTURE/broken-jq-only/jq"

R9H_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" PATH="$FIXTURE/broken-jq-only:$PATH" bash "$EG" plan-batches "EPIC-R9H-NONEXISTENT" 2>&1)
R9H_CONTROL_RC=$?
assert_eq "9h.1 RESTORE CONTROL: broken jq against the SHIPPED script exits 0" "0" "$R9H_CONTROL_RC"
assert_eq "9h.2 RESTORE CONTROL: ok:true (a determined, if narrow, answer -- never an infra failure to the caller)" \
    "true" "$(json_field '.ok' "$R9H_CONTROL_OUT")"
assert_eq "9h.3 RESTORE CONTROL: parallel_safe:false" "false" "$(json_field '.parallel_safe' "$R9H_CONTROL_OUT")"
assert_eq "9h.4 RESTORE CONTROL: degradation_reason names the malfunction specifically, not jq_unavailable" \
    "envelope_construction_failed" "$(json_field '.degradation_reason' "$R9H_CONTROL_OUT")"
assert_eq "9h.5 RESTORE CONTROL: graph_intersection_computed is still present and false" \
    "false" "$(json_field '.graph_intersection_computed' "$R9H_CONTROL_OUT")"
assert_eq "9h.6 RESTORE CONTROL: graph_degradation_reason is still present" \
    "code_graph_absent" "$(json_field '.graph_degradation_reason' "$R9H_CONTROL_OUT")"
assert_contains "9h.7 RESTORE CONTROL: observations name jq's malfunction, not its absence" \
    "present-but-malfunctioning, not absent" "$(json_field '.observations' "$R9H_CONTROL_OUT")"

# NON-VACUITY: the fallback literal exists exactly once before mutation.
R9H_ANCHOR="the plan-batches envelope itself could not be constructed"
R9H_COUNT_BEFORE=$(grep -cF "$R9H_ANCHOR" "$EG")
assert_eq "9h.8 NON-VACUITY: the fallback literal existed exactly once before mutation" "1" "$R9H_COUNT_BEFORE"

new_fixture_root "mutant9h"
awk '
  /# PLAN-BATCHES-FINISH-FALLBACK-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-FINISH-FALLBACK-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9H_AWK_RC=$?
assert_eq "9h.9 NON-VACUITY: the awk strip found both sentinels" "0" "$R9H_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9H_COUNT_AFTER=$(grep -cF "$R9H_ANCHOR" "$EG_M")
assert_eq "9h.10 NON-VACUITY: the fallback literal is GONE from the mutant" "0" "$R9H_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9h.11 NON-VACUITY: the mutant still parses" "0" "$?"

R9H_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" PATH="$FIXTURE/broken-jq-only:$PATH" bash "$EG_M" plan-batches "EPIC-R9H-NONEXISTENT" 2>&1)
R9H_MUTANT_RC=$?
assert_eq "9h.12 SPECIFIC MISBEHAVIOUR: mutant still exits 0 (no crash)..." "0" "$R9H_MUTANT_RC"
assert_eq "9h.13 ...but stdout is EMPTY -- not a wrong-shaped envelope, no envelope at all" \
    "" "$R9H_MUTANT_OUT"

# Sanity: the mutant is unmutated w.r.t. jq ABSENCE handling -- it still
# degrades correctly when jq is simply not there at all (R1-F7's own
# guard, upstream of this one, is untouched by this mutation).
R9H_ABSENT_PATH="$FIXTURE/no-jq-bin"
mkdir -p "$R9H_ABSENT_PATH"
for t in bash sh grep sed awk cat tr head tail cut date mktemp wc printf basename dirname env true false rm mkdir ls; do
    c=$(command -v "$t" 2>/dev/null) && ln -sf "$c" "$R9H_ABSENT_PATH/$t"
done
R9H_ABSENT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" PATH="$R9H_ABSENT_PATH" bash "$EG_M" plan-batches "EPIC-R9H-NONEXISTENT" 2>&1)
assert_eq "9h.14 sanity: mutant is unaffected by R1-F7's OWN jq-absent guard (a different code path) -- still parallel_safe=false" \
    "false" "$(json_field '.parallel_safe' "$R9H_ABSENT_OUT")"
assert_eq "9h.15 sanity: ...reason is jq_unavailable specifically, not envelope_construction_failed (proves the two jq-failure code paths stay independently distinguishable)" \
    "jq_unavailable" "$(json_field '.degradation_reason' "$R9H_ABSENT_OUT")"

# --- 9h EXTENDED (round 5, R5-F5): the exit-1 shim above cannot see the
# OTHER malfunction shape -- a jq that exits 0 while printing malformed
# output. _pb_finish used to test only [ -z "$out" ], so rc-0 whitespace/
# []/null/garbage from the emit bypassed the jq-independent fallback and
# was PERSISTED AND PRINTED as the envelope. The shim below is CALL-SITE-
# TARGETED (the repo's marker discipline: the fault must match the exact
# call site it names): it sabotages ONLY the program whose text contains
# a source-unique substring of emit_plan_batches' own envelope
# construction, printing [] with rc 0, and passes every other invocation
# through to the real jq -- so the R5-F5 shape-validation call inside
# _pb_finish runs REAL jq against the sabotaged output and must route it
# to the fallback. ---------------------------------------------------------
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9H2_EMIT_MARKER='manifest_path:$mpath'
R9H2_EMIT_COUNT=$(grep -cF "$R9H2_EMIT_MARKER" "$EG")
assert_eq "9h.16 PRECONDITION: the emit-program marker is source-unique (substring matching cannot strand at another call site)" \
    "1" "$R9H2_EMIT_COUNT"

mkdir -p "$FIXTURE/malformed-jq-bin"
cat > "$FIXTURE/malformed-jq-bin/jq" <<SHIMEOF
#!/bin/bash
# R9H2_MALFORM_SUBSTRING: substring match against the emit program only
# (proven source-unique in 9h.16) -> print [] and exit 0 (R5-F5's
# successful-but-malformed shape). Every other call runs the real jq.
if [ -n "\${R9H2_MALFORM_SUBSTRING:-}" ]; then
    for a in "\$@"; do
        case "\$a" in
            *"\$R9H2_MALFORM_SUBSTRING"*) printf '[]\n'; exit 0 ;;
        esac
    done
fi
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/malformed-jq-bin/jq"

R9H2_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" R9H2_MALFORM_SUBSTRING="$R9H2_EMIT_MARKER" PATH="$FIXTURE/malformed-jq-bin:$PATH" bash "$EG" plan-batches "EPIC-R9H-NONEXISTENT" 2>&1)
R9H2_RC=$?
assert_eq "9h.17 R5-F5: an rc-0-malformed emit still exits 0 against the SHIPPED script" "0" "$R9H2_RC"
assert_eq "9h.18 R5-F5: the shape validation routes the malformed output to the jq-independent fallback (reason envelope_construction_failed), never persists or prints it" \
    "envelope_construction_failed" "$(json_field '.degradation_reason' "$R9H2_OUT")"
assert_eq "9h.19 R5-F5: fallback envelope is complete (ok:true, parallel_safe:false)" \
    "true|false" "$(json_field '.ok' "$R9H2_OUT")|$(json_field '.parallel_safe' "$R9H2_OUT")"

# MUTANT: EG_M is the FINISH-FALLBACK-GATE-stripped copy built at
# 9h.9-9h.11 above -- the strip removes the R5-F5 validation AND the
# fallback together (they share the sentinel). Under the same rc-0-
# malformed injection, execution falls straight through to persist-and-
# print of the malformed bytes: stdout is literally [] with exit 0,
# presented to the consumer as if it were the envelope.
R9H2_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" R9H2_MALFORM_SUBSTRING="$R9H2_EMIT_MARKER" PATH="$FIXTURE/malformed-jq-bin:$PATH" bash "$EG_M" plan-batches "EPIC-R9H-NONEXISTENT" 2>&1)
R9H2_MUTANT_RC=$?
assert_eq "9h.20 SPECIFIC MISBEHAVIOUR: the gate-stripped mutant exits 0..." "0" "$R9H2_MUTANT_RC"
assert_eq "9h.21 ...and prints the raw malformed bytes ([]) as the envelope -- R5-F5's exact named danger (persisted and printed, no fallback)" \
    "[]" "$R9H2_MUTANT_OUT"

# --- 9i: R3-F1 -- the alias pass's OWN per-line (.u, .f) extraction must be
# fail-CLOSED. Before this fix, `|| ""` on either field made a failed
# extraction read as "nothing to check" (line 1279's `continue`), silently
# dropping BOTH declared paths of that pair from EVERY alias check -- the
# reviewer's own probe used a jq shim failing only the exact `.u` argument
# against the 9g symlink fixture and observed the collision vanish
# entirely (flat_pairs=2, alias_entries_after=0). Each extraction is now
# its own independent rc-AND-shape-checked read (matching this file's
# discipline everywhere else); a failure BREAKS the loop and degrades
# set_computation_failed instead of continuing past the entry. ------------
R9IU1=$(u U1 "plain-i1.sh")
R9IU2=$(u U2 "plain-i2.sh")
R9IUNITS=$(units_of "$R9IU1" "$R9IU2")
R9IDH=$(seed_epic "$FIXTURE" "$FIXTURE/bd-fixture" "$WFM" "EPIC-R9I" "$R9IUNITS" "T-R9I-U1,T-R9I-U2")
bind_child "$FIXTURE/bd-fixture" "T-R9I-U1" "EPIC-R9I" "U1" "$R9IDH"
bind_child "$FIXTURE/bd-fixture" "T-R9I-U2" "EPIC-R9I" "U2" "$R9IDH"

# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9I_U_MARKER='if (type=="object" and (.u|type)=="string" and (.u|length)>0) then .u else empty end'
# shellcheck disable=SC2016
R9I_F_MARKER='if (type=="object" and (.f|type)=="string" and (.f|length)>0) then .f else empty end'
R9I_U_COUNT=$(grep -cF "$R9I_U_MARKER" "$EG")
R9I_F_COUNT=$(grep -cF "$R9I_F_MARKER" "$EG")
assert_eq "9i.0a PRECONDITION: the .u extraction marker is source-unique (exact matching is safe and necessary)" "1" "$R9I_U_COUNT"
assert_eq "9i.0b PRECONDITION: the .f extraction marker is source-unique" "1" "$R9I_F_COUNT"

mkdir -p "$FIXTURE/r9i-shim-bin"
cat > "$FIXTURE/r9i-shim-bin/jq" <<SHIMEOF
#!/bin/bash
# R9I_FAIL_MARKER: WHOLE-ARGUMENT exact match only.
for a in "\$@"; do
    if [ -n "\$R9I_FAIL_MARKER" ] && [ "\$a" = "\$R9I_FAIL_MARKER" ]; then
        exit 1
    fi
done
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/r9i-shim-bin/jq"

R9I_U_FAIL_OUT=$(R9I_FAIL_MARKER="$R9I_U_MARKER" PATH="$FIXTURE/r9i-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9I")
assert_eq "9i.1 R3-F1: an induced .u-extraction failure degrades (never silently drops the pair)" \
    "false" "$(json_field '.parallel_safe' "$R9I_U_FAIL_OUT")"
assert_eq "9i.2 R3-F1: ...names set_computation_failed" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9I_U_FAIL_OUT")"

R9I_F_FAIL_OUT=$(R9I_FAIL_MARKER="$R9I_F_MARKER" PATH="$FIXTURE/r9i-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9I")
assert_eq "9i.3 R3-F1: an induced .f-extraction failure ALSO degrades" \
    "false" "$(json_field '.parallel_safe' "$R9I_F_FAIL_OUT")"
assert_eq "9i.4 R3-F1: ...also names set_computation_failed" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9I_F_FAIL_OUT")"

R9I_CLEAN_OUT=$(bash "$EG" plan-batches "EPIC-R9I")
assert_eq "9i.5 sanity: the identical fixture with NO induced failure is parallel_safe=true (two plain, non-aliasing files)" \
    "true" "$(json_field '.parallel_safe' "$R9I_CLEAN_OUT")"

# --- 9j: R3-F3 -- the topological reorder must be fed real bindings at the
# CHILD-BINDING-GATE call site, not just at the later unit_depends_on_
# unresolved_unit call site 9f already covers. Two children (T-Z-PREREQ,
# T-A-DEPENDENT) bind cleanly with a real dependency between them; a THIRD
# child (T-UNBOUND-THIRD) is enumerable but has no DESIGN-UNIT binding at
# all, which is what forces the degrade at THIS specific, earlier call
# site. Task ids are chosen so lexicographic order is wrong (T-A < T-Z),
# matching the reviewer's own probe. ----------------------------------------
new_fixture_root "mutant9j"
R9JU1=$(u U-prereq "p.sh")
R9JU2=$(u U-dependent "d.sh" "U-prereq")
R9JUNITS=$(units_of "$R9JU1" "$R9JU2")

# NON-VACUITY: the early-publish assignment exists exactly once before mutation.
# shellcheck disable=SC2016
R9J_ANCHOR='_PB_DEGRADE_BINDINGS_JSON="$bound_pairs_json"'
R9J_COUNT_BEFORE=$(grep -cF "$R9J_ANCHOR" "$EG_M")
assert_eq "9j.1 NON-VACUITY: the early bindings-publish assignment existed exactly once before mutation" "1" "$R9J_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-EARLY-BINDINGS-PUBLISH-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9J_AWK_RC=$?
assert_eq "9j.2 NON-VACUITY: the awk strip found both sentinels" "0" "$R9J_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9J_COUNT_AFTER=$(grep -cF "$R9J_ANCHOR" "$EG_M")
assert_eq "9j.3 NON-VACUITY: the early bindings-publish assignment is GONE from the mutant" "0" "$R9J_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9j.4 NON-VACUITY: the mutant still parses" "0" "$?"

R9JDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9J" "$R9JUNITS" "T-A-DEPENDENT,T-UNBOUND-THIRD,T-Z-PREREQ")
bind_child "$BDFIX" "T-Z-PREREQ" "EPIC-R9J" "U-prereq" "$R9JDH"
bind_child "$BDFIX" "T-A-DEPENDENT" "EPIC-R9J" "U-dependent" "$R9JDH"
unbound_child "$BDFIX" "T-UNBOUND-THIRD"

R9J_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9J")
assert_eq "9j.5 sanity: mutant still degrades (this gate is an ORDERING refinement, not a safety guard)" \
    "false" "$(json_field '.parallel_safe' "$R9J_MUTANT_OUT")"
# shellcheck disable=SC2016
R9J_M_PREREQ_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-Z-PREREQ")] | index(true)' "$R9J_MUTANT_OUT")
# shellcheck disable=SC2016
R9J_M_DEPENDENT_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-A-DEPENDENT")] | index(true)' "$R9J_MUTANT_OUT")
if [ "$R9J_M_PREREQ_IDX" -lt "$R9J_M_DEPENDENT_IDX" ] 2>/dev/null; then R9J_M_ORDER_OK="true"; else R9J_M_ORDER_OK="false"; fi
assert_eq "9j.6 SPECIFIC MISBEHAVIOUR: mutant (bindings not yet published at this call site) emits T-A-DEPENDENT's batch BEFORE T-Z-PREREQ's" \
    "false" "$R9J_M_ORDER_OK"

R9J_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9J")
assert_eq "9j.7 RESTORE CONTROL: the SHIPPED script still degrades on the identical fixture" \
    "false" "$(json_field '.parallel_safe' "$R9J_CONTROL_OUT")"
assert_eq "9j.8 RESTORE CONTROL: reason names the unbound third child" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$R9J_CONTROL_OUT")"
# shellcheck disable=SC2016
R9J_C_PREREQ_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-Z-PREREQ")] | index(true)' "$R9J_CONTROL_OUT")
# shellcheck disable=SC2016
R9J_C_DEPENDENT_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-A-DEPENDENT")] | index(true)' "$R9J_CONTROL_OUT")
if [ "$R9J_C_PREREQ_IDX" -lt "$R9J_C_DEPENDENT_IDX" ] 2>/dev/null; then R9J_C_ORDER_OK="true"; else R9J_C_ORDER_OK="false"; fi
assert_eq "9j.9 RESTORE CONTROL: SHIPPED script places T-Z-PREREQ's batch BEFORE T-A-DEPENDENT's at THIS call site (bindings now published in time)" \
    "true" "$R9J_C_ORDER_OK"


# ===========================================================================
printf '\n=== Section 9 continued: round-4 findings (xsu1-r4) ===\n'
# ===========================================================================

# --- 9k: R4-F2 -- validate-design's EXIT STATUS counts. A validator that
# prints a shape-valid ok:true envelope and exits NONZERO is reporting its
# own failure out-of-band; the sibling design-status ladder already treats
# rc as authoritative, and (round 4) the validate-design ladder now
# matches it -- two ladders in one file must not disagree on whether the
# exit status counts. The lying validator below is fixture-LOCAL:
# epic-gate.sh resolves review-check.sh from $CLAUDE_PROJECT_DIR at
# runtime, so overwriting the fixture root's copy scopes the lie to this
# leg while $EG stays the SHIPPED artifact (R4-F6's convention). The stub
# echoes the SAME semantic content the real validator would produce for
# this artifact, so a run that wrongly trusts it sails through to a full
# clean plan -- the sharpest possible misbehaviour for the mutant leg. ----
new_fixture_root "r9k"
R9KU1=$(u U1 "a.sh")
R9KUNITS=$(units_of "$R9KU1")
R9KDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9K" "$R9KUNITS" "T-R9K")
bind_child "$BDFIX" "T-R9K" "EPIC-R9K" "U1" "$R9KDH"

# Control FIRST (the real validator, same root, same fixture): clean plan.
R9K_CLEAN_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9K")
assert_eq "9k.1 RESTORE CONTROL: with the real validator this fixture computes a clean plan (parallel_safe=true)" \
    "true" "$(json_field '.parallel_safe' "$R9K_CLEAN_OUT")"

cat > "$ROOT/.claude/scripts/review-check.sh" <<'R9KSTUB'
#!/bin/bash
# 9k lying-validator stub: a SHAPE-VALID ok:true validate-design envelope
# carrying the same semantic content the real validator would emit for
# EPIC-R9K -- and a NONZERO exit. rc=7 is distinctive so the assertion can
# prove the rc arm (not the shape arm) of the ladder fired.
printf '%s\n' '{"ok":true,"subcommand":"validate-design","error_key":"","observations":"stub","units":1,"unit_ids":["U1"],"task_id":"EPIC-R9K","unit_files":{"U1":["a.sh"]},"unit_deps":{"U1":[]}}'
exit 7
R9KSTUB
chmod 0755 "$ROOT/.claude/scripts/review-check.sh"

R9K_LIE_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9K")
assert_eq "9k.2 R4-F2: the SHIPPED script refuses the ok:true-but-exit-7 validator (parallel_safe=false)" \
    "false" "$(json_field '.parallel_safe' "$R9K_LIE_OUT")"
assert_eq "9k.3 R4-F2: reason is validate_design_unavailable" \
    "validate_design_unavailable" "$(json_field '.degradation_reason' "$R9K_LIE_OUT")"
assert_contains "9k.4 R4-F2: observations carry the nonzero rc (rc=7), proving the rc arm of the ladder fired against a shape-VALID body" \
    "(rc=7)" "$(json_field '.observations' "$R9K_LIE_OUT")"

# MUTANT: revert the ladder to its round-3 shape-only form (awk exact-LINE
# replacement, values passed via ENVIRON so no -v backslash mangling and
# no python3 dependency) and prove the rc arm is load-bearing: the mutant
# TRUSTS the lying validator and computes a full clean plan over a
# validation the authoritative command reported as failed.
# shellcheck disable=SC2016  # intentional non-interpolating literals, matched against source below
R9K_OLD_LINE='    if [ "$vout_rc" -ne 0 ] || [ "$vshape_ok" != "true" ]; then'
# shellcheck disable=SC2016
R9K_NEW_LINE='    if [ "$vshape_ok" != "true" ]; then'
R9K_COUNT_BEFORE=$(grep -cF "$R9K_OLD_LINE" "$EG_M")
assert_eq "9k.5 NON-VACUITY: the rc-AND-shape ladder line existed exactly once before mutation" "1" "$R9K_COUNT_BEFORE"
OLD_LINE="$R9K_OLD_LINE" NEW_LINE="$R9K_NEW_LINE" awk '
  { if ($0 == ENVIRON["OLD_LINE"]) { print ENVIRON["NEW_LINE"]; n++ } else print }
  END { if (n != 1) exit 7 }
' "$EG_M" > "$EG_M.replaced"
R9K_AWK_RC=$?
assert_eq "9k.6 NON-VACUITY: the awk exact-line replacement landed exactly once (exit 7 would mean it did not)" "0" "$R9K_AWK_RC"
mv "$EG_M.replaced" "$EG_M"
chmod 0755 "$EG_M"
bash -n "$EG_M"
assert_eq "9k.7 NON-VACUITY: the mutant still parses" "0" "$?"

R9K_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9K")
assert_eq "9k.8 SPECIFIC MISBEHAVIOUR: the shape-only mutant TRUSTS the failing validator -> parallel_safe=true over a validation whose own command exited 7" \
    "true" "$(json_field '.parallel_safe' "$R9K_MUTANT_OUT")"
assert_eq "9k.9 SPECIFIC MISBEHAVIOUR: the mutant computed a full batch plan from the untrusted envelope (1 real batch)" \
    "1" "$(json_field '.batches | length' "$R9K_MUTANT_OUT")"

# --- 9l: R4-F3 -- a declared path containing a control character (most
# sharply a TRAILING NEWLINE) must degrade at the new
# PLAN-BATCHES-CONTROL-CHAR-GATE. Command substitution strips trailing
# newlines, so every check that extracts the name through $(...) tests a
# DIFFERENT spelling ('alias', 5 bytes) than the byte-exact one the
# batching reducer intersects ('alias\n', 6 bytes) -- the round-4
# reviewer's own probe (original_len=6, extracted_len=5). validate-design
# itself ACCEPTS the path (its nonempty_string only rejects the
# all-whitespace case), so the gate under test is the ONLY detection
# point; 9l.0a/9l.0b prove that reachability premise instead of assuming
# it. Reject-never-sanitise (the bjx class): the refusal names the exact
# bytes @json-escaped, it never strips them. -------------------------------
new_fixture_root "r9l"
R9L_NLPATH=$'alias\n'
# u() cannot carry a newline through its CSV interface; build the unit
# object directly. bash $'...' keeps the trailing newline in the variable
# -- only command substitution would strip it -- and jq --arg carries it
# into the artifact's JSON escaped as \n.
# shellcheck disable=SC2016
R9LU1=$("$REAL_JQ" -nc --arg f "$R9L_NLPATH" '{unit_id:"U1", goal:"goal-U1", verification:"verify-U1", files:[$f], acceptance:[{id:"AC-U1",text:"text-U1"}], depends_on:[]}')
R9LU2=$(u U2 "alias")
R9LUNITS=$(units_of "$R9LU1" "$R9LU2")
R9LDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9L" "$R9LUNITS" "T-R9L-U1,T-R9L-U2")
bind_child "$BDFIX" "T-R9L-U1" "EPIC-R9L" "U1" "$R9LDH"
bind_child "$BDFIX" "T-R9L-U2" "EPIC-R9L" "U2" "$R9LDH"

# Reachability preconditions: the artifact genuinely carries the 6-byte
# name AND the shipped validator accepts it -- if either failed, every
# assertion below would pass for the wrong reason (a rejected artifact
# also degrades, with a different reason this section must not launder).
R9L_VOUT=$(CLAUDE_PROJECT_DIR="$ROOT" bash "$ROOT/.claude/scripts/review-check.sh" validate-design "$ROOT/docs/specs/EPIC-R9L.md")
assert_eq "9l.0a PRECONDITION: validate-design ACCEPTS the newline-bearing declaration (ok:true -- the gate under test is the only detection point)" \
    "true" "$(json_field '.ok' "$R9L_VOUT")"
assert_eq "9l.0b PRECONDITION: the declared name is genuinely 6 characters end-to-end (trailing newline intact in the artifact)" \
    "6" "$(json_field '.unit_files.U1[0] | length' "$R9L_VOUT")"

R9L_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9L")
assert_eq "9l.1 R4-F3: a trailing-newline declared path degrades (parallel_safe=false)" \
    "false" "$(json_field '.parallel_safe' "$R9L_OUT")"
assert_eq "9l.2 R4-F3: reason names the control characters specifically" \
    "declared_path_contains_control_chars" "$(json_field '.degradation_reason' "$R9L_OUT")"
assert_contains "9l.3 R4-F3: observations name the offending declaration with the newline VISIBLE (@json-escaped), never silently stripped" \
    'U1:"alias\n"' "$(json_field '.observations' "$R9L_OUT")"

# RESTORE CONTROL: the identical shape WITHOUT the control character stays
# clean -- the gate rejects the byte class, not these filenames.
R9LSANEU1=$(u U1 "alias")
R9LSANEU2=$(u U2 "other.sh")
R9LSANEUNITS=$(units_of "$R9LSANEU1" "$R9LSANEU2")
R9LSANEDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9LSANE" "$R9LSANEUNITS" "T-R9LS-U1,T-R9LS-U2")
bind_child "$BDFIX" "T-R9LS-U1" "EPIC-R9LSANE" "U1" "$R9LSANEDH"
bind_child "$BDFIX" "T-R9LS-U2" "EPIC-R9LSANE" "U2" "$R9LSANEDH"
R9LSANE_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9LSANE")
assert_eq "9l.4 RESTORE CONTROL: the same shape without the newline stays parallel_safe=true on the SHIPPED script" \
    "true" "$(json_field '.parallel_safe' "$R9LSANE_OUT")"

# MUTANT: strip PLAN-BATCHES-CONTROL-CHAR-GATE. The 6-byte and 5-byte
# spellings are byte-distinct, so the exact-byte intersection reads them
# as disjoint and the mutant CO-BATCHES them -- two declarations of what
# collapses to one file for any tool that trims the name.
R9L_GATE_ANCHOR='declared_path_contains_control_chars'
R9L_COUNT_BEFORE=$(grep -cF "$R9L_GATE_ANCHOR" "$EG_M")
assert_contains "9l.5 NON-VACUITY: the control-char gate exists in the source before mutation (reason token present)" \
    "true" "$([ "$R9L_COUNT_BEFORE" -gt 0 ] && echo true || echo false)"
awk '
  /# PLAN-BATCHES-CONTROL-CHAR-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-CONTROL-CHAR-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9L_AWK_RC=$?
assert_eq "9l.6 NON-VACUITY: the awk strip found both sentinels" "0" "$R9L_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
bash -n "$EG_M"
assert_eq "9l.7 NON-VACUITY: the mutant still parses" "0" "$?"

R9L_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9L")
assert_eq "9l.8 SPECIFIC MISBEHAVIOUR: the gate-stripped mutant reports parallel_safe=true over the two spellings" \
    "true" "$(json_field '.parallel_safe' "$R9L_MUTANT_OUT")"
assert_eq "9l.9 SPECIFIC MISBEHAVIOUR: mutant CO-BATCHES them (byte-distinct -> disjoint under exact intersection -> one batch)" \
    "1" "$(json_field '.batches | length' "$R9L_MUTANT_OUT")"

# --- 9m: R4-F1 -- the alias-flattening's CARDINALITY is verified, not
# just its rc. A flat_pairs that SUCCEEDS (rc 0) with EMPTY or PARTIAL
# output used to run that many fewer loop bodies, never trip
# line_extract_failed, and leave the alias arrays short -- so the alias
# check silently happened over a SUBSET of the declared files (over NONE,
# in the empty case), the FIFTH instance in this slice of a failed
# computation reading as a benign empty. The shims below reproduce the
# finding's exact shapes: exit 0 printing NOTHING, and exit 0 printing one
# line fewer. The fixture is 9g's own symlinked-collision shape, so "the
# check did not happen" has a REAL collision to miss -- which is what the
# gate-stripped mutant then demonstrably misses. ---------------------------
new_fixture_root "r9m"
mkdir -p "$ROOT/real-dir"
ln -s real-dir "$ROOT/alias-dir"
R9MU1=$(u U1 "alias-dir/shared.sh")
R9MU2=$(u U2 "real-dir/shared.sh")
R9MUNITS=$(units_of "$R9MU1" "$R9MU2")
R9MDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9M" "$R9MUNITS" "T-R9M-U1,T-R9M-U2")
bind_child "$BDFIX" "T-R9M-U1" "EPIC-R9M" "U1" "$R9MDH"
bind_child "$BDFIX" "T-R9M-U2" "EPIC-R9M" "U2" "$R9MDH"

# The flatten program is the shim's WHOLE-ARGUMENT exact-match target
# (structurally immune to stranding at an earlier call whose own program
# merely CONTAINS it -- 9d's own fix); source-uniqueness asserted, not
# assumed.
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9M_FLATTEN_MARKER='to_entries[] | .key as $u | .value[] | {u:$u, f:.}'
R9M_FLATTEN_COUNT=$(grep -cF "$R9M_FLATTEN_MARKER" "$EG")
assert_eq "9m.0 PRECONDITION: the flatten program is source-unique (whole-argument matching is safe)" "1" "$R9M_FLATTEN_COUNT"

mkdir -p "$FIXTURE/r9m-shim-bin"
cat > "$FIXTURE/r9m-shim-bin/jq" <<SHIMEOF
#!/bin/bash
# R9M_EMPTY_MARKER: WHOLE-ARGUMENT exact match -> exit 0 printing NOTHING
# (the successful-but-EMPTY shape R4-F1 names).
# R9M_PARTIAL_MARKER: WHOLE-ARGUMENT exact match -> run the real jq but
# drop the LAST output line (successful-but-PARTIAL).
for a in "\$@"; do
    if [ -n "\${R9M_EMPTY_MARKER:-}" ] && [ "\$a" = "\$R9M_EMPTY_MARKER" ]; then
        exit 0
    fi
    if [ -n "\${R9M_PARTIAL_MARKER:-}" ] && [ "\$a" = "\$R9M_PARTIAL_MARKER" ]; then
        "$REAL_JQ" "\$@" | sed -e '\$d'
        exit 0
    fi
done
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/r9m-shim-bin/jq"

R9M_EMPTY_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9M_EMPTY_MARKER="$R9M_FLATTEN_MARKER" PATH="$FIXTURE/r9m-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9M")
assert_eq "9m.1 R4-F1: a successful-but-EMPTY flattening degrades on the SHIPPED script (parallel_safe=false)" \
    "false" "$(json_field '.parallel_safe' "$R9M_EMPTY_OUT")"
assert_eq "9m.2 R4-F1: ...names set_computation_failed, never 'nothing to check'" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9M_EMPTY_OUT")"
assert_contains "9m.3 R4-F1: observations carry the cardinality arithmetic (0 of 2 declared pairs)" \
    "0 of 2" "$(json_field '.observations' "$R9M_EMPTY_OUT")"

R9M_PARTIAL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9M_PARTIAL_MARKER="$R9M_FLATTEN_MARKER" PATH="$FIXTURE/r9m-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9M")
assert_eq "9m.4 R4-F1: a successful-but-PARTIAL flattening ALSO degrades (set_computation_failed)" \
    "set_computation_failed" "$(json_field '.degradation_reason' "$R9M_PARTIAL_OUT")"
assert_contains "9m.5 R4-F1: observations carry the partial arithmetic (1 of 2 declared pairs)" \
    "1 of 2" "$(json_field '.observations' "$R9M_PARTIAL_OUT")"

# RESTORE CONTROL: unshimmed, the same fixture flows the full pair set
# into the alias pass, which catches the symlinked collision -- proving
# the data path the cardinality gate protects genuinely feeds the check.
R9M_CLEAN_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9M")
assert_eq "9m.6 RESTORE CONTROL: unshimmed, the SHIPPED script catches the real symlinked collision (declared_path_traverses_symlink)" \
    "declared_path_traverses_symlink" "$(json_field '.degradation_reason' "$R9M_CLEAN_OUT")"

# MUTANT: strip PLAN-BATCHES-ALIAS-CARDINALITY-GATE and induce the SAME
# empty flattening. The alias check silently does not happen and the
# symlinked collision CO-BATCHES -- R4-F1's exact named danger.
R9M_GATE_ANCHOR='the alias-check flattening produced'
R9M_GATE_COUNT_BEFORE=$(grep -cF "$R9M_GATE_ANCHOR" "$EG_M")
assert_eq "9m.7 NON-VACUITY: the cardinality gate existed exactly once before mutation" "1" "$R9M_GATE_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-ALIAS-CARDINALITY-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-ALIAS-CARDINALITY-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9M_AWK_RC=$?
assert_eq "9m.8 NON-VACUITY: the awk strip found both sentinels" "0" "$R9M_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9M_GATE_COUNT_AFTER=$(grep -cF "$R9M_GATE_ANCHOR" "$EG_M")
assert_eq "9m.9 NON-VACUITY: the cardinality gate is GONE from the mutant" "0" "$R9M_GATE_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9m.10 NON-VACUITY: the mutant still parses" "0" "$?"

R9M_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9M_EMPTY_MARKER="$R9M_FLATTEN_MARKER" PATH="$FIXTURE/r9m-shim-bin:$PATH" bash "$EG_M" plan-batches "EPIC-R9M")
assert_eq "9m.11 SPECIFIC MISBEHAVIOUR: gate-stripped mutant + empty flattening -> parallel_safe=true (the alias check silently did not happen)" \
    "true" "$(json_field '.parallel_safe' "$R9M_MUTANT_OUT")"
assert_eq "9m.12 SPECIFIC MISBEHAVIOUR: the symlinked collision CO-BATCHES (one batch) -- the exact aliased-units-co-batch danger R4-F1 names" \
    "1" "$(json_field '.batches | length' "$R9M_MUTANT_OUT")"

# --- 9n: R4-F4/R4-F5/R4-F8 -- _pb_degrade itself is fail-closed and is
# exercised WITH CHILDREN under induced jq failures. R4-F4: the old body
# had four unguarded jq assignments under set -e, so a jq failure exited
# the script BEFORE _pb_finish -- the safety net emitted NOTHING. R4-F5:
# on a topological-computation failure the old body fell back to lexical
# id order, emitting T-A-DEPENDENT's batch before T-Z-PREREQ's over a
# KNOWN edge. R4-F8: 9h's broken-jq control cannot see either (zero
# children -- see 9h's own scope note). The rework collapsed the degrade
# path's seven jq call sites to TWO (the schedule construction and the
# .batches extraction); this section injects a failure into EACH
# independently (9d's marker technique), against a fixture with real
# children and a real KNOWN dependency edge, and asserts the fail-closed
# refusal: exit 0, a full envelope, the ORIGINAL degradation_reason
# preserved, batches=[] (never a lexical order over the known edge), and
# the annotated observations. The fixture is 9j's own shape: two children
# bind cleanly with a dependency between them (ids chosen so lexical
# order is WRONG: T-A-DEPENDENT < T-Z-PREREQ), and an unbound third child
# forces the degrade at the CHILD-BINDING-GATE, where bindings are
# already published (R3-F3). ------------------------------------------------
new_fixture_root "r9n"
R9NU1=$(u U-prereq "p.sh")
R9NU2=$(u U-dependent "d.sh" "U-prereq")
R9NUNITS=$(units_of "$R9NU1" "$R9NU2")
R9NDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9N" "$R9NUNITS" "T-A-DEPENDENT,T-UNBOUND-THIRD,T-Z-PREREQ")
bind_child "$BDFIX" "T-Z-PREREQ" "EPIC-R9N" "U-prereq" "$R9NDH"
bind_child "$BDFIX" "T-A-DEPENDENT" "EPIC-R9N" "U-dependent" "$R9NDH"
unbound_child "$BDFIX" "T-UNBOUND-THIRD"

# Marker preconditions. Both programs are LONG (a shim argument can never
# EQUAL a short marker of either), so both markers are SUBSTRINGS
# independently proven source-unique: the construction's own refusal
# token, and (round 5 — R5-F6 rewrote the extraction into a validating
# filter, so the old whole-argument marker no longer exists) a clause of
# the extraction's multiset validation.
R9N_SCHED_MARKER='degrade_input_cardinality'
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9N_EXTRACT_MARKER='map(.[0].task_id)'
R9N_SCHED_COUNT=$(grep -cF "$R9N_SCHED_MARKER" "$EG")
R9N_EXTRACT_COUNT=$(grep -cF "$R9N_EXTRACT_MARKER" "$EG")
assert_eq "9n.0a PRECONDITION: the schedule-construction marker is source-unique (substring matching cannot strand)" "1" "$R9N_SCHED_COUNT"
assert_eq "9n.0b PRECONDITION: the extraction-validation marker is source-unique (substring matching cannot strand)" "1" "$R9N_EXTRACT_COUNT"

mkdir -p "$FIXTURE/r9n-shim-bin"
cat > "$FIXTURE/r9n-shim-bin/jq" <<SHIMEOF
#!/bin/bash
# R9N_FAIL_MARKER: whole-argument exact match -> exit 1.
# R9N_FAIL_SUBSTRING: substring match (markers proven source-unique in
# 9n.0a/9n.0b) -> exit 1.
# R9N_EMPTYSCHED_SUBSTRING: substring match -> print R5-F6's exact probe
# ({"ok":true,"batches":[]}) and exit 0 -- the successful-but-empty
# construction shape. Every unmatched call runs the real jq, so the
# validating extraction downstream is genuinely exercised.
for a in "\$@"; do
    if [ -n "\${R9N_FAIL_MARKER:-}" ] && [ "\$a" = "\$R9N_FAIL_MARKER" ]; then
        exit 1
    fi
    if [ -n "\${R9N_FAIL_SUBSTRING:-}" ]; then
        case "\$a" in
            *"\$R9N_FAIL_SUBSTRING"*) exit 1 ;;
        esac
    fi
    if [ -n "\${R9N_EMPTYSCHED_SUBSTRING:-}" ]; then
        case "\$a" in
            *"\$R9N_EMPTYSCHED_SUBSTRING"*) printf '{"ok":true,"batches":[]}\n'; exit 0 ;;
        esac
    fi
done
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/r9n-shim-bin/jq"

# Control first: no injection. The degrade computes the COMPLETE
# 3-singleton schedule in topological order.
R9N_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9N")
assert_eq "9n.1 RESTORE CONTROL: the fixture degrades for the unbound third child (design_unit_binding_missing)" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$R9N_CONTROL_OUT")"
assert_eq "9n.2 RESTORE CONTROL: uninjected, the SHIPPED script emits the complete serial schedule (3 singleton batches)" \
    "3" "$(json_field '.batches | length' "$R9N_CONTROL_OUT")"
R9N_C_PREREQ_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-Z-PREREQ")] | index(true)' "$R9N_CONTROL_OUT")
R9N_C_DEPENDENT_IDX=$(json_field '[.batches[] | any(.[]; .task_id=="T-A-DEPENDENT")] | index(true)' "$R9N_CONTROL_OUT")
if [ "$R9N_C_PREREQ_IDX" -lt "$R9N_C_DEPENDENT_IDX" ] 2>/dev/null; then R9N_C_ORDER_OK="true"; else R9N_C_ORDER_OK="false"; fi
assert_eq "9n.3 RESTORE CONTROL: ...in topological order (T-Z-PREREQ before T-A-DEPENDENT)" \
    "true" "$R9N_C_ORDER_OK"

# Injection A: the schedule construction itself fails.
R9N_A_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9N_FAIL_SUBSTRING="$R9N_SCHED_MARKER" PATH="$FIXTURE/r9n-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9N" 2>&1)
R9N_A_RC=$?
assert_eq "9n.4 R4-F4: an induced schedule-construction failure still exits 0 (the failure reaches _pb_finish, never a set -e death)" \
    "0" "$R9N_A_RC"
assert_eq "9n.5 R4-F4: ...and still emits a FULL envelope (stdout parses as an object; the old unguarded shape emitted NOTHING)" \
    "true" "$(printf '%s' "$R9N_A_OUT" | "$REAL_JQ" -e 'type=="object"' >/dev/null 2>&1 && echo true || echo false)"
assert_eq "9n.6 R4-F4: parallel_safe stays false" "false" "$(json_field '.parallel_safe' "$R9N_A_OUT")"
assert_eq "9n.7 R4-F5: the ORIGINAL degradation_reason is preserved (the root cause stays actionable)" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$R9N_A_OUT")"
assert_eq "9n.8 R4-F5: batches is [] -- NEVER the lexical 3-batch order that would place T-A-DEPENDENT before its own prerequisite over a KNOWN edge" \
    "0" "$(json_field '.batches | length' "$R9N_A_OUT")"
assert_contains "9n.9 R4-F5: observations carry the refusal annotation" \
    "refused rather than emitted" "$(json_field '.observations' "$R9N_A_OUT")"
assert_contains "9n.10 R4-F5: observations still carry the original root-cause detail alongside the annotation" \
    "has no DESIGN-UNIT v1 binding" "$(json_field '.observations' "$R9N_A_OUT")"
assert_contains "9n.11 R4-F4: the annotation names WHICH step failed (schedule rc=1)" \
    "(schedule rc=1" "$(json_field '.observations' "$R9N_A_OUT")"

# Injection B: the .batches extraction fails (the schedule computed fine).
R9N_B_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9N_FAIL_SUBSTRING="$R9N_EXTRACT_MARKER" PATH="$FIXTURE/r9n-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9N" 2>&1)
R9N_B_RC=$?
assert_eq "9n.12 R4-F4: an induced extraction failure also exits 0 with a full envelope" \
    "0" "$R9N_B_RC"
assert_eq "9n.13 R4-F4/R4-F5: extraction failure also refuses (batches=[])" \
    "0" "$(json_field '.batches | length' "$R9N_B_OUT")"
assert_contains "9n.14 R4-F4: the annotation names the extraction step specifically (extraction rc=1)" \
    "extraction rc=1" "$(json_field '.observations' "$R9N_B_OUT")"
assert_eq "9n.15 R4-F5: the original reason survives the extraction failure too" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$R9N_B_OUT")"

# Injection C (round 5, R5-F6): the construction SUCCEEDS with an empty
# schedule -- rc 0, {"ok":true,"batches":[]} (the reviewer's exact probe)
# -- over a fixture with 3 real children. The old extraction accepted any
# nonempty ok:true/array text, so this shape was assigned as the schedule
# with NO refusal annotation; the validating extraction (real jq, via the
# shim's passthrough) must now refuse it on cardinality (-e empty output,
# rc 4) and annotate.
R9N_C_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9N_EMPTYSCHED_SUBSTRING="$R9N_SCHED_MARKER" PATH="$FIXTURE/r9n-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9N" 2>&1)
R9N_C_RC=$?
assert_eq "9n.16 R5-F6: a successful-but-EMPTY construction still exits 0 with the original reason preserved" \
    "0|design_unit_binding_missing" "$R9N_C_RC|$(json_field '.degradation_reason' "$R9N_C_OUT")"
assert_eq "9n.17 R5-F6: batches stays [] (the empty schedule is REFUSED, not adopted)" \
    "0" "$(json_field '.batches | length' "$R9N_C_OUT")"
assert_contains "9n.18 R5-F6: observations carry the refusal annotation (before this fix the empty schedule was accepted silently, with no annotation at all)" \
    "refused rather than emitted" "$(json_field '.observations' "$R9N_C_OUT")"
assert_contains "9n.19 R5-F6: the annotation names the validating extraction's refusal specifically (rc 4 = -e with empty output)" \
    "extraction rc=4" "$(json_field '.observations' "$R9N_C_OUT")"

# MUTANT (paired for R5-F6): strip the PLAN-BATCHES-SCHED-SHAPE-GATE
# jq-comment sentinel INSIDE the extraction filter, reverting it to the
# round-4 acceptance (any ok:true object with an array .batches). The
# fixture root r9n's own EG_M copy is mutated; $EG stays shipped.
R9N_SHAPE_COUNT_BEFORE=$(grep -cF "$R9N_EXTRACT_MARKER" "$EG_M")
assert_eq "9n.20 NON-VACUITY: the extraction-validation clause existed exactly once before mutation" "1" "$R9N_SHAPE_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-SCHED-SHAPE-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-SCHED-SHAPE-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9N_SHAPE_AWK_RC=$?
assert_eq "9n.21 NON-VACUITY: the awk strip found both sentinels (inside the jq program text)" "0" "$R9N_SHAPE_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9N_SHAPE_COUNT_AFTER=$(grep -cF "$R9N_EXTRACT_MARKER" "$EG_M")
assert_eq "9n.22 NON-VACUITY: the validation clause is GONE from the mutant" "0" "$R9N_SHAPE_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9n.23 NON-VACUITY: the mutant still parses (the strip removes whole lines inside the single-quoted jq program, leaving it compilable)" "0" "$?"

R9N_C_MUT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9N_EMPTYSCHED_SUBSTRING="$R9N_SCHED_MARKER" PATH="$FIXTURE/r9n-shim-bin:$PATH" bash "$EG_M" plan-batches "EPIC-R9N" 2>&1)
R9N_C_MUT_RC=$?
assert_eq "9n.24 mutant sanity: still exits 0 with the original reason and an (empty) batches array" \
    "0|design_unit_binding_missing|0" "$R9N_C_MUT_RC|$(json_field '.degradation_reason' "$R9N_C_MUT_OUT")|$(json_field '.batches | length' "$R9N_C_MUT_OUT")"
R9N_C_MUT_ANNOT=$(printf '%s' "$(json_field '.observations' "$R9N_C_MUT_OUT")" | grep -cF "refused rather than emitted")
assert_eq "9n.25 SPECIFIC MISBEHAVIOUR: the validation-stripped mutant ACCEPTS the empty schedule as computed -- the refusal annotation is ABSENT, so 3 children silently have no schedule and nothing says so (R5-F6's exact named defect)" \
    "0" "$R9N_C_MUT_ANNOT"


# ===========================================================================
printf '\n=== Section 9 continued: round-5 findings (xsu1-r5) ===\n'
# ===========================================================================

# --- 9o: R5-F1 (status half) -- the design-status shape gate requires
# EXACT TYPES, never mere presence. satisfied:"true" (a JSON STRING) used
# to pass has("satisfied") and then satisfy the textual jq -r comparison,
# pushing the run past a gate whose source never said boolean-true. The
# fixture epic below is genuinely UNREVIEWED (a DESIGN-ARTIFACT comment
# but NO DESIGN-REVIEW), so a run that trusts the lying stub sails to a
# full clean plan over a design no reviewer ever accepted -- the sharpest
# available misbehaviour for the mutant leg. The stub delegates every
# OTHER subcommand (design-unit-show) to the real fixture copy, so the
# run past the lie stays otherwise genuine. -------------------------------
new_fixture_root "r9o"
R9OU1=$(u U1 "a9o.sh")
R9OUNITS=$(units_of "$R9OU1")
R9O_APATH="$ROOT/docs/specs/EPIC-R9O.md"
write_artifact "$R9O_APATH" "EPIC-R9O" "$R9OUNITS"
R9ODH=$(design_hash_of "$WFM_M" "$R9O_APATH")
R9O_C1="DESIGN-ARTIFACT v1 task=EPIC-R9O designer=designer design_hash=$R9ODH units=1 at 2026-01-01T00:00:00Z: seeded"
# shellcheck disable=SC2016
bd_fixture_write "$BDFIX" "EPIC-R9O" \
    "$("$REAL_JQ" -nc '[{id:"T-R9O", dependency_type:"parent-child"}]')" \
    "$("$REAL_JQ" -nc --arg a "$R9O_C1" '[$a]')"
bind_child "$BDFIX" "T-R9O" "EPIC-R9O" "U1" "$R9ODH"

# Negative control (real qa-gate): the REAL boolean-typed envelope passes
# the strict gate and the run degrades on the real verdict (unreviewed
# design), NOT on design_status_unavailable -- proving the type
# tightening reads a healthy envelope, it does not over-refuse it.
R9O_CTRL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9O")
R9O_CTRL_REASON=$(json_field '.degradation_reason' "$R9O_CTRL_OUT")
R9O_CTRL_OK="false"
[ -n "$R9O_CTRL_REASON" ] && [ "$R9O_CTRL_REASON" != "design_status_unavailable" ] && R9O_CTRL_OK="true"
assert_eq "9o.1 RESTORE CONTROL: the real design-status envelope passes the strict type gate (degrades on the real unreviewed-design verdict '$R9O_CTRL_REASON', not design_status_unavailable)" \
    "false|true" "$(json_field '.parallel_safe' "$R9O_CTRL_OUT")|$R9O_CTRL_OK"

cp "$ROOT/.claude/scripts/qa-gate.sh" "$ROOT/.claude/scripts/qa-gate-real.sh"
cat > "$ROOT/.claude/scripts/qa-gate.sh" <<R9OSTUB
#!/bin/bash
# 9o lying-status stub: satisfied is the JSON STRING "true" (R5-F1's
# exact probe); every other field is present with its real type, the
# design_hash is the artifact's REAL hash, ok:true, exit 0 -- so the ONLY
# malformation is the satisfied type, and the run past this gate stays
# otherwise genuine (design-unit-show delegates to the real copy).
if [ "\${1:-}" = "design-status" ]; then
    printf '%s\n' '{"ok":true,"subcommand":"design-status","task_id":"EPIC-R9O","satisfied":"true","error_key":"","observations":"stub: satisfied is a STRING, not a boolean","design_hash":"$R9ODH","artifact_path":"$ROOT/docs/specs/EPIC-R9O.md"}'
    exit 0
fi
exec bash "$ROOT/.claude/scripts/qa-gate-real.sh" "\$@"
R9OSTUB
chmod 0755 "$ROOT/.claude/scripts/qa-gate.sh"

R9O_LIE_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9O")
assert_eq "9o.2 R5-F1: the SHIPPED script refuses the string-typed satisfied (parallel_safe=false)" \
    "false" "$(json_field '.parallel_safe' "$R9O_LIE_OUT")"
assert_eq "9o.3 R5-F1: reason is design_status_unavailable (a wrong-typed field is not-well-formed, never read as its textual rendering)" \
    "design_status_unavailable" "$(json_field '.degradation_reason' "$R9O_LIE_OUT")"

# MUTANT: revert the status gate to its round-4 presence-only form (awk
# exact-line replacement, 9k's ENVIRON technique) and prove the type arm
# is load-bearing: the mutant trusts the string, sails past design-status
# and computes a FULL CLEAN PLAN over a design that was never reviewed.
# shellcheck disable=SC2016  # intentional non-interpolating literals, matched against source below
R9O_NEW_LINE='    if printf '"'"'%s'"'"' "$status_json" | jq -e '"'"'type=="object" and (.satisfied|type)=="boolean" and (.error_key|type)=="string" and (.design_hash|type)=="string" and (.artifact_path|type)=="string"'"'"' >/dev/null 2>&1; then'
# shellcheck disable=SC2016
R9O_OLD_LINE='    if printf '"'"'%s'"'"' "$status_json" | jq -e '"'"'type=="object" and has("satisfied") and has("error_key") and has("design_hash") and has("artifact_path")'"'"' >/dev/null 2>&1; then'
R9O_COUNT_BEFORE=$(grep -cF "$R9O_NEW_LINE" "$EG_M")
assert_eq "9o.4 NON-VACUITY: the strict-type status gate line existed exactly once before mutation" "1" "$R9O_COUNT_BEFORE"
OLD_LINE="$R9O_NEW_LINE" NEW_LINE="$R9O_OLD_LINE" awk '
  { if ($0 == ENVIRON["OLD_LINE"]) { print ENVIRON["NEW_LINE"]; n++ } else print }
  END { if (n != 1) exit 7 }
' "$EG_M" > "$EG_M.replaced"
R9O_AWK_RC=$?
assert_eq "9o.5 NON-VACUITY: the awk exact-line replacement landed exactly once" "0" "$R9O_AWK_RC"
mv "$EG_M.replaced" "$EG_M"
chmod 0755 "$EG_M"
bash -n "$EG_M"
assert_eq "9o.6 NON-VACUITY: the mutant still parses" "0" "$?"

R9O_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9O")
assert_eq "9o.7 SPECIFIC MISBEHAVIOUR: the presence-only mutant trusts satisfied:\"true\" -> parallel_safe=true over a NEVER-REVIEWED design" \
    "true" "$(json_field '.parallel_safe' "$R9O_MUTANT_OUT")"
assert_eq "9o.8 SPECIFIC MISBEHAVIOUR: ...and computes a full batch plan from it (1 real batch)" \
    "1" "$(json_field '.batches | length' "$R9O_MUTANT_OUT")"

# --- 9p: R5-F1 (validator half) -- same class, sharper payload: the
# validate-design shape gate must require .ok to be a real boolean,
# because ok:"true" plus REAL-typed unit data is exactly "a malformed
# validator supplies usable unit data and reaches parallel_safe=true"
# (the finding's own words). The stub isolates the ok type: unit_ids/
# unit_files/unit_deps all carry their genuine types and the fixture's
# genuine content, ok is the ONLY string-typed field, and the stub exits
# 0 so the rc arm (9k's own guard) cannot mask the type arm under test. --
new_fixture_root "r9p"
R9PU1=$(u U1 "a9p.sh")
R9PUNITS=$(units_of "$R9PU1")
R9PDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9P" "$R9PUNITS" "T-R9P")
bind_child "$BDFIX" "T-R9P" "EPIC-R9P" "U1" "$R9PDH"

# Negative control (real validator): clean plan.
R9P_CTRL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9P")
assert_eq "9p.1 RESTORE CONTROL: with the real validator this fixture computes a clean plan (parallel_safe=true) -- the strict gate does not over-refuse a genuine boolean" \
    "true" "$(json_field '.parallel_safe' "$R9P_CTRL_OUT")"

cat > "$ROOT/.claude/scripts/review-check.sh" <<'R9PSTUB'
#!/bin/bash
# 9p lying-validator stub: ok is the JSON STRING "true"; every other
# field carries its real type and this fixture's real content; exit 0.
printf '%s\n' '{"ok":"true","subcommand":"validate-design","error_key":"","observations":"stub: ok is a JSON STRING","units":1,"unit_ids":["U1"],"task_id":"EPIC-R9P","unit_files":{"U1":["a9p.sh"]},"unit_deps":{"U1":[]}}'
exit 0
R9PSTUB
chmod 0755 "$ROOT/.claude/scripts/review-check.sh"

R9P_LIE_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9P")
assert_eq "9p.2 R5-F1: the SHIPPED script refuses the string-typed ok (parallel_safe=false)" \
    "false" "$(json_field '.parallel_safe' "$R9P_LIE_OUT")"
assert_eq "9p.3 R5-F1: reason is validate_design_unavailable" \
    "validate_design_unavailable" "$(json_field '.degradation_reason' "$R9P_LIE_OUT")"

# MUTANT: revert the validator gate to presence-only and watch the
# malformed validator's unit data be USED: full clean plan, one batch.
# shellcheck disable=SC2016  # intentional non-interpolating literals, matched against source below
R9P_NEW_LINE='    if printf '"'"'%s'"'"' "$vout" | jq -e '"'"'type=="object" and (.ok|type)=="boolean" and (.unit_ids|type)=="array" and (.unit_files|type)=="object" and (.unit_deps|type)=="object"'"'"' >/dev/null 2>&1; then'
# shellcheck disable=SC2016
R9P_OLD_LINE='    if printf '"'"'%s'"'"' "$vout" | jq -e '"'"'type=="object" and has("ok") and has("unit_ids") and has("unit_files") and has("unit_deps")'"'"' >/dev/null 2>&1; then'
R9P_COUNT_BEFORE=$(grep -cF "$R9P_NEW_LINE" "$EG_M")
assert_eq "9p.4 NON-VACUITY: the strict-type validator gate line existed exactly once before mutation" "1" "$R9P_COUNT_BEFORE"
OLD_LINE="$R9P_NEW_LINE" NEW_LINE="$R9P_OLD_LINE" awk '
  { if ($0 == ENVIRON["OLD_LINE"]) { print ENVIRON["NEW_LINE"]; n++ } else print }
  END { if (n != 1) exit 7 }
' "$EG_M" > "$EG_M.replaced"
R9P_AWK_RC=$?
assert_eq "9p.5 NON-VACUITY: the awk exact-line replacement landed exactly once" "0" "$R9P_AWK_RC"
mv "$EG_M.replaced" "$EG_M"
chmod 0755 "$EG_M"
bash -n "$EG_M"
assert_eq "9p.6 NON-VACUITY: the mutant still parses" "0" "$?"

R9P_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9P")
assert_eq "9p.7 SPECIFIC MISBEHAVIOUR: the presence-only mutant reads ok:\"true\" as success and USES the malformed validator's unit data -> parallel_safe=true" \
    "true" "$(json_field '.parallel_safe' "$R9P_MUTANT_OUT")"
assert_eq "9p.8 SPECIFIC MISBEHAVIOUR: ...reaching a full batch plan (1 real batch) supplied by a validator that never spoke boolean" \
    "1" "$(json_field '.batches | length' "$R9P_MUTANT_OUT")"

# --- 9q: the R5-F4 interior refusal site, probed directly (Section 8's
# own convention: a direct against-the-shipped-script probe, NO mutant,
# for a guard with redundant downstream backups -- verified during this
# round's development: with the encode guard stripped, the empty/garbage
# pairs value still fails --argjson in the multibind check and then in
# the degrade construction itself, so a strip degrades safely through
# two more layers rather than misbehaving sharply; what only THIS site
# provides is the SPECIFIC refusal shape below). The (unit_id, task_id)
# pair encoding is the ONE call site left between the dependency publish
# and the bindings publish; if it fails, the bindings were READ but
# cannot be FED to the degraded-schedule construction, so the degrade
# must pass NO child ids -- batches [] with an explanatory observation
# -- because a serial order computed without the read bindings could
# contradict the fixture's real U-dependent -> U-prereq edge. Fixture
# and shim are 9n's own (r9n root, uninjected control pinned at
# 9n.2/9n.3). ------------------------------------------------------------
# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9Q_PAIRS_MARKER='task_id: $lines[2*.+1]'
R9Q_PAIRS_COUNT=$(grep -cF "$R9Q_PAIRS_MARKER" "$EG")
assert_eq "9q.0 PRECONDITION: the pair-encoding marker is source-unique (substring matching cannot strand)" "1" "$R9Q_PAIRS_COUNT"

# Explicit r9n paths: $ROOT/$BDFIX point at 9p's root (and its lying
# validator stub) by the time this section runs.
R9Q_ROOT="$FIXTURE/roots/r9n"
R9Q_BDFIX="$R9Q_ROOT/bd-fixture"

R9Q_SANE_OUT=$(CLAUDE_PROJECT_DIR="$R9Q_ROOT" BD_FIXTURE_DIR="$R9Q_BDFIX" bash "$EG" plan-batches "EPIC-R9N")
assert_eq "9q.1 RESTORE CONTROL: uninjected, the identical fixture still yields the complete 3-singleton schedule" \
    "3" "$(json_field '.batches | length' "$R9Q_SANE_OUT")"

R9Q_OUT=$(CLAUDE_PROJECT_DIR="$R9Q_ROOT" BD_FIXTURE_DIR="$R9Q_BDFIX" R9N_FAIL_SUBSTRING="$R9Q_PAIRS_MARKER" PATH="$FIXTURE/r9n-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9N" 2>&1)
R9Q_RC=$?
assert_eq "9q.2 R5-F4 interior site: an induced pair-encoding failure still exits 0 with a full envelope (reason set_computation_failed)" \
    "0|set_computation_failed" "$R9Q_RC|$(json_field '.degradation_reason' "$R9Q_OUT")"
assert_eq "9q.3 R5-F4 interior site: NO serial schedule is emitted (batches=[]) -- the bindings were read but could not be fed, so an order that could contradict the fixture's real edge is refused outright" \
    "0" "$(json_field '.batches | length' "$R9Q_OUT")"
assert_contains "9q.4 R5-F4 interior site: the observation says exactly that, instead of leaving an unexplained empty schedule" \
    "could not be fed to the degraded-schedule construction" "$(json_field '.observations' "$R9Q_OUT")"


# ===========================================================================
printf '\n=== Section 9 continued: round-7 findings (xsu1-r7) ===\n'
# ===========================================================================

# --- 9r: R7-F1 -- a BOUND dependent whose PREREQUISITE unit has no bound
# implementing task. Nothing exercised this shape before round 7: 9j/9n
# bind BOTH ends of their real edge and leave only an unrelated third
# child unbound, which is exactly why round 6's partial-mapping claim
# survived them. Here the design records U-dependent -> U-prereq,
# T-A-DEPENDENT is bound to U-dependent, and T-Z-PREREQ is left UNBOUND:
# the round-6 construction's // empty lookup ERASED the edge (the round-7
# reviewer's own probe) and emitted T-A-DEPENDENT first in sorted order
# -- runnable, before the task that would implement its prerequisite,
# over an edge the design records. The shipped script now refuses; the
# mutant strips the resolve clauses (a jq-comment sentinel inside the
# construction, round 5's SCHED-SHAPE-GATE technique) and reproduces the
# reviewer's hazard verbatim. ----------------------------------------------
new_fixture_root "r7f1"
R9RU1=$(u U-prereq "p9r.sh")
R9RU2=$(u U-dependent "d9r.sh" "U-prereq")
R9RUNITS=$(units_of "$R9RU1" "$R9RU2")
R9RDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9R" "$R9RUNITS" "T-A-DEPENDENT,T-Z-PREREQ")
bind_child "$BDFIX" "T-A-DEPENDENT" "EPIC-R9R" "U-dependent" "$R9RDH"
unbound_child "$BDFIX" "T-Z-PREREQ"

R9R_CONTROL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9R")
assert_eq "9r.1 R7-F1: the fixture degrades on the unbound prerequisite (design_unit_binding_missing preserved as the root cause)" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$R9R_CONTROL_OUT")"
assert_eq "9r.2 R7-F1: the SHIPPED script emits NO schedule (batches=[]) -- the bound dependent's design edge cannot be resolved to a bound task, and erasing it would read a failed resolution as 'no constraint'" \
    "0" "$(json_field '.batches | length' "$R9R_CONTROL_OUT")"
assert_contains "9r.3 R7-F1: observations carry the refusal annotation" \
    "refused rather than emitted" "$(json_field '.observations' "$R9R_CONTROL_OUT")"
assert_contains "9r.4 R7-F1: the refusal is the construction's own (validating extraction rc 4 on the ok:false result), not a crash" \
    "extraction rc=4" "$(json_field '.observations' "$R9R_CONTROL_OUT")"

# NON-VACUITY + MUTANT. The anchor is the resolve lookup only the gate
# performs -- the reduce deliberately keeps its // empty spelling, so the
# two are textually distinct and the anchor cannot strand there.
# shellcheck disable=SC2016
R9R_ANCHOR='($u2t[.] // null) == null'
R9R_COUNT_BEFORE=$(grep -cF "$R9R_ANCHOR" "$EG_M")
assert_eq "9r.5 NON-VACUITY: the resolve clause existed exactly once before mutation" "1" "$R9R_COUNT_BEFORE"
awk '
  /# PLAN-BATCHES-DEGRADE-DEP-RESOLVE-GATE BEGIN/ { found_begin=1; skip=1; next }
  /# PLAN-BATCHES-DEGRADE-DEP-RESOLVE-GATE END/   { found_end=1; skip=0; next }
  !skip { print }
  END { if (!found_begin || !found_end) exit 7 }
' "$EG_M" > "$EG_M.stripped"
R9R_AWK_RC=$?
assert_eq "9r.6 NON-VACUITY: the awk strip found both sentinels (inside the jq program text)" "0" "$R9R_AWK_RC"
mv "$EG_M.stripped" "$EG_M"
chmod 0755 "$EG_M"
R9R_COUNT_AFTER=$(grep -cF "$R9R_ANCHOR" "$EG_M")
assert_eq "9r.7 NON-VACUITY: the resolve clause is GONE from the mutant" "0" "$R9R_COUNT_AFTER"
bash -n "$EG_M"
assert_eq "9r.8 NON-VACUITY: the mutant still parses" "0" "$?"

R9R_MUTANT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG_M" plan-batches "EPIC-R9R")
assert_eq "9r.9 mutant sanity: still degrades with the root-cause reason (the gate is a schedule refusal, not a safety flag)" \
    "design_unit_binding_missing" "$(json_field '.degradation_reason' "$R9R_MUTANT_OUT")"
R9R_M_FIRST=$(json_field '.batches[0][0].task_id' "$R9R_MUTANT_OUT")
assert_eq "9r.10 SPECIFIC MISBEHAVIOUR: the resolve-stripped mutant emits the DEPENDENT first (2 batches, T-A-DEPENDENT's before its own unbound prerequisite's) -- the round-7 reviewer's reproduced hazard: a known design edge erased because its task could not be resolved" \
    "2|T-A-DEPENDENT" "$(json_field '.batches | length' "$R9R_MUTANT_OUT")|$R9R_M_FIRST"

# --- 9s: R7-F3 -- the three PROBED rc-0-wrong-shape cases, and ONLY
# those (the general guarded-envelope form for every safety computation
# is deferred to claude-workflow-plugin-uopo by operator decision). Each
# leg injects the reviewer's exact probe output at the exact call site
# via a marker-targeted shim (real jq for every other call) and asserts
# the shipped script refuses where the round-6 script read the lie as a
# clean answer. Direct against-the-shipped-script probes, no mutants:
# (1)'s decision is now jq-free bash cardinality (nothing left to lie
# to), and (2)/(3) are one-clause widenings of existing guarded gates
# whose pre-fix acceptance the negative-control run over the round-6
# script demonstrates. -----------------------------------------------------
new_fixture_root "r7f3"
R9SU1=$(u U1 "a9s.sh")
R9SU2=$(u U2 "b9s.sh")
R9SUNITS=$(units_of "$R9SU1" "$R9SU2")
R9SDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9S" "$R9SUNITS" "T-R9S-A,T-R9S-B")
bind_child "$BDFIX" "T-R9S-A" "EPIC-R9S" "U1" "$R9SDH"
bind_child "$BDFIX" "T-R9S-B" "EPIC-R9S" "U2" "$R9SDH"

R9S_CLEAN_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9S")
assert_eq "9s.0 RESTORE CONTROL: uninjected, two disjoint no-dep units compute a clean plan (parallel_safe=true, one 2-member batch)" \
    "true|1" "$(json_field '.parallel_safe' "$R9S_CLEAN_OUT")|$(json_field '.batches | length' "$R9S_CLEAN_OUT")"

# Markers: each proven source-unique, each a substring of exactly the
# program it names.
# shellcheck disable=SC2016
R9S_BATCH_MARKER='as $min_start'
# shellcheck disable=SC2016
R9S_INPUTS_MARKER='{ r: $r, unresolved: $unresolved, blocked: $blocked, ud_r: $ud_r }'
R9S_DUPDETAIL_MARKER='group_by(.unit_id)'
assert_eq "9s.0a PRECONDITION: batching-program marker source-unique" "1" "$(grep -cF "$R9S_BATCH_MARKER" "$EG")"
assert_eq "9s.0b PRECONDITION: batching-inputs marker source-unique" "1" "$(grep -cF "$R9S_INPUTS_MARKER" "$EG")"
assert_eq "9s.0c PRECONDITION: dup-detail marker source-unique (the multiply-bound DECISION itself no longer contains a jq call to target -- R7-F3(1))" "1" "$(grep -cF "$R9S_DUPDETAIL_MARKER" "$EG")"

mkdir -p "$FIXTURE/r9s-shim-bin"
cat > "$FIXTURE/r9s-shim-bin/jq" <<SHIMEOF
#!/bin/bash
# R9S_LIE_SUBSTRING + R9S_LIE_OUTPUT: when any argument contains the
# marker, print the canned lie and exit 0; every other call runs the
# real jq. Reproduces R7-F3's exact probes (rc-0 wrong-shape output).
if [ -n "\${R9S_LIE_SUBSTRING:-}" ]; then
    for a in "\$@"; do
        case "\$a" in
            *"\$R9S_LIE_SUBSTRING"*) printf '%s\n' "\$R9S_LIE_OUTPUT"; exit 0 ;;
        esac
    done
fi
exec "$REAL_JQ" "\$@"
SHIMEOF
chmod +x "$FIXTURE/r9s-shim-bin/jq"

# (2) the batching computation lies {ok:true,batches:[]} over 2 real units.
R9S_BATCH_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9S_LIE_SUBSTRING="$R9S_BATCH_MARKER" R9S_LIE_OUTPUT='{"ok":true,"batches":[]}' PATH="$FIXTURE/r9s-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9S" 2>&1)
assert_eq "9s.1 R7-F3(2): an rc-0 {ok:true,batches:[]} batching result is REFUSED (flattened-member multiset vs R) -> set_computation_failed, never parallel_safe=true with every unit silently dropped" \
    "false|set_computation_failed" "$(json_field '.parallel_safe' "$R9S_BATCH_OUT")|$(json_field '.degradation_reason' "$R9S_BATCH_OUT")"
assert_eq "9s.2 R7-F3(2): the degrade still emits the serial schedule (2 singleton batches -- child ids and a safe order are both available at this site)" \
    "2" "$(json_field '.batches | length' "$R9S_BATCH_OUT")"

# (3) the resolvable-set derivation lies with mutually consistent empties.
R9S_INPUTS_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9S_LIE_SUBSTRING="$R9S_INPUTS_MARKER" R9S_LIE_OUTPUT='{"r":[],"unresolved":[],"blocked":[],"ud_r":{}}' PATH="$FIXTURE/r9s-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9S" 2>&1)
assert_eq "9s.3 R7-F3(3): rc-0 {r:[],unresolved:[],blocked:[],ud_r:{}} fails the r+unresolved==unit_ids partition check -> set_computation_failed, never a silent all-units-dropped clean plan" \
    "false|set_computation_failed" "$(json_field '.parallel_safe' "$R9S_INPUTS_OUT")|$(json_field '.degradation_reason' "$R9S_INPUTS_OUT")"

# (1) multiply-bound: the DECISION is now jq-free. Fixture: BOTH children
# bound to U1. Honest path names the conflict; with the one remaining jq
# in the gate (the detail NAMER) fed the reviewer's [] lie, the degrade
# still fires from the bash cardinality (2 bindings, 1 distinct unit).
R9SDUPDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9SDUP" "$R9SUNITS" "T-R9SD-A,T-R9SD-B")
bind_child "$BDFIX" "T-R9SD-A" "EPIC-R9SDUP" "U1" "$R9SDUPDH"
bind_child "$BDFIX" "T-R9SD-B" "EPIC-R9SDUP" "U1" "$R9SDUPDH"
R9S_DUP_HONEST=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9SDUP")
assert_eq "9s.4 R7-F3(1): honest path still degrades AND names both conflicting task ids in observations" \
    "unit_bound_to_multiple_tasks|1|1" "$(json_field '.degradation_reason' "$R9S_DUP_HONEST")|$(printf '%s' "$(json_field '.observations' "$R9S_DUP_HONEST")" | grep -cF 'T-R9SD-A')|$(printf '%s' "$(json_field '.observations' "$R9S_DUP_HONEST")" | grep -cF 'T-R9SD-B')"
R9S_DUP_LIE=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9S_LIE_SUBSTRING="$R9S_DUPDETAIL_MARKER" R9S_LIE_OUTPUT='[]' PATH="$FIXTURE/r9s-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9SDUP" 2>&1)
assert_eq "9s.5 R7-F3(1): the reviewer's rc-0 [] lie no longer reaches the decision -- the bash cardinality degrades regardless (pre-fix, this exact lie hit the dup-scan program and produced parallel_safe=true with one binding silently collapsed away by from_entries)" \
    "false|unit_bound_to_multiple_tasks" "$(json_field '.parallel_safe' "$R9S_DUP_LIE")|$(json_field '.degradation_reason' "$R9S_DUP_LIE")"

# Round 8 (R8-F3, the cheap half): two shape-consistent but semantically
# wrong lies the round-7 gates still accepted, now pinned to
# unit_task_map. Same fixture, same shim.
R9S_INPUTS2_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9S_LIE_SUBSTRING="$R9S_INPUTS_MARKER" R9S_LIE_OUTPUT='{"r":[],"unresolved":["U1","U2"],"blocked":[],"ud_r":{}}' PATH="$FIXTURE/r9s-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9S" 2>&1)
assert_eq "9s.6 R8-F3: a PERFECT partition that reclassifies every bound unit as unresolved fails the r==unit_task_map-keys pin -> set_computation_failed, never a clean plan with zero batches over two bound units" \
    "false|set_computation_failed" "$(json_field '.parallel_safe' "$R9S_INPUTS2_OUT")|$(json_field '.degradation_reason' "$R9S_INPUTS2_OUT")"
R9S_BATCH2_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9S_LIE_SUBSTRING="$R9S_BATCH_MARKER" R9S_LIE_OUTPUT='{"ok":true,"batches":[[{"unit_id":"U1","task_id":"forged-A"},{"unit_id":"U2","task_id":"forged-B"}]]}' PATH="$FIXTURE/r9s-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9S" 2>&1)
assert_eq "9s.7 R8-F3: a correct unit-id multiset carrying FORGED task ids fails the task_id==unit_task_map pin -> set_computation_failed, and the degrade still emits the honest 2-singleton serial schedule" \
    "false|set_computation_failed|2" "$(json_field '.parallel_safe' "$R9S_BATCH2_OUT")|$(json_field '.degradation_reason' "$R9S_BATCH2_OUT")|$(json_field '.batches | length' "$R9S_BATCH2_OUT")"

# ===========================================================================
printf '\n=== Section 9 continued: round-8 findings (xsu1-r8) ===\n'
# ===========================================================================

# --- 9t: R8-F2 -- the round-7 multiply-bound decision escaped the
# unguarded-jq channel (uopo) by landing in the unguarded-PIPELINE
# channel (i8cx): without pipefail, `printf | sort -u | grep -c .` takes
# grep's status, so a sort that copied stdin through unsorted and exited
# 9 (the reviewer's reproduction, and this shim's exact behaviour) left
# entries == "distinct" and the duplicate branch SKIPPED -- from_entries
# then collapsed one binding and the clean plan could report
# parallel_safe:true. The fix scopes `set -o pipefail` to that one
# command substitution. The shim is surgical: armed by env var AND keyed
# on the -u flag -- the only `sort -u` reachable in a plan-batches run
# is this decision's (epic-gate's degrade sort has no -u; qa-gate's
# sort -u sites live in gate/tracker/design-conform functions no
# plan-batches subprocess calls) -- and 9s.4/9s.5 stay the honest-path
# and jq-lie legs this one was flagged as non-discriminating for. -----------
new_fixture_root "r8f2"
R9TU1=$(u U1 "a9t.sh")
R9TUNITS=$(units_of "$R9TU1")
R9TDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9T" "$R9TUNITS" "T-R9T-A,T-R9T-B")
bind_child "$BDFIX" "T-R9T-A" "EPIC-R9T" "U1" "$R9TDH"
bind_child "$BDFIX" "T-R9T-B" "EPIC-R9T" "U1" "$R9TDH"

REAL_SORT=$(command -v sort)
mkdir -p "$FIXTURE/r9t-sort-shim-bin"
cat > "$FIXTURE/r9t-sort-shim-bin/sort" <<SHIMEOF
#!/bin/bash
# Armed + '-u' present: copy stdin through UNSORTED and exit 9 (the
# reviewer's exact R8-F2 reproduction). Everything else: real sort.
if [ -n "\${R9T_SORT_SABOTAGE:-}" ]; then
    for a in "\$@"; do
        if [ "\$a" = "-u" ]; then
            cat
            exit 9
        fi
    done
fi
exec "$REAL_SORT" "\$@"
SHIMEOF
chmod +x "$FIXTURE/r9t-sort-shim-bin/sort"

R9T_HONEST_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9T")
assert_eq "9t.0 RESTORE CONTROL: unshimmed, the double-bound fixture degrades on the honest cardinality (unit_bound_to_multiple_tasks)" \
    "unit_bound_to_multiple_tasks" "$(json_field '.degradation_reason' "$R9T_HONEST_OUT")"

R9T_SAB_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9T_SORT_SABOTAGE=1 PATH="$FIXTURE/r9t-sort-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9T" 2>&1)
assert_eq "9t.1 R8-F2: a sort that copies stdin and exits 9 now surfaces through the scoped pipefail -> set_computation_failed, never a skipped duplicate branch" \
    "false|set_computation_failed" "$(json_field '.parallel_safe' "$R9T_SAB_OUT")|$(json_field '.degradation_reason' "$R9T_SAB_OUT")"
assert_contains "9t.2 R8-F2: observations carry sort's own status (pipeline rc=9), proving the FIRST stage's failure is what surfaced" \
    "pipeline rc=9" "$(json_field '.observations' "$R9T_SAB_OUT")"

# MUTANT: revert the pipefail line to its round-7 form (awk exact-line
# replacement, 9k's ENVIRON technique) and re-run the SAME sabotage: the
# duplicate branch is skipped, from_entries collapses one binding, and
# the clean plan reports parallel_safe:true -- R8-F2's exact hazard.
# shellcheck disable=SC2016  # intentional non-interpolating literals, matched against source below
R9T_NEW_LINE='        distinct_bound_units=$(set -o pipefail; printf '"'"'%s\n'"'"' "${bound_units[@]}" | LC_ALL=C sort -u | grep -c .) || distinct_rc=$?'
# shellcheck disable=SC2016
R9T_OLD_LINE='        distinct_bound_units=$(printf '"'"'%s\n'"'"' "${bound_units[@]}" | LC_ALL=C sort -u | grep -c .) || distinct_rc=$?'
R9T_COUNT_BEFORE=$(grep -cF "$R9T_NEW_LINE" "$EG_M")
assert_eq "9t.3 NON-VACUITY: the pipefail-scoped counting line existed exactly once before mutation" "1" "$R9T_COUNT_BEFORE"
OLD_LINE="$R9T_NEW_LINE" NEW_LINE="$R9T_OLD_LINE" awk '
  { if ($0 == ENVIRON["OLD_LINE"]) { print ENVIRON["NEW_LINE"]; n++ } else print }
  END { if (n != 1) exit 7 }
' "$EG_M" > "$EG_M.replaced"
R9T_AWK_RC=$?
assert_eq "9t.4 NON-VACUITY: the awk exact-line replacement landed exactly once" "0" "$R9T_AWK_RC"
mv "$EG_M.replaced" "$EG_M"
chmod 0755 "$EG_M"
bash -n "$EG_M"
assert_eq "9t.5 NON-VACUITY: the mutant still parses" "0" "$?"

R9T_MUT_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9T_SORT_SABOTAGE=1 PATH="$FIXTURE/r9t-sort-shim-bin:$PATH" bash "$EG_M" plan-batches "EPIC-R9T" 2>&1)
assert_eq "9t.6 SPECIFIC MISBEHAVIOUR: the pipefail-stripped mutant reads grep's rc 0, skips the duplicate branch, and reports parallel_safe=TRUE over a multiply-bound unit" \
    "true" "$(json_field '.parallel_safe' "$R9T_MUT_OUT")"
assert_eq "9t.7 SPECIFIC MISBEHAVIOUR: from_entries collapsed the conflict -- exactly one task survives in unit_task_map, the other is an unconstrained writer invisible to the plan" \
    "1" "$(json_field '.unit_task_map | length' "$R9T_MUT_OUT")"

# --- 9u: R8-F1 -- the validated design's re-extractions must never
# substitute an empty []/{} on failure. Before round 8, `|| ..."{}"`
# published the substituted {} as the degrade path's dependency data, so
# a failed unit_deps read told the schedule construction "no edges" --
# R7-F1's defect one level upstream, surfacing only later as
# unit_files_missing_for_declared_unit AFTER the wrong order was already
# emitted (the round-8 negative control over the round-7 script shows
# exactly that shape: reason unit_files_missing_for_declared_unit,
# batches sorted with T-A-DEPENDENT first). The extraction is now ONE
# guarded jq call whose program text is unique across ALL the scripts a
# plan-batches run executes -- asserted below, because review-check.sh
# carries textually identical single-field '.unit_deps' extractions a
# whole-argument shim would strand at -- and any failure degrades with
# NO child ids (batches []). --------------------------------------------
new_fixture_root "r8f1"
R9UU1=$(u U-prereq "p9u.sh")
R9UU2=$(u U-dependent "d9u.sh" "U-prereq")
R9UUNITS=$(units_of "$R9UU1" "$R9UU2")
R9UDH=$(seed_epic "$ROOT" "$BDFIX" "$WFM_M" "EPIC-R9U" "$R9UUNITS" "T-A-DEPENDENT,T-Z-PREREQ")
bind_child "$BDFIX" "T-Z-PREREQ" "EPIC-R9U" "U-prereq" "$R9UDH"
bind_child "$BDFIX" "T-A-DEPENDENT" "EPIC-R9U" "U-dependent" "$R9UDH"

# shellcheck disable=SC2016  # intentional non-interpolating literal, matched against source below
R9U_VEX_MARKER='.unit_ids, .unit_files, .unit_deps'
assert_eq "9u.0a PRECONDITION: the triple-extraction program is source-unique in epic-gate.sh" \
    "1" "$(grep -cF "$R9U_VEX_MARKER" "$EG")"
assert_eq "9u.0b PRECONDITION: ...and absent from the fixture's qa-gate.sh and review-check.sh (the shim sees every subprocess's jq calls, so a marker matching review-check's own extractions would strand the injection at the wrong call site)" \
    "0|0" "$(grep -cF "$R9U_VEX_MARKER" "$ROOT/.claude/scripts/qa-gate.sh")|$(grep -cF "$R9U_VEX_MARKER" "$ROOT/.claude/scripts/review-check.sh")"

R9U_CTRL_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" bash "$EG" plan-batches "EPIC-R9U")
assert_eq "9u.1 RESTORE CONTROL: uninjected, the two-unit dependent fixture computes a clean 2-batch plan in dependency order" \
    "true|2" "$(json_field '.parallel_safe' "$R9U_CTRL_OUT")|$(json_field '.batches | length' "$R9U_CTRL_OUT")"

R9U_INJ_OUT=$(CLAUDE_PROJECT_DIR="$ROOT" BD_FIXTURE_DIR="$BDFIX" R9N_FAIL_MARKER="$R9U_VEX_MARKER" PATH="$FIXTURE/r9n-shim-bin:$PATH" bash "$EG" plan-batches "EPIC-R9U" 2>&1)
assert_eq "9u.2 R8-F1: an induced triple-extraction failure degrades set_computation_failed with NO schedule (batches=[]) -- never the pre-round-8 substituted {} that read as 'no edges'" \
    "false|set_computation_failed|0" "$(json_field '.parallel_safe' "$R9U_INJ_OUT")|$(json_field '.degradation_reason' "$R9U_INJ_OUT")|$(json_field '.batches | length' "$R9U_INJ_OUT")"
assert_contains "9u.3 R8-F1: the observation names the refusal's reason -- unreadable dependency data means no order can be trusted" \
    "could not be re-extracted" "$(json_field '.observations' "$R9U_INJ_OUT")"

# ===========================================================================
# Summary — the completeness line names every counter, including sections
# that could not run (R4 vacuity sweep: a skipped section is visible in
# the spec's own accounting, not just in the runner's transcript regex).
# ===========================================================================
printf '\n=== plan-batches.test.sh: summary ===\n'
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED assertions:\n'
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
fi
printf 'Total: %d, Passed: %d, Failed: %d, Skipped-sections: %d\n' \
    "$((PASS + FAIL))" "$PASS" "$FAIL" "$SKIPPED_SECTIONS"
if [ "$FAIL" -gt 0 ]; then
    exit 1
fi
exit 0
