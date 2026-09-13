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
# claude-workflow-plugin-k6re (test-suite split, 2026-09-12): Sections 7
# through 8.14 — the UNRECORDED-REVIEW-ARTIFACT-REFUSAL family and its
# review-reconcile governance, added across independent review rounds 13-16
# — moved to unrecorded-review-artifact.test.sh. NOT a content change: the
# pre-split file (264 assertions total, confirmed via `bash
# review-separation.test.sh` run standalone to completion) splits into 94
# assertions staying here in Sections 1-6, and 170 moving to the companion
# file (167 call-sites there; the +3 is Section 8.3's own
# `for i in 3 1 4 2` loop around one assert_eq, which runs four times).
# Reason: this file alone had grown from 955 to 2146 lines (2.2x) across
# those rounds and crossed run-tests.sh's SPEC_TIMEOUT_S=900 per-spec
# watchdog cap under the tier's own contention — QA round 16 had already
# measured it at 227/227 assertions in 849s (94% of budget), and the
# round-16 fix-verification work (old Sections 8.12-8.14) pushed it over:
# the full L1 tier killed it at 250 assertions against the 900s cap, tree
# dc4a4c8d, 2026-09-10 16:25:52. Run standalone (no watchdog), the pre-split
# file completed all 264 assertions but took ~1000s real time — genuinely
# over budget, not merely close to it. Splitting restores real margin to
# both halves rather than raising a cap for a spec that had simply outgrown
# it. EXPECTED_SPECS in run-tests.sh moved 60 -> 61 in the same change. See
# unrecorded-review-artifact.test.sh's own header for the full account and
# the section-by-section table of contents for 7 through 8.14.
#
# Conventions mirror qa-gate-choose.test.sh / qa-gate-grade-record.test.sh:
# plain bash, `set -u`, local assert helpers, trailing summary, tempdir fixture
# with a pass-through bd shim, skip-with-log when bd is absent in CI.
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

# No BD_SHIM_ONLY skip arm any more (a9hh): CI installs the real bd, and a
# bd-less environment is a hard failure everywhere — 60 assertions that
# silently skip are how "nobody signs off on their own work" went unverified
# in the only environment that runs on every push.
if ! command -v bd >/dev/null 2>&1; then
    echo "bd CLI not on PATH — review-separation tests require Beads."
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
# Section 4.1 asserts the approval record spells `worktree=none` off a git
# checkout, so this fixture MUST NOT be one. bd 1.1.2's `bd init` runs
# `git init` (0.47.x did not), which silently satisfied `git rev-parse` and
# made the record carry a real path instead — the precondition was gone, not
# the behaviour. Drop the repo bd created rather than relaxing the assertion.
# `--skip-agents --skip-hooks` suppresses the CLAUDE.md/.claude scaffolding but
# NOT the git init, so removing it here is the only way back to a bare tempdir.
# bd itself is unaffected: the store is .beads/embeddeddolt, not git.
rm -rf "$FIXTURE/.git"
export CLAUDE_PROJECT_DIR="$FIXTURE"

QG="$FIXTURE/.claude/scripts/qa-gate.sh"
IR="$FIXTURE/.claude/scripts/impact-report.sh"
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
{"task_id":"$tid","role":"backend","model":"seeded","pin":"seeded","files_changed":["$file"],"tests_added":["review-separation.test.sh::seeded"],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the review-separation fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}
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
OUT=$(bash "$QG" approve "$TID_LOW" --no-design "fkm.4: testing review-separation, not design-satisfied" "one low nit, below threshold" 2>/dev/null) || RC=$?
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
OUT=$(bash "$QG" approve "$TID_OPEN" --no-design "fkm.4: testing review-separation, not design-satisfied" "finding resolved with evidence" 2>/dev/null) || RC=$?
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
OUT=$(bash "$QG" approve "$TID_ARB" --no-design "fkm.4: testing review-separation, not design-satisfied" "finding overruled with rationale" 2>/dev/null) || RC=$?
assert_eq "2.2 after arbitrate overrule: approve succeeds (exit 0)" "0" "$RC"
assert_eq "2.2 after arbitrate overrule: status=approved" \
    "approved" "$(printf '%s' "$OUT" | jq -r '.status')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2.3: the quarantine-artifact override has been REMOVED (claude-workflow-plugin-k6re, R2-F1) ==="
