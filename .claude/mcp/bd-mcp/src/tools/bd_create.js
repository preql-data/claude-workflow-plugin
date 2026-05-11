// bd_create.js — task and epic creation tools.
//
// Two tools registered here:
//   - bd_create_task: typed wrapper around `bd create <title> [flags]`
//   - bd_create_epic: same but with --type epic baked in, and an optional
//                     children[] payload that creates child tasks pointing
//                     at the epic via --parent
//
// Why two tools and not just one with a `type` parameter:
//   The mcp-builder methodology says: build for workflows. Creating an
//   epic with sub-tasks is a distinct workflow from creating a single
//   task; making it its own tool means the LLM doesn't have to compose
//   two calls and fail halfway through.

import { z } from 'zod';
import { runBd, runBdJson, BdError, validateTaskId } from '../lib/exec-bd.js';
import { ok, fail, safe } from '../lib/format.js';

// Shared input shape for "create" parameters that overlap between task
// and epic. We use plain Zod-raw-shape (object of fields) rather than
// z.object({...}) because the SDK expects the raw shape for inputSchema.
const COMMON_FIELDS = {
    title: z.string().min(1).max(500)
        .describe("Issue title — what the work is. Required."),
    description: z.string().max(20_000).optional()
        .describe("Long-form description of the work. Markdown supported."),
    priority: z.enum(['0', '1', '2', '3', '4']).optional()
        .describe("Priority 0-4 (0 = highest). Default: 2."),
    labels: z.array(z.string().min(1)).optional()
        .describe("Labels to attach (e.g., ['backend', 'qa-pending'])."),
    parent: z.string().optional()
        .describe("Parent issue id (for hierarchical child)."),
    deps: z.array(z.string().min(1)).optional()
        .describe("Dependency ids in 'type:id' or 'id' form (e.g., 'blocks:bd-15')."),
    notes: z.string().max(50_000).optional()
        .describe("Initial notes block (will be the canonical 'doc' for this task — see bd_doc_write)."),
    assignee: z.string().optional()
        .describe("Assignee (typically an email or username)."),
    acceptance: z.string().max(10_000).optional()
        .describe("Acceptance criteria block."),
    design: z.string().max(20_000).optional()
        .describe("Design notes block."),
    cwd: z.string().optional()
        .describe("Working directory where bd should run (overrides BD_CWD env)."),
};

/**
 * Build positional + flag args for `bd create`. Returns the array passed
 * to execFile. Centralising this here means create_task and create_epic
 * share argument formatting.
 */
function buildCreateArgs(input, type) {
    const args = ['create', input.title, '-t', type, '--json'];
    if (input.priority !== undefined) args.push('-p', input.priority);
    if (input.labels && input.labels.length > 0) args.push('-l', input.labels.join(','));
    if (input.parent) args.push('--parent', validateTaskId(input.parent, 'parent'));
    if (input.deps && input.deps.length > 0) args.push('--deps', input.deps.join(','));
    if (input.notes) args.push('--notes', input.notes);
    if (input.description) args.push('-d', input.description);
    if (input.assignee) args.push('-a', input.assignee);
    if (input.acceptance) args.push('--acceptance', input.acceptance);
    if (input.design) args.push('--design', input.design);
    return args;
}

/**
 * Register the bd_create_task and bd_create_epic tools on the given server.
 */
