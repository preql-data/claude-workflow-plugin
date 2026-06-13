/**
 * invariants.ts — model-agnostic invariant engine for live e2e traces.
 *
 * Introduced in v3.1.0 spec item 0.8 (golden retirement). Each fixture's
 * `fixture.yaml` declares an `invariants:` block — a list of named checks
 * to run against the recorded `Trace`. The engine evaluates each check
 * and returns `{pass, detail}`. Specs assert every declared invariant
 * passes; a failure cites the invariant name plus its detail line.
 *
 * Why invariants, not golden-trace equality:
 *   Goldens drift with every model snapshot. Day-zero model auto-upgrade
 *   (cross-cutting principle 1) makes every committed golden stale on
 *   arrival. Invariants are properties of the workflow contract
 *   (orchestrator never edits, QA approval gates Stop, declared
 *   specialists are the only ones invoked) — they hold across model
 *   versions by construction.
 *
 * Engine philosophy:
 *   - Each invariant is one named function in `INVARIANTS`. Adding an
 *     invariant is a one-row edit plus a META-TEST in
 *     `_invariants.unit.spec.ts`.
 *   - Invariants take the raw `Trace` (NOT the normalized one) so they
 *     can read fields the normalizer collapses (e.g. tool input shapes).
 *     Where normalization helps, callers can reuse `normalizeTrace`
 *     internally — but the engine surface stays raw-Trace-in.
 *   - Honest about gaps: where the trace can't fully observe the
 *     invariant's underlying property (e.g. label state at the moment a
 *     Stop hook fires), the implementation documents the approximation
 *     and asserts the strongest checkable form. The `completion-contract`
 *     invariant is implemented as `skipped` because the trace truly does
 *     not capture structured completion payloads; pretending otherwise
 *     would make the gate worthless.
 *   - Plugin-qualifier tolerant matching for subagent types, mirroring
 *     `assertions.matchers.subagentInvoked` — invariants must treat
 *     `backend` and `claude-workflow:backend` as the same role.
 */
import type { Trace, ToolCall } from "./trace.js";

/** Result of evaluating a single invariant against a trace. */
export interface InvariantResult {
  /** Whether the invariant held. */
  pass: boolean;
  /** Free-form diagnostic line. When `pass === true`, may still be
   *  informative ("matched milestones: qa-pending, qa-approved").
   *  When `pass === false`, MUST identify the violation in enough detail
   *  for an engineer to start debugging without reopening the trace. */
  detail: string;
  /** When set, the invariant was skipped — neither pass nor fail.
   *  Reserved for invariants that can't be checked against the current
   *  trace schema. Skip reasons MUST be documented in this file
   *  (so the gap is visible) and surfaced to operators via
   *  `evaluateAll`. */
  skipped?: boolean;
}

/**
 * Signature for invariant implementations. Implementations receive the
 * raw Trace plus an optional params object the fixture passed in
 * (`invariants: [{ name, params: {...} }]` in fixture.yaml).
 */
export type InvariantImpl = (
  trace: Trace,
  params?: Record<string, unknown>,
) => InvariantResult;

/** Strip plugin qualifier from a subagent/agent type string.
 *  `claude-workflow:backend` -> `backend`. Idempotent for bare forms. */
function stripQualifier(type: string): string {
  return type.includes(":") ? type.slice(type.indexOf(":") + 1) : type;
}

/** Equality check that is tolerant of plugin qualifiers in either direction. */
function typesMatch(a: string, b: string): boolean {
  if (a === b) return true;
  return stripQualifier(a) === stripQualifier(b);
}

/** Build a map from tool_use id to its ToolCall, for parent-chain walks. */
function buildToolCallIndex(trace: Trace): Map<string, ToolCall> {
  const map = new Map<string, ToolCall>();
  for (const call of trace.toolCalls) map.set(call.id, call);
  return map;
}

/**
 * Is this tool call attributable to the root orchestrator (not nested
 * inside any subagent)? Walk the parentToolUseId chain — if no ancestor
 * is a Task call (i.e. the call sits at the top level of the SDK's
 * conversation), it's the orchestrator's.
 *
 * Subagents are spawned via `Task` (or older `Agent`). A child tool call
 * carries the parent Task's tool_use id in `parentToolUseId`. Walking up
 * the chain, every step is a tool call; if we hit a Task call along the
 * way the call is attributable to that subagent, not the orchestrator.
 *
 * Returns true iff:
 *   - `call.parentToolUseId` is null/undefined (top level), OR
 *   - walking up the chain hits no Task/Agent before the root.
 *
 * The orchestrator itself is invoked via Agent/Task in some fixtures;
 * we still treat its direct edits as "orchestrator edits" because the
 * orchestrator role is the agent doing the editing. A subagent invoked
 * BY the orchestrator's Task call is a different story — its tool calls
 * are inside that subagent's scope.
 */
