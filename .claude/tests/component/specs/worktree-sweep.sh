#!/bin/bash
# worktree-sweep.sh component spec — v4.1 C1b (claude-workflow-plugin-8xv).
#
# The full lifecycle of .claude/scripts/worktree-sweep.sh against a REAL git
# topology: a repo, a bare origin it can actually push to, five linked worktrees
# under .claude/worktrees/ and one deliberately outside it.
#
# WHY bd IS STUBBED AND bd_required_or_skip IS NOT CALLED
# ------------------------------------------------------
# CI runs with BD_SHIM_ONLY=1 and no bd binary, so a spec that gates on
# bd_required_or_skip SKIPS THERE — and the four META-TESTs below, which are the
# only evidence that the safety gates are load-bearing, would never execute on
# the runner that guards the branch. The task-status lookup is one `bd show
# <id> --json` call, so it is stubbed with the case-dispatch pattern from
# bd-github-link.test.sh and every assertion runs on every host.
#
# SECTIONS
#   1. baseline dry run — one removable, and each keeper's FIRST failing gate
#   2. flags — --max-candidates bound, --report-only beats --apply, --age-days,
#      --json validity
#   3. read-only — a dry run modifies no file in any worktree
#   4. META-1 (BUDGET-MANDATED) — strip the UN-PUSHED check: `unpushed` becomes
#      removable; restore and it must disappear again
#   5. META-2 — same for the DIRTY check and `dirty`
#   6. META-3 — same for the TASK-CLOSED check and `open-task`
#   7. --apply — the real removal path, then META-4 on the --apply gate itself
#
# RESTORE-AND-RE-ASSERT is the discipline in 4/5/6: a fixture that quietly
# became un-listable (a bad mutation, a broken worktree) produces the same
# "not removable" observable as a working gate, so each META re-runs the
# SHIPPED script afterwards and re-asserts the original verdict.
#
# THE SYMLINK HAZARD: mk_fixture symlinks the plugin's REAL scripts into the
# fixture. Every mutated variant here is written as a NEW file beside the link,
# never `sed -i`/`cp` onto it; section 7 re-checksums the real script.

set -u

# ---------------------------------------------------------------------------
# SECTION 0 — fixture.
# ---------------------------------------------------------------------------

mk_fixture
# PHYSICALLY resolved: `mktemp -d` hands back /var/folders/… on macOS while git
# records the /private/var/folders/… it resolves to, so an un-canonicalised
# fixture root makes every `git worktree list` comparison in this spec miss.
FX=$(cd "$COMPONENT_FIXTURE_PATH" 2>/dev/null && pwd -P)
SWEEP="$FX/.claude/scripts/worktree-sweep.sh"
PLUGIN_SWEEP="$(plugin_root)/.claude/scripts/worktree-sweep.sh"
SWEEP_SHA_BEFORE=$(shasum -a 256 "$PLUGIN_SWEEP" 2>/dev/null | awk '{print $1}')

# bd stub — quoted heredoc, ARGS="$*", case dispatch on $1. Overwrites whatever
# mk_bd_shim left at $FX/bin/bd (which is already first on PATH).
cat > "$FX/bin/bd" <<'STUB'
#!/bin/bash
ARGS="$*"
printf '%s\n' "$ARGS" >> "${BD_STUB_LOG:-/dev/null}"
case "$1" in
    show)
        case "$2" in
            sweep-task-aaa|sweep-task-bbb|sweep-task-ccc|sweep-task-redo)
                printf '%s\n' '{"status":"closed"}'; exit 0 ;;
            sweep-task-open)
                printf '%s\n' '{"status":"open"}'; exit 0 ;;
            *) printf 'no such issue: %s\n' "$2" >&2; exit 1 ;;
        esac ;;
esac
exit 0
STUB
chmod +x "$FX/bin/bd"
export BD_STUB_LOG="$FX/bd-stub.log"

