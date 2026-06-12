/**
 * runFixture — drives the Claude Agent SDK against a fixture project
 * and produces a structural Trace.
 *
 * Design notes (cross-reference: G8 plan, "Critical constraint" section):
 *
 * - We must use the SDK, not `claude -p`, because PreToolUse shell hooks
 *   don't fire under -p (anthropics/claude-code#40506). The SDK with
 *   `settingSources: ["project"]` loads the fixture's `.claude/settings.json`
 *   — including its hooks block — and fires every hook for real.
 *
 * - Plugin loading: we walk up from this file to find the plugin root
 *   (the dir containing `.claude-plugin/plugin.json`) and pass it as
 *   `plugins: [{ type: "local", path: <pluginRoot> }]`. The fixture's
 *   own .claude/ overlays the plugin's .claude/ for project-specific
 *   things (.beads, settings.json) but the agents/hooks/skills/MCP
 *   servers come from the plugin so we're testing the published surface.
 *
 * - Isolation: every run gets a fresh tempdir HOME under `.tmp/` so
 *   memory writes (~/.claude/projects/...) don't pollute the developer's
 *   real `~/.claude/`. The fixture's working tree is `git stash`ed before
 *   the run and reset after, so non-determinism in the LLM doesn't leak
 *   into the committed fixture state. Stashing is the cleanest restore
 *   primitive available — even if the run errors out, `git stash pop`
 *   in the cleanup step puts the fixture back exactly as it was.
 *
 * - The drainer is the meaty bit. Each SDK message type maps to a
 *   different slice of the Trace. We accept that the SDK's surface is
 *   still pre-1.0 and tolerate unknown subtypes (just collect them in
 *   diagnostics) rather than throwing on the first new field.
 */
import {
  spawnSync,
  type SpawnSyncReturns,
} from "node:child_process";
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import {
  createEmptyTrace,
  TraceSchema,
  type Trace,
  type HookOutput,
  type ToolCall,
} from "./trace.js";
import { ensureFixtureGitInit } from "./fixtureInit.js";
import {
  readBeadsIssues,
  diffBeadsIssues,
  flushFixtureBeads,
} from "./beadsCapture.js";

// Lazy import — keeps `runFixture` compilable even if the SDK isn't
// installed (so a developer can `npm install` to bring it in).
type SDKQueryFn = (opts: unknown) => AsyncGenerator<SDKAnyMessage, void, void>;

// Loose typing for SDK messages — pins down only the fields we actually
// read. The full type is in @anthropic-ai/claude-agent-sdk.
type SDKAnyMessage = {
  type?: string;
  subtype?: string;
  uuid?: string;
  session_id?: string;
  parent_tool_use_id?: string | null;
  message?: {
    id?: string;
    content?: Array<{
      type: string;
      id?: string;
      name?: string;
      input?: Record<string, unknown>;
      text?: string;
    }>;
    stop_reason?: string;
    usage?: {
      input_tokens?: number;
      output_tokens?: number;
    };
  };
  // Hook event message fields. The SDK names hook event names under
  // `hook_event` (current shape, sdk.d.ts:3046,3061,3076) and used to
  // call it `hook_event_name` in earlier shapes; we accept both for
  // forward/backward compat. `hook_name` (current) carries the script
  // identifier — there's no `script` field in the SDK envelope.
  // `output` is the verbatim JSON the hook script wrote to stdout
  // (SyncHookJSONOutput shape, sdk.d.ts:5519); the response object
  // we used to read came from a pre-1.0 SDK shape and isn't emitted
  // by the current SDK. We keep `response?` as an opaque carry-through
  // for older fixtures / replays whose JSONL retains it.
  hook_event_name?: string;
  hook_event?: string;
  hook_name?: string;
  hook_id?: string;
  output?: string;
  stdout?: string;
  stderr?: string;
  exit_code?: number;
  outcome?: "success" | "error" | "cancelled";
  response?: {
    decision?: "approve" | "block" | "ask";
    reason?: string;
    stopReason?: string;
    continue?: boolean;
    suppressOutput?: boolean;
    systemMessage?: string;
    hookSpecificOutput?: Record<string, unknown>;
  };
  tool_name?: string;
  tool_use_id?: string;
  decision_reason?: string;
  decision_reason_type?: string;
  agent_id?: string;
  // SDKSystemMessage init fields. Several variants are accepted because
  // the SDK is pre-1.0 and the surface is still evolving — different
  // versions name "available subagent types" under different keys.
  tools?: string[];
  plugins?: Array<{ name: string; path: string }>;
  // The SDK has emitted plugin-load errors as either flat strings (older
  // shape) or `{ plugin, type, message, ... }` objects (current shape; see
  // PluginError in trace.ts). We accept both so the harness doesn't need
  // to be re-typed every time the SDK rev changes the surface.
  plugin_errors?: Array<string | Record<string, unknown>>;
  pluginErrors?: Array<string | Record<string, unknown>>;
  mcp_servers?: Array<{ name: string; status: string }>;
  agents?: string[];
  available_subagents?: string[];
  availableSubagents?: string[];
  subagent_types?: string[];
  // SDKResultMessage fields:
  duration_ms?: number;
  num_turns?: number;
  result?: string;
  total_cost_usd?: number;
  usage?: {
    input_tokens?: number;
    output_tokens?: number;
    cache_creation_input_tokens?: number;
    cache_read_input_tokens?: number;
  };
  permission_denials?: Array<{
    tool_name?: string;
    tool_use_id?: string;
    message?: string;
    decision_reason?: string;
    decision_reason_type?: string;
  }>;
  is_error?: boolean;
};

