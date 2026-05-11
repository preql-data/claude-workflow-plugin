// bd_doc.js — task-attached document storage (J4 from the v3 plan).
//
// Concept
// -------
// Specialists need to attach long-form context (a SPEC, an architecture
// brief, a QA test plan) to a Beads task so that downstream agents reading
// the task in a later session pick up the same context without the
// orchestrator having to re-paste it. We surface that as two MCP tools:
//
//   bd_doc_write(task_id, name, content) — upsert a named doc on a task.
//   bd_doc_read(task_id, name?)          — read a named doc (or all docs).
//
// Storage layout
// --------------
// Two layers, in order of precedence:
//
//   1. The task's `notes` field. If `name` is "main" or omitted, write/read
//      goes straight to/from `notes`. This is the canonical primary doc and
//      is exactly what the bash hooks use today (`bd update --notes ...`).
//
//   2. Named docs (anything other than "main") live as comments on the task
//      with a sentinel header so we can find them deterministically:
//
//          <!-- BD-MCP-DOC: <name> v<n> -->
//          <markdown body...>
//
//      To update a named doc, we ADD a NEW comment with v<n+1>; we never
//      mutate prior comments (Beads comments are append-only). bd_doc_read
//      returns the latest version.
//
// Why this design
// ---------------
//   - Beads notes is single-slot — fine for the SPEC/main doc but useless
//     for multi-doc workflows.
//   - Beads comments are append-only — perfect audit-friendly, version-
//     friendly storage. Versioned headers make "latest" lookup deterministic.
//   - No new database schema. Everything is layered on top of bd's existing
//     primitives. Phase 6b can migrate to a richer convention without
//     breaking docs already written via Phase 6a.

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

// ---------------------------------------------------------------------------
// Helpers

const DOC_HEADER_RE = /<!--\s*BD-MCP-DOC:\s*([A-Za-z0-9._-]+)\s*v(\d+)\s*-->/;

/**
 * Validate a doc name: lowercase-ish identifier, max 64 chars. We disallow
 * spaces and special chars so the sentinel marker stays parseable.
 */
function validateDocName(raw) {
    if (typeof raw !== 'string') {
        throw new BdError("name must be a string", {
            hint: "Use a short identifier like 'spec', 'qa-plan', 'arch'.",
        });
    }
    const t = raw.trim();
    if (t.length === 0 || t.length > 64) {
        throw new BdError("name has invalid length", {
            hint: "1-64 characters; lowercase identifier-like.",
        });
    }
    if (!/^[A-Za-z0-9][A-Za-z0-9._-]*$/.test(t)) {
        throw new BdError("name has invalid characters", {
            hint: "Allowed: letters, digits, '.', '_', '-'. Examples: 'spec', 'qa-plan'.",
        });
    }
    return t;
}

/**
 * Find all comments that look like named docs, parse their headers, and
 * return them indexed by name with the latest version per name.
 */
function indexDocsFromComments(comments) {
    const out = new Map();
    for (const c of comments || []) {
        const text = c.text || c.body || '';
        const match = DOC_HEADER_RE.exec(text);
        if (!match) continue;
        const [, name, versionStr] = match;
        const version = parseInt(versionStr, 10);
        if (!Number.isFinite(version)) continue;
        // Strip the header line(s) for the body — everything after the FIRST
        // closing `-->` is the doc content.
        const headerEnd = text.indexOf('-->') + 3;
        const body = text.slice(headerEnd).replace(/^\s*\n/, '');
        const existing = out.get(name);
        if (!existing || existing.version < version) {
            out.set(name, {
                name,
                version,
                content: body,
                comment_id: c.id,
                created_at: c.created_at,
                author: c.author,
            });
        }
    }
    return out;
}

