#!/bin/bash
# beads-ledger.sh — L2 component spec for the JSONL ledger guards
# (claude-workflow-plugin-fkm.1.1).
#
# WHAT THIS PROVES
# ----------------
# bd 1.1.2 removed `bd sync`, which was the workflow's ONLY ledger-write path.
# The failure it caused is the worst shape available: silent. Every commit kept
# recording a stale .beads/issues.jsonl behind a green pre-commit hook, and the
# loss only surfaces at the next clone, as missing issues.
#
# What replaced it is DETECTION plus an explicit operator repair — NOT an
# automatic write. A classifier-driven auto-repair was tried and removed
# (R4-F1): it produced five defects, each an evidence rule whose claim was
# weaker than the safety property it authorised. So this spec pins four
# surfaces, and the shape of all four is "notice and report", never "fix":
#
#   1. beads-ledger.sh itself — the divergence detector (`check`, read-only),
#                                plus two writers that are DRY RUN unless
#                                --apply and are never invoked by a hook.
#   2. session-end.sh          — DETECTS a divergence at the normal exit and
#                                writes nothing; records it to sync-errors.log.
#   3. session-start.sh        — DETECTS a divergence in either direction,
#                                writes nothing, and surfaces it as a warning
#                                naming `reconcile --apply`.
#   4. workflow-doctor.sh      — the named `beads_ledger` check, so a diverged
#                                ledger fails a check instead of a clone.
#
# Repair is always deliberate: `beads-ledger.sh reconcile --apply`, which the
# Landing-the-Plane protocol in AGENTS.md runs around `git pull`.
#
# THE TWO ASSERTIONS THAT MATTER MOST:
#   * Section 2's comment-only mutation. The tempting cheap predicate is
#     "compare record counts", and it is WRONG: adding a comment changes the
#     ledger while leaving the count identical, and comments are where every
#     QA-gate record lives (approvals, rubric verdicts, IMPLEMENTER identity).
#     Asserted directly, with the count pinned EQUAL on both sides so it cannot
#     pass for the wrong reason.
#   * Section 11's negative control. It fails if any hook reacquires the
#     ability to write the ledger — the guard against someone restoring the
#     convenience and reintroducing the whole five-member family.
#
# METAs prove the guards bite before they are trusted: section 5 moves the one
# variable (ledger content) and watches the doctor check go PASS -> FAIL ->
# PASS; section 11 plants a `reconcile --apply` in SessionStart and watches the
# negative control flip.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

LEDGER_SH="$FIXTURE/.claude/scripts/beads-ledger.sh"
LEDGER="$FIXTURE/.beads/issues.jsonl"