# HISTORY. R12-F1 introduced quarantine-artifact as the only recovery path
# for a malformed REVIEW-ARTIFACT candidate once review-check.sh's selector
# stopped inferring safety from comment position (R11-F1's own premise,
# falsified against the actual bd 1.2.2 source). Independent review round 2
# of THIS SAME TASK (R2-F1) found the RECOVERY mechanism itself forgeable:
# the comment stream carries no verifiable author, the reader matched a
# bare hash= prefix rather than the writer's full `at <ts>: <reason>`
# grammar, and a hand-typed comment or a `bd import` reaches the reader
# without ever calling this writer's own validation. Removed entirely
# rather than re-guarded. This section now drives that removal end to end,
# through the REAL `approve` and the now-absent `quarantine-artifact`
# command — unlike review-count.test.sh's offline --comments-json seam,
# which proves the SELECTOR logic in isolation.

sha256_of_stdin() {
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum 2>/dev/null | awk '{print $1}'
    fi
}

if [ -z "$(printf 'probe' | sha256_of_stdin)" ]; then
    echo "  SKIP: Section 2.3 (malformed-record permanent-refusal proof) — neither shasum nor sha256sum on PATH"
else
    # A malformed record injected DIRECTLY via `bd comments add`, bypassing
    # review-record's writer-side validation entirely — record_artifact's
    # helper goes through that REAL writer, which (since R11-F1) REJECTS a
    # non-integer `iterations` at write time, so it cannot produce this
    # fixture. This is exactly the shape a pre-writer-guard hand-typed
    # record, or a `bd import` carrying one, would leave behind.
    TID_QUAR=$(new_task "review-sep: malformed record has no recovery" "src/seven.ts")
    record_implementer "$TID_QUAR" "backend"
    # reviewer=sol-codex deliberately (not qa-claude): this is the identity
    # review-count.test.sh's own offline BAD_ITER fixture uses to prove the
    # malformed-refusal message never leaks it; using the SAME identity
    # here makes THIS live, end-to-end lane-purity check (below) non-vacuous
    # on its own — a leak has something real to leak, not merely an
    # absence of anything worth scrubbing.
    MALFORMED_LINE="REVIEW-ARTIFACT v1 iteration=abc reviewer=sol-codex model=test-model pin=test-model reviewed_hash=$(current_hash) risk_threshold=high verdict=approve stopped_by=verdict findings=[] artifact_hash=ah at $(date -u +%Y-%m-%dT%H:%M:%SZ): summary"
    bd comments add "$TID_QUAR" "$MALFORMED_LINE" >/dev/null 2>&1
    MALFORMED_HASH=$(printf '%s' "$MALFORMED_LINE" | sha256_of_stdin)

    # 2.3.1 CONTROL: approve refuses. No well-formed competitor exists yet
    # (11.9c's shape in review-count.test.sh), driven here through the REAL
    # approve path instead of the offline seam.
    RC=0
    OUT=$(bash "$QG" approve "$TID_QUAR" "shipping over a malformed review record" 2>/dev/null) || RC=$?
    assert_eq "2.3.1 malformed record blocks approve (exit 4)" "4" "$RC"
    assert_eq "2.3.1 ...error_key=review_artifact_iteration_unparseable" \
        "review_artifact_iteration_unparseable" "$(printf '%s' "$OUT" | jq -r '.error_key')"
    # 2.3.1b/c/d the remedy no longer names a recovery command — there is
    # none, and it says so.
    assert_not_contains "2.3.1b remediation no longer names quarantine-artifact (removed, R2-F1)" \
        "quarantine-artifact" "$OUT"
    assert_contains "2.3.1c remediation states the refusal is unconditional and permanent" \
        "refusing unconditionally and permanently" "$OUT"
    assert_contains "2.3.1d remediation names an operator repairing the store directly as the only remedy" \
        "operator must repair the underlying record directly in the store" "$OUT"
    # 2.3.1e/f LANE-PURITY, driven live through qa-gate.sh's remedy-relay,
    # not just review-check.sh's own offline observations field.
    # MALFORMED_LINE embeds reviewer=sol-codex, so the anti-vacuity leg
    # below is genuine — this fixture actually carries the substring the
    # guard forbids, somewhere for the relay to have leaked if it were not
    # scrubbed.
    assert_eq "2.3.1e anti-vacuity: the fixture genuinely embeds a sol-codex identity (something real to leak)" "1" \
        "$(printf '%s' "$MALFORMED_LINE" | grep -c 'sol-codex' || true)"
    assert_eq "2.3.1f STRUCTURAL: approve's full runtime JSON output never echoes it" "0" \
        "$(printf '%s' "$OUT" | grep -icE 'codex|reviewer[[:space:]_.-]*lane' || true)"

    # 2.3.2 THE REMOVAL ITSELF: qa-gate.sh no longer recognises
    # quarantine-artifact as a subcommand at all — a direct regression
    # guard on the removal, not just on its consequences.
    RC=0
    QOUT=$(bash "$QG" quarantine-artifact "$TID_QUAR" "$MALFORMED_HASH" "reason" 2>&1) || RC=$?
    assert_eq "2.3.2 quarantine-artifact is no longer a recognised subcommand (exit 1)" "1" "$RC"
    assert_contains "2.3.2b ...unknown-subcommand output" \
        "unknown subcommand: quarantine-artifact" "$QOUT"
    assert_eq "2.3.2c no REVIEW-ARTIFACT-QUARANTINE comment was posted (the unrecognised subcommand wrote nothing)" "0" \
        "$(printf '%s\n' "$(comments_of "$TID_QUAR")" | grep -cE '^REVIEW-ARTIFACT-QUARANTINE v1' || true)"

    # 2.3.3/2.3.3b THE NEGATIVE CONTROL (the important one, per R2-F1's own
    # framing): plant a comment matching the FULL, well-formed writer
    # grammar `cmd_quarantine_artifact` used to produce — not a bare
    # prefix, the complete `at <ts>: <reason>` shape a legitimate operator
    # invocation would have posted — naming the EXACT hash of the
    # malformed candidate above, via `bd comments add` directly (the writer
    # command that used to produce this exact text no longer exists to
    # call). approve must STILL refuse, with the SAME error_key as 2.3.1 —
    # proving the read side honours NO quarantine record, however
    # well-formed, rather than merely that a loosely-matched prefix was
    # tightened.
    WELLFORMED_QUARANTINE="REVIEW-ARTIFACT-QUARANTINE v1 hash=$MALFORMED_HASH at $(date -u +%Y-%m-%dT%H:%M:%SZ): verified via bd show --include-comments -- a synthetic test fixture, not a real review round"
    bd comments add "$TID_QUAR" "$WELLFORMED_QUARANTINE" >/dev/null 2>&1
    RC=0
    OUT=$(bash "$QG" approve "$TID_QUAR" "shipping over a malformed record with a well-formed quarantine posted" 2>/dev/null) || RC=$?
    assert_eq "2.3.3 NEGATIVE CONTROL: a full, well-formed REVIEW-ARTIFACT-QUARANTINE record excuses NOTHING (still exit 4)" \
        "4" "$RC"
    assert_eq "2.3.3b ...SAME error_key as 2.3.1 (review_artifact_iteration_unparseable) -- the malformed record still governs the refusal" \
        "review_artifact_iteration_unparseable" "$(printf '%s' "$OUT" | jq -r '.error_key')"

    # 2.3.4 ANTI-OVERREACH: an ordinary, entirely well-formed task (no
    # malformed record anywhere in its history) still approves cleanly —
    # this removal only removes a forgeable escape hatch, not the ordinary
    # path. Created via new_task AFTER every approve call above that
    # depends on TID_QUAR's own impact report, so overwriting the ONE
    # SHARED $TRACK/changed-files.txt here cannot stale it out from under
    # 2.3.1/2.3.3 (the same hazard 2.3.3's predecessor in this section
    # documented and avoided).
    TID_QUAR_CLEAN=$(new_task "review-sep: quarantine removal does not affect a clean task" "src/eight.ts")
    record_implementer "$TID_QUAR_CLEAN" "backend"
    record_artifact "$TID_QUAR_CLEAN" "qa-claude" "[]"
    RC=0
    OUT=$(bash "$QG" approve "$TID_QUAR_CLEAN" --no-design "fkm.4: testing review-separation, not design-satisfied" \
        "ordinary clean approval, unaffected by the quarantine removal" 2>/dev/null) || RC=$?
    assert_eq "2.3.4 anti-overreach: an ordinary well-formed task still approves cleanly (exit 0)" "0" "$RC"
    assert_eq "2.3.4b ...status=approved" "approved" "$(printf '%s' "$OUT" | jq -r '.status')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2.4: R3-F1 (Sol/Codex k6re round 3) driven end to end through the REAL approve / resolve-finding ==="
