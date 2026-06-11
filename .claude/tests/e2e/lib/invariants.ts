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
 * Fixture-declared milestones appear as a subsequence of label-add
 * events in the trace. This REPLACES `expected_label_progression`
 * equality (which forced exact matching against per-run noise).
 *
 * APPROXIMATION ON ORDERING:
 *   `beadsLabelTransitions` is computed as a single post-run before/after
 *   diff per task (see runFixture.diffBeadsIssues). Within one
 *   transition's `added[]`, the labels are unordered (set diff). Across
 *   transitions, the array order reflects the order tasks appear in
 *   `.beads/issues.jsonl`, not the temporal order labels were added.
 *
 *   Given the lack of in-run temporal ordering, the strongest assertion
 *   the trace supports is SET MEMBERSHIP: every declared milestone must
 *   appear as an `added` label on SOME task. Order is enforced only via
 *   the absence of in-trace evidence, so "subsequence" here is "every
 *   required milestone present, extras allowed". This matches the
 *   spec's "extra intermediate steps allowed" relaxation versus the old
 *   exact-equality contract.
 *
 *   When the trace acquires in-run label sequencing (Phase A follow-up:
 *   capture `bd label add` / `bd qa_*` calls as structured events
 *   with timestamps), this invariant becomes a real-subsequence check
 *   over the temporal stream.
 *
 * Params:
 *   `milestones: string[]` — required label adds. Defaults to
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

  // Flatten every added-label observation across all transitions.
  const addedAcrossTrace = new Set<string>();
  for (const t of trace.beadsLabelTransitions) {
    for (const l of t.added) addedAcrossTrace.add(l);
  }

  const missing = milestones.filter((m) => !addedAcrossTrace.has(m));
  if (missing.length === 0) {
    return {
      pass: true,
      detail: `all ${milestones.length} milestone label(s) observed as added: [${milestones.join(", ")}]`,
    };
  }
  return {
    pass: false,
    detail: `missing milestone label add(s): [${missing.join(", ")}] — observed adds across run: [${[...addedAcrossTrace].sort().join(", ") || "<none>"}]`,
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
