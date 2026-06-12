// code_context.js — `code_context(symbol, max_results?=30, cwd?)`.
//
// Byte-compatible with code-context-mcp's code_context on the surface:
//   - Tool name: code_context
//   - Inputs: symbol (string), max_results (int, default 30, cap 200),
//             cwd (string?)
//   - Output: { symbol, backend, max_results, definitions, usages,
//               total_matches, truncated }
//
// New under the hood: definitions and usages now come from the
// tree-sitter graph, not a regex-classified `git grep`. That makes the
// classification semantic rather than heuristic — `definitions` are
// real symbol-table entries; `usages` are call sites recorded in the
// edges table.
//
// Differences from the old behaviour, documented:
//   - `backend` is now 'graph-index'. Code that branched on
//     'git-grep -w' / 'rg --word-regexp' / 'grep -rwn' should drop the
//     branch — the data shape stays the same.
//   - Definition kinds are richer (function/class/method/type/...). The
//     downstream tooling only used `file`, `line`, `snippet` from each
//     entry; `kind` is a new optional field.

import { z } from 'zod';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { resolveProjectRoot } from '../lib/resolve.js';
import { ensureIndex } from '../lib/indexer.js';
import { openDb } from '../lib/db.js';
import { ok, fail, safe } from '../lib/format.js';
import { validateSymbol } from '../lib/validate.js';

const MAX_SNIPPET_LEN = 300;

export function registerContextTool(server) {
    server.registerTool(
        'code_context',
        {
            title: 'Find definition + usages of a symbol',
            description:
                "Given a symbol name (function, class, method, variable, type), return its semantic " +
                "definition site(s) and a sample of its call/usage sites — both pulled from the " +
                "tree-sitter symbol graph. Returns { definitions: [...], usages: [...] } where each entry " +
                "is { file, line, snippet, kind? } and `kind` describes the syntactic shape.\n\n" +
                "Use this BEFORE delegating: pre-load the calling context of every symbol the specialist " +
                "will touch. The QA agent uses the same tool to surface regression candidates by walking " +
                "the usages of each changed symbol.\n\n" +
                "Byte-compatible with code-context-mcp's code_context on inputs/outputs; backend is now " +
                "'graph-index' and classification is semantic, not heuristic regex.",
            inputSchema: {
                symbol: z.string().min(1).max(256)
                    .describe("Code identifier to look up (e.g., 'getCurrentTask', 'MyClass', 'API_BASE')."),
                max_results: z.number().int().min(1).max(200).optional()
                    .describe("Maximum results across definitions+usages combined. Default: 30."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Get symbol context',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const symbol = validateSymbol(input.symbol);
            const maxResults = input.max_results ?? 30;
            const root = resolveProjectRoot({ cwd: input.cwd });

            await ensureIndex({ cwd: input.cwd });
            const db = await openDb({ cwd: input.cwd });
            try {
                // Definitions: every row in symbols with the given name.
                const defRows = db.all(
                    `SELECT symbols.name, symbols.kind, symbols.line, symbols.col,
                            symbols.is_export, files.path AS file, files.lang
                     FROM symbols
                     JOIN files ON files.id = symbols.file_id
                     WHERE symbols.name = ?
                     ORDER BY files.path, symbols.line
                     LIMIT ?`,
                    [symbol, maxResults],
                );

                // Usages: edges whose dst_name matches (resolved or not).
                // We join through to the source symbol + file for the
                // location context.
                const usageRows = db.all(
                    `SELECT edges.line AS line, edges.col AS col, edges.kind AS edge_kind,
                            files.path AS file, files.lang
                     FROM edges
                     JOIN symbols src ON src.id = edges.src_symbol_id
                     JOIN files ON files.id = src.file_id
                     WHERE edges.dst_name = ?
                     ORDER BY files.path, edges.line
                     LIMIT ?`,
                    [symbol, maxResults],
                );

                // Cap combined results.
                let defsKept = defRows;
                let usagesKept = usageRows;
                const totalAvailable = defRows.length + usageRows.length;
                if (totalAvailable > maxResults) {
                    // Prioritise definitions; usages fill the rest.
                    if (defRows.length >= maxResults) {
                        defsKept = defRows.slice(0, maxResults);
                        usagesKept = [];
                    } else {
                        defsKept = defRows;
                        usagesKept = usageRows.slice(0, maxResults - defRows.length);
                    }
                }

                const definitions = defsKept.map((r) => ({
                    file: r.file,
                    line: r.line,
                    snippet: snippetFor(root, r.file, r.line),
                    kind: r.kind,
                    is_export: !!r.is_export,
                }));
                const usages = usagesKept.map((r) => ({
                    file: r.file,
                    line: r.line,
                    snippet: snippetFor(root, r.file, r.line),
                    kind: r.edge_kind,  // 'call' / 'import' / 'reference'
                }));
                const totalShown = definitions.length + usages.length;
                const truncated = totalAvailable > totalShown;

                return ok(
                    `code_context for ${JSON.stringify(symbol)}: ${definitions.length} definition(s), ${usages.length} usage(s)` +
                        (truncated ? ` (truncated from ${totalAvailable})` : ''),
                    {
                        symbol,
                        backend: 'graph-index',
                        max_results: maxResults,
                        definitions,
                        usages,
                        total_matches: totalAvailable,
                        truncated,
                    },
                    truncated
                        ? `Showing ${totalShown} of ${totalAvailable} matches. Increase max_results to see more, or scope to a directory via dependency_path/impact_of.`
                        : (totalShown === 0
                            ? 'No matches. Verify the symbol name (case matters); try code_search for a looser pattern, or code_index_health to confirm the project was indexed.'
                            : 'Definitions and usages come from the symbol graph. Dynamic dispatch, reflection, and macro expansion are NOT resolved — flagged in the server README under Limits.'),
                );
            } finally {
                db.close();
            }
        }),
    );
}

function snippetFor(root, filePath, line) {
    try {
        const abs = path.join(root, filePath);
        const lines = readFileSync(abs, 'utf8').split('\n');
        const idx = Math.max(0, line - 1);
        return (lines[idx] ?? '').slice(0, MAX_SNIPPET_LEN);
    } catch {
        return '';
    }
}
