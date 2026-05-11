// bd_qa.js — QA-gate lifecycle tools.
//
// These wrap qa-gate.sh (Phase 1 / B1 / D1 / J2 / F4) so the LLM can drive
// the lifecycle end-to-end without ever shell-string-formatting a bd
// command. Mapping:
//
//   bd_qa_enter   -> qa-gate.sh enter   <id>
//   bd_qa_status  -> qa-gate.sh status  <id>
//   bd_qa_approve -> qa-gate.sh approve <id> "<summary>"
//   bd_qa_block   -> qa-gate.sh block   <id> "<reason>"
//
// Why shell out to qa-gate.sh and not re-implement here:
//   qa-gate.sh contains a pile of state-tracking logic — current-task
//   helper write/clear, iteration-counter wipe, qa-block memory
//   fingerprint/index updates, atomic label rollback on failure. Forking
//   that into JS would double the maintenance burden and risk drift
//   between the bash hooks (which still call qa-gate.sh directly) and the
//   MCP tools.
//
// Fallback path: if qa-gate.sh isn't found (unusual install), we degrade
// to talking directly to bd label/show/comments. The fallback covers
// enter/status/approve/block but skips the memory + iteration-state side
// effects with a clear note in observations.

import { z } from 'zod';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import {
    runBd,
    runBdJson,
    BdError,
    validateTaskId,
    HINT_LIST_TO_FIND_IDS,
    resolveQaGateScript,
    resolveBdCwd,
    normalizeShowResult,
} from '../lib/exec-bd.js';
import { ok, fail, safe } from '../lib/format.js';

const execFileP = promisify(execFile);

// ---------------------------------------------------------------------------
// qa-gate.sh wrapper

/**
 * Invoke qa-gate.sh with a subcommand + args. Returns the parsed JSON
 * payload. If the script isn't on disk, returns null so the caller can
 * choose a fallback.
 */
async function callQaGate(sub, args, opts = {}) {
    const script = resolveQaGateScript(opts);
    if (!script) return { fallback: true, reason: 'qa-gate.sh not found at .claude/scripts/' };
    const cwd = resolveBdCwd(opts);
    try {
        const { stdout, stderr } = await execFileP('bash', [script, sub, ...args], {
            cwd,
            timeout: 60_000,
            maxBuffer: 4 * 1024 * 1024,
            env: { ...process.env, CLAUDE_PROJECT_DIR: cwd },
        });
        const trimmed = stdout.trim();
        if (!trimmed) {
            throw new BdError(`qa-gate.sh ${sub} returned no output`, {
                stderr,
                hint: "Check .claude/.qa-tracking/sync-errors.log for context.",
            });
        }
        let parsed;
        try {
            parsed = JSON.parse(trimmed);
        } catch {
            throw new BdError(`qa-gate.sh ${sub} produced unparseable JSON`, {
                stderr,
                stdout: trimmed.slice(0, 2000),
                hint: "qa-gate.sh should always emit JSON. Check that bash and jq are on PATH.",
            });
        }
        return { fallback: false, payload: parsed, stderr };
    } catch (err) {
        if (err instanceof BdError) throw err;
        // execFile rejection: err.stdout/stderr/code populated.
        throw new BdError(
            `qa-gate.sh ${sub} failed (exit ${err.code ?? 'unknown'})`,
            {
                stderr: err.stderr || '',
                stdout: err.stdout || '',
                code: err.code,
                hint: HINT_LIST_TO_FIND_IDS,
            },
        );
    }
}

// ---------------------------------------------------------------------------
// Direct fallbacks (when qa-gate.sh is absent)

