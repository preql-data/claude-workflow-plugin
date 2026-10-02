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

// ---------------------------------------------------------------------------
// LABEL INHERITANCE (claude-workflow-plugin-rmz)
//
// THE DEFECT. bd 1.1.2 `create --parent <P>` COPIES P's labels onto the new
// issue, silently, with nothing in the response distinguishing an inherited
// label from a passed one. Measured on bd 1.1.2 in an isolated workspace:
//
//   parent  devops,qa-approved,qa-gate-entered
//   child   created with `-l bug,frontend --parent <P>`
//        -> bug,devops,frontend,qa-approved,qa-gate-entered
//
// So a brand-new, never-reviewed task is born carrying the gate's own labels,
// and the inheritance is TRANSITIVE — a grandchild under that child gets them
// too, contaminating a whole decomposition subtree from one approved ancestor.
//
// WHY IT MATTERS EVEN THOUGH THE STOP GATE HOLDS. verify-before-stop.sh
// requires a change-set-BOUND approval record, not a bare label, so a task born
// approved cannot release (it emits LABEL_WITHOUT_RECORD instead). The damage is
// upstream of the release predicate: `bd list --label qa-approved` reports
// unreviewed work as approved, session-start's anomaly guard fires on work
// nobody approved, and a task born with `qa-gate-entered` can NEVER acquire the
// paired cycle record — cmd_enter returns early when the label is already
// present, so the one call that would write the record declines to.
//
// TWO LAYERS, and they are deliberately independent:
//
//   PREVENTION  `--no-inherit-labels` whenever --parent is passed. Atomic (the
//               label never exists), needs no list of which labels are
//               dangerous, and so cannot go stale when a new gate label is
//               added. MEASURED: with the flag the child carries EXACTLY the
//               passed labels; without --parent the flag is a harmless no-op,
//               and it is still scoped to parented creates so a bd too old to
//               know the flag keeps working for every other create.
//   DETECTION   compare the labels bd ECHOES BACK against the labels asked for.
//               Free — `bd create --json` already returns the created issue's
//               labels — and it is the layer that survives the prevention
//               failing: an older bd that rejects the flag, a future bd that
//               accepts and ignores it, or an explicit inherit_labels=true.
//
// The detection layer is the general form of the rule this whole defect family
// violates: DO NOT REPORT A RESULT YOU DID NOT CHECK. rmz was found precisely
// because a human read the echo instead of assuming the input was the output;
// this makes that check mechanical.
const NO_INHERIT_FLAG = '--no-inherit-labels';

/**
 * Labels that assert something about REVIEW STATE — i.e. that a measurement
 * happened. Never legitimately inherited: no caller has a use for a fresh task
 * being born approved, blocked, mid-cycle or pre-graded.
 *
 * Domain labels (backend / frontend / devops) are deliberately NOT here.
 * Inheriting those from an epic is useful and is presumably why bd inherits at
 * all, so under an explicit inherit_labels=true they ride along untouched.
 *
 * MIRRORS qa-gate.sh's QA_CYCLE_LABELS, plus `rubric-satisfied` — which that
 * shell set deliberately EXCLUDES for an unrelated reason (it is the audit
 * trail of the grader verdict, so the terminal-label sweep must not destroy
 * it). Being un-sweepable does not make it inheritable: a child born
 * rubric-satisfied is pre-graded against a change set it has no relationship
 * to. The two lists are bound by a test rather than by this comment.
 */
export const WORKFLOW_GATE_LABELS = [
    'qa-approved',
    'qa-blocked',
    'qa-gate-entered',
    'qa-pending',
    'qa-escalated',
    'qa-deferred',
    'rubric-pending',
    'rubric-satisfied',
];

const GATE_LABEL_SET = new Set(WORKFLOW_GATE_LABELS);

function isGateLabel(label) {
    return GATE_LABEL_SET.has(String(label || '').trim().toLowerCase());
}

/**
 * Pull the labels bd echoed back off a create response, tolerating both the
 * object and 1-element-array shapes and the key being ABSENT (measured: bd
 * 1.1.2 omits `labels` entirely when an issue has none, rather than emitting
 * an empty array).
 */
function echoedLabels(created) {
    const obj = Array.isArray(created) ? created[0] : created;
    const raw = obj && obj.labels;
    return Array.isArray(raw) ? raw.map((l) => String(l)) : [];
}

function createdId(created) {
    const obj = Array.isArray(created) ? created[0] : created;
    return (obj && obj.id) || null;
}

/**
 * `bd create` with the inheritance suppression, falling back to a create
 * WITHOUT the flag if the installed bd does not know it.
 *
 * Pin the chain, not the leg — the same shape runBdShowJson uses for
 * `--include-comments`. The fallback is only safe because auditCreatedLabels()
 * runs afterwards either way: dropping the flag degrades to "detect and strip"
 * rather than to "inherit silently". Any error that is NOT an unknown-flag
 * rejection propagates untouched, so a real failure is never masked by a
 * second attempt.
 *
 * @returns {Promise<{created: any, suppressed: boolean}>}
 */
