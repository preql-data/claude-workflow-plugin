#!/bin/bash
# bd-compat.sh — L2 smoke spec pinning the bd CLI contract (G2.bd-compat,
# claude-workflow-plugin-llh.6).
#
# WHY THIS EXISTS
#   The hooks and MCP servers parse bd output shapes that were OBSERVED on
#   bd 0.47.1, never contracted. Two real capture bugs came from exactly
#   this gap (see LESSONS.md / CHANGELOG 3.4.0):
#     - daemon flush race: daemon-mode `bd create` enqueues the JSONL
#       export, so a read immediately after create saw a stale file
#       (beadsCapture.ts now forces BD_NO_DAEMON=1).
#     - 366.5 sync hash-match short-circuit: `bd sync --flush-only` exits 0
#       but writes nothing when issues.jsonl is absent and the metadata
#       hash matches a sibling baseline; the harness gained a
#       `bd export --force -o` fallback.
#   A future bd upgrade can silently break the QA gate the same way. This
#   spec runs every bd invocation the production scripts depend on against
#   the INSTALLED bd, inside a sandbox repo, and asserts the exact shape
#   each caller parses. On ANY mismatch it fails loudly, naming the
#   command, the assertion, and the supported range.
#
# PINNED INVENTORY — 32 distinct command+flag combinations
#   (consumer -> what shape the caller parses)
#    1. bd --version                  session-start.sh:103  first line contains semver
#    2. bd init                       installer/fixtures    exit 0; .beads/ created
#    3. bd create <t> -t task -p 2 --json
#                                     tech-debt.sh:107      stdout = single JSON OBJECT
#                                                           (not array); jq '.id // empty'
#                                                           non-empty; id =~ [a-z0-9-]+
#    4. bd create <t> -t task -p 2 --deps blocks:<id> --json
#                                     tech-debt.sh:107      accepted; dependency recorded
#    5. bd create <t> -t task -p 1 -l <l1>,<l2> --json
#                                     bd-mcp bd_create.js   labels attached at birth
#    6. bd create <t> -t epic -p 1 --json
#                                     bd-mcp bd_create.js   epic id parses
#    7. bd create <t> -t task --parent <epic> --json
#                                     bd-mcp bd_create.js   child id = <epic>.<n> (dotted)
#    8. bd show <id> --json           qa-gate.sh:348, verify-before-stop.sh:319,
#                                     epic-gate.sh:69/87/98/112/133, bd-mcp tools
#                                                           top-level OBJECT or 1-elem
#                                                           ARRAY (0.47.1: array);
#                                                           .labels string[]; .status;
#                                                           .notes; .comments[].text;
#                                                           .dependencies[] with
#                                                           dependency_type/issue_type;
#                                                           .dependents[] (epic side)
#    9. bd show <id> --json --refs    bd-mcp bd_list.js     exit 0; stdout valid JSON
#   10. bd label add <id> <label>     qa-gate.sh:362, verify-before-stop.sh:628/786,
#                                     bd-mcp bd_label.js    exit 0; visible in show .labels
#   11. bd label remove <id> <label>  qa-gate.sh:366        exit 0; absent afterwards
#   12. bd comments add <id> <text>   qa-gate.sh:374, post-edit.sh:121,
#       (|| bd comment add fallback)  verify-before-stop.sh:634/795, bd-mcp
#                                                           chain exits 0; text lands in
#                                                           show .comments[].text
#       NOTE: on 0.47.1 the singular `bd comment add` exits 1 — the chain
#       rides entirely on the plural form. Pin the chain, not the leg.
#   13. bd update <id> --status closed
#                                     verify-before-stop.sh:569/1068
#                                                           exit 0; show .status=closed
#   14. bd update <id> --notes <text> bd-mcp bd_doc.js      exit 0; notes round-trip
#   15. bd update <id> -s in_progress --add-label <l> --json
#                                     bd-mcp bd_update.js   stdout JSON (object OR 1-elem
#                                                           array); status/labels updated
#   16. bd update <id> --claim        bd-mcp bd_update.js   exit 0; status=in_progress;
#                                                           assignee set
#   17. bd close <id> -r <r> --json   bd-mcp bd_update.js   unblocked: exit 0 + closed.
#                                                           QUIRK (0.47.x): on a BLOCKED
#                                                           issue it exits 0, prints
#                                                           "cannot close", and changes
#                                                           NOTHING — bd-mcp reports
#                                                           success on exit code alone,
#                                                           so this no-op contract is
#                                                           load-bearing. Pin both.
#   18. bd list --json                bd-mcp bd_list.js     JSON array; entries have
#                                                           .id + .status
#   19. bd list --label <l> --status open --json
#                                     session-start.sh:214/247
#                                                           JSON array; jq length numeric
#   20. bd list --label <l> --status open   (text mode)
#                                     session-start.sh:219/252
#                                                           exit 0; lists the id
#   21. bd list --type epic --json    epic-gate.sh:76       JSON array containing epics.
#                                       NOTE: 0.47.1 list entries do NOT carry
#                                       .dependents — epic-gate's fallback scan yields
#                                       empty there; only the show-based primary path
#                                       (#8) resolves parents. Do not "fix" a parent
#                                       lookup by leaning on the list fallback.
#   22. bd blocked --json             session-start.sh:186, bd-mcp
#                                                           JSON array; blocked ids listed
#   23. bd blocked                    session-start.sh:191  exit 0; text lists the id
#   24. bd ready --json               bd-mcp bd_list.js     JSON array
#   25. bd dep add <dependent> <blocker>
#                                     bd-mcp bd_dep.js      exit 0; show <dependent>
#                                                           .dependencies[].id has blocker
#   26. bd dep relate <a> <b>         bd-mcp bd_dep.js      exit 0
#   27. bd prime                      session-start.sh:159  exit 0; non-empty stdout
#   28. bd doctor --quiet             session-start.sh:34   terminates; DB still readable
#                                                           (caller ignores exit via ||true)
#   29. bd sync                       session-end.sh:25     terminates rc 0|1; on failure
#                                                           the error text goes to STDERR
#                                                           (session-end logs stderr line 1)
#   30. BD_NO_DAEMON=1 bd sync --flush-only
#                                     e2e lib/beadsCapture.ts
#                                                           exit 0; materializes
#                                                           .beads/issues.jsonl with the
#                                                           freshly created issue
#   31. BD_NO_DAEMON=1 bd export --force -o .beads/issues.jsonl
#                                     e2e lib/beadsCapture.ts (366.5 fallback)
#                                                           exit 0; ALWAYS rewrites the
#                                                           file from the DB, even when
#                                                           deleted — the regression
#                                                           anchor for the 366.5 bug
#   32. bd label list-all --json (|| text fallback)
#                                     bd-mcp bd_label.js    chain succeeds
#
#   Not separately pinned (covered by the rows above): multi-id
#   `bd label add <id1> <id2> <label>` (same shape family as #10) and
#   bd_doc.js's `update <id> --notes <c> --json` (union of #14 + #15).
#   lessons.sh and current-task.sh make NO bd invocations (verified by
#   grep at pin time).
#
# FAILURE WORDING CONTRACT
#   Every mismatch prints:
#     bd <version> output shape mismatch for '<cmd>' — supported range:
#     >=0.47 <(next-known-break...)  Failing assertion: <name>
#
# META-TEST
#   A PATH-shimmed fake bd returns a wrong shape (labels as a string, not
#   an array) for `show <id> --json`; the spec re-runs the SAME pinned
#   check function against it in a counter-isolated subshell and asserts
#   the check fails naming that command — proving the assertions bite.
#
# README.md "Supported bd range" points here as the compatibility oracle.