# The repo. Everything the harness owns is gitignored so the worktrees read
# CLEAN — the same reason the real plugin gitignores .claude/.qa-tracking/.
printf '%s\n' '.claude/.qa-tracking/' '.claude/worktrees/' '.claude/scripts/' \
    '.claude/settings.json' '.claude/skills/' '.beads/' 'bin/' 'remote.git/' \
    'outside-wt/' 'bd-stub.log' '*.mutant.sh' > "$FX/.gitignore"
mkdir -p "$FX/src"
printf 'export const a = 0;\n' > "$FX/src/a.ts"
(
  cd "$FX" && git init -q -b main . && git config user.email t@t.t \
    && git config user.name t && git add -A && git commit -qm baseline
) >/dev/null 2>&1
git init -q --bare "$FX/remote.git" >/dev/null 2>&1
(cd "$FX" && git remote add origin "$FX/remote.git" && git push -q -u origin main) >/dev/null 2>&1

mkdir -p "$FX/.claude/worktrees"
add_wt() {
    # add_wt <abs-path> <branch> [push]
    git -C "$FX" worktree add -q -b "$2" "$1" main >/dev/null 2>&1
    if [ "${3:-}" = "push" ]; then
        git -C "$1" push -q -u origin "$2" >/dev/null 2>&1
    fi
}
add_wt "$FX/.claude/worktrees/clean-merged-closed-old" wt-sweep-aaa push
add_wt "$FX/.claude/worktrees/dirty"                   wt-sweep-bbb push
add_wt "$FX/.claude/worktrees/unpushed"                wt-sweep-ccc push
add_wt "$FX/.claude/worktrees/open-task"               wt-sweep-open push
add_wt "$FX/.claude/worktrees/young"                   wt-sweep-young push
add_wt "$FX/outside-wt"                                wt-sweep-outside push

seed_task() {
    # seed_task <worktree> <task-id> — the EVIDENCE gate 6 reads.
    mkdir -p "$1/.claude/.qa-tracking"
    printf '%s\n' "$2" > "$1/.claude/.qa-tracking/current-task"
}
seed_task "$FX/.claude/worktrees/clean-merged-closed-old" sweep-task-aaa
seed_task "$FX/.claude/worktrees/dirty"                   sweep-task-bbb
seed_task "$FX/.claude/worktrees/unpushed"                sweep-task-ccc
seed_task "$FX/.claude/worktrees/open-task"               sweep-task-open
seed_task "$FX/.claude/worktrees/young"                   sweep-task-aaa
seed_task "$FX/outside-wt"                                sweep-task-aaa

# `dirty` gets one tracked-but-uncommitted change; `unpushed` a real local
# commit ahead of its upstream and off every merge line.
printf 'export const dirt = 1;\n' > "$FX/.claude/worktrees/dirty/src/a.ts"
(
  cd "$FX/.claude/worktrees/unpushed" && printf 'export const l = 1;\n' > src/local.ts \
    && git add -A && git commit -qm "local only"
) >/dev/null 2>&1

# Backdate LAST: every write above refreshes the directory mtime gate 5 reads.
for d in clean-merged-closed-old dirty unpushed open-task; do
    touch -t 202001010000 "$FX/.claude/worktrees/$d"
done
touch -t 202001010000 "$FX/outside-wt"

sweep() {
    # sweep [--script <path>] [args…] -> the --json report of one run
    local s="$SWEEP"
    if [ "${1:-}" = "--script" ]; then s="$2"; shift 2; fi
    CLAUDE_PROJECT_DIR="$FX" bash "$s" --json "$@" 2>/dev/null
}
reason_of() {
    printf '%s' "$1" | jq -r --arg b "$2" \
        '[.candidates[] | select(.path | endswith("/" + $b)) | .reason][0] // "<absent>"' 2>/dev/null
}
status_of() {
    printf '%s' "$1" | jq -r --arg b "$2" \
        '[.candidates[] | select(.path | endswith("/" + $b)) | .status][0] // "<absent>"' 2>/dev/null
}
wt_present() {
    git -C "$FX" worktree list --porcelain 2>/dev/null | grep -qF "worktree $1" && echo yes || echo no
}

# ---------------------------------------------------------------------------
# SECTION 1 — baseline dry run. Every keeper reports its FIRST failing gate.
# ---------------------------------------------------------------------------
echo "--- 1. baseline dry run ---"
J1=$(sweep)