async function runCreate(args, opts) {
    const wanted = args.includes(NO_INHERIT_FLAG);
    try {
        return { created: await runBdJson(args, opts), suppressed: wanted };
    } catch (err) {
        if (
            wanted &&
            err instanceof BdError &&
            /unknown flag|unknown shorthand|flag provided but not defined/i.test(err.stderr || '')
        ) {
            const without = args.filter((a) => a !== NO_INHERIT_FLAG);
            return { created: await runBdJson(without, opts), suppressed: false };
        }
        throw err;
    }
}

/**
 * Compare what bd actually put on the new issue against what the caller asked
 * for, and remove what arrived unrequested.
 *
 * HOW MUCH IT REMOVES depends on what the caller asked for, and the two cases
 * are deliberately different:
 *
 *   allowInherited=false (the DEFAULT)  strip EVERY unrequested label. The
 *       tool's stated contract is "labels are exactly what you pass", and this
 *       is the layer that keeps that true when the prevention layer is
 *       degraded — an older bd that rejects --no-inherit-labels, or a future
 *       one that accepts and ignores it. Leaving an inherited DOMAIN label
 *       behind in that case would make the contract quietly version-dependent,
 *       which is a smaller version of the same defect: a promise nothing checks.
 *   allowInherited=true                 strip only the WORKFLOW-GATE labels.
 *       The caller asked for the parent's labels and gets them; what no caller
 *       can ask for is a fresh task that claims to have been reviewed.
 *
 * Only a GATE label that could not be removed is a hard failure (`leaked`). A
 * stuck domain label is untidy, not unsafe, so it is reported in `residual` and
 * the call still succeeds.
 *
 * Never throws — the issue exists by this point, and failing the whole call
 * would leave the caller unable to tell that it was created (same reasoning as
 * applyDeps).
 *
 * @returns {Promise<{unrequested: string[], stripped: string[], leaked: string[],
 *                    residual: string[], kept: string[], note: string}>}
 */
