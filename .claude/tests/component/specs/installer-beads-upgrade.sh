#!/bin/bash
# installer-beads-upgrade.sh — L2 component spec for install.sh's Beads
# upgrader (claude-workflow-plugin-fkm.1.1).
#
# WHAT THIS PROVES
# ----------------
# bd 0.47.x cannot re-import its own ledger once any issue's JSONL line exceeds
# Go's 64KB bufio.Scanner limit: `bd import` fails and a fresh clone recovers
# ZERO issues. This repo hit it with 15 oversized records and 277 issues. The
# installer therefore moves a target off 0.47.x — and the ORDER it does that in
# is the entire safety property, because bd 1.1.2 cannot read a 0.47.x SQLite
# store at all ("no beads database found"). Only .beads/issues.jsonl survives
# the version boundary.
#
# So the contract under test is:
#
#   1. FRESH target (no .beads/)     -> upgrade runs, nothing to migrate.
#   2. ALREADY-INSTALLED target      -> the ledger is exported with the OLD bd
#      (a .beads/ with issues)          BEFORE the binary is replaced, and the
#                                       store is rebuilt afterwards.
#   3. Export fails                  -> REFUSE to upgrade. A half-migrated
#                                       target (unreadable store + stale
#                                       ledger) is worse than an old bd.
#   4. Already current               -> no-op, no upgrade command run.
#   5. Below the floor WITHOUT a     -> the install is REFUSED (exit 1), and
#      working opt-in upgrade           so is every opt-in step that leaves bd
#                                       below the floor. --skip-beads-upgrade
#                                       stops the opt-in upgrade from running;
#                                       it never admits an old bd.
#
# THE UPGRADE IS OPT-IN (claude-workflow-plugin-wyt3): it runs only when the
# operator sets BD_UPGRADE_COMMAND AND CWP_BEADS_UPGRADE=1. The harness below
# therefore sets CWP_BEADS_UPGRADE=1 by default, so sections 1-3 and 6 still
# exercise the upgrade path itself; section 4 clears it to test the refusal.
# Every refusal is the installer's refuse_below_floor, which this spec extracts
# alongside the upgrader (claude-workflow-plugin-ishe R5-F1: until then a skip
# flag or a failed opt-in step returned instead, and the install proceeded on
# an unsupported bd).
#
# HERMETIC BY CONSTRUCTION. Nothing here touches the network or swaps a real
# binary: BD_UPGRADE_COMMAND is the installer's documented seam and is pointed
# at a local script, and `bd` itself is a PATH shim whose reported version is
# read from a file the spec controls. Assertion 3 in particular could not be
# written any other way — it needs an export that fails on demand.
#
# Only the upgrader function is exercised, not a whole install: the function is
# sourced out of install.sh by name. That keeps the spec fast and makes each
# assertion point at one behaviour instead of at an install transcript.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

PLUGIN_D=$(plugin_root)
INSTALLER="$PLUGIN_D/install.sh"
WORK="$FIXTURE/upgrade-work"
mkdir -p "$WORK"

assert_eq "installer-beads-upgrade 0: install.sh is present" "yes" \
    "$([ -f "$INSTALLER" ] && echo yes || echo no)"

# The recommended floor is declared between sentinels so this spec reads the
# SAME value the installer enforces, instead of hardcoding a second copy that
# could drift.
RECOMMENDED=$(sed -n 's/^RECOMMENDED_BD_VERSION="\(.*\)"$/\1/p' "$INSTALLER" | head -1)
assert_match "installer-beads-upgrade 0: RECOMMENDED_BD_VERSION is declared and dotted-numeric" \
    '^[0-9]+\.[0-9]+(\.[0-9]+)?$' "$RECOMMENDED"
assert_eq "installer-beads-upgrade 0: MIN_BD_VERSION is still 0.47 (the CLI floor checked first; it rejects a bd too old to talk to and admits none)" \
    "0.47" "$(sed -n 's/^MIN_BD_VERSION="\(.*\)"$/\1/p' "$INSTALLER" | head -1)"