export interface RunFixtureOptions {
  /** Absolute path to the fixture root (the project the prompt operates on). */
  fixturePath: string;
  /** The user prompt that drives the run. */
  prompt: string;
  /** SDK maxTurns. Default 30 — matches the plan's determinism strategy. */
  maxTurns?: number;
  /** "default" | "acceptEdits" | "plan" | "bypassPermissions". We use
   *  "bypassPermissions" by default to satisfy the autonomy principle
   *  (no permission prompts block the run). The plan calls this "dontAsk"
   *  but the SDK's actual enum is bypassPermissions. */
  permissionMode?:
    | "default"
    | "acceptEdits"
    | "plan"
    | "bypassPermissions";
  /** Optional explicit tool allowlist. By default we omit and let the
   *  fixture's settings.json + the plugin's defaults stand. */
  allowedTools?: string[];
  /** REQUIRED. Pinned model snapshot. We don't default this — recording
   *  cassettes against an unpinned `claude-opus-4-7` (latest alias) would
   *  invalidate them silently when Anthropic ships a new snapshot. */
  modelSnapshot: string;
  /** Whether to print streaming events to stderr while the run is in
   *  progress. Useful for live debugging; off by default. */
  verbose?: boolean;
}

/** Walk up from a starting dir until we find a directory containing
 *  `.claude-plugin/plugin.json`. Returns the plugin root, or throws. */
export function findPluginRoot(startDir: string): string {
  let dir = path.resolve(startDir);
  for (let i = 0; i < 12; i++) {
    if (existsSync(path.join(dir, ".claude-plugin", "plugin.json"))) {
      return dir;
    }
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error(
    `runFixture: could not locate plugin root (no .claude-plugin/plugin.json found) starting from ${startDir}`,
  );
}

// Beads-capture helpers (readBeadsIssues, diffBeadsIssues, flushFixtureBeads)
// live in beadsCapture.ts so they can be unit-tested in isolation; this
// module imports them at the top. Keeping them out of runFixture.ts means
// _beads-capture.unit.spec.ts doesn't need to spin up the SDK to exercise
// the capture contract — see claude-workflow-plugin-l1r.7 for the rationale.

/** Run a git command in the fixture and return stdout/stderr/exit. */
function git(fixturePath: string, args: string[]): SpawnSyncReturns<string> {
  return spawnSync("git", args, {
    cwd: fixturePath,
    encoding: "utf8",
    timeout: 30_000,
  });
}

/** Snapshot the fixture's working tree via `git stash --include-untracked`
 *  and capture the pre-run HEAD SHA. Returns the SHA plus a flag
 *  indicating whether a stash was actually created (i.e. there were
 *  uncommitted changes to stash). On clean trees, no stash is created
 *  but the HEAD SHA is still captured — that's the safety net against
 *  run-time `bd sync` (or any other process) that COMMITS to the
 *  fixture during the run and would otherwise leave HEAD advanced past
 *  the canonical fixture state. */
/** File names that are harness metadata (never written by the agent
 *  under test) and must survive a restore cycle even if their working
 *  copy contained uncommitted edits at snapshot time.
 *
 *  fixture.yaml is the canonical case: an operator editing invariants
 *  or expected_subagents must not have those edits silently wiped by
 *  the next live run's restoreFixture call (the Phase B trace fix at
 *  claude-workflow-plugin-366.6 had its fixture.yaml restoration lost
 *  exactly this way — uncommitted edit + git-based restore).
 *
 *  Keep this list small and conservative; anything an agent is allowed
 *  to write must NOT be on it. */
const HARNESS_METADATA_FILES = ["fixture.yaml"] as const;

export function snapshotFixture(
  fixturePath: string,
): { stashed: boolean; headSha: string; harnessMetadata: Record<string, string> } {
  // Refuse to run if the fixture isn't a git repo — the restore step
  // depends on git working.
  const isRepo = git(fixturePath, ["rev-parse", "--is-inside-work-tree"]);
  if (isRepo.status !== 0) {
    throw new Error(
      `runFixture: fixture at ${fixturePath} is not a git repo (rev-parse failed: ${isRepo.stderr})`,
    );
  }
  // Capture the pre-run HEAD SHA. This is what `restoreFixture` resets
  // to — NOT plain `HEAD`, because the run itself can advance HEAD via
  // `bd sync` commits (discovered claude-workflow-plugin-0wk.10 Phase A.2:
  // the bd post-edit hook commits beads/issues.jsonl to fixture HEAD,
  // so resetting to `HEAD` after a run keeps those commits and means
  // subsequent runs see the previous run's beads tasks as
  // already-present → beadsTasksCreated reports 0 spuriously).
  const headSha = git(fixturePath, ["rev-parse", "HEAD"]);
  if (headSha.status !== 0) {
    throw new Error(
      `runFixture: failed to capture pre-run HEAD SHA: ${headSha.stderr}`,
    );
  }
  const sha = headSha.stdout.trim();

  // Capture harness-metadata file contents BEFORE we stash — they
  // represent the operator-authored state at the START of the run.
  // restoreFixture will rewrite them at the END regardless of how the
  // intermediate stash/reset/clean/pop sequence behaves, so any
  // uncommitted edits the operator left in place survive the cycle.
  // See claude-workflow-plugin-366.6 for the regression that produced
  // this contract.
  const harnessMetadata = snapshotHarnessMetadata(fixturePath);

  const status = git(fixturePath, ["status", "--porcelain"]);
  if (status.status !== 0) {
    throw new Error(`runFixture: git status failed: ${status.stderr}`);
  }
  if (!status.stdout.trim()) {
    return { stashed: false, headSha: sha, harnessMetadata };
  }
  const stash = git(fixturePath, [
    "stash",
    "push",
    "--include-untracked",
    "-m",
    "runFixture-pre-run",
  ]);
  if (stash.status !== 0) {
    throw new Error(`runFixture: git stash failed: ${stash.stderr}`);
  }
  return { stashed: true, headSha: sha, harnessMetadata };
}

/** Read each harness-metadata file's current bytes from the fixture
 *  working tree, returning a map of relative-path -> contents. Missing
 *  files are silently omitted (a fixture without fixture.yaml is
 *  legitimate — the resolver only enforces invariants where declared). */
function snapshotHarnessMetadata(
  fixturePath: string,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const rel of HARNESS_METADATA_FILES) {
    const full = path.join(fixturePath, rel);
    if (!existsSync(full)) continue;
    try {
      out[rel] = readFileSync(full, "utf8");
    } catch {
      // Best-effort: a permission error or transient I/O error here
      // means we'd rather take a degraded restore (no metadata
      // protection) than abort the whole run.
    }
  }
  return out;
}

