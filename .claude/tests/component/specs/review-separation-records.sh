#!/bin/bash
# review-separation-records.sh — L2 component spec for the qa-gate.sh review
# record writers (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# review-record / resolve-finding / arbitrate are the ONLY writers of their
# load-bearing V3 comment grammars. This spec posts real Beads comments and
# greps them back to prove BYTE-EXACT grammar, plus the rejection paths:
#   R1  review-record posts:  REVIEW-ARTIFACT v1 iteration=.. reviewer=.. model=..
#       reviewed_hash=.. risk_threshold=.. verdict=.. stopped_by=.. findings=[..] at <ts>: ..
#   R2  resolve-finding posts: RESOLVED <id> at <ts>: fix=<ref> test=<ref> — <summary>
#   R3  arbitrate posts:       ARBITRATION <id> decision=<d> at <ts>: <rationale>
#   R4  resolve/arbitrate on an id NOT in the latest artifact -> finding_id_not_found
#   R5  empty --fix / --test / rationale -> exit 1 (evidence is mandatory)
#   R6  review-record of a schema-invalid artifact -> rejected via review-check

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

QAGATE="$FIXTURE/.claude/scripts/qa-gate.sh"
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

TID=$(bd create "review-separation spec" -t task --json 2>/dev/null | jq -r '.id // empty')
[ -z "$TID" ] && TID=$(bd list --json 2>/dev/null | jq -r '.[0].id // empty')

# latest_comment_matching <regex> — the last comment text whose FIRST line
# matches (records are single-line).
latest_comment_matching() {
    bd show "$TID" --json 2>/dev/null | jq -r '.[0].comments[].text' 2>/dev/null \
        | grep -E "$1" | tail -1
}

# Seed an implementer marker so independence has a real (different) role.
bd comments add "$TID" "IMPLEMENTER: role=backend implemented the feature" >/dev/null 2>&1

