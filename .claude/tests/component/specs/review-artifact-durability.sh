#!/bin/bash
# review-artifact-durability.sh — L2 component spec for claude-workflow-plugin-rqer
# (v5 D2): the review artifact now PERSISTS across a completed approve, is
# NAMED BY HASH from the bd record, and ENTERS THE CHANGE SET the approval
# binds.
#
# THE DEFECT THIS PINS. wipe_review_artifacts() (qa-gate.sh) deleted the
# review artifact on every completed approve — by design, per its own
# header — so the reviewer's own evidence never outlived the review cycle,
# and no token in the REVIEW-ARTIFACT v1 grammar named the artifact's bytes.
# The fix moves the artifact's canonical home to a committed, task-derived
# path OUTSIDE .claude/.qa-tracking/ (review_artifact_path_for, qa-gate.sh),
# adds an artifact_hash=<64 hex> token to the record (produced by the same
# workflow-manifest.sh hash-file instrument the design side already uses),
# and leaves the path reachable by no glob in wipe_review_artifacts.
#
# WHY THE EXISTING LEG (component/specs/codex-review.sh:85-104) CANNOT CATCH
# THIS: it drives the Sol-lane writer against a stub server and asserts a
# valid artifact is written, but it never calls `approve` — the exact
# boundary this defect lives on. This spec crosses that boundary.
#
# Leg A drives the SHIPPED claude-lane path (qa-gate.sh review-record via
# stdin — no node/stub-server dependency, and the same mechanism that closes
# the "no shipped code writes the Claude-lane artifact" gap by consequence:
# see the closing section below) through a REAL approve, over a REAL git
# repo (reconcile_tracker needs git-visible dirt to discover). Legs B and C
# are negative controls: mutate a COPY of qa-gate.sh (put the canonical
# directory back in the wipe) and a COPY of workflow-denylist.sh (widen
# WORKFLOW_SELF_WRITTEN_REGEX to cover it), and prove each collapses the
# exact property Leg A pins — never against the real tree (.claude/tests/
# README.md "The pairing requirement").
#
#   Leg A  AC-1..AC-6, driven end to end: derived path, artifact_hash= token,
#          change-set membership, survival across approve, and the
#          non-self-referential hash triad (reviewed_hash / artifact_hash /
#          change_set_hash).
#   Leg B  mutation 1 — extend wipe_review_artifacts to the canonical dir.
#   Leg C  mutation 2 — widen WORKFLOW_SELF_WRITTEN_REGEX to the canonical dir.
#
# RED-BEFORE-FIX (measured against the committed pre-fix qa-gate.sh via
# `git show HEAD:...`, never against the real tree — see this task's
# completion report for the exact commands and output): review-record
# accepted the stdin artifact unconditionally (ok:true), wrote nothing at
# any canonical path, and posted a REVIEW-ARTIFACT v1 record with zero
# artifact_hash= tokens. Leg A's steps 2-4 are exactly the assertions that
# red state fails.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
RCHECK="$FIXTURE/.claude/scripts/review-check.sh"
WM="$FIXTURE/.claude/scripts/workflow-manifest.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"

# A REAL git repo: reconcile_tracker (AC-4's mechanism) only discovers
# git-visible dirt, and the mutations in Legs B/C are measured against real
# approve/reconcile behaviour, not a git-less degraded mode.
(cd "$FIXTURE" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# ---------------------------------------------------------------------------
# Shared helpers.

# derived_path <root> <tid> <iter> — the EXPECTED canonical path, spelled out
# independently of review_artifact_path_for (never a call into the function
# under test), so a regression in the derivation itself has no self-reference
# to hide behind.
derived_path() {
    printf '%s/docs/reviews/%s-r%s.json' "$1" "$2" "$3"
}

# artifact_json <tid> <hash> — a valid, findings-free review artifact.
artifact_json() {
    # artifact_json <tid> <hash> [iteration=1]
    jq -nc --arg tid "$1" --arg hash "$2" --argjson it "${3:-1}" \
        '{contract_version:"1",task_id:$tid,reviewer_identity:"qa-claude",
          reviewer_model:"claude-fable-5",reviewer_pin:"claude-fable-5",
          reviewed_hash:$hash,risk_threshold:"high",
          stop_condition:"every acceptance criterion traced to a test",
          verdict:"approve",findings:[],iterations:$it,stopped_by:"verdict"}'
}

