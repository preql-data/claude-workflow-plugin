// exec-bd.js — shared helper for invoking the Beads (`bd`) CLI from MCP tools.
//
// Why this exists:
//   Every MCP tool ultimately shells out to `bd <subcommand>`. Putting the
//   exec logic + JSON parsing + actionable-error messages here keeps the
//   per-tool code tiny and consistent.
//
// Design choices:
//   1. execFile (not exec) — no shell interpolation, args are passed as an
//      array. Prevents shell injection from any user-supplied string that
//      ends up as a flag value.
//   2. cwd defaults to BD_CWD env var or process.cwd(). MCP servers run as a
//      child process spawned by Claude Code; the parent passes the project
//      directory via `cwd` in .mcp.json so bd auto-discovers .beads/ from
//      the right place.
//   3. JSON normalization — `bd show <id> --json` returns either an object
//      or a 1-element array depending on bd version (Phase 1 / qa-gate.sh
//      already learned this). normalizeShowResult collapses both shapes.
//   4. Actionable errors — when bd fails, BdError carries the stderr tail
//      AND a hint string. Tools wrap thrown errors into MCP tool results
//      with isError: true.
//
// Imports limited to Node stdlib so the module has zero install cost beyond
// `npm install` for the MCP SDK + zod itself.

import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { existsSync } from 'node:fs';
import path from 'node:path';

const execFileP = promisify(execFile);

// Maximum stdout we will buffer from bd. bd output for `bd list --json` can
// grow large; we cap at 16 MB which is well above realistic Beads-DB sizes.
const MAX_STDOUT = 16 * 1024 * 1024;

// Default timeout for bd invocations. bd is fast; 30s is generous and stops
// us from hanging the MCP server forever if bd deadlocks on a daemon lock.
const DEFAULT_TIMEOUT_MS = 30_000;

/**
 * Custom error type used to surface actionable hints to the LLM.
 *
 * The MCP tool layer translates BdError into a CallToolResult with
 * isError: true and content of the form:
 *
 *   <message>
 *
 *   stderr: <truncated stderr>
 *
 *   hint: <hint>
 *
 * Tool callers can also catch this and decide to recover (e.g., qa_enter
 * is idempotent and treats "label already present" as success).
 */
export class BdError extends Error {
    constructor(message, { stderr, stdout, code, hint } = {}) {
        super(message);
        this.name = 'BdError';
        this.stderr = (stderr || '').toString();
        this.stdout = (stdout || '').toString();
        this.code = code;
        this.hint = hint;
    }
}

/**
 * Resolve the cwd to run bd in. Precedence:
 *   1. Explicit `opts.cwd`
 *   2. BD_CWD env var (set by the MCP launcher in .mcp.json)
 *   3. CLAUDE_PROJECT_DIR env var (set by Claude Code itself for hooks)
 *   4. process.cwd()
 *
 * If the resolved candidate already has a .beads/ directory, we use it
 * as-is — never walk up from a known bd root. The walk-up search only
 * applies when the explicit cwd lacks .beads/ and we therefore need to
 * locate a parent that has it (for ergonomics: the hooks may pass a
 * subdirectory of the project root). This avoids accidentally picking
 * up an unrelated parent's .beads when the caller has clearly named a
 * specific repo.
 *
 * Phase 6b QA followup (Phase 6a item 3): tighten so an explicit cwd
 * with .beads/ never triggers the walk-up, and the walk-up is capped to
 * a reasonable depth even when no .beads/ is found.
 */