assert_eq "1.1 the report is valid JSON with a completeness count" "6" \
    "$(printf '%s' "$J1" | jq -r '.total // "<none>"' 2>/dev/null)"
assert_eq "1.2 all six were examined (cap not reached)" "6" \
    "$(printf '%s' "$J1" | jq -r '.examined' 2>/dev/null)"
assert_eq "1.3 exactly one worktree is removable" "1" \
    "$(printf '%s' "$J1" | jq -r '.removable' 2>/dev/null)"
assert_eq "1.4 and it is the clean/merged/closed/old one" "clean-merged-closed-old" \
    "$(printf '%s' "$J1" | jq -r '[.candidates[]|select(.status=="REMOVABLE")|.path|split("/")|last]|join(",")' 2>/dev/null)"
assert_eq "1.5 dry run removed nothing" "0" \
    "$(printf '%s' "$J1" | jq -r '.removed' 2>/dev/null)"
assert_eq "1.6 keeper reason — dirty tree" "dirty" "$(reason_of "$J1" dirty)"
assert_eq "1.7 keeper reason — neither pushed nor merged" "unpushed-and-unmerged" \
    "$(reason_of "$J1" unpushed)"
assert_eq "1.8 keeper reason — task still open" "task-not-closed" "$(reason_of "$J1" open-task)"
assert_eq "1.9 keeper reason — too young" "too-young" "$(reason_of "$J1" young)"
assert_eq "1.10 keeper reason — outside .claude/worktrees/" "not-contained" \
    "$(reason_of "$J1" outside-wt)"
assert_eq "1.11 the removable one carries the resolved task id" "sweep-task-aaa" \
    "$(printf '%s' "$J1" | jq -r '[.candidates[]|select(.status=="REMOVABLE")|.task][0]' 2>/dev/null)"
assert_contains "1.12 gate 6 really consulted bd" "show sweep-task-aaa --json" \
    "$(cat "$BD_STUB_LOG" 2>/dev/null)"

# ---------------------------------------------------------------------------
# SECTION 2 — flags.
# ---------------------------------------------------------------------------
echo "--- 2. flags ---"
J2=$(sweep --max-candidates 2)
assert_eq "2.1 --max-candidates bounds what is EXAMINED" "2" \
    "$(printf '%s' "$J2" | jq -r '.examined' 2>/dev/null)"
assert_eq "2.2 ...while the total still reports what exists" "6" \
    "$(printf '%s' "$J2" | jq -r '.total' 2>/dev/null)"

J3=$(sweep --report-only --apply)
assert_eq "2.3 --report-only WINS over --apply (fail-safe precedence)" "dry-run" \
    "$(printf '%s' "$J3" | jq -r '.mode' 2>/dev/null)"
assert_eq "2.4 ...and therefore removes nothing" "0" \
    "$(printf '%s' "$J3" | jq -r '.removed' 2>/dev/null)"
assert_eq "2.5 the removable worktree survived the --report-only --apply run" "yes" \
    "$(wt_present "$FX/.claude/worktrees/clean-merged-closed-old")"

assert_eq "2.6 --age-days 3650 ages every candidate out" "0" \
    "$(sweep --age-days 3650 | jq -r '.removable' 2>/dev/null)"
assert_eq "2.7 --age-days 0 still refuses a worktree created this session" "too-young" \
    "$(reason_of "$(sweep --age-days 0)" young)"

# ---------------------------------------------------------------------------
# SECTION 3 — a dry run is read-only inside the worktrees it inspects.
# .git internals are excluded: `git status` legitimately refreshes the index.
# ---------------------------------------------------------------------------
echo "--- 3. read-only ---"
tree_fp() {
    ( cd "$1" 2>/dev/null || return 0
      find . -type f -not -path '*/.git/*' -not -name '.git' 2>/dev/null | LC_ALL=C sort \
        | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f" | tr -s ' ' '-')" "$f"; done )
}
FP_BEFORE=$(tree_fp "$FX/.claude/worktrees")
sweep >/dev/null 2>&1
FP_AFTER=$(tree_fp "$FX/.claude/worktrees")
assert_eq "3.1 a dry run modifies no file in any worktree" "$FP_BEFORE" "$FP_AFTER"
# 7 = the main checkout + the 6 linked worktrees.
assert_eq "3.2 and the worktree registry is unchanged" "7" \
    "$(git -C "$FX" worktree list --porcelain | grep -c '^worktree ' || true)"

