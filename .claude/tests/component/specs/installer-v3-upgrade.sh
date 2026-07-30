#!/bin/bash
# installer-v3-upgrade.sh - L2 component spec for the v3.5 -> v4 in-place
# upgrade path (v4.1 Phase U0 / claude-workflow-plugin-x15).
#
# WHAT THIS PROVES
# ----------------
# The plugin's installer history is the reason this spec exists: it silently
# dropped .claude/agents/grader.md for two releases while every test stayed
# green (LESSONS.md, 2026-06-12). "Installs cleanly" now has to mean fresh
# installs AND in-place upgrades, proven by an executed test rather than by
# inspection — so this spec builds a GENUINE v3.5 install (from the v3.5.0 git
# tag, using v3.5.0's OWN installer), seeds the customizations a real operator
# would have, runs the shipped installer with NO FLAGS, and asserts the end
# state file by file.
#
# Auto-detection is deliberately part of the subject: the upgrade run passes no
# --upgrade and no --mode. If detect_v3_install() ever stops firing, section 5
# fails rather than quietly taking the flat mode-2 path.
#
# DELIBERATE DEVIATION: NO bd_required_or_skip
# --------------------------------------------
# Every other bd-touching spec in this tier calls `bd_required_or_skip`, which
# exits 0 with a SKIPPED line when the real Beads CLI is absent — and CI sets
# BD_SHIM_ONLY=1 precisely because there is no public bd installer to curl.
# This spec would therefore NEVER RUN in CI, which is the one place the upgrade
# path most needs a guard. install.sh only ever asks bd for four things
# (`--version`, `init`, `hooks install`, `doctor`) and ignores everything but
# the version string and a case-insensitive 'error' grep of doctor's output, so
# a stub is a complete stand-in. We write a fake-bd into a bin dir prepended to
# PATH and run for real, in CI and on dev machines alike. mk_fixture is skipped
# for the same reason (it builds a wrapper around the REAL bd); the fixture
# cleanup array from lib/fixture.sh is still used for teardown.
#
# SECTIONS
#   1. Tag gate            — v3.5.0 must be reachable; hard FAIL in CI (the CI
#                            checkout carries fetch-depth: 0 for exactly this),
#                            skip-with-log locally.
#   2. Frozen-table integrity — manifests/v3.5.0.sha256 is byte-identical to a
#                            manifest regenerated from the tag tree.
#   3. Genuine v3.5 fixture — v3.5.0's own installer, v3.5 markers present, v4
#                            markers absent.
#   4. Operator customizations — CLAUDE.md, LESSONS.md, settings env key,
#                            rubric rule, an .mcp.json server, a gate record
#                            under the dotfile-only .qa-tracking/.
#   5. The upgrade under test — no flags; readout assertions.
#   6. Post-state          — parity, preservation, merges, backup, manifest.
#   7. META-TESTs          — a second fixture proves the preservation is
#                            detector-driven (not unconditional), a third
#                            proves the backup checker can fail.
#   8. Re-runs (v4.1 / U0.4) — the second run on an already-upgraded tree:
#                            no-change probe skips the backup, a customization
#                            made AFTER the upgrade is preserved rather than
#                            re-clobbered, and two METAs prove both of those
#                            assertions can fail. Sections 8d and 8e (v4.1 /
#                            U0.5) add the two riders U0.4 left open: the probe
#                            counting a re-created merged-class file as a write,
#                            and WHICH old table an --upgrade classifies
#                            against — the target's own install-manifest when it
#                            has a usable one, else the frozen table for the
#                            release the target DECLARES, which is
#                            v4.1.0.sha256 for a 4.1 tree now that this release
#                            freezes one, not v3.5.0.sha256 unconditionally.
#   9. Fresh vs upgraded    — the upgraded tree and a FRESH install of the same
#                            source differ in EXACTLY the expected places
#                            (preserved operator files + the two merged files)
#                            and nowhere else, with a META that plants a
#                            divergent workflow file and watches the assertion
#                            fail.
#  10. Truthful failure report (v4.1 / U0.8, x15 review finding R1-F2) — a
#                            fixture whose settings.json AND .mcp.json are both
#                            unmergeable: the on-disk outcomes DIFFER (one left
#                            untouched, one replaced by the shipped config) and
#                            the saved report has to say which, instead of
#                            calling both "installed as shipped". 10c strips the
#                            renderer from a copy and watches 10b fail.
#
# Runtime is dominated by three v3.5 installs plus three upgrades, and (sections
# 8-9) four fresh v4 installs plus eight re-runs/upgrades; each is well under two
# seconds because the installer copies a ~10 MB tree and hashes ~250 files, with
# no network and no LLM calls.

set -u

# INSTALLER FLAGS FOR THE L2 TIER (v4.1 / C0b) -------------------------------
# install.sh now does two things after the copy loops that this spec has no
# business paying for:
#   1. `npm ci` per MCP server IN THE TARGET. That needs the npm registry, so
#      leaving it on would make assertions about FILE COPYING fail on an
#      offline machine — a network dependency in the component tier.
#   2. workflow-doctor.sh, exiting 3 ("installed, verification FAILED") when a
#      functional check does not pass. This spec's fixtures are not built to
#      satisfy eleven functional checks, and every `install.sh exits 0`
#      assertion here would start reporting a fixture gap as an installer bug.
# Both are covered for real by `make install-test`, which installs into a
# tempdir and requires a fully green doctor — that is the surface that proves
# dependency provisioning works, and it is now expected to be GREEN.
# Exported once so every installer invocation in this file inherits them
# without a per-call-site flag; the v3.5-era installer some of these specs also
# run ignores unknown environment variables.
export CWP_SKIP_MCP_DEPS=1
export CWP_SKIP_VERIFY=1

PLUGIN_ROOT=$(plugin_root)
TAG="v3.5.0"
MANIFEST_TOOL="$PLUGIN_ROOT/.claude/scripts/workflow-manifest.sh"
FROZEN_TABLE="$PLUGIN_ROOT/manifests/v3.5.0.sha256"

WORK=$(mktemp -d -t cwp-v3upgrade.XXXXXX)
__COMPONENT_FIXTURES_TO_CLEAN+=("$WORK")

# Operator sentinels. Distinct strings so a survival assertion cannot pass on
# the wrong file's content.
CLAUDE_SENTINEL="OPERATOR-SENTINEL-CLAUDE-MD"
LESSON_SENTINEL="OPERATOR-SENTINEL-LESSON-LEDGER"
RUBRIC_SENTINEL="OPERATOR-SENTINEL-RUBRIC-RULE"
# Seeded verbatim AND asserted verbatim from this one literal, so the two can
# never drift. The bare ${SOMEVAR} is intentional: project-scoped .mcp.json
# needs the ${VAR:-default} form, and the installer must NAME the problem
# without rewriting an operator-owned server.
OPERATOR_SERVER_JSON='{"type":"stdio","command":"node","args":["${SOMEVAR}/thing.js"]}'

# --- fake bd ----------------------------------------------------------------
FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/bd" <<'FAKE_BD'
#!/bin/bash
# fake-bd — the entire `bd` surface install.sh touches. Deliberate: this spec
# must run in CI where the real Beads CLI is unavailable (see spec header).
# `doctor` output must never contain the string 'error' — install.sh greps for
# it case-insensitively and would print a spurious warning.
case "${1:-}" in
    --version|-v|version)
        printf 'bd 0.99.0 (fake-bd for installer specs)\n'
        ;;
    init)
        printf 'fake-bd: initialized Beads workspace\n'
        ;;
    hooks)
        printf 'fake-bd: git hooks installed\n'
        ;;
    doctor)
        printf 'fake-bd: all checks passed\n'
        ;;
    *)
        printf 'fake-bd: ok (%s)\n' "${1:-}"
        ;;
esac
exit 0
FAKE_BD
chmod +x "$FAKE_BIN/bd"
export PATH="$FAKE_BIN:$PATH"

# --- helpers ----------------------------------------------------------------

# seed_v35_install <dir> — a genuine v3.5 install: git-init <dir>, then run
# v3.5.0's OWN installer into it. Returns the installer's exit code.
seed_v35_install() {
    local dir="$1"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q >/dev/null 2>&1 || true
        # An empty commit keeps any `git rev-parse HEAD` consumer happy and
        # stops the installer's "Initialize git repository?" prompt path.
        git -c user.email=test@example.com -c user.name=test \
            commit --allow-empty -q -m "v3.5 baseline" >/dev/null 2>&1 || true
    )
    bash "$SRC35/install.sh" --mode=1 "$dir" </dev/null \
        >"$WORK/$(basename "$dir")-install-v35.log" 2>&1
}

# run_upgrade <dir> <logfile> — the shipped installer, NO FLAGS. Auto-detection
# is part of what is under test, so nothing is passed that could bypass it.
run_upgrade() {
    bash "$PLUGIN_ROOT/install.sh" "$1" </dev/null >"$2" 2>&1
}

# backup_count_of <target> — how many .claude-v3-backup-* dirs exist.
backup_count_of() {
    find "$1" -maxdepth 1 -type d -name '.claude-v3-backup-*' 2>/dev/null \
        | grep -c . | tr -d ' \n'
}

# backup_dir_of <target> — the (first) .claude-v3-backup-* dir, or "".
backup_dir_of() {
    find "$1" -maxdepth 1 -type d -name '.claude-v3-backup-*' 2>/dev/null \
        | sort | head -1
}

# CHECKER (shared with the section 7 META): the backup carries the gate record
# that lives under the DOTFILE directory .claude/.qa-tracking/. This is the one
# assertion that would have caught the `cp -r dir/*` glob, which silently omits
# dotfiles — the whole gate history of a live install.
#   0 = present, 1 = absent
backup_has_seeded_record() {
    [ -f "$1/.qa-tracking/seeded-record.txt" ]
}

# CHECKER (shared with the section 7 META): the operator's file was preserved
# and the shipped version written alongside as <path>.new.
#   0 = the .new file exists, 1 = it does not
preserved_new_exists() {
    [ -f "$1/$2.new" ]
}

# yesno <command...> — "yes" when the command succeeds, "no" when it does not.
# Keeps boolean assertions readable in assert_eq's expected/actual output.
#
# The wrapped command's own output is discarded, and that is load-bearing: this
# is called inside $( ), so a command that PRINTS as well as returning a status
# (git rev-parse echoes the sha) would otherwise prepend its stdout to the
# yes/no and every such assertion would silently compare against garbage.
yesno() {
    if "$@" >/dev/null 2>&1; then printf 'yes'; else printf 'no'; fi
}

# ===========================================================================
# Section 1: tag gate
# ===========================================================================
# The fixture is built from the real v3.5.0 tag, so the tag has to be there.
# In CI that is guaranteed (the l2-component checkout sets fetch-depth: 0 for
# this spec); a silent skip in CI would let the whole upgrade path rot
# unnoticed, which is the regression this gate prevents. Locally — shallow
# clone, worktree without tags — we skip with a log instead of failing a dev's
# suite for an environment reason.
TAG_PRESENT=$(yesno git -C "$PLUGIN_ROOT" rev-parse -q --verify "$TAG^{commit}")
if [ "$TAG_PRESENT" != "yes" ]; then
    if [ "${CI:-}" = "true" ]; then
        assert_eq "installer-v3-upgrade 1: $TAG tag reachable (CI must fetch tags)" \
            "yes" "$TAG_PRESENT"
        printf '  diagnostic: git -C %s rev-parse %s^{commit} failed.\n' "$PLUGIN_ROOT" "$TAG"
        printf '  diagnostic: the l2-component job needs actions/checkout with fetch-depth: 0.\n'
        exit 1
    fi
    printf 'SKIPPED: %s tag unavailable (shallow clone or tagless worktree)\n' "$TAG"
    exit 0
fi
assert_eq "installer-v3-upgrade 1: $TAG tag reachable" "yes" "$TAG_PRESENT"

# ===========================================================================
# Section 2: frozen-table integrity
# ===========================================================================
# manifests/v3.5.0.sha256 is the table the upgrade uses to tell "operator never
# touched this stock file" from "operator edited it". If it drifts from the
# actual v3.5.0 tree, every verdict downstream is wrong — stock files start
# looking customized and vice versa. Byte comparison, no tolerance.
SRC35="$WORK/src35"
mkdir -p "$SRC35"
ARCHIVE_RC=0
( set -o pipefail; git -C "$PLUGIN_ROOT" archive "$TAG" | tar -x -C "$SRC35" ) \
    || ARCHIVE_RC=$?
assert_eq "installer-v3-upgrade 2: git archive $TAG extracts cleanly" "0" "$ARCHIVE_RC"
assert_eq "installer-v3-upgrade 2: extracted tag tree carries its own install.sh" \
    "yes" "$(yesno test -f "$SRC35/install.sh")"

GEN35_RC=0
bash "$MANIFEST_TOOL" generate "$SRC35" > "$WORK/gen35.tsv" 2>"$WORK/gen35.err" \
    || GEN35_RC=$?
assert_eq "installer-v3-upgrade 2: workflow-manifest.sh generate on the tag tree exits 0" \
    "0" "$GEN35_RC"
TABLE_CMP_RC=0
cmp -s "$WORK/gen35.tsv" "$FROZEN_TABLE" || TABLE_CMP_RC=$?
if [ "$TABLE_CMP_RC" -ne 0 ]; then
    printf '  diagnostic: first differing rows (regenerated vs frozen):\n'
    diff "$WORK/gen35.tsv" "$FROZEN_TABLE" 2>/dev/null | head -10 | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 2: manifests/v3.5.0.sha256 is byte-identical to the regenerated tag manifest" \
    "0" "$TABLE_CMP_RC"

# ===========================================================================
# Section 3: genuine v3.5 fixture
# ===========================================================================
# Built by v3.5.0's OWN installer, not by hand and not by the current one: a
# hand-rolled "v3.5-shaped" tree would let a detection or hash bug pass because
# the fixture was built to match the code under test.
T="$WORK/target"
V35_RC=0
seed_v35_install "$T" || V35_RC=$?
if [ "$V35_RC" -ne 0 ]; then
    printf '  diagnostic: v3.5.0 installer exited %s; tail of log:\n' "$V35_RC"
    tail -15 "$WORK/target-install-v35.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 3: v3.5.0's own installer exits 0 with fake-bd on PATH" \
    "0" "$V35_RC"
assert_eq "installer-v3-upgrade 3: fixture manifest declares version 3.5.0" \
    "3.5.0" "$(jq -r '.version // empty' "$T/.claude-plugin/plugin.json" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 3: fixture carries the v3.5 marker .claude/scripts/qa-gate.sh" \
    "yes" "$(yesno test -f "$T/.claude/scripts/qa-gate.sh")"
assert_eq "installer-v3-upgrade 3: fixture lacks the v4 marker .claude/scripts/review-check.sh" \
    "no" "$(yesno test -e "$T/.claude/scripts/review-check.sh")"
assert_eq "installer-v3-upgrade 3: fixture lacks the v4 marker .claude/model-roles" \
    "no" "$(yesno test -e "$T/.claude/model-roles")"

# ===========================================================================
# Section 4: seed operator customizations
# ===========================================================================
# Six operator-owned edits, one per mechanism the upgrade must respect:
#   CLAUDE.md              never touched (not in the shipped surface at all)
#   LESSONS.md             operator class -> preserve + .new
#   .claude/settings.json  merged class  -> key-wise jq merge
#   .claude/rubrics/*.md   operator class -> preserve + .new
#   .mcp.json              merged class  -> key-wise jq merge
#   .claude/.qa-tracking/  dotfile directory -> must reach the backup
printf '\n<!-- %s -->\n' "$CLAUDE_SENTINEL" >> "$T/CLAUDE.md"
printf '\n- %s: never trust an unproven upgrade path.\n' "$LESSON_SENTINEL" >> "$T/LESSONS.md"
printf '\n- %s: rollback must be demonstrated, not asserted.\n' "$RUBRIC_SENTINEL" \
    >> "$T/.claude/rubrics/default.md"
jq '.env.OPERATOR_KEY = "op-1"' "$T/.claude/settings.json" > "$WORK/settings.seeded.json" \
    && cp "$WORK/settings.seeded.json" "$T/.claude/settings.json"
