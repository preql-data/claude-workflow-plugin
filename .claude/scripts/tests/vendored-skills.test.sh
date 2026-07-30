#!/bin/bash
# vendored-skills.test.sh — the L1 consistency assertion for vendored
# third-party instruction material (claude-workflow-plugin-kfe, v4.1 / U4).
#
# WHAT IS VENDORED. Exactly one upstream skill: `brainstorming` from
# obra/superpowers at a 40-hex pin, MIT, landing at
# .claude/vendor/superpowers/brainstorming/SKILL.md with a sibling MANIFEST.md
# and a verbatim LICENSE.upstream. Four further upstream skills were read at the
# same pin and HARVESTED as practices into agent prompts that already existed;
# no text from them is committed.
#
# WHAT THIS TEST DEFENDS. A vendored instruction file is a second voice inside
# the agent's context window. The danger is not that it is wrong — it is that it
# is plausible, and that it quietly establishes a SECOND release authority, a
# SECOND debugging protocol, or a SECOND place the spec lives. Ten surgical
# modifications removed those from the vendored file; this test is what keeps
# them removed, and what stops the same material re-entering through the
# harvest.
#
# ---------------------------------------------------------------------------
# SCOPE, AND WHY IT IS SPLIT THREE WAYS
#
# RUNTIME_SCOPE — files an agent reads AS INSTRUCTIONS during real work: the
#   vendored SKILL.md plus the five agent prompts the harvest touched. The
#   alternate-authority and second-debug-protocol scans run over all of these,
#   because "a competing instruction sneaks in via the harvest" is the likeliest
#   regression, not "someone re-edits the vendored file".
#
# VENDORED_SKILL only — the 16 banned phrases and the two line-level
#   invariants. Those needles were MEASURED in the upstream file at the pin, so
#   they only carry meaning against its descendant. The `approv` invariant in
#   particular CANNOT be widened: orchestrator.md legitimately carries 19 lines
#   containing `approv` (measured 2026-07-30), 17 of them without the literal
#   `qa-approved` — `qa-gate.sh approve`, `approve --no-review`, the
#   `approval-cites-independent-review` invariant. Applying the rule there would
#   fail on correct text, and a rule that fails on correct text gets deleted.
#
# EXEMPT, BY NAME — MANIFEST.md, LICENSE.upstream, THIRD_PARTY.md, LICENSE.
#   These are provenance records, never read as instructions. MANIFEST.md must
#   QUOTE the banned needles: that is its job. The exemption is asserted by
#   exact name, not by glob, so a future file dropped into the vendor tree does
#   not silently inherit it — and the bidirectional check below turns the
#   MANIFEST exemption into a POSITIVE requirement: every needle banned from the
#   skill must be documented in the manifest.
#
# ---------------------------------------------------------------------------
# NON-VACUITY
#
# Every ban records its MEASURED upstream occurrence count beside it (the
# `count|phrase` entries in BANNED_PHRASES, measured with `grep -cF` against the
# upstream file at the pin on 2026-07-30). A ban whose needle never existed
# proves nothing. Bans alone also cannot prove a REPLACEMENT landed rather than
# a section being silently deleted, so the positive sentinels — the fast-path
# carve-out literal `single-line typo fix`, and the four wiring sentinels in
# orchestrator.md — are asserted too.
#
# Exit codes:
#   0  every assertion passed and the assertion count is complete
#   1  an assertion failed, or the count moved

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"
VENDOR_DIR="$PROJECT_DIR/.claude/vendor/superpowers"
VENDORED_SKILL="$VENDOR_DIR/brainstorming/SKILL.md"
VENDOR_MANIFEST="$VENDOR_DIR/MANIFEST.md"
VENDOR_LICENSE="$VENDOR_DIR/LICENSE.upstream"
PLUGIN_JSON="$PROJECT_DIR/.claude-plugin/plugin.json"

EXPECTED_PIN="3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9"

# Files an agent reads as instructions. The vendored doc plus every file the
# harvest touched.
RUNTIME_SCOPE=(
    "$VENDORED_SKILL"
    "$AGENTS_DIR/orchestrator.md"
    "$AGENTS_DIR/qa.md"
    "$AGENTS_DIR/backend.md"
    "$AGENTS_DIR/frontend.md"
    "$AGENTS_DIR/devops.md"
)

