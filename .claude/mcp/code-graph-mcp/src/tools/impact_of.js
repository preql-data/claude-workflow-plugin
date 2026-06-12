// impact_of.js — `impact_of({symbol?, file?, max_depth?, cwd?})`.
//
// Transitive callers + dependents reachable from a seed.
//
// Seed shape:
//   - {symbol: "name"}        — every symbol with that name seeds the BFS.
//   - {file: "src/foo.ts"}    — every symbol in that file seeds, AND
//                                every file that imports it joins as a
//                                dependent.
//
// Result:
//   {
//     seed: { kind: 'symbol'|'file', value: string },
//     max_depth: int,
//     nodes: [
//       { symbol_id, name, kind, file, line, depth, relation },
//       ...
//     ],
//     file_dependents: [   // only present for {file: ...} seed
//       { file, lang }
//     ],
//     truncated: false      // true when max_depth was hit while the
//                            //  frontier was still growing
//   }
//
// `relation` values: "caller" (this symbol calls the seed transitively),
// "self" (the seed itself, depth 0 — included for completeness when
// the symbol seed resolves to multiple definitions).
//
// Caveats (also in the README): the false-negative risk is dynamic
// dispatch / reflection / macros — calls the static graph never
// captured. The false-positive risk is the high-recall mode for
// name-only edges — when multiple symbols share a name, callers of
// one may appear as callers of the other.

import { z } from 'zod';
import { ensureIndex } from '../lib/indexer.js';
import { openDb } from '../lib/db.js';
import {
    findSymbolsByName,
    findFile,
    symbolIdsInFile,
    transitiveCallers,
    fileDependents,
    expandSymbolIds,
} from '../lib/graph.js';
import { ok, fail, safe } from '../lib/format.js';
import { CodeGraphError } from '../lib/errors.js';
import { validateSymbol, validateScopePath, validateDepth } from '../lib/validate.js';

