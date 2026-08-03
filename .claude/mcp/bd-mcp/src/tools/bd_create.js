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
    // DELIBERATELY NO `--deps` HERE. See applyDeps() below: bd 1.1.2 still
    // ACCEPTS the flag and records the edge BACKWARDS, so passing it is worse
    // than useless — it writes a wrong edge and then blocks the right one.
    if (input.notes) args.push('--notes', input.notes);
    if (input.description) args.push('-d', input.description);
    if (input.assignee) args.push('-a', input.assignee);
    if (input.acceptance) args.push('--acceptance', input.acceptance);
    if (input.design) args.push('--design', input.design);
    return args;
}

/**
 * Attach `deps` to a freshly-created issue with explicit `bd dep` calls.
 *
 * WHY THIS EXISTS (claude-workflow-plugin-fkm.1.1)
 *   `bd create --deps blocks:<id>` records the edge INVERTED on bd 1.1.2. The
 *   flag is still documented in `bd create --help` and the command still exits
 *   0, but the direction is reversed: `create B --deps blocks:A` should mean
 *   "B is blocked by A" and instead yields "A is blocked by B". Verified
 *   directly against a `bd dep add` control — B's own `.dependencies` stays
 *   empty while A acquires a dependency on B. That is silent CORRUPTION, not
 *   silent loss, and it poisons the correct call afterwards: a subsequent
 *   `bd dep add B A` is refused with "adding dependency would create a cycle".
 *
 *   Doing it explicitly is also VERSION-INDEPENDENT, which is why `--deps` is
 *   dropped from the create args entirely rather than kept as a first attempt:
 *   on bd 0.47.x the flag DOES work, so a create-then-add pair would try to
 *   record every edge twice. One path, both versions.
 *
 *   Mapping mirrors bd_dep.js exactly (`related` is bi-directional and uses
 *   `dep relate`; everything else is `dep add <dependent> <blocker>` with
 *   `--type` for non-default kinds), so the two tools cannot drift into
 *   disagreeing about what an edge kind means.
 *
 * Never throws: the issue already exists by this point, and failing the whole
 * call would leave the caller unable to tell that it was created. Returns the
 * list of human-readable failures for the tool layer to surface.
 *
 * @returns {Promise<string[]>} empty when every edge was recorded
 */
async function applyDeps(newId, deps, opts) {
    const failures = [];
    for (const raw of deps) {
        const spec = String(raw).trim();
        if (!spec) continue;
        // 'type:id' or bare 'id' (bare defaults to blocks, matching the
        // documented --deps grammar this replaces).
        const sep = spec.indexOf(':');
        const kind = sep === -1 ? 'blocks' : spec.slice(0, sep).trim();
        const other = sep === -1 ? spec : spec.slice(sep + 1).trim();
        if (!other) {
            failures.push(`'${spec}' names no issue id`);
            continue;
        }
        try {
            const blocker = validateTaskId(other, 'deps');
            if (kind === 'related' || kind === 'relates-to' || kind === 'relates_to') {
                await runBd(['dep', 'relate', blocker, newId], opts);
            } else {
                const depArgs = ['dep', 'add', newId, blocker];
                if (kind !== 'blocks') depArgs.push('--type', kind);
                await runBd(depArgs, opts);
            }
        } catch (err) {
            failures.push(`${spec}: ${err && err.message ? err.message : String(err)}`);
        }
    }
    return failures;
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
            // Deps are attached AFTER creation, not via --deps. See applyDeps().
            let depNote = '';
            if (id && input.deps && input.deps.length > 0) {
                const failures = await applyDeps(id, input.deps, { cwd: input.cwd });
                depNote = failures.length
                    ? ` ${failures.length} of ${input.deps.length} dependency edge(s) could NOT be recorded: ${failures.join('; ')}.`
                    : ` ${input.deps.length} dependency edge(s) recorded via bd dep.`;
            }
            return ok(
                `Created ${type} ${id ?? '(id unknown)'}: ${input.title.slice(0, 80)}`,
                created,
                (id
                    ? `Next typical step: bd_qa_enter for QA gate, or bd_update_task to set status=in_progress when work begins.`
                    : `Server returned create result without an id field; inspect the JSON below.`) + depNote,
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

            // Step 1b: attach the EPIC's own deps explicitly (bd 1.1.2 records
            // `bd create --deps blocks:` BACKWARDS — see applyDeps). Children
            // carry no deps of their own: the children[] schema has no deps
            // field, and their parent-child edge comes from --parent, which
            // still works.
            const epicDepFailures =
                input.deps && input.deps.length > 0
                    ? await applyDeps(epicId, input.deps, { cwd: input.cwd })
                    : [];

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

            const epicDepNote = epicDepFailures.length
                ? ` ${epicDepFailures.length} dependency edge(s) on the epic could NOT be recorded: ${epicDepFailures.join('; ')}.`
                : '';
            return ok(
                `Created epic ${epicId} with ${created.length} child task(s)`,
                { epic, children: created, failures: [] },
                (created.length > 0
                    ? `Children inherit the epic's id as parent. Use bd_get_ready or bd_list_tasks(parent=${epicId}) to see them.`
                    : `Created an empty epic. Add children later with bd_create_task(..., parent=${epicId}).`) + epicDepNote,
            );
        }),
    );
}