async function fallbackEnter(tid, opts) {
    // Add qa-gate-entered if missing; idempotent.
    const showRaw = await runBdJson(['show', tid, '--json'], {
        cwd: opts.cwd,
        hintOnError: HINT_LIST_TO_FIND_IDS,
    });
    const task = normalizeShowResult(showRaw);
    if (!task) {
        throw new BdError(`Task '${tid}' not found`, { hint: HINT_LIST_TO_FIND_IDS });
    }
    const labels = task.labels || [];
    if (!labels.includes('qa-gate-entered')) {
        await runBd(['label', 'add', tid, 'qa-gate-entered'], { cwd: opts.cwd });
    }
    return { status: 'entered', already: labels.includes('qa-gate-entered') };
}

async function fallbackStatus(tid, opts) {
    const showRaw = await runBdJson(['show', tid, '--json'], {
        cwd: opts.cwd,
        hintOnError: HINT_LIST_TO_FIND_IDS,
    });
    const task = normalizeShowResult(showRaw);
    if (!task) {
        throw new BdError(`Task '${tid}' not found`, { hint: HINT_LIST_TO_FIND_IDS });
    }
    const labels = task.labels || [];
    if (labels.includes('qa-approved')) return { status: 'approved', labels };
    if (labels.includes('qa-blocked')) return { status: 'blocked', labels };
    if (labels.includes('qa-gate-entered')) return { status: 'entered', labels };
    return { status: 'not-entered', labels };
}

async function fallbackApprove(tid, summary, opts) {
    // Atomic-ish: add qa-approved, remove qa-gate-entered, remove qa-pending.
    await runBd(['label', 'add', tid, 'qa-approved'], { cwd: opts.cwd });
    // Best-effort removes — Beads returns success when the label is absent.
    await runBd(['label', 'remove', tid, 'qa-gate-entered'], { cwd: opts.cwd }).catch(() => {});
    await runBd(['label', 'remove', tid, 'qa-pending'], { cwd: opts.cwd }).catch(() => {});
    // Comment.
    const ts = new Date().toISOString();
    await runBd(['comments', 'add', tid, `QA-GATE APPROVED at ${ts}: ${summary}`], { cwd: opts.cwd })
        .catch(() => runBd(['comment', 'add', tid, `QA-GATE APPROVED at ${ts}: ${summary}`], { cwd: opts.cwd }))
        .catch(() => {});
    return { status: 'approved' };
}

async function fallbackBlock(tid, reason, opts) {
    await runBd(['label', 'add', tid, 'qa-blocked'], { cwd: opts.cwd });
    const ts = new Date().toISOString();
    await runBd(['comments', 'add', tid, `QA-GATE BLOCKED at ${ts}: ${reason}`], { cwd: opts.cwd })
        .catch(() => runBd(['comment', 'add', tid, `QA-GATE BLOCKED at ${ts}: ${reason}`], { cwd: opts.cwd }))
        .catch(() => {});
    return { status: 'blocked' };
}

// ---------------------------------------------------------------------------
// Tool registration