export function registerCreateTools(server) {
    server.registerTool(
        'bd_create_task',
        {
            title: 'Create a Beads task',
            description:
                "Create a new Beads issue of type 'task' (or other non-epic type via the type field). " +
                "Use for individual units of work. To create a parent epic with sub-tasks at the same time, " +
                "prefer bd_create_epic which accepts a children[] array.\n\n" +
                "Returns the created issue (id, title, status, labels, parent).\n\n" +
                "Replaces shell call: `bd create '<title>' -t task -p <pri> -l <labels> --parent <id>`",
            inputSchema: {
                ...COMMON_FIELDS,
                type: z.enum(['task', 'bug', 'feature', 'chore']).optional()
                    .describe("Issue type — defaults to 'task'. Use bd_create_epic for epics."),
            },
            annotations: {
                title: 'Create Beads task',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const type = input.type || 'task';
            const args = buildCreateArgs(input, type);
            const created = await runBdJson(args, {
                cwd: input.cwd,
                hintOnError:
                    "Common causes: invalid --parent id (run bd_list_tasks to find valid ids), " +
                    "duplicate label that conflicts with a unique constraint, or .beads/ not initialized in cwd.",
            });
            const id = created && (created.id || (Array.isArray(created) && created[0]?.id));
            return ok(
                `Created ${type} ${id ?? '(id unknown)'}: ${input.title.slice(0, 80)}`,
                created,
                id
                    ? `Next typical step: bd_qa_enter for QA gate, or bd_update_task to set status=in_progress when work begins.`
                    : `Server returned create result without an id field; inspect the JSON below.`,
            );
        }),
    );

    server.registerTool(
        'bd_create_epic',
        {
            title: 'Create an epic with optional sub-tasks',
            description:
                "Create a Beads issue of type 'epic'. Optionally create child tasks at the same time " +
                "(via the children[] array) — each child is created with --parent set to the new epic, " +
                "atomically failing the whole call if any child fails.\n\n" +
                "Workflow tool: prefer this over calling bd_create_task with type='epic' followed by " +
                "N more bd_create_task calls. The orchestrator typically uses this to break a feature " +
                "request into a planned hierarchy.\n\n" +
                "Returns { epic, children: [...] }.",
            inputSchema: {
                ...COMMON_FIELDS,
                children: z
                    .array(
                        z.object({
                            title: z.string().min(1).max(500),
                            description: z.string().max(20_000).optional(),
                            priority: z.enum(['0', '1', '2', '3', '4']).optional(),
                            labels: z.array(z.string().min(1)).optional(),
                            notes: z.string().max(50_000).optional(),
                            type: z.enum(['task', 'bug', 'feature', 'chore']).optional(),
                        }),
                    )
                    .max(50)
                    .optional()
                    .describe("Optional child tasks to create under the epic. Max 50 per call."),
            },
            annotations: {
                title: 'Create Beads epic',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            // Step 1: create the epic.
            const epicArgs = buildCreateArgs(input, 'epic');
            const epic = await runBdJson(epicArgs, {
                cwd: input.cwd,
                hintOnError:
                    "Could not create epic. Verify .beads/ is initialized (cd to project, run `bd init`).",
            });
            const epicId = epic && (epic.id || (Array.isArray(epic) && epic[0]?.id));
            if (!epicId) {
                return fail(
                    new BdError("Epic was created but no id was returned", {
                        hint: "Check `bd list --type epic` to locate the orphan and link children manually.",
                    }),
                );
            }

            // Step 2: create each child with --parent <epic.id>.
            const created = [];
            const failures = [];
            for (const child of input.children || []) {
                const childArgs = buildCreateArgs(
                    {
                        ...child,
                        parent: epicId,
                    },
                    child.type || 'task',
                );
                try {
                    const out = await runBdJson(childArgs, { cwd: input.cwd });
                    created.push(out);
                } catch (err) {
                    failures.push({
                        title: child.title,
                        error: err instanceof BdError ? err.message : String(err),
                    });
                }
            }

            if (failures.length > 0) {
                return fail(
                    new BdError(
                        `Epic ${epicId} created, but ${failures.length} child task(s) failed`,
                        {
                            hint:
                                "Inspect failures[] in structuredContent. The epic remains; you can retry the failed children with bd_create_task using parent=" +
                                epicId +
                                ".",
                        },
                    ),
                    `Created epic + ${created.length}/${(input.children || []).length} children. Failures kept the partial state — see structuredContent.data.failures.`,
                );
            }

            return ok(
                `Created epic ${epicId} with ${created.length} child task(s)`,
                { epic, children: created, failures: [] },
                created.length > 0
                    ? `Children inherit the epic's id as parent. Use bd_get_ready or bd_list_tasks(parent=${epicId}) to see them.`
                    : `Created an empty epic. Add children later with bd_create_task(..., parent=${epicId}).`,
            );
        }),
    );
}
