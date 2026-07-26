#!/bin/bash
# worktree-approval-resolution.sh component spec — claude-workflow-plugin-3mg.2
# (Phase V4 pt2). TRANSCRIPT SCENARIO 2: the approval was recorded in a SIBLING
# WORKTREE and the primary checkout cannot reproduce its hash.
#
# THE BUG THIS CLOSES
# -------------------
# The change-set hash is PER-CHECKOUT — it hashes the checkout's OWN
# changed-files list. The tri-model workflow runs implementers and reviewers in
# linked worktrees, so a review that happened in `wt-<task>` records a hash the
# primary checkout can never reproduce. The Stop hook then reports "qa-approved
# label present but no change-set-bound approval record matches" forever: the
# work IS reviewed, the record IS on the task, and nothing the operator does in
# the primary checkout can make the hashes agree. The session deadlocks.
#
# THE CONSTRAINT THAT SHAPES THE FIX (verified live, section 1 pins it)
# --------------------------------------------------------------------
# `qa-gate.sh approve` TRUNCATES changed-files.txt in the approving checkout, so
# a post-approve recompute THERE returns the sha256 of the empty list — the
# approved hash is unreproducible even in the worktree that produced it.
# Resolution must therefore be RECORD-BASED: read the persisted
# `impact-report-<tid>.json`, which survives approve and carries both the
# approved hash and the approved file list. Section 1.4/1.5 assert exactly this,
# so a future change that makes the truncation conditional (or that swaps the
# record read for a recompute) fails here rather than silently degrading into
# "resolution never fires".
#
# WHAT THIS SPEC COVERS (a REAL `git worktree add`, never a simulated one —
# this is also Phase V4 item 6's empirical topology probe)
#   1.  approve INSIDE the worktree: the record carries `worktree=<%20-token>`,
#       the impact report survives, the tracker is truncated, and a recompute in
#       W no longer yields the approved hash.
#   2.  PRE-FIX: the same release state under a verify-before-stop.sh that has
#       no WORKTREE-RESOLUTION block BLOCKS (run against the committed HEAD blob
#       when it predates this landing; section 8 proves it permanently).
#   3.  RELEASE — delta spelled absolute under the sibling worktree.
#   4.  RELEASE — delta spelled repo-relative (the git-status fallback's shape).
#   5.  NEGATIVE — post-approval drift IN W, and (5.4) a W with no baseline at
#       all: no drift evidence must refuse, never pass.
#   6.  NEGATIVE — this checkout's delta is NOT a subset of W's approved set.
#   7.  NEGATIVE — a finding recorded AFTER the approval (review discipline).
#   8.  META (spec-mandated) — awk-strip the WORKTREE-RESOLUTION sentinel block
#       from a copy of the hook; the section-3 release state must BLOCK.
#   9.  BACK-COMPAT — an approval record with NO worktree token (pre-3mg.2, or a
#       WORKTREE-TOKEN-stripped writer) still resolves via the bounded scan.
#   9b. THE ENCODING, round-trip — a worktree whose path contains a SPACE: the
#       writer emits %20, the record grammar survives, the reader decodes it.
#   9c. FAIL CLOSED — impact-report.sh missing (this checkout cannot measure
#       itself) blocks even with a resolvable approval on file.
#   10. NEGATIVE — the recorded worktree has been REMOVED: block, and the reason
#       names the token so the operator knows why re-review is required.
#   11. SAFETY — read-only + no MCP boot + the real plugin scripts untouched.
#
# TOPOLOGY MODELLED (and its honest limits)
# -----------------------------------------
# Every gate script is driven with an EXPLICIT `CLAUDE_PROJECT_DIR`: W for the
# approve, the primary for the Stop. `bd` always runs with cwd = the primary, so
# both checkouts read ONE Beads database — which is the observed production
# shape (the parent session's hooks/tool calls fire with the primary's cwd while
# the per-checkout gate state lives wherever CLAUDE_PROJECT_DIR points). What
# this spec CANNOT prove is what Claude Code itself sets for a worktree-isolated
# subagent; that needs a live run. What it DOES prove is that a real linked
# worktree behaves as the design assumes (`.git` is a file, the common-dir is
# shared, `git worktree list --porcelain` enumerates both checkouts) and that
# the resolution is correct under that topology.
#
# THE SYMLINK HAZARD (read before editing)
# ----------------------------------------
# mk_fixture SYMLINKS the plugin's real scripts into the fixture, and the
# worktree's committed `.claude/scripts/` are those same symlinks. Never `sed -i`
# or `cp` ONTO one of them — the write travels down the link into the plugin
# itself. Both mutated copies here are NEW files written next to the links, and
# section 11 re-checksums the real plugin scripts afterwards.

set -u

# ---------------------------------------------------------------------------
# Helpers.

# stop_decision <root> [hook] / stop_reason <root> [hook] — drive a Stop hook
# with CLAUDE_PROJECT_DIR=<root>. The hook defaults to <root>'s own copy so a
# section can point at a stripped variant instead.
stop_decision() {
    local root="$1" hook="${2:-$1/.claude/scripts/verify-before-stop.sh}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$root" bash "$hook" 2>/dev/null \
        | tail -1 | jq -r '.decision // "ALLOW"' 2>/dev/null
}

