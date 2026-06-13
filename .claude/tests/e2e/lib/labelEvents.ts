/**
 * labelEvents — derive ordered Beads label transition EVENTS from a
 * trace's tool-call stream (G2.9ke / claude-workflow-plugin-9ke).
 *
 * THE BUG THIS FIXES: `trace.beadsLabelTransitions` is a NET pre/post
 * diff per task. A label added and then removed within one run —
 * `qa-pending` in EVERY correct approve flow — is invisible to it, so
 * the `label-milestones` invariant structurally could not pass on
 * correct runs (identical FAIL on Phase B runs 3 and 4). The tool-call
 * stream, however, already carries the evidence: qa-gate.sh runs via
 * Bash tool calls whose inputs name the subcommand, and raw
 * `bd label add/remove` / MCP bd-label calls appear directly. This
 * module turns that evidence into an ordered event stream.
 *
 * EVENT SOURCES (deterministic-by-construction only):
 *
 *   1. `qa-gate.sh <subcommand> <task-id>` Bash calls. The gate script's
 *      label contract is deterministic per subcommand (read from
 *      `.claude/scripts/qa-gate.sh`):
 *        enter   -> +qa-gate-entered +rubric-pending
 *        approve -> +qa-approved −qa-gate-entered −qa-pending −rubric-pending
 *        block   -> +qa-blocked
 *        choose approve -> delegates to approve (same contract)
 *      Unknown/other subcommands (status, request, choose continue|
 *      tech-debt|defer, grade-record, bare invocation) derive NOTHING —
 *      see "documented gaps" below.
 *
 *   2. Raw `bd [global-flags] label add|remove <task-id> <label...>`
 *      Bash commands (multi-label and compound `&&`-chained forms
 *      included; observed verbatim in the run-3/run-4 seed traces).
 *
 *   3. `bd [global-flags] create … -l|--label(s) a,b` Bash commands —
 *      creation labels ARE adds (run 3's qa-pending arrived exclusively
 *      via `bd create … -l backend,qa-pending`). The created task's id
 *      is assigned server-side, so these events carry `taskId: ""`.
 *
 *   4. `bd [global-flags] update <task-id> --add-label X --remove-label Y`
 *      Bash commands.
 *
 *   5. The MCP bd surface (tool names matched by suffix so both the
 *      plugin-qualified `mcp__plugin_<plugin>_bd__<tool>` and bare
 *      `mcp__bd__<tool>` / `<tool>` forms work):
 *        bd_add_label / bd_remove_label  -> direct events per task_id
 *        bd_qa_enter / bd_qa_approve / bd_qa_block -> gate contract
 *          (the bd-mcp server shells out to qa-gate.sh; same contract)
 *        bd_create_task / bd_create_epic -> creation labels (incl.
 *          epic children[].labels), taskId "" as in source 3
 *        bd_update_task -> add_labels[] / remove_labels[]
 *
 * ORDERING: events are emitted in tool-call order; within one Bash
 * command string, in match-position order; within one matched call,
 * in the contract/argument order. The stream is therefore a faithful
 * chronological projection of label INTENT across the run.
 *
 * DOCUMENTED GAPS (kept deliberately, with the mitigation named):
 *
 *   - INTENT, NOT EFFECT. Events derive from tool-call inputs; the
 *     trace does not capture per-call results, so a command that failed
 *     at runtime (e.g. an approve refused for a stale impact report)
 *     still yields its intended events. Mitigation: the net-diff field
 *     stays authoritative for end-state; the `label-milestones`
 *     invariant reads both.
 *   - SCRIPT-INTERNAL LABEL FLIPS ARE INVISIBLE. `qa-gate.sh
 *     grade-record` adds `rubric-satisfied` from INSIDE the script and
 *     only when the piped/`--file` verdict JSON says `satisfied` —
 *     not determinable from the command shape, so no event is derived.
 *     Mitigation: `rubric-satisfied` is preserved by approve and
 *     survives to the post-run net diff; the invariant's net-diff
 *     complement covers it. Same reasoning for `choose defer`'s
 *     qa-deferred (survives) and the conditional escalation-label
 *     clears on enter/approve (removes only; the invariant asserts
 *     adds).
 *   - REGEX OVER SHELL TEXT, NOT A SHELL PARSER. Quoted prose that
 *     embeds a full `bd label add …`/`-l …` shape (e.g. inside a
 *     `--description` string) can yield a phantom event. Additive
 *     noise only; it cannot hide a real event. The run-3/run-4
 *     adversarial corpus (grep'ing qa-gate.sh, titles naming
 *     qa-gate.sh, `bd list --label`) is pinned green in
 *     `_label-events.unit.spec.ts`.
 *   - `bd_update_task` set_labels / bare `bd update --label` replace-all
 *     forms are NOT derivable (the resulting add/remove set depends on
 *     prior state) and derive nothing.
 */
