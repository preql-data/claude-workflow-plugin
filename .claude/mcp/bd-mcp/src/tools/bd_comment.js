// bd_comment.js — comments add/list tools.
//
// bd_add_comment is the typed wrapper around `bd comments add`. It includes
// metadata-aware optional fields (kind, author, ts) which we serialize as
// a structured JSON header in the comment body. The header lets downstream
// tools (qa-gate, doc tools, statusline) parse comments deterministically
// without doing free-text scans.
//
// We tolerate Beads' newer (`comments`) and older (`comment`) singular
// command names — qa-gate.sh does the same dance.

import { z } from 'zod';
import {
    runBd,
    BdError,
    validateTaskId,
    HINT_LIST_TO_FIND_IDS,
    runBdJson,
    normalizeShowResult,
} from '../lib/exec-bd.js';
import { ok, fail, safe } from '../lib/format.js';

// ---------------------------------------------------------------------------
// Helpers

/**
 * Try `bd comments add <id> <body>` first; fall back to `bd comment add ...`
 * for older Beads versions that used the singular command name.
 */
async function addComment(taskId, body, opts = {}) {
    try {
        return await runBd(['comments', 'add', taskId, body], opts);
    } catch (errFirst) {
        try {
            return await runBd(['comment', 'add', taskId, body], opts);
        } catch (errSecond) {
            // Re-raise the FIRST error (more relevant for newer bd versions)
            // but prefer the second error's stderr if the first was empty
            // (which can happen if `comments` was just absent without
            // surfacing a stderr message).
            const first = errFirst instanceof BdError ? errFirst : null;
            const second = errSecond instanceof BdError ? errSecond : null;
            const merged = new BdError(
                "Could not add comment via either `bd comments add` or `bd comment add`.",
                {
                    stderr: (first?.stderr || second?.stderr || '').slice(0, 2000),
                    hint:
                        "Verify bd is on PATH and the task id exists. " +
                        HINT_LIST_TO_FIND_IDS,
                },
            );
            throw merged;
        }
    }
}

export function registerCommentTools(server) {
    server.registerTool(
        'bd_add_comment',
        {
            title: 'Add a comment to a Beads task',
            description:
                "Add a comment to a Beads task. Comments are append-only — there's no edit/delete on " +
                "the Beads side. The comment text supports Markdown.\n\n" +
                "If you pass `metadata` (e.g., {kind: 'qa-note', source: 'qa-agent'}), the metadata is " +
                "serialized as a JSON line at the top of the comment so downstream tools can parse it. " +
                "Plain text comments (no metadata) post unchanged.\n\n" +
                "Replaces shell: `bd comments add <id> '<body>'`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                body: z.string().min(1).max(50_000)
                    .describe("Comment body. Supports Markdown."),
                metadata: z
                    .record(z.string(), z.union([z.string(), z.number(), z.boolean(), z.null()]))
                    .optional()
                    .describe(
                        "Optional structured metadata to embed at the top of the comment as a JSON line " +
                        "(e.g., {kind: 'qa-note'}). Useful for typed comment streams.",
                    ),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Add comment',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            // Build the comment body. If metadata is present, prepend a
            // <!-- BD-MCP-META: {...} --> HTML comment line so the Beads
            // markdown rendering doesn't show it but parsers can extract.
            let body = input.body;
            if (input.metadata && Object.keys(input.metadata).length > 0) {
                const meta = JSON.stringify(input.metadata);
                body = `<!-- BD-MCP-META: ${meta} -->\n${input.body}`;
            }
            await addComment(tid, body, { cwd: input.cwd });
            return ok(
                `Added comment to ${tid}`,
                { task_id: tid, length: body.length, metadata: input.metadata || null },
                null,
            );
        }),
    );

    server.registerTool(
        'bd_list_comments',
        {
            title: 'List comments on a task',
            description:
                "Return all comments on a task in chronological order. Each comment includes id, " +
                "author, text, and created_at.\n\n" +
                "Comments embedded with bd_add_comment metadata expose their JSON header in the text — " +
                "callers may parse <!-- BD-MCP-META: {...} --> on the first line.\n\n" +
                "Replaces shell: `bd show <id> --json | jq '.comments'`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'List comments',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            // bd show is more reliable than `bd comments <id> --json`, which
            // doesn't exist as a standalone JSON-list mode in 0.47.x.
            const raw = await runBdJson(['show', tid, '--json'], {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            const task = normalizeShowResult(raw);
            if (!task) {
                return fail(
                    new BdError(`Task '${tid}' not found`, { hint: HINT_LIST_TO_FIND_IDS }),
                );
            }
            const comments = task.comments || [];
            return ok(
                `bd_list_comments ${tid}: ${comments.length} comment(s)`,
                { task_id: tid, comments },
                null,
            );
        }),
    );
}
