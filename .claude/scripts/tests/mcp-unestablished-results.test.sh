#!/bin/bash
# mcp-unestablished-results.test.sh — claude-workflow-plugin-rmz + fkm.1.18.
#
# ONE RULE, TWO DEFECTS: a bd-mcp tool must not report a result it did not
# establish. Both bugs this spec guards are instances of it, and they were
# fixed as instances of it rather than as two unrelated patches.
#
#   rmz       bd 1.1.2 `create --parent P` COPIES P's labels onto the new
#             issue. A sub-task filed under an approved parent is born carrying
#             qa-approved — a label asserting a review that never happened —
#             and the inheritance is transitive, so one approved ancestor
#             contaminates a whole decomposition subtree. bd_create.js now
#             passes --no-inherit-labels AND independently audits the labels bd
#             echoes back against the ones the caller asked for.
#   fkm.1.18  bd_list_comments answered {"ok":true,...,"comments":[]} on a task
#             carrying 76 comments, because bd 1.1.2 stopped inlining .comments
#             and `task.comments || []` turns an unreadable source into a
#             confident zero. The tool now cross-checks against bd's own
#             comment_count and REFUSES rather than reporting an empty result
#             it cannot establish.
#
# WHY THIS SPEC LIVES HERE AND NOT IN .claude/mcp/bd-mcp/tests/
# -------------------------------------------------------------
# That `node --test` suite is ORPHANED: run-tests.sh discovers `*.sh` only, the
# component runner drives hook scripts, and the L3 job runs vitest under
# .claude/tests/e2e. No tier invokes it. Measured while writing this spec: it
# runs 29 tests, 28 pass and 1 fails (the qa-gate lifecycle leg, which predates
# approve's completion-record requirement) — a red test that has been red with
# nobody to see it. A control added there would not run, and a control that does
# not run is exactly the failure mode both these bugs are.
#
# WHAT MAKES THESE CONTROLS NON-VACUOUS
# -------------------------------------
# Every guard is proved by MUTATION, never by grepping the shipped file for the
# text of its own fix:
#   * each mutant is built in a throwaway COPY of src/ and its file hash is
#     asserted to differ from the shipped one, so a sed that silently matched
#     nothing cannot pass as a mutation;
#   * each mutant is then DRIVEN, and asserted to fail in the specific way the
#     guard prevents (a child born qa-approved; a success response asserting
#     zero comments) rather than merely "differently";
#   * a restore control re-drives the SHIPPED tree afterwards, so a mutation
#     that leaked into the real source would fail the run.
# Anchors are text, never line numbers.
#
# THE bd SIMULATOR, and why sections 1-2 do not need a real bd
# ------------------------------------------------------------
# CI has no bd (BD_SHIM_ONLY=1), so a spec that needed one would be a skip in
# the only environment that runs on every push. Sections 1-2 therefore run
# against a PATH shim that reproduces the two measured bd behaviours this fix
# turns on — parent-label union on create, and comment_count-without-bodies on
# show. Section 3 then VALIDATES THE SIMULATOR against the real bd when one is
# present, so the CI-runnable legs rest on a model that has been checked rather
# than assumed. Only section 3 skips.
#
# MEASURED FACTS THIS SPEC ENCODES (bd 1.1.2, this repo's ledger, 342 issues):
#   * `bd show --json --include-comments` omits the `comments` KEY entirely on a
#     zero-comment task — 117 of 342. So key-presence cannot be the
#     empty-vs-unavailable discriminator; comment_count is.
#   * comment_count was present on 342/342 and equalled comments.length on
#     342/342.
#   * `bd create --json` omits the `labels` key when an issue has none.
#   * `bd update <child> --parent <P>` does NOT copy labels — only create does.

set -u

PASS=0
FAIL=0
FAILED_TESTS=()
KEEP_FIXTURE="${KEEP_FIXTURE:-0}"

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

assert_ne() {
    local name="$1" unexpected="$2" actual="$3"
    if [ "$unexpected" != "$actual" ]; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    must differ from: %s\n' "$name" "$unexpected"
    fi
}

assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        PASS=$((PASS + 1))
        printf '  PASS: %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("$name")
        printf '  FAIL: %s\n    needle:   %s\n    haystack: %s\n' \
            "$name" "$needle" "$haystack"
    fi
}

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
MCP_ROOT="$PROJECT_DIR/.claude/mcp/bd-mcp"