export function registerImpactTool(server) {
    server.registerTool(
        'impact_of',
        {
            title: 'Transitive impact of a symbol or file',
            description:
                "Return the transitive set of callers and dependents reachable from a seed. Seed is either " +
                "a {symbol: 'name'} or a {file: 'project/relative/path'} — exactly one must be provided.\n\n" +
                "Depth is BFS-bounded by `max_depth` (default 5). The result lists every reached node with " +
                "the depth it was first encountered at and its relation ('caller' for symbol-to-symbol " +
                "edges, 'self' for the seed). For file seeds, every file that imports the seed file is " +
                "also listed under `file_dependents`.\n\n" +
                "Use this to answer 'what could break if I change X?'. Combine with QA's J19 regression " +
                "framing: high-fan-in seeds (lots of callers at depth 1) are mandatory regression candidates.\n\n" +
                "Limits — the static graph does NOT resolve dynamic dispatch, reflection, macro expansion, " +
                "or renaming re-exports. False negatives are possible; treat impact_of as a high-recall " +
                "starting point, not an exhaustive proof.",
            inputSchema: {
                symbol: z.string().min(1).max(256).optional()
                    .describe("Seed symbol name (mutually exclusive with `file`)."),
                file: z.string().min(1).max(1024).optional()
                    .describe("Seed file path (project-relative; mutually exclusive with `symbol`)."),
                max_depth: z.number().int().min(0).max(50).optional()
                    .describe("BFS depth cap. Default: 5. 0 means direct callers only."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Impact analysis',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            // Validate seed shape: exactly one of symbol/file required.
            const hasSymbol = typeof input.symbol === 'string' && input.symbol.length > 0;
            const hasFile = typeof input.file === 'string' && input.file.length > 0;
            if (hasSymbol === hasFile) {
                throw new CodeGraphError(
                    hasSymbol
                        ? 'impact_of: pass exactly one of `symbol` or `file` (not both)'
                        : 'impact_of: pass exactly one of `symbol` or `file` (got neither)',
                    {
                        hint: 'Symbol seeds drill into a named identifier; file seeds widen to every symbol in a file plus the files that import it.',
                        example: 'impact_of({symbol: "handleLogin", max_depth: 3}) OR impact_of({file: "src/auth.ts"})',
                    },
                );
            }
            const maxDepth = validateDepth(input.max_depth);

            await ensureIndex({ cwd: input.cwd });
            const db = await openDb({ cwd: input.cwd });
            try {
                let seedIds = [];
                let fileSeedRow = null;
                let seedShape;
                if (hasSymbol) {
                    const symbol = validateSymbol(input.symbol);
                    seedShape = { kind: 'symbol', value: symbol };
                    const rows = findSymbolsByName(db, symbol);
                    seedIds = rows.map((r) => r.id);
                    if (seedIds.length === 0) {
                        return ok(
                            `impact_of: no symbol named ${JSON.stringify(symbol)} found`,
                            {
                                seed: seedShape,
                                max_depth: maxDepth,
                                nodes: [],
                                file_dependents: [],
                                truncated: false,
                            },
                            'The symbol is unknown. Confirm the spelling, or run code_index_health() to verify the index is populated.',
                        );
                    }
                } else {
                    const filePath = validateScopePath(input.file, 'file');
                    if (!filePath) {
                        throw new CodeGraphError('impact_of: `file` cannot be empty', {
                            hint: 'Pass a project-relative path.',
                            example: 'impact_of({file: "src/auth.ts"})',
                        });
                    }
                    seedShape = { kind: 'file', value: filePath };
                    fileSeedRow = findFile(db, filePath);
                    if (!fileSeedRow) {
                        return ok(
                            `impact_of: file ${JSON.stringify(filePath)} is not in the index`,
                            {
                                seed: seedShape,
                                max_depth: maxDepth,
                                nodes: [],
                                file_dependents: [],
                                truncated: false,
                            },
                            'No row in the files table. The file may not be a supported language (see code_index_health.supported_languages) or it was skipped (binary, oversized, in a SKIP_DIRS-listed folder).',
                        );
                    }
                    seedIds = symbolIdsInFile(db, fileSeedRow.id);
                }

                // BFS from every seed id. Dedupe across seeds.
                const seen = new Set(seedIds);
                const nodes = [];
                // Seed depth-0 rows.
                const seedRows = expandSymbolIds(db, seedIds);
                for (const sr of seedRows) {
                    nodes.push({
                        symbol_id: sr.id,
                        name: sr.name,
                        kind: sr.kind,
                        file: sr.file,
                        lang: sr.lang,
                        line: sr.line,
                        depth: 0,
                        relation: 'self',
                    });
                }
                for (const seed of seedIds) {
                    const reached = transitiveCallers(db, seed, maxDepth);
                    for (const node of reached) {
                        if (seen.has(node.symbol_id)) continue;
                        seen.add(node.symbol_id);
                        nodes.push(node);
                    }
                }

                // File dependents (file seed only).
                let fileDeps = [];
                if (fileSeedRow) {
                    fileDeps = fileDependents(db, fileSeedRow.id);
                }

                // Truncation signal: if any reached BFS layer was at
                // exactly maxDepth and produced new nodes, mark
                // truncated=true. We approximate by checking whether
                // any output node has depth === maxDepth — if so, a
                // further hop *might* exist that we didn't follow.
                const truncated = nodes.some((n) => n.depth === maxDepth) && maxDepth > 0;

                return ok(
                    `impact_of ${seedShape.kind}=${JSON.stringify(seedShape.value)}: ${nodes.length - seedIds.length} caller(s) within depth ${maxDepth}` +
                        (fileSeedRow ? `, ${fileDeps.length} file-level dependent(s)` : ''),
                    {
                        seed: seedShape,
                        max_depth: maxDepth,
                        nodes,
                        file_dependents: fileDeps,
                        truncated,
                    },
                    truncated
                        ? `Result was capped at depth=${maxDepth}. Raise max_depth to follow the call chain further, but understand the result set grows fast.`
                        : (nodes.length <= seedIds.length
                            ? 'Seed has no recorded callers. Either it is project surface (entry point / exported API) or it is unreachable — combine with dead_code() to check.'
                            : null),
                );
            } finally {
                db.close();
            }
        }),
    );
}