# ---------------------------------------------------------------------------
# Harness: a fake `bd` whose version, export behaviour and store-readability
# are all driven by files, so each scenario is one variable.
#
#   $STATE/version      what `bd --version` prints
#   $STATE/export-rc    exit code for `bd export`
#   $STATE/readable     "yes" => `bd list --json` succeeds
#   $STATE/calls        append-only argv log
STATE="$WORK/state"
mkdir -p "$STATE" "$WORK/bin"
cat > "$WORK/bin/bd" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STATE/calls"
case "${1:-}" in
    --version) printf 'bd version %s\n' "$(cat "$STATE/version")" ;;
    export)
        rc=$(cat "$STATE/export-rc" 2>/dev/null || echo 0)
        if [ "$rc" = "0" ]; then
            # Mimic `bd export -o <file>`: last arg is the destination.
            dest=""; for a in "$@"; do dest="$a"; done
            # MODELS THE REAL 0.47.1 DEFECT (R2-F1): `bd export` emits every
            # ISSUE and DROPS EVERY COMMENT. Measured on the parked 0.47.1
            # binary: 3 comments in the database, a ledger with no `comments`
            # key at all, exit 0. The fake must reproduce that or the spec
            # cannot see the audit-trail loss — which is exactly why the
            # original version of this spec passed while the bug shipped.
            if [ "$(cat "$STATE/export-drops-comments" 2>/dev/null || echo yes)" = "yes" ]; then
                jq -c 'del(.comments)' "$STATE/db.jsonl" > "$dest" 2>/dev/null || true
            else
                cp "$STATE/db.jsonl" "$dest" 2>/dev/null || true
            fi
        fi
        exit "$rc" ;;
    sync)
        # 0.47.x's comment-PRESERVING writer, and the one this repo's committed
        # ledger was actually produced by. Gone in 1.1.2, hence the exit-1 leg.
        [ "$(cat "$STATE/sync-ok" 2>/dev/null || echo yes)" = "yes" ] || exit 1
        # The upgrader runs this with cwd=<target>, and `sync --flush-only`
        # writes bd's default ledger path — no -o to honour.
        mkdir -p "$PWD/.beads" 2>/dev/null || true
        cp "$STATE/db.jsonl" "$PWD/.beads/issues.jsonl" 2>/dev/null || true
        exit 0 ;;
    list)
        [ "$(cat "$STATE/readable" 2>/dev/null || echo yes)" = "yes" ] || exit 1
        printf '[]\n' ;;
    bootstrap)
        printf 'yes' > "$STATE/readable"; printf 'Imported\n' ;;
    *) : ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/bd"

# The upgrade "command": flips the fake bd's reported version. Stands in for
# the real `curl ... | bash`.
cat > "$WORK/bin/fake-upgrade" <<'EOF'
#!/bin/bash
printf '%s' "$FAKE_NEW_VERSION" > "$STATE/version"
printf 'upgrade-ran\n' >> "$STATE/calls"
EOF
chmod +x "$WORK/bin/fake-upgrade"

