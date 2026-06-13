/**
 * _label-events.unit.spec.ts — derivation + invariant tests for the
 * Beads label EVENT stream (G2.9ke / claude-workflow-plugin-9ke).
 *
 * THE BUG: `trace.beadsLabelTransitions` is a NET pre/post diff, so a
 * label added then removed in-run (qa-pending during every correct
 * approve flow) is invisible — the `label-milestones` invariant FAILED
 * on every correct approve-flow run (pinned on runs 3 and 4 in
 * `_phase-b-run3-trace.unit.spec.ts` / `_phase-b-run4-trace.unit.spec.ts`).
 *
 * THE FIX UNDER TEST, two layers:
 *
 *   1. `deriveBeadsLabelEvents(toolCalls)` (lib/labelEvents.ts) — turns
 *      the tool-call stream into an ordered `beadsLabelEvents` stream:
 *      qa-gate.sh subcommands imply label events per the gate contract;
 *      raw `bd label add/remove`, `bd create -l`, `bd update
 *      --add/remove-label`, and the MCP bd surface yield direct events.
 *
 *   2. The rewritten `label-milestones` invariant — milestone adds must
 *      appear as an ordered subsequence over the EVENT stream
 *      (qa-pending's add counts even though it is later removed), with
 *      a documented net-diff complement for stream-invisible adds that
 *      survive the run (rubric-satisfied is set INSIDE qa-gate.sh
 *      grade-record, so no tool call ever shows it). Traces that
 *      predate the events field (all committed seeds) SKIP honestly
 *      instead of retro-failing.
 *
 * FAILING-FIRST (evidence in the Beads notes for
 * claude-workflow-plugin-llh.4): this spec was written against a stub
 * derivation (returns []) and the OLD net-diff invariant, captured red,
 * then the implementation flipped it green.
 *
 * Real-trace grounding: every Bash command shape in the derivation
 * tests below is verbatim (or minimally trimmed) from the run-3/run-4
 * seed traces, including the adversarial negatives (grep'ing
 * qa-gate.sh, a `bd create` title that NAMES qa-gate.sh, `bd list
 * --label`, an invalid `qa-gate.sh request` subcommand).
 */
import { describe, it, expect } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { deriveBeadsLabelEvents } from "../lib/labelEvents.js";
import { INVARIANTS, evaluateAll } from "../lib/invariants.js";
import {
  createEmptyTrace,
  type BeadsLabelEvent,
  type ToolCall,
  type Trace,
} from "../lib/trace.js";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const SEED_DIR = path.resolve(__dirname, "..", "cassettes", "seed");
const RUN4_TRACE = path.join(
  SEED_DIR,
  "node-react-auth-2026-06-12T02-18-12-871Z.jsonl",
);
const RUN3_TRACE = path.join(
  SEED_DIR,
  "node-react-auth-2026-06-12T00-50-56-312Z.jsonl",
);

// ---------------------------------------------------------------------------
// Builders. Expected events are HARDCODED in every assertion (never
// referenced from the implementation's contract tables) so a corrupted
// mapping in labelEvents.ts cannot silently satisfy its own test.
// ---------------------------------------------------------------------------

function bash(id: string, command: string): ToolCall {
  return {
    id,
    name: "Bash",
    input: { command },
    parentToolUseId: null,
    durationMs: 0,
  };
}

function mcp(id: string, name: string, input: unknown): ToolCall {
  return { id, name, input, parentToolUseId: null, durationMs: 0 };
}

function ev(
  action: "add" | "remove",
  label: string,
  taskId: string,
  source: string,
): BeadsLabelEvent {
  return { action, label, taskId, source };
}

// ---------------------------------------------------------------------------
// 1. qa-gate.sh subcommand contract (enter / approve / block / choose
//    approve). The label semantics are read from
//    .claude/scripts/qa-gate.sh — see lib/labelEvents.ts header.
// ---------------------------------------------------------------------------

