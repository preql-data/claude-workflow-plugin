#!/bin/bash
# post-edit.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers B5/B6/B9: append tracked
# file path to .qa-tracking/changed-files.txt, denylist build artifacts,
# race-safe dedup.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
PE="$FIXTURE/.claude/scripts/post-edit.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"
FILE="$TRACK/changed-files.txt"

# 1. Write a TS file -> appended to changed-files.txt + {} envelope.
OUT=$(printf '%s' '{"tool_input":{"file_path":"/tmp/foo.ts"}}' | bash "$PE")
assert_empty_envelope "post-edit: TS write emits {}" "$OUT"
assert_eq "post-edit: changed-files.txt created" "0" \
    "$([ -s "$FILE" ] && echo 0 || echo 1)"
LINES=$(grep -c '/tmp/foo.ts' "$FILE")
assert_eq "post-edit: TS path recorded once" "1" "$LINES"

# 2. Second write of the SAME file -> dedup-on-write IF flock is available,
# else dedup-at-read (the file may have duplicates which `sort -u` flattens).
# Either way, the UNIQUE count after a repeat write must be 1.
printf '%s' '{"tool_input":{"file_path":"/tmp/foo.ts"}}' | bash "$PE" >/dev/null
LINES=$(sort -u "$FILE" | grep -c '/tmp/foo.ts')
assert_eq "post-edit: dedup on repeat write (unique count)" "1" "$LINES"

# 3. Different file appended as a new line.
printf '%s' '{"tool_input":{"file_path":"/tmp/bar.md"}}' | bash "$PE" >/dev/null
UNIQUE=$(sort -u "$FILE" | wc -l | tr -d ' ')
assert_eq "post-edit: different file added" "2" "$UNIQUE"