# review-count.test.sh's Section 4c proves the FIX in isolation, against
# review-check.sh's `gate` subcommand directly. This section proves the
# SAME fix through the two REAL consumers this task's own family-fix
# requirement named: qa-gate.sh's `approve` (wired to `gate`) and
# `resolve-finding` (wired to finding_id_in_latest_artifact's OWN
# independent anchored re-implementation). Both matter: fixing review-
# check.sh alone would leave resolve-finding/arbitrate reading the SAME
# vulnerable `sed -nE 's/.*findings=\[([^]]*)\].*/\1/p'` this task's family-
# fix requirement explicitly calls out enumerating and fixing.
#
# A WELL-FORMED record — findings=[R1-F1:high] closes correctly,
# artifact_hash= and at <ts>: both present and well-formed — whose free-text
# summary merely mentions `findings=[]` as prose. No malformed input
# anywhere; injected via `bd comments add` (the same hand-typed/bd-import
# channel Section 2.3 above already established reaches this file's read
# path directly, bypassing review-record's own writer-side validation).
TID_R3F1=$(new_task "review-sep: R3-F1 prose-confusion reproduction" "src/nine.ts")
record_implementer "$TID_R3F1" "backend"
R3F1_LINE="REVIEW-ARTIFACT v1 iteration=1 reviewer=sol-codex model=test-model pin=test-model reviewed_hash=$(current_hash) risk_threshold=high verdict=findings stopped_by=verdict findings=[R1-F1:high] artifact_hash=ah at $(date -u +%Y-%m-%dT%H:%M:%SZ): fixed the bug where findings=[R9-F9:critical] was mis-parsed as findings=[]"
bd comments add "$TID_R3F1" "$R3F1_LINE" >/dev/null 2>&1