if ! command -v node >/dev/null 2>&1; then
    echo "SKIPPED: mcp-unestablished-results.test.sh (node not on PATH; bd-mcp is a Node MCP server)"
    exit 0
fi
if [ ! -d "$MCP_ROOT/node_modules" ]; then
    echo "SKIPPED: mcp-unestablished-results.test.sh (bd-mcp node_modules absent; run 'npm ci' in $MCP_ROOT)"
    exit 0
fi

FIXTURE=$(mktemp -d -t mcp-unestab.XXXXXX)
# shellcheck disable=SC2329  # invoked via trap.
cleanup() {
    if [ "$KEEP_FIXTURE" = "1" ]; then
        printf '\nFixture kept at: %s\n' "$FIXTURE"
    else
        rm -rf "$FIXTURE"
    fi
}
trap cleanup EXIT

mkdir -p "$FIXTURE/mutants" "$FIXTURE/bin" "$FIXTURE/simstate" "$FIXTURE/.beads"

# ---------------------------------------------------------------------------
# mk_variant <name> — a throwaway copy of the shipped src/ that can be mutated.
#
# node_modules is SYMLINKED rather than copied so `zod` resolves by the normal
# upward walk from the variant's own tree, at zero copy cost.
mk_variant() {
    local dir="$FIXTURE/mutants/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp -R "$MCP_ROOT/src" "$dir/src"
    ln -s "$MCP_ROOT/node_modules" "$dir/node_modules"
    printf '%s' "$dir"
}

# mutate <variant-dir> <relative-file> <sed-expr> <label>
# Applies the edit and PROVES it landed by comparing file hashes. A sed that
# matched nothing is a silently vacuous mutant, which is the one outcome that
# would make every downstream assertion meaningless.
mutate() {
    local dir="$1" rel="$2" expr="$3" label="$4"
    local f="$dir/$rel" before after
    before=$(shasum "$f" | awk '{print $1}')
    sed -i.bak "$expr" "$f"
    rm -f "$f.bak"
    after=$(shasum "$f" | awk '{print $1}')
    assert_ne "NON-VACUITY: mutation '$label' actually changed $rel" "$before" "$after"
}

# ---------------------------------------------------------------------------
# The driver. Imports the tools from a given src root and runs one scenario,
# emitting KEY=VALUE lines. Kept in the fixture so it can point at either the
# shipped tree or a mutant.
cat > "$FIXTURE/drive.mjs" <<'DRIVER'
const [root, scenario, ...rest] = process.argv.slice(2);
const emit = (k, v) => console.log(`${k}=${v}`);

if (scenario === 'resolve-comments') {
    // Pure-function discriminator table. No bd involved at all.
    const { resolveComments } = await import(`${root}/src/lib/exec-bd.js`);
    const cases = {
        // The genuine-zero shape bd 1.1.2 actually emits: count 0, KEY ABSENT.
        genuine_zero_key_absent: { comment_count: 0 },
        genuine_zero_empty_array: { comment_count: 0, comments: [] },
        healthy: { comment_count: 2, comments: [{ id: 1 }, { id: 2 }] },
        // The fkm.1.18 shape: the count says there are comments, none arrived.
        unavailable_bodies_missing: { comment_count: 76 },
        unavailable_truncated: { comment_count: 76, comments: [{ id: 1 }] },
        // A bd too old to publish the count, but which inlines the bodies.
        no_witness_with_bodies: { comments: [{ id: 1 }] },
        no_witness_nothing: {},
    };
    for (const [name, task] of Object.entries(cases)) {
        emit(name, resolveComments(task).status);
    }
    process.exit(0);
}

const mkServer = () => {
    const tools = {};
    return { tools, srv: { registerTool(n, _d, h) { tools[n] = h; } } };
};

if (scenario === 'create') {
    const { registerCreateTools } = await import(`${root}/src/tools/bd_create.js`);
    const { tools, srv } = mkServer();
    registerCreateTools(srv);
    const input = JSON.parse(rest[0]);
    const res = await tools.bd_create_task(input, {});
    emit('isError', String(res.isError || false));
    emit('id', (res.structuredContent?.data?.id) ?? (res.structuredContent?.data?.[0]?.id) ?? 'none');
    emit('obs', (res.structuredContent?.llm_observations || res.content?.[0]?.text || '').replace(/\n/g, ' '));
    process.exit(0);
}