# 4. Denylist: node_modules path -> NOT tracked, {} envelope.
OUT=$(printf '%s' '{"tool_input":{"file_path":"/tmp/node_modules/foo/bar.js"}}' | bash "$PE")
assert_empty_envelope "post-edit: denylist envelope" "$OUT"
DENIED=$(grep -c 'node_modules' "$FILE" 2>/dev/null || true)
DENIED=$(printf '%s' "$DENIED" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: node_modules NOT in tracking" "0" "${DENIED:-0}"

# 5. Denylist: .git path -> NOT tracked. (`grep -c` always prints the count
# on stdout AND exits non-zero when 0 — no need for `|| echo 0`.)
printf '%s' '{"tool_input":{"file_path":"/tmp/.git/index"}}' | bash "$PE" >/dev/null
GIT_LINES=$(grep -c '\.git' "$FILE" 2>/dev/null || true)
GIT_LINES=$(printf '%s' "$GIT_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: .git NOT tracked" "0" "${GIT_LINES:-0}"

# 6. Denylist: lockfile -> NOT tracked.
printf '%s' '{"tool_input":{"file_path":"/tmp/package-lock.json"}}' | bash "$PE" >/dev/null
LOCK_LINES=$(grep -c 'package-lock' "$FILE" 2>/dev/null || true)
LOCK_LINES=$(printf '%s' "$LOCK_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: package-lock NOT tracked" "0" "${LOCK_LINES:-0}"

# 7. Denylist: .min.js -> NOT tracked.
printf '%s' '{"tool_input":{"file_path":"/tmp/dist/app.min.js"}}' | bash "$PE" >/dev/null
MIN_LINES=$(grep -c 'app\.min\.js' "$FILE" 2>/dev/null || true)
MIN_LINES=$(printf '%s' "$MIN_LINES" | head -1 | tr -d '[:space:]')
assert_eq "post-edit: .min.js NOT tracked" "0" "${MIN_LINES:-0}"

# 8. Missing file_path -> {} envelope, no tracking change.
BEFORE=$(wc -l < "$FILE" | tr -d ' ')
OUT=$(printf '%s' '{"tool_input":{}}' | bash "$PE")
assert_empty_envelope "post-edit: missing file_path returns {}" "$OUT"
AFTER=$(wc -l < "$FILE" | tr -d ' ')
assert_eq "post-edit: missing file_path doesn't append" "$BEFORE" "$AFTER"

# 9. Alternative field name `path` (vs `file_path`) is also probed.
OUT=$(printf '%s' '{"tool_input":{"path":"/tmp/baz.py"}}' | bash "$PE")
assert_empty_envelope "post-edit: path-field envelope" "$OUT"
ALT=$(grep -c '/tmp/baz.py' "$FILE")
assert_eq "post-edit: tool_input.path also tracked" "1" "$ALT"

# 10. Permissive extensions (denylist not allowlist): .md / .json / .toml
# / .proto all tracked (B6 — replaced allowlist with denylist).
for f in "/tmp/README.md" "/tmp/config.json" "/tmp/Cargo.toml" "/tmp/service.proto"; do
    printf '%s' "{\"tool_input\":{\"file_path\":\"$f\"}}" | bash "$PE" >/dev/null
done
for f in "README.md" "config.json" "Cargo.toml" "service.proto"; do
    LN=$(grep -c "$f" "$FILE")
    assert_eq "post-edit: $f tracked (denylist not allowlist)" "1" "$LN"
done

# ===========================================================================
# Mutation-survivor kills (G2.6ix / claude-workflow-plugin-llh.5).
#
# The original C.3 sweep (task claude-workflow-plugin-6ix, theme F) left the
# post-edit.sh tracking/cadence logic uncovered: the L2 spec above asserts the
# dedup/denylist/envelope contract but NEVER drives the trim-at-1000 threshold,
# the every-10th-edit comment cadence, the sort|wc pipeline, the EDIT_COUNT
# increment, the CLAUDE_PROJECT_DIR default, or the LINE_COUNT default. Each
# block below kills one surviving mutant; every kill was proven mutant->FAIL /
# original->PASS during development. Survivor ids map to
# .claude/.mutation-runs/20260612T063107Z/verdict.json (the original record);
# the current re-sweep is .claude/.mutation-runs/20260613T102846Z.
#
# These need a SECOND fixture (bd-initialised, isolated counters) because the
# fixture above has accumulated tracking/edit-count state and no .beads. We
# build a fresh one per the mk_fixture contract.
mk_fixture
FIXTURE2="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
PE2="$FIXTURE2/.claude/scripts/post-edit.sh"
TRACK2="$FIXTURE2/.claude/.qa-tracking"
FILE2="$TRACK2/changed-files.txt"
ECF="$TRACK2/edit-count"

# Helper: seed changed-files.txt with N synthetic unique tracked paths.
seed_tracking_lines() {
    awk -v n="$1" 'BEGIN{for(i=1;i<=n;i++)print "src/f"i".ts"}' > "$FILE2"
}
# Helper: run post-edit once for a given file path (returns its stdout).
run_pe2() {
    printf '%s' "{\"tool_input\":{\"file_path\":\"$1\"}}" | bash "$PE2"
}
# Helper: count Progress: comments on a task.
progress_comment_count() {
    bd show "$1" --json 2>/dev/null \
        | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | map(select(.text|test("Progress:")))|length' \
        2>/dev/null || echo "0"
}

# --- id32 (F8, line 114): EDIT_COUNT increment + 1 vs + 2 -----------------
# A single edit from a zero counter must leave the persisted edit-count at 1.
# The +2 mutant writes 2 (and halves the comment cadence). Needs an active
# task + .beads so the EDIT_COUNT block runs.
TID_INC=$(cd "$FIXTURE2" && bd create "pe increment" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_INC" > "$TRACK2/current-task"
rm -f "$ECF"
run_pe2 "src/inc.ts" >/dev/null
INC_AFTER=$(cat "$ECF" 2>/dev/null | tr -d '[:space:]')
assert_eq "post-edit mut32: one edit increments edit-count by exactly 1 (not 2)" \
    "1" "$INC_AFTER"

# --- id26 (F1, line 117): comment cadence % 10 -eq 0 vs -ne 0 -------------
# At edit #9 (not a multiple of 10) the original posts NO progress comment.
# The -ne mutant posts on every non-multiple, so #9 would post one.
TID_CAD=$(cd "$FIXTURE2" && bd create "pe cadence" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_CAD" > "$TRACK2/current-task"
seed_tracking_lines 3
printf '8' > "$ECF"            # next edit -> 9
run_pe2 "src/cad.ts" >/dev/null
CAD9=$(progress_comment_count "$TID_CAD")
assert_eq "post-edit mut26: NO progress comment at edit #9 (cadence fires only on multiples of 10)" \
    "0" "$CAD9"

# --- id30 (F5, line 120): drop the wc -l pipeline segment -----------------
# At edit #10 the original posts "Progress: <integer> files edited". Dropping
# wc -l makes UNIQUE_COUNT the newline-joined file list, so the comment reads
# "Progress: <path>\n<path>... files edited". Assert the count field is a bare
# integer immediately followed by " files edited".
TID_PIPE=$(cd "$FIXTURE2" && bd create "pe pipeline" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_PIPE" > "$TRACK2/current-task"
seed_tracking_lines 3
printf '9' > "$ECF"            # next edit -> 10
run_pe2 "src/f1.ts" >/dev/null
PIPE_TEXT=$(bd show "$TID_PIPE" --json 2>/dev/null \
    | jq -r '(if type=="array" then .[0].comments else .comments end)//[] | map(select(.text|test("Progress:")))|.[0].text // ""' 2>/dev/null)
assert_match "post-edit mut30: progress comment count is a bare integer (wc -l pipeline intact)" \
    "Progress: [0-9]+ files edited" "$PIPE_TEXT"
# Negative: the file-list form (a slash path before 'files edited') must NOT appear.
PIPE_BADFORM=$(printf '%s' "$PIPE_TEXT" | grep -c 'src/.*files edited' || true)
PIPE_BADFORM=$(printf '%s' "$PIPE_BADFORM" | tr -d '[:space:]')
assert_eq "post-edit mut30: progress comment is NOT the raw file list" "0" "$PIPE_BADFORM"

# --- id25 (F1, line 98): trim threshold -gt 1000 vs -le 1000 --------------
# A small tracking file (well under 1000 lines) must NOT be trimmed. The -le
# mutant trims on every edit (sort -u | tail -500). Seed 500 unique lines,
# add one NEW path; the original leaves 501 (no trim), the mutant collapses
# to 500. Use a fixture with NO active task / no .beads churn so only the
# trim path is exercised. We reuse FIXTURE2 but clear the task first.
rm -f "$TRACK2/current-task"
seed_tracking_lines 500
run_pe2 "src/trim-new-small.ts" >/dev/null
SMALL_COUNT=$(wc -l < "$FILE2" | tr -d ' ')
assert_eq "post-edit mut25: small tracking file (<=1000) is NOT trimmed (count stays 501)" \
    "501" "$SMALL_COUNT"

# --- id31 (F6, line 98): trim boundary -gt 1000 vs -ge 1000 ---------------
# At exactly 1000 lines the original must NOT trim ([1000 -gt 1000] = false);
# the -ge mutant trims to 500. Seed 999 unique lines then append one NEW path
# (this platform's no-flock append makes wc == 1000 exactly).
seed_tracking_lines 999
run_pe2 "src/trim-boundary-new.ts" >/dev/null
BOUNDARY_COUNT=$(wc -l < "$FILE2" | tr -d ' ')
assert_eq "post-edit mut31: at exactly 1000 lines the file is NOT trimmed (boundary; count stays 1000)" \
    "1000" "$BOUNDARY_COUNT"

# --- id28 (F4, line 16): CLAUDE_PROJECT_DIR default removal ----------------
# Running the hook with CLAUDE_PROJECT_DIR UNSET must still work via the
# $(pwd) fallback: rc 0 and the tracking file lands under the cwd. The mutant
# ${CLAUDE_PROJECT_DIR} (no default) yields PROJECT_DIR='', mkdir -p
# '/.claude/.qa-tracking' fails under set -e, the hook aborts non-zero and no
# tracking file is written. Run in a throwaway cwd so we don't write into the
# fixture root.
ID28_CWD=$(mktemp -d -t pe-id28-cwd.XXXXXX)
ID28_RC=0
( cd "$ID28_CWD" && env -u CLAUDE_PROJECT_DIR bash "$PE2" <<<'{"tool_input":{"file_path":"src/env.ts"}}' >/dev/null 2>&1 ) || ID28_RC=$?
ID28_TRACKED="no"
[ -s "$ID28_CWD/.claude/.qa-tracking/changed-files.txt" ] && ID28_TRACKED="yes"
rm -rf "$ID28_CWD"
assert_eq "post-edit mut28: CLAUDE_PROJECT_DIR unset -> hook still exits 0 (pwd fallback)" \
    "0" "$ID28_RC"
assert_eq "post-edit mut28: CLAUDE_PROJECT_DIR unset -> tracking still written (pwd fallback)" \
    "yes" "$ID28_TRACKED"

# --- id29 (F4, line 98): LINE_COUNT default removal ------------------------
# When wc emits an empty string the original's ${LINE_COUNT:-0} normalises to
# "0" so [ 0 -gt 1000 ] is clean. The mutant ${LINE_COUNT} leaves it empty so
# [ "" -gt 1000 ] prints an 'integer/unary' error on stderr. Stub wc to emit
# empty and assert the hook's stderr carries NO such error. (No .beads dir in
# this throwaway cwd so the cadence block is skipped — isolates the LINE_COUNT
# path.)
ID29_DIR=$(mktemp -d -t pe-id29.XXXXXX)
mkdir -p "$ID29_DIR/.claude/.qa-tracking" "$ID29_DIR/bin"
printf 'src/seed.ts\n' > "$ID29_DIR/.claude/.qa-tracking/changed-files.txt"
printf '#!/bin/bash\nprintf ""\n' > "$ID29_DIR/bin/wc"; chmod +x "$ID29_DIR/bin/wc"
ID29_ERR=$( cd "$ID29_DIR" && PATH="$ID29_DIR/bin:$PATH" CLAUDE_PROJECT_DIR="$ID29_DIR" bash "$PE2" <<<'{"tool_input":{"file_path":"src/seed.ts"}}' 2>&1 1>/dev/null )
rm -rf "$ID29_DIR"
ID29_BAD=$(printf '%s' "$ID29_ERR" | grep -cE 'integer expression expected|unary operator expected' || true)
ID29_BAD=$(printf '%s' "$ID29_BAD" | tr -d '[:space:]')
assert_eq "post-edit mut29: empty LINE_COUNT does NOT trip an integer-expression error (\${LINE_COUNT:-0} default intact)" \
    "0" "$ID29_BAD"

# --- META-TEST: prove the mut32 increment assertion is load-bearing -------
# Build a copy of post-edit.sh with the +1 increment mutated to +2 and re-run
# the increment scenario; the edit-count must read 2 (so the mut32 assertion
# would FAIL). This proves the assertion is sensitive to the regression it
# names, not passing for an incidental reason.
PE2_REAL=$(readlink "$PE2" || printf '%s' "$PE2")
PE2_MUT="$FIXTURE2/post-edit-mut32.sh"
awk 'NR==114 && /EDIT_COUNT \+ 1/ {print "    EDIT_COUNT=$((EDIT_COUNT + 2))"; next} {print}' \
    "$PE2_REAL" > "$PE2_MUT"
chmod +x "$PE2_MUT"
# Sanity: the mutation actually landed (line 114 now reads + 2).
MUT_LANDED=$(sed -n '114p' "$PE2_MUT" | grep -c 'EDIT_COUNT + 2' || true)
MUT_LANDED=$(printf '%s' "$MUT_LANDED" | tr -d '[:space:]')
assert_eq "post-edit META: +2 mutation applied to copy at line 114" "1" "$MUT_LANDED"
TID_META=$(cd "$FIXTURE2" && bd create "pe meta increment" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
printf '%s\n' "$TID_META" > "$TRACK2/current-task"
rm -f "$ECF"
printf '%s' '{"tool_input":{"file_path":"src/meta.ts"}}' | bash "$PE2_MUT" >/dev/null
META_AFTER=$(cat "$ECF" 2>/dev/null | tr -d '[:space:]')
assert_eq "post-edit META: under +2 mutant one edit yields edit-count 2 (mut32 assertion WOULD fail)" \
    "2" "$META_AFTER"

[ "$FAIL" -eq 0 ]