import type { BeadsLabelEvent, ToolCall } from "./trace.js";

// ---------------------------------------------------------------------------
// Contract tables
// ---------------------------------------------------------------------------

type Action = "add" | "remove";

interface ContractEvent {
  action: Action;
  label: string;
}

/**
 * Deterministic label semantics of qa-gate.sh subcommands, read from
 * `.claude/scripts/qa-gate.sh`:
 *   - cmd_enter: `add_label qa-gate-entered` + `add_label rubric-pending`
 *     (both the fresh and the idempotent re-enter paths converge on this
 *     post-state; the conditional escalation/rubric-satisfied CLEARS are
 *     state-dependent and deliberately not derived — removes only, and
 *     the invariant asserts adds).
 *   - cmd_approve: `add_label qa-approved`, then removes qa-gate-entered,
 *     qa-pending, and rubric-pending (script order preserved here). The
 *     best-effort escalation-label clears are excluded for the same
 *     reason as on enter.
 *   - cmd_block: `add_label qa-blocked` (qa-gate-entered preserved).
 *
 * `choose approve` delegates to cmd_approve in the script and maps to
 * the approve contract in `deriveFromBashCommand`. Every other
 * subcommand (status, request/typos, choose continue|tech-debt|defer,
 * grade-record) derives nothing — see the module header's documented
 * gaps.
 */
const QA_GATE_CONTRACTS: Record<string, ContractEvent[]> = {
  enter: [
    { action: "add", label: "qa-gate-entered" },
    { action: "add", label: "rubric-pending" },
  ],
  approve: [
    { action: "add", label: "qa-approved" },
    { action: "remove", label: "qa-gate-entered" },
    { action: "remove", label: "qa-pending" },
    { action: "remove", label: "rubric-pending" },
  ],
  block: [{ action: "add", label: "qa-blocked" }],
};

// ---------------------------------------------------------------------------
// Bash command scanners. We regex-scan the WHOLE command string (it may
// be compound: `&&`-chains, pipes, if-blocks) and order hits by match
// position. All /g regexes are used exclusively via String.matchAll,
// which clones the regex per call — no shared lastIndex state.
// ---------------------------------------------------------------------------

/** Beads task ids: `auth-neb.1`, `claude-workflow-plugin-llh.4`, ... */
const ID_TOKEN_RE = /^[A-Za-z0-9._-]+$/;
/** Label tokens additionally allow commas (comma-joined lists split). */
const LABEL_TOKEN_RE = /^[A-Za-z0-9._,-]+$/;

/** `qa-gate.sh <enter|approve|block> <task-id>` — path-agnostic (the
 *  filename can be bare, relative, or absolute; `bash`/`sh` prefixes
 *  irrelevant). The subcommand must be followed by whitespace so
 *  `approved`/`enterX` never match, and the task id is the first
 *  positional after it (true for all three subcommands; approve's
 *  `--no-impact-report` flag comes after the id). */
