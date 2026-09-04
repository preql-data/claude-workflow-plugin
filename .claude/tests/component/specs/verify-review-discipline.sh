#!/bin/bash
# verify-review-discipline.sh — L2 component spec for the REVIEW-DISCIPLINE
# release block in verify-before-stop.sh (v4.0.0 Phase V3 /
# claude-workflow-plugin-jio.1).
#
# THE CONTRACT UNDER TEST: a change-set-bound approval is necessary but no
# longer sufficient. Before releasing, the Stop hook re-runs the SAME
# independent-review predicate approve ran (review-check.sh gate) against the
# CURRENT record set. That re-check exists because findings keep arriving after
# an approval — a second review round, a re-opened issue — and the approval
# record, written once, cannot know about them. Without the re-check,
# "approve early, discover later" ships the finding.
#
# Cases (each drives the REAL hook with a crafted stdin payload):
#   D1  clean independent review + matching record        -> RELEASE (control)
#   D2  a finding recorded AFTER the approval             -> BLOCK, reason cites
#                                                            the error_key + id
#   D3  the finding is arbitrated (overrule)              -> RELEASE
#   D4  an audited `[review bypass:` record (the F1 doc-only fast path writes
#       it) -> RELEASE even though the predicate itself still reports the
#       finding open — isolating the marker as the cause
#   D5  review-check.sh missing                           -> BLOCK (fail CLOSED)
#   D6  META: strip the REVIEW-DISCIPLINE sentinel block from a copy of the
#       hook -> the D2 open-finding release SUCCEEDS, proving the block (not
#       something incidental) is what refuses.
#
# D4 doubles as the deliverable-4 assertion: the F1 fast path must call approve
# with --no-review, because a doc-only change has no implementer and nothing to
# review — without the flag every documentation commit would deadlock.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

VBS="$FIXTURE/.claude/scripts/verify-before-stop.sh"
QG="$FIXTURE/.claude/scripts/qa-gate.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"
RCHECK="$FIXTURE/.claude/scripts/review-check.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# 94d: keep this spec's own INSTRUMENTATION out of the fixture's git view. D5
# DELETES `.claude/scripts/review-check.sh` and D6 WRITES a stripped hook copy
# into `.claude/scripts/` — both are real, git-visible changes (deletions
# included), so once `reconcile-tracker` existed they moved the change-set hash
# mid-cycle and LABEL_WITHOUT_RECORD fired before the review-discipline check the
# assertions are about. Same call the shared denylist already makes for the e2e
# tier ("churn the harness rewrites mechanically"), applied to an L2 mktemp root
# no denylist branch can name. The SUBJECT (src/handler.ts and friends) stays
# tracked and fully reviewable.
printf 'bin/\n.claude/scripts/\n.claude/.qa-tracking/\n' > "$FIXTURE/.gitignore"
(cd "$FIXTURE" && git init -q 2>/dev/null \
    && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline 2>/dev/null) || true

# detect-stack stub with an empty test_cmd: skip the (slow) test pass so each
# Stop reaches the approval/release predicate directly. The change-sets below
# stay non-doc where the approved path is under test, so the F1 fast path does
# not swallow them.
rm -f "$FIXTURE/.claude/scripts/detect-stack.sh"
printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
    > "$FIXTURE/.claude/scripts/detect-stack.sh"
chmod +x "$FIXTURE/.claude/scripts/detect-stack.sh"

# 94d: the fixture is fully constructed now, so this is its ARRIVAL state —
# baseline it, exactly as session-start.sh does on a real session. Without this,
# `qa-gate.sh reconcile-tracker` correctly reads the harness's own detect-stack
# stub and whatever `bd init` scaffolded (.gitignore, CLAUDE.md, AGENTS.md) as
# this session's work: D4's change set stops being doc-only so F1 never fires,
# and D5/D6 get a change-set hash no recorded approval binds. The tracker is
# empty here, so `--exclude-tracked` has nothing to protect yet and every path
# each case seeds below is new relative to this snapshot — which is precisely the
# change set each case means to measure. See baseline_incidental_dirt in
# lib/fixture.sh.
baseline_incidental_dirt "$FIXTURE"

# stop_decision [hook-path] — run the Stop hook and print `block` or `ALLOW`.
stop_decision() {
    local hook="${1:-$VBS}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$hook" 2>/dev/null | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}