set -u

# Capture the real bd binary BEFORE mk_fixture prepends its --no-daemon
# wrapper to PATH. The BD_NO_DAEMON section must exercise the env-var
# path itself (exactly how beadsCapture.ts suppresses the daemon), not
# the wrapper's injected flag.
REAL_BD=$(command -v bd 2>/dev/null || true)

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip

# ---------------------------------------------------------------------------
# Spec header: print the detected bd version (required by the G2 contract).

BD_VERSION_RAW=$(bd --version 2>/dev/null | head -1 || echo "")
# Verbatim parse from session-start.sh:104 (pinned invocation #1).
BD_VERSION_NUM=$(echo "$BD_VERSION_RAW" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)
BD_VERSION_DETECTED="${BD_VERSION_NUM:-unknown}"
printf 'bd-compat: pinning bd output shapes against installed: %s\n' \
    "${BD_VERSION_RAW:-<bd --version produced no output>}"

NEXT_KNOWN_BREAK="(next-known-break: none recorded — this bd version is the first; update README.md 'Supported bd range' and this spec)"

shape_mismatch_banner() {
    # $1 = pinned command label, $2 = assertion name
    printf "bd %s output shape mismatch for '%s' — supported range: >=0.47 <%s Failing assertion: %s\n" \
        "$BD_VERSION_DETECTED" "$1" "$NEXT_KNOWN_BREAK" "$2"
}

# Assertion wrappers: delegate to the lib helpers (so PASS/FAIL accounting
# stays tier-consistent) and append the loud mismatch banner on failure.
shape_assert_eq() {
    local cmd="$1" name="$2" expected="$3" actual="$4"
    local before="$FAIL"
    assert_eq "bd-compat[$cmd]: $name" "$expected" "$actual"
    if [ "$FAIL" -gt "$before" ]; then shape_mismatch_banner "$cmd" "$name"; fi
    return 0
}

shape_assert_match() {
    local cmd="$1" name="$2" pattern="$3" actual="$4"
    local before="$FAIL"
    assert_match "bd-compat[$cmd]: $name" "$pattern" "$actual"
    if [ "$FAIL" -gt "$before" ]; then shape_mismatch_banner "$cmd" "$name"; fi
    return 0
}

