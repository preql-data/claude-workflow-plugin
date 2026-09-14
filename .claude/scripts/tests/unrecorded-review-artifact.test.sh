#!/bin/bash
# unrecorded-review-artifact.test.sh — the UNRECORDED-REVIEW-ARTIFACT-REFUSAL
# refusal in qa-gate.sh approve, plus its review-reconcile governance
# (claude-workflow-plugin-k6re).
#
# SPLIT OUT OF review-separation.test.sh (claude-workflow-plugin-k6re,
# 2026-09-12). That file's Sections 1-6 test the ORIGINAL REVIEW-SEPARATION
# refusal (v4.0.0 Phase V3 / jio.1: nobody signs off on their own work).
# Sections 7 through 8.14 here are the SAME task's own later work — the
# defect this task's title names ("codex-review.sh writes a review artifact
# but never records it") and the review-reconcile governance mechanism that
# grew out of fixing it, across independent review rounds 13-16. Moved to
# this file, not trimmed or rewritten, because review-separation.test.sh
# alone had grown from 955 to 2146 lines (2.2x) across those rounds and
# crossed run-tests.sh's SPEC_TIMEOUT_S=900 per-spec watchdog cap under the
# tier's own contention: QA round 16 had already measured it at 227/227
# assertions in 849s (94% of budget), and the round-16 fix-verification work
# (Sections 8.12-8.14) pushed it over — the full L1 tier killed it at 250
# assertions against the 900s cap, tree dc4a4c8d, 2026-09-10 16:25:52. Run
# standalone (no watchdog), the pre-split file completes all 264 assertions
# but takes ~1000s real time (`bash review-separation.test.sh` at the tree
# this split was made from) — genuinely over budget, not merely close to it.
# Splitting restores real margin to both halves rather than raising a cap for
# a spec that had simply outgrown it. EXPECTED_SPECS in run-tests.sh moved
# 60 -> 61 for this file, in the same change.
#
# Section numbering is PRESERVED exactly as it was in the parent file
# (starting at 7, with the pre-existing 8.9 -> 8.11 numbering gap and the
# 8.12.M suffix both intact) so the audit trail across four independent
# review rounds — R13-F1/F2/F6, R14-F1/F5, R15-F1/F2/F3, R16-F1/F2/F3/F4 —
# stays citable by the same section and finding ids QA's own review history
# already uses. This file's preamble (fixture setup, assert helpers, the
# new_task/record_artifact/record_completion family) is a byte-identical
# duplicate of review-separation.test.sh's own, not a shared library —
# matching every OTHER sibling spec in this directory, each of which is a
# fully self-contained script (confirmed: no .test.sh file in this directory
# sources a shared test-harness lib; several source the SHIPPED script under
# test instead, e.g. tree-lease.test.sh / scoped-log-dir.test.sh).
#
# THE CONTRACT UNDER TEST: an on-disk review artifact that nothing ever
# called `qa-gate.sh review-record` for is NOT the same as "no review
# artifact". `codex-review.sh` (and a human running the reviewer role by
# hand) writes docs/reviews/<tid>-r<n>.json and stops; approve must refuse
# unless EVERY such artifact, checked by CONTENT HASH never mtime, is
# accounted for as either the governing recorded round or an explicitly
# reconciled historic one. Governance itself comes from ONE authoritative
# selector (review-check.sh gate), never a re-derivation from disk files —
# three independent review rounds (R13-F1, R14-F1, R15-F1) found new ways a
# disk-derived comparison could be wrong, so it was retired rather than
# patched a fourth time.
#
# Sections (numbering continues from review-separation.test.sh's own 1-6):
#   7. UNRECORDED-REVIEW-ARTIFACT-REFUSAL (the HEADLINE defect)
#        7.1 unrecorded artifact(s) on disk           -> exit 4, review_artifact_unrecorded
#        7.2 anti-vacuity: reconciled via review-record -> approve succeeds
#        7.3 --accept-unrecorded-review '<reason>'    -> approves, records reason
#        7.4 --accept-unrecorded-review empty reason  -> exit 1, bypass_reason_required
#        7.5 litter safety: impact-report-approve_XXXXXX_* files never trigger it
#        7.7 a directory at the derived path (R13-F6) -> "not a regular file", not "unhashable"
#   7.6 META: strip UNRECORDED-REVIEW-ARTIFACT-REFUSAL from a COPY -> 7.1 WOULD fail
#   8. review-reconcile on a PQND-SHAPED backlog (R13-F1/F2)
#        8.1 the TRAP: naive review-record (even ascending) wedges the K3 selector
#        8.2 the negative control on the pqnd shape
#        8.3 the anti-vacuity leg: review-reconcile in arbitrary order, never wedges
#        8.4 review-reconcile usage/schema guards
#   8.5 META: RECONCILED-grammar recognition in recorded-hashes is load-bearing
#   8.6 THE PRINTED ADVICE, parsed from the envelope, followed literally (R14-F1)
#        8.6a-d Shape A (i8cx-shaped: unrecorded global max)
#        8.6e-k Shape B (pqnd-shaped: recorded global max) -- THE CRITICAL LEG
#   8.7 governance comes from review-check.sh gate, never from disk files (R15-F1/F2)
#        8.7.A Trigger A: governing file DELETED
#        8.7.B Trigger B: governing file UNREADABLE (chmod 000)
#        8.7.C R15-F2: a RECONCILED high iteration never governs
#        8.7.D STRUCTURAL: recorded_max_iter is gone from the shipped script
#   8.7.E META: the R15-GATE-CONSULT block is load-bearing
#   8.8 review-reconcile REFUSES an unacknowledged open finding at/above
#       its own risk_threshold (R14-F5): inclusive boundary, negative control
#   8.9 META: the R14F5-FINDINGS-GUARD sentinel block is load-bearing
#   8.11 an acknowledged finding reaches MECHANICAL readers too (R15-F3):
#        recorded-hashes.acknowledged_count/acknowledged_hashes, additive;
#        approve's own success observations mention it
#   8.12 the gate-consult survives a refusal under `set -e` (R16-F1)
#   8.12.M META: the R16-F1 `|| true` guard is load-bearing
#   8.13 an unreadable docs/reviews/ FAILS CLOSED, never a silent pass (R16-F2):
#        unreadable, traversable-not-listable, an otherwise-clean task,
#        directory ABSENT (still a pass), a dangling symlink
#   8.14 LOW/cheap wording fixes (R16-F3 filename/content iteration mismatch,
#        R16-F4 equal-iteration content drift reads ALREADY recorded not NEWER)
#   8.15 a MALFORMED-but-hashable unrecorded artifact refuses cleanly, never
#        aborts under `set -e` (R17-F1): well-formed control, valid-JSON-
#        no-.iterations control, malformed-but-hashable (the defect)
#   8.15.M META: the R17-F1 || true guard (unrecorded_content_iter) is
#        load-bearing
#
# Conventions mirror review-separation.test.sh / qa-gate-choose.test.sh /
# qa-gate-grade-record.test.sh: plain bash, `set -u`, local assert helpers,
# trailing summary, tempdir fixture with a pass-through bd shim, hard-fail
# (never skip) when bd is absent.
#
# Exit codes:
#   0  every assertion passed
#   1  at least one assertion failed
#
# Usage:
#   bash .claude/scripts/tests/unrecorded-review-artifact.test.sh
#   bash .claude/scripts/tests/unrecorded-review-artifact.test.sh --keep

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
FIXTURE=$(mktemp -d -t unrecorded-review-artifact.XXXXXX)

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

# No BD_SHIM_ONLY skip arm any more (a9hh): CI installs the real bd, and a
# bd-less environment is a hard failure everywhere — 60 assertions that
# silently skip are how "nobody signs off on their own work" went unverified
# in the only environment that runs on every push.
if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — unrecorded-review-artifact tests require Beads."
    exit 1
fi

# bd wrapper: a pass-through so the fixture has one PATH-controlled bd. It
# injected --no-daemon until bd 1.1.2 removed the flag (and the daemon: 1.1.x
# runs an in-process embedded Dolt engine, so there is no tempdir race left).
REAL_BD=$(command -v bd)
cat > "$FIXTURE/bin/bd" <<EOF
#!/bin/bash
exec ${REAL_BD} "\$@"
EOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

cd "$FIXTURE" && bd init >/dev/null 2>&1
# review-separation.test.sh's Section 4.1 asserts the approval record
# spells `worktree=none` off a git checkout, so this fixture MUST NOT be
# one. bd 1.1.2's `bd init` runs `git init` (0.47.x did not), which
# silently satisfied `git rev-parse` and made the record carry a real
# path instead — the precondition was gone, not the behaviour. Drop the
# repo bd created rather than relaxing the assertion. `--skip-agents
# --skip-hooks` suppresses the CLAUDE.md/.claude scaffolding but NOT the
# git init, so removing it here is the only way back to a bare tempdir.
# bd itself is unaffected: the store is .beads/embeddeddolt, not git.
rm -rf "$FIXTURE/.git"
export CLAUDE_PROJECT_DIR="$FIXTURE"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
RC_SCRIPT="$FIXTURE/.claude/scripts/review-check.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

labels_for() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}

# Same version-tolerant reader the production scripts use: bd 1.1.2 returns
# only a comment_count on a plain `show --json` and needs --include-comments;
# bd 0.47.x rejects that flag but inlines .comments. Pin the chain, not the leg.
bd_show_with_comments() {
    bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null \
        || true
}

comments_of() {
    bd_show_with_comments "$1" \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}

current_hash() {
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" --hash-only 2>/dev/null || echo ""
}

