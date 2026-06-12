// symbol_callers.js — `symbol_callers(symbol, cwd?)`.
//
// Direct callers (one hop) of the named symbol. New-stable tool: not
// present in the simpler code-context-mcp; the surface was reserved by
// the .mcp.json `_phase7_codebase_graph_target.tools_to_expose` block.
// Documented as new in the server README.
//
// Output shape:
//   {
//     symbol,
//     resolved_symbol_count,
//     callers: [
//       {
//         caller_symbol,   // name of the caller (e.g. "handleLogin")
//         caller_kind,     // 'function' | 'method' | '<module>' | ...
//         file,            // project-relative
//         line,            // call site line
//         col,
//         resolved: boolean,  // true when the edge was bound to a
//                             //  concrete symbol id at index time
//       },
//       ...
//     ]
//   }
//
// "Direct" means depth=1 from the seed. Use impact_of() for the
// transitive closure. We surface BOTH resolved and name-only edges:
// the high-recall default catches calls our resolver couldn't pin to
// a unique symbol id (overloads, name collisions). Each entry's
// `resolved` flag tells the caller which is which.

import { z } from 'zod';
import { resolveProjectRoot } from '../lib/resolve.js';
import { ensureIndex } from '../lib/indexer.js';
import { openDb } from '../lib/db.js';
import { findSymbolsByName, directCallers } from '../lib/graph.js';
import { ok, safe } from '../lib/format.js';
import { validateSymbol } from '../lib/validate.js';

export function registerSymbolCallersTool(server) {
    server.registerTool(
        'symbol_callers',
        {
            title: 'Direct callers of a symbol (one hop)',
            description:
                "Return every direct caller of a symbol. One hop only — for the transitive closure use " +
                "impact_of(). The seed can match multiple symbols (overloads, polymorphic methods); we " +
                "report `resolved_symbol_count` so the caller knows whether the result is ambiguous.\n\n" +
                "Each caller entry includes the calling symbol's name+kind, the file+line+col of the call " +
                "site, and a `resolved` flag indicating whether the edge was bound to a concrete symbol id " +
                "at index time. Unresolved edges (name-only) are still included — they catch overloads and " +
                "dynamic dispatch the static resolver couldn't pin down.",
            inputSchema: {
                symbol: z.string().min(1).max(256)
                    .describe("Symbol name to look up callers for."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Symbol callers',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const symbol = validateSymbol(input.symbol);
            await ensureIndex({ cwd: input.cwd });
            const db = await openDb({ cwd: input.cwd });
            try {
                const seeds = findSymbolsByName(db, symbol);
                if (seeds.length === 0) {
                    return ok(
                        `symbol_callers: no symbol named ${JSON.stringify(symbol)} found in the index`,
                        {
                            symbol,
                            resolved_symbol_count: 0,
                            seed_locations: [],
                            callers: [],
                        },
                        'The symbol is unknown to the graph. Check spelling and case; some external library symbols are never recorded. Use code_search to confirm.',
                    );
                }
                // Aggregate callers across all matching symbol rows;
                // dedupe by (file, line, col).
                const seen = new Set();
                const callers = [];
                for (const seed of seeds) {
                    const rows = directCallers(db, seed.id);
                    for (const r of rows) {
                        const key = `${r.src_file}:${r.call_line}:${r.call_col}`;
                        if (seen.has(key)) continue;
                        seen.add(key);
                        callers.push({
                            caller_symbol: r.src_name,
                            caller_kind: r.src_kind,
                            file: r.src_file,
                            lang: r.src_lang,
                            line: r.call_line,
                            col: r.call_col,
                            resolved: r.resolved !== null,
                            edge_kind: r.edge_kind,
                        });
                    }
                }
                return ok(
                    `symbol_callers for ${JSON.stringify(symbol)}: ${callers.length} caller(s) across ${seeds.length} symbol definition(s)`,
                    {
                        symbol,
                        resolved_symbol_count: seeds.length,
                        seed_locations: seeds.map((s) => ({ file: s.file, line: s.line, kind: s.kind })),
                        callers,
                    },
                    seeds.length > 1
                        ? `${seeds.length} symbols share this name — the callers list aggregates across all definitions. Filter by file via the seed_locations field if you need disambiguation.`
                        : (callers.length === 0
                            ? 'Symbol is defined but has no recorded callers. Possible reasons: it is part of the project surface (entry point, exported API consumed externally), it is called via dynamic dispatch the resolver missed, or it is genuinely dead — try dead_code() to confirm.'
                            : null),
                );
            } finally {
                db.close();
            }
        }),
    );
}