# "<measured upstream line count>|<phrase>". The count is what makes each ban
# provably non-vacuous: the needle existed, this many times, in the upstream
# file at EXPECTED_PIN.
#
# RE-VERIFY THE COUNTS (network; not run in CI, which is offline). This
# one-liner regenerates the whole column, so the claim is checkable rather than
# merely asserted:
#
#   PIN=3dcbd5c4b48e02263fbf4a3c01e3fe4f81d584d9
#   curl -sfL -o /tmp/up.md \
#     "https://raw.githubusercontent.com/obra/superpowers/$PIN/skills/brainstorming/SKILL.md"
#   awk '/^BANNED_PHRASES=\(/{f=1;next} f&&/^\)/{exit} f' \
#     .claude/scripts/tests/vendored-skills.test.sh \
#     | sed 's/^ *"//; s/"$//' \
#     | while IFS= read -r e; do [ -n "$e" ] || continue; \
#         printf '%s declared=%s upstream=%s\n' "${e#*|}" "${e%%|*}" \
#           "$(grep -cF -- "${e#*|}" /tmp/up.md | tr -d ' \n')"; done
#
# Counts are per grep -cF, i.e. MATCHING LINES, not occurrences. `<HARD-GATE>`
# is 1 and not 2 for exactly that reason: the closing tag on upstream line 14 is
# `</HARD-GATE>`, which does not contain the needle. (Caught by running the
# recipe above during verification, after the column was first written from a
# looser `HARD-GATE` probe that answered 2.)
BANNED_PHRASES=(
    "1|<HARD-GATE>"
    "1|the user has approved it"
    "1|regardless of perceived simplicity"
    "1|get user approval after each section"
    "4|User approves design?"
    "2|docs/superpowers/specs"
    "1|Commit the design document to git"
    "6|writing-plans"
    "1|frontend-design"
    "1|mcp-builder"
    "1|You MUST create a task for each of these items"
    "2|Wait for the user"
    "1|elements-of-style"
    "2|Visual Companion"
    "1|visual-companion.md"
    "1|Every project goes through this process"
)

# Phrasings that would establish a release authority other than the
# change-set-hash-bound qa-approved record. All measured at 0 across
# RUNTIME_SCOPE on 2026-07-30 — this is a "keep it at zero" scan, and the
# vendored file is the reason it is not vacuous: eleven of its upstream lines
# carried this vocabulary.
ALT_AUTHORITY=(
    "the user has approved it"
    "get user approval"
    "user approval after"
    "until the user approves"
    "Only proceed once the user approves"
    "requires user approval"
    "wait for user approval"
    "the user approves"
    "the user must approve"
    "await user approval"
)

# Markers of a SECOND debugging protocol. The upstream systematic-debugging
# skill was MERGED into the evidence-before-fix protocol (the EBF-CORE region,
# guarded byte-for-byte by evidence-before-fix.test.sh), not vendored beside it.
# Each of these is a load-bearing string from that upstream text; any of them
# appearing in RUNTIME_SCOPE means a competing protocol came back.
SECOND_PROTOCOL=(
    "Iron Law"
    "NO FIXES WITHOUT ROOT CAUSE"
    "3+ fixes"
    "superpowers:"
    "root-cause-tracing.md"
    "your human partner"
)

# Positive wiring sentinels. Bans prove a sentence is gone; only these prove the
# wire-in landed. Fixed strings, anchored on text and never on line numbers.
WIRING_SENTINELS=(
    ".claude/vendor/superpowers/brainstorming/SKILL.md"
    "Three clauses override that file wherever it disagrees"
    "the delimited EBF-CORE region in"
    "skip the brainstorming read for genuinely trivial work (single-line typo fix, README touch-up)"
)

assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    expected: %s\n    actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

# ---------------------------------------------------------------------------
# CHECKERS. Every one takes its target as an argument so the METAs can point
# the SAME code at a planted fixture. A checker only its real caller can reach
# is a checker nothing has ever proved sensitive.

# banned_hits <file> — one line per banned phrase present. Empty == clean.
banned_hits() {
    local f="$1" entry phrase n
    [ -f "$f" ] || { printf 'NO_FILE\n'; return 0; }
    for entry in "${BANNED_PHRASES[@]}"; do
        phrase="${entry#*|}"
        n=$(grep -cF -- "$phrase" "$f" 2>/dev/null | tr -d ' \n')
        [ "${n:-0}" = "0" ] || printf '%s (x%s)\n' "$phrase" "$n"
    done
}

# approv_violations <file> — every line containing `approv` that does NOT also
# contain the literal `qa-approved`. Empty == clean.
approv_violations() {
    local f="$1"
    [ -f "$f" ] || { printf 'NO_FILE\n'; return 0; }
    grep -nF -- "approv" "$f" 2>/dev/null | grep -vF -- "qa-approved" || true
}

# commit_violations <file> — every line matching `commit` CASE-INSENSITIVELY
# that does not also contain `recent commits`. Case-insensitive because the
# upstream instruction that mattered most was capitalised ("Commit the design
# document to git") and a case-sensitive rule would have walked straight past
# it. Empty == clean.
commit_violations() {
    local f="$1"
    [ -f "$f" ] || { printf 'NO_FILE\n'; return 0; }
    grep -niE -- "commit" "$f" 2>/dev/null | grep -vF -- "recent commits" || true
}