function isOrchestratorAttributable(
  call: ToolCall,
  index: Map<string, ToolCall>,
): boolean {
  let parentId = call.parentToolUseId;
  const seen = new Set<string>();
  while (parentId && !seen.has(parentId)) {
    seen.add(parentId);
    const parent = index.get(parentId);
    if (!parent) {
      // Parent not in trace — assume top-level / orchestrator-attributable.
      return true;
    }
    if (parent.name === "Task" || parent.name === "Agent") {
      // Inside a subagent's scope.
      return false;
    }
    parentId = parent.parentToolUseId;
  }
  return true;
}

// ============================================================================
// Invariant 1: stop-requires-approval
// ============================================================================
/**
 * No Stop hook ever allowed completion while the active task lacked
 * `qa-approved` (or the audited escape `qa-deferred` from 0.2).
 *
 * APPROXIMATION:
 *   The trace records hookOutputs as a temporal sequence and
 *   beadsLabelTransitions as a single post-run before/after diff per
 *   task (not interleaved per-event). So we cannot observe label state
 *   at the exact moment a Stop hook fires. The strongest checkable form
 *   asserted here:
 *
 *     If ANY Stop hook output emitted an `allow` decision (decision
 *     absent / null / "approve"), THEN at least one transition's added
 *     labels must include `qa-approved` or `qa-deferred`.
 *
 *   This catches the failure mode the invariant guards against — Stop
 *   allowed completion with no QA approval anywhere in the run — while
 *   being honest about the temporal blind spot. A trace with a single
 *   Stop:allow late in the run AND a single qa-approved label add
 *   anywhere passes, even though we can't prove ordering. The
 *   block-then-recover pattern naturally satisfies this (the final
 *   Stop:allow comes after qa-approved is set on the task).
 *
 *   When a Stop hook output has `decision === "block"`, it does NOT
 *   count as an `allow` for this check. A trace with only Stop:block
 *   events and no qa-approved transitions PASSES this invariant
 *   (block IS the gate working correctly), though such a trace
 *   typically fails other assertions in the spec.
 */
function invStopRequiresApproval(trace: Trace): InvariantResult {
  const stopAllows = trace.hookOutputs.filter(
    (h) =>
      h.event === "Stop" &&
      (h.decision === "approve" ||
        h.decision === undefined ||
        h.decision === null),
  );
  if (stopAllows.length === 0) {
    return {
      pass: true,
      detail:
        "no Stop hook emitted an allow decision (vacuously satisfied)",
    };
  }
  const sawApproval = trace.beadsLabelTransitions.some(
    (t) =>
      t.added.includes("qa-approved") || t.added.includes("qa-deferred"),
  );
  if (sawApproval) {
    const allTransitions = trace.beadsLabelTransitions
      .filter(
        (t) =>
          t.added.includes("qa-approved") || t.added.includes("qa-deferred"),
      )
      .map((t) => t.taskId);
    return {
      pass: true,
      detail: `${stopAllows.length} Stop:allow event(s) with qa-approved/qa-deferred recorded on: [${allTransitions.join(", ")}]`,
    };
  }
  return {
    pass: false,
    detail: `Stop hook emitted ${stopAllows.length} allow decision(s) but no task transitioned to qa-approved or qa-deferred — gate may have leaked`,
  };
}

// ============================================================================
// Invariant 2: orchestrator-no-edits
// ============================================================================
/**
 * The orchestrator must not call Write / Edit / MultiEdit directly.
 * Editing is the specialist's job; the orchestrator delegates.
 *
 * Implementation: walk parentToolUseId chains and find any
 * Write/Edit/MultiEdit toolCall that is orchestrator-attributable
 * (i.e. not inside a subagent's Task scope). Plugin guard
 * `prevent-orchestrator-edits.sh` is the runtime enforcement; this
 * invariant is the trace-level proof the guard is effective.
 */
function invOrchestratorNoEdits(trace: Trace): InvariantResult {
  const editTools = new Set(["Write", "Edit", "MultiEdit"]);
  const index = buildToolCallIndex(trace);
  const offenders = trace.toolCalls.filter(
    (c) => editTools.has(c.name) && isOrchestratorAttributable(c, index),
  );
  if (offenders.length === 0) {
    return {
      pass: true,
      detail: "no Write/Edit/MultiEdit attributable to the orchestrator",
    };
  }
  const sample = offenders
    .slice(0, 5)
    .map((c) => {
      const path =
        (c.input as { file_path?: string; path?: string } | undefined)
          ?.file_path ??
        (c.input as { file_path?: string; path?: string } | undefined)
          ?.path ??
        "<unknown path>";
      return `${c.name}(${path})`;
    })
    .join(", ");
  return {
    pass: false,
    detail: `${offenders.length} orchestrator-attributable edit call(s): ${sample}${offenders.length > 5 ? " …" : ""}`,
  };
}

// ============================================================================
// Invariant 3: completion-contract
// ============================================================================
/**
 * Every specialist completion payload carries all six F7 fields
 * (task_id, files_changed, tests_added, decisions, blockers,
 * llm_observations).
 *
 * SKIPPED: the current `Trace` schema does not capture specialist
 * completion payloads as structured data. The closest signals are the
 * final assistant text of each subagent and free-form `notes` in
 * `bd_update_task` calls — neither is parseable for a six-field
 * presence check without false positives (regex over assistant prose
 * is not evidence). Faking this invariant would make the gate
 * worthless.
 *
 * TRACE GAP: capturing the completion payload as structured trace
 * fields is a Phase A follow-up (it ties into the rubric grader's
 * input packet). When that lands, this skip becomes a real check.
 */
