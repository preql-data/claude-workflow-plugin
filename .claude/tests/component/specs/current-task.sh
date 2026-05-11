#!/bin/bash
# current-task.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers the F3 single-source-of-
# truth contract for the active task id, plus the I8 multi-repo extension
# (Phase 6b) that persists a repo fingerprint alongside the id.
#
# Subcommands exercised: set, get, get-repo, get-json, clear.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
CT="$FIXTURE/.claude/scripts/current-task.sh"
TRACK="$FIXTURE/.claude/.qa-tracking"

# 1. `get` on a fresh fixture returns empty (no file).
OUT=$(bash "$CT" get)
assert_eq "current-task: get on fresh fixture is empty" "" "$OUT"

# 2. `set <id>` writes the id + repo fingerprint atomically.
bash "$CT" set "task-abc.42"
OUT=$(bash "$CT" get)
assert_eq "current-task: get after set returns the id" "task-abc.42" "$OUT"
assert_eq "current-task: current-task file persisted" "0" \
    "$([ -s "$TRACK/current-task" ] && echo 0 || echo 1)"

# 3. Repo fingerprint persistence. The fixture is in tempdir, which we
# *initialise as a git repo* now so the helper has a toplevel to record.
(cd "$FIXTURE" && git init -q 2>/dev/null || true)
bash "$CT" set "task-with-repo.1"
OUT_REPO=$(bash "$CT" get-repo)
# get-repo should be non-empty under a git repo. The exact path varies by
# tempdir, so we assert "non-empty AND ends with the fixture's basename".
FB=$(basename "$FIXTURE")
assert_match "current-task: get-repo non-empty under git init" "$FB$" "$OUT_REPO"

# 4. get-json emits a {task, repo} envelope.
JSON=$(bash "$CT" get-json)
assert_json_field "current-task: get-json .task" "$JSON" '.task' "task-with-repo.1"
# .repo should at least be non-empty (we just set it).
REPO_FIELD=$(printf '%s' "$JSON" | jq -r '.repo // empty')
assert_eq "current-task: get-json .repo non-empty" "0" \
    "$([ -n "$REPO_FIELD" ] && echo 0 || echo 1)"

# 5. clear removes both files.
bash "$CT" clear
assert_eq "current-task: clear removed current-task file" "1" \
    "$([ -s "$TRACK/current-task" ] && echo 0 || echo 1)"
assert_eq "current-task: clear removed current-task.repo file" "1" \
    "$([ -s "$TRACK/current-task.repo" ] && echo 0 || echo 1)"
# clear is idempotent — calling twice doesn't error.
bash "$CT" clear
assert_eq "current-task: clear is idempotent" "0" "$?"

# 6. set rejects whitespace in the id.
RC=0
bash "$CT" set "bad id" 2>/dev/null || RC=$?
assert_eq "current-task: set rejects whitespace in id" "1" "$RC"

# 7. set with no arg fails usage.
RC=0
bash "$CT" set 2>/dev/null || RC=$?
assert_eq "current-task: set with no arg exits non-zero" "1" "$RC"

# 8. get-json without jq still produces well-formed JSON (the helper
# manually hand-rolls JSON when jq is missing). We can't easily strip jq
# from PATH inside the subshell, but we CAN verify the with-jq path
# round-trips through jq cleanly.
bash "$CT" set "json-roundtrip.1"
JSON2=$(bash "$CT" get-json)
ROUNDTRIP=$(printf '%s' "$JSON2" | jq -c '.' 2>/dev/null || echo "INVALID")
assert_match "current-task: get-json JSON round-trips through jq" \
    '"task":"json-roundtrip\.1"' "$ROUNDTRIP"

# Exit non-zero if any assertion failed (the runner reads this).
[ "$FAIL" -eq 0 ]
