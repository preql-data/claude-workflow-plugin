#!/bin/bash
# design-accessors.test.sh — the two read-only qa-gate.sh accessors
# (`design-unit-show`, `design-status`) that epic-gate.sh plan-batches shells
# out to, under FAILURE of the sources they read (v5 D4b fix round,
# claude-workflow-plugin-xsu1 review artifact h2r1).
#
# WHY A SEPARATE SPEC. Until this round there was NO direct invocation or
# assertion of design-unit-show anywhere in the tier (the review's
# coverage-gap list, verified by the orchestrator), and plan-batches.test.sh
# exercises both accessors only THROUGH epic-gate.sh over well-formed canned
# fixtures — a path that can never present an unreadable source, a malformed
# binding, or a failing encoder. The natural sibling (design-conform.test.sh)
# already runs ~640s against a real bd store; these cases specifically need
# a bd that FAILS on demand and per-call-site jq fault injection, which the
# canned-fixture fake-bd pattern (plan-batches.test.sh's own harness shape)
# gives in milliseconds. BD-FREE by design: the fake bd serves per-task JSON
# from $BD_FIXTURE_DIR and exits 1 for anything unknown.
#
# WHAT IS COVERED (each finding from docs/reviews/claude-workflow-plugin-
# xsu1-h2r1.json, with its four-part pairing per .claude/tests/README.md):
#
#   1. Determined answers, shipped script running (the positive arm both
#      H2-F2's and H2-F3's mutants need to be non-vacuous): bound:true with
#      the COMPLETE validated envelope shape, bound:false from a
#      successfully-parsed empty comment stream.
#   2. H2-F2 — an UNREADABLE binding source (bd show failing, or unparseable
#      comment JSON) is ok:false/design_binding_unreadable/exit 2, and is
#      DISTINGUISHABLE from section 1's determined bound:false.
#   3. H2-F2 META — a sed mutant restores the pre-fix call-site guard
#      (`|| binding_json="{}"`); the mutant reports the unreadable source as
#      the determined answer bound:false/ok:true/exit 0 — the exact defect —
#      while the shipped script (section 2) refuses.
#   4. H2-F3 — the binding is validated ONCE against the full union shape;
#      an induced failure of exactly that classifier call refuses
#      (design_binding_malformed) instead of emitting bound:true with empty
#      required fields. State-mutation pairing: marker-file proves the
#      injection landed; the uninjected control (section 1) is the restore.
#   5. H2-F5 — design-status distinguishes an unreadable Beads source
#      (ok:false/design_source_unreadable/exit 2, satisfied:false RETAINED)
#      from a task that genuinely has no design (ok:true/
#      no_design_attempted/exit 0), plus the satisfied:true positive arm.
#   6. H2-F5 META — stripping the DESIGN-SOURCE-UNREADABLE GUARD sentinels
#      from a qa-gate.sh copy brings back the masquerade: the mutant reports
#      the unreadable source as ok:true/no_design_attempted/exit 0 (the key
#      design-gate-precheck maps to "ready").
#   7. H2-F4 — neither accessor may exit 0 with malformed output when its
#      final JSON encoder fails: an induced failure of exactly the marked
#      `jq -nc` envelope build yields the caller-data-free literal
#      (envelope_construction_failed), still-parseable output, and exit 2,
#      for BOTH accessors. Controls re-run uninjected.
#
# ROUND 2 (docs/reviews/claude-workflow-plugin-xsu1-h2r2.json):
#
#   8. H2R2-F1 — design_comments_json's proof rule: a bd response carrying
#      comment_count>0 but NO comments array (bd 1.2.2's own plain-show
#      shape, measured) is an UNRETRIEVED stream (refused), not a confirmed-
#      empty one; comment_count==0 with no array is PROVEN absence
#      (accepted — both bd 1.2.2 show forms omit the array on pristine
#      tasks, so this arm is what keeps the rule livable); `{}` — the
#      review's own probe shape — is refused. META: a mutant that restores
#      the permissive `// []`-equivalent arm brings the masquerade back.
#   9. H2R2-F2 — design-unit-bind's pre-write existing-binding read refuses
#      design_binding_unreadable BEFORE add_comment in BOTH the flocked and
#      unflocked branches (each branch pinned deterministically: a stub
#      flock forces the first, a flock-less curated PATH forces the
#      second); the post-write confirmation read distinguishes "re-read
#      failed" (design_binding_confirm_unreadable) from "re-read succeeded
#      and my record is not latest" (design_binding_write_unconfirmed); and
#      design-conform reports an unreadable binding source as
#      design_binding_unreadable/exit 2 instead of unit_not_in_design.
#      META: restoring the pre-fix `|| var="{}"` spellings lets a bind over
#      a transiently-unreadable store silently supersede the authoritative
#      binding and report "recorded" — reproduced against a write-capable
#      fake bd whose outage heals exactly at the write, the review's own
#      narrative.
#  10. H2R2-F3 — latest_design_review's failure channel: a failed review
#      read surfaces as design_source_unreadable from compute_design_
#      satisfied (never design_verdict_missing), and design-review-record
#      refuses design_review_history_unreadable BEFORE its amendment/
#      iteration decision (never writing a duplicate iteration over an
#      unread history). METAs strip each guard region and watch the named
#      masquerade come back; the duplicate write is materialized in the
#      fake store and counted.
#
# Exit codes: 0 all assertions passed | 1 one or more failed | 2 harness error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()
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

if ! command -v jq >/dev/null 2>&1; then
    echo "jq not on PATH — this harness itself needs it."
    exit 2
fi
REAL_JQ=$(command -v jq)

PLUGIN_DIR="$(cd "$(dirname "$0")/../../.." && pwd)"
FIXTURE=$(mktemp -d -t design-accessors.XXXXXX)

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
mkdir -p "$SCRIPTS" "$FIXTURE/.beads" "$FIXTURE/docs/specs" \
    "$FIXTURE/bd-fixture" "$FIXTURE/fake-bd"
cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$SCRIPTS/"
chmod 0755 "$SCRIPTS"/*.sh

# The fake bd: canned per-task JSON, exit 1 for anything unknown — which is
# exactly the "both bd show forms fail" state H2-F2/H2-F5 need on demand.
# Same shape as plan-batches.test.sh's own (flags after `show <id>` are
# ignored, so the `--include-comments` first leg of the comment readers
# succeeds and returns the canned comments).
#
# v2 (xsu1 H2R2-F2, sections 9-10): `comments add`/`comment add` now
# maintain a REAL tiny store — the text is appended into the fixture's
# comments array and every attempt is logged to comments-add.log — because
# round 2's scenarios need to observe whether a WRITE actually reached the
# store, not just what the command printed. Three per-task sidecar files
# model the store states the H2R2-F2 narrative needs:
#   <fixture>.unreadable      show exits 1 (the store cannot be read NOW)
#   <fixture>.heal-on-write   the .unreadable marker is removed the moment
#                             a write lands — the review's transient-outage
#                             narrative: read fails, write+confirm succeed
#   <fixture>.break-on-write  the store becomes unreadable right AFTER a
#                             write lands — the confirmation-read failure
#   <fixture>.drop-writes     the write claims success but stores nothing —
#                             the determined write_unconfirmed contrast
cat > "$FIXTURE/fake-bd/bd" <<FAKEBD
#!/bin/bash
case "\${1:-}" in
    show)
        tid="\${2:-}"
        f="\$BD_FIXTURE_DIR/\$(printf '%s' "\$tid" | tr -c 'A-Za-z0-9._-' '_').json"
        [ -f "\$f.unreadable" ] && exit 1
        if [ -f "\$f" ]; then
            cat "\$f"
            exit 0
        fi
        exit 1
        ;;
    comments|comment)
        [ "\${2:-}" = "add" ] || exit 1
        tid="\${3:-}"; text="\${4:-}"
        f="\$BD_FIXTURE_DIR/\$(printf '%s' "\$tid" | tr -c 'A-Za-z0-9._-' '_').json"
        printf '%s\n' "\$tid" >> "\$BD_FIXTURE_DIR/comments-add.log"
        if [ -f "\$f.drop-writes" ]; then exit 0; fi
        [ -f "\$f" ] || printf '{"id":"%s","status":"open","labels":[],"comments":[]}\n' "\$tid" > "\$f"
        tmp=\$("$REAL_JQ" --arg t "\$text" '.comments = ((.comments // []) + [{text:\$t}])' "\$f") || exit 1
        printf '%s\n' "\$tmp" > "\$f"
        [ -f "\$f.heal-on-write" ] && rm -f "\$f.unreadable" "\$f.heal-on-write"
        [ -f "\$f.break-on-write" ] && { : > "\$f.unreadable"; rm -f "\$f.break-on-write"; }
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
FAKEBD
chmod 0755 "$FIXTURE/fake-bd/bd"

export CLAUDE_PROJECT_DIR="$FIXTURE"
export BD_FIXTURE_DIR="$FIXTURE/bd-fixture"
export PATH="$FIXTURE/fake-bd:$PATH"

# (xsu1 R7-F7) QG names the CANONICAL repository artifact — the thing this
# spec exists to test — never the fixture copy. Before this fix every
# behaviour leg ran the copy made by the `cp` above, so leg 4 of the
# four-part pairing standard (at least one leg observes the SHIPPED
# artifact RUNNING) was absent while the leg labels asserted otherwise —
# the identical defect plan-batches.test.sh's R4-F6 comment records and
# fixes. The copies under $SCRIPTS remain as the SUPPORT scripts qa-gate.sh
# resolves from CLAUDE_PROJECT_DIR at runtime (review-check.sh,
# workflow-manifest.sh, impact-report.sh, ...) — Section 11 swaps validator
# stubs into THAT copy, never into the canonical file, which no test may
# write to. Mutants are generated FROM the canonical bytes into
# fixture-local copies and run from there; that is the point of a mutant.
QG="$PLUGIN_DIR/.claude/scripts/qa-gate.sh"
WM="$SCRIPTS/workflow-manifest.sh"

json_field() { printf '%s' "$2" | "$REAL_JQ" -r "$1" 2>/dev/null || printf ''; }

# bd_task <id> <comments-json-array-of-strings>
bd_task() {
    local id="$1" comments="$2" f
    f="$BD_FIXTURE_DIR/$(printf '%s' "$id" | tr -c 'A-Za-z0-9._-' '_').json"
    # shellcheck disable=SC2016  # jq program: $id/$comments are jq variables.
    "$REAL_JQ" -n --arg id "$id" --argjson comments "$comments" \
        '{id:$id, status:"open", labels:[], comments: ($comments | map({text:.}))}' > "$f"
}

# mk_marker_shim <dir> <marker> <fired-file> — a jq that fails (exit 5) ONLY
# the invocation whose argv carries <marker> verbatim, recording that it
# fired; every other call reaches the real jq. The markers are comments
# inside the shipped jq programs, unique per call site (asserted in section
# 0), so the injection cannot land on an earlier call by substring accident.
mk_marker_shim() {
    local dir="$1" marker="$2" fired="$3"
    mkdir -p "$dir"
    cat > "$dir/jq" <<SHIMEOF
#!/bin/bash
case "\$*" in
  *"$marker"*)
    echo fired >> "$fired"
    exit 5 ;;
esac
exec "$REAL_JQ" "\$@"
SHIMEOF
    chmod 0755 "$dir/jq"
}

# mk_wrongshape_shim <dir> <marker> <fired-file> — a jq that, ONLY for the
# invocation whose argv carries <marker> verbatim, prints `[]` and exits 0
# (a PARSEABLE-but-wrong build result — the rc-0 malfunction R7-F5 names;
# `jq -n -e '[]'` is rc 0, so a parseability-only guard passes it), while
# every other call reaches the real jq.
mk_wrongshape_shim() {
    local dir="$1" marker="$2" fired="$3"
    mkdir -p "$dir"
    cat > "$dir/jq" <<SHIMEOF
#!/bin/bash
case "\$*" in
  *"$marker"*)
    echo fired >> "$fired"
    printf '[]\n'
    exit 0 ;;
esac
exec "$REAL_JQ" "\$@"
SHIMEOF
    chmod 0755 "$dir/jq"
}

DHASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
# shellcheck disable=SC2016  # '[$c]' is a jq program.
bd_task "T-BOUND" "$("$REAL_JQ" -nc --arg c "DESIGN-UNIT v1 task=T-BOUND design_task=E-DESIGN unit_id=U1 design_hash=$DHASH at 2026-08-24T00:00:00Z: bound for the accessor spec" '[$c]')"
bd_task "T-EMPTY" "[]"
printf 'this is not json at all\n' > "$BD_FIXTURE_DIR/T-GARBLED.json"
# T-NOFIXTURE deliberately has no file: both bd show forms exit 1 for it.

# ===========================================================================
printf '\n=== Section 0: the fault-injection markers are unique call sites ===\n'
# ===========================================================================
# The rule this tier holds injection to: a marker must match the EXACT call
# site it names, never an earlier one by substring. Each marker below occurs
# exactly once in the shipped script, so the shim's `case "$*"` cannot fire
# anywhere else.
assert_eq "0.1 classifier marker is unique in qa-gate.sh" "1" \
    "$(grep -cF 'design-unit-show binding-shape classifier (xsu1 H2-F3)' "$QG")"
assert_eq "0.2 design-unit-show success-envelope marker is unique" "1" \
    "$(grep -cF 'design-unit-show success envelope (xsu1 H2-F4)' "$QG")"
assert_eq "0.3 design-status envelope marker is unique" "1" \
    "$(grep -cF 'design-status envelope (xsu1 H2-F4)' "$QG")"
assert_eq "0.4 proven-retrieval read marker is unique (H2R2-F1)" "1" \
    "$(grep -cF 'design-comments proven-retrieval read (xsu1 H2R2-F1)' "$QG")"
assert_eq "0.5 design-review record-selector marker is unique (H2R2-F3)" "1" \
    "$(grep -cF 'latest-design-review record selector (xsu1 H2R2-F3)' "$QG")"
assert_eq "0.6 design-review union-shape marker is unique (H2R2-F3)" "1" \
    "$(grep -cF 'latest-design-review union-shape check (xsu1 H2R2-F3)' "$QG")"

# ===========================================================================
printf '\n=== Section 1: determined answers (shipped script, running) ===\n'
# ===========================================================================

S1_RC=0
S1_OUT=$(bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || S1_RC=$?
assert_eq "1.1 bound child: exit 0" "0" "$S1_RC"
# The COMPLETE envelope shape in one assertion — the thing H2-F3 found
# untested: exactly the nine documented keys, bound genuinely true, both ids
# non-empty and exact, the hash 64-hex, ok true, error_key empty.
assert_eq "1.1b the FULL bound:true envelope shape validates (all nine keys, no extras)" "true" \
    "$(json_field '
        (keys | sort) == ["bound","design_hash","design_task","error_key","observations","ok","subcommand","task_id","unit_id"]
        and .ok == true and .bound == true and .error_key == ""
        and .task_id == "T-BOUND" and .subcommand == "design-unit-show"
        and .design_task == "E-DESIGN"
        and .unit_id == "U1"
        and (.design_hash | test("^[0-9a-fA-F]{64}$"))
    ' "$S1_OUT")"

S2_RC=0
S2_OUT=$(bash "$QG" design-unit-show "T-EMPTY" 2>/dev/null) || S2_RC=$?
assert_eq "1.2 unbound child (comment stream read and parsed, no record): exit 0" "0" "$S2_RC"
assert_eq "1.2b ...ok:true, bound:false, empty triple" "true" \
    "$(json_field '.ok == true and .bound == false and .design_task == "" and .unit_id == "" and .design_hash == ""' "$S2_OUT")"

# ===========================================================================
printf '\n=== Section 2: H2-F2 — an unreadable source is NOT bound:false ===\n'
# ===========================================================================

U1_RC=0
U1_OUT=$(bash "$QG" design-unit-show "T-NOFIXTURE" 2>/dev/null) || U1_RC=$?
assert_eq "2.1 both bd show forms failing: exit 2, not a determined answer" "2" "$U1_RC"
assert_eq "2.1b ...ok:false with the specific key" "false|design_binding_unreadable" \
    "$(json_field '.ok' "$U1_OUT")|$(json_field '.error_key' "$U1_OUT")"

U2_RC=0
U2_OUT=$(bash "$QG" design-unit-show "T-GARBLED" 2>/dev/null) || U2_RC=$?
assert_eq "2.2 unparseable comment JSON: exit 2 with the same key" "2|design_binding_unreadable" \
    "$U2_RC|$(json_field '.error_key' "$U2_OUT")"

# The distinguishability H2-F2 demanded: the determined bound:false (1.2) and
# the unreadable source (2.1) now differ on ok, error_key AND exit code.
assert_eq "2.3 determined-absence vs unreadable-source are distinguishable" "true" \
    "$( [ "$S2_RC" = "0" ] && [ "$U1_RC" = "2" ] \
        && [ "$(json_field '.ok' "$S2_OUT")" = "true" ] \
        && [ "$(json_field '.ok' "$U1_OUT")" = "false" ] && echo true || echo false )"

# ===========================================================================
printf '\n=== Section 3: H2-F2/H2R2-F2 META — the pre-fix call sites, restored ===\n'
# ===========================================================================
# The pre-fix line was `binding_json=$(latest_design_unit_binding "$tid") ||
# binding_json="{}"` — the reader's failure channel swallowed at the call
# site, so an unreadable source flowed into the absent-binding arm. Round 1
# fixed design-unit-show's call site; ROUND 2 (H2R2-F2) converted
# design-conform's too, spelled BYTE-IDENTICALLY on purpose, so ONE sed
# below restores the historical fail-open shape at BOTH call sites and this
# section watches each consumer misbehave in its own named way: unit-show
# reports the determined answer bound:false, conform rewrites the unread
# source as unit_not_in_design (a claim whose remedy — "bind it first" — is
# wrong when the store simply could not be read).
QG_MUT3="$SCRIPTS/qa-gate.mutant-s3.sh"
# shellcheck disable=SC2016  # the sed pattern/replacement quote SHELL SOURCE
# from qa-gate.sh verbatim; expanding $(...) here would defeat the mutation.
sed 's/binding_json=$(latest_design_unit_binding "$tid") || binding_rc=$?/binding_json=$(latest_design_unit_binding "$tid") || binding_json="{}"/' \
    "$QG" > "$QG_MUT3"
# Non-vacuity: the shipped script carries the rc-capture line at BOTH call
# sites (design-unit-show + design-conform, H2R2-F2) and the fail-open
# spelling at none; the mutant must carry zero and two respectively.
# (grep -cF counts LINES; the conform header comment quotes only the short
# `|| binding_json="{}"` fragment, which cannot match these full-line
# needles — counting text to prove a claim about code is exactly what the
# tests README warns about, so 3.2/3.4 below DRIVE both mutated consumers.)
# shellcheck disable=SC2016  # grep -cF needles are literal shell source.
assert_eq "3.1 NON-VACUITY: rc-capture call sites shipped/mutant = 2/0" "2|0" \
    "$(grep -cF 'binding_json=$(latest_design_unit_binding "$tid") || binding_rc=$?' "$QG")|$(grep -cF 'binding_json=$(latest_design_unit_binding "$tid") || binding_rc=$?' "$QG_MUT3")"
# shellcheck disable=SC2016  # grep -cF needles are literal shell source.
assert_eq "3.1b NON-VACUITY: fail-open call sites shipped/mutant = 0/2" "0|2" \
    "$(grep -cF 'binding_json=$(latest_design_unit_binding "$tid") || binding_json="{}"' "$QG")|$(grep -cF 'binding_json=$(latest_design_unit_binding "$tid") || binding_json="{}"' "$QG_MUT3")"
BASHN3_RC=0; bash -n "$QG_MUT3" 2>/dev/null || BASHN3_RC=$?
assert_eq "3.1c ...and the mutant parses" "0" "$BASHN3_RC"
chmod 0755 "$QG_MUT3"
M3_RC=0
M3_OUT=$(bash "$QG_MUT3" design-unit-show "T-NOFIXTURE" 2>/dev/null) || M3_RC=$?
assert_eq "3.2 SPECIFIC MISBEHAVIOUR: the mutant reports the unreadable source as the determined answer" "0|true|false|" \
    "$M3_RC|$(json_field '.ok' "$M3_OUT")|$(json_field '.bound' "$M3_OUT")|$(json_field '.error_key' "$M3_OUT")"
# Restore control: the SHIPPED script on the SAME input refuses (2.1 above
# already ran it; re-asserted adjacent so this section stands alone).
M3C_RC=0
M3C_OUT=$(bash "$QG" design-unit-show "T-NOFIXTURE" 2>/dev/null) || M3C_RC=$?
assert_eq "3.3 RESTORE CONTROL: shipped script, same input, refuses" "2|design_binding_unreadable" \
    "$M3C_RC|$(json_field '.error_key' "$M3C_OUT")"
# --- the SECOND consumer the same mutant resurrects (H2R2-F2):
# design-conform's binding-read guard sits BEFORE any artifact work, so no
# design fixture is needed — the refusal (and the mutant's misreport) are
# reachable from the binding read alone.
M3D_RC=0
M3D_OUT=$(bash "$QG_MUT3" design-conform "T-NOFIXTURE" 2>/dev/null) || M3D_RC=$?
assert_eq "3.4 SPECIFIC MISBEHAVIOUR: mutant design-conform rewrites the unread source as unit_not_in_design/exit 4" \
    "4|unit_not_in_design" \
    "$M3D_RC|$(json_field '.error_key' "$M3D_OUT")"
M3E_RC=0
M3E_OUT=$(bash "$QG" design-conform "T-NOFIXTURE" 2>/dev/null) || M3E_RC=$?
assert_eq "3.5 RESTORE CONTROL: shipped design-conform, same input, refuses with its own key at exit 2" \
    "2|design_binding_unreadable" \
    "$M3E_RC|$(json_field '.error_key' "$M3E_OUT")"
rm -f "$QG_MUT3"

# ===========================================================================
printf '\n=== Section 4: H2-F3 — the union-shape classifier is load-bearing ===\n'
# ===========================================================================
# The pre-fix shape was three independent extractions with only unit_id
# tested — a selective jq failure emitted bound:true with design_task and
# design_hash empty. Post-fix there is ONE classifier; this induces failure
# of exactly that call (state mutation + marker-file non-vacuity) and
# asserts the refusal. Section 1.1 is the uninjected restore control.
mk_marker_shim "$FIXTURE/shim-classify" \
    'design-unit-show binding-shape classifier (xsu1 H2-F3)' "$FIXTURE/fired-classify"
rm -f "$FIXTURE/fired-classify"
C4_RC=0
C4_OUT=$(PATH="$FIXTURE/shim-classify:$PATH" bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || C4_RC=$?
assert_eq "4.1 NON-VACUITY: the injection landed on the classifier call" "yes" \
    "$( [ -f "$FIXTURE/fired-classify" ] && echo yes || echo no )"
assert_eq "4.2 a failed classification REFUSES: exit 2, design_binding_malformed" "2|design_binding_malformed" \
    "$C4_RC|$(json_field '.error_key' "$C4_OUT")"
assert_eq "4.3 ...and never emits bound:true (the H2-F3 defect shape: bound:true with empty required fields)" "false" \
    "$(json_field '.bound' "$C4_OUT")"
assert_eq "4.4 ...ok:false — a consumer cannot read a determined answer out of it" "false" \
    "$(json_field '.ok' "$C4_OUT")"

# ===========================================================================
printf '\n=== Section 5: H2-F5 — design-status: unreadable is not absence ===\n'
# ===========================================================================

# Positive arm first: a genuinely satisfied design (artifact on disk,
# DESIGN-ARTIFACT + satisfied DESIGN-REVIEW records carrying its live hash).
printf '# design E-SAT\nreal content\n' > "$FIXTURE/docs/specs/E-SAT.md"
SAT_HASH=$(bash "$WM" hash-file "$FIXTURE/docs/specs/E-SAT.md")
assert_eq "5.0 precondition: the artifact hashed (64 hex)" "64" "${#SAT_HASH}"
# shellcheck disable=SC2016  # '[$a, $r]' is a jq program.
bd_task "E-SAT" "$("$REAL_JQ" -nc \
    --arg a "DESIGN-ARTIFACT v1 task=E-SAT designer=designer-claude design_hash=$SAT_HASH at 2026-08-24T00:00:00Z: recorded" \
    --arg r "DESIGN-REVIEW v1 task=E-SAT reviewer=design-reviewer verdict=satisfied design_hash=$SAT_HASH iteration=1 rubric_version=v1 at 2026-08-24T00:00:01Z: satisfied" \
    '[$a, $r]')"
P5_RC=0
P5_OUT=$(bash "$QG" design-status "E-SAT" 2>/dev/null) || P5_RC=$?
assert_eq "5.1 satisfied design: exit 0, ok:true, satisfied:true, hash carried" "0|true|true|$SAT_HASH" \
    "$P5_RC|$(json_field '.ok' "$P5_OUT")|$(json_field '.satisfied' "$P5_OUT")|$(json_field '.design_hash' "$P5_OUT")"

# Determined absence: readable task, empty comments.
A5_RC=0
A5_OUT=$(bash "$QG" design-status "T-EMPTY" 2>/dev/null) || A5_RC=$?
assert_eq "5.2 genuinely no design: exit 0, ok:true, no_design_attempted (unchanged behaviour)" "0|true|no_design_attempted" \
    "$A5_RC|$(json_field '.ok' "$A5_OUT")|$(json_field '.error_key' "$A5_OUT")"

# Unreadable source: bd failing, and unparseable comments.
X5_RC=0
X5_OUT=$(bash "$QG" design-status "T-NOFIXTURE" 2>/dev/null) || X5_RC=$?
assert_eq "5.3 unreadable Beads source: exit 2, ok:false, its OWN key" "2|false|design_source_unreadable" \
    "$X5_RC|$(json_field '.ok' "$X5_OUT")|$(json_field '.error_key' "$X5_OUT")"
assert_eq "5.3b ...satisfied:false RETAINED (fail-safe for a satisfied-only reader)" "false" \
    "$(json_field '.satisfied' "$X5_OUT")"
G5_RC=0
G5_OUT=$(bash "$QG" design-status "T-GARBLED" 2>/dev/null) || G5_RC=$?
assert_eq "5.4 unparseable comment JSON: same refusal" "2|design_source_unreadable" \
    "$G5_RC|$(json_field '.error_key' "$G5_OUT")"

# ===========================================================================
printf '\n=== Section 6: H2-F5 META — strip the guard, watch the masquerade ===\n'
# ===========================================================================
QG_MUT6="$SCRIPTS/qa-gate.mutant-s6.sh"
AWK6_RC=0
awk '/# DESIGN-SOURCE-UNREADABLE GUARD BEGIN \(xsu1 H2-F5\)/{skip=1; found=1; next}
     /# DESIGN-SOURCE-UNREADABLE GUARD END \(xsu1 H2-F5\)/{skip=0; next}
     !skip{print}
     END{if(!found) exit 7}' "$QG" > "$QG_MUT6" || AWK6_RC=$?
assert_eq "6.1 NON-VACUITY: the sentinel strip found its region (awk exit 7 otherwise)" "0" "$AWK6_RC"
assert_eq "6.1b ...and the mutant differs from the shipped bytes" "differs" \
    "$(cmp -s "$QG" "$QG_MUT6" && echo same || echo differs)"
BASHN6_RC=0; bash -n "$QG_MUT6" 2>/dev/null || BASHN6_RC=$?
assert_eq "6.1c ...and still parses" "0" "$BASHN6_RC"
chmod 0755 "$QG_MUT6"
M6_RC=0
M6_OUT=$(bash "$QG_MUT6" design-status "T-NOFIXTURE" 2>/dev/null) || M6_RC=$?
assert_eq "6.2 SPECIFIC MISBEHAVIOUR: the mutant reports the unreadable source as ordinary absence — ok:true/no_design_attempted/exit 0, the key design-gate-precheck maps to \"ready\"" \
    "0|true|no_design_attempted" \
    "$M6_RC|$(json_field '.ok' "$M6_OUT")|$(json_field '.error_key' "$M6_OUT")"
# Restore control: shipped script, same input (5.3 above; re-run adjacent).
M6C_RC=0
M6C_OUT=$(bash "$QG" design-status "T-NOFIXTURE" 2>/dev/null) || M6C_RC=$?
assert_eq "6.3 RESTORE CONTROL: shipped script, same input, refuses with its own key" "2|design_source_unreadable" \
    "$M6C_RC|$(json_field '.error_key' "$M6C_OUT")"
rm -f "$QG_MUT6"

# ===========================================================================
printf '\n=== Section 7: H2-F4 — a failed final encoder cannot exit 0 ===\n'
# ===========================================================================
# Proven shape (the review reproduced it): under `set -e`, printf with a
# failing inner substitution prints the malformed splice and CONTINUES rc 0.
# The fix builds every envelope with one guarded `jq -nc` and routes it
# through print_envelope_checked; this section fails exactly that build for
# each accessor and asserts the caller-data-free literal + exit 2 + output
# that still parses.

mk_marker_shim "$FIXTURE/shim-encshow" \
    'design-unit-show success envelope (xsu1 H2-F4)' "$FIXTURE/fired-encshow"
rm -f "$FIXTURE/fired-encshow"
E7_RC=0
E7_OUT=$(PATH="$FIXTURE/shim-encshow:$PATH" bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || E7_RC=$?
assert_eq "7.1 NON-VACUITY: the injection landed on the design-unit-show envelope build" "yes" \
    "$( [ -f "$FIXTURE/fired-encshow" ] && echo yes || echo no )"
assert_eq "7.1b encoder failure: exit 2, never 0" "2" "$E7_RC"
assert_eq "7.1c ...output is STILL parseable JSON (the literal), ok:false, the specific key" "true|false|envelope_construction_failed" \
    "$(printf '%s' "$E7_OUT" | "$REAL_JQ" -e . >/dev/null 2>&1 && echo true || echo false)|$(json_field '.ok' "$E7_OUT")|$(json_field '.error_key' "$E7_OUT")"
assert_eq "7.1d ...and it is caller-data-free (task_id null, no binding fields)" "null|false" \
    "$(json_field '.task_id' "$E7_OUT")|$(json_field 'has("design_task")' "$E7_OUT")"
E7C_RC=0
E7C_OUT=$(bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || E7C_RC=$?
assert_eq "7.2 RESTORE CONTROL: uninjected, the same call emits the valid bound:true envelope at exit 0" "0|true" \
    "$E7C_RC|$(json_field '.bound' "$E7C_OUT")"

mk_marker_shim "$FIXTURE/shim-encstat" \
    'design-status envelope (xsu1 H2-F4)' "$FIXTURE/fired-encstat"
rm -f "$FIXTURE/fired-encstat"
E8_RC=0
E8_OUT=$(PATH="$FIXTURE/shim-encstat:$PATH" bash "$QG" design-status "E-SAT" 2>/dev/null) || E8_RC=$?
assert_eq "7.3 NON-VACUITY: the injection landed on the design-status envelope build" "yes" \
    "$( [ -f "$FIXTURE/fired-encstat" ] && echo yes || echo no )"
assert_eq "7.3b encoder failure: exit 2, parseable literal, the specific key" "2|true|envelope_construction_failed" \
    "$E8_RC|$(printf '%s' "$E8_OUT" | "$REAL_JQ" -e . >/dev/null 2>&1 && echo true || echo false)|$(json_field '.error_key' "$E8_OUT")"
assert_eq "7.3c ...caller-data-free (task_id null, no satisfied field a consumer could read as determined)" "null|false" \
    "$(json_field '.task_id' "$E8_OUT")|$(json_field 'has("satisfied")' "$E8_OUT")"
E8C_RC=0
E8C_OUT=$(bash "$QG" design-status "E-SAT" 2>/dev/null) || E8C_RC=$?
assert_eq "7.4 RESTORE CONTROL: uninjected, the same call emits the valid satisfied envelope at exit 0" "0|true" \
    "$E8C_RC|$(json_field '.satisfied' "$E8C_OUT")"

# --- 7.5+ (xsu1 R7-F5): a PARSEABLE-BUT-WRONG build must not print ----------
# Round 6's legs above only sabotage the build with exit 5, so the rc arm of
# the guard triggers the fallback and the parseability arm was never
# discriminated — `jq -n -e '[]'` is rc 0, so a build that "succeeded" into
# [] printed under a success status. The guard now validates the exact
# per-subcommand envelope shape; these legs make exactly that rc-0/[]
# malfunction and watch the literal come back instead.
mk_wrongshape_shim "$FIXTURE/shim-wrongshow" \
    'design-unit-show success envelope (xsu1 H2-F4)' "$FIXTURE/fired-wrongshow"
rm -f "$FIXTURE/fired-wrongshow"
W7_RC=0
W7_OUT=$(PATH="$FIXTURE/shim-wrongshow:$PATH" bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || W7_RC=$?
assert_eq "7.5 NON-VACUITY: the rc-0/[] malfunction landed on the design-unit-show envelope build" "yes" \
    "$( [ -f "$FIXTURE/fired-wrongshow" ] && echo yes || echo no )"
assert_eq "7.5b a parseable-but-wrong build is refused: exit 2, the literal, never []" \
    "2|envelope_construction_failed" \
    "$W7_RC|$(json_field '.error_key' "$W7_OUT")"
mk_wrongshape_shim "$FIXTURE/shim-wrongstat" \
    'design-status envelope (xsu1 H2-F4)' "$FIXTURE/fired-wrongstat"
rm -f "$FIXTURE/fired-wrongstat"
W8_RC=0
W8_OUT=$(PATH="$FIXTURE/shim-wrongstat:$PATH" bash "$QG" design-status "E-SAT" 2>/dev/null) || W8_RC=$?
assert_eq "7.6 NON-VACUITY: ...and on the design-status build" "yes" \
    "$( [ -f "$FIXTURE/fired-wrongstat" ] && echo yes || echo no )"
assert_eq "7.6b same refusal for design-status" "2|envelope_construction_failed" \
    "$W8_RC|$(json_field '.error_key' "$W8_OUT")"

# --- 7.7 META: strip the shape gate, watch [] print at exit 0 ---------------
QG_MUT7="$SCRIPTS/qa-gate.mutant-s7.sh"
AWK7_RC=0
awk '/# ENVELOPE-SHAPE-GATE BEGIN \(xsu1 R7-F5\)/{skip=1; found=1; next}
     /# ENVELOPE-SHAPE-GATE END \(xsu1 R7-F5\)/{skip=0; next}
     !skip{print}
     END{if(!found) exit 7}' "$QG" > "$QG_MUT7" || AWK7_RC=$?
assert_eq "7.7 NON-VACUITY: the shape-gate strip found its region" "0" "$AWK7_RC"
assert_eq "7.7b ...and the mutant differs from the shipped bytes" "differs" \
    "$(cmp -s "$QG" "$QG_MUT7" && echo same || echo differs)"
BASHN7_RC=0; bash -n "$QG_MUT7" 2>/dev/null || BASHN7_RC=$?
assert_eq "7.7c ...and still parses" "0" "$BASHN7_RC"
chmod 0755 "$QG_MUT7"
rm -f "$FIXTURE/fired-wrongshow"
M7_RC=0
M7_OUT=$(PATH="$FIXTURE/shim-wrongshow:$PATH" bash "$QG_MUT7" design-unit-show "T-BOUND" 2>/dev/null) || M7_RC=$?
assert_eq "7.7d SPECIFIC MISBEHAVIOUR: parseability-only prints the [] build at exit 0 (the R7-F5 defect: epic-gate would read a non-envelope under a success rc)" \
    "0|[]|yes" \
    "$M7_RC|$M7_OUT|$( [ -f "$FIXTURE/fired-wrongshow" ] && echo yes || echo no )"
rm -f "$QG_MUT7"
# 7.5b above is the shipped-bytes restore control for this pair; 7.2/7.4 are
# the uninjected controls.

# ===========================================================================
printf '\n=== Section 8: H2R2-F1 — retrieval must be PROVEN, not presumed ===\n'
# ===========================================================================
# Measured ground truth (bd 1.2.2, this repo's own store): a plain
# `bd show --json` on a task carrying 13 comments returns comment_count=13
# and NO comments key; BOTH show forms omit the array on a zero-comment
# task while carrying comment_count=0. The pre-fix readers' `// []` turned
# the first shape — a stream that was NOT retrieved — into confirmed
# absence: design-unit-show bound:false, design-status no_design_attempted,
# which design-gate-precheck maps to "ready". design_comments_json's proof
# rule (explicit comments array, OR comment_count==0) closes that while
# keeping pristine tasks readable. The fake bd ignores flags after
# `show <id>`, so a canned count-only body models the fallback-leg shape on
# every host, exactly as the review's own jq probe did.
jq_w() { "$REAL_JQ" -n "$@"; }
jq_w '{id:"T-COUNTONLY", status:"open", labels:[], comment_count:3}' > "$BD_FIXTURE_DIR/T-COUNTONLY.json"
jq_w '{id:"T-COUNT0", status:"open", labels:[], comment_count:0}' > "$BD_FIXTURE_DIR/T-COUNT0.json"
printf '{}' > "$BD_FIXTURE_DIR/T-EMPTYOBJ.json"

R8A_RC=0
R8A_OUT=$(bash "$QG" design-unit-show "T-COUNTONLY" 2>/dev/null) || R8A_RC=$?
assert_eq "8.1 comment_count=3 with NO comments array is an UNRETRIEVED stream, not bound:false" \
    "2|false|design_binding_unreadable|false" \
    "$R8A_RC|$(json_field '.ok' "$R8A_OUT")|$(json_field '.error_key' "$R8A_OUT")|$(json_field '.bound' "$R8A_OUT")"

R8B_RC=0
R8B_OUT=$(bash "$QG" design-unit-show "T-COUNT0" 2>/dev/null) || R8B_RC=$?
assert_eq "8.2 comment_count=0 with no array is PROVEN absence (the arm that keeps pristine tasks readable): determined bound:false" \
    "0|true||false" \
    "$R8B_RC|$(json_field '.ok' "$R8B_OUT")|$(json_field '.error_key' "$R8B_OUT")|$(json_field '.bound' "$R8B_OUT")"

R8C_RC=0
R8C_OUT=$(bash "$QG" design-unit-show "T-EMPTYOBJ" 2>/dev/null) || R8C_RC=$?
assert_eq "8.3 a bare {} task body (the review's own probe shape) is refused, not read as {}" \
    "2|design_binding_unreadable" \
    "$R8C_RC|$(json_field '.error_key' "$R8C_OUT")"

R8D_RC=0
R8D_OUT=$(bash "$QG" design-status "T-COUNTONLY" 2>/dev/null) || R8D_RC=$?
assert_eq "8.4 design-status on the same shape: design_source_unreadable, never no_design_attempted" \
    "2|false|design_source_unreadable" \
    "$R8D_RC|$(json_field '.ok' "$R8D_OUT")|$(json_field '.error_key' "$R8D_OUT")"
R8E_RC=0
R8E_OUT=$(bash "$QG" design-status "T-COUNT0" 2>/dev/null) || R8E_RC=$?
assert_eq "8.4b ...while proven-zero stays the ordinary determined answer" \
    "0|true|no_design_attempted" \
    "$R8E_RC|$(json_field '.ok' "$R8E_OUT")|$(json_field '.error_key' "$R8E_OUT")"

# --- 8.5 META: restore the permissive arm, watch the masquerade come back.
# The pre-fix acceptance was `// []` at every reader; inside the shared
# helper the equivalent single-point mutation is `else [] end` where the
# shipped code refuses. One sed, one arm, and both accessors regress.
QG_MUT8="$SCRIPTS/qa-gate.mutant-s8.sh"
sed 's/else error("comment-stream-not-retrieved")/else []/' "$QG" > "$QG_MUT8"
assert_eq "8.5 NON-VACUITY: refusal-arm spelling shipped/mutant = 1/0" "1|0" \
    "$(grep -cF 'else error("comment-stream-not-retrieved")' "$QG")|$(grep -cF 'else error("comment-stream-not-retrieved")' "$QG_MUT8")"
assert_eq "8.5b ...and the mutant differs from the shipped bytes" "differs" \
    "$(cmp -s "$QG" "$QG_MUT8" && echo same || echo differs)"
BASHN8_RC=0; bash -n "$QG_MUT8" 2>/dev/null || BASHN8_RC=$?
assert_eq "8.5c ...and still parses" "0" "$BASHN8_RC"
chmod 0755 "$QG_MUT8"
M8_RC=0
M8_OUT=$(bash "$QG_MUT8" design-unit-show "T-COUNTONLY" 2>/dev/null) || M8_RC=$?
assert_eq "8.5d SPECIFIC MISBEHAVIOUR: the mutant reads the withheld stream as confirmed absence — ok:true/bound:false/exit 0" \
    "0|true|false|" \
    "$M8_RC|$(json_field '.ok' "$M8_OUT")|$(json_field '.bound' "$M8_OUT")|$(json_field '.error_key' "$M8_OUT")"
M8S_RC=0
M8S_OUT=$(bash "$QG_MUT8" design-status "T-COUNTONLY" 2>/dev/null) || M8S_RC=$?
assert_eq "8.5e ...and design-status regresses to the key precheck maps to \"ready\"" \
    "0|true|no_design_attempted" \
    "$M8S_RC|$(json_field '.ok' "$M8S_OUT")|$(json_field '.error_key' "$M8S_OUT")"
M8C_RC=0
M8C_OUT=$(bash "$QG" design-unit-show "T-COUNTONLY" 2>/dev/null) || M8C_RC=$?
assert_eq "8.6 RESTORE CONTROL: shipped script, same input, refuses" "2|design_binding_unreadable" \
    "$M8C_RC|$(json_field '.error_key' "$M8C_OUT")"
rm -f "$QG_MUT8"

# --- 8.7 the helper's own jq is on the critical read path (injection).
mk_marker_shim "$FIXTURE/shim-proven" \
    'design-comments proven-retrieval read (xsu1 H2R2-F1)' "$FIXTURE/fired-proven"
rm -f "$FIXTURE/fired-proven"
R8F_RC=0
R8F_OUT=$(PATH="$FIXTURE/shim-proven:$PATH" bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || R8F_RC=$?
assert_eq "8.7 NON-VACUITY: the injection landed on the proven-retrieval call" "yes" \
    "$( [ -f "$FIXTURE/fired-proven" ] && echo yes || echo no )"
assert_eq "8.7b a failed retrieval read refuses even over a normally-bindable task" \
    "2|design_binding_unreadable" \
    "$R8F_RC|$(json_field '.error_key' "$R8F_OUT")"
R8G_RC=0
R8G_OUT=$(bash "$QG" design-unit-show "T-BOUND" 2>/dev/null) || R8G_RC=$?
assert_eq "8.7c RESTORE CONTROL: uninjected, the same task binds true at exit 0" "0|true" \
    "$R8G_RC|$(json_field '.bound' "$R8G_OUT")"

# ===========================================================================
printf '\n=== Section 9: H2R2-F2 — no write over an unread binding history ===\n'
# ===========================================================================
# The reviewer's narrative, reproduced end to end: a transient store outage
# at the pre-write read used to read as "no existing binding", the write
# then landed against the recovered store, the confirmation read succeeded,
# and design-unit-bind reported "recorded" — an unaudited silent supersede
# of the authoritative binding, no --rebind anywhere. The fake bd's
# heal-on-write sidecar models exactly that outage window. Both branches
# are pinned deterministically per leg: a flock-less curated PATH forces
# the sequential branch on every host, a stub flock forces the flocked one.

# A valid two-unit design artifact for the bind's own validation ladder.
cat > "$FIXTURE/docs/specs/E-DESIGN.md" <<'ART'
## Problem
p
## Approaches considered
a
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
{
  "contract_version": "1",
  "task_id": "E-DESIGN",
  "designer_identity": "designer-claude",
  "units": [
    { "unit_id": "U1", "goal": "g1", "verification": "v1",
      "files": ["src/a.sh"],
      "acceptance": [ { "id": "AC1", "text": "t1" } ],
      "depends_on": [] },
    { "unit_id": "U2", "goal": "g2", "verification": "v2",
      "files": ["src/b.sh"],
      "acceptance": [ { "id": "AC2", "text": "t2" } ],
      "depends_on": [] }
  ]
}
<!-- DESIGN-UNITS END -->
ART

# bind_fixture <tid> <bound|empty> — a store body, optionally carrying an
# authoritative U1 binding record.
bind_fixture() {
    local tid="$1" mode="$2" f
    f="$BD_FIXTURE_DIR/$tid.json"
    if [ "$mode" = "bound" ]; then
        # shellcheck disable=SC2016  # {text:$c} is a jq program variable.
        "$REAL_JQ" -n --arg c "DESIGN-UNIT v1 task=$tid design_task=E-DESIGN unit_id=U1 design_hash=$DHASH at 2026-08-25T00:00:00Z: authoritative binding" \
            '{id:"'"$tid"'", status:"open", labels:[], comments:[{text:$c}]}' > "$f"
    else
        printf '{"id":"%s","status":"open","labels":[],"comments":[]}\n' "$tid" > "$f"
    fi
}
latest_unit_of() {
    "$REAL_JQ" -r '[.comments[].text | select(startswith("DESIGN-UNIT v1 ")) | capture("unit_id=(?<u>[A-Za-z0-9._-]+)").u] | last // ""' \
        "$BD_FIXTURE_DIR/$1.json" 2>/dev/null || printf ''
}
log_hits() {
    [ -f "$BD_FIXTURE_DIR/comments-add.log" ] || { printf '0'; return; }
    grep -cxF "$1" "$BD_FIXTURE_DIR/comments-add.log" 2>/dev/null || true
}

# The flock-less curated PATH (same technique as design-conform.test.sh
# Section 13 and design-artifact.test.sh 2b.5): everything qa-gate.sh's
# bind path needs, minus flock, plus the fake bd and the real jq.
NOFLOCK_BIN="$FIXTURE/noflock-bin"
mkdir -p "$NOFLOCK_BIN"
for b in bash git jq sed awk grep cut head tail tr cat cmp date mkdir cp mv \
         rm ln ls dirname basename readlink realpath sort wc shasum \
         sha256sum openssl mktemp touch chmod uname stat find; do
    bp=$(command -v "$b" 2>/dev/null) && ln -sf "$bp" "$NOFLOCK_BIN/$b"
done
ln -sf "$FIXTURE/fake-bd/bd" "$NOFLOCK_BIN/bd"
assert_eq "9.0 precondition: the curated PATH has no flock (forces the sequential branch)" "yes" \
    "$(PATH="$NOFLOCK_BIN" command -v flock >/dev/null 2>&1 && echo no || echo yes)"
assert_eq "9.0b precondition: bd on the curated PATH is the fake store" "$NOFLOCK_BIN/bd" \
    "$(PATH="$NOFLOCK_BIN" command -v bd)"

# --- 9.1 UNLOCKED branch, shipped: refuse BEFORE the write ----------------
bind_fixture "T-TRANS" bound
: > "$BD_FIXTURE_DIR/T-TRANS.json.unreadable"
: > "$BD_FIXTURE_DIR/T-TRANS.json.heal-on-write"
R91_RC=0
R91_OUT=$(PATH="$NOFLOCK_BIN" "$NOFLOCK_BIN/bash" "$QG" design-unit-bind "T-TRANS" --design-task E-DESIGN --unit-id U2 2>/dev/null) || R91_RC=$?
assert_eq "9.1 unreadable pre-write read: exit 2, design_binding_unreadable (sequential branch)" \
    "2|design_binding_unreadable" \
    "$R91_RC|$(json_field '.error_key' "$R91_OUT")"
assert_eq "9.1b ...the write was NEVER attempted (nothing logged for this task)" "0" "$(log_hits T-TRANS)"
assert_eq "9.1c ...the authoritative U1 binding is intact in the store" "U1" "$(latest_unit_of T-TRANS)"
assert_eq "9.1d ...and the outage marker is still armed (heal fires only on a write)" "yes" \
    "$( [ -f "$BD_FIXTURE_DIR/T-TRANS.json.unreadable" ] && echo yes || echo no )"

# --- 9.2 FLOCKED branch, shipped: same refusal inside the critical section
STUBFLOCK_BIN="$FIXTURE/stub-flock-bin"
mkdir -p "$STUBFLOCK_BIN"
cat > "$STUBFLOCK_BIN/flock" <<STUBEOF
#!/bin/bash
echo invoked >> "$FIXTURE/flock-invoked"
exit 0
STUBEOF
chmod 0755 "$STUBFLOCK_BIN/flock"
bind_fixture "T-TRANSL" bound
: > "$BD_FIXTURE_DIR/T-TRANSL.json.unreadable"
: > "$BD_FIXTURE_DIR/T-TRANSL.json.heal-on-write"
rm -f "$FIXTURE/flock-invoked"
R92_RC=0
R92_OUT=$(PATH="$STUBFLOCK_BIN:$PATH" bash "$QG" design-unit-bind "T-TRANSL" --design-task E-DESIGN --unit-id U2 2>/dev/null) || R92_RC=$?
assert_eq "9.2 NON-VACUITY: the stub flock ran (the flocked branch executed)" "yes" \
    "$( [ -f "$FIXTURE/flock-invoked" ] && echo yes || echo no )"
assert_eq "9.2b flocked branch, same refusal before the write, parent re-raises exit 2" \
    "2|design_binding_unreadable" \
    "$R92_RC|$(json_field '.error_key' "$R92_OUT")"
assert_eq "9.2c ...write never attempted, authoritative binding intact" "0|U1" \
    "$(log_hits T-TRANSL)|$(latest_unit_of T-TRANSL)"

# --- 9.3 META: restore BOTH pre-fix pre-write spellings, watch the silent
# supersede land and get reported "recorded".
QG_MUT9="$SCRIPTS/qa-gate.mutant-s9.sh"
# shellcheck disable=SC2016  # sed patterns/replacements quote SHELL SOURCE.
sed -e 's/_rb_existing=$(latest_design_unit_binding "$tid") || _rb_rc=$?/_rb_existing=$(latest_design_unit_binding "$tid") || _rb_existing="{}"/' \
    -e 's/existing=$(latest_design_unit_binding "$tid") || existing_rc=$?/existing=$(latest_design_unit_binding "$tid") || existing="{}"/' \
    "$QG" > "$QG_MUT9"
# shellcheck disable=SC2016  # grep -cF needles are literal shell source.
assert_eq "9.3 NON-VACUITY: flocked rc-capture shipped/mutant = 1/0" "1|0" \
    "$(grep -cF '_rb_existing=$(latest_design_unit_binding "$tid") || _rb_rc=$?' "$QG")|$(grep -cF '_rb_existing=$(latest_design_unit_binding "$tid") || _rb_rc=$?' "$QG_MUT9")"
# shellcheck disable=SC2016  # grep -cF needles are literal shell source.
assert_eq "9.3b NON-VACUITY: sequential rc-capture shipped/mutant = 1/0" "1|0" \
    "$(grep -cF 'existing=$(latest_design_unit_binding "$tid") || existing_rc=$?' "$QG")|$(grep -cF 'existing=$(latest_design_unit_binding "$tid") || existing_rc=$?' "$QG_MUT9")"
BASHN9_RC=0; bash -n "$QG_MUT9" 2>/dev/null || BASHN9_RC=$?
assert_eq "9.3c ...and the mutant parses" "0" "$BASHN9_RC"
chmod 0755 "$QG_MUT9"
bind_fixture "T-MUT" bound
: > "$BD_FIXTURE_DIR/T-MUT.json.unreadable"
: > "$BD_FIXTURE_DIR/T-MUT.json.heal-on-write"
M9_RC=0
M9_OUT=$(PATH="$NOFLOCK_BIN" "$NOFLOCK_BIN/bash" "$QG_MUT9" design-unit-bind "T-MUT" --design-task E-DESIGN --unit-id U2 2>/dev/null) || M9_RC=$?
assert_eq "9.3d SPECIFIC MISBEHAVIOUR: the mutant reports the unaudited repeat binding recorded at exit 0" \
    "0|recorded" \
    "$M9_RC|$(json_field '.status' "$M9_OUT")"
assert_eq "9.3e ...and the store's authoritative binding really was silently superseded (latest is now U2, no --rebind anywhere)" \
    "U2" "$(latest_unit_of T-MUT)"
assert_eq "9.3f ...via a real write that reached the store" "yes" \
    "$( [ "$(log_hits T-MUT)" != "0" ] && echo yes || echo no )"
rm -f "$QG_MUT9"
# Restore control: shipped bytes, identical store state, fresh task.
bind_fixture "T-CTRL" bound
: > "$BD_FIXTURE_DIR/T-CTRL.json.unreadable"
: > "$BD_FIXTURE_DIR/T-CTRL.json.heal-on-write"
R93_RC=0
R93_OUT=$(PATH="$NOFLOCK_BIN" "$NOFLOCK_BIN/bash" "$QG" design-unit-bind "T-CTRL" --design-task E-DESIGN --unit-id U2 2>/dev/null) || R93_RC=$?
assert_eq "9.3g RESTORE CONTROL: shipped script refuses the same state, store untouched" \
    "2|design_binding_unreadable|0|U1" \
    "$R93_RC|$(json_field '.error_key' "$R93_OUT")|$(log_hits T-CTRL)|$(latest_unit_of T-CTRL)"

# --- 9.4 the confirmation read's OWN failure channel -----------------------
bind_fixture "T-CONF" empty
: > "$BD_FIXTURE_DIR/T-CONF.json.break-on-write"
R94_RC=0
R94_OUT=$(PATH="$NOFLOCK_BIN" "$NOFLOCK_BIN/bash" "$QG" design-unit-bind "T-CONF" --design-task E-DESIGN --unit-id U1 2>/dev/null) || R94_RC=$?
assert_eq "9.4 store breaks right AFTER the write: design_binding_confirm_unreadable, exit 5" \
    "5|design_binding_confirm_unreadable" \
    "$R94_RC|$(json_field '.error_key' "$R94_OUT")"
assert_eq "9.4b ...the write itself DID land (this is an unconfirmable write, not a refused one)" "U1" \
    "$(latest_unit_of T-CONF)"

# --- 9.5 ...distinguishable from the determined write_unconfirmed ----------
bind_fixture "T-DROP" empty
: > "$BD_FIXTURE_DIR/T-DROP.json.drop-writes"
R95_RC=0
R95_OUT=$(PATH="$NOFLOCK_BIN" "$NOFLOCK_BIN/bash" "$QG" design-unit-bind "T-DROP" --design-task E-DESIGN --unit-id U1 2>/dev/null) || R95_RC=$?
assert_eq "9.5 a write the store silently dropped: the EXISTING determined key, distinguishable from 9.4" \
    "5|design_binding_write_unconfirmed" \
    "$R95_RC|$(json_field '.error_key' "$R95_OUT")"
assert_eq "9.5b ...the two post-write outcomes carry different keys (the H2R2-F2 'capture confirmation rc separately' point, observable)" "yes" \
    "$( [ "$(json_field '.error_key' "$R94_OUT")" != "$(json_field '.error_key' "$R95_OUT")" ] && echo yes || echo no )"

# --- 9.6+ (xsu1 R7-F6): a failed flock must not run the section unlocked ----
# Errexit is DISABLED inside the flocked subshell (the whole `( ... )` is
# the left side of `|| rebind_rc=$?`; `set -e; ( false; echo continued ) ||
# rc=$?` prints "continued"), so a bare `flock -x 9` failure used to fall
# through into the read and add_comment WITHOUT the lock. The guard tests
# flock's rc explicitly and refuses as infrastructure.
FAILFLOCK_BIN="$FIXTURE/failflock-bin"
mkdir -p "$FAILFLOCK_BIN"
cat > "$FAILFLOCK_BIN/flock" <<STUBEOF
#!/bin/bash
echo invoked >> "$FIXTURE/failflock-invoked"
exit 1
STUBEOF
chmod 0755 "$FAILFLOCK_BIN/flock"
bind_fixture "T-LOCKF" empty
rm -f "$FIXTURE/failflock-invoked"
R96_RC=0
R96_OUT=$(PATH="$FAILFLOCK_BIN:$PATH" bash "$QG" design-unit-bind "T-LOCKF" --design-task E-DESIGN --unit-id U1 2>/dev/null) || R96_RC=$?
assert_eq "9.6 NON-VACUITY: the failing flock stub genuinely ran (the flocked branch executed)" "yes" \
    "$( [ -f "$FIXTURE/failflock-invoked" ] && echo yes || echo no )"
assert_eq "9.6b a failed flock refuses as infrastructure BEFORE reading or writing" \
    "2|design_binding_lock_unavailable" \
    "$R96_RC|$(json_field '.error_key' "$R96_OUT")"
assert_eq "9.6c ...no write was attempted and the store carries no binding" "0|" \
    "$(log_hits T-LOCKF)|$(latest_unit_of T-LOCKF)"

# --- 9.7 META: strip the guard, watch the section run UNLOCKED --------------
QG_MUT96="$SCRIPTS/qa-gate.mutant-s96.sh"
AWK96_RC=0
awk '/# REBIND-LOCK-GUARD BEGIN \(xsu1 R7-F6\)/{skip=1; found=1; next}
     /# REBIND-LOCK-GUARD END \(xsu1 R7-F6\)/{skip=0; next}
     !skip{print}
     END{if(!found) exit 7}' "$QG" > "$QG_MUT96" || AWK96_RC=$?
assert_eq "9.7 NON-VACUITY: the lock-guard strip found its region" "0" "$AWK96_RC"
BASHN96_RC=0; bash -n "$QG_MUT96" 2>/dev/null || BASHN96_RC=$?
assert_eq "9.7b ...and still parses (the mutant keeps the bare capture line — the exact pre-fix shape: failure captured, never checked)" "0" "$BASHN96_RC"
chmod 0755 "$QG_MUT96"
bind_fixture "T-LOCKM" empty
rm -f "$FIXTURE/failflock-invoked"
M96_RC=0
M96_OUT=$(PATH="$FAILFLOCK_BIN:$PATH" bash "$QG_MUT96" design-unit-bind "T-LOCKM" --design-task E-DESIGN --unit-id U1 2>/dev/null) || M96_RC=$?
assert_eq "9.7c SPECIFIC MISBEHAVIOUR: the mutant records THROUGH the failed lock — an unlocked critical section reported recorded at exit 0" \
    "0|recorded|yes" \
    "$M96_RC|$(json_field '.status' "$M96_OUT")|$( [ -f "$FIXTURE/failflock-invoked" ] && echo yes || echo no )"
assert_eq "9.7d ...and the unlocked write really landed in the store" "U1" "$(latest_unit_of T-LOCKM)"
rm -f "$QG_MUT96"

# --- 9.8 CONTROL: a WORKING flock on the same state records normally --------
# (proves 9.6b's refusal is keyed on the lock FAILING, not on the flocked
# branch itself; the stub-flock leg 9.2 above is the unreadable-store
# sibling of this control.)
R98_RC=0
R98_OUT=$(PATH="$STUBFLOCK_BIN:$PATH" bash "$QG" design-unit-bind "T-LOCKF" --design-task E-DESIGN --unit-id U1 2>/dev/null) || R98_RC=$?
assert_eq "9.8 CONTROL: same task, working flock, records normally" "0|recorded" \
    "$R98_RC|$(json_field '.status' "$R98_OUT")"

# ===========================================================================
printf '\n=== Section 10: H2R2-F3 — a failed verdict read is not a verdict ===\n'
# ===========================================================================
# latest_design_review used to be unconditionally fail-open ({} rc 0).
# compute_design_satisfied then reported a failed SECOND read (designer read
# fine, review read dead) as design_verdict_missing — a determined claim —
# and cmd_design_review_record's iteration-advance guard read the same {}
# as "no prior verdict" and would write a DUPLICATE iteration. Both
# consumers now refuse on the reader's rc 3.
# shellcheck disable=SC2016  # {text:$a},{text:$r} are jq program variables.
jq_w --arg a "DESIGN-ARTIFACT v1 task=E-RR designer=designer-claude design_hash=$DHASH at 2026-08-25T00:00:00Z: recorded" \
     --arg r "DESIGN-REVIEW v1 task=E-RR reviewer=design-claude verdict=needs_revision design_hash=$DHASH iteration=1 rubric_version=v1 at 2026-08-25T00:00:01Z: failed: X" \
     '{id:"E-RR", status:"open", labels:[], comments:[{text:$a},{text:$r}]}' > "$BD_FIXTURE_DIR/E-RR.json"
# shellcheck disable=SC2016  # same jq program variables as E-RR above.
jq_w --arg a "DESIGN-ARTIFACT v1 task=E-RRM designer=designer-claude design_hash=$DHASH at 2026-08-25T00:00:00Z: recorded" \
     --arg r "DESIGN-REVIEW v1 task=E-RRM reviewer=design-claude verdict=needs_revision design_hash=$DHASH iteration=1 rubric_version=v1 at 2026-08-25T00:00:01Z: failed: X" \
     '{id:"E-RRM", status:"open", labels:[], comments:[{text:$a},{text:$r}]}' > "$BD_FIXTURE_DIR/E-RRM.json"
VERDICT_DUP=$(jq_w '{verdict:"needs_revision", criterion_results:[{criterion:"c", pass:false, justification:"j"}], required_fixes:["f"], iteration:1, rubric_version:"v1", reviewer_identity:"design-claude"}')

mk_marker_shim "$FIXTURE/shim-rsel" \
    'latest-design-review record selector (xsu1 H2R2-F3)' "$FIXTURE/fired-rsel"

# --- 10.1 compute_design_satisfied (via design-status): the second read ---
rm -f "$FIXTURE/fired-rsel"
R101_RC=0
R101_OUT=$(PATH="$FIXTURE/shim-rsel:$PATH" bash "$QG" design-status "E-RR" 2>/dev/null) || R101_RC=$?
assert_eq "10.1 NON-VACUITY: the injection landed on the review selector" "yes" \
    "$( [ -f "$FIXTURE/fired-rsel" ] && echo yes || echo no )"
assert_eq "10.1b a failed review read (designer read succeeded) is design_source_unreadable, exit 2" \
    "2|false|design_source_unreadable" \
    "$R101_RC|$(json_field '.ok' "$R101_OUT")|$(json_field '.error_key' "$R101_OUT")"
R102_RC=0
R102_OUT=$(bash "$QG" design-status "E-RR" 2>/dev/null) || R102_RC=$?
assert_eq "10.2 RESTORE CONTROL: uninjected, the same task reads determined (needs_revision -> design_not_satisfied, exit 0)" \
    "0|true|design_not_satisfied" \
    "$R102_RC|$(json_field '.ok' "$R102_OUT")|$(json_field '.error_key' "$R102_OUT")"

# --- 10.3 the union-shape check is on the same critical path --------------
mk_marker_shim "$FIXTURE/shim-rshape" \
    'latest-design-review union-shape check (xsu1 H2R2-F3)' "$FIXTURE/fired-rshape"
rm -f "$FIXTURE/fired-rshape"
R103_RC=0
R103_OUT=$(PATH="$FIXTURE/shim-rshape:$PATH" bash "$QG" design-status "E-RR" 2>/dev/null) || R103_RC=$?
assert_eq "10.3 NON-VACUITY: the injection landed on the union-shape check" "yes" \
    "$( [ -f "$FIXTURE/fired-rshape" ] && echo yes || echo no )"
assert_eq "10.3b a record that cannot be shape-validated is an unreadable read, never a partial verdict" \
    "2|design_source_unreadable" \
    "$R103_RC|$(json_field '.error_key' "$R103_OUT")"

# --- 10.4 META: strip the compute_design_satisfied guard ------------------
QG_MUT10="$SCRIPTS/qa-gate.mutant-s10.sh"
AWK10_RC=0
awk '/# DESIGN-REVIEW-SOURCE-UNREADABLE GUARD BEGIN \(xsu1 H2R2-F3\)/{skip=1; found=1; next}
     /# DESIGN-REVIEW-SOURCE-UNREADABLE GUARD END \(xsu1 H2R2-F3\)/{skip=0; next}
     !skip{print}
     END{if(!found) exit 7}' "$QG" > "$QG_MUT10" || AWK10_RC=$?
assert_eq "10.4 NON-VACUITY: the sentinel strip found its region" "0" "$AWK10_RC"
assert_eq "10.4b ...and the mutant differs from the shipped bytes" "differs" \
    "$(cmp -s "$QG" "$QG_MUT10" && echo same || echo differs)"
BASHN10_RC=0; bash -n "$QG_MUT10" 2>/dev/null || BASHN10_RC=$?
assert_eq "10.4c ...and still parses" "0" "$BASHN10_RC"
chmod 0755 "$QG_MUT10"
M10_RC=0
M10_OUT=$(PATH="$FIXTURE/shim-rsel:$PATH" bash "$QG_MUT10" design-status "E-RR" 2>/dev/null) || M10_RC=$?
assert_eq "10.4d SPECIFIC MISBEHAVIOUR: the mutant reports the unread history as the determined design_verdict_missing at ok:true/exit 0" \
    "0|true|design_verdict_missing" \
    "$M10_RC|$(json_field '.ok' "$M10_OUT")|$(json_field '.error_key' "$M10_OUT")"
rm -f "$QG_MUT10"

# --- 10.5 design-review-record refuses BEFORE its iteration decision ------
rm -f "$BD_FIXTURE_DIR/comments-add.log"
R105_RC=0
R105_OUT=$(printf '%s' "$VERDICT_DUP" | PATH="$FIXTURE/shim-rsel:$PATH" bash "$QG" design-review-record "E-RR" --design-hash "$DHASH" 2>/dev/null) || R105_RC=$?
assert_eq "10.5 unreadable history: design_review_history_unreadable, exit 2" \
    "2|design_review_history_unreadable" \
    "$R105_RC|$(json_field '.error_key' "$R105_OUT")"
assert_eq "10.5b ...and NOTHING was written (no add attempt logged for E-RR)" "0" "$(log_hits E-RR)"

# --- 10.6 META: strip the history guard, watch the duplicate write land ---
QG_MUT10B="$SCRIPTS/qa-gate.mutant-s10b.sh"
AWK10B_RC=0
awk '/# DESIGN-REVIEW-HISTORY-GUARD BEGIN \(xsu1 H2R2-F3\)/{skip=1; found=1; next}
     /# DESIGN-REVIEW-HISTORY-GUARD END \(xsu1 H2R2-F3\)/{skip=0; next}
     !skip{print}
     END{if(!found) exit 7}' "$QG" > "$QG_MUT10B" || AWK10B_RC=$?
assert_eq "10.6 NON-VACUITY: the history-guard strip found its region" "0" "$AWK10B_RC"
BASHN10B_RC=0; bash -n "$QG_MUT10B" 2>/dev/null || BASHN10B_RC=$?
assert_eq "10.6b ...and still parses" "0" "$BASHN10B_RC"
chmod 0755 "$QG_MUT10B"
M10B_RC=0
M10B_OUT=$(printf '%s' "$VERDICT_DUP" | PATH="$FIXTURE/shim-rsel:$PATH" bash "$QG_MUT10B" design-review-record "E-RRM" --design-hash "$DHASH" 2>/dev/null) || M10B_RC=$?
assert_eq "10.6c SPECIFIC MISBEHAVIOUR: the mutant records a verdict over the unread history" \
    "0|recorded" \
    "$M10B_RC|$(json_field '.status' "$M10B_OUT")"
assert_eq "10.6d ...materializing a DUPLICATE iteration=1 DESIGN-REVIEW in the store (the write the B2/P6 check exists to refuse)" "2" \
    "$("$REAL_JQ" -r '[.comments[].text | select(startswith("DESIGN-REVIEW v1 ")) | select(test(" iteration=1 "))] | length' "$BD_FIXTURE_DIR/E-RRM.json")"
rm -f "$QG_MUT10B"

# --- 10.7 the guard fronts a REAL downstream check ------------------------
R107_RC=0
R107_OUT=$(printf '%s' "$VERDICT_DUP" | bash "$QG" design-review-record "E-RR" --design-hash "$DHASH" 2>/dev/null) || R107_RC=$?
assert_eq "10.7 RESTORE CONTROL: shipped script, readable history, same duplicate verdict — the EXISTING iteration-advance refusal fires" \
    "1|design_review_iteration_not_advancing" \
    "$R107_RC|$(json_field '.error_key' "$R107_OUT")"

# ===========================================================================
printf '\n=== Section 11: R7-F4 — the validator said it failed; believe it ===\n'
# ===========================================================================
# The three validate-design consumers (design-record, design-unit-bind,
# design-conform step 3) used to run the validator with `|| true` and
# compare `jq -r '.ok // false'` textually. Two vectors through that:
#   (a) a SHAPE-PERFECT ok:true envelope from a validator that EXITS
#       NONZERO — a command reporting its own failure out-of-band;
#   (b) `"ok": "true"` — a JSON STRING — which `jq -r` renders identically
#       to the boolean.
# validate_design_envelope_ok is the ONE consumer-side gate for all three
# sites (rc 0 first, then exact types field by field, `.ok == true`
# type-strict). The stubs below are swapped into the FIXTURE review-check.sh
# — the support copy qa-gate resolves via CLAUDE_PROJECT_DIR — never the
# canonical file.

assert_eq "11.0 the rc-gate sentinels are unique in the shipped script" "1|1" \
    "$(grep -cF '# VALIDATE-DESIGN-CONSUMER-RC-GATE BEGIN (xsu1 R7-F4)' "$QG")|$(grep -cF '# VALIDATE-DESIGN-CONSUMER-RC-GATE END (xsu1 R7-F4)' "$QG")"
assert_eq "11.0b the type-strict ok line is unique (the META-2 mutation target)" "1" \
    "$(grep -cF 'and .ok == true  # type-strict' "$QG")"
# shellcheck disable=SC2016  # the grep -cF needle is literal shell source.
assert_eq "11.0c the helper is wired at all three consumer sites" "3" \
    "$(grep -cF 'if ! validate_design_envelope_ok "$vout_rc" "$vout"; then' "$QG")"

RC_FIXTURE="$SCRIPTS/review-check.sh"
cp "$RC_FIXTURE" "$SCRIPTS/review-check.real.sh"
# Stub (a): a shape-perfect ok:true envelope + exit 3. Everything a
# pre-R7-F4 consumer looked at says "success"; only the exit status tells
# the truth.
mk_stub_validator_a() {
    cat > "$RC_FIXTURE" <<'STUB'
#!/bin/bash
printf '{"ok":true,"subcommand":"validate-design","error_key":"","observations":"stub-a","units":2,"unit_ids":["U1","U2"],"task_id":"%TASKID%","unit_files":{"U1":["src/a.sh"],"U2":["src/b.sh"]},"unit_deps":{"U1":[],"U2":[]}}\n'
exit 3
STUB
    sed -i.bak "s/%TASKID%/$1/" "$RC_FIXTURE" && rm -f "$RC_FIXTURE.bak"
    chmod 0755 "$RC_FIXTURE"
}
# Stub (b): ok as the STRING "true", exit 0 — the jq -r rendering trap.
mk_stub_validator_b() {
    cat > "$RC_FIXTURE" <<'STUB'
#!/bin/bash
printf '{"ok":"true","subcommand":"validate-design","error_key":"","observations":"stub-b","units":2,"unit_ids":["U1","U2"],"task_id":"%TASKID%","unit_files":{"U1":["src/a.sh"],"U2":["src/b.sh"]},"unit_deps":{"U1":[],"U2":[]}}\n'
exit 0
STUB
    sed -i.bak "s/%TASKID%/$1/" "$RC_FIXTURE" && rm -f "$RC_FIXTURE.bak"
    chmod 0755 "$RC_FIXTURE"
}
restore_validator() { cp "$SCRIPTS/review-check.real.sh" "$RC_FIXTURE"; chmod 0755 "$RC_FIXTURE"; }

# --- 11.1/11.2: the bind site refuses both vectors, before any write --------
bind_fixture "T-VDX" empty
mk_stub_validator_a "E-DESIGN"
V11A_RC=0
V11A_OUT=$(bash "$QG" design-unit-bind "T-VDX" --design-task E-DESIGN --unit-id U1 2>/dev/null) || V11A_RC=$?
assert_eq "11.1 vector (a) ok:true + exit 3: refused, the validator's own failure is believed" \
    "1|invalid_design_artifact" \
    "$V11A_RC|$(json_field '.error_key' "$V11A_OUT")"
assert_eq "11.1b ...the refusal names the out-of-band exit (validator exit rc=3)" "yes" \
    "$(printf '%s' "$(json_field '.observations' "$V11A_OUT")" | grep -qF 'validator exit rc=3' && echo yes || echo no)"
assert_eq "11.1c ...and nothing was written" "0" "$(log_hits T-VDX)"
mk_stub_validator_b "E-DESIGN"
V11B_RC=0
V11B_OUT=$(bash "$QG" design-unit-bind "T-VDX" --design-task E-DESIGN --unit-id U1 2>/dev/null) || V11B_RC=$?
assert_eq "11.2 vector (b) ok:\"true\" STRING + exit 0: refused — jq -r rendered it as true, jq's == does not" \
    "1|invalid_design_artifact|0" \
    "$V11B_RC|$(json_field '.error_key' "$V11B_OUT")|$(log_hits T-VDX)"
# --- 11.3 restore control ----------------------------------------------------
restore_validator
V11C_RC=0
V11C_OUT=$(bash "$QG" design-unit-bind "T-VDX" --design-task E-DESIGN --unit-id U1 2>/dev/null) || V11C_RC=$?
assert_eq "11.3 RESTORE CONTROL: real validator, same task, binds normally" "0|recorded" \
    "$V11C_RC|$(json_field '.status' "$V11C_OUT")"

# --- 11.4 META-1: strip the rc gate, watch vector (a) get recorded ----------
QG_MUT11="$SCRIPTS/qa-gate.mutant-s11.sh"
AWK11_RC=0
awk '/# VALIDATE-DESIGN-CONSUMER-RC-GATE BEGIN \(xsu1 R7-F4\)/{skip=1; found=1; next}
     /# VALIDATE-DESIGN-CONSUMER-RC-GATE END \(xsu1 R7-F4\)/{skip=0; next}
     !skip{print}
     END{if(!found) exit 7}' "$QG" > "$QG_MUT11" || AWK11_RC=$?
assert_eq "11.4 NON-VACUITY: the rc-gate strip found its region" "0" "$AWK11_RC"
assert_eq "11.4b ...and the mutant differs from the shipped bytes" "differs" \
    "$(cmp -s "$QG" "$QG_MUT11" && echo same || echo differs)"
BASHN11_RC=0; bash -n "$QG_MUT11" 2>/dev/null || BASHN11_RC=$?
assert_eq "11.4c ...and still parses" "0" "$BASHN11_RC"
chmod 0755 "$QG_MUT11"
bind_fixture "T-MUTA" empty
mk_stub_validator_a "E-DESIGN"
M11A_RC=0
M11A_OUT=$(bash "$QG_MUT11" design-unit-bind "T-MUTA" --design-task E-DESIGN --unit-id U1 2>/dev/null) || M11A_RC=$?
assert_eq "11.4d SPECIFIC MISBEHAVIOUR: without the rc gate, a validator that EXITED 3 gets its binding recorded anyway" \
    "0|recorded|U1" \
    "$M11A_RC|$(json_field '.status' "$M11A_OUT")|$(latest_unit_of T-MUTA)"
restore_validator
rm -f "$QG_MUT11"
# 11.1 above is the shipped-bytes restore control for this pair.

# --- 11.5 META-2: relax the type-strict ok, watch vector (b) recorded -------
QG_MUT11B="$SCRIPTS/qa-gate.mutant-s11b.sh"
# shellcheck disable=SC2016  # the sed strings quote jq SOURCE verbatim.
sed 's/and \.ok == true  # type-strict: the STRING "true" must not pass (R7-F4)/and (.ok | tostring) == "true"/' \
    "$QG" > "$QG_MUT11B"
# shellcheck disable=SC2016  # grep -cF needles are literal jq source.
assert_eq "11.5 NON-VACUITY: type-strict line shipped/mutant = 1/0, textual-compare mutant line = 0/1" "1|0|0|1" \
    "$(grep -cF 'and .ok == true  # type-strict' "$QG")|$(grep -cF 'and .ok == true  # type-strict' "$QG_MUT11B")|$(grep -cF 'and (.ok | tostring) == "true"' "$QG")|$(grep -cF 'and (.ok | tostring) == "true"' "$QG_MUT11B")"
BASHN11B_RC=0; bash -n "$QG_MUT11B" 2>/dev/null || BASHN11B_RC=$?
assert_eq "11.5b ...and the mutant parses" "0" "$BASHN11B_RC"
chmod 0755 "$QG_MUT11B"
bind_fixture "T-MUTB" empty
mk_stub_validator_b "E-DESIGN"
M11B_RC=0
M11B_OUT=$(bash "$QG_MUT11B" design-unit-bind "T-MUTB" --design-task E-DESIGN --unit-id U1 2>/dev/null) || M11B_RC=$?
assert_eq "11.5c SPECIFIC MISBEHAVIOUR: with a tostring compare, the STRING \"true\" reads as success and the binding records" \
    "0|recorded|U1" \
    "$M11B_RC|$(json_field '.status' "$M11B_OUT")|$(latest_unit_of T-MUTB)"
restore_validator
rm -f "$QG_MUT11B"
# 11.2 above is the shipped-bytes restore control for this pair.

# --- 11.6 the design-record site is wired to the same gate ------------------
# shellcheck disable=SC2016  # {text:$g} is a jq program variable.
jq_w --arg g "GRILLING v1 rounds=2 questions=5 approaches=2 unresolved=0 vendor_hash=$(printf 'b%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64) at 2026-08-25T00:00:00Z: done" \
    '{id:"T-REC", status:"open", labels:[], comments:[{text:$g}]}' > "$BD_FIXTURE_DIR/T-REC.json"
sed 's/"task_id": "E-DESIGN",/"task_id": "T-REC",/' "$FIXTURE/docs/specs/E-DESIGN.md" > "$FIXTURE/docs/specs/T-REC.md"
mkdir -p "$FIXTURE/.claude/.qa-tracking"
printf 'docs/specs/T-REC.md\n' > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
mk_stub_validator_a "T-REC"
R116_RC=0
R116_OUT=$(bash "$QG" design-record "T-REC" 2>/dev/null) || R116_RC=$?
assert_eq "11.6 design-record + vector (a): refused, nothing recorded" \
    "1|invalid_design_artifact|0" \
    "$R116_RC|$(json_field '.error_key' "$R116_OUT")|$(log_hits T-REC)"
restore_validator
R116C_RC=0
R116C_OUT=$(bash "$QG" design-record "T-REC" 2>/dev/null) || R116C_RC=$?
assert_eq "11.6b CONTROL: real validator, same task, records" "0|recorded|yes" \
    "$R116C_RC|$(json_field '.status' "$R116C_OUT")|$( [ "$(log_hits T-REC)" != "0" ] && echo yes || echo no )"

# --- 11.7 the design-conform site is wired to the same gate -----------------
LIVE_EDESIGN=$(bash "$WM" hash-file "$FIXTURE/docs/specs/E-DESIGN.md")
# shellcheck disable=SC2016  # {text:$a},{text:$r} are jq program variables.
jq_w --arg a "DESIGN-ARTIFACT v1 task=E-DESIGN designer=designer-claude design_hash=$LIVE_EDESIGN at 2026-08-25T00:00:00Z: recorded" \
     --arg r "DESIGN-REVIEW v1 task=E-DESIGN reviewer=design-claude verdict=satisfied design_hash=$LIVE_EDESIGN iteration=1 rubric_version=v1 at 2026-08-25T00:00:01Z: satisfied" \
     '{id:"E-DESIGN", status:"open", labels:[], comments:[{text:$a},{text:$r}]}' > "$BD_FIXTURE_DIR/E-DESIGN.json"
bind_fixture "T-CFM2" bound
mkdir -p "$FIXTURE/src"; touch "$FIXTURE/src/a.sh"
printf 'src/a.sh\n' > "$FIXTURE/.claude/.qa-tracking/changed-files.txt"
mk_stub_validator_a "E-DESIGN"
R117_RC=0
R117_OUT=$(bash "$QG" design-conform "T-CFM2" 2>/dev/null) || R117_RC=$?
assert_eq "11.7 design-conform + vector (a): refused at step 3, before any change-set work" \
    "4|invalid_design_artifact" \
    "$R117_RC|$(json_field '.error_key' "$R117_OUT")"
restore_validator
R117C_RC=0
R117C_OUT=$(bash "$QG" design-conform "T-CFM2" 2>/dev/null) || R117C_RC=$?
assert_eq "11.7b CONTROL: real validator, same task, conforms end to end" "0|true|[]" \
    "$R117C_RC|$(json_field '.ok' "$R117C_OUT")|$(json_field '.undeclared_files | tojson' "$R117C_OUT")"
rm -f "$SCRIPTS/review-check.real.sh"

# ===========================================================================
printf '\n=== Summary ===\n'
# ===========================================================================
printf '\nTotal: %d assertion(s) run\n' "$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d assertion(s)\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