export function registerQaTools(server) {
    server.registerTool(
        'bd_qa_enter',
        {
            title: 'Enter the QA gate for a task',
            description:
                "Mark a task as having entered the QA gate. Adds the qa-gate-entered label, persists " +
                "the active task id to .claude/.qa-tracking/current-task (so hooks can find it), and " +
                "writes an audit comment.\n\n" +
                "Idempotent: re-entering refreshes the current-task helper but is otherwise a no-op " +
                "if the label is already present.\n\n" +
                "Replaces shell: `bash .claude/scripts/qa-gate.sh enter <id>`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'QA: enter gate',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            const result = await callQaGate('enter', [tid], { cwd: input.cwd });
            if (result.fallback) {
                const direct = await fallbackEnter(tid, { cwd: input.cwd });
                return ok(
                    `QA gate entered for ${tid} (fallback path)`,
                    { task_id: tid, status: direct.status, fallback: true },
                    `qa-gate.sh not found (${result.reason}); used direct bd-label fallback. ` +
                    "Side effects (current-task helper, iteration counters) were SKIPPED — " +
                    "if you rely on those, install the .claude/scripts/qa-gate.sh helper.",
                );
            }
            const p = result.payload;
            return ok(
                `QA gate entered for ${tid}: ${p.status || 'entered'}`,
                p,
                p.observations || null,
            );
        }),
    );

    server.registerTool(
        'bd_qa_status',
        {
            title: 'Get QA gate status for a task',
            description:
                "Return one of: not-entered, entered, approved, blocked. Precedence: approved > blocked > " +
                "entered > not-entered. Read-only — purely a status check.\n\n" +
                "Replaces shell: `bash .claude/scripts/qa-gate.sh status <id>`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'QA: status',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            const result = await callQaGate('status', [tid], { cwd: input.cwd });
            if (result.fallback) {
                const direct = await fallbackStatus(tid, { cwd: input.cwd });
                return ok(
                    `QA status for ${tid}: ${direct.status}`,
                    { task_id: tid, ...direct, fallback: true },
                    `qa-gate.sh not found; used direct bd-label fallback.`,
                );
            }
            const p = result.payload;
            return ok(
                `QA status for ${tid}: ${p.status || 'unknown'}`,
                p,
                p.observations || null,
            );
        }),
    );

    server.registerTool(
        'bd_qa_approve',
        {
            title: 'Approve the QA gate for a task',
            description:
                "Atomic operation: add qa-approved, remove qa-gate-entered, remove qa-pending, write an " +
                "audit comment with the approval summary. On any failure, all label changes are rolled " +
                "back. Also clears .claude/.qa-tracking/current-task and per-task iteration counters.\n\n" +
                "Idempotent: if qa-approved is already present, returns success no-op without re-doing " +
                "anything.\n\n" +
                "Replaces shell: `bash .claude/scripts/qa-gate.sh approve <id> '<summary>'`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                summary: z.string().min(1).max(5000)
                    .describe("Human-readable summary of why this task was approved (commits, test runs, etc.)."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'QA: approve',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            const result = await callQaGate('approve', [tid, input.summary], { cwd: input.cwd });
            if (result.fallback) {
                const direct = await fallbackApprove(tid, input.summary, { cwd: input.cwd });
                return ok(
                    `QA approved ${tid} (fallback path)`,
                    { task_id: tid, ...direct, fallback: true },
                    `qa-gate.sh not found (${result.reason}); used direct bd-label fallback. ` +
                    "current-task helper + iteration-counter wipe were SKIPPED.",
                );
            }
            const p = result.payload;
            return ok(
                `QA approved ${tid}`,
                p,
                p.observations || null,
            );
        }),
    );

    server.registerTool(
        'bd_qa_block',
        {
            title: 'Block the QA gate for a task with a reason',
            description:
                "Add the qa-blocked label and record the reason. Keeps qa-gate-entered (so the gate " +
                "stays open until either approve or unblock-and-approve). Also writes a feedback memory " +
                "entry under ~/.claude/projects/<slug>/memory/qa-block-<fp>.md so subsequent sessions " +
                "can pre-warn for the same pattern (Phase 5 / E8).\n\n" +
                "Replaces shell: `bash .claude/scripts/qa-gate.sh block <id> '<reason>'`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                reason: z.string().min(1).max(5000)
                    .describe("Reason for the block. The first ~80 chars are fingerprinted for memory dedup."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'QA: block',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            const result = await callQaGate('block', [tid, input.reason], { cwd: input.cwd });
            if (result.fallback) {
                const direct = await fallbackBlock(tid, input.reason, { cwd: input.cwd });
                return ok(
                    `QA blocked ${tid} (fallback path)`,
                    { task_id: tid, ...direct, fallback: true },
                    `qa-gate.sh not found (${result.reason}); used direct bd-label fallback. ` +
                    "Memory entry write was SKIPPED.",
                );
            }
            const p = result.payload;
            return ok(
                `QA blocked ${tid}: ${input.reason.slice(0, 80)}`,
                p,
                p.observations || null,
            );
        }),
    );
}
