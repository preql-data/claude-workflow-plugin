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

[ "$FAIL" -eq 0 ]
