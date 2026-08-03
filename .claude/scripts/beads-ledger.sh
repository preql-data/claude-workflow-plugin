#!/bin/bash
# beads-ledger.sh — the ONE place that knows how to write and validate the
# Beads JSONL ledger (.beads/issues.jsonl).
#
# WHY THIS EXISTS (claude-workflow-plugin-fkm.1.1)
#   `bd sync` was REMOVED in bd 1.1.2. It was the plugin's only ledger-write
#   path: session-end.sh ran it, and the "Landing the Plane" protocol in
#   AGENTS.md put it between `git pull --rebase` and `git push`. On 1.1.2 that
#   command does not exist, so every one of those call sites was a no-op that
#   logged a failure.
#
#   The obvious replacements do not work either, and both were MEASURED rather
#   than assumed:
#
#     - bd's own git pre-commit hook. `.git/hooks/pre-commit` is a thin shim
#       delegating to `bd hooks run pre-commit`. On 1.1.2 that subcommand still
#       exists and exits 0 but does NOT export: with a provably stale ledger
#       (288 records on disk, 289 in the DB) the JSONL hash did not move. Every
#       commit records a stale ledger behind a green hook.
#     - `bd config set export.auto true`. This gates PER-WRITE export only, not
#       the hook. It costs a 4.4MB rewrite on every single DB write and still
#       leaves commit time unguarded. Deliberately NOT enabled.
#
#   The ledger is not a nicety. It is the portable ground truth: a fresh clone
#   recovers the issue database from it, and .beads/embeddeddolt/ is gitignored
#   machine-local state. A silently stale ledger is silent data loss that only
#   surfaces at the next clone.
#
# THE STALENESS PREDICATE, AND WHAT IT COSTS
#   `check` exports the DB to a temp file and compares its sha256 against the
#   on-disk ledger. That is a FULL export, and it is the only honest predicate
#   available. The cheap alternatives were investigated and rejected:
#
#     - `bd sql 'SELECT COUNT(*), MAX(updated_at) ...'` would be ideal, but
#       1.1.2 refuses it outright: "Error: 'bd sql' is not yet supported in
#       embedded mode", and embedded is the default backend.
#     - File mtimes are a proxy that can be wrong in both directions (a write
#       that changes nothing bumps mtime; a restored backup does not).
#     - Record COUNT alone misses edits, and issues.jsonl carries comment
#       BODIES (200 of this repo's 277 records have a comments key), so any
#       count-based proxy is blind to the audit trail the QA gate lives in.
#
#   The price turns out not to matter: a full export is ~0.44-0.76s against
#   this repo's 4.4MB / 289-record ledger, versus ~0.26s for `bd info` and
#   ~0.35s for a single `bd show`. bd's process startup dominates; the
#   serialization itself is ~0.2-0.5s. There is no proxy worth its wrongness
#   at that price.
#
#   The comparison is SOUND because `bd export` is byte-deterministic: three
#   consecutive exports of an unchanged DB produced an identical sha256. If a
#   future bd embeds a timestamp or randomises ordering, `check` would report
#   permanent staleness — bd-compat.sh pins the determinism so that shows up
#   there as a named failure rather than as mystery churn here.
#
# DIRECTION IS PART OF THE PREDICATE (R1-F1)
#   A hash comparison says the two DIFFER. It cannot say which one is ahead,
#   and the first version of this script resolved every difference as "the
#   database wins" — because the failure it was built for (SessionEnd skipped)
#   always has that direction. Three ordinary states have the opposite one:
#   a fresh clone whose `bd init` leaves an empty database beside a populated
#   committed ledger; any second machine after `git pull`; a restored backup.
#   In all three, exporting DELETES records that exist only in the ledger, and
#   bd 1.1.2 never auto-imports so nothing else notices. `classify()` therefore
#   reports a direction. That direction used to gate an automatic write, which
#   is the story the next section tells; today it only decides which remedy the
#   operator is told to run.
#
# WHY THERE IS NO AUTOMATIC REPAIR (the R4-F1 decision)
#   This script used to expose `refresh`, which SessionStart and SessionEnd ran
#   unattended: classify the divergence, and write the ledger whenever the
#   database looked like the safe side. Five defects came out of that one idea,
#   each found only after the previous fix shipped:
#
#     R1-F1  direction-blind        every difference resolved as "database wins"
#     R2-F2  unmodeled differences  fell through to the destructive branch
#     R3-F1  rule ORDER             a newer timestamp outranked comment evidence
#     R4-F1  count vs SET          equal/greater counts over DISJOINT comment
#                                   sets still "proved" db-ahead
#
#   Every member was the same mistake: an evidence rule whose claim was WEAKER
#   than the safety property it authorised. Newer-record is not loses-nothing.
#   More-comments is not superset. Count is not set. Each fix strengthened one
#   rule and left the shape intact, so the family kept producing members.
#
#   So the mechanism is gone rather than guarded again. Nothing here writes the
#   ledger without an explicit operator `--apply`. classify() survives as the
#   DETECTOR — it is genuinely good at saying "these two differ and here is
#   which way it looks" — and detection is all it is now allowed to do.
#
#   Precedent: claude-workflow-plugin-gl6 resolved the same way after six review
#   rounds and thirteen findings — "Resolved by SCOPE REDUCTION: the 103-line
#   automated sweep was declined in favour of automate-the-read /
#   hand-do-the-write / verify-with-the-real-parser." Same shape, same remedy:
#   keep the reading, decline the automatic writing.
#
# SUBCOMMANDS
#   check      Read-only. Never writes the ledger, never writes into .beads/.
#              THE ONLY SUBCOMMAND ANY HOOK RUNS. exit 0 = fresh,
#              1 = differs/DATABASE ahead, 2 = undetermined (no bd / no .beads /
#              export failed), 3 = differs/LEDGER ahead or indeterminate.
#              Undetermined is deliberately NOT "fresh".
#   reconcile  `bd import` then `bd export`, in that order, so the database ends
#              up holding the union and nothing is discarded. Safe in EVERY
#              direction, which is why it — not `export` — is what the release
#              protocol and every remediation message name. DRY RUN unless
#              --apply. Never invoked by a hook.
#   export     Unconditional one-way rewrite from the database. Direction-blind
#              BY CONSTRUCTION: it discards anything only the ledger has. DRY
#              RUN unless --apply. Kept because "the database is authoritative,
#              overwrite the file" is a real operator intent, but it is never
#              the automatic answer to a divergence.
#
#   DRY-RUN IS THE DEFAULT for both writers, matching worktree-sweep.sh. A
#   destructive default is how a convenience becomes an accident.
#
# FLAGS
#   --json    Emit a one-line JSON envelope on stdout instead of text.
#   --quiet   Suppress stdout entirely; communicate via exit code only.
#
# NEVER blocks a hook: every failure path exits with a code the caller chooses
# to ignore, and no path calls `exit 1` on an operational hiccup that isn't
# genuinely staleness.

