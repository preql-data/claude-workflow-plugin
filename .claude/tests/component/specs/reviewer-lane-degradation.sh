#!/bin/bash
# reviewer-lane-degradation.sh — L2 THE DEGRADATION PROOF for the optional Sol
# reviewer lane (v4.0.0 Phase V2 / claude-workflow-plugin-1vq.1).
#
# Sol is ADVISORY and STRICTLY OPTIONAL. The release-defining invariant is that
# the gate/record machinery behaves IDENTICALLY whether or not the Codex lane
# is connected. Originally two guarantees were proved in this one file; as of
# claude-workflow-plugin-icn4 item 1 this file proves only:
#
#   BEHAVIOURAL: the identical sequence (seed comments -> review-record a
#   qa-claude artifact -> review-check gate) produces BYTE-IDENTICAL outputs and
#   comments (timestamps normalised) in a fixture WITH reviewer-lane.json=codex
#   + a registered stub server, and in a fixture with NEITHER.
#
# THE STRUCTURAL GUARANTEE MOVED TO L1 (claude-workflow-plugin-icn4 item 1).
# "qa-gate.sh, verify-before-stop.sh and review-check.sh contain zero
# references to codex or the reviewer lane" is a ~7-SECOND grep-only check
# with its own META injection — it needs none of this file's Beads-backed
# fixture scaffolding. QA measured a correction-10 violation surviving FOUR
# green verification passes and two commits BECAUSE that cheap check ran only
# at this tier's reserved ~65-minute cadence ("guard cadence must be at least
# violation cadence"). It now lives at
# .claude/scripts/tests/reviewer-lane-structural.test.sh, runs on every
# `make test`, and is the sole authority for that half of the invariant —
# read it for the exact pattern and its documented semantics
# (claude-workflow-plugin-mruw corrected and WIDENED the pattern; this file's
# own header used to use the phrase "reviewer lane" in prose without ever
# remarking on why that was safe). This file's BEHAVIOURAL half is unaffected
# and stays here: it needs the fixture, the stub Codex MCP server, and Beads.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

PLUGIN="$(plugin_root)"
QAGATE="$FIXTURE/.claude/scripts/qa-gate.sh"
RCHECK="$FIXTURE/.claude/scripts/review-check.sh"
STUB="$PLUGIN/.claude/tests/component/lib/stub-codex-mcp.js"
ISO='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ---------------------------------------------------------------------------
# BEHAVIOURAL: the diff proof needs Beads (review-record posts a comment).
bd_required_or_skip

TID=$(bd create "degradation proof" -t task --json 2>/dev/null | jq -r '.id // empty')
[ -z "$TID" ] && TID=$(bd list --json 2>/dev/null | jq -r '.[0].id // empty')

# A fixed qa-claude artifact + a fixed comment-set for the gate. Using the
# --comments-json seam keeps the gate deterministic regardless of how many
# times review-record has appended to the live task.
cat > "$FIXTURE/art.json" <<EOF
{"contract_version":"1","task_id":"$TID","reviewer_identity":"qa-claude","reviewer_model":"claude","reviewer_pin":"claude","reviewed_hash":"h","risk_threshold":"high","stop_condition":"x","verdict":"findings","findings":[{"id":"R1-F1","severity":"critical","location":"a:1","evidence":"e","description":"d"}],"iterations":1,"stopped_by":"verdict"}
EOF
cat > "$FIXTURE/comments.json" <<'EOF'
["IMPLEMENTER: role=backend built it",
 "REVIEW-ARTIFACT v1 iteration=1 reviewer=qa-claude model=claude reviewed_hash=h risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:critical] at 2026-07-25T00:00:00Z: x"]
EOF

# run_sequence <output-file> — the identical sequence; outputs normalised.
run_sequence() {
    {
        # claude-workflow-plugin-rqer (v5 D2): --file now asserts the
        # CANONICAL derived path; piped via stdin instead — deterministic
        # given the FIXED $TID and identical content, so the byte-identical
        # comparison below (which already normalises the timestamp) is
        # unaffected.
        bash "$QAGATE" review-record "$TID" < "$FIXTURE/art.json" 2>/dev/null
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