/** Write each preserved file back to the fixture. Idempotent: writing
 *  the same bytes is a no-op as far as git is concerned (the
 *  working-tree file ends up identical to the version `git reset`
 *  produced, in which case it does nothing visible; or it overrides
 *  the reset-restored version with the operator's uncommitted edits,
 *  which is the whole point). */
function restoreHarnessMetadata(
  fixturePath: string,
  snapshot: Record<string, string>,
): void {
  for (const [rel, content] of Object.entries(snapshot)) {
    const full = path.join(fixturePath, rel);
    try {
      // Ensure the parent dir exists — defensive, since fixture.yaml
      // lives at the fixture root which we know exists by this point.
      const parent = path.dirname(full);
      if (!existsSync(parent)) mkdirSync(parent, { recursive: true });
      writeFileSync(full, content);
    } catch {
      // Same trade-off as snapshotHarnessMetadata: a failure here
      // means an operator edit may be lost, but we won't abort the
      // whole restore.
    }
  }
}

/** Restore the fixture to its pre-run state. Best-effort: we always try
 *  `git reset --hard <pre-run-sha>` + `git clean -fd` even if stash pop
 *  fails, so the fixture is never left in a partially-mutated state.
 *
 *  Resets to the exact pre-run SHA (NOT plain `HEAD`) so any commits
 *  the run made — e.g. `bd sync` auto-committing beads/issues.jsonl
 *  via the post-edit hook — are rolled back. Without this, fixture
 *  HEAD would accumulate spurious commits across runs and the
 *  beadsTasksCreated diff would degrade to 0 after the first run.
 *
 *  Harness-metadata files (fixture.yaml — see HARNESS_METADATA_FILES)
 *  are SNAPSHOTTED BEFORE the reset and RESTORED AFTER, so that
 *  uncommitted operator edits to those files survive the cycle. The
 *  agent under test never writes them; preserving them is safe. This
 *  closes the Phase B regression at claude-workflow-plugin-366.6
 *  where an uncommitted fixture.yaml invariants edit was wiped by a
 *  live run's restoreFixture. */
export function restoreFixture(
  fixturePath: string,
  snapshot: { stashed: boolean; headSha: string; harnessMetadata?: Record<string, string> },
): void {
  // Hard-reset to the captured pre-run SHA. This rolls back BOTH
  // tracked changes AND any commits the run made (e.g. bd sync).
  git(fixturePath, ["reset", "--hard", snapshot.headSha]);
  // Remove untracked files (e.g. .qa-tracking, .beads/wal mutations,
  // node_modules under fixture if the run installed any).
  git(fixturePath, ["clean", "-fd", "-e", "node_modules"]);
  if (snapshot.stashed) {
    // Restore the pre-run state from the stash. If pop fails (rare,
    // e.g. conflict with the now-clean tree), drop the stash to avoid
    // leaving it dangling.
    const pop = git(fixturePath, ["stash", "pop"]);
    if (pop.status !== 0) {
      git(fixturePath, ["stash", "drop"]);
    }
  }
  // Re-write harness-metadata files AFTER the reset/clean/pop using
  // the snapshot captured at the TOP of the run (in snapshotFixture).
  // This is intentionally the last step so any prior step that touched
  // these files is overridden by the operator's pre-run version. The
  // `harnessMetadata` field is optional in the type only for backward
  // compatibility with callers built against the pre-366.6 signature;
  // the snapshotFixture() helper in this file always populates it.
  if (snapshot.harnessMetadata) {
    restoreHarnessMetadata(fixturePath, snapshot.harnessMetadata);
  }
}

/** Compute the file-write set by diffing the fixture against HEAD. We
 *  also include untracked files (anything in `git status --porcelain`'s
 *  `??` lines) so newly-created files are caught. */
function captureFileWrites(
  fixturePath: string,
): Array<{ path: string; bytesWritten: number; changeType: "added" | "modified" | "deleted" }> {
  const out: Array<{
    path: string;
    bytesWritten: number;
    changeType: "added" | "modified" | "deleted";
  }> = [];
  const status = git(fixturePath, ["status", "--porcelain"]);
  if (status.status !== 0) return out;
  for (const rawLine of status.stdout.split("\n")) {
    if (!rawLine) continue;
    // Porcelain format: "XY path" where XY is two status chars. Untracked
    // is "?? path", deletions show D in either column, additions show A
    // (staged) or "?? " (untracked). We just classify into 3 buckets.
    const xy = rawLine.slice(0, 2);
    const filePath = rawLine.slice(3).trim();
    if (!filePath) continue;
    let changeType: "added" | "modified" | "deleted" = "modified";
    if (xy.includes("D")) changeType = "deleted";
    else if (xy.includes("?") || xy.includes("A")) changeType = "added";
    let bytesWritten = -1;
    if (changeType !== "deleted") {
      try {
        bytesWritten = statSync(path.join(fixturePath, filePath)).size;
      } catch {
        bytesWritten = -1;
      }
    }
    out.push({ path: filePath.replace(/\\/g, "/"), bytesWritten, changeType });
  }
  return out;
}