if (scenario === 'epic') {
    const { registerCreateTools } = await import(`${root}/src/tools/bd_create.js`);
    const { tools, srv } = mkServer();
    registerCreateTools(srv);
    const res = await tools.bd_create_epic(JSON.parse(rest[0]), {});
    emit('isError', String(res.isError || false));
    const d = res.structuredContent?.data;
    emit('epic_id', d?.epic?.id ?? d?.epic?.[0]?.id ?? 'none');
    emit('child_ids', (d?.children || []).map((c) => c?.id ?? c?.[0]?.id ?? '?').join(','));
    process.exit(0);
}

if (scenario === 'list-comments') {
    const { registerCommentTools } = await import(`${root}/src/tools/bd_comment.js`);
    const { tools, srv } = mkServer();
    registerCommentTools(srv);
    const res = await tools.bd_list_comments(JSON.parse(rest[0]), {});
    emit('isError', String(res.isError || false));
    emit('ok', String(res.structuredContent?.ok ?? 'absent'));
    emit('count', String(res.structuredContent?.data?.comments?.length ?? 'absent'));
    emit('count_verified', String(res.structuredContent?.data?.count_verified ?? 'absent'));
    emit('text', (res.content?.[0]?.text || '').split('\n')[0]);
    process.exit(0);
}

if (scenario === 'doc-read') {
    const { registerDocTools } = await import(`${root}/src/tools/bd_doc.js`);
    const { tools, srv } = mkServer();
    registerDocTools(srv);
    const res = await tools.bd_doc_read(JSON.parse(rest[0]), {});
    emit('isError', String(res.isError || false));
    emit('text', (res.content?.[0]?.text || '').split('\n')[0]);
    process.exit(0);
}

console.error(`unknown scenario '${scenario}'`);
process.exit(2);
DRIVER

drive() {
    local root="$1"; shift
    node "$FIXTURE/drive.mjs" "$root" "$@" 2>&1
}
kv() { printf '%s' "$1" | sed -n "s/^$2=//p" | head -1; }

# ===========================================================================
printf '\n--- 1. fkm.1.18: the empty-vs-unavailable discriminator ---\n'
# ===========================================================================
SHIPPED="$MCP_ROOT"

OUT=$(drive "$SHIPPED" resolve-comments)
assert_eq "1.1 count 0 with the comments KEY ABSENT is a genuine empty (117/342 real tasks)" \
    "verified" "$(kv "$OUT" genuine_zero_key_absent)"
assert_eq "1.2 count 0 with an empty array is a genuine empty" \
    "verified" "$(kv "$OUT" genuine_zero_empty_array)"
assert_eq "1.3 count agrees with the bodies -> verified" \
    "verified" "$(kv "$OUT" healthy)"
assert_eq "1.4 count 76 with NO bodies is UNAVAILABLE, not empty (the fkm.1.18 shape)" \
    "unavailable" "$(kv "$OUT" unavailable_bodies_missing)"
assert_eq "1.5 count 76 with 1 body is UNAVAILABLE (truncation is loss, not emptiness)" \
    "unavailable" "$(kv "$OUT" unavailable_truncated)"
assert_eq "1.6 bodies but no count -> unverified (usable, but the count is not claimed)" \
    "unverified" "$(kv "$OUT" no_witness_with_bodies)"
assert_eq "1.7 neither bodies nor count -> unavailable (nothing was established)" \
    "unavailable" "$(kv "$OUT" no_witness_nothing)"

# THE core requirement of the finding, stated as one assertion: a genuinely
# empty task and an unreadable source must NOT produce the same output.
assert_ne "1.8 a genuine empty and an unavailable source are DISTINGUISHABLE" \
    "$(kv "$OUT" genuine_zero_key_absent)" "$(kv "$OUT" unavailable_bodies_missing)"

# --- MUTANT: strip the discriminator, restoring `task.comments || []` -------
M1=$(mk_variant m1-no-discriminator)
mutate "$M1" "src/lib/exec-bd.js" \
    "s#export function resolveComments(task) {#export function resolveComments(task) { return { status: COMMENTS_VERIFIED, comments: Array.isArray(task \&\& task.comments) ? task.comments : [], count: null, reason: null };#" \
    "resolveComments always claims verified"