# 2.4.1 approve must refuse, naming the REAL open finding — not silently
# succeed as it did pre-fix (ART_FINDINGS read back "" and open_findings=0).
RC=0
OUT=$(bash "$QG" approve "$TID_R3F1" --no-design "fkm.4: testing review-separation, not design-satisfied" \
    "shipping over what should be an open HIGH" 2>/dev/null) || RC=$?
assert_eq "2.4.1 THE REPRODUCTION, live through approve: exit 4 (NOT the pre-fix silent exit 0)" "4" "$RC"
assert_eq "2.4.1b ...error_key=unresolved_findings" \
    "unresolved_findings" "$(printf '%s' "$OUT" | jq -r '.error_key')"
assert_contains "2.4.1c ...refusal names the real open finding id R1-F1" "R1-F1" "$OUT"

# 2.4.2 resolve-finding on the REAL id must succeed — proving
# finding_id_in_latest_artifact's own independent anchored re-implementation
# (qa-gate.sh) finds R1-F1 despite the adversarial summary, not merely that
# review-check.sh's gate does.
RC=0
OUT=$(bash "$QG" resolve-finding "$TID_R3F1" R1-F1 \
    --fix "commit:deadbeef src/nine.ts:1" \
    --test "review-separation.test.sh::section-2.4" \
    "verified real, fixed with evidence" 2>/dev/null) || RC=$?