/** Drain a single SDK message into the trace. Returns true if the message
 *  was a `result` event (run is over). */
/**
 * Best-effort: parse the `output` string from an SDKHookResponseMessage
 * into a SyncHookJSONOutput-shaped object. The SDK emits whatever the
 * hook script wrote to stdout verbatim; the hook script is expected to
 * have produced JSON matching `SyncHookJSONOutput` (decision, reason,
 * stopReason, hookSpecificOutput, etc.) but shell hooks routinely emit
 * non-JSON output (logs, info text) too. We tolerate both:
 *   - JSON parses cleanly → return the parsed object.
 *   - JSON parse fails → return null; caller treats as a no-decision hook
 *     fire (e.g. a SessionStart hook that just logs to stderr).
 *
 * Why this matters: before this parser existed, `hookOutputs` rows came
 * back with `event="<unknown>"` and `decision=null` because the parser
 * was reading the pre-1.0 SDK shape (`msg.hook_event_name`, `msg.response.*`).
 * The current SDK shape carries event under `msg.hook_event` and decision
 * inside the stringified `msg.output`. See sdk.d.ts:3056 (SDKHookResponseMessage)
 * and sdk.d.ts:5519 (SyncHookJSONOutput) for the field-by-field source.
 */
function parseHookResponseOutput(output: string | undefined): {
  decision?: "approve" | "block" | "ask";
  reason?: string;
  stopReason?: string;
  continue?: boolean;
  suppressOutput?: boolean;
  systemMessage?: string;
  hookSpecificOutput?: Record<string, unknown>;
} | null {
  if (!output || !output.trim()) return null;
  try {
    const parsed = JSON.parse(output);
    if (parsed && typeof parsed === "object") {
      return parsed as ReturnType<typeof parseHookResponseOutput>;
    }
    return null;
  } catch {
    // Non-JSON hook output is fine — many hooks just write logs.
    return null;
  }
}

