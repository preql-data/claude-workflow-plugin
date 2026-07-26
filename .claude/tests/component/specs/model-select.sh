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
#     SUPERSEDED by en9 (2026-07-25) — see the T-block at the bottom of
#     this file. The sort is now `[._class, -(._ts), -(._ctx)]`:
#     capability class (ranking-file tier index; unknown family = TOP
#     class) is PRIMARY and recency only orders WITHIN a class. Specs
#     written against the recency-primary era still hold except ms-Y,
#     which was re-scoped to intra-class recency (see its header).
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
#   Y. within one capability class, created_at (not the version tuple) is
#      the sort key (re-scoped by en9; see the spec's own header).
#   Z. "!claude-haiku" exclusion drops haiku even when it is newest.
#   W. `--refresh` bypasses a cached listing.
#   I. META-TEST: stub pick_best to lie; spec F's pin assertion must fail
#      against the lying picker.
#   T-block (en9). Capability class beats recency for KNOWN families:
#      T1 tier-vs-recency regression (older fable beats newer opus),
#      T2 the live role split end-to-end, T3 unknown-newer day-zero,
#      T4 unknown-older, T5 top-class bogus date -> manual-adopt,
#      TM META-TEST: a pick_best reverted to the recency-primary sort
#      must make T1's assertion fail.

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

