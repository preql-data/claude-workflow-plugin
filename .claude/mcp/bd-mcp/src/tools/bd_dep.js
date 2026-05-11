// bd_dep.js — dependency add/list tools.
//
// Beads' dependency model:
//   - blocks: A blocks B (B can't start until A closes)
//   - parent-child: hierarchical parent/child link
//   - related: bi-directional weak link
//   - discovered-from: A was discovered while working on B
//
// `bd dep add <child> <parent>` says "<child> depends on <parent>" — i.e.,
// child is BLOCKED BY parent. The agent-facing wording in our tool flips
// this to be unambiguous: blocker = the thing that must finish first;
// dependent = the thing that's waiting.

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

export function registerDepTools(server) {
    server.registerTool(
        'bd_add_dep',
        {
            title: 'Add a dependency between two Beads tasks',
            description:
                "Add a dependency edge. Default kind is 'blocks' — the blocker must close before the " +
                "dependent can be marked ready.\n\n" +
                "Wording is explicit:\n" +
                "  blocker: id of the task that must complete first.\n" +
                "  dependent: id of the task that's waiting.\n" +
                "\n" +
                "Equivalent shell: `bd dep add <dependent> <blocker>` for blocks,\n" +
                "                  `bd dep relate <a> <b>` for relates_to.\n",
            inputSchema: {
                blocker: z.string().min(1).max(256)
                    .describe("Task that must complete first."),
                dependent: z.string().min(1).max(256)
                    .describe("Task that's waiting on the blocker."),
                kind: z
                    .enum(['blocks', 'related', 'discovered-from', 'parent-child'])
                    .optional()
                    .describe(
                        "Edge kind. Default 'blocks'. 'related' is bi-directional. " +
                        "'parent-child' is typically set via bd_create_task(parent=...) instead.",
                    ),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Add dependency',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const blocker = validateTaskId(input.blocker, 'blocker');
            const dependent = validateTaskId(input.dependent, 'dependent');
            const kind = input.kind || 'blocks';

            if (kind === 'related') {
                // `bd dep relate <a> <b>` is the bi-directional form.
                await runBd(['dep', 'relate', blocker, dependent], {
                    cwd: input.cwd,
                    hintOnError: HINT_LIST_TO_FIND_IDS,
                });
                return ok(
                    `Added relates_to between ${blocker} and ${dependent}`,
                    { a: blocker, b: dependent, kind },
                    "relates_to is bi-directional — both tasks now reference each other.",
                );
            }

            // For blocks / discovered-from: `bd dep add <dependent> <blocker>`.
            // bd's CLI takes [issue-id] [dependency-id]; the second arg is what
            // the first one depends on. We pass --type for non-default kinds.
            const args = ['dep', 'add', dependent, blocker];
            if (kind !== 'blocks') {
                args.push('--type', kind);
            }
            await runBd(args, {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            return ok(
                `Added '${kind}' dep: ${dependent} ← ${blocker}`,
                { blocker, dependent, kind },
                kind === 'blocks'
                    ? `${dependent} is now blocked by ${blocker}. Use bd_get_blocked to verify.`
                    : null,
            );
        }),
    );

    server.registerTool(
        'bd_list_deps',
        {
            title: 'List dependencies of a task',
            description:
                "Show the dependencies attached to a task. By default returns both blockers (what " +
                "this task depends on) and dependents (what depends on this task), parsed from " +
                "`bd show --json`.\n\n" +
                "Replaces shell: `bd dep list <id>` / `bd show <id> --json | jq '.dependencies'`",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'List dependencies',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            // bd's `--refs --json` returns a different shape (a reverse-ref
            // map keyed by id), but plain `bd show --json` already includes
            // both `dependencies[]` (blockers) AND `dependents[]` (reverse
            // refs) in its output. So we use plain show — simpler and
            // consistent with how every other tool reads task state.
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
            const deps = task.dependencies || [];
            const dependents = task.dependents || [];
            return ok(
                `bd_list_deps ${tid}: ${deps.length} blocker(s), ${dependents.length} dependent(s)`,
                { task_id: tid, dependencies: deps, dependents },
                deps.length === 0 && dependents.length === 0
                    ? "No dependency edges. Task has no blockers and nothing waits on it."
                    : null,
            );
        }),
    );
}