function ingestMessage(
  msg: SDKAnyMessage,
  trace: Trace,
  toolCallStartTimes: Map<string, number>,
  hookStartTimes: Map<
    string,
    { event: string; script: string; start: number }
  >,
  verbose: boolean,
): { done: boolean } {
  if (verbose) {
    process.stderr.write(
      `[runFixture] ${msg.type ?? "?"}/${msg.subtype ?? "?"}\n`,
    );
  }

  // System: init — populate both the legacy top-level fields
  // (toolsAvailable / pluginsLoaded) and the new structured `systemInit`
  // snapshot. Best-effort across SDK shape variants: different versions
  // name the "available subagent types" list differently, so we accept
  // a handful and union them. Anything we don't pull into a structured
  // slot lands in `systemInit.raw` so post-mortem readers don't have
  // to re-spend a live capture to inspect a new field. This is the
  // diagnostic anchor for plugin-loading regressions: when the SDK
  // silently fails to register plugin-defined agents (the live G8
  // observation behind this field's existence), `systemInit` is where
  // we look first.
  if (msg.type === "system" && msg.subtype === "init") {
    if (Array.isArray(msg.tools)) trace.toolsAvailable = [...msg.tools];
    if (Array.isArray(msg.plugins)) {
      trace.pluginsLoaded = msg.plugins.map((p) => ({
        name: p.name,
        path: p.path,
      }));
    }
    const pluginNames = Array.isArray(msg.plugins)
      ? msg.plugins.map((p) => p.name)
      : [];
    const pluginErrors = Array.isArray(msg.plugin_errors)
      ? [...msg.plugin_errors]
      : Array.isArray(msg.pluginErrors)
        ? [...msg.pluginErrors]
        : [];
    // Union of every known shape the SDK has used for "subagent types
    // visible to the Task/Agent tool". Empty in the live G8 trace —
    // which is the smoking gun behind the upstream research bug.
    const availableSubagents = [
      ...(Array.isArray(msg.agents) ? msg.agents : []),
      ...(Array.isArray(msg.available_subagents) ? msg.available_subagents : []),
      ...(Array.isArray(msg.availableSubagents) ? msg.availableSubagents : []),
      ...(Array.isArray(msg.subagent_types) ? msg.subagent_types : []),
    ];
    trace.systemInit = {
      plugins: pluginNames,
      pluginErrors,
      availableSubagents,
      tools: Array.isArray(msg.tools) ? [...msg.tools] : [],
      mcpServers: Array.isArray(msg.mcp_servers)
        ? msg.mcp_servers.map((s) => ({ name: s.name, status: s.status }))
        : [],
      // `raw` preserves the verbatim init message so future debug sessions
      // can read whatever the SDK currently emits without re-recording.
      // Strip `type`/`subtype` because they're constant for init; everything
      // else is interesting.
      raw: msg,
    };
    if (pluginErrors.length > 0) {
      trace.pluginErrors = [...trace.pluginErrors, ...pluginErrors];
    }
    return { done: false };
  }

  // System: hook_started — record start timestamp keyed by hook_id.
  //
  // SDK shape (sdk.d.ts:3071, SDKHookStartedMessage): the event name is
  // under `hook_event` (current) — older shapes used `hook_event_name`
  // and we still accept that for backward-compat with legacy replays.
  // The script identifier is `hook_name`; we capture it here so the
  // matching response can attribute the firing to a specific script
  // (e.g. `verify-before-stop`) rather than just the event family.
  if (msg.type === "system" && msg.subtype === "hook_started") {
    const event = msg.hook_event ?? msg.hook_event_name;
    if (msg.hook_id && event) {
      hookStartTimes.set(msg.hook_id, {
        event,
        script: msg.hook_name ?? "<unknown>",
        start: Date.now(),
      });
    }
    return { done: false };
  }

  // System: hook_response — finalize the hook output entry.
  //
  // SDK shape (sdk.d.ts:3056, SDKHookResponseMessage): the hook script's
  // stdout is delivered verbatim in `msg.output` (a string). Per the
  // hooks reference, hooks emit a SyncHookJSONOutput JSON envelope
  // (sdk.d.ts:5519) carrying `decision`, `reason`, `stopReason`,
  // `hookSpecificOutput`, etc. We parse that string here and fall back
  // gracefully when the hook printed non-JSON (logs, info text, etc.) —
  // such hooks just don't have a decision, which the schema allows.
  //
  // We also accept the older `msg.response` envelope shape (pre-1.0
  // SDK) for replays captured before this fix; if both are present
  // the parsed `output` wins because that's the current authoritative
  // source on a live run.
  if (msg.type === "system" && msg.subtype === "hook_response") {
    if (msg.hook_id) {
      const started = hookStartTimes.get(msg.hook_id);
      const duration = started ? Date.now() - started.start : 0;
      const event =
        msg.hook_event ??
        msg.hook_event_name ??
        started?.event ??
        "<unknown>";
      const script = msg.hook_name ?? started?.script ?? "<unknown>";
      const parsedOutput = parseHookResponseOutput(msg.output);
      const legacyResponse = msg.response ?? {};
      const decision = parsedOutput?.decision ?? legacyResponse.decision;
      const reason =
        parsedOutput?.reason ??
        parsedOutput?.stopReason ??
        legacyResponse.reason ??
        legacyResponse.stopReason;
      const out: HookOutput = {
        event,
        script,
        decision,
        reason,
        durationMs: duration,
        // Preserve the raw response envelope for post-mortem: whichever
        // shape was present wins. This is diagnostic-only — golden
        // compare ignores `response`.
        response: parsedOutput ?? legacyResponse,
        hookId: msg.hook_id,
      };
      trace.hookOutputs.push(out);
      hookStartTimes.delete(msg.hook_id);
    }
    return { done: false };
  }

  // System: hook_progress — soft signal, ignored for trace structure
  if (msg.type === "system" && msg.subtype === "hook_progress") {
    return { done: false };
  }

  // System: permission_denied
  if (msg.type === "system" && msg.subtype === "permission_denied") {
    trace.permissionDenials.push({
      tool: msg.tool_name ?? "<unknown>",
      reason: msg.decision_reason ?? msg.response?.reason ?? "",
      decisionReasonType: msg.decision_reason_type,
      agentId: msg.agent_id,
      toolUseId: msg.tool_use_id,
    });
    return { done: false };
  }

  // Assistant message — extract tool_use blocks
  if (msg.type === "assistant" && msg.message?.content) {
    for (const block of msg.message.content) {
      if (block.type !== "tool_use" || !block.id || !block.name) continue;
      const toolCall: ToolCall = {
        id: block.id,
        name: block.name,
        input: block.input ?? {},
        parentToolUseId: msg.parent_tool_use_id ?? null,
        durationMs: 0,
        messageUuid: msg.uuid,
      };
      // If this is a Task/Agent call, surface subagent_type for convenience.
      // The SDK is mid-migration: type docs reference both "the Task tool"
      // (sdk.d.ts:95) and "the Agent tool" (sdk.d.ts:36, :1189), and the
      // runtime carries an internal mapping `lE = {Task:"Agent",...}` used
      // by the permission-rule parser (sdk.mjs ~767357). The model-facing
      // tool name in tool_use blocks could come through under either label
      // depending on plugin version / runtime patches, so accept both. The
      // input shape is the same in both cases (AgentInput.subagent_type per
      // sdk-tools.d.ts:285).
      if ((block.name === "Task" || block.name === "Agent") && block.input) {
        const subagentType =
          typeof block.input.subagent_type === "string"
            ? block.input.subagent_type
            : "";
        toolCall.subagentType = subagentType;
        if (subagentType) {
          trace.subagentInvocations.push({
            type: subagentType,
            toolUseId: block.id,
            parentToolUseId: msg.parent_tool_use_id ?? null,
          });
        }
      }
      trace.toolCalls.push(toolCall);
      toolCallStartTimes.set(block.id, Date.now());
    }
    return { done: false };
  }

  // User message carrying a tool_result — close out the timing entry
  if (msg.type === "user" && msg.message?.content) {
    for (const block of msg.message.content) {
      // tool_result blocks reference the originating tool_use id
      const blockAny = block as { type?: string; tool_use_id?: string };
      if (blockAny.type === "tool_result" && blockAny.tool_use_id) {
        const start = toolCallStartTimes.get(blockAny.tool_use_id);
        if (start !== undefined) {
          const tc = trace.toolCalls.find((t) => t.id === blockAny.tool_use_id);
          if (tc) tc.durationMs = Date.now() - start;
          toolCallStartTimes.delete(blockAny.tool_use_id);
        }
      }
    }
    return { done: false };
  }

  // Result event — terminal
  if (msg.type === "result") {
    trace.result.subtype = msg.subtype ?? "success";
    trace.result.totalCostUsd = msg.total_cost_usd ?? 0;
    trace.result.inputTokens = msg.usage?.input_tokens ?? 0;
    trace.result.outputTokens = msg.usage?.output_tokens ?? 0;
    trace.result.turns = msg.num_turns ?? 0;
    trace.result.durationMs = msg.duration_ms ?? 0;
    trace.result.finalAssistantMessage = msg.result ?? "";
    if (Array.isArray(msg.permission_denials)) {
      for (const pd of msg.permission_denials) {
        // Avoid duplicating denials we already captured via the live
        // permission_denied stream event.
        const dup = trace.permissionDenials.some(
          (existing) =>
            existing.toolUseId === pd.tool_use_id &&
            existing.tool === pd.tool_name,
        );
        if (!dup) {
          trace.permissionDenials.push({
            tool: pd.tool_name ?? "<unknown>",
            reason: pd.decision_reason ?? pd.message ?? "",
            decisionReasonType: pd.decision_reason_type,
            toolUseId: pd.tool_use_id,
          });
        }
      }
    }
    return { done: true };
  }

  return { done: false };
}

