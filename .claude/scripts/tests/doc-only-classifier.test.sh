#!/bin/bash
# doc-only-classifier.test.sh — L1 unit fixture for verify-before-stop.sh's
# `is_doc_only_path` and its DOC-CONTENT-VETO (claude-workflow-plugin-bbh).
#
# WHY THIS TIER. `is_doc_only_path` is the predicate the F1 fast path's entire
# licence rests on: DOC_ONLY stays true only if EVERY changed path matches it,
# and a change set that is DOC_ONLY is auto-approved with `reviewed_by=none`. It
# is a pure function of a path plus (now) two facts about the file on disk, so
# it can be driven exhaustively offline. The hook-level consequences — a Stop
# that releases, a record that gets written — belong to the component tier and
# live in specs/verify-before-stop.sh; this file answers "what does the
# classifier say", deterministically and by the thousand.
#
# THE FUNCTIONS UNDER TEST ARE EXTRACTED FROM THE SHIPPED SCRIPT by awk, never
# re-typed here. A copy of the classifier in this file would be a second
# definition free to drift from the one that gates releases, which is the exact
# failure class bbh is about.
#
# Sections:
#   1  extraction + self-check (the extraction is the test's own dependency)
#   2  the bbh probe table — position and name-glob no longer confer doc status
#   3  the REMOVAL proves itself: re-insert the two deleted arms and the
#      measured defect returns, over a 1120-path cross product
#   4  the DOC-CONTENT-VETO: executable content is never doc-only
#   5  VETO META: strip the region and the veto's own leg goes green-to-defect
#
# Offline, self-contained; exit 0 all pass / 1 any fail / 2 invocation error.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
VBS="$PROJECT_DIR/.claude/scripts/verify-before-stop.sh"

if [ ! -f "$VBS" ]; then
    printf 'doc-only-classifier.test: script under test missing: %s\n' "$VBS" >&2
    exit 2
fi

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

WORK=$(mktemp -d -t doc-only-classifier.XXXXXX)
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. EXTRACTION
# ---------------------------------------------------------------------------
# Two pieces, both text-anchored, never line-numbered:
#   - the DOC-CONTENT-VETO helper region. Its sentinels sit at COLUMN 0 while
#     the call-site region's are indented inside the function, so `^#` selects
#     the helper and only the helper. Pulling both would drop an orphaned `if`
#     at top level and the extraction would not parse.
#   - is_doc_only_path itself, by its `name() {` .. `}` range.
extract_classifier() {
    local src="$1" out="$2"
    {
        awk '/^# DOC-CONTENT-VETO BEGIN/,/^# DOC-CONTENT-VETO END/' "$src"
        printf '\n'
        awk '/^is_doc_only_path\(\) \{/,/^\}/' "$src"
    } > "$out"
}

SHIPPED_LIB="$WORK/shipped.sh"
extract_classifier "$VBS" "$SHIPPED_LIB"

assert_eq "1.1 the extraction defines is_doc_only_path" "1" \
    "$(grep -c '^is_doc_only_path() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "1.2 the extraction defines the veto helper" "1" \
    "$(grep -c '^doc_path_is_executable_content() {$' "$SHIPPED_LIB" | tr -d '[:space:]')"
assert_eq "1.3 the extraction parses" "0" \
    "$(bash -n "$SHIPPED_LIB" 2>/dev/null && echo 0 || echo 1)"

# classify_all <lib> <project-dir> <paths-file> -> "<verdict>\t<path>" per line.
#
# One bash per call, `log_sync_error` stubbed to stderr so the classifier's own
# diagnostic is capturable without pulling the rest of the hook in. Stdout
# carries only verdicts.
classify_all() {
    local lib="$1" pdir="$2" paths="$3"
    bash -c '
        set -u
        PROJECT_DIR="$1"
        log_sync_error() { printf "SYNCERR %s\n" "$1" >&2; }
        . "$2"
        while IFS= read -r p; do
            [ -z "$p" ] && continue
            if is_doc_only_path "$p"; then printf "DOC-ONLY\t%s\n" "$p"
            else printf "reviewable\t%s\n" "$p"; fi
        done < "$3"
    ' _ "$pdir" "$lib" "$paths"
}

