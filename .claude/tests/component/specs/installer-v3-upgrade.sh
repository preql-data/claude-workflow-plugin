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
#
# Runtime is dominated by three v3.5 installs plus three upgrades; each is well
# under two seconds because the installer copies a ~10 MB tree and hashes ~250
# files, with no network and no LLM calls.

set -u

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