export function registerDocTools(server) {
    server.registerTool(
        'bd_doc_write',
        {
            title: 'Write a document attached to a Beads task',
            description:
                "Upsert a named markdown document on a task. Two storage modes:\n" +
                "  - name='main' (or omitted): writes directly to the task's notes field, replacing it.\n" +
                "  - any other name: appends a versioned comment with a parseable sentinel header.\n" +
                "\n" +
                "The orchestrator typically writes name='spec' before delegating to a specialist. The " +
                "specialist reads it via bd_doc_read(task_id, 'spec'). QA writes name='qa-plan'.\n" +
                "\n" +
                "Named docs are append-only on the Beads side: each write creates a new comment with " +
                "version=latest+1. bd_doc_read returns the latest by default.",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                name: z.string().min(1).max(64).optional()
                    .describe("Doc name. 'main' (or omitted) uses the notes field; anything else uses comments."),
                content: z.string().max(200_000)
                    .describe("Doc body (Markdown). Pass empty string to clear (notes only — comments cannot be erased)."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Write task doc',
                readOnlyHint: false,
                destructiveHint: false,
                idempotentHint: false,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);
            const name = input.name ? validateDocName(input.name) : 'main';

            if (name === 'main') {
                // Writes to the notes field via `bd update --notes`. Idempotent
                // up to the content matching what's already there.
                await runBdJson(['update', tid, '--notes', input.content, '--json'], {
                    cwd: input.cwd,
                    hintOnError: HINT_LIST_TO_FIND_IDS,
                });
                return ok(
                    `Wrote doc 'main' to ${tid} (${input.content.length} chars)`,
                    { task_id: tid, name, length: input.content.length, storage: 'notes' },
                    "main doc lives in the notes field — replace-on-write.",
                );
            }

            // Named doc: figure out the next version, then append a comment
            // with the sentinel header.
            const showRaw = await runBdJson(['show', tid, '--json'], {
                cwd: input.cwd,
                hintOnError: HINT_LIST_TO_FIND_IDS,
            });
            const task = normalizeShowResult(showRaw);
            if (!task) {
                return fail(
                    new BdError(`Task '${tid}' not found`, { hint: HINT_LIST_TO_FIND_IDS }),
                );
            }
            const existing = indexDocsFromComments(task.comments || []);
            const prev = existing.get(name);
            const nextVersion = prev ? prev.version + 1 : 1;

            const body = `<!-- BD-MCP-DOC: ${name} v${nextVersion} -->\n${input.content}`;
            // Use plural 'comments add' first; fall back to 'comment add'.
            try {
                await runBd(['comments', 'add', tid, body], { cwd: input.cwd });
            } catch (errFirst) {
                try {
                    await runBd(['comment', 'add', tid, body], { cwd: input.cwd });
                } catch (errSecond) {
                    return fail(
                        new BdError(
                            `Failed to add doc comment for '${name}'`,
                            {
                                stderr: errFirst instanceof BdError ? errFirst.stderr : '',
                                hint:
                                    "Both `bd comments add` and `bd comment add` failed. " +
                                    HINT_LIST_TO_FIND_IDS,
                            },
                        ),
                    );
                }
            }
            return ok(
                `Wrote doc '${name}' v${nextVersion} to ${tid} (${input.content.length} chars)`,
                {
                    task_id: tid,
                    name,
                    version: nextVersion,
                    length: input.content.length,
                    storage: 'comment',
                },
                prev
                    ? `Replaced version ${prev.version}; previous version remains in comment history (${prev.comment_id ?? 'id unknown'}).`
                    : "First version of this doc.",
            );
        }),
    );

    server.registerTool(
        'bd_doc_read',
        {
            title: 'Read a document attached to a Beads task',
            description:
                "Read a named markdown doc from a task. Three modes:\n" +
                "  - name='main' (or omitted): returns the notes field.\n" +
                "  - name=<other>: returns the latest version of that named doc (from comments).\n" +
                "  - list_only=true: returns metadata for ALL docs on the task (names + versions), no content.\n" +
                "\n" +
                "Specialists call this at the top of their work to load the SPEC/brief written by the " +
                "orchestrator, before doing anything else.",
            inputSchema: {
                task_id: z.string().min(1).max(256),
                name: z.string().min(1).max(64).optional()
                    .describe("Doc name. Defaults to 'main' (notes field)."),
                version: z.number().int().min(1).optional()
                    .describe(
                        "For named docs: read a specific historical version. Default: latest. " +
                        "Ignored for name='main' (notes has no versioning).",
                    ),
                list_only: z.boolean().optional()
                    .describe("If true, return only doc metadata (names, versions, sizes) without content."),
                cwd: z.string().optional(),
            },
            annotations: {
                title: 'Read task doc',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const tid = validateTaskId(input.task_id);

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

            const named = indexDocsFromComments(task.comments || []);
            const mainContent = task.notes || '';

            if (input.list_only) {
                const meta = [
                    ...(mainContent
                        ? [{ name: 'main', length: mainContent.length, storage: 'notes' }]
                        : []),
                    ...Array.from(named.values()).map((d) => ({
                        name: d.name,
                        version: d.version,
                        length: d.content.length,
                        storage: 'comment',
                        created_at: d.created_at,
                    })),
                ];
                return ok(
                    `bd_doc_read ${tid}: ${meta.length} doc(s) attached`,
                    { task_id: tid, docs: meta },
                    null,
                );
            }

            const name = input.name ? validateDocName(input.name) : 'main';

            if (name === 'main') {
                if (!mainContent) {
                    return fail(
                        new BdError(`No 'main' doc on ${tid} (notes is empty)`, {
                            hint:
                                "Write one with bd_doc_write(task_id, content=...). " +
                                "Use list_only=true to see what other docs are attached.",
                        }),
                    );
                }
                return ok(
                    `bd_doc_read ${tid}/main: ${mainContent.length} chars`,
                    {
                        task_id: tid,
                        name: 'main',
                        version: null,
                        storage: 'notes',
                        content: mainContent,
                    },
                    null,
                );
            }

            // Named doc.
            if (input.version !== undefined) {
                // Need to find the matching version from history. We have all
                // versions in the comments list — re-scan instead of using the
                // index map (which only kept the latest).
                let chosen = null;
                for (const c of task.comments || []) {
                    const text = c.text || c.body || '';
                    const m = DOC_HEADER_RE.exec(text);
                    if (!m) continue;
                    if (m[1] !== name) continue;
                    if (parseInt(m[2], 10) !== input.version) continue;
                    const headerEnd = text.indexOf('-->') + 3;
                    chosen = {
                        name,
                        version: input.version,
                        content: text.slice(headerEnd).replace(/^\s*\n/, ''),
                        comment_id: c.id,
                        created_at: c.created_at,
                    };
                    break;
                }
                if (!chosen) {
                    return fail(
                        new BdError(
                            `Doc '${name}' v${input.version} not found on ${tid}`,
                            {
                                hint:
                                    "Use bd_doc_read(task_id, list_only=true) to see available docs and versions.",
                            },
                        ),
                    );
                }
                return ok(
                    `bd_doc_read ${tid}/${name} v${chosen.version}: ${chosen.content.length} chars`,
                    {
                        task_id: tid,
                        name: chosen.name,
                        version: chosen.version,
                        storage: 'comment',
                        content: chosen.content,
                    },
                    null,
                );
            }

            const latest = named.get(name);
            if (!latest) {
                return fail(
                    new BdError(`Doc '${name}' not found on ${tid}`, {
                        hint:
                            "Use bd_doc_read(task_id, list_only=true) to see what docs ARE attached, " +
                            "or bd_doc_write(task_id, name='" + name + "', content=...) to create it.",
                    }),
                );
            }
            return ok(
                `bd_doc_read ${tid}/${name} v${latest.version}: ${latest.content.length} chars`,
                {
                    task_id: tid,
                    name: latest.name,
                    version: latest.version,
                    storage: 'comment',
                    content: latest.content,
                },
                null,
            );
        }),
    );
}