assert_eq "2.4.2 resolve-finding on the real id R1-F1 succeeds (exit 0)" "0" "$RC"
assert_eq "2.4.2b ...status=resolved" "resolved" "$(printf '%s' "$OUT" | jq -r '.status')"

# 2.4.3 DISCRIMINATOR: resolve-finding on the FAKE id the summary
# mentions (R9-F9, which never appears in the real findings=[...] token)
# must still be refused as finding_id_not_found — proving 2.4.2 succeeded
# because R1-F1 is genuinely in the anchored token, not because this
# build accepts any id.
RC=0
OUT=$(bash "$QG" resolve-finding "$TID_R3F1" R9-F9 \
    --fix "commit:deadbeef src/nine.ts:1" \
    --test "review-separation.test.sh::section-2.4" \
    "should not exist" 2>/dev/null) || RC=$?
assert_eq "2.4.3 discriminator: an id the summary mentions but the real token never carried is refused (exit 1)" "1" "$RC"
assert_eq "2.4.3b ...error_key=finding_id_not_found" \
    "finding_id_not_found" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2.4b: R4-F1 (Sol/Codex k6re round 4) — finding_id_in_latest_artifact must normalize each comment to its first line before selecting, exactly as review-check.sh's cmd_gate does ==="
# Section 2.4 above proved R3-F1's PARSE-BOUNDARY anchor (ART_PREFIX) closes
# the greedy-sed / prose-mention class. R4-F1 is the layer UNDER that one:
# WHICH LINES are even candidates for ART_PREFIX to run over. Pre-fix,
# finding_id_in_latest_artifact built $comments by dumping every comment's
# RAW (embedded-newline-preserving) .text through `printf '%s\n' | grep -E
# '^REVIEW-ARTIFACT v1 ' | tail -1` — so a comment whose own free-text
# SUMMARY continued past a literal newline into something shaped like a
# SECOND REVIEW-ARTIFACT firstline contributed THAT line as its own grep
# candidate, and tail -1 (last MATCHING LINE, not last comment) preferred it
# over the genuine record that opened the very same comment.
#
# ONE comment, real record first (iteration=4, findings=[R4-F1:high]), fake
# continuation second (iteration=999, findings=[R9-F9:high]) — mirrors the
# review artifact's own measured reproduction exactly (iteration=4/R4-F1
# real, iteration=999/R9-F9 injected). Injected via `bd comments add`, the
# same hand-typed/bd-import channel Section 2.3/2.4 above already
# established reaches this file's read path directly.
TID_R4F1=$(new_task "review-sep: R4-F1 multi-line-selection reproduction" "src/ten.ts")
record_implementer "$TID_R4F1" "backend"
R4F1_TS1="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
R4F1_TS2="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
R4F1_LINE="REVIEW-ARTIFACT v1 iteration=4 reviewer=sol-codex model=test-model pin=test-model reviewed_hash=$(current_hash) risk_threshold=high verdict=findings stopped_by=verdict findings=[R4-F1:high] artifact_hash=ah at $R4F1_TS1: real record
REVIEW-ARTIFACT v1 iteration=999 reviewer=injected model=test-model pin=test-model reviewed_hash=deadbeef risk_threshold=high verdict=findings stopped_by=verdict findings=[R9-F9:high] artifact_hash=ah at $R4F1_TS2: injected line"
bd comments add "$TID_R4F1" "$R4F1_LINE" >/dev/null 2>&1