# phrase_hits_in_files <phrase> <file...> — "<file>:<count>" per file that
# contains the phrase. Empty == the phrase appears nowhere in the set.
phrase_hits_in_files() {
    local phrase="$1" f n
    shift
    for f in "$@"; do
        [ -f "$f" ] || continue
        n=$(grep -cF -- "$phrase" "$f" 2>/dev/null | tr -d ' \n')
        [ "${n:-0}" = "0" ] || printf '%s:%s\n' "$(basename "$f")" "$n"
    done
}

# shipped_skill_files <root> — every SKILL.md the SHIPPED tree carries, one per
# line, relative to <root>.
#
# `.claude/tests` is pruned deliberately, and this is not a convenience: the
# live repo answers 14 to a bare `find .claude -name SKILL.md`, because the e2e
# fixtures each carry a rendered copy of the plugin and node_modules ships two
# unrelated vendor skills of its own. Counting those would make the
# registration assertion meaningless in both directions.
shipped_skill_files() {
    local root="$1"
    [ -d "$root/.claude" ] || return 0
    (cd "$root" && find .claude -name tests -prune -o -name 'SKILL.md' -print 2>/dev/null | LC_ALL=C sort)
}

# count_matching <pattern> — count lines on stdin containing <pattern>.
count_matching() {
    grep -cF -- "$1" 2>/dev/null | tr -d ' \n' || printf '0'
}

# manifest_pins <manifest> — every DISTINCT 40-hex string in the file. More than
# one means a stale pin is lurking beside the live one; zero means the manifest
# names no version at all.
manifest_pins() {
    local f="$1"
    [ -f "$f" ] || return 0
    grep -oE '\b[0-9a-f]{40}\b' "$f" 2>/dev/null | LC_ALL=C sort -u
}

# wiring_missing <file> — one line per wiring sentinel absent from <file>.
wiring_missing() {
    local f="$1" s
    [ -f "$f" ] || { printf 'NO_FILE\n'; return 0; }
    for s in "${WIRING_SENTINELS[@]}"; do
        grep -qF -- "$s" "$f" || printf '%s\n' "$s"
    done
}

# provenance_forward <manifest> <vendor-root> — one line per file in the vendor
# tree that the manifest does not name.
provenance_forward() {
    local mf="$1" root="$2" rel
    [ -f "$mf" ] || { printf 'NO_MANIFEST\n'; return 0; }
    [ -d "$root" ] || { printf 'NO_ROOT\n'; return 0; }
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        # MANIFEST.md naming itself as "this file" in the size column is the one
        # row with no literal path; accept its basename.
        grep -qF -- "$rel" "$mf" || printf '%s\n' "$rel"
    done < <(cd "$root" && find . -type f 2>/dev/null | sed 's|^\./||' | LC_ALL=C sort)
}