function invCompletionContract(_trace: Trace): InvariantResult {
  return {
    pass: true,
    skipped: true,
    detail:
      "skipped: trace does not capture structured specialist completion payloads (documented trace gap; see invariants.ts).",
  };
}

// ============================================================================
// Invariant 4: label-milestones
// ============================================================================
/**
 * Fixture-declared milestones appear as an ordered subsequence of
 * label-ADD events in the trace's event stream. This REPLACES the
 * pre-3.5 net-diff set-membership check, which was STRUCTURALLY unable
 * to pass on correct approve-flow runs (claude-workflow-plugin-9ke):
 * `beadsLabelTransitions` is a post-run net diff, so a label added then
 * removed in-run — `qa-pending` in every correct gate cycle — was
 * invisible, and the invariant failed identically on Phase B runs 3
 * and 4 despite both runs cycling the gate correctly.
 *
 * EVIDENCE MODEL (strongest honestly-checkable form):
 *
 *   1. PRIMARY — `trace.beadsLabelEvents`, the ordered event stream the
 *      recorder derives from the tool-call sequence (qa-gate.sh
 *      subcommands imply events per the gate contract; raw
 *      `bd label add/remove`, `bd create -l`, `bd update
 *      --add/remove-label`, and the MCP bd surface yield direct
 *      events — see lib/labelEvents.ts). Milestones must match as a
 *      subsequence of ADD events: each declared milestone's add must
 *      appear at or after the previous milestone's match position.
 *      A transient label (added then removed) is therefore full
 *      evidence — the remove no longer hides the add.
 *
 *   2. NET-DIFF COMPLEMENT — a milestone with ZERO add events anywhere
 *      in the stream may still be proven by membership in the net-diff
 *      adds. This exists for STREAM-INVISIBLE adds: `rubric-satisfied`
 *      is set INSIDE `qa-gate.sh grade-record` (no tool call ever
 *      shows the label; the verdict lives in piped JSON), and approve
 *      preserves it, so it survives to the post-run diff. Without this
 *      complement the rubric-revision-loop fixture would recreate the
 *      exact impossible-invariant bug this rewrite fixes. Ordering is
 *      not verifiable for net-diff matches (the cursor does not
 *      advance); the provenance string says so.
 *
 *   3. ORDER IS ENFORCED WHERE THE STREAM CAN SEE IT — if a milestone
 *      HAS add events in the stream but only BEFORE the preceding
 *      milestone's match (affirmative misorder), that is a FAILURE;
 *      the net-diff complement must not rescue it.
 *
 * HONESTY CAVEATS:
 *   - Events are derived from tool-call INPUTS (intent), not observed
 *     Beads state — a command that failed at runtime still yields its
 *     events (the trace does not capture per-call results). The
 *     net-diff remains the end-state ground truth alongside.
 *   - Traces recorded before the events field existed (all pre-3.5
 *     cassettes/seeds) are SKIPPED, not retro-failed: absence of
 *     `beadsLabelEvents` means the recorder never derived events, and
 *     pretending the net diff could answer the milestone question is
 *     the exact bug this invariant had. An EMPTY events array is NOT
 *     absence — it means the recorder ran and saw no label activity,
 *     and the check proceeds (typically failing, loudly and correctly).
 *
 * Params:
 *   `milestones: string[]` — required label adds, in order. Defaults to
 *     `['qa-pending', 'qa-approved']` so a fixture that declares the
 *     invariant by name without params still gets the canonical
 *     coverage.
 */
