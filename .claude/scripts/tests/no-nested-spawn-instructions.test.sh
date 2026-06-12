#!/bin/bash
# no-nested-spawn-instructions.test.sh — claude-workflow-plugin-l1r.6.
#
# Encodes the relay-design constraint surfaced by lesson 4 of LESSONS.md:
#
#   "Subagents cannot spawn other subagents in the Claude Code runtime
#    (docs: sub-agents page — Agent(agent_type) has no effect in subagent
#    definitions). Any agent-spawning step must live at the root
#    conversation level; design multi-agent handoffs as root-orchestrated
#    relays, never nested spawns."
#
# The plugin's QA-to-grader handoff was originally written as a nested
# spawn inside qa.md section 6 ("Spawn the grader via Task(..."). Live
# traces confirmed the spawn step is structurally unreachable from inside
# a subagent. The fix is a relay: QA writes a grading packet and returns
# a `needs-grading` status; the root orchestrator picks up the packet,
# spawns the grader at root, records the verdict, and re-engages QA.
#
# This test guards the relay shape so we cannot accidentally re-nest the
# spawn:
#
#   (a) Every non-orchestrator agent file (qa.md, backend.md, frontend.md,
#       devops.md, grader.md) must NOT contain a spawn-directive aimed at
#       another subagent — the regex catches the `Task(subagent_type="..."`
#       Python-ish form used in qa.md section 6b and the equivalent
#       `Task("@..."` shorthand used in orchestrator.md.
#   (b) qa.md MUST contain the relay handoff sentinel
#       `RUBRIC-RELAY: status=needs-grading` — proves QA is wired to the
#       new handoff, not the old direct spawn.
#   (c) orchestrator.md MUST contain the relay-pickup sentinel
#       `RUBRIC-RELAY: grading-relay` — proves the orchestrator is wired
#       to spawn the grader at root after a needs-grading return.
#
# Sentinels are the same-shape guard pattern used by
# evidence-before-fix.test.sh and agents-manifest-parity.test.sh.
#
# META-TEST: a fixture agent file that DOES include a nested-spawn
# directive must be flagged by the same checker. Without the META-TEST,
# a future refactor that broke the regex would let the test silently
# pass-without-asserting.
#
# Exit codes:
#   0  every non-orchestrator agent file is free of spawn-directives,
#      qa.md has the relay handoff sentinel, orchestrator.md has the
#      relay-pickup sentinel, AND the META-TEST fixture is flagged
#   1  one or more assertions failed
#   2  invocation error (missing files)

set -u

PASS=0
FAIL=0
FAILED_TESTS=()

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../../.." && pwd)}"
AGENTS_DIR="$PROJECT_DIR/.claude/agents"

# Non-orchestrator agent files. These must NOT contain spawn-directives.
# orchestrator.md is excluded — it is the ONLY agent permitted to spawn
# other subagents via Task() (its tool list includes Task; subagents'
# Task tool, even when granted, has no effect per the docs cited above).
#
# judge.md (C.2) is included here for the same reason as grader.md: the
# judge is spawned BY the orchestrator from the mutation-sweep packet,
# never by another subagent. Re-nesting the judge spawn (e.g., having QA
# spawn it) would be structurally unreachable per the docs.
NON_ORCHESTRATOR_AGENTS=(
    "$AGENTS_DIR/qa.md"
    "$AGENTS_DIR/backend.md"
    "$AGENTS_DIR/frontend.md"
    "$AGENTS_DIR/devops.md"
    "$AGENTS_DIR/grader.md"
    "$AGENTS_DIR/judge.md"
)

# Relay sentinels — fixed strings so whitespace/case don't drift.
QA_RELAY_SENTINEL='RUBRIC-RELAY: status=needs-grading'
ORCH_RELAY_SENTINEL='RUBRIC-RELAY: grading-relay'
# JUDGE-RELAY (claude-workflow-plugin-n45.5): the mutation-judge relay
# lives at the same root-orchestrated level as the rubric grader for
# the same structural reason (subagents cannot spawn subagents). The
# orchestrator must carry a JUDGE-RELAY: judging-relay anchor so a
# future refactor that strips the section is caught at L1, parallel
# to the rubric-grader guard above.
ORCH_JUDGE_RELAY_SENTINEL='JUDGE-RELAY: judging-relay'

# Spawn-directive patterns. Each is an extended regex; a match in a
# non-orchestrator agent file means that file is instructing the agent
# to spawn another subagent — structurally impossible per docs, and the
# regression we're guarding against.
#
# Pattern 1: `Task(subagent_type="..."`  — qa.md section 6b's old form.
# Pattern 2: `Task("@<role>"`            — orchestrator.md shorthand;
#                                          forbidden in non-orchestrator
#                                          agents.
# Pattern 3: `subagent_type=["']grader`  — explicit grader spawn, the
#                                          specific shape this fix is
#                                          eliminating.
SPAWN_REGEX_TASK_KW='Task\([^)]*subagent_type[[:space:]]*='
SPAWN_REGEX_AT_ROLE='Task\([[:space:]]*"@[A-Za-z]+"'
SPAWN_REGEX_GRADER='subagent_type[[:space:]]*=[[:space:]]*["'"'"']grader'

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