async function auditCreatedLabels(created, requestedLabels, opts, { allowInherited = false } = {}) {
    const id = createdId(created);
    const actual = echoedLabels(created);
    const requested = new Set(
        (requestedLabels || []).map((l) => String(l).trim()).filter(Boolean),
    );
    const unrequested = actual.filter((l) => !requested.has(String(l).trim()));
    const toStrip = allowInherited ? unrequested.filter(isGateLabel) : unrequested;
    const kept = allowInherited ? unrequested.filter((l) => !isGateLabel(l)) : [];

    const stripped = [];
    const leaked = [];
    const residual = [];
    for (const label of toStrip) {
        const gate = isGateLabel(label);
        if (!id) {
            (gate ? leaked : residual).push(label);
            continue;
        }
        try {
            await runBd(['label', 'remove', id, label], opts);
            stripped.push(label);
        } catch {
            (gate ? leaked : residual).push(label);
        }
    }

    // Reflect the strip in the echoed object so the caller's payload does not
    // still advertise a label we removed a moment ago.
    if (stripped.length > 0) {
        const obj = Array.isArray(created) ? created[0] : created;
        if (obj && Array.isArray(obj.labels)) {
            obj.labels = obj.labels.filter((l) => !stripped.includes(String(l)));
        }
    }

    const strippedGate = stripped.filter(isGateLabel);
    const strippedOther = stripped.filter((l) => !isGateLabel(l));
    const parts = [];
    if (strippedGate.length > 0) {
        parts.push(
            `STRIPPED ${strippedGate.length} inherited workflow-gate label(s) from ${id}: ` +
                `${strippedGate.join(', ')}. bd copied them from the parent; they were never passed and ` +
                `assert a review that never happened (claude-workflow-plugin-rmz).`,
        );
    }
    if (strippedOther.length > 0) {
        parts.push(
            `Also removed ${strippedOther.length} unrequested inherited label(s) from ${id}: ` +
                `${strippedOther.join(', ')} — pass inherit_labels=true to keep the parent's domain labels.`,
        );
    }
    if (leaked.length > 0) {
        parts.push(
            `COULD NOT REMOVE inherited workflow-gate label(s) from ${id ?? '(id unknown)'}: ` +
                `${leaked.join(', ')}. The issue EXISTS and carries a gate label it did not earn — ` +
                `remove it by hand with \`bd label remove ${id ?? '<id>'} <label>\` before anything ` +
                `reads it. Do NOT retry the create; that would duplicate the issue.`,
        );
    }
    if (residual.length > 0) {
        parts.push(
            `Could not remove ${residual.length} unrequested non-gate label(s) from ` +
                `${id ?? '(id unknown)'}: ${residual.join(', ')}. Not a gate label, so this is untidy ` +
                `rather than unsafe.`,
        );
    }
    if (kept.length > 0) {
        parts.push(
            `Kept ${kept.length} inherited non-gate label(s) as requested (inherit_labels=true): ` +
                `${kept.join(', ')}.`,
        );
    }
    return { unrequested, stripped, leaked, residual, kept, note: parts.join(' ') };
}

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
    inherit_labels: z.boolean().optional()
        .describe(
            "Opt IN to bd's parent-label inheritance (default false). By default a child created " +
            "with `parent` carries EXACTLY the labels you pass — bd would otherwise copy the " +
            "parent's, including qa-approved / qa-gate-entered, onto a never-reviewed task. Set " +
            "true only when you want the parent's domain labels; workflow-gate labels are stripped " +
            "even then.",
        ),
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
    if (input.parent) {
        args.push('--parent', validateTaskId(input.parent, 'parent'));
        // Suppression is the DEFAULT and the flag is scoped to parented
        // creates, because that is the only shape that inherits (measured: with
        // no --parent the flag changes nothing) — so a bd too old to know it
        // still creates every un-parented issue normally. See the rmz block at
        // the top of this file for why the default is suppress-unless-asked
        // rather than inherit-unless-refused.
        if (!input.inherit_labels) args.push(NO_INHERIT_FLAG);
    }
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
                "LABELS ARE EXACTLY WHAT YOU PASS. bd copies a parent's labels onto a child by " +
                "default — including qa-approved / qa-gate-entered, which would make a never-reviewed " +
                "task look approved. This tool suppresses that, and independently verifies the labels " +
                "bd echoed back against the ones you asked for.\n\n" +
                "Replaces shell call: `bd create '<title>' -t task -p <pri> -l <labels> --parent <id> " +
                "--no-inherit-labels`",
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
            const { created, suppressed } = await runCreate(args, {
                cwd: input.cwd,
                hintOnError:
                    "Common causes: invalid --parent id (run bd_list_tasks to find valid ids), " +
                    "duplicate label that conflicts with a unique constraint, or .beads/ not initialized in cwd.",
            });
            const id = createdId(created);
            // rmz: verify the labels bd echoed back are the labels we asked for,
            // and strip any inherited gate label. Runs on EVERY create, not just
            // parented ones — the whole point is to check rather than assume.
            const audit = await auditCreatedLabels(
                created,
                input.labels,
                { cwd: input.cwd },
                { allowInherited: !!input.inherit_labels },
            );
            if (audit.leaked.length > 0) {
                return fail(
                    new BdError(
                        `Created ${type} ${id ?? '(id unknown)'}, but it carries ${audit.leaked.length} ` +
                            `unearned workflow-gate label(s) that could not be removed: ${audit.leaked.join(', ')}`,
                        {
                            hint:
                                `bd inherited them from parent '${input.parent ?? '(unknown)'}'. THE ISSUE EXISTS — ` +
                                `do not retry this call. Remove the label(s) with ` +
                                `\`bd label remove ${id ?? '<id>'} <label>\` and verify with \`bd show ${id ?? '<id>'}\`.`,
                        },
                    ),
                    audit.note,
                );
            }
            // Deps are attached AFTER creation, not via --deps. See applyDeps().
            let depNote = '';
            if (id && input.deps && input.deps.length > 0) {
                const failures = await applyDeps(id, input.deps, { cwd: input.cwd });
                depNote = failures.length
                    ? ` ${failures.length} of ${input.deps.length} dependency edge(s) could NOT be recorded: ${failures.join('; ')}.`
                    : ` ${input.deps.length} dependency edge(s) recorded via bd dep.`;
            }
            const inheritNote =
                input.parent && !input.inherit_labels && !suppressed
                    ? ` NOTE: the installed bd does not support ${NO_INHERIT_FLAG}, so parent-label ` +
                      `inheritance could not be suppressed at creation; the label audit is what ` +
                      `enforced the contract instead.`
                    : '';
            return ok(
                `Created ${type} ${id ?? '(id unknown)'}: ${input.title.slice(0, 80)}`,
                created,
                (id
                    ? `Next typical step: bd_qa_enter for QA gate, or bd_update_task to set status=in_progress when work begins.`
                    : `Server returned create result without an id field; inspect the JSON below.`) +
                    depNote +
                    inheritNote +
                    (audit.note ? ` ${audit.note}` : ''),
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
                "EACH CHILD'S LABELS ARE EXACTLY ITS OWN. bd would otherwise copy the epic's labels " +
                "onto every child; children never inherit here, and the epic's own labels are verified " +
                "against what you passed before any child is created.\n\n" +
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
            const { created: epic } = await runCreate(epicArgs, {
                cwd: input.cwd,
                hintOnError:
                    "Could not create epic. Verify .beads/ is initialized (cd to project, run `bd init`).",
            });
            const epicId = createdId(epic);
            if (!epicId) {
                return fail(
                    new BdError("Epic was created but no id was returned", {
                        hint: "Check `bd list --type epic` to locate the orphan and link children manually.",
                    }),
                );
            }
            // rmz: an epic filed UNDER a parent inherits that parent's labels
            // exactly like any other child, and then hands them to every child
            // it creates below. Audit it before the fan-out, not after.
            const epicAudit = await auditCreatedLabels(
                epic,
                input.labels,
                { cwd: input.cwd },
                { allowInherited: !!input.inherit_labels },
            );
            if (epicAudit.leaked.length > 0) {
                return fail(
                    new BdError(
                        `Epic ${epicId} was created but carries ${epicAudit.leaked.length} unearned ` +
                            `workflow-gate label(s) that could not be removed: ${epicAudit.leaked.join(', ')}. ` +
                            `NO CHILDREN WERE CREATED — they would each inherit it.`,
                        {
                            hint:
                                `THE EPIC EXISTS — do not retry this call. Remove the label(s) with ` +
                                `\`bd label remove ${epicId} <label>\`, then add the children with ` +
                                `bd_create_task(parent=${epicId}).`,
                        },
                    ),
                    epicAudit.note,
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
            //
            // rmz: children NEVER inherit, and that is deliberate even when the
            // epic itself opted in. `inherit_labels` on this call is about the
            // EPIC inheriting from ITS parent; a child's labels are exactly its
            // own `labels[]`. Spreading `input.inherit_labels` into `child` here
            // would let a `qa-pending` on the epic mint a fan-out of tasks that
            // each claim to be awaiting a review nobody requested — so the
            // omission below is load-bearing, not an oversight.
            const created = [];
            const failures = [];
            const childAuditNotes = [];
            for (const child of input.children || []) {
                const childArgs = buildCreateArgs(
                    {
                        ...child,
                        parent: epicId,
                    },
                    child.type || 'task',
                );
                try {
                    const { created: out } = await runCreate(childArgs, { cwd: input.cwd });
                    // allowInherited is NOT threaded from the epic: a child's
                    // labels are exactly its own, always. See the block above.
                    const childAudit = await auditCreatedLabels(
                        out,
                        child.labels,
                        { cwd: input.cwd },
                        { allowInherited: false },
                    );
                    if (childAudit.note) childAuditNotes.push(childAudit.note);
                    if (childAudit.leaked.length > 0) {
                        failures.push({
                            title: child.title,
                            error:
                                `created as ${createdId(out) ?? '(id unknown)'} but carries unearned ` +
                                `workflow-gate label(s) that could not be removed: ` +
                                `${childAudit.leaked.join(', ')}`,
                        });
                    }
                    created.push(out);
                } catch (err) {
                    failures.push({
                        title: child.title,
                        error: err instanceof BdError ? err.message : String(err),
                    });
                }
            }

            if (failures.length > 0) {
                // The per-child detail is spelled out IN the hint rather than
                // pointed at: fail() carries only `error` in structuredContent,
                // so the old "inspect failures[] in structuredContent" sent the
                // reader to a field that is not there — and a gate-label leak
                // reported that way would be invisible.
                const detail = failures
                    .map((f) => `  - ${f.title}: ${f.error}`)
                    .join('\n');
                return fail(
                    new BdError(
                        `Epic ${epicId} created, but ${failures.length} of ` +
                            `${(input.children || []).length} child task(s) failed`,
                        {
                            hint:
                                `Per-child failures:\n${detail}\n` +
                                `The epic and any successfully created children REMAIN — retry only the ` +
                                `failed ones with bd_create_task(parent=${epicId}).`,
                        },
                    ),
                    `Created epic + ${created.length}/${(input.children || []).length} children. ` +
                        `Failures kept the partial state.`,
                );
            }

            const epicDepNote = epicDepFailures.length
                ? ` ${epicDepFailures.length} dependency edge(s) on the epic could NOT be recorded: ${epicDepFailures.join('; ')}.`
                : '';
            const auditNote = [epicAudit.note, ...childAuditNotes].filter(Boolean).join(' ');
            return ok(
                `Created epic ${epicId} with ${created.length} child task(s)`,
                { epic, children: created, failures: [] },
                (created.length > 0
                    ? `Children are parented to the epic; each child's labels are exactly the ones it ` +
                      `specified. Use bd_get_ready or bd_list_tasks(parent=${epicId}) to see them.`
                    : `Created an empty epic. Add children later with bd_create_task(..., parent=${epicId}).`) +
                    epicDepNote +
                    (auditNote ? ` ${auditNote}` : ''),
            );
        }),
    );
}