# run_upgrader <old-version> <target> [extra env assignments...]
#
# Sources install.sh's function WITHOUT executing the installer: everything
# above the function is skipped by extracting just the function body plus the
# handful of variables it reads. Extraction is anchored on the function name so
# a rename fails here loudly rather than silently testing nothing.
extract_upgrader() {
    awk '/^upgrade_beads_if_old\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALLER"
}
UPGRADER_SRC="$WORK/upgrader.sh"
# The single-quoted lines below are the CONTENT of a generated script, so their
# `$` must survive into the file rather than expanding here. That is the whole
# point of the quoting, not an oversight.
# shellcheck disable=SC2016
{
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'GREEN=""; YELLOW=""; RED=""; NC=""'
    printf 'RECOMMENDED_BD_VERSION=%q\n' "$RECOMMENDED"
    printf '%s\n' 'SKIP_BEADS_UPGRADE=${SKIP_BEADS_UPGRADE:-false}'
    printf '%s\n' 'BD_UPGRADE_COMMAND=${BD_UPGRADE_COMMAND:-true}'
    # The safeguard's loss detector lives beside the upgrader in install.sh;
    # extract it too, anchored on its name so a rename fails loudly here.
    awk '/^ledger_comment_count\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALLER"
    # ...and the helper the refusal prints its re-run and check commands with
    # (claude-workflow-plugin-s229), plus the two repo defaults it reads, taken
    # verbatim from install.sh. SCRIPT_DIR is empty, as `curl ... | bash` leaves
    # it, so the procedure prints the curl form. Without the helper, the
    # refusal would print "command not found" where the command belongs and
    # every assertion below would still pass.
    printf '%s\n' 'SCRIPT_DIR=""'
    grep -E '^REPO_(URL|BRANCH)=' "$INSTALLER"
    awk '/^installer_rerun_cmd\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALLER"
    # ...and the refusal every below-floor path ends in. Without it, a call to
    # an undefined function would print an error and CONTINUE, so the guard
    # below is what keeps this spec from passing a refusal that never exited.
    awk '/^refuse_below_floor\(\) \{/{f=1} f{print} f&&/^\}$/{exit}' "$INSTALLER"
    extract_upgrader
    printf '%s\n' 'upgrade_beads_if_old "$1" "$2"'
} > "$UPGRADER_SRC"

assert_eq "installer-beads-upgrade 0: the upgrader function was extracted (guards a rename)" \
    "yes" \
    "$(grep -q 'upgrade_beads_if_old() {' "$UPGRADER_SRC" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 0: the refusal function was extracted too (guards a rename)" \
    "yes" \
    "$(grep -q 'refuse_below_floor() {' "$UPGRADER_SRC" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 0: ...and the re-run helper it calls, with both repo defaults (guards a rename)" \
    "yes" \
    "$(grep -q 'installer_rerun_cmd() {' "$UPGRADER_SRC" && [ "$(grep -cE '^REPO_(URL|BRANCH)=' "$UPGRADER_SRC")" -eq 2 ] && echo yes || echo no)"

# The modelled database: two issues, one carrying the three gate records whose
# survival across the migration is the whole point of R2-F1.
DB_SEED='{"id":"seed-1","title":"audited","comments":[{"id":1,"text":"IMPLEMENTER: role=backend task=seed-1 at 2026-08-02T00:00:00Z"},{"id":2,"text":"REVIEW-ARTIFACT v1 reviewer=qa-claude findings=[] verdict=approve"},{"id":3,"text":"QA-GATE APPROVED change_set_hash=deadbeef reviewed_by=qa-claude"}]}
{"id":"seed-2","title":"plain","comments":[]}'
reset_state() {
    printf '%s' "${1:-0.47.1}" > "$STATE/version"
    printf '0' > "$STATE/export-rc"
    printf 'yes' > "$STATE/readable"
    printf 'yes' > "$STATE/sync-ok"
    printf 'yes' > "$STATE/export-drops-comments"
    printf '%s\n' "$DB_SEED" > "$STATE/db.jsonl"
    : > "$STATE/calls"
}
# comment entries across a ledger — the measure a record count cannot see.
ledger_comments() {
    [ -f "$1" ] || { printf '0'; return 0; }
    jq -rR 'fromjson? | ((.comments // []) | length)' "$1" 2>/dev/null \
        | awk '{n += $1} END { printf "%d", n + 0 }'
}
# The opt-in defaults ON here (CWP_BEADS_UPGRADE=1) because the upgrade path is
# unreachable without it; a caller clears it with CWP_BEADS_UPGRADE= to test the
# default refusal. The exit status is the subshell's, so `OUT=$(run_upgrader
# ...); RC=$?` captures it without adding anything to the output.
run_upgrader() {
    local oldver="$1" target="$2"
    env -u CLAUDE_WORKFLOW_REPO -u CLAUDE_WORKFLOW_BRANCH \
        PATH="$WORK/bin:$PATH" STATE="$STATE" \
        FAKE_NEW_VERSION="${FAKE_NEW_VERSION:-$RECOMMENDED}" \
        SKIP_BEADS_UPGRADE="${SKIP_BEADS_UPGRADE:-false}" \
        CWP_SKIP_BEADS_UPGRADE="${CWP_SKIP_BEADS_UPGRADE:-}" \
        CWP_BEADS_UPGRADE="${CWP_BEADS_UPGRADE-1}" \
        BD_UPGRADE_COMMAND="${BD_UPGRADE_COMMAND:-$WORK/bin/fake-upgrade}" \
        bash "$UPGRADER_SRC" "$oldver" "$target" 2>&1
}
calls_contain() { grep -qF -- "$1" "$STATE/calls" 2>/dev/null; }

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 1: FRESH target (no .beads/) ==="

