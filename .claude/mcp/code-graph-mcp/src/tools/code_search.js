// code_search.js — `code_search(query, max_results=10, regex?=false, cwd?)`.
//
// Byte-compatible with code-context-mcp's code_search on the surface:
//   - Tool name: code_search
//   - Inputs: query (string), max_results (int, default 10, cap 200),
//             regex (bool, default false), cwd (string?)
//   - Output (in structuredContent.data): { tool, query, regex,
//             max_results, matches: [{file, line, snippet}] }
//
// New under the hood: we no longer shell out to rg / git grep. Instead
// we use the indexed `symbols.name` column for fast identifier
// lookups, falling back to scanning file content for regex queries
// (LIKE for fixed-string, regexp via JS for true regex). Lazy build:
// the indexer runs on first invocation.
//
// Differences from the old behaviour, documented for downstream
// callers:
//   - `tool` in the result is now one of {"graph-index", "graph-scan"}
//     instead of {"rg","git-grep","grep"}. Code that branches on `tool`
//     should be updated; code that reads `matches[].{file,line,snippet}`
//     is unchanged.

import { z } from 'zod';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { resolveProjectRoot } from '../lib/resolve.js';
import { ensureIndex } from '../lib/indexer.js';
import { openDb } from '../lib/db.js';
import { ok, fail, safe } from '../lib/format.js';
import { CodeGraphError } from '../lib/errors.js';
import { validateQuery } from '../lib/validate.js';

const MAX_SNIPPET_LEN = 300;

export function registerSearchTool(server) {
    server.registerTool(
        'code_search',
        {
            title: 'Search code in the current project',
            description:
                "Find a string or pattern in the project's source files. Backed by the tree-sitter symbol " +
                "index when the query looks like a code identifier (fast path), otherwise a file-content scan " +
                "(slow path). Returns up to `max_results` matches as { file, line, snippet } objects.\n\n" +
                "Use this when you need to know where a function, constant, error message, or literal lives " +
                "in the codebase. The orchestrator pre-loads relevant call sites with this tool before " +
                "delegating implementation, and QA uses it to find regression candidates.\n\n" +
                "Byte-compatible with code-context-mcp's code_search on inputs/outputs; the `tool` field in " +
                "the result now reads 'graph-index' or 'graph-scan' to indicate the backend.",
            inputSchema: {
                query: z.string().min(1).max(1024)
                    .describe("Search string. Treated as fixed text by default; pass regex=true for regex semantics."),
                max_results: z.number().int().min(1).max(200).optional()
                    .describe("Maximum results. Default: 10. Cap: 200."),
                regex: z.boolean().optional()
                    .describe("If true, treat query as a JavaScript regex. Default: false (fixed-string)."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Search code',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const query = validateQuery(input.query);
            const maxResults = input.max_results ?? 10;
            const useRegex = input.regex === true;

            // Lazy build: ensures the index reflects the current
            // filesystem before we search it.
            await ensureIndex({ cwd: input.cwd });
            const db = await openDb({ cwd: input.cwd });
            const root = resolveProjectRoot({ cwd: input.cwd });
            try {
                // Fast path: if the query looks like a code identifier
                // AND we're not in regex mode, use the symbol index.
                const isIdentLike = !useRegex && /^[A-Za-z_$][A-Za-z0-9_$]*$/.test(query);
                if (isIdentLike) {
                    const rows = db.all(
                        `SELECT symbols.name, symbols.line, symbols.col, symbols.kind,
                                files.path AS file, files.lang
                         FROM symbols
                         JOIN files ON files.id = symbols.file_id
                         WHERE symbols.name = ?
                         ORDER BY files.path, symbols.line
                         LIMIT ?`,
                        [query, maxResults],
                    );
                    if (rows.length > 0) {
                        const matches = rows.map((r) => ({
                            file: r.file,
                            line: r.line,
                            snippet: snippetFor(root, r.file, r.line),
                        }));
                        return ok(
                            `code_search via graph-index: ${matches.length} symbol match(es) for ${JSON.stringify(query)}`,
                            {
                                tool: 'graph-index',
                                query,
                                regex: useRegex,
                                max_results: maxResults,
                                matches,
                            },
                            'Matches come from the symbol index (definitions). For text/comment hits, pass regex=true or a non-identifier query to use the scan path.',
                        );
                    }
                    // No symbol hits — fall through to the scan path so
                    // we still find textual occurrences (e.g. usage
                    // sites that weren't captured as definitions).
                }

                // Scan path: walk every file in the index and search
                // its content. We never re-read files we haven't seen
                // (the index lists them already).
                const files = db.all('SELECT id, path FROM files ORDER BY path');
                const matches = [];
                let regexObj = null;
                if (useRegex) {
                    try {
                        regexObj = new RegExp(query);
                    } catch (err) {
                        throw new CodeGraphError(`regex compile failed: ${err.message}`, {
                            hint: 'JavaScript regex syntax. Escape `.`, `(`, `+`, etc. for literal matches, or pass regex=false.',
                            example: 'code_search({query: "TODO", regex: false})',
                        });
                    }
                }
                for (const file of files) {
                    if (matches.length >= maxResults) break;
                    const abs = path.join(root, file.path);
                    let lines;
                    try {
                        lines = readFileSync(abs, 'utf8').split('\n');
                    } catch {
                        continue;
                    }
                    for (let i = 0; i < lines.length; i++) {
                        if (matches.length >= maxResults) break;
                        const text = lines[i];
                        const hit = useRegex ? regexObj.test(text) : text.includes(query);
                        if (!hit) continue;
                        matches.push({
                            file: file.path,
                            line: i + 1,
                            snippet: text.slice(0, MAX_SNIPPET_LEN),
                        });
                    }
                }

                return ok(
                    `code_search via graph-scan: ${matches.length} match(es) for ${JSON.stringify(query)}`,
                    {
                        tool: 'graph-scan',
                        query,
                        regex: useRegex,
                        max_results: maxResults,
                        matches,
                    },
                    matches.length === 0
                        ? "No matches. Try broadening the query, or verify the symbol exists with code_index_health()."
                        : 'The scan path reads file contents from disk; use code_context(symbol) for typed identifier lookups (faster + classified into definitions/usages).',
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
        const text = lines[idx] ?? '';
        return text.slice(0, MAX_SNIPPET_LEN);
    } catch {
        return '';
    }
}