export function resolveBdCwd(opts = {}) {
    const explicitlyProvided =
        opts.cwd !== undefined ||
        process.env.BD_CWD !== undefined ||
        process.env.CLAUDE_PROJECT_DIR !== undefined;

    const candidate =
        opts.cwd ||
        process.env.BD_CWD ||
        process.env.CLAUDE_PROJECT_DIR ||
        process.cwd();

    let dir = path.resolve(candidate);

    // Tightening: if the candidate already has .beads/, use it as-is.
    // This stops us from walking up out of a chosen repo and into an
    // unrelated parent's .beads.
    if (existsSync(path.join(dir, '.beads'))) {
        return dir;
    }

    // Walk-up search. We cap depth at 8 to guard against pathological mounts
    // and to keep this O(1) on any sane filesystem.
    for (let i = 0; i < 8; i++) {
        const parent = path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
        if (existsSync(path.join(dir, '.beads'))) {
            return dir;
        }
    }

    // Fall back to candidate even if no .beads — bd will produce a clean
    // error and our wrapper turns it into a BdError with a hint.
    // (We resolve the original candidate, not the walked-up dir, so the
    // error message references the place the caller actually pointed at.)
    return path.resolve(candidate);
}

/**
 * Run a bd subcommand. Returns { stdout, stderr } on exit code 0; throws
 * BdError otherwise.
 *
 * @param {string[]} args - command + flags, e.g. ['list', '--json']
 * @param {object} opts
 *   @param {string}   [opts.cwd]      - working dir; see resolveBdCwd
 *   @param {string}   [opts.input]    - stdin to pipe in (used by --body-file=- patterns)
 *   @param {number}   [opts.timeoutMs]- override default 30s timeout
 *   @param {string}   [opts.hintOnError] - hint string attached to BdError
 */
export async function runBd(args, opts = {}) {
    const cwd = resolveBdCwd(opts);
    const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;

    try {
        const result = await execFileP('bd', args, {
            cwd,
            timeout: timeoutMs,
            maxBuffer: MAX_STDOUT,
            input: opts.input,
            env: { ...process.env },
        });
        return { stdout: result.stdout, stderr: result.stderr };
    } catch (err) {
        // execFile rejects with err.code = exit code; err.stdout/err.stderr
        // are populated. ENOENT means the bd binary itself is missing.
        if (err && err.code === 'ENOENT') {
            throw new BdError("bd CLI not found on PATH", {
                stderr: '',
                code: 'ENOENT',
                hint: "Install Beads (https://github.com/steveyegge/beads) and ensure `bd` is on PATH. Verify with `which bd` and `bd --version`.",
            });
        }
        if (err && err.killed && err.signal === 'SIGTERM') {
            throw new BdError(`bd ${args[0] || ''} timed out after ${timeoutMs}ms`, {
                stderr: err.stderr || '',
                stdout: err.stdout || '',
                code: 'TIMEOUT',
                hint: opts.hintOnError ||
                    "If the daemon is stuck, try `bd --no-daemon ${args[0]}` or check `.beads/daemon.log` for hangs.",
            });
        }
        throw new BdError(
            `bd ${args.join(' ')} failed (exit ${err && err.code !== undefined ? err.code : 'unknown'})`,
            {
                stderr: err && err.stderr ? err.stderr : '',
                stdout: err && err.stdout ? err.stdout : '',
                code: err && err.code !== undefined ? err.code : 'unknown',
                hint: opts.hintOnError,
            },
        );
    }
}

/**
 * Run a bd subcommand expecting --json output. Parses stdout as JSON.
 * Throws BdError if exit code != 0; throws BdError("invalid json") if stdout
 * is not parseable.
 *
 * Some bd subcommands print a brief preamble before the JSON when --json
 * is missing — we always pass --json explicitly in callers so this stays
 * predictable.
 */
export async function runBdJson(args, opts = {}) {
    const { stdout, stderr } = await runBd(args, opts);
    const trimmed = (stdout || '').trim();
    if (trimmed.length === 0) {
        // Some commands emit nothing on success (e.g. label add). Return null
        // so the tool layer can decide what to do.
        return null;
    }
    try {
        return JSON.parse(trimmed);
    } catch (parseErr) {
        throw new BdError(`bd ${args.join(' ')} produced unparseable JSON`, {
            stderr,
            stdout: trimmed.slice(0, 2000),
            hint: "This usually means the bd version is older than expected. Check with `bd --version` (need >=0.47).",
        });
    }
}