const QA_GATE_SUB_RE =
  /qa-gate\.sh\s+(enter|approve|block)\s+["']?([A-Za-z0-9._-]+)/g;

/** `qa-gate.sh choose approve <task-id>` — delegates to cmd_approve. */
const QA_GATE_CHOOSE_APPROVE_RE =
  /qa-gate\.sh\s+choose\s+approve\s+["']?([A-Za-z0-9._-]+)/g;

/** `bd [global-flags] label add|remove <rest...>`. The `rest` capture
 *  stops at the first shell separator character (`&`, `|`, `;`,
 *  newline) so `&&`-chains, pipes, and `2>&1` redirects bound the
 *  token list; tokenization below does the fine-grained filtering. */
const BD_LABEL_RE =
  /\bbd(?:\s+-{1,2}\w[\w-]*(?:=\S+)?)*\s+label\s+(add|remove)\s+([^&|;\n]*)/g;

/** `bd [global-flags] update <task-id>` anchor; label flags are scanned
 *  in the slice between this anchor and the next one (or end). */
const BD_UPDATE_RE =
  /\bbd(?:\s+-{1,2}\w[\w-]*(?:=\S+)?)*\s+update\s+["']?([A-Za-z0-9._-]+)["']?/g;
const UPDATE_LABEL_FLAG_RE =
  /--(add|remove)-label[=\s]+["']?([A-Za-z0-9._,-]+)/g;

/** `bd [global-flags] create …` anchor; `-l|--label|--labels` values are
 *  scanned in the slice between this anchor and the next one (or end). */
const BD_CREATE_RE = /\bbd(?:\s+-{1,2}\w[\w-]*(?:=\S+)?)*\s+create\b/g;
const CREATE_LABEL_FLAG_RE =
  /(?:^|\s)(?:-l|--labels?)[=\s]+(?:"([^"]+)"|'([^']+)'|([^\s"']+))/g;

/** Strip a single layer of surrounding quotes from a token. */
function stripQuotes(token: string): string {
  return token.replace(/^["']|["']$/g, "");
}

/** Split a (possibly comma-joined) label value into clean label names. */
function splitLabels(value: string): string[] {
  return value
    .split(",")
    .map((l) => stripQuotes(l.trim()))
    .filter((l) => l.length > 0 && ID_TOKEN_RE.test(l));
}

interface PositionedEvent {
  index: number;
  action: Action;
  label: string;
  taskId: string;
}

/** Scan one Bash command string for label-affecting invocations and
 *  return events ordered by match position. */
function deriveFromBashCommand(
  command: string,
  source: string,
): BeadsLabelEvent[] {
  const hits: PositionedEvent[] = [];

  // --- qa-gate.sh subcommands -> contract events.
  for (const m of command.matchAll(QA_GATE_SUB_RE)) {
    const contract = QA_GATE_CONTRACTS[m[1] ?? ""];
    const tid = m[2] ?? "";
    if (!contract || !ID_TOKEN_RE.test(tid)) continue;
    contract.forEach((c, k) =>
      hits.push({ index: (m.index ?? 0) + k * 1e-3, ...c, taskId: tid }),
    );
  }
  for (const m of command.matchAll(QA_GATE_CHOOSE_APPROVE_RE)) {
    const tid = m[1] ?? "";
    if (!ID_TOKEN_RE.test(tid)) continue;
    QA_GATE_CONTRACTS.approve!.forEach((c, k) =>
      hits.push({ index: (m.index ?? 0) + k * 1e-3, ...c, taskId: tid }),
    );
  }

  // --- raw `bd label add|remove <tid> <label...>` -> direct events.
  for (const m of command.matchAll(BD_LABEL_RE)) {
    const action = (m[1] ?? "") as Action;
    const tokens = (m[2] ?? "").trim().split(/\s+/).filter(Boolean);
    if (tokens.length < 2) continue;
    const tid = stripQuotes(tokens[0] ?? "");
    if (!ID_TOKEN_RE.test(tid)) continue;
    let k = 0;
    for (const raw of tokens.slice(1)) {
      const token = stripQuotes(raw);
      // Stop at the first non-label token: flags (`--json`), redirect
      // fragments (`2>&1`, `2>`), pipes already cut by the regex.
      if (token.startsWith("-") || !LABEL_TOKEN_RE.test(token)) break;
      for (const label of splitLabels(token)) {
        hits.push({
          index: (m.index ?? 0) + k * 1e-3,
          action,
          label,
          taskId: tid,
        });
        k += 1;
      }
    }
  }

  // --- `bd update <tid> --add-label X --remove-label Y` -> direct events.
  const updateMatches = [...command.matchAll(BD_UPDATE_RE)];
  updateMatches.forEach((m, i) => {
    const tid = m[1] ?? "";
    if (!ID_TOKEN_RE.test(tid)) return;
    const sliceStart = (m.index ?? 0) + m[0].length;
    const sliceEnd =
      i + 1 < updateMatches.length
        ? (updateMatches[i + 1]!.index ?? command.length)
        : command.length;
    const slice = command.slice(sliceStart, sliceEnd);
    for (const f of slice.matchAll(UPDATE_LABEL_FLAG_RE)) {
      const action = (f[1] ?? "") as Action;
      for (const label of splitLabels(f[2] ?? "")) {
        hits.push({
          index: sliceStart + (f.index ?? 0),
          action,
          label,
          taskId: tid,
        });
      }
    }
  });

  // --- `bd create … -l a,b` -> creation-label adds (taskId "" — the
  // new id is assigned server-side and never appears in the command).
  const createMatches = [...command.matchAll(BD_CREATE_RE)];
  createMatches.forEach((m, i) => {
    const sliceStart = (m.index ?? 0) + m[0].length;
    const sliceEnd =
      i + 1 < createMatches.length
        ? (createMatches[i + 1]!.index ?? command.length)
        : command.length;
    const slice = command.slice(sliceStart, sliceEnd);
    for (const f of slice.matchAll(CREATE_LABEL_FLAG_RE)) {
      const value = f[1] ?? f[2] ?? f[3] ?? "";
      let k = 0;
      for (const label of splitLabels(value)) {
        hits.push({
          index: sliceStart + (f.index ?? 0) + k * 1e-3,
          action: "add",
          label,
          taskId: "",
        });
        k += 1;
      }
    }
  });

  hits.sort((a, b) => a.index - b.index);
  return hits.map(({ action, label, taskId }) => ({
    action,
    label,
    taskId,
    source,
  }));
}

// ---------------------------------------------------------------------------
// MCP bd surface
// ---------------------------------------------------------------------------

/** Resolve the bare tool name from a possibly plugin-qualified MCP name
 *  (`mcp__plugin_claude-workflow_bd__bd_add_label` -> `bd_add_label`). */
function bareToolName(name: string): string {
  const idx = name.lastIndexOf("__");
  return idx >= 0 ? name.slice(idx + 2) : name;
}

function asStringArray(v: unknown): string[] {
  return Array.isArray(v)
    ? v.filter((x): x is string => typeof x === "string")
    : [];
}

function asString(v: unknown): string {
  return typeof v === "string" ? v : "";
}

/** Map bd_qa_* MCP tools to the qa-gate.sh contract — the bd-mcp server
 *  shells out to qa-gate.sh for these, so the label semantics are
 *  identical by construction. */
const MCP_QA_CONTRACTS: Record<string, ContractEvent[]> = {
  bd_qa_enter: QA_GATE_CONTRACTS.enter!,
  bd_qa_approve: QA_GATE_CONTRACTS.approve!,
  bd_qa_block: QA_GATE_CONTRACTS.block!,
};

function deriveFromMcpCall(call: ToolCall): BeadsLabelEvent[] {
  const tool = bareToolName(call.name);
  const input = (call.input ?? {}) as Record<string, unknown>;
  const out: BeadsLabelEvent[] = [];

  if (tool === "bd_add_label" || tool === "bd_remove_label") {
    const action: Action = tool === "bd_add_label" ? "add" : "remove";
    const label = asString(input.label);
    if (!label) return out;
    const ids = asStringArray(input.task_ids);
    const targets = ids.length > 0 ? ids : [asString(input.task_id)];
    for (const tid of targets) {
      if (!tid) continue;
      out.push({ action, label, taskId: tid, source: call.id });
    }
    return out;
  }

  const qaContract = MCP_QA_CONTRACTS[tool];
  if (qaContract) {
    const tid = asString(input.task_id);
    if (!tid) return out;
    for (const c of qaContract) {
      out.push({ ...c, taskId: tid, source: call.id });
    }
    return out;
  }

  if (tool === "bd_create_task" || tool === "bd_create_epic") {
    for (const label of asStringArray(input.labels)) {
      out.push({ action: "add", label, taskId: "", source: call.id });
    }
    if (tool === "bd_create_epic" && Array.isArray(input.children)) {
      for (const child of input.children) {
        const childLabels = asStringArray(
          (child as Record<string, unknown> | null | undefined)?.labels,
        );
        for (const label of childLabels) {
          out.push({ action: "add", label, taskId: "", source: call.id });
        }
      }
    }
    return out;
  }

  if (tool === "bd_update_task") {
    const tid = asString(input.task_id);
    if (!tid) return out;
    for (const label of asStringArray(input.add_labels)) {
      out.push({ action: "add", label, taskId: tid, source: call.id });
    }
    for (const label of asStringArray(input.remove_labels)) {
      out.push({ action: "remove", label, taskId: tid, source: call.id });
    }
    // set_labels is replace-all: the implied add/remove set depends on
    // prior label state, which the call shape does not carry. Derives
    // nothing by design (documented gap in the module header).
    return out;
  }

  return out;
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

/**
 * Derive the ordered label-event stream for a run.
 *
 * Pure function over the tool-call list — callable offline against any
 * recorded trace (the `_label-events.unit.spec.ts` run-3/run-4 smoke
 * tests do exactly that). Events are ordered by tool-call position,
 * then by match position within a Bash command string, then by
 * contract/argument order within a single matched invocation.
 */
export function deriveBeadsLabelEvents(
  toolCalls: ToolCall[],
): BeadsLabelEvent[] {
  const out: BeadsLabelEvent[] = [];
  for (const call of toolCalls) {
    if (call.name === "Bash") {
      const cmd = (call.input as { command?: unknown } | null | undefined)
        ?.command;
      if (typeof cmd === "string" && cmd.length > 0) {
        out.push(...deriveFromBashCommand(cmd, call.id));
      }
      continue;
    }
    out.push(...deriveFromMcpCall(call));
  }
  return out;
}