set -u

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
BEADS_DIR="$PROJECT_DIR/.beads"

ARG_JSON=0
ARG_QUIET=0
ARG_APPLY=0
SUBCOMMAND=""

# ---------------------------------------------------------------------------
# Helpers

# sha256 of a file, portable across macOS (shasum) and Linux (sha256sum).
# Same two-branch idiom impact-report.sh uses; empty output on failure.
sha256_file() {
    local f="$1"
    [ -f "$f" ] || { printf ''; return 0; }
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$f" 2>/dev/null | awk '{print $1}'
    else
        printf ''
    fi
}

# Record count of a file, or 0 when it does not exist. A bare
# `wc -l < "$missing"` makes the SHELL (not wc) write "No such file or
# directory" to stderr, which no `2>/dev/null` on the command can suppress —
# and a hook that leaks that line looks broken on the one path where the ledger
# is most legitimately absent.
count_lines() {
    local f="$1"
    [ -f "$f" ] || { printf '0'; return 0; }
    wc -l < "$f" 2>/dev/null | tr -d ' '
}

# The ledger path. bd's own default is .beads/issues.jsonl and both a fresh
# 1.1.2 `bd init` and a 0.47.x-migrated tree land there. A tree migrated from
# 0.47.x additionally carries `jsonl_export` in .beads/metadata.json; a FRESH
# 1.1.2 init does NOT write that key, so it is read opportunistically and never
# required. BEADS_LEDGER_PATH overrides both (used by the component specs).
resolve_ledger() {
    if [ -n "${BEADS_LEDGER_PATH:-}" ]; then
        printf '%s' "$BEADS_LEDGER_PATH"
        return 0
    fi
    local name=""
    if [ -f "$BEADS_DIR/metadata.json" ] && command -v jq >/dev/null 2>&1; then
        name=$(jq -r '.jsonl_export // empty' "$BEADS_DIR/metadata.json" 2>/dev/null || echo "")
    fi
    [ -n "$name" ] || name="issues.jsonl"
    printf '%s/%s' "$BEADS_DIR" "$name"
}