# provenance_reverse <manifest> <vendor-root> — one line per path the manifest's
# provenance table names that does not exist on disk. Reads the backticked
# leading cell of the pipe-table rows, which is where the file paths live.
provenance_reverse() {
    local mf="$1" root="$2" rel
    [ -f "$mf" ] || { printf 'NO_MANIFEST\n'; return 0; }
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        [ -e "$root/$rel" ] || printf '%s\n' "$rel"
    done < <(awk -F'|' '
        /^\| `[A-Za-z]/ {
            cell = $2
            gsub(/^[ \t]*`/, "", cell)
            gsub(/`[ \t]*$/, "", cell)
            if (cell != "") print cell
        }
    ' "$mf" | LC_ALL=C sort -u)
}

printf '\n=== Section 1: the vendored tree is present and shaped as declared ===\n'

if [ -d "$VENDOR_DIR" ]; then hit=yes; else hit=no; fi
assert_eq "1.1 the vendor tree exists at .claude/vendor/superpowers" "yes" "$hit"

if [ -f "$VENDOR_MANIFEST" ]; then hit=yes; else hit=no; fi
assert_eq "1.2 MANIFEST.md is present" "yes" "$hit"

if [ -f "$VENDOR_LICENSE" ]; then hit=yes; else hit=no; fi
assert_eq "1.3 LICENSE.upstream is present" "yes" "$hit"

if [ -f "$VENDORED_SKILL" ]; then hit=yes; else hit=no; fi
assert_eq "1.4 brainstorming/SKILL.md is present" "yes" "$hit"

VENDOR_FILE_COUNT=$(find "$VENDOR_DIR" -type f 2>/dev/null | grep -c . | tr -d ' \n')
assert_eq "1.5 the vendor tree holds exactly 3 files (manifest, licence, skill)" \
    "3" "$VENDOR_FILE_COUNT"

if grep -qF -- "Copyright (c) 2025 Jesse Vincent" "$VENDOR_LICENSE" 2>/dev/null \
    && grep -qF -- "MIT License" "$VENDOR_LICENSE" 2>/dev/null; then hit=yes; else hit=no; fi
assert_eq "1.6 LICENSE.upstream carries the upstream MIT grant and its holder" "yes" "$hit"

# The two-key frontmatter is kept VERBATIM so re-vendoring stays a one-line
# curl|diff. Count the keys in the first frontmatter block: exactly 2.
FM_KEYS=$(awk 'NR==1 && $0=="---" {inside=1; next} inside && $0=="---" {exit} inside && /^[a-zA-Z_-]+:/ {n++} END {printf "%d", n+0}' "$VENDORED_SKILL" 2>/dev/null)
assert_eq "1.7 the vendored skill keeps upstream's 2-key frontmatter verbatim" "2" "$FM_KEYS"

printf '\n=== Section 2: single-pin format ===\n'

PIN_LIST=$(manifest_pins "$VENDOR_MANIFEST")
PIN_COUNT=$(printf '%s\n' "$PIN_LIST" | grep -c . | tr -d ' \n')
assert_eq "2.1 MANIFEST names exactly ONE distinct 40-hex pin (no stale second pin)" \
    "1" "$PIN_COUNT"
assert_eq "2.2 that pin is the expected upstream commit" "$EXPECTED_PIN" "$(printf '%s' "$PIN_LIST" | head -1)"

if grep -qF -- "$EXPECTED_PIN" "$PROJECT_DIR/THIRD_PARTY.md" 2>/dev/null; then hit=yes; else hit=no; fi
assert_eq "2.3 THIRD_PARTY.md cites the SAME pin (one version, two documents)" "yes" "$hit"

printf '\n=== Section 3: bidirectional provenance parity ===\n'

assert_eq "3.1 forward: every file in the vendor tree is named in MANIFEST.md" \
    "" "$(provenance_forward "$VENDOR_MANIFEST" "$VENDOR_DIR")"
assert_eq "3.2 reverse: every path in MANIFEST's provenance table exists on disk" \
    "" "$(provenance_reverse "$VENDOR_MANIFEST" "$VENDOR_DIR")"

# Vacuity guard for 3.2: a table the awk never parsed also reports no misses,
# so the row count is asserted rather than inferred from a clean result. Three
# rows: LICENSE.upstream, brainstorming/SKILL.md, and MANIFEST.md's own row.
# shellcheck disable=SC2016  # literal backtick in the awk pattern; no expansion wanted.
PROV_ROWS=$(awk -F'|' '/^\| `[A-Za-z]/ { n++ } END { printf "%d", n+0 }' "$VENDOR_MANIFEST" 2>/dev/null)
assert_eq "3.3 the provenance table actually parsed (3 file rows, not 0)" "3" "$PROV_ROWS"

printf '\n=== Section 4: reference doc, NOT a registered skill ===\n'

SKILL_FILES=$(shipped_skill_files "$PROJECT_DIR")
SKILL_TOTAL=$(printf '%s\n' "$SKILL_FILES" | grep -c . | tr -d ' \n')
assert_eq "4.1 the shipped tree carries exactly 2 SKILL.md files" "2" "$SKILL_TOTAL"

SKILLS_DIR_COUNT=$(printf '%s\n' "$SKILL_FILES" | count_matching ".claude/skills/")
assert_eq "4.2 exactly 1 of them is under .claude/skills/ (the registered one)" "1" "$SKILLS_DIR_COUNT"

VENDOR_SKILL_COUNT=$(printf '%s\n' "$SKILL_FILES" | count_matching ".claude/vendor/")
assert_eq "4.3 exactly 1 of them is under .claude/vendor/ (the reference one)" "1" "$VENDOR_SKILL_COUNT"

SKILLS_ARRAY_LEN=$(jq -r '.skills | length' "$PLUGIN_JSON" 2>/dev/null)
assert_eq "4.4 plugin.json skills[] stays length 1" "1" "$SKILLS_ARRAY_LEN"

VENDOR_IN_MANIFEST=$(jq -r '[.skills[] | select(test("vendor"))] | length' "$PLUGIN_JSON" 2>/dev/null)
assert_eq "4.5 plugin.json skills[] does NOT register the vendor tree" "0" "$VENDOR_IN_MANIFEST"

printf '\n=== Section 5: the 16 banned phrases (each with its measured upstream count) ===\n'

for entry in "${BANNED_PHRASES[@]}"; do
    count="${entry%%|*}"
    phrase="${entry#*|}"
    n=$(grep -cF -- "$phrase" "$VENDORED_SKILL" 2>/dev/null | tr -d ' \n')
    assert_eq "5.x banned in the vendored skill (upstream had $count line(s)): $phrase" "0" "${n:-0}"
done

# Bidirectional: the exemption that lets MANIFEST.md quote these needles is only
# defensible if it USES it. Every ban must be documented where a reader can find
# what was removed and why.
UNDOCUMENTED=""
for entry in "${BANNED_PHRASES[@]}"; do
    phrase="${entry#*|}"
    grep -qF -- "$phrase" "$VENDOR_MANIFEST" || UNDOCUMENTED="$UNDOCUMENTED $phrase"
done
assert_eq "5.17 every banned phrase is DOCUMENTED in MANIFEST.md (the exemption earns itself)" \
    "" "${UNDOCUMENTED# }"

printf '\n=== Section 6: the two line-level invariants (vendored skill only) ===\n'

assert_eq "6.1 every line containing 'approv' also contains 'qa-approved'" \
    "" "$(approv_violations "$VENDORED_SKILL")"
assert_eq "6.2 every line matching /commit/i also contains 'recent commits'" \
    "" "$(commit_violations "$VENDORED_SKILL")"

# Non-vacuity: an invariant over zero lines is satisfied by an empty file.
APPROV_LINES=$(grep -cF -- "approv" "$VENDORED_SKILL" 2>/dev/null | tr -d ' \n')
if [ "${APPROV_LINES:-0}" -gt 0 ]; then hit=yes; else hit=no; fi
assert_eq "6.3 the approv invariant is non-vacuous (the file HAS approv lines)" "yes" "$hit"

COMMIT_LINES=$(grep -ciE -- "commit" "$VENDORED_SKILL" 2>/dev/null | tr -d ' \n')
if [ "${COMMIT_LINES:-0}" -gt 0 ]; then hit=yes; else hit=no; fi
assert_eq "6.4 the commit invariant is non-vacuous (the file HAS commit lines)" "yes" "$hit"

printf '\n=== Section 7: no alternate release authority, across the whole runtime scope ===\n'

assert_eq "7.1 the runtime scope is the 6 files the vendoring + harvest touched" \
    "6" "${#RUNTIME_SCOPE[@]}"

SCOPE_PRESENT=0
for f in "${RUNTIME_SCOPE[@]}"; do
    [ -f "$f" ] && SCOPE_PRESENT=$((SCOPE_PRESENT + 1))
done
assert_eq "7.2 every scope file exists (a missing file scans clean for free)" \
    "6" "$SCOPE_PRESENT"

ALT_HITS=""
for phrase in "${ALT_AUTHORITY[@]}"; do
    found=$(phrase_hits_in_files "$phrase" "${RUNTIME_SCOPE[@]}")
    [ -z "$found" ] || ALT_HITS="$ALT_HITS $phrase=>[$(printf '%s' "$found" | tr '\n' ',')]"
done
assert_eq "7.3 no alternate-approval phrasing anywhere in the runtime scope" "" "${ALT_HITS# }"

printf '\n=== Section 8: no SECOND debugging protocol, across the whole runtime scope ===\n'

for phrase in "${SECOND_PROTOCOL[@]}"; do
    assert_eq "8.x absent from the runtime scope: $phrase" \
        "" "$(phrase_hits_in_files "$phrase" "${RUNTIME_SCOPE[@]}")"
done

printf '\n=== Section 9: positive wiring sentinels (orchestrator.md section 1) ===\n'

ORCH="$AGENTS_DIR/orchestrator.md"
for s in "${WIRING_SENTINELS[@]}"; do
    if grep -qF -- "$s" "$ORCH"; then hit=present; else hit=ABSENT; fi
    assert_eq "9.x wiring sentinel present: $s" "present" "$hit"
done

printf '\n=== Section 10: attribution ===\n'

ROOT_LICENSE="$PROJECT_DIR/LICENSE"
if [ -f "$ROOT_LICENSE" ] && grep -qF -- "MIT License" "$ROOT_LICENSE"; then hit=yes; else hit=no; fi
assert_eq "10.1 root LICENSE exists and is the MIT text" "yes" "$hit"

if grep -qF -- "preql-data" "$ROOT_LICENSE" 2>/dev/null; then hit=yes; else hit=no; fi
assert_eq "10.2 root LICENSE names the holder plugin.json declares" "yes" "$hit"

assert_eq "10.3 plugin.json still declares MIT (now with a backing file)" \
    "MIT" "$(jq -r '.license' "$PLUGIN_JSON" 2>/dev/null)"

TP="$PROJECT_DIR/THIRD_PARTY.md"
if grep -qF -- "grammars/MANIFEST.md" "$TP" 2>/dev/null; then hit=yes; else hit=no; fi
assert_eq "10.4 THIRD_PARTY.md points at the tree-sitter grammars manifest" "yes" "$hit"

if grep -qF -- "vendor/superpowers/MANIFEST.md" "$TP" 2>/dev/null \
    && grep -qF -- "vendor/superpowers/LICENSE.upstream" "$TP" 2>/dev/null; then hit=yes; else hit=no; fi
assert_eq "10.5 THIRD_PARTY.md points at the vendored manifest AND its licence" "yes" "$hit"

printf '\n=== Section 11: registration sites (a new tree is invisible unless registered) ===\n'

INSTALL_SH="$PROJECT_DIR/install.sh"
INSTALL_PS1="$PROJECT_DIR/install.ps1"
WM="$PROJECT_DIR/.claude/scripts/workflow-manifest.sh"
PARITY="$PROJECT_DIR/.claude/tests/component/specs/installer-manifest-parity.sh"

MISSING_SH=""
for p in ".claude/vendor/superpowers/MANIFEST.md" ".claude/vendor/superpowers/LICENSE.upstream" ".claude/vendor/superpowers/brainstorming/SKILL.md"; do
    grep -qF -- "\"$p\"" "$INSTALL_SH" || MISSING_SH="$MISSING_SH $p"
done
assert_eq "11.1 install.sh's required-source list names all 3 vendor files" "" "${MISSING_SH# }"

MISSING_PS=""
for p in ".claude/vendor/superpowers/MANIFEST.md" ".claude/vendor/superpowers/LICENSE.upstream" ".claude/vendor/superpowers/brainstorming/SKILL.md"; do
    grep -qF -- "\"$p\"" "$INSTALL_PS1" || MISSING_PS="$MISSING_PS $p"
done
assert_eq "11.2 install.ps1's \$Required names all 3 vendor files" "" "${MISSING_PS# }"

# shellcheck disable=SC2016  # matching the LITERAL text `$SOURCE_DIR` in install.sh, not expanding it.
assert_eq "11.3 install.sh walks BOTH trees through copy_file (skills + vendor)" \
    "2" "$(grep -cE '^copy_shipped_tree "\$SOURCE_DIR/\.claude/(skills|vendor)"' "$INSTALL_SH" | tr -d ' \n')"

assert_eq "11.4 install.ps1 walks BOTH trees through Copy-WorkflowFile" \
    "2" "$(grep -cE '^ *Copy-ShippedTree -SrcRoot' "$INSTALL_PS1" | tr -d ' \n')"

# The retired name-by-name copy. Its absence is what the tree-walk change
# bought; a reintroduced hardcoded path would drop a second skill file from
# every install without failing anything else.
# shellcheck disable=SC2016  # matching the LITERAL text `$SOURCE_DIR` in install.sh, not expanding it.
assert_eq "11.5 install.sh no longer copies the skill by its literal filename" \
    "0" "$(grep -cF -- 'copy_file "$SOURCE_DIR/.claude/skills/workflow-engine/SKILL.md"' "$INSTALL_SH" | tr -d ' \n')"

if grep -qF -- 'scan_tree workflow ".claude/skills"' "$WM" \
    && grep -qF -- 'scan_tree workflow ".claude/vendor"' "$WM"; then hit=yes; else hit=no; fi
assert_eq "11.6 workflow-manifest.sh scans BOTH trees" "yes" "$hit"

# shellcheck disable=SC2016  # matching the LITERAL PowerShell text `$Root`, not expanding it.
if grep -qF -- 'Get-SurfaceTreeRows -Root $Root -Class "workflow" -Dir ".claude/skills"' "$INSTALL_PS1" \
    && grep -qF -- 'Get-SurfaceTreeRows -Root $Root -Class "workflow" -Dir ".claude/vendor"' "$INSTALL_PS1"; then hit=yes; else hit=no; fi
assert_eq "11.7 install.ps1's surface generator scans BOTH trees" "yes" "$hit"

# ONE scope array, not two hand-copied ones: changing the checker's list and not
# the vacuity guard's silently WEAKENS the guard rather than failing it.
assert_eq "11.8 installer-manifest-parity.sh declares its scope list exactly once" \
    "1" "$(grep -cE '^PARITY_SCOPES=\(' "$PARITY" | tr -d ' \n')"
# shellcheck disable=SC2016  # matching the LITERAL array expansion text in the spec, not expanding it.
assert_eq "11.9 both parity consumers read that one array" \
    "2" "$(grep -cF -- 'for scope in "${PARITY_SCOPES[@]}"' "$PARITY" | tr -d ' \n')"
if grep -qF -- '".claude/vendor:9"' "$PARITY"; then hit=yes; else hit=no; fi
assert_eq "11.10 the parity scope list covers .claude/vendor" "yes" "$hit"

printf '\n=== Section 12: META-TESTs — every checker proved sensitive ===\n'

META_DIR=$(mktemp -d -t vendored-skills-meta.XXXXXX)

# --- META-1: a planted banned phrase must be caught -----------------------
cp "$VENDORED_SKILL" "$META_DIR/planted-ban.md"
printf '\nDo NOT invoke frontend-design, mcp-builder, or any other skill.\n' >> "$META_DIR/planted-ban.md"
assert_eq "META-1a: the planted banned phrase actually landed in the fixture" \
    "1" "$(grep -cF -- "mcp-builder" "$META_DIR/planted-ban.md" | tr -d ' \n')"
if [ -n "$(banned_hits "$META_DIR/planted-ban.md")" ]; then hit=caught; else hit=MISSED; fi
assert_eq "META-1b: banned_hits FLAGS the planted phrase" "caught" "$hit"
assert_eq "META-1c: control — the shipped file is still clean" "" "$(banned_hits "$VENDORED_SKILL")"

# --- META-2: a manifest with no 40-hex pin must be caught -----------------
sed "s/$EXPECTED_PIN/PINREMOVED/g" "$VENDOR_MANIFEST" > "$META_DIR/no-pin.md"
assert_eq "META-2a: the pin-stripping mutation actually landed" \
    "0" "$(grep -cE '\b[0-9a-f]{40}\b' "$META_DIR/no-pin.md" | tr -d ' \n')"
assert_eq "META-2b: manifest_pins reports ZERO pins for the mutant" \
    "0" "$(manifest_pins "$META_DIR/no-pin.md" | grep -c . | tr -d ' \n')"
assert_eq "META-2c: control — the shipped manifest still reports exactly 1" \
    "1" "$(manifest_pins "$VENDOR_MANIFEST" | grep -c . | tr -d ' \n')"

# A SECOND pin is the other half of "single-pin format": one live, one stale.
cp "$VENDOR_MANIFEST" "$META_DIR/two-pins.md"
# shellcheck disable=SC2016  # literal backticks in the planted markdown; no expansion wanted.
printf '\nPreviously pinned at `0123456789abcdef0123456789abcdef01234567`.\n' >> "$META_DIR/two-pins.md"
assert_eq "META-2d: a SECOND (stale) pin is detected, not averaged away" \
    "2" "$(manifest_pins "$META_DIR/two-pins.md" | grep -c . | tr -d ' \n')"

# --- META-3: a missing wiring sentinel must be caught ---------------------
grep -vF -- "Three clauses override that file wherever it disagrees" "$ORCH" > "$META_DIR/unwired.md"
META3_DELTA=$(( $(grep -c . "$ORCH") - $(grep -c . "$META_DIR/unwired.md") ))
assert_eq "META-3a: the sentinel-stripping mutation actually removed a line" "1" "$META3_DELTA"
assert_eq "META-3b: wiring_missing NAMES the absent sentinel" \
    "Three clauses override that file wherever it disagrees" "$(wiring_missing "$META_DIR/unwired.md")"
assert_eq "META-3c: control — the shipped orchestrator.md is fully wired" \
    "" "$(wiring_missing "$ORCH")"

# --- META-4: an approv line lacking qa-approved must be caught ------------
cp "$VENDORED_SKILL" "$META_DIR/approv-stub.md"
printf '\nPresent the design and wait until the user has approved it before coding.\n' >> "$META_DIR/approv-stub.md"
assert_eq "META-4a: the planted approval line actually landed" \
    "1" "$(grep -cF -- "wait until the user has approved it" "$META_DIR/approv-stub.md" | tr -d ' \n')"
if [ -n "$(approv_violations "$META_DIR/approv-stub.md")" ]; then hit=caught; else hit=MISSED; fi
assert_eq "META-4b: the approv/qa-approved invariant FLAGS it" "caught" "$hit"
assert_eq "META-4c: control — the shipped file has no violation" \
    "" "$(approv_violations "$VENDORED_SKILL")"

# --- META-5: a commit line lacking 'recent commits' must be caught --------
cp "$VENDORED_SKILL" "$META_DIR/commit-stub.md"
printf '\nCommit the design document to git before continuing.\n' >> "$META_DIR/commit-stub.md"
assert_eq "META-5a: the planted commit instruction actually landed" \
    "1" "$(grep -ciE -- "^Commit the design document" "$META_DIR/commit-stub.md" | tr -d ' \n')"
if [ -n "$(commit_violations "$META_DIR/commit-stub.md")" ]; then hit=caught; else hit=MISSED; fi
assert_eq "META-5b: the commit/recent-commits invariant FLAGS it (case-insensitively)" "caught" "$hit"
assert_eq "META-5c: control — the shipped file has no violation" \
    "" "$(commit_violations "$VENDORED_SKILL")"

# --- META-6: three SKILL.md files must be counted as three ---------------
# A second REGISTERED skill is the specific regression this guards: it would
# escape platform-audit.test.sh, whose scan names agents + commands + THE ONE
# skill by variable, not by glob.
mkdir -p "$META_DIR/fake/.claude/skills/one" "$META_DIR/fake/.claude/skills/two" \
    "$META_DIR/fake/.claude/vendor/upstream/thing" "$META_DIR/fake/.claude/tests/e2e/fixtures/x/.claude/skills/z"
for p in "skills/one" "skills/two" "vendor/upstream/thing"; do
    printf -- '---\nname: x\n---\n' > "$META_DIR/fake/.claude/$p/SKILL.md"
done
printf -- '---\nname: fixture-copy\n---\n' > "$META_DIR/fake/.claude/tests/e2e/fixtures/x/.claude/skills/z/SKILL.md"
assert_eq "META-6a: the fixture really holds 3 shipped SKILL.md files" \
    "3" "$(shipped_skill_files "$META_DIR/fake" | grep -c . | tr -d ' \n')"
assert_eq "META-6b: ...and the .claude/tests copy is pruned, not counted" \
    "0" "$(shipped_skill_files "$META_DIR/fake" | count_matching ".claude/tests/")"
assert_eq "META-6c: control — the real repo still answers 2" "2" "$SKILL_TOTAL"

# --- META-7: an alternate-authority phrase planted in a HARVEST file -----
# Scoped to a harvest-touched agent prompt rather than the vendored file,
# because that is the direction the brief calls likeliest: a competing
# instruction arriving through the harvest, not through a re-edit of the
# vendored doc.
cp "$AGENTS_DIR/backend.md" "$META_DIR/harvest-drift.md"
printf '\nDo not merge until the user approves the design.\n' >> "$META_DIR/harvest-drift.md"
assert_eq "META-7a: the planted authority phrase actually landed" \
    "1" "$(grep -cF -- "until the user approves" "$META_DIR/harvest-drift.md" | tr -d ' \n')"
assert_eq "META-7b: the scope scan FLAGS it in a harvest file" \
    "harvest-drift.md:1" "$(phrase_hits_in_files "the user approves" "$META_DIR/harvest-drift.md")"
assert_eq "META-7c: control — the real backend.md is clean" \
    "" "$(phrase_hits_in_files "the user approves" "$AGENTS_DIR/backend.md")"

# --- META-8: a second debugging protocol planted in a harvest file -------
cp "$AGENTS_DIR/qa.md" "$META_DIR/second-protocol.md"
printf '\n## The Iron Law\n\nNO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST\n' >> "$META_DIR/second-protocol.md"
assert_eq "META-8a: the planted protocol header actually landed" \
    "1" "$(grep -cF -- "Iron Law" "$META_DIR/second-protocol.md" | tr -d ' \n')"
assert_eq "META-8b: the second-protocol scan FLAGS it" \
    "second-protocol.md:1" "$(phrase_hits_in_files "Iron Law" "$META_DIR/second-protocol.md")"
assert_eq "META-8c: control — the real qa.md is clean" \
    "" "$(phrase_hits_in_files "Iron Law" "$AGENTS_DIR/qa.md")"

# --- META-9: provenance parity is sensitive in BOTH directions -----------
mkdir -p "$META_DIR/prov/extra"
cp "$VENDOR_MANIFEST" "$META_DIR/prov/MANIFEST.md"
cp "$VENDOR_LICENSE" "$META_DIR/prov/LICENSE.upstream"
printf 'unlisted\n' > "$META_DIR/prov/extra/STRAY.md"
assert_eq "META-9a: forward parity NAMES a vendor file the manifest omits" \
    "extra/STRAY.md" "$(provenance_forward "$META_DIR/prov/MANIFEST.md" "$META_DIR/prov")"
assert_eq "META-9b: reverse parity NAMES a manifest row with no file on disk" \
    "brainstorming/SKILL.md" "$(provenance_reverse "$META_DIR/prov/MANIFEST.md" "$META_DIR/prov")"

# Restore-after: every META wrote only inside $META_DIR, never the live repo.
rm -rf "$META_DIR"

printf '\n=== Summary ===\n'

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi

# Completeness line. A "no failures" verdict is not a "the run finished"
# verdict: a run that aborted halfway also reports zero failures.
#   7  section 1   presence and shape
#   3  section 2   single-pin format
#   3  section 3   bidirectional provenance parity
#   5  section 4   non-registration counts
#  17  section 5   16 banned phrases + the MANIFEST documentation check
#   4  section 6   two line-level invariants + their non-vacuity guards
#   3  section 7   alternate-authority scan + scope completeness
#   6  section 8   second-debug-protocol scan
#   4  section 9   positive wiring sentinels
#   5  section 10  attribution
#  10  section 11  registration sites
#  27  section 12  nine META-TESTs (8 of them mutation-landed + caught +
#                  control; META-2 adds the stale-second-pin case; META-9 is
#                  two directions of one parity checker)
# Counts measured from a real run on 2026-07-30, not estimated.
EXPECTED_ASSERTIONS=94
RUN=$((PASS + FAIL))
printf '\nTotal: %d assertion(s) run (expected %d)\n' "$RUN" "$EXPECTED_ASSERTIONS"
if [ "$RUN" -ne "$EXPECTED_ASSERTIONS" ]; then
    printf 'INCOMPLETE: assertion count moved. Update EXPECTED_ASSERTIONS deliberately, or find the dropped assertion.\n' >&2
    exit 1
fi

printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