MOUT=$(drive "$M1" resolve-comments)
assert_eq "1.9 MUTANT reports the unreadable source as VERIFIED — the defect, reproduced" \
    "verified" "$(kv "$MOUT" unavailable_bodies_missing)"
assert_eq "1.10 MUTANT collapses empty and unavailable to one answer" \
    "$(kv "$MOUT" genuine_zero_key_absent)" "$(kv "$MOUT" unavailable_bodies_missing)"

# --- RESTORE CONTROL -------------------------------------------------------
ROUT=$(drive "$SHIPPED" resolve-comments)
assert_eq "1.11 RESTORE CONTROL: the shipped tree still distinguishes them" \
    "unavailable" "$(kv "$ROUT" unavailable_bodies_missing)"

# ===========================================================================
printf '\n--- 2. rmz: a task cannot be born carrying a gate label ---\n'
# ===========================================================================
# The bd SIMULATOR. Reproduces the two measured bd 1.1.2 behaviours:
#   create --parent P            -> labels = requested UNION P's labels
#   create --parent P --no-inherit-labels -> labels = requested, exactly
#   (and the `labels` key is OMITTED when the set is empty, as bd does)
# Section 3 checks this model against the real bd.
cat > "$FIXTURE/bin/bd" <<'SIMBD'
#!/bin/bash
# bd simulator — see the spec header. State: one file per issue holding a
# comma-joined label list. SIM_STATE and SIM_NO_INHERIT_UNKNOWN come from env.
set -u
STATE="${SIM_STATE:?}"
cmd="${1:-}"; shift || true

labels_of() { [ -f "$STATE/$1.labels" ] && cat "$STATE/$1.labels" || printf ''; }

json_issue() {
    local id="$1" lbls="$2"
    printf '[{"id":"%s","title":"sim","status":"open","issue_type":"task"' "$id"
    if [ -n "$lbls" ]; then
        printf ',"labels":['
        local first=1 l
        local IFS=,
        for l in $lbls; do
            [ -n "$l" ] || continue
            [ "$first" = 1 ] || printf ','
            printf '"%s"' "$l"
            first=0
        done
        printf ']'
    fi
    printf '}]\n'
}

case "$cmd" in
create)
    req=""; parent=""; noinherit=0
    while [ $# -gt 0 ]; do
        case "$1" in
            -l|--labels) req="$2"; shift 2 ;;
            --parent) parent="$2"; shift 2 ;;
            --no-inherit-labels) noinherit=1; shift ;;
            -p|--priority|-t|--type|-d|--description|-a|--assignee|--notes|--acceptance|--design) shift 2 ;;
            --json) shift ;;
            *) shift ;;
        esac
    done
    if [ "$noinherit" = 1 ] && [ "${SIM_NO_INHERIT_UNKNOWN:-0}" = "1" ]; then
        printf 'unknown flag: --no-inherit-labels\n' >&2
        exit 1
    fi
    n=$(( $(cat "$STATE/.seq" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$STATE/.seq"
    id="sim-$n"
    final="$req"
    if [ -n "$parent" ] && [ "$noinherit" = 0 ]; then
        for l in $(labels_of "$parent" | tr ',' ' '); do
            case ",$final," in *",$l,"*) ;; *) final="${final:+$final,}$l" ;; esac
        done
    fi
    printf '%s' "$final" > "$STATE/$id.labels"
    json_issue "$id" "$final"
    ;;
label)
    sub="$1"; id="$2"; lbl="$3"
    cur=$(labels_of "$id")
    case "$sub" in
        remove)
            [ "${SIM_LABEL_REMOVE_FAILS:-0}" = "1" ] && { echo "simulated removal failure" >&2; exit 1; }
            out=""
            for l in $(printf '%s' "$cur" | tr ',' ' '); do
                [ "$l" = "$lbl" ] && continue
                out="${out:+$out,}$l"
            done
            printf '%s' "$out" > "$STATE/$id.labels" ;;
        add)
            case ",$cur," in *",$lbl,"*) ;; *) cur="${cur:+$cur,}$lbl" ;; esac
            printf '%s' "$cur" > "$STATE/$id.labels" ;;
    esac
    ;;