# record_completion <tid> <changed-file> — the F7 completion contract record
# (P7 / claude-workflow-plugin-qbhw), written through the REAL writer so a
# grammar or schema change breaks this loudly instead of leaving the spec
# asserting against a dead shape. Same reasoning as record_artifact below.
#
# P7 MIGRATION, and why the seed is here rather than a --no-completion on every
# approve call. approve now REFUSES (exit 2, completion_record_missing) unless
# the task carries a validated COMPLETION v1 record, so eleven tasks in this
# spec acquired a precondition the spec predates. Two ways to satisfy it, and
# the choice is the same one this spec's own section-3 comment makes about the
# impact bypass: satisfy the requirement LEGITIMATELY rather than stack a second
# bypass on the case under test. A `--no-completion` on every call would mean
# this spec never drives approve's normal path at all — so a completion refusal
# that regressed to always-firing would leave every leg here green.
#
# `files_changed` names the file new_task staged, so approve's completeness
# cross-check (fkm.1.20) PASSES rather than emitting a WARNING about a delta
# that is an artifact of the fixture.
record_completion() {
    local tid="$1" file="$2" pay
    pay="$TRACK/completion-draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    cat > "$pay" <<JSON
{"task_id":"$tid","role":"backend","model":"seeded","pin":"seeded","files_changed":["$file"],"tests_added":["unrecorded-review-artifact.test.sh::seeded"],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the unrecorded-review-artifact fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown","unit_id":"","design_hash":"","green_before":"none","green_after":"none"}
JSON
    bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
}

# new_task <title> <changed-file> — create a task, stage a change-set for it,
# and enter the gate (which generates the impact report so the EARLIER
# impact-freshness refusal never masks the review refusal under test). Also
# records the F7 completion contract, so the LATER completion refusal does not
# mask it either — this spec's subject is review separation, and every other
# precondition has to be satisfied for that subject to be observable.
new_task() {
    local title="$1" file="$2" tid
    tid=$(bd create "$title" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    printf '%s\n' "$file" > "$TRACK/changed-files.txt"
    bash "$QG" enter "$tid" >/dev/null 2>&1
    record_completion "$tid" "$file"
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
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"test-model","reviewer_pin":"test-model","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"$verdict","findings":$findings,"iterations":1,"stopped_by":"verdict"}
JSON
    # claude-workflow-plugin-rqer (v5 D2): --file now asserts the CANONICAL
    # derived path; piped via stdin instead.
    bash "$QG" review-record "$tid" < "$art" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: UNRECORDED-REVIEW-ARTIFACT-REFUSAL (claude-workflow-plugin-k6re, the HEADLINE defect) ==="
# THE DEFECT. codex-review.sh writes docs/reviews/<tid>-r<n>.json and exits;
# nothing calls qa-gate.sh review-record for it unless an agent remembers to.
# review-separation.test.sh's Sections 1-6 prove review-separation holds
# for the record that DOES get recorded; this section proves approve
# additionally refuses when a review artifact sits on disk for this task
# with NO corresponding record — by CONTENT HASH, never mtime — the
# "artifact exists but was never recorded" state the task description
# calls "currently silent".
#
# art_path_for <tid> <iteration> — mirrors qa-gate.sh's review_artifact_path_for
# byte for byte (same sanitisation, same format string), so this section
# plants bytes at the EXACT path the real driver/writer would use, not an
# approximation of it.
art_path_for() {
    local sanitized iter_sanitized
    sanitized=$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')
    iter_sanitized=$(printf '%s' "$2" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s/docs/reviews/%s-r%s.json' "$FIXTURE" "$sanitized" "$iter_sanitized"
}

# plant_unrecorded <tid> <iteration> — writes a well-formed, VALID review
# artifact DIRECTLY to the canonical path, bypassing review-record entirely —
# exactly codex-review.sh's own current (bugged) behaviour: the bytes are
# real and would pass validate-artifact, but nothing ever posted a
# REVIEW-ARTIFACT v1 record binding them.
plant_unrecorded() {
    local tid="$1" iter="$2" path
    path=$(art_path_for "$tid" "$iter")
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"sol-codex","reviewer_model":"gpt-5.6-sol","reviewer_pin":"gpt-5.6-sol","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"x","verdict":"approve","findings":[],"iterations":$iter,"stopped_by":"verdict"}
JSON
}

# plant_unrecorded_findings <tid> <iteration> <risk_threshold> <findings-json>
# — like plant_unrecorded, but with a caller-supplied risk_threshold and
# findings[] instead of the hardcoded clean "approve, no findings" shape.
# Needed for Section 8.8 (claude-workflow-plugin-k6re R14-F5): review-
# reconcile's findings-acknowledgment guard only has something to refuse
# when the planted artifact actually carries an open finding, which
# plant_unrecorded can never produce.
plant_unrecorded_findings() {
    local tid="$1" iter="$2" threshold="$3" findings="$4" verdict="approve" path
    [ "$findings" != "[]" ] && verdict="findings"
    path=$(art_path_for "$tid" "$iter")
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"sol-codex","reviewer_model":"gpt-5.6-sol","reviewer_pin":"gpt-5.6-sol","reviewed_hash":"$(current_hash)","risk_threshold":"$threshold","stop_condition":"x","verdict":"$verdict","findings":$findings,"iterations":$iter,"stopped_by":"verdict"}
JSON
}

# 7.1 THE NEGATIVE CONTROL. iteration=1 is recorded through the REAL writer
# (review-separation passes); iterations 2 AND 3 are planted UNRECORDED —
# proving the refusal walks every on-disk artifact, not just the first it
# finds, and that the "N of M" count in the refusal is accurate.
TID_UNREC=$(new_task "review-sep: unrecorded artifact (k6re headline)" "src/fifteen.ts")
record_implementer "$TID_UNREC" "backend"
record_artifact "$TID_UNREC" "qa-claude" "[]"
plant_unrecorded "$TID_UNREC" 2
plant_unrecorded "$TID_UNREC" 3
RC=0
OUT=$(bash "$QG" approve "$TID_UNREC" --no-design "k6re: testing unrecorded-artifact refusal, not design-satisfied" "shipping over two unrecorded rounds" 2>/dev/null) || RC=$?
assert_eq "7.1a unrecorded artifact: exit 4" "4" "$RC"
assert_eq "7.1b ...error_key=review_artifact_unrecorded" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "7.1c ...refusal names BOTH unrecorded files" \
    "$(art_path_for "$TID_UNREC" 2)" "$OUT"
assert_contains "7.1d ...and the second" \
    "$(art_path_for "$TID_UNREC" 3)" "$OUT"
assert_contains "7.1e ...refusal states '2 of 3' (counts every on-disk artifact, not just one)" \
    "2 of 3 review artifact(s)" "$OUT"
assert_contains "7.1f ...refusal states the check is by CONTENT HASH, never mtime" \
    "CONTENT HASH" "$OUT"
assert_contains "7.1g ...remediation names review-record" \
    "qa-gate.sh review-record" "$OUT"
assert_contains "7.1h ...remediation names the audited bypass" \
    "--accept-unrecorded-review" "$OUT"
# A refused approve is a no-op on labels — same discipline as 1.4.
LBL_UNREC=$(labels_for "$TID_UNREC")
assert_not_contains "7.1i refusal leaves qa-approved unset" "qa-approved" "$LBL_UNREC"
assert_contains "7.1j refusal preserves qa-gate-entered" "qa-gate-entered" "$LBL_UNREC"

# 7.2 THE ANTI-VACUITY LEG (the task description's own explicit pairing
# requirement): reconcile BOTH stray artifacts through the REAL review-record
# writer, then approve on the SAME task SUCCEEDS. Proves 7.1 refused because
# the artifacts were genuinely unrecorded, not because this build refuses
# unconditionally whenever more than one artifact exists on disk.
bash "$QG" review-record "$TID_UNREC" --file "$(art_path_for "$TID_UNREC" 2)" >/dev/null 2>&1
bash "$QG" review-record "$TID_UNREC" --file "$(art_path_for "$TID_UNREC" 3)" >/dev/null 2>&1
RC=0
OUT=$(bash "$QG" approve "$TID_UNREC" --no-design "k6re: testing unrecorded-artifact refusal, not design-satisfied" "reconciled, now approves" 2>/dev/null) || RC=$?
assert_eq "7.2a anti-vacuity: after reconciling both rounds, approve succeeds (exit 0)" "0" "$RC"
assert_eq "7.2b ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
assert_contains "7.2c ...observations report the check PASSED for all three on-disk artifacts" \
    "unrecorded-artifact check PASSED" "$OUT"

# 7.3 THE AUDITED BYPASS. A fresh task with one recorded round and one
# unrecorded round; --accept-unrecorded-review with a reason approves
# despite the unrecorded artifact, and the reason is durably recorded.
TID_BYP_UNREC=$(new_task "review-sep: unrecorded-artifact audited bypass" "src/sixteen.ts")
record_implementer "$TID_BYP_UNREC" "backend"
record_artifact "$TID_BYP_UNREC" "qa-claude" "[]"
plant_unrecorded "$TID_BYP_UNREC" 9
RC=0
OUT=$(bash "$QG" approve "$TID_BYP_UNREC" \
    --accept-unrecorded-review "historic backlog, reviewed out of band" \
    --no-design "k6re: testing the unrecorded-artifact bypass, not design-satisfied" \
    "bypassed" 2>/dev/null) || RC=$?
assert_eq "7.3a bypass: approve succeeds (exit 0)" "0" "$RC"
assert_eq "7.3b bypass: status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
assert_contains "7.3c bypass: reason recorded in gate JSON observations" \
    "historic backlog, reviewed out of band" "$OUT"
assert_contains "7.3d bypass: observations flag it as an unrecorded-artifact bypass" \
    "unrecorded-artifact bypass" "$OUT"
BYP_UNREC_CMT=$(comments_of "$TID_BYP_UNREC" | grep 'QA-GATE APPROVED' | tail -1)
assert_contains "7.3e bypass: approval comment carries the [unrecorded review artifact accepted:] marker" \
    "[unrecorded review artifact accepted: historic backlog, reviewed out of band]" "$BYP_UNREC_CMT"

# 7.4 An unexplained bypass is refused — same contract as --no-review /
# --no-impact-report / --accept-reconstructed.
TID_BYP_UNREC2=$(new_task "review-sep: unrecorded-artifact empty bypass reason" "src/seventeen.ts")
RC=0
OUT=$(bash "$QG" approve "$TID_BYP_UNREC2" --accept-unrecorded-review 2>/dev/null) || RC=$?
assert_eq "7.4a empty bypass reason: exit 1" "1" "$RC"
assert_eq "7.4b ...error_key=bypass_reason_required" \
    "bypass_reason_required" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_not_contains "7.4c empty bypass reason: no qa-approved label" \
    "qa-approved" "$(labels_for "$TID_BYP_UNREC2")"

# 7.5 LITTER SAFETY. docs/reviews/ also holds impact-report-approve_XXXXXX_*
# files that are NOT review artifacts (a DIFFERENT generator, impact-report.sh
# via approve itself). One is planted here EMBEDDING this task's own id as a
# substring, immediately followed by a non-"-r<n>.json" suffix — the exact
# adversarial-looking shape the real litter has — and approve must still
# succeed: the glob is anchored on the sanitised task id followed by a
# LITERAL "-r", which this litter shape never matches.
TID_LITTER=$(new_task "review-sep: litter files do not trigger the refusal" "src/eighteen.ts")
record_implementer "$TID_LITTER" "backend"
record_artifact "$TID_LITTER" "qa-claude" "[]"
mkdir -p "$FIXTURE/docs/reviews"
echo '{"not":"a review artifact"}' > "$FIXTURE/docs/reviews/impact-report-approve_XXXXXX_${TID_LITTER}-zzz-r1.json"
echo '{"not":"a review artifact either"}' > "$FIXTURE/docs/reviews/impact-report-approve_XXXXXX_unrelated-r1.json"
RC=0
OUT=$(bash "$QG" approve "$TID_LITTER" --no-design "k6re: testing litter-file safety, not design-satisfied" "litter must not interfere" 2>/dev/null) || RC=$?
assert_eq "7.5a litter safety: approve succeeds despite adjacent impact-report-approve_XXXXXX_* files (exit 0)" \
    "0" "$RC"
assert_eq "7.5b ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status')"

# 7.7 (claude-workflow-plugin-k6re R13-F6): a DIRECTORY at the derived
# on-disk path is admitted by [ -e ] but must be named "not a regular file",
# not the generic "unhashable" wording the hash-tool failure case uses — the
# true cause is closer at hand than a hashing failure, and the
# codex-review.sh spec's own C10 leg already treats this as a distinct
# condition, so the vocabulary exists. Placed here (its own fresh task,
# after every OTHER Section 7 leg that shares TID_UNREC's tracker state)
# deliberately — new_task's changed-files.txt write would otherwise stale
# out the impact report of whichever earlier leg's task still needed it.
TID_DIRSHAPE=$(new_task "review-sep: directory-shaped unrecorded path (R13-F6)" "src/dirshape.ts")
record_implementer "$TID_DIRSHAPE" "backend"
record_artifact "$TID_DIRSHAPE" "qa-claude" "[]"
mkdir -p "$(art_path_for "$TID_DIRSHAPE" 2)"
RC=0
OUT=$(bash "$QG" approve "$TID_DIRSHAPE" --no-design "k6re R13-F6: directory-shaped path wording" "should refuse, naming the true cause" 2>/dev/null) || RC=$?
assert_eq "7.7a directory-shaped unrecorded path: exit 4" "4" "$RC"
assert_contains "7.7b ...names 'not a regular file', not the generic 'unhashable'" \
    "not a regular file" "$OUT"
assert_not_contains "7.7c ...does NOT claim the hash tool failed for a directory it was never asked to hash" \
    "unhashable, rc=" "$OUT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7.6: META — the UNRECORDED-REVIEW-ARTIFACT-REFUSAL block is load-bearing ==="

# Strip everything between the sentinels from a COPY. If the refusal really is
# what enforces the contract, the stripped copy approves 7.1's EXACT scenario
# (one recorded round, two unrecorded ones) — i.e. every 7.1 assertion would
# FAIL against it. Same directory placement rationale as QG_NOTOKEN /
# QG_STRIPPED above (94d: qa-gate.sh resolves workflow-denylist.sh from its
# own directory).
QG_STRIPPED_UNREC="$FIXTURE/.claude/scripts/qa-gate-nounrecorded.sh"
STRIP_UNREC_RC=0
awk '
    /# UNRECORDED-REVIEW-ARTIFACT-REFUSAL BEGIN/ { skipping=1; found=1; next }
    /# UNRECORDED-REVIEW-ARTIFACT-REFUSAL END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_STRIPPED_UNREC" || STRIP_UNREC_RC=$?
chmod +x "$QG_STRIPPED_UNREC"
assert_eq "7.6a META: UNRECORDED-REVIEW-ARTIFACT-REFUSAL sentinels present in qa-gate.sh" "0" "$STRIP_UNREC_RC"

if [ "$STRIP_UNREC_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$QG_STRIPPED_UNREC" 2>/dev/null || PARSE_RC=$?
    assert_eq "7.6b META: stripped copy still parses (unrecorded_review_obs defaults empty outside the block)" \
        "0" "$PARSE_RC"

    TID_META_UNREC=$(new_task "review-sep: unrecorded-artifact META strip" "src/nineteen.ts")
    record_implementer "$TID_META_UNREC" "backend"
    record_artifact "$TID_META_UNREC" "qa-claude" "[]"
    plant_unrecorded "$TID_META_UNREC" 2
    plant_unrecorded "$TID_META_UNREC" 3
    RC=0
    OUT=$(bash "$QG_STRIPPED_UNREC" approve "$TID_META_UNREC" --no-design "k6re META: testing UNRECORDED-REVIEW-ARTIFACT-REFUSAL, not design-satisfied" "stripped copy must NOT refuse" 2>/dev/null) || RC=$?
    assert_eq "7.6c META: WITHOUT the block, approve succeeds despite two unrecorded artifacts (7.1 WOULD fail)" \
        "0" "$RC"
    assert_eq "7.6d META: stripped copy status=approved" \
        "approved" "$(printf '%s' "$OUT" | jq -r '.status')"

    # Discriminator: the mutant still enforces REVIEW-SEPARATION itself (a
    # DIFFERENT, untouched block) — proving only the unrecorded-artifact
    # guard was removed, not review checking as a whole.
    TID_META_UNREC_DISCRIM=$(new_task "review-sep: unrecorded-artifact META discriminator (no artifact at all)" "src/twenty.ts")
    record_implementer "$TID_META_UNREC_DISCRIM" "backend"
    RC=0
    OUT=$(bash "$QG_STRIPPED_UNREC" approve "$TID_META_UNREC_DISCRIM" "no artifact at all — REVIEW-SEPARATION must still refuse" 2>/dev/null) || RC=$?
    assert_eq "7.6e discriminator: the mutant still refuses on a task with NO review artifact at all (exit 4, review-separation untouched)" \
        "4" "$RC"
    assert_eq "7.6f discriminator: ...error_key=review_artifact_missing (the OTHER block, not this one)" \
        "review_artifact_missing" "$(printf '%s' "$OUT" | jq -r '.error_key')"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("7.6 META: sentinels missing — strip meta-test skipped")
    printf '  FAIL: 7.6 META: sentinels missing — strip meta-test skipped\n'
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: review-reconcile on a PQND-SHAPED backlog (claude-workflow-plugin-k6re R13-F1/F2) ==="
# QA ROUND 13's OWN WARNING, taken seriously: "A control built on i8cx or
# k6re alone would pass under the insufficient fix and prove nothing." Both
# of those shapes have their HIGHEST iteration among the UNRECORDED set, so
# simply backfilling in ascending numeric order happens to avoid the K3
# selector disagreement — not because ordering is a real fix, but because
# that shape cannot expose the defect. A pqnd-shaped backlog is the opposite:
# the highest iteration is ALREADY recorded (governing), and a LOWER,
# unrecorded set needs reconciling — no order of writing that lower set
# through review-record can ever make one of them simultaneously
# max(iteration), so ascending order does not help here at all. This section
# is built on exactly that shape.

# record_artifact_at_iter <tid> <reviewer> <iteration> <findings-json> — like
# record_artifact above but at an ARBITRARY iteration (record_artifact
# hardcodes iterations=1), for building a multi-round backlog. Real writer,
# same discipline as record_artifact.
record_artifact_at_iter() {
    local tid="$1" reviewer="$2" iter="$3" findings="$4" verdict="approve"
    [ "$findings" != "[]" ] && verdict="findings"
    local art
    art=$(art_path_for "$tid" "$iter")
    mkdir -p "$(dirname "$art")"
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"$reviewer","reviewer_model":"test-model","reviewer_pin":"test-model","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"$verdict","findings":$findings,"iterations":$iter,"stopped_by":"verdict"}
JSON
    bash "$QG" review-record "$tid" --file "$art" >/dev/null 2>&1
}

# 8.1 THE TRAP, reproduced as a regression baseline (not this fix — this is
# cmd_gate's PRE-EXISTING K3 selector, unchanged by this round): on a
# pqnd-shaped backlog (iterations 5-9 recorded, governing iteration=9;
# iterations 1-4 unrecorded), reconciling the unrecorded set through the
# NAIVE approach — raw review-record, even in ASCENDING order, the ordering
# rule that looks like a fix on i8cx/k6re-shaped backlogs — still wedges the
# selector. Proves the trap is real before proving the cure works.
TID_TRAP=$(new_task "review-sep: pqnd-shaped trap (naive review-record wedges it)" "src/trap.ts")
record_implementer "$TID_TRAP" "backend"
for i in 5 6 7 8 9; do record_artifact_at_iter "$TID_TRAP" "sol-codex" "$i" "[]"; done
plant_unrecorded "$TID_TRAP" 1
plant_unrecorded "$TID_TRAP" 2
plant_unrecorded "$TID_TRAP" 3
plant_unrecorded "$TID_TRAP" 4
GATE_PRE=$(bash "$RC_SCRIPT" gate "$TID_TRAP" 2>/dev/null)
assert_eq "8.1a pre-backfill control: gate already has a clean single winner (iteration=9)" \
    "9" "$(printf '%s' "$GATE_PRE" | jq -r '.artifact.iteration')"
for i in 1 2 3 4; do
    bash "$QG" review-record "$TID_TRAP" --file "$(art_path_for "$TID_TRAP" "$i")" >/dev/null 2>&1
done
GATE_TRAP=$(bash "$RC_SCRIPT" gate "$TID_TRAP" 2>/dev/null)
assert_eq "8.1b THE TRAP: naive review-record on the lower set, even ascending, WEDGES the selector" \
    "review_artifact_selection_disagreement" "$(printf '%s' "$GATE_TRAP" | jq -r '.error_key')"
RC=0
OUT=$(bash "$QG" approve "$TID_TRAP" --no-design "k6re: reproducing the trap" "should be wedged" 2>/dev/null) || RC=$?
assert_eq "8.1c ...approve also refuses (exit 4)" "4" "$RC"
assert_contains "8.1d ...the improved remedy names review-reconcile as the going-forward fix" \
    "review-reconcile" "$OUT"
assert_contains "8.1e ...the improved remedy names re-recording the highest iteration as the repair" \
    "HIGHEST iteration number" "$OUT"

# 8.2 THE NEGATIVE CONTROL, on a FRESH pqnd-shaped task (TID_TRAP above is
# now permanently wedged by design, matching what a real operator following
# the OLD advice would have done): approve refuses while the lower set is
# unrecorded — the ordinary review_artifact_unrecorded detection, proven
# here specifically on a shape where the highest iteration is ALREADY
# recorded, which QA's own round named as the shape a k6re/i8cx-only control
# cannot prove anything about.
TID_PQND=$(new_task "review-sep: pqnd-shaped negative control + anti-vacuity" "src/pqnd.ts")
record_implementer "$TID_PQND" "backend"
for i in 5 6 7 8 9; do record_artifact_at_iter "$TID_PQND" "sol-codex" "$i" "[]"; done
plant_unrecorded "$TID_PQND" 1
plant_unrecorded "$TID_PQND" 2
plant_unrecorded "$TID_PQND" 3
plant_unrecorded "$TID_PQND" 4
RC=0
OUT=$(bash "$QG" approve "$TID_PQND" --no-design "k6re: pqnd-shaped negative control" "should refuse, 4 unrecorded" 2>/dev/null) || RC=$?
assert_eq "8.2a NEGATIVE CONTROL (pqnd-shaped): approve refuses (exit 4)" "4" "$RC"
assert_eq "8.2b ...error_key=review_artifact_unrecorded" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "8.2c ...states 4 of 9" "4 of 9 review artifact(s)" "$OUT"

# 8.3 THE ANTI-VACUITY LEG: reconcile the SAME 4 files via review-reconcile,
# in a NON-ascending, arbitrary order (3, 1, 4, 2) — proving order no longer
# matters at all, unlike the trap above. The governing record (iteration=9)
# must stay untouched throughout.
RC=0
for i in 3 1 4 2; do
    OUT=$(bash "$QG" review-reconcile "$TID_PQND" --file "$(art_path_for "$TID_PQND" "$i")" \
        "historic Sol round, backfilled after the fact; iteration 9 governs" 2>/dev/null) || RC=1
    assert_eq "8.3 review-reconcile r$i: ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok' 2>/dev/null)"
done
GATE_PQND_POST=$(bash "$RC_SCRIPT" gate "$TID_PQND" 2>/dev/null)
assert_eq "8.3f the governing record is UNTOUCHED after reconciliation (still iteration=9)" \
    "9" "$(printf '%s' "$GATE_PQND_POST" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_PQND" --no-design "k6re: pqnd-shaped anti-vacuity" "reconciled out of order, must approve" 2>/dev/null) || RC=$?
assert_eq "8.3g ANTI-VACUITY: after reconciling all 4 via review-reconcile (arbitrary order), approve succeeds (exit 0)" \
    "0" "$RC"
assert_eq "8.3h ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
RECONCILED_COMMENTS=$(comments_of "$TID_PQND" | grep -c '^REVIEW-ARTIFACT-RECONCILED v1 ' || true)
assert_eq "8.3i all 4 RECONCILED records are durable comments on the task" "4" "$RECONCILED_COMMENTS"

# 8.4 review-reconcile itself: usage/schema guards distinct from review-record
# (no stdin mode; reason is required).
TID_RECTOOL=$(bd create "review-sep: review-reconcile usage guards" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
# changed-files.txt must be non-empty BEFORE plant_unrecorded computes
# current_hash — otherwise reviewed_hash lands on the SHA-256 empty-content
# degradation sentinel, which validate-artifact refuses unconditionally
# (reviewed_hash_unusable) regardless of what review-reconcile itself does.
# Every OTHER task in this section goes through new_task, which sets this
# first; TID_RECTOOL does not need new_task's enter/completion-record
# machinery, only this one line of what it does.
printf 'src/rectool.ts\n' > "$TRACK/changed-files.txt"
plant_unrecorded "$TID_RECTOOL" 1
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_RECTOOL" 2>/dev/null) || RC=$?
assert_eq "8.4a missing --file: exit 1" "1" "$RC"
assert_eq "8.4b ...error_key=missing_file_path" "missing_file_path" "$(printf '%s' "$OUT" | jq -r '.error_key')"
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_RECTOOL" --file "$(art_path_for "$TID_RECTOOL" 1)" 2>/dev/null) || RC=$?
assert_eq "8.4c missing reason: exit 1" "1" "$RC"
assert_eq "8.4d ...error_key=bypass_reason_required" "bypass_reason_required" "$(printf '%s' "$OUT" | jq -r '.error_key')"
RC=0
OUT=$(printf '' | bash "$QG" review-reconcile "$TID_RECTOOL" --file "$(art_path_for "$TID_RECTOOL" 1)" "no stdin mode should exist" 2>/dev/null) || RC=$?
assert_eq "8.4e review-reconcile succeeds with --file + reason (no stdin needed even when stdin is empty/piped)" "0" "$RC"
RECTOOL_CMT=$(comments_of "$TID_RECTOOL" | grep '^REVIEW-ARTIFACT-RECONCILED v1 ' | tail -1)
assert_match "8.4f the durable comment matches the documented grammar exactly" \
    "^REVIEW-ARTIFACT-RECONCILED v1 iteration=1 artifact_hash=[0-9a-f]{64} at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: no stdin mode should exist$" \
    "$RECTOOL_CMT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.5: META — RECONCILED-grammar recognition in recorded-hashes is load-bearing ==="
# Strip the RECONCILED-GRAMMAR sentinel region from a COPY of review-check.sh
# and swap it IN PLACE at the fixture's canonical script path, then restore —
# the same technique review-separation.test.sh's Section 5 (FAIL CLOSED)
# already uses to perturb review-check.sh. A SIBLING-DIRECTORY copy of
# qa-gate.sh (QG_STRIPPED's own pattern, used everywhere else in this file
# for qa-gate.sh mutants) does NOT
# work for a review-check.sh mutation: REVIEW_CHECK_SCRIPT is derived from
# $PROJECT_DIR (a fixed env var for this whole run), never from qa-gate.sh's
# OWN directory, so a copy of qa-gate.sh sitting next to a mutant
# review-check.sh still resolves and calls the REAL one at
# $PROJECT_DIR/.claude/scripts/review-check.sh — measured directly (a first
# draft of this section used the sibling-copy pattern and the mutant had
# ZERO effect, exit 0 where 8.5c below expects exit 4, for exactly this
# reason) — so the swap has to be at the resolved path itself.
RCHECK_REAL="$FIXTURE/.claude/scripts/review-check.sh"
RCHECK_MUTANT_STAGED="$(mktemp -t review-check-rconciled-strip.XXXXXX)"
STRIP_RECON_RC=0
awk '
    /# RECONCILED-GRAMMAR BEGIN/ { skipping=1; found=1; next }
    /# RECONCILED-GRAMMAR END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$RCHECK_REAL" > "$RCHECK_MUTANT_STAGED" || STRIP_RECON_RC=$?
assert_eq "8.5a META: RECONCILED-GRAMMAR sentinels present in review-check.sh" "0" "$STRIP_RECON_RC"

if [ "$STRIP_RECON_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$RCHECK_MUTANT_STAGED" 2>/dev/null || PARSE_RC=$?
    assert_eq "8.5b META: stripped review-check.sh copy still parses" "0" "$PARSE_RC"

    # TID_PQND's impact report was generated back in 8.2; Section 8.4's
    # TID_RECTOOL work overwrote changed-files.txt since, so a re-approve
    # here would hit impact_report_stale before ever reaching the review
    # checks this section actually tests. Re-stage and regenerate, same
    # discipline review-separation.test.sh's Section 2.1 already uses
    # after a resolve-finding round changes what changed-files.txt holds
    # — but with an ADDITIONAL file
    # (not merely a repeat of src/pqnd.ts alone), deliberately: TID_PQND was
    # already approved in 8.3g at the change_set_hash for {src/pqnd.ts}
    # alone, and cmd_approve's hash-aware idempotency (gz3/v4.1 U1) no-ops
    # WITHOUT re-verifying any precondition when a re-approve binds a change
    # set an existing record already covers — measured directly: the first
    # draft of this leg re-staged the identical single file and the mutant
    # swap below had no effect for exactly this reason (exit 0, not the
    # expected 4, because approve never reached the review checks at all).
    # A genuinely different change set forces the real re-verification path.
    printf 'src/pqnd.ts\nsrc/pqnd-recheck.ts\n' > "$TRACK/changed-files.txt"
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" "$TID_PQND" >/dev/null 2>&1 || true

    # Swap the mutant IN at the resolved path, run both legs, then restore —
    # unconditionally, before anything else in this file could run against a
    # tree missing RECONCILED recognition.
    mv "$RCHECK_REAL" "$RCHECK_REAL.real"
    cp "$RCHECK_MUTANT_STAGED" "$RCHECK_REAL"
    chmod +x "$RCHECK_REAL"

    RC=0
    OUT=$(bash "$QG" approve "$TID_PQND" --no-design "k6re META: RECONCILED-GRAMMAR strip" "must refuse again without recognition" 2>/dev/null) || RC=$?

    # Discriminator: the mutant still correctly approves an ORDINARY task
    # with no reconciled records involved at all — proving the loss is
    # scoped to RECONCILED recognition, not a broken review-check.sh.
    TID_RCHECK_DISCRIM=$(new_task "review-sep: RECONCILED-GRAMMAR META discriminator (ordinary task)" "src/discrim.ts")
    record_implementer "$TID_RCHECK_DISCRIM" "backend"
    record_artifact "$TID_RCHECK_DISCRIM" "qa-claude" "[]"
    RC2=0
    OUT2=$(bash "$QG" approve "$TID_RCHECK_DISCRIM" --no-design "k6re META discriminator" "ordinary task, unaffected" 2>/dev/null) || RC2=$?

    mv "$RCHECK_REAL.real" "$RCHECK_REAL"
    rm -f "$RCHECK_MUTANT_STAGED" 2>/dev/null || true

    assert_eq "8.5c META: WITHOUT RECONCILED recognition, the SAME already-reconciled task refuses again (exit 4) — 8.3g WOULD fail" \
        "4" "$RC"
    assert_eq "8.5d META: ...error_key=review_artifact_unrecorded (recorded-hashes no longer sees the 4 reconciled files)" \
        "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key')"
    assert_eq "8.5e discriminator: the mutant still approves an ordinary task with no RECONCILED records at all (exit 0)" \
        "0" "$RC2"
    assert_eq "8.5f ...status=approved" "approved" "$(printf '%s' "$OUT2" | jq -r '.status' 2>/dev/null)"
else
    rm -f "$RCHECK_MUTANT_STAGED" 2>/dev/null || true
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("8.5 META: RECONCILED-GRAMMAR sentinels missing — strip meta-test skipped")
    printf '  FAIL: 8.5 META: RECONCILED-GRAMMAR sentinels missing — strip meta-test skipped\n'
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.6: THE PRINTED ADVICE, PARSED FROM THE ENVELOPE, FOLLOWED LITERALLY (claude-workflow-plugin-k6re R14-F1) ==="
# R13-F1's own control asked for this in these exact words: "reconcile a
# pqnd-shaped backlog ... in the order the SHIPPED refusal prints, assert
# approve reaches 0." Section 8.3 satisfied that by performing the CORRECT
# procedure by hand, which is a DIFFERENT claim: R14-F1 measured that the
# printed advice itself was wrong on a pqnd-shaped backlog (recommending
# review-record on the unrecorded maximum when the TRUE governing round was
# ALREADY recorded), and a control that drives the correct procedure cannot
# detect that the PRINTED one is wrong. This section parses the advice OUT
# OF the refusal envelope and drives the fixture through THAT — never
# re-deriving what the advice ought to say — for both backlog shapes.

# parse_unrecorded_files <observations> -> one file path per line, from the
# "checked by CONTENT HASH" list the refusal prints.
parse_unrecorded_files() {
    printf '%s' "$1" \
        | sed -n 's/.*CONTENT HASH (never mtime): \(.*\)\. The gate would otherwise.*/\1/p' \
        | tr ';' '\n' \
        | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | sed -E 's/ \([^()]*\)$//' \
        | grep -v '^$'
}
# parse_record_file <observations> -> the ONE file the advice names for
# review-record, or empty if the advice says to record none of them. Safe
# against the review-reconcile / no-file-identified lines, which always use
# the literal placeholder "<path>" (no .json suffix) rather than a real one.
parse_record_file() {
    printf '%s' "$1" | grep -oE -- '--file [^ ]+\.json' | head -1 | sed 's/^--file //'
}
# follow_the_advice <tid> <observations> <reconcile-reason> — drives the REAL
# review-record / review-reconcile commands, exactly as parsed. Sets
# FOLLOW_RC to the last non-zero exit encountered, or 0.
FOLLOW_RC=0
follow_the_advice() {
    local tid="$1" obs="$2" reason="$3" record_file f
    FOLLOW_RC=0
    record_file=$(parse_record_file "$obs")
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if [ -n "$record_file" ] && [ "$f" = "$record_file" ]; then
            bash "$QG" review-record "$tid" --file "$f" >/dev/null 2>&1 || FOLLOW_RC=$?
        else
            bash "$QG" review-reconcile "$tid" --file "$f" "$reason" >/dev/null 2>&1 || FOLLOW_RC=$?
        fi
    done < <(parse_unrecorded_files "$obs")
}

# 8.6a-d SHAPE A (i8cx-shaped: global max r4 is itself unrecorded) — the
# advice names r4 for review-record; following it literally must succeed.
TID_ADVA=$(new_task "review-sep: R14-F1 advice-following, Shape A (i8cx-shaped)" "src/advA.ts")
record_implementer "$TID_ADVA" "backend"
record_artifact_at_iter "$TID_ADVA" "sol-codex" 1 "[]"
plant_unrecorded "$TID_ADVA" 2
plant_unrecorded "$TID_ADVA" 3
plant_unrecorded "$TID_ADVA" 4
RC=0
OUT=$(bash "$QG" approve "$TID_ADVA" --no-design "k6re R14-F1: shape A advice-following" "should refuse" 2>/dev/null) || RC=$?
assert_eq "8.6a shape A: initial refusal (exit 4)" "4" "$RC"
OBS_A=$(printf '%s' "$OUT" | jq -r '.observations')
follow_the_advice "$TID_ADVA" "$OBS_A" "k6re R14-F1: historic round, per the PRINTED advice"
assert_eq "8.6b shape A: every parsed command succeeded" "0" "$FOLLOW_RC"
GATE_A=$(bash "$RC_SCRIPT" gate "$TID_ADVA" 2>/dev/null)
assert_eq "8.6c shape A: gate still resolves after following the PRINTED advice (iteration=4)" \
    "4" "$(printf '%s' "$GATE_A" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_ADVA" --no-design "k6re R14-F1: shape A advice-following" "should now succeed" 2>/dev/null) || RC=$?
assert_eq "8.6d shape A: approve succeeds after following the PRINTED advice literally (exit 0)" "0" "$RC"

# 8.6e-k SHAPE B (pqnd-shaped: global max r9 is ALREADY recorded) — THE
# CRITICAL LEG R13-F1 asked for and R14-F1 found missing. Pre-fix, the
# advice named the unrecorded max (r4) for review-record, and following
# THAT verbatim wedged a selector that worked before any remedy was
# attempted. Post-fix, the advice must say to reconcile everything and
# record nothing.
TID_ADVB=$(new_task "review-sep: R14-F1 advice-following, Shape B (pqnd-shaped, CRITICAL LEG)" "src/advB.ts")
record_implementer "$TID_ADVB" "backend"
for i in 5 6 7 8 9; do record_artifact_at_iter "$TID_ADVB" "sol-codex" "$i" "[]"; done
plant_unrecorded "$TID_ADVB" 1
plant_unrecorded "$TID_ADVB" 2
plant_unrecorded "$TID_ADVB" 3
plant_unrecorded "$TID_ADVB" 4
GATE_B_PRE=$(bash "$RC_SCRIPT" gate "$TID_ADVB" 2>/dev/null)
assert_eq "8.6e pre-condition: gate already has a WORKING selector before any remedy (iteration=9)" \
    "9" "$(printf '%s' "$GATE_B_PRE" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_ADVB" --no-design "k6re R14-F1: shape B advice-following" "should refuse" 2>/dev/null) || RC=$?
assert_eq "8.6f shape B: initial refusal (exit 4)" "4" "$RC"
OBS_B=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "8.6g shape B: the advice correctly identifies iteration=9 as ALREADY recorded" \
    "iteration=9) is ALREADY recorded" "$OBS_B"
follow_the_advice "$TID_ADVB" "$OBS_B" "k6re R14-F1: historic round, per the PRINTED advice"
assert_eq "8.6h shape B: every parsed command succeeded" "0" "$FOLLOW_RC"
GATE_B_POST=$(bash "$RC_SCRIPT" gate "$TID_ADVB" 2>/dev/null)
assert_eq "8.6i THE FIX: gate is STILL RESOLVABLE after following the PRINTED advice on the pqnd shape (iteration=9, unchanged)" \
    "9" "$(printf '%s' "$GATE_B_POST" | jq -r '.artifact.iteration')"
assert_eq "8.6j ...never review_artifact_selection_disagreement" \
    "" "$(printf '%s' "$GATE_B_POST" | jq -r '.error_key')"
RC=0
OUT=$(bash "$QG" approve "$TID_ADVB" --no-design "k6re R14-F1: shape B advice-following" "should now succeed" 2>/dev/null) || RC=$?
assert_eq "8.6k shape B: approve succeeds after following the PRINTED advice literally (exit 0) — THE R13-F1 CONTROL, SATISFIED" "0" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.7: governance comes from review-check.sh gate, never from disk files (claude-workflow-plugin-k6re R15-F1/F2) ==="
# THIRD ROUND against the SAME comparison (R13-F1, R14-F1, now R15-F1): the
# disk-only derivation missed a governing round whenever its FILE was
# missing or unreadable, and could mistake a non-governing RECONCILED
# record for a governing one (R15-F2). The fix retires the comparison
# entirely rather than patching it a fourth time -- cmd_approve now consults
# review-check.sh gate (the ONE authoritative K3 selector) and reports ITS
# answer. These legs reproduce QA's own two measured triggers directly
# against the SHIPPED script, not against a re-derivation of the bug.

# 8.7.A TRIGGER A: the governing round's FILE is DELETED entirely (matches
# QA's own probe8-citable.sh shape: git-untracked docs/reviews/*.json for a
# task whose REVIEW-ARTIFACT v1 record lives durably in bd — a fresh clone
# or `git clean -fdx` reproduces this for real, unprompted).
TID_R15A=$(new_task "review-sep: R15-F1 Trigger A (governing file deleted)" "src/r15a.ts")
record_implementer "$TID_R15A" "backend"
for i in 15 16 17 18 19 20; do record_artifact_at_iter "$TID_R15A" "sol-codex" "$i" "[]"; done
plant_unrecorded "$TID_R15A" 10
GATE_R15A_PRE=$(bash "$RC_SCRIPT" gate "$TID_R15A" 2>/dev/null)
assert_eq "8.7.A.1 pre-condition: gate has a WORKING selector before any remedy (iteration=20)" \
    "20" "$(printf '%s' "$GATE_R15A_PRE" | jq -r '.artifact.iteration')"
rm -f "$(art_path_for "$TID_R15A" 20)"
assert_eq "8.7.A.2 precondition: r20's file is genuinely gone" \
    "1" "$([ ! -e "$(art_path_for "$TID_R15A" 20)" ] && echo 1 || echo 0)"
GATE_R15A_NOFILE=$(bash "$RC_SCRIPT" gate "$TID_R15A" 2>/dev/null)
assert_eq "8.7.A.3 gate STILL reports iteration=20 with the file gone (the record, not the file, is what gate reads)" \
    "20" "$(printf '%s' "$GATE_R15A_NOFILE" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_R15A" --no-design "k6re R15-F1 Trigger A" "should refuse" 2>/dev/null) || RC=$?
assert_eq "8.7.A.4 approve refuses (exit 4)" "4" "$RC"
OBS_R15A=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "8.7.A.5 THE FIX: advice correctly identifies iteration=20 (from gate) as ALREADY recorded" \
    "iteration=20) is ALREADY recorded" "$OBS_R15A"
assert_not_contains "8.7.A.6 advice does NOT recommend review-record on the unrecorded r10 (there IS a governing round; recording anything would invert it)" \
    "record THAT one" "$OBS_R15A"
assert_not_contains "8.7.A.7 r20 (deleted) is invisible to the on-disk glob, so it is never listed as an unrecorded artifact" \
    "-r20.json" "$OBS_R15A"
follow_the_advice "$TID_R15A" "$OBS_R15A" "k6re R15-F1 Trigger A: historic round, per the printed advice"
assert_eq "8.7.A.8 every parsed command (reconcile r10) succeeded" "0" "$FOLLOW_RC"
GATE_R15A_POST=$(bash "$RC_SCRIPT" gate "$TID_R15A" 2>/dev/null)
assert_eq "8.7.A.9 gate STILL resolves at iteration=20 after the remedy (never review_artifact_selection_disagreement)" \
    "20" "$(printf '%s' "$GATE_R15A_POST" | jq -r '.artifact.iteration')"
assert_eq "8.7.A.10 ...error_key empty" "" "$(printf '%s' "$GATE_R15A_POST" | jq -r '.error_key')"
RC=0
OUT=$(bash "$QG" approve "$TID_R15A" --no-design "k6re R15-F1 Trigger A" "should now succeed" 2>/dev/null) || RC=$?
assert_eq "8.7.A.11 approve succeeds after the remedy (exit 0) — TRIGGER A CLOSED" "0" "$RC"

# 8.7.B TRIGGER B: the governing round's FILE is UNREADABLE (chmod 000), NOT
# deleted — QA's own probe9-unreadable.sh shape, needing no deletion at all.
# Unlike Trigger A, r20's file DOES appear in unrecorded_missing here (as
# "unhashable"), but it must never be reconciled or recorded — it already
# governs. The recovery QA measured for this shape reconciles ONLY the
# genuinely-unrecorded file and separately clears the unhashable r20 entry
# via the audited --accept-unrecorded-review bypass, so this leg drives
# exactly that, rather than the generic follow_the_advice helper (which
# would try, and fail, to review-reconcile an unreadable file — a different,
# out-of-scope question about how that sub-case is worded).
TID_R15B=$(new_task "review-sep: R15-F1 Trigger B (governing file chmod 000)" "src/r15b.ts")
record_implementer "$TID_R15B" "backend"
for i in 15 16 17 18 19 20; do record_artifact_at_iter "$TID_R15B" "sol-codex" "$i" "[]"; done
plant_unrecorded "$TID_R15B" 10
GATE_R15B_PRE=$(bash "$RC_SCRIPT" gate "$TID_R15B" 2>/dev/null)
assert_eq "8.7.B.1 pre-condition: gate has a WORKING selector before any remedy (iteration=20)" \
    "20" "$(printf '%s' "$GATE_R15B_PRE" | jq -r '.artifact.iteration')"
chmod 000 "$(art_path_for "$TID_R15B" 20)"
GATE_R15B_UNREAD=$(bash "$RC_SCRIPT" gate "$TID_R15B" 2>/dev/null)
assert_eq "8.7.B.2 gate STILL reports iteration=20 with the file unreadable (gate never reads docs/reviews/*.json at all)" \
    "20" "$(printf '%s' "$GATE_R15B_UNREAD" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_R15B" --no-design "k6re R15-F1 Trigger B" "should refuse" 2>/dev/null) || RC=$?
assert_eq "8.7.B.3 approve refuses (exit 4)" "4" "$RC"
OBS_R15B=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "8.7.B.4 THE FIX: advice STILL correctly identifies iteration=20 as ALREADY recorded, even though r20's own file is unreadable" \
    "iteration=20) is ALREADY recorded" "$OBS_R15B"
assert_contains "8.7.B.5 r20 (unreadable) DOES appear, honestly, as unhashable -- unlike Trigger A" \
    "unhashable" "$OBS_R15B"
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_R15B" --file "$(art_path_for "$TID_R15B" 10)" "k6re R15-F1 Trigger B: reconcile the genuinely-unrecorded round only" 2>/dev/null) || RC=$?
assert_eq "8.7.B.6 reconciling ONLY the genuinely-unrecorded r10 succeeds" "0" "$RC"
RC=0
OUT=$(bash "$QG" approve "$TID_R15B" --no-design "k6re R15-F1 Trigger B" --accept-unrecorded-review "r20 file is chmod 000 by design of this test; the record already governs" "clearing the residual unhashable entry" 2>/dev/null) || RC=$?
assert_eq "8.7.B.7 the audited bypass clears the residual unhashable r20 entry (exit 0) — TRIGGER B CLOSED" "0" "$RC"
chmod 644 "$(art_path_for "$TID_R15B" 20)" 2>/dev/null || true

# 8.7.C R15-F2: a RECONCILED record at a HIGH iteration must never be
# reported as governing, even though recorded-hashes deliberately treats its
# hash as "recorded" (the union, not the K3 winner).
TID_R15C=$(new_task "review-sep: R15-F2 a RECONCILED high iteration never governs" "src/r15c.ts")
record_implementer "$TID_R15C" "backend"
record_artifact_at_iter "$TID_R15C" "sol-codex" 3 "[]"
plant_unrecorded "$TID_R15C" 999
bash "$QG" review-reconcile "$TID_R15C" --file "$(art_path_for "$TID_R15C" 999)" "k6re R15-F2: historic round, reconciled, never governing" >/dev/null 2>&1
# iteration=1, deliberately BELOW the governing iteration=3 (not above, and
# nowhere near the RECONCILED 999) -- the point under test is specifically
# whether the ALREADY-recorded comparison is fooled by the RECONCILED
# iteration into thinking IT governs, not the separate (and correctly
# different) "an unrecorded round is newer than what governs" branch 8.7.A
# already covers.
plant_unrecorded "$TID_R15C" 1
GATE_R15C=$(bash "$RC_SCRIPT" gate "$TID_R15C" 2>/dev/null)
assert_eq "8.7.C.1 pre-condition: gate selects the GOVERNING iteration=3, never the RECONCILED iteration=999" \
    "3" "$(printf '%s' "$GATE_R15C" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_R15C" --no-design "k6re R15-F2" "should refuse" 2>/dev/null) || RC=$?