/**
 * `bd show <id> --json` returns either an object or a 1-element array
 * depending on bd version. Normalize to a single object or null.
 */
export function normalizeShowResult(raw) {
    if (raw == null) return null;
    if (Array.isArray(raw)) {
        return raw.length === 0 ? null : raw[0];
    }
    return raw;
}

/**
 * Build a stable "actionable error" message for the LLM. We keep this
 * compact to preserve context tokens — full stderr is included only as a
 * tail, not the entire blob.
 */
export function formatBdError(err) {
    if (!(err instanceof BdError)) {
        return `Internal error: ${err && err.message ? err.message : String(err)}`;
    }
    const parts = [err.message];
    if (err.stderr && err.stderr.trim().length > 0) {
        const tail = err.stderr.trim().split('\n').slice(-6).join('\n');
        parts.push(`stderr (last 6 lines):\n${tail}`);
    }
    if (err.hint) {
        parts.push(`hint: ${err.hint}`);
    }
    return parts.join('\n\n');
}

/**
 * Convenience: run a bd command and ignore non-fatal failures. Used for
 * best-effort calls (e.g., comments add) where we don't want to fail the
 * whole tool call if the comment didn't post.
 */
export async function runBdSoft(args, opts = {}) {
    try {
        const out = await runBd(args, opts);
        return { ok: true, ...out };
    } catch (err) {
        return { ok: false, error: err };
    }
}

/**
 * Validate a Beads ID shape. Beads IDs look like `<rig>-<id>` or
 * `<rig>-<id>.<n>` — alphanumerics, dots, hyphens. Whitespace and shell
 * metacharacters are rejected. Used by every tool that takes a task_id.
 *
 * Returns the trimmed id or throws BdError("invalid id") with a hint.
 */
const ID_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
export function validateTaskId(raw, label = 'task_id') {
    if (typeof raw !== 'string') {
        throw new BdError(`${label} must be a string`, {
            hint: "Pass a Beads issue id like 'my-project-1' or 'my-project-1.3'.",
        });
    }
    const trimmed = raw.trim();
    if (trimmed.length === 0 || trimmed.length > 256) {
        throw new BdError(`${label} has invalid length`, {
            hint: "Beads ids are non-empty short strings (e.g., 'project-42').",
        });
    }
    if (!ID_RE.test(trimmed)) {
        throw new BdError(`${label} contains invalid characters`, {
            hint: "Beads ids contain only [A-Za-z0-9._-] and start with [A-Za-z0-9].",
        });
    }
    return trimmed;
}

/**
 * Common hint snippet — used when a task lookup fails.
 */
export const HINT_LIST_TO_FIND_IDS =
    "Try bd_list_tasks() with no filters, or bd_get_ready() to see actionable tasks, to find valid ids.";

/**
 * Path resolver for the qa-gate.sh helper. The MCP server is shipped under
 * .claude/mcp/bd-mcp/, and qa-gate.sh lives at .claude/scripts/qa-gate.sh
 * relative to the project root (resolved via resolveBdCwd). Returning null
 * lets the QA tools fall back to talking directly to bd if the helper is
 * absent (e.g., installs that ship the MCP server but not the bash hooks).
 */
export function resolveQaGateScript(opts = {}) {
    const cwd = resolveBdCwd(opts);
    const candidate = path.join(cwd, '.claude', 'scripts', 'qa-gate.sh');
    if (existsSync(candidate)) {
        return candidate;
    }
    // Fall back to the path next to this MCP server — useful for installs
    // where the MCP is symlinked elsewhere but the .claude tree lives a few
    // levels up. We've already walked up to find .beads in resolveBdCwd, so
    // if the script isn't there, return null.
    return null;
}