FRESH="$WORK/fresh"; mkdir -p "$FRESH"
reset_state "0.47.1"
OUT1=$(run_upgrader "0.47.1" "$FRESH")
assert_contains "installer-beads-upgrade 1.1: an old bd is named, with the 64KB reason" \
    "64KB" "$OUT1"
assert_eq "installer-beads-upgrade 1.2: the upgrade command RAN" "yes" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_contains "installer-beads-upgrade 1.3: ...and the new version is reported" \
    "0.47.1 -> $RECOMMENDED" "$OUT1"
assert_eq "installer-beads-upgrade 1.4: no export was attempted — there is no store to protect" "no" \
    "$(calls_contain "export" && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 2: ALREADY-INSTALLED target (the operator's case) ==="

INST="$WORK/installed"; mkdir -p "$INST/.beads"
printf '{"id":"pre-existing"}\n' > "$INST/.beads/issues.jsonl"
reset_state "0.47.1"
OUT2=$(run_upgrader "0.47.1" "$INST")
assert_contains "installer-beads-upgrade 2.1: THE ORDERING — the ledger is written BEFORE the upgrade" \
    "before upgrading" "$OUT2"
# Order is asserted from the call log, not from the prose: the ledger write must
# be recorded before the upgrade ran, or the delta would have been unreachable.
# Matches EITHER writer — the safeguard prefers `sync --flush-only` (the
# comment-preserving leg, R2-F1) and falls back to `export`; which one fired is
# section 6's business, the ORDER is this one's.
WRITE_LINE=$(grep -nE '^(sync|export)' "$STATE/calls" | head -1 | cut -d: -f1)
UPGRADE_LINE=$(grep -n '^upgrade-ran' "$STATE/calls" | head -1 | cut -d: -f1)
assert_eq "installer-beads-upgrade 2.2: ...and the call LOG proves that order (ledger write before upgrade)" \
    "yes" \
    "$([ -n "$WRITE_LINE" ] && [ -n "$UPGRADE_LINE" ] && [ "$WRITE_LINE" -lt "$UPGRADE_LINE" ] && echo yes || echo no)"
assert_contains "installer-beads-upgrade 2.3: the upgrade completed" "0.47.1 -> $RECOMMENDED" "$OUT2"
assert_contains "installer-beads-upgrade 2.4: ...and the upgraded bd can read the database" \
    "reads the existing database" "$OUT2"

# 2b. The migration case: after the swap the new bd CANNOT read the old store
# (this is what really happens going 0.47.x -> 1.1.2), so it must rebuild from
# the ledger rather than leave the target empty.
INST2="$WORK/installed-unreadable"; mkdir -p "$INST2/.beads"
printf '{"id":"pre-existing"}\n' > "$INST2/.beads/issues.jsonl"
reset_state "0.47.1"
cat > "$WORK/bin/fake-upgrade-breaks" <<'EOF'
#!/bin/bash
printf '%s' "$FAKE_NEW_VERSION" > "$STATE/version"
printf 'no' > "$STATE/readable"     # 1.1.2 cannot read a 0.47.x SQLite store
printf 'upgrade-ran\n' >> "$STATE/calls"
EOF
chmod +x "$WORK/bin/fake-upgrade-breaks"
OUT2B=$(BD_UPGRADE_COMMAND="$WORK/bin/fake-upgrade-breaks" run_upgrader "0.47.1" "$INST2")
assert_contains "installer-beads-upgrade 2.5: an unreadable post-upgrade store triggers a rebuild" \
    "rebuilding from the ledger" "$OUT2B"