# ---------------------------------------------------------------------------
# R1: review-record posts the REVIEW-ARTIFACT v1 grammar byte-exactly.
cat > "$FIXTURE/art.json" <<EOF
{"contract_version":"1","task_id":"$TID","reviewer_identity":"sol-codex","reviewer_model":"gpt-5.6-sol","reviewed_hash":"deadbeef","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"critical","location":"a.ts:10","evidence":"e","description":"d"},{"id":"R1-F2","severity":"low","location":"b.ts:2","evidence":"e","description":"d"}],"iterations":1,"stopped_by":"verdict"}
EOF
REC_OUT=$(bash "$QAGATE" review-record "$TID" --file "$FIXTURE/art.json" 2>/dev/null)
assert_json_field "R1 review-record: ok=true" "$REC_OUT" ".ok|tostring" "true"
REC_COMMENT=$(latest_comment_matching '^REVIEW-ARTIFACT v1 ')
assert_match "R1 review-record: grammar byte-exact" \
    "^REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=gpt-5\.6-sol reviewed_hash=deadbeef risk_threshold=high verdict=findings stopped_by=verdict findings=\[R1-F1:critical,R1-F2:low\] at ${ISO}: " \
    "$REC_COMMENT"

# empty findings render as findings=[].
cat > "$FIXTURE/art_approve.json" <<EOF
{"contract_version":"1","task_id":"$TID","reviewer_identity":"qa-claude","reviewer_model":"claude","reviewed_hash":"cafe","risk_threshold":"high","stop_condition":"x","verdict":"approve","findings":[],"iterations":2,"stopped_by":"verdict"}
EOF
bash "$QAGATE" review-record "$TID" --file "$FIXTURE/art_approve.json" >/dev/null 2>&1
APPROVE_COMMENT=$(latest_comment_matching '^REVIEW-ARTIFACT v1 iteration=2 ')
assert_match "R1 review-record: empty findings render as findings=[]" \
    "findings=\[\] at ${ISO}: " "$APPROVE_COMMENT"

# ---------------------------------------------------------------------------
# R2: resolve-finding grammar. (R1-F1 is in the LATEST artifact — the approve
# one has no findings, so re-record the findings artifact to make it latest.)
bash "$QAGATE" review-record "$TID" --file "$FIXTURE/art.json" >/dev/null 2>&1
RES_OUT=$(bash "$QAGATE" resolve-finding "$TID" R1-F1 --fix "commit:abc123" --test "tests/sqli.test.sh" "sanitized and covered" 2>/dev/null)
assert_json_field "R2 resolve-finding: ok=true" "$RES_OUT" ".ok|tostring" "true"
RES_COMMENT=$(latest_comment_matching '^RESOLVED ')
assert_match "R2 resolve-finding: grammar byte-exact" \
    "^RESOLVED R1-F1 at ${ISO}: fix=commit:abc123 test=tests/sqli\.test\.sh — sanitized and covered$" \
    "$RES_COMMENT"

# ---------------------------------------------------------------------------
# R3: arbitrate grammar.
ARB_OUT=$(bash "$QAGATE" arbitrate "$TID" R1-F2 overrule "accepted risk, tracked in tech-debt" 2>/dev/null)
assert_json_field "R3 arbitrate: ok=true" "$ARB_OUT" ".ok|tostring" "true"
ARB_COMMENT=$(latest_comment_matching '^ARBITRATION ')
assert_match "R3 arbitrate: grammar byte-exact" \
    "^ARBITRATION R1-F2 decision=overrule at ${ISO}: accepted risk, tracked in tech-debt$" \
    "$ARB_COMMENT"

# ---------------------------------------------------------------------------
# R4: id-not-found rejections.
NF_RES=$(bash "$QAGATE" resolve-finding "$TID" R9-F9 --fix x --test y "z" 2>/dev/null)
assert_json_field "R4 resolve-finding unknown id: error_key" "$NF_RES" ".error_key" "finding_id_not_found"
NF_RES_RC=0; bash "$QAGATE" resolve-finding "$TID" R9-F9 --fix x --test y "z" >/dev/null 2>&1 || NF_RES_RC=$?
assert_eq "R4 resolve-finding unknown id: exit 1" "1" "$NF_RES_RC"

NF_ARB=$(bash "$QAGATE" arbitrate "$TID" R9-F9 sustain "why" 2>/dev/null)
assert_json_field "R4 arbitrate unknown id: error_key" "$NF_ARB" ".error_key" "finding_id_not_found"

# ---------------------------------------------------------------------------
# R5: empty-evidence rejections.
EF_OUT=$(bash "$QAGATE" resolve-finding "$TID" R1-F1 --fix "" --test "tests/x.sh" "summary" 2>/dev/null)
assert_json_field "R5 resolve-finding empty --fix: error_key" "$EF_OUT" ".error_key" "empty_fix"
ET_OUT=$(bash "$QAGATE" resolve-finding "$TID" R1-F1 --fix "commit:x" --test "" "summary" 2>/dev/null)
assert_json_field "R5 resolve-finding empty --test: error_key" "$ET_OUT" ".error_key" "empty_test"
ER_OUT=$(bash "$QAGATE" arbitrate "$TID" R1-F1 sustain "" 2>/dev/null)
assert_json_field "R5 arbitrate empty rationale: error_key" "$ER_OUT" ".error_key" "empty_rationale"
BADDEC_OUT=$(bash "$QAGATE" arbitrate "$TID" R1-F1 banana "rationale" 2>/dev/null)
assert_json_field "R5 arbitrate bad decision: error_key" "$BADDEC_OUT" ".error_key" "decision_invalid_enum"

# ---------------------------------------------------------------------------
# R6: review-record of a schema-invalid artifact is rejected via review-check.
printf '{"contract_version":"1","task_id":"x"}' > "$FIXTURE/bad_art.json"
BAD_OUT=$(bash "$QAGATE" review-record "$TID" --file "$FIXTURE/bad_art.json" 2>/dev/null)
assert_json_field "R6 review-record invalid artifact: ok=false" "$BAD_OUT" ".ok|tostring" "false"
assert_match "R6 review-record invalid artifact: error_key names the missing key" \
    "missing_key:" "$(printf '%s' "$BAD_OUT" | jq -r '.error_key')"