# latest_review_artifact_comment <root> <tid> — the LAST REVIEW-ARTIFACT v1
# firstline, through the real bd_show_with_comments (never a raw `bd show`).
latest_review_artifact_comment() {
    ( cd "$1" && bd_show_with_comments "$2" ) \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
        | grep -E '^REVIEW-ARTIFACT v1 ' | tail -1
}

# latest_approval_comment <root> <tid> — the LAST QA-GATE APPROVED firstline.
latest_approval_comment() {
    ( cd "$1" && bd_show_with_comments "$2" ) \
        | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null \
        | grep -E '^QA-GATE APPROVED ' | tail -1
}

# hash_without_path <tracker-file> <path> — the SAME canonicalisation
# impact-report.sh uses (LC_ALL=C sort -u | sha256), applied to the tracker
# with exactly <path> removed. Used to PROVE membership (AC-6's "the approval
# names a superset of what was reviewed") rather than merely assert it.
hash_without_path() {
    grep -vF "$2" "$1" 2>/dev/null | LC_ALL=C sort -u | shasum -a 256 2>/dev/null | awk '{print $1}'
}

# run_cycle <qagate-path> <root> <tid> <src-file> — drives enter, an
# IMPLEMENTER record, review-record (stdin — the claude lane), reconcile,
# an impact-report regeneration (AC-6's ordering: reconcile BEFORE
# regenerating, or approve's own reconcile moves the tracker a second time —
# see qa-gate.sh's cmd_review_record / cmd_approve comments for the same
# note), a completion record (F7 — approve refuses without one), and approve,
# ALL through the GIVEN qa-gate.sh copy. Globals set on return:
#   RC_CANONICAL   the expected canonical artifact path
#   RC_APPROVE_OUT approve's own JSON-ish envelope (stdout+stderr)
#   RC_APPROVE_RC  approve's exit code
#   RC_PRE_HASH    change_set_hash WITH the artifact (post-reconcile, pre-approve)
#   RC_WITHOUT_HASH change_set_hash of the SAME tracker with the artifact's
#                  own line removed (AC-6's membership proof)
# run_cycle_pre_approve <qagate-path> <root> <tid> <src-file> — everything
# UP TO but NOT INCLUDING approve, so a caller can assert on tracker
# membership (AC-4) before a successful approve truncates changed-files.txt.
# Call run_cycle_approve next to complete the cycle.
run_cycle_pre_approve() {
    local qg="$1" root="$2" tid="$3" srcfile="$4"
    local track="$root/.claude/.qa-tracking"
    printf '%s\n' "$srcfile" > "$track/changed-files.txt"
    CLAUDE_PROJECT_DIR="$root" bash "$qg" enter "$tid" >/dev/null 2>&1
    ( cd "$root" && bd comments add "$tid" \
        "IMPLEMENTER: role=backend task=$tid at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1 )

    local hash
    hash=$(CLAUDE_PROJECT_DIR="$root" bash "$IR" --hash-only 2>/dev/null || echo "")
    RC_CANONICAL=$(derived_path "$root" "$tid" 1)
    artifact_json "$tid" "$hash" \
        | CLAUDE_PROJECT_DIR="$root" bash "$qg" review-record "$tid" >/dev/null 2>&1

    CLAUDE_PROJECT_DIR="$root" bash "$qg" reconcile-tracker >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$root" bash "$IR" "$tid" >/dev/null 2>&1
    RC_PRE_HASH=$(CLAUDE_PROJECT_DIR="$root" bash "$IR" --hash-only 2>/dev/null || echo "")
    RC_WITHOUT_HASH=$(hash_without_path "$track/changed-files.txt" "$RC_CANONICAL")
}

# run_cycle_approve <qagate-path> <root> <tid> <src-file> — the completion
# record + approve, run AFTER the caller has asserted on the pre-approve
# tracker state.
run_cycle_approve() {
    local qg="$1" root="$2" tid="$3" srcfile="$4"
    local pay="$root/.claude/.qa-tracking/.rqer-completion-$tid.json"
    printf '{"task_id":"%s","role":"backend","model":"seeded","pin":"seeded","files_changed":["%s"],"tests_added":[],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by review-artifact-durability.sh","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}' \
        "$tid" "$srcfile" > "$pay"
    CLAUDE_PROJECT_DIR="$root" bash "$qg" completion-record "$tid" --file "$pay" >/dev/null 2>&1

    # v5 D2 (claude-workflow-plugin-fkm.4) MIGRATION, R2-F1: approve
    # additionally refuses (exit 2, no_design_attempted) without a satisfied
    # design verdict. --no-design here, deliberately NOT a seeded
    # design-record: this whole spec is precision hash arithmetic over
    # changed-files.txt (RC_PRE_HASH / RC_WITHOUT_HASH / the membership proofs
    # in AC-6/Leg C) — a real design-record would add docs/specs/<tid>.md as
    # ANOTHER real tracked path on top of the review artifact this spec is
    # already isolating, multiplying the paths every hash-subtraction leg has
    # to account for, for a phenomenon (design review) this spec is not about.
    RC_APPROVE_OUT=$(CLAUDE_PROJECT_DIR="$root" bash "$qg" approve "$tid" --no-design "review-artifact-durability spec: no design phase; isolating review-artifact hash mechanics" "reviewed and approved (review-artifact-durability.sh)" 2>&1)
    RC_APPROVE_RC=$?
}

# run_cycle <qagate-path> <root> <tid> <src-file> — the full cycle, for
# callers that do not need to inspect the pre-approve tracker state
# themselves (Legs B/C's own precondition/RESTORE runs).
run_cycle() {
    run_cycle_pre_approve "$1" "$2" "$3" "$4"
    run_cycle_approve "$1" "$2" "$3" "$4"
}

# ===========================================================================
# LEG A — EXECUTION: drive the shipped scripts end to end, AC-1 through AC-6.
# ===========================================================================
TID_A=$(cd "$FIXTURE" && bd create "rqer Leg A" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
assert_eq "Leg A: precondition — the fixture task was created" "1" "$([ -n "$TID_A" ] && echo 1 || echo 0)"

run_cycle_pre_approve "$QG" "$FIXTURE" "$TID_A" "src/a-feature.ts"

# --- step 2: canonical path exists and validates -------------------------
assert_eq "Leg A step 2: the canonical artifact exists at the derived path" "1" \
    "$([ -f "$RC_CANONICAL" ] && echo 1 || echo 0)"
VOUT=$(bash "$RCHECK" validate-artifact "$RC_CANONICAL" 2>/dev/null)
assert_json_field "Leg A step 2: the canonical artifact validates (.ok==true)" "$VOUT" ".ok|tostring" "true"

# --- step 3: H0 = hash-file <canonical> ----------------------------------
H0=$(bash "$WM" hash-file "$RC_CANONICAL" 2>/dev/null)
assert_match "Leg A step 3: H0 is a real 64-hex sha256 digest" '^[0-9a-f]{64}$' "$H0"

# --- step 4: the REVIEW-ARTIFACT v1 record carries artifact_hash=$H0 ------
ART_COMMENT=$(latest_review_artifact_comment "$FIXTURE" "$TID_A")
assert_contains "Leg A step 4: the posted record carries artifact_hash=\$H0" \
    "artifact_hash=$H0" "$ART_COMMENT"

# --- step 5: the canonical path is in changed-files.txt (AC-4) ------------
# Checked BEFORE approve runs: a successful approve truncates
# changed-files.txt (0wk.2), so this membership claim has to be observed at
# the one point in the cycle where it is still there to observe.
assert_eq "Leg A step 5: the canonical path entered the tracker" "1" \
    "$(grep -cF "$RC_CANONICAL" "$FIXTURE/.claude/.qa-tracking/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"

run_cycle_approve "$QG" "$FIXTURE" "$TID_A" "src/a-feature.ts"

# --- step 6: approve completes ---------------------------------------------
assert_eq "Leg A step 6: approve exits 0" "0" "$RC_APPROVE_RC"
assert_contains "Leg A step 6: qa-approved is set" '"status":"approved"' "$RC_APPROVE_OUT"
LBL=$(cd "$FIXTURE" && bd show "$TID_A" --json 2>/dev/null | jq -r '(if type=="array" then .[0] else . end).labels | join(",")' 2>/dev/null)
assert_contains "Leg A step 6: the task carries qa-approved" "qa-approved" "$LBL"

# --- step 7 (AC-5): the canonical file SURVIVES approve, unchanged --------
assert_eq "Leg A step 7: the canonical artifact still EXISTS after approve" "1" \
    "$([ -f "$RC_CANONICAL" ] && echo 1 || echo 0)"
H0_AFTER=$(bash "$WM" hash-file "$RC_CANONICAL" 2>/dev/null)
assert_eq "Leg A step 7: ...and still hashes to H0 (byte-identical)" "$H0" "$H0_AFTER"

# --- step 8 (AC-6): membership, proved rather than asserted ---------------
APPROVAL_COMMENT=$(latest_approval_comment "$FIXTURE" "$TID_A")
APPROVED_HASH=$(printf '%s' "$APPROVAL_COMMENT" | sed -nE 's/.*change_set_hash=([A-Za-z0-9-]+).*/\1/p' | head -1)
assert_match "Leg A step 8: the approval record carries a real change_set_hash" '^[0-9a-f]{64}$' "$APPROVED_HASH"
assert_eq "Leg A step 8: ...and it is the WITH-artifact hash this cycle reconciled to" \
    "$RC_PRE_HASH" "$APPROVED_HASH"
assert_eq "Leg A step 8: ...which DIFFERS from the hash of the tracker with the artifact removed (membership, not assertion)" \
    "1" "$([ "$APPROVED_HASH" != "$RC_WITHOUT_HASH" ] && echo 1 || echo 0)"

# AC-6's non-self-referential triad: reviewed_hash (pre-artifact, a claim
# about the past) must never equal change_set_hash (post-artifact) on a task
# where the artifact is IN the change set — otherwise the "fixpoint" AC-6
# names would be real rather than resolved.
REVIEWED_HASH_TOKEN=$(printf '%s' "$ART_COMMENT" | sed -nE 's/.*reviewed_hash=([A-Za-z0-9._-]+).*/\1/p' | head -1)
assert_eq "Leg A / AC-6: reviewed_hash (pre-artifact) is never equal to change_set_hash (post-artifact) here" \
    "1" "$([ "$REVIEWED_HASH_TOKEN" != "$APPROVED_HASH" ] && echo 1 || echo 0)"

# AC-2: the canonical path is NOT gitignored (only .claude/.qa-tracking/ is).
GITIGNORE_RC=0
( cd "$FIXTURE" && git check-ignore -v "$RC_CANONICAL" >/dev/null 2>&1 ) || GITIGNORE_RC=$?
assert_eq "Leg A / AC-2: the canonical path is NOT gitignored" "1" "$([ "$GITIGNORE_RC" -ne 0 ] && echo 1 || echo 0)"

# AC-1 (--file must ASSERT the derivation, not supply one): a non-derived
# --file is refused; the derived one (this task's own canonical path, at a
# NEW iteration) is accepted.
BAD_FILE="$FIXTURE/not-the-derived-path.json"
cp "$RC_CANONICAL" "$BAD_FILE" 2>/dev/null || true
BAD_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$TID_A" --file "$BAD_FILE" 2>/dev/null)
assert_json_field "Leg A / AC-1: --file naming a non-derived path is refused" "$BAD_OUT" ".ok|tostring" "false"
assert_json_field "Leg A / AC-1: ...naming the refusal" "$BAD_OUT" ".error_key" "artifact_path_not_derived"

# AC-1 (symlink escape): a symlink AT the derived path for a FRESH iteration,
# pointing outside docs/reviews/, must not be accepted and hashed.
OUTSIDE="$FIXTURE/outside-secret.json"
artifact_json "$TID_A" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2 > "$OUTSIDE"
ESCAPE_PATH=$(derived_path "$FIXTURE" "$TID_A" 2)
mkdir -p "$(dirname "$ESCAPE_PATH")"
ln -sf "$OUTSIDE" "$ESCAPE_PATH"
ESCAPE_OUT=$(artifact_json "$TID_A" "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef" 2 | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$TID_A" --file "$ESCAPE_PATH" 2>/dev/null)
assert_json_field "Leg A / AC-1: a symlink at the derived path escaping the dir is refused" \
    "$ESCAPE_OUT" ".ok|tostring" "false"
assert_json_field "Leg A / AC-1: ...naming the escape" "$ESCAPE_OUT" ".error_key" "artifact_outside_review_dir"
rm -f "$ESCAPE_PATH" "$OUTSIDE" "$BAD_FILE"

# AC-3 (mutate one byte after review-record, then approve must not claim a
# verified binding): corrupt the canonical file post-record and confirm the
# NEXT approve's own re-verification ladder withholds the token.
printf 'x' >> "$RC_CANONICAL"
CORRUPT_TID="$TID_A"
# fkm.4 R2-F1: same --no-design reasoning as run_cycle_approve above. This is
# a SECOND approve on an already-approved task; the idempotency short-circuit
# (gz3) only fires when an existing record already binds the CURRENT change
# set, and the corruption changes what reconcile/impact-report see, so this
# does not take that path — it re-verifies every precondition, design
# included, exactly like the first approve does.
CORRUPT_OUT=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" reconcile-tracker 2>&1
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" "$CORRUPT_TID" >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" approve "$CORRUPT_TID" --no-design "review-artifact-durability spec: no design phase; isolating review-artifact hash mechanics" "second approve after corrupting the artifact" 2>&1)
assert_not_contains "Leg A / AC-3: a one-byte post-record edit means the NEXT approve claims no verified binding" \
    "review-artifact binding VERIFIED" "$CORRUPT_OUT"
assert_contains "Leg A / AC-3: ...and says so by name" \
    "no review-artifact binding" "$CORRUPT_OUT"

printf 'Leg A: PASSED — AC-1 through AC-6 driven end to end against the shipped scripts.\n'

# ===========================================================================
# LEG B — NEGATIVE CONTROL 1: put the canonical path back in the wipe.
#
# Mutant: extend wipe_review_artifacts (qa-gate.sh) to ALSO glob the
# canonical review-artifact directory — the exact pre-fix behaviour, applied
# only to this one path.
# ===========================================================================
mk_fixture
FIXTURE_B="$COMPONENT_FIXTURE_PATH"
(cd "$FIXTURE_B" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

QG_SHIPPED="$(plugin_root)/.claude/scripts/qa-gate.sh"
MUT_B="$FIXTURE_B/qa-gate-mutant-b.sh"
# Insert BEFORE the function's `return 0`, not before its closing `}` — the
# first attempt at this mutation landed the injected rm AFTER `return 0`,
# which made it dead code that never ran (measured: assert_mutant_applied
# and a literal-text grep both passed, because the BYTES differ, but the
# mutant behaved identically to the shipped script at runtime — exactly the
# non-vacuity gap the pairing requirement's part 1 exists to catch. Anchoring
# on `return 0` inside the function, not on the closing brace, is what makes
# the inserted line part of the function's LIVE control flow.
awk '
    /^wipe_review_artifacts\(\) \{$/ { print; infn=1; next }
    infn && /^    return 0$/ {
        print "    rm -f \"$PROJECT_DIR/docs/reviews/$tid\"-r*.json \"$PROJECT_DIR/docs/reviews/$sanitized\"-r*.json 2>/dev/null || true"
        print
        infn=0
        next
    }
    { print }
' "$QG_SHIPPED" > "$MUT_B"
chmod +x "$MUT_B"

assert_mutant_applied "Leg B" "$QG_SHIPPED" "$MUT_B"
assert_eq "Leg B: the injected glob is present in the mutant" "1" \
    "$(grep -c 'docs/reviews/\$tid' "$MUT_B" | tr -d '[:space:]')"
assert_eq "Leg B: the mutant still parses as bash" "1" \
    "$(bash -n "$MUT_B" 2>/dev/null && echo 1 || echo 0)"

# The mutant needs workflow-denylist.sh etc. as SIBLINGS (BASH_SOURCE-relative
# sourcing) — copy it into the fixture's own scripts dir rather than running
# it from an unrelated directory, matching how design-artifact.test.sh /
# qa-gate-grade-record.test.sh isolate CLAUDE_PROJECT_DIR (never against the
# real tree).
cp "$MUT_B" "$FIXTURE_B/.claude/scripts/qa-gate.sh.mutant"
chmod +x "$FIXTURE_B/.claude/scripts/qa-gate.sh.mutant"

TID_B=$(cd "$FIXTURE_B" && bd create "rqer Leg B (mutant)" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
run_cycle "$FIXTURE_B/.claude/scripts/qa-gate.sh.mutant" "$FIXTURE_B" "$TID_B" "src/b-feature.ts"

assert_eq "Leg B: precondition — approve still succeeds under the mutant (only the wipe changed)" \
    "0" "$RC_APPROVE_RC"
# THE SPECIFIC MISBEHAVIOUR, named: the artifact is gone, so the artifact_hash=
# recorded in the bd comment now names bytes nothing can produce, and a
# docs/RELEASE_AUDIT.md-style citation of this path becomes dangling.
assert_eq "Leg B MUTANT: step-7 analog — the canonical artifact is GONE after approve (wipe_review_artifacts reached it)" \
    "1" "$([ ! -f "$RC_CANONICAL" ] && echo 1 || echo 0)"
B_ART_COMMENT=$(latest_review_artifact_comment "$FIXTURE_B" "$TID_B")
B_HASH_TOKEN=$(printf '%s' "$B_ART_COMMENT" | sed -nE 's/.*artifact_hash=([A-Za-z0-9._-]+).*/\1/p' | head -1)
assert_match "Leg B MUTANT: ...and the record's artifact_hash= still names bytes (now dangling — nothing on disk can reproduce it)" \
    '^[0-9a-f]{64}$' "$B_HASH_TOKEN"

# RESTORE CONTROL: same fixture shape, shipped script, FRESH task — survives.
TID_B_RESTORE=$(cd "$FIXTURE_B" && bd create "rqer Leg B (restore control)" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
run_cycle "$QG_SHIPPED" "$FIXTURE_B" "$TID_B_RESTORE" "src/b-restore.ts"
assert_eq "Leg B RESTORE: precondition — approve succeeds" "0" "$RC_APPROVE_RC"
assert_eq "Leg B RESTORE: the shipped script's canonical artifact SURVIVES approve (step 7, green)" \
    "1" "$([ -f "$RC_CANONICAL" ] && echo 1 || echo 0)"

printf 'Leg B: PASSED — the mutant collapses AC-5, the restore control does not.\n'

# ===========================================================================
# LEG C — NEGATIVE CONTROL 2: widen WORKFLOW_SELF_WRITTEN_REGEX to the
# canonical directory — the exact condition that holds today for
# .claude/.qa-tracking/.
# ===========================================================================
mk_fixture
FIXTURE_C="$COMPONENT_FIXTURE_PATH"
(cd "$FIXTURE_C" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

DL_LIVE="$FIXTURE_C/.claude/scripts/workflow-denylist.sh"
DL_REAL=$(readlink "$DL_LIVE" 2>/dev/null || printf '%s' "$DL_LIVE")
rm -f "$DL_LIVE"
cp "$DL_REAL" "$DL_LIVE"
chmod +x "$DL_LIVE"
sed -i.bak "s#^WORKFLOW_SELF_WRITTEN_REGEX='#WORKFLOW_SELF_WRITTEN_REGEX='(^|/)docs/reviews/|#" "$DL_LIVE"
rm -f "$DL_LIVE.bak"

assert_mutant_applied "Leg C" "$DL_REAL" "$DL_LIVE"
assert_eq "Leg C: the mutated lib still parses" "1" \
    "$(bash -n "$DL_LIVE" 2>/dev/null && echo 1 || echo 0)"

# NON-VACUITY, precisely (the shipped values this task's audit measured):
# keep for docs/reviews/…, SELF-WRITTEN for .claude/.qa-tracking/….
MUT_SELF_WRITTEN=$( . "$DL_LIVE"; workflow_self_written "docs/reviews/x-r1.json"; echo $? )
assert_eq "Leg C: the mutated lib now calls docs/reviews/ self-written (returns 0)" "0" "$MUT_SELF_WRITTEN"
SHIPPED_SELF_WRITTEN=$( . "$DL_REAL"; workflow_self_written "docs/reviews/x-r1.json"; echo $? )
assert_eq "Leg C: ...while the SHIPPED lib does not (returns 1)" "1" "$SHIPPED_SELF_WRITTEN"

TID_C=$(cd "$FIXTURE_C" && bd create "rqer Leg C (mutant lib live)" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
run_cycle_pre_approve "$FIXTURE_C/.claude/scripts/qa-gate.sh" "$FIXTURE_C" "$TID_C" "src/c-feature.ts"

# THE SPECIFIC MISBEHAVIOUR, named: the artifact never reaches
# changed-files.txt, so change_set_hash is computed over a set that EXCLUDES
# the evidence — the exact "artifact outside the change set is an artifact no
# approval attests to" failure the operator directive names. Checked BEFORE
# approve, which truncates the tracker unconditionally on success and would
# make this assertion pass vacuously either way if checked after.
assert_eq "Leg C MUTANT: step-5 analog — the canonical path never entered the tracker" \
    "0" "$(grep -cF "$RC_CANONICAL" "$FIXTURE_C/.claude/.qa-tracking/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"

run_cycle_approve "$FIXTURE_C/.claude/scripts/qa-gate.sh" "$FIXTURE_C" "$TID_C" "src/c-feature.ts"
assert_eq "Leg C MUTANT: precondition — approve still succeeds (only membership changed)" \
    "0" "$RC_APPROVE_RC"
C_APPROVAL_COMMENT=$(latest_approval_comment "$FIXTURE_C" "$TID_C")
C_APPROVED_HASH=$(printf '%s' "$C_APPROVAL_COMMENT" | sed -nE 's/.*change_set_hash=([A-Za-z0-9-]+).*/\1/p' | head -1)
assert_eq "Leg C MUTANT: step-8 analog — the approval's change_set_hash EQUALS the without-artifact hash (the artifact was never counted)" \
    "1" "$([ "$C_APPROVED_HASH" = "$RC_WITHOUT_HASH" ] && echo 1 || echo 0)"
# The artifact is still real and hashed correctly by review-record itself —
# this mutation's damage is SCOPED to change-set membership, not to AC-1/AC-3.
assert_eq "Leg C MUTANT: the artifact FILE itself still exists (the damage is membership, not the write)" \
    "1" "$([ -f "$RC_CANONICAL" ] && echo 1 || echo 0)"

# RESTORE CONTROL: shipped lib, fresh task, same fixture — membership holds.
#
# TID_C's OWN artifact (docs/reviews/$TID_C-r1.json) is real and still
# UNCOMMITTED (the mutation kept it out of the TRACKER, not off disk), and
# its approve just baselined "everything dirty right now" — which, at that
# instant, means git's bare `?? docs/reviews/` porcelain line (git collapses
# a wholly-untracked directory to ONE line until something inside it is
# tracked; never expanded per-file at baseline-capture time). Leaving it
# would make TID_C_RESTORE's own fresh artifact reproduce that SAME bare
# line, so reconcile's baseline comparison (94d.1: raw porcelain LINES, not
# content) would read it as "the same pre-existing dirt" and silently drop
# it — measured directly (this failed exactly this way before the commit
# below was added). Committing narrowly makes the directory carry a tracked
# entry, so the NEXT artifact reports as an individual untracked file — a
# line no earlier baseline could have recorded. `>/dev/null 2>&1` on the
# whole subshell: with nothing STAGED, `git commit -q` still prints "nothing
# to commit" to STDOUT, which would otherwise corrupt this section's own
# reasoning (nothing consumes this particular stdout, but the discipline is
# the same one that broke upgrade-gate-compat.sh's new_task() the first time).
if [ -d "$FIXTURE_C/docs/reviews" ] && [ -n "$(ls -A "$FIXTURE_C/docs/reviews" 2>/dev/null)" ]; then
    ( cd "$FIXTURE_C" && git add -- docs/reviews \
        && git commit -qm "checkpoint: commit prior review artifact(s)" ) >/dev/null 2>&1 || true
fi
rm -f "$DL_LIVE"
ln -sf "$DL_REAL" "$DL_LIVE"
TID_C_RESTORE=$(cd "$FIXTURE_C" && bd create "rqer Leg C (restore control)" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
run_cycle_pre_approve "$QG_SHIPPED" "$FIXTURE_C" "$TID_C_RESTORE" "src/c-restore.ts"
assert_eq "Leg C RESTORE: the canonical path DOES enter the tracker (step 5, green)" \
    "1" "$(grep -cF "$RC_CANONICAL" "$FIXTURE_C/.claude/.qa-tracking/changed-files.txt" 2>/dev/null | tr -d '[:space:]')"
run_cycle_approve "$QG_SHIPPED" "$FIXTURE_C" "$TID_C_RESTORE" "src/c-restore.ts"
assert_eq "Leg C RESTORE: precondition — approve succeeds" "0" "$RC_APPROVE_RC"
RESTORE_APPROVAL=$(latest_approval_comment "$FIXTURE_C" "$TID_C_RESTORE")
RESTORE_APPROVED_HASH=$(printf '%s' "$RESTORE_APPROVAL" | sed -nE 's/.*change_set_hash=([A-Za-z0-9-]+).*/\1/p' | head -1)
assert_eq "Leg C RESTORE: ...and the approval's change_set_hash DIFFERS from the without-artifact hash (step 8, green)" \
    "1" "$([ "$RESTORE_APPROVED_HASH" != "$RC_WITHOUT_HASH" ] && echo 1 || echo 0)"

printf 'Leg C: PASSED — the mutant collapses AC-4/AC-6 membership, the restore control does not.\n'