function invLabelMilestones(
  trace: Trace,
  params?: Record<string, unknown>,
): InvariantResult {
  const milestones = Array.isArray(params?.milestones)
    ? (params.milestones as unknown[]).filter(
        (m): m is string => typeof m === "string",
      )
    : ["qa-pending", "qa-approved"];

  const events = Array.isArray(trace.beadsLabelEvents)
    ? trace.beadsLabelEvents
    : undefined;
  if (events === undefined) {
    return {
      pass: true,
      skipped: true,
      detail:
        "skipped: trace lacks beadsLabelEvents (pre-3.5 recording) — the net-diff beadsLabelTransitions cannot observe transient labels (added then removed in-run), so milestone adds are unevaluable on this trace; re-record with the current recorder to evaluate (claude-workflow-plugin-9ke).",
    };
  }

  // Net-diff adds: the complement channel for stream-invisible adds.
  const netAdds = new Set<string>();
  for (const t of trace.beadsLabelTransitions) {
    for (const l of t.added) netAdds.add(l);
  }

  // Indexed add events, preserving stream order.
  const addEvents: Array<{ label: string; i: number }> = [];
  events.forEach((e, i) => {
    if (e.action === "add") addEvents.push({ label: e.label, i });
  });

  let cursor = 0; // next stream match must sit at index >= cursor
  const provenance: string[] = [];
  const missing: string[] = [];
  const misordered: string[] = [];
  for (const m of milestones) {
    const hit = addEvents.find((a) => a.i >= cursor && a.label === m);
    if (hit) {
      cursor = hit.i + 1;
      provenance.push(`${m}@event[${hit.i}]`);
      continue;
    }
    if (addEvents.some((a) => a.label === m)) {
      // The stream affirmatively shows this add only BEFORE the
      // preceding milestone's match — a real ordering violation that
      // the net-diff complement must not paper over.
      misordered.push(m);
      continue;
    }
    if (netAdds.has(m)) {
      provenance.push(`${m}@net-diff`);
      continue;
    }
    missing.push(m);
  }

  if (missing.length === 0 && misordered.length === 0) {
    return {
      pass: true,
      detail: `all ${milestones.length} milestone label add(s) proven: [${provenance.join(", ")}] (@event[i] = ordered event-stream match; @net-diff = stream-invisible add that survived to the post-run diff — see invariants.ts).`,
    };
  }
  const observedAdds = addEvents.map((a) => a.label).join(", ") || "<none>";
  const netAddsStr = [...netAdds].sort().join(", ") || "<none>";
  const parts: string[] = [];
  if (missing.length > 0) {
    parts.push(`missing milestone label add(s): [${missing.join(", ")}]`);
  }
  if (misordered.length > 0) {
    parts.push(
      `milestone label add(s) out of declared order: [${misordered.join(", ")}] (each has add event(s) in the stream only before the preceding milestone's match)`,
    );
  }
  return {
    pass: false,
    detail: `${parts.join("; ")} — declared order: [${milestones.join(", ")}]; observed add events (in order): [${observedAdds}]; net-diff adds: [${netAddsStr}]`,
  };
}

// ============================================================================
// Invariant 5: declared-subagents-only
// ============================================================================
/**
 * Every subagent the run invoked matches one of the fixture's declared
 * specialist types. Plugin-qualifier tolerant: a declared `backend`
 * matches an invocation of `claude-workflow:backend`. Catches the
 * failure mode where the orchestrator decomposes into an unexpected
 * role (e.g. spawning a `claude-workflow:db-migration` agent that
 * doesn't exist).
 *
 * The orchestrator itself is allowed even if not in the declared set —
 * a fixture's `expected_subagents` lists specialists invoked BY the
 * orchestrator, not the orchestrator role itself. We tolerate any
 * invocation whose type matches `orchestrator` (qualifier-stripped) or
 * `general-purpose` (the SDK fallback when a plugin agent doesn't
 * register — observed in cassettes/replays/node-react-auth-*).
 *
 * Params:
 *   `declared: string[]` — declared specialist types. Required; if
 *     missing, the invariant errors out (a fixture that doesn't declare
 *     its specialists should not opt into this invariant).
 */
function invDeclaredSubagentsOnly(
  trace: Trace,
  params?: Record<string, unknown>,
): InvariantResult {
  const declared = Array.isArray(params?.declared)
    ? (params.declared as unknown[]).filter(
        (m): m is string => typeof m === "string",
      )
    : [];
  if (declared.length === 0) {
    return {
      pass: false,
      detail:
        "declared-subagents-only: missing `declared` parameter — fixture must list specialist types in fixture.yaml invariants block.",
    };
  }
  // Always-allowed roles: the orchestrator itself plus the SDK's
  // general-purpose fallback. Declared specialists are matched via
  // qualifier-stripped equality.
  const alwaysAllowed = new Set(["orchestrator", "general-purpose"]);
  const undeclared: string[] = [];
  for (const inv of trace.subagentInvocations) {
    const bare = stripQualifier(inv.type);
    if (alwaysAllowed.has(bare)) continue;
    if (declared.some((d) => typesMatch(d, inv.type))) continue;
    undeclared.push(inv.type);
  }
  if (undeclared.length === 0) {
    return {
      pass: true,
      detail: `all ${trace.subagentInvocations.length} invocation(s) matched declared specialists or always-allowed roles`,
    };
  }
  return {
    pass: false,
    detail: `${undeclared.length} undeclared subagent invocation(s): [${[...new Set(undeclared)].sort().join(", ")}] — declared was [${declared.join(", ")}]`,
  };
}