assert_eq "installer-beads-upgrade 2.6: ...via bd bootstrap" "yes" \
    "$(calls_contain "bootstrap" && echo yes || echo no)"
assert_contains "installer-beads-upgrade 2.7: ...and the rebuild is CONFIRMED, not assumed" \
    "database rebuilt from .beads/issues.jsonl" "$OUT2B"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 3: REFUSAL when the safeguard export fails ==="

REFUSE="$WORK/refuse"; mkdir -p "$REFUSE/.beads"
printf '{"id":"pre-existing"}\n' > "$REFUSE/.beads/issues.jsonl"
reset_state "0.47.1"
# BOTH writers must fail for "cannot write the ledger at all": the safeguard is
# a chain now (sync --flush-only, then export), so disabling only one leg leaves
# the other one succeeding and there is nothing to refuse.
printf 'no' > "$STATE/sync-ok"
printf '1' > "$STATE/export-rc"
OUT3=$(run_upgrader "0.47.1" "$REFUSE"); RC3=$?
assert_contains "installer-beads-upgrade 3.1: THE SAFETY PROPERTY — a failed export REFUSES the upgrade" \
    "Refusing to upgrade" "$OUT3"
assert_eq "installer-beads-upgrade 3.2: ...and the upgrade command never ran" "no" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_contains "installer-beads-upgrade 3.3: ...saying WHY, in terms of what would be stranded" \
    "cannot read a 0.47.x store" "$OUT3"
assert_eq "installer-beads-upgrade 3.4: ...and the INSTALL is refused too, exit 1 (bd is still below the floor)" \
    "1" "$RC3"
assert_contains "installer-beads-upgrade 3.5: ...saying no plugin file was written" \
    "No plugin file has been written" "$OUT3"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 4: no-ops ==="

CUR="$WORK/current"; mkdir -p "$CUR/.beads"
reset_state "$RECOMMENDED"
OUT4=$(run_upgrader "$RECOMMENDED" "$CUR")
assert_eq "installer-beads-upgrade 4.1: a bd already at the recommendation runs no upgrade" "no" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 4.2: ...and says nothing" "" "$(printf '%s' "$OUT4" | tr -d '[:space:]')"

# A NEWER bd must also be left alone — a naive string compare would "upgrade"
# 1.2.0 back down to the recommendation.
NEWER="$WORK/newer"; mkdir -p "$NEWER/.beads"
reset_state "9.9.9"
OUT4B=$(run_upgrader "9.9.9" "$NEWER")
assert_eq "installer-beads-upgrade 4.3: a NEWER bd is left alone (version compare, not string compare)" \
    "no" "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 4.4: ...and says nothing" "" "$(printf '%s' "$OUT4B" | tr -d '[:space:]')"

# THE SKIP FLAGS DO NOT ADMIT AN OLD BD (claude-workflow-plugin-ishe R5-F1).
# They used to return before the version was even compared, which let v5 install
# over bd 0.47.1 — 6965 files and exit 3, measured. They now only stop the
# opt-in upgrade from running. The harness's opt-in is ON here, so 4.6 also
# shows the flag beating an operator who set both.
SKIPD="$WORK/skipped"; mkdir -p "$SKIPD/.beads"
reset_state "0.47.1"
OUT5=$(SKIP_BEADS_UPGRADE=true run_upgrader "0.47.1" "$SKIPD"); RC5=$?
assert_eq "installer-beads-upgrade 4.5: --skip-beads-upgrade does NOT admit an old bd: the install is REFUSED, exit 1" \
    "1" "$RC5"