# check_no_spawn <file> — exit 0 if the file is free of spawn-directives;
# 1 if any of the three regexes match; 2 if the file is missing. Uses
# grep -E with -v on a comment-strip pass so that future README-style
# annotations that QUOTE the pattern in an explanatory context (e.g. "do
# NOT write Task(subagent_type=...)") don't accidentally trip the check
# — but actual instructions still do. We strip prose ONLY inside fenced
# code blocks, which is where directive-shaped text would otherwise live.
#
# In practice the agent prompts use the literal `Task(...)` form in code
# blocks when they mean "spawn this", and use English prose when they
# explain a concept. The regex sees both. To avoid false positives we
# narrow the match to lines that look like an actual call — leading
# whitespace + the call shape, not the call inside a longer sentence.
check_no_spawn() {
    local f="$1"
    if [ ! -f "$f" ]; then
        return 2
    fi
    # A genuine spawn-directive begins with optional whitespace + the
    # Task( token. Prose that quotes the pattern usually has it embedded
    # in a sentence with leading text. We anchor with `^[[:space:]]*` to
    # cut out the embedded-prose case. The same anchor catches indented
    # code-block bodies, which is the form qa.md section 6b used to
    # carry.
    if grep -qE "^[[:space:]]*${SPAWN_REGEX_TASK_KW}" "$f"; then
        return 1
    fi
    if grep -qE "^[[:space:]]*${SPAWN_REGEX_AT_ROLE}" "$f"; then
        return 1
    fi
    # The grader-specific regex is checked anywhere on a line — the
    # explicit subagent_type="grader" string is the smoking gun for the
    # regression even if surrounded by other tokens.
    if grep -qE "${SPAWN_REGEX_GRADER}" "$f"; then
        return 1
    fi
    return 0
}

# --- Real agents: spawn-directive freedom ---------------------------------

for f in "${NON_ORCHESTRATOR_AGENTS[@]}"; do
    name=$(basename "$f" .md)
    if check_no_spawn "$f"; then
        rc=0
    else
        rc=$?
    fi
    assert_eq "no-nested-spawn: $name carries no spawn-directive" "0" "$rc"
done

# --- Relay sentinels in qa.md / orchestrator.md ---------------------------

QA_FILE="$AGENTS_DIR/qa.md"
ORCH_FILE="$AGENTS_DIR/orchestrator.md"

if [ -f "$QA_FILE" ] && grep -qF -- "$QA_RELAY_SENTINEL" "$QA_FILE"; then
    qa_sentinel_rc=0
else
    qa_sentinel_rc=1
fi
assert_eq "no-nested-spawn: qa.md contains relay handoff sentinel" "0" "$qa_sentinel_rc"

if [ -f "$ORCH_FILE" ] && grep -qF -- "$ORCH_RELAY_SENTINEL" "$ORCH_FILE"; then
    orch_sentinel_rc=0
else
    orch_sentinel_rc=1
fi
assert_eq "no-nested-spawn: orchestrator.md contains relay-pickup sentinel" "0" "$orch_sentinel_rc"

# orchestrator.md MUST also contain the JUDGE-RELAY anchor (claude-
# workflow-plugin-n45.5). Same shape as the RUBRIC-RELAY guard above —
# this catches a future refactor that drops or renames the mutation-
# judge relay section.
if [ -f "$ORCH_FILE" ] && grep -qF -- "$ORCH_JUDGE_RELAY_SENTINEL" "$ORCH_FILE"; then
    orch_judge_sentinel_rc=0
else
    orch_judge_sentinel_rc=1
fi
assert_eq "no-nested-spawn: orchestrator.md contains JUDGE-RELAY anchor" "0" "$orch_judge_sentinel_rc"

# --- META-TEST ------------------------------------------------------------
#
# Build a fixture agent file that DOES contain a nested-spawn directive
# (the exact shape qa.md used to carry pre-fix). check_no_spawn must
# flag it. If it doesn't, the regex is no longer sensitive and the real
# assertions above can't be trusted.

META_TMP=$(mktemp -t no-nested-spawn.XXXXXX)
cat > "$META_TMP" <<'MD'
---
name: meta-fixture
description: stub agent with a nested-spawn directive (META-TEST trigger)
tools: Read, Task
model: claude-opus-4-7
---
You are a stub specialist.

When the rubric trigger fires, spawn the grader:

```
Task(
    subagent_type="grader",
    description="Grade work",
    prompt="..."
)
```
MD

# Soft check: the fixture must NOT inadvertently contain any of the
# relay sentinels — otherwise the META-TEST would pass for the wrong
# reason (the assertion checks a different invariant than expected).
if grep -qF -- "$QA_RELAY_SENTINEL" "$META_TMP" \
    || grep -qF -- "$ORCH_RELAY_SENTINEL" "$META_TMP" \
    || grep -qF -- "$ORCH_JUDGE_RELAY_SENTINEL" "$META_TMP"; then
    FAIL=$((FAIL + 1))
    FAILED_TESTS+=("META-TEST fixture inadvertently contains a relay sentinel")
    printf '  FAIL: META-TEST fixture inadvertently contains a relay sentinel\n'
else
    if check_no_spawn "$META_TMP"; then
        rc_meta=0
    else
        rc_meta=$?
    fi
    # rc=1 is the expected "spawn-directive detected" outcome.
    assert_eq "META-TEST: checker flags fixture with nested-spawn directive" "1" "$rc_meta"
fi

rm -f "$META_TMP"

# --- Summary --------------------------------------------------------------

if [ "$FAIL" -gt 0 ]; then
    printf '\nFAILED: %d\n' "$FAIL"
    for t in "${FAILED_TESTS[@]}"; do
        printf '  - %s\n' "$t"
    done
    exit 1
fi
printf '\nPASSED: %d assertion(s)\n' "$PASS"
exit 0