stop_reason() {
    local root="$1" hook="${2:-$1/.claude/scripts/verify-before-stop.sh}"
    printf '%s' '{"stop_reason":"end_turn","stop_hook_active":false}' \
        | CLAUDE_PROJECT_DIR="$root" bash "$hook" 2>/dev/null \
        | tail -1 | jq -r '.reason // empty' 2>/dev/null
}

# tree_fingerprint <dir> — content fingerprint of every non-git file under
# <dir>. Used to prove the resolution never WRITES into the worktree it reads.
tree_fingerprint() {
    local d="$1"
    ( cd "$d" 2>/dev/null || return 0
      find . -type f -not -path './.git/*' -not -name '.git' 2>/dev/null | LC_ALL=C sort \
        | while IFS= read -r f; do printf '%s %s\n' "$(cksum < "$f" 2>/dev/null | tr -s ' ' '-')" "$f"; done )
}

# baseline_body <file> — the snapshot lines (mirrors gate_baseline_entries).
baseline_body() {
    awk 'body { print; next } /^--$/ { body = 1 }' "$1" 2>/dev/null || true
}

fast_stack_stub() {
    local root="$1"
    rm -f "$root/.claude/scripts/detect-stack.sh"
    printf '#!/bin/bash\nprintf %s\n' "'{\"runner\":\"npm\",\"test_cmd\":\"\",\"lint_cmd\":\"\",\"type_cmd\":\"\"}'" \
        > "$root/.claude/scripts/detect-stack.sh"
    chmod +x "$root/.claude/scripts/detect-stack.sh"
}

# ===========================================================================
# SECTION 0 — the primary checkout, a real linked worktree, and the canary.
# ===========================================================================
mk_fixture
PRIM="$COMPONENT_FIXTURE_PATH"
bd_required_or_skip
fast_stack_stub "$PRIM"

PTRACK="$PRIM/.claude/.qa-tracking"
PQG="$PRIM/.claude/scripts/qa-gate.sh"
PCT="$PRIM/.claude/scripts/current-task.sh"
PVBS="$PRIM/.claude/scripts/verify-before-stop.sh"

# The gate's own bookkeeping, the Beads db and the bd shim are gitignored for
# the same reason the real plugin repo ignores them: they are per-session
# ephemera, and leaving them tracked would make the gate's own writes dirty the
# tree mid-spec (a baseline would go stale the instant it was taken).
printf '.claude/.qa-tracking/\n.claude/.session-start\n.beads/\nbin/\n' > "$PRIM/.gitignore"
mkdir -p "$PRIM/src"
printf 'export const a = 0;\n' > "$PRIM/src/a.ts"
printf 'export const b = 0;\n' > "$PRIM/src/b.ts"
printf 'export const c = 0;\n' > "$PRIM/src/c.ts"
(cd "$PRIM" && git init -q && git config user.email t@t.t && git config user.name t \
    && git add -A && git commit -qm baseline) >/dev/null 2>&1

# The code-graph MCP boot canary. impact-report.sh execs
# "$IMPACT_REPORT_NODE $CODE_GRAPH_MCP_BIN" when it generates a report; the
# fake node appends a line and exits. Section 11 asserts the canary fires for a
# `qa-gate.sh enter` (so it is not a dud) and NEVER for a Stop.
CANARY="$PRIM/.claude/mcp-boot-canary"
cat > "$PRIM/fake-node" <<EOF
#!/bin/bash
printf 'BOOTED %s\n' "\$*" >> "$CANARY"
exit 0
EOF
chmod +x "$PRIM/fake-node"
printf '// canary bin\n' > "$PRIM/fake-mcp.js"
export IMPACT_REPORT_NODE="$PRIM/fake-node"
export CODE_GRAPH_MCP_BIN="$PRIM/fake-mcp.js"
# The fake server never answers the handshake, so keep the budgets small — but
# NOT 1s: impact-report.sh computes its deadline as `date +%s` + budget, so a
# 1s budget can expire on the FIRST poll (whole-second granularity) and kill the
# fake node before it has written the canary. That made the positive control
# flaky. 3s leaves >=2s of real time, which is deterministic here and still
# leaves an `enter` at ~3s instead of the 30s default boot budget.
export IMPACT_REPORT_BOOT_TIMEOUT_S=3
export IMPACT_REPORT_TIMEOUT_S=10
export IMPACT_REPORT_FIRST_CALL_TIMEOUT_S=2
export IMPACT_REPORT_CALL_TIMEOUT_S=2

# The worktree lives OUTSIDE the fixture on purpose: a checkout under
# `.claude/worktrees/` is denylisted, which would mask the very paths under test.
WT_PARENT=$(mktemp -d -t wtres-worktree.XXXXXX)
W="$WT_PARENT/wt-feature"
WT_OK=1
(cd "$PRIM" && git worktree add -q "$W" -b wtres-linked) >/dev/null 2>&1 || WT_OK=0

if [ "$WT_OK" != "1" ] || [ ! -e "$W/.git" ]; then
    # Skip-with-log, same contract as bd_required_or_skip: the runner sources
    # each spec inside its own `bash -c` wrapper, so exit 0 records a PASS with
    # zero assertions rather than faking any. A SIMULATED worktree is not an
    # acceptable substitute here — the real linked topology IS the thing
    # under test (Phase V4 item 6).
    printf 'SKIPPED: worktree-approval-resolution (git worktree add unavailable in this environment)\n'
    rm -rf "$WT_PARENT"
    exit 0