assert_eq "installer-beads-upgrade 4.6: ...and the opt-in upgrade still never ran" "no" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_contains "installer-beads-upgrade 4.7: ...and the refusal says the flag does not admit it" \
    "does not admit a bd below" "$OUT5"

SKIPE="$WORK/skipped-env"; mkdir -p "$SKIPE/.beads"
reset_state "0.47.1"
OUT5E=$(CWP_SKIP_BEADS_UPGRADE=1 run_upgrader "0.47.1" "$SKIPE"); RC5E=$?
assert_eq "installer-beads-upgrade 4.8: the environment form CWP_SKIP_BEADS_UPGRADE=1 is refused the same way, exit 1" \
    "1" "$RC5E"
assert_contains "installer-beads-upgrade 4.9: ...printing the refusal" "REFUSING to install" "$OUT5E"

# The default path: no opt-in at all. Refused, and nothing ran.
NOOPT="$WORK/no-opt-in"; mkdir -p "$NOOPT/.beads"
reset_state "0.47.1"
OUT5N=$(CWP_BEADS_UPGRADE='' run_upgrader "0.47.1" "$NOOPT"); RC5N=$?
assert_eq "installer-beads-upgrade 4.10: with no opt-in, an old bd is REFUSED, exit 1" "1" "$RC5N"
assert_contains "installer-beads-upgrade 4.11: ...saying no plugin file has been written (not \"nothing\": ishe R7-F2)" \
    "No plugin file has been written" "$OUT5N"
assert_eq "installer-beads-upgrade 4.12: ...and no upgrade command ran" "no" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
# THE PRINTED RE-RUN (claude-workflow-plugin-s229). The procedure is addressed
# to curl users, who have no local install.sh, so steps 3 and 4 must name the
# curl one-liner. installer-flags.test.sh 9.16 drives the whole installer down
# the stdin path, and carries the mutant that proves this check can fail.
assert_contains "installer-beads-upgrade 4.15: step 3 re-runs the installer with the curl one-liner" \
    "curl -fsSL https://raw.githubusercontent.com/preql-data/claude-workflow-plugin/main/install.sh | bash" "$OUT5N"
assert_contains "installer-beads-upgrade 4.16: ...and step 4's check is the same one-liner with --verify" \
    "/main/install.sh | bash -s -- --verify" "$OUT5N"
assert_eq "installer-beads-upgrade 4.17: ...and nothing in the refusal reports a missing command" "no" \
    "$(printf '%s\n' "$OUT5N" | grep -q 'command not found' && echo yes || echo no)"

# CONTROL: the same skip flag on a bd AT the floor is not refused and says
# nothing. Without this leg, 4.5-4.9 could pass because the flag itself had
# started refusing everything, rather than because the bd was below the floor.
SKIPC="$WORK/skipped-at-floor"; mkdir -p "$SKIPC/.beads"
reset_state "$RECOMMENDED"
OUT5C=$(SKIP_BEADS_UPGRADE=true run_upgrader "$RECOMMENDED" "$SKIPC"); RC5C=$?
assert_eq "installer-beads-upgrade 4.13: CONTROL — the skip flag on a bd AT the floor is not refused (exit 0)" \
    "0" "$RC5C"
assert_eq "installer-beads-upgrade 4.14: CONTROL — ...and says nothing" "" "$(printf '%s' "$OUT5C" | tr -d '[:space:]')"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 5: a failed opt-in upgrade REFUSES the install ==="

# Each of these used to return and let the install continue on the old bd
# ("Continuing on bd 0.47.1"), which is warning where the installer should
# refuse. They now end in the same refusal as never upgrading at all.
FAILU="$WORK/failed-upgrade"; mkdir -p "$FAILU/.beads"
printf '{"id":"pre-existing"}\n' > "$FAILU/.beads/issues.jsonl"
reset_state "0.47.1"
OUT6=$(BD_UPGRADE_COMMAND="false" run_upgrader "0.47.1" "$FAILU"); RC6=$?
assert_contains "installer-beads-upgrade 5.1: an offline/failed upgrade is reported" \
    "the Beads upgrade command failed" "$OUT6"
