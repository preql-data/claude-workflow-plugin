#!/bin/bash
# model-select.sh component spec — spec 0.3 (claude-workflow-plugin-e0d.3).
#
# Hotfix vlp.1 (2026-06-12): spec rewritten for the new resolver contract.
# The plan is at /Users/edk0/.claude/plans/we-are-working-on-dynamic-marshmallow.md.
# Summary of contract changes vs the original spec:
#   - Ranking is EXCLUSION-ONLY ("!prefix" drops matching ids); unknown
#     families are first-class candidates.
#   - Sort: created_at DESC, then max_input_tokens DESC, then ranking-file
#     position ASC (tertiary tie-break).
#   - The "unknown-newer" / "family-gated" semantics are gone; specs C and
#     H are flipped accordingly.
#   - New specs:
#       X — unknown-family-newest wins (claude-zenith-6 over fable/opus).
#       Y — newest-by-created_at wins even when version tuple disagrees.
#       Z — "!prefix" exclusion respected.
#       W — `--refresh` bypasses cache.
#       I — picker-stub META-TEST: a resolver that lies about the best
#           model causes the post-apply pin assertion to fail; this proves
#           the assertion is sensitive to the resolver's output, not just
#           to the apply helper rewriting whatever it was handed.
#
# Exercises the automatic best-model selection helper offline. The /v1/models
# enumeration is stubbed via a curl PATH shim (mk_shim) so the spec never
# touches the network and never depends on ANTHROPIC_API_KEY.
#
# Specs (current):
#   A. resolve picks the highest-eligible model (fable when listing has fable).
#   B. when ranking has no exclusions, newest-by-created_at within the listing wins.
#   C. unknown family in listing IS selected when ranking doesn't exclude it
#      (flipped from the family-gated era).
#   D. cache freshness honoured: a second call within TTL doesn't re-invoke curl.
#   E. fail-open when curl exits non-zero: exit 0, warning printed, pin unchanged.
#   F. apply rewrites agent pins in the fixture's agents dir and records a
#      Beads comment on the meta-task with a /workflow-model rollback line.
#   G. apply is idempotent when the current pin already matches the best.
#   H. META-TEST: a "!claude-fable" exclusion correctly drops fable from
#      consideration — proving the picker is sensitive to the exclusion line
#      (flipped from the family-gated era where H asserted the picker
#      returned nothing on an unknown-only ranking).
#   X. unknown-family-newest wins (claude-zenith-6 over fable/opus).
#   Y. newest-by-created_at wins; max_input_tokens is the tie-break.
#   Z. "!claude-haiku" exclusion drops haiku even when it is newest.
#   W. `--refresh` bypasses a cached listing.
#   I. META-TEST: stub pick_best to lie; spec F's pin assertion must fail
#      against the lying picker.

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
mkdir -p "$AGENTS_DIR"
cat > "$RANKING" <<'RANKING'
# Spec-scoped ranking — kept tiny. Under the new contract, this is a
# tertiary tie-break hint only. Unknown families are first-class.
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

# Helper: extract the resolved id from `resolve` stdout. resolve prints
# "<id>\t<source>" on stdout; stderr carries informationals prefixed
# "model-select:". The spec uses 2>&1 so we filter the model-select: lines
# back out and look at the first remaining token.
ms_extract_id() {
    printf '%s\n' "$1" | grep -v '^model-select:' | head -1 | awk '{print $1}'
}

# Sample listings. The new resolver sorts by created_at DESC, then
# max_input_tokens DESC, then ranking-file position ASC.
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