# emit <ok> <status> <exit-code> <observations>
#
# THE STATUS IS A CONSUMED CONTRACT, not a log string. session-start.sh reads
# `.status` out of the --json envelope and branches on it BY NAME: `stale` and
# `ledger-ahead`/`indeterminate` render two different operator warnings (their
# remedies are opposites — export vs import), and `failed`/`undetermined` are
# what it appends to sync-errors.log. A status this list omits is a branch
# nobody knew to write, so the list is the full emitted set, per subcommand:
#
#   check      fresh          the ledger matches the database                  0
#              stale          they differ and the DATABASE is ahead            1
#              ledger-ahead   they differ and the LEDGER is ahead              3
#              indeterminate  they differ, direction NOT provable              3
#              undetermined   the question could not be asked at all           2
#   reconcile  dry-run        the default: reported, changed nothing           0
#              reconciled     imported, then re-exported the union             0
#              undetermined   no bd, no .beads/, or no ledger to import from   2
#              failed         `bd import` or the re-export failed              1
#   export     dry-run        the default: reported, changed nothing           0
#              exported       the ledger was overwritten from the database     0
#              undetermined   no bd or no .beads/                              2
#              failed         `bd export` failed                               1
#
# The one place `ok` carries information `status` does not: `export --dry-run`
# emits ok:false when the classifier says the overwrite would DISCARD
# ledger-only records, and ok:true when it would not. Same status, same exit 0,
# because in both cases nothing was written.
#
# `refreshed` was the automatic-repair status; it went with cmd_refresh (R4-F1)
# and nothing emits it. It stayed in this list for a full review round after the
# subcommand was deleted, which is how a stale contract reads: complete.
emit() {
    local ok="$1" status="$2" code="$3" obs="$4"
    if [ "$ARG_QUIET" = "1" ]; then
        exit "$code"
    fi
    if [ "$ARG_JSON" = "1" ]; then
        if command -v jq >/dev/null 2>&1; then
            jq -nc --argjson ok "$ok" --arg status "$status" --arg ledger "$LEDGER" \
                --arg obs "$obs" \
                '{ok:$ok, status:$status, ledger:$ledger, observations:$obs}'
        else
            # jq-less hosts still get a parseable envelope for the common fields.
            printf '{"ok":%s,"status":"%s","observations":"jq unavailable; %s"}\n' \
                "$ok" "$status" "$(printf '%s' "$obs" | sed 's/[\\"]//g')"
        fi
    else
        printf '%s: %s\n' "$status" "$obs"
    fi
    exit "$code"
}

# Preconditions shared by every subcommand. Returns non-zero when the ledger
# question cannot be asked at all.
preflight() {
    command -v bd >/dev/null 2>&1 || return 1
    [ -d "$BEADS_DIR" ] || return 1
    return 0
}

# export_to <dest> — run bd's exporter. Returns bd's exit code.
#
# `--force` was REMOVED in bd 1.1.2; plain `bd export -o <file>` always rewrites
# the destination from the DB, which is exactly the 366.5 fallback primitive the
# old flag provided. The `-o` form is accepted by BOTH 0.47.x and 1.1.2, so no
# version-tolerant chain is needed here — unlike the `--include-comments` reads,
# where the flag genuinely does not exist on the older bd.
export_to() {
    local dest="$1"
    ( cd "$PROJECT_DIR" 2>/dev/null || exit 1
      bd export -o "$dest" >/dev/null 2>&1 )
}