assert_contains "installer-beads-upgrade 5.2: ...with the manual command to run" \
    "Upgrade by hand" "$OUT6"
assert_eq "installer-beads-upgrade 5.3: ...and the install is REFUSED, exit 1, not continued on 0.47.1" \
    "1" "$RC6"
assert_eq "installer-beads-upgrade 5.4: ...so nothing says it is continuing" "no" \
    "$(printf '%s' "$OUT6" | grep -q 'Continuing on bd' && echo yes || echo no)"

# The version-did-not-move case: the command "succeeded" but bd is the same.
STUCK="$WORK/stuck"; mkdir -p "$STUCK/.beads"
printf '{"id":"pre-existing"}\n' > "$STUCK/.beads/issues.jsonl"
reset_state "0.47.1"
OUT7=$(BD_UPGRADE_COMMAND="true" run_upgrader "0.47.1" "$STUCK"); RC7=$?
assert_contains "installer-beads-upgrade 5.5: a no-op upgrade command does NOT migrate the database" \
    "Not migrating the database" "$OUT7"
assert_eq "installer-beads-upgrade 5.6: ...bootstrap was never called" "no" \
    "$(calls_contain "bootstrap" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 5.7: ...and the install is REFUSED, exit 1" "1" "$RC7"

# The swap happened but landed BELOW the floor: a changed binary is not a
# supported one.
LOWER="$WORK/still-below"; mkdir -p "$LOWER/.beads"
printf '{"id":"pre-existing"}\n' > "$LOWER/.beads/issues.jsonl"
reset_state "0.47.1"
OUT8=$(FAKE_NEW_VERSION="1.0.0" run_upgrader "0.47.1" "$LOWER"); RC8=$?
assert_eq "installer-beads-upgrade 5.8: precondition — the fake upgrade really did run" "yes" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_contains "installer-beads-upgrade 5.9: an upgrade that lands below the floor is named as such" \
    "still below $RECOMMENDED" "$OUT8"
assert_eq "installer-beads-upgrade 5.10: ...the install is REFUSED, exit 1" "1" "$RC8"
assert_eq "installer-beads-upgrade 5.11: ...and the database was not migrated (no bootstrap)" "no" \
    "$(calls_contain "bootstrap" && echo yes || echo no)"

# ---------------------------------------------------------------------------
echo ""
echo "=== Section 6: the safeguard must PRESERVE THE AUDIT TRAIL (R2-F1) ==="

# THE DEFECT THIS PINS. The safeguard originally wrote the pre-upgrade ledger
# with `bd export`, then bootstrapped 1.1.2 from it. On the exact versions being
# upgraded that is an audit-trail shredder: bd 0.47.1's `bd export` emits every
# ISSUE and DROPS EVERY COMMENT (974 -> 0 on this repo; re-measured for this fix
# as 3 -> 0 with no `comments` key at all, exit 0). Every approval record,
# rubric verdict, IMPLEMENTER identity and REVIEW-ARTIFACT in the target would
# be destroyed by a step whose entire purpose was to protect them.
#
# The original spec could not catch it because its fake bd modelled no comments
# and asserted only call ORDER and bootstrap. Record count is preserved by a
# comment-dropping exporter, so counting records proves nothing — these
# assertions count COMMENTS.

# 6a. The happy path: a bd whose comment-preserving writer works.
PRESERVE="$WORK/preserve"; mkdir -p "$PRESERVE/.beads"
reset_state "0.47.1"
printf '%s\n' "$DB_SEED" > "$PRESERVE/.beads/issues.jsonl"
assert_eq "installer-beads-upgrade 6.1: precondition — the target ledger carries 3 gate records" \
    "3" "$(ledger_comments "$PRESERVE/.beads/issues.jsonl")"
OUT6=$(run_upgrader "0.47.1" "$PRESERVE")
assert_contains "installer-beads-upgrade 6.2: the safeguard uses the comment-preserving writer" \
    "comment-preserving" "$OUT6"