fi

# `.beads/` is gitignored here, so the worktree checkout has none; in the real
# repo `.beads/` is TRACKED and every worktree gets one. qa-gate.sh requires the
# directory to exist ($PROJECT_DIR/.beads), so model that. bd itself always runs
# with cwd = the primary, i.e. ONE database.
mkdir -p "$W/.claude/.qa-tracking" "$W/.beads"
WTRACK="$W/.claude/.qa-tracking"
WQG="$W/.claude/scripts/qa-gate.sh"

# The spelling git itself reports for the worktree — and therefore the spelling
# the `worktree=` token records and the block reason echoes back. On macOS
# `mktemp -d` hands out /var/folders/... while git resolves the symlink to
# /private/var/folders/..., so assertions on the token must use git's spelling,
# not $W. (The resolution canonicalises BOTH sides through `pwd -P`, which is
# why the release path is indifferent to it; only the TEXT assertions care.)
W_TOPLEVEL=$(git -C "$W" rev-parse --show-toplevel 2>/dev/null)

assert_eq "wtres-0.1: the linked worktree's .git is a FILE (a real worktree, not a copy)" "file" \
    "$([ -d "$W/.git" ] && echo dir || { [ -f "$W/.git" ] && echo file || echo missing; })"
assert_eq "wtres-0.2: both checkouts share ONE git common-dir (the same-repo identity)" "same" \
    "$([ "$(cd "$(git -C "$PRIM" rev-parse --git-common-dir)" && pwd -P)" = \
        "$(cd "$(git -C "$W" rev-parse --git-common-dir)" && pwd -P)" ] && echo same || echo differs)"
assert_eq "wtres-0.3: git worktree list --porcelain enumerates 2 worktrees" "2" \
    "$(git -C "$PRIM" worktree list --porcelain | grep -c '^worktree ' | tr -d '[:space:]')"
assert_eq "wtres-0.4: the worktree's hook surface resolves (committed symlinks)" "yes" \
    "$([ -r "$WQG" ] && [ -r "$W/.claude/scripts/impact-report.sh" ] && echo yes || echo no)"

# restage <paths...> — put the PRIMARY back in "this is what the session
# changed" position and reset the per-task iteration counter.
#
# The counter reset is load-bearing, not hygiene: without it ~12 Stop fires on
# one task would cross MAX_ITERATIONS, set qa-escalated, then AUTO-DEFER — and a
# qa-deferred task releases unconditionally, turning every later assertion green
# for the wrong reason. Section 11 re-checks that no defer label appeared.
SAN=""
restage() {
    bash "$PCT" set "$TID" >/dev/null 2>&1
    : > "$PTRACK/changed-files.txt"
    local f
    for f in "$@"; do printf '%s\n' "$f" >> "$PTRACK/changed-files.txt"; done
    rm -f "$PTRACK/iteration-count" "$PTRACK/iteration-count.$SAN" 2>/dev/null || true
}

