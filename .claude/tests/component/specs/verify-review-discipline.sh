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
    bd show "$1" --json 2>/dev/null \
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
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"test-model","reviewed_hash":"h$iter","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"$verdict","findings":$findings,"iterations":$iter,"stopped_by":"verdict"}
JSON
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$QG" review-record "$tid" --file "$art" >/dev/null 2>&1
}

# restage <tid> <file> — put the task back in "this exact change-set is what
# was approved" position (the release path rm's the tracker and clears
# current-task on every allow, exactly as it does in production).
restage() {
    bash "$CT" set "$1" >/dev/null 2>&1
    printf '%s\n' "$2" > "$TRACK/changed-files.txt"
}

# ---------------------------------------------------------------------------
# D1: control — clean independent review releases.
TID=$(cd "$FIXTURE" && bd create "review-discipline release" -t task -p 1 -l backend,qa-pending --json 2>/dev/null | jq -r '.id // empty')
printf 'src/handler.ts\n' > "$TRACK/changed-files.txt"
bash "$QG" enter "$TID" >/dev/null 2>&1
bd comments add "$TID" "IMPLEMENTER: role=backend task=$TID at 2026-07-26T00:00:00Z" >/dev/null 2>&1
record_artifact "$TID" 1 "qa-claude" "[]"
APPROVE_OUT=$(bash "$QG" approve "$TID" "reviewed by qa-claude; ships safely" 2>&1)
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
D2_RECORD_OK=$(bd show "$TID" --json 2>/dev/null \
    | jq -r '(if type=="array" then .[0].comments else .comments end) // [] | .[].text
             | select(test("QA-GATE APPROVED .*change_set_hash="))' 2>/dev/null | wc -l | tr -d ' ')
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
VBS_STRIPPED="$FIXTURE/verify-before-stop-nodiscipline.sh"
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
    bash "$QG" approve "$TID_META" "clean at approve time" >/dev/null 2>&1
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
