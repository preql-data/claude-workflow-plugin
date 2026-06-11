#!/bin/bash
# model-select.sh component spec — spec 0.3 (claude-workflow-plugin-e0d.3).
#
# Exercises the automatic best-model selection helper offline. The /v1/models
# enumeration is stubbed via a curl PATH shim (mk_shim) so the spec never
# touches the network and never depends on ANTHROPIC_API_KEY.
#
# Specs:
#   A. resolve picks the highest-ranked family with a real listing match.
#   B. unknown-newer heuristic: a higher version inside a known family wins.
#   C. unknown family in listing is ignored, with a warning naming it.
#   D. cache freshness honoured: a second call within TTL doesn't re-invoke
#      curl (shim invocation count stays at 1).
#   E. fail-open when curl exits non-zero: exit 0, warning printed, pin
#      unchanged.
#   F. apply rewrites agent pins in the fixture's agents dir and records a
#      Beads comment on the meta-task with a /workflow-model rollback line.
#   G. apply is idempotent when the current pin already matches the best.
#   H. META-TEST: a deliberately broken ranking file (only an unknown
#      family) causes the highest-version assertion in spec B to FAIL,
#      proving the assertion is sensitive to the ranking logic.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# This spec exercises the full apply path including a bd comment on the
# meta-task. Skip cleanly on BD_SHIM_ONLY CI.
bd_required_or_skip

MS="$FIXTURE/.claude/scripts/model-select.sh"
APPLY="$FIXTURE/.claude/scripts/workflow-model-apply.sh"
CACHE="$FIXTURE/.claude/.qa-tracking/model-select-cache.json"
RANKING="$FIXTURE/.claude/model-ranking"
META_PTR="$FIXTURE/.claude/.model-select-meta-task"
AGENTS_DIR="$FIXTURE/.claude/agents"

# The fixture symlinks scripts but does NOT seed agents/ or the ranking
# file by default. We do that here so the rewrite has something to touch.
# Seed the ranking deliberately small so unknown-family/unknown-newer
# cases are easy to assert.
mkdir -p "$AGENTS_DIR"
cat > "$RANKING" <<'RANKING'
# Spec-scoped ranking — kept tiny so the unknown-family branch is easy
# to exercise. Real ranking lives at the plugin root.
claude-fable
claude-opus
RANKING

# Seed five agent files with the current pin "claude-opus-4-7" so apply
# has something to rewrite. Use simple frontmatter; workflow-model-apply.sh
# only cares about the model: line.
for agent in orchestrator qa backend frontend devops; do
    cat > "$AGENTS_DIR/$agent.md" <<EOF
---
name: $agent
description: stub
model: claude-opus-4-7
---
stub body for $agent
EOF
done

# Seed a settings.json so workflow-model-apply.sh's jq path doesn't bail.
cat > "$FIXTURE/.claude/settings.json" <<'JSON'
{
  "env": {
    "CLAUDE_LATEST_OPUS": "claude-opus-4-7"
  }
}
JSON

# Curl shim payload helper. ms_set_curl_payload <json> writes a curl shim
# that emits the JSON on stdout and exits 0. The shim also records argv
# (so we can assert "called with /v1/models" and count invocations).
ms_set_curl_payload() {
    local payload="$1"
    # Use the shim's stdout slot. The plugin's `mk_shim` records argv to
    # bin/<cmd>.log; we point that to a known path for assertion.
    mk_shim "curl" "$FIXTURE" 0 "$payload" >/dev/null
}

ms_set_curl_failure() {
    # Non-zero exit + empty stdout simulates network failure.
    mk_shim "curl" "$FIXTURE" 1 "" >/dev/null
}

ms_curl_invocations() {
    # Count lines in the shim log; each invocation appends one line.
    # `grep -c .` returns non-zero on zero matches, so we wrap and fall
    # through to "0" without double-printing.
    local log count
    log=$(shim_log "$FIXTURE" "curl")
    if [ ! -f "$log" ]; then
        printf '%s' "0"
        return
    fi
    count=$(grep -c . "$log" 2>/dev/null) || count=0
    printf '%s' "${count:-0}"
}

# Sample listing: two opus versions, one fable version, one mystery
# family. Mirrors the real /v1/models response shape: data array of
# {id, max_input_tokens, created_at, capabilities}. We keep max_input_tokens
# uniform so version ordering is what we're testing.
LISTING_HAPPY='{
  "data": [
    {"id":"claude-opus-4-7","max_input_tokens":200000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-4-8","max_input_tokens":200000,"created_at":"2026-05-02T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-05-03T00:00:00Z","capabilities":{}}
  ],
  "first_id":"claude-opus-4-7","has_more":false,"last_id":"claude-fable-5"
}'