assert_eq "8.7.C.2 approve refuses on the genuinely-unrecorded r1 (exit 4)" "4" "$RC"
OBS_R15C=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "8.7.C.3 THE FIX: advice identifies iteration=3 (gate's real answer) as ALREADY recorded" \
    "iteration=3) is ALREADY recorded" "$OBS_R15C"
assert_not_contains "8.7.C.4 advice NEVER claims the RECONCILED iteration=999 governs — the exact R15-F2 defect" \
    "iteration=999) is ALREADY recorded" "$OBS_R15C"
follow_the_advice "$TID_R15C" "$OBS_R15C" "k6re R15-F2: historic round"
assert_eq "8.7.C.5 every parsed command succeeded" "0" "$FOLLOW_RC"
GATE_R15C_POST=$(bash "$RC_SCRIPT" gate "$TID_R15C" 2>/dev/null)
assert_eq "8.7.C.6 gate still selects iteration=3 after the remedy" \
    "3" "$(printf '%s' "$GATE_R15C_POST" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_R15C" --no-design "k6re R15-F2" "should now succeed" 2>/dev/null) || RC=$?
assert_eq "8.7.C.7 approve succeeds (exit 0)" "0" "$RC"

# 8.7.D STRUCTURAL: the retired disk-derived comparison cannot be
# reintroduced silently under its old name (claude-workflow-plugin-k6re,
# per the explicit instruction that a future reader must not be able to).
# Word-boundary anchored: "unrecorded_max_iter" (the legitimate, UNCHANGED
# fallback-only variable this same block still declares) contains
# "recorded_max_iter" as a bare substring with no boundary before it ("n"
# into "r" is word-to-word, not a boundary) -- an unanchored count would
# false-positive on every one of ITS OWN occurrences and never actually
# prove the retired name is gone.
# NOT `grep -c ... || echo 0`: grep -c ALWAYS prints a count, including "0",
# and exits 1 (not 0) precisely when that count is zero -- a fallback keyed
# on grep's exit code fires on the ordinary, well-formed "zero matches"
# case too, appending a SECOND "0" after an embedded newline ("0\n0") that
# compares unequal to the plain "0" this assertion expects. Bare grep -c
# already reports "0" correctly on its own; no fallback is needed here.
assert_eq "8.7.D.1 the shipped qa-gate.sh no longer declares recorded_max_iter anywhere (word-boundary anchored, distinct from the legitimate unrecorded_max_iter)" \
    "0" "$(grep -cE '\brecorded_max_iter\b' "$QG" 2>/dev/null)"