shape_assert_contains() {
    local cmd="$1" name="$2" needle="$3" haystack="$4"
    local before="$FAIL"
    assert_contains "bd-compat[$cmd]: $name" "$needle" "$haystack"
    if [ "$FAIL" -gt "$before" ]; then shape_mismatch_banner "$cmd" "$name"; fi
    return 0
}

# ---------------------------------------------------------------------------
# Production parse replicas — jq expressions copied VERBATIM from the
# consuming scripts. If bd changes shape, these return wrong/empty values
# and the pins above them fail. Never "improve" these expressions here;
# they must drift in lockstep with the production scripts they mirror.

production_get_labels() {
    # qa-gate.sh:348 get_labels / verify-before-stop.sh:319 task_has_label.
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null \
        || echo ""
}

production_get_status() {
    # epic-gate.sh:133 status_of.
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].status else .status end // "unknown"' 2>/dev/null \
        || echo "unknown"
}

production_get_notes() {
    # epic-gate.sh files_changed_of stage 1 (notes extraction).
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].notes else .notes end // ""' 2>/dev/null \
        || echo ""
}

production_parent_epic_of() {
    # epic-gate.sh:69 parent_epic_of PRIMARY path (the list-scan fallback
    # is dead on 0.47.1 — see inventory note #21).
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0] else . end
                 | (.dependencies // [])
                 | map(select(.dependency_type == "parent-child" and .issue_type == "epic"))
                 | .[0].id // empty' 2>/dev/null || echo ""
}

production_sub_tasks_of() {
    # epic-gate.sh:87 sub_tasks_of.
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0] else . end
                 | (.dependents // [])
                 | map(select(.dependency_type == "parent-child"))
                 | .[].id' 2>/dev/null || true
}

# Shared by the REAL run and the META-TEST below. One pinned assertion.
check_show_labels_shape() {
    local got
    got=$(production_get_labels "$1")
    shape_assert_contains "show <id> --json" \
        "labels parse via qa-gate.sh get_labels jq (array of strings)" \
        "qa-pending" "$got"
}

# ---------------------------------------------------------------------------
# Sandbox: a fresh git repo with `bd init`, nested inside the fixture so
# the fixture's cleanup trap removes it. The dirname is deliberately
# lowercase-hyphen ("sandbox-repo") because bd derives the issue-id prefix
# from it, and the id-format pin (#3) asserts the production-like
# [a-z0-9-]+ shape. Without a git repo bd 0.47.1 falls back to long
# MIXED-CASE random ids ("could not compute repository ID"), so git init
# + user config are part of the faithful setup, matching the real
# project's conditions.

SANDBOX="$FIXTURE/bdcompat/sandbox-repo"
mkdir -p "$SANDBOX"
(
    cd "$SANDBOX" \
        && git init -q . \
        && git config user.email "bd-compat@example.invalid" \
        && git config user.name "bd-compat-spec"
) >/dev/null 2>&1
cd "$SANDBOX" || exit 1

# Pin #2: bd init in a fresh repo.
INIT_RC=0
bd init >/dev/null 2>&1 || INIT_RC=$?
shape_assert_eq "init" "bd init exits 0 in a fresh sandbox repo" "0" "$INIT_RC"
shape_assert_eq "init" "bd init creates .beads/" "0" \
    "$([ -d "$SANDBOX/.beads" ] && echo 0 || echo 1)"

# Pin #1: version line shape (session-start.sh's exact grep already ran).
shape_assert_match "--version" \
    "first line contains a dotted semver (session-start.sh:104 parse)" \
    '^[0-9]+\.[0-9]+(\.[0-9]+)?$' "$BD_VERSION_DETECTED"

# Range floor: README claims >=0.47. version_cmp replica (session-start.sh:61).
VERSION_FLOOR_CMP="equal"
if [ "$BD_VERSION_DETECTED" != "0.47" ]; then
    VERSION_FLOOR_SORTED=$(printf '%s\n%s\n' "$BD_VERSION_DETECTED" "0.47" | sort -V | head -1)
    if [ "$VERSION_FLOOR_SORTED" = "$BD_VERSION_DETECTED" ]; then
        VERSION_FLOOR_CMP="older"
    else
        VERSION_FLOOR_CMP="newer"
    fi
fi
shape_assert_match "--version" \
    "installed bd satisfies the README floor >=0.47" \
    '^(equal|newer)$' "$VERSION_FLOOR_CMP"

# ---------------------------------------------------------------------------
# Phase 1 — creates (pins #3, #4, #5, #6, #7).

# Pin #3: the EXACT tech-debt.sh invocation and parse. tech-debt.sh pipes
# stdout into `jq -r '.id // empty'`, which only works on an OBJECT — if a
# future bd returned a 1-element array here (as show/update already do),
# tech-debt would silently lose every created-task id.
CREATE_OUT=$(bd create "bd-compat probe alpha" -t task -p 2 --json 2>/dev/null || echo "")
CREATE_TYPE=$(printf '%s' "$CREATE_OUT" | jq -r 'type' 2>/dev/null || echo "unparseable")
shape_assert_eq "create <title> -t task -p 2 --json" \
    "stdout is a single JSON object (tech-debt.sh .id parse breaks on array)" \
    "object" "$CREATE_TYPE"