# ---------------------------------------------------------------------------
# SECTION 4 — META-1 (budget-mandated): the UN-PUSHED check.
# Anchored on a unique TEXT pattern, never a line number (LESSONS.md).
# ---------------------------------------------------------------------------
echo "--- 4. META-1: the un-pushed check is load-bearing ---"
MUT_PUSH="$FX/.claude/scripts/sweep-nopush.mutant.sh"
awk 'index($0, "= \"0\" ] && pushed=1") { print "        pushed=1  # MUTATED"; next } { print }' \
    "$SWEEP" > "$MUT_PUSH"
assert_eq "4.1 the mutation changed the script (non-vacuous)" "1" \
    "$(cmp -s "$SWEEP" "$MUT_PUSH" && echo 0 || echo 1)"
bash -n "$MUT_PUSH" 2>/dev/null
assert_eq "4.2 the mutant still parses (it fails for its own reason)" "0" "$?"
JM1=$(sweep --script "$MUT_PUSH")
assert_eq "4.3 with the un-pushed check gone, 'unpushed' is REMOVABLE" "REMOVABLE" \
    "$(status_of "$JM1" unpushed)"
assert_eq "4.4 control — the mutant still keeps 'dirty' (it broke ONE gate)" "dirty" \
    "$(reason_of "$JM1" dirty)"
assert_eq "4.5 RESTORE — the shipped script keeps 'unpushed' again" "unpushed-and-unmerged" \
    "$(reason_of "$(sweep)" unpushed)"
assert_eq "4.6 RESTORE — and is back to exactly one removable" "1" \
    "$(sweep | jq -r '.removable' 2>/dev/null)"

# ---------------------------------------------------------------------------
# SECTION 5 — META-2: the DIRTY check.
# ---------------------------------------------------------------------------
echo "--- 5. META-2: the dirty check is load-bearing ---"
MUT_DIRTY="$FX/.claude/scripts/sweep-nodirty.mutant.sh"
awk 'index($0, "SWEEP_REASON=\"dirty\"") { print "    :  # MUTATED"; next } { print }' \
    "$SWEEP" > "$MUT_DIRTY"
assert_eq "5.1 the mutation changed the script (non-vacuous)" "1" \
    "$(cmp -s "$SWEEP" "$MUT_DIRTY" && echo 0 || echo 1)"
JM2=$(sweep --script "$MUT_DIRTY")
assert_eq "5.2 with the dirty check gone, 'dirty' is REMOVABLE" "REMOVABLE" \
    "$(status_of "$JM2" dirty)"
assert_eq "5.3 control — the mutant still keeps 'unpushed'" "unpushed-and-unmerged" \
    "$(reason_of "$JM2" unpushed)"
assert_eq "5.4 RESTORE — the shipped script keeps 'dirty' again" "dirty" \
    "$(reason_of "$(sweep)" dirty)"

# ---------------------------------------------------------------------------
# SECTION 6 — META-3: the TASK-CLOSED check.
# ---------------------------------------------------------------------------
echo "--- 6. META-3: the task-closed check is load-bearing ---"
MUT_TASK="$FX/.claude/scripts/sweep-notask.mutant.sh"
awk 'index($0, "SWEEP_REASON=\"task-not-closed\"") { print "    :  # MUTATED"; next } { print }' \
    "$SWEEP" > "$MUT_TASK"
assert_eq "6.1 the mutation changed the script (non-vacuous)" "1" \
    "$(cmp -s "$SWEEP" "$MUT_TASK" && echo 0 || echo 1)"