jq --argjson srv "$OPERATOR_SERVER_JSON" '.mcpServers["operator-thing"] = $srv' \
    "$T/.mcp.json" > "$WORK/mcp.seeded.json" \
    && cp "$WORK/mcp.seeded.json" "$T/.mcp.json"
mkdir -p "$T/.claude/.qa-tracking"
printf 'seeded gate record (pre-upgrade)\n' > "$T/.claude/.qa-tracking/seeded-record.txt"

# Pre-conditions. Without these, a silently-failed seed would make the
# section 6 preservation assertions pass for the wrong reason.
assert_eq "installer-v3-upgrade 4: seeded settings.json carries env.OPERATOR_KEY pre-upgrade" \
    "op-1" "$(jq -r '.env.OPERATOR_KEY // empty' "$T/.claude/settings.json" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 4: seeded .mcp.json carries the operator server pre-upgrade" \
    "$(printf '%s' "$OPERATOR_SERVER_JSON" | jq -cS .)" \
    "$(jq -cS '.mcpServers["operator-thing"]' "$T/.mcp.json" 2>/dev/null || echo "")"
assert_contains "installer-v3-upgrade 4: seeded rubric carries the operator rule pre-upgrade" \
    "$RUBRIC_SENTINEL" "$(cat "$T/.claude/rubrics/default.md")"
assert_eq "installer-v3-upgrade 4: seeded gate record exists under the dotfile .qa-tracking/" \
    "yes" "$(yesno test -f "$T/.claude/.qa-tracking/seeded-record.txt")"

# Pre-upgrade bytes we compare against later.
PRE_QA_GATE="$WORK/pre-qa-gate.sh"
cp "$T/.claude/scripts/qa-gate.sh" "$PRE_QA_GATE"

# ===========================================================================
# Section 5: the upgrade under test
# ===========================================================================
UPGRADE_LOG_FILE="$WORK/upgrade.log"
UPGRADE_RC=0
run_upgrade "$T" "$UPGRADE_LOG_FILE" || UPGRADE_RC=$?
if [ "$UPGRADE_RC" -ne 0 ]; then
    printf '  diagnostic: upgrade exited %s; tail of log:\n' "$UPGRADE_RC"
    tail -25 "$UPGRADE_LOG_FILE" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 5: install.sh with NO flags exits 0 on a v3.5 target" \
    "0" "$UPGRADE_RC"

UPGRADE_LOG=$(cat "$UPGRADE_LOG_FILE" 2>/dev/null || echo "")
BACKUP_DIR=$(backup_dir_of "$T")
SOURCE_VERSION=$(jq -r '.version // empty' "$PLUGIN_ROOT/.claude-plugin/plugin.json" 2>/dev/null || echo "")

# Auto-detection, not a flag, chose this path.
assert_contains "installer-v3-upgrade 5: readout reports auto-detection of the v3.5.0 install" \
    "Detected v3.5.0 plugin installation" "$UPGRADE_LOG"
# Both versions come from the two plugin.json files; neither is hardcoded in
# the installer, so this line also pins that they are read dynamically.
assert_contains "installer-v3-upgrade 5: readout names both versions on one upgrade line" \
    "Upgrade complete: v3.5.0 -> v$SOURCE_VERSION" "$UPGRADE_LOG"
assert_contains "installer-v3-upgrade 5: readout uses the word preserved" \
    "preserved" "$UPGRADE_LOG"
assert_contains "installer-v3-upgrade 5: readout mentions the .new convention" \
    ".new" "$UPGRADE_LOG"
assert_contains "installer-v3-upgrade 5: readout names the backup directory" \
    "$BACKUP_DIR" "$UPGRADE_LOG"
assert_contains "installer-v3-upgrade 5: readout points at the CHANGELOG hash-migration note" \
    "UPGRADE NOTE" "$UPGRADE_LOG"
# The v3 readout REPLACES the generic tail rather than printing alongside it.
assert_not_contains "installer-v3-upgrade 5: v3 readout replaces the generic completion tail" \
    "Installation complete." "$UPGRADE_LOG"

# ===========================================================================
# Section 6: post-state
# ===========================================================================

# --- 6a. packaging parity: every workflow-class file landed, byte-exact -----
# Driven from the generator, not from a hand-written list: that is what makes
# the grader.md class of failure (a shipped file the installer forgot)
# structurally impossible rather than merely unlikely.
SRC_MANIFEST="$WORK/source-manifest.tsv"
TGT_MANIFEST="$WORK/target-manifest.tsv"
SRC_GEN_RC=0
bash "$MANIFEST_TOOL" generate "$PLUGIN_ROOT" > "$SRC_MANIFEST" 2>/dev/null || SRC_GEN_RC=$?
TGT_GEN_RC=0
bash "$MANIFEST_TOOL" generate "$T" > "$TGT_MANIFEST" 2>/dev/null || TGT_GEN_RC=$?
assert_eq "installer-v3-upgrade 6a: generate on the plugin source exits 0" "0" "$SRC_GEN_RC"
assert_eq "installer-v3-upgrade 6a: generate on the upgraded target exits 0" "0" "$TGT_GEN_RC"

# Guard against a vacuous parity pass: an empty or truncated source manifest
# would make the comparison below trivially true.
SRC_WORKFLOW_ROWS=$(awk -F'\t' '$2 == "workflow"' "$SRC_MANIFEST" 2>/dev/null | grep -c . | tr -d ' \n')
assert_eq "installer-v3-upgrade 6a: source manifest lists a plausible number of workflow files (>90)" \
    "yes" "$(yesno test "${SRC_WORKFLOW_ROWS:-0}" -gt 90)"