describe("deriveBeadsLabelEvents: qa-gate.sh subcommand contract", () => {
  it("enter implies +qa-gate-entered +rubric-pending (run-4 verbatim shape: abs path, redirect, pipe)", () => {
    const calls = [
      bash(
        "b-enter",
        "bash /Users/edk0/Desktop/projects/claude-workflow-plugin/.claude/scripts/qa-gate.sh enter auth-neb.1 2>&1 | head -40",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-gate-entered", "auth-neb.1", "b-enter"),
      ev("add", "rubric-pending", "auth-neb.1", "b-enter"),
    ]);
  });

  it("approve implies +qa-approved −qa-gate-entered −qa-pending −rubric-pending, in script order", () => {
    const calls = [
      bash(
        "b-approve",
        "bash .claude/scripts/qa-gate.sh approve auth-neb.1 'Approved. npm test 11/11 green; lint+typecheck placeholders pass.'",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-approved", "auth-neb.1", "b-approve"),
      ev("remove", "qa-gate-entered", "auth-neb.1", "b-approve"),
      ev("remove", "qa-pending", "auth-neb.1", "b-approve"),
      ev("remove", "rubric-pending", "auth-neb.1", "b-approve"),
    ]);
  });

  it("approve with --no-impact-report flag still resolves the task id (tid is positionally first)", () => {
    const calls = [
      bash(
        "b-bypass",
        "bash .claude/scripts/qa-gate.sh approve auth-b69 --no-impact-report 'code-graph absent' 'summary text'",
      ),
    ];
    const events = deriveBeadsLabelEvents(calls);
    expect(events[0]).toEqual(ev("add", "qa-approved", "auth-b69", "b-bypass"));
    expect(events).toHaveLength(4);
  });

  it("block implies +qa-blocked (qa-gate-entered preserved per the script contract)", () => {
    const calls = [
      bash(
        "b-block",
        "bash .claude/scripts/qa-gate.sh block auth-neb.2 'tests fail: 3/11 red'",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-blocked", "auth-neb.2", "b-block"),
    ]);
  });

  it("choose approve delegates to the approve contract (cmd_choose -> cmd_approve)", () => {
    const calls = [
      bash(
        "b-choose",
        "bash .claude/scripts/qa-gate.sh choose approve auth-neb 'accepting residual findings'",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-approved", "auth-neb", "b-choose"),
      ev("remove", "qa-gate-entered", "auth-neb", "b-choose"),
      ev("remove", "qa-pending", "auth-neb", "b-choose"),
      ev("remove", "rubric-pending", "auth-neb", "b-choose"),
    ]);
  });

  it("derives NOTHING for unknown/non-label subcommands: the run-4 invalid `request` call, status, bare invocation", () => {
    const calls = [
      // Run-4 verbatim: the model invented a `request` subcommand; the
      // script exits 1 via usage() with zero label effects.
      bash(
        "b-request",
        'if [ -x /Users/edk0/Desktop/projects/claude-workflow-plugin/.claude/scripts/qa-gate.sh ]; then\n  /Users/edk0/Desktop/projects/claude-workflow-plugin/.claude/scripts/qa-gate.sh request auth-neb.1 2>&1\nelse\n  echo "qa-gate missing"\nfi',
      ),
      bash("b-status", "bash .claude/scripts/qa-gate.sh status auth-neb.1"),
      // Run-3 verbatim: bare invocation to read the usage text.
      bash("b-bare", ".claude/scripts/qa-gate.sh 2>&1 | head -30"),
      // grade-record's rubric-satisfied flip happens INSIDE the script
      // and depends on the piped verdict JSON — not derivable from the
      // command shape; documented gap covered by the invariant's
      // net-diff complement.
      bash(
        "b-grade",
        "printf '%s' \"$VERDICT_JSON\" | bash .claude/scripts/qa-gate.sh grade-record auth-neb.1",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([]);
  });

  it("derives NOTHING from commands that merely READ qa-gate.sh (run-3 adversarial corpus)", () => {
    const calls = [
      bash(
        "b-grep",
        'grep -E "(request|approve|reject)" .claude/scripts/qa-gate.sh | head -20',
      ),
      bash(
        "b-grep2",
        'grep -E "Usage|usage|^\\s+[a-z]+ " .claude/scripts/qa-gate.sh | head -20',
      ),
      bash("b-ls", 'ls .claude/scripts/ 2>&1\necho "---"\nls .claude/scripts/qa-gate.sh 2>&1'),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// 2. Raw `bd label add/remove` Bash commands.
// ---------------------------------------------------------------------------

describe("deriveBeadsLabelEvents: raw bd label add/remove", () => {
  it("single add with global --no-daemon flag and redirect (run-4 verbatim)", () => {
    const calls = [
      bash("b1", "bd --no-daemon label add auth-neb.1 qa-pending 2>&1"),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "auth-neb.1", "b1"),
    ]);
  });

  it("piped suffix does not leak tokens into the label list (run-4 verbatim)", () => {
    const calls = [
      bash("b2", "bd --no-daemon label add auth-neb.2 qa-pending 2>&1 | tail -5"),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "auth-neb.2", "b2"),
    ]);
  });

  it("compound &&-chained adds in ONE Bash call derive in match order (run-4 verbatim)", () => {
    const calls = [
      bash(
        "b3",
        "bd --no-daemon label add auth-neb.1 qa-gate-entered 2>&1 && bd --no-daemon label add auth-neb.2 qa-gate-entered 2>&1",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-gate-entered", "auth-neb.1", "b3"),
      ev("add", "qa-gate-entered", "auth-neb.2", "b3"),
    ]);
  });

  it("add+remove+remove manual-workaround chain (run-4 verbatim: the daemon-bug fallback)", () => {
    const calls = [
      bash(
        "b4",
        "bd --no-daemon label add auth-neb.1 qa-approved && bd --no-daemon label remove auth-neb.1 qa-pending && bd --no-daemon label remove auth-neb.1 qa-gate-entered",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-approved", "auth-neb.1", "b4"),
      ev("remove", "qa-pending", "auth-neb.1", "b4"),
      ev("remove", "qa-gate-entered", "auth-neb.1", "b4"),
    ]);
  });

  it("multi-label form: one command, several labels (run-4 verbatim)", () => {
    const calls = [
      bash(
        "b5",
        "bd --no-daemon label remove auth-neb qa-pending qa-gate-entered 2>&1 | tail -3",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("remove", "qa-pending", "auth-neb", "b5"),
      ev("remove", "qa-gate-entered", "auth-neb", "b5"),
    ]);
  });

  it("trailing flags terminate the label list", () => {
    const calls = [
      bash("b6", "bd label add t-9 qa-pending --json"),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "t-9", "b6"),
    ]);
  });

  it("works through the fixture's bd shim path", () => {
    const calls = [
      bash(
        "b7",
        "/x/fixtures/node-react-auth/.claude/bin/bd label add auth-86b.1 qa-approved 2>&1 | head -5",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-approved", "auth-86b.1", "b7"),
    ]);
  });

  it("derives NOTHING from non-label bd commands (show / list --label / update --notes)", () => {
    const calls = [
      bash("n1", "bd --no-daemon show auth-86b.2 2>&1 | head -20"),
      bash("n2", "bd --no-daemon list --label qa-pending --json 2>&1 | head -100"),
      bash(
        "n3",
        "bd --no-daemon update auth-neb.2 --notes \"COMPLETED: client/src/LoginForm.jsx with controlled email/password inputs\"",
      ),
      bash("n4", "ls -la && echo done"),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// 3. Creation labels + update label flags.
// ---------------------------------------------------------------------------

describe("deriveBeadsLabelEvents: bd create -l / bd update --add-label", () => {
  it("create with -l derives adds with taskId '' (id is assigned server-side) — run-4 verbatim incl. a title that NAMES qa-gate.sh", () => {
    const calls = [
      bash(
        "c1",
        'bd --no-daemon create "qa-gate.sh + bd-mcp fail under bd daemon autostart stack overflow" -t bug -p 2 -l devops --json -d "Discovered during auth-neb QA gate"',
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "devops", "", "c1"),
    ]);
  });

  it("create with comma-joined labels splits them (run-3 verbatim shape: -l backend,qa-pending)", () => {
    const calls = [
      bash(
        "c2",
        'bd --no-daemon create "Backend: POST /auth/login with JWT" -t feature -p 1 --parent auth-86b -l backend,qa-pending --description "Implement POST /auth/login in server/index.js."',
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "backend", "", "c2"),
      ev("add", "qa-pending", "", "c2"),
    ]);
  });

  it("update --add-label / --remove-label derive direct events on the named task", () => {
    const calls = [
      bash(
        "u1",
        "bd --no-daemon update auth-neb.1 --add-label qa-pending --remove-label qa-blocked",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "auth-neb.1", "u1"),
      ev("remove", "qa-blocked", "auth-neb.1", "u1"),
    ]);
  });

  it("create without -l derives nothing", () => {
    const calls = [
      bash("c3", 'bd create "plain task with no labels" -t task -p 2'),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// 4. MCP bd tool surface. Names arrive plugin-qualified
//    (mcp__plugin_claude-workflow_bd__<tool>), server-bare
//    (mcp__bd__<tool>), or bare (<tool>); suffix matching covers all.
// ---------------------------------------------------------------------------

describe("deriveBeadsLabelEvents: MCP bd tool surface", () => {
  it("bd_add_label fans out one add per task_id", () => {
    const calls = [
      mcp("m1", "mcp__plugin_claude-workflow_bd__bd_add_label", {
        task_ids: ["t-1", "t-2"],
        label: "qa-pending",
      }),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "t-1", "m1"),
      ev("add", "qa-pending", "t-2", "m1"),
    ]);
  });

  it("bd_remove_label mirrors bd_add_label with action=remove", () => {
    const calls = [
      mcp("m2", "mcp__bd__bd_remove_label", {
        task_ids: ["t-1"],
        label: "qa-blocked",
      }),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("remove", "qa-blocked", "t-1", "m2"),
    ]);
  });

  it("bd_qa_enter / bd_qa_approve / bd_qa_block carry the qa-gate.sh contract (the MCP server shells out to it)", () => {
    const calls = [
      mcp("m3", "mcp__plugin_claude-workflow_bd__bd_qa_enter", {
        task_id: "t-5",
      }),
      mcp("m4", "mcp__bd__bd_qa_approve", {
        task_id: "t-5",
        summary: "all green",
      }),
      mcp("m5", "bd_qa_block", { task_id: "t-6", reason: "red tests" }),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-gate-entered", "t-5", "m3"),
      ev("add", "rubric-pending", "t-5", "m3"),
      ev("add", "qa-approved", "t-5", "m4"),
      ev("remove", "qa-gate-entered", "t-5", "m4"),
      ev("remove", "qa-pending", "t-5", "m4"),
      ev("remove", "rubric-pending", "t-5", "m4"),
      ev("add", "qa-blocked", "t-6", "m5"),
    ]);
  });

  it("bd_create_task labels and bd_create_epic labels (incl. children) derive adds with taskId ''", () => {
    const calls = [
      mcp("m6", "mcp__plugin_claude-workflow_bd__bd_create_task", {
        title: "x",
        labels: ["backend", "qa-pending"],
      }),
      mcp("m7", "mcp__plugin_claude-workflow_bd__bd_create_epic", {
        title: "epic",
        labels: ["devops"],
        children: [
          { title: "child-1", labels: ["frontend"] },
          { title: "child-2" },
        ],
      }),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "backend", "", "m6"),
      ev("add", "qa-pending", "", "m6"),
      ev("add", "devops", "", "m7"),
      ev("add", "frontend", "", "m7"),
    ]);
  });

  it("bd_update_task add_labels/remove_labels derive events; set_labels derives NOTHING (replace-all needs prior state)", () => {
    const calls = [
      mcp("m8", "mcp__bd__bd_update_task", {
        task_id: "t-7",
        add_labels: ["qa-pending"],
        remove_labels: ["qa-blocked"],
      }),
      mcp("m9", "mcp__bd__bd_update_task", {
        task_id: "t-8",
        set_labels: ["whole", "new", "set"],
      }),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "t-7", "m8"),
      ev("remove", "qa-blocked", "t-7", "m8"),
    ]);
  });

  it("non-bd tools and unrelated MCP calls derive nothing", () => {
    const calls = [
      mcp("x1", "Read", { file_path: "/etc/hosts" }),
      mcp("x2", "Write", { file_path: "a.txt", content: "qa-pending" }),
      mcp("x3", "mcp__plugin_claude-workflow_code-graph__impact_of", {
        symbol: "qa-pending",
      }),
      mcp("x4", "mcp__bd__bd_show_task", { task_id: "t-1" }),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// 5. Ordering and source attribution across the whole stream.
// ---------------------------------------------------------------------------

describe("deriveBeadsLabelEvents: ordering + source attribution", () => {
  it("emits the canonical gate cycle in chronological order across calls", () => {
    const calls = [
      bash("s1", "bd --no-daemon label add t-1 qa-pending"),
      bash("s2", "bash .claude/scripts/qa-gate.sh enter t-1"),
      bash("s3", "bash .claude/scripts/qa-gate.sh approve t-1 'all green'"),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-pending", "t-1", "s1"),
      ev("add", "qa-gate-entered", "t-1", "s2"),
      ev("add", "rubric-pending", "t-1", "s2"),
      ev("add", "qa-approved", "t-1", "s3"),
      ev("remove", "qa-gate-entered", "t-1", "s3"),
      ev("remove", "qa-pending", "t-1", "s3"),
      ev("remove", "rubric-pending", "t-1", "s3"),
    ]);
  });

  it("interleaves scanners within ONE command string by match position", () => {
    const calls = [
      bash(
        "s4",
        "bash .claude/scripts/qa-gate.sh block t-2 'broken' && bd label remove t-2 qa-pending",
      ),
    ];
    expect(deriveBeadsLabelEvents(calls)).toEqual([
      ev("add", "qa-blocked", "t-2", "s4"),
      ev("remove", "qa-pending", "t-2", "s4"),
    ]);
  });

  it("returns [] for an empty tool-call list", () => {
    expect(deriveBeadsLabelEvents([])).toEqual([]);
  });
});

// ---------------------------------------------------------------------------
// 6. The rewritten label-milestones invariant — event-stream semantics.
// ---------------------------------------------------------------------------

/** Synthetic trace modelling a CORRECT approve flow as the recorder now
 *  captures it: qa-pending is added then removed in-run (so the net
 *  diff does NOT contain it — exactly the run-3/run-4 reality), while
 *  the event stream shows the full cycle. */
function eventCycleTrace(): Trace {
  const t = createEmptyTrace("synthetic-events", "p", "claude-opus-4-7");
  t.beadsLabelEvents = [
    ev("add", "qa-pending", "t-1", "src-label-add"),
    ev("add", "qa-gate-entered", "t-1", "src-gate-enter"),
    ev("add", "rubric-pending", "t-1", "src-gate-enter"),
    ev("add", "qa-approved", "t-1", "src-gate-approve"),
    ev("remove", "qa-gate-entered", "t-1", "src-gate-approve"),
    ev("remove", "qa-pending", "t-1", "src-gate-approve"),
    ev("remove", "rubric-pending", "t-1", "src-gate-approve"),
  ];
  // Net diff models reality: transient labels invisible, survivors only.
  t.beadsLabelTransitions = [
    { taskId: "t-1", added: ["backend", "qa-approved"], removed: [] },
  ];
  return t;
}

describe("invariant: label-milestones (event-stream semantics)", () => {
  it("PASSES on a correct approve flow: qa-pending add proven by the event stream even though removed in-run (net diff lacks it)", () => {
    const t = eventCycleTrace();
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(true);
    expect(r.skipped).toBeFalsy();
    expect(r.detail).toMatch(/qa-pending/);
  });

  it("defaults to milestones [qa-pending, qa-approved] when params are omitted", () => {
    const t = eventCycleTrace();
    const r = INVARIANTS["label-milestones"]!(t);
    expect(r.pass).toBe(true);
    expect(r.skipped).toBeFalsy();
  });

  it("SKIPS honestly on a trace that predates the events field (pre-3.5 recording)", () => {
    const t = eventCycleTrace();
    delete (t as Partial<Trace>).beadsLabelEvents;
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.skipped).toBe(true);
    expect(r.pass).toBe(true);
    expect(r.detail).toContain(
      "trace lacks beadsLabelEvents (pre-3.5 recording)",
    );
  });

  it("evaluateAll surfaces the legacy-trace case in `skipped`, not `failed`", () => {
    const t = eventCycleTrace();
    delete (t as Partial<Trace>).beadsLabelEvents;
    const agg = evaluateAll(t, [
      {
        name: "label-milestones",
        params: { milestones: ["qa-pending", "qa-approved"] },
      },
    ]);
    expect(agg.allPassed).toBe(true);
    expect(agg.skipped).toEqual(["label-milestones"]);
    expect(agg.failed).toEqual([]);
  });

  it("META-TEST: dropping the qa-pending ADD event from a passing trace flips to FAIL (the remove alone is not evidence of the add)", () => {
    const t = eventCycleTrace();
    t.beadsLabelEvents = (t.beadsLabelEvents ?? []).filter(
      (e) => !(e.action === "add" && e.label === "qa-pending"),
    );
    const agg = evaluateAll(t, [
      {
        name: "label-milestones",
        params: { milestones: ["qa-pending", "qa-approved"] },
      },
    ]);
    expect(agg.allPassed).toBe(false);
    expect(agg.failed).toEqual(["label-milestones"]);
    expect(agg.results[0]?.result.detail).toMatch(/qa-pending/);
  });

  it("META-TEST: empty event stream + empty net adds FAILS (empty is not the same as absent)", () => {
    const t = eventCycleTrace();
    t.beadsLabelEvents = [];
    t.beadsLabelTransitions = [];
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(false);
    expect(r.skipped).toBeFalsy();
    expect(r.detail).toMatch(/missing milestone/);
  });

  it("enforces declared ORDER among stream-visible adds: a stream that affirmatively shows misorder fails even if the net diff has the label", () => {
    const t = eventCycleTrace();
    t.beadsLabelEvents = [
      ev("add", "qa-approved", "t-1", "s-a"),
      ev("add", "qa-pending", "t-1", "s-b"),
    ];
    // qa-approved survives, so the net diff contains it — but the
    // stream shows its only add BEFORE qa-pending's, so the net-diff
    // complement must NOT rescue the ordering violation.
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(false);
    expect(r.detail).toMatch(/order/i);
  });

  it("net-diff complement: stream-invisible adds that survive the run (rubric-satisfied via grade-record) still prove their milestone", () => {
    const t = eventCycleTrace();
    // No rubric-satisfied event exists anywhere in the stream (the add
    // happens inside qa-gate.sh grade-record), but approve preserves it
    // so it appears in the post-run net diff.
    t.beadsLabelTransitions = [
      {
        taskId: "t-1",
        added: ["backend", "qa-approved", "rubric-satisfied"],
        removed: [],
      },
    ];
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "rubric-satisfied", "qa-approved"],
    });
    expect(r.pass).toBe(true);
    expect(r.detail).toMatch(/net-diff/);
  });

  it("extra intermediate add events are tolerated (subsequence, not exact match)", () => {
    const t = eventCycleTrace();
    t.beadsLabelEvents = [
      ev("add", "qa-pending", "t-1", "s1"),
      ev("add", "qa-blocked", "t-1", "s2"),
      ev("remove", "qa-blocked", "t-1", "s3"),
      ev("add", "qa-pending", "t-1", "s4"),
      ev("add", "qa-approved", "t-1", "s5"),
    ];
    const r = INVARIANTS["label-milestones"]!(t, {
      milestones: ["qa-pending", "qa-approved"],
    });
    expect(r.pass).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// 7. Real-trace grounding: the runs that PROVED the bug must now be
//    provable. We derive events offline from the committed seed traces
//    and re-evaluate the invariant — flipping the exact 9ke headline.
// ---------------------------------------------------------------------------

describe.skipIf(!existsSync(RUN4_TRACE))(
  "real-trace grounding: run 4 (node-react-auth 2026-06-12T02-18-12-871Z)",
  () => {
    function loadRun4(): Trace {
      return JSON.parse(readFileSync(RUN4_TRACE, "utf8").trim()) as Trace;
    }

    it("derivation surfaces the in-run qa-pending cycle the net diff lost", () => {
      const trace = loadRun4();
      const events = deriveBeadsLabelEvents(trace.toolCalls);
      const pendingAdd = events.findIndex(
        (e) =>
          e.action === "add" &&
          e.label === "qa-pending" &&
          e.taskId === "auth-neb.1",
      );
      const approvedAdd = events.findIndex(
        (e) =>
          e.action === "add" &&
          e.label === "qa-approved" &&
          e.taskId === "auth-neb.1",
      );
      expect(pendingAdd).toBeGreaterThanOrEqual(0);
      expect(approvedAdd).toBeGreaterThan(pendingAdd);
      // The net diff demonstrably lacks qa-pending (the 9ke evidence).
      const netAdds = new Set(
        trace.beadsLabelTransitions.flatMap((t) => t.added),
      );
      expect(netAdds.has("qa-pending")).toBe(false);
      expect(netAdds.has("qa-approved")).toBe(true);
    });

    it("the previously-impossible invariant PASSES on run 4 once events are derived", () => {
      const trace = loadRun4();
      const withEvents: Trace = {
        ...trace,
        beadsLabelEvents: deriveBeadsLabelEvents(trace.toolCalls),
      };
      const r = INVARIANTS["label-milestones"]!(withEvents, {
        milestones: ["qa-pending", "qa-approved"],
      });
      expect(r.pass).toBe(true);
      expect(r.skipped).toBeFalsy();
    });
  },
);

describe.skipIf(!existsSync(RUN3_TRACE))(
  "real-trace grounding: run 3 (node-react-auth 2026-06-12T00-50-56-312Z)",
  () => {
    function loadRun3(): Trace {
      return JSON.parse(readFileSync(RUN3_TRACE, "utf8").trim()) as Trace;
    }

    it("run 3's qa-pending adds arrive via `bd create -l backend,qa-pending` and are derived as creation-label events", () => {
      const trace = loadRun3();
      const events = deriveBeadsLabelEvents(trace.toolCalls);
      const pendingAdds = events.filter(
        (e) => e.action === "add" && e.label === "qa-pending",
      );
      expect(pendingAdds.length).toBeGreaterThanOrEqual(2);
      // Creation-label events carry taskId "" (id assigned server-side).
      expect(pendingAdds.some((e) => e.taskId === "")).toBe(true);
    });

    it("the previously-impossible invariant PASSES on run 3 once events are derived", () => {
      const trace = loadRun3();
      const withEvents: Trace = {
        ...trace,
        beadsLabelEvents: deriveBeadsLabelEvents(trace.toolCalls),
      };
      const r = INVARIANTS["label-milestones"]!(withEvents, {
        milestones: ["qa-pending", "qa-approved"],
      });
      expect(r.pass).toBe(true);
      expect(r.skipped).toBeFalsy();
    });
  },
);