TID_A=$(printf '%s' "$CREATE_OUT" | jq -r '.id // empty' 2>/dev/null || echo "")
shape_assert_match "create <title> -t task -p 2 --json" \
    ".id parses via tech-debt.sh jq and matches [a-z0-9-]+" \
    '^[a-z0-9][a-z0-9-]*$' "$TID_A"

# Pin #5: bd-mcp create with labels at birth.
TID_B=$(bd create "bd-compat probe bravo" -t task -p 1 -l devops,qa-pending --json 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null || echo "")
shape_assert_match "create <title> -t task -p 1 -l <l1>,<l2> --json" \
    "create with -l returns a parseable id" '^[a-z0-9][a-z0-9-]*$' "$TID_B"
LABELS_B=$(production_get_labels "$TID_B")
shape_assert_contains "create <title> -t task -p 1 -l <l1>,<l2> --json" \
    "labels attached at birth are visible in show --json .labels (devops)" \
    "devops" "$LABELS_B"
shape_assert_contains "create <title> -t task -p 1 -l <l1>,<l2> --json" \
    "labels attached at birth are visible in show --json .labels (qa-pending)" \
    "qa-pending" "$LABELS_B"

# Pins #6 + #7: epic and dotted child id (bd-mcp bd_create_epic path).
EPIC_ID=$(bd create "bd-compat probe epic" -t epic -p 1 --json 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null || echo "")
shape_assert_match "create <title> -t epic -p 1 --json" \
    "epic id parses" '^[a-z0-9][a-z0-9-]*$' "$EPIC_ID"
CHILD_ID=$(bd create "bd-compat probe child" -t task --parent "$EPIC_ID" --json 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null || echo "")
shape_assert_match "create <title> -t task --parent <epic> --json" \
    "child id is the dotted <epic>.<n> form bd-mcp validateTaskId accepts" \
    '^[a-z0-9][a-z0-9.-]*\.[0-9]+$' "$CHILD_ID"

# Supporting cast for later phases (re-uses pin #3's command shape).
TID_C=$(bd create "bd-compat probe charlie" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || echo "")
TID_E=$(bd create "bd-compat probe echo" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || echo "")
TID_F=$(bd create "bd-compat probe foxtrot" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || echo "")
TID_G=$(bd create "bd-compat probe golf" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || echo "")

# Pin #4: tech-debt.sh's --deps form (new task blocked by the active one).
TID_D=$(bd create "bd-compat probe debt" -t task -p 2 --deps "blocks:$TID_A" --json 2>/dev/null \
    | jq -r '.id // empty' 2>/dev/null || echo "")
shape_assert_match "create <title> -t task -p 2 --deps blocks:<id> --json" \
    "create with --deps returns a parseable id" '^[a-z0-9][a-z0-9-]*$' "$TID_D"
DEPS_D=$(bd show "$TID_D" --json 2>/dev/null \
    | jq -r 'if type == "array" then .[0] else . end | (.dependencies // []) | map(.id) | join(",")' 2>/dev/null || echo "")
shape_assert_contains "create <title> -t task -p 2 --deps blocks:<id> --json" \
    "--deps blocks:<id> records the dependency (visible in show .dependencies)" \
    "$TID_A" "$DEPS_D"

# ---------------------------------------------------------------------------
# Phase 2 — show/label/comment/notes pins on TID_A while it is still open
# (pins #8, #10, #12, #14 and the shared meta-check).

# Pin #8a: top-level shape of show --json is object OR 1-element array
# (0.47.1 emits the array form — both qa-gate.sh and bd-mcp's
# normalizeShowResult handle either; anything else breaks both).
SHOW_TYPE=$(bd show "$TID_A" --json 2>/dev/null | jq -r 'type' 2>/dev/null || echo "unparseable")
shape_assert_match "show <id> --json" \
    "top-level JSON type is object or array (both production parsers handle only these)" \
    '^(object|array)$' "$SHOW_TYPE"

# Pin #8b: status via the verbatim epic-gate jq.
shape_assert_eq "show <id> --json" \
    "status parses via epic-gate.sh status_of jq" \
    "open" "$(production_get_status "$TID_A")"

# Pin #10: label add — exit code 0 AND visible via the production jq.
LBL_RC=0
bd label add "$TID_A" qa-pending >/dev/null 2>&1 || LBL_RC=$?
shape_assert_eq "label add <id> <label>" "exits 0 (qa-gate.sh add_label contract)" "0" "$LBL_RC"
check_show_labels_shape "$TID_A"

# Pin #12: the qa-gate.sh add_comment chain, verbatim fallback order.
COMMENT_MARKER="bd-compat-comment-marker-7c4e"
CMT_RC=0
bd comments add "$TID_A" "$COMMENT_MARKER" >/dev/null 2>&1 \
    || bd comment add "$TID_A" "$COMMENT_MARKER" >/dev/null 2>&1 \
    || CMT_RC=1
