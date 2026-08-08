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
                    "Check `.beads/daemon.log` for hangs, and `bd dolt status` for the backend state. " +
                    "(`--no-daemon` was REMOVED in bd 1.1.x, which runs an in-process embedded Dolt " +
                    "engine — there is no daemon to disable.)",
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
 * `bd show <id> --json` with optional hydration flags, tolerant of the bd
 * versions this plugin supports (>=0.47).
 *
 * WHY: bd 1.1.2 stopped INLINING two arrays that 0.47.x returned by default.
 * Plain `bd show --json` now returns `comment_count` / `dependent_count`
 * integers, and the arrays themselves require the new `--include-comments` /
 * `--include-dependents` flags. Reading `.comments` off a plain 1.1.2 response
 * silently yields [] — which for the QA gate means "no approval record", and
 * for bd_doc_read means "no docs".
 *
 * bd 0.47.x does not have those flags and exits 1 with
 * "unknown flag: --include-comments" — but it inlines both arrays already. So
 * we try the hydrated form and fall back to the plain one ONLY on an
 * unknown-flag error. Pin the chain, not the leg. Any other failure (missing
 * task, timeout) propagates untouched, so we never mask a real error behind a
 * second call.
 *
 * Pass the flags ONLY where the field is actually read: hydration is not free
 * (bd's own help warns it "may be slow on issues with many comments"), though
 * measured against this repo's heaviest bead it costs ~40ms on a ~350ms
 * baseline, i.e. process startup dominates.
 *
 * @param {string} tid           issue id
 * @param {object} opts          cwd / hintOnError, plus:
 *   includeComments  {boolean}  hydrate .comments[]
 *   includeDependents{boolean}  hydrate .dependents[]
 *   extraArgs        {string[]} additional bd args (e.g. ['--refs'])
 */
export async function runBdShowJson(tid, opts = {}) {
    const extraArgs = opts.extraArgs || [];
    const plain = ['show', tid, '--json', ...extraArgs];
    const hydrate = [];
    if (opts.includeComments) hydrate.push('--include-comments');
    if (opts.includeDependents) hydrate.push('--include-dependents');
    if (hydrate.length === 0) return runBdJson(plain, opts);

    try {
        return await runBdJson(['show', tid, '--json', ...hydrate, ...extraArgs], opts);
    } catch (err) {
        if (err instanceof BdError && /unknown flag/i.test(err.stderr || '')) {
            // bd 0.47.x — the arrays are inlined in the plain response.
            return runBdJson(plain, opts);
        }
        throw err;
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

// ---------------------------------------------------------------------------
// COMMENT AVAILABILITY (claude-workflow-plugin-fkm.1.18)
//
// THE RULE THIS ENFORCES: a tool must not report a comment count it did not
// establish. `[]` has to mean "this task genuinely has none", never "I could
// not see them".
//
// WHY IT IS A SHARED HELPER AND NOT A PATCH AT ONE CALL SITE. Four readers
// consume `.comments` off a show response — bd_list_comments, bd_doc_read,
// bd_doc_write (named docs ARE comments, and a blind read computes
// nextVersion=1 over an existing chain, which FORKS it rather than merely
// hiding it) and bd_show_task's headline. Every one of them previously spelled
// `task.comments || []`, which turns an unreadable source into a confident
// zero. Fixing the transport at one of them is what already happened once:
// fkm.1.1 added `--include-comments` on 2026-08-03, and on 2026-08-04 the tool
// still answered `{"ok":true,...,"comments":[]}` on a task carrying 76, because
// nothing CHECKED that the transport had worked.
//
// THE WITNESS, and why this is possible at all: bd reports `comment_count`
// separately from the bodies, and it reports it on a PLAIN show — the exact
// response shape that carries no bodies. So every response that can lose the
// array still carries the number that proves the array is missing.
//
// MEASURED against this repo's ledger on bd 1.1.2, all 342 issues, hydrated:
//   comment_count present on 342/342          (never absent)
//   comment_count === comments.length 342/342 (never disagrees)
//   `comments` KEY ABSENT on 117/342          — exactly the 117 with count 0
//
// That last row is why key-presence is NOT the discriminator: bd 1.1.2 omits
// `comments` entirely on a zero-comment task even when hydrating, so
// "key absent => unavailable" would have failed 34% of this ledger. The count
// is the witness; the key is not.
export const COMMENTS_VERIFIED = 'verified';
export const COMMENTS_UNVERIFIED = 'unverified';
export const COMMENTS_UNAVAILABLE = 'unavailable';

/**
 * Decide whether a show response's comment bodies can be trusted.
 *
 * @param {object|null} task  normalizeShowResult() output
 * @returns {{status: string, comments: Array, count: number|null, reason: string|null}}
 *
 *   verified     the array is present and agrees with comment_count (this
 *                INCLUDES the genuine-zero case: count 0 with no array).
 *   unverified   bodies are present but no comment_count came back to check
 *                them against (a bd old enough to inline the array without
 *                publishing the count). Callers may use the bodies; they must
 *                not claim the count is confirmed.
 *   unavailable  the count says there are comments and the bodies did not
 *                arrive, or nothing usable came back at all. NEVER report this
 *                as an empty result.
 */
export function resolveComments(task) {
    const arrRaw = task && task.comments;
    const hasArray = Array.isArray(arrRaw);
    const comments = hasArray ? arrRaw : [];

    // comment_count may legitimately arrive as a JSON number; tolerate a
    // numeric string so a future serialisation change degrades to `unverified`
    // rather than to a wrong verdict.
    const ccRaw = task ? task.comment_count : undefined;
    let count = null;
    if (typeof ccRaw === 'number' && Number.isFinite(ccRaw)) {
        count = ccRaw;
    } else if (typeof ccRaw === 'string' && /^\d+$/.test(ccRaw.trim())) {
        count = parseInt(ccRaw.trim(), 10);
    }

    if (count === null) {
        if (hasArray) {
            return {
                status: COMMENTS_UNVERIFIED,
                comments,
                count: null,
                reason:
                    `bd returned ${comments.length} comment body/bodies but no comment_count field, ` +
                    `so the count could not be cross-checked against an independent witness.`,
            };
        }
        return {
            status: COMMENTS_UNAVAILABLE,
            comments: [],
            count: null,
            reason:
                "bd returned neither a comments array nor a comment_count field, so " +
                "'this task has no comments' and 'the comments could not be read' are indistinguishable.",
        };
    }

    if (count === comments.length) {
        return { status: COMMENTS_VERIFIED, comments, count, reason: null };
    }

    return {
        status: COMMENTS_UNAVAILABLE,
        comments,
        count,
        reason:
            `bd reports comment_count=${count} but returned ${hasArray ? comments.length : 'no'} ` +
            `comment ${hasArray ? 'bodies' : 'body array'}. The bodies are missing or truncated, ` +
            `not absent.`,
    };
}

/**
 * The one BdError every caller raises when resolveComments() says the bodies
 * cannot be trusted. Centralised so the four readers cannot drift into
 * describing the same failure four different ways.
 *
 * @param {string} tid        issue id, for the message
 * @param {object} resolved   resolveComments() output
 * @param {string} whatFor    what the caller needed the comments FOR
 */
export function commentsUnavailableError(tid, resolved, whatFor) {
    return new BdError(
        `Comments on '${tid}' could not be read — refusing to report an empty result. ${resolved.reason}`,
        {
            hint:
                `This tool needs the comment bodies ${whatFor}. Reproduce with ` +
                `\`bd show ${tid} --json --include-comments\` and compare \`.comment_count\` against ` +
                `\`.comments | length\`. If the installed bd does not stream bodies, read them with ` +
                `plain \`bd show ${tid}\` (the COMMENTS section) until the transport is fixed. ` +
                `An empty array from this tool means the task genuinely has none; this error means ` +
                `it could not be established either way.`,
        },
    );
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
