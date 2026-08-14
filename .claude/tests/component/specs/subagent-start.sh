#!/bin/bash
# subagent-start.sh component spec.
#
# Phase B (claude-workflow-plugin-0wk.11). Covers J3 (Phase 6b): when a
# SubagentStart event names one of our specialists, the hook injects the
# active Beads task id and a brief summary via additionalContext.

set -u

mk_fixture
FIXTURE="$COMPONENT_FIXTURE_PATH"

# Skip-with-log when the real `bd` CLI is absent (CI runner, BD_SHIM_ONLY=1).
# Every assertion below depends on the seeded Beads task (the additionalContext
# the hook injects must mention the task id) — no bd, no signal.
bd_required_or_skip

HOOK="$FIXTURE/.claude/scripts/subagent-start.sh"
CT="$FIXTURE/.claude/scripts/current-task.sh"

# Seed an active Beads task.
TID=$(cd "$FIXTURE" && bd create "Test subagent task" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
assert_match "subagent-start: seed task id created" "$BD_ID_RE" "$TID"
bash "$CT" set "$TID"

# 1. agent_type=backend + active task -> additionalContext injected.
OUT=$(printf '%s' "{\"agent_type\":\"backend\"}" | bash "$HOOK")
assert_valid_envelope "subagent-start: backend valid envelope" "$OUT"
assert_hook_event "subagent-start: backend hookEventName" "$OUT" "SubagentStart"
# The additionalContext should mention the spawned specialist + the task id.
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: context mentions @backend" "@backend" "$CTX"
assert_contains "subagent-start: context contains task id" "$TID" "$CTX"
assert_match "subagent-start: context references SPEC doc convention" \
    "bd_doc_read" "$CTX"

# 2. agent_type=frontend -> @frontend in the context body.
OUT=$(printf '%s' "{\"agent_type\":\"frontend\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @frontend in context" "@frontend" "$CTX"

# 3. agent_type=qa -> @qa in the context body.
OUT=$(printf '%s' "{\"agent_type\":\"qa\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @qa in context" "@qa" "$CTX"

# 4. agent_type=devops -> @devops in the context body.
OUT=$(printf '%s' "{\"agent_type\":\"devops\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @devops in context" "@devops" "$CTX"

# 5. Built-in agent (general-purpose) -> {} (no injection).
OUT=$(printf '%s' "{\"agent_type\":\"general-purpose\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: general-purpose no-op" "$OUT"

OUT=$(printf '%s' "{\"agent_type\":\"Explore\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: Explore no-op" "$OUT"

OUT=$(printf '%s' "{\"agent_type\":\"Plan\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: Plan no-op" "$OUT"

# 6. @-prefixed agent_type is normalised correctly.
OUT=$(printf '%s' "{\"agent_type\":\"@backend\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: @-prefix normalised to backend" "@backend" "$CTX"

# 7. Forward-compat field name `subagent_type` is accepted.
OUT=$(printf '%s' "{\"subagent_type\":\"backend\"}" | bash "$HOOK")
CTX=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
assert_match "subagent-start: subagent_type field accepted" "@backend" "$CTX"

# 8. No active task -> {} (the spawned agent will see SessionStart's list).
bash "$CT" clear
OUT=$(printf '%s' "{\"agent_type\":\"backend\"}" | bash "$HOOK")
assert_empty_envelope "subagent-start: no-active-task no-op" "$OUT"

# 9. Empty stdin -> {} (no crash on manual invocations).
OUT=$(printf '' | bash "$HOOK")
assert_empty_envelope "subagent-start: empty stdin no-op" "$OUT"

# 10. Missing agent_type -> {} (the hook can't decide which specialist).
OUT=$(printf '%s' "{}" | bash "$HOOK")
assert_empty_envelope "subagent-start: empty JSON no-op" "$OUT"

# ===========================================================================
# IMPLEMENTER identity records (v4.0.0 Phase V3 / claude-workflow-plugin-jio.1).
#
# The spawn is the ONE moment the workflow knows, mechanically, which role is
# about to touch a task. `review-check.sh gate` reads those records as the
# implementer set and `qa-gate.sh approve` refuses when the recorded reviewer
# is in it — so a MISSING record silently makes self-review legal, and a
# WRONG one (qa recorded as an implementer) makes every single-agent review
# non-independent and deadlocks the gate. Both directions are asserted.
#
# Grammar (matched by the shipped counter's `^IMPLEMENTER: role=([a-z]+) `):
#   IMPLEMENTER: role=<backend|frontend|devops> task=<tid> at <ISO8601-UTC>
# ===========================================================================

implementer_lines() {
    # All IMPLEMENTER record first-lines on a task (one per line).
    bd_show_with_comments "$1" \
        | jq -r '(if type == "array" then .[0].comments else .comments end) // []
                 | .[].text | split("\n")[0]' 2>/dev/null \
        | grep -E '^IMPLEMENTER: ' || true
}

count_role() {
    # count_role <tid> <role> -> number of records for that role.
    implementer_lines "$1" | grep -cE "^IMPLEMENTER: role=$2 " | tr -d '[:space:]'
}

TID_IMPL=$(cd "$FIXTURE" && bd create "implementer identity" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$TID_IMPL"

# I1. A backend spawn records the identity exactly once, with the exact grammar.
printf '%s' '{"agent_type":"backend"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: backend spawn records the identity" "1" \
    "$(count_role "$TID_IMPL" backend)"
assert_match "implementer: record matches the counter's grammar (role, task, model, pin, ISO ts)" \
    "^IMPLEMENTER: role=backend task=${TID_IMPL} model=[^ ]+ pin=[^ ]+ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" \
    "$(implementer_lines "$TID_IMPL" | grep 'role=backend' | head -1)"
# 46w9: model=/pin= fall back to "unknown" in THIS fixture because mk_fixture
# does not seed .claude/agents/*.md or model-roles-resolved.json (see the
# dedicated model-pin-fields leg below, which seeds both and asserts the real
# values). "unknown" here is the fail-safe path working, not a defect — but
# pin it explicit rather than leaving assert_match's "any non-space token"
# to accept a genuinely wrong fallback silently.
assert_contains "implementer: in THIS fixture (no agent files, no resolved artifact) both fall back to unknown" \
    "model=unknown pin=unknown" "$(implementer_lines "$TID_IMPL" | grep 'role=backend' | head -1)"

# I2. IDEMPOTENT: re-spawning the same role on the same task adds nothing.
# (A re-spawn per iteration is normal; duplicate records would make the audit
# trail unreadable without changing the gate's verdict.)
printf '%s' '{"agent_type":"backend"}' | bash "$HOOK" >/dev/null
printf '%s' '{"agent_type":"@backend"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: re-spawn does NOT duplicate the record" "1" \
    "$(count_role "$TID_IMPL" backend)"

# I3. A REVIEWING agent is never recorded as an implementer. This is the
# assertion that keeps single-agent review viable: if qa were recorded here,
# the qa-claude artifact would be non-independent and approve would refuse
# forever.
printf '%s' '{"agent_type":"qa"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: a qa spawn records NOTHING (reviewers are not implementers)" \
    "0" "$(count_role "$TID_IMPL" qa)"

# I4. Multi-domain task: one record per DISTINCT role.
printf '%s' '{"agent_type":"frontend"}' | bash "$HOOK" >/dev/null
printf '%s' '{"agent_type":"devops"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: a second role gets its own record" "1" \
    "$(count_role "$TID_IMPL" frontend)"
assert_eq "implementer: a third role gets its own record" "1" \
    "$(count_role "$TID_IMPL" devops)"
assert_eq "implementer: three distinct roles -> exactly three records" "3" \
    "$(implementer_lines "$TID_IMPL" | grep -c . | tr -d '[:space:]')"

# I5. Non-specialist spawns are untouched by the new side effect.
printf '%s' '{"agent_type":"general-purpose"}' | bash "$HOOK" >/dev/null
assert_eq "implementer: a general-purpose spawn records nothing" "3" \
    "$(implementer_lines "$TID_IMPL" | grep -c . | tr -d '[:space:]')"

# I6. The existing additionalContext contract still holds alongside the write.
OUT=$(printf '%s' '{"agent_type":"backend"}' | bash "$HOOK")
assert_valid_envelope "implementer: envelope still valid with the identity write" "$OUT"
assert_contains "implementer: additionalContext still carries the task id" "$TID_IMPL" \
    "$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')"

# I7. Best-effort: with bd off PATH the hook must still emit its envelope
# (a spawn is never blocked by a bookkeeping failure).
TID_NOBD=$(cd "$FIXTURE" && bd create "implementer no-bd" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
bash "$CT" set "$TID_NOBD"
NOBD_OUT=$(PATH="/usr/bin:/bin" bash "$HOOK" <<< '{"agent_type":"backend"}' 2>/dev/null || echo "")
NOBD_JSON_OK=$(printf '%s' "$NOBD_OUT" | jq -e . >/dev/null 2>&1 && echo yes || echo no)
assert_eq "implementer: bd absent -> hook still emits valid JSON (never blocks a spawn)" \
    "yes" "$NOBD_JSON_OK"

# ===========================================================================
# THE IDEMPOTENCY KEY INCLUDES THE REVIEW CYCLE (claude-workflow-plugin-qzv.1).
#
# I2 above pins "a re-spawn does not duplicate", and it passed for a year while
# the guard was WRONG: `grep -qE "^IMPLEMENTER: role=${role} "` matched ANY
# comment on the task ever, so the record was idempotent per (role, task) with no
# expiry. The Stop hook's F1 predicate compares that record's TIMESTAMP against
# the most recent `QA-GATE: entered at <ts>` to refuse auto-approving a doc-only
# change set while an implementer is in flight — and against a permanently-first
# timestamp it read "previous cycle" from the second cycle onward and auto-
# approved mid-implementation (QA reproduced it end to end; see qzv.1).
#
# Every leg below is deterministic BY CONSTRUCTION rather than by timing: the
# cycle records are planted at fixed stamps, so no assertion depends on whether
# `enter` and a spawn landed in the same whole second. The counterpart — a real
# `qa-gate.sh enter` writing the cycle record, and the Stop-hook consequence —
# is leg 8 of the verify-before-stop spec, which drives this same hook.
#
# A note on the planted stamps: the PAST-cycle legs use 2000-01-01 and the
# FUTURE-cycle legs 2099-01-01 so the comparison against the record this hook
# writes (always `date -u` NOW) has the same answer on any plausible clock. In a
# future-dated cycle every spawn posts, which is the fail-safe direction and only
# reachable through clock skew or a forged comment.
# ===========================================================================

plant_comment() {
    # plant_comment <tid> <text> — append a record to the task, newest last.
    (cd "$FIXTURE" && bd comments add "$1" "$2" >/dev/null 2>&1 \
        || bd comment add "$1" "$2" >/dev/null 2>&1)
}
spawn_as() {
    # spawn_as <agent_type> [hook] — drive the real SubagentStart entry point.
    printf '%s' "{\"agent_type\":\"$1\"}" | bash "${2:-$HOOK}" >/dev/null 2>&1 || true
}
new_cycle_task() {
    # new_cycle_task <title> -> id, claimed as the active task.
    local tid
    tid=$(cd "$FIXTURE" && bd create "$1" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$CT" set "$tid"
    printf '%s' "$tid"
}

# I9a. Inside ONE open cycle, a re-spawn still posts nothing. This is the
# anti-spam property the guard exists for — preserved, not traded away.
TID_C1=$(new_cycle_task "cycle key: one cycle")
plant_comment "$TID_C1" "QA-GATE: entered at 2000-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9a: the first spawn in an open cycle records once" "1" \
    "$(count_role "$TID_C1" devops)"
spawn_as devops
spawn_as @devops
assert_eq "cycle key I9a: ...and re-spawns INSIDE the same cycle add nothing" "1" \
    "$(count_role "$TID_C1" devops)"

# I9b. THE DEFECT. A cycle opened AFTER this role's record -> a fresh record.
# Pre-fix this posted nothing and the count stayed 1, which is the whole bug.
TID_C2=$(new_cycle_task "cycle key: later cycle")
plant_comment "$TID_C2" "IMPLEMENTER: role=devops task=$TID_C2 at 2000-01-01T00:00:00Z"
plant_comment "$TID_C2" "QA-GATE: entered at 2099-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9b: a re-spawn in a LATER cycle posts a FRESH record (was: nothing)" \
    "2" "$(count_role "$TID_C2" devops)"
assert_match "cycle key I9b: ...and every reader still parses it (model=/pin= sit before 'at', the timestamp anchor is untouched)" \
    "^IMPLEMENTER: role=devops task=${TID_C2} model=[^ ]+ pin=[^ ]+ at [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$" \
    "$(implementer_lines "$TID_C2" | tail -1)"

# I9c/d/e. THE BOUNDARY, one second either side and the exact tie. The tie counts
# as "current" deliberately: F1 refuses same-second pairs (whole-second stamps
# cannot order an enter and a spawn), so the record already there blocks and a
# duplicate would add a line for nothing.
TID_C3=$(new_cycle_task "cycle key: one second before")
plant_comment "$TID_C3" "IMPLEMENTER: role=devops task=$TID_C3 at 2098-12-31T23:59:59Z"
plant_comment "$TID_C3" "QA-GATE: entered at 2099-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9c: a record ONE SECOND before the cycle open -> posts" "2" \
    "$(count_role "$TID_C3" devops)"

TID_C4=$(new_cycle_task "cycle key: same second")
plant_comment "$TID_C4" "IMPLEMENTER: role=devops task=$TID_C4 at 2099-01-01T00:00:00Z"
plant_comment "$TID_C4" "QA-GATE: entered at 2099-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9d: a record in the SAME SECOND as the cycle open -> no post" "1" \
    "$(count_role "$TID_C4" devops)"

TID_C5=$(new_cycle_task "cycle key: one second after")
plant_comment "$TID_C5" "IMPLEMENTER: role=devops task=$TID_C5 at 2099-01-01T00:00:01Z"
plant_comment "$TID_C5" "QA-GATE: entered at 2099-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9e: a record ONE SECOND after the cycle open -> no post" "1" \
    "$(count_role "$TID_C5" devops)"

# I9f. THE LEXICOGRAPHIC MAX, not the last line in comment order. The newer cycle
# record is planted FIRST, so a reader keying on comment order would see the OLDER
# open, conclude the role's record is newer than it, and skip.
TID_C6=$(new_cycle_task "cycle key: max not last line")
plant_comment "$TID_C6" "QA-GATE: entered at 2099-01-01T00:00:00Z"
plant_comment "$TID_C6" "QA-GATE: entered at 2000-01-01T00:00:00Z"
plant_comment "$TID_C6" "IMPLEMENTER: role=devops task=$TID_C6 at 2050-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9f: the MAX cycle open wins over the last-listed one -> posts" "2" \
    "$(count_role "$TID_C6" devops)"

# I9g. PER-ROLE, which is why `review-check.sh gate`'s cross-role
# `latest_implementer_ts` could not be reused for this decision: reusing it would
# suppress devops's record because backend already posted one this cycle, and the
# implementer SET is what makes `approve` refuse a self-review (jio.1).
TID_C7=$(new_cycle_task "cycle key: per role")
plant_comment "$TID_C7" "QA-GATE: entered at 2000-01-01T00:00:00Z"
spawn_as backend
assert_eq "cycle key I9g: precondition — backend recorded in this cycle" "1" \
    "$(count_role "$TID_C7" backend)"
spawn_as devops
assert_eq "cycle key I9g: ...and devops still gets its OWN record (never suppressed)" "1" \
    "$(count_role "$TID_C7" devops)"

# I9h. An UNPARSEABLE stamp posts rather than skips. `date` failing makes this
# hook write a literal `at ?`, so it is a stamp the writer can really produce; the
# two records cannot be ordered, and a fresh well-formed one is the only answer
# that makes the predicate readable again.
TID_C8=$(new_cycle_task "cycle key: unparseable stamp")
plant_comment "$TID_C8" "IMPLEMENTER: role=devops task=$TID_C8 at ?"
plant_comment "$TID_C8" "QA-GATE: entered at 2099-01-01T00:00:00Z"
spawn_as devops
assert_eq "cycle key I9h: an unparseable existing stamp -> posts (fail-safe)" "2" \
    "$(count_role "$TID_C8" devops)"

# ===========================================================================
# MODEL-PIN-FIELDS (claude-workflow-plugin-46w9). The legs above all ran
# against a fixture with no .claude/agents/*.md and no
# model-roles-resolved.json, which is why every model=/pin= read "unknown" —
# that IS the fail-safe path, proven above, but the happy path (real values)
# needs its own fixture state to exercise at all.
REAL_HOOK=$(readlink "$HOOK" 2>/dev/null || printf '%s' "$HOOK")

mkdir -p "$FIXTURE/.claude/agents"
cat > "$FIXTURE/.claude/agents/backend.md" <<'EOF'
---
name: backend
model: claude-sonnet-5
---
seeded fixture agent file, not a real prompt.
EOF

TID_MP1=$(new_cycle_task "model-pin: matching pin and resolved model")
cat > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json" <<'EOF'
{"schema":2,"roles":{"implementer":"claude-sonnet-5","reviewer":"claude-fable-5"}}
EOF
spawn_as backend
MP1_LINE=$(implementer_lines "$TID_MP1" | grep 'role=backend' | head -1)
assert_contains "model-pin: pin= reads the role's own frontmatter" \
    "pin=claude-sonnet-5" "$MP1_LINE"
assert_contains "model-pin: model= reads the resolved implementer-class pick" \
    "model=claude-sonnet-5" "$MP1_LINE"

# DIVERGENCE: the frontmatter and the resolved artifact disagree (a stale
# artifact, or a hand-edit since the last apply). BOTH values are recorded —
# neither is silently reconciled to the other — because the divergence is
# exactly the signal 46w9 exists to make visible. Spawns as "backend" (not a
# different role) so it reads the SAME seeded backend.md as MP1 — a fixture
# with only one agent file on disk, which every OTHER leg here also has.
TID_MP2=$(new_cycle_task "model-pin: pin and resolved model DIVERGE")
cat > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json" <<'EOF'
{"schema":2,"roles":{"implementer":"claude-opus-9","reviewer":"claude-fable-5"}}
EOF
spawn_as backend
MP2_LINE=$(implementer_lines "$TID_MP2" | grep 'role=backend' | head -1)
assert_contains "model-pin: divergence — pin= still names the frontmatter value" \
    "pin=claude-sonnet-5" "$MP2_LINE"
assert_contains "model-pin: divergence — model= still names the resolved value, UNRECONCILED" \
    "model=claude-opus-9" "$MP2_LINE"

# BRACKET-CONTAINING MODEL ID (the bjx class, applied to a real observed
# runtime id — claude-workflow-plugin-gz3's ledger note records
# `claude-opus-5[1m]` verbatim, the model that actually ran a review versus
# the frontmatter pin that would normally apply). Must survive verbatim, not
# truncate at the bracket and not reject to "unknown".
TID_MP3=$(new_cycle_task "model-pin: bracket-suffixed id survives verbatim")
cat > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json" <<'EOF'
{"schema":2,"roles":{"implementer":"claude-opus-5[1m]","reviewer":"claude-fable-5"}}
EOF
spawn_as backend
MP3_LINE=$(implementer_lines "$TID_MP3" | grep 'role=backend' | head -1)
assert_contains "model-pin: a bracket-suffixed real id survives verbatim in model=" \
    "model=claude-opus-5[1m]" "$MP3_LINE"

# OUT-OF-CLASS VALUE (an injection-shaped resolved value) falls back to
# "unknown" rather than embedding it — reject, never sanitise.
TID_MP4=$(new_cycle_task "model-pin: out-of-class resolved value falls back")
cat > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json" <<'EOF'
{"schema":2,"roles":{"implementer":"claude sonnet; rm -rf /","reviewer":"claude-fable-5"}}
EOF
spawn_as backend
MP4_LINE=$(implementer_lines "$TID_MP4" | grep 'role=backend' | head -1)
assert_contains "model-pin: an out-of-class resolved value falls back to unknown" \
    "model=unknown" "$MP4_LINE"
assert_not_contains "model-pin: ...and the raw value never reaches the record" \
    "rm -rf" "$MP4_LINE"

# META (load-bearing): neutralise model_id_class_ok (replace its body with an
# unconditional accept) in a copy, and the SAME out-of-class value from MP4
# must now survive into the record — proving MP4's rejection is the guard's
# doing and not some unrelated reason the value never landed.
CLASS_MUT="$FIXTURE/subagent-start-noclass.sh"
awk '
    /^model_id_class_ok\(\) \{/ { print; print "    return 0  # META: neutralised"; skip = 1; next }
    skip && /^\}$/ { print; skip = 0; next }
    skip { next }
    { print }
' "$REAL_HOOK" > "$CLASS_MUT"
chmod +x "$CLASS_MUT"
if assert_mutant_applied "model-pin class META" "$REAL_HOOK" "$CLASS_MUT"; then
    assert_eq "model-pin class META: the neutralised guard is gone from the mutant" "0" \
        "$(grep -cF "printf '%s' \"\$1\" | grep -qE" "$CLASS_MUT" | tr -d '[:space:]')"
    assert_eq "model-pin class META: mutated hook parses" "0" \
        "$(bash -n "$CLASS_MUT" 2>/dev/null && echo 0 || echo 1)"
    TID_MP5=$(new_cycle_task "model-pin class META: no guard")
    cat > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json" <<'EOF'
{"schema":2,"roles":{"implementer":"claude sonnet; rm -rf /","reviewer":"claude-fable-5"}}
EOF
    spawn_as backend "$CLASS_MUT"
    MP5_LINE=$(implementer_lines "$TID_MP5" | grep 'role=backend' | head -1)
    assert_contains "model-pin class META: WITHOUT the guard the out-of-class value now reaches the record" \
        "claude sonnet; rm -rf /" "$MP5_LINE"
fi

# Restore a clean resolved artifact for the legs below.
cat > "$FIXTURE/.claude/.qa-tracking/model-roles-resolved.json" <<'EOF'
{"schema":2,"roles":{"implementer":"claude-sonnet-5","reviewer":"claude-fable-5"}}
EOF

# I8. META: break the idempotency guard in a COPY (invert the grep so the
# "already recorded" branch never fires) -> a re-spawn DUPLICATES the record,
# i.e. assertion I2 would fail. Proves I2 is sensitive to the guard rather
# than to some incidental de-duplication elsewhere. TEXT-anchored on the guard
# (LESSONS llh.20), not on a line number.
#
# qzv.1 kept this anchor line byte-identical on purpose: the pre-fix
# per-(role, task) grep still lives outside the IMPLEMENTER-CYCLE-KEY region and
# still decides the first half of the guard, so rewriting it to a constant-false
# condition still makes every spawn post. What changed is that it now sets a
# `skip` variable the region refines, instead of returning directly.
# ($REAL_HOOK is set once, above, by the model-pin-fields section.)
HOOK_MUT="$FIXTURE/subagent-start-dupmut.sh"
awk '
    /if printf .%s\\n. "\$existing" \| grep -qE "\^IMPLEMENTER: role=\$\{role\} "; then/ {
        print "    if [ \"no\" = \"yes\" ]; then"
        mutated=1
        next
    }
    { print }
    END { if (!mutated) exit 7 }
' "$REAL_HOOK" > "$HOOK_MUT"
MUT_RC=$?
chmod +x "$HOOK_MUT"
assert_eq "implementer META: idempotency guard located + mutated in the copy" "0" "$MUT_RC"
if [ "$MUT_RC" -eq 0 ]; then
    TID_MUT=$(cd "$FIXTURE" && bd create "implementer META dup" -t task -p 1 --json 2>/dev/null | jq -r '.id // empty')
    bash "$CT" set "$TID_MUT"
    printf '%s' '{"agent_type":"backend"}' | bash "$HOOK_MUT" >/dev/null
    printf '%s' '{"agent_type":"backend"}' | bash "$HOOK_MUT" >/dev/null
    assert_eq "implementer META: with the guard broken a re-spawn DUPLICATES (I2 WOULD fail)" \
        "2" "$(count_role "$TID_MUT" backend)"
fi

# I10. META (spec-mandated for qzv.1): strip the IMPLEMENTER-CYCLE-KEY region and
# a re-spawn in a LATER cycle posts NOTHING again — I9b's exact state, pre-fix.
# This is the writer-side half; the gate-side half (the same strip making a
# doc-only Stop auto-approve mid-implementation) is the qzv.1 META in the
# verify-before-stop spec.
#
# The strip yields the PRE-FIX guard rather than a syntax error because the
# per-(role, task) grep and the `skip` variable it sets live OUTSIDE the
# sentinels; only the refinement and its two helpers live inside. Anchored
# patterns (`^ *#`) so a prose line naming the sentinel cannot start the excision
# early.
CK_MUT="$FIXTURE/subagent-start-cyclekey-stripped.sh"
awk '
    /^ *# IMPLEMENTER-CYCLE-KEY BEGIN/ { skip = 1; next }
    /^ *# IMPLEMENTER-CYCLE-KEY END/   { skip = 0; next }
    !skip { print }
' "$REAL_HOOK" > "$CK_MUT"
chmod +x "$CK_MUT"
if assert_mutant_applied "implementer I10 META" "$REAL_HOOK" "$CK_MUT"; then
    assert_eq "implementer I10 META: no cycle refinement survives (the strip landed where aimed)" \
        "0" "$(grep -c 'recorded_in_current_cycle' "$CK_MUT" | tr -d '[:space:]')"
    assert_eq "implementer I10 META: ...while the pre-fix per-(role, task) grep SURVIVES outside it" \
        "1" "$(grep -c -F 'if printf '"'"'%s\n'"'"' "$existing" | grep -qE "^IMPLEMENTER: role=${role} "; then' "$CK_MUT" | tr -d '[:space:]')"
    assert_eq "implementer I10 META: the stripped copy still parses" "0" \
        "$(bash -n "$CK_MUT" 2>/dev/null && echo 0 || echo 1)"
    TID_CKM=$(new_cycle_task "cycle key META: stripped writer goes blind")
    plant_comment "$TID_CKM" "IMPLEMENTER: role=devops task=$TID_CKM at 2000-01-01T00:00:00Z"
    plant_comment "$TID_CKM" "QA-GATE: entered at 2099-01-01T00:00:00Z"
    spawn_as devops "$CK_MUT"
    assert_eq "implementer I10 META: with the cycle key stripped the later cycle posts NOTHING (I9b WOULD fail)" \
        "1" "$(count_role "$TID_CKM" devops)"
    # Restore control: the SHIPPED hook, identical state, posts the fresh record.
    TID_CKC=$(new_cycle_task "cycle key META: shipped writer records")
    plant_comment "$TID_CKC" "IMPLEMENTER: role=devops task=$TID_CKC at 2000-01-01T00:00:00Z"
    plant_comment "$TID_CKC" "QA-GATE: entered at 2099-01-01T00:00:00Z"
    spawn_as devops
    assert_eq "implementer I10 META: restore control — the shipped hook posts it" "2" \
        "$(count_role "$TID_CKC" devops)"
    # ...and the stripped copy is NOT broken in some blanket way that would make
    # the leg above pass for the wrong reason: with no cycle record at all, both
    # copies agree (this is the state I2 covers, where the keys are equivalent).
    TID_CKN=$(new_cycle_task "cycle key META: no cycle, both agree")
    spawn_as devops "$CK_MUT"
    spawn_as devops "$CK_MUT"
    assert_eq "implementer I10 META: ...and with NO cycle record the stripped copy still de-dupes" \
        "1" "$(count_role "$TID_CKN" devops)"
fi

[ "$FAIL" -eq 0 ]