# verdict_of <classified-output> <path>
verdict_of() {
    printf '%s\n' "$1" | awk -F'\t' -v p="$2" '$2 == p { print $1; found=1 } END { if (!found) print "MISSING" }'
}

# ---------------------------------------------------------------------------
# 2. THE bbh PROBE TABLE
# ---------------------------------------------------------------------------
# NO FILE EXISTS for any of these paths, deliberately: this section measures the
# NAME/POSITION half on its own, with the veto unable to contribute an opinion.
# Section 4 supplies the files.
cat > "$WORK/table.txt" <<'EOF'
docs/HOOKS.md
docs/guide.markdown
docs/api.mdx
docs/spec.rst
docs/notes.txt
docs/examples/setup.sh
docs/scripts/migrate.py
docs/fixtures/payload.json
docs/Dockerfile
docs/Makefile
docs/.github/workflows/ci.yml
docs/settings.json
docs/img/diagram.png
docs/deploy.sh
docs/README
src/docs/handler.ts
packages/web/docs/build.gradle
/abs/root/docs/deploy.sh
LICENSE
LICENSE.md
LICENSE.txt
LICENSE.sh
LICENSE.py
LICENSE.yml
src/LICENSE.sh
CHANGELOG
CHANGELOG.md
NOTICE
AUTHORS
README.md
README
tests/spec.txt
.claude/scripts/hook.txt
src/handler.rst
install.sh
.claude/scripts/qa-gate.sh
src/index.ts
package.json
Dockerfile
EOF
TABLE=$(classify_all "$SHIPPED_LIB" "$WORK/nonexistent-root" "$WORK/table.txt" 2>/dev/null)

# 2a. The bypass the task was filed for: POSITION no longer confers doc status.
for p in docs/examples/setup.sh docs/scripts/migrate.py docs/fixtures/payload.json \
         docs/Dockerfile docs/Makefile docs/.github/workflows/ci.yml docs/settings.json \
         docs/img/diagram.png docs/deploy.sh docs/README src/docs/handler.ts \
         packages/web/docs/build.gradle /abs/root/docs/deploy.sh; do
    assert_eq "2a position: $p is REVIEWABLE (was DOC-ONLY via */docs/*)" \
        "reviewable" "$(verdict_of "$TABLE" "$p")"
done

# 2b. A NAME GLOB no longer confers doc status on an arbitrary extension.
for p in LICENSE.sh LICENSE.py LICENSE.yml; do
    assert_eq "2b name glob: $p is REVIEWABLE (was DOC-ONLY via LICENSE.*)" \
        "reviewable" "$(verdict_of "$TABLE" "$p")"
done
# The asymmetry that made the old arm's reach non-obvious: it had no `*/`
# prefix, so this one was ALREADY reviewable. Pinned so the two are not
# conflated when reading the section above.
assert_eq "2b control: src/LICENSE.sh was reviewable before this change too" \
    "reviewable" "$(verdict_of "$TABLE" "src/LICENSE.sh")"

# 2c. ANTI-OVERREACH. Documentation must not lose the fast path — F1 exists for
# exactly these commits, and a fix that deadlocks them is the same error in the
# other direction.
for p in docs/HOOKS.md docs/guide.markdown docs/api.mdx docs/spec.rst docs/notes.txt \
         LICENSE LICENSE.md LICENSE.txt CHANGELOG CHANGELOG.md NOTICE AUTHORS \
         README.md tests/spec.txt .claude/scripts/hook.txt src/handler.rst; do
    assert_eq "2c anti-overreach: $p is still DOC-ONLY" \
        "DOC-ONLY" "$(verdict_of "$TABLE" "$p")"