JM3=$(sweep --script "$MUT_TASK")
assert_eq "6.2 with the task check gone, the OPEN task's worktree is REMOVABLE" "REMOVABLE" \
    "$(status_of "$JM3" open-task)"
assert_eq "6.3 RESTORE — the shipped script keeps 'open-task' again" "task-not-closed" \
    "$(reason_of "$(sweep)" open-task)"

# ---------------------------------------------------------------------------
# SECTION 7 — the real --apply path, then META-4 on the --apply gate itself.
# ---------------------------------------------------------------------------
echo "--- 7. --apply, and META-4 on the --apply gate ---"
J7=$(sweep --apply)
assert_eq "7.1 --apply removes exactly the one removable worktree" "1" \
    "$(printf '%s' "$J7" | jq -r '.removed' 2>/dev/null)"
assert_eq "7.2 the removed worktree is gone from the git registry" "no" \
    "$(wt_present "$FX/.claude/worktrees/clean-merged-closed-old")"
assert_eq "7.3 ...and gone from disk" "no" \
    "$([ -d "$FX/.claude/worktrees/clean-merged-closed-old" ] && echo yes || echo no)"
# 6 = the main checkout + the 5 keepers; one of seven entries went away.
assert_eq "7.4 every keeper survived --apply" "6" \
    "$(git -C "$FX" worktree list --porcelain | grep -c '^worktree ' || true)"
assert_eq "7.5 the dirty worktree's uncommitted work is still on disk" "yes" \
    "$([ -f "$FX/.claude/worktrees/dirty/src/a.ts" ] && echo yes || echo no)"

# A fresh removable candidate for META-4.
add_wt "$FX/.claude/worktrees/redo" wt-sweep-redo push
seed_task "$FX/.claude/worktrees/redo" sweep-task-redo
touch -t 202001010000 "$FX/.claude/worktrees/redo"
assert_eq "7.6 control — the SHIPPED script's dry run leaves 'redo' in place" "yes" \
    "$(sweep >/dev/null 2>&1; wt_present "$FX/.claude/worktrees/redo")"

MUT_APPLY="$FX/.claude/scripts/sweep-noapplygate.mutant.sh"
awk 'index($0, "if [ \"$ARG_APPLY\" != \"1\" ]; then") { print "    if false; then  # MUTATED"; next } { print }' \
    "$SWEEP" > "$MUT_APPLY"
assert_eq "7.7 the mutation changed the script (non-vacuous)" "1" \
    "$(cmp -s "$SWEEP" "$MUT_APPLY" && echo 0 || echo 1)"
sweep --script "$MUT_APPLY" >/dev/null 2>&1
assert_eq "7.8 META-4: without the --apply gate, a DRY RUN deletes 'redo'" "no" \
    "$(wt_present "$FX/.claude/worktrees/redo")"

assert_eq "7.9 SAFETY — the plugin's real worktree-sweep.sh was never written to" \
    "$SWEEP_SHA_BEFORE" "$(shasum -a 256 "$PLUGIN_SWEEP" 2>/dev/null | awk '{print $1}')"

# ---------------------------------------------------------------------------
# SECTION 8 — the SessionEnd -> SessionStart report round trip.
#
# SessionEnd CANNOT BLOCK OR ENFORCE (output and exit code ignored), so its
# only job here is to persist a count; SessionStart is what the operator
# actually reads. The pair is asserted end to end because a report nobody
# surfaces is indistinguishable from no report at all.
#
# SYMLINK HAZARD: $FX/.claude/scripts/* are symlinks INTO the plugin. Each stub
# below is `rm -f` then a NEW file, never a write through the link; 8.10
# re-checksums the real script afterwards.
# ---------------------------------------------------------------------------
echo "--- 8. SessionEnd -> SessionStart round trip ---"
stub_script() { rm -f "$FX/.claude/scripts/$1"; printf '%s\n' '#!/bin/bash' 'exit 0' > "$FX/.claude/scripts/$1"; chmod +x "$FX/.claude/scripts/$1"; }
# model-select.sh probes the network (bounded, but seconds) and codex-detect.sh
# shells out; neither is under test here.
stub_script model-select.sh
stub_script codex-detect.sh