# The target manifest is loaded in BEGIN via getline rather than with the
# NR == FNR two-file idiom: NR == FNR is true for every record of the second
# file when the first contributed none, so an empty target manifest would make
# awk skip the whole comparison and report perfect parity.
PARITY_BAD=$(awk -F'\t' -v tgtf="$TGT_MANIFEST" '
    BEGIN {
        while ((getline line < tgtf) > 0) {
            n = split(line, f, "\t")
            if (n >= 3 && f[1] != "") { tgt[f[1]] = f[3] }
        }
        close(tgtf)
    }
    $2 == "workflow" {
        if (!($1 in tgt))          { print $1 " (absent)" }
        else if (tgt[$1] != $3)    { print $1 " (hash differs)" }
    }
' "$SRC_MANIFEST" | sort | tr '\n' ' ' | sed 's/ *$//')
assert_eq "installer-v3-upgrade 6a: every workflow-class file hash-matches in the upgraded target" \
    "" "$PARITY_BAD"

# --- 6b. operator rubric preserved, shipped version alongside ---------------
assert_contains "installer-v3-upgrade 6b: the operator's rubric rule survived the upgrade" \
    "$RUBRIC_SENTINEL" "$(cat "$T/.claude/rubrics/default.md" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 6b: .claude/rubrics/default.md.new was written alongside" \
    "yes" "$(yesno preserved_new_exists "$T" ".claude/rubrics/default.md")"
RUBRIC_NEW_CMP_RC=0
cmp -s "$T/.claude/rubrics/default.md.new" "$PLUGIN_ROOT/.claude/rubrics/default.md" \
    || RUBRIC_NEW_CMP_RC=$?
assert_eq "installer-v3-upgrade 6b: default.md.new is byte-identical to the shipped rubric" \
    "0" "$RUBRIC_NEW_CMP_RC"

# --- 6c. root-level operator content survived ------------------------------
assert_contains "installer-v3-upgrade 6c: the CLAUDE.md sentinel survived (never in the shipped surface)" \
    "$CLAUDE_SENTINEL" "$(cat "$T/CLAUDE.md" 2>/dev/null || echo "")"
assert_contains "installer-v3-upgrade 6c: the LESSONS.md sentinel survived" \
    "$LESSON_SENTINEL" "$(cat "$T/LESSONS.md" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 6c: LESSONS.md.new carries the shipped ledger alongside" \
    "yes" "$(yesno preserved_new_exists "$T" "LESSONS.md")"

# --- 6d. settings.json merged key-wise -------------------------------------
# The operator key survives, the retired env pin is deleted (union alone can
# only ADD keys, so its removal is the one thing that proves the del ran), and
# the workflow-owned hook block was replaced wholesale.
POST_SETTINGS=$(cat "$T/.claude/settings.json" 2>/dev/null || echo "{}")
assert_json_field "installer-v3-upgrade 6d: settings.json still carries env.OPERATOR_KEY" \
    "$POST_SETTINGS" '.env.OPERATOR_KEY' "op-1"
assert_json_field "installer-v3-upgrade 6d: settings.json no longer carries env.CLAUDE_CODE_EFFORT_LEVEL" \
    "$POST_SETTINGS" 'if (.env // {} | has("CLAUDE_CODE_EFFORT_LEVEL")) then "yes" else "no" end' "no"
assert_json_field "installer-v3-upgrade 6d: settings.json gained the v4 SubagentStart hook" \
    "$POST_SETTINGS" 'if (.hooks // {} | has("SubagentStart")) then "yes" else "no" end' "yes"
assert_json_field "installer-v3-upgrade 6d: settings.json carries a top-level effortLevel" \
    "$POST_SETTINGS" 'if has("effortLevel") then "yes" else "no" end' "yes"
assert_json_field "installer-v3-upgrade 6d: settings.json carries a top-level statusLine" \
    "$POST_SETTINGS" 'if has("statusLine") then "yes" else "no" end' "yes"

# --- 6e. .mcp.json merged key-wise -----------------------------------------
assert_eq "installer-v3-upgrade 6e: the operator's MCP server survived verbatim" \
    "$(printf '%s' "$OPERATOR_SERVER_JSON" | jq -cS .)" \
    "$(jq -cS '.mcpServers["operator-thing"]' "$T/.mcp.json" 2>/dev/null || echo "")"
assert_contains "installer-v3-upgrade 6e: shipped bd server uses the \${CLAUDE_PROJECT_DIR:-.} form" \
    '${CLAUDE_PROJECT_DIR:-.}' "$(jq -r '.mcpServers.bd.args[0] // empty' "$T/.mcp.json" 2>/dev/null || echo "")"
assert_contains "installer-v3-upgrade 6e: shipped code-graph server uses the \${CLAUDE_PROJECT_DIR:-.} form" \
    '${CLAUDE_PROJECT_DIR:-.}' "$(jq -r '.mcpServers["code-graph"].args[0] // empty' "$T/.mcp.json" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 6e: the retired code-context server is absent" \
    "no" "$(jq -r 'if (.mcpServers // {} | has("code-context")) then "yes" else "no" end' "$T/.mcp.json" 2>/dev/null || echo "err")"
assert_contains "installer-v3-upgrade 6e: the readout names the operator server carrying a bare variable" \
    "operator-thing" "$UPGRADE_LOG"

# --- 6f. the backup ---------------------------------------------------------
assert_eq "installer-v3-upgrade 6f: exactly one .claude-v3-backup-* directory exists" \
    "1" "$(backup_count_of "$T")"
assert_eq "installer-v3-upgrade 6f: the backup carries .qa-tracking/seeded-record.txt (dotfile-inclusive copy)" \
    "yes" "$(yesno backup_has_seeded_record "$BACKUP_DIR")"
# The backup must hold the PRE-upgrade bytes, and those bytes must actually
# differ from the post-upgrade file — otherwise "the backup matches" would be
# satisfied by an upgrade that changed nothing.
POST_QA_GATE_DIFFERS_RC=0
cmp -s "$PRE_QA_GATE" "$T/.claude/scripts/qa-gate.sh" || POST_QA_GATE_DIFFERS_RC=$?
assert_eq "installer-v3-upgrade 6f: qa-gate.sh actually changed in the upgrade" \
    "yes" "$(yesno test "$POST_QA_GATE_DIFFERS_RC" -ne 0)"
BACKUP_QA_GATE_CMP_RC=0
cmp -s "$BACKUP_DIR/scripts/qa-gate.sh" "$PRE_QA_GATE" || BACKUP_QA_GATE_CMP_RC=$?
assert_eq "installer-v3-upgrade 6f: the backup's qa-gate.sh is the pre-upgrade file byte-for-byte" \
    "0" "$BACKUP_QA_GATE_CMP_RC"
assert_eq "installer-v3-upgrade 6f: the backup carries the pre-upgrade plugin.json as plugin.json" \
    "3.5.0" "$(jq -r '.version // empty' "$BACKUP_DIR/plugin.json" 2>/dev/null || echo "")"

# --- 6g. install-manifest ---------------------------------------------------
INSTALL_MANIFEST="$T/.claude/install-manifest"
assert_eq "installer-v3-upgrade 6g: .claude/install-manifest was written" \
    "yes" "$(yesno test -f "$INSTALL_MANIFEST")"
assert_eq "installer-v3-upgrade 6g: install-manifest header names the installed version" \
    "# claude-workflow-plugin $SOURCE_VERSION" \
    "$(head -1 "$INSTALL_MANIFEST" 2>/dev/null || echo "")"
MANIFEST_BODY_CMP_RC=0
tail -n +2 "$INSTALL_MANIFEST" 2>/dev/null | cmp -s - "$SRC_MANIFEST" || MANIFEST_BODY_CMP_RC=$?
assert_eq "installer-v3-upgrade 6g: install-manifest body byte-equals the generated source manifest" \
    "0" "$MANIFEST_BODY_CMP_RC"

# --- 6h. the saved report ---------------------------------------------------
REPORT="$BACKUP_DIR/upgrade-report.txt"
assert_eq "installer-v3-upgrade 6h: upgrade-report.txt was saved into the backup" \
    "yes" "$(yesno test -f "$REPORT")"
REPORT_TEXT=$(cat "$REPORT" 2>/dev/null || echo "")
assert_contains "installer-v3-upgrade 6h: the saved report names the preserved rubric" \
    ".claude/rubrics/default.md" "$REPORT_TEXT"
assert_contains "installer-v3-upgrade 6h: the saved report carries the same upgrade line" \
    "Upgrade complete: v3.5.0 -> v$SOURCE_VERSION" "$REPORT_TEXT"
# R1-F2, the SUCCESS half. Both merges really ran on this fixture (6d/6e just
# proved the operator's key and server survived), so the report has to say so
# per file and must NOT fall back to the "nothing to merge" sentence. Section 10
# takes the failure half.
assert_contains "installer-v3-upgrade 6h (R1-F2): the report reports settings.json as merged, naming the .bak" \
    ".claude/settings.json  (your pre-upgrade copy: .claude/settings.json.bak)" "$REPORT_TEXT"
assert_contains "installer-v3-upgrade 6h (R1-F2): ...and .mcp.json the same way" \
    ".mcp.json              (your pre-upgrade copy: .mcp.json.bak)" "$REPORT_TEXT"
assert_not_contains "installer-v3-upgrade 6h (R1-F2): neither merged file is described as installed-as-shipped" \
    "installed as shipped" "$REPORT_TEXT"
assert_not_contains "installer-v3-upgrade 6h (R1-F2): and no merge-failure sentence appears on a successful run" \
    "MERGE FAILED" "$REPORT_TEXT"

# --- 6i. the shipped-docs subset landed (v4.1 / U0.8) -----------------------
# 6a already covers these two through the manifest-driven parity walk; they are
# called out by name because they are the newest surface members and because the
# SUBSET property (exactly two, not all of docs/) has no other home on the
# upgrade path. A v3.5 target has no docs/ directory at all, so the upgrade also
# has to CREATE it — the failure mode being an installer that copies into a
# parent that does not exist and dies mid-upgrade.
for upgraded_doc in docs/CODEX_SETUP.md docs/HOOKS.md; do
    assert_eq "installer-v3-upgrade 6i: the upgrade installed $upgraded_doc" \
        "yes" "$(yesno test -f "$T/$upgraded_doc")"
    assert_eq "installer-v3-upgrade 6i: ...byte-identical to the shipped copy" \
        "yes" "$(yesno cmp -s "$T/$upgraded_doc" "$PLUGIN_ROOT/$upgraded_doc")"
done
UPGRADED_DOCS=$( (cd "$T" && find docs -type f 2>/dev/null | LC_ALL=C sort) \
    | tr '\n' ' ' | sed 's/ *$//')
assert_eq "installer-v3-upgrade 6i: docs/ holds EXACTLY the two shipped files (a subset, never a scan)" \
    "$(printf '%s\n' "docs/CODEX_SETUP.md" "docs/HOOKS.md" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" \
    "$UPGRADED_DOCS"
# Both are class workflow, so neither may produce an operator-style sidecar.
for upgraded_doc in docs/CODEX_SETUP.md docs/HOOKS.md; do
    assert_eq "installer-v3-upgrade 6i: no .new sidecar for $upgraded_doc (workflow class, not operator)" \
        "no" "$(yesno preserved_new_exists "$T" "$upgraded_doc")"
done
# The per-file readout named them, and named them as WRITTEN. On this fixture the
# v3.5 installer left no docs/ behind, so both rows classify copy-new and
# place_by_verdict prints the plain `OK   <rel>` line; the two prefixes asserted
# absent are the ones that would mean the verdict had come out
# skip-current (`same`) or preserve-custom (`keep`) instead. The distinction
# matters because replace-stock IS reachable for docs/HOOKS.md — on a target that
# carries the untouched v3.5 file — and that is exactly what the refreeze
# enables; workflow-manifest.test.sh section 4d pins all four reachable verdicts
# against a purpose-built fixture.
#
# The log is ANSI-stripped first: the installer colours these lines, so the
# escape sequence sits between `OK` and the path and a fixed-string match on the
# rendered prefix would silently never fire.
UPGRADE_LOG_PLAIN=$(printf '%s' "$UPGRADE_LOG" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')
assert_contains "installer-v3-upgrade 6i: the ANSI-stripped readout is non-empty (guards the two checks below)" \
    "Upgrade complete:" "$UPGRADE_LOG_PLAIN"
for upgraded_doc in docs/CODEX_SETUP.md docs/HOOKS.md; do
    assert_eq "installer-v3-upgrade 6i: the readout reports $upgraded_doc as written (OK, exactly once)" \
        "1" "$(printf '%s\n' "$UPGRADE_LOG_PLAIN" | grep -c -F -- "OK   $upgraded_doc" | tr -d ' \n')"
    assert_not_contains "installer-v3-upgrade 6i: ...not as already-current" \
        "same $upgraded_doc" "$UPGRADE_LOG_PLAIN"
    assert_not_contains "installer-v3-upgrade 6i: ...and not as an operator file kept back" \
        "keep $upgraded_doc" "$UPGRADE_LOG_PLAIN"
done

# ===========================================================================
# Section 7: META-TESTs
# ===========================================================================

# --- META (a): preservation is DETECTOR-driven, not unconditional ----------
# A second genuine v3.5 fixture with the rubric left ALONE. If the installer
# wrote a .new file for every operator-class file regardless of customization,
# section 6b would pass for the wrong reason and operators would get spurious
# .new litter on every upgrade. On this fixture the section 6b assertions MUST
# NOT hold: no .new file, and the rubric matching the shipped bytes.
T2="$WORK/target-pristine"
V35_RC_2=0
seed_v35_install "$T2" || V35_RC_2=$?
assert_eq "installer-v3-upgrade 7a: second v3.5 fixture installs cleanly" "0" "$V35_RC_2"
UPGRADE_RC_2=0
run_upgrade "$T2" "$WORK/upgrade2.log" || UPGRADE_RC_2=$?
assert_eq "installer-v3-upgrade 7a: second fixture upgrades cleanly" "0" "$UPGRADE_RC_2"
assert_eq "installer-v3-upgrade 7a META-TEST: no default.md.new when the rubric was never customized" \
    "no" "$(yesno preserved_new_exists "$T2" ".claude/rubrics/default.md")"
PRISTINE_RUBRIC_CMP_RC=0
cmp -s "$T2/.claude/rubrics/default.md" "$PLUGIN_ROOT/.claude/rubrics/default.md" \
    || PRISTINE_RUBRIC_CMP_RC=$?
assert_eq "installer-v3-upgrade 7a META-TEST: an uncustomized rubric matches the shipped bytes after upgrade" \
    "0" "$PRISTINE_RUBRIC_CMP_RC"

# --- META (b): the backup checker can FAIL --------------------------------
# A third genuine v3.5 fixture whose .qa-tracking/ is seeded and then DELETED
# before the upgrade. backup_has_seeded_record — the identical function section
# 6f asserts on — must report absent here. Without this, a checker that always
# returned 0 would satisfy 6f and the dotfile-copy fix would be untested.
T3="$WORK/target-nodotfiles"
V35_RC_3=0
seed_v35_install "$T3" || V35_RC_3=$?
assert_eq "installer-v3-upgrade 7b: third v3.5 fixture installs cleanly" "0" "$V35_RC_3"
mkdir -p "$T3/.claude/.qa-tracking"
printf 'seeded then removed\n' > "$T3/.claude/.qa-tracking/seeded-record.txt"
rm -rf "$T3/.claude/.qa-tracking"
UPGRADE_RC_3=0
run_upgrade "$T3" "$WORK/upgrade3.log" || UPGRADE_RC_3=$?
assert_eq "installer-v3-upgrade 7b: third fixture upgrades cleanly" "0" "$UPGRADE_RC_3"
BACKUP_DIR_3=$(backup_dir_of "$T3")
assert_eq "installer-v3-upgrade 7b: third fixture produced a backup directory" \
    "yes" "$(yesno test -d "$BACKUP_DIR_3")"
assert_eq "installer-v3-upgrade 7b META-TEST: the backup checker reports ABSENT when .qa-tracking was removed" \
    "no" "$(yesno backup_has_seeded_record "$BACKUP_DIR_3")"

# ===========================================================================
# Section 8: re-runs (v4.1 / U0.4)
# ===========================================================================
# Sections 1-7 prove ONE run. The gap they leave is the second one: an upgraded
# tree is a v4 tree, so detect_v3_install correctly declines and the run falls
# to the flat mode-2 Update — which through v4.0 plain-copied every shipped
# file and re-clobbered anything the operator had changed since the upgrade.
# The same clobber the whole flow exists to prevent, one run later.
#
# Two behaviours are under test here:
#   the no-change probe   same release + zero write verdicts -> no backup dir,
#                         because a timestamped backup per re-run is noise the
#                         operator has to clean up by hand;
#   the verdict walk      mode 2 classifies against the target's OWN
#                         .claude/install-manifest, so operator files get the
#                         same preserve-and-write-.new treatment as an upgrade.
#
# WHY --mode=2 RATHER THAN NO FLAGS. Section 5 deliberately passes no flags
# because auto-detection is part of what it proves. Here it cannot: on a v4
# target the mode PROMPT is reachable, and the installer reads it from
# /dev/tty whenever a controlling terminal is openable — so a bare re-run would
# block forever on a developer's machine while passing in CI. --mode=2 selects
# the identical branch the non-interactive default picks (case 2), which is
# exactly what the flag is documented for.
#
# WHY 8a RUNS ON THE PRISTINE FIXTURE. The probe skips the backup only when the
# plan carries ZERO write verdicts, and preserve-custom is a write (it puts a
# <path>.new on disk). T still carries two preserved customizations from
# section 4, so a re-run there legitimately writes and legitimately backs up —
# that is 8b. The pristine fixture T2 is the tree where "nothing to do" is
# literally true, so it is the one that must skip its backup.

# update_backup_count_of <target> — how many mode-1/2 .claude-backup-* dirs
# exist. Deliberately a DIFFERENT prefix from backup_count_of's
# .claude-v3-backup-*: the two mechanisms must be counted separately or "no new
# backup" would be satisfied by the upgrade's own backup from section 5.
update_backup_count_of() {
    find "$1" -maxdepth 1 -type d -name '.claude-backup-*' 2>/dev/null \
        | grep -c . | tr -d ' \n'
}

# run_update_with <installer> <target> <logfile> — a mode-2 Update run. Every
# re-run in this section (real installer AND the two section-8c mutants) goes
# through this one function, so a mutant can never differ from the subject by
# how it was invoked.
run_update_with() {
    bash "$1" --mode=2 "$2" </dev/null >"$3" 2>&1
}

run_update() {
    run_update_with "$PLUGIN_ROOT/install.sh" "$1" "$2"
}

# workflow_rows_to <target> <outfile> — the workflow-class rows of the target's
# generated manifest (path + sha256). Comparing this file across a re-run is
# how "no plugin-owned file changed" is proven by hash rather than by mtime.
workflow_rows_to() {
    bash "$MANIFEST_TOOL" generate "$1" 2>/dev/null | awk -F'\t' '$2 == "workflow"' > "$2"
}

# seed_v4_install <dir> <installer> — a fresh v4 install with <installer>.
# git-init FIRST for the same reason seed_v35_install does: the installer's
# "Initialize git repository?" prompt also falls through to /dev/tty.
seed_v4_install() {
    local dir="$1"
    local installer="$2"
    mkdir -p "$dir"
    (
        cd "$dir" || exit 1
        git init -q >/dev/null 2>&1 || true
        git -c user.email=test@example.com -c user.name=test \
            commit --allow-empty -q -m "v4 baseline" >/dev/null 2>&1 || true
    )
    bash "$installer" "$dir" </dev/null \
        >"$WORK/$(basename "$dir")-install-v4.log" 2>&1
}

# The readout line the probe prints, built from the version the source
# plugin.json declares — never a hardcoded release number.
SKIP_BACKUP_LINE="already at $SOURCE_VERSION; no file changes — skipping backup"

# --- 8a. idempotency: re-running an unchanged tree writes nothing -----------
T2_WORKFLOW_PRE="$WORK/t2-workflow-pre.tsv"
T2_WORKFLOW_POST="$WORK/t2-workflow-post.tsv"
workflow_rows_to "$T2" "$T2_WORKFLOW_PRE"
T2_WORKFLOW_ROWS=$(grep -c . "$T2_WORKFLOW_PRE" | tr -d ' \n')
# Guard against a vacuous comparison: an empty pre-file would make the cmp
# below trivially true.
assert_eq "installer-v3-upgrade 8a: the upgraded pristine tree lists a plausible number of workflow files (>90)" \
    "yes" "$(yesno test "${T2_WORKFLOW_ROWS:-0}" -gt 90)"

RERUN_RC=0
run_update "$T2" "$WORK/rerun-idempotent.log" || RERUN_RC=$?
RERUN_LOG=$(cat "$WORK/rerun-idempotent.log" 2>/dev/null || echo "")
if [ "$RERUN_RC" -ne 0 ]; then
    printf '  diagnostic: idempotent re-run exited %s; tail of log:\n' "$RERUN_RC"
    tail -20 "$WORK/rerun-idempotent.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 8a: a second run on the upgraded tree exits 0" \
    "0" "$RERUN_RC"
# The Update was verdict-driven, not a plain copy: this line is the whole of
# U0.4 deliverable 1 showing up in the readout.
assert_contains "installer-v3-upgrade 8a: the re-run classified against the target's own install-manifest" \
    "classified against .claude/install-manifest" "$RERUN_LOG"
assert_contains "installer-v3-upgrade 8a: the re-run reports the no-change probe skipping the backup" \
    "$SKIP_BACKUP_LINE" "$RERUN_LOG"
assert_eq "installer-v3-upgrade 8a: no mode-2 .claude-backup-* directory was created" \
    "0" "$(update_backup_count_of "$T2")"
assert_eq "installer-v3-upgrade 8a: still exactly one .claude-v3-backup-* directory" \
    "1" "$(backup_count_of "$T2")"
# The v3 flow must NOT have re-fired on a tree it already upgraded.
assert_not_contains "installer-v3-upgrade 8a: the re-run did not re-enter the v3 upgrade flow" \
    "Backing up the installed plugin to" "$RERUN_LOG"

workflow_rows_to "$T2" "$T2_WORKFLOW_POST"
T2_ROWS_CMP_RC=0
cmp -s "$T2_WORKFLOW_PRE" "$T2_WORKFLOW_POST" || T2_ROWS_CMP_RC=$?
if [ "$T2_ROWS_CMP_RC" -ne 0 ]; then
    printf '  diagnostic: workflow rows that changed across the re-run:\n'
    diff "$T2_WORKFLOW_PRE" "$T2_WORKFLOW_POST" 2>/dev/null | head -10 | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 8a: every workflow-class file hash is unchanged by the re-run" \
    "0" "$T2_ROWS_CMP_RC"
# No spurious .new litter: the pristine fixture had none after section 7a and
# a no-op re-run must not invent one.
assert_eq "installer-v3-upgrade 8a: no default.md.new appeared on the uncustomized tree" \
    "no" "$(yesno preserved_new_exists "$T2" ".claude/rubrics/default.md")"
assert_eq "installer-v3-upgrade 8a: the re-run wrote no .new file anywhere in the tree" \
    "0" "$(find "$T2" -name '*.new' -type f 2>/dev/null | grep -c . | tr -d ' \n')"
# The manifest is rewritten even when the backup is skipped — the probe gates
# the backup, nothing else.
assert_eq "installer-v3-upgrade 8a: install-manifest still names the installed version after the re-run" \
    "# claude-workflow-plugin $SOURCE_VERSION" \
    "$(head -1 "$T2/.claude/install-manifest" 2>/dev/null || echo "")"

# --- 8b. a customization made AFTER the upgrade is preserved, not clobbered -
# The re-clobber regression itself. T already carries the section-4 sentinel
# (which section 6b proved survived the upgrade); this adds a SECOND, freshly
# written one so the assertion cannot pass on the strength of the first.
POST_UPGRADE_SENTINEL="OPERATOR-SENTINEL-RUBRIC-POST-UPGRADE"
printf '\n- %s: an edit made after the upgrade, before the next run.\n' \
    "$POST_UPGRADE_SENTINEL" >> "$T/.claude/rubrics/default.md"
assert_contains "installer-v3-upgrade 8b: the post-upgrade rubric edit is in place before the re-run" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$T/.claude/rubrics/default.md" 2>/dev/null || echo "")"

RECUSTOM_RC=0
run_update "$T" "$WORK/rerun-recustomized.log" || RECUSTOM_RC=$?
RECUSTOM_LOG=$(cat "$WORK/rerun-recustomized.log" 2>/dev/null || echo "")
if [ "$RECUSTOM_RC" -ne 0 ]; then
    printf '  diagnostic: re-customized re-run exited %s; tail of log:\n' "$RECUSTOM_RC"
    tail -20 "$WORK/rerun-recustomized.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 8b: the re-run on a re-customized tree exits 0" \
    "0" "$RECUSTOM_RC"
POST_RERUN_RUBRIC=$(cat "$T/.claude/rubrics/default.md" 2>/dev/null || echo "")
assert_contains "installer-v3-upgrade 8b: the post-upgrade rubric edit SURVIVED the re-run (re-clobber regression)" \
    "$POST_UPGRADE_SENTINEL" "$POST_RERUN_RUBRIC"
assert_contains "installer-v3-upgrade 8b: the original pre-upgrade rubric rule is still there too" \
    "$RUBRIC_SENTINEL" "$POST_RERUN_RUBRIC"
assert_eq "installer-v3-upgrade 8b: the shipped rubric is alongside as default.md.new" \
    "yes" "$(yesno preserved_new_exists "$T" ".claude/rubrics/default.md")"
RERUN_NEW_CMP_RC=0
cmp -s "$T/.claude/rubrics/default.md.new" "$PLUGIN_ROOT/.claude/rubrics/default.md" \
    || RERUN_NEW_CMP_RC=$?
assert_eq "installer-v3-upgrade 8b: default.md.new still carries the shipped bytes" \
    "0" "$RERUN_NEW_CMP_RC"
# A .new must never be treated as a shipped path in its own right.
assert_eq "installer-v3-upgrade 8b: no default.md.new.new was produced" \
    "no" "$(yesno test -e "$T/.claude/rubrics/default.md.new.new")"
assert_eq "installer-v3-upgrade 8b: exactly one .new file under .claude/rubrics/" \
    "1" "$(find "$T/.claude/rubrics" -name '*.new' -type f 2>/dev/null | grep -c . | tr -d ' \n')"
# This run HAD something to write, so the probe must decline and the backup
# must be taken — the complement of 8a, and what 8c mutates.
assert_not_contains "installer-v3-upgrade 8b: the no-change probe did NOT fire (there was work to do)" \
    "$SKIP_BACKUP_LINE" "$RECUSTOM_LOG"
assert_eq "installer-v3-upgrade 8b: a mode-2 .claude-backup-* directory WAS created" \
    "1" "$(update_backup_count_of "$T")"
RECUSTOM_BACKUP=$(find "$T" -maxdepth 1 -type d -name '.claude-backup-*' 2>/dev/null | sort | head -1)
assert_contains "installer-v3-upgrade 8b: that backup holds the operator's rubric as it was" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$RECUSTOM_BACKUP/rubrics/default.md" 2>/dev/null || echo "")"
assert_contains "installer-v3-upgrade 8b: the readout names the preserved rubric and its .new" \
    ".claude/rubrics/default.md.new" "$RECUSTOM_LOG"

# --- 8c. META-TESTs: both 8b assertions can fail ---------------------------
# Each mutant is a COPY of the shipped installer with ONE sentinel-delimited
# region changed, run against a fixture of the same shape as 8b: a v4 tree
# carrying an install-manifest and an operator-customized rubric.
#
# THE CONTROL IS THE POINT. A mutation META is only worth its runtime if the
# fixture would have produced the OTHER outcome under the unmutated installer —
# otherwise "0 backups" could simply mean "this tree had nothing to write".
# So one fixture is built, cloned three ways byte-for-byte, and run through the
# real installer and the two mutants. One variable, three outcomes.
#
# The mutants need a source tree to install FROM: install.sh uses its own
# directory when that directory looks like a plugin checkout, and CLONES FROM
# THE NETWORK when it does not — which a spec must never do. So extract HEAD
# once, drop the installer under test into it, and swap the mutants in there.
# install.sh is not part of the shipped surface, so swapping it perturbs no
# hash and no verdict.
META_SRC="$WORK/meta-src"
mkdir -p "$META_SRC"
META_ARCHIVE_RC=0
( set -o pipefail; git -C "$PLUGIN_ROOT" archive HEAD | tar -x -C "$META_SRC" ) \
    || META_ARCHIVE_RC=$?
assert_eq "installer-v3-upgrade 8c: git archive HEAD extracts a source tree for the mutants" \
    "0" "$META_ARCHIVE_RC"
cp "$PLUGIN_ROOT/install.sh" "$META_SRC/install.sh"

# WORKING-TREE OVERLAY (v4.1 / claude-workflow-plugin-0fc).
#
# `git archive HEAD` is HEAD-only, but the install.sh copied in just above comes
# from the WORKING TREE. Those two disagree the moment a change adds a file to
# install.sh's required-source list without committing it: the working-tree
# installer demands `.claude/scripts/<new>.sh`, HEAD's tree does not have it,
# and EVERY install in sections 8c-8e aborts with "Plugin source missing" —
# 39 assertions failing for a reason that has nothing to do with what they test.
# Observed exactly once, when workflow-doctor.sh joined the required list.
#
# The fix keeps the archive (a consistent, .gitignore-respecting snapshot) and
# overlays the working tree's SHIPPED SURFACE on top, so META_SRC always matches
# the installer under test. The surface is enumerated by the repo's own
# workflow-manifest.sh rather than a hand-written path list — a second list here
# would be one more thing to forget, which is the failure mode this overlay
# exists to remove. Self-consistent by construction: seed_v4_install generates
# the target's install-manifest FROM META_SRC, so the hashes downstream
# assertions classify against are the overlaid bytes.
#
# Best-effort: a failure to enumerate leaves the pure-HEAD tree in place (the
# pre-overlay behaviour), and the install assertions below still report it.
META_OVERLAY_TOOL="$PLUGIN_ROOT/.claude/scripts/workflow-manifest.sh"
META_OVERLAY_COUNT=0
if [ -f "$META_OVERLAY_TOOL" ]; then
    while IFS="$(printf '\t')" read -r rel _class _hash; do
        [ -n "$rel" ] || continue
        [ -f "$PLUGIN_ROOT/$rel" ] || continue
        mkdir -p "$META_SRC/$(dirname "$rel")" 2>/dev/null || continue
        cp "$PLUGIN_ROOT/$rel" "$META_SRC/$rel" 2>/dev/null \
            && META_OVERLAY_COUNT=$((META_OVERLAY_COUNT + 1))
    done <<EOF
$(bash "$META_OVERLAY_TOOL" generate "$PLUGIN_ROOT" 2>/dev/null || true)
EOF
fi
# Non-vacuity: an overlay that copied nothing would silently restore the exact
# HEAD-only fragility this block removes.
if [ "$META_OVERLAY_COUNT" -gt 20 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: installer-v3-upgrade 8c: working-tree surface overlaid onto the archived source (%s file(s))\n' \
        "$META_OVERLAY_COUNT"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("installer-v3-upgrade 8c: the working-tree overlay copied only $META_OVERLAY_COUNT file(s); META_SRC may not match the installer under test")
    printf '  FAIL: installer-v3-upgrade 8c: working-tree overlay copied only %s file(s) (expected the whole shipped surface)\n' \
        "$META_OVERLAY_COUNT"
fi
# Pin the specific class that broke: every path install.sh REQUIRES must now be
# present in META_SRC, whether or not it is committed yet.
#
# The extraction is anchored on install.sh's own `for required in \` block and
# its `    ; do` terminator. Those anchors are TEXT, so a reformat of install.sh
# would make the awk range match nothing, the loop below would run zero times,
# and the "" comparison would be green forever while asserting nothing. The
# floor below closes that — same non-vacuity discipline as META_OVERLAY_COUNT
# directly above, applied to the reader instead of the writer. 20 is a
# deliberate under-estimate of the real list (25 entries as of v4.1) so a
# legitimate shrink does not trip it.
META_REQ_MISSING=""
META_REQ_COUNT=0
while IFS= read -r req; do
    [ -n "$req" ] || continue
    META_REQ_COUNT=$((META_REQ_COUNT + 1))
    [ -e "$META_SRC/$req" ] || META_REQ_MISSING="$META_REQ_MISSING $req"
done <<EOF
$(awk '/^for required in \\$/, /^    ; do$/' "$META_SRC/install.sh" 2>/dev/null \
    | sed -n 's/^[[:space:]]*"\([^"]*\)".*/\1/p')
EOF
if [ "$META_REQ_COUNT" -gt 20 ]; then
    PASS=$((PASS + 1))
    printf '  PASS: installer-v3-upgrade 8c: the required-source extraction found %s path(s) to assert about\n' \
        "$META_REQ_COUNT"
else
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("installer-v3-upgrade 8c: the required-source extraction yielded only $META_REQ_COUNT path(s) — the awk anchors ('for required in \\' / '    ; do') have probably drifted, making the assertion below vacuous")
    printf '  FAIL: installer-v3-upgrade 8c: required-source extraction yielded only %s path(s); the awk anchors have drifted and the next assertion is vacuous\n' \
        "$META_REQ_COUNT"
fi
assert_eq "installer-v3-upgrade 8c: every path install.sh requires exists in the overlaid source" \
    "" "$META_REQ_MISSING"

# clone_meta_fixture <name> — a byte-for-byte copy of the base fixture at
# $WORK/<name>, printed on stdout. `cp -R src/. dst/` and not `src/*`: the
# whole tree under test is dotfiles (.claude/, .claude-plugin/, .git/), which
# the glob form silently skips — the same trap the installer's own backups hit.
clone_meta_fixture() {
    local dst="$WORK/$1"
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -R "$META_BASE/." "$dst/" 2>/dev/null || true
    printf '%s' "$dst"
}

META_BASE="$WORK/meta-base"
META_BASE_RC=0
seed_v4_install "$META_BASE" "$META_SRC/install.sh" || META_BASE_RC=$?
if [ "$META_BASE_RC" -ne 0 ]; then
    printf '  diagnostic: fresh v4 META fixture install exited %s; tail of log:\n' "$META_BASE_RC"
    tail -15 "$WORK/meta-base-install-v4.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 8c: the fresh v4 META fixture installs cleanly" \
    "0" "$META_BASE_RC"
printf '\n- %s: operator rule written on a fresh v4 tree.\n' "$POST_UPGRADE_SENTINEL" \
    >> "$META_BASE/.claude/rubrics/default.md"
# Pre-condition: without the customization in place every assertion below
# would pass for the wrong reason.
assert_contains "installer-v3-upgrade 8c: the META fixture carries the operator rule before any run" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$META_BASE/.claude/rubrics/default.md" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 8c: the META fixture carries an install-manifest to classify against" \
    "yes" "$(yesno test -f "$META_BASE/.claude/install-manifest")"

# CONTROL: the unmutated installer on this exact tree. Backs up AND preserves.
META_CONTROL=$(clone_meta_fixture "meta-control")
META_CONTROL_RC=0
run_update_with "$META_SRC/install.sh" "$META_CONTROL" "$WORK/meta-control.log" \
    || META_CONTROL_RC=$?
assert_eq "installer-v3-upgrade 8c CONTROL: the shipped installer completes on the META fixture" \
    "0" "$META_CONTROL_RC"
assert_contains "installer-v3-upgrade 8c CONTROL: the shipped installer PRESERVES the operator rule" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$META_CONTROL/.claude/rubrics/default.md" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 8c CONTROL: the shipped installer TAKES a backup (there was work)" \
    "1" "$(update_backup_count_of "$META_CONTROL")"

# META (a): force the no-change probe TRUE, anchored inside the NOCHANGE-PROBE
# sentinels so the mutation cannot drift onto another line.
META_PROBE="$WORK/install-probe-forced.sh"
sed '/# NOCHANGE-PROBE-START/,/# NOCHANGE-PROBE-END/ s/UPDATE_SKIP_BACKUP=false/UPDATE_SKIP_BACKUP=true/' \
    "$PLUGIN_ROOT/install.sh" > "$META_PROBE"
# One rewritten line shows up as a < / > pair. Zero would mean the sentinels
# drifted and the mutation silently did nothing — the way a META rots.
PROBE_DIFF_LINES=$(diff "$PLUGIN_ROOT/install.sh" "$META_PROBE" 2>/dev/null | grep -c '^[<>]' | tr -d ' \n')
assert_eq "installer-v3-upgrade 8c META-TEST: the probe mutation rewrote exactly one line (one < / > pair)" \
    "2" "$PROBE_DIFF_LINES"
assert_eq "installer-v3-upgrade 8c META-TEST: the probe-forced copy is still valid bash" \
    "yes" "$(yesno bash -n "$META_PROBE")"

META_A=$(clone_meta_fixture "meta-probe-forced")
cp "$META_PROBE" "$META_SRC/install.sh"
META_A_RC=0
run_update_with "$META_SRC/install.sh" "$META_A" "$WORK/meta-probe-rerun.log" || META_A_RC=$?
assert_eq "installer-v3-upgrade 8c: the probe-forced copy still completes" "0" "$META_A_RC"
# The CONTROL took a backup on this identical tree; the mutant does not.
assert_eq "installer-v3-upgrade 8c META-TEST: probe forced TRUE -> 8b's backup assertion FAILS (0 backups, control had 1)" \
    "0" "$(update_backup_count_of "$META_A")"
assert_contains "installer-v3-upgrade 8c META-TEST: the forced probe prints the skip line with work still pending" \
    "$SKIP_BACKUP_LINE" "$(cat "$WORK/meta-probe-rerun.log" 2>/dev/null || echo "")"
# Scope check: the probe gates the BACKUP and nothing else, so preservation is
# unaffected. If this flipped too, the mutation would be proving two things at
# once and neither cleanly.
assert_contains "installer-v3-upgrade 8c META-TEST: the forced probe does NOT affect preservation" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$META_A/.claude/rubrics/default.md" 2>/dev/null || echo "")"

# META (b): delete the verdict-driven Update block. The mutant falls back to
# the pre-v4.1 plain-copy Update — precisely the re-clobber this task fixed —
# so 8b's preservation assertion must fail against it.
META_LEGACY="$WORK/install-verdict-stripped.sh"
sed '/# UPDATE-VERDICT-START/,/# UPDATE-VERDICT-END/d' "$PLUGIN_ROOT/install.sh" > "$META_LEGACY"
SUT_LINES=$(wc -l < "$PLUGIN_ROOT/install.sh" | tr -d ' ')
LEGACY_LINES=$(wc -l < "$META_LEGACY" | tr -d ' ')
assert_eq "installer-v3-upgrade 8c META-TEST: the strip removed the verdict block (fewer lines)" \
    "yes" "$(yesno test "$LEGACY_LINES" -lt "$SUT_LINES")"
assert_eq "installer-v3-upgrade 8c META-TEST: the stripped copy is still valid bash" \
    "yes" "$(yesno bash -n "$META_LEGACY")"

META_B=$(clone_meta_fixture "meta-verdict-stripped")
cp "$META_LEGACY" "$META_SRC/install.sh"
META_B_RC=0
run_update_with "$META_SRC/install.sh" "$META_B" "$WORK/meta-legacy-rerun.log" || META_B_RC=$?
assert_eq "installer-v3-upgrade 8c: the verdict-stripped copy still completes" "0" "$META_B_RC"
# The CONTROL preserved the rule on this identical tree; the mutant overwrites
# it with the shipped rubric. That is the whole U0.4 regression, on the record.
assert_not_contains "installer-v3-upgrade 8c META-TEST: verdict block stripped -> 8b's preservation assertion FAILS (rubric clobbered)" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$META_B/.claude/rubrics/default.md" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 8c META-TEST: the stripped copy wrote no .new alongside either" \
    "no" "$(yesno preserved_new_exists "$META_B" ".claude/rubrics/default.md")"
# ...and it got there by losing the classification, not by some other route:
# the line 8a asserts is present must be absent here.
assert_not_contains "installer-v3-upgrade 8c META-TEST: the stripped copy never classified against the install-manifest" \
    "classified against .claude/install-manifest" \
    "$(cat "$WORK/meta-legacy-rerun.log" 2>/dev/null || echo "")"
# The backup is untouched by this mutation — it is the preservation that moved.
assert_eq "installer-v3-upgrade 8c META-TEST: the stripped copy still took its backup" \
    "1" "$(update_backup_count_of "$META_B")"

# ===========================================================================
# Section 8d: the probe counts a re-created merged-class file as a write
# ===========================================================================
# U0.4 shipped the no-change probe with a documented hole (pnf probe (h)).
# classify emits `merge` for the two merged-class files unconditionally,
# plan_write_count counted only verdict rows, and the two jq merges own only the
# case where the file EXISTS — so an operator who DELETED .mcp.json and re-ran
# the same release was told "no file changes" while the installer put the file
# back. Nothing could be lost (an absent file has nothing to lose, and a mode-2
# backup snapshots only .claude/), but the probe's contract — "it fired, so this
# run wrote nothing" — stopped being exactly true, and an invariant that is only
# nearly true is one a future change can break without failing a test.
#
# U0.5 counts the write rather than softening the readout to "no tracked file
# changes". This is that choice on the record: ONE fixture, cloned three ways,
# one variable per clone.
#
#   CONTROL   untouched tree            -> probe fires, no backup. Proves this
#                                          fixture is one where "nothing to do"
#                                          is literally true, so the SUBJECT's
#                                          decline cannot be for another reason.
#   SUBJECT   .mcp.json deleted         -> probe declines, backup taken, file
#                                          re-created.
#   MUTANT    .mcp.json deleted, and the MERGED-ABSENT block deleted from the
#             installer                 -> probe fires while the file is
#                                          re-created. The pre-U0.5 behaviour,
#                                          asserted so the fix cannot silently
#                                          regress.

# clone_tree <src> <name> — a byte-for-byte copy of <src> at $WORK/<name>,
# printed on stdout. The general form of clone_meta_fixture, which is pinned to
# META_BASE. `cp -R src/. dst/` and not `src/*`: the whole tree under test is
# dotfiles (.claude/, .claude-plugin/, .git/), which the glob form silently
# skips — the same trap the installer's own backups hit.
clone_tree() {
    local dst="$WORK/$2"
    rm -rf "$dst"
    mkdir -p "$dst"
    cp -R "$1/." "$dst/" 2>/dev/null || true
    printf '%s' "$dst"
}

# use_meta_installer <path> — install <path> into the META source tree as the
# installer under test. Section 8c leaves a MUTANT sitting there, so every later
# section that wants the real one has to say so out loud.
use_meta_installer() {
    cp "$1" "$META_SRC/install.sh"
}

# run_forced_upgrade_with <installer> <target> <logfile> — a `--upgrade` run.
# Section 5 deliberately passes no flags because auto-detection is what it
# proves; sections 8e cannot, because the subject there IS the forced flow on a
# target auto-detection would decline (a 4.x tree is not a v3 install).
run_forced_upgrade_with() {
    bash "$1" --upgrade "$2" </dev/null >"$3" 2>&1
}

use_meta_installer "$PLUGIN_ROOT/install.sh"
PROBE_BASE="$WORK/probe-base"
PROBE_BASE_RC=0
seed_v4_install "$PROBE_BASE" "$META_SRC/install.sh" || PROBE_BASE_RC=$?
if [ "$PROBE_BASE_RC" -ne 0 ]; then
    printf '  diagnostic: the 8d fixture install exited %s; tail of log:\n' "$PROBE_BASE_RC"
    tail -15 "$WORK/probe-base-install-v4.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 8d: the fresh v4 fixture for the probe installs cleanly" \
    "0" "$PROBE_BASE_RC"
assert_eq "installer-v3-upgrade 8d: it carries .mcp.json (the merged-class file under test)" \
    "yes" "$(yesno test -f "$PROBE_BASE/.mcp.json")"
assert_eq "installer-v3-upgrade 8d: it carries an install-manifest to classify against" \
    "yes" "$(yesno test -f "$PROBE_BASE/.claude/install-manifest")"

# CONTROL: nothing removed, nothing customized.
PROBE_CONTROL=$(clone_tree "$PROBE_BASE" "probe-control")
PROBE_CONTROL_RC=0
run_update_with "$META_SRC/install.sh" "$PROBE_CONTROL" "$WORK/probe-control.log" \
    || PROBE_CONTROL_RC=$?
assert_eq "installer-v3-upgrade 8d CONTROL: the re-run on an untouched clone completes" \
    "0" "$PROBE_CONTROL_RC"
assert_contains "installer-v3-upgrade 8d CONTROL: an untouched tree still skips its backup" \
    "$SKIP_BACKUP_LINE" "$(cat "$WORK/probe-control.log" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 8d CONTROL: and creates no .claude-backup-* directory" \
    "0" "$(update_backup_count_of "$PROBE_CONTROL")"

# SUBJECT: the merged-class file is gone before the re-run.
PROBE_SUBJECT=$(clone_tree "$PROBE_BASE" "probe-deleted-mcp")
rm -f "$PROBE_SUBJECT/.mcp.json"
assert_eq "installer-v3-upgrade 8d: the subject clone really has no .mcp.json before the re-run" \
    "no" "$(yesno test -e "$PROBE_SUBJECT/.mcp.json")"
PROBE_SUBJECT_RC=0
run_update_with "$META_SRC/install.sh" "$PROBE_SUBJECT" "$WORK/probe-subject.log" \
    || PROBE_SUBJECT_RC=$?
PROBE_SUBJECT_LOG=$(cat "$WORK/probe-subject.log" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 8d: the re-run on the subject clone completes" \
    "0" "$PROBE_SUBJECT_RC"
assert_eq "installer-v3-upgrade 8d: the re-run re-created .mcp.json" \
    "yes" "$(yesno test -f "$PROBE_SUBJECT/.mcp.json")"
PROBE_MCP_CMP_RC=0
cmp -s "$PROBE_SUBJECT/.mcp.json" "$META_SRC/.mcp.json" || PROBE_MCP_CMP_RC=$?
assert_eq "installer-v3-upgrade 8d: and it re-created the SHIPPED bytes" \
    "0" "$PROBE_MCP_CMP_RC"
assert_not_contains "installer-v3-upgrade 8d: the probe did NOT claim 'no file changes' while writing one" \
    "$SKIP_BACKUP_LINE" "$PROBE_SUBJECT_LOG"
assert_eq "installer-v3-upgrade 8d: and the backup was taken" \
    "1" "$(update_backup_count_of "$PROBE_SUBJECT")"

# MUTANT: the counting term is deleted, anchored inside its sentinels.
META_MERGED="$WORK/install-merged-absent-stripped.sh"
sed '/# MERGED-ABSENT-START/,/# MERGED-ABSENT-END/d' "$PLUGIN_ROOT/install.sh" > "$META_MERGED"
MERGED_STRIP_LINES=$(diff "$PLUGIN_ROOT/install.sh" "$META_MERGED" 2>/dev/null | grep -c '^<' | tr -d ' \n')
assert_eq "installer-v3-upgrade 8d META-TEST: the strip removed the sentinel block (lines deleted)" \
    "yes" "$(yesno test "${MERGED_STRIP_LINES:-0}" -ge 5)"
assert_eq "installer-v3-upgrade 8d META-TEST: the stripped copy is still valid bash" \
    "yes" "$(yesno bash -n "$META_MERGED")"

PROBE_MUTANT=$(clone_tree "$PROBE_BASE" "probe-mutant")
rm -f "$PROBE_MUTANT/.mcp.json"
use_meta_installer "$META_MERGED"
PROBE_MUTANT_RC=0
run_update_with "$META_SRC/install.sh" "$PROBE_MUTANT" "$WORK/probe-mutant.log" \
    || PROBE_MUTANT_RC=$?
assert_eq "installer-v3-upgrade 8d: the stripped copy still completes" "0" "$PROBE_MUTANT_RC"
# Same tree, same deleted file: the real installer declined and backed up, the
# mutant announces "no file changes" and skips — while re-creating the file.
assert_contains "installer-v3-upgrade 8d META-TEST: MERGED-ABSENT stripped -> the probe fires with a write pending" \
    "$SKIP_BACKUP_LINE" "$(cat "$WORK/probe-mutant.log" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 8d META-TEST: -> and 8d's backup assertion FAILS (0 backups, subject had 1)" \
    "0" "$(update_backup_count_of "$PROBE_MUTANT")"
assert_eq "installer-v3-upgrade 8d META-TEST: the file is re-created either way (the readout was the defect, not the write)" \
    "yes" "$(yesno test -f "$PROBE_MUTANT/.mcp.json")"

# ===========================================================================
# Section 8e: WHICH old table an --upgrade classifies against
# ===========================================================================
# `--upgrade` on a 4.x target takes the v3 flow deliberately (backup + verdict
# walk). Which table it hashes the installed tree against is the subject here,
# and install.sh has exactly two sources, tried in that order:
#
#   1. $TARGET/.claude/install-manifest — the per-file hashes THIS tree was
#      really installed with. Preferred for any non-3.x target (U0.5).
#   2. manifests/v<declared>.sha256 — the frozen table for the release the
#      target declares, WHEN THE SOURCE SHIPS ONE; manifests/v3.5.0.sha256
#      otherwise.
#
# Source 2's "when the source ships one" is the whole story of this section.
# Through v4.0 manifests/ held v3.5.0.sha256 alone, so every 4.x target without
# an install-manifest fell back to a table that predates it: each file that
# changed between v3.5 and the installed release differs from BOTH the shipped
# copy and that old table, so STOCK files are classified customized —
# operator-class ones collect a spurious .new and are LEFT STALE (the
# operator's "version" is the shipped v4 file they never edited), workflow-class
# ones are reported as "replaced; yours is in the backup". That is the noise
# U0.5 added source 1 to remove.
#
# v4.1 then FROZE manifests/v4.1.0.sha256, which changes what a 4.1.0 fixture
# can prove. Both sources now describe the same release, so they agree
# file-for-file: the manifest-present / manifest-absent pair no longer differs
# in OUTCOME, only in which table the readout NAMES. Asserting the old noisy
# outcome for the manifest-less arm — which this section did until the table
# was frozen — asserts a defect that has been fixed.
#
# So the outcome-level proof moves to a fixture whose release has NO frozen
# table. That is not a contrived shape: v4.0.0 has none, and EVERY release has
# none between the version bump and the freeze. It is built by removing the
# table from a COPY OF THE SOURCE rather than by doctoring the target, so every
# target here stays a byte-exact clone of the same install; manifests/ is not
# part of the shipped surface (workflow-manifest.sh generate emits no row for
# it) and is never copied into a target, so removing it perturbs no hash and no
# verdict.
#
# Four legs on the 4.1 fixture, one variable each, plus a fifth on a genuine
# v3.5 target:
#
#   A  manifest present, source HAS the 4.1 table -> names install-manifest
#   B  manifest ABSENT,  source HAS the 4.1 table -> names v4.1.0.sha256, and
#                                                    classifies CORRECTLY
#   C  manifest ABSENT,  source has NO 4.1 table  -> names v3.5.0.sha256, and
#                                                    reproduces the old noise
#   D  manifest present, source has NO 4.1 table  -> names install-manifest,
#                                                    noise gone (C's variable)
#   E  genuine v3.5 target (section 5's run)      -> names v3.5.0.sha256
#
# C and D are the one-variable pair that proves U0.5 still earns its keep; that
# proof used to live in A/B and no longer can. B and E are the pair that proves
# the selector tracks the version the target DECLARES rather than a hardcoded
# name: same code path, two fixtures, two different right answers.
#
# The two source-side edits are made to files that are ABSENT from the frozen
# v3.5 table by construction (both arrived in v4). That is asserted below, not
# assumed: if either ever appeared in the frozen table the discrimination would
# quietly weaken and this META would stop proving anything.
FROZEN_ABSENT_OPERATOR=".claude/model-roles"
FROZEN_ABSENT_WORKFLOW=".claude/scripts/review-check.sh"
assert_eq "installer-v3-upgrade 8e: $FROZEN_ABSENT_OPERATOR is absent from the frozen v3.5 table" \
    "0" "$(awk -F'\t' -v p="$FROZEN_ABSENT_OPERATOR" '$1 == p { n++ } END { printf "%d", n + 0 }' "$FROZEN_TABLE")"
assert_eq "installer-v3-upgrade 8e: $FROZEN_ABSENT_WORKFLOW is absent from the frozen v3.5 table" \
    "0" "$(awk -F'\t' -v p="$FROZEN_ABSENT_WORKFLOW" '$1 == p { n++ } END { printf "%d", n + 0 }' "$FROZEN_TABLE")"

use_meta_installer "$PLUGIN_ROOT/install.sh"
UPG44_BASE="$WORK/v4-upgrade-base"
UPG44_BASE_RC=0
seed_v4_install "$UPG44_BASE" "$META_SRC/install.sh" || UPG44_BASE_RC=$?
assert_eq "installer-v3-upgrade 8e: the fresh v4 fixture for the 4->4 upgrade installs cleanly" \
    "0" "$UPG44_BASE_RC"
# One genuine operator customization, so "preserved (yours)" has a legitimate
# member and the assertion is about the SPURIOUS ones.
printf '\n- %s: operator rule on a v4 tree, before a 4 -> 4 upgrade.\n' "$POST_UPGRADE_SENTINEL" \
    >> "$UPG44_BASE/.claude/rubrics/default.md"
UPG44_MF_VERSION=$(head -1 "$UPG44_BASE/.claude/install-manifest" 2>/dev/null \
    | sed 's/^# claude-workflow-plugin //')
assert_eq "installer-v3-upgrade 8e: the fixture's install-manifest names a version" \
    "yes" "$(yesno test -n "$UPG44_MF_VERSION")"

# Now the SOURCE moves on, exactly as a 4.0 -> 4.1 release does. The fixture's
# manifest already recorded the pre-edit hashes, so these two files are stock in
# the target and changed in the source — the only shape in which the two old
# tables disagree.
printf '\n# source-side change, 8e\n' >> "$META_SRC/$FROZEN_ABSENT_OPERATOR"
printf '\n# source-side change, 8e\n' >> "$META_SRC/$FROZEN_ABSENT_WORKFLOW"

# LEG A — manifest present, source HAS the frozen 4.1 table: the manifest is
# preferred over it.
UPG44_SUBJECT=$(clone_tree "$UPG44_BASE" "v4-upgrade-manifest")
UPG44_SUBJECT_RC=0
run_forced_upgrade_with "$META_SRC/install.sh" "$UPG44_SUBJECT" "$WORK/v4-upgrade-manifest.log" \
    || UPG44_SUBJECT_RC=$?
UPG44_SUBJECT_LOG=$(cat "$WORK/v4-upgrade-manifest.log" 2>/dev/null || echo "")
if [ "$UPG44_SUBJECT_RC" -ne 0 ]; then
    printf '  diagnostic: the 4->4 upgrade exited %s; tail of log:\n' "$UPG44_SUBJECT_RC"
    tail -20 "$WORK/v4-upgrade-manifest.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 8e: --upgrade on a v4 target exits 0" "0" "$UPG44_SUBJECT_RC"
assert_contains "installer-v3-upgrade 8e: it classified against the target's own install-manifest" \
    "Classifying the installed tree against .claude/install-manifest (v$UPG44_MF_VERSION)" \
    "$UPG44_SUBJECT_LOG"
assert_contains "installer-v3-upgrade 8e: and the report names that table rather than a temp path" \
    "hashed against .claude/install-manifest (v$UPG44_MF_VERSION)" "$UPG44_SUBJECT_LOG"
# The two stock-but-changed files are replace-stock: replaced silently, no .new,
# no "yours is in the backup" line.
assert_contains "installer-v3-upgrade 8e: both stock-but-changed files are classified replaced (stock)" \
    "replaced (stock)       2" "$UPG44_SUBJECT_LOG"
assert_contains "installer-v3-upgrade 8e: nothing is misreported as replaced (customized)" \
    "replaced (customized)  0" "$UPG44_SUBJECT_LOG"
assert_contains "installer-v3-upgrade 8e: exactly the one real customization is preserved" \
    "preserved (yours)      1" "$UPG44_SUBJECT_LOG"
assert_eq "installer-v3-upgrade 8e: no spurious $FROZEN_ABSENT_OPERATOR.new was written" \
    "no" "$(yesno preserved_new_exists "$UPG44_SUBJECT" "$FROZEN_ABSENT_OPERATOR")"
UPG44_ROLES_CMP_RC=0
cmp -s "$UPG44_SUBJECT/$FROZEN_ABSENT_OPERATOR" "$META_SRC/$FROZEN_ABSENT_OPERATOR" \
    || UPG44_ROLES_CMP_RC=$?
assert_eq "installer-v3-upgrade 8e: the stock operator file actually got the new shipped bytes" \
    "0" "$UPG44_ROLES_CMP_RC"
UPG44_REVIEW_CMP_RC=0
cmp -s "$UPG44_SUBJECT/$FROZEN_ABSENT_WORKFLOW" "$META_SRC/$FROZEN_ABSENT_WORKFLOW" \
    || UPG44_REVIEW_CMP_RC=$?
assert_eq "installer-v3-upgrade 8e: the stock workflow file did too" "0" "$UPG44_REVIEW_CMP_RC"
# Preservation is unaffected: the rider changes WHICH table is consulted, not
# what happens to a file the operator really did edit.
assert_contains "installer-v3-upgrade 8e: the genuine operator rule survived" \
    "$POST_UPGRADE_SENTINEL" "$(cat "$UPG44_SUBJECT/.claude/rubrics/default.md" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 8e: with the shipped rubric alongside as .new" \
    "yes" "$(yesno preserved_new_exists "$UPG44_SUBJECT" ".claude/rubrics/default.md")"

# LEG B — manifest DELETED, source still HAS the frozen table for the release
# this fixture declares. It falls back to source 2 and picks the table NAMED FOR
# THAT VERSION, and because that table describes the same release the tree was
# installed from, the verdicts match leg A's exactly: no spurious .new, no stale
# stock file.
#
# The expected table name is read from the SOURCE TREE instead of being
# hardcoded. Both branches of the selector are asserted, and the reason is
# concrete rather than defensive: this section previously hardcoded
# v3.5.0.sha256, and freezing manifests/v4.1.0.sha256 turned four assertions red
# on a release commit for behaviour that had IMPROVED. A future release that
# bumps plugin.json before freezing its own table is the same event again, and
# it must not fail here — leg C constructs the no-table branch outright and leg
# E the has-table branch, so neither branch depends on which one this leg lands
# in.
if [ -f "$META_SRC/manifests/v$UPG44_MF_VERSION.sha256" ]; then
    UPG44_EXPECT_TABLE="v$UPG44_MF_VERSION.sha256"
else
    UPG44_EXPECT_TABLE=$(basename "$FROZEN_TABLE")
fi
UPG44_CONTROL=$(clone_tree "$UPG44_BASE" "v4-upgrade-frozen")
rm -f "$UPG44_CONTROL/.claude/install-manifest"
UPG44_CONTROL_RC=0
run_forced_upgrade_with "$META_SRC/install.sh" "$UPG44_CONTROL" "$WORK/v4-upgrade-frozen.log" \
    || UPG44_CONTROL_RC=$?
UPG44_CONTROL_LOG=$(cat "$WORK/v4-upgrade-frozen.log" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 8e B: the manifest-less clone still upgrades cleanly" \
    "0" "$UPG44_CONTROL_RC"
assert_contains "installer-v3-upgrade 8e B: with no manifest it falls back to the frozen table for the DECLARED version ($UPG44_EXPECT_TABLE)" \
    "Classifying the installed tree against $UPG44_EXPECT_TABLE" "$UPG44_CONTROL_LOG"
assert_contains "installer-v3-upgrade 8e B: and the report names that same table" \
    "hashed against $UPG44_EXPECT_TABLE" "$UPG44_CONTROL_LOG"
# Same verdicts as leg A. Asserting exact counts here looks like it couples this
# leg to manifests/v4.1.0.sha256 staying in sync with the working tree, and it
# does not: classify compares target-hash == source-hash FIRST and emits
# skip-current (workflow-manifest.sh, the arm above the old-table comparison),
# so a shipped file edited in the working tree is identical in the target and in
# the source and lands in no write bucket, whatever the frozen table says about
# it. Only the two edits this section makes ITSELF can move these numbers. That
# is a property of the code above, re-readable there; it was also checked once
# by hand while writing this, by drifting two unrelated shipped files and
# watching the three counts stay put. Nothing here re-checks it per run.
assert_contains "installer-v3-upgrade 8e B: both stock-but-changed files are classified replaced (stock)" \
    "replaced (stock)       2" "$UPG44_CONTROL_LOG"
assert_contains "installer-v3-upgrade 8e B: nothing is misreported as replaced (customized)" \
    "replaced (customized)  0" "$UPG44_CONTROL_LOG"
assert_contains "installer-v3-upgrade 8e B: exactly the one real customization is preserved" \
    "preserved (yours)      1" "$UPG44_CONTROL_LOG"
assert_eq "installer-v3-upgrade 8e B: no spurious $FROZEN_ABSENT_OPERATOR.new was written" \
    "no" "$(yesno preserved_new_exists "$UPG44_CONTROL" "$FROZEN_ABSENT_OPERATOR")"
UPG44_B_ROLES_CMP_RC=0
cmp -s "$UPG44_CONTROL/$FROZEN_ABSENT_OPERATOR" "$META_SRC/$FROZEN_ABSENT_OPERATOR" \
    || UPG44_B_ROLES_CMP_RC=$?
assert_eq "installer-v3-upgrade 8e B: the stock operator file got the new shipped bytes (NOT left stale)" \
    "0" "$UPG44_B_ROLES_CMP_RC"
assert_eq "installer-v3-upgrade 8e B: the genuine customization is still preserved as .new" \
    "yes" "$(yesno preserved_new_exists "$UPG44_CONTROL" ".claude/rubrics/default.md")"

# LEGS C and D — the source has NO frozen table for the declared release. This
# is the shape in which source 1 and source 2 still disagree, so it is where the
# U0.5 rider is proved to earn its keep. The source is a COPY with the table
# removed; META_SRC itself is left intact.
UPG44_NOFROZEN_SRC="$WORK/meta-src-nofrozen"
rm -rf "$UPG44_NOFROZEN_SRC"
cp -R "$META_SRC" "$UPG44_NOFROZEN_SRC" 2>/dev/null || true
rm -f "$UPG44_NOFROZEN_SRC/manifests/v$UPG44_MF_VERSION.sha256"
# Non-vacuity, both ways: the copy must really be missing the declared release's
# table AND must still carry the v3.5 fallback, or legs C and D would be
# testing a source that simply has no tables at all — which install.sh rejects
# outright with "the upgrade flow needs both".
assert_eq "installer-v3-upgrade 8e C/D: the no-frozen-table source really lacks v$UPG44_MF_VERSION.sha256" \
    "no" "$(yesno test -f "$UPG44_NOFROZEN_SRC/manifests/v$UPG44_MF_VERSION.sha256")"
assert_eq "installer-v3-upgrade 8e C/D: ...and still carries the v3.5 fallback table" \
    "yes" "$(yesno test -f "$UPG44_NOFROZEN_SRC/manifests/$(basename "$FROZEN_TABLE")")"
assert_eq "installer-v3-upgrade 8e C/D: ...and the source-side edits survived the copy" \
    "yes" "$(yesno cmp -s "$UPG44_NOFROZEN_SRC/$FROZEN_ABSENT_OPERATOR" "$META_SRC/$FROZEN_ABSENT_OPERATOR")"

# LEG C — no table, no manifest: the pre-U0.5 fallback, noise and all.
UPG44_C=$(clone_tree "$UPG44_BASE" "v4-upgrade-nofrozen-nomanifest")
rm -f "$UPG44_C/.claude/install-manifest"
UPG44_C_RC=0
run_forced_upgrade_with "$UPG44_NOFROZEN_SRC/install.sh" "$UPG44_C" \
    "$WORK/v4-upgrade-nofrozen-nomanifest.log" || UPG44_C_RC=$?
UPG44_C_LOG=$(cat "$WORK/v4-upgrade-nofrozen-nomanifest.log" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 8e C: no frozen table + no manifest still upgrades cleanly" \
    "0" "$UPG44_C_RC"
assert_contains "installer-v3-upgrade 8e C: with neither source available it falls back to $(basename "$FROZEN_TABLE")" \
    "Classifying the installed tree against $(basename "$FROZEN_TABLE")" "$UPG44_C_LOG"
# The noise, reproduced: the stock operator file is misread as the operator's.
assert_contains "installer-v3-upgrade 8e C: which misreports the stock operator file as preserved (2, not 1)" \
    "preserved (yours)      2" "$UPG44_C_LOG"
assert_eq "installer-v3-upgrade 8e C: and litters the spurious $FROZEN_ABSENT_OPERATOR.new" \
    "yes" "$(yesno preserved_new_exists "$UPG44_C" "$FROZEN_ABSENT_OPERATOR")"
# The real cost of the noise: the stock file is left STALE, so the operator has
# to merge a file they never edited.
UPG44_STALE_CMP_RC=0
cmp -s "$UPG44_C/$FROZEN_ABSENT_OPERATOR" "$UPG44_NOFROZEN_SRC/$FROZEN_ABSENT_OPERATOR" \
    || UPG44_STALE_CMP_RC=$?
assert_eq "installer-v3-upgrade 8e C: leaving the stock operator file stale (differs from shipped)" \
    "yes" "$(yesno test "$UPG44_STALE_CMP_RC" -ne 0)"

# LEG D — same source, same tree, manifest RESTORED. One variable against leg C,
# and the outcome flips: this is the assertion that the U0.5 rider is still
# load-bearing now that a 4.1 target's frozen table happens to agree with it.
UPG44_D=$(clone_tree "$UPG44_BASE" "v4-upgrade-nofrozen-manifest")
UPG44_D_RC=0
run_forced_upgrade_with "$UPG44_NOFROZEN_SRC/install.sh" "$UPG44_D" \
    "$WORK/v4-upgrade-nofrozen-manifest.log" || UPG44_D_RC=$?
UPG44_D_LOG=$(cat "$WORK/v4-upgrade-nofrozen-manifest.log" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 8e D: no frozen table + a manifest upgrades cleanly" \
    "0" "$UPG44_D_RC"
assert_contains "installer-v3-upgrade 8e D: the manifest is preferred even with no frozen table to fall back to" \
    "Classifying the installed tree against .claude/install-manifest (v$UPG44_MF_VERSION)" \
    "$UPG44_D_LOG"
assert_contains "installer-v3-upgrade 8e D: -> leg C's misreport is GONE (1, not 2)" \
    "preserved (yours)      1" "$UPG44_D_LOG"
assert_eq "installer-v3-upgrade 8e D: -> and leg C's spurious $FROZEN_ABSENT_OPERATOR.new is not written" \
    "no" "$(yesno preserved_new_exists "$UPG44_D" "$FROZEN_ABSENT_OPERATOR")"
UPG44_D_FRESH_CMP_RC=0
cmp -s "$UPG44_D/$FROZEN_ABSENT_OPERATOR" "$UPG44_NOFROZEN_SRC/$FROZEN_ABSENT_OPERATOR" \
    || UPG44_D_FRESH_CMP_RC=$?
assert_eq "installer-v3-upgrade 8e D: -> and leg C's stale stock file got the shipped bytes instead" \
    "0" "$UPG44_D_FRESH_CMP_RC"

# LEG E — a genuine v3.5-era target. No install-manifest existed before v4.1, so
# this tree can only take source 2, and the table it must land on is the one
# frozen for the release it declares: v3.5.0.sha256. Nothing asserted that until
# now — sections 1-7 check the VERDICTS of that upgrade but never which table
# produced them. A selector that started preferring the newest manifests/ entry
# would not have gone unnoticed (that mutation was run: sections 7a, 8a and 9
# all go red), but every one of those is a SYMPTOM — a missing .new here, an
# unexpected equivalence diff there — and none of them names the table as the
# cause. This leg is the one line that does. Asserted against section 5's
# already-executed no-flags upgrade ($UPGRADE_LOG), so it costs no extra run.
#
# This is the other half of leg B: same selector, a fixture declaring a
# different version, a different right answer. A hardcoded table name cannot
# satisfy both.
assert_contains "installer-v3-upgrade 8e E: a genuine v3.5 target still classifies against $(basename "$FROZEN_TABLE")" \
    "Classifying the installed tree against $(basename "$FROZEN_TABLE")" "$UPGRADE_LOG"
assert_contains "installer-v3-upgrade 8e E: and its report names that table too" \
    "hashed against $(basename "$FROZEN_TABLE")" "$UPGRADE_LOG"

# ===========================================================================
# Section 9: fresh vs upgraded equivalence
# ===========================================================================
# "Installs cleanly" has to mean the upgraded tree and a FRESH install of the
# same source are the same product. Sections 6a and 8a prove the parts; this is
# the whole: every path in the source manifest compared byte-for-byte between
# the upgraded T (v3.5 install -> upgrade -> mode-2 re-run, with two operator
# customizations along the way) and a fresh F, with the differing set asserted
# to be EXACTLY the four paths that have a reason to differ:
#
#   .claude/rubrics/default.md  preserved operator file (sections 4 + 8b)
#   LESSONS.md                  preserved operator file (section 4)
#   .claude/settings.json       merged key-wise in T, copied verbatim into F
#   .mcp.json                   merged key-wise in T, copied verbatim into F
#
# Anything else in that set is a real defect: a file the upgrade forgot to
# replace, a stale v3.5 file that survived, or a merge that leaked into a path it
# does not own. An EMPTY set would be a defect too — it would mean the
# customizations did not survive — so the assertion is equality with the exact
# list, not a subset check.
F="$WORK/fresh-v4"
FRESH_RC=0
seed_v4_install "$F" "$PLUGIN_ROOT/install.sh" || FRESH_RC=$?
if [ "$FRESH_RC" -ne 0 ]; then
    printf '  diagnostic: the fresh v4 install exited %s; tail of log:\n' "$FRESH_RC"
    tail -15 "$WORK/fresh-v4-install-v4.log" 2>/dev/null | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 9: a fresh v4 install of the same source exits 0" "0" "$FRESH_RC"

# CHECKER (shared with the section 9 META): the source-manifest paths whose
# BYTES differ between two installs, one per line, sorted. Driven from the
# manifest so it covers every shipped class — including the two merged files,
# which is what makes the expected set explicit rather than exempted.
equivalence_diff() {
    local manifest="$1"
    local a="$2"
    local b="$3"
    local epath eclass ehash
    while IFS=$'\t' read -r epath eclass ehash; do
        [ -n "$epath" ] || continue
        : "$eclass" "$ehash"
        if [ ! -f "$a/$epath" ] || [ ! -f "$b/$epath" ]; then
            printf '%s (missing on one side)\n' "$epath"
        elif ! cmp -s "$a/$epath" "$b/$epath"; then
            printf '%s\n' "$epath"
        fi
    done < "$manifest" | LC_ALL=C sort
}

# Expected side built from an explicit list run through the same sort, so the
# assertion names the four files without hardcoding a collation order.
EXPECTED_DIFF=$(printf '%s\n' \
    ".claude/rubrics/default.md" \
    "LESSONS.md" \
    ".claude/settings.json" \
    ".mcp.json" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')
ACTUAL_DIFF=$(equivalence_diff "$SRC_MANIFEST" "$T" "$F" | tr '\n' ' ' | sed 's/ *$//')
if [ "$ACTUAL_DIFF" != "$EXPECTED_DIFF" ]; then
    printf '  diagnostic: upgraded-vs-fresh differences, one per line:\n'
    equivalence_diff "$SRC_MANIFEST" "$T" "$F" | head -15 | sed 's/^/    /'
fi
assert_eq "installer-v3-upgrade 9: upgraded and fresh differ in EXACTLY the four expected paths" \
    "$EXPECTED_DIFF" "$ACTUAL_DIFF"

# The two merged files differ because they were MERGED, and the merge kept the
# operator's content — asserted here so their membership in the set above is
# accounted for rather than tolerated.
assert_json_field "installer-v3-upgrade 9: the upgraded settings.json carries the operator key the fresh one cannot" \
    "$(cat "$T/.claude/settings.json" 2>/dev/null || echo '{}')" '.env.OPERATOR_KEY' "op-1"
assert_eq "installer-v3-upgrade 9: the fresh settings.json does not" \
    "" "$(jq -r '.env.OPERATOR_KEY // empty' "$F/.claude/settings.json" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 9: the upgraded .mcp.json carries the operator server the fresh one cannot" \
    "$(printf '%s' "$OPERATOR_SERVER_JSON" | jq -cS .)" \
    "$(jq -cS '.mcpServers["operator-thing"]' "$T/.mcp.json" 2>/dev/null || echo "")"
assert_eq "installer-v3-upgrade 9: the fresh .mcp.json does not" \
    "no" "$(jq -r 'if (.mcpServers // {} | has("operator-thing")) then "yes" else "no" end' \
        "$F/.mcp.json" 2>/dev/null || echo "err")"

# new_sidecars_of <tree> — the *.new files in the LIVE tree, space-joined and
# sorted, with the backup and trash directories pruned.
#
# The prune is load-bearing rather than cosmetic: T's section-8b mode-2 backup
# was taken AFTER the section-5 upgrade had already written
# .claude/rubrics/default.md.new, so the backup legitimately holds a copy of that
# sidecar. A bare `find` over the tree therefore reports three sidecars for two
# real ones, and "no .new litter" would be asserted against snapshots of the tree
# rather than the tree.
new_sidecars_of() {
    ( cd "$1" && find . \
        \( -name '.claude-backup-*' -o -name '.claude-v2-backup-*' \
           -o -name '.claude-v3-backup-*' -o -name '.claude-uninstall-trash-*' \) -prune \
        -o -name '*.new' -type f -print 2>/dev/null ) \
        | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//'
}

# .new sidecars are an UPGRADE artifact only. A fresh install has nothing to
# preserve, so one appearing there would mean the verdict walk had leaked onto a
# path where every file is new by definition.
assert_eq "installer-v3-upgrade 9: the fresh install wrote no .new file anywhere" \
    "" "$(new_sidecars_of "$F")"
assert_eq "installer-v3-upgrade 9: the upgraded tree carries exactly the two expected .new sidecars" \
    "$(printf '%s\n' ".claude/rubrics/default.md.new" "LESSONS.md.new" | LC_ALL=C sort | tr '\n' ' ' | sed 's/ *$//')" \
    "$(new_sidecars_of "$T")"

# Both trees were written by the same source, so the record of WHAT was written
# has to be identical — byte for byte, header included. This is also what lets a
# later upgrade treat an upgraded tree and a fresh one identically.
EQ_MANIFEST_CMP_RC=0
cmp -s "$T/.claude/install-manifest" "$F/.claude/install-manifest" || EQ_MANIFEST_CMP_RC=$?
assert_eq "installer-v3-upgrade 9: both trees carry a byte-identical .claude/install-manifest" \
    "0" "$EQ_MANIFEST_CMP_RC"

# --- 9b META-TEST: the equivalence checker can FAIL -------------------------
# A byte appended to one workflow file in the upgraded tree — the shape of "the
# upgrade left a stale file behind". The checker must report that path, and the
# assertion above must stop holding. Restoring the file from F (byte-identical by
# construction, since the assertion above just proved it) puts the tree back, and
# the checker going quiet again proves the META did not simply latch.
META_DIVERGENT=".claude/scripts/session-start.sh"
printf '\n# 9b META-TEST divergence\n' >> "$T/$META_DIVERGENT"
META_DIFF=$(equivalence_diff "$SRC_MANIFEST" "$T" "$F" | tr '\n' ' ' | sed 's/ *$//')
assert_contains "installer-v3-upgrade 9b META-TEST: a planted divergent workflow file is reported" \
    "$META_DIVERGENT" "$META_DIFF"
assert_eq "installer-v3-upgrade 9b META-TEST: -> section 9's equality assertion FAILS on it" \
    "no" "$(yesno test "$META_DIFF" = "$EXPECTED_DIFF")"
cp "$F/$META_DIVERGENT" "$T/$META_DIVERGENT"
assert_eq "installer-v3-upgrade 9b META-TEST: and holds again once the divergence is undone" \
    "$EXPECTED_DIFF" "$(equivalence_diff "$SRC_MANIFEST" "$T" "$F" | tr '\n' ' ' | sed 's/ *$//')"

# ===========================================================================
# Section 10: the saved report is TRUTHFUL when a merge fails (R1-F2)
# ===========================================================================
# THE DEFECT, reproduced. Through v4.0 the report rendered one boolean per
# merged-class file: true -> "your pre-upgrade copy: <file>.bak", false ->
# "installed as shipped; nothing to merge". False is also what an ATTEMPTED AND
# FAILED merge leaves behind, so the saved report told an operator the shipped
# file had been installed when in fact:
#
#   settings.json  their own file was still on disk, unmerged (that arm is
#                  deliberately non-destructive — settings.json is
#                  operator-owned), so they were missing every v4 hook and had
#                  no line in the report pointing at it; and
#   .mcp.json      the SHIPPED config had replaced theirs wholesale, so their
#                  own servers were gone from the live file and only recoverable
#                  from .mcp.json.bak — which the report never mentioned.
#
# The terminal shows both failures in red as they happen. The report saved into
# the backup is what gets read days later, and it is the artifact this section
# holds to the truth.
#
# THE FIXTURE. A fresh genuine v3.5 install whose two merge inputs are made
# MULTI-DOCUMENT (two JSON objects concatenated) before the upgrade. That is a
# real shape — a bad hand-edit, a conflict marker resolution gone wrong, two
# tools appending to the same file — and it is the input the R1-F1 validity gate
# was added for, so it reaches both failure arms through the SAME door the
# shipped gate uses rather than through a mocked one.
T10="$WORK/target-merge-fail"
V35_RC_10=0
seed_v35_install "$T10" || V35_RC_10=$?
assert_eq "installer-v3-upgrade 10: the merge-failure fixture installs v3.5 cleanly" "0" "$V35_RC_10"

# Two documents in each file. `jq -s` slurps them into a 2-element array, so
# JSON_SINGLE_OBJECT_JQ's `length == 1` is false and both merges take their
# refusal arm.
printf '{"env":{"OPERATOR_KEY":"op-10"}}\n{"second":"document"}\n' > "$T10/.claude/settings.json"
printf '{"mcpServers":{"operator-only":{"type":"stdio","command":"node"}}}\n{"second":"document"}\n' \
    > "$T10/.mcp.json"
# Pre-conditions: both really are multi-document, or the section proves nothing.
assert_eq "installer-v3-upgrade 10: the seeded settings.json really is multi-document" \
    "no" "$(yesno jq -s -e 'length == 1 and (.[0] | type == "object")' "$T10/.claude/settings.json")"
assert_eq "installer-v3-upgrade 10: the seeded .mcp.json really is multi-document" \
    "no" "$(yesno jq -s -e 'length == 1 and (.[0] | type == "object")' "$T10/.mcp.json")"
SETTINGS_PRE_10="$WORK/settings-pre-10.json"
cp "$T10/.claude/settings.json" "$SETTINGS_PRE_10"

UPGRADE_RC_10=0
run_upgrade "$T10" "$WORK/upgrade10.log" || UPGRADE_RC_10=$?
UPGRADE_LOG_10=$(cat "$WORK/upgrade10.log" 2>/dev/null || echo "")
if [ "$UPGRADE_RC_10" -ne 0 ]; then
    printf '  diagnostic: merge-failure upgrade exited %s; tail of log:\n' "$UPGRADE_RC_10"
    tail -20 "$WORK/upgrade10.log" 2>/dev/null | sed 's/^/    /'
fi
# A bad merge input is an operator problem, not an installer crash: the run
# still completes so the rest of the upgrade lands.
assert_eq "installer-v3-upgrade 10: the upgrade still exits 0 with two unmergeable inputs" \
    "0" "$UPGRADE_RC_10"

BACKUP_DIR_10=$(backup_dir_of "$T10")
REPORT_10=$(cat "$BACKUP_DIR_10/upgrade-report.txt" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 10: a report was still saved into the backup" \
    "yes" "$(yesno test -f "$BACKUP_DIR_10/upgrade-report.txt")"

# --- 10a. the ON-DISK truth, established first ------------------------------
# The report's claims are only checkable against what actually happened, so the
# disk state is asserted before the wording.
assert_eq "installer-v3-upgrade 10a: settings.json was left EXACTLY as the operator had it" \
    "yes" "$(yesno cmp -s "$T10/.claude/settings.json" "$SETTINGS_PRE_10")"
assert_eq "installer-v3-upgrade 10a: ...with the pre-merge copy alongside as .bak" \
    "yes" "$(yesno test -f "$T10/.claude/settings.json.bak")"
assert_eq "installer-v3-upgrade 10a: .mcp.json WAS replaced by the shipped config (it must parse)" \
    "yes" "$(yesno cmp -s "$T10/.mcp.json" "$PLUGIN_ROOT/.mcp.json")"
assert_eq "installer-v3-upgrade 10a: ...and the operator's version is recoverable from .mcp.json.bak" \
    "yes" "$(yesno grep -qF 'operator-only' "$T10/.mcp.json.bak")"

# --- 10b. THE FIX: the report says which of those two things happened -------
assert_contains "installer-v3-upgrade 10b (R1-F2): the report says settings.json was left UNCHANGED by a failed merge" \
    ".claude/settings.json  (MERGE FAILED - your file was left UNCHANGED, not replaced; copy at .claude/settings.json.bak." \
    "$REPORT_10"
assert_contains "installer-v3-upgrade 10b (R1-F2): the report says the SHIPPED .mcp.json was installed over the operator's" \
    ".mcp.json              (MERGE REFUSED - yours was not a single JSON object, so the SHIPPED config was installed over it; yours is at .mcp.json.bak." \
    "$REPORT_10"
# THE REGRESSION WITNESS. This is the exact sentence v4.0 printed for both of
# them, and printing it here is the defect: it is the one string that must not
# appear in a report about two files the merge could not complete.
assert_not_contains "installer-v3-upgrade 10b (R1-F2): and NEITHER is described as 'installed as shipped; nothing to merge'" \
    "installed as shipped; nothing to merge" "$REPORT_10"
# The two failure sentences are DIFFERENT sentences, because the follow-up
# actions differ (merge the shipped keys in by hand vs re-add your servers from
# the .bak). A report that used one wording for both would satisfy the two
# assertions above only by accident of substring matching, so the .bak each one
# names is asserted distinctly.
assert_contains "installer-v3-upgrade 10b (R1-F2): the settings line tells the operator to merge the shipped keys in" \
    "Merge the shipped keys in by hand." "$REPORT_10"
assert_contains "installer-v3-upgrade 10b (R1-F2): the .mcp.json line tells them to re-add their servers from the .bak" \
    "Re-add your own servers from there." "$REPORT_10"
# And the terminal said so too, in red, as it happened — the report is the
# durable copy of a message the operator may have scrolled past, not a
# replacement for it.
assert_contains "installer-v3-upgrade 10b: the live readout also reported the settings merge failure" \
    "Could not merge settings.json" "$UPGRADE_LOG_10"
assert_contains "installer-v3-upgrade 10b: ...and the .mcp.json refusal" \
    ".mcp.json was not a single JSON object" "$UPGRADE_LOG_10"

# --- 10c. META-TEST: the wording check can actually fail --------------------
# The four-arm renderer is deleted from a COPY of install.sh, anchored on its own
# sentinels, and replaced by nothing — so the report loses both merged-class
# lines entirely. The 10b assertions must stop holding. Without this, a checker
# looking for a sentence that no longer exists anywhere would be indistinguishable
# from a passing suite, and the whole section would be pinning a string rather
# than a behaviour.
MUTANT_INSTALL_10="$WORK/install-no-merge-status.sh"
sed '/# MERGE-STATUS-LINES-START/,/# MERGE-STATUS-LINES-END/d' \
    "$PLUGIN_ROOT/install.sh" > "$MUTANT_INSTALL_10"
assert_eq "installer-v3-upgrade 10c META-TEST: the mutated copy really differs from install.sh" \
    "no" "$(yesno cmp -s "$MUTANT_INSTALL_10" "$PLUGIN_ROOT/install.sh")"
assert_eq "installer-v3-upgrade 10c META-TEST: the strip removed the block (fewer lines)" \
    "yes" "$(yesno test "$(grep -c . "$MUTANT_INSTALL_10" | tr -d ' \n')" -lt "$(grep -c . "$PLUGIN_ROOT/install.sh" | tr -d ' \n')")"
assert_eq "installer-v3-upgrade 10c META-TEST: the mutated copy is still valid bash" \
    "yes" "$(yesno bash -n "$MUTANT_INSTALL_10")"
# A second v3.5 fixture with the same two unmergeable inputs, run through the
# mutant. A separate tree because the mutant is expected to produce a DIFFERENT
# report and reusing T10 would make section 10b depend on run order.
T10M="$WORK/target-merge-fail-mutant"
V35_RC_10M=0
seed_v35_install "$T10M" || V35_RC_10M=$?
assert_eq "installer-v3-upgrade 10c META-TEST: the mutant fixture installs v3.5 cleanly" "0" "$V35_RC_10M"
printf '{"env":{"OPERATOR_KEY":"op-10m"}}\n{"second":"document"}\n' > "$T10M/.claude/settings.json"
printf '{"mcpServers":{"operator-only":{"type":"stdio","command":"node"}}}\n{"second":"document"}\n' \
    > "$T10M/.mcp.json"
# The mutant is invoked from the repo root as install.sh's own basename would
# be, but from a COPY — so it is pointed at the real plugin tree via the same
# mechanism the control uses: it is copied INTO the plugin root under a
# throwaway name, run, and removed. install.sh treats its own directory as the
# source when that directory looks like a checkout, and would otherwise clone
# from the network, which a component spec must never do.
MUTANT_IN_PLACE="$PLUGIN_ROOT/.install-mutant-u08.sh"
cp "$MUTANT_INSTALL_10" "$MUTANT_IN_PLACE"
UPGRADE_RC_10M=0
bash "$MUTANT_IN_PLACE" "$T10M" </dev/null >"$WORK/upgrade10m.log" 2>&1 || UPGRADE_RC_10M=$?
rm -f "$MUTANT_IN_PLACE"
assert_eq "installer-v3-upgrade 10c META-TEST: the mutant still runs to completion" \
    "0" "$UPGRADE_RC_10M"
BACKUP_DIR_10M=$(backup_dir_of "$T10M")
REPORT_10M=$(cat "$BACKUP_DIR_10M/upgrade-report.txt" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 10c META-TEST: the mutant still saved a report" \
    "yes" "$(yesno test -f "$BACKUP_DIR_10M/upgrade-report.txt")"
# THE FLIP: 10b's two assertions no longer hold against the mutant's report.
assert_not_contains "installer-v3-upgrade 10c META-TEST: -> the settings failure sentence is GONE" \
    "MERGE FAILED - your file was left UNCHANGED" "$REPORT_10M"
assert_not_contains "installer-v3-upgrade 10c META-TEST: -> and the .mcp.json refusal sentence is GONE" \
    "MERGE REFUSED - yours was not a single JSON object" "$REPORT_10M"
# Surgical: the rest of the report is intact, so the flip above is about the
# renderer and not about a mutant that failed to produce a report at all.
assert_contains "installer-v3-upgrade 10c META-TEST: the mutant's report still carries the upgrade line" \
    "Upgrade complete: v3.5.0 -> v$SOURCE_VERSION" "$REPORT_10M"
assert_contains "installer-v3-upgrade 10c META-TEST: ...and the ACTION REQUIRED block" \
    "ACTION REQUIRED" "$REPORT_10M"

# ===========================================================================
# Section 11: "yours is in the backup" must be TRUE for every replaced row
# ===========================================================================
# THE DEFECT THIS SECTION EXISTS FOR (QA cycle 1, HIGH, data loss). U0.8 added
# docs/CODEX_SETUP.md + docs/HOOKS.md to the copy surface and synced SIX places
# that name the subset — both manifest surfaces, both copy loops, both
# required-source lists — but NOT the backup legs, which enumerated root-level
# files from a hardcoded list written before docs/ was shipped. Result: an
# operator-edited docs/HOOKS.md classified replace-custom, was overwritten, and
# the readout AND the saved report both said "yours is in the backup" while the
# backup contained no such file. The bytes were gone from the entire tree.
#
# 1437 assertions passed over it, because every existing assertion checked the
# REPORT STRING or the absence of a .new sidecar. Nothing asserted that the
# backup CONTAINS the replaced bytes. So that is what this section asserts, in
# all three arms that can replace a file, and it asserts it on CONTENT rather
# than on any readout wording — a fix that only reworded the claim would leave
# these red.
#
# THE CONTRACT: if any install path overwrites a file the operator had, the
# operator's exact bytes are recoverable afterwards. Where they are recoverable
# FROM differs per arm (a timestamped backup directory when the path takes one,
# a .bak sidecar on the fresh path which takes none) — the contract is
# recoverability, not a location.
DOC_SENTINEL="OPERATOR-DOCS-SENTINEL-BACKUP-MUST-HOLD-THIS"

# CHECKER (shared with the 11d META): the operator's pre-upgrade bytes for
# <rel> exist SOMEWHERE recoverable under <target>, byte-identical to <expected>.
# Prints the path that matched, or nothing.
#
# Deliberately a CONTENT search rather than a path assertion: the point is that
# the bytes survive, and an implementation that put them somewhere sensible but
# unexpected should pass. The mirrored-path assertions below pin the layout
# separately, so a regression tells you WHICH property broke.
operator_bytes_recoverable() {
    local target="$1" expected="$2" f
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if cmp -s "$f" "$expected"; then
            printf '%s\n' "$f"
            return 0
        fi
    done < <(find "$target" -type f -name '*HOOKS.md*' 2>/dev/null)
    return 1
}

# --- 11a. the v3.5 -> v4 upgrade arm ---------------------------------------
# A dedicated fixture rather than reusing T: sections 6/8/9 pin T's state
# precisely (section 9 asserts the upgraded-vs-fresh diff is EXACTLY four
# paths), and seeding a fifth customization there would make a failure in this
# section read as a failure in those.
T11="$WORK/target-docs-backup"
V35_RC_11=0
seed_v35_install "$T11" || V35_RC_11=$?
assert_eq "installer-v3-upgrade 11a: the fixture installs v3.5 cleanly" "0" "$V35_RC_11"
# The v3.5 tag's own docs/HOOKS.md, then an operator edit on top. Using the tag's
# bytes as the base is what makes this replace-CUSTOM rather than copy-new: the
# file exists, and it matches neither the shipped v4 bytes nor the frozen v3.5
# hash.
mkdir -p "$T11/docs"
git -C "$PLUGIN_ROOT" show "$TAG:docs/HOOKS.md" > "$T11/docs/HOOKS.md" 2>/dev/null || true
printf '\n<!-- %s -->\n' "$DOC_SENTINEL" >> "$T11/docs/HOOKS.md"
DOC_PRE_11="$WORK/docs-hooks-pre-11.md"
cp "$T11/docs/HOOKS.md" "$DOC_PRE_11"
assert_contains "installer-v3-upgrade 11a: the fixture's docs/HOOKS.md carries the operator sentinel pre-upgrade" \
    "$DOC_SENTINEL" "$(cat "$T11/docs/HOOKS.md" 2>/dev/null || echo "")"
# Pre-condition: it must differ from the shipped copy, or the upgrade has
# nothing to replace and 11a would pass vacuously.
assert_eq "installer-v3-upgrade 11a: ...and really differs from the shipped doc" \
    "no" "$(yesno cmp -s "$T11/docs/HOOKS.md" "$PLUGIN_ROOT/docs/HOOKS.md")"

UPGRADE_RC_11=0
run_upgrade "$T11" "$WORK/upgrade11.log" || UPGRADE_RC_11=$?
UPGRADE_LOG_11=$(cat "$WORK/upgrade11.log" 2>/dev/null || echo "")
assert_eq "installer-v3-upgrade 11a: the upgrade exits 0" "0" "$UPGRADE_RC_11"
BACKUP_DIR_11=$(backup_dir_of "$T11")
assert_eq "installer-v3-upgrade 11a: a backup directory was created" \
    "yes" "$(yesno test -d "$BACKUP_DIR_11")"

# The verdict really was replace-custom (not copy-new, not skip-current), so the
# "replaced" claim below is the one under test.
assert_contains "installer-v3-upgrade 11a: the readout reports docs/HOOKS.md as replaced-and-customized" \
    "docs/HOOKS.md (replaced; yours is in the backup)" \
    "$(printf '%s' "$UPGRADE_LOG_11" | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g')"
# The live file is now the shipped doc — the plugin's product wins for a
# workflow-class row, which is correct and is NOT what was broken.
assert_eq "installer-v3-upgrade 11a: the live docs/HOOKS.md is now the shipped copy" \
    "yes" "$(yesno cmp -s "$T11/docs/HOOKS.md" "$PLUGIN_ROOT/docs/HOOKS.md")"

# THE ASSERTION THE DEFECT FAILED. The operator's bytes are still somewhere.
DOC_FOUND_11=$(operator_bytes_recoverable "$T11" "$DOC_PRE_11" || printf '')
if [ -z "$DOC_FOUND_11" ]; then
    printf '  diagnostic: the operator bytes are NOT recoverable anywhere under the target.\n'
    printf '  diagnostic: backup dir holds: %s\n' \
        "$(find "$BACKUP_DIR_11" -maxdepth 2 2>/dev/null | head -12 | tr '\n' ' ')"
fi
assert_eq "installer-v3-upgrade 11a: the operator's pre-upgrade docs/HOOKS.md bytes are RECOVERABLE" \
    "yes" "$([ -n "$DOC_FOUND_11" ] && echo yes || echo no)"
# And at the MIRRORED path inside the backup, which is the layout decision
# (documented in install.sh's backup leg): a root row keeps its relative path, so
# a flat row's path IS its basename and a nested one keeps its subdirectory.
# Flattening docs/HOOKS.md to HOOKS.md would be ambiguous against any
# root-level HOOKS.md and would make the report's `diff -r` advice wrong.
assert_eq "installer-v3-upgrade 11a: the backup holds it at the MIRRORED path docs/HOOKS.md" \
    "yes" "$(yesno cmp -s "$BACKUP_DIR_11/docs/HOOKS.md" "$DOC_PRE_11")"
assert_eq "installer-v3-upgrade 11a: ...and did NOT flatten it to the backup root" \
    "no" "$(yesno test -e "$BACKUP_DIR_11/HOOKS.md")"
# The pre-U0.8 flat entries keep their existing spelling — the layout change is
# additive, and 6f already depends on plugin.json being flat.
assert_eq "installer-v3-upgrade 11a: the four flat root files still land flat (back-compat)" \
    "yes" "$(yesno test -f "$BACKUP_DIR_11/LESSONS.md")"
assert_eq "installer-v3-upgrade 11a: ...and plugin.json keeps its flat basename" \
    "yes" "$(yesno test -f "$BACKUP_DIR_11/plugin.json")"

# --- 11b. the mode-2 Update arm -------------------------------------------
# The realistic v4.0 -> v4.1 population, and the arm QA called out as the one
# most operators will hit: classify hands replace-custom to ANY target file that
# differs from both the shipped bytes and the old table — including a path the
# old table never listed, which is exactly a v4.0 operator's own docs/HOOKS.md.
T11B="$WORK/target-docs-backup-mode2"
FRESH_RC_11B=0
seed_v4_install "$T11B" "$PLUGIN_ROOT/install.sh" || FRESH_RC_11B=$?
assert_eq "installer-v3-upgrade 11b: the fixture takes a fresh v4 install cleanly" "0" "$FRESH_RC_11B"
# The operator edits the installed doc AFTER the install — so the tree has a
# valid install-manifest and the edit is genuinely post-install.
printf '\n<!-- %s -->\n' "$DOC_SENTINEL" >> "$T11B/docs/HOOKS.md"
DOC_PRE_11B="$WORK/docs-hooks-pre-11b.md"
cp "$T11B/docs/HOOKS.md" "$DOC_PRE_11B"
assert_eq "installer-v3-upgrade 11b: the edited doc differs from the shipped copy" \
    "no" "$(yesno cmp -s "$T11B/docs/HOOKS.md" "$PLUGIN_ROOT/docs/HOOKS.md")"

MODE2_RC_11B=0
bash "$PLUGIN_ROOT/install.sh" --mode=2 "$T11B" </dev/null >"$WORK/mode2-11b.log" 2>&1 || MODE2_RC_11B=$?
assert_eq "installer-v3-upgrade 11b: the mode-2 Update exits 0" "0" "$MODE2_RC_11B"
MODE2_BACKUP_11B=$(find "$T11B" -maxdepth 1 -type d -name '.claude-backup-*' 2>/dev/null | LC_ALL=C sort | head -1)
assert_eq "installer-v3-upgrade 11b: the Update took a backup (a write verdict is present)" \
    "yes" "$(yesno test -d "$MODE2_BACKUP_11B")"
DOC_FOUND_11B=$(operator_bytes_recoverable "$T11B" "$DOC_PRE_11B" || printf '')
if [ -z "$DOC_FOUND_11B" ]; then
    printf '  diagnostic: mode-2 backup holds: %s\n' \
        "$(find "$MODE2_BACKUP_11B" -maxdepth 2 2>/dev/null | head -12 | tr '\n' ' ')"
fi
assert_eq "installer-v3-upgrade 11b: the operator's post-install docs edit is RECOVERABLE after the Update" \
    "yes" "$([ -n "$DOC_FOUND_11B" ] && echo yes || echo no)"
assert_eq "installer-v3-upgrade 11b: ...at the mirrored path inside the mode-2 backup" \
    "yes" "$(yesno cmp -s "$MODE2_BACKUP_11B/docs/HOOKS.md" "$DOC_PRE_11B")"

# --- 11c. the FRESH-install arm (no verdict walk, no backup directory) -----
# A never-installed project that happens to own a docs/HOOKS.md. There is no
# plan, no backup directory and no .new convention on this path, so the guard is
# a plain exists-and-differs check before the copy. docs/ is the ONLY shipped
# scope where this can happen: every other shipped path lives under .claude/ or
# is a plugin-specific root dotfile, so docs/ is the only place the plugin
# borrows a filename in a directory the operator owns.
T11C="$WORK/target-docs-fresh"
mkdir -p "$T11C/docs"
(
    cd "$T11C" || exit 1
    git init -q >/dev/null 2>&1 || true
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -q -m "fresh baseline" >/dev/null 2>&1 || true
)
printf '# my own hooks notes\n<!-- %s -->\n' "$DOC_SENTINEL" > "$T11C/docs/HOOKS.md"
DOC_PRE_11C="$WORK/docs-hooks-pre-11c.md"
cp "$T11C/docs/HOOKS.md" "$DOC_PRE_11C"
FRESH_RC_11C=0
bash "$PLUGIN_ROOT/install.sh" --mode=1 "$T11C" </dev/null >"$WORK/fresh-11c.log" 2>&1 || FRESH_RC_11C=$?
FRESH_LOG_11C=$(cat "$WORK/fresh-11c.log" 2>/dev/null | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g' || echo "")
assert_eq "installer-v3-upgrade 11c: the fresh install exits 0" "0" "$FRESH_RC_11C"
assert_eq "installer-v3-upgrade 11c: no backup directory exists on this path (nothing to snapshot)" \
    "0" "$(find "$T11C" -maxdepth 1 -type d -name '.claude*backup*' 2>/dev/null | grep -c . | tr -d ' \n')"
# The shipped doc wins the canonical path — the gate messages point operators at
# docs/HOOKS.md by name, so the plugin's copy has to be there.
assert_eq "installer-v3-upgrade 11c: the live docs/HOOKS.md is the shipped copy" \
    "yes" "$(yesno cmp -s "$T11C/docs/HOOKS.md" "$PLUGIN_ROOT/docs/HOOKS.md")"
# ...and the operator's bytes are alongside as .bak, the suffix the installer
# already uses for the pre-merge copies of settings.json / .mcp.json.
DOC_FOUND_11C=$(operator_bytes_recoverable "$T11C" "$DOC_PRE_11C" || printf '')
assert_eq "installer-v3-upgrade 11c: the operator's pre-existing doc is RECOVERABLE" \
    "yes" "$([ -n "$DOC_FOUND_11C" ] && echo yes || echo no)"
assert_eq "installer-v3-upgrade 11c: ...specifically at docs/HOOKS.md.bak" \
    "yes" "$(yesno cmp -s "$T11C/docs/HOOKS.md.bak" "$DOC_PRE_11C")"
# It is REPORTED, not silent: a generic "OK   HOOKS.md" line was the whole
# problem on this arm — the operator had no way to know a file of theirs had
# just been replaced.
assert_contains "installer-v3-upgrade 11c: the readout names the file it preserved" \
    "docs/HOOKS.md" "$FRESH_LOG_11C"
assert_contains "installer-v3-upgrade 11c: ...and says where the old bytes went" \
    "docs/HOOKS.md.bak" "$FRESH_LOG_11C"
# A pre-existing doc that is ALREADY the shipped bytes must not collect a
# pointless .bak — the guard is exists-AND-DIFFERS, not exists.
T11D="$WORK/target-docs-fresh-identical"
mkdir -p "$T11D/docs"
(
    cd "$T11D" || exit 1
    git init -q >/dev/null 2>&1 || true
    git -c user.email=test@example.com -c user.name=test \
        commit --allow-empty -q -m "fresh baseline" >/dev/null 2>&1 || true
)
cp "$PLUGIN_ROOT/docs/HOOKS.md" "$T11D/docs/HOOKS.md"
bash "$PLUGIN_ROOT/install.sh" --mode=1 "$T11D" </dev/null >"$WORK/fresh-11d.log" 2>&1 || true
assert_eq "installer-v3-upgrade 11c: an identical pre-existing doc collects NO .bak" \
    "no" "$(yesno test -e "$T11D/docs/HOOKS.md.bak")"

# --- 11d META-TEST: the backup leg is load-bearing -------------------------
# The root-file backup helper is deleted from a COPY of install.sh, anchored on
# its own sentinels, and 11a is re-run against the mutant. The operator bytes
# must become unrecoverable — which is the defect, mechanically reproduced. A
# checker that could not see this would be exactly as blind as the 1437
# assertions that passed over the original bug.
MUTANT_BACKUP="$WORK/install-no-root-backup.sh"
sed '/# ROOT-BACKUP-START/,/# ROOT-BACKUP-END/d' "$PLUGIN_ROOT/install.sh" > "$MUTANT_BACKUP"
assert_eq "installer-v3-upgrade 11d META-TEST: the mutated copy really differs from install.sh" \
    "no" "$(yesno cmp -s "$MUTANT_BACKUP" "$PLUGIN_ROOT/install.sh")"
assert_eq "installer-v3-upgrade 11d META-TEST: the strip removed the block (fewer lines)" \
    "yes" "$(yesno test "$(grep -c . "$MUTANT_BACKUP" | tr -d ' \n')" -lt "$(grep -c . "$PLUGIN_ROOT/install.sh" | tr -d ' \n')")"
assert_eq "installer-v3-upgrade 11d META-TEST: the mutated copy is still valid bash" \
    "yes" "$(yesno bash -n "$MUTANT_BACKUP")"
T11M="$WORK/target-docs-backup-mutant"
V35_RC_11M=0
seed_v35_install "$T11M" || V35_RC_11M=$?
assert_eq "installer-v3-upgrade 11d META-TEST: the mutant fixture installs v3.5 cleanly" "0" "$V35_RC_11M"
mkdir -p "$T11M/docs"
git -C "$PLUGIN_ROOT" show "$TAG:docs/HOOKS.md" > "$T11M/docs/HOOKS.md" 2>/dev/null || true
printf '\n<!-- %s -->\n' "$DOC_SENTINEL" >> "$T11M/docs/HOOKS.md"
DOC_PRE_11M="$WORK/docs-hooks-pre-11m.md"
cp "$T11M/docs/HOOKS.md" "$DOC_PRE_11M"
# Run from inside the plugin root under a throwaway name so the mutant resolves
# the real tree as its source instead of cloning from the network.
MUTANT_IN_PLACE_11="$PLUGIN_ROOT/.install-mutant-u08-backup.sh"
cp "$MUTANT_BACKUP" "$MUTANT_IN_PLACE_11"
MUTANT_RC_11=0
bash "$MUTANT_IN_PLACE_11" "$T11M" </dev/null >"$WORK/upgrade11m.log" 2>&1 || MUTANT_RC_11=$?
rm -f "$MUTANT_IN_PLACE_11"
assert_eq "installer-v3-upgrade 11d META-TEST: the mutant still runs to completion" "0" "$MUTANT_RC_11"
# THE FLIP.
assert_eq "installer-v3-upgrade 11d META-TEST: -> without the block the operator bytes are UNRECOVERABLE" \
    "no" "$([ -n "$(operator_bytes_recoverable "$T11M" "$DOC_PRE_11M" || printf '')" ] && echo yes || echo no)"
# ...while the mutant STILL prints the false claim, which is precisely why the
# report string was never a usable oracle for this contract.
assert_contains "installer-v3-upgrade 11d META-TEST: ...and it still claims 'yours is in the backup'" \
    "docs/HOOKS.md (replaced; yours is in the backup)" \
    "$(cat "$WORK/upgrade11m.log" 2>/dev/null | sed 's/'"$(printf '\033')"'\[[0-9;]*m//g' || echo "")"
# Surgical: the mutant still backs up the .claude/ tree, so the flip above is
# about the ROOT-scope leg and not about a backup that failed wholesale.
BACKUP_DIR_11M=$(backup_dir_of "$T11M")
assert_eq "installer-v3-upgrade 11d META-TEST: the mutation is surgical — .claude/ still reached the backup" \
    "yes" "$(yesno test -f "$BACKUP_DIR_11M/scripts/qa-gate.sh")"