shape_assert_eq "comments add <id> <text>" \
    "add_comment chain (comments add || comment add) exits 0" "0" "$CMT_RC"
COMMENTS_JSON=$(bd show "$TID_A" --json 2>/dev/null \
    | jq -c 'if type == "array" then .[0] else . end | .comments // []' 2>/dev/null || echo "[]")
shape_assert_match "show <id> --json" \
    ".comments is a non-empty array after comments add" '^\[.+\]$' "$COMMENTS_JSON"
shape_assert_contains "show <id> --json" \
    "comment text round-trips into show .comments" "$COMMENT_MARKER" "$COMMENTS_JSON"
COMMENT_HAS_TEXT=$(printf '%s' "$COMMENTS_JSON" | jq -r '.[0] | has("text")' 2>/dev/null || echo "false")
shape_assert_eq "show <id> --json" \
    "comment objects expose a .text key (bd-mcp bd_list_comments consumer)" \
    "true" "$COMMENT_HAS_TEXT"

# Pin #14: notes write + round-trip via the verbatim epic-gate notes jq.
NOTES_MARKER="bd-compat-notes-marker-19af"
NOTES_RC=0
bd update "$TID_A" --notes "$NOTES_MARKER" >/dev/null 2>&1 || NOTES_RC=$?
shape_assert_eq "update <id> --notes <text>" "exits 0" "0" "$NOTES_RC"
shape_assert_eq "show <id> --json" \
    "notes round-trip via epic-gate.sh notes jq" \
    "$NOTES_MARKER" "$(production_get_notes "$TID_A")"

# ---------------------------------------------------------------------------
# Phase 3 — list/blocked/ready pins (#18, #19, #20, #21, #22, #23, #24)
# and dependency pins (#25, #26). TID_A is open + qa-pending here.

# Pin #18: bd list --json is an array whose entries carry .id and .status.
LIST_TYPE=$(bd list --json 2>/dev/null | jq -r 'type' 2>/dev/null || echo "unparseable")
shape_assert_eq "list --json" "top-level JSON type is array" "array" "$LIST_TYPE"
LIST_ENTRY_SHAPE=$(bd list --json 2>/dev/null \
    | jq -r '.[0] | (has("id") and has("status"))' 2>/dev/null || echo "false")
shape_assert_eq "list --json" "entries expose .id and .status" "true" "$LIST_ENTRY_SHAPE"

# Pin #19: session-start.sh's qa-pending queue scan — array + numeric length
# + the open labeled task is present.
QA_PENDING_JSON=$(bd list --label qa-pending --status open --json 2>/dev/null || echo "[]")
QA_PENDING_LEN=$(printf '%s' "$QA_PENDING_JSON" | jq 'length' 2>/dev/null || echo "ERR")
shape_assert_match "list --label <l> --status open --json" \
    "jq length is numeric (session-start.sh count parse)" '^[0-9]+$' "$QA_PENDING_LEN"
shape_assert_contains "list --label <l> --status open --json" \
    "open task labeled qa-pending appears in the filtered list" \
    "$TID_A" "$QA_PENDING_JSON"

# Pin #20: the text-mode variant session-start renders for humans.
QA_PENDING_TEXT_RC=0
QA_PENDING_TEXT=$(bd list --label qa-pending --status open 2>/dev/null) || QA_PENDING_TEXT_RC=$?
shape_assert_eq "list --label <l> --status open (text)" "exits 0" "0" "$QA_PENDING_TEXT_RC"
shape_assert_contains "list --label <l> --status open (text)" \
    "text listing mentions the labeled task id" "$TID_A" "$QA_PENDING_TEXT"

# Pin #21: epic-gate.sh's epic scan.
EPIC_LIST_JSON=$(bd list --type epic --json 2>/dev/null || echo "[]")
shape_assert_contains "list --type epic --json" \
    "array contains the created epic" "$EPIC_ID" "$EPIC_LIST_JSON"

# Pin #25: bd-mcp dep add — arg order is <dependent> <blocker>.
DEP_RC=0
bd dep add "$TID_C" "$TID_A" >/dev/null 2>&1 || DEP_RC=$?
shape_assert_eq "dep add <dependent> <blocker>" "exits 0" "0" "$DEP_RC"
DEPS_C=$(bd show "$TID_C" --json 2>/dev/null \
    | jq -r 'if type == "array" then .[0] else . end | (.dependencies // []) | map(.id) | join(",")' 2>/dev/null || echo "")
shape_assert_contains "dep add <dependent> <blocker>" \
    "blocker appears in show <dependent> .dependencies[].id" "$TID_A" "$DEPS_C"

# Pin #26: bd-mcp dep relate (bi-directional, non-blocking edge).
RELATE_RC=0
bd dep relate "$TID_E" "$TID_F" >/dev/null 2>&1 || RELATE_RC=$?
shape_assert_eq "dep relate <a> <b>" "exits 0" "0" "$RELATE_RC"