# 8.7.E META: the R15-GATE-CONSULT block is load-bearing (non-vacuity: a
# shipped copy with the gate-consultation stripped visibly DEGRADES rather
# than silently keeping the old, wrong disk-based answer — there is no old
# disk-based answer left anywhere in the source to fall back to).
QG_R15_STRIPPED="$FIXTURE/.claude/scripts/qa-gate-nor15fix.sh"
STRIP_R15_RC=0
awk '
    /# R15-GATE-CONSULT BEGIN/ { skipping=1; found=1; next }
    /# R15-GATE-CONSULT END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_R15_STRIPPED" || STRIP_R15_RC=$?
chmod +x "$QG_R15_STRIPPED"
assert_eq "8.7.E.1 META: R15-GATE-CONSULT sentinels present in qa-gate.sh" "0" "$STRIP_R15_RC"

if [ "$STRIP_R15_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$QG_R15_STRIPPED" 2>/dev/null || PARSE_RC=$?
    assert_eq "8.7.E.2 META: stripped copy still parses (unrecorded_current_advice stays permanently unset, its declared default)" \
        "0" "$PARSE_RC"

    TID_R15_META=$(new_task "review-sep: R15-F1 META, gate-consult stripped" "src/r15meta.ts")
    record_implementer "$TID_R15_META" "backend"
    for i in 15 16 17 18 19 20; do record_artifact_at_iter "$TID_R15_META" "sol-codex" "$i" "[]"; done
    plant_unrecorded "$TID_R15_META" 10
    RC=0
    OUT=$(bash "$QG_R15_STRIPPED" approve "$TID_R15_META" --no-design "k6re R15-F1 META" "should refuse" 2>/dev/null) || RC=$?
    assert_eq "8.7.E.3 META: the mutant still refuses initially (exit 4)" "4" "$RC"
    OBS_R15_META=$(printf '%s' "$OUT" | jq -r '.observations')
    assert_not_contains "8.7.E.4 META, SPECIFIC MISBEHAVIOUR: WITHOUT gate-consultation, the advice never identifies iteration=20 as governing (the mechanism is what says so)" \
        "ALREADY recorded" "$OBS_R15_META"

    # Discriminator: the sentinel wraps the WHOLE advice computation (all
    # three branches share it), so there is no "different branch, same
    # refusal" leg left to discriminate against within this one refusal —
    # unlike 8.9's guard, which sits beside unrelated code in the SAME
    # function. The meaningful "is this mutation scoped, or is the whole
    # script broken" question here is instead: does the mutant still
    # approve NORMALLY when there is nothing to refuse on at all (every
    # artifact already accounted for) — proving the strip specifically
    # empties the REFUSAL's advice text, not cmd_approve as a whole or the
    # separate REVIEW-SEPARATION mechanism this same function also runs.
    TID_R15_DISCRIM=$(new_task "review-sep: R15-F1 META discriminator, nothing unrecorded at all" "src/r15discrim.ts")
    record_implementer "$TID_R15_DISCRIM" "backend"
    record_artifact_at_iter "$TID_R15_DISCRIM" "sol-codex" 1 "[]"
    RC=0
    OUT=$(bash "$QG_R15_STRIPPED" approve "$TID_R15_DISCRIM" --no-design "k6re R15-F1 META discriminator" "should succeed" 2>/dev/null) || RC=$?
    assert_eq "8.7.E.5 discriminator: the mutant still approves NORMALLY when nothing is unrecorded (exit 0) — the strip is scoped to the refusal path" "0" "$RC"
    assert_eq "8.7.E.6 discriminator: ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status' 2>/dev/null)"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("8.7.E META: R15-GATE-CONSULT sentinels missing — strip meta-test skipped")
    printf '  FAIL: 8.7.E META: R15-GATE-CONSULT sentinels missing — strip meta-test skipped\n'
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.8: review-reconcile REFUSES an unacknowledged open finding at/above its own risk_threshold (claude-workflow-plugin-k6re R14-F5) ==="
# THE DEFECT THIS CLOSES: the review_artifact_unrecorded refusal's own
# remediation advice tells the operator to reconcile "every OTHER listed
# file" with no severity qualifier — so an unrecorded historic round that
# still carries an open CRITICAL could be durably marked non-governing
# (and therefore NEVER counted by gate's open-findings check, since a
# REVIEW-ARTIFACT-RECONCILED v1 record carries no findings of its own) without
# the operator ever being forced to notice. NOT a blanket refusal: a historic
# critical is usually already addressed by a LATER round, which is close to
# what "historic" means here — the audited escape is --acknowledge-findings,
# the same "explain yourself" shape --no-review and --accept-unrecorded-review
# already use elsewhere in this file.

# 8.8a: an unrecorded artifact whose OWN findings carry a CRITICAL at/above
# its own risk_threshold=high — review-reconcile refuses without the flag.
TID_F5=$(new_task "review-sep: R14-F5 findings-acknowledgment guard" "src/f5crit.ts")
record_implementer "$TID_F5" "backend"
plant_unrecorded_findings "$TID_F5" 1 "high" \
    '[{"id":"R1-F1","severity":"critical","location":"src/f5crit.ts:1","evidence":"planted for 8.8","description":"deliberately unresolved for this test"}]'
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_F5" --file "$(art_path_for "$TID_F5" 1)" "backfilling round 1" 2>/dev/null) || RC=$?
assert_eq "8.8a refuses without --acknowledge-findings: exit 1" "1" "$RC"
assert_eq "8.8b ...error_key=reconcile_open_findings_unacknowledged" \
    "reconcile_open_findings_unacknowledged" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "8.8c ...names the open finding id and severity" "R1-F1:critical" "$OUT"
assert_contains "8.8d ...remedy names --acknowledge-findings" "--acknowledge-findings" "$OUT"
assert_contains "8.8e ...remedy also names review-record + resolve-finding as the alternative" \
    "resolve-finding" "$OUT"

# 8.8f: the refusal is a NO-OP — no RECONCILED comment was written at all.
assert_eq "8.8f refusal wrote NO comment" "0" \
    "$(comments_of "$TID_F5" | grep -c '^REVIEW-ARTIFACT-RECONCILED v1 ' || true)"

# 8.8g: the SAME command with --acknowledge-findings and a reason succeeds,
# and the durable comment carries a visible acknowledgment marker so the
# information is never silently dropped.
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_F5" --file "$(art_path_for "$TID_F5" 1)" \
    --acknowledge-findings "superseded by round 9, see governing artifact" 2>/dev/null) || RC=$?
assert_eq "8.8h --acknowledge-findings succeeds: exit 0" "0" "$RC"
assert_eq "8.8i ...ok=true" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
F5_CMT=$(comments_of "$TID_F5" | grep '^REVIEW-ARTIFACT-RECONCILED v1 ' | tail -1)
assert_contains "8.8j the durable comment embeds the acknowledgment marker" \
    "[open findings acknowledged: R1-F1:critical]" "$F5_CMT"
assert_contains "8.8k ...and still carries the human reason after the marker" \
    "superseded by round 9, see governing artifact" "$F5_CMT"

# 8.8l: THE NEGATIVE CONTROL — an artifact with a finding BELOW its own
# risk_threshold reconciles cleanly with NO flag and NO marker, proving the
# guard triggers on SEVERITY RANK, not on the mere presence of findings[].
plant_unrecorded_findings "$TID_F5" 2 "high" \
    '[{"id":"R1-F2","severity":"low","location":"src/f5crit.ts:2","evidence":"cosmetic","description":"well below threshold"}]'
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_F5" --file "$(art_path_for "$TID_F5" 2)" "below-threshold historic finding" 2>/dev/null) || RC=$?
assert_eq "8.8m below-threshold finding needs NO flag: exit 0" "0" "$RC"
F5_CMT2=$(comments_of "$TID_F5" | grep '^REVIEW-ARTIFACT-RECONCILED v1 iteration=2 ')
assert_not_contains "8.8n ...and carries NO acknowledgment marker (nothing to acknowledge)" \
    "acknowledged" "$F5_CMT2"

# 8.8o: BOUNDARY — a finding EXACTLY AT the risk_threshold (not merely above
# it) still triggers the guard, mirroring gate's own inclusive ">=" open-
# findings rule (review-check.sh: "severity rank is >= the artifact's
# risk_threshold rank").
plant_unrecorded_findings "$TID_F5" 3 "high" \
    '[{"id":"R1-F3","severity":"high","location":"src/f5crit.ts:3","evidence":"at threshold","description":"exactly at threshold"}]'
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_F5" --file "$(art_path_for "$TID_F5" 3)" "at-threshold historic finding" 2>/dev/null) || RC=$?
assert_eq "8.8p exactly-at-threshold ALSO refuses (inclusive boundary): exit 1" "1" "$RC"
assert_eq "8.8q ...error_key=reconcile_open_findings_unacknowledged" \
    "reconcile_open_findings_unacknowledged" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.9: META — the R14F5-FINDINGS-GUARD sentinel block is load-bearing (claude-workflow-plugin-k6re R14-F5) ==="
QG_R14F5_STRIPPED="$FIXTURE/.claude/scripts/qa-gate-nor14f5.sh"
STRIP_R14F5_RC=0
awk '
    /# R14F5-FINDINGS-GUARD BEGIN/ { skipping=1; found=1; next }
    /# R14F5-FINDINGS-GUARD END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG" > "$QG_R14F5_STRIPPED" || STRIP_R14F5_RC=$?
chmod +x "$QG_R14F5_STRIPPED"
assert_eq "8.9a META: R14F5-FINDINGS-GUARD sentinels present in qa-gate.sh" "0" "$STRIP_R14F5_RC"

if [ "$STRIP_R14F5_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$QG_R14F5_STRIPPED" 2>/dev/null || PARSE_RC=$?
    assert_eq "8.9b META: stripped copy still parses" "0" "$PARSE_RC"

    TID_F5_META=$(new_task "review-sep: R14-F5 META, guard stripped" "src/f5meta.ts")
    record_implementer "$TID_F5_META" "backend"
    plant_unrecorded_findings "$TID_F5_META" 1 "high" \
        '[{"id":"R1-F1","severity":"critical","location":"src/f5meta.ts:1","evidence":"planted for 8.9","description":"should be caught; mutant lacks the guard"}]'
    RC=0
    OUT=$(bash "$QG_R14F5_STRIPPED" review-reconcile "$TID_F5_META" --file "$(art_path_for "$TID_F5_META" 1)" "mutant probe, no flag" 2>/dev/null) || RC=$?
    assert_eq "8.9c SPECIFIC MISBEHAVIOUR: WITHOUT the guard, an unacknowledged critical reconciles SILENTLY (exit 0)" \
        "0" "$RC"
    assert_eq "8.9d ...ok=true (the exact R14-F5 defect, reproduced)" "true" "$(printf '%s' "$OUT" | jq -r '.ok')"
    F5_META_CMT=$(comments_of "$TID_F5_META" | grep '^REVIEW-ARTIFACT-RECONCILED v1 ')
    assert_not_contains "8.9e ...and the durable comment carries NO acknowledgment marker -- the finding is now invisible" \
        "acknowledged" "$F5_META_CMT"

    # Discriminator: the mutant still reconciles a CLEAN artifact fine —
    # proving 8.9c/d is specifically about the missing guard, not a broken
    # script in general (same discriminator shape as 8.7h-k).
    TID_F5_DISCRIM=$(new_task "review-sep: R14-F5 META discriminator" "src/f5discrim.ts")
    record_implementer "$TID_F5_DISCRIM" "backend"
    plant_unrecorded "$TID_F5_DISCRIM" 1
    RC=0
    OUT=$(bash "$QG_R14F5_STRIPPED" review-reconcile "$TID_F5_DISCRIM" --file "$(art_path_for "$TID_F5_DISCRIM" 1)" "clean historic round" 2>/dev/null) || RC=$?
    assert_eq "8.9f discriminator: the mutant still reconciles a CLEAN artifact fine (exit 0)" "0" "$RC"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("8.9 META: R14F5-FINDINGS-GUARD sentinels missing — strip meta-test skipped")
    printf '  FAIL: 8.9 META: R14F5-FINDINGS-GUARD sentinels missing — strip meta-test skipped\n'
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.11: an acknowledged finding reaches MECHANICAL readers, not only the comment stream (claude-workflow-plugin-k6re R15-F3) ==="
# QA's R15-F3 ruling: the --acknowledge-findings marker is real in the
# comment stream, but INERT to every mechanical reader before this fix --
# gate reports open_findings=0 (by design, unchanged), recorded-hashes had
# no such field at all, and approve emitted an unqualified "check PASSED".
# That is asymmetric with --accept-unrecorded-review, whose reason DOES
# reach the approve envelope. Two legs: recorded-hashes' new field directly,
# then the same fact surfacing in approve's own success observations.

# 8.11a: recorded-hashes exposes acknowledged_hashes/acknowledged_count.
TID_F3=$(new_task "review-sep: R15-F3 acknowledged finding reaches recorded-hashes" "src/f3ack.ts")
record_implementer "$TID_F3" "backend"
record_artifact_at_iter "$TID_F3" "sol-codex" 1 "[]"
plant_unrecorded_findings "$TID_F3" 2 "high" \
    '[{"id":"R1-F1","severity":"critical","location":"src/f3ack.ts:2","evidence":"planted for 8.11","description":"acknowledged historic critical"}]'
ART2_HASH=$(bash "$FIXTURE/.claude/scripts/workflow-manifest.sh" hash-file "$(art_path_for "$TID_F3" 2)" 2>/dev/null)
RC=0
OUT=$(bash "$QG" review-reconcile "$TID_F3" --file "$(art_path_for "$TID_F3" 2)" --acknowledge-findings "superseded by round 1, see governing artifact" 2>/dev/null) || RC=$?
assert_eq "8.11a review-reconcile --acknowledge-findings succeeds" "0" "$RC"
RH_F3=$(bash "$RC_SCRIPT" recorded-hashes "$TID_F3" 2>/dev/null)
assert_eq "8.11b recorded-hashes.acknowledged_count=1" "1" "$(printf '%s' "$RH_F3" | jq -r '.acknowledged_count')"
assert_eq "8.11c recorded-hashes.acknowledged_hashes contains the r2 hash" "true" \
    "$(printf '%s' "$RH_F3" | jq --arg h "$ART2_HASH" '.acknowledged_hashes | index($h) != null')"
assert_eq "8.11d ...and hashes (the full recorded set) still contains it too — additive, not a replacement" "true" \
    "$(printf '%s' "$RH_F3" | jq --arg h "$ART2_HASH" '.hashes | index($h) != null')"

# 8.11e-h: the SAME fact reaches approve's own success observations, closing
# the asymmetry with --accept-unrecorded-review's own reason (which already
# reaches this same string, per the branch above).
RC=0
OUT=$(bash "$QG" approve "$TID_F3" --no-design "k6re R15-F3" "should succeed, mentioning the acknowledgment" 2>/dev/null) || RC=$?
assert_eq "8.11e approve succeeds (nothing left unrecorded)" "0" "$RC"
OBS_F3=$(printf '%s' "$OUT" | jq -r '.observations')
assert_contains "8.11f THE FIX: approve's own envelope mentions the acknowledged open finding — no longer inert to this mechanical reader" \
    "1 of the recorded artifact(s)" "$OBS_F3"
assert_contains "8.11g ...naming review-reconcile --acknowledge-findings as the mechanism" \
    "acknowledge-findings" "$OBS_F3"

# 8.11h ANTI-VACUITY: a task whose backlog reconciles CLEAN (no acknowledged
# findings at all) gets NO such mention — proving 8.11f is not a fixed
# string printed unconditionally.
TID_F3_CLEAN=$(new_task "review-sep: R15-F3 negative control, no acknowledgment" "src/f3clean.ts")
record_implementer "$TID_F3_CLEAN" "backend"
record_artifact_at_iter "$TID_F3_CLEAN" "sol-codex" 1 "[]"
plant_unrecorded "$TID_F3_CLEAN" 2
bash "$QG" review-reconcile "$TID_F3_CLEAN" --file "$(art_path_for "$TID_F3_CLEAN" 2)" "clean historic round, nothing to acknowledge" >/dev/null 2>&1
RH_F3_CLEAN=$(bash "$RC_SCRIPT" recorded-hashes "$TID_F3_CLEAN" 2>/dev/null)
assert_eq "8.11h ...recorded-hashes.acknowledged_count=0 for a clean backlog" "0" "$(printf '%s' "$RH_F3_CLEAN" | jq -r '.acknowledged_count')"
RC=0
OUT=$(bash "$QG" approve "$TID_F3_CLEAN" --no-design "k6re R15-F3 negative control" "should succeed, no mention" 2>/dev/null) || RC=$?
assert_eq "8.11i approve succeeds" "0" "$RC"
OBS_F3_CLEAN=$(printf '%s' "$OUT" | jq -r '.observations')
assert_not_contains "8.11j ...and its envelope carries NO acknowledgment mention (nothing to acknowledge)" \
    "acknowledged open finding" "$OBS_F3_CLEAN"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.12: the gate-consult survives a refusal under set -e (claude-workflow-plugin-k6re R16-F1) ==="
# THE DEFECT THIS CLOSES: qa-gate.sh runs under `set -e` (line 196). gate
# EXITS 4 ON EVERY REFUSAL, and the R15-F1 fix's own consult
# (unrecorded_gate_out=$(... gate ...)) was a BARE command substitution --
# the only one of four `review-check.sh gate` call sites in this file with
# no `|| true` / `|| rc=$?` guard. Under set -e, a bare substitution whose
# command exits non-zero aborts the WHOLE SCRIPT on the spot, with gate's
# OWN exit code becoming qa-gate.sh's exit code and NO envelope at all --
# which is every path except the one where a governing record already
# exists cleanly, i.e. exactly the two branches (review_artifact_missing;
# the "will NOT guess" catch-all) this whole mechanism exists to reach.

# 8.12a-d: THE F1 SHAPE (--no-review, zero REVIEW-ARTIFACT records, one
# stray unrecorded artifact) -- branch 2 (review_artifact_missing).
TID_R16A=$(new_task "review-sep: R16-F1 gate-consult survives (branch 2)" "src/r16a.ts")
plant_unrecorded "$TID_R16A" 1
RC=0
OUT=$(bash "$QG" approve "$TID_R16A" --no-design "k6re R16-F1" --no-review "no implementer, no review artifact at all" "should refuse with a real envelope" 2>/dev/null) || RC=$?
assert_eq "8.12a approve refuses (exit 4)" "4" "$RC"
assert_eq "8.12b THE FIX: the envelope is NOT empty (a bare abort under set -e produces zero bytes)" \
    "nonempty" "$([ -n "$OUT" ] && echo nonempty || echo empty)"
assert_eq "8.12c ...error_key=review_artifact_unrecorded (the key verify-before-stop.sh documents as reachable here)" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"
assert_contains "8.12d ...observations name the review_artifact_missing branch (nothing governs yet)" \
    "review_artifact_missing" "$(printf '%s' "$OUT" | jq -r '.observations' 2>/dev/null)"

# 8.12e-h: THE ELSE-BRANCH SHAPE -- gate cannot establish a governing
# record for a reason OTHER than "none exist" (here: a WEDGED selector,
# review_artifact_selection_disagreement, built the same way Section 8.1's
# TID_TRAP proves it -- naive review-record on a pqnd-shaped backlog, even
# ascending), plus a fresh stray unrecorded file. Branch 3, the fix's own
# headline safety claim ("will NOT guess"), only reachable if gate's
# non-zero exit does not itself kill the process first.
TID_R16B=$(new_task "review-sep: R16-F1 gate-consult survives (branch 3, else)" "src/r16b.ts")
record_implementer "$TID_R16B" "backend"
for i in 5 6 7 8 9; do record_artifact_at_iter "$TID_R16B" "sol-codex" "$i" "[]"; done
# plant BEFORE recording -- review-record needs real bytes at each path to
# record; Section 8.1's TID_TRAP establishes the identical wedge the same
# two-step way (plant, then record each planted file in ascending order).
for i in 1 2 3 4; do plant_unrecorded "$TID_R16B" "$i"; done
for i in 1 2 3 4; do
    bash "$QG" review-record "$TID_R16B" --file "$(art_path_for "$TID_R16B" "$i")" >/dev/null 2>&1
done
GATE_R16B_WEDGED=$(bash "$RC_SCRIPT" gate "$TID_R16B" 2>/dev/null)
assert_eq "8.12e precondition: the selector is genuinely wedged (review_artifact_selection_disagreement)" \
    "review_artifact_selection_disagreement" "$(printf '%s' "$GATE_R16B_WEDGED" | jq -r '.error_key')"
plant_unrecorded "$TID_R16B" 20
RC=0
OUT=$(bash "$QG" approve "$TID_R16B" --no-design "k6re R16-F1 else branch" --no-review "REVIEW-SEPARATION (an EARLIER, unrelated block) also independently refuses on a wedged selector -- bypassed so this leg exercises the unrecorded-artifact block's own else-branch specifically, not REVIEW-SEPARATION's" "should refuse, not abort" 2>/dev/null) || RC=$?
assert_eq "8.12f approve refuses (exit 4)" "4" "$RC"
assert_eq "8.12g THE FIX: the envelope is NOT empty here either" \
    "nonempty" "$([ -n "$OUT" ] && echo nonempty || echo empty)"
OBS_R16B=$(printf '%s' "$OUT" | jq -r '.observations' 2>/dev/null)
assert_contains "8.12h THE FIX: the headline safety claim actually prints -- gate could not establish which round governs, and this refusal will NOT guess" \
    "will NOT guess" "$OBS_R16B"
assert_not_contains "8.12i ...and, correctly, names NO --file for review-record (nothing to promote when gate itself cannot be trusted)" \
    "--file $(art_path_for "$TID_R16B" 20) '<reason>' for each" "$OBS_R16B"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.12.M: META — the R16-F1 || true guard is load-bearing (claude-workflow-plugin-k6re R16-F1) ==="
QG_R16F1_STRIPPED="$FIXTURE/.claude/scripts/qa-gate-nor16f1.sh"
STRIP_R16F1_RC=0
# Anchored on "unrecorded_gate_out=" specifically, NOT merely on the shared
# "bash ... gate ... || true)" suffix: the OTHER two guarded call sites in
# this file (art_gate_out=, rc_out=) share that exact suffix, and an
# unanchored pattern would revert all three at once -- the SAME "same-
# shaped text in multiple places doubles a sed mutation's footprint" class
# already caught once this arc (review-count.test.sh 15.9a2).
# Both sides of the s/// below are meant to be LITERAL source text, dollar
# signs included: the pattern must match qa-gate.sh's own `$(...)` command-
# substitution syntax byte for byte, and the replacement must reproduce it
# minus ` || true`. Single quotes are what keeps every `$` here from being
# expanded by THIS shell before sed ever sees it; double-quoting to silence
# the shellcheck warning below would defeat the point of the sentence.
# shellcheck disable=SC2016
sed 's/unrecorded_gate_out=\$(CLAUDE_PROJECT_DIR="\$PROJECT_DIR" bash "\$REVIEW_CHECK_SCRIPT" gate "\$tid" 2>\/dev\/null || true)/unrecorded_gate_out=$(CLAUDE_PROJECT_DIR="$PROJECT_DIR" bash "$REVIEW_CHECK_SCRIPT" gate "$tid" 2>\/dev\/null)/' \
    "$QG" > "$QG_R16F1_STRIPPED"
# STRIP_R16F1_RC=$? MUST be the line immediately after the redirect above --
# capturing `sed`'s own exit status, not a later command's, is the whole
# point of putting it here at all; inserting anything between the redirect
# and this assignment would silently start capturing THAT command's status
# instead. Read below (8.12.M.0), not just assigned: a mutation leg whose
# own mutation-step exit status is captured and never checked is the same
# vacuous-META shape `ybhc` and two separate QA-round finding legs already
# cost this arc once each -- cmp/diff below prove the CONTENT changed, this
# is the cheaper, independent witness that the tool that changed it did not
# itself fail first.
STRIP_R16F1_RC=$?
assert_eq "8.12.M.0 META non-vacuity: sed itself exited 0 (the mutation step did not fail before ever reaching the content)" \
    "0" "$STRIP_R16F1_RC"
chmod +x "$QG_R16F1_STRIPPED"
assert_eq "8.12.M.1 META: the revert applied (mutant differs from source)" "differs" \
    "$(cmp -s "$QG" "$QG_R16F1_STRIPPED" && echo identical || echo differs)"
assert_eq "8.12.M.2 META: the revert touches EXACTLY one line" "1" \
    "$(diff "$QG" "$QG_R16F1_STRIPPED" | grep -c '^<')"
PARSE_RC=0
bash -n "$QG_R16F1_STRIPPED" 2>/dev/null || PARSE_RC=$?
assert_eq "8.12.M.3 META: reverted copy still parses" "0" "$PARSE_RC"

TID_R16M=$(new_task "review-sep: R16-F1 META, guard reverted" "src/r16meta.ts")
plant_unrecorded "$TID_R16M" 1
RC=0
OUT=$(bash "$QG_R16F1_STRIPPED" approve "$TID_R16M" --no-design "k6re R16-F1 META" --no-review "reverted guard" "should abort, not refuse cleanly" 2>/dev/null) || RC=$?
assert_eq "8.12.M.4 META, SPECIFIC MISBEHAVIOUR: WITHOUT the guard, set -e still aborts with rc=4 (gate's own exit code)..." \
    "4" "$RC"
assert_eq "8.12.M.5 ...but the envelope is COMPLETELY EMPTY -- the exact R16-F1 defect, reproduced" \
    "" "$OUT"

# Discriminator: the reverted mutant still functions normally on the plain
# happy path (a governing record, nothing unrecorded) -- proving the revert
# is scoped to the refusal path under set -e, not a broken script overall.
TID_R16_DISCRIM=$(new_task "review-sep: R16-F1 META discriminator, clean task" "src/r16discrim.ts")
record_implementer "$TID_R16_DISCRIM" "backend"
record_artifact_at_iter "$TID_R16_DISCRIM" "sol-codex" 1 "[]"
RC=0
OUT=$(bash "$QG_R16F1_STRIPPED" approve "$TID_R16_DISCRIM" --no-design "k6re R16-F1 META discriminator" "should succeed" 2>/dev/null) || RC=$?
assert_eq "8.12.M.6 discriminator: the reverted mutant still approves a genuinely clean task (exit 0)" "0" "$RC"
assert_eq "8.12.M.7 ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status' 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.13: an unreadable docs/reviews/ FAILS CLOSED, never a silent pass (claude-workflow-plugin-k6re R16-F2) ==="
# THE DEFECT THIS CLOSES: the enumeration glob has no readability
# precondition, and an UNLISTABLE directory is indistinguishable from an
# EMPTY one to a glob -- so an unreadable docs/reviews/ used to make a
# genuinely-unrecorded artifact invisible, landing in the SAME affirmative
# "nothing to reconcile" PASS a truly clean task prints. Restored to 0755
# after each leg so fixture cleanup is never blocked by a directory this
# test itself made unreadable.

# 8.13a-d: THE A/B, same task, same records, same files, only the
# permission bit differing.
TID_R16C=$(new_task "review-sep: R16-F2 unreadable docs-reviews fails closed" "src/r16c.ts")
plant_unrecorded "$TID_R16C" 1
RC=0
OUT=$(bash "$QG" approve "$TID_R16C" --no-design "k6re R16-F2 baseline" --no-review "baseline, readable directory" "should refuse" 2>/dev/null) || RC=$?
assert_eq "8.13a BASELINE (0755, readable): approve refuses (exit 4)" "4" "$RC"
assert_eq "8.13b ...error_key=review_artifact_unrecorded" "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

chmod 000 "$FIXTURE/docs/reviews"
RC=0
OUT=$(bash "$QG" approve "$TID_R16C" --no-design "k6re R16-F2 unreadable" --no-review "the SAME unrecorded artifact, directory now 0000" "should STILL refuse" 2>/dev/null) || RC=$?
chmod 755 "$FIXTURE/docs/reviews"
assert_eq "8.13c THE FIX: docs/reviews at 0000, SAME unrecorded artifact -> approve STILL refuses (exit 4), never a silent pass" \
    "4" "$RC"
assert_eq "8.13d ...error_key=review_dir_unreadable (distinguishable from review_artifact_unrecorded, not conflated)" \
    "review_dir_unreadable" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

chmod 111 "$FIXTURE/docs/reviews"
RC=0
OUT=$(bash "$QG" approve "$TID_R16C" --no-design "k6re R16-F2 traversable-not-listable" --no-review "traversable but not listable" "should STILL refuse" 2>/dev/null) || RC=$?
chmod 755 "$FIXTURE/docs/reviews"
assert_eq "8.13e 0111 (traversable, not listable) ALSO refuses (exit 4) -- both bits checked, not just readability" \
    "4" "$RC"
assert_eq "8.13f ...same error_key=review_dir_unreadable" "review_dir_unreadable" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

# 8.13g-i ANTI-VACUITY, discriminator 1: the naive expectation is that a
# genuinely CLEAN task (nothing unrecorded at all) would still approve
# normally even with the directory unreadable, since there is nothing to
# reconcile. That is wrong: an unreadable directory must ALSO refuse a
# clean task, since "clean" cannot be verified either when the directory
# cannot be listed.
# Confirm that directly, so the guard is proven to fire on ITS OWN
# precondition (directory unreadable) rather than merely coinciding with an
# unrecorded-artifact refusal that would have fired anyway.
TID_R16_CLEAN=$(new_task "review-sep: R16-F2 discriminator, clean task + unreadable dir" "src/r16clean.ts")
record_implementer "$TID_R16_CLEAN" "backend"
record_artifact_at_iter "$TID_R16_CLEAN" "sol-codex" 1 "[]"
RC=0
OUT=$(bash "$QG" approve "$TID_R16_CLEAN" --no-design "k6re R16-F2 clean task, readable" "should succeed" 2>/dev/null) || RC=$?
assert_eq "8.13g precondition: the SAME task approves normally while the directory IS readable (exit 0)" "0" "$RC"
# cmd_approve's hash-aware idempotency would otherwise no-op the SECOND
# call below (identical change set as an already-approved task never
# re-verifies any precondition) and make this leg pass for the wrong
# reason -- expand the change set and regenerate the impact report first,
# the same real re-verification trigger review-separation.test.sh's
# Section 2.1 already establishes, so the second call is forced to run
# every check fresh, including the one under test.
printf 'src/r16clean.ts\nsrc/r16clean-second.ts\n' > "$TRACK/changed-files.txt"
CLAUDE_PROJECT_DIR="$FIXTURE" bash "$IR" "$TID_R16_CLEAN" >/dev/null 2>&1 || true
chmod 000 "$FIXTURE/docs/reviews"
RC=0
OUT=$(bash "$QG" approve "$TID_R16_CLEAN" --no-design "k6re R16-F2 clean task, unreadable" "should now refuse -- cannot verify clean either" 2>/dev/null) || RC=$?
chmod 755 "$FIXTURE/docs/reviews"
assert_eq "8.13h discriminator: an OTHERWISE-clean task ALSO refuses once the directory is unreadable (exit 4) -- the guard fires on its own precondition" \
    "4" "$RC"
assert_eq "8.13i ...error_key=review_dir_unreadable" "review_dir_unreadable" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

# 8.13j discriminator 2: a directory-ABSENT task must keep passing --
# "absent" is legitimately "nothing to reconcile", not an error, and the
# fix must not conflate the two.
TID_R16_ABSENT=$(new_task "review-sep: R16-F2 discriminator, directory absent stays a pass" "src/r16absent.ts")
record_implementer "$TID_R16_ABSENT" "backend"
record_artifact_at_iter "$TID_R16_ABSENT" "sol-codex" 1 "[]"
MOVED_DIR="$FIXTURE/docs/reviews.moved-for-8.13j"
mv "$FIXTURE/docs/reviews" "$MOVED_DIR"
RC=0
OUT=$(bash "$QG" approve "$TID_R16_ABSENT" --no-design "k6re R16-F2 dir absent" "should succeed -- absent is not an error" 2>/dev/null) || RC=$?
mv "$MOVED_DIR" "$FIXTURE/docs/reviews"
assert_eq "8.13j discriminator: docs/reviews ABSENT entirely -> approve still succeeds (exit 0), never conflated with unreadable" \
    "0" "$RC"
assert_eq "8.13k ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status' 2>/dev/null)"

# 8.13l: a DANGLING SYMLINK at the review-artifact directory path also
# fails closed (the extra safety leg beyond QA's own minimal verified
# remedy -- `-d`/`-e` alone cannot tell "dangling" from "absent").
TID_R16_DANGLE=$(new_task "review-sep: R16-F2 dangling symlink fails closed" "src/r16dangle.ts")
record_implementer "$TID_R16_DANGLE" "backend"
record_artifact_at_iter "$TID_R16_DANGLE" "sol-codex" 1 "[]"
MOVED_DIR2="$FIXTURE/docs/reviews.moved-for-8.13l"
mv "$FIXTURE/docs/reviews" "$MOVED_DIR2"
ln -s "$FIXTURE/docs/reviews-nonexistent-target" "$FIXTURE/docs/reviews"
RC=0
OUT=$(bash "$QG" approve "$TID_R16_DANGLE" --no-design "k6re R16-F2 dangling symlink" "should refuse -- cannot tell if it held artifacts" 2>/dev/null) || RC=$?
rm -f "$FIXTURE/docs/reviews"
mv "$MOVED_DIR2" "$FIXTURE/docs/reviews"
assert_eq "8.13l a DANGLING symlink at docs/reviews/ ALSO refuses (exit 4), not silently read as absent" \
    "4" "$RC"
assert_eq "8.13m ...error_key=review_dir_unreadable" "review_dir_unreadable" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.14: LOW/cheap wording fixes (claude-workflow-plugin-k6re R16-F3, R16-F4) ==="

# 8.14a-c R16-F3: a file whose NAME disagrees with its own CONTENT
# .iterations must never be recommended for review-record (neither
# review-record nor review-reconcile would accept the path this loop could
# name for it).
TID_R16_MISMATCH=$(new_task "review-sep: R16-F3 filename-vs-content iteration mismatch" "src/r16mismatch.ts")
record_implementer "$TID_R16_MISMATCH" "backend"
record_artifact_at_iter "$TID_R16_MISMATCH" "sol-codex" 5 "[]"
MISNAMED="$(art_path_for "$TID_R16_MISMATCH" 99)"
cat > "$MISNAMED" <<JSON
{"contract_version":"1","task_id":"$TID_R16_MISMATCH","reviewer_identity":"sol-codex","reviewer_model":"gpt-5.6-sol","reviewer_pin":"gpt-5.6-sol","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"x","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}
JSON
RC=0
OUT=$(bash "$QG" approve "$TID_R16_MISMATCH" --no-design "k6re R16-F3" "should refuse, never recommend the mismatched file" 2>/dev/null) || RC=$?
assert_eq "8.14a approve refuses (exit 4)" "4" "$RC"
OBS_R16_MISMATCH=$(printf '%s' "$OUT" | jq -r '.observations' 2>/dev/null)
assert_contains "8.14b THE FIX: the mismatch is named explicitly (filename says iteration=99 but content says iterations=1)" \
    "filename says iteration=99 but its own content says iterations=1" "$OBS_R16_MISMATCH"
assert_not_contains "8.14c ...and the mismatched file is NEVER named as the one to review-record" \
    "review-record $TID_R16_MISMATCH --file $MISNAMED" "$OBS_R16_MISMATCH"

# 8.14d-f R16-F4: an unrecorded file at the SAME iteration as the governing
# one (content drift, not a newer round) must read "ALREADY recorded", not
# "NEWER".
TID_R16_DRIFT=$(new_task "review-sep: R16-F4 equal-iteration content drift" "src/r16drift.ts")
record_implementer "$TID_R16_DRIFT" "backend"
record_artifact_at_iter "$TID_R16_DRIFT" "sol-codex" 5 "[]"
DRIFT_PATH="$(art_path_for "$TID_R16_DRIFT" 5)"
cat > "$DRIFT_PATH" <<JSON
{"contract_version":"1","task_id":"$TID_R16_DRIFT","reviewer_identity":"sol-codex","reviewer_model":"gpt-5.6-sol","reviewer_pin":"gpt-5.6-sol","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"x drifted","verdict":"approve","findings":[],"iterations":5,"stopped_by":"verdict"}
JSON
GATE_R16_DRIFT=$(bash "$RC_SCRIPT" gate "$TID_R16_DRIFT" 2>/dev/null)
assert_eq "8.14d precondition: gate still governs at iteration=5 (drift is a hash mismatch, not a new record)" \
    "5" "$(printf '%s' "$GATE_R16_DRIFT" | jq -r '.artifact.iteration')"
RC=0
OUT=$(bash "$QG" approve "$TID_R16_DRIFT" --no-design "k6re R16-F4" "should refuse, correctly worded" 2>/dev/null) || RC=$?
assert_eq "8.14e approve refuses (exit 4)" "4" "$RC"
OBS_R16_DRIFT=$(printf '%s' "$OUT" | jq -r '.observations' 2>/dev/null)
assert_contains "8.14f THE FIX: equal iteration reads ALREADY recorded, via -ge" \
    "iteration=5) is ALREADY recorded" "$OBS_R16_DRIFT"
assert_not_contains "8.14g ...never the wrong NEWER wording for an equal iteration" \
    "iteration=5), is a NEWER round" "$OBS_R16_DRIFT"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.15: a MALFORMED-but-hashable unrecorded artifact refuses cleanly, never aborts under set -e (claude-workflow-plugin-k6re R17-F1) ==="
# THE DEFECT. `unrecorded_content_iter=$(cat -- "$unrecorded_f" | jq -r
# '.iterations // ""')` (qa-gate.sh, the unrecorded-artifact walk) was a bare
# command substitution under `set -e`: `.iterations // ""` is a jq FILTER
# default, which only fires once jq has already parsed its input — it is
# invisible to a top-level PARSE failure, which is exactly what a truncated
# or otherwise malformed on-disk artifact produces. `plant_unrecorded`
# (above) documents itself as writing a well-formed VALID artifact, and no
# leg anywhere in this file's predecessor ever planted malformed JSON under
# docs/reviews/ — the untested-by-construction gap this section closes.
#
# THREE legs, same shape, only the FILE CONTENT differing — mirroring the
# independent review's own A/B: well-formed (baseline control), valid JSON
# with NO .iterations field (control 2 — a MISSING field is a jq no-op, not
# a parse error, so this already refused cleanly even before the fix; it
# discriminates "field absent" from "document does not parse", which is
# exactly the distinction the defect collapsed), and malformed-but-hashable
# (the defect itself).

# 8.15a: BASELINE CONTROL.
TID_R17_WELLFORMED=$(new_task "review-sep: R17-F1 control A, well-formed unrecorded artifact" "src/r17wellformed.ts")
plant_unrecorded "$TID_R17_WELLFORMED" 1
RC=0
OUT=$(bash "$QG" approve "$TID_R17_WELLFORMED" --no-design "k6re R17-F1 control A" --no-review "well-formed unrecorded artifact" "should refuse cleanly" 2>/dev/null) || RC=$?
assert_eq "8.15a CONTROL well-formed: approve refuses (exit 4)" "4" "$RC"
assert_eq "8.15a2 ...error_key=review_artifact_unrecorded" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

# 8.15b: CONTROL 2 — valid JSON, .iterations field absent entirely (distinct
# from malformed: this document PARSES, it just lacks one field).
TID_R17_NOITER=$(new_task "review-sep: R17-F1 control B, valid JSON no .iterations field" "src/r17noiter.ts")
NOITER_PATH="$(art_path_for "$TID_R17_NOITER" 1)"
mkdir -p "$(dirname "$NOITER_PATH")"
cat > "$NOITER_PATH" <<JSON
{"contract_version":"1","task_id":"$TID_R17_NOITER","reviewer_identity":"sol-codex","reviewer_model":"gpt-5.6-sol","reviewer_pin":"gpt-5.6-sol","reviewed_hash":"$(current_hash)","risk_threshold":"high","stop_condition":"x","verdict":"approve","findings":[],"stopped_by":"verdict"}
JSON
RC=0
OUT=$(bash "$QG" approve "$TID_R17_NOITER" --no-design "k6re R17-F1 control B" --no-review "valid JSON, no .iterations field" "should refuse cleanly" 2>/dev/null) || RC=$?
assert_eq "8.15b CONTROL no-iterations: approve refuses (exit 4)" "4" "$RC"
assert_eq "8.15b2 ...error_key=review_artifact_unrecorded (a missing FIELD is not a parse failure)" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

# 8.15c: THE DEFECT ITSELF — truncated mid-token, unparseable, but a real,
# hashable file at the canonical unrecorded path.
TID_R17_MALFORMED=$(new_task "review-sep: R17-F1 malformed-but-hashable unrecorded artifact" "src/r17malformed.ts")
MALFORMED_PATH="$(art_path_for "$TID_R17_MALFORMED" 1)"
mkdir -p "$(dirname "$MALFORMED_PATH")"
printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"sol-codex","iterat' "$TID_R17_MALFORMED" > "$MALFORMED_PATH"
RC=0
OUT=$(bash "$QG" approve "$TID_R17_MALFORMED" --no-design "k6re R17-F1" --no-review "malformed but hashable unrecorded artifact" "should refuse cleanly, not abort" 2>/dev/null) || RC=$?
assert_eq "8.15c THE FIX: malformed-but-hashable unrecorded artifact -> approve refuses (exit 4), not a bare set -e abort" \
    "4" "$RC"
assert_eq "8.15d ...the envelope is NOT empty (a bare abort under set -e produces zero bytes, exactly the pre-fix shape)" \
    "nonempty" "$([ -n "$OUT" ] && echo nonempty || echo empty)"
assert_eq "8.15e ...error_key=review_artifact_unrecorded, the SAME key both controls above report -- malformed content changes whether a refusal fires at all, not WHICH refusal fires" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8.15.M: META — the R17-F1 || true guard (unrecorded_content_iter) is load-bearing (claude-workflow-plugin-k6re R17-F1) ==="
QG_R17F1_STRIPPED="$FIXTURE/.claude/scripts/qa-gate-nor17f1.sh"
STRIP_R17F1_RC=0
# Anchored on the UNIQUE variable name `unrecorded_content_iter=`, not on the
# shared ` || true)` suffix several other guards in this file also end with —
# an unanchored pattern would revert all of them at once, the same "same-
# shaped text in multiple places doubles a mutation's footprint" class
# review-count.test.sh 15.9a2 already caught once, and precisely the
# discipline 8.12.M's own comment states for ITS anchor. The pattern is
# bounded to one physical line (`.` does not match newline in sed) and
# strips ONLY the trailing guard text, matching the "the region must contain
# only the guard" requirement — no sentinel-region strip is used here at
# all, so there is no region to accidentally over-scope.
sed 's/\(unrecorded_content_iter=.*\) || true$/\1/' "$QG" > "$QG_R17F1_STRIPPED"
# STRIP_R17F1_RC=$? MUST be the line immediately after the redirect above —
# see 8.12.M's own comment for why (capturing a LATER command's status here
# instead would make this META vacuous, the ybhc/R14-F5 shape).
STRIP_R17F1_RC=$?
assert_eq "8.15.M.0 META non-vacuity: sed itself exited 0 (the mutation step did not fail before ever reaching the content)" \
    "0" "$STRIP_R17F1_RC"
chmod +x "$QG_R17F1_STRIPPED"
assert_eq "8.15.M.1 META: the revert applied (mutant differs from source)" "differs" \
    "$(cmp -s "$QG" "$QG_R17F1_STRIPPED" && echo identical || echo differs)"
assert_eq "8.15.M.2 META: the revert touches EXACTLY one line" "1" \
    "$(diff "$QG" "$QG_R17F1_STRIPPED" | grep -c '^<')"
PARSE_RC=0
bash -n "$QG_R17F1_STRIPPED" 2>/dev/null || PARSE_RC=$?
assert_eq "8.15.M.3 META: reverted copy still parses" "0" "$PARSE_RC"

TID_R17M=$(new_task "review-sep: R17-F1 META, guard reverted" "src/r17meta.ts")
MALFORMED_META_PATH="$(art_path_for "$TID_R17M" 1)"
mkdir -p "$(dirname "$MALFORMED_META_PATH")"
printf '{"contract_version":"1","task_id":"%s","reviewer_identity":"sol-codex","iterat' "$TID_R17M" > "$MALFORMED_META_PATH"
RC=0
OUT=$(bash "$QG_R17F1_STRIPPED" approve "$TID_R17M" --no-design "k6re R17-F1 META" --no-review "reverted guard, malformed artifact" "should abort, not refuse cleanly" 2>/dev/null) || RC=$?
assert_eq "8.15.M.4 META, SPECIFIC MISBEHAVIOUR: WITHOUT the guard, set -e aborts with rc=5 (jq's own parse-error exit code, NOT gate's rc=4 -- a different signature than 8.12.M's mutant, because a different command fails)" \
    "5" "$RC"
assert_eq "8.15.M.5 ...but the envelope is COMPLETELY EMPTY -- the exact R17-F1 defect, reproduced" \
    "" "$OUT"

# Discriminator: the reverted mutant still refuses CLEANLY (not an abort) on
# a WELL-FORMED unrecorded artifact — the ordinary case this whole block
# exists for. Proves the revert's damage is scoped to the malformed-content
# path specifically (a well-formed file's .iterations extraction never
# fails, so removing the guard has no observable effect there), not a
# broken script overall — the same discriminating purpose 8.12.M.6/7 serves
# for its own mutant, adapted to hit the SAME loop/line this guard sits on
# rather than a different code path that would never reach it either way.
TID_R17_DISCRIM=$(new_task "review-sep: R17-F1 META discriminator, well-formed artifact" "src/r17discrim.ts")
plant_unrecorded "$TID_R17_DISCRIM" 1
RC=0
OUT=$(bash "$QG_R17F1_STRIPPED" approve "$TID_R17_DISCRIM" --no-design "k6re R17-F1 META discriminator" --no-review "well-formed artifact, reverted guard" "should still refuse cleanly" 2>/dev/null) || RC=$?
assert_eq "8.15.M.6 discriminator: the reverted mutant still refuses CLEANLY on a well-formed unrecorded artifact (exit 4)" "4" "$RC"
assert_eq "8.15.M.7 ...error_key=review_artifact_unrecorded" \
    "review_artifact_unrecorded" "$(printf '%s' "$OUT" | jq -r '.error_key' 2>/dev/null)"

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