show)
    json_issue "$1" "$(labels_of "$1")" ;;
*)
    exit 0 ;;
esac
SIMBD
chmod +x "$FIXTURE/bin/bd"

export SIM_STATE="$FIXTURE/simstate"
# The parent: approved, mid-cycle, pre-graded — every gate label at once.
printf 'devops,qa-approved,qa-gate-entered,qa-pending,rubric-pending,rubric-satisfied' \
    > "$SIM_STATE/parent.labels"

sim_labels() { tr ',' '\n' < "$SIM_STATE/$1.labels" 2>/dev/null | sort | tr '\n' ',' | sed 's/,$//'; }

CREATE_ARGS='{"title":"child","type":"bug","labels":["bug","frontend"],"parent":"parent","cwd":"'"$FIXTURE"'"}'

# --- SHIPPED ---------------------------------------------------------------
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$SHIPPED" create "$CREATE_ARGS")
CID=$(kv "$OUT" id)
assert_eq "2.1 SHIPPED: create under an approved parent succeeds" "false" "$(kv "$OUT" isError)"
assert_eq "2.2 SHIPPED: the child carries EXACTLY the labels asked for" \
    "bug,frontend" "$(sim_labels "$CID")"

# --- MUTANT A: prevention removed (no --no-inherit-labels) -----------------
MA=$(mk_variant ma-no-flag)
mutate "$MA" "src/tools/bd_create.js" \
    's#if (!input.inherit_labels) args.push(NO_INHERIT_FLAG);#/* mutated out */#' \
    "drop --no-inherit-labels"
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$MA" create "$CREATE_ARGS")
MACID=$(kv "$OUT" id)
assert_eq "2.3 MUTANT A: with prevention gone, DETECTION still leaves the child clean" \
    "bug,frontend" "$(sim_labels "$MACID")"
assert_contains "2.4 MUTANT A: and it SAYS a gate label had to be stripped" \
    "STRIPPED 5 inherited workflow-gate label(s)" "$(kv "$OUT" obs)"

# --- MUTANT B: detection removed (audit neutered) --------------------------
MB=$(mk_variant mb-no-audit)
mutate "$MB" "src/tools/bd_create.js" \
    's#const toStrip = allowInherited ? unrequested.filter(isGateLabel) : unrequested;#const toStrip = [];#' \
    "neuter the label audit"
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$MB" create "$CREATE_ARGS")
MBCID=$(kv "$OUT" id)
assert_eq "2.5 MUTANT B: with detection gone, PREVENTION still leaves the child clean" \
    "bug,frontend" "$(sim_labels "$MBCID")"

# --- MUTANT C: both removed — the defect itself ----------------------------
# This is the vacuity check for 2.1-2.5: it proves the harness can SEE the bug.
MC=$(mk_variant mc-both)
mutate "$MC" "src/tools/bd_create.js" \
    's#if (!input.inherit_labels) args.push(NO_INHERIT_FLAG);#/* mutated out */#' \
    "drop --no-inherit-labels (C)"
mutate "$MC" "src/tools/bd_create.js" \
    's#const toStrip = allowInherited ? unrequested.filter(isGateLabel) : unrequested;#const toStrip = [];#' \
    "neuter the label audit (C)"
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$MC" create "$CREATE_ARGS")
MCCID=$(kv "$OUT" id)
assert_eq "2.6 MUTANT C: with BOTH guards gone, the child is born qa-approved" \
    "bug,devops,frontend,qa-approved,qa-gate-entered,qa-pending,rubric-pending,rubric-satisfied" \
    "$(sim_labels "$MCCID")"
assert_eq "2.7 MUTANT C: and it reports ok anyway — the silent-claim shape" \
    "false" "$(kv "$OUT" isError)"

# --- Old bd: the flag is rejected; detection is the only thing left --------
OUT=$(SIM_NO_INHERIT_UNKNOWN=1 PATH="$FIXTURE/bin:$PATH" drive "$SHIPPED" create "$CREATE_ARGS")
OCID=$(kv "$OUT" id)
assert_eq "2.8 a bd that REJECTS --no-inherit-labels still yields a clean child" \
    "bug,frontend" "$(sim_labels "$OCID")"