done

# 2d. Unchanged in both directions — reviewable before, reviewable after.
for p in install.sh .claude/scripts/qa-gate.sh src/index.ts package.json Dockerfile README; do
    assert_eq "2d unchanged: $p is reviewable" "reviewable" "$(verdict_of "$TABLE" "$p")"
done

# ---------------------------------------------------------------------------
# 3. THE REMOVAL PROVES ITSELF
# ---------------------------------------------------------------------------
# A deletion cannot be measured by stripping a sentinel — there is nothing left
# to strip. The negative control is the inverse: RE-INSERT the two removed arms
# into a copy and assert the measured defect comes back. Anything this section
# asserts about the shipped classifier is then attributable to the removal and
# to nothing else in the function.
#
# The veto is stripped from the reconstruction as well, so the copy is the
# pre-bbh classifier in behaviour rather than a hybrid; section 4 measures the
# veto separately, on its own.
VETO_STRIPPED_SRC="$WORK/vbs-noveto.sh"
awk '/^ *# DOC-CONTENT-VETO BEGIN/ { skip = 1; next }
     /^ *# DOC-CONTENT-VETO END/   { skip = 0; next }
     !skip { print }' "$VBS" > "$VETO_STRIPPED_SRC"
PREFIX_LIB="$WORK/prefix.sh"
extract_classifier "$VETO_STRIPPED_SRC" "$PREFIX_LIB"
# Re-insert, text-anchored on the arms as they are written today.
sed -e 's#^        \*/LICENSE|LICENSE) ;;$#        */LICENSE|LICENSE|LICENSE.*) ;;#' \
    -e 's#^        \*) return 1 ;;$#        */docs/*|docs/*) ;;\
        *) return 1 ;;#' \
    "$PREFIX_LIB" > "$PREFIX_LIB.tmp" && mv "$PREFIX_LIB.tmp" "$PREFIX_LIB"

if cmp -s "$SHIPPED_LIB" "$PREFIX_LIB"; then
    assert_eq "3.0 GUARD: the re-insertion APPLIED (mutant differs from shipped)" \
        "differs" "identical"