// ============================================================================
// Invariant 6: qa-queried-impact-of
// ============================================================================
/**
 * QA's regression-impact analysis ran for the landed diff. This invariant
 * encodes the contract in the QA agent prompt (extends J19): before
 * approving a diff, the impact of every changed symbol must be analysed so
 * high-fan-in callers surface as regression candidates, not just the tests
 * shipped in the diff.
 *
 * WHY THIS IS NOT "QA CALLED impact_of" ANY MORE (n6d /
 * claude-workflow-plugin-llh.2, rewritten in llh.15):
 *   Across FOUR paid live runs the QA subagent made ZERO `impact_of` MCP
 *   tool-calls regardless of prompt strength (evidence: the Phase B seed
 *   traces + `bd show claude-workflow-plugin-n6d`). Prompts are
 *   suggestions. n6d therefore moved the impact analysis OUT of Claude's
 *   tool interface into a DETERMINISTIC ARTIFACT the model cannot skip:
 *     - `qa-gate.sh enter <task-id>` invokes `.claude/scripts/impact-report.sh`,
 *       which drives the code-graph server DIRECTLY over stdio JSON-RPC and
 *       writes `.claude/.qa-tracking/impact-report-<task-id>.json`
 *       ({generated_at, task_id, change_set_hash, files:[{file,impact}],
 *       server:"code-graph"|"absent"}).
 *     - `qa-gate.sh approve` REFUSES (exit 2) unless that artifact exists
 *       and its `change_set_hash` matches the CURRENT changed-files list,
 *       with one documented escape: `--no-impact-report '<reason>'`.
 *   Those code-graph stdio calls are NOT Claude tool_uses, so a CORRECT
 *   n6d run shows ZERO `impact_of` tool_uses in the trace. The old
 *   invariant counted them and so FAILED every correct n6d run by
 *   construction. Asserting the disproven "QA calls impact_of" signal is
 *   exactly the bug this rewrite removes — DO NOT reintroduce it.
 *
 * THE MECHANICAL SIGNATURE THIS INVARIANT ASSERTS (strongest combination
 * observable in the trace; the trace records toolCalls — incl. Bash
 * `input.command` and Read `input.file_path` — plus the QA subagent's
 * `toolUseId` for parent-chain attribution):
 *
 *   PASS — code-graph present + fileWrites>0 + a QA-attributable n6d
 *     ARTIFACT FOOTPRINT (a Bash/Read referencing the
 *     `impact-report-<taskid>.json` path — the QA prompt's mandated FIRST
 *     ACTION is `cat .claude/.qa-tracking/impact-report-<task-id>.json`,
 *     `.claude/agents/qa.md` §3a — OR an `impact-report.sh` invocation)
 *     AND a QA-attributable `qa-gate.sh approve` with NO
 *     `--no-impact-report` bypass. The unbypassed approve is the
 *     MECHANICAL FLOOR: approve refuses without a fresh artifact, so an
 *     unbypassed approve attributable to QA proves the artifact existed
 *     and was current (approve-succeeded-unbypassed => fresh artifact).
 *     The footprint is what distinguishes a genuine n6d run from a pre-n6d
 *     recording (see the SKIP branch) — both carry enter+approve, only the
 *     post-n6d run references the artifact.
 *
 *   FAIL — code-graph present + fileWrites>0 + a QA-attributable
 *     `qa-gate.sh approve … --no-impact-report <reason>` whose reason is
 *     NOT a code-graph-absent reason. The mechanical impact gate was
 *     genuinely waived. `--no-impact-report` is a post-n6d-only construct
 *     (it appears in NO pre-n6d trace), so it is an unambiguous post-n6d
 *     signal — a bypass here is a real skip, not a recording gap.
 *
 *   SKIP "code-graph absent" — no code-graph tool in `toolsAvailable`
 *     (server not loaded; agents degrade to search-only per
 *     MCP_SERVERS.md), OR the impact-report footprint shows
 *     `server: "absent"`, OR a bypass reason names code-graph absence.
 *     The artifact's documented degradation is a valid outcome; the gate
 *     guards against SKIPPED analysis, not absent environments.
 *
 *   SKIP vacuous — fileWrites empty: no diff to assess, contract vacuous.
 *
 *   SKIP "pre-n6d recording" — code-graph present + fileWrites>0 but NO
 *     artifact footprint AND NO `--no-impact-report` flag anywhere
 *     QA-attributable. The n6d mechanic did not exist when the trace was
 *     recorded (every pre-llh.2 seed trace lands here: it has
 *     QA-attributable `qa-gate.sh enter`/`approve` but zero impact-report
 *     references and zero bypass flags). Retro-failing it would re-assert
 *     a recording-layer gap as a workflow defect — the same trap the llh.4
 *     "pre-3.5 recording" skip avoids for `label-milestones`. Re-record
 *     under the current (n6d) plugin to evaluate.
 *
 *   SKIP "footprint without approve" (llh.16) — code-graph present +
 *     fileWrites>0 + an artifact footprint BUT no QA-attributable
 *     unbypassed approve. The footprint match is a loose string test (it
 *     fires on any command text mentioning impact-report-*.json or
 *     impact-report.sh), so a hand-built mention — an `echo`/`grep` of the
 *     path — trips it without any real consultation. Footprint-ALONE is
 *     therefore NOT a trustworthy PASS: the only defensible green is
 *     footprint + an unbypassed approve (the PASS branch), because
 *     approve REFUSES without a fresh artifact and that refusal is the
 *     co-signal a bare mention lacks. We SKIP rather than PASS so a mere
 *     mention cannot green the invariant, and rather than FAIL because the
 *     approve may simply have happened outside the captured QA scope.
 *
 * NOTE the `min_calls` param (legacy: minimum QA `impact_of` calls) is now
 * vestigial — the disproven signal it tuned is gone. It is still accepted
 * and ignored so existing fixture.yaml `params: {min_calls: N}` entries do
 * not become "unknown param" surprises.
 */
