#!/bin/bash
# qa-gate-pipefail.test.sh — the change-set evidence chain refuses on failed
# reads instead of returning the empty answer (claude-workflow-plugin-i8cx,
# units U3 + U4).
#
# THE DEFECT CLASS. qa-gate.sh sets `set -e` but never pipefail, so a
# pipeline's exit status was its LAST command's: every upstream failure was
# masked, and the masked shape was always the same — an EMPTY set at rc 0,
# which the consumer read as a positive finding of "nothing here". The audit
# (141 sites, 40 must-fix) placed seven of the worst in this file's gate
# evidence chain:
#
#   :327  write_gate_baseline's `git status | sort` — sort last, so the
#         author's own `|| { log; return 1; }` handler was DEAD CODE and a
#         failed git status captured an empty baseline at rc 0.
#   :402  gate_baseline_exclude_tracked's `while ... | sort -u > tmp` — no rc
#         branch at all; an empty tmp excludes nothing, so the session's OWN
#         edits were baselined as pre-existing (a free pass past the gate).
#   :437  gate_baseline_entries swallowed awk/cat with `|| true`.
#   :745/:754/:761  reconcile_tracker's baseline/current/comm reads — the
#         `|| true` sat INSIDE the command substitution, so pipefail alone
#         could never fix these; a failed sort read as "working tree clean"
#         and a failed comm as "nothing new", silently disarming BOTH approve
#         refusals (tracker_unreconcilable, change_set_reconstructed).
#   :6409 design_foreign_paths' process substitution — rc unobservable, the
#         loop ran zero times, foreign_n=0, and designer_touched_source was
#         skipped over a tracker full of source paths.
#   :1875 sha256_file digested an unreadable file to "" at rc 0, and the
#         completion cross-check's `[ -n "$disk_sha" ]` skipped the digest
#         binding — reporting PASSED over an unverified artifact.
#
# WHY SCOPED pipefail AND NOT FILE-WIDE (measured, from the i8cx audit):
# `( set -o pipefail; printf '' | grep -c . )` is rc 1 on the HEALTHY
# zero-match case, and `seq 1 100000 | head -1` is rc 141 (SIGPIPE) while the
# same over 3 lines is rc 0 — the trap bites nondeterministically by data
# size. Under `set -e` either one aborts the common path. Every fix is
# per-site; this spec's mutants restore the per-site masks and watch each
# masquerade come back.
#
# PAIRING (per .claude/tests/README.md "The pairing requirement"): every leg
# below drives the SHIPPED .claude/scripts/qa-gate.sh (leg 4); mutants are
# generated FROM the canonical bytes into fixture-local copies with an
# explicit landed-where-aimed proof (leg 1: strip counts / revert counts +
# bash -n); each mutant is asserted to fail in the guard's SPECIFIC way
# (leg 2: the named masquerade); and every fault has an unshimmed restore
# control (leg 3), including the two cases an over-eager refusal would break
# first — a clean tree still reconciling rc 0, and a clean checkout still
# capturing entries=0 ok:true.
#
# Sections:
#   0. the shipped guards exist (sentinel census — the strip METAs' baseline)
#   1. write_gate_baseline: :327 dead handler revived, :402 exclusion build
#      refuses; mutants A (pipefail removed) and B (pre-fix exclude body)
#   2. reconcile_tracker -> approve: sort/comm failures refuse with
#      tracker_unreconcilable; clean-tree and full-approve restore controls;
#      mutant C (RECONCILE-READ-GUARD stripped) brings back "working tree
#      clean" / "already in the gate baseline" over a dirty tree
#   3. design-record: unreadable tracker refuses change_set_unreadable
#      (exit 2) instead of recording with foreign_n=0; designer_touched_source
#      and the clean success path still fire; mutant D records the masquerade
#   4. approve completion cross-check: an undigestable payload reports
#      UNESTABLISHED with a stated reason, never PASSED; mutant E reports
#      PASSED over the same undigestable payload
#
# Needs: real bd (like review-separation.test.sh — no skip arm), jq, git,
# shasum. Exit codes: 0 all assertions passed | 1 failures | 2 harness error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"
[ "${1:-}" = "--keep" ] && KEEP_FIXTURE=1

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' "$name" "$expected" "$actual"
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
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %.400s\n' "$name" "$needle" "$haystack"
    fi
}

assert_not_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    forbidden: %s\n    haystack:  %.400s\n' "$name" "$needle" "$haystack"
    else
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    fi
}

for tool in bd jq git shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "$tool not on PATH — this spec requires it (same hard-fail rule as review-separation.test.sh)."
        exit 1
    fi
done
REAL_SORT=$(command -v sort)
REAL_GIT=$(command -v git)
REAL_SHASUM=$(command -v shasum)
REAL_BD=$(command -v bd)

PLUGIN_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
# The SHIPPED artifact — canonical repository path, never a fixture copy
# (leg 4 of the pairing standard; same xsu1 R7-F7 rule design-accessors and
# design-artifact carry). Fixture copies exist only as the SUPPORT scripts
# qa-gate.sh resolves from CLAUDE_PROJECT_DIR at runtime; mutants are built
# FROM the canonical bytes into fixture-local copies.
QG="$PLUGIN_DIR/.claude/scripts/qa-gate.sh"