# Pin #22: blocked --json carries the dependent we just blocked.
BLOCKED_JSON=$(bd blocked --json 2>/dev/null || echo "[]")
BLOCKED_TYPE=$(printf '%s' "$BLOCKED_JSON" | jq -r 'type' 2>/dev/null || echo "unparseable")
shape_assert_eq "blocked --json" "top-level JSON type is array" "array" "$BLOCKED_TYPE"
shape_assert_contains "blocked --json" \
    "blocked dependent is listed" "$TID_C" "$BLOCKED_JSON"

# Pin #23: blocked text mode (session-start renders + line-counts it).
BLOCKED_TEXT_RC=0
BLOCKED_TEXT=$(bd blocked 2>/dev/null) || BLOCKED_TEXT_RC=$?
shape_assert_eq "blocked (text)" "exits 0" "0" "$BLOCKED_TEXT_RC"
shape_assert_contains "blocked (text)" \
    "text listing mentions the blocked id" "$TID_C" "$BLOCKED_TEXT"

# Pin #24: ready --json parses as an array.
READY_TYPE=$(bd ready --json 2>/dev/null | jq -r 'type' 2>/dev/null || echo "unparseable")
shape_assert_eq "ready --json" "top-level JSON type is array" "array" "$READY_TYPE"

# ---------------------------------------------------------------------------
# Phase 4 — epic-gate parent/child jq pins (#8, dependencies/dependents).

shape_assert_eq "show <id> --json" \
    "parent epic resolves via epic-gate.sh parent_epic_of jq (.dependencies parent-child)" \
    "$EPIC_ID" "$(production_parent_epic_of "$CHILD_ID")"
SUBTASKS=$(production_sub_tasks_of "$EPIC_ID")
shape_assert_contains "show <id> --json" \
    "child resolves via epic-gate.sh sub_tasks_of jq (.dependents parent-child)" \
    "$CHILD_ID" "$SUBTASKS"

# ---------------------------------------------------------------------------
# Phase 5 — mutations (#13, #15, #16, #17, #11, #9, #32).

# Pin #17 (quirk half): closing a BLOCKED issue is an exit-0 NO-OP on
# 0.47.x. bd-mcp's bd_close_task reports success from the exit code alone,
# so production behavior depends on this exact contract. If a future bd
# flips this to a non-zero exit, bd-mcp starts surfacing errors where it
# previously claimed success — we want to know.
BLOCKED_CLOSE_OUT=$(bd close "$TID_C" -r "bd-compat blocked close probe" --json 2>&1)
BLOCKED_CLOSE_RC=$?
shape_assert_eq "close <id> -r <reason> --json" \
    "QUIRK: closing a blocked issue exits 0 (bd-mcp tolerates the no-op)" \
    "0" "$BLOCKED_CLOSE_RC"
shape_assert_contains "close <id> -r <reason> --json" \
    "QUIRK: blocked close prints the cannot-close notice" \
    "cannot close" "$BLOCKED_CLOSE_OUT"
shape_assert_eq "close <id> -r <reason> --json" \
    "QUIRK: blocked close leaves status unchanged (open)" \
    "open" "$(production_get_status "$TID_C")"

# Pin #13: verify-before-stop.sh's close-out path.
CLOSE_E_RC=0
bd update "$TID_E" --status closed >/dev/null 2>&1 || CLOSE_E_RC=$?
shape_assert_eq "update <id> --status closed" "exits 0" "0" "$CLOSE_E_RC"
shape_assert_eq "update <id> --status closed" \
    "status reads back as closed" "closed" "$(production_get_status "$TID_E")"

# Pin #17 (happy half): close on an UNBLOCKED issue really closes it.
CLOSE_F_RC=0
bd close "$TID_F" -r "bd-compat close probe" --json >/dev/null 2>&1 || CLOSE_F_RC=$?
shape_assert_eq "close <id> -r <reason> --json" "unblocked close exits 0" "0" "$CLOSE_F_RC"
shape_assert_eq "close <id> -r <reason> --json" \
    "unblocked close really closes (status=closed)" \
    "closed" "$(production_get_status "$TID_F")"

# Pin #15: bd-mcp bd_update_task — combined flags, --json output shape.
UPDATE_OUT=$(bd update "$TID_B" -s in_progress --add-label bd-compat-mcp --json 2>/dev/null || echo "")
UPDATE_STATUS=$(printf '%s' "$UPDATE_OUT" \
    | jq -r 'if type == "array" then .[0].status else .status end // empty' 2>/dev/null || echo "")
shape_assert_eq "update <id> -s in_progress --add-label <l> --json" \
    "stdout parses as JSON and normalized .status is in_progress (bd-mcp normalizeShowResult)" \
    "in_progress" "$UPDATE_STATUS"
shape_assert_contains "update <id> -s in_progress --add-label <l> --json" \
    "--add-label lands (visible via qa-gate get_labels jq)" \
    "bd-compat-mcp" "$(production_get_labels "$TID_B")"