# Sample listings. Since en9 the resolver sorts by capability class ASC
# (ranking-file tier index; unknown family = top class), then created_at
# DESC, then max_input_tokens DESC. Listings below that mix families are
# read with that ordering in mind — each spec names the key it probes.
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
# V1 (bi3.1): the auto-switch comment is role-tagged and its rollback line
# carries the `--role <role>` scope so a single lane can be reverted.
assert_contains "ms-F: comment carries the role-tagged rollback line" \
    "/workflow-model --role orchestrator claude-opus-4-7" "$COMMENT"

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
# V1 (bi3.1): the role-aware apply summarises with "(N switched)"; a no-op
# run reports "(0 switched)".
assert_contains "ms-G: no-op result line reports zero switches" "(0 switched)" "$RESULT_G"

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
# Spec Y: created_at — NOT the id's version tuple — orders candidates.
#
# RE-SCOPED BY en9 (2026-07-25). The original spec asserted this across
# FAMILIES with a ranking file that listed `claude-opus` ABOVE
# `claude-fable`, then expected the newer fable id to win. Under the en9
# contract that ranking makes opus the TOP capability class, so the older
# opus id correctly wins and the old expectation is no longer the
# contract (cross-family ordering is now the T-block's subject).
#
# The property Y actually exists to protect — "the sort key is the
# release date, not the version number embedded in the id" — is
# preserved here and made SHARPER by scoping it inside one class: two
# claude-opus ids where the NEWER created_at sits on the LOWER version
# tuple. Contexts are identical (1M each) so the _ctx tie-break cannot
# decide it; only -(._ts) can.
# ---------------------------------------------------------------------------
LISTING_INTRA_CLASS_RECENCY='{
  "data": [
    {"id":"claude-opus-4-9","max_input_tokens":1000000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-4-8","max_input_tokens":1000000,"created_at":"2026-06-10T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'
cat > "$RANKING" <<'RANKING'
claude-fable
claude-opus
RANKING
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_INTRA_CLASS_RECENCY"
OUT_Y=$(bash "$MS" resolve 2>&1)
ID_Y=$(ms_extract_id "$OUT_Y")
assert_eq "ms-Y: within a class, created_at decides — not the version tuple (opus-4-8 over opus-4-9)" \
    "claude-opus-4-8" "$ID_Y"

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

# ===========================================================================
# Spec R-block: role-aware resolution (v4.0.0 Phase V1 / bi3.1).
#
# These extend the spec to the model-roles surface. Everything reuses the
# curl-shim + LISTING fixture pattern above. A `.claude/model-roles` file is
# seeded per case (the earlier specs run with NO model-roles, i.e. all-`top`,
# which is exactly the single-pin behavior they assert).
# ===========================================================================

ARTIFACT="$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json"

# The R-block asserts on all SEVEN agents; seed grader/judge alongside the
# five the earlier specs use so the parity + byte-unchanged checks are real.
for agent in grader judge; do
    cat > "$AGENTS_DIR/$agent.md" <<EOF
---
name: $agent
description: stub
model: claude-opus-4-7
---
stub body for $agent
EOF
done

# Default V1 role map for the R-block: orchestrator/reviewer top, implementer
# opus-class.
seed_role_map() {
    cat > "$FIXTURE/.claude/model-roles" <<'ROLES'
orchestrator=top
implementer=opus-class
reviewer=top
ROLES
}

# LISTING_OPUS_PRESENT: a newer NON-opus family (fable-9) plus two opus
# generations. top -> fable-9; opus-class -> opus-5-0 (newest opus).
LISTING_OPUS_PRESENT='{
  "data": [
    {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-5-0","max_input_tokens":400000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-4-8","max_input_tokens":200000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# LISTING_NO_OPUS: no claude-opus-* at all -> implementer must fall back to
# top and record implementer_fallback:true.
LISTING_NO_OPUS='{
  "data": [
    {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z","capabilities":{}},
    {"id":"claude-sonnet-4","max_input_tokens":200000,"created_at":"2026-06-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# ---------------------------------------------------------------------------
# Spec R1 (LISTING_OPUS_PRESENT): implementer gets the opus id while
# orchestrator/reviewer get the top pick; artifact records the split.
# ---------------------------------------------------------------------------
seed_role_map
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
for agent in orchestrator qa backend frontend devops grader judge; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done
bash "$MS" apply --quiet 2>/tmp/ms-r1.err >/dev/null
PIN_R1_ORCH=$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')
PIN_R1_IMPL=$(grep -E '^model:' "$AGENTS_DIR/backend.md" | head -1 | awk '{print $2}')
PIN_R1_REV=$(grep -E '^model:' "$AGENTS_DIR/qa.md" | head -1 | awk '{print $2}')
assert_eq "ms-R1: orchestrator gets the top pick (fable-9)" "claude-fable-9" "$PIN_R1_ORCH"
assert_eq "ms-R1: implementer gets the newest opus (opus-5-0)" "claude-opus-5-0" "$PIN_R1_IMPL"
assert_eq "ms-R1: reviewer gets the top pick (fable-9)" "claude-fable-9" "$PIN_R1_REV"
assert_eq "ms-R1: frontend rides the implementer lane too" "claude-opus-5-0" \
    "$(grep -E '^model:' "$AGENTS_DIR/frontend.md" | head -1 | awk '{print $2}')"
assert_json_field "ms-R1: artifact records implementer opus id" \
    "$(cat "$ARTIFACT")" ".roles.implementer" "claude-opus-5-0"
assert_json_field "ms-R1: artifact records orchestrator top id" \
    "$(cat "$ARTIFACT")" ".roles.orchestrator" "claude-fable-9"
# NB: pipe through tostring — assert_json_field appends `// empty`, and jq's
# `//` treats a boolean `false` as empty (so a raw `.implementer_fallback`
# would read as ""). `tostring` yields the literal "false"/"true".
assert_json_field "ms-R1: artifact implementer_fallback is false" \
    "$(cat "$ARTIFACT")" ".implementer_fallback | tostring" "false"
assert_json_field "ms-R1: artifact reviewer_lane defaults to claude" \
    "$(cat "$ARTIFACT")" ".reviewer_lane" "claude"

# ---------------------------------------------------------------------------
# Spec R2 (LISTING_NO_OPUS): implementer falls back to top; artifact says so.
# ---------------------------------------------------------------------------
seed_role_map
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_NO_OPUS"
bash "$MS" apply --quiet 2>/tmp/ms-r2.err >/dev/null
assert_eq "ms-R2: implementer falls back to the top pick (fable-9)" "claude-fable-9" \
    "$(grep -E '^model:' "$AGENTS_DIR/backend.md" | head -1 | awk '{print $2}')"
assert_json_field "ms-R2: artifact flags implementer_fallback true" \
    "$(cat "$ARTIFACT")" ".implementer_fallback | tostring" "true"
assert_json_field "ms-R2: artifact implementer id is the top pick" \
    "$(cat "$ARTIFACT")" ".roles.implementer" "claude-fable-9"

# ---------------------------------------------------------------------------
# Spec R3 (subset exclusion): "!claude-opus-5" drops opus-5 from the opus
# subset, so the implementer lands the surviving older opus (opus-4-8) while
# orchestrator still gets the top pick. Proves the ranking exclusion is
# applied INSIDE the opus-class subset.
# ---------------------------------------------------------------------------
seed_role_map
cat > "$RANKING" <<'RANKING'
!claude-opus-5
claude-opus
RANKING
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
bash "$MS" apply --quiet 2>/tmp/ms-r3.err >/dev/null
assert_eq "ms-R3: exclusion inside subset -> implementer gets surviving opus (opus-4-8)" \
    "claude-opus-4-8" "$(grep -E '^model:' "$AGENTS_DIR/backend.md" | head -1 | awk '{print $2}')"
assert_eq "ms-R3: orchestrator still gets the top pick (fable-9)" \
    "claude-fable-9" "$(grep -E '^model:' "$AGENTS_DIR/orchestrator.md" | head -1 | awk '{print $2}')"
# Restore the non-exclusion ranking for later cases.
cat > "$RANKING" <<'RANKING'
claude-opus
RANKING

# ---------------------------------------------------------------------------
# Spec R4 (all-or-nothing MANUAL): a manual-adopt listing (winner has an
# unparseable created_at) must leave ALL SEVEN pins byte-unchanged AND write
# NO artifact. Reuses LISTING_MANUAL_ADOPT from the M-block.
# ---------------------------------------------------------------------------
seed_role_map
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_MANUAL_ADOPT"
for agent in orchestrator qa backend frontend devops grader judge; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done
# Snapshot all seven files (whole file, not just the pin).
R4_UNCHANGED=1
R4_DRIFT=""
for agent in orchestrator qa backend frontend devops grader judge; do
    eval "PRE_R4_${agent}=\$(shasum -a 256 \"\$AGENTS_DIR/\$agent.md\" | awk '{print \$1}')"
done
bash "$MS" apply --quiet 2>/tmp/ms-r4.err >/dev/null
RC_R4=$?
for agent in orchestrator qa backend frontend devops grader judge; do
    NOW=$(shasum -a 256 "$AGENTS_DIR/$agent.md" | awk '{print $1}')
    eval "PRE=\$PRE_R4_${agent}"
    if [ "$NOW" != "$PRE" ]; then
        R4_UNCHANGED=0; R4_DRIFT="${R4_DRIFT:+$R4_DRIFT,}$agent"
    fi
done
assert_eq "ms-R4: apply exit 0 under all-or-nothing manual-adopt" "0" "$RC_R4"
assert_eq "ms-R4: all seven agent files byte-identical (no drift: '$R4_DRIFT')" "1" "$R4_UNCHANGED"
assert_eq "ms-R4: NO artifact written on the manual-adopt path" "1" \
    "$([ ! -f "$ARTIFACT" ] && echo 1 || echo 0)"
RESULT_R4=$(grep '^model-select:' /tmp/ms-r4.err | tail -1)
assert_contains "ms-R4: result line names the manual-adopt outcome" \
    "manual adoption required" "$RESULT_R4"

# ms-R4b: stale-beats-none. Pre-seed an artifact, then a manual-adopt apply
# must LEAVE IT in place (fail-open never clobbers the prior mapping).
printf '{"roles":{"orchestrator":"claude-prev-1","implementer":"claude-prev-1","reviewer":"claude-prev-1"},"reviewer_lane":"claude"}' > "$ARTIFACT"
ms_set_curl_payload "$LISTING_MANUAL_ADOPT"
rm -f "$CACHE"
bash "$MS" apply --quiet 2>/dev/null >/dev/null
assert_json_field "ms-R4b: stale-beats-none — prior artifact preserved on fail-open" \
    "$(cat "$ARTIFACT")" ".roles.orchestrator" "claude-prev-1"

# ---------------------------------------------------------------------------
# Spec R5 (lane flip): WORKFLOW_REVIEWER_LANE=codex must land in the artifact
# and drive the statusline reviewer segment to the literal `sol`.
# ---------------------------------------------------------------------------
seed_role_map
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
WORKFLOW_REVIEWER_LANE=codex bash "$MS" apply --quiet 2>/tmp/ms-r5.err >/dev/null
assert_json_field "ms-R5: env seam flips artifact reviewer_lane to codex" \
    "$(cat "$ARTIFACT")" ".reviewer_lane" "codex"
STATUS_R5=$(echo '{}' | bash "$FIXTURE/.claude/scripts/statusline.sh" 2>/dev/null)
assert_contains "ms-R5: statusline renders reviewer lane as sol" "rev:sol" "$STATUS_R5"

# ---------------------------------------------------------------------------
# Spec R6 (roles subcommand): after an apply the `roles` output reports the
# resolved id per role from the artifact.
# ---------------------------------------------------------------------------
seed_role_map
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_OPUS_PRESENT"
bash "$MS" apply --quiet 2>/dev/null >/dev/null
ROLES_OUT=$(bash "$MS" roles 2>/dev/null)
assert_contains "ms-R6: roles reports implementer strategy+resolved id" \
    "implementer	opus-class	claude-opus-5-0" "$ROLES_OUT"
assert_contains "ms-R6: roles reports orchestrator strategy+resolved id" \
    "orchestrator	top	claude-fable-9" "$ROLES_OUT"

# ===========================================================================
# Spec T-block: capability CLASS beats recency for KNOWN families
# (v4.0.0 / claude-workflow-plugin-en9).
#
# THE DEFECT (reproduced live on 2026-07-25): pick_best sorted
# `[-(._ts), -(._ctx), ._rank]` — recency PRIMARY, ranking-file tier
# position only a tertiary tie-break for exact date+context ties. On the
# real account listing (claude-opus-5 created 2026-07-24, claude-fable-5
# created 2026-06-07) `top` therefore resolved to claude-opus-5, so the
# orchestrator + reviewer lanes were dragged onto the implementer's Opus
# lane and the v4 role split collapsed to a single model.
#
# THE CONTRACT (post-en9): `sort_by([._class, -(._ts), -(._ctx)])`.
# `_class` is the index of the first ranking-file tier prefix the id
# matches; an UNKNOWN family gets class 0 — the same class as the top
# tier — so day-zero adoption of a genuinely-new top family survives
# (it wins on recency inside class 0).
#
# ms-T1 is the regression fixture: verified RED against the pre-en9 sort
# (it returned claude-opus-5) and GREEN after. ms-TM is its META — a
# pick_best reverted to the recency-primary sort must make T1's
# expectation fail.
# ===========================================================================

# The shipped .claude/model-ranking tier order, best family first. No
# exclusions: this block is about ORDERING, not filtering (filtering has
# its own coverage in ms-H / ms-Z / ms-MX / ms-R3).
seed_tier_ranking() {
    cat > "$RANKING" <<'RANKING'
claude-fable
claude-mythos
claude-opus
claude-sonnet
claude-haiku
RANKING
}

# LISTING_TIER_VS_RECENCY — the head of the REAL listing that produced the
# defect. Every entry carries the SAME max_input_tokens, so the _ctx key
# cannot decide the winner: class and recency are the only live keys and
# they DISAGREE (opus-5 is 47 days newer than fable-5, fable is two tiers
# more capable). Pre-en9 -> claude-opus-5. Post-en9 -> claude-fable-5.
LISTING_TIER_VS_RECENCY='{
  "data": [
    {"id":"claude-opus-5","max_input_tokens":1000000,"created_at":"2026-07-24T00:00:00Z","capabilities":{}},
    {"id":"claude-sonnet-5","max_input_tokens":1000000,"created_at":"2026-06-29T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-06-07T00:00:00Z","capabilities":{}},
    {"id":"claude-opus-4-8","max_input_tokens":1000000,"created_at":"2026-05-28T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# LISTING_UNKNOWN_ABOVE_TOP — an unknown family NEWER than the top tier.
# claude-zenith-6 matches no ranking prefix -> class 0, ties with fable and
# wins on recency (day-zero adoption). claude-opus-5 is newer than BOTH and
# must still lose: class is primary for known families.
LISTING_UNKNOWN_ABOVE_TOP='{
  "data": [
    {"id":"claude-opus-5","max_input_tokens":1000000,"created_at":"2026-07-24T00:00:00Z","capabilities":{}},
    {"id":"claude-zenith-6","max_input_tokens":1000000,"created_at":"2026-07-01T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-06-07T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# LISTING_UNKNOWN_BELOW_TOP — the same unknown family, but OLDER than the
# top tier. Class 0 ties with fable; fable wins on recency.
LISTING_UNKNOWN_BELOW_TOP='{
  "data": [
    {"id":"claude-opus-5","max_input_tokens":1000000,"created_at":"2026-07-24T00:00:00Z","capabilities":{}},
    {"id":"claude-fable-5","max_input_tokens":1000000,"created_at":"2026-06-07T00:00:00Z","capabilities":{}},
    {"id":"claude-zenith-6","max_input_tokens":1000000,"created_at":"2026-05-01T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# LISTING_TOPCLASS_BOGUS_DATE — a TOP-class entry whose created_at will not
# parse, alongside a well-formed lower-class entry. Documented consequence
# of class-primary ordering: the bogus top-class id still wins its class and
# takes the MANUAL adopt path (loud, no rewrite) instead of silently
# downgrading the whole workflow to the lower tier.
LISTING_TOPCLASS_BOGUS_DATE='{
  "data": [
    {"id":"claude-fable-9","max_input_tokens":1000000,"created_at":"BOGUS-DATE","capabilities":{}},
    {"id":"claude-opus-5","max_input_tokens":1000000,"created_at":"2026-07-24T00:00:00Z","capabilities":{}}
  ],
  "has_more":false
}'

# ---------------------------------------------------------------------------
# Spec T1 (en9 REGRESSION — MUST FAIL against the recency-primary sort):
# the older, more capable family takes `top`.
# ---------------------------------------------------------------------------
seed_tier_ranking
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_TIER_VS_RECENCY"
OUT_T1=$(bash "$MS" resolve 2>&1)
ID_T1=$(ms_extract_id "$OUT_T1")
assert_eq "ms-T1 (en9 REGRESSION): capability class beats recency — fable-5 (2026-06-07) over opus-5 (2026-07-24)" \
    "claude-fable-5" "$ID_T1"

# ---------------------------------------------------------------------------
# Spec T2: the whole role split, end to end, on the real listing shape.
# orchestrator + reviewer (strategy `top`) land on the top-class fable id;
# the implementer lane (strategy `opus-class`, one class throughout) lands
# on the newest opus. This is the live outcome en9 restores.
# ---------------------------------------------------------------------------
seed_role_map
seed_tier_ranking
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_TIER_VS_RECENCY"
for agent in orchestrator qa backend frontend devops grader judge; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done
bash "$MS" apply --quiet 2>/tmp/ms-t2.err >/dev/null
RC_T2=$?
assert_eq "ms-T2: apply exit 0" "0" "$RC_T2"
for agent in orchestrator qa grader judge; do
    assert_eq "ms-T2: $agent (top lane) pinned to the top-class id" "claude-fable-5" \
        "$(grep -E '^model:' "$AGENTS_DIR/$agent.md" | head -1 | awk '{print $2}')"
done
for agent in backend frontend devops; do
    assert_eq "ms-T2: $agent (implementer lane) pinned to the newest opus" "claude-opus-5" \
        "$(grep -E '^model:' "$AGENTS_DIR/$agent.md" | head -1 | awk '{print $2}')"
done
assert_json_field "ms-T2: artifact orchestrator role is the top-class id" \
    "$(cat "$ARTIFACT")" ".roles.orchestrator" "claude-fable-5"
assert_json_field "ms-T2: artifact reviewer role is the top-class id" \
    "$(cat "$ARTIFACT")" ".roles.reviewer" "claude-fable-5"
assert_json_field "ms-T2: artifact implementer role is the newest opus" \
    "$(cat "$ARTIFACT")" ".roles.implementer" "claude-opus-5"
assert_json_field "ms-T2: implementer did NOT fall back to top" \
    "$(cat "$ARTIFACT")" ".implementer_fallback | tostring" "false"

# ---------------------------------------------------------------------------
# Spec T3: day-zero adoption survives. An unknown family newer than the top
# tier wins (class 0 tie, recency decides) — and the unknown-family warning
# still names it so the operator can place or exclude it.
# ---------------------------------------------------------------------------
seed_tier_ranking
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_UNKNOWN_ABOVE_TOP"
OUT_T3=$(bash "$MS" resolve 2>/tmp/ms-t3.err)
ID_T3=$(ms_extract_id "$OUT_T3")
assert_eq "ms-T3: unknown family newer than the top tier wins (day-zero adoption preserved)" \
    "claude-zenith-6" "$ID_T3"
WARN_T3=$(grep '^model-select:' /tmp/ms-t3.err | grep 'new family/families' | head -1)
assert_contains "ms-T3: unknown-family warning names the new family (the class-0 residual affordance)" \
    "claude-zenith" "$WARN_T3"

# ---------------------------------------------------------------------------
# Spec T4: an unknown family OLDER than the top tier loses to it — and the
# newest KNOWN lower-tier id (opus-5) still loses to both.
# ---------------------------------------------------------------------------
seed_tier_ranking
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_UNKNOWN_BELOW_TOP"
OUT_T4=$(bash "$MS" resolve 2>&1)
ID_T4=$(ms_extract_id "$OUT_T4")
assert_eq "ms-T4: unknown family older than the top tier loses to it (fable-5 wins)" \
    "claude-fable-5" "$ID_T4"

# ---------------------------------------------------------------------------
# Spec T5 (documented consequence of class-primary): a TOP-class entry with
# an unparseable created_at outranks a well-formed LOWER-class entry, so the
# resolver takes the MANUAL adopt path — loud notice, zero rewrites — rather
# than silently downgrading every lane to the lower tier.
# ---------------------------------------------------------------------------
seed_role_map
seed_tier_ranking
rm -f "$CACHE" "$ARTIFACT"
ms_set_curl_payload "$LISTING_TOPCLASS_BOGUS_DATE"
for agent in orchestrator qa backend frontend devops grader judge; do
    awk '/^model:/{print "model: claude-opus-4-7"; next} {print}' \
        "$AGENTS_DIR/$agent.md" > "$AGENTS_DIR/$agent.md.tmp" \
        && mv "$AGENTS_DIR/$agent.md.tmp" "$AGENTS_DIR/$agent.md"
done
OUT_T5=$(bash "$MS" resolve 2>/tmp/ms-t5.err)
ID_T5=$(ms_extract_id "$OUT_T5")
assert_eq "ms-T5: bogus-dated TOP-class entry still wins its class (no silent downgrade to opus-5)" \
    "claude-fable-9" "$ID_T5"
NOTICE_T5=$(grep 'manual adopt' /tmp/ms-t5.err | head -1)
assert_contains "ms-T5: LOUD manual-adopt notice carries the adopt command" \
    "/workflow-model claude-fable-9" "$NOTICE_T5"
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_TOPCLASS_BOGUS_DATE"
bash "$MS" apply --quiet 2>/tmp/ms-t5-apply.err >/dev/null
RC_T5=$?
assert_eq "ms-T5: apply exit 0 (fail-open)" "0" "$RC_T5"
T5_UNCHANGED=1
T5_DRIFT=""
for agent in orchestrator qa backend frontend devops grader judge; do
    PIN_T5=$(grep -E '^model:' "$AGENTS_DIR/$agent.md" | head -1 | awk '{print $2}')
    if [ "$PIN_T5" != "claude-opus-4-7" ]; then
        T5_UNCHANGED=0; T5_DRIFT="${T5_DRIFT:+$T5_DRIFT,}$agent=$PIN_T5"
    fi
done
assert_eq "ms-T5: every pin unchanged on the manual-adopt path (drift: '$T5_DRIFT')" \
    "1" "$T5_UNCHANGED"

# ---------------------------------------------------------------------------
# Spec TM (META-TEST for ms-T1, REQUIRED by the en9 spec): a pick_best whose
# sort reverts to recency-primary MUST make T1's expectation fail.
#
# The wrapper sources the real model-select.sh prefix (so exclusions, the
# tier load, cmd_resolve and every caller are the REAL code) and overrides
# ONLY pick_best with the pre-en9 body — the sort line
# `sort_by([-(._ts), -(._ctx), ._rank])` is written out literally here, so
# this META is TEXT-anchored and cannot drift into agreement with whatever
# the shipped resolver later does. Against LISTING_TIER_VS_RECENCY the
# reverted sort must return claude-opus-5; if it returns claude-fable-5
# then ms-T1 is passing for some reason OTHER than the sort key and is not
# a real regression guard.
#
# (The pre-en9 MANUAL\t branch is elided: every entry in this fixture has a
# well-formed created_at, so that branch is unreachable here.)
# ---------------------------------------------------------------------------
seed_tier_ranking
rm -f "$CACHE"
ms_set_curl_payload "$LISTING_TIER_VS_RECENCY"

RECENCY_LIAR="$FIXTURE/.claude/scripts/model-select-recency-liar.sh"
cat > "$RECENCY_LIAR" <<'WRAP'
#!/bin/bash
# META wrapper: real model-select.sh with a pre-en9 (recency-primary)
# pick_best swapped in. See the spec's ms-TM header for the rationale.
set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
REAL_MS="$PROJECT_DIR/.claude/scripts/model-select.sh"

awk '/^case "\$SUBCMD" in$/{exit} {print}' "$REAL_MS" \
    > "$PROJECT_DIR/.claude/scripts/.ms-recency-prefix.sh"
# shellcheck disable=SC1091
. "$PROJECT_DIR/.claude/scripts/.ms-recency-prefix.sh"

# Pre-en9 pick_best: created_at DESC primary, max_input_tokens DESC
# secondary, ranking-file position ASC tertiary (unknown families last).
pick_best() {
    local models="$1"
    local exclusions_json tiers_json
    exclusions_json=$(load_exclusions | jq -R -s -c 'split("\n") | map(select(length>0))')
    tiers_json=$(load_tiers | jq -R -s -c 'split("\n") | map(select(length>0))')
    local pick
    pick=$(jq -n -c \
        --argjson models "$models" \
        --argjson excludes "$exclusions_json" \
        --argjson tiers "$tiers_json" '
        def rank_for($id; $tiers):
            ($tiers | to_entries
             | map(. as $e | select($id | startswith($e.value + "-")))
             | (first | .key) // ($tiers | length));

        def excluded($id; $excludes):
            ($excludes | any(. as $e | $id | startswith($e + "-")));

        ($models // [])
        | map(select(excluded(.id; $excludes) | not))
        | map(. + {
            _ts: ((.created_at // "")
                  | if . == "" then -1
                    else (fromdate? // -1)
                    end),
            _ctx: (.max_input_tokens // 0),
            _rank: rank_for(.id; $tiers)
          })
        | sort_by([-(._ts), -(._ctx), ._rank])
        | (first // null)
    ' 2>/dev/null)
    if [ -z "$pick" ] || [ "$pick" = "null" ]; then
        return 1
    fi
    printf '%s' "$pick" | jq -r '.id'
}

case "${SUBCMD:-}" in
    resolve)  cmd_resolve ;;
    apply)    cmd_apply ;;
    *)        printf 'unknown subcommand\n' >&2; exit 2 ;;
esac
WRAP
chmod +x "$RECENCY_LIAR"

OUT_TM=$(bash "$RECENCY_LIAR" resolve 2>&1)
ID_TM=$(ms_extract_id "$OUT_TM")
if [ "$ID_TM" = "claude-fable-5" ]; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("ms-TM: META-TEST — recency-primary pick_best still produced claude-fable-5; ms-T1 is NOT sensitive to the sort key")
    printf '  FAIL: ms-TM: META-TEST — reverting pick_best to the recency-primary sort still yielded claude-fable-5; ms-T1 does not guard the en9 regression\n'
else
    PASS=$((PASS + 1))
    printf '  PASS: ms-TM: META-TEST — recency-primary pick_best yields %s (ms-T1 is sensitive to the class-primary sort)\n' "$ID_TM"
fi
