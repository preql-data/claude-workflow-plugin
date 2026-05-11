// bd_label.js — label add/remove/list tools.
//
// These wrap `bd label {add,remove,list}`. We expose them as MCP tools
// even though bd_update_task can also add/remove labels — the label-only
// variant is the right call when the caller wants pure label semantics
// without touching anything else (idempotent, narrow scope).
//
// idempotentHint: true — adding a label that's already present is a no-op
// in Beads, and removing one that's absent is also a no-op. Both are safe
// to retry.

import { z } from 'zod';
import {
    runBdJson,
    runBd,
    BdError,
    validateTaskId,
    HINT_LIST_TO_FIND_IDS,
    normalizeShowResult,
} from '../lib/exec-bd.js';
import { ok, fail, safe } from '../lib/format.js';

export function registerLabelTools(server) {
    server.registerTool(
        'bd_add_label',
        {
            title: 'Add a label to a Beads task',
            description:
                "Add a single label to one or more tasks. Idempotent — adding a label that's already " +
                "present is a successful no-op.\n\n" +
                "Common labels in this workflow: backend, frontend, devops, qa-pending, qa-approved, " +
                "qa-blocked, qa-gate-entered, bug, improvement.\n\n" +
                "Replaces shell: `bd label add <id> <label>`",
            inputSchema: {
                task_ids: z.array(z.string().min(1).max(256)).min(1)
                    .describe("One or more task ids to label."),
                label: z.string().min(1).max(64)
                    .describe("Single label to add (e.g., 'qa-pending'). For multiple labels, call repeatedly."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Add label',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const ids = input.task_ids.map((t) => validateTaskId(t));
            // bd label add accepts multiple ids in a single call; we batch.
            const args = ['label', 'add', ...ids, input.label];
            await runBd(args, {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            return ok(
                `Added label '${input.label}' to ${ids.length} task(s)`,
                { task_ids: ids, label: input.label, op: 'add' },
                "Label add is idempotent — re-running this call is a safe no-op.",
            );
        }),
    );

    server.registerTool(
        'bd_remove_label',
        {
            title: 'Remove a label from a Beads task',
            description:
                "Remove a single label from one or more tasks. Idempotent — removing a label that's " +
                "absent is a successful no-op.\n\n" +
                "destructiveHint: true because removing a workflow label (e.g., qa-pending) can change " +
                "what hooks fire next. Be deliberate.\n\n" +
                "Replaces shell: `bd label remove <id> <label>`",
            inputSchema: {
                task_ids: z.array(z.string().min(1).max(256)).min(1),
                label: z.string().min(1).max(64),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Remove label',
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const ids = input.task_ids.map((t) => validateTaskId(t));
            const args = ['label', 'remove', ...ids, input.label];
            await runBd(args, {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            return ok(
                `Removed label '${input.label}' from ${ids.length} task(s)`,
                { task_ids: ids, label: input.label, op: 'remove' },
                null,
            );
        }),
    );

    server.registerTool(
        'bd_list_labels',
        {
            title: 'List labels on a task or across the whole DB',
            description:
                "Two modes:\n" +
                "  - With task_id: list labels on that specific task.\n" +
                "  - Without task_id: list every distinct label in the database (useful for triage).\n\n" +
                "Replaces shell: `bd label list <id>` or `bd label list-all`",
            inputSchema: {
                task_id: z.string().min(1).max(256).optional(),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'List labels',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            if (input.task_id) {
                const tid = validateTaskId(input.task_id);
                // We use `bd show --json` because `bd label list` doesn't
                // have a --json output mode (it pretty-prints). show is the
                // robust path: it returns an object containing labels[].
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
                const labels = task.labels || [];
                return ok(
                    `bd_list_labels ${tid}: ${labels.length} label(s)`,
                    { task_id: tid, labels },
                    null,
                );
            }
            // No task — list-all across the DB. We probe via `bd label list-all
            // --json`; older bd may not support --json on this subcommand, so
            // we have a graceful fallback to plain text.
            try {
                const raw = await runBdJson(['label', 'list-all', '--json'], { cwd: input.cwd });
                const arr = Array.isArray(raw) ? raw : (raw && raw.labels) || [];
                return ok(`bd_list_labels (db-wide): ${arr.length} label(s)`, { labels: arr }, null);
            } catch (err) {
                if (err instanceof BdError) {
                    // Try plain (no --json) fallback.
                    const { stdout } = await runBd(['label', 'list-all'], { cwd: input.cwd });
                    const lines = stdout
                        .split('\n')
                        .map((l) => l.trim())
                        .filter((l) => l && !l.startsWith('#'));
                    return ok(
                        `bd_list_labels (db-wide, fallback): ${lines.length} label(s)`,
                        { labels: lines },
                        "Used plain-text fallback because the bd version did not return JSON for label list-all.",
                    );
                }
                throw err;
            }
        }),
    );
}