FIXTURE=$(mktemp -d -t qa-gate-pipefail.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\n' "$FIXTURE"
    else
        chmod -R u+rwX "$FIXTURE" 2>/dev/null || true
        rm -rf "$FIXTURE"
    fi
}
trap cleanup EXIT

TRACK="$FIXTURE/.claude/.qa-tracking"
mkdir -p "$FIXTURE/.claude/scripts" "$TRACK" "$FIXTURE/src" "$FIXTURE/docs/specs" \
    "$FIXTURE/bin" "$FIXTURE/shim-sort" "$FIXTURE/shim-sortu" "$FIXTURE/shim-sorttrk" \
    "$FIXTURE/shim-comm" "$FIXTURE/shim-git" "$FIXTURE/shim-shasum" "$FIXTURE/mutants"
cp "$PLUGIN_DIR/.claude/scripts/"*.sh "$FIXTURE/.claude/scripts/"
chmod +x "$FIXTURE/.claude/scripts/"*.sh
# Mutant copies run from $FIXTURE/mutants/, and qa-gate.sh sources the shared
# denylist from ITS OWN directory (_WFDL_DIR). Without a sibling copy every
# mutant reconcile refuses on the MISSING LIB — a different, pre-existing
# refusal — instead of demonstrating the masquerade under test.
cp "$PLUGIN_DIR/.claude/scripts/workflow-denylist.sh" "$FIXTURE/mutants/"

# One PATH-controlled bd, exactly review-separation's shape.
cat > "$FIXTURE/bin/bd" <<BDEOF
#!/bin/bash
exec ${REAL_BD} "\$@"
BDEOF
chmod +x "$FIXTURE/bin/bd"
export PATH="$FIXTURE/bin:$PATH"