else
    assert_eq "3.0 GUARD: the re-insertion APPLIED (mutant differs from shipped)" \
        "differs" "differs"
    assert_eq "3.1 the reconstruction parses" "0" \
        "$(bash -n "$PREFIX_LIB" 2>/dev/null && echo 0 || echo 1)"
    assert_eq "3.2 the */docs/* arm is back" "1" \
        "$(grep -c '^        \*/docs/\*|docs/\*) ;;$' "$PREFIX_LIB" | tr -d '[:space:]')"
    assert_eq "3.3 the LICENSE.* glob is back" "1" \
        "$(grep -c '^        \*/LICENSE|LICENSE|LICENSE\.\*) ;;$' "$PREFIX_LIB" | tr -d '[:space:]')"
    assert_eq "3.4 ...and the veto call did NOT survive into the reconstruction" "0" \
        "$(grep -c 'doc_path_is_executable_content' "$PREFIX_LIB" | tr -d '[:space:]')"

    PRE_TABLE=$(classify_all "$PREFIX_LIB" "$WORK/nonexistent-root" "$WORK/table.txt" 2>/dev/null)
    # THE DEFECT, reproduced. Each of these is one of the paths measured on the
    # task; with the arms back they are documentation again.
    for p in docs/examples/setup.sh docs/scripts/migrate.py docs/Dockerfile \
             docs/deploy.sh src/docs/handler.ts LICENSE.sh LICENSE.py; do
        assert_eq "3.5 DEFECT REPRODUCED: with the arms re-inserted, $p is DOC-ONLY again" \
            "DOC-ONLY" "$(verdict_of "$PRE_TABLE" "$p")"
    done
    # ...and the one the arms never reached, so the reconstruction is the
    # pre-fix classifier rather than something merely more permissive.
    assert_eq "3.6 DEFECT REPRODUCED: src/LICENSE.sh stays reviewable (the arm had no */ prefix)" \
        "reviewable" "$(verdict_of "$PRE_TABLE" "src/LICENSE.sh")"

    # ---- the cross product ------------------------------------------------
    # 8 directory shapes x 10 basenames x 14 extensions. The question is not
    # "does it classify these correctly" — it is what the REMOVAL did to the
    # function as a whole, in both directions.
    : > "$WORK/cross.txt"
    for d in "" "docs/" "docs/sub/" "src/" "src/docs/" "a/b/docs/c/" "/abs/docs/" "/abs/src/"; do
        for b in README LICENSE CHANGELOG NOTICE AUTHORS deploy handler golden Dockerfile Makefile; do
            for e in "" .md .markdown .mdx .rst .txt .sh .py .ts .json .yml .png .Md .MD; do
                printf '%s%s%s\n' "$d" "$b" "$e" >> "$WORK/cross.txt"
            done
        done
    done
    assert_eq "3.7 cross product is the expected size" "1120" \
        "$(grep -c . "$WORK/cross.txt" | tr -d '[:space:]')"
    classify_all "$SHIPPED_LIB" "$WORK/nonexistent-root" "$WORK/cross.txt" 2>/dev/null \
        | cut -f1 > "$WORK/cross.now"
    classify_all "$PREFIX_LIB" "$WORK/nonexistent-root" "$WORK/cross.txt" 2>/dev/null \
        | cut -f1 > "$WORK/cross.pre"
    paste -d' ' "$WORK/cross.pre" "$WORK/cross.now" "$WORK/cross.txt" > "$WORK/cross.joined"

    # (a) It can only NARROW. A single path gaining doc status would be a new
    #     bypass introduced by the fix, which is the one outcome that must be
    #     impossible.
    assert_eq "3.8 the change NEVER widens: 0 paths went reviewable -> DOC-ONLY" "0" \
        "$(awk '$1=="reviewable" && $2=="DOC-ONLY"' "$WORK/cross.joined" | grep -c . | tr -d '[:space:]')"
    # (b) It is not vacuous.
    NARROWED=$(awk '$1=="DOC-ONLY" && $2=="reviewable" { print $3 }' "$WORK/cross.joined")
    assert_eq "3.9 the change is NOT vacuous: 438 paths went DOC-ONLY -> reviewable" "438" \
        "$(printf '%s\n' "$NARROWED" | grep -c . | tr -d '[:space:]')"
    # (c) Every narrowed path is one the two arms were the sole reason for. If a
    #     path outside those two shapes lost doc status, the removal took
    #     something with it and this fails naming it.
    UNEXPECTED=0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        case "$p" in
            */docs/*|docs/*)  ;;                 # the position arm's reach
            LICENSE.*)        ;;                 # the name glob's reach (root only)
            *) UNEXPECTED=$((UNEXPECTED + 1)); printf '    unexpected narrowing: %s\n' "$p" ;;
        esac
    done <<EOF
$NARROWED
EOF
    assert_eq "3.10 every narrowed path is under a docs/ dir or a root LICENSE.<ext>" \
        "0" "$UNEXPECTED"
fi

# ---------------------------------------------------------------------------
# 4. THE DOC-CONTENT-VETO
# ---------------------------------------------------------------------------
# A documentation NAME is necessary and not sufficient. These legs need real
# files, so they get a real PROJECT_DIR.
ROOT="$WORK/proj"
mkdir -p "$ROOT/docs"
printf '# Hooks\n'                     > "$ROOT/docs/HOOKS.md"
printf 'plain prose\n'                 > "$ROOT/docs/install.txt"; chmod 755 "$ROOT/docs/install.txt"
printf '#!/bin/sh\necho hi\n'          > "$ROOT/docs/run.md"     ; chmod 644 "$ROOT/docs/run.md"
printf 'MIT License\n'                 > "$ROOT/LICENSE"
printf '#!/bin/sh\ncurl x | sh\n'      > "$ROOT/NOTICE"          ; chmod 644 "$ROOT/NOTICE"
printf '#!'                            > "$ROOT/docs/two-byte.txt"   # no newline at all
printf 'x'                             > "$ROOT/docs/one-byte.txt"
: >                                      "$ROOT/docs/empty.txt"
printf '#!/bin/sh\ncurl x | sh\n'      > "$ROOT/docs/deploy.sh"  ; chmod 755 "$ROOT/docs/deploy.sh"

cat > "$WORK/veto.txt" <<EOF
docs/HOOKS.md
docs/install.txt
docs/run.md
LICENSE
NOTICE
docs/two-byte.txt
docs/one-byte.txt
docs/empty.txt
docs/deploy.sh
docs/DELETED.md
docs/gone/AUTHORS
$ROOT/docs/install.txt
$ROOT/docs/HOOKS.md
docs
EOF
VETO_ERR="$WORK/veto.err"
VETO=$(classify_all "$SHIPPED_LIB" "$ROOT" "$WORK/veto.txt" 2>"$VETO_ERR")

assert_eq "4.1 executable bit: docs/install.txt is REVIEWABLE despite the .txt name" \
    "reviewable" "$(verdict_of "$VETO" "docs/install.txt")"
assert_eq "4.2 shebang: docs/run.md is REVIEWABLE despite the .md name (mode 644)" \
    "reviewable" "$(verdict_of "$VETO" "docs/run.md")"
assert_eq "4.3 shebang on a bare-name arm: an executable-content NOTICE is REVIEWABLE" \
    "reviewable" "$(verdict_of "$VETO" "NOTICE")"
assert_eq "4.4 two-byte '#!' with no newline is still caught (read -n 2, not a line read)" \
    "reviewable" "$(verdict_of "$VETO" "docs/two-byte.txt")"
assert_eq "4.5 absolute spelling of the same file gets the same verdict" \
    "reviewable" "$(verdict_of "$VETO" "$ROOT/docs/install.txt")"

# CONTROLS — the veto must not eat ordinary documentation.
assert_eq "4.6 control: a plain docs/HOOKS.md is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/HOOKS.md")"
assert_eq "4.7 control: absolute docs/HOOKS.md is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "$ROOT/docs/HOOKS.md")"
assert_eq "4.8 control: a plain LICENSE is DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "LICENSE")"
assert_eq "4.9 control: a 1-byte file is DOC-ONLY (partial read is not a shebang)" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/one-byte.txt")"
assert_eq "4.10 control: an EMPTY file is DOC-ONLY (read returns EOF, no veto)" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/empty.txt")"

# THE DELETION CONTRACT. A path with no file behind it is not evidence of
# anything, so the name arms decide — which is what keeps a documentation
# DELETION on the fast path. This is the one asymmetry in the veto and it is the
# leg that pins it.
assert_eq "4.11 a DELETED doc (no file on disk) stays DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/DELETED.md")"
assert_eq "4.12 a DELETED extension-less doc stays DOC-ONLY" \
    "DOC-ONLY" "$(verdict_of "$VETO" "docs/gone/AUTHORS")"

# Not a doc name at all -> the veto never runs; unchanged from section 2.
assert_eq "4.13 docs/deploy.sh is reviewable by NAME, before the veto is consulted" \
    "reviewable" "$(verdict_of "$VETO" "docs/deploy.sh")"
assert_eq "4.14 a directory named docs is reviewable" \
    "reviewable" "$(verdict_of "$VETO" "docs")"

# DIAGNOSABILITY. A block whose cause the operator cannot see is a dead end, so
# each veto writes a sync-error naming the path and the evidence.
# Anchored immediately after `F1: ` so the relative and absolute spellings of
# the SAME file are counted separately — an unanchored `docs/install.txt`
# matches both lines and the leg then asserts a number rather than a fact.
assert_eq "4.15 the veto logs the executable-bit case, naming the path" "1" \
    "$(grep -c 'SYNCERR F1: docs/install.txt carries .*executable bit is set' "$VETO_ERR" | tr -d '[:space:]')"
assert_eq "4.16 the veto logs the shebang case, naming the evidence" "1" \
    "$(grep -c 'SYNCERR F1: docs/run.md carries .*#! shebang' "$VETO_ERR" | tr -d '[:space:]')"
assert_eq "4.17 the absolute spelling logs its own line, under its own path" "1" \
    "$(grep -c "SYNCERR F1: $ROOT/docs/install.txt carries .*executable bit is set" "$VETO_ERR" | tr -d '[:space:]')"
assert_eq "4.18 ...and NOTHING is logged for the documentation controls" "0" \
    "$(grep -c 'SYNCERR.*HOOKS.md' "$VETO_ERR" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
# 5. VETO META
# ---------------------------------------------------------------------------
# Strip the DOC-CONTENT-VETO regions and the section-4 legs must go back to the
# behaviour the veto exists to prevent. Without this the veto is a guard whose
# failure nobody has produced.
NOVETO_LIB="$WORK/noveto.sh"
extract_classifier "$VETO_STRIPPED_SRC" "$NOVETO_LIB"
if cmp -s "$SHIPPED_LIB" "$NOVETO_LIB"; then
    assert_eq "5.0 GUARD: the veto strip APPLIED (mutant differs from shipped)" \
        "differs" "identical"
else
    assert_eq "5.0 GUARD: the veto strip APPLIED (mutant differs from shipped)" \
        "differs" "differs"
    assert_eq "5.1 the stripped copy parses" "0" \
        "$(bash -n "$NOVETO_LIB" 2>/dev/null && echo 0 || echo 1)"
    assert_eq "5.2 no veto call survives the strip" "0" \
        "$(grep -c 'doc_path_is_executable_content' "$NOVETO_LIB" | tr -d '[:space:]')"
    assert_eq "5.3 ...while the name arms survive outside the region" "1" \
        "$(grep -c '^        \*.md|\*.markdown|\*.mdx|\*.rst|\*.txt) ;;$' "$NOVETO_LIB" | tr -d '[:space:]')"

    NOVETO=$(classify_all "$NOVETO_LIB" "$ROOT" "$WORK/veto.txt" 2>/dev/null)
    assert_eq "5.4 META: without the veto, an EXECUTABLE docs/install.txt is DOC-ONLY (4.1 WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "docs/install.txt")"
    assert_eq "5.5 META: ...and a shebang-carrying docs/run.md is DOC-ONLY (4.2 WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "docs/run.md")"
    assert_eq "5.6 META: ...and an executable-content NOTICE is DOC-ONLY (4.3 WOULD fail)" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "NOTICE")"
    # Discriminator: the stripped copy still ran the real classifier, so the
    # difference above is the veto and nothing else about the extraction.
    assert_eq "5.7 META: the stripped copy still classifies docs/deploy.sh reviewable (it ran the real arms)" \
        "reviewable" "$(verdict_of "$NOVETO" "docs/deploy.sh")"
    assert_eq "5.8 META: ...and still classifies a plain docs/HOOKS.md DOC-ONLY" \
        "DOC-ONLY" "$(verdict_of "$NOVETO" "docs/HOOKS.md")"
    # RESTORE CONTROL: the shipped copy, same inputs, same call shape.
    RESTORE=$(classify_all "$SHIPPED_LIB" "$ROOT" "$WORK/veto.txt" 2>/dev/null)
    assert_eq "5.9 restore control: the SHIPPED copy vetoes the identical file" \
        "reviewable" "$(verdict_of "$RESTORE" "docs/install.txt")"
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$FAIL" -gt 0 ]; then
    printf 'FAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
printf 'PASSED: %d assertion(s)\n' "$PASS"
exit 0
