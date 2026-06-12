// dead_code.js — `dead_code({scope?, cwd?})`.
//
// Lists unreferenced exports within the scope. An "export" is a row
// where symbols.is_export = 1 (the indexer set this when the
// definition node was wrapped in an export_statement-like construct).
// An export is "dead" when no edge points at it: no incoming call
// edge with dst_symbol_id matching AND no edge whose dst_name matches
// AND no import line referencing the file from another file's
// imports.
//
// Output:
//   {
//     scope,
//     dead: [
//       { name, kind, file, line, lang, reason }
//     ],
//     scanned_exports,
//     limitations: string
//   }
//
// **Critical caveats** (echoed in the tool description AND README):
//
//   - Re-exports (`export { foo } from './bar'`) are NOT tracked as
//     additional uses; we may flag the original definition as dead
//     even though it is reachable via the re-export.
//   - Reflection / metaprogramming targets are invisible; symbols
//     used only via `Reflect.apply`, `__getattr__`, `method_missing`,
//     etc. will appear dead.
//   - Externally-consumed exports (a public package surface someone
//     OUTSIDE this repo depends on) appear dead.
//   - Imports whose resolved_file_id remained NULL are treated as
//     unresolved — for the purposes of dead_code we DO conservatively
//     credit the imported file with use, so exports of `foo.ts` count
//     as referenced when any file imports from `'./foo'` even if the
//     resolver couldn't pin the candidate.
//
// In short: dead_code is a STARTING POINT for cleanup, not a proof.
// Use it to find candidates; verify each one manually before deleting.

import { z } from 'zod';
import { ensureIndex } from '../lib/indexer.js';
import { openDb } from '../lib/db.js';
import { ok, safe } from '../lib/format.js';
import { validateScopePath } from '../lib/validate.js';

const LIMITATIONS_NOTE =
    'Limits: re-exports are not tracked as uses; reflection / metaprogramming / dynamic dispatch are invisible; externally-consumed exports look dead. Treat results as candidates, not proofs.';

export function registerDeadCodeTool(server) {
    server.registerTool(
        'dead_code',
        {
            title: 'Unreferenced exports within a scope',
            description:
                "List exported symbols within the given scope that have no recorded uses (no incoming call " +
                "edges, no name-only edges, no file-level imports from other files). Scope is a path prefix " +
                "(e.g. 'src/', 'server/lib/'); pass '' or omit it to scan the whole project.\n\n" +
                "**This is a high-recall starting point for cleanup, not a proof.** False positives are " +
                "common: re-exports across barrel files, reflection, dynamic dispatch, and externally-" +
                "consumed exports all look dead. Verify each candidate manually before deleting.\n\n" +
                "Output includes a `reason` string per dead candidate (which check fired) and a global " +
                "`limitations` paragraph repeating these caveats for downstream LLMs.",
            inputSchema: {
                scope: z.string().max(1024).optional()
                    .describe("Project-relative path prefix scoping the search. Empty / omitted = whole project."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Dead-code scan',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const scope = validateScopePath(input.scope);

            await ensureIndex({ cwd: input.cwd });
            const db = await openDb({ cwd: input.cwd });
            try {
                // 1. Collect all exports in scope.
                let exportsRows;
                if (scope) {
                    exportsRows = db.all(
                        `SELECT symbols.id, symbols.name, symbols.kind, symbols.line,
                                symbols.is_export, files.id AS file_id, files.path AS file, files.lang
                         FROM symbols
                         JOIN files ON files.id = symbols.file_id
                         WHERE symbols.is_export = 1 AND files.path LIKE ?
                         ORDER BY files.path, symbols.line`,
                        [`${scope}%`],
                    );
                } else {
                    exportsRows = db.all(
                        `SELECT symbols.id, symbols.name, symbols.kind, symbols.line,
                                symbols.is_export, files.id AS file_id, files.path AS file, files.lang
                         FROM symbols
                         JOIN files ON files.id = symbols.file_id
                         WHERE symbols.is_export = 1
                         ORDER BY files.path, symbols.line`,
                    );
                }

                // 2. For each export, check:
                //    (a) any edge with dst_symbol_id = id
                //    (b) any edge with dst_name = name AND
                //        src_symbol_id NOT in the same file (cross-file
                //        name reference — a same-file usage isn't a
                //        reason to keep an exported API alive).
                //    (c) any imports.resolved_file_id pointing at the
                //        export's file from ANOTHER file. The whole
                //        file's exports are credited as used if ANY
                //        cross-file import resolves to it.
                //
                // We compute (c) once for the whole set so we don't
                // re-query per export.
                const importedFileIds = new Set(
                    db.all(
                        `SELECT DISTINCT resolved_file_id FROM imports
                         WHERE resolved_file_id IS NOT NULL AND file_id <> resolved_file_id`,
                    ).map((r) => r.resolved_file_id),
                );

                const dead = [];
                for (const ex of exportsRows) {
                    // (a) resolved edge
                    const hasResolvedCaller = db.get(
                        `SELECT 1 AS hit FROM edges WHERE dst_symbol_id = ? LIMIT 1`,
                        [ex.id],
                    );
                    if (hasResolvedCaller) continue;

                    // (b) cross-file name-only edge
                    const crossFileName = db.get(
                        `SELECT 1 AS hit FROM edges
                         JOIN symbols src ON src.id = edges.src_symbol_id
                         WHERE edges.dst_name = ? AND src.file_id <> ?
                         LIMIT 1`,
                        [ex.name, ex.file_id],
                    );
                    if (crossFileName) continue;

                    // (c) file-level import from another file
                    if (importedFileIds.has(ex.file_id)) continue;

                    // None of the above — flag as dead.
                    dead.push({
                        name: ex.name,
                        kind: ex.kind,
                        file: ex.file,
                        lang: ex.lang,
                        line: ex.line,
                        reason: 'no edges and no cross-file import resolved to this file',
                    });
                }

                return ok(
                    `dead_code: ${dead.length} unreferenced export(s) in scope ${scope ? JSON.stringify(scope) : '(whole project)'} out of ${exportsRows.length} scanned`,
                    {
                        scope: scope || null,
                        dead,
                        scanned_exports: exportsRows.length,
                        limitations: LIMITATIONS_NOTE,
                    },
                    dead.length === 0
                        ? 'No unreferenced exports detected in scope. Either the codebase is well-pruned, or the scope is small enough that everything has a use.'
                        : LIMITATIONS_NOTE,
                );
            } finally {
                db.close();
            }
        }),
    );
}