assert_contains "2.9 and the response names the degraded prevention" \
    "does not support --no-inherit-labels" "$(kv "$OUT" obs)"

# --- A gate label the caller ASKED for must survive ------------------------
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$SHIPPED" create \
    '{"title":"c","type":"bug","labels":["qa-pending"],"parent":"parent","cwd":"'"$FIXTURE"'"}')
assert_eq "2.10 an explicitly requested gate label is KEPT, not stripped as inherited" \
    "qa-pending" "$(sim_labels "$(kv "$OUT" id)")"

# --- inherit_labels=true: domain yes, gate no ------------------------------
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$SHIPPED" create \
    '{"title":"c","type":"bug","labels":["bug"],"parent":"parent","inherit_labels":true,"cwd":"'"$FIXTURE"'"}')
assert_eq "2.11 opt-in inheritance takes the parent's DOMAIN label and no gate label" \
    "bug,devops" "$(sim_labels "$(kv "$OUT" id)")"

# --- An unstrippable gate label must FAIL the call, not warn ---------------
OUT=$(SIM_NO_INHERIT_UNKNOWN=1 SIM_LABEL_REMOVE_FAILS=1 PATH="$FIXTURE/bin:$PATH" \
    drive "$SHIPPED" create "$CREATE_ARGS")
assert_eq "2.12 a gate label that cannot be removed FAILS the call" "true" "$(kv "$OUT" isError)"
assert_contains "2.13 and the error says the issue EXISTS, so the caller does not retry" \
    "do not retry this call" "$(kv "$OUT" obs)"

# --- Epic children ---------------------------------------------------------
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$SHIPPED" epic \
    '{"title":"e","labels":["devops"],"parent":"parent","children":[{"title":"k1","labels":["backend"]},{"title":"k2"}],"cwd":"'"$FIXTURE"'"}')
assert_eq "2.14 epic under an approved parent: the epic itself is clean" \
    "devops" "$(sim_labels "$(kv "$OUT" epic_id)")"
K1=$(printf '%s' "$(kv "$OUT" child_ids)" | cut -d, -f1)
K2=$(printf '%s' "$(kv "$OUT" child_ids)" | cut -d, -f2)
assert_eq "2.15 epic child with labels carries exactly its own" "backend" "$(sim_labels "$K1")"
assert_eq "2.16 epic child with no labels carries none" "" "$(sim_labels "$K2")"

# --- RESTORE CONTROL -------------------------------------------------------
OUT=$(PATH="$FIXTURE/bin:$PATH" drive "$SHIPPED" create "$CREATE_ARGS")
assert_eq "2.17 RESTORE CONTROL: the shipped tree still creates a clean child" \
    "bug,frontend" "$(sim_labels "$(kv "$OUT" id)")"

# ===========================================================================
printf '\n--- 3. against the REAL bd: simulator fidelity + end to end ---\n'
# ===========================================================================
if ! command -v bd >/dev/null 2>&1; then
    if [ "${BD_SHIM_ONLY:-0}" = "1" ]; then
        printf '  note: section 3 SKIPPED (bd not available; CI env BD_SHIM_ONLY=1).\n'
        printf '  note: NOT measured here — that bd 1.1.2 really unions parent labels on create,\n'
        printf '        that --no-inherit-labels really suppresses it, and that a real degraded\n'
        printf '        transport really trips the refusal. Sections 1-2 ran against the simulator.\n'
    else
        printf '  FAIL: bd CLI not on PATH and BD_SHIM_ONLY is unset — section 3 cannot run.\n'
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("section 3 could not run: bd missing without BD_SHIM_ONLY")
    fi