LISTING_WITH_UNKNOWN='{
  "data": [
    {"id":"claude-opus-4-8","max_input_tokens":200000,"created_at":"2026-05-02T00:00:00Z","capabilities":{}},
    {"id":"claude-narwhal-1","max_input_tokens":300000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

LISTING_UNKNOWN_NEWER='{
  "data": [
    {"id":"claude-opus-4-7","max_input_tokens":200000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-5-1","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# A canned ANTHROPIC_API_KEY satisfies the "is the key set?" branch. The
# shimmed curl never validates it.
export ANTHROPIC_API_KEY="sk-spec-fake"

# ---------------------------------------------------------------------------
# Spec A: resolve picks fable as the highest-ranked family present.
# ---------------------------------------------------------------------------
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_HAPPY"
OUT_A=$(bash "$MS" resolve 2>&1)
# resolve's stdout is "<id>\t<source>"; stderr has any warnings/results.
ID_A=$(printf '%s\n' "$OUT_A" | grep -v '^model-select:' | head -1 | awk '{print $1}')
assert_eq "ms-A: resolve picks fable family head" "claude-fable-5" "$ID_A"

# ---------------------------------------------------------------------------
# Spec B: unknown-newer heuristic — same family, higher version wins.
# Rewrite the ranking to remove fable so opus is the only family; we then
# show claude-opus-5-1 (higher than any in our ranking notion) wins
# automatically. The "unknown-newer" reading: opus is a *known family*, a
# version above the prior baseline is accepted without a ranking edit.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_UNKNOWN_NEWER"
OUT_B=$(bash "$MS" resolve 2>&1)
ID_B=$(printf '%s\n' "$OUT_B" | grep -v '^model-select:' | head -1 | awk '{print $1}')
assert_eq "ms-B: unknown-newer opus-5-1 beats opus-4-7" "claude-opus-5-1" "$ID_B"

# ---------------------------------------------------------------------------
# Spec C: unknown family is skipped with a warning naming it.
# Ranking only knows claude-opus; the listing has claude-narwhal-1, which
# must NOT win, and a warning must mention "claude-narwhal".
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_WITH_UNKNOWN"
OUT_C=$(bash "$MS" resolve 2>&1)
ID_C=$(printf '%s\n' "$OUT_C" | grep -v '^model-select:' | head -1 | awk '{print $1}')
WARN_C=$(printf '%s\n' "$OUT_C" | grep '^model-select:' | grep -i 'narwhal' || true)
assert_eq "ms-C: unknown family is NOT selected (opus wins)" "claude-opus-4-8" "$ID_C"
assert_contains "ms-C: warning names the unknown family" "claude-narwhal" "$WARN_C"

# ---------------------------------------------------------------------------
# Spec D: cache freshness honoured — second resolve doesn't hit curl.
# Reset the shim log, run resolve twice, assert only one invocation.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_HAPPY"  # also resets the curl.log file
COUNT_BEFORE=$(ms_curl_invocations)
bash "$MS" resolve >/dev/null 2>&1
COUNT_AFTER_FIRST=$(ms_curl_invocations)
bash "$MS" resolve >/dev/null 2>&1
COUNT_AFTER_SECOND=$(ms_curl_invocations)
assert_eq "ms-D: first resolve invokes curl once" "1" \
    "$((COUNT_AFTER_FIRST - COUNT_BEFORE))"
assert_eq "ms-D: second resolve hits cache (no extra curl)" "1" \
    "$((COUNT_AFTER_SECOND - COUNT_BEFORE))"

# ---------------------------------------------------------------------------
# Spec E: curl failure -> fail-open, pin unchanged, exit 0, warning printed.
# ---------------------------------------------------------------------------
rm -f "$CACHE"
ms_set_curl_failure
# Snapshot current pin before the attempt.
PIN_BEFORE_E=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
bash "$MS" apply 2>/tmp/ms-e.err >/tmp/ms-e.out
RC_E=$?
WARN_E=$(grep '^model-select:' /tmp/ms-e.err | head -1)
PIN_AFTER_E=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
assert_eq "ms-E: fail-open exit code 0" "0" "$RC_E"
assert_contains "ms-E: fail-open warning emitted" "model-select:" "$WARN_E"
assert_eq "ms-E: pin unchanged under fail-open" "$PIN_BEFORE_E" "$PIN_AFTER_E"

# ---------------------------------------------------------------------------
# Spec F: apply rewrites agent pins AND records a Beads comment with a
# /workflow-model rollback line on a freshly-created meta-task.
# ---------------------------------------------------------------------------
# Reset state so apply actually has a change to make.
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE" "$META_PTR"
ms_set_curl_payload "$LISTING_HAPPY"
# Re-seed pins so apply has a delta. The orchestrator already has 4-7;
# all five agents are pinned the same way.
for agent in orchestrator qa backend frontend devops; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done

bash "$MS" apply 2>/tmp/ms-f.err >/tmp/ms-f.out
RC_F=$?
PIN_F=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
assert_eq "ms-F: apply exit 0" "0" "$RC_F"
assert_eq "ms-F: orchestrator pin updated to claude-fable-5" \
    "claude-fable-5" "$PIN_F"
# All five agents must update in lockstep — assert at least one more.
PIN_F_QA=$(grep -E '^model:' "$AGENTS_DIR/qa.md" | head -1 | awk '{print $2}')
assert_eq "ms-F: qa pin updated in lockstep" "claude-fable-5" "$PIN_F_QA"
# Meta-task pointer file written and the comment was added.
assert_eq "ms-F: meta-task pointer file exists" "0" \
    "$([ -f "$META_PTR" ] && echo 0 || echo 1)"
META_ID=$(cat "$META_PTR" 2>/dev/null)
# bd issue IDs have shape "<project-prefix>.<suffix>". In the fixture the
# project prefix is the mktemp dir basename (e.g. component-fixture.XXXXXX)
# which is case-preserved by mktemp on macOS, so we accept mixed case.
assert_match "ms-F: meta-task id is a valid bd id" '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$' "$META_ID"
COMMENT=$(bd show "$META_ID" 2>/dev/null | grep -A3 'MODEL SWITCH' | head -4)
assert_contains "ms-F: comment records the old->new transition" \
    "claude-opus-4-7 -> claude-fable-5" "$COMMENT"
assert_contains "ms-F: comment carries the rollback line" \
    "/workflow-model claude-opus-4-7" "$COMMENT"

# ---------------------------------------------------------------------------
# Spec G: idempotent — apply when pin already matches is a no-op.
# Re-run apply against the now-fable-5 pin; ranking is unchanged.
# ---------------------------------------------------------------------------
PIN_G_BEFORE=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
bash "$MS" apply 2>/tmp/ms-g.err >/dev/null
RC_G=$?
PIN_G_AFTER=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
assert_eq "ms-G: apply exit 0 on no-op" "0" "$RC_G"
assert_eq "ms-G: pin unchanged on no-op" "$PIN_G_BEFORE" "$PIN_G_AFTER"
# And the result line says "no change".
RESULT_G=$(grep '^model-select:' /tmp/ms-g.err | tail -1)
assert_contains "ms-G: no-change result line" "no change" "$RESULT_G"

# ---------------------------------------------------------------------------
# Spec H: META-TEST — break the ranking parser by writing a ranking that
# matches no family in the listing. The "unknown-newer wins" assertion
# from spec B is the canary: with a busted ranking the picker returns no
# candidate, so a copy of spec B run against the broken ranking MUST FAIL
# (i.e. the ID we'd compare to is NOT claude-opus-5-1; it'll be empty).
# We assert that empty != expected so the META-TEST counts as a PASS
# only when sensitivity is real.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
# Only families that DON'T appear in the listing — every match should fail.
claude-nonexistent
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_UNKNOWN_NEWER"
OUT_H=$(bash "$MS" resolve 2>&1)
ID_H=$(printf '%s\n' "$OUT_H" | grep -v '^model-select:' | head -1 | awk '{print $1}')
# If pick_best is broken (would happily return claude-opus-5-1 despite
# the ranking saying "only claude-nonexistent"), the META-TEST fails.
# Under the real implementation ID_H is empty.
if [ -z "$ID_H" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: ms-H: META-TEST — broken ranking returns no candidate (sensitivity confirmed)\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("ms-H: META-TEST sensitivity")
    printf '  FAIL: ms-H: META-TEST — broken ranking still returned %s; the picker is not sensitive to the ranking file\n' "$ID_H"
fi