add_wt "$FX/.claude/worktrees/sess" wt-sweep-sess push
seed_task "$FX/.claude/worktrees/sess" sweep-task-redo
touch -t 202001010000 "$FX/.claude/worktrees/sess"
SWEEP_LOG="$FX/.claude/.qa-tracking/worktree-sweep.log"
SYNC_LOG="$FX/.claude/.qa-tracking/sync-errors.log"
rm -f "$SWEEP_LOG" "$SYNC_LOG"

SE_OUT=$(printf '%s' '{"reason":"clear"}' | CLAUDE_PROJECT_DIR="$FX" bash "$FX/.claude/scripts/session-end.sh" 2>/dev/null)
assert_eq "8.1 session-end still emits exactly {} with the sweep leg active" "{}" \
    "$(printf '%s' "$SE_OUT" | jq -c '.' 2>/dev/null)"
assert_eq "8.2 session-end recorded the sweepable count in its OWN log" "1" \
    "$(grep -c '1 sweepable worktree' "$SWEEP_LOG" 2>/dev/null || true)"
assert_eq "8.3 ...and NOT in sync-errors.log, which SessionStart renders as a bd failure" "no" \
    "$([ -s "$SYNC_LOG" ] && echo yes || echo no)"
assert_eq "8.4 the sweep did NOT remove anything from a hook" "yes" \
    "$(wt_present "$FX/.claude/worktrees/sess")"

SS_CTX=$(printf '%s' '{}' | CLAUDE_PROJECT_DIR="$FX" bash "$FX/.claude/scripts/session-start.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert_contains "8.5 SessionStart surfaces the sweep report as a warning" \
    "worktree-sweep at" "$SS_CTX"
assert_contains "8.6 ...naming the manual command, not claiming cleanup happened" \
    "worktree-sweep.sh (then --apply to remove)" "$SS_CTX"
assert_not_contains "8.7 ...and never as a bd sync failure" "bd sync failed" "$SS_CTX"
assert_eq "8.8 SessionStart truncated the log, so the warning fires once" "0" \
    "$(wc -c < "$SWEEP_LOG" 2>/dev/null | tr -d ' ')"
SS_CTX2=$(printf '%s' '{}' | CLAUDE_PROJECT_DIR="$FX" bash "$FX/.claude/scripts/session-start.sh" 2>/dev/null \
    | jq -r '.hookSpecificOutput.additionalContext // empty' 2>/dev/null)
assert_not_contains "8.9 a second SessionStart repeats nothing" "worktree-sweep at" "$SS_CTX2"

# session-end.sh runs under `set -e`, so a sweeper that dies mid-run must not
# take the hook's `echo "{}"` with it. Two shapes: exits non-zero with noise on
# stdout, and absent altogether (an install that predates this script).
rm -f "$FX/.claude/scripts/worktree-sweep.sh"
printf '%s\n' '#!/bin/bash' 'printf "boom\n"' 'exit 3' > "$FX/.claude/scripts/worktree-sweep.sh"
chmod +x "$FX/.claude/scripts/worktree-sweep.sh"
assert_eq "8.10 a FAILING sweeper still leaves session-end emitting {}" "{}" \
    "$(printf '%s' '{"reason":"clear"}' | CLAUDE_PROJECT_DIR="$FX" bash "$FX/.claude/scripts/session-end.sh" 2>/dev/null | jq -c '.' 2>/dev/null)"
rm -f "$FX/.claude/scripts/worktree-sweep.sh"
assert_eq "8.11 an ABSENT sweeper (pre-C1b install) likewise" "{}" \
    "$(printf '%s' '{"reason":"clear"}' | CLAUDE_PROJECT_DIR="$FX" bash "$FX/.claude/scripts/session-end.sh" 2>/dev/null | jq -c '.' 2>/dev/null)"

assert_eq "8.12 SAFETY — the plugin's real worktree-sweep.sh is STILL untouched" \
    "$SWEEP_SHA_BEFORE" "$(shasum -a 256 "$PLUGIN_SWEEP" 2>/dev/null | awk '{print $1}')"