/**
 * Build a path under `cassettes/replays/` for an always-on trace dump.
 * The dump is written EVEN if the run throws or the schema validation
 * later rejects the trace — its purpose is post-mortem debugging when a
 * live spec fails mid-flight (e.g. an `expect(trace).subagentInvoked(...)`
 * fails and we'd otherwise lose ~$10-15 of capture data because
 * RECORD_GOLDEN=1 only writes the cassette after every assertion passes).
 *
 * The replay directory is gitignored (`.claude/tests/e2e/.gitignore`).
 */
function buildReplayPath(here: string, fixtureName: string): string {
  const replaysDir = path.resolve(here, "..", "cassettes", "replays");
  if (!existsSync(replaysDir)) mkdirSync(replaysDir, { recursive: true });
  // ISO timestamp with colons replaced — safe for all filesystems.
  const ts = new Date().toISOString().replace(/[:.]/g, "-");
  // Slugify the fixture name; basenames are usually safe but be defensive.
  const slug = fixtureName.replace(/[^A-Za-z0-9._-]/g, "_");
  return path.join(replaysDir, `${slug}-${ts}.jsonl`);
}

/**
 * Write the trace as a single JSON line to `replayPath`. Best-effort: if
 * the write fails (disk full, permissions, etc.) we log to stderr but do
 * NOT rethrow — the original error from the run, if any, is more
 * informative than a secondary I/O failure.
 *
 * The file is written as JSONL (one record per line) to leave room for
 * future per-event streaming if we ever want to dump events as they
 * arrive rather than batching at the end. For now there's a single line:
 * the entire Trace as one JSON object.
 */
function writeTraceDump(replayPath: string, trace: Trace): void {
  try {
    // Single JSON line + trailing newline. `jq .` works on this directly.
    writeFileSync(replayPath, JSON.stringify(trace) + "\n", "utf8");
    process.stderr.write(`[runFixture] trace written to ${replayPath}\n`);
  } catch (err) {
    process.stderr.write(
      `[runFixture] WARNING: failed to write trace dump to ${replayPath}: ${(err as Error).message}\n`,
    );
  }
}

/**
 * Run the fixture against real Claude. Returns a Trace conforming to
 * TraceSchema. Throws on:
 *   - missing ANTHROPIC_API_KEY
 *   - fixture path doesn't exist or isn't a git repo
 *   - SDK not installed
 *   - schema validation failure on the produced trace
 *
 * On EVERY exit (success, throw, schema-validation failure), the trace
 * is persisted to `cassettes/replays/<fixture>-<ISO-timestamp>.jsonl` so
 * failed runs don't lose their diagnostic data. See `buildReplayPath`.
 */
