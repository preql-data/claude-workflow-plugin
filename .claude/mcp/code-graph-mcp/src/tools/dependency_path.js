// dependency_path.js — `dependency_path({from, to, cwd?})`.
//
// Shortest call-chain from `from` to `to`. Both endpoints are symbol
// names. We pick the first matching symbol id for each name (if there
// are multiple, that's reported in the response so the caller can
// retry with a more specific identifier).
//
// Output:
//   - On hit:
//       {
//         from, to,
//         path: [{name, kind, file, line}, ...],   // length >= 2
//         length: int                              // edges, not nodes
//       }
//   - On miss:
//       {
//         from, to,
//         path: null,
//         length: null,
//         reason: 'not_connected' | 'from_not_found' | 'to_not_found'
//       }
//
// Implementation: BFS from `from` over outgoing call edges (graph.js
// shortestPath). Cap on visited nodes is 5000 — enough for big
// codebases, conservative enough that an adversarial input cannot
// blow the stack.

import { z } from 'zod';
import { ensureIndex } from '../lib/indexer.js';
import { openDb } from '../lib/db.js';
import { findSymbolsByName, shortestPath, expandSymbolIds } from '../lib/graph.js';
import { ok, safe } from '../lib/format.js';
import { validateSymbol } from '../lib/validate.js';

export function registerDependencyPathTool(server) {
    server.registerTool(
        'dependency_path',
        {
            title: 'Shortest call chain between two symbols',
            description:
                "Find the shortest call chain from `from` to `to`. Both endpoints are symbol names; if " +
                "either name resolves to multiple definitions, we pick the first match and surface the " +
                "ambiguity in `from_resolution` / `to_resolution`.\n\n" +
                "Returns `path` as a list of nodes (from -> ... -> to) on hit, or `path: null` + a `reason` " +
                "code on miss ('not_connected', 'from_not_found', 'to_not_found'). The `length` field is " +
                "the number of edges traversed.\n\n" +
                "Use this to answer 'does A reach B?' — useful for QA's regression assessment when checking " +
                "whether a changed symbol is on the critical path of a target subsystem.\n\n" +
                "Caveat: dependency_path follows resolved call edges + name-only edges with a unique " +
                "candidate. Dynamic dispatch and reflection are invisible; a 'not_connected' result may " +
                "mean 'connected via a path the static graph could not capture'.",
            inputSchema: {
                from: z.string().min(1).max(256)
                    .describe("Starting symbol name."),
                to: z.string().min(1).max(256)
                    .describe("Target symbol name."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Dependency path',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const from = validateSymbol(input.from, 'from');
            const to = validateSymbol(input.to, 'to');

            await ensureIndex({ cwd: input.cwd });
            const db = await openDb({ cwd: input.cwd });
            try {
                const fromSeeds = findSymbolsByName(db, from);
                const toSeeds = findSymbolsByName(db, to);
                if (fromSeeds.length === 0) {
                    return ok(
                        `dependency_path: from-symbol ${JSON.stringify(from)} not found in the index`,
                        {
                            from, to,
                            path: null,
                            length: null,
                            reason: 'from_not_found',
                        },
                        'Verify the spelling/case. dependency_path needs definitions on both ends; if either symbol comes from an external package, the graph cannot trace through it.',
                    );
                }
                if (toSeeds.length === 0) {
                    return ok(
                        `dependency_path: to-symbol ${JSON.stringify(to)} not found in the index`,
                        {
                            from, to,
                            path: null,
                            length: null,
                            reason: 'to_not_found',
                        },
                        'Verify the spelling/case. If `to` is an external dependency, the graph cannot trace through it.',
                    );
                }

                // Try every (fromSeed, toSeed) pair, keep the shortest.
                let best = null;
                for (const f of fromSeeds) {
                    for (const t of toSeeds) {
                        const p = shortestPath(db, f.id, t.id);
                        if (!p) continue;
                        if (!best || p.length < best.length) {
                            best = p;
                        }
                    }
                }
                if (!best) {
                    return ok(
                        `dependency_path: no static call chain from ${JSON.stringify(from)} to ${JSON.stringify(to)}`,
                        {
                            from, to,
                            path: null,
                            length: null,
                            reason: 'not_connected',
                            from_resolution: fromSeeds.length,
                            to_resolution: toSeeds.length,
                        },
                        'No reachable chain in the static graph. Dynamic dispatch or reflection could still connect them at runtime; verify with a runtime trace if it matters.',
                    );
                }
                const nodes = expandSymbolIds(db, best);
                return ok(
                    `dependency_path: ${nodes.length} node(s) (length=${best.length - 1}) from ${JSON.stringify(from)} to ${JSON.stringify(to)}`,
                    {
                        from, to,
                        path: nodes.map((n) => ({
                            symbol_id: n.id,
                            name: n.name,
                            kind: n.kind,
                            file: n.file,
                            lang: n.lang,
                            line: n.line,
                        })),
                        length: best.length - 1,
                        from_resolution: fromSeeds.length,
                        to_resolution: toSeeds.length,
                    },
                    fromSeeds.length > 1 || toSeeds.length > 1
                        ? `Ambiguity: from=${fromSeeds.length} candidates, to=${toSeeds.length} candidates — returned the shortest path across all pairs.`
                        : null,
                );
            } finally {
                db.close();
            }
        }),
    );
}