function invQaQueriedImpactOf(
  trace: Trace,
  _params?: Record<string, unknown>,
): InvariantResult {
  // ---- code-graph presence (server-loaded?) --------------------------------
  // Any tool whose name carries `code-graph` is evidence the server
  // registered. SDK-rewritten form `mcp__plugin_<plugin>_code-graph__<tool>`
  // is the common shape; bare server-tool forms are tolerated too.
  const codeGraphPattern = /code-graph/;
  const hasCodeGraphServer = trace.toolsAvailable.some((t) =>
    codeGraphPattern.test(t),
  );
  if (!hasCodeGraphServer) {
    return {
      pass: true,
      skipped: true,
      detail:
        "skipped: trace.toolsAvailable shows no code-graph tools — code-graph server was not loaded (agents degrade to search-only flow per MCP_SERVERS.md migration); the n6d impact-report degrades to server:\"absent\".",
    };
  }

  // ---- vacuous skip: nothing to assess --------------------------------------
  if (trace.fileWrites.length === 0) {
    return {
      pass: true,
      skipped: true,
      detail:
        "skipped: trace.fileWrites is empty — no diff for QA to assess, regression-impact contract is vacuous.",
    };
  }

  // ---- QA attribution -------------------------------------------------------
  // QA Task tool_use ids; any call whose parent chain reaches one is
  // QA-attributable. Plugin-qualifier tolerant (`qa` == `claude-workflow:qa`).
  const qaTaskIds = new Set<string>();
  for (const inv of trace.subagentInvocations) {
    if (stripQualifier(inv.type) === "qa") {
      qaTaskIds.add(inv.toolUseId);
    }
  }
  if (qaTaskIds.size === 0) {
    return {
      pass: false,
      detail:
        "no QA subagent invocation found in trace.subagentInvocations — the QA gate never ran, so the impact analysis cannot be attributed to QA.",
    };
  }

  const index = buildToolCallIndex(trace);
  const isQaAttributable = (call: ToolCall): boolean => {
    let parentId = call.parentToolUseId;
    const seen = new Set<string>();
    while (parentId && !seen.has(parentId)) {
      seen.add(parentId);
      if (qaTaskIds.has(parentId)) return true;
      const parent = index.get(parentId);
      if (!parent) break;
      parentId = parent.parentToolUseId;
    }
    return false;
  };

  // ---- pull the command/path text out of a tool call ------------------------
  // Bash carries `input.command`; Read/Edit/Write carry `input.file_path`.
  // We sniff both so the artifact footprint is detected whether QA `cat`s
  // the report (Bash) or Reads it (Read tool_use).
  const callText = (call: ToolCall): string => {
    const input = call.input as
      | { command?: unknown; file_path?: unknown }
      | undefined;
    const parts: string[] = [];
    if (input && typeof input.command === "string") parts.push(input.command);
    if (input && typeof input.file_path === "string")
      parts.push(input.file_path);
    return parts.join("\n");
  };

  // The n6d artifact footprint: a reference to the per-task impact-report
  // JSON, or an explicit `impact-report.sh` invocation. Both are post-n6d
  // constructs — no pre-n6d trace contains them.
  const artifactPattern =
    /impact-report-[^\s'".]+\.json|impact-report\.sh/;
  // A `qa-gate.sh approve` invocation (any args).
  const approvePattern = /qa-gate\.sh\s+approve\b/;
  // The documented bypass flag. A bypass whose reason mentions code-graph
  // being absent/unavailable is the honest degradation, not a skip.
  const bypassPattern = /--no-impact-report\b/;
  const codeGraphAbsentReason =
    /code-?graph[^\n]*\b(absent|unavailable|missing|not (installed|available|present)|down)\b|\b(absent|unavailable|missing|no)\b[^\n]*code-?graph/i;

  let qaArtifactFootprint = false;
  let qaApproveUnbypassed = false;
  let qaApproveBypassedReason: string | null = null;
  let qaApproveBypassDegradation = false;

  for (const call of trace.toolCalls) {
    if (!isQaAttributable(call)) continue;
    const text = callText(call);
    if (!text) continue;
    if (artifactPattern.test(text)) qaArtifactFootprint = true;
    if (approvePattern.test(text)) {
      if (bypassPattern.test(text)) {
        qaApproveBypassedReason = text;
        if (codeGraphAbsentReason.test(text))
          qaApproveBypassDegradation = true;
      } else {
        qaApproveUnbypassed = true;
      }
    }
  }

  // ---- decide ---------------------------------------------------------------
  // A code-graph-absent bypass reason is the documented degradation -> SKIP.
  if (qaApproveBypassedReason && qaApproveBypassDegradation) {
    return {
      pass: true,
      skipped: true,
      detail:
        "skipped: QA approved with --no-impact-report and a code-graph-absent reason — the n6d impact-report's documented degradation (server unbootable/uninstalled); the impact pass was manual. The gate guards skipped analysis, not absent environments.",
    };
  }

  // A bypass with any OTHER reason means the mechanical impact gate was
  // genuinely waived -> FAIL. This is post-n6d-unambiguous: the flag is a
  // post-n6d-only construct.
  if (qaApproveBypassedReason) {
    return {
      pass: false,
      detail:
        "qa-queried-impact-of: QA approved with --no-impact-report (bypass) and no code-graph-absent reason — the mechanical impact-report gate (n6d) was genuinely waived, so the regression-impact analysis was skipped. Approve without the bypass after regenerating the artifact (bash .claude/scripts/impact-report.sh <task-id>), or record a code-graph-absent reason if the server truly is unavailable.",
    };
  }

  // No bypass. The positive n6d signature is the artifact footprint plus an
  // unbypassed approve (approve-succeeded-unbypassed => the refusal let it
  // through => a fresh artifact existed).
  if (qaArtifactFootprint && qaApproveUnbypassed) {
    return {
      pass: true,
      detail:
        "QA consulted the mechanical impact report (n6d artifact footprint) and approved without the --no-impact-report bypass — the unbypassed approve proves a fresh impact-report-<taskid>.json existed (approve refuses otherwise). Impact analysis ran via impact-report.sh; impact_of MCP tool_uses are intentionally absent from the trace post-n6d (they run inside the script over stdio).",
    };
  }

  // Footprint present but NO QA-attributable unbypassed approve observable
  // (the approve happened outside the captured QA scope, OR the "footprint"
  // is a hand-built mention — an `echo`/`grep` of impact-report-*.json or
  // impact-report.sh — with no approve to confirm a real consultation).
  //
  // llh.16: this is now a SKIP, not a PASS. The artifactPattern is a loose
  // string match (it fires on any command text mentioning the artifact
  // path), so footprint-ALONE is forgeable and cannot be trusted to green
  // the invariant. The ONLY defensible PASS is Branch A above
  // (footprint + unbypassed approve): an unbypassed successful approve
  // mechanically proves a FRESH artifact existed, because qa-gate.sh approve
  // REFUSES without one — that refusal is the load-bearing co-signal a bare
  // mention lacks. Without it we cannot confirm the mechanic actually ran,
  // so we SKIP ("consultation footprint present but no in-scope approve to
  // confirm") rather than assert a green we cannot defend. The legit live
  // signature (footprint + unbypassed approve) is unaffected — it already
  // PASSed via Branch A and never reaches here.
  if (qaArtifactFootprint) {
    return {
      pass: true,
      skipped: true,
      detail:
        "skipped: consultation footprint present (an impact-report-<taskid>.json / impact-report.sh reference) but no in-scope unbypassed qa-gate.sh approve to confirm it. The artifact reference alone is a loose string match (a hand-built echo/grep mention trips it), so it is not a trustworthy PASS signal on its own — only footprint + an unbypassed approve (Branch A) is, because approve REFUSES without a fresh artifact. Re-evaluate with the approve in QA scope.",
    };
  }

  // No footprint AND no bypass flag anywhere QA-attributable -> the n6d
  // mechanic left no trace, i.e. the run was recorded before n6d existed.
  // SKIP rather than retro-fail (llh.4 "pre-3.5 recording" precedent).
  return {
    pass: true,
    skipped: true,
    detail:
      "skipped: pre-n6d recording — code-graph present and fileWrites>0, but the trace carries no impact-report artifact footprint (no impact-report-<taskid>.json reference, no impact-report.sh call) and no --no-impact-report flag, so the n6d mechanic (qa-gate.sh enter generates the artifact; approve enforces it — claude-workflow-plugin-llh.2) did not exist when this trace was recorded. The legacy QA-attributed impact_of signal is disproven (4 live runs, 0 calls), so its absence is not a failure. Re-record under the current plugin to evaluate.",
  };
}

// ============================================================================
// Registry
// ============================================================================
/**
 * The named registry of invariants. Fixture.yaml `invariants:` entries
 * reference these names. Adding a new invariant is:
 *   1. Implement the function above with the same signature.
 *   2. Register here.
 *   3. Add a META-TEST in `_invariants.unit.spec.ts` (one violation
 *      mutation per invariant, asserting the engine catches it).
 */
export const INVARIANTS: Record<string, InvariantImpl> = {
  "stop-requires-approval": invStopRequiresApproval,
  "orchestrator-no-edits": invOrchestratorNoEdits,
  "completion-contract": invCompletionContract,
  "label-milestones": invLabelMilestones,
  "declared-subagents-only": invDeclaredSubagentsOnly,
  "qa-queried-impact-of": invQaQueriedImpactOf,
};

/** Returns the sorted list of registered invariant names. Useful for
 *  enumeration / docs / META-TEST coverage assertions. */
export function listInvariants(): string[] {
  return Object.keys(INVARIANTS).sort();
}

/** Spec for one invariant entry in a fixture.yaml. */
export interface InvariantSpec {
  name: string;
  params?: Record<string, unknown>;
}

/** Aggregate result for `evaluateAll`. */
export interface EvaluateAllResult {
  results: Array<{
    name: string;
    params?: Record<string, unknown>;
    result: InvariantResult;
  }>;
  /** True iff every non-skipped invariant passed. */
  allPassed: boolean;
  /** Names of invariants that were skipped (documented trace gaps). */
  skipped: string[];
  /** Names of invariants that failed. */
  failed: string[];
}

/**
 * Evaluate every invariant in `specs` against `trace`. Order of evaluation
 * mirrors the fixture's declaration order so failure logs read left-to-right.
 * Unknown invariant names produce a synthetic failure (better than silently
 * passing — typo on a fixture name should be loud).
 */
export function evaluateAll(
  trace: Trace,
  specs: InvariantSpec[],
): EvaluateAllResult {
  const results: EvaluateAllResult["results"] = [];
  const failed: string[] = [];
  const skipped: string[] = [];
  for (const spec of specs) {
    const impl = INVARIANTS[spec.name];
    if (!impl) {
      const r: InvariantResult = {
        pass: false,
        detail: `unknown invariant name '${spec.name}'. Registered: [${listInvariants().join(", ")}]`,
      };
      results.push({ name: spec.name, params: spec.params, result: r });
      failed.push(spec.name);
      continue;
    }
    const result = impl(trace, spec.params);
    results.push({ name: spec.name, params: spec.params, result });
    if (result.skipped) {
      skipped.push(spec.name);
    } else if (!result.pass) {
      failed.push(spec.name);
    }
  }
  return {
    results,
    allPassed: failed.length === 0,
    failed,
    skipped,
  };
}

/**
 * Load the `invariants:` block from a fixture.yaml. Minimal YAML parsing
 * is enough — we only need to extract a list of `{name, params}` entries.
 * The harness intentionally does NOT pull in a YAML dep just for this;
 * the existing fixture.yaml parse path uses a small regex-based reader.
 *
 * Schema:
 *   invariants:
 *     - name: stop-requires-approval
 *     - name: orchestrator-no-edits
 *     - name: label-milestones
 *       params:
 *         milestones:
 *           - qa-pending
 *           - qa-approved
 *
 * For robustness this parser tolerates whitespace variation but rejects
 * any structure it doesn't recognize (returns []).
 *
 * NOTE: production fixture loading should use a real YAML parser. This
 * is the simplest correct extractor for the invariants block specifically.
 */
export function parseInvariantsFromYaml(
  yamlContent: string,
): InvariantSpec[] {
  const lines = yamlContent.split(/\r?\n/);
  const out: InvariantSpec[] = [];

  // Find the `invariants:` block start.
  let i = 0;
  while (i < lines.length) {
    const line = lines[i] ?? "";
    if (/^invariants\s*:\s*(?:#.*)?$/.test(line)) {
      i += 1;
      break;
    }
    i += 1;
  }
  if (i >= lines.length) return out;

  // The block is the contiguous run of lines starting with `  - ` until
  // we hit a top-level key or EOF.
  let current: InvariantSpec | null = null;
  let inParams = false;
  let paramsKey: string | null = null;
  let paramsList: string[] | null = null;

  const flush = () => {
    if (paramsKey && paramsList && current) {
      current.params = { ...(current.params ?? {}), [paramsKey]: paramsList };
    }
    paramsKey = null;
    paramsList = null;
  };

  for (; i < lines.length; i += 1) {
    const line = lines[i] ?? "";
    if (line.trim() === "" || /^\s*#/.test(line)) continue;
    // Top-level key — invariants block ended.
    if (/^[A-Za-z_][A-Za-z0-9_-]*\s*:/.test(line)) {
      flush();
      if (current) out.push(current);
      current = null;
      break;
    }
    // New entry: "  - name: <id>" possibly followed by params.
    const mEntry = /^\s*-\s*name\s*:\s*(\S.*?)\s*$/.exec(line);
    if (mEntry) {
      flush();
      if (current) out.push(current);
      current = { name: (mEntry[1] ?? "").replace(/^["']|["']$/g, "") };
      inParams = false;
      continue;
    }
    // `    params:` opens a params object for the current entry.
    if (/^\s+params\s*:\s*$/.test(line)) {
      inParams = true;
      continue;
    }
    // List item under params (e.g. milestone names).
    const mListItem = /^\s+-\s*(.+?)\s*$/.exec(line);
    if (inParams && mListItem && paramsKey && paramsList) {
      paramsList.push((mListItem[1] ?? "").replace(/^["']|["']$/g, ""));
      continue;
    }
    // Params key: list (e.g. `      milestones:`).
    const mParamsKey = /^\s+([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*$/.exec(line);
    if (inParams && mParamsKey) {
      // Flush any prior accumulating key on this entry.
      if (paramsKey && paramsList && current) {
        current.params = {
          ...(current.params ?? {}),
          [paramsKey]: paramsList,
        };
      }
      paramsKey = mParamsKey[1] ?? null;
      paramsList = [];
      continue;
    }
    // Params key: scalar (e.g. `      depth: 3`).
    const mParamsScalar =
      /^\s+([A-Za-z_][A-Za-z0-9_-]*)\s*:\s*(\S.*?)\s*$/.exec(line);
    if (inParams && mParamsScalar && current) {
      const k = mParamsScalar[1] ?? "";
      const raw = (mParamsScalar[2] ?? "").replace(/^["']|["']$/g, "");
      const num = Number(raw);
      const value: unknown = Number.isFinite(num) && raw !== "" ? num : raw;
      current.params = { ...(current.params ?? {}), [k]: value };
      continue;
    }
  }
  flush();
  if (current) out.push(current);
  return out;
}