export async function runFixture(opts: RunFixtureOptions): Promise<Trace> {
  if (!opts.modelSnapshot) {
    throw new Error(
      "runFixture: modelSnapshot is required (no defaults — explicit pin per the determinism strategy).",
    );
  }
  if (!opts.fixturePath || !path.isAbsolute(opts.fixturePath)) {
    throw new Error(
      `runFixture: fixturePath must be absolute, got: ${opts.fixturePath}`,
    );
  }
  if (!existsSync(opts.fixturePath)) {
    throw new Error(`runFixture: fixturePath does not exist: ${opts.fixturePath}`);
  }
  if (!process.env.ANTHROPIC_API_KEY) {
    throw new Error(
      "runFixture: ANTHROPIC_API_KEY is not set. The harness requires a real Claude API key — see G8 plan, 'Determinism strategy' principle 6 (golden cassettes are evidence, not a replay substitute).",
    );
  }

  const here = path.dirname(fileURLToPath(import.meta.url));
  const pluginRoot = findPluginRoot(here);

  // Lazily init the fixture's nested git repo if it's missing (fresh
  // clone scenario — parent repo doesn't track the inner .git/). Idempotent.
  ensureFixtureGitInit(opts.fixturePath);

  // Self-heal from a prior crash. Vitest enforces `testTimeout` by
  // SIGKILL'ing the worker; that bypasses our try/finally cleanup and
  // leaves the fixture mutated. If we see a dirty tree on entry we
  // assume a previous run was killed mid-flight and restore before
  // doing anything else — including BEFORE git stash, so we don't end
  // up stashing crash artifacts and creating a confusing dangling
  // stash entry. This makes the harness self-healing across crashes.
  const dirtyOnEntry = git(opts.fixturePath, ["status", "--porcelain"]);
  if (dirtyOnEntry.status === 0 && dirtyOnEntry.stdout.trim()) {
    process.stderr.write(
      `[runFixture] WARNING: fixture ${opts.fixturePath} was dirty on entry (probable prior crash — vitest SIGKILL bypasses try/finally cleanup); restoring before run\n`,
    );
    git(opts.fixturePath, ["reset", "--hard", "HEAD"]);
    git(opts.fixturePath, ["clean", "-fd", "-e", "node_modules"]);
  }

  // Snapshot fixture state before mutation. Flush bd's pending writes to
  // `.beads/issues.jsonl` before reading so the pre-run baseline reflects
  // any prior tasks the fixture's DB carries (e.g. seeded by a fixture's
  // build script). Without this the baseline could miss tasks the daemon
  // had cached but not yet written, and a later identical read at end-of-run
  // would spuriously report them as "created during this run". Tolerant of
  // failure — see flushFixtureBeads docstring for the best-effort contract.
  // Discovered: claude-workflow-plugin-l1r.7 — the live rubric-revision-loop
  // trace showed an empty beads diff despite three bd-create operations on
  // the wire. The daemon path doesn't flush JSONL synchronously, so without
  // an explicit flush the post-snapshot can read stale state.
  const preFlush = flushFixtureBeads(opts.fixturePath);
  if (!preFlush.ok && !preFlush.noBeadsDir) {
    process.stderr.write(
      `[runFixture] WARNING: pre-run beads flush failed (continuing): bdMissing=${preFlush.bdMissing}, status=${preFlush.status}, stderrTail=${preFlush.stderrTail.replace(/\n/g, " | ").slice(0, 200)}\n`,
    );
  }
  const beadsBefore = readBeadsIssues(opts.fixturePath);
  const snapshot = snapshotFixture(opts.fixturePath);

  // Extra safety net: register signal handlers for graceful kill paths
  // (Ctrl+C, SIGTERM, parent shell exit) so we still restore the fixture
  // when the worker is asked to die politely. Note: this does NOT cover
  // SIGKILL — vitest's testTimeout enforces a hard kill that no handler
  // can intercept. The self-heal-on-entry check above is the
  // belt-and-suspenders mitigation for that case.
  let handlersInstalled = false;
  const signalHandler = (sig: NodeJS.Signals) => {
    process.stderr.write(
      `[runFixture] received ${sig}; attempting fixture restore before exit\n`,
    );
    try {
      restoreFixture(opts.fixturePath, snapshot);
    } catch (err) {
      process.stderr.write(
        `[runFixture] signal-path restore failed: ${(err as Error).message}\n`,
      );
    }
    // Re-raise the default behavior — exit non-zero so vitest reports
    // the run as a failure rather than a passing empty trace.
    process.exit(sig === "SIGINT" ? 130 : 143);
  };
  const sigintHandler = () => signalHandler("SIGINT");
  const sigtermHandler = () => signalHandler("SIGTERM");
  process.on("SIGINT", sigintHandler);
  process.on("SIGTERM", sigtermHandler);
  handlersInstalled = true;

  // Set up an isolated HOME under the e2e .tmp/ dir so memory writes
  // don't pollute the developer's real ~/.claude/.
  const tmpRoot = path.resolve(here, "..", ".tmp");
  if (!existsSync(tmpRoot)) mkdirSync(tmpRoot, { recursive: true });
  const isoHome = mkdtempSync(path.join(tmpRoot, "home-"));
  mkdirSync(path.join(isoHome, ".claude"), { recursive: true });

  const trace = createEmptyTrace(
    path.basename(opts.fixturePath),
    opts.prompt,
    opts.modelSnapshot,
  );

  // Pre-compute the replay-dump path so it's stable across the run (the
  // timestamp is bound at start-of-run, not end-of-run). We persist the
  // trace to this path UNCONDITIONALLY from the run's `finally` block
  // below, so a mid-run throw still leaves a post-mortem-readable
  // artifact behind. The schema-validation step at the end runs AFTER
  // the dump, so even a malformed trace gets dumped before the throw
  // surfaces. This is the foundation for diagnosing live-run failures
  // without having to re-spend the full live capture cost.
  const replayPath = buildReplayPath(here, path.basename(opts.fixturePath));

  // Save env we mutate so we can restore them.
  const savedEnv = {
    HOME: process.env.HOME,
    CLAUDE_PROJECT_DIR: process.env.CLAUDE_PROJECT_DIR,
    USERPROFILE: process.env.USERPROFILE,
  };

  try {
    process.env.HOME = isoHome;
    process.env.USERPROFILE = isoHome; // Windows compatibility
    process.env.CLAUDE_PROJECT_DIR = opts.fixturePath;

    // Lazy-load the SDK so the harness file itself is importable even
    // when deps aren't installed.
    let queryFn: SDKQueryFn;
    try {
      const sdk = (await import("@anthropic-ai/claude-agent-sdk")) as {
        query?: SDKQueryFn;
      };
      if (typeof sdk.query !== "function") {
        throw new Error(
          "@anthropic-ai/claude-agent-sdk exported no query() function",
        );
      }
      queryFn = sdk.query;
    } catch (err) {
      throw new Error(
        `runFixture: failed to import @anthropic-ai/claude-agent-sdk. Did you run 'npm install' in .claude/tests/e2e/? Underlying error: ${(err as Error).message}`,
      );
    }

    const queryOpts: Record<string, unknown> = {
      prompt: opts.prompt,
      options: {
        cwd: opts.fixturePath,
        settingSources: ["project"],
        plugins: [{ type: "local", path: pluginRoot }],
        model: opts.modelSnapshot,
        // SDK 0.2.138 contract: permissionMode "bypassPermissions" REQUIRES
        // allowDangerouslySkipPermissions:true alongside it; the SDK may
        // reject bypassPermissions without the explicit opt-in flag. This
        // pairing realizes autonomy principle #3 of v3 (the harness is
        // intentionally non-interactive). See:
        // https://code.claude.com/docs/en/agent-sdk/typescript
        permissionMode: opts.permissionMode ?? "bypassPermissions",
        allowDangerouslySkipPermissions: true,
        maxTurns: opts.maxTurns ?? 30,
        // includeHookEvents=true MUST be set for the SDK to emit
        // `hook_started` / `hook_response` events for non-SessionStart
        // hook types (PreToolUse, PostToolUse, Stop, UserPromptSubmit,
        // SubagentStart, SessionEnd). Without this, the trace's
        // hookOutputs only contains SessionStart firings — which makes
        // every spec assertion of the form
        // `hookFired("Stop", { decision: "approve" })` fail spuriously
        // with `saw events: [SessionStart]`. SessionStart and Setup
        // hooks are always emitted; everything else is gated on this
        // flag (SDK 0.2.138, sdk.d.ts:1383). Discovered during the
        // claude-workflow-plugin-0wk.10 Phase A.2 first live-record
        // attempt where the gate ran successfully (qa-approved labels
        // appeared on every beads task) but no Stop event surfaced in
        // the captured trace — a silent harness bug that would have
        // made the spec untestable.
        includeHookEvents: true,
        ...(opts.allowedTools ? { allowedTools: opts.allowedTools } : {}),
      },
    };

    const toolCallStartTimes = new Map<string, number>();
    const hookStartTimes = new Map<
      string,
      { event: string; script: string; start: number }
    >();

    const iterator = queryFn(queryOpts);
    let resultSeen = false;
    for await (const msg of iterator) {
      const { done } = ingestMessage(
        msg,
        trace,
        toolCallStartTimes,
        hookStartTimes,
        opts.verbose ?? false,
      );
      if (done) {
        resultSeen = true;
        // Don't break — let the iterator close naturally. The SDK may
        // emit additional cleanup events after `result`.
      }
    }

    if (!resultSeen) {
      throw new Error(
        "runFixture: SDK iterator closed without emitting a `result` event. The run may have been aborted or the SDK is misbehaving.",
      );
    }

    // Capture fixture file diffs and Beads label transitions BEFORE we
    // restore — once we restore, the diffs vanish.
    trace.fileWrites = captureFileWrites(opts.fixturePath);
    // Flush bd's pending JSONL exports before reading `beadsAfter`. The
    // daemon path (MCP `bd_create_task` and similar) writes SQLite eagerly
    // but flushes JSONL on a 5s poll interval, so a naive read here misses
    // any task created within ~5s of end-of-run. The flush is run with
    // BD_NO_DAEMON=1 and `--flush-only` (skips git ops), so it's fast and
    // hermetic. Tolerant of failure — see flushFixtureBeads docstring.
    // The matching spec assertion in fixtures uses the established OR-shape
    // (harness diff OR MCP tool call OR Bash bd create) so a flush failure
    // here doesn't break workflow assertions. Cross-ref:
    // claude-workflow-plugin-l1r.7 (live rubric trace evidence).
    const postFlush = flushFixtureBeads(opts.fixturePath);
    if (!postFlush.ok && !postFlush.noBeadsDir) {
      process.stderr.write(
        `[runFixture] WARNING: post-run beads flush failed (capture will fall back to spec OR-shape): bdMissing=${postFlush.bdMissing}, status=${postFlush.status}, stderrTail=${postFlush.stderrTail.replace(/\n/g, " | ").slice(0, 200)}\n`,
      );
    }
    const beadsAfter = readBeadsIssues(opts.fixturePath);
    const { created, transitions } = diffBeadsIssues(beadsBefore, beadsAfter);
    trace.beadsTasksCreated = created;
    trace.beadsLabelTransitions = transitions;
  } finally {
    // ALWAYS restore — even on throw — so the fixture is reusable.
    try {
      restoreFixture(opts.fixturePath, snapshot);
    } catch (restoreErr) {
      process.stderr.write(
        `[runFixture] WARNING: restore failed: ${(restoreErr as Error).message}\n`,
      );
    }
    // Remove signal handlers so they don't accumulate across multiple
    // runs in the same vitest worker (spec files share a process under
    // singleFork:true) and don't fire after the spec has already
    // finished cleaning up.
    if (handlersInstalled) {
      process.off("SIGINT", sigintHandler);
      process.off("SIGTERM", sigtermHandler);
    }
    // Restore env.
    if (savedEnv.HOME !== undefined) process.env.HOME = savedEnv.HOME;
    else delete process.env.HOME;
    if (savedEnv.CLAUDE_PROJECT_DIR !== undefined)
      process.env.CLAUDE_PROJECT_DIR = savedEnv.CLAUDE_PROJECT_DIR;
    else delete process.env.CLAUDE_PROJECT_DIR;
    if (savedEnv.USERPROFILE !== undefined)
      process.env.USERPROFILE = savedEnv.USERPROFILE;
    else delete process.env.USERPROFILE;
    // Best-effort cleanup of the per-run HOME tempdir.
    try {
      rmSync(isoHome, { recursive: true, force: true });
    } catch {
      /* leave the tempdir; it's under .tmp/ and will be cleaned by `make clean` */
    }
    // ALWAYS write the trace dump — success or throw — so a mid-run
    // failure (e.g. an SDK iterator error, or a vitest assertion against
    // the trace later in the spec) still leaves a post-mortem artifact
    // behind. Without this, RECORD_GOLDEN=1 only writes the golden after
    // every assertion passes; a single failure mid-spec discards the
    // entire ~$10-15 live capture. The dump path was pre-computed
    // (`replayPath`) at the top of the run so it's stable. See
    // `writeTraceDump` for the failure-tolerant write semantics.
    writeTraceDump(replayPath, trace);
  }

  // Validate the trace against the schema before returning. A schema
  // failure here is a harness bug (we produced a malformed Trace), not
  // a test failure. The dump above ran before this — so a schema
  // failure here is still post-mortem-debuggable from the JSONL file.
  return TraceSchema.parse(trace);
}