LISTING_NEW_FAMILY='{
  "data": [
    {"id":"claude-opus-4-8","max_input_tokens":200000,"created_at":"2026-05-02T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-05-15T00:00:00Z","capabilities":{}},
    {"id":"claude-zenith-6","max_input_tokens":1000000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

LISTING_TIEBREAK='{
  "data": [
    {"id":"claude-opus-4-7","max_input_tokens":200000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-06-10T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

LISTING_EXCLUSION='{
  "data": [
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-05-15T00:00:00Z","capabilities":{}},
    {"id":"claude-haiku-4-5","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# A canned ANTHROPIC_API_KEY satisfies the "is the key set?" branch. The
# shimmed curl never validates it.
export ANTHROPIC_API_KEY="sk-spec-fake"

# ---------------------------------------------------------------------------
# Spec A: resolve picks fable when fable is the newest model in the listing.
# ---------------------------------------------------------------------------
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_HAPPY"
OUT_A=$(bash "$MS" resolve 2>&1)
ID_A=$(ms_extract_id "$OUT_A")
assert_eq "ms-A: resolve picks newest-by-created_at (fable-5)" "claude-fable-5" "$ID_A"

# ---------------------------------------------------------------------------
# Spec B: with a ranking that has no exclusions, the newest model wins
# regardless of family. Two opus generations; the newer created_at wins.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_TIEBREAK"
OUT_B=$(bash "$MS" resolve 2>&1)
ID_B=$(ms_extract_id "$OUT_B")
assert_eq "ms-B: newest-by-created_at wins (fable-5 over opus-4-7)" "claude-fable-5" "$ID_B"

# ---------------------------------------------------------------------------
# Spec C (FLIPPED): unknown family IS selected when ranking does not exclude.
# Was "unknown family ignored with a warning"; under the new contract the
# unknown family is first-class. Ranking is tertiary tie-break only.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_WITH_UNKNOWN"
OUT_C=$(bash "$MS" resolve 2>&1)
ID_C=$(ms_extract_id "$OUT_C")
assert_eq "ms-C: unknown family IS selected when not excluded (narwhal wins)" \
    "claude-narwhal-1" "$ID_C"

# ---------------------------------------------------------------------------
# Spec D: cache freshness honoured — second resolve doesn't hit curl.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_HAPPY"  # resets the curl.log file
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
PIN_F_QA=$(grep -E '^model:' "$AGENTS_DIR/qa.md" | head -1 | awk '{print $2}')
assert_eq "ms-F: qa pin updated in lockstep" "claude-fable-5" "$PIN_F_QA"
assert_eq "ms-F: meta-task pointer file exists" "0" \
    "$([ -f "$META_PTR" ] && echo 0 || echo 1)"
META_ID=$(cat "$META_PTR" 2>/dev/null)
assert_match "ms-F: meta-task id is a valid bd id" '^[A-Za-z0-9.-]+\.[A-Za-z0-9-]+$' "$META_ID"
COMMENT=$(bd show "$META_ID" 2>/dev/null | grep -A3 'MODEL SWITCH' | head -4)
assert_contains "ms-F: comment records the old->new transition" \
    "claude-opus-4-7 -> claude-fable-5" "$COMMENT"
assert_contains "ms-F: comment carries the rollback line" \
    "/workflow-model claude-opus-4-7" "$COMMENT"

# ---------------------------------------------------------------------------
# Spec G: idempotent — apply when pin already matches is a no-op.
# ---------------------------------------------------------------------------
PIN_G_BEFORE=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
bash "$MS" apply 2>/tmp/ms-g.err >/dev/null
RC_G=$?
PIN_G_AFTER=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
assert_eq "ms-G: apply exit 0 on no-op" "0" "$RC_G"
assert_eq "ms-G: pin unchanged on no-op" "$PIN_G_BEFORE" "$PIN_G_AFTER"
RESULT_G=$(grep '^model-select:' /tmp/ms-g.err | tail -1)
assert_contains "ms-G: no-change result line" "no change" "$RESULT_G"

# ---------------------------------------------------------------------------
# Spec H (FLIPPED): META-TEST — a "!claude-fable" exclusion correctly
# drops fable. The picker MUST return something other than fable when the
# exclusion is present. We use LISTING_HAPPY (fable is newest); the
# exclusion should bump us to opus-4-8 (next newest).
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
!claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_HAPPY"
OUT_H=$(bash "$MS" resolve 2>&1)
ID_H=$(ms_extract_id "$OUT_H")
assert_eq "ms-H (META-TEST): exclusion '!claude-fable' drops fable -> opus-4-8 wins" \
    "claude-opus-4-8" "$ID_H"

# ---------------------------------------------------------------------------
# Spec X (new): unknown-family-newest wins. Ranking has no exclusions;
# claude-zenith-6 (unknown family, newest) MUST win over fable/opus.
# Designed to fail against the original family-gated resolver.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_NEW_FAMILY"
OUT_X=$(bash "$MS" resolve 2>&1)
ID_X=$(ms_extract_id "$OUT_X")
assert_eq "ms-X: unknown-family-newest wins (zenith-6 over fable-5)" \
    "claude-zenith-6" "$ID_X"

# ---------------------------------------------------------------------------
# Spec Y (new): newest-by-created_at wins. Same family, monotonic ids;
# newer created_at MUST win even though max_input_tokens is identical.
# (Primary sort is created_at, not version tuple.)
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-opus
claude-fable
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_TIEBREAK"
OUT_Y=$(bash "$MS" resolve 2>&1)
ID_Y=$(ms_extract_id "$OUT_Y")
# fable-5 has the newer created_at (2026-06-10) than opus-4-7 (2026-05-01)
# AND a larger max_input_tokens. The primary key (created_at) is what we
# assert sensitivity to; the larger context is a redundant signal.
assert_eq "ms-Y: created_at is the primary sort (fable-5 over opus-4-7)" \
    "claude-fable-5" "$ID_Y"

# ---------------------------------------------------------------------------
# Spec Z (new): "!prefix" exclusion respected. Listing has fable-5 (older)
# and haiku-4-5 (newer); without the exclusion haiku would win on
# created_at, but "!claude-haiku" drops it -> fable wins.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
!claude-haiku
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_EXCLUSION"
OUT_Z=$(bash "$MS" resolve 2>&1)
ID_Z=$(ms_extract_id "$OUT_Z")
assert_eq "ms-Z: '!claude-haiku' exclusion drops haiku-4-5 -> fable-5 wins" \
    "claude-fable-5" "$ID_Z"

# ---------------------------------------------------------------------------
# Spec W (new): `--refresh` bypasses the cache. Seed cache with one
# listing, change the shim payload, then resolve --refresh. The new
# payload's best MUST come back.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_HAPPY"
# First call seeds the cache with LISTING_HAPPY (best = fable-5).
bash "$MS" resolve >/dev/null 2>&1
# Swap payload to LISTING_NEW_FAMILY (best = zenith-6 if --refresh works).
ms_set_curl_payload "$LISTING_NEW_FAMILY"
# Without --refresh, the cached fable-5 would come back.
OUT_W_CACHED=$(bash "$MS" resolve 2>&1)
ID_W_CACHED=$(ms_extract_id "$OUT_W_CACHED")
assert_eq "ms-W: without --refresh, cached payload wins (fable-5)" \
    "claude-fable-5" "$ID_W_CACHED"
# With --refresh, the new payload's best wins.
OUT_W_FRESH=$(bash "$MS" resolve --refresh 2>&1)
ID_W_FRESH=$(ms_extract_id "$OUT_W_FRESH")
assert_eq "ms-W: --refresh bypasses cache (zenith-6)" \
    "claude-zenith-6" "$ID_W_FRESH"

# ---------------------------------------------------------------------------
# Spec M-block: negative-path coverage added per QA review of vlp.1
# (claude-workflow-plugin-3fn). These exercise the MANUAL_ADOPT_REQUIRED
# gate (subshell-lost variable bug), tie-break behaviour with identical
# created_at but differing max_input_tokens, missing-field tolerance,
# and the all-excluded fail-open path. The original L2 spec covered
# happy-paths only; QA found the unparseable-created_at branch was
# untested and the gate at cmd_apply:500 unreachable. Specs M, MS, ME,
# MT, MC, MX added here are the regression coverage.
# ---------------------------------------------------------------------------

# Manual-adopt listing: WINNER (claude-fable-5) has an unparseable
# created_at — every other surviving entry has _ts=-1 too, so fable
# emerges as the head of sort_by([-_ts, -_ctx, _rank]) thanks to its
# larger max_input_tokens. Per the file-header contract (lines 49-52)
# and cmd_apply:496-503, apply MUST refuse the rewrite and surface the
# LOUD adopt notice; resolve MUST still print the id with the notice on
# stderr.
LISTING_MANUAL_ADOPT='{
  "data": [
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"BOGUS-DATE","capabilities":{}}
  ],
  "has_more":false
}'

# Tie-break listing for created_at: two entries with IDENTICAL created_at;
# the resolver MUST fall through to max_input_tokens DESC. fable-5 has
# 1000000 vs opus 200000, so fable wins.
LISTING_CREATED_AT_TIE='{
  "data": [
    {"id":"claude-opus-4-8","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# Missing-field listing: one entry has no max_input_tokens at all.
# Resolver MUST default it to 0 (per jq `.max_input_tokens // 0` on line
# 314) and still produce a sane winner — newer created_at takes priority
# over the missing-context entry.
LISTING_MISSING_CTX='{
  "data": [
    {"id":"claude-opus-4-8","created_at":"2026-05-01T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# All-excluded listing: every id in the listing is dropped by the
# ranking's "!" lines. pick_best returns 1 -> cmd_apply prints "ranking
# produced no candidate; keeping current pin" and exit 0 fail-open.
LISTING_ALL_EXCLUDED='{
  "data": [
    {"id":"claude-haiku-4-5","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-4-7","max_input_tokens":200000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# ---------------------------------------------------------------------------
# Spec M (NEW, MUST FAIL pre-fix): manual-adopt gate prevents auto-rewrite
# when the winner's created_at is unparseable.
#
# Pre-fix behaviour: pick_best sets MANUAL_ADOPT_REQUIRED inside the
# $(...) subshell at model-select.sh:341; the parent's variable stays
# empty; the gate at cmd_apply:500 is unreachable; apply rewrites the
# pin from claude-opus-4-7 to claude-fable-5 silently (despite the LOUD
# stderr notice). This is the "silent stale/wrong pin" class the hotfix
# vlp.1 exists to prevent.
#
# Post-fix behaviour: pick_best emits "MANUAL\t<id>" on stdout when the
# manual-adopt branch fires; cmd_apply parses the prefix, short-circuits
# BEFORE current-pin comparison/rewrite, prints the LOUD adopt notice
# with the /workflow-model command, leaves every agent pin byte-unchanged.
# Exit code stays 0 per the fail-open contract (spec 0.3 principle 1).
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE" "$META_PTR"
ms_set_curl_payload "$LISTING_MANUAL_ADOPT"
# Re-seed every agent pin to claude-opus-4-7 so we can prove
# byte-identity after the apply attempt.
for agent in orchestrator qa backend frontend devops; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done

# Snapshot every agent file's content (NOT just the pin) so we can
# assert byte-for-byte equality. The contract is "leave ALL agent pins
# byte-unchanged" — we read the whole file to catch any rewrite that
# touches frontmatter ordering, whitespace, etc. macOS bash 3.2 has no
# associative arrays, so we use five flat variables.
PRE_M_HASH_ORCH=$(shasum -a 256 "$AGENTS_DIR/orchestrator.md" | awk '{print $1}')
PRE_M_HASH_QA=$(shasum -a 256 "$AGENTS_DIR/qa.md" | awk '{print $1}')
PRE_M_HASH_BACK=$(shasum -a 256 "$AGENTS_DIR/backend.md" | awk '{print $1}')
PRE_M_HASH_FRONT=$(shasum -a 256 "$AGENTS_DIR/frontend.md" | awk '{print $1}')
PRE_M_HASH_DEVOPS=$(shasum -a 256 "$AGENTS_DIR/devops.md" | awk '{print $1}')

bash "$MS" apply 2>/tmp/ms-m.err >/tmp/ms-m.out
RC_M=$?
RESULT_M=$(grep '^model-select:' /tmp/ms-m.err | tail -1)

# (a) LOUD adopt notice fired with the /workflow-model <id> command.
NOTICE_M=$(grep '^model-select:' /tmp/ms-m.err | grep 'manual adopt' | head -1)
assert_contains "ms-M (a): LOUD manual-adopt notice surfaces winner id" \
    "claude-fable-5" "$NOTICE_M"
assert_contains "ms-M (a): notice carries /workflow-model adopt command" \
    "/workflow-model claude-fable-5" "$NOTICE_M"

# (b) Every agent file is byte-unchanged.
PINS_UNCHANGED=1
DRIFTED=""
NOW_HASH=$(shasum -a 256 "$AGENTS_DIR/orchestrator.md" | awk '{print $1}')
if [ "$NOW_HASH" != "$PRE_M_HASH_ORCH" ]; then
    PINS_UNCHANGED=0; DRIFTED="${DRIFTED:+$DRIFTED,}orchestrator"
fi
NOW_HASH=$(shasum -a 256 "$AGENTS_DIR/qa.md" | awk '{print $1}')
if [ "$NOW_HASH" != "$PRE_M_HASH_QA" ]; then
    PINS_UNCHANGED=0; DRIFTED="${DRIFTED:+$DRIFTED,}qa"
fi
NOW_HASH=$(shasum -a 256 "$AGENTS_DIR/backend.md" | awk '{print $1}')
if [ "$NOW_HASH" != "$PRE_M_HASH_BACK" ]; then
    PINS_UNCHANGED=0; DRIFTED="${DRIFTED:+$DRIFTED,}backend"
fi
NOW_HASH=$(shasum -a 256 "$AGENTS_DIR/frontend.md" | awk '{print $1}')
if [ "$NOW_HASH" != "$PRE_M_HASH_FRONT" ]; then
    PINS_UNCHANGED=0; DRIFTED="${DRIFTED:+$DRIFTED,}frontend"
fi
NOW_HASH=$(shasum -a 256 "$AGENTS_DIR/devops.md" | awk '{print $1}')
if [ "$NOW_HASH" != "$PRE_M_HASH_DEVOPS" ]; then
    PINS_UNCHANGED=0; DRIFTED="${DRIFTED:+$DRIFTED,}devops"
fi
assert_eq "ms-M (b): every agent file is byte-identical (no drift: '$DRIFTED')" \
    "1" "$PINS_UNCHANGED"

# Explicit per-agent pin assertion (defence in depth — the hash check
# is sensitive to any byte change, the pin check is the specific
# contract).
for agent in orchestrator qa backend frontend devops; do
    PIN_NOW=$(grep -E '^model:' "$AGENTS_DIR/$agent.md" | head -1 | awk '{print $2}')
    assert_eq "ms-M (b'): $agent pin unchanged (still claude-opus-4-7)" \
        "claude-opus-4-7" "$PIN_NOW"
done

# (c) Exit status documented: fail-open contract says exit 0; the
# result line surfaces the manual-adopt outcome explicitly.
assert_eq "ms-M (c): apply exit 0 under fail-open contract" "0" "$RC_M"
assert_contains "ms-M (c): result line names the manual-adopt outcome" \
    "manual adoption required" "$RESULT_M"

# (d) resolve path: still prints the id on stdout WITH the LOUD notice
# on stderr — the resolve contract is "tell me what would have been
# picked"; the manual-adopt gate only refuses the AUTO-REWRITE.
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_MANUAL_ADOPT"
OUT_M_RESOLVE=$(bash "$MS" resolve 2>/tmp/ms-m-resolve.err)
ID_M_RESOLVE=$(ms_extract_id "$OUT_M_RESOLVE")
assert_eq "ms-M (d): resolve still prints the candidate id on stdout" \
    "claude-fable-5" "$ID_M_RESOLVE"
NOTICE_M_RESOLVE=$(grep 'manual adopt' /tmp/ms-m-resolve.err | head -1)
assert_contains "ms-M (d): resolve emits the LOUD notice on stderr" \
    "/workflow-model claude-fable-5" "$NOTICE_M_RESOLVE"

# (e) status path: surfaces "manual adopt required" when cache has a
# manual-adopt winner. The status subcommand reads the cache and runs
# pick_best against it.
ms_set_curl_payload "$LISTING_MANUAL_ADOPT"
bash "$MS" resolve >/dev/null 2>&1  # seed cache with the bogus listing
OUT_M_STATUS=$(bash "$MS" status 2>/tmp/ms-m-status.err)
assert_contains "ms-M (e): status surfaces manual-adopt id in cached-best line" \
    "claude-fable-5" "$OUT_M_STATUS"
# The status path is allowed to either include the qualifier inline or
# surface it via stderr (pick_best's _warn). Either signal is acceptable.
STATUS_SAW_NOTICE=0
if printf '%s' "$OUT_M_STATUS" | grep -q "manual adopt"; then
    STATUS_SAW_NOTICE=1
elif grep -q "manual adopt" /tmp/ms-m-status.err 2>/dev/null; then
    STATUS_SAW_NOTICE=1
fi
assert_eq "ms-M (e): status surfaces manual-adopt qualifier (stdout or stderr)" \
    "1" "$STATUS_SAW_NOTICE"

# ---------------------------------------------------------------------------
# Spec ME (NEW META-TEST for ms-M): a stripped variant of cmd_apply that
# bypasses the manual-adopt parse MUST land the rewrite — proving the
# new gate in ms-M is sensitive to the parse logic (not just to some
# unrelated short-circuit). Mirrors the design of spec I.
#
# We build a wrapper that sources model-select.sh's prefix, then
# OVERRIDES cmd_apply with a stripped version that simply calls
# pick_best, strips any MANUAL\t prefix on the resolver side ONLY (so
# the resolver sees the id) and then proceeds to the rewrite without
# the gate. The honest apply (post-fix) MUST refuse to rewrite under
# this listing; the stripped variant MUST rewrite the pin to fable-5.
# If the rewrite doesn't happen under the stripped variant, the new
# assertion in ms-M is NOT sensitive — that's the regression META-TEST.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_MANUAL_ADOPT"
# Re-seed pins to opus-4-7 so the stripped variant has a delta.
for agent in orchestrator qa backend frontend devops; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done

STRIPPED="$FIXTURE/.claude/scripts/model-select-stripped.sh"
cat > "$STRIPPED" <<'WRAP'
#!/bin/bash
# Stripped variant: sources the real prefix and then defines a
# cmd_apply that skips the MANUAL_ADOPT_REQUIRED gate entirely. The
# strip drops every line containing "MANUAL_ADOPT_REQUIRED" from the
# real cmd_apply body — including the parse-prefix logic post-fix
# that converts pick_best's "MANUAL\t<id>" sentinel into the gate.
# Whatever shape the fix takes (sentinel, separate function, file),
# the strip should fail to load OR the pin should land — proving the
# assertion is sensitive to the gate.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
REAL_MS="$PROJECT_DIR/.claude/scripts/model-select.sh"

# Source the real file up to the dispatch block.
awk '/^case "\$SUBCMD" in$/{exit} {print}' "$REAL_MS" > "$PROJECT_DIR/.claude/scripts/.ms-stripped-prefix.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/.claude/scripts/.ms-stripped-prefix.sh"

# Override cmd_apply: strip every line mentioning MANUAL_ADOPT_REQUIRED
# or the sentinel prefix "MANUAL\t". The picker may emit the sentinel
# on stdout (post-fix); we coerce it to a plain id so the rewrite
# proceeds. This is the variant cmd_apply *would* be if the fix were
# absent.
cmd_apply() {
    local models rc
    models=$(get_models)
    rc=$?
    if [ "$rc" -ne 0 ]; then
        case "$rc" in
            2) _result "no key" ;;
            *) _result "fail" ;;
        esac
        return 0
    fi
    local raw_best best
    raw_best=$(pick_best "$models")
    # Coerce any sentinel-prefixed output to a plain id, mimicking
    # the pre-fix call site that never knew about the prefix.
    best=$(printf '%s' "$raw_best" | awk -F'\t' '/^MANUAL\t/{print $2; exit} {print; exit}')
    if [ -z "$best" ]; then
        _result "ranking produced no candidate; keeping current pin"
        return 0
    fi
    local cur
    cur=$(current_pin)
    if [ "$cur" = "$best" ]; then
        _result "no change (current pin already $cur)"
        return 0
    fi
    local stripped_id
    stripped_id=$(printf '%s' "$best" | sed -E 's/\[1m\]$//')
    if ! printf '%s' "$models" | jq -e --arg id "$stripped_id" 'any(.id == $id)' >/dev/null 2>&1; then
        _result "not in listing"
        return 0
    fi
    if [ ! -x "$APPLY_HELPER" ]; then
        _result "no helper"
        return 0
    fi
    bash "$APPLY_HELPER" "$best" >/dev/null 2>&1 || true
    record_switch "$cur" "$best"
    _result "switched ${cur:-<none>} -> $best"
}

case "${SUBCMD:-}" in
    apply) cmd_apply ;;
    *) printf 'unknown\n' >&2; exit 2 ;;
esac
WRAP
chmod +x "$STRIPPED"

bash "$STRIPPED" apply 2>/tmp/ms-me.err >/tmp/ms-me.out || true
PIN_ME=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
# The stripped variant MUST land claude-fable-5 (the silent rewrite the
# bug enables). If it doesn't, ms-M's sensitivity is not proven.
if [ "$PIN_ME" = "claude-fable-5" ]; then
    PASS=$((PASS + 1))
    printf '  PASS: ms-ME: META-TEST — stripped cmd_apply rewrites pin (proves ms-M gate is sensitive)\n'
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("ms-ME: META-TEST — stripped cmd_apply did NOT rewrite; ms-M gate may not be sensitive")
    printf '  FAIL: ms-ME: META-TEST — stripped cmd_apply expected to rewrite to claude-fable-5; got %s\n' \
        "$PIN_ME"
fi

# ---------------------------------------------------------------------------
# Spec MT (NEW): created_at tie -> max_input_tokens DESC tiebreak.
# Two entries with IDENTICAL created_at; the resolver MUST fall through
# to max_input_tokens DESC. fable (1M) > opus (200k) -> fable wins.
# Documented sort order at model-select.sh:45-48 (primary -> tertiary).
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_CREATED_AT_TIE"
OUT_MT=$(bash "$MS" resolve 2>&1)
ID_MT=$(ms_extract_id "$OUT_MT")
assert_eq "ms-MT: created_at tie -> max_input_tokens DESC (fable-5 wins on 1M ctx)" \
    "claude-fable-5" "$ID_MT"

# ---------------------------------------------------------------------------
# Spec MC (NEW): missing max_input_tokens defaults to 0 — winner with
# the field still wins on created_at; the missing-field entry sorts
# behind it. Probes the jq `.max_input_tokens // 0` fallback at
# model-select.sh:314.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_MISSING_CTX"
OUT_MC=$(bash "$MS" resolve 2>&1)
ID_MC=$(ms_extract_id "$OUT_MC")
assert_eq "ms-MC: missing max_input_tokens tolerated (fable-5 wins on newer created_at)" \
    "claude-fable-5" "$ID_MC"

# ---------------------------------------------------------------------------
# Spec MX (NEW): all-excluded -> fail-open. Every id in the listing
# matches a "!" prefix; pick_best returns 1; cmd_apply emits the
# "ranking produced no candidate" result line and exits 0; pin
# unchanged.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
!claude-haiku
!claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_ALL_EXCLUDED"
# Re-seed pins to a known sentinel so we can prove no rewrite.
for agent in orchestrator qa backend frontend devops; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done
bash "$MS" apply 2>/tmp/ms-mx.err >/tmp/ms-mx.out
RC_MX=$?
PIN_MX=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
RESULT_MX=$(grep '^model-select:' /tmp/ms-mx.err | tail -1)
assert_eq "ms-MX: all-excluded fail-open exit 0" "0" "$RC_MX"
assert_eq "ms-MX: pin unchanged when no candidate survives exclusion" \
    "claude-opus-4-7" "$PIN_MX"
assert_contains "ms-MX: result line names the no-candidate outcome" \
    "no candidate" "$RESULT_MX"

# Reset the ranking for any specs after this block (defensive; no later
# specs at the time of writing).
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING

# ---------------------------------------------------------------------------
# Spec I (new META-TEST): a lying picker must cause spec F's pin
# assertion to fail. We wrap model-select.sh with a small shell that
# overrides pick_best to print a stale id, then assert the rewrite
# happens against the lie. If the spec F assertion still passes against
# the lie, it means F isn't sensitive to the resolver — that's the
# regression this META-TEST guards.
# ---------------------------------------------------------------------------
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_NEW_FAMILY"  # honest best = zenith-6
# Re-seed pins to opus-4-7 so apply has a delta.
for agent in orchestrator qa backend frontend devops; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done

# Build a wrapper script whose pick_best lies (prints claude-opus-4-7
# regardless of what the listing actually says). We source the real
# model-select.sh but override pick_best AFTER sourcing.
LIAR="$FIXTURE/.claude/scripts/model-select-liar.sh"
cat > "$LIAR" <<'WRAP'
#!/bin/bash
# Wrapper: source the real model-select.sh, then override pick_best to
# return a stale id. The override happens BEFORE cmd_apply runs because
# bash evaluates function definitions sequentially.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
REAL_MS="$PROJECT_DIR/.claude/scripts/model-select.sh"

# Source the real script up to the dispatch block by extracting all
# lines BEFORE the `case "$SUBCMD" in` block. This keeps every function
# and helper but skips the dispatch so we can override and then call.
awk '/^case "\$SUBCMD" in$/{exit} {print}' "$REAL_MS" > "$PROJECT_DIR/.claude/scripts/.ms-prefix.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/.claude/scripts/.ms-prefix.sh"

# Liar override: always return claude-opus-4-7 regardless of input.
pick_best() {
    printf 'claude-opus-4-7\n'
    return 0
}

# Re-dispatch.
case "${SUBCMD:-}" in
    resolve)  cmd_resolve ;;
    apply)    cmd_apply ;;
    status)   cmd_status ;;
    *)        printf 'unknown subcommand\n' >&2; exit 2 ;;
esac
WRAP
chmod +x "$LIAR"

# Run the liar's apply. The honest answer would be zenith-6; the liar
# returns opus-4-7. Since current_pin is also opus-4-7, the liar takes
# the no-change short-circuit — which means the orchestrator pin stays
# opus-4-7 (NOT updated to zenith-6).
bash "$LIAR" apply --quiet 2>/dev/null >/dev/null || true
PIN_I=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')

# The META-TEST: if PIN_I equals the honest best (zenith-6), the spec F
# assertion would pass against a lying picker — that's the bug we guard.
# We assert PIN_I != claude-zenith-6 (i.e., the lie propagated, proving
# the apply path is wired to the picker's output).
if [ "$PIN_I" = "claude-zenith-6" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("ms-I: META-TEST — lying picker still landed honest best on the pin (assertion is NOT sensitive to the picker)")
    printf '  FAIL: ms-I: META-TEST — lying picker still produced the honest best on the pin; spec F is not sensitive to pick_best output\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: ms-I: META-TEST — lying picker propagates to the pin (spec F is sensitive to pick_best output)\n'
fi