# approve_in <worktree> <tid> <qa-gate-path> <summary> — the full review cycle
# INSIDE a worktree, through the real writers. CLAUDE_PROJECT_DIR=<worktree> so
# the hash, the impact report and the gate baseline are all that checkout's; cwd
# stays the primary so bd writes to the one shared database.
approve_in() {
    local root="$1" tid="$2" qg="$3" summary="$4" san hash art
    san=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    art="$root/.claude/.qa-tracking/review-artifact-$san-r1.json"
    CLAUDE_PROJECT_DIR="$root" bash "$qg" enter "$tid" >/dev/null 2>&1
    bd comments add "$tid" "IMPLEMENTER: role=devops task=$tid at $(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null 2>&1
    hash=$(CLAUDE_PROJECT_DIR="$root" bash "$root/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null || echo "")
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"qa-claude","reviewer_model":"test-model","reviewed_hash":"$hash","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"approve","findings":[],"iterations":1,"stopped_by":"verdict"}
JSON
    CLAUDE_PROJECT_DIR="$root" bash "$qg" review-record "$tid" --file "$art" >/dev/null 2>&1
    CLAUDE_PROJECT_DIR="$root" bash "$qg" approve "$tid" "$summary" 2>&1 | tail -1
}

# record_artifact <tid> <iteration> <findings-json> — a further review round,
# recorded through the real writer (used by section 7).
record_artifact() {
    local tid="$1" iter="$2" findings="$3" verdict="approve" san art
    [ "$findings" != "[]" ] && verdict="findings"
    san=$(printf '%s' "$tid" | tr -c 'A-Za-z0-9._-' '_')
    art="$PTRACK/review-artifact-$san-r$iter.json"
    cat > "$art" <<JSON
{"contract_version":"1","task_id":"$tid","reviewer_identity":"qa-claude","reviewer_model":"test-model","reviewed_hash":"h$iter","risk_threshold":"high","stop_condition":"acceptance criteria traced to tests","verdict":"$verdict","findings":$findings,"iterations":$iter,"stopped_by":"verdict"}
JSON
    CLAUDE_PROJECT_DIR="$PRIM" bash "$PQG" review-record "$tid" --file "$art" >/dev/null 2>&1
}

comments_of() {
    bd show "$1" --json 2>/dev/null \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // [] | .[].text' 2>/dev/null || echo ""
}

labels_of() {
    bd show "$1" --json 2>/dev/null \
        | jq -r 'if type == "array" then .[0].labels else .labels end // [] | join(",")' 2>/dev/null || echo ""
}

# ===========================================================================
# SECTION 1 — approve INSIDE the worktree. What it records, and what it
# destroys (the constraint that forces a record-based resolution).
# ===========================================================================
TID=$(cd "$PRIM" && bd create "cross-worktree approval bridge" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
SAN=$(printf '%s' "$TID" | tr -c 'A-Za-z0-9._-' '_')
WREPORT="$WTRACK/impact-report-$SAN.json"

# TWO files edited in W, tracked with the W-absolute spellings post-edit.sh
# records. The primary's tracker will carry a SUBSET of them, which is how the
# two checkouts end up with different hashes over the same reviewed work.
printf 'export const a = 1; // implemented in the worktree\n' > "$W/src/a.ts"
printf 'export const b = 1; // implemented in the worktree\n' > "$W/src/b.ts"
printf '%s\n%s\n' "$W/src/a.ts" "$W/src/b.ts" > "$WTRACK/changed-files.txt"

W_APPROVED_HASH=$(CLAUDE_PROJECT_DIR="$W" bash "$W/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
rm -f "$CANARY"
APPROVE_OUT=$(approve_in "$W" "$TID" "$WQG" "reviewed in the worktree by qa-claude")
assert_json_field "wtres-1.0: approve INSIDE the worktree succeeds" "$APPROVE_OUT" '.status' "approved"
assert_eq "wtres-1.0: the canary proves an enter/approve cycle DOES boot the server (not a dud)" "fired" \
    "$([ -s "$CANARY" ] && echo fired || echo silent)"

APPROVAL_REC=$(comments_of "$TID" | grep 'QA-GATE APPROVED' | tail -1)
W_TOKEN=$(printf '%s' "$W_TOPLEVEL" | sed 's/ /%20/g')
assert_contains "wtres-1.1: the record names the approving worktree (worktree=<%20-token>)" \
    "worktree=$W_TOKEN " "$APPROVAL_REC"
assert_match "wtres-1.2: full grammar — hash, reviewed_by, worktree, then the timestamp" \
    "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude worktree=[^ ]+ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: " \
    "$APPROVAL_REC"
assert_contains "wtres-1.3: the record binds the WORKTREE's change-set hash" \
    "change_set_hash=$W_APPROVED_HASH " "$APPROVAL_REC"

# 1.4/1.5 THE constraint. The report survives; the tracker does not.
assert_eq "wtres-1.4: the worktree's impact report SURVIVES approve (the evidence file)" "yes" \
    "$([ -f "$WREPORT" ] && echo yes || echo no)"
assert_eq "wtres-1.4: ...carrying the approved hash" "$W_APPROVED_HASH" \
    "$(jq -r '.change_set_hash // empty' "$WREPORT" 2>/dev/null)"
assert_eq "wtres-1.4: ...and both approved files" "2" \
    "$(jq -r '(.files // [])[] | .file' "$WREPORT" 2>/dev/null | grep -c 'src/[ab]\.ts' | tr -d '[:space:]')"
assert_eq "wtres-1.5: approve TRUNCATED the worktree's tracker" "0" \
    "$(wc -c < "$WTRACK/changed-files.txt" | tr -d '[:space:]')"
W_RECOMPUTE=$(CLAUDE_PROJECT_DIR="$W" bash "$W/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
assert_eq "wtres-1.5: ...so a recompute IN W can no longer reproduce the approved hash (resolution MUST read the record)" \
    "differs" "$([ "$W_RECOMPUTE" = "$W_APPROVED_HASH" ] && echo same || echo differs)"
assert_contains "wtres-1.6: approve refreshed the worktree's gate baseline (the drift reference)" \
    "src/a.ts" "$(baseline_body "$WTRACK/gate-baseline")"

# ===========================================================================
# SECTION 2 — PRE-FIX. The exact release state of section 3, driven through a
# verify-before-stop.sh that has no WORKTREE-RESOLUTION block, must BLOCK.
#
# The committed HEAD blob is that hook only until this change lands, so the leg
# is conditional on HEAD predating it — and section 8 proves the same property
# permanently by stripping the sentinels out of the CURRENT hook. Anchoring the
# assertion on "HEAD lacks the sentinel" unconditionally would make this spec
# start failing the moment the fix is committed.
# ===========================================================================
restage "$W/src/a.ts"
PRIM_HASH=$(CLAUDE_PROJECT_DIR="$PRIM" bash "$PRIM/.claude/scripts/impact-report.sh" --hash-only 2>/dev/null)
assert_eq "wtres-2.0: precondition — the primary's hash differs from the approved one (the deadlock)" \
    "differs" "$([ "$PRIM_HASH" = "$W_APPROVED_HASH" ] && echo same || echo differs)"

VBS_HEAD="$PRIM/.claude/scripts/verify-before-stop-head.sh"
HEAD_OK=0
if git -C "$(plugin_root)" show HEAD:.claude/scripts/verify-before-stop.sh > "$VBS_HEAD" 2>/dev/null; then
    chmod +x "$VBS_HEAD"
    HEAD_OK=1
fi
if [ "$HEAD_OK" = "1" ] && ! grep -q 'WORKTREE-RESOLUTION BEGIN' "$VBS_HEAD"; then
    restage "$W/src/a.ts"
    assert_eq "wtres-2.1: PRE-FIX — the committed HEAD hook BLOCKS this release state" \
        "block" "$(stop_decision "$PRIM" "$VBS_HEAD")"
    restage "$W/src/a.ts"
    assert_contains "wtres-2.1: ...with the label-without-record reason (the production deadlock)" \
        "no change-set-bound approval record matches" "$(stop_reason "$PRIM" "$VBS_HEAD")"
else
    printf '  note: wtres-2.1 skipped — HEAD already carries WORKTREE-RESOLUTION (post-landing); section 8 is the permanent proof\n'
fi
rm -f "$VBS_HEAD"

# ===========================================================================
# SECTION 3 — RELEASE. The delta is spelled ABSOLUTE under the sibling
# worktree, which is what the parent session's post-edit.sh records when a
# worktree-isolated specialist edits a file.
# ===========================================================================
W_BEFORE=$(tree_fingerprint "$W")
restage "$W/src/a.ts"
rm -f "$CANARY"
assert_eq "wtres-3.1: the approval bound in the worktree RELEASES the primary's Stop" \
    "ALLOW" "$(stop_decision "$PRIM")"
assert_eq "wtres-3.2: the resolution never boots the code-graph MCP server" "silent" \
    "$([ -s "$CANARY" ] && echo fired || echo silent)"
assert_eq "wtres-3.3: the resolution wrote NOTHING in the worktree it read" "identical" \
    "$([ "$W_BEFORE" = "$(tree_fingerprint "$W")" ] && echo identical || echo mutated)"
assert_contains "wtres-3.4: the release is audited in sync-errors.log, naming the worktree" \
    "released via worktree resolution" "$(tail -20 "$PTRACK/sync-errors.log" 2>/dev/null)"
assert_contains "wtres-3.4: ...and the resolved worktree path" \
    "$W_TOPLEVEL" "$(tail -20 "$PTRACK/sync-errors.log" 2>/dev/null)"

# ===========================================================================
# SECTION 4 — RELEASE with the delta spelled REPO-RELATIVE, the shape the
# Stop hook's own git-status fallback produces (`${line#???}`). Both spellings
# must map to the same repo-relative key; this isolates that mapping.
# ===========================================================================
restage "src/a.ts"
assert_eq "wtres-4.1: a repo-relative delta resolves against the same approved set" \
    "ALLOW" "$(stop_decision "$PRIM")"

# ===========================================================================
# SECTION 5 — NEGATIVE: post-approval drift IN the worktree. The approval
# covered the tree as it was; anything dirtied in W afterwards is unreviewed,
# so the bridge must refuse. Causation, as everywhere in this tier: remove the
# one variable and the release comes back.
# ===========================================================================
printf 'export const drifted = 1;\n' > "$W/src/drift.ts"
restage "$W/src/a.ts"
assert_eq "wtres-5.1: new dirt in the worktree AFTER approve BLOCKS the bridge" \
    "block" "$(stop_decision "$PRIM")"
restage "$W/src/a.ts"
assert_contains "wtres-5.2: the block names how many worktrees were probed" \
    "checked 1 worktree(s)" "$(stop_reason "$PRIM")"
rm -f "$W/src/drift.ts"
restage "$W/src/a.ts"
assert_eq "wtres-5.3: removing ONLY the drift restores the release (drift is the cause)" \
    "ALLOW" "$(stop_decision "$PRIM")"

# 5.4 The no-evidence case. Drift is judged against W's OWN gate-baseline, so a
# missing baseline means "cannot prove nothing changed after the approval" —
# which must refuse, not pass. (Absence of evidence is not evidence of absence:
# the same reason a `git status` that FAILS in W refuses rather than reading as
# an empty, therefore clean, tree.)
mv "$WTRACK/gate-baseline" "$WTRACK/gate-baseline.away"
restage "$W/src/a.ts"
assert_eq "wtres-5.4: a worktree with NO gate-baseline cannot prove absence of drift -> BLOCK" \
    "block" "$(stop_decision "$PRIM")"
mv "$WTRACK/gate-baseline.away" "$WTRACK/gate-baseline"
restage "$W/src/a.ts"
assert_eq "wtres-5.4: restoring the baseline restores the release" \
    "ALLOW" "$(stop_decision "$PRIM")"

# ===========================================================================
# SECTION 6 — NEGATIVE: the primary's delta is NOT a subset of what W
# approved. src/c.ts was never in the reviewed change set, so the bridge must
# not smuggle it out on the back of an approval that never saw it.
# ===========================================================================
restage "$W/src/a.ts" "$W/src/c.ts"
assert_eq "wtres-6.1: an unapproved path in the delta BLOCKS (subset, not overlap)" \
    "block" "$(stop_decision "$PRIM")"
restage "src/c.ts"
assert_eq "wtres-6.2: ...even alone, and in the repo-relative spelling" \
    "block" "$(stop_decision "$PRIM")"
restage "$W/src/a.ts"
assert_eq "wtres-6.3: dropping the unapproved path restores the release" \
    "ALLOW" "$(stop_decision "$PRIM")"

# ===========================================================================
# SECTION 7 — NEGATIVE: a finding recorded AFTER the approval. The same
# re-arming the V3 REVIEW-DISCIPLINE block applies to same-checkout releases
# must apply here, or the cross-worktree path becomes the one release route
# where "approve early, discover later" ships the finding.
# ===========================================================================
record_artifact "$TID" 2 \
    '[{"id":"R2-F1","severity":"critical","location":"src/a.ts:1","evidence":"the worktree review missed the unguarded write","description":"post-approval finding"}]'
restage "$W/src/a.ts"
assert_eq "wtres-7.1: an open at-threshold finding recorded after approve BLOCKS the bridge" \
    "block" "$(stop_decision "$PRIM")"
restage "$W/src/a.ts"
REASON7=$(stop_reason "$PRIM")
assert_contains "wtres-7.2: the block reason names the review error_key" "unresolved_findings" "$REASON7"
assert_contains "wtres-7.2: ...and the open finding id" "R2-F1" "$REASON7"
CLAUDE_PROJECT_DIR="$PRIM" bash "$PQG" arbitrate "$TID" R2-F1 overrule \
    "the write is guarded by the caller's transaction; covered by tests/tx.test.sh" >/dev/null 2>&1
restage "$W/src/a.ts"
assert_eq "wtres-7.3: after an arbitrated overrule the release comes back" \
    "ALLOW" "$(stop_decision "$PRIM")"

# ===========================================================================
# SECTION 8 — META (spec-mandated): the WORKTREE-RESOLUTION block is
# load-bearing. Strip everything between the sentinels from a COPY of the
# CURRENT hook and re-run section 3's exact state: it must BLOCK, i.e. every
# release assertion above would fail without the block. TEXT-anchored on the
# sentinels (LESSONS llh.20), never on line numbers.
#
# The stripped copy lives in `.claude/scripts/` because the hook sources
# `workflow-denylist.sh` BASH_SOURCE-relative; parked elsewhere it would take
# the missing-denylist fail-closed arm and block for the WRONG reason.
# ===========================================================================
VBS_STRIPPED="$PRIM/.claude/scripts/verify-before-stop-nowtres.sh"
REAL_VBS=$(readlink "$PVBS" 2>/dev/null || printf '%s' "$PVBS")
STRIP_RC=0
awk '
    /# WORKTREE-RESOLUTION BEGIN/ { skipping=1; found=1; next }
    /# WORKTREE-RESOLUTION END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$REAL_VBS" > "$VBS_STRIPPED" || STRIP_RC=$?
chmod +x "$VBS_STRIPPED"
assert_eq "wtres-8.0 META: WORKTREE-RESOLUTION sentinels present in verify-before-stop.sh" \
    "0" "$STRIP_RC"

if [ "$STRIP_RC" -eq 0 ]; then
    PARSE_RC=0
    bash -n "$VBS_STRIPPED" 2>/dev/null || PARSE_RC=$?
    assert_eq "wtres-8.1 META: the stripped copy still parses (the block is cleanly strippable)" \
        "0" "$PARSE_RC"
    restage "$W/src/a.ts"
    assert_eq "wtres-8.2 META: control — the real hook RELEASES this state" \
        "ALLOW" "$(stop_decision "$PRIM")"
    restage "$W/src/a.ts"
    assert_eq "wtres-8.3 META: WITHOUT the block the same state BLOCKS (section 3 WOULD fail)" \
        "block" "$(stop_decision "$PRIM" "$VBS_STRIPPED")"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("wtres-8 META: sentinels missing — strip meta-test skipped")
    printf '  FAIL: wtres-8 META: sentinels missing — strip meta-test skipped\n'
fi

# ===========================================================================
# SECTION 9 — BACK-COMPAT: an approval record with NO worktree token still
# resolves. Records written before 3mg.2 carry none, so the token can only be a
# FAST PATH — losing it must cost ordering, never the resolution. Produced by
# stripping the WORKTREE-TOKEN sentinels out of a copy of qa-gate.sh, which is
# exactly the pre-3mg.2 writer.
# ===========================================================================
QG_NOTOKEN="$PRIM/.claude/scripts/qa-gate-notoken.sh"
QG_REAL=$(readlink "$PQG" 2>/dev/null || printf '%s' "$PQG")
NOTOKEN_RC=0
awk '
    /# WORKTREE-TOKEN BEGIN/ { skipping=1; found=1; next }
    /# WORKTREE-TOKEN END/   { skipping=0; next }
    skipping { next }
    { print }
    END { if (!found) exit 7 }
' "$QG_REAL" > "$QG_NOTOKEN" || NOTOKEN_RC=$?
chmod +x "$QG_NOTOKEN"
assert_eq "wtres-9.0: WORKTREE-TOKEN sentinels present in qa-gate.sh" "0" "$NOTOKEN_RC"

if [ "$NOTOKEN_RC" -eq 0 ]; then
    TID2=$(cd "$PRIM" && bd create "pre-3mg.2 record shape" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    SAN2=$(printf '%s' "$TID2" | tr -c 'A-Za-z0-9._-' '_')
    printf 'export const b = 2; // second cycle in the worktree\n' > "$W/src/b.ts"
    printf '%s\n' "$W/src/b.ts" > "$WTRACK/changed-files.txt"
    APPROVE2=$(approve_in "$W" "$TID2" "$QG_NOTOKEN" "reviewed in the worktree, pre-3mg.2 writer")
    assert_json_field "wtres-9.1: the token-less writer still approves" "$APPROVE2" '.status' "approved"
    REC2=$(comments_of "$TID2" | grep 'QA-GATE APPROVED' | tail -1)
    assert_not_contains "wtres-9.2: its record carries NO worktree token (the pre-3mg.2 shape)" \
        "worktree=" "$REC2"
    assert_contains "wtres-9.2: ...but still binds a change-set hash" "change_set_hash=" "$REC2"
    # THE compatibility assertion the v3.5 readers depend on: the hash capture
    # extracts the same value from both record shapes.
    REC2_HASH=$(printf '%s' "$REC2" | jq -Rr 'capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null)
    REC1_HASH=$(printf '%s' "$APPROVAL_REC" | jq -Rr 'capture("change_set_hash=(?<h>[A-Za-z0-9-]+)").h' 2>/dev/null)
    assert_eq "wtres-9.3: the llh.18 hash capture works on the token-BEARING record" \
        "$W_APPROVED_HASH" "$REC1_HASH"
    assert_match "wtres-9.3: ...and on the token-LESS record (same expression, both shapes)" \
        '^[A-Za-z0-9-]+$' "$REC2_HASH"
    # Resolution with no token to steer by: the bounded scan must find W.
    TID_SAVE="$TID"; SAN_SAVE="$SAN"
    TID="$TID2"; SAN="$SAN2"
    restage "$W/src/b.ts"
    assert_eq "wtres-9.4: a token-less approval still resolves via the bounded scan" \
        "ALLOW" "$(stop_decision "$PRIM")"
    restage "src/c.ts"
    assert_eq "wtres-9.5: ...and the subset rule still applies to it" \
        "block" "$(stop_decision "$PRIM")"
    TID="$TID_SAVE"; SAN="$SAN_SAVE"
fi

# ===========================================================================
# SECTION 9b — THE ENCODING, end to end: a worktree whose path contains a
# SPACE. Unencoded, that space would split `worktree=` into two fields and shift
# every token after it, so the record's own `at <ts>:` grammar would break and
# the reader would look for a directory that does not exist. The writer encodes
# (%20) and the Stop hook decodes; only a round-trip test covers both halves.
# ===========================================================================
W2="$WT_PARENT/wt with space"
W2_OK=1
(cd "$PRIM" && git worktree add -q "$W2" -b wtres-spaced) >/dev/null 2>&1 || W2_OK=0
if [ "$W2_OK" = "1" ] && [ -e "$W2/.git" ]; then
    mkdir -p "$W2/.claude/.qa-tracking" "$W2/.beads"
    W2_TOPLEVEL=$(git -C "$W2" rev-parse --show-toplevel 2>/dev/null)
    TID3=$(cd "$PRIM" && bd create "approval from a worktree whose path has a space" -t task -p 1 -l devops,qa-pending --json 2>/dev/null | jq -r '.id // empty')
    SAN3=$(printf '%s' "$TID3" | tr -c 'A-Za-z0-9._-' '_')
    printf 'export const a = 3; // spaced worktree\n' > "$W2/src/a.ts"
    printf '%s\n' "$W2/src/a.ts" > "$W2/.claude/.qa-tracking/changed-files.txt"
    APPROVE3=$(approve_in "$W2" "$TID3" "$W2/.claude/scripts/qa-gate.sh" "reviewed in the spaced worktree")
    assert_json_field "wtres-9b.1: approve succeeds in a worktree whose path has a space" \
        "$APPROVE3" '.status' "approved"
    REC3=$(comments_of "$TID3" | grep 'QA-GATE APPROVED' | tail -1)
    REC3_TOKEN=$(printf '%s' "$REC3" | jq -Rr 'capture("worktree=(?<w>[^ ]+)").w' 2>/dev/null || echo "")
    assert_contains "wtres-9b.2: the token encodes the space as %20" "%20" "$REC3_TOKEN"
    assert_eq "wtres-9b.2: ...and decodes back to the worktree's toplevel" \
        "$W2_TOPLEVEL" "$(printf '%s' "$REC3_TOKEN" | sed 's/%20/ /g; s/%25/%/g')"
    # The grammar assertion that would fail on an unencoded token: `at <ts>:`
    # must still be the field right after the worktree token.
    assert_match "wtres-9b.3: the record grammar survives the spaced path" \
        "^QA-GATE APPROVED change_set_hash=[A-Za-z0-9-]+ reviewed_by=qa-claude worktree=[^ ]+ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z: " \
        "$REC3"
    # And the decode is load-bearing on the read side: resolution must release.
    TID_SAVE="$TID"; SAN_SAVE="$SAN"
    TID="$TID3"; SAN="$SAN3"
    restage "$W2/src/a.ts"
    assert_eq "wtres-9b.4: the Stop hook decodes the token and resolves the approval" \
        "ALLOW" "$(stop_decision "$PRIM")"
    # 9b.5 ISOLATES the decode. A release alone would not: with a broken decoder
    # the bounded scan would still find the worktree, so the ALLOW above would
    # pass either way. The decoded token's OTHER job is deciding whether the
    # recorded worktree is still live — so refuse for an unrelated reason (a
    # non-subset delta) and check the diagnosis. A decoder that mangled the
    # spaced path would report a live worktree as removed.
    restage "src/c.ts"
    REASON9B=$(stop_reason "$PRIM")
    # (The count is 2 here — both W and the spaced worktree are live — so the
    # assertion is on the SHAPE, not on an incidental number.)
    assert_match "wtres-9b.5: the spaced worktree is recognised as LIVE (decode round-trips)" \
        'checked [0-9]+ worktree\(s\)' "$REASON9B"
    assert_not_contains "wtres-9b.5: ...so it is never misreported as removed" \
        "no longer exists" "$REASON9B"
    TID="$TID_SAVE"; SAN="$SAN_SAVE"
    (cd "$PRIM" && git worktree remove --force "$W2") >/dev/null 2>&1 || rm -rf "$W2"
else
    printf '  note: wtres-9b skipped — could not create a worktree at a path with a space\n'
fi

# ===========================================================================
# SECTION 9c — FAIL CLOSED when this checkout cannot measure itself. With
# impact-report.sh gone the current change-set hash is unknowable; the bridge
# exists for a hash MISMATCH, not for a hash we could not compute, so a broken
# install must block even though a resolvable approval is sitting right there.
# ===========================================================================
IR_LINK="$PRIM/.claude/scripts/impact-report.sh"
IR_REAL=$(readlink "$IR_LINK" 2>/dev/null || printf '%s' "$IR_LINK")
restage "$W/src/a.ts"
assert_eq "wtres-9c.0: control — this state releases while impact-report.sh is present" \
    "ALLOW" "$(stop_decision "$PRIM")"
rm -f "$IR_LINK"          # the SYMLINK only; $IR_REAL (the plugin script) is untouched
restage "$W/src/a.ts"
assert_eq "wtres-9c.1: with impact-report.sh missing the bridge refuses (fails CLOSED)" \
    "block" "$(stop_decision "$PRIM")"
ln -sf "$IR_REAL" "$IR_LINK"
restage "$W/src/a.ts"
assert_eq "wtres-9c.2: restoring it restores the release (the guard is the cause)" \
    "ALLOW" "$(stop_decision "$PRIM")"

# ===========================================================================
# SECTION 10 — NEGATIVE: the recorded worktree is GONE. Runs last: it removes
# the worktree every section above depends on. The block must name the recorded
# token, because "re-review here" is only actionable if the operator can see
# WHERE the approval went.
# ===========================================================================
(cd "$PRIM" && git worktree remove --force "$W") >/dev/null 2>&1 || rm -rf "$W"
assert_eq "wtres-10.0: precondition — the worktree is gone" "gone" \
    "$([ -d "$W" ] && echo present || echo gone)"
restage "$W/src/a.ts"
assert_eq "wtres-10.1: a deleted approving worktree BLOCKS (fail closed, never assumed)" \
    "block" "$(stop_decision "$PRIM")"
restage "$W/src/a.ts"
REASON10=$(stop_reason "$PRIM")
assert_contains "wtres-10.2: the reason names the recorded worktree explicitly" \
    "bound in worktree $W_TOPLEVEL" "$REASON10"
assert_contains "wtres-10.2: ...and says it no longer exists" \
    "no longer exists" "$REASON10"

# ===========================================================================
# SECTION 11 — SAFETY. The spec wrote two mutated script copies next to the
# fixture's symlinks; neither may have travelled down a link into the plugin.
# Plus the false-green guard: no auto-defer label crept onto the task (a
# qa-deferred task releases unconditionally, which would fake every ALLOW).
# ===========================================================================
assert_eq "wtres-11.1 safety: the REAL plugin verify-before-stop.sh has no stripped-copy marker" "0" \
    "$(grep -c 'verify-before-stop-nowtres' "$(plugin_root)/.claude/scripts/verify-before-stop.sh" | tr -d '[:space:]')"
assert_eq "wtres-11.1 safety: the REAL plugin verify-before-stop.sh still carries the sentinels" "1" \
    "$(grep -c '# WORKTREE-RESOLUTION BEGIN' "$(plugin_root)/.claude/scripts/verify-before-stop.sh" | tr -d '[:space:]')"
assert_eq "wtres-11.1 safety: the REAL plugin qa-gate.sh still carries the token sentinels" "1" \
    "$(grep -c '# WORKTREE-TOKEN BEGIN' "$(plugin_root)/.claude/scripts/qa-gate.sh" | tr -d '[:space:]')"
assert_eq "wtres-11.2 safety: the fixture's hook is still a SYMLINK (never cp'd over)" "yes" \
    "$([ -L "$PVBS" ] && echo yes || echo no)"
assert_not_contains "wtres-11.3 guard: the task never picked up qa-deferred (no free-pass release)" \
    "qa-deferred" "$(labels_of "$TID")"

rm -rf "$WT_PARENT"

[ "$FAIL" -eq 0 ]