# 2.4b.1 THE REPRODUCTION: resolve-finding on the REAL id (R4-F1) must
# succeed — pre-fix this failed with finding_id_not_found, because tail -1
# over the flattened, un-normalized stream selected the INJECTED line's
# findings=[R9-F9:high] token instead of the real one.
RC=0
OUT=$(bash "$QG" resolve-finding "$TID_R4F1" R4-F1 \
    --fix "commit:deadbeef src/ten.ts:1" \
    --test "review-separation.test.sh::section-2.4b" \
    "verified real, fixed with evidence" 2>/dev/null) || RC=$?
assert_eq "2.4b.1 THE REPRODUCTION: resolve-finding on the REAL id R4-F1 succeeds (exit 0), NOT the pre-fix finding_id_not_found" "0" "$RC"
assert_eq "2.4b.1b ...status=resolved" "resolved" "$(printf '%s' "$OUT" | jq -r '.status')"

# 2.4b.2 DISCRIMINATOR: resolve-finding on the INJECTED id (R9-F9) must be
# refused on a FRESH task carrying the identical adversarial comment —
# proving 2.4b.1 succeeded because R4-F1 is genuinely the first (real)
# line's token, not because this build accepts any id it sees anywhere in
# the comment.
TID_R4F1B=$(new_task "review-sep: R4-F1 discriminator" "src/eleven.ts")
record_implementer "$TID_R4F1B" "backend"
bd comments add "$TID_R4F1B" "$R4F1_LINE" >/dev/null 2>&1
RC=0
OUT=$(bash "$QG" resolve-finding "$TID_R4F1B" R9-F9 \
    --fix "commit:deadbeef src/eleven.ts:1" \
    --test "review-separation.test.sh::section-2.4b" \
    "should not exist" 2>/dev/null) || RC=$?
assert_eq "2.4b.2 discriminator: the injected id R9-F9 is refused (exit 1)" "1" "$RC"
assert_eq "2.4b.2b ...error_key=finding_id_not_found" \
    "finding_id_not_found" "$(printf '%s' "$OUT" | jq -r '.error_key')"

# 2.4b.3 ANTI-OVERREACH: an ORDINARY, single-line, well-formed record (no
# embedded newline anywhere) still resolves correctly — the fix must not
# regress the common case.
TID_R4F1C=$(new_task "review-sep: R4-F1 anti-overreach (ordinary single-line record)" "src/twelve.ts")
record_implementer "$TID_R4F1C" "backend"
record_artifact "$TID_R4F1C" "sol-codex" \
    '[{"id":"R1-F1","severity":"high","location":"src/twelve.ts:1","evidence":"ordinary finding, no adversarial shape","description":"plain"}]'
RC=0
OUT=$(bash "$QG" resolve-finding "$TID_R4F1C" R1-F1 \
    --fix "commit:deadbeef src/twelve.ts:1" \
    --test "review-separation.test.sh::section-2.4b" \
    "ordinary resolution" 2>/dev/null) || RC=$?
assert_eq "2.4b.3 ANTI-OVERREACH: an ordinary well-formed record still resolves (exit 0)" "0" "$RC"
assert_eq "2.4b.3b ...status=resolved" "resolved" "$(printf '%s' "$OUT" | jq -r '.status')"

# 2.4b.4 META: REVERT THE NORMALIZATION, WATCH THE INJECTED LINE GET
# SELECTED AGAIN. The single textual change R4-F1 made was appending
# `| split("\n")[0]` to finding_id_in_latest_artifact's jq filter.
# Reverting JUST that, in a mutant copy of qa-gate.sh, must bring the
# EXACT pre-fix behaviour back on the SAME adversarial comment: the real
# id refused, the injected id accepted — proving the one-line addition
# itself (not some other guard) is what is load-bearing here.
REVERT_R4F1_SED="$FIXTURE/.claude/.qa-tracking/revert-r4f1.sed"
cat > "$REVERT_R4F1_SED" <<'SEDEOF'
s/ | (\.\[\]?\.text \/\/ empty) | split("\\n")\[0\]'/ | (.[]?.text \/\/ empty)'/
SEDEOF
MUTANT_R4F1="$FIXTURE/.claude/scripts/qa-gate-revert-r4f1.sh"
sed -f "$REVERT_R4F1_SED" "$QG" > "$MUTANT_R4F1"
chmod +x "$MUTANT_R4F1"
assert_eq "2.4b.4a META: the revert mutation applied (mutant differs from the fixed source)" "differs" \
    "$(cmp -s "$QG" "$MUTANT_R4F1" && echo identical || echo differs)"