# Pin #16: bd-mcp's atomic claim.
CLAIM_RC=0
bd update "$TID_G" --claim >/dev/null 2>&1 || CLAIM_RC=$?
shape_assert_eq "update <id> --claim" "exits 0 on an unclaimed task" "0" "$CLAIM_RC"
shape_assert_eq "update <id> --claim" \
    "claim sets status=in_progress" "in_progress" "$(production_get_status "$TID_G")"
CLAIM_ASSIGNEE=$(bd show "$TID_G" --json 2>/dev/null \
    | jq -r 'if type == "array" then .[0] else . end | .assignee // .owner // ""' 2>/dev/null || echo "")
shape_assert_match "update <id> --claim" \
    "claim sets a non-empty assignee/owner" '.+' "$CLAIM_ASSIGNEE"

# Pin #11: label remove — exit 0 and the label disappears.
LBL_RM_RC=0
bd label remove "$TID_A" qa-pending >/dev/null 2>&1 || LBL_RM_RC=$?
shape_assert_eq "label remove <id> <label>" "exits 0 (qa-gate.sh remove_label contract)" "0" "$LBL_RM_RC"
LABELS_A_AFTER=$(production_get_labels "$TID_A")
shape_assert_eq "label remove <id> <label>" \
    "label no longer visible via qa-gate get_labels jq" "1" \
    "$(printf ',%s,' "$LABELS_A_AFTER" | grep -q ',qa-pending,' && echo 0 || echo 1)"

# Pin #9: show --refs (bd-mcp advanced path) — exit 0 + valid JSON.
REFS_OUT=$(bd show "$TID_A" --json --refs 2>/dev/null || echo "")
REFS_VALID=$(printf '%s' "$REFS_OUT" | jq -e 'type' >/dev/null 2>&1 && echo "valid" || echo "invalid")
shape_assert_eq "show <id> --json --refs" "stdout is valid JSON" "valid" "$REFS_VALID"

# Pin #32: bd-mcp label list-all chain (--json first, text fallback).
LISTALL_OK="no"
if bd label list-all --json 2>/dev/null | jq -e 'type' >/dev/null 2>&1; then
    LISTALL_OK="yes"
elif bd label list-all >/dev/null 2>&1; then
    LISTALL_OK="yes"
fi
shape_assert_eq "label list-all --json (|| text fallback)" \
    "at least one leg of the bd-mcp list-all chain succeeds" "yes" "$LISTALL_OK"

# ---------------------------------------------------------------------------
# Phase 6 — session health pins (#27, #28).

# Pin #27: bd prime — session-start embeds its raw stdout; an empty or
# failing prime silently degrades every session's context.
PRIME_RC=0
PRIME_OUT=$(bd prime 2>/dev/null) || PRIME_RC=$?
shape_assert_eq "prime" "exits 0" "0" "$PRIME_RC"
shape_assert_match "prime" "produces non-empty context output" '.+' "$PRIME_OUT"

# Pin #28: bd doctor --quiet — session-start tolerates ANY exit code
# (|| true), so the load-bearing contract is just: it terminates and the
# DB is still readable afterwards.
bd doctor --quiet >/dev/null 2>&1 || true
POST_DOCTOR_TYPE=$(bd list --json 2>/dev/null | jq -r 'type' 2>/dev/null || echo "unparseable")
shape_assert_eq "doctor --quiet" \
    "terminates and leaves the DB readable (list --json still parses)" \
    "array" "$POST_DOCTOR_TYPE"

# ---------------------------------------------------------------------------
# Phase 7 — sync / flush / export pins (#29, #30, #31). These are the
# regression anchors for the two real capture bugs in the header.

# Pin #29: session-end.sh runs `bd sync` and, on failure, logs the FIRST
# LINE OF STDERR. The sandbox has no git remote, so full sync may
# legitimately fail — the pinned contract is: rc is 0 or 1 (the subcommand
# exists; no usage error), and when it fails the error text is on stderr.
SYNC_ERR_FILE="$FIXTURE/bdcompat/sync-stderr.txt"
SYNC_RC=0
bd sync >/dev/null 2>"$SYNC_ERR_FILE" || SYNC_RC=$?
shape_assert_match "sync" \
    "terminates with rc 0 or 1 (subcommand exists; session-end.sh tolerates failure)" \
    '^[01]$' "$SYNC_RC"
if [ "$SYNC_RC" -ne 0 ]; then
    shape_assert_eq "sync" \
        "on failure the error text lands on stderr (session-end.sh logs its first line)" \
        "0" "$([ -s "$SYNC_ERR_FILE" ] && echo 0 || echo 1)"
fi

# Pin #30: the beadsCapture.ts daemon-safe flush. New dirty row first, then
# the EXACT production invocation: env BD_NO_DAEMON=1 against the real
# binary (not the fixture wrapper — the env var itself is under test).
TID_H=$(bd create "bd-compat probe hotel" -t task -p 2 --json 2>/dev/null | jq -r '.id // empty' 2>/dev/null || echo "")
FLUSH_RC=0
BD_NO_DAEMON=1 "$REAL_BD" sync --flush-only >/dev/null 2>&1 || FLUSH_RC=$?
shape_assert_eq "BD_NO_DAEMON=1 sync --flush-only" "exits 0" "0" "$FLUSH_RC"
shape_assert_eq "BD_NO_DAEMON=1 sync --flush-only" \
    "materializes .beads/issues.jsonl (366.5 regression: flush must produce the file)" \
    "0" "$([ -f "$SANDBOX/.beads/issues.jsonl" ] && echo 0 || echo 1)"