lg() { CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LEDGER_SH" "$@" 2>/dev/null; }
lg_rc() { CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LEDGER_SH" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
ledger_lines() { [ -f "$LEDGER" ] && wc -l < "$LEDGER" | tr -d ' ' || printf '0'; }
sha_of() { [ -f "$1" ] && shasum -a 256 "$1" | awk '{print $1}' || printf ''; }

assert_eq "beads-ledger 0: the helper is installed in the fixture" "yes" \
    "$([ -f "$LEDGER_SH" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: the predicate on a virgin workspace ==="

# mk_fixture runs `bd init` and nothing else, so the DB is empty. bd does NOT
# create an issues.jsonl at init time — and "no ledger, no records" is NOT
# staleness: a clone recovers zero issues, which is correct. Getting this wrong
# would fail the doctor on every freshly-installed target.
assert_eq "beads-ledger 1.1: an empty DB with no ledger reads FRESH (exit 0)" "0" "$(lg_rc check)"
assert_contains "beads-ledger 1.2: ...and says why, rather than reporting a phantom staleness" \
    "nothing to export" "$(lg check)"
assert_eq "beads-ledger 1.3: a virgin workspace has no ledger and nothing invents one" "no" \
    "$([ -f "$LEDGER" ] && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: staleness detection ==="

TID=$(cd "$FIXTURE" && bd create "ledger probe" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "beads-ledger 2.0: seed task created" "$BD_ID_RE" "$TID"

# A record exists and no ledger does -> a clone would lose it.
assert_eq "beads-ledger 2.1: a record with no ledger is STALE (exit 1)" "1" "$(lg_rc check)"
assert_contains "beads-ledger 2.2: ...and names what a clone could not recover" \
    "no clone could recover" "$(lg check)"

# An EXPLICIT write materialises it, and check then agrees. Two things are
# being pinned here: that --apply is required at all (R4-F1 — nothing writes
# without it), and that `export` is the right command for FIRST creation
# specifically, because there is no ledger yet and so nothing it could discard.
assert_eq "beads-ledger 2.3a: export WITHOUT --apply is a dry run and creates nothing" "no" \
    "$(lg export >/dev/null 2>&1; [ -f "$LEDGER" ] && echo yes || echo no)"
assert_eq "beads-ledger 2.3: export --apply exits 0" "0" "$(lg_rc export --apply)"
assert_eq "beads-ledger 2.4: ...and the ledger now exists" "yes" \
    "$([ -f "$LEDGER" ] && echo yes || echo no)"
assert_eq "beads-ledger 2.5: ...and check now reads FRESH" "0" "$(lg_rc check)"

# THE COUNT-BLIND CASE. Add a COMMENT only: the record count does not move, but
# the ledger content does, because issues.jsonl carries comment bodies. A
# count- or mtime-based proxy passes here; the hash comparison must not.
LINES_BEFORE=$(ledger_lines)
(cd "$FIXTURE" && bd comments add "$TID" "ledger-sensitivity-probe" >/dev/null 2>&1) || true
assert_eq "beads-ledger 2.6: a comment-only write is STALE (exit 1)" "1" "$(lg_rc check)"
# Pin the counts EQUAL on both sides, so 2.6 cannot be passing because the
# record count happened to change.
LG_JSON=$(lg check --json)
assert_eq "beads-ledger 2.7: ...THE POINT — the record count did NOT change, so a count proxy would have said FRESH" \
    "$LINES_BEFORE" "$(ledger_lines)"
assert_json_field "beads-ledger 2.8: ...and the envelope reports status=stale" \
    "$LG_JSON" '.status' "stale"

assert_eq "beads-ledger 2.9: reconcile --apply clears it again" "0" "$(lg_rc reconcile --apply)"
assert_eq "beads-ledger 2.10: ...and the comment is now IN the ledger" "1" \
    "$(grep -c 'ledger-sensitivity-probe' "$LEDGER" 2>/dev/null | tr -d ' ')"

# `check` must never write. Everything it needs goes to a temp file OUTSIDE the
# target — the doctor's read-only claim depends on this.
BEADS_SHA_BEFORE=$(find "$FIXTURE/.beads" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort | shasum -a 256 | awk '{print $1}')
lg check >/dev/null 2>&1 || true
BEADS_SHA_AFTER=$(find "$FIXTURE/.beads" -type f -exec shasum -a 256 {} \; 2>/dev/null | sort | shasum -a 256 | awk '{print $1}')
assert_eq "beads-ledger 2.11: check is READ-ONLY — every file under .beads/ is byte-identical after it" \
    "$BEADS_SHA_BEFORE" "$BEADS_SHA_AFTER"

# Undetermined is its own outcome and is NOT reported as fresh.
assert_eq "beads-ledger 2.12: with bd off PATH the result is undetermined (exit 2), never a false FRESH" \
    "2" "$(env PATH=/usr/bin:/bin CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LEDGER_SH" check >/dev/null 2>&1; printf '%s' "$?")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: session-end.sh DETECTS a divergence and writes nothing (R4-F1) ==="

# session-end used to write the ledger — first via a direction-blind `export`,
# then via the classifier-driven `refresh`. Both are gone. Five defects came out
# of letting a classifier verdict authorise an unattended write, so the hook now
# records the condition and leaves the file alone.

(cd "$FIXTURE" && bd create "post-sessionend record" -t task -p 2 --json >/dev/null 2>&1) || true
assert_eq "beads-ledger 3.1: precondition — the new record makes the two sides differ" "1" "$(lg_rc check)"
SE_SHA_BEFORE=$(sha_of "$LEDGER")
SE_OUT=$(cd "$FIXTURE" && CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/session-end.sh" 2>/dev/null || true)
assert_eq "beads-ledger 3.2: session-end.sh still emits a {} envelope" "{}" \
    "$(printf '%s' "$SE_OUT" | tr -d '[:space:]')"
assert_eq "beads-ledger 3.3: THE REMOVAL — session-end wrote NOTHING; the ledger is byte-identical" \
    "$SE_SHA_BEFORE" "$(sha_of "$LEDGER")"
assert_eq "beads-ledger 3.4: ...so the divergence is still there for a human to resolve" "1" "$(lg_rc check)"
SE_ERRLOG="$FIXTURE/.claude/.qa-tracking/sync-errors.log"
assert_eq "beads-ledger 3.5: ...and it was RECORDED rather than silently skipped" "1" \
    "$([ -f "$SE_ERRLOG" ] && grep -c 'ledger NOT written' "$SE_ERRLOG" 2>/dev/null | tr -d ' ' || echo 0)"
assert_contains "beads-ledger 3.6: ...naming the explicit command that repairs it" \
    "reconcile --apply" "$([ -f "$SE_ERRLOG" ] && cat "$SE_ERRLOG" || echo "")"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: session-start.sh DETECTS and warns, and writes nothing (R4-F1) ==="

# Simulate a session that died before SessionEnd: mutate the DB, do not export.
(cd "$FIXTURE" && bd create "record from a crashed session" -t task -p 2 --json >/dev/null 2>&1) || true
assert_eq "beads-ledger 4.1: precondition — the two sides differ, as after a crash" "1" "$(lg_rc check)"
SS_SHA_BEFORE=$(sha_of "$LEDGER")
SS_OUT=$(cd "$FIXTURE" && printf '%s' '{}' \
    | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/session-start.sh" 2>/dev/null || true)
SS_CTX=$(printf '%s' "$SS_OUT" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || echo "")
assert_eq "beads-ledger 4.2: THE REMOVAL — SessionStart wrote NOTHING; the ledger is byte-identical" \
    "$SS_SHA_BEFORE" "$(sha_of "$LEDGER")"
assert_eq "beads-ledger 4.3: ...and the divergence is still there, unrepaired, for a human" "1" "$(lg_rc check)"
# The warning names the DIRECTION on purpose (R1-F1): "stale" alone was the word
# that let a ledger-ahead divergence be reported as a database-ahead one.
assert_contains "beads-ledger 4.4: ...but it is SURFACED, naming the direction" \
    "is BEHIND the local Beads database" "$SS_CTX"
assert_contains "beads-ledger 4.5: ...and says plainly that nothing was changed" \
    "NOTHING WAS CHANGED" "$SS_CTX"
assert_contains "beads-ledger 4.6: ...and names the explicit repair command" \
    "reconcile --apply" "$SS_CTX"

# CONTROL: a fresh ledger must NOT cry wolf.
lg reconcile --apply >/dev/null 2>&1 || true
SS_OUT2=$(cd "$FIXTURE" && printf '%s' '{}' \
    | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/session-start.sh" 2>/dev/null || true)
SS_CTX2=$(printf '%s' "$SS_OUT2" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || echo "")
assert_not_contains "beads-ledger 4.7: CONTROL — a fresh ledger produces no divergence warning" \
    "is BEHIND the local Beads database" "$SS_CTX2"

# 4b. The OTHER direction at the SessionStart surface: a ledger-ahead state must
# be warned about and NOT repaired, and the operator must not be told to commit.
printf '%s\n' '{"id":"ss-ghost-ahead","title":"only in the ledger","status":"open","issue_type":"task","priority":2}' >> "$LEDGER"
SS_LEDGER_SHA=$(sha_of "$LEDGER")
SS_OUT3=$(cd "$FIXTURE" && printf '%s' '{}' \
    | CLAUDE_PROJECT_DIR="$FIXTURE" bash "$FIXTURE/.claude/scripts/session-start.sh" 2>/dev/null || true)
SS_CTX3=$(printf '%s' "$SS_OUT3" | jq -r '.hookSpecificOutput.additionalContext // ""' 2>/dev/null || echo "")
assert_eq "beads-ledger 4.8: a ledger-ahead state is left byte-identical too" \
    "$SS_LEDGER_SHA" "$(sha_of "$LEDGER")"
assert_contains "beads-ledger 4.9: ...and is warned about as a DIVERGENCE" "DIVERGE" "$SS_CTX3"
assert_contains "beads-ledger 4.10: ...warning against the one-way export specifically" \
    "Do NOT run" "$SS_CTX3"
assert_not_contains "beads-ledger 4.11: ...and NOT telling the operator to commit a deletion" \
    "commit it with your next change" "$SS_CTX3"
lg reconcile --apply >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: the workflow-doctor beads_ledger check (META) ==="

DOCTOR="$FIXTURE/.claude/scripts/workflow-doctor.sh"
# Only the one check, so the run is fast and the verdict is unambiguous.
SKIP_ALL_BUT="deps,agents,skill,mcp_config,settings_hooks,beads,session_start,mcp_bd,mcp_code_graph,gate_pretooluse,gate_stop"
doctor_ledger_status() {
    CLAUDE_PROJECT_DIR="$FIXTURE" bash "$DOCTOR" --target "$FIXTURE" --skip "$SKIP_ALL_BUT" 2>/dev/null \
        | grep -E '(PASS|FAIL|SKIP)[[:space:]]+beads_ledger' | awk '{print $1}' | head -1
}

assert_eq "beads-ledger 5.1: registry — the doctor declares beads_ledger" "1" \
    "$(sed -n 's/^DOCTOR_CHECK_NAMES="\(.*\)"$/\1/p' "$DOCTOR" | head -1 | tr ' ' '\n' | grep -cx 'beads_ledger' | tr -d ' ')"
assert_eq "beads-ledger 5.2: with a FRESH ledger the check PASSes" "PASS" "$(doctor_ledger_status)"

# THE META: move exactly one variable — the ledger's content — and the same
# check must flip. Appending a record the DB does not have is the cheapest
# honest way to desynchronise the two without touching the database.
cp "$LEDGER" "$FIXTURE/.beads/issues.jsonl.specbak"
printf '{"id":"ghost-000","title":"not in the database","status":"open"}\n' >> "$LEDGER"
assert_eq "beads-ledger 5.3: META — a desynchronised ledger FAILs the check" "FAIL" "$(doctor_ledger_status)"
mv "$FIXTURE/.beads/issues.jsonl.specbak" "$LEDGER"
assert_eq "beads-ledger 5.4: META restore control — putting it back makes the check PASS again" \
    "PASS" "$(doctor_ledger_status)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: DIRECTION — the ledger-ahead states must never be overwritten (R1-F1) ==="

# The first version of this helper compared sha256 only and resolved every
# difference as "the database wins", because the failure it was built for
# (SessionEnd skipped) always has that direction. Three ordinary states have the
# OPPOSITE direction, and all three were silently destroyed:
#   * a fresh clone, where `bd init` leaves an EMPTY database beside a fully
#     populated committed ledger;
#   * any second machine after `git pull`;
#   * a restored backup.
# bd 1.1.2 never auto-imports a newer ledger, so nothing else catches it. These
# assertions are the regression wall: the mechanism built to stop the ledger
# being silently LOST must not silently DESTROY it.

# 6a. Ledger-ahead by one record the database has never seen. Same ghost-record
# trick section 5 uses to desynchronise the two sides.
lg reconcile --apply >/dev/null 2>&1 || true   # start from fresh
GHOST='{"id":"ghost-ahead-001","title":"a record only the ledger has","status":"open","issue_type":"task","priority":2}'
printf '%s\n' "$GHOST" >> "$LEDGER"
LEDGER_SHA_BEFORE=$(sha_of "$LEDGER")
assert_eq "beads-ledger 6.1: a ledger-ahead divergence is its OWN outcome, not 'stale' (exit 3)" \
    "3" "$(lg_rc check)"
assert_json_field "beads-ledger 6.2: ...reported as status=ledger-ahead" \
    "$(lg check --json)" '.status' "ledger-ahead"

LG_MSG=$(lg check)
# The wording is load-bearing: the old message asserted a direction the hash
# cannot know, and prescribed the destructive export in exactly the state where
# it destroys.
assert_contains "beads-ledger 6.3: the message says the ledger DIFFERS" "DIFFERS" "$LG_MSG"
assert_not_contains "beads-ledger 6.4: ...and does NOT claim the database carries changes the ledger lacks" \
    "the database carries changes" "$LG_MSG"
assert_contains "beads-ledger 6.5: ...and names the ONLY safe recovery for this direction" \
    "bd import" "$LG_MSG"

# THE SAFETY PROPERTY: the automatic path must refuse, and must not touch a byte.
assert_eq "beads-ledger 6.6: check REPORTS a ledger-ahead divergence (exit 3)" \
    "3" "$(lg_rc check)"
assert_eq "beads-ledger 6.7: ...and the ledger is byte-identical afterwards" \
    "$LEDGER_SHA_BEFORE" "$(sha_of "$LEDGER")"
assert_eq "beads-ledger 6.8: ...so the ledger-only record still exists (the data-loss assertion)" \
    "1" "$(grep -c 'ghost-ahead-001' "$LEDGER" 2>/dev/null | tr -d ' ')"

# The doctor must prescribe the RIGHT direction too — an export here deletes.
DOCTOR_LA=$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$DOCTOR" --target "$FIXTURE" --skip "$SKIP_ALL_BUT" 2>/dev/null || true)
assert_contains "beads-ledger 6.9: the doctor FAILs on a ledger-ahead divergence" \
    "FAIL beads_ledger" "$DOCTOR_LA"
assert_contains "beads-ledger 6.10: ...and its remedy names the import direction, never a bare export" \
    "reconcile" "$DOCTOR_LA"

# 6b. reconcile heals it, losing nothing from EITHER side.
# DRY RUN FIRST (rider a): reconcile changes nothing without --apply.
LG_DRY_SHA=$(sha_of "$LEDGER")
assert_eq "beads-ledger 6.11a: reconcile WITHOUT --apply exits 0 but is a dry run" "0" "$(lg_rc reconcile)"
assert_eq "beads-ledger 6.11b: ...and the ledger is byte-identical after it" "$LG_DRY_SHA" "$(sha_of "$LEDGER")"
assert_contains "beads-ledger 6.11c: ...and it SAYS it is a dry run" "DRY RUN" "$(lg reconcile)"
assert_eq "beads-ledger 6.11: reconcile --apply exits 0" "0" "$(lg_rc reconcile --apply)"
assert_eq "beads-ledger 6.12: ...the ledger-only record is now IN the database" "1" \
    "$( (cd "$FIXTURE" && bd show ghost-ahead-001 --json 2>/dev/null | jq -r 'if type=="array" then .[0] else . end | .id' 2>/dev/null) | grep -c 'ghost-ahead-001' | tr -d ' ')"
assert_eq "beads-ledger 6.13: ...and the two sides now agree" "0" "$(lg_rc check)"

# 6c. CONTENT-level ledger-ahead: identical id sets, but the ledger carries a
# comment the database does not. An id-superset check alone passes this and
# then destroys the comment — which is where every QA-gate record lives.
LG_TID=$( (cd "$FIXTURE" && bd list --json 2>/dev/null | jq -r '.[0].id') )
jq -c --arg t "$LG_TID" 'if .id==$t then .comments = ((.comments // []) + [{"id":9901,"text":"REVIEW-ARTIFACT v1 pulled from a colleague","created_at":"2030-01-01T00:00:00Z"}]) else . end' \
    "$LEDGER" > "$LEDGER.spec6c" && mv "$LEDGER.spec6c" "$LEDGER"
# Export to a real file: `bd export -o /dev/stdout` produces nothing usable
# inside a command substitution, which would compare the ledger against an
# empty set and make this "precondition" pass or fail for the wrong reason.
SPEC6C_DB=$(mktemp -t beads-ledger-6c.XXXXXX)
( cd "$FIXTURE" && bd export -o "$SPEC6C_DB" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 6.14: precondition — the id SETS are still identical (ids alone cannot see this)" \
    "" "$(comm -3 \
        <(jq -rR 'fromjson? | .id // empty' "$LEDGER" | sort -u) \
        <(jq -rR 'fromjson? | .id // empty' "$SPEC6C_DB" | sort -u) 2>/dev/null | tr -d '[:space:]')"
rm -f "$SPEC6C_DB"
assert_eq "beads-ledger 6.15: a comment-only ledger-ahead is STILL reported (exit 3)" "3" "$(lg_rc check)"
assert_eq "beads-ledger 6.16: ...and the colleague's record survives" "1" \
    "$(grep -c 'pulled from a colleague' "$LEDGER" 2>/dev/null | tr -d ' ')"

# 6d. CONTROL — an EXPLICIT `reconcile --apply` must still repair the
# database-ahead direction. (Nothing repairs it automatically: R4-F1 removed
# that. What is being guarded here is the opposite failure — a helper that
# satisfies 6.6/6.15 by simply refusing everything and never writing at all.)
lg reconcile --apply >/dev/null 2>&1 || true
(cd "$FIXTURE" && bd create "db-ahead control" -t task -p 2 --json >/dev/null 2>&1) || true
assert_eq "beads-ledger 6.17: CONTROL — a database-ahead divergence is exit 1, not 3" "1" "$(lg_rc check)"
assert_eq "beads-ledger 6.18: CONTROL — and an explicit reconcile --apply repairs it" "0" "$(lg_rc reconcile --apply)"
assert_eq "beads-ledger 6.19: CONTROL — leaving the two sides in agreement" "0" "$(lg_rc check)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 7: the fresh-clone state (empty database, populated committed ledger) ==="

# The sharpest instance of R1-F1, and the one a new contributor hits on day one:
# clone the repo, run `bd init`, start a session. The database is EMPTY and the
# committed ledger holds every issue. The original virgin-init guard covered
# only the ledger-ABSENT case, so this state read as "stale" and the first
# SessionStart truncated a fully populated ledger to 0 records, reporting
# ok:true / status:refreshed.
# OUTSIDE the fixture tree, deliberately: bd resolves its database by walking
# UP from cwd, so a .beads/ nested inside the fixture still binds to the
# fixture's own store and the "empty database" precondition would be a fiction
# (measured: it reported the parent's 5 records). A sibling tempdir is the only
# way to get a genuinely virgin workspace.
CLONE=$(mktemp -d -t beads-ledger-clone.XXXXXX)
# Re-arming EXIT replaces the runner wrapper's trap, so the chain ends with
# __spec_wrapper_exit (a9hh R4-F1): it prints the __SPEC_SUMMARY__ line and
# runs the fixture cleanup this trap would otherwise silently drop. Dropping
# the chain is loud, not silent — the runner scores an exit-0 spec with no
# summary line as FAILED.
# shellcheck disable=SC2064
trap "rm -rf '$CLONE' 2>/dev/null || true; __spec_wrapper_exit" EXIT
mkdir -p "$CLONE/.beads"
printf '%s\n' \
    '{"id":"clone-aaa","title":"first issue from the clone","status":"open","issue_type":"task","priority":2}' \
    '{"id":"clone-bbb","title":"second issue from the clone","status":"open","issue_type":"task","priority":2}' \
    > "$CLONE/.beads/issues.jsonl"
( cd "$CLONE" && bd init --prefix clone --skip-agents --skip-hooks >/dev/null 2>&1 ) || true
clone_lg_rc() { CLAUDE_PROJECT_DIR="$CLONE" bash "$LEDGER_SH" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
CLONE_DB_N=$( (cd "$CLONE" && bd list --json 2>/dev/null | jq -r 'length') )
assert_eq "beads-ledger 7.1: precondition — bd init left the database EMPTY" "0" "${CLONE_DB_N:-x}"
assert_eq "beads-ledger 7.2: precondition — the committed ledger holds 2 records" "2" \
    "$(wc -l < "$CLONE/.beads/issues.jsonl" | tr -d ' ')"
assert_eq "beads-ledger 7.3: this reads as LEDGER-AHEAD (exit 3), not as a stale export" \
    "3" "$(clone_lg_rc check)"
assert_eq "beads-ledger 7.4: THE REGRESSION — check reports it, and no hook may write, so the first session cannot truncate it" \
    "3" "$(clone_lg_rc check)"
assert_eq "beads-ledger 7.5: ...and all 2 records are still on disk" "2" \
    "$(wc -l < "$CLONE/.beads/issues.jsonl" | tr -d ' ')"
assert_eq "beads-ledger 7.6a: reconcile WITHOUT --apply leaves the fresh clone's database empty" "0" \
    "$( (cd "$CLONE" && bash "$LEDGER_SH" reconcile >/dev/null 2>&1); cd "$CLONE" && bd list --json 2>/dev/null | jq -r 'length')"
assert_eq "beads-ledger 7.6: reconcile --apply imports them into the fresh database" "0" "$(clone_lg_rc reconcile --apply)"
assert_eq "beads-ledger 7.7: ...so the clone now has its issues" "2" \
    "$( (cd "$CLONE" && bd list --json 2>/dev/null | jq -r 'length') )"
assert_eq "beads-ledger 7.8: ...and the two sides agree" "0" "$(clone_lg_rc check)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 8: cannot-classify must REFUSE, not export (R2-F2) ==="

# The first direction-aware classify() enumerated three ledger-ahead signals and
# fell through to db-ahead. Absence of evidence for ledger-ahead is not evidence
# of db-ahead: a label-only difference, a dependency-only difference, comment
# text edited at equal count, or two writes inside the same one-second
# `updated_at` tick all landed in the destructive direction. Each case below
# leaves the record COUNT, the comment COUNT and the TIMESTAMP identical, so the
# only thing that can save the ledger is requiring positive proof.
#
# Every case asserts the same two things: exit 3, and the ledger byte-identical
# afterwards. The byte check is the one that matters — an exit code can be right
# while the file has already been rewritten.

lg reconcile --apply >/dev/null 2>&1 || true
lg reconcile --apply >/dev/null 2>&1 || true
S8_TID=$( (cd "$FIXTURE" && bd list --json 2>/dev/null | jq -r '.[0].id') )
S8_PRISTINE="$FIXTURE/s8-pristine.jsonl"
cp "$LEDGER" "$S8_PRISTINE"

# mutate_ledger <jq-program> — apply an edit to the seed record ONLY, leaving
# updated_at and the comment count untouched.
mutate_ledger() {
    jq -c --arg t "$S8_TID" "if .id==\$t then $1 else . end" "$S8_PRISTINE" > "$LEDGER.s8" \
        && mv "$LEDGER.s8" "$LEDGER"
}
# assert_refuses <n> <label> <jq-program>
assert_refuses() {
    local n="$1" label="$2" prog="$3"
    mutate_ledger "$prog"
    local before after rc
    before=$(sha_of "$LEDGER")
    rc=$(lg_rc check)
    after=$(sha_of "$LEDGER")
    assert_eq "beads-ledger $n: $label -> refuses (exit 3)" "3" "$rc"
    assert_eq "beads-ledger $n: ...and the ledger is byte-identical afterwards" "$before" "$after"
}

assert_refuses "8.1" "a LABEL-only difference at equal timestamp and comment count" \
    '.labels = ((.labels // []) + ["only-in-the-ledger"])'
assert_refuses "8.2" "a DEPENDENCY-only difference" \
    '.dependencies = ((.dependencies // []) + [{"id":"phantom-dep","dependency_type":"blocks"}])'
assert_refuses "8.3" "comment TEXT edited at EQUAL comment count" \
    '.comments = (((.comments // []) | if length > 0 then (.[0].text = "REWRITTEN BY A COLLEAGUE") | . else . end))'
assert_refuses "8.4" "an arbitrary field difference (the unmodeled case, by construction)" \
    '.title = "retitled only in the ledger"'

# 8.5 SAME-SECOND updated_at: bd stamps to second granularity, so two writes in
# the same tick are indistinguishable by timestamp. Explicitly pinned because
# `bd import` documents same-second ties as potentially distinct updates.
cp "$S8_PRISTINE" "$LEDGER"
S8_TS=$(jq -rR --arg t "$S8_TID" 'fromjson? | select(.id==$t) | .updated_at' "$LEDGER" | head -1)
mutate_ledger ".title = \"same-second edit\" | .updated_at = \"$S8_TS\""
S8_B=$(sha_of "$LEDGER")
assert_eq "beads-ledger 8.5: a difference at an IDENTICAL second-granularity timestamp refuses" \
    "3" "$(lg_rc check)"
assert_eq "beads-ledger 8.6: ...leaving the ledger byte-identical" "$S8_B" "$(sha_of "$LEDGER")"

# 8.7 MALFORMED lines must force a refusal, not be silently skipped. A skipped
# line means the comparison ran on a partial view of the file.
cp "$S8_PRISTINE" "$LEDGER"
printf '<<<<<<< HEAD\n' >> "$LEDGER"
S8_C=$(sha_of "$LEDGER")
assert_eq "beads-ledger 8.7: an unparseable line (git conflict marker) refuses rather than being skipped" \
    "3" "$(lg_rc check)"
assert_eq "beads-ledger 8.8: ...leaving the ledger byte-identical" "$S8_C" "$(sha_of "$LEDGER")"
assert_contains "beads-ledger 8.9: ...and says the file could not be parsed, not that it is stale" \
    "not parseable" "$(lg check)"

# 8.10 The jq-less PATH. Reproduced by QA destroying a ledger-ahead ledger while
# reporting "refreshed (2 -> 2 records)": without jq every read came back empty,
# both id sets looked identical, and the fall-through wrote. A missing tool is
# the definition of cannot-classify.
cp "$S8_PRISTINE" "$LEDGER"
printf '{"id":"jqless-ghost","title":"only in the ledger","status":"open","issue_type":"task","priority":2}\n' >> "$LEDGER"
S8_D=$(sha_of "$LEDGER")
# Built by hand, and `bash` is symlinked in and invoked by path: PATH=/usr/bin:/bin
# is NOT jq-less on macOS 15+ or on ubuntu runners (LESSONS.md), and a PATH that
# cannot find bash itself fails with 127 for a reason unrelated to jq.
JQLESS_BIN="$FIXTURE/jqless-bin"; mkdir -p "$JQLESS_BIN"
for t in bash bd sort comm join awk sed grep cut head tail tr wc mktemp rm cp mv cat dirname basename date shasum sha256sum; do
    src=$(command -v "$t" 2>/dev/null) && ln -sf "$src" "$JQLESS_BIN/$t" 2>/dev/null || true
done
# Probed in a SUBPROCESS, not with `PATH=x command -v` in this shell: bash
# caches resolved paths in its hash table, and jq has been executed many times
# by the assertions above, so the builtin answers from the cache and reports jq
# present on a PATH that does not contain it. A fresh process has no cache.
assert_eq "beads-ledger 8.10: precondition — the restricted PATH really has no jq" "yes" \
    "$(env PATH="$JQLESS_BIN" sh -c 'command -v jq' >/dev/null 2>&1 && echo no || echo yes)"
JQLESS_RC=$(PATH="$JQLESS_BIN" CLAUDE_PROJECT_DIR="$FIXTURE" "$JQLESS_BIN/bash" "$LEDGER_SH" check >/dev/null 2>&1; printf '%s' "$?")
assert_eq "beads-ledger 8.11: with no jq the check REPORTS indeterminate instead of guessing" "3" "$JQLESS_RC"
assert_eq "beads-ledger 8.12: ...and the ledger-only record survives (QA's live repro)" \
    "$S8_D" "$(sha_of "$LEDGER")"

# 8.13 CONTROL — positive db-ahead evidence must STILL authorise a write, or
# every assertion above is satisfied by a helper that refuses unconditionally.
cp "$S8_PRISTINE" "$LEDGER"
lg reconcile --apply >/dev/null 2>&1 || true
(cd "$FIXTURE" && bd comments add "$S8_TID" "a locally added gate record" >/dev/null 2>&1) || true
assert_eq "beads-ledger 8.13: CONTROL — a local comment-add is proven db-ahead and IS exported" \
    "0" "$(lg_rc reconcile --apply)"
assert_eq "beads-ledger 8.14: CONTROL — ...and the comment reached the ledger" "1" \
    "$(grep -c 'a locally added gate record' "$LEDGER" 2>/dev/null | tr -d ' ')"
rm -f "$S8_PRISTINE"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 9: comment asymmetry OUTRANKS a newer database timestamp (R3-F1) ==="

# THE ORDERING BUG. classify()'s db-ahead legs prove the database record is
# NEWER. For append-only sub-records that is not the same claim as "loses
# nothing", and the two come apart in an ordinary state:
#
#   1. a teammate's gate record arrives in the LEDGER via `git pull`
#      (comments are append-only and `bd comments add` does NOT bump the
#      parent's updated_at — measured);
#   2. anything is then edited LOCALLY, which does bump the database's
#      updated_at.
#
# With the timestamp rule consulted first, step 2 "proved" db-ahead and the
# automatic session-start refresh destroyed the pulled record — reporting
# `refreshed (1 -> 1 records)`, an identical record count, so nothing looked
# lost. Section 8 could not catch it: every case there holds updated_at EQUAL,
# so no pinned state could distinguish the two orderings. These two do.

# 9a. THE DESTRUCTIVE STATE: ledger richer in comments AND database newer.
S9="$FIXTURE/r3-guard"
mkdir -p "$S9"
( cd "$S9" && git init -q . && git config user.email t@e.com && git config user.name t ) >/dev/null 2>&1
( cd "$S9" && bd init --prefix r3g --skip-agents --skip-hooks >/dev/null 2>&1 ) || true
s9_lg_rc() { CLAUDE_PROJECT_DIR="$S9" bash "$LEDGER_SH" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
S9_LEDGER="$S9/.beads/issues.jsonl"
S9_TID=$( (cd "$S9" && bd create "shared task" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty') )
assert_match "beads-ledger 9.1: seed task created" "$BD_ID_RE" "$S9_TID"
( cd "$S9" && bd comments add "$S9_TID" "LOCAL: my own record" >/dev/null 2>&1 ) || true
( cd "$S9" && bd export -o "$S9_LEDGER" >/dev/null 2>&1 ) || true
# (1) the pull: a colleague's gate record lands in the LEDGER only.
jq -c '.comments = ((.comments // []) + [{"id":77,"text":"QA-GATE APPROVED change_set_hash=teammate reviewed_by=colleague","created_at":"2026-08-02T00:00:00Z"}])' \
    "$S9_LEDGER" > "$S9_LEDGER.tmp" && mv "$S9_LEDGER.tmp" "$S9_LEDGER"
# (2) a later LOCAL edit, which bumps only the database's updated_at.
sleep 1
( cd "$S9" && bd update "$S9_TID" --notes "a local edit made after the pull" >/dev/null 2>&1 ) || true

S9_DB=$(mktemp -t beads-ledger-r3db.XXXXXX)
( cd "$S9" && bd export -o "$S9_DB" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 9.2: precondition — the LEDGER holds MORE comments than the database" "yes" \
    "$([ "$(jq -rR 'fromjson? | ((.comments // []) | length)' "$S9_LEDGER" | awk '{n+=$1} END{print n+0}')" -gt \
        "$(jq -rR 'fromjson? | ((.comments // []) | length)' "$S9_DB" | awk '{n+=$1} END{print n+0}')" ] && echo yes || echo no)"
assert_eq "beads-ledger 9.3: precondition — and the DATABASE's updated_at is NEWER (what used to short-circuit)" "yes" \
    "$([ "$(jq -rR 'fromjson? | .updated_at // ""' "$S9_DB" | head -1)" \> \
        "$(jq -rR 'fromjson? | .updated_at // ""' "$S9_LEDGER" | head -1)" ] && echo yes || echo no)"
rm -f "$S9_DB"

S9_SHA=$(sha_of "$S9_LEDGER")
assert_eq "beads-ledger 9.4: check REFUSES (exit 3) instead of reporting the database ahead" "3" "$(s9_lg_rc check)"
assert_eq "beads-ledger 9.5: THE REGRESSION — check reports it rather than anything exporting over the pulled record" \
    "3" "$(s9_lg_rc check)"
assert_eq "beads-ledger 9.6: ...and the ledger is byte-identical afterwards" "$S9_SHA" "$(sha_of "$S9_LEDGER")"
assert_eq "beads-ledger 9.7: ...so the colleague's QA-GATE APPROVED record survives" "1" \
    "$(grep -c 'reviewed_by=colleague' "$S9_LEDGER" 2>/dev/null | tr -d ' ')"
assert_contains "beads-ledger 9.8: ...and the message says the database is not proven to lose nothing" \
    "no proof the database loses nothing" "$(CLAUDE_PROJECT_DIR="$S9" bash "$LEDGER_SH" check 2>&1)"

# 9b. CONTROL — the guard must not swallow the ordinary case. EQUAL comment
# counts plus a newer local edit is still provably database-ahead and MUST
# export. Without this the fix could be satisfied by widening refusal until
# nothing is ever written, which is the same trap 8.13/8.14 guards.
S9C="$FIXTURE/r3-control"
mkdir -p "$S9C"
( cd "$S9C" && git init -q . && git config user.email t@e.com && git config user.name t ) >/dev/null 2>&1
( cd "$S9C" && bd init --prefix r3c --skip-agents --skip-hooks >/dev/null 2>&1 ) || true
s9c_lg_rc() { CLAUDE_PROJECT_DIR="$S9C" bash "$LEDGER_SH" "$@" >/dev/null 2>&1; printf '%s' "$?"; }
S9C_LEDGER="$S9C/.beads/issues.jsonl"
S9C_TID=$( (cd "$S9C" && bd create "control task" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty') )
( cd "$S9C" && bd comments add "$S9C_TID" "one record, present on BOTH sides" >/dev/null 2>&1 ) || true
( cd "$S9C" && bd export -o "$S9C_LEDGER" >/dev/null 2>&1 ) || true
sleep 1
( cd "$S9C" && bd update "$S9C_TID" --notes "a purely local edit, nothing pulled" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 9.9: CONTROL — equal comment counts + a newer local edit is still db-ahead (exit 1)" \
    "1" "$(s9c_lg_rc check)"
assert_eq "beads-ledger 9.10: CONTROL — ...and an explicit reconcile --apply DOES write it" "0" "$(s9c_lg_rc reconcile --apply)"
assert_eq "beads-ledger 9.11: CONTROL — ...so the local edit reached the ledger" "1" \
    "$(grep -c 'a purely local edit, nothing pulled' "$S9C_LEDGER" 2>/dev/null | tr -d ' ')"
assert_eq "beads-ledger 9.12: CONTROL — ...leaving the two sides in agreement" "0" "$(s9c_lg_rc check)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 10: R4-F1's variants, converted into detector regressions ==="

# Comment-COUNT evidence is blind to comment-SET divergence. QA reproduced two
# variants against the shipped count-guard:
#   A  equal counts, DISJOINT sets, plus a later local edit  -> "db-ahead"
#   B  database has MORE comments, disjoint sets, no edit    -> "db-ahead"
# Variant B needs nothing but two machines commenting on the same task, which is
# this workflow's own review shape.
#
# The classifier is NOT fixed here — the automatic write it authorised is gone
# instead, so a wrong direction hint can no longer cost anything. What these
# assertions pin is the property that still matters: the detector must REPORT
# the divergence (never silence), and no automatic path may write. They are
# deliberately honest that the direction hint itself can be wrong in these two
# states; that is precisely why the mechanism was removed rather than guarded
# for a fifth time.

mk_variant() {   # mk_variant <dir> <prefix>
    rm -rf "$1"; mkdir -p "$1"
    ( cd "$1" && git init -q . && git config user.email t@e.com && git config user.name t ) >/dev/null 2>&1
    ( cd "$1" && bd init --prefix "$2" --skip-agents --skip-hooks >/dev/null 2>&1 ) || true
}
variant_rc() { CLAUDE_PROJECT_DIR="$1" bash "$LEDGER_SH" check >/dev/null 2>&1; printf '%s' "$?"; }

# --- Variant A: equal counts, disjoint sets, later local edit ---------------
VA="$FIXTURE/r4-variant-a"
mk_variant "$VA" r4a
VA_L="$VA/.beads/issues.jsonl"
VA_T=$( (cd "$VA" && bd create "shared" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty') )
( cd "$VA" && bd comments add "$VA_T" "LOCAL-ONLY comment" >/dev/null 2>&1 ) || true
( cd "$VA" && bd export -o "$VA_L" >/dev/null 2>&1 ) || true
# The pull replaces our comment with the teammate's: SAME count, DISJOINT set.
jq -c '.comments = [{"id":501,"text":"QA-GATE APPROVED reviewed_by=teammate-A","created_at":"2026-01-01T00:00:00Z"}]' \
    "$VA_L" > "$VA_L.t" && mv "$VA_L.t" "$VA_L"
sleep 1
( cd "$VA" && bd update "$VA_T" --notes "a later local edit" >/dev/null 2>&1 ) || true
VA_DB=$(mktemp -t r4a-db.XXXXXX); ( cd "$VA" && bd export -o "$VA_DB" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 10.1: variant A precondition — comment counts are EQUAL" \
    "$(jq -rR 'fromjson? | ((.comments // []) | length)' "$VA_DB" | awk '{n+=$1} END{print n+0}')" \
    "$(jq -rR 'fromjson? | ((.comments // []) | length)' "$VA_L" | awk '{n+=$1} END{print n+0}')"
assert_eq "beads-ledger 10.2: variant A precondition — but the SETS are disjoint" "0" \
    "$(grep -c 'reviewed_by=teammate-A' "$VA_DB" 2>/dev/null | tr -d ' ')"
rm -f "$VA_DB"
VA_SHA=$(sha_of "$VA_L")
assert_eq "beads-ledger 10.3: variant A — the detector REPORTS a divergence (non-zero), never silence" "yes" \
    "$([ "$(variant_rc "$VA")" != "0" ] && echo yes || echo no)"
( cd "$VA" && printf '%s' '{}' | CLAUDE_PROJECT_DIR="$VA" bash "$FIXTURE/.claude/scripts/session-start.sh" >/dev/null 2>&1 ) || true
( cd "$VA" && CLAUDE_PROJECT_DIR="$VA" bash "$FIXTURE/.claude/scripts/session-end.sh" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 10.4: variant A — NEITHER hook wrote; the ledger is byte-identical" \
    "$VA_SHA" "$(sha_of "$VA_L")"
assert_eq "beads-ledger 10.5: variant A — the teammate's gate record survives both hooks" "1" \
    "$(grep -c 'reviewed_by=teammate-A' "$VA_L" 2>/dev/null | tr -d ' ')"

# --- Variant B: database has MORE comments, disjoint, NO local edit ---------
# The more reachable of the two: it needs only both machines commenting.
VB="$FIXTURE/r4-variant-b"
mk_variant "$VB" r4b
VB_L="$VB/.beads/issues.jsonl"
VB_T=$( (cd "$VB" && bd create "shared" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty') )
( cd "$VB" && bd comments add "$VB_T" "LOCAL one" >/dev/null 2>&1 ) || true
( cd "$VB" && bd export -o "$VB_L" >/dev/null 2>&1 ) || true
jq -c '.comments = [{"id":601,"text":"QA-GATE APPROVED reviewed_by=teammate-B","created_at":"2026-01-01T00:00:00Z"}]' \
    "$VB_L" > "$VB_L.t" && mv "$VB_L.t" "$VB_L"
( cd "$VB" && bd comments add "$VB_T" "LOCAL two" >/dev/null 2>&1 ) || true   # DB now has 2, ledger 1
VB_DB=$(mktemp -t r4b-db.XXXXXX); ( cd "$VB" && bd export -o "$VB_DB" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 10.6: variant B precondition — the DATABASE has MORE comments" "yes" \
    "$([ "$(jq -rR 'fromjson? | ((.comments // []) | length)' "$VB_DB" | awk '{n+=$1} END{print n+0}')" -gt \
        "$(jq -rR 'fromjson? | ((.comments // []) | length)' "$VB_L" | awk '{n+=$1} END{print n+0}')" ] && echo yes || echo no)"
assert_eq "beads-ledger 10.7: variant B precondition — and it still lacks the teammate's comment" "0" \
    "$(grep -c 'reviewed_by=teammate-B' "$VB_DB" 2>/dev/null | tr -d ' ')"
rm -f "$VB_DB"
VB_SHA=$(sha_of "$VB_L")
assert_eq "beads-ledger 10.8: variant B — the detector REPORTS a divergence (non-zero)" "yes" \
    "$([ "$(variant_rc "$VB")" != "0" ] && echo yes || echo no)"
( cd "$VB" && printf '%s' '{}' | CLAUDE_PROJECT_DIR="$VB" bash "$FIXTURE/.claude/scripts/session-start.sh" >/dev/null 2>&1 ) || true
( cd "$VB" && CLAUDE_PROJECT_DIR="$VB" bash "$FIXTURE/.claude/scripts/session-end.sh" >/dev/null 2>&1 ) || true
assert_eq "beads-ledger 10.9: THE R4-F1 ASSERTION — the detect-and-warn path performed NO WRITE" \
    "$VB_SHA" "$(sha_of "$VB_L")"
assert_eq "beads-ledger 10.10: variant B — the teammate's gate record survives" "1" \
    "$(grep -c 'reviewed_by=teammate-B' "$VB_L" 2>/dev/null | tr -d ' ')"
# CONTROL: the operator's explicit command still resolves it, losing nothing.
assert_eq "beads-ledger 10.11: CONTROL — an explicit reconcile --apply still repairs variant B" "0" \
    "$(CLAUDE_PROJECT_DIR="$VB" bash "$LEDGER_SH" reconcile --apply >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "beads-ledger 10.12: CONTROL — ...keeping BOTH sides' comments" "1" \
    "$(grep -c 'reviewed_by=teammate-B' "$VB_L" 2>/dev/null | tr -d ' ')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 11: NEGATIVE CONTROL — no automatic path may write the ledger ==="

# THE STRUCTURAL GUARANTEE. Sections 3, 4 and 10 assert that today's hooks do
# not write. This section asserts that no hook may ACQUIRE the ability to,
# which is the guard against someone later restoring the convenience and
# reintroducing the whole five-member family. It is deliberately written in the
# demote/mutation style used for R3-F1: the probe is proven to bite before it
# is trusted.

# The CANONICAL scripts, not the fixture's symlinks — this is a claim about
# what ships, not about one sandbox.
NEG_PLUGIN=$(plugin_root)
SS_SH="$NEG_PLUGIN/.claude/scripts/session-start.sh"
SE_SH="$NEG_PLUGIN/.claude/scripts/session-end.sh"
# A "writing invocation" is a beads-ledger CALL that names a writer subcommand
# or carries --apply. `check` is the only permitted one.
#
# The probe must distinguish an INVOCATION from a MENTION: both hooks name
# `beads-ledger.sh reconcile --apply` inside their operator-facing warning text,
# which is exactly the string an invocation would contain. The discriminator is
# that real calls here go through the shell VARIABLE (`bash "$LEDGER_SH" ...`)
# or begin a command at line start, whereas the remediation text is embedded
# mid-string. Getting this wrong in the lax direction would make the whole
# section pass vacuously, so 11.5/11.6 prove the probe still bites.
writes_ledger() {
    { grep -E 'bash "\$[A-Z_]*LEDGER_SH"' "$1" 2>/dev/null || true
      grep -E '^[[:space:]]*bash [^"]*beads-ledger\.sh' "$1" 2>/dev/null || true
    } | grep -cE -- '--apply|LEDGER_SH"[[:space:]]+(export|reconcile)|beads-ledger\.sh[[:space:]]+(export|reconcile)' \
      | tr -d ' '
}
assert_eq "beads-ledger 11.1: session-start.sh contains NO ledger-writing invocation" "0" "$(writes_ledger "$SS_SH")"
assert_eq "beads-ledger 11.2: session-end.sh contains NO ledger-writing invocation" "0" "$(writes_ledger "$SE_SH")"
assert_eq "beads-ledger 11.3: ...and the removed auto-repair subcommand is gone from the script itself" "0" \
    "$(grep -cE '^cmd_refresh\(\)' "$LEDGER_SH" | tr -d ' ')"
assert_eq "beads-ledger 11.4: ...so invoking it is a usage error, not a silent write" "2" \
    "$(CLAUDE_PROJECT_DIR="$FIXTURE" bash "$LEDGER_SH" refresh >/dev/null 2>&1; printf '%s' "$?")"

# META: the probe must be able to FAIL. Plant the exact convenience someone
# would plausibly restore — a `reconcile --apply` in SessionStart — and show
# 11.1 flips. Without this the four assertions above could be passing because
# the grep never matches anything.
NEG_MUT="$FIXTURE/session-start.restored-autorepair.sh"
# Single quotes keep `$SS_LEDGER_SH` literal for sed; it is a string in the
# file being mutated, not a variable to expand here.
# shellcheck disable=SC2016
sed 's|bash "\$SS_LEDGER_SH" check --json|bash "$SS_LEDGER_SH" reconcile --apply --json|' "$SS_SH" > "$NEG_MUT"
assert_eq "beads-ledger 11.5: META — the mutation really planted an auto-repair call" "1" \
    "$(grep -c -- 'reconcile --apply --json' "$NEG_MUT" | tr -d ' ')"
assert_eq "beads-ledger 11.6: META — ...and the negative control DETECTS it (would fail 11.1)" "yes" \
    "$([ "$(writes_ledger "$NEG_MUT")" != "0" ] && echo yes || echo no)"
assert_eq "beads-ledger 11.7: META control — the shipped session-start.sh still passes" "0" \
    "$(writes_ledger "$SS_SH")"
rm -f "$NEG_MUT"
