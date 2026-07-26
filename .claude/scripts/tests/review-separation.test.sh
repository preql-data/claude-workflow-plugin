#!/bin/bash
# review-separation.test.sh — the REVIEW-SEPARATION refusal in qa-gate.sh
# approve (v4.0.0 Phase V3 / claude-workflow-plugin-jio.1).
#
# THE CONTRACT UNDER TEST: nobody signs off on their own work, mechanically.
# `qa-gate.sh approve` refuses unless the task carries a review artifact whose
# reviewer_identity differs from EVERY recorded IMPLEMENTER, with zero findings
# at/above the artifact's risk_threshold still open. The predicate is the ONE
# shipped counter (review-check.sh gate); approve WIRES it, never re-counts.
#
# Sections:
#   1. Refusal per error_key
#        1.1 no artifact                 -> exit 4, review_artifact_missing
#        1.2 reviewer == implementer     -> exit 4, reviewer_not_independent
#        1.3 open at-threshold finding   -> exit 4, unresolved_findings (+ ids)
#        1.4 refusals flip NO labels (a refused approve is a no-op)
#        1.5 below-threshold finding does NOT block (the counter's own rule,
#            observed through approve so the wiring is proven end-to-end)
#   2. Clearing the refusal
#        2.1 resolve-finding (fix + test) -> approve succeeds
#        2.2 arbitrate overrule           -> approve succeeds
#   3. The audited bypass
#        3.1 --no-review '<reason>'  -> approves, records reason + reviewed_by=none
#        3.2 --no-review with empty reason -> exit 1, bypass_reason_required
#   4. Record grammar / backward compatibility
#        4.1 the approval comment carries reviewed_by=<identity> and, since
#            3mg.2, worktree=<tok> (`none` off a git checkout)
#        4.2 the llh.18 change_set_hash capture STILL extracts the same hash
#            (both later tokens are space-separated AFTER the hash token)
#        4.2b META: strip the WORKTREE-TOKEN sentinels from a COPY -> it writes
#            the pre-3mg.2 shape, and BOTH reader expressions extract identical
#            values from both shapes (and from a renamed token region)
#        4.3 the review scratch files are cleaned up on approve
#   5. FAIL CLOSED
#        5.1 review-check.sh missing -> exit 4, review_check_unavailable
#   6. META-TEST: strip the REVIEW-SEPARATION sentinel block from a COPY of
#      qa-gate.sh -> approve then SUCCEEDS with no artifact at all, i.e. every
#      section-1 assertion would fail against that copy. Proves the block is
#      load-bearing rather than incidental. TEXT-anchored on the sentinels
#      (LESSONS llh.20), never on line numbers.
#
# Conventions mirror qa-gate-choose.test.sh / qa-gate-grade-record.test.sh:
# plain bash, `set -u`, local assert helpers, trailing summary, tempdir fixture
# with a bd --no-daemon shim, skip-with-log when bd is absent in CI.
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/review-separation.test.sh
#   bash .claude/scripts/tests/review-separation.test.sh --keep

# shellcheck disable=SC2317
# Same rationale as the sibling tests in this dir: helpers and scenario bodies
# are reached through control flow (set -u + early-exit + subshells) the static
# analyzer cannot follow. Disabled file-wide.

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
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden: %s\n    haystack:  %s\n' \
            "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

assert_match() {
    local name="$1" pattern="$2" actual="$3"
    if printf '%s' "$actual" | grep -qE "$pattern"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    pattern: %s\n    actual:  %s\n' \
            "$name" "$pattern" "$actual"
    fi
}

PLUGIN_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
FIXTURE=$(mktemp -d -t review-separation.XXXXXX)

# shellcheck disable=SC2329  # cleanup invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf 'Fixture kept at: %s\n' "$FIXTURE"
        return
    fi
    [ -d "$FIXTURE" ] && rm -rf "$FIXTURE"
}
trap cleanup EXIT

mkdir -p "$FIXTURE/.claude/scripts" "$FIXTURE/.claude/.qa-tracking" \
    "$FIXTURE/.beads" "$FIXTURE/bin"
cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh

if ! command -v bd >/dev/null 2>&1; then
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        echo "SKIPPED: review-separation.test.sh (bd not available; CI env BD_SHIM_ONLY=1)"
        exit 0
    fi
    echo "bd CLI not on PATH — review-separation tests require Beads."
    exit 1