shape_assert_eq "BD_NO_DAEMON=1 sync --flush-only" \
    "flushed file contains the freshly created issue (daemon-race regression)" \
    "0" "$(grep -q "$TID_H" "$SANDBOX/.beads/issues.jsonl" 2>/dev/null && echo 0 || echo 1)"

# Pin #31: the 366.5 fallback primitive. `bd export --force -o` must
# rewrite issues.jsonl from the DB even when the file is missing — this is
# what beadsCapture.ts relies on when flush-only short-circuits on a
# metadata hash match.
rm -f "$SANDBOX/.beads/issues.jsonl"
EXPORT_RC=0
BD_NO_DAEMON=1 "$REAL_BD" export --force -o "$SANDBOX/.beads/issues.jsonl" >/dev/null 2>&1 || EXPORT_RC=$?
shape_assert_eq "BD_NO_DAEMON=1 export --force -o .beads/issues.jsonl" \
    "exits 0" "0" "$EXPORT_RC"
shape_assert_eq "BD_NO_DAEMON=1 export --force -o .beads/issues.jsonl" \
    "rewrites issues.jsonl after deletion (366.5 fallback primitive)" \
    "0" "$([ -f "$SANDBOX/.beads/issues.jsonl" ] && echo 0 || echo 1)"
EXPORTED_IDS=$(grep -c '"id":' "$SANDBOX/.beads/issues.jsonl" 2>/dev/null || echo 0)
shape_assert_match "BD_NO_DAEMON=1 export --force -o .beads/issues.jsonl" \
    "exported file contains all 10 sandbox issues (full DB materialization)" \
    '^(1[0-9]|[2-9][0-9])$' "$EXPORTED_IDS"
shape_assert_eq "BD_NO_DAEMON=1 export --force -o .beads/issues.jsonl" \
    "exported file contains the dotted child id (hierarchy survives export)" \
    "0" "$(grep -q "$CHILD_ID" "$SANDBOX/.beads/issues.jsonl" 2>/dev/null && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Phase 8 — META-TEST: prove the pins bite. A fake bd (PATH shim) returns
# labels as a STRING (not an array) for `show <id> --json`; the SAME
# check function the real run used above must fail and name the command.

FAKEBIN="$FIXTURE/bdcompat/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/bd" <<FAKE
#!/bin/bash
# Meta-test shim: wrong shape for 'show', logs every invocation.
printf '%s\n' "\$*" >> "$FAKEBIN/bd.log"
case "\${1:-}" in
  show)
    # WRONG SHAPE: labels as a comma string, not an array. The production
    # jq's 'join(",")' errors on this, so get_labels must come back empty.
    printf '{"id":"%s","labels":"qa-pending"}\n' "\${2:-unknown}"
    exit 0
    ;;
esac
exit 0
FAKE
chmod +x "$FAKEBIN/bd"

# Counter-isolated subshell: same check, fake bd first on PATH.
# shellcheck disable=SC2030  # PATH mutation is intentionally subshell-local.
META_OUT=$(
    # shellcheck disable=SC2034  # consumed by the sourced assert helpers in this subshell.
    PASS=0
    FAIL=0
    # shellcheck disable=SC2034  # consumed by the sourced assert helpers in this subshell.
    FAILED_TESTS=()
    PATH="$FAKEBIN:$PATH"
    check_show_labels_shape "$TID_A"
    printf '__META_FAIL_COUNT__=%d\n' "$FAIL"
)
printf 'META-TEST transcript (expected failure below proves the pin is not vacuous):\n'
printf '%s\n' "$META_OUT" | sed 's/^/    [meta] /'
# shellcheck disable=SC2031  # parent PATH was never modified.
assert_contains "bd-compat[meta]: fake bd trips the pinned shape check, naming the command" \
    "output shape mismatch for 'show <id> --json'" "$META_OUT"
assert_match "bd-compat[meta]: meta-run recorded exactly one assertion failure" \
    '__META_FAIL_COUNT__=1' "$META_OUT"
assert_eq "bd-compat[meta]: fake bd was actually invoked (PATH interception took)" "0" \
    "$([ -s "$FAKEBIN/bd.log" ] && echo 0 || echo 1)"

# ---------------------------------------------------------------------------
# Footer.

printf 'bd-compat: 32 distinct bd invocations pinned against bd %s\n' "$BD_VERSION_DETECTED"

# Exit non-zero if any assertion failed (the runner reads this).
# shellcheck disable=SC2031  # this reads the PARENT-shell counter; the meta
# subshell's FAIL was intentionally isolated and never meant to propagate.
[ "$FAIL" -eq 0 ]