else
    REAL_BD=$(command -v bd)
    BW="$FIXTURE/realbd"
    mkdir -p "$BW"
    if ! (cd "$BW" && "$REAL_BD" init --prefix mur >/dev/null 2>&1) && [ ! -d "$BW/.beads" ]; then
        printf '  FAIL: bd init failed in %s\n' "$BW"
        FAIL=$((FAIL + 1))
        FAILED_TESTS+=("bd init failed")
    else
        bdx() { "$REAL_BD" -C "$BW" "$@"; }
        real_labels() {
            bdx show "$1" --json 2>/dev/null \
                | jq -r 'if type=="array" then .[0] else . end | (.labels // []) | sort | join(",")'
        }
        RP=$(bdx create "real parent" -t bug -p 1 -l devops --json 2>/dev/null \
            | jq -r 'if type=="array" then .[0].id else .id end')
        for l in qa-approved qa-gate-entered; do bdx label add "$RP" "$l" >/dev/null 2>&1; done

        # 3a. SIMULATOR FIDELITY — the model sections 1-2 rely on.
        RC1=$(bdx create "real inherit" -t bug -p 2 -l bug --parent "$RP" --json 2>/dev/null \
            | jq -r 'if type=="array" then .[0].id else .id end')
        assert_eq "3.1 FIDELITY: real bd create --parent DOES union the parent's labels" \
            "bug,devops,qa-approved,qa-gate-entered" "$(real_labels "$RC1")"
        RC2=$(bdx create "real noinherit" -t bug -p 2 -l bug --parent "$RP" --no-inherit-labels --json 2>/dev/null \
            | jq -r 'if type=="array" then .[0].id else .id end')
        assert_eq "3.2 FIDELITY: --no-inherit-labels yields exactly the passed labels" \
            "bug" "$(real_labels "$RC2")"
        assert_eq "3.3 FIDELITY: bd omits the labels key entirely when there are none" \
            "false" "$(bdx create "no labels" -t bug -p 2 --json 2>/dev/null \
                | jq -r 'if type=="array" then .[0] else . end | has("labels")')"

        # 3b. The shipped tool against the real bd.
        OUT=$(drive "$SHIPPED" create \
            '{"title":"e2e child","type":"bug","labels":["bug","frontend"],"parent":"'"$RP"'","cwd":"'"$BW"'"}')
        assert_eq "3.4 END TO END: real bd, real parent carrying qa-approved -> clean child" \
            "bug,frontend" "$(real_labels "$(kv "$OUT" id)")"

        # 3c. Comments: a genuine zero and an unreadable source, side by side.
        ZERO=$(kv "$OUT" id)
        OUT=$(drive "$SHIPPED" list-comments '{"task_id":"'"$ZERO"'","cwd":"'"$BW"'"}')
        assert_eq "3.5 a genuinely empty task returns ok, not an error" "false" "$(kv "$OUT" isError)"
        assert_eq "3.6 ... with zero comments" "0" "$(kv "$OUT" count)"
        assert_eq "3.7 ... and the count is VERIFIED against bd's own comment_count" \
            "true" "$(kv "$OUT" count_verified)"

        for i in 1 2 3; do bdx comments add "$ZERO" "body $i" >/dev/null 2>&1; done
        OUT=$(drive "$SHIPPED" list-comments '{"task_id":"'"$ZERO"'","cwd":"'"$BW"'"}')
        assert_eq "3.8 three real comments are returned" "3" "$(kv "$OUT" count)"

        # The pre-migration transport, reproduced: a bd that drops the
        # hydration flag returns comment_count WITHOUT the bodies.
        cat > "$FIXTURE/bin/bd-strip" <<STRIP