fi

REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} --no-daemon "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1
export CLAUDE_PROJECT_DIR="$FIXTURE"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

labels_for() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

comments_of() {
    bd show "$1" --json 2>/dev/null \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

current_hash() {
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" --hash-only 2>/dev/null || echo ""
}

# new_task <title> <changed-file> — create a task, stage a change-set for it,
# and enter the gate (which generates the impact report so the EARLIER
# impact-freshness refusal never masks the review refusal under test).
new_task() {
    local title="$1" file="$2" tid
    tid=$(bd create "$title" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf '%s\n' "$file" > "$TRACK/changed-files.txt"
    bash "$QG" enter "$tid" >/dev/null 2>&1
    printf '%s' "$tid"
}

# record_implementer <tid> <role> — the record subagent-start.sh writes on spawn.
record_implementer() {
    bd comments add "$1" "IMPLEMENTER: role=$2 task=$1 at $(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        >/dev/null 2>&1
}

# record_artifact <tid> <reviewer> <findings-json> — write + record a review
# artifact through the REAL writer (qa-gate.sh review-record, which re-validates
# via review-check.sh). Using the real writer means a grammar change breaks
# these tests loudly instead of leaving them asserting against a dead shape.
record_artifact() {
    local tid="$1" reviewer="$2" findings="$3" verdict="approve"
    [ "$findings" != "[]" ] && verdict="findings"
    local art
    art="$TRACK/review-artifact-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"test-model","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"$verdict","findings":$findings,"iterations":1,"stopped_by":"verdict"}
JSON
    bash "$QG" review-record "$tid" --file "$art" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: approve REFUSES, one error_key per violation ==="

# 1.1 No review artifact at all.
TID_MISS=$(new_task "review-sep: no artifact" "src/one.ts")
record_implementer "$TID_MISS" "backend"
RC=0
OUT=$(bash "$QG" approve "$TID_MISS" "ship it" 2>/dev/null) || RC=$?
assert_eq "1.1 no artifact: exit 4" "4" "$RC"
assert_contains "1.1 no artifact: ok=false" '"ok":false' "$OUT"
assert_eq "1.1 no artifact: error_key=review_artifact_missing" \
    "review_artifact_missing" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "1.1 no artifact: remediation names review-record" \
    "qa-gate.sh review-record" "$OUT"
assert_contains "1.1 no artifact: remediation names the audited bypass" \
    "--no-review" "$OUT"

# 1.4 A refused approve is a NO-OP on labels (checked here, on the first
# refusal, so a later passing case cannot mask a label leak).
LBL=$(labels_for "$TID_MISS")
assert_not_contains "1.4 refusal leaves qa-approved unset" "qa-approved" "$LBL"
assert_contains "1.4 refusal preserves qa-gate-entered" "qa-gate-entered" "$LBL"

# 1.2 Reviewer IS the implementer — the self-review case this whole phase exists
# to stop.
TID_SELF=$(new_task "review-sep: self review" "src/two.ts")
record_implementer "$TID_SELF" "devops"
record_artifact "$TID_SELF" "devops" "[]"
RC=0
OUT=$(bash "$QG" approve "$TID_SELF" "I reviewed my own work" 2>/dev/null) || RC=$?
assert_eq "1.2 self-review: exit 4" "4" "$RC"
assert_eq "1.2 self-review: error_key=reviewer_not_independent" \
    "reviewer_not_independent" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "1.2 self-review: remediation demands a DIFFERENT identity" \
    "DIFFERENT identity" "$OUT"

# 1.3 Independent reviewer, but a critical finding is still open.
TID_OPEN=$(new_task "review-sep: open finding" "src/three.ts")
record_implementer "$TID_OPEN" "backend"
record_artifact "$TID_OPEN" "qa-claude" \
    '[{"id":"R1-F1","severity":"critical","location":"src/three.ts:10","evidence":"unsanitised input reaches the query","description":"sqli"}]'
RC=0
OUT=$(bash "$QG" approve "$TID_OPEN" "shipping over the finding" 2>/dev/null) || RC=$?
assert_eq "1.3 open finding: exit 4" "4" "$RC"
assert_eq "1.3 open finding: error_key=unresolved_findings" \
    "unresolved_findings" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "1.3 open finding: refusal names the open finding id" \
    "R1-F1" "$OUT"
assert_contains "1.3 open finding: remediation names resolve-finding" \
    "qa-gate.sh resolve-finding" "$OUT"
assert_contains "1.3 open finding: remediation names arbitrate" \
    "arbitrate" "$OUT"

# 1.5 A finding BELOW the artifact's risk_threshold must NOT block. This is the
# counter's rule; asserting it through approve proves the wiring passes the
# whole verdict through rather than treating "any finding" as fatal.
TID_LOW=$(new_task "review-sep: below-threshold finding" "src/four.ts")
record_implementer "$TID_LOW" "backend"
record_artifact "$TID_LOW" "qa-claude" \
    '[{"id":"R1-F1","severity":"low","location":"src/four.ts:2","evidence":"nit","description":"naming"}]'
RC=0
OUT=$(bash "$QG" approve "$TID_LOW" "one low nit, below threshold" 2>/dev/null) || RC=$?
assert_eq "1.5 below-threshold finding: approve succeeds (exit 0)" "0" "$RC"
assert_eq "1.5 below-threshold finding: status=approved" \
    "approved" "$(printf '%s' "$OUT" | jq -r '.status')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: clearing the refusal (resolve / arbitrate) ==="

# 2.1 resolve-finding with fix + test evidence.
bash "$QG" resolve-finding "$TID_OPEN" R1-F1 \
    --fix "commit:deadbeef src/three.ts:10" \
    --test "tests/sqli.test.sh::rejects-unsanitised" \
    "parameterised the query and covered it" >/dev/null 2>&1
# Resolving a finding CHANGES FILES — that is what "resolved" means. So the
# change-set (and its hash) legitimately moves away from what the reviewer saw:
# re-stage the fix's files and regenerate the impact report exactly as the real
# loop would. This also sets up the D6 assertion below: the artifact's
# reviewed_hash no longer matches the approved hash, which must WARN, not block.
printf 'src/three.ts\ntests/sqli.test.sh\n' > "$TRACK/changed-files.txt"
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" "$TID_OPEN" >/dev/null 2>&1 || true
RC=0
OUT=$(bash "$QG" approve "$TID_OPEN" "finding resolved with evidence" 2>/dev/null) || RC=$?
assert_eq "2.1 after resolve-finding: approve succeeds (exit 0)" "0" "$RC"
assert_eq "2.1 after resolve-finding: status=approved" \
    "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
assert_contains "2.1 after resolve-finding: obs names the verified reviewer" \
    "independent review verified (reviewed_by=qa-claude" "$OUT"
# D6: a review artifact that predates the fix is AUDITED, never blocking —
# otherwise no resolve-then-approve cycle could ever close.
assert_contains "2.1 stale reviewed_hash after a fix: WARNS in observations" \
    "the reviewed change-set is not byte-identical to the approved one" "$OUT"

# 2.2 arbitrate overrule on a DIFFERENT task (an explicit, justified override).
TID_ARB=$(new_task "review-sep: arbitrated finding" "src/five.ts")
record_implementer "$TID_ARB" "frontend"
record_artifact "$TID_ARB" "qa-claude" \
    '[{"id":"R1-F1","severity":"high","location":"src/five.ts:3","evidence":"n+1 query","description":"perf"}]'
RC=0
bash "$QG" approve "$TID_ARB" "pre-arbitration control" >/dev/null 2>&1 || RC=$?
assert_eq "2.2 control: open finding blocks before arbitration" "4" "$RC"
bash "$QG" arbitrate "$TID_ARB" R1-F1 overrule \
    "accepted: the loop runs over a bounded 3-element config list; tracked as tech-debt" \
    >/dev/null 2>&1
RC=0
OUT=$(bash "$QG" approve "$TID_ARB" "finding overruled with rationale" 2>/dev/null) || RC=$?
assert_eq "2.2 after arbitrate overrule: approve succeeds (exit 0)" "0" "$RC"
assert_eq "2.2 after arbitrate overrule: status=approved" \
    "approved" "$(printf '%s' "$OUT" | jq -r '.status')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: the audited --no-review bypass ==="

TID_BYP=$(new_task "review-sep: audited bypass" "src/six.ts")
record_implementer "$TID_BYP" "backend"
RC=0
OUT=$(bash "$QG" approve "$TID_BYP" \
    --no-review "docs-only follow-up; nothing reviewable changed" \
    "bypassed approval" 2>/dev/null) || RC=$?
assert_eq "3.1 bypass: approve succeeds (exit 0)" "0" "$RC"
assert_eq "3.1 bypass: status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
assert_contains "3.1 bypass: reason recorded in gate JSON observations" \
    "docs-only follow-up; nothing reviewable changed" "$OUT"
assert_contains "3.1 bypass: observations flag it as a review bypass" \
    "review-bypass" "$OUT"
BYP_CMT=$(comments_of "$TID_BYP" | grep 'QA-GATE APPROVED' | tail -1)
assert_contains "3.1 bypass: approval comment carries the [review bypass:] marker" \
    "[review bypass: docs-only follow-up; nothing reviewable changed]" "$BYP_CMT"
assert_contains "3.1 bypass: approval comment records reviewed_by=none" \
    "reviewed_by=none" "$BYP_CMT"

# 3.2 An unexplained bypass is refused — same contract as --no-impact-report.
TID_BYP2=$(new_task "review-sep: empty bypass reason" "src/seven.ts")
RC=0
OUT=$(bash "$QG" approve "$TID_BYP2" --no-review 2>/dev/null) || RC=$?
assert_eq "3.2 empty bypass reason: exit 1" "1" "$RC"
assert_eq "3.2 empty bypass reason: error_key=bypass_reason_required" \
    "bypass_reason_required" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_not_contains "3.2 empty bypass reason: no qa-approved label" \
    "qa-approved" "$(labels_for "$TID_BYP2")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: approval-record grammar + llh.18 backward compatibility ==="

TID_REC=$(new_task "review-sep: record grammar" "src/eight.ts")
record_implementer "$TID_REC" "backend"
record_artifact "$TID_REC" "qa-claude" "[]"
# Capture the hash BEFORE approve (approve truncates the tracker, after which
# --hash-only would return the empty-set hash).
REC_EXPECTED_HASH=$(current_hash)
bash "$QG" approve "$TID_REC" "clean independent review" >/dev/null 2>&1
REC_CMT=$(comments_of "$TID_REC" | grep 'QA-GATE APPROVED' | tail -1)

# The two READER expressions, verbatim. Every compat assertion below runs these
# rather than a paraphrase, so a record-grammar change that breaks a real reader
# cannot pass here:
#   capture_hash        — verify-before-stop.sh task_has_matching_approval_record
#   capture_reviewed_by — invariants.ts REVIEWED_BY (/\breviewed_by=(\S+)/)
capture_hash() {
    printf '%s' "$1" | jq -Rr 'capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null || echo ""
}
capture_reviewed_by() {
    printf '%s' "$1" | jq -Rr 'capture("reviewed_by=(?<r>[^ ]+)").r' 2>/dev/null || echo ""
}

# 4.1 reviewed_by is present and names the artifact's reviewer.
assert_contains "4.1 approval comment carries reviewed_by=qa-claude" \
    "reviewed_by=qa-claude" "$REC_CMT"
# Full grammar, byte-anchored: hash token, THEN reviewed_by, THEN worktree
# (3mg.2), THEN `at <ts>:`. Token order is the compatibility contract — every
# addition goes AFTER the hash, space-separated.
assert_match "4.1 approval record grammar (hash, reviewed_by, worktree, timestamp)" \
    "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude worktree=[^ ]+ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: " \
    "$REC_CMT"
# This fixture is a bare tempdir, NOT a git checkout, so the token records the
# unresolvable case. `none` rather than an omitted token is the point: a stable
# grammar lets a reader tell "no worktree recorded" from "recorded, but
# unresolvable". (The resolvable spelling is covered against a REAL linked
# worktree by the L2 spec worktree-approval-resolution.sh.)
assert_contains "4.1 non-git checkout records worktree=none (never an omitted token)" \
    "worktree=none " "$REC_CMT"

# 4.2 THE compatibility assertion: the llh.18 capture the Stop hook uses is
# UNCHANGED by the inserted tokens. Run the hook's exact jq, not a paraphrase.
REC_CAPTURED=$(bd show "$TID_REC" --json 2>/dev/null \
    | jq -r '(if type == "array" then .[0].comments else .comments end) // []
             | .[].text
             | select(test("QA-GATE APPROVED .*change_set_hash="))
             | capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null | tail -1)
assert_eq "4.2 llh.18 hash capture still extracts the approved change_set_hash" \
    "$REC_EXPECTED_HASH" "$REC_CAPTURED"
assert_not_contains "4.2 captured hash did NOT swallow the reviewed_by token" \
    "reviewed_by" "$REC_CAPTURED"
assert_not_contains "4.2 captured hash did NOT swallow the worktree token" \
    "worktree" "$REC_CAPTURED"
assert_eq "4.2 the V3 reviewed_by capture stops before worktree=" \
    "qa-claude" "$(capture_reviewed_by "$REC_CMT")"

# 4.2b META (3mg.2, TEXT-anchored on the WORKTREE-TOKEN sentinels): strip the
# token region from a COPY of qa-gate.sh and approve a fresh task with it. That
# copy writes the PRE-3mg.2 record shape, so running BOTH readers over BOTH
# shapes proves the captures are invariant to the token region — which is the
# whole back-compat claim. Without this, "the old regex still works" would rest
# on inspection of one record rather than on a differential test.
QG_NOTOKEN="$FIXTURE/qa-gate-noworktreetoken.sh"
TOKSTRIP_RC=0
awk '
    /# WORKTREE-TOKEN BEGIN/ { skipping=1; found=1; next }
    /# WORKTREE-TOKEN END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_NOTOKEN" || TOKSTRIP_RC=$?
chmod +x "$QG_NOTOKEN"
assert_eq "4.2b META: WORKTREE-TOKEN sentinels present in qa-gate.sh" "0" "$TOKSTRIP_RC"

if [ "$TOKSTRIP_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$QG_NOTOKEN" 2>/dev/null || PARSE_RC=$?
    assert_eq "4.2b META: stripped copy parses (worktree_field defaults empty outside the block)" \
        "0" "$PARSE_RC"

    TID_NOTOK=$(new_task "review-sep: pre-3mg.2 record shape" "src/eight-b.ts")
    record_implementer "$TID_NOTOK" "backend"
    record_artifact "$TID_NOTOK" "qa-claude" "[]"
    NOTOK_EXPECTED_HASH=$(current_hash)
    bash "$QG_NOTOKEN" approve "$TID_NOTOK" "clean independent review" >/dev/null 2>&1
    NOTOK_CMT=$(comments_of "$TID_NOTOK" | grep 'QA-GATE APPROVED' | tail -1)

    assert_not_contains "4.2b META: the stripped writer emits NO worktree token" \
        "worktree=" "$NOTOK_CMT"
    # The pre-3mg.2 grammar, exactly — no dangling token, no double space.
    assert_match "4.2b META: ...and the record is otherwise byte-shaped as v3.5" \
        "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: " \
        "$NOTOK_CMT"
    # THE differential: both readers, both shapes, same extractions.
    assert_eq "4.2b META: the hash capture is IDENTICAL on the token-less record" \
        "$NOTOK_EXPECTED_HASH" "$(capture_hash "$NOTOK_CMT")"
    assert_eq "4.2b META: the hash capture is IDENTICAL on the token-bearing record" \
        "$REC_EXPECTED_HASH" "$(capture_hash "$REC_CMT")"
    assert_eq "4.2b META: the reviewed_by capture is IDENTICAL on the token-less record" \
        "qa-claude" "$(capture_reviewed_by "$NOTOK_CMT")"
    assert_eq "4.2b META: the reviewed_by capture is IDENTICAL on the token-bearing record" \
        "qa-claude" "$(capture_reviewed_by "$REC_CMT")"
    # And the reverse direction: a RENAMED token region must be equally
    # invisible to both readers (proving they key on their own token, not on
    # position or field count).
    RENAMED_CMT=$(printf '%s' "$REC_CMT" | sed 's/ worktree=/ approving_checkout=/')
    assert_eq "4.2b META: renaming the token leaves the hash capture unchanged" \
        "$REC_EXPECTED_HASH" "$(capture_hash "$RENAMED_CMT")"
    assert_eq "4.2b META: renaming the token leaves the reviewed_by capture unchanged" \
        "qa-claude" "$(capture_reviewed_by "$RENAMED_CMT")"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("4.2b META: WORKTREE-TOKEN sentinels missing — strip meta-test skipped")
    printf '  FAIL: 4.2b META: WORKTREE-TOKEN sentinels missing — strip meta-test skipped\n'
fi

# 4.3 approve cleans up the review round's on-disk scratch files (the Beads
# comments remain the durable record).
REC_ART="$TRACK/review-artifact-$(printf '%s' "$TID_REC" | tr -c 'A-Za-z0-9._-' '_')-r1.json"
assert_eq "4.3 approve removes the review artifact scratch file" \
    "absent" "$([ -e "$REC_ART" ] && echo present || echo absent)"
assert_contains "4.3 the durable REVIEW-ARTIFACT comment survives approve" \
    "REVIEW-ARTIFACT v1" "$(comments_of "$TID_REC")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: FAIL CLOSED when the predicate is unavailable ==="

TID_NOHELPER=$(new_task "review-sep: predicate missing" "src/nine.ts")
record_implementer "$TID_NOHELPER" "backend"
record_artifact "$TID_NOHELPER" "qa-claude" "[]"
mv "$FIXTURE/.claude/scripts/review-check.sh" "$FIXTURE/review-check.sh.hidden"
RC=0
OUT=$(bash "$QG" approve "$TID_NOHELPER" "predicate is gone" 2>/dev/null) || RC=$?
mv "$FIXTURE/review-check.sh.hidden" "$FIXTURE/.claude/scripts/review-check.sh"
assert_eq "5.1 missing review-check.sh: exit 4 (fails CLOSED, not open)" "4" "$RC"
assert_eq "5.1 missing review-check.sh: error_key=review_check_unavailable" \
    "review_check_unavailable" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_not_contains "5.1 missing review-check.sh: no qa-approved label" \
    "qa-approved" "$(labels_for "$TID_NOHELPER")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: META — the REVIEW-SEPARATION block is load-bearing ==="

# Strip everything between the sentinels from a COPY. If the refusal really is
# what enforces the contract, the stripped copy approves a task with NO review
# artifact — i.e. every section-1 assertion would FAIL against it.
QG_STRIPPED="$FIXTURE/qa-gate-noreviewsep.sh"
STRIP_RC=0
awk '
    /# REVIEW-SEPARATION BEGIN/ { skipping=1; found=1; next }
    /# REVIEW-SEPARATION END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_STRIPPED" || STRIP_RC=$?
chmod +x "$QG_STRIPPED"
assert_eq "6 META: REVIEW-SEPARATION sentinels present in qa-gate.sh" "0" "$STRIP_RC"

if [ "$STRIP_RC" -eq 0 ]; then
    # The stripped copy must still be a valid script — the block was written to
    # be strippable (reviewed_by is declared OUTSIDE it with a default).
    PARSE_RC=0
    bash -n "$QG_STRIPPED" 2>/dev/null || PARSE_RC=$?
    assert_eq "6 META: stripped copy still parses (block is cleanly strippable)" \
        "0" "$PARSE_RC"

    TID_META=$(new_task "review-sep: META strip" "src/ten.ts")
    record_implementer "$TID_META" "backend"
    # Deliberately NO artifact — section 1.1's exact precondition.
    RC=0
    OUT=$(bash "$QG_STRIPPED" approve "$TID_META" "stripped copy must NOT refuse" 2>/dev/null) || RC=$?
    assert_eq "6 META: WITHOUT the block, approve succeeds with no artifact (1.1 WOULD fail)" \
        "0" "$RC"
    assert_eq "6 META: stripped copy status=approved" \
        "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
    # And the stripped copy still writes a coherent record (reviewed_by defaults
    # to none) — the strip must not corrupt the approval grammar.
    META_CMT=$(comments_of "$TID_META" | grep 'QA-GATE APPROVED' | tail -1)
    assert_contains "6 META: stripped copy still writes a coherent reviewed_by token" \
        "reviewed_by=none" "$META_CMT"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("6 META: sentinels missing — strip meta-test skipped")
    printf '  FAIL: 6 META: sentinels missing — strip meta-test skipped\n'
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d assertion(s)\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    printf 'Passed: %d\n' "$PASS"
    exit 1
fi

printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