# record_meta <jsonl> — one row per record, sorted by id:
#   id <TAB> comment_count <TAB> updated_at <TAB> canonical_json
# The serialised record is what lets a shared record be proven IDENTICAL rather
# than merely "same count, same timestamp". jq -c never emits a literal tab, so
# the JSON can ride in a TSV field safely.
#
# NOT canonicalised (R3-F2): this is plain `tojson`, which preserves key order,
# so two semantically equal records serialised with different key orders would
# NOT compare equal here. That is deliberate rather than an oversight — both
# sides are produced by the same `bd export` serializer, so the case does not
# arise in practice, and when it does the only consequence is that the identity
# leg misses and the record falls through to the guard and timestamp rules,
# which refuse. Failing towards refusal is the safe direction. An earlier
# version of this comment claimed `jq -S` sorted-key canonicalisation that the
# code never performed; sorting keys recursively would remove a false-refusal
# that has never been observed, at the cost of real complexity in the one
# function whose correctness the whole refusal contract rests on.
record_meta() {
    [ -f "$1" ] || return 0
    jq -rR 'fromjson? | select(.id != null)
            | [ .id, ((.comments // []) | length), (.updated_at // ""), (. | tojson) ]
            | @tsv' "$1" 2>/dev/null | sort -k1,1
}

# parse_failures <jsonl> — count of NON-BLANK lines that do not yield a JSON
# object carrying an id. Any such line was silently skipped by record_meta, so
# the comparison would be running on a partial view of the file — a git
# conflict marker, a truncated write, a half-flushed export. Classifying on a
# partial view is exactly the "cannot classify" case, so this forces a refusal
# instead of a confident wrong answer.
parse_failures() {
    [ -f "$1" ] || { printf '0'; return 0; }
    jq -rR 'select((. | gsub("^[[:space:]]+|[[:space:]]+$"; "")) != "")
            | if ((fromjson? | objects | .id?) // null) == null then "bad" else empty end' \
        "$1" 2>/dev/null | grep -c . | tr -d ' '
}

# classify <ledger> <fresh-db-export> — prints "<verdict><TAB><detail>" where
# verdict is one of:
#   db-ahead      POSITIVELY established: exporting is safe
#   ledger-ahead  positively established the other way: exporting would DESTROY
#   indeterminate cannot prove either — treated exactly like ledger-ahead
#
# THE DEFAULT IS THE WHOLE FIX (R2-F2). The first direction-aware version
# enumerated three ledger-ahead signals and fell through to db-ahead, so
# anything it did not model — a label-only difference, a dependency-only
# difference, comments that differ in CONTENT at equal count, two writes inside
# the same one-second `updated_at` tick, a line that failed to parse — resolved
# to "safe to overwrite". Absence of evidence for ledger-ahead is not evidence
# of db-ahead, and the cost of that confusion is unrecoverable.
#
# So db-ahead now requires POSITIVE evidence for EVERY shared record. A record
# is proven database-ahead when any of these holds:
#   * it is canonically IDENTICAL on both sides (nothing to lose);
#   * the database's updated_at is strictly NEWER (a real edit);
#   * the database has MORE comments (comments are append-only, and
#     `bd comments add` does NOT bump updated_at — measured — so without this
#     leg the commonest legitimate case, a session appending gate records,
#     would refuse and the mechanism would be useless).
# Anything else is indeterminate and refuses.
classify() {
    local ledger="$1" fresh="$2"

    # Tooling gate. Without jq every downstream read returns empty, the id sets
    # both look empty, and the old code concluded db-ahead and overwrote a
    # ledger-ahead ledger while reporting "refreshed (2 -> 2 records)". A
    # missing tool is the definition of cannot-classify.
    if ! command -v jq >/dev/null 2>&1; then
        printf 'indeterminate\t%s' "jq is not on PATH, so the ledger cannot be compared record by record"
        return 0
    fi

    # Integrity gate: a partial view cannot support a confident verdict.
    local lbad fbad
    lbad=$(parse_failures "$ledger")
    fbad=$(parse_failures "$fresh")
    if [ "${lbad:-0}" -gt 0 ] 2>/dev/null; then
        printf 'indeterminate\t%s' "${lbad} line(s) in the ledger are not parseable records (conflict markers? truncated write?), so it cannot be compared safely"
        return 0
    fi
    if [ "${fbad:-0}" -gt 0 ] 2>/dev/null; then
        printf 'indeterminate\t%s' "${fbad} line(s) of the database export are not parseable records, so the comparison would run on a partial view"
        return 0
    fi

    local lm fm
    lm=$(mktemp -t bd-ledger-lm.XXXXXX 2>/dev/null) || { printf 'indeterminate\t%s' "could not create a temp file for the comparison"; return 0; }
    fm=$(mktemp -t bd-ledger-fm.XXXXXX 2>/dev/null) || { rm -f "$lm"; printf 'indeterminate\t%s' "could not create a temp file for the comparison"; return 0; }
    record_meta "$ledger" > "$lm"
    record_meta "$fresh"  > "$fm"

    # Records the database has never seen. Unambiguous, and the loudest case.
    local ledger_only
    ledger_only=$(comm -23 <(cut -f1 "$lm") <(cut -f1 "$fm") 2>/dev/null | head -5 | tr '\n' ' ')
    if [ -n "$(printf '%s' "$ledger_only" | tr -d '[:space:]')" ]; then
        printf 'ledger-ahead\t%s' "record(s) present in the ledger and MISSING from the database: ${ledger_only}"
        rm -f "$lm" "$fm"; return 0
    fi

    # Every shared record must carry positive database-ahead evidence.
    # join fields: 1=id  2,3,4=ledger(count,updated,json)  5,6,7=db(count,updated,json)
    #
    # RULE ORDER IS LOAD-BEARING (R3-F1). The comment-asymmetry GUARD must run
    # BEFORE the timestamp rule, not after it as one more way to prove
    # db-ahead. The legs prove the database record is NEWER; for append-only
    # sub-records that is not the same claim as "loses nothing". `bd comments
    # add` does not bump the parent's updated_at (measured), so a teammate's
    # comment arriving via `git pull` leaves the ledger richer while ANY later
    # local edit makes the database's updated_at newer — and with the timestamp
    # rule first, that state short-circuited to "proven db-ahead" and the
    # automatic refresh destroyed the pulled record, reporting
    # `refreshed (1 -> 1 records)`. Identical record count, so nothing looked
    # lost. Reproduced end to end before this fix.
    #
    # So: more comments in the ledger than in the database is, on its own,
    # disqualifying. No later leg may overturn it.
    local unproven
    unproven=$(join -t "$(printf '\t')" -j 1 "$lm" "$fm" 2>/dev/null \
        | awk -F'\t' '
            $4 == $7            { next }               # canonically identical
            ($2 + 0) > ($5 + 0) { print $1; next }     # GUARD: ledger holds comments the DB lacks
            ($6 != "" && $3 != "" && $6 > $3) { next } # database strictly newer
            ($5 + 0) > ($2 + 0) { next }               # database has more comments
            { print $1 }
          ' | head -5 | tr '\n' ' ')
    if [ -n "$(printf '%s' "$unproven" | tr -d '[:space:]')" ]; then
        printf 'indeterminate\t%s' "record(s) differ with no proof the database loses nothing — either the LEDGER holds comments the database lacks (a pulled gate record), or the two differ with no evidence of direction at all (a label, a dependency, edited comment text): ${unproven}"
        rm -f "$lm" "$fm"; return 0
    fi
    rm -f "$lm" "$fm"
    printf 'db-ahead\t%s' "every ledger record is accounted for in the database, which is the newer side"
}

# mk_fresh_export — a temp file holding the database's current export, for the
# dry-run reports. Prints an empty path on failure; classify() treats a missing
# side as indeterminate, which is the correct dry-run answer anyway.
mk_fresh_export() {
    local t
    t=$(mktemp -t bd-ledger-dry.XXXXXX 2>/dev/null) || { printf ''; return 0; }
    export_to "$t" || true
    printf '%s' "$t"
}

# ---------------------------------------------------------------------------
# Subcommands

cmd_check() {
    if ! preflight; then
        emit false undetermined 2 "bd not on PATH or $BEADS_DIR missing; ledger staleness cannot be determined"
    fi
    local tmp
    tmp=$(mktemp -t bd-ledger.XXXXXX 2>/dev/null) || tmp=""
    if [ -z "$tmp" ]; then
        emit false undetermined 2 "could not create a temp file for the comparison export"
    fi
    # shellcheck disable=SC2064  # expand $tmp now, on purpose
    trap "rm -f '$tmp' 2>/dev/null || true" EXIT
    if ! export_to "$tmp"; then
        emit false undetermined 2 "bd export failed; ledger staleness cannot be determined"
    fi
    local fresh_sha disk_sha
    fresh_sha=$(sha256_file "$tmp")
    disk_sha=$(sha256_file "$LEDGER")
    if [ -z "$fresh_sha" ]; then
        emit false undetermined 2 "no sha256 tool (shasum/sha256sum) on PATH; cannot compare"
    fi
    if [ ! -f "$LEDGER" ]; then
        # A virgin `bd init` creates .beads/ WITHOUT an issues.jsonl — bd only
        # writes one once there is something to write. So "no ledger" is only
        # staleness when the database actually holds records; an empty DB and
        # an absent ledger agree perfectly (a clone recovers zero issues, which
        # is correct). Calling that stale would fail the doctor on every
        # freshly-installed target.
        if [ "$(count_lines "$tmp")" = "0" ]; then
            emit true fresh 0 "no ledger yet and no records in the database — nothing to export"
        fi
        emit false stale 1 "the ledger $LEDGER does not exist; the database has $(count_lines "$tmp") record(s) that no clone could recover"
    fi
    if [ "$fresh_sha" = "$disk_sha" ]; then
        emit true fresh 0 "the ledger matches the database"
    fi
    # DIFFERS. Which side is ahead decides whether exporting is a repair or a
    # deletion, so say "differs" and then name the direction — never assert a
    # direction the hash alone cannot know (R1-F1).
    local dn fn verdict direction detail
    dn=$(count_lines "$LEDGER")
    fn=$(count_lines "$tmp")
    verdict=$(classify "$LEDGER" "$tmp")
    direction=${verdict%%	*}
    detail=${verdict#*	}
    if [ "$direction" = "ledger-ahead" ]; then
        emit false ledger-ahead 3 "the ledger DIFFERS from the database and the LEDGER IS AHEAD: on disk ${dn:-?} record(s), database ${fn:-?}. ${detail}. Exporting would DESTROY them — import first: bd import $LEDGER"
    fi
    # Cannot-classify refuses on the SAME exit code as ledger-ahead: the caller
    # must treat "I could not prove the database is ahead" identically to "the
    # ledger is ahead", because the only safe action is the same one.
    if [ "$direction" = "indeterminate" ]; then
        emit false indeterminate 3 "the ledger DIFFERS from the database and the direction CANNOT BE DETERMINED: on disk ${dn:-?} record(s), database ${fn:-?}. ${detail}. Refusing to guess — reconcile keeps both sides: bash .claude/scripts/beads-ledger.sh reconcile"
    fi
    emit false stale 1 "the ledger DIFFERS from the database and the database is ahead: on disk ${dn:-?} record(s), database ${fn:-?}. Nothing repairs this automatically — run: bash .claude/scripts/beads-ledger.sh reconcile --apply"
}

# reconcile — import the ledger into the DB, then export the union back out.
#
# THE ORDER IS THE POINT. `bd import` then `bd export` yields the union and
# loses nothing. The reverse order destroys every ledger-only record before
# the import can see it — which is exactly the R1-F1 bug, and exactly what an
# operator staring at a "ledger differs" message is most likely to type. Having
# a single command means nobody has to get that ordering right under pressure.
#
# DELIBERATELY MANUAL: no hook calls this. It mutates the database, and the
# divergence it resolves can also mean a genuine conflict (both sides moved),
# which a human should look at. Every automatic surface stops at NAMING a
# remedy: `check`'s own messages, the doctor's `beads_ledger` check and
# session-start's warnings each print a command for the operator to run, and run
# none of it. Section 11 of the component spec pins that, with a META that
# plants the auto-repair call back into SessionStart and shows the probe bites.
cmd_reconcile() {
    if ! preflight; then
        emit false undetermined 2 "bd not on PATH or $BEADS_DIR missing; nothing reconciled"
    fi
    if [ ! -f "$LEDGER" ]; then
        emit false undetermined 2 "no ledger at $LEDGER to reconcile from"
    fi
    local before_db
    before_db=$(count_lines "$LEDGER")
    # DRY RUN unless --apply (worktree-sweep.sh's convention). Report the
    # divergence this would resolve and change nothing.
    if [ "$ARG_APPLY" != "1" ]; then
        local v d
        v=$(classify "$LEDGER" "$(mk_fresh_export)")
        d=${v#*	}
        emit true dry-run 0 "DRY RUN — nothing changed. ${d}. Re-run with --apply to import $LEDGER into the database and re-export the union (${before_db:-0} record(s) on disk now); nothing would be discarded from either side."
    fi
    if ! ( cd "$PROJECT_DIR" 2>/dev/null && bd import "$LEDGER" >/dev/null 2>&1 ); then
        emit false failed 1 "bd import $LEDGER failed; the ledger is UNCHANGED (nothing was destroyed)"
    fi
    if ! export_to "$LEDGER"; then
        emit false failed 1 "the import succeeded but the re-export failed; the database now holds the union — re-run: bd export -o $LEDGER"
    fi
    local after
    after=$(count_lines "$LEDGER")
    emit true reconciled 0 "imported $LEDGER into the database and re-exported the union (${before_db:-0} -> ${after:-?} records); nothing was discarded"
}

cmd_export() {
    if ! preflight; then
        emit false undetermined 2 "bd not on PATH or $BEADS_DIR missing; nothing exported"
    fi
    # DRY RUN unless --apply. This subcommand is the direction-BLIND one, so its
    # dry run names what it would discard rather than just what it would write.
    if [ "$ARG_APPLY" != "1" ]; then
        local v d n
        v=$(classify "$LEDGER" "$(mk_fresh_export)")
        d=${v%%	*}
        n=$(count_lines "$LEDGER")
        if [ "$d" != "db-ahead" ] && [ "$d" != "fresh" ]; then
            emit false dry-run 0 "DRY RUN — nothing changed. This would OVERWRITE $LEDGER (${n:-0} record(s)) from the database, and the two sides do NOT agree in that direction, so records only in the ledger WOULD BE LOST. Use reconcile --apply instead, which keeps both sides."
        fi
        emit true dry-run 0 "DRY RUN — nothing changed. Re-run with --apply to overwrite $LEDGER (${n:-0} record(s)) from the database."
    fi
    if ! export_to "$LEDGER"; then
        emit false failed 1 "bd export -o $LEDGER failed"
    fi
    local n
    n=$(count_lines "$LEDGER")
    emit true exported 0 "exported ${n:-?} record(s) to $LEDGER"
}

usage() {
    cat <<'EOF'
Usage: beads-ledger.sh <check|export|reconcile> [--apply] [--json] [--quiet]

  check      Read-only divergence detector, WITH DIRECTION. This is the only
             subcommand any hook runs, and it never writes.
             0=fresh  1=differs, database ahead  2=undetermined  3=differs, LEDGER ahead
  reconcile  `bd import` then `bd export`, in that order, so the database ends up
             holding the union and nothing is discarded. THE FIX for any
             divergence — fresh clone, post-`git pull`, restored backup.
  export     Unconditional one-way rewrite from the database. Direction-blind by
             construction: it DISCARDS anything only the ledger has. Prefer
             reconcile unless you know the database is authoritative.

  --apply    Required by `reconcile` and `export`. WITHOUT IT THEY ONLY REPORT
             what they would do and change nothing — the same convention
             worktree-sweep.sh uses, and for the same reason.

There is deliberately no automatic-repair subcommand. See the header.

The staleness predicate is a full `bd export` to a temp file plus a sha256
compare. That is deliberate: `bd sql` is unavailable in embedded mode and every
cheaper proxy can be wrong. It costs ~0.5s, which is about what any single bd
invocation costs.
EOF
}

# ---------------------------------------------------------------------------
# Main

while [ $# -gt 0 ]; do
    case "$1" in
        check|export|reconcile)
            [ -z "$SUBCOMMAND" ] || { printf 'beads-ledger.sh: more than one subcommand given\n' >&2; exit 2; }
            SUBCOMMAND="$1"; shift ;;
        --apply) ARG_APPLY=1; shift ;;
        --json)  ARG_JSON=1; shift ;;
        --quiet) ARG_QUIET=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'beads-ledger.sh: unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

LEDGER=$(resolve_ledger)

case "$SUBCOMMAND" in
    check)   cmd_check ;;
    export)  cmd_export ;;
    reconcile) cmd_reconcile ;;
    "")      usage >&2; exit 2 ;;
esac
