#!/bin/bash
# reviewer-lane-degradation.sh — L2 THE DEGRADATION PROOF for the optional Sol
# reviewer lane (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# Sol is ADVISORY and STRICTLY OPTIONAL. The release-defining invariant is that
# the gate/record machinery behaves IDENTICALLY whether or not the Codex lane
# is connected. Two guarantees, both proved here:
#
#   STRUCTURAL (D5): qa-gate.sh, verify-before-stop.sh, and review-check.sh
#   contain ZERO references to codex or the reviewer lane. Lane selection is
#   prompt/statusline-side only. A META injection proves the grep is sensitive.
#
#   BEHAVIOURAL: the identical sequence (seed comments -> review-record a
#   qa-claude artifact -> review-check gate) produces BYTE-IDENTICAL outputs and
#   comments (timestamps normalised) in a fixture WITH reviewer-lane.json=codex
#   + a registered stub server, and in a fixture with NEITHER.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

PLUGIN="$(plugin_root)"
QAGATE="$FIXTURE/.claude/scripts/qa-gate.sh"
RCHECK="$FIXTURE/.claude/scripts/review-check.sh"
STUB="$PLUGIN/.claude/tests/component/lib/stub-codex-mcp.js"
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ---------------------------------------------------------------------------
# STRUCTURAL: the three gate-critical scripts are codex/lane-free. (No bd
# needed — runs even on CI runners without Beads.)
GATE_SCRIPTS="qa-gate.sh verify-before-stop.sh review-check.sh"
for f in $GATE_SCRIPTS; do
    CNT=$(grep -cEi 'codex|reviewer[._]lane' "$PLUGIN/.claude/scripts/$f" 2>/dev/null || true)
    [ -z "$CNT" ] && CNT=0
    assert_eq "structural: $f has zero codex/reviewer-lane references" "0" "$CNT"
done

# META: inject a codex/lane reference into a COPY and confirm the same grep
# TRIPS — proving the structural check above is sensitive, not vacuous.
cp "$PLUGIN/.claude/scripts/review-check.sh" "$FIXTURE/review-check-injected.sh"
printf '\n# reviewer_lane hook for codex (deliberate injection for the META test)\n' \
    >> "$FIXTURE/review-check-injected.sh"
INJ_CNT=$(grep -cEi 'codex|reviewer[._]lane' "$FIXTURE/review-check-injected.sh" 2>/dev/null || true)
[ -z "$INJ_CNT" ] && INJ_CNT=0
assert_eq "META: an injected codex/lane reference trips the structural grep" "1" \
    "$([ "$INJ_CNT" -gt 0 ] && echo 1 || echo 0)"

# ---------------------------------------------------------------------------
# BEHAVIOURAL: the diff proof needs Beads (review-record posts a comment).
bd_required_or_skip

TID=$(bd create "degradation proof" -t task --json 2>/dev/null | jq -r '.id // empty')
[ -z "$TID" ] && TID=$(bd list --json 2>/dev/null | jq -r '.[0].id // empty')

# A fixed qa-claude artifact + a fixed comment-set for the gate. Using the
# --comments-json seam keeps the gate deterministic regardless of how many
# times review-record has appended to the live task.
cat > "$FIXTURE/art.json" <<EOF
{"contract_version":"1","task_id":"$TID","reviewer_identity":"qa-claude","reviewer_model":"claude","reviewed_hash":"h","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"critical","location":"a:1","evidence":"e","description":"d"}],"iterations":1,"stopped_by":"verdict"}
EOF
cat > "$FIXTURE/comments.json" <<'EOF'
["IMPLEMENTER: role=backend built it",
 "REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical] at 2026-07-25T00:00:00Z: x"]
EOF

# run_sequence <output-file> — the identical sequence; outputs normalised.
run_sequence() {
    {
        bash "$QAGATE" review-record "$TID" --file "$FIXTURE/art.json" 2>/dev/null
        bash "$RCHECK" gate "$TID" --comments-json "$FIXTURE/comments.json" 2>/dev/null
    } | sed -E "s/${ISO}/<TS>/g"
}

# Condition CODEX: reviewer-lane.json=codex present + a registered stub server.
mkdir -p "$FIXTURE/.claude/.qa-tracking"
cat > "$FIXTURE/.claude/.qa-tracking/reviewer-lane.json" <<EOF
{"reviewer_lane":"codex","method":"handshake","codex_cmd":"node","codex_args":["$STUB"],"detected_at":"2026-07-25T00:00:00Z"}
EOF
cat > "$FIXTURE/.claude/codex-config.json" <<EOF
{"mcpServers":{"codex":{"command":"node","args":["$STUB"]}}}
EOF
CODEX_USER_CONFIG="$FIXTURE/.claude/codex-config.json" run_sequence > "$FIXTURE/out_codex.txt"

# Condition NONE: no reviewer-lane.json, no codex registration.
rm -f "$FIXTURE/.claude/.qa-tracking/reviewer-lane.json"
CODEX_USER_CONFIG="$FIXTURE/.claude/.no-codex-config.json" run_sequence > "$FIXTURE/out_none.txt"

# The captured outputs must be byte-identical.
DIFF_OUT=$(diff "$FIXTURE/out_codex.txt" "$FIXTURE/out_none.txt" 2>/dev/null || true)
assert_eq "behavioural: codex-present vs codex-absent outputs are byte-identical (empty diff)" \
    "" "$DIFF_OUT"

# Sanity: the sequence actually produced meaningful output (not two empty files
# that trivially match).
NONEMPTY=$([ -s "$FIXTURE/out_codex.txt" ] && echo 1 || echo 0)
assert_eq "behavioural: the captured sequence output is non-empty" "1" "$NONEMPTY"
assert_contains "behavioural: output includes the review-record envelope" \
    "REVIEW-ARTIFACT v1" "$(cat "$FIXTURE/out_codex.txt")"
assert_contains "behavioural: output includes the gate's unresolved_findings verdict" \
    "unresolved_findings" "$(cat "$FIXTURE/out_codex.txt")"