assert_eq "installer-beads-upgrade 6.3: THE POINT — all 3 comments survive the safeguard" \
    "3" "$(ledger_comments "$PRESERVE/.beads/issues.jsonl")"
assert_contains "installer-beads-upgrade 6.4: ...and the QA-GATE APPROVED record is still there by name" \
    "QA-GATE APPROVED" "$(cat "$PRESERVE/.beads/issues.jsonl")"
assert_contains "installer-beads-upgrade 6.5: ...as is the REVIEW-ARTIFACT" \
    "REVIEW-ARTIFACT v1" "$(cat "$PRESERVE/.beads/issues.jsonl")"
assert_contains "installer-beads-upgrade 6.6: ...and the upgrade still completed" \
    "0.47.1 -> $RECOMMENDED" "$OUT6"
assert_eq "installer-beads-upgrade 6.7: no .pre-upgrade.bak is left behind on success" "no" \
    "$([ -f "$PRESERVE/.beads/issues.jsonl.pre-upgrade.bak" ] && echo yes || echo no)"

# 6b. THE REFUSAL. A bd whose only working writer is the comment-dropping
# `export` — precisely bd 0.47.1 in the state where `sync --flush-only`
# short-circuits (the 366.5 hash-match bug) or is unavailable. The upgrade must
# NOT proceed on a hollowed-out ledger.
SHRED="$WORK/shredder"; mkdir -p "$SHRED/.beads"
reset_state "0.47.1"
printf 'no' > "$STATE/sync-ok"                 # comment-preserving writer unavailable
printf 'yes' > "$STATE/export-drops-comments"  # ...leaving only the shredder
printf '%s\n' "$DB_SEED" > "$SHRED/.beads/issues.jsonl"
OUT6B=$(run_upgrader "0.47.1" "$SHRED"); RC6B=$?
assert_contains "installer-beads-upgrade 6.8: a comment-dropping exporter REFUSES the upgrade" \
    "REFUSING" "$OUT6B"
assert_eq "installer-beads-upgrade 6.8b: ...and the install, exit 1 (bd is still 0.47.1)" "1" "$RC6B"
assert_contains "installer-beads-upgrade 6.9: ...naming what would have been destroyed" \
    "QA audit trail" "$OUT6B"
assert_eq "installer-beads-upgrade 6.10: THE DATA-LOSS ASSERTION — the ledger is RESTORED with all 3 comments" \
    "3" "$(ledger_comments "$SHRED/.beads/issues.jsonl")"
assert_eq "installer-beads-upgrade 6.11: ...the binary was never swapped" "no" \
    "$(calls_contain "upgrade-ran" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 6.12: ...bootstrap never ran on the hollowed ledger" "no" \
    "$(calls_contain "bootstrap" && echo yes || echo no)"
assert_eq "installer-beads-upgrade 6.13: ...and no .bak litter is left in .beads/" "no" \
    "$([ -f "$SHRED/.beads/issues.jsonl.pre-upgrade.bak" ] && echo yes || echo no)"

# 6c. META — the fake bd's shredding leg must actually shred, or 6.8-6.13 would
# be asserting against a defect the harness cannot produce (which is exactly how
# the original spec passed while the bug shipped).
META_SHRED="$WORK/meta-shred/out.jsonl"; mkdir -p "$WORK/meta-shred"
reset_state "0.47.1"
( cd "$WORK/meta-shred" && env PATH="$WORK/bin:$PATH" STATE="$STATE" bd export -o "$META_SHRED" >/dev/null 2>&1 )
assert_eq "installer-beads-upgrade 6.14: META — the modelled 0.47 exporter really does drop every comment" \
    "0" "$(ledger_comments "$META_SHRED")"
assert_eq "installer-beads-upgrade 6.15: META — ...while preserving the record count (why counting records is blind)" \
    "2" "$(grep -c '"id"' "$META_SHRED" | tr -d ' ')"