#!/bin/bash
args=()
for a in "\$@"; do [ "\$a" = "--include-comments" ] && continue; args+=("\$a"); done
exec "$REAL_BD" "\${args[@]}"
STRIP
        chmod +x "$FIXTURE/bin/bd-strip"
        mkdir -p "$FIXTURE/stripbin"
        cp "$FIXTURE/bin/bd-strip" "$FIXTURE/stripbin/bd"
        OUT=$(PATH="$FIXTURE/stripbin:$PATH" drive "$SHIPPED" list-comments \
            '{"task_id":"'"$ZERO"'","cwd":"'"$BW"'"}')
        assert_eq "3.9 DEGRADED TRANSPORT: the tool REFUSES rather than reporting zero" \
            "true" "$(kv "$OUT" isError)"
        assert_contains "3.10 ... and names the witness that caught it" \
            "comment_count=3" "$(kv "$OUT" text)"
        OUT=$(PATH="$FIXTURE/stripbin:$PATH" drive "$SHIPPED" doc-read \
            '{"task_id":"'"$ZERO"'","list_only":true,"cwd":"'"$BW"'"}')
        assert_eq "3.11 bd_doc_read list_only refuses too, instead of '0 doc(s) attached'" \
            "true" "$(kv "$OUT" isError)"

        # A `main` doc lives in .notes, so it must stay READABLE when the
        # comment transport is degraded — the refusal is scoped, not blanket.
        bdx update "$ZERO" --notes "the spec body" >/dev/null 2>&1
        OUT=$(PATH="$FIXTURE/stripbin:$PATH" drive "$SHIPPED" doc-read \
            '{"task_id":"'"$ZERO"'","cwd":"'"$BW"'"}')
        assert_eq "3.12 a 'main' doc still reads under a degraded comment transport" \
            "false" "$(kv "$OUT" isError)"

        # MUTANT: restore `task.comments || []` in bd_list_comments and drive
        # it through the SAME degraded transport. This is the historical bug,
        # reproduced against a real bd.
        MD=$(mk_variant md-list-comments)
        mutate "$MD" "src/tools/bd_comment.js" \
            's#const resolved = resolveComments(task);#const resolved = { status: "verified", comments: task.comments || [], count: null };#' \
            "restore task.comments || []"
        OUT=$(PATH="$FIXTURE/stripbin:$PATH" drive "$MD" list-comments \
            '{"task_id":"'"$ZERO"'","cwd":"'"$BW"'"}')
        assert_eq "3.13 MUTANT: without the check it succeeds..." "false" "$(kv "$OUT" isError)"
        assert_eq "3.14 MUTANT: ...asserting ZERO comments on a task carrying three" \
            "0" "$(kv "$OUT" count)"

        # RESTORE CONTROL
        OUT=$(PATH="$FIXTURE/stripbin:$PATH" drive "$SHIPPED" list-comments \
            '{"task_id":"'"$ZERO"'","cwd":"'"$BW"'"}')
        assert_eq "3.15 RESTORE CONTROL: the shipped tree still refuses" \
            "true" "$(kv "$OUT" isError)"

        # 3d. The filing's UNVERIFIED item, now measured: does a REPARENT
        # copy labels the way a create does? It does not — so bd_update_task
        # needs no equivalent guard, and that is a measurement rather than an
        # assumption.
        ORPH=$(bdx create "orphan" -t bug -p 2 -l backend --json 2>/dev/null \
            | jq -r 'if type=="array" then .[0].id else .id end')
        bdx update "$ORPH" --parent "$RP" >/dev/null 2>&1
        assert_eq "3.16 bd update --parent does NOT copy labels (only create does)" \
            "backend" "$(real_labels "$ORPH")"
    fi
fi

# ===========================================================================
printf '\n--- 4. the gate-label set does not drift from qa-gate.sh ---\n'
# ===========================================================================
# WORKFLOW_GATE_LABELS in bd_create.js must stay a superset of qa-gate.sh's
# QA_CYCLE_LABELS. Both sides are READ FROM THE CODE, not from prose: the JS
# list is imported and printed by node, and the shell list is produced by
# sourcing qa-gate.sh's own definition. A new gate label added to one side and
# not the other fails here.
JS_LABELS=$(node -e "import('$MCP_ROOT/src/tools/bd_create.js').then(m=>console.log(m.WORKFLOW_GATE_LABELS.slice().sort().join(' ')))" 2>&1)
SH_LABELS=$(bash -c 'eval "$(grep -m1 "^QA_CYCLE_LABELS=" "$1")"; printf "%s" "$QA_CYCLE_LABELS"' _ \
    "$PROJECT_DIR/.claude/scripts/qa-gate.sh" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')
assert_ne "4.1 the shell cycle-label set was actually read (not empty)" "" "$SH_LABELS"
MISSING=""
for l in $SH_LABELS; do
    case " $JS_LABELS " in *" $l "*) ;; *) MISSING="${MISSING:+$MISSING }$l" ;; esac
done
assert_eq "4.2 every qa-gate.sh cycle label is in WORKFLOW_GATE_LABELS" "" "$MISSING"
assert_contains "4.3 rubric-satisfied is included too (un-sweepable is not inheritable)" \
    "rubric-satisfied" "$JS_LABELS"

# ===========================================================================
printf '\n=== Summary ===\n'
printf 'Passed: %d  Failed: %d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
    printf 'Failed assertions:\n'
    for t in "${FAILED_TESTS[@]}"; do printf '  - %s\n' "$t"; done
    exit 1
fi
exit 0