stop_reason() {
    local hook="${1:-$VBS}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | bash "$hook" 2>/dev/null | tail -1 | jq -r '.reason // ""' 2>/dev/null
}

comments_of() {
    bd_show_with_comments "$1" \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

# record_artifact <tid> <iteration> <reviewer> <findings-json> — post a review
# record through the REAL writer so the grammar stays real.
record_artifact() {
    local tid="$1" iter="$2" reviewer="$3" findings="$4" verdict="approve"
    [ "$findings" != "[]" ] && verdict="findings"
    local art
    art="$TRACK/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r$iter.json"
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"test-model","reviewer_pin":"test-model","reviewed_hash":"h$iter","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"$verdict","findings":$findings,"iterations":$iter,"stopped_by":"verdict"}
JSON
    # claude-workflow-plugin-rqer (v5 D2): --file now asserts the CANONICAL
    # derived path; piped via stdin instead.
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
    # DELIBERATELY no reconcile-tracker here (unlike this same helper's
    # shape in other specs). This one is called for TWO different purposes
    # in this file: (a) the FIRST round on a task, immediately followed by
    # approve — that call site reconciles explicitly, right before its own
    # approve, so approve's freshness check sees the artifact; (b) a LATER
    # round recorded AFTER a task is already approved (D2/D4/D6's "the
    # record changed, the file set did not" scenarios), where reconciling
    # HERE would fold the new artifact into changed-files.txt and move the
    # live hash, so the Stop hook's llh.18 comparison would block on a
    # HASH MISMATCH — masking the review-discipline re-check this spec
    # exists to prove. Folding a reconcile into a shared helper used both
    # ways was the bug; each call site now owns the decision explicitly.
}

# restage <tid> <file> — put the task back in "this exact change-set is what
# was approved" position (the release path rm's the tracker and clears
# current-task on every allow, exactly as it does in production).
#
# claude-workflow-plugin-rqer (v5 D2): "what was approved" now includes
# whichever docs/reviews/<tid>-r<n>.json path(s) were folded into the
# tracker at the time of the reference approval — a restage that names only
# the source file understates the approved set, the hook's live recompute
# no longer matches the recorded hash, and a case meant to assert RELEASE
# gets a spurious BLOCK instead, not because review discipline re-armed but
# because this helper forgot a path.
#
# NEITHER a fresh glob NOR "whatever's in changed-files.txt right now" is
# correct here, and both were tried and measured wrong before this comment:
#   - A glob of every docs/reviews/*.json that exists on disk over-includes:
#     record_artifact deliberately does NOT reconcile a LATER round recorded
#     after a task is already approved (D2/D4/D6's "the record changed, the
#     file set did not" scenarios), so a fresh glob folds that later,
#     never-reconciled artifact in anyway, moving the live hash away from
#     what is actually bound.
#   - Reading changed-files.txt live is worse: a SUCCESSFUL approve
#     TRUNCATES it, so by the time restage runs (always after an approve in
#     this file) there is nothing left to read.
#   Correct source: RESTAGE_ART_LINES, captured explicitly by the ONE call
#   site that reconciles right before each approve (see D1/D6 META), which
#   snapshots the tracker's docs/reviews/ line(s) at the one instant they are
#   both present AND known-correct — after reconcile, before truncation.
#
# ABSOLUTE path, not relative — measured empirically, not assumed:
# reconcile_tracker's own git-status-based discovery writes newly-found paths
# into changed-files.txt as ABSOLUTE (fixture-root-prefixed) strings, while
# entries this spec writes itself (like the bare `$file` below) stay
# whatever spelling the caller chose. change_set_hash hashes the tracker's
# raw string content — no path normalization — so a relative spelling here
# byte-mismatches what reconcile actually bound and produces a hash the
# recorded approval does not carry, even though it names the same file.
RESTAGE_ART_LINES=""
restage() {
    local tid="$1" file="$2"
    bash "$CT" set "$tid" >/dev/null 2>&1
    {
        printf '%s\n' "$file"
        [ -n "$RESTAGE_ART_LINES" ] && printf '%s\n' "$RESTAGE_ART_LINES"
    } > "$TRACK/changed-files.txt"
}

# ---------------------------------------------------------------------------
# D1: control — clean independent review releases.
TID=$(cd "$FIXTURE" && bd create "review-discipline release" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID" >/dev/null 2>&1
bd comments add "$TID" "IMPLEMENTER: role=backend task=$TID at 2026-07-26T00:00:00Z" >/dev/null 2>&1
record_artifact "$TID" 1 "qa-claude" "[]"
# claude-workflow-plugin-rqer (v5 D2): THIS call site reconciles (unlike
# record_artifact itself, deliberately — see its own comment) because it is
# immediately followed by approve, which refuses on impact_report_stale
# without the artifact folded into the tracker first. Snapshot the
# docs/reviews/ line(s) into TID_ART_LINES NOW — restage's own comment
# explains why that snapshot, not a live read or a fresh glob, is correct.
# TID_ART_LINES is the STABLE copy for this task (D4 zeroes the ACTIVE
# RESTAGE_ART_LINES for its own unrelated task and D5 restores from here).
if [ -f "$FIXTURE/.claude/scripts/impact-report.sh" ]; then
    bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" "$TID" >/dev/null 2>&1 || true
fi
TID_ART_LINES=$(grep '/docs/reviews/' "$TRACK/changed-files.txt" 2>/dev/null || true)
RESTAGE_ART_LINES="$TID_ART_LINES"
# P7 (claude-workflow-plugin-qbhw) MIGRATION: approve also refuses without a
# validated COMPLETION v1 record. D1 is the CONTROL for this whole spec — "a
# clean independent review releases" — so it has to reach a real approve.
seed_completion_record "$TID" "backend" "$FIXTURE"
# v5 D2 (claude-workflow-plugin-fkm.4) MIGRATION, R2-F1: approve additionally
# refuses (exit 2, no_design_attempted) without a satisfied design verdict.
# This spec's subject is REVIEW discipline, not design — no task here has a
# design phase — so --no-design is the spec-true choice (seeding a real
# design-record would add docs/specs/<tid>.md as a new tracked path, which
# this spec's own restage()/RESTAGE_ART_LINES bookkeeping does not account
# for and has no need to). Same reasoning applies to D6 META's approve below.
APPROVE_OUT=$(bash "$QG" approve "$TID" --no-design "verify-review-discipline spec: no design phase, testing review discipline only" "reviewed by qa-claude; ships safely" 2>&1)
assert_json_field "D1: approve succeeds with an independent clean review" \
    "$APPROVE_OUT" '.status' "approved"
restage "$TID" "src/handler.ts"
assert_eq "D1: clean review + matching record -> RELEASE" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D2: a finding recorded AFTER the approval must re-arm the gate.
#
# This is the whole point of re-checking at Stop: the approval record is
# already written and still matches the change-set, so llh.18 is satisfied —
# only the review state changed.
restage "$TID" "src/handler.ts"
record_artifact "$TID" 2 "qa-claude" \
    '[{"id":"R2-F1","severity":"critical","location":"src/handler.ts:42","evidence":"the retry loop swallows the auth error","description":"silent auth failure"}]'
# Precondition: the record still matches (so any block is about REVIEW state).
# claude-workflow-plugin-yrij: anchored at `^`, matching the real hook's own
# fix (byte-neutral here — this precondition only ever sees a genuine record).
D2_RECORD_OK=$(bd_show_with_comments "$TID" \
    | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text
             | select(test("^QA-GATE APPROVED .*change_set_hash="))' 2>/dev/null | wc -l | tr -d ' ')
assert_eq "D2: precondition — the change-set-bound approval record is still on file" \
    "1" "$D2_RECORD_OK"
assert_eq "D2: post-approval open finding -> BLOCK" "block" "$(stop_decision)"
restage "$TID" "src/handler.ts"
D2_REASON=$(stop_reason)
assert_contains "D2: block reason names the error_key" "unresolved_findings" "$D2_REASON"
assert_contains "D2: block reason names the open finding id" "R2-F1" "$D2_REASON"
assert_contains "D2: block reason steers to resolve-finding" \
    "qa-gate.sh resolve-finding" "$D2_REASON"
assert_contains "D2: block reason steers to arbitrate" \
    "arbitrate" "$D2_REASON"
assert_contains "D2: block reason explains a finding can post-date an approval" \
    "recorded AFTER an approval" "$D2_REASON"

# ---------------------------------------------------------------------------
# D3: an explicit, justified overrule clears it.
bash "$QG" arbitrate "$TID" R2-F1 overrule \
    "the swallowed error is re-raised by the caller's guard; covered by tests/auth-retry.test.sh" \
    >/dev/null 2>&1
restage "$TID" "src/handler.ts"
assert_eq "D3: after arbitrate overrule -> RELEASE" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D4: the audited `[review bypass:` record (written by the F1 fast path).
#
# Drive the REAL doc-only fast path rather than hand-writing the marker: that
# is simultaneously the deliverable-4 assertion (F1 must approve with
# --no-review, or every doc commit deadlocks on the review refusal).
TID_DOC=$(cd "$FIXTURE" && bd create "doc-only fast path" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
# claude-workflow-plugin-rqer (v5 D2): reset restage's artifact-line memory —
# D1 left TID's line active, and TID_DOC's approval is about to come from
# the F1 --no-review fast path, which binds NO review artifact at all.
# Carrying D1's leftover value into TID_DOC's tracker would be cross-task
# contamination, not "what was approved" for THIS task. D5 (which reuses
# $TID) restores from TID_ART_LINES.
RESTAGE_ART_LINES=""
printf 'docs/notes.md\n' > "$TRACK/changed-files.txt"
bash "$CT" set "$TID_DOC" >/dev/null 2>&1
assert_eq "D4: F1 doc-only fast path releases" "ALLOW" "$(stop_decision)"
DOC_APPROVAL=$(comments_of "$TID_DOC" | grep 'QA-GATE APPROVED' | tail -1)
assert_contains "D4: F1 auto-approve carries the audited [review bypass:] marker" \
    "[review bypass: F1 doc-only fast path" "$DOC_APPROVAL"
assert_contains "D4: F1 auto-approve records reviewed_by=none" \
    "reviewed_by=none" "$DOC_APPROVAL"

# Now record an OPEN critical finding on that task and re-run the Stop against
# the same doc-only change-set. The predicate itself must report the finding
# open (proving the state is genuinely dirty) while the Stop still releases —
# so the ONLY thing granting the release is the bypass marker.
bd comments add "$TID_DOC" "IMPLEMENTER: role=devops task=$TID_DOC at 2026-07-26T00:00:00Z" >/dev/null 2>&1
record_artifact "$TID_DOC" 1 "qa-claude" \
    '[{"id":"R1-F1","severity":"critical","location":"docs/notes.md:1","evidence":"synthetic","description":"synthetic open finding"}]'
DOC_GATE_RC=0
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$RCHECK" gate "$TID_DOC" >/dev/null 2>&1 || DOC_GATE_RC=$?
assert_eq "D4: precondition — review-check reports the finding OPEN (exit 4)" "4" "$DOC_GATE_RC"
restage "$TID_DOC" "docs/notes.md"
assert_eq "D4: a [review bypass:] record still releases (audited escape honoured)" \
    "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D5: FAIL CLOSED when the predicate is unavailable.
#
# Same task and state as D3's release (clean, arbitrated, matching record) —
# the ONLY variable is whether review-check.sh exists.
# claude-workflow-plugin-rqer (v5 D2): restore restage's artifact-line memory
# to TID's — D4 zeroed it for TID_DOC's unrelated no-review approval.
RESTAGE_ART_LINES="$TID_ART_LINES"
restage "$TID" "src/handler.ts"
assert_eq "D5: sanity — this state releases while review-check.sh is present" \
    "ALLOW" "$(stop_decision)"
RCHECK_REAL=$(readlink "$RCHECK" 2>/dev/null || printf '%s' "$RCHECK")
rm -f "$RCHECK"
assert_eq "D5: precondition — review-check.sh is absent" \
    "absent" "$([ -e "$RCHECK" ] && echo present || echo absent)"
restage "$TID" "src/handler.ts"
assert_eq "D5: MISSING review-check.sh -> BLOCK (fails closed, not open)" \
    "block" "$(stop_decision)"
restage "$TID" "src/handler.ts"
D5_REASON=$(stop_reason)
assert_contains "D5: block reason names review_check_unavailable" \
    "review_check_unavailable" "$D5_REASON"
ln -sf "$RCHECK_REAL" "$RCHECK"
restage "$TID" "src/handler.ts"
assert_eq "D5: restoring review-check.sh restores the release" "ALLOW" "$(stop_decision)"

# ---------------------------------------------------------------------------
# D6: META — the REVIEW-DISCIPLINE block is load-bearing.
#
# Strip everything between the sentinels from a COPY of the hook and re-run
# D2's exact scenario (matching approval record + an open at-threshold
# finding). Under the stripped copy the release SUCCEEDS, i.e. D2's "block"
# assertion would fail — so D2 is testing the block, not a side effect.
# TEXT-anchored on the sentinels (LESSONS llh.20), never on line numbers.
#
# 3mg.1: the stripped copy lives in the fixture's `.claude/scripts/`, next to
# the `workflow-denylist.sh` the hook now sources BASH_SOURCE-relative. Parked
# at the fixture root it would take the missing-denylist fail-closed arm and
# BLOCK — inverting this META's expected ALLOW and hiding whether the
# REVIEW-DISCIPLINE block is load-bearing at all.
VBS_STRIPPED="$FIXTURE/.claude/scripts/verify-before-stop-nodiscipline.sh"
REAL_VBS=$(readlink "$VBS" 2>/dev/null || printf '%s' "$VBS")
STRIP_RC=0
awk '
    /# REVIEW-DISCIPLINE BEGIN/ { skipping=1; found=1; next }
    /# REVIEW-DISCIPLINE END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$REAL_VBS" > "$VBS_STRIPPED" || STRIP_RC=$?
chmod +x "$VBS_STRIPPED"
assert_eq "D6 META: REVIEW-DISCIPLINE sentinels present in verify-before-stop.sh" \
    "0" "$STRIP_RC"

if [ "$STRIP_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$VBS_STRIPPED" 2>/dev/null || PARSE_RC=$?
    assert_eq "D6 META: stripped copy still parses (block is cleanly strippable)" \
        "0" "$PARSE_RC"

    # Rebuild D2's state on a fresh task: approved + matching record, then an
    # open critical finding recorded afterwards.
    TID_META=$(cd "$FIXTURE" && bd create "review-discipline META" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    printf 'src/meta-handler.ts\n' > "$TRACK/changed-files.txt"
    bash "$QG" enter "$TID_META" >/dev/null 2>&1
    bd comments add "$TID_META" "IMPLEMENTER: role=backend task=$TID_META at 2026-07-26T00:00:00Z" >/dev/null 2>&1
    record_artifact "$TID_META" 1 "qa-claude" "[]"
    # claude-workflow-plugin-rqer (v5 D2): reconcile before this approve, same
    # reason as D1's (see that call site's comment) — and re-snapshot
    # RESTAGE_ART_LINES for THIS task, since D6 META reuses restage() with a
    # different tid.
    if [ -f "$FIXTURE/.claude/scripts/impact-report.sh" ]; then
        bash "$QG" reconcile-tracker >/dev/null 2>&1 || true
        CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/impact-report.sh" "$TID_META" >/dev/null 2>&1 || true
    fi
    RESTAGE_ART_LINES=$(grep '/docs/reviews/' "$TRACK/changed-files.txt" 2>/dev/null || true)
    # P7 MIGRATION (see D1): the META rebuilds D2's approved state, which needs
    # a real approve to exist at all.
    seed_completion_record "$TID_META" "backend" "$FIXTURE"
    # fkm.4 R2-F1 (see D1's approve above for the reasoning): --no-design, same
    # spec-true reason.
    bash "$QG" approve "$TID_META" --no-design "verify-review-discipline spec: no design phase, testing review discipline only" "clean at approve time" >/dev/null 2>&1
    record_artifact "$TID_META" 2 "qa-claude" \
        '[{"id":"R2-F1","severity":"critical","location":"src/meta-handler.ts:7","evidence":"synthetic","description":"post-approval finding"}]'
    # Control: the REAL hook blocks this state (same assertion as D2).
    restage "$TID_META" "src/meta-handler.ts"
    assert_eq "D6 META: control — the real hook BLOCKS the open-finding state" \
        "block" "$(stop_decision "$VBS")"
    # And the stripped copy releases it.
    restage "$TID_META" "src/meta-handler.ts"
    assert_eq "D6 META: WITHOUT the block, the open finding RELEASES (D2 WOULD fail)" \
        "ALLOW" "$(stop_decision "$VBS_STRIPPED")"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("D6 META: sentinels missing — strip meta-test skipped")
    printf '  FAIL: D6 META: sentinels missing — strip meta-test skipped\n'
fi

[ "$FAIL" -eq 0 ]