assert_eq "2.4b.4b META: mutated script parses" "0" \
    "$(bash -n "$MUTANT_R4F1" 2>/dev/null && echo 0 || echo 1)"

TID_R4F1_META=$(new_task "review-sep: R4-F1 META revert" "src/thirteen.ts")
record_implementer "$TID_R4F1_META" "backend"
bd comments add "$TID_R4F1_META" "$R4F1_LINE" >/dev/null 2>&1

RC=0
OUT=$(bash "$MUTANT_R4F1" resolve-finding "$TID_R4F1_META" R4-F1 \
    --fix "commit:deadbeef src/thirteen.ts:1" \
    --test "review-separation.test.sh::section-2.4b" \
    "should now fail against the mutant" 2>/dev/null) || RC=$?
assert_eq "2.4b.4c META: WITHOUT the normalization, the REAL id R4-F1 is wrongly refused (exit 1) — the R4-F1 defect, reproduced" \
    "1" "$RC"
assert_eq "2.4b.4d META: ...error_key=finding_id_not_found" \
    "finding_id_not_found" "$(printf '%s' "$OUT" | jq -r '.error_key')"

RC=0
OUT=$(bash "$MUTANT_R4F1" resolve-finding "$TID_R4F1_META" R9-F9 \
    --fix "commit:deadbeef src/thirteen.ts:1" \
    --test "review-separation.test.sh::section-2.4b" \
    "should now wrongly succeed against the mutant" 2>/dev/null) || RC=$?
assert_eq "2.4b.4e META: WITHOUT the normalization, the INJECTED id R9-F9 is wrongly ACCEPTED (exit 0) — the forgery this fix closes" \
    "0" "$RC"
assert_eq "2.4b.4f META: ...status=resolved (forged finding id accepted as real)" \
    "resolved" "$(printf '%s' "$OUT" | jq -r '.status')"

# Discriminator: the mutant still runs the real predicate elsewhere (an
# ordinary record with no adversarial second line is unaffected by this
# one substitution), so the difference above is the normalization and
# nothing else.
TID_R4F1_METADISC=$(new_task "review-sep: R4-F1 META discriminator" "src/fourteen.ts")
record_implementer "$TID_R4F1_METADISC" "backend"
record_artifact "$TID_R4F1_METADISC" "sol-codex" \
    '[{"id":"R1-F1","severity":"high","location":"src/fourteen.ts:1","evidence":"ordinary finding, no adversarial shape","description":"plain"}]'
RC=0
OUT=$(bash "$MUTANT_R4F1" resolve-finding "$TID_R4F1_METADISC" R1-F1 \
    --fix "commit:deadbeef src/fourteen.ts:1" \
    --test "review-separation.test.sh::section-2.4b" \
    "ordinary resolution against the mutant" 2>/dev/null) || RC=$?
assert_eq "2.4b.4g discriminator: the mutant still resolves an UNRELATED ordinary record correctly (exit 0) — ran the real predicate" \
    "0" "$RC"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: the audited --no-review bypass ==="