# --- the fault injectors --------------------------------------------------
# All-fail sort: kills every stage of every sort-bearing pipeline the gate
# runs (write_gate_baseline :327, reconcile :745/:746).
printf '#!/bin/bash\nexit 9\n' > "$FIXTURE/shim-sort/sort"
# Fail ONLY `sort -u`: isolates the :402 exclusion-set build while :327's
# plain `sort` still works.
cat > "$FIXTURE/shim-sortu/sort" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = "-u" ] && exit 9; done
exec ${REAL_SORT} "\$@"
SHIMEOF
# Fail ONLY the invocation that reads changed-files.txt: isolates
# design_foreign_paths' `sort -u "\$tracking"` (:6409) so design-record's
# validator/hasher, which run on the mutant's continue path, stay healthy.
cat > "$FIXTURE/shim-sorttrk/sort" <<SHIMEOF
#!/bin/bash
case "\$*" in *changed-files.txt*) exit 9 ;; esac
exec ${REAL_SORT} "\$@"
SHIMEOF
# Fail comm: reconcile's baseline subtraction (:754/:761) is the gate's only
# comm consumer.
printf '#!/bin/bash\nexit 9\n' > "$FIXTURE/shim-comm/comm"
# Fail ONLY `git ... status ...`: what revives (or, on the mutant, re-buries)
# :327's handler; has_git_repo / rev-parse stay healthy.
cat > "$FIXTURE/shim-git/git" <<SHIMEOF
#!/bin/bash
for a in "\$@"; do [ "\$a" = "status" ] && exit 9; done
exec ${REAL_GIT} "\$@"
SHIMEOF
# Fail ONLY the digest of a persisted completion payload: sha256_file's argv
# carries the payload path; impact-report's sha256_stdin hashes stdin and the
# approval-record fingerprint hashes stdin, so both stay healthy.
cat > "$FIXTURE/shim-shasum/shasum" <<SHIMEOF
#!/bin/bash
case "\$*" in *"/completion-"*) exit 9 ;; esac
exec ${REAL_SHASUM} "\$@"
SHIMEOF
chmod +x "$FIXTURE"/shim-*/*

# --- the fixture repo -------------------------------------------------------
cd "$FIXTURE" || exit 2
git init -q .
printf '.beads/\n.claude/.qa-tracking/\n' > .gitignore
# src/ must be a TRACKED directory: git collapses a fully-untracked dir into
# one `?? src/` porcelain line, which would defeat every per-file exclusion
# assertion below (the collapse blind spot reconcile_tracker's own header
# documents).
printf '' > src/.gitkeep
bd init --skip-agents --skip-hooks >/dev/null 2>&1 || bd init >/dev/null 2>&1
git add -A
git -c user.email=i8cx@test -c user.name=i8cx commit -q -m 'fixture baseline'
export CLAUDE_PROJECT_DIR="$FIXTURE"

json_field() { printf '%s' "$2" | jq -r "$1" 2>/dev/null || printf ''; }
labels_for() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' \
        2>/dev/null || echo ""
}
comments_of() {
    { bd show "$1" --json --include-comments 2>/dev/null \
        || bd show "$1" --json 2>/dev/null || true; } \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' \
        2>/dev/null || echo ""
}
reset_gate_state() {
    rm -f "$TRACK/gate-baseline" "$TRACK/approved-baseline" \
        "$TRACK/changed-files.txt" "$TRACK/current-task" 2>/dev/null
}
# record_completion <tid> <declared-file> — through the REAL writer, so the
# grammar cannot drift under this spec (review-separation's reasoning).
record_completion() {
    local tid="$1" file="$2" pay
    pay="$TRACK/draft-$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_').json"
    cat > "$pay" <<JSON
{"task_id":"$tid","role":"devops","model":"i8cx-spec","pin":"i8cx-spec","files_changed":["$file"],"tests_added":["qa-gate-pipefail.test.sh::seeded"],"decisions":["seeded fixture"],"blockers":[],"llm_observations":"seeded by the qa-gate-pipefail fixture","context_coverage":"seeded fixture: nothing read, nothing omitted, no unknown"}
JSON
    bash "$QG" completion-record "$tid" --file "$pay" >/dev/null 2>&1
}
# A valid v5 design artifact (design-artifact.test.sh's shape: eight prose
# sections, one sentinel pair, fenced machine block).
write_design_artifact() {
    local path="$1" tid="$2"
    cat > "$path" <<ARTIFACT
# Design — $tid

## Problem
A masked pipeline failure reads as an empty change set.

## Approaches considered
1. File-wide pipefail — rejected: measured traps on grep -c and head.
2. Per-site rc guards — chosen.

## Chosen approach
Guard each read.

## Units
See the machine block.

## Global constraints
No new harnesses.

## Out of scope
Everything else.

## Verification plan
\`make test\`

## Revision log
- v1 initial.

<!-- DESIGN-UNITS BEGIN -->
\`\`\`json
{
  "contract_version": "1",
  "task_id": "$tid",
  "designer_identity": "designer",
  "units": [
    {
      "unit_id": "U1",
      "role": "devops",
      "goal": "guard the reads",
      "acceptance": [
        { "id": "AC1", "text": "a failed read refuses instead of reporting empty" }
      ],
      "files": [ ".claude/scripts/qa-gate.sh" ],
      "verification": "make test",
      "depends_on": []
    }
  ]
}
\`\`\`
<!-- DESIGN-UNITS END -->
ARTIFACT
}

# ===========================================================================
echo ""
echo "=== Section 0: the shipped guards exist (strip-META baseline) ==="
# ===========================================================================
# The census the strip mutants below are proven against: if these counts
# move, the awk strips must move with them.
N_RRG=$(grep -c '# RECONCILE-READ-GUARD BEGIN (i8cx)' "$QG" || true)
N_DFG=$(grep -c '# DESIGN-FOREIGN-READ-GUARD BEGIN (i8cx)' "$QG" || true)
N_CXG=$(grep -c '# COMPLETION-XCHECK-DIGEST-GUARD BEGIN (i8cx)' "$QG" || true)
assert_eq "0.1 shipped qa-gate.sh carries 3 RECONCILE-READ-GUARD regions" "3" "$N_RRG"
assert_eq "0.2 shipped qa-gate.sh carries 1 DESIGN-FOREIGN-READ-GUARD region" "1" "$N_DFG"
assert_eq "0.3 shipped qa-gate.sh carries 1 COMPLETION-XCHECK-DIGEST-GUARD region" "1" "$N_CXG"

# ===========================================================================
echo ""
echo "=== Section 1: write_gate_baseline — dead handler revived, exclusion build refuses ==="
# ===========================================================================

# 1.1 SHIPPED + all-fail sort: capture refuses (ok:false, exit 2) and leaves
# NO baseline file — before i8cx this captured an empty snapshot at rc 0, and
# a later `enter --if-missing` would then keep the wrong artifact all session.
reset_gate_state
RC=0; OUT=$(PATH="$FIXTURE/shim-sort:$PATH" bash "$QG" baseline-capture 2>/dev/null) || RC=$?
assert_eq "1.1 sort failure: baseline-capture refuses (exit 2, ok:false)" \
    "2|false" "$RC|$(json_field '.ok' "$OUT")"
assert_eq "1.1b sort failure: no baseline file is left behind" "absent" \
    "$([ -f "$TRACK/gate-baseline" ] && echo present || echo absent)"

# 1.2 SHIPPED + git-status-only failure: the :327 handler the author wrote is
# REACHABLE now — the refusal is attributed to git status in sync-errors.log.
reset_gate_state
rm -f "$TRACK/sync-errors.log"
RC=0; OUT=$(PATH="$FIXTURE/shim-git:$PATH" bash "$QG" baseline-capture 2>/dev/null) || RC=$?
assert_eq "1.2 git-status failure: capture refuses (exit 2, ok:false)" \
    "2|false" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "1.2b the previously-dead handler fired (named in sync-errors.log)" \
    "write_gate_baseline: git status failed" "$(cat "$TRACK/sync-errors.log" 2>/dev/null)"

# 1.3 SHIPPED + sort-u-only failure + a session-tracked path: the :402
# exclusion-set build fails -> REFUSAL TO CAPTURE, and specifically the
# session's own edit is NOT baselined as pre-existing (no file at all).
reset_gate_state
printf 'session edit\n' > "$FIXTURE/src/session.sh"
printf '%s/src/session.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(PATH="$FIXTURE/shim-sortu:$PATH" bash "$QG" baseline-capture --exclude-tracked 2>/dev/null) || RC=$?
assert_eq "1.3 exclusion set unbuildable: capture refuses (exit 2, ok:false)" \
    "2|false" "$RC|$(json_field '.ok' "$OUT")"
assert_eq "1.3b no baseline written over the unbuildable exclusion" "absent" \
    "$([ -f "$TRACK/gate-baseline" ] && echo present || echo absent)"

# 1.4 RESTORE CONTROL (the case an over-eager refusal breaks first): a CLEAN
# checkout still captures ok:true entries=0.
reset_gate_state
rm -f "$FIXTURE/src/session.sh"
RC=0; OUT=$(bash "$QG" baseline-capture 2>/dev/null) || RC=$?
assert_eq "1.4 clean checkout still captures (ok:true, entries=0, exit 0)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "1.4b entries=0 reported, not 'unreadable'" "entries=0" \
    "$(json_field '.observations' "$OUT")"

# 1.5 RESTORE CONTROL: dirty tree + tracked session path + --exclude-tracked
# still captures, still EXCLUDES the tracked path, still counts the rest.
reset_gate_state
printf 'arrival dirt\n' > "$FIXTURE/src/arrival.sh"
printf 'session edit\n' > "$FIXTURE/src/session.sh"
printf '%s/src/session.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(bash "$QG" baseline-capture --exclude-tracked 2>/dev/null) || RC=$?
assert_eq "1.5 exclude-tracked capture still works unshimmed (ok:true)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "1.5b arrival dirt IS baselined" "src/arrival.sh" \
    "$(cat "$TRACK/gate-baseline" 2>/dev/null)"
assert_not_contains "1.5c the session's tracked edit is NOT baselined" "src/session.sh" \
    "$(cat "$TRACK/gate-baseline" 2>/dev/null)"

# --- MUTANT A: remove the :327 scoped pipefail (restores the dead handler) --
MUT_A="$FIXTURE/mutants/qa-gate-A.sh"
# shellcheck disable=SC2016  # the $-bearing string is a LITERAL sed pattern.
sed 's@status_out=$( set -o pipefail; git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort ) @status_out=$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null | LC_ALL=C sort) @' \
    "$QG" > "$MUT_A"
chmod +x "$MUT_A"
MUT_A_HIT="miss"
# shellcheck disable=SC2016  # literal needles, deliberately unexpanded.
if grep -qF 'set -o pipefail; git -C "$PROJECT_DIR" status --porcelain' "$QG" \
    && ! grep -qF 'set -o pipefail; git -C "$PROJECT_DIR" status --porcelain' "$MUT_A" \
    && bash -n "$MUT_A" 2>/dev/null; then
    MUT_A_HIT="hit"
fi
assert_eq "1.6 mutant A landed (pipefail removed from :327, copy parses)" "hit" "$MUT_A_HIT"

# Mutant A + the same git-status failure 1.2 refused on: the handler is dead
# again — an EMPTY baseline is captured at ok:true entries=0. That is the
# exact masquerade, and it is what makes 1.2 non-vacuous.
reset_gate_state
RC=0; OUT=$(PATH="$FIXTURE/shim-git:$PATH" bash "$MUT_A" baseline-capture 2>/dev/null) || RC=$?
assert_eq "1.7 mutant A: failed git status captures an EMPTY baseline at rc 0" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "1.7b mutant A reports entries=0 over a DIRTY tree (the masquerade)" \
    "entries=0" "$(json_field '.observations' "$OUT")"

# --- MUTANT B: pre-i8cx gate_baseline_exclude_tracked (no rc branch) --------
# Wholesale function replacement keyed on the signature line and the
# function's only column-0 `}` — the qa-gate-baseline.sh precedent. The body
# is the pre-fix behaviour: mktemp/pipeline failures fall through to the
# UNFILTERED snapshot; the pipeline's rc is dropped.
cat > "$FIXTURE/mutants/prefix-exclude-fn.txt" <<'PREFIX'
gate_baseline_exclude_tracked() {
    local status_out="$1"
    local tracking="$QA_TRACKING_DIR/changed-files.txt"
    [ -s "$tracking" ] || { printf '%s' "$status_out"; return 0; }
    local tmp_tracked
    tmp_tracked=$(mktemp -t gate-baseline-tracked.XXXXXX 2>/dev/null) || {
        printf '%s' "$status_out"; return 0
    }
    local t
    while IFS= read -r t; do
        [ -z "$t" ] && continue
        printf '%s\n' "$t"
        case "$t" in
            "$PROJECT_DIR"/*) printf '%s\n' "${t#"$PROJECT_DIR"/}" ;;
        esac
    done < "$tracking" | LC_ALL=C sort -u > "$tmp_tracked"
    local line p kept=""
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        p="${line#???}"
        case "$p" in *" -> "*) p="${p##* -> }" ;; esac
        if grep -qxF "$p" "$tmp_tracked" 2>/dev/null; then
            continue
        fi
        kept="$kept$line
"
    done <<< "$status_out"
    rm -f "$tmp_tracked" 2>/dev/null || true
    printf '%s' "${kept%$'\n'}"
}
PREFIX
MUT_B="$FIXTURE/mutants/qa-gate-B.sh"
awk -v fn="$FIXTURE/mutants/prefix-exclude-fn.txt" '
    BEGIN { in_fn = 0; replaced = 0 }
    /^gate_baseline_exclude_tracked\(\) \{$/ && !replaced {
        while ((getline line < fn) > 0) print line
        close(fn)
        in_fn = 1
        replaced = 1
        next
    }
    in_fn && /^\}$/ { in_fn = 0; next }
    in_fn { next }
    { print }
    END { if (!replaced) exit 7 }
' "$QG" > "$MUT_B"
MUT_B_AWK_RC=$?
chmod +x "$MUT_B"
MUT_B_FN=$(sed -n '/^gate_baseline_exclude_tracked() {$/,/^}$/p' "$MUT_B")
MUT_B_HIT="miss"
if [ "$MUT_B_AWK_RC" = "0" ] \
    && ! printf '%s' "$MUT_B_FN" | grep -qF 'set -o pipefail' \
    && printf '%s' "$MUT_B_FN" | grep -qF 'return 0' \
    && bash -n "$MUT_B" 2>/dev/null; then
    MUT_B_HIT="hit"
fi
assert_eq "1.8 mutant B landed (pre-fix exclude body installed, copy parses)" "hit" "$MUT_B_HIT"

# Mutant B + the same sort-u failure 1.3 refused on: the capture SUCCEEDS and
# the baseline CONTAINS the session's own tracked edit — the free pass.
reset_gate_state
printf '%s/src/session.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(PATH="$FIXTURE/shim-sortu:$PATH" bash "$MUT_B" baseline-capture --exclude-tracked 2>/dev/null) || RC=$?
assert_eq "1.9 mutant B: unbuildable exclusion set still captures at rc 0" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "1.9b mutant B baselines the session's OWN edit as pre-existing (the free pass)" \
    "src/session.sh" "$(cat "$TRACK/gate-baseline" 2>/dev/null)"

# ===========================================================================
echo ""
echo "=== Section 2: reconcile_tracker -> approve refuses on failed sort/comm ==="
# ===========================================================================
reset_gate_state
rm -f "$FIXTURE/src/arrival.sh" "$FIXTURE/src/session.sh"

# T2: arrival dirt D (baselined at enter), session file S (tracked), entered
# gate, completion record — everything approve's later gates need, so the
# reconcile refusal under test is the ONLY thing separating refusal from
# success.
printf 'arrival dirt\n' > "$FIXTURE/src/d.sh"
TID2=$(bd create "i8cx reconcile task" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty')
assert_eq "2.0 fixture task created" "yes" "$([ -n "$TID2" ] && echo yes || echo no)"
printf 'session work\n' > "$FIXTURE/src/s.sh"
printf '%s/src/s.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(bash "$QG" enter "$TID2" 2>/dev/null) || RC=$?
assert_eq "2.0b enter succeeded (baseline captured, impact report generated)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
record_completion "$TID2" "$FIXTURE/src/s.sh"

# 2.1 SHIPPED + all-fail sort: approve refuses tracker_unreconcilable — the
# reconcile's baseline/current reads could not be proven, so the change set
# is unknown. No label flips.
RC=0; OUT=$(PATH="$FIXTURE/shim-sort:$PATH" bash "$QG" approve "$TID2" --no-review 'i8cx: review not under test' --no-design 'i8cx: design not under test' 'i8cx approve under failed sort' 2>/dev/null) || RC=$?
assert_eq "2.1 failed sort: approve refuses tracker_unreconcilable (exit 2)" \
    "2|tracker_unreconcilable" "$RC|$(json_field '.error_key' "$OUT")"
assert_not_contains "2.1b the refusal does not claim a clean tree" \
    "working tree clean" "$(json_field '.observations' "$OUT")"
assert_not_contains "2.1c no qa-approved label flipped on the refusal" \
    "qa-approved" "$(labels_for "$TID2")"

# 2.2 SHIPPED + failed comm (baseline non-empty, tree dirty, so the comm
# branch is the one that runs): approve refuses tracker_unreconcilable, and
# the observation names the comm — it does NOT proceed with subtracted=0,
# which is what silently disarmed the change_set_reconstructed refusal.
RC=0; OUT=$(PATH="$FIXTURE/shim-comm:$PATH" bash "$QG" approve "$TID2" --no-review 'i8cx: review not under test' --no-design 'i8cx: design not under test' 'i8cx approve under failed comm' 2>/dev/null) || RC=$?
assert_eq "2.2 failed comm: approve refuses tracker_unreconcilable (exit 2)" \
    "2|tracker_unreconcilable" "$RC|$(json_field '.error_key' "$OUT")"
assert_contains "2.2b the refusal names the failed subtraction, not an empty answer" \
    "comm could not subtract" "$(json_field '.observations' "$OUT")"
assert_not_contains "2.2c the refusal never reports subtracted=0 over a failed comm" \
    "subtracted=0" "$(json_field '.observations' "$OUT")"

# 2.3 RESTORE CONTROL: the same task, unshimmed, approves end to end — and
# the completion cross-check reports PASSED (this doubles as section 4's
# unshimmed digest control).
RC=0; OUT=$(bash "$QG" approve "$TID2" --no-review 'i8cx: review not under test' --no-design 'i8cx: design not under test' 'i8cx clean approve' 2>/dev/null) || RC=$?
assert_eq "2.3 unshimmed: the same approve succeeds (exit 0, ok:true)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "2.3b unshimmed digest+lists: completeness cross-check PASSED" \
    "completeness cross-check PASSED" "$(json_field '.observations' "$OUT")"
assert_not_contains "2.3c no UNESTABLISHED on the healthy path" \
    "cross-check UNESTABLISHED" "$(json_field '.observations' "$OUT")"
assert_contains "2.3d qa-approved label flipped" "qa-approved" "$(labels_for "$TID2")"

# 2.4 RESTORE CONTROL: a genuinely CLEAN tree still reconciles rc 0 with the
# clean observation (the other case an over-eager refusal breaks). The
# harness scaffolding built so far (mutants A/B, shims) is committed first:
# the control needs a clean TREE, not clean-except-the-harness.
rm -f "$FIXTURE/src/d.sh" "$FIXTURE/src/s.sh"
git add -A >/dev/null 2>&1
git -c user.email=i8cx@test -c user.name=i8cx commit -q -m 'section 2.4 clean point' >/dev/null 2>&1 || true
RC=0; OUT=$(bash "$QG" reconcile-tracker 2>/dev/null) || RC=$?
assert_eq "2.4 clean tree: reconcile-tracker rc 0" "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "2.4b clean tree names itself clean" "working tree clean relative to HEAD" \
    "$(json_field '.observations' "$OUT")"

# 2.5 SHIPPED, direct: failed sort on a DIRTY tree refuses via the
# reconcile-tracker subcommand too (the Stop hook's entry point).
printf 'dirty again\n' > "$FIXTURE/src/d.sh"
RC=0; OUT=$(PATH="$FIXTURE/shim-sort:$PATH" bash "$QG" reconcile-tracker 2>/dev/null) || RC=$?
assert_eq "2.5 failed sort, dirty tree: reconcile-tracker refuses (exit 2)" \
    "2|tracker_unreconcilable" "$RC|$(json_field '.error_key' "$OUT")"

# --- MUTANT C: strip the RECONCILE-READ-GUARD regions -----------------------
MUT_C="$FIXTURE/mutants/qa-gate-C.sh"
awk '
    BEGIN { n = 0; skip = 0 }
    /^ *# RECONCILE-READ-GUARD BEGIN/ { skip = 1; n++; next }
    /^ *# RECONCILE-READ-GUARD END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (n != 3) exit 7 }
' "$QG" > "$MUT_C"
MUT_C_AWK_RC=$?
chmod +x "$MUT_C"
MUT_C_HIT="miss"
if [ "$MUT_C_AWK_RC" = "0" ] \
    && [ "$(grep -c '# RECONCILE-READ-GUARD BEGIN (i8cx)' "$MUT_C" || true)" = "0" ] \
    && bash -n "$MUT_C" 2>/dev/null; then
    MUT_C_HIT="hit"
fi
assert_eq "2.6 mutant C landed (all 3 guard regions stripped, copy parses)" "hit" "$MUT_C_HIT"

# Mutant C + failed sort on the SAME dirty tree 2.5 refused on: the pre-fix
# masquerade — rc 0 claiming "working tree clean" while src/d.sh is dirty.
RC=0; OUT=$(PATH="$FIXTURE/shim-sort:$PATH" bash "$MUT_C" reconcile-tracker 2>/dev/null) || RC=$?
assert_eq "2.7 mutant C: failed sort reads as SUCCESS (rc 0) on a dirty tree" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "2.7b mutant C claims 'working tree clean' over a dirty tree (the masquerade)" \
    "working tree clean" "$(json_field '.observations' "$OUT")"

# Mutant C + failed comm (baseline holding the dirty path, so the comm branch
# runs): survivors read as empty — "already in the gate baseline" over a
# subtraction that never happened.
RC=0; OUT=$(bash "$QG" baseline-capture 2>/dev/null) || RC=$?
assert_eq "2.8 setup: baseline over the dirty tree captured (comm branch armed)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
printf 'new dirt the baseline does not hold\n' > "$FIXTURE/src/new.sh"
RC=0; OUT=$(PATH="$FIXTURE/shim-comm:$PATH" bash "$MUT_C" reconcile-tracker 2>/dev/null) || RC=$?
assert_eq "2.9 mutant C: failed comm reads as SUCCESS (rc 0)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "2.9b mutant C claims everything is baselined while comm never ran" \
    "already in the gate baseline" "$(json_field '.observations' "$OUT")"
# The SHIPPED artifact on the identical state refuses — same-state contrast.
RC=0; OUT=$(PATH="$FIXTURE/shim-comm:$PATH" bash "$QG" reconcile-tracker 2>/dev/null) || RC=$?
assert_eq "2.10 shipped, same state: failed comm refuses (exit 2)" \
    "2|tracker_unreconcilable" "$RC|$(json_field '.error_key' "$OUT")"
rm -f "$FIXTURE/src/new.sh" "$FIXTURE/src/d.sh"

# ===========================================================================
echo ""
echo "=== Section 3: design-record — unreadable tracker refuses, never foreign_n=0 ==="
# ===========================================================================
reset_gate_state

TID3A=$(bd create "i8cx design task A" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty')
TID3B=$(bd create "i8cx design task B" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty')
assert_eq "3.0 design fixture tasks created" "yes" \
    "$([ -n "$TID3A" ] && [ -n "$TID3B" ] && echo yes || echo no)"
write_design_artifact "$FIXTURE/docs/specs/$TID3A.md" "$TID3A"
write_design_artifact "$FIXTURE/docs/specs/$TID3B.md" "$TID3B"

# A tracker holding a SOURCE path — the state designer_touched_source exists
# to refuse, and the state a failed read used to count as foreign_n=0.
printf 'not a design artifact\n' > "$FIXTURE/src/foreign.sh"
printf '%s/src/foreign.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"

# 3.1 SHIPPED + tracker-read failure: refuses change_set_unreadable (exit 2)
# — NOT a recorded design over foreign_n=0.
RC=0; OUT=$(PATH="$FIXTURE/shim-sorttrk:$PATH" bash "$QG" design-record "$TID3A" --no-grilling 'i8cx spec' 2>/dev/null) || RC=$?
assert_eq "3.1 unreadable tracker: design-record refuses change_set_unreadable (exit 2)" \
    "2|change_set_unreadable" "$RC|$(json_field '.error_key' "$OUT")"
assert_not_contains "3.1b no DESIGN-ARTIFACT record was posted on the refusal" \
    "DESIGN-ARTIFACT v1" "$(comments_of "$TID3A")"

# 3.2 RESTORE CONTROL: unshimmed, the ORDINARY refusal still fires — a source
# path in the tracker is designer_touched_source, not unreadable.
RC=0; OUT=$(bash "$QG" design-record "$TID3A" --no-grilling 'i8cx spec' 2>/dev/null) || RC=$?
assert_eq "3.2 readable tracker with a source path: designer_touched_source (exit 1)" \
    "1|designer_touched_source" "$RC|$(json_field '.error_key' "$OUT")"

# 3.3 RESTORE CONTROL: a designer that touched ONLY its artifact records
# successfully (foreign_n=0 via a READ that succeeded, not one that failed).
printf '%s/docs/specs/%s.md\n' "$FIXTURE" "$TID3B" > "$TRACK/changed-files.txt"
RC=0; OUT=$(bash "$QG" design-record "$TID3B" --no-grilling 'i8cx spec' 2>/dev/null) || RC=$?
assert_eq "3.3 artifact-only tracker: design-record succeeds" \
    "0|true|recorded" "$RC|$(json_field '.ok' "$OUT")|$(json_field '.status' "$OUT")"
assert_not_contains "3.3b no foreign-paths bypass note on the clean path" \
    "ACCEPTED" "$(json_field '.observations' "$OUT")"

# --- MUTANT D: strip the DESIGN-FOREIGN-READ-GUARD region -------------------
MUT_D="$FIXTURE/mutants/qa-gate-D.sh"
awk '
    BEGIN { n = 0; skip = 0 }
    /^ *# DESIGN-FOREIGN-READ-GUARD BEGIN/ { skip = 1; n++; next }
    /^ *# DESIGN-FOREIGN-READ-GUARD END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (n != 1) exit 7 }
' "$QG" > "$MUT_D"
MUT_D_AWK_RC=$?
chmod +x "$MUT_D"
MUT_D_HIT="miss"
if [ "$MUT_D_AWK_RC" = "0" ] \
    && [ "$(grep -c '# DESIGN-FOREIGN-READ-GUARD BEGIN (i8cx)' "$MUT_D" || true)" = "0" ] \
    && bash -n "$MUT_D" 2>/dev/null; then
    MUT_D_HIT="hit"
fi
assert_eq "3.4 mutant D landed (guard region stripped, copy parses)" "hit" "$MUT_D_HIT"

# Mutant D + the same unreadable tracker 3.1 refused on: the design RECORDS
# with foreign_n read as 0 — the record 3.1 proves the shipped gate refuses.
printf '%s/src/foreign.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(PATH="$FIXTURE/shim-sorttrk:$PATH" bash "$MUT_D" design-record "$TID3A" --no-grilling 'i8cx spec' 2>/dev/null) || RC=$?
assert_eq "3.5 mutant D: the unreadable tracker RECORDS a design (the masquerade)" \
    "0|true|recorded" "$RC|$(json_field '.ok' "$OUT")|$(json_field '.status' "$OUT")"
assert_contains "3.5b mutant D materialised the defect: a DESIGN-ARTIFACT record exists over an unread change set" \
    "DESIGN-ARTIFACT v1" "$(comments_of "$TID3A")"

# ===========================================================================
echo ""
echo "=== Section 4: approve's completion cross-check — unestablished, never PASSED, on a failed digest ==="
# ===========================================================================
reset_gate_state
git add -A >/dev/null 2>&1
git -c user.email=i8cx@test -c user.name=i8cx commit -q -m 'section 4 baseline' 2>/dev/null || true

# T4A: a full, healthy approve fixture whose ONLY fault is the digest of the
# persisted completion payload.
TID4A=$(bd create "i8cx digest task A" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty')
printf 'section 4 work\n' > "$FIXTURE/src/s4.sh"
printf '%s/src/s4.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(bash "$QG" enter "$TID4A" 2>/dev/null) || RC=$?
assert_eq "4.0 enter succeeded for the digest fixture" "0|true" "$RC|$(json_field '.ok' "$OUT")"
record_completion "$TID4A" "$FIXTURE/src/s4.sh"

# 4.1 SHIPPED + payload-digest failure: the cross-check reports UNESTABLISHED
# with the stated digest reason — never PASSED — and approve still succeeds
# (the cross-check reports, it does not refuse; that contract is unchanged).
RC=0; OUT=$(PATH="$FIXTURE/shim-shasum:$PATH" bash "$QG" approve "$TID4A" --no-review 'i8cx: review not under test' --no-design 'i8cx: design not under test' 'i8cx approve under failed digest' 2>/dev/null) || RC=$?
assert_eq "4.1 failed payload digest: approve still succeeds (report-only contract)" \
    "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "4.1b cross-check reports UNESTABLISHED" \
    "completeness cross-check UNESTABLISHED" "$(json_field '.observations' "$OUT")"
assert_contains "4.1c the reason is the failed digest, stated" \
    "could NOT be digested" "$(json_field '.observations' "$OUT")"
assert_not_contains "4.1d PASSED is never reported over an undigestable payload" \
    "completeness cross-check PASSED" "$(json_field '.observations' "$OUT")"

# --- MUTANT E: strip the COMPLETION-XCHECK-DIGEST-GUARD region --------------
MUT_E="$FIXTURE/mutants/qa-gate-E.sh"
awk '
    BEGIN { n = 0; skip = 0 }
    /^ *# COMPLETION-XCHECK-DIGEST-GUARD BEGIN/ { skip = 1; n++; next }
    /^ *# COMPLETION-XCHECK-DIGEST-GUARD END/   { skip = 0; next }
    skip { next }
    { print }
    END { if (n != 1) exit 7 }
' "$QG" > "$MUT_E"
MUT_E_AWK_RC=$?
chmod +x "$MUT_E"
MUT_E_HIT="miss"
if [ "$MUT_E_AWK_RC" = "0" ] \
    && [ "$(grep -c '# COMPLETION-XCHECK-DIGEST-GUARD BEGIN (i8cx)' "$MUT_E" || true)" = "0" ] \
    && bash -n "$MUT_E" 2>/dev/null; then
    MUT_E_HIT="hit"
fi
assert_eq "4.2 mutant E landed (digest guard stripped, copy parses)" "hit" "$MUT_E_HIT"

# T4B: identical fixture, approved through mutant E under the same digest
# failure: the cross-check reports PASSED over a payload nothing digested —
# the pre-fix masquerade 4.1 proves the shipped gate no longer performs.
# (A fresh task: approve is idempotent per task, so re-approving T4A would
# short-circuit before the cross-check runs.)
TID4B=$(bd create "i8cx digest task B" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty')
printf 'section 4 work B\n' > "$FIXTURE/src/s5.sh"
printf '%s/src/s5.sh\n' "$FIXTURE" > "$TRACK/changed-files.txt"
RC=0; OUT=$(bash "$QG" enter "$TID4B" 2>/dev/null) || RC=$?
assert_eq "4.3 enter succeeded for the mutant-E fixture" "0|true" "$RC|$(json_field '.ok' "$OUT")"
record_completion "$TID4B" "$FIXTURE/src/s5.sh"
RC=0; OUT=$(PATH="$FIXTURE/shim-shasum:$PATH" bash "$MUT_E" approve "$TID4B" --no-review 'i8cx: review not under test' --no-design 'i8cx: design not under test' 'i8cx mutant approve under failed digest' 2>/dev/null) || RC=$?
assert_eq "4.4 mutant E: approve succeeds" "0|true" "$RC|$(json_field '.ok' "$OUT")"
assert_contains "4.4b mutant E reports PASSED over the undigestable payload (the masquerade)" \
    "completeness cross-check PASSED" "$(json_field '.observations' "$OUT")"
assert_not_contains "4.4c mutant E never says UNESTABLISHED (the guard is what said it)" \
    "cross-check UNESTABLISHED" "$(json_field '.observations' "$OUT")"

# ===========================================================================
printf '\n=== Summary ===\n'
# ===========================================================================
printf '\nTotal: %d assertion(s) run\n' "$((PASS + FAIL))"
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d assertion(s)\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
