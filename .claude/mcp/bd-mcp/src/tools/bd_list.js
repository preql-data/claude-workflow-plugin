// bd_list.js — list/show/ready/blocked tools.
//
// All read-only. They each shell out to `bd <subcommand> --json` and return
// the parsed array/object plus a small headline.
//
// One agent-centric design choice: bd_list_tasks accepts label_any[] and
// label_all[] separately. Beads' `--label` is AND-style; `--label-any` is
// OR-style. Surfacing both lets the LLM ask "any of these labels" without
// having to compose multiple calls.

import { z } from 'zod';
import {
    runBdJson,
    BdError,
    validateTaskId,
    HINT_LIST_TO_FIND_IDS,
    normalizeShowResult,
} from '../lib/exec-bd.js';
import { ok, fail, safe } from '../lib/format.js';

export function registerListTools(server) {
    server.registerTool(
        'bd_list_tasks',
        {
            title: 'List Beads tasks (filtered)',
            description:
                "List Beads issues filtered by status, labels, parent, type, etc. Returns an array of issue " +
                "objects (id, title, status, priority, labels, etc.).\n\n" +
                "Supports two label modes:\n" +
                "  - labels_all[]: must have ALL of these labels (AND)\n" +
                "  - labels_any[]: must have AT LEAST ONE of these labels (OR)\n" +
                "Combine both freely.\n\n" +
                "By default, closed issues are excluded. Pass include_closed=true to include them. " +
                "limit defaults to 50; pass 0 for unlimited.\n\n" +
                "Replaces shell: `bd list --status <s> -l <labels> --json | jq`",
            inputSchema: {
                status: z
                    .enum(['open', 'in_progress', 'blocked', 'deferred', 'closed'])
                    .optional()
                    .describe("Filter to a single status. Omit to include all (subject to include_closed)."),
                labels_all: z.array(z.string().min(1)).optional()
                    .describe("Must have ALL of these labels (AND filter)."),
                labels_any: z.array(z.string().min(1)).optional()
                    .describe("Must have AT LEAST ONE of these labels (OR filter)."),
                parent: z.string().optional()
                    .describe("Filter to children of this parent issue id."),
                type: z
                    .enum(['bug', 'feature', 'task', 'epic', 'chore', 'merge-request', 'molecule', 'gate'])
                    .optional()
                    .describe("Filter by issue type."),
                assignee: z.string().optional()
                    .describe("Filter by assignee (string match)."),
                title_contains: z.string().min(1).max(200).optional()
                    .describe("Case-insensitive substring match on title."),
                priority_max: z.enum(['0', '1', '2', '3', '4']).optional()
                    .describe("Maximum priority (inclusive). Useful with --priority-min for ranges."),
                priority_min: z.enum(['0', '1', '2', '3', '4']).optional()
                    .describe("Minimum priority (inclusive)."),
                limit: z.number().int().min(0).max(500).optional()
                    .describe("Max results (0 = unlimited up to bd's cap). Defaults to 50."),
                include_closed: z.boolean().optional()
                    .describe("Include closed issues in the result. Default: false (closed are excluded)."),
                cwd: z.string().optional()
                    .describe("Override working directory (BD_CWD)."),
            },
            annotations: {
                title: 'List Beads tasks',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const args = ['list', '--json'];
            if (input.status) args.push('--status', input.status);
            if (input.labels_all && input.labels_all.length > 0) args.push('-l', input.labels_all.join(','));
            if (input.labels_any && input.labels_any.length > 0) args.push('--label-any', input.labels_any.join(','));
            if (input.parent) args.push('--parent', validateTaskId(input.parent, 'parent'));
            if (input.type) args.push('-t', input.type);
            if (input.assignee) args.push('-a', input.assignee);
            if (input.title_contains) args.push('--title-contains', input.title_contains);
            if (input.priority_max !== undefined) args.push('--priority-max', input.priority_max);
            if (input.priority_min !== undefined) args.push('--priority-min', input.priority_min);
            if (input.limit !== undefined) args.push('-n', String(input.limit));
            if (input.include_closed) args.push('--all');

            const list = await runBdJson(args, { cwd: input.cwd });
            const arr = Array.isArray(list) ? list : list ? [list] : [];
            const obs =
                arr.length === 0
                    ? "No tasks match. If you expected results, double-check label spelling and consider include_closed=true."
                    : arr.length >= (input.limit ?? 50)
                        ? `Returned ${arr.length} tasks; this may be truncated. Re-call with limit=0 for unlimited or narrow filters.`
                        : `Returned ${arr.length} tasks.`;
            return ok(`bd_list_tasks: ${arr.length} match`, arr, obs);
        }),
    );

    server.registerTool(
        'bd_show_task',
        {
            title: 'Show a Beads task in detail',
            description:
                "Show a single task with its full state: title, status, priority, labels, assignee, " +
                "parent, dependencies, comments, notes, design, acceptance.\n\n" +
                "Use this BEFORE updating a task to read its current state, and AFTER creating/updating " +
                "to verify the change landed.\n\n" +
                "Replaces shell: `bd show <id> --json | jq`",
            inputSchema: {
                task_id: z.string().min(1).max(256)
                    .describe("Beads issue id (e.g., 'project-42' or 'project-42.3')."),
                include_refs: z.boolean().optional()
                    .describe(
                        "Advanced: pass `bd show --refs` which returns a reverse-reference MAP keyed by " +
                        "the requested id (different shape than the default object). Most callers should " +
                        "leave this false — plain show already includes `dependencies` (blockers) and " +
                        "`dependents` (reverse refs) in the returned task. Default: false.",
                    ),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Show Beads task',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            const args = ['show', tid, '--json'];
            if (input.include_refs) args.push('--refs');
            const raw = await runBdJson(args, {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            const task = normalizeShowResult(raw);
            if (!task) {
                return fail(
                    new BdError(`Task '${tid}' not found`, {
                        hint: HINT_LIST_TO_FIND_IDS,
                    }),
                );
            }
            const labels = (task.labels || []).join(',') || '(none)';
            return ok(
                `bd_show_task ${tid}: status=${task.status || '?'} labels=[${labels}]`,
                task,
                `comments: ${(task.comments || []).length}, dependencies: ${(task.dependencies || []).length}`,
            );
        }),
    );

    server.registerTool(
        'bd_get_ready',
        {
            title: 'List ready (unblocked, actionable) tasks',
            description:
                "Return tasks that are open or in_progress and have no unmet blockers — i.e., the work " +
                "the orchestrator can hand to a specialist next.\n\n" +
                "Replaces shell: `bd ready --json`",
            inputSchema: {
                assignee: z.string().optional(),
                labels_all: z.array(z.string().min(1)).optional(),
                labels_any: z.array(z.string().min(1)).optional(),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'List ready tasks',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const args = ['ready', '--json'];
            if (input.assignee) args.push('-a', input.assignee);
            if (input.labels_all && input.labels_all.length > 0) args.push('-l', input.labels_all.join(','));
            if (input.labels_any && input.labels_any.length > 0) args.push('--label-any', input.labels_any.join(','));
            const list = await runBdJson(args, { cwd: input.cwd });
            const arr = Array.isArray(list) ? list : list ? [list] : [];
            return ok(
                `bd_get_ready: ${arr.length} task(s) actionable`,
                arr,
                arr.length === 0
                    ? "No ready work. Check bd_get_blocked() for tasks waiting on dependencies."
                    : "These have no unmet blockers — pick by priority.",
            );
        }),
    );

    server.registerTool(
        'bd_get_blocked',
        {
            title: 'List blocked tasks',
            description:
                "Return tasks that are blocked by another task or marked as blocked. Useful for triaging " +
                "what's stuck and which dependencies need to be resolved first.\n\n" +
                "Replaces shell: `bd blocked --json`",
            inputSchema: {
                parent: z.string().optional()
                    .describe("Limit to descendants of this parent/epic id."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'List blocked tasks',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const args = ['blocked', '--json'];
            if (input.parent) args.push('--parent', validateTaskId(input.parent, 'parent'));
            const list = await runBdJson(args, { cwd: input.cwd });
            const arr = Array.isArray(list) ? list : list ? [list] : [];
            return ok(
                `bd_get_blocked: ${arr.length} blocked task(s)`,
                arr,
                arr.length === 0
                    ? "Nothing blocked — workflow has no waiting work."
                    : "Use bd_show_task on any to see what's blocking each.",
            );
        }),
    );
}
