// bd_update.js — update / close tools.
//
// bd_update_task is the omnibus mutation tool for changing the state of an
// existing task. It maps each MCP input field to a single `bd update`
// invocation so the change is one atomic call to bd.
//
// bd_close_task wraps `bd close` with optional reason and supports
// closing multiple tasks at once.
//
// Annotation choice:
//   - update is non-destructive (additive/edit-in-place; we surface the
//     before/after to the LLM so it can verify the change landed).
//   - close has destructiveHint=true. close is REVERSIBLE in Beads
//     (`bd reopen`), but it's a directional state change with side
//     effects (sub-tasks may unblock, etc.) so we flag it.

import { z } from 'zod';
import {
    runBd,
    runBdJson,
    BdError,
    validateTaskId,
    HINT_LIST_TO_FIND_IDS,
    normalizeShowResult,
} from '../lib/exec-bd.js';
import { ok, fail, safe } from '../lib/format.js';

export function registerUpdateTools(server) {
    server.registerTool(
        'bd_update_task',
        {
            title: 'Update a Beads task (status, notes, labels, etc.)',
            description:
                "Update a single Beads task. Pass only the fields you want to change. The most common " +
                "uses:\n" +
                "  - claim: set status=in_progress (use the `claim` flag for atomic claim semantics)\n" +
                "  - update notes: pass `notes` to overwrite the notes block\n" +
                "  - add/remove labels: use `add_labels[]` and `remove_labels[]`\n" +
                "  - reassign: pass `assignee`\n" +
                "\n" +
                "All edits land in a single `bd update` invocation. Returns the updated task object.\n\n" +
                "Replaces shell: `bd update <id> --status ... --add-label ... --notes ...`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                status: z
                    .enum(['open', 'in_progress', 'blocked', 'deferred', 'closed'])
                    .optional()
                    .describe("New status. Use bd_close_task for closing — it's a separate op with reason support."),
                title: z.string().min(1).max(500).optional()
                    .describe("New title."),
                notes: z.string().max(50_000).optional()
                    .describe("Replace the notes block. Use bd_doc_write to edit doc-style content with semantics."),
                description: z.string().max(20_000).optional(),
                priority: z.enum(['0', '1', '2', '3', '4']).optional(),
                assignee: z.string().optional(),
                add_labels: z.array(z.string().min(1)).optional()
                    .describe("Labels to ADD (cumulative — keeps existing)."),
                remove_labels: z.array(z.string().min(1)).optional()
                    .describe("Labels to REMOVE."),
                set_labels: z.array(z.string().min(1)).optional()
                    .describe("Replace ALL labels. Mutually exclusive with add/remove."),
                claim: z.boolean().optional()
                    .describe("Atomically claim the issue: sets assignee=you, status=in_progress, fails if already claimed."),
                parent: z.string().optional()
                    .describe("Reparent. Pass empty string to remove parent."),
                acceptance: z.string().max(10_000).optional(),
                design: z.string().max(20_000).optional(),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Update Beads task',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);

            // Guard: set_labels conflicts with add/remove. Catch this client-side
            // for a clear error rather than letting bd's own error bubble.
            if (
                input.set_labels &&
                ((input.add_labels && input.add_labels.length > 0) ||
                    (input.remove_labels && input.remove_labels.length > 0))
            ) {
                return fail(
                    new BdError(
                        "set_labels conflicts with add_labels / remove_labels",
                        {
                            hint:
                                "Either pass set_labels[] to replace ALL labels, OR pass add_labels[]/remove_labels[] to make incremental changes.",
                        },
                    ),
                );
            }

            const args = ['update', tid, '--json'];
            if (input.status) args.push('-s', input.status);
            if (input.title) args.push('--title', input.title);
            if (input.notes !== undefined) args.push('--notes', input.notes);
            if (input.description !== undefined) args.push('-d', input.description);
            if (input.priority !== undefined) args.push('-p', input.priority);
            if (input.assignee !== undefined) args.push('-a', input.assignee);
            if (input.parent !== undefined) args.push('--parent', input.parent);
            if (input.acceptance !== undefined) args.push('--acceptance', input.acceptance);
            if (input.design !== undefined) args.push('--design', input.design);
            if (input.claim) args.push('--claim');
            if (input.add_labels) {
                for (const l of input.add_labels) args.push('--add-label', l);
            }
            if (input.remove_labels) {
                for (const l of input.remove_labels) args.push('--remove-label', l);
            }
            if (input.set_labels) {
                for (const l of input.set_labels) args.push('--set-labels', l);
            }

            // bd update with --json returns the updated issue.
            const updated = await runBdJson(args, {
                cwd: input.cwd,
                hintOnError:
                    "Common causes: invalid task_id (run bd_show_task to verify it exists), " +
                    "stale data (Beads may need `bd doctor`), or trying to claim an already-claimed task. " +
                    HINT_LIST_TO_FIND_IDS,
            });
            const task = normalizeShowResult(updated);
            const labels = task ? (task.labels || []).join(',') || '(none)' : '?';
            return ok(
                `Updated ${tid} (status=${task?.status ?? '?'}, labels=[${labels}])`,
                task ?? updated,
                input.claim
                    ? "Atomic claim succeeded — task is now yours and in_progress."
                    : null,
            );
        }),
    );

    server.registerTool(
        'bd_close_task',
        {
            title: 'Close one or more Beads tasks',
            description:
                "Close a task (or multiple tasks). Sets status=closed and records an optional reason. " +
                "Closure is REVERSIBLE via bd reopen (not exposed here as a tool — uncommon and easy " +
                "to do by hand if needed) but state change is real: dependent tasks may unblock.\n\n" +
                "Replaces shell: `bd close <id1> [id2...] -r '<reason>'`",
            inputSchema: {
                task_ids: z.array(z.string().min(1).max(256)).min(1)
                    .describe("One or more issue ids to close."),
                reason: z.string().max(2000).optional()
                    .describe("Reason for closing. Surfaces in audit trail."),
                suggest_next: z.boolean().optional()
                    .describe("Also include newly-unblocked tasks in the result. Default: false."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Close Beads tasks',
                readOnlyHint: false,
                destructiveHint: true,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const ids = input.task_ids.map((t) => validateTaskId(t));
            const args = ['close', ...ids];
            if (input.reason) args.push('-r', input.reason);
            if (input.suggest_next) args.push('--suggest-next');
            args.push('--json');

            const result = await runBd(args, {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            // bd close --json may emit either the closed issues or a status
            // object. We surface the raw text back to the LLM along with a
            // headline, since the shape varies by bd version.
            let parsed = null;
            try {
                parsed = JSON.parse(result.stdout.trim() || 'null');
            } catch {
                parsed = { raw_stdout: result.stdout };
            }
            return ok(
                `Closed ${ids.length} task(s): ${ids.join(', ')}`,
                parsed,
                input.reason ? `reason: ${input.reason}` : null,
            );
        }),
    );
}