TID_BYP=$(new_task "review-sep: audited bypass" "src/six.ts")
record_implementer "$TID_BYP" "backend"
RC=0
OUT=$(bash "$QG" approve "$TID_BYP" \
    --no-review "docs-only follow-up; nothing reviewable changed" \
    --no-design "fkm.4: testing the review bypass, not design-satisfied" \
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
bash "$QG" approve "$TID_REC" --no-design "fkm.4: testing the approval-record grammar, not design-satisfied" "clean independent review" >/dev/null 2>&1
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
# claude-workflow-plugin-rqer / fkm.4 (v5 D2): the token order is
# change_set_hash, reviewed_by, worktree, [design_hash], artifact_hash,
# [design_verdict_hash], at <ts> — verbatim from cmd_approve's add_comment
# interpolation ("${hash_field}reviewed_by=$reviewed_by ${worktree_field}${design_field}${review_file_hash_field}${design_verdict_field}at $ts: ").
# No design binding is established in this scenario (--no-design was passed
# above), so BOTH design_hash and design_verdict_hash are absent, but the
# review-artifact binding IS established (record_artifact ran above), so
# artifact_hash= is present and sits directly before `at`.
assert_match "4.1 approval record grammar (hash, reviewed_by, worktree, timestamp)" \
    "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude worktree=[^ ]+ artifact_hash=[0-9a-f]{64} at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: " \
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
# (The jq below is byte-identical to the hook's; only the transport in front of
# it gained --include-comments, in both places, for bd 1.1.2.)
#
# claude-workflow-plugin-yrij (APPROVAL-SELECTOR-ANCHOR): the hook's selector
# is now anchored at `^` (a comment whose first line was prose and whose
# LATER line fabricated a record used to satisfy the old unanchored form).
# Updated here to stay byte-identical, per this section's own stated
# purpose — this is the ONE assertion in the suite that explicitly claims to
# run the hook's real expression rather than a paraphrase of it, so leaving
# it stale would make that claim false the moment the fix landed.
REC_CAPTURED=$(bd_show_with_comments "$TID_REC" \
    | jq -r '(if type == "array" then .[0].comments else .comments end) // []
             | .[].text
             | select(test("^QA-GATE APPROVED .*change_set_hash="))
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
# The copy lives in the fixture's `.claude/scripts/` — NOT the fixture root.
# Since 94d qa-gate.sh loads `workflow-denylist.sh` from its OWN directory
# (BASH_SOURCE-relative), so a copy parked anywhere else has no denylist,
# reconcile_tracker refuses, and approve exits 2 for a reason that has nothing
# to do with the region under test. Same constraint the post-edit.sh component
# spec's META already documents for its mutant.
QG_NOTOKEN="$FIXTURE/.claude/scripts/qa-gate-noworktreetoken.sh"
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
    bash "$QG_NOTOKEN" approve "$TID_NOTOK" --no-design "fkm.4: testing the worktree-token region, not design-satisfied" "clean independent review" >/dev/null 2>&1
    NOTOK_CMT=$(comments_of "$TID_NOTOK" | grep 'QA-GATE APPROVED' | tail -1)

    assert_not_contains "4.2b META: the stripped writer emits NO worktree token" \
        "worktree=" "$NOTOK_CMT"
    # The pre-3mg.2 grammar, exactly — no dangling token, no double space.
    # claude-workflow-plugin-rqer (v5 D2): only the WORKTREE-TOKEN region was
    # stripped from this copy; the review-artifact-hash binding (a SEPARATE
    # sentinel region — qa-gate.sh's REVIEW-ARTIFACT-BINDING-TOKEN block) is
    # untouched, so record_artifact's real review-record binding still
    # verifies and artifact_hash= still lands directly before `at`.
    assert_match "4.2b META: ...and the record is otherwise byte-shaped as v3.5" \
        "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude artifact_hash=[0-9a-f]{64} at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: " \
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
# In `.claude/scripts/`, not the fixture root — see the note on QG_NOTOKEN above
# (94d made qa-gate.sh resolve workflow-denylist.sh from its own directory).
QG_STRIPPED="$FIXTURE/.claude/scripts/qa-gate-noreviewsep.sh"
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
    OUT=$(bash "$QG_STRIPPED" approve "$TID_META" --no-design "fkm.4: testing REVIEW-SEPARATION, not design-satisfied" "stripped copy must NOT refuse" 2>/dev/null) || RC=$?
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
