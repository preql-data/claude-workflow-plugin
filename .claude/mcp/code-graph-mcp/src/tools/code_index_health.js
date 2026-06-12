// code_index_health.js — `code_index_health()` MCP tool.
//
// Reports the index's freshness, the per-language coverage, the last
// index time, and the DB size on disk. Returns `unhealthy` when the
// DB file is corrupt or unreadable — the META-TEST target.
//
// Status taxonomy:
//
//   "healthy"   — index DB exists, opens cleanly, and is at most
//                 STALE_FILE_THRESHOLD files behind the live tree.
//   "stale"     — opens cleanly but the file count drifted past the
//                 threshold. Tells the caller a reindex is worth
//                 triggering; tools that follow will trigger it
//                 themselves on first call.
//   "unhealthy" — DB is corrupt, missing, or unreadable AND the
//                 walk couldn't enumerate files either. Distinct from
//                 "stale" because callers must NOT trust the index
//                 contents.
//   "uninitialized" — DB doesn't exist yet (no tool call has built it).
//                 This is the LAZY-BUILD baseline; not an error.

import { z } from 'zod';
import { existsSync, statSync } from 'node:fs';
import { resolveProjectRoot, indexPath } from '../lib/resolve.js';
import { openDb } from '../lib/db.js';
import { walkProject } from '../lib/walker.js';
import { LANGUAGES } from '../lib/parser-loader.js';
import { ok, fail, safe } from '../lib/format.js';
import { CodeGraphError } from '../lib/errors.js';

const STALE_FILE_THRESHOLD = 5;   // files added/removed since last index

export function registerHealthTool(server) {
    server.registerTool(
        'code_index_health',
        {
            title: 'Check code-graph index health',
            description:
                "Sanity-check the code-graph index. Reports status (healthy / stale / unhealthy / uninitialized), " +
                "last index time, per-language coverage counts, the number of files on disk since the last index, " +
                "and the index file size.\n\n" +
                "Run this once at the start of a session to confirm the graph tools will return useful results. " +
                "Do not call it in a hot loop. The very first call against an uninitialised project returns " +
                "status='uninitialized' — that is not an error; the next tool call (code_search, code_context, " +
                "etc.) will build the index on demand.",
            inputSchema: {
                cwd: z.string().optional()
                    .describe("Working directory (overrides CLAUDE_PROJECT_DIR env)."),
            },
            annotations: {
                title: 'Health check',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false,
            },
        },
        safe(async (input) => {
            const root = resolveProjectRoot({ cwd: input.cwd });
            if (!existsSync(root)) {
                return fail(new CodeGraphError(`project root not found: ${root}`, {
                    hint: 'Pass an existing directory via the cwd parameter, or set CLAUDE_PROJECT_DIR.',
                    example: 'code_index_health({cwd: "/path/to/repo"})',
                }));
            }
            const dbPath = indexPath({ cwd: input.cwd });
            const dbExists = existsSync(dbPath);

            // Count files on disk first so we can answer even when the
            // DB is broken.
            let liveFiles = [];
            let walkError = null;
            try {
                liveFiles = walkProject(root);
            } catch (err) {
                walkError = err;
            }

            if (!dbExists) {
                return ok(
                    `code_index_health: status=uninitialized, project=${root}, candidate_files=${liveFiles.length}`,
                    {
                        status: 'uninitialized',
                        project_root: root,
                        index_path: dbPath,
                        candidate_files: liveFiles.length,
                        per_language_candidates: countByLang(liveFiles),
                        supported_languages: Object.keys(LANGUAGES),
                    },
                    'No index yet. The next code_search/code_context/etc. call will build it on demand (lazy first build).',
                );
            }

            // Try to open the DB. If it's corrupt, openDb throws a
            // CodeGraphError with code === 'CORRUPT_INDEX'. Surface as
            // status=unhealthy (NOT isError) so the LLM can read the
            // payload structurally without treating it as a tool
            // failure — health-asking-isError is too coarse.
            let db;
            try {
                db = await openDb({ cwd: input.cwd });
            } catch (err) {
                if (err instanceof CodeGraphError && err.code === 'CORRUPT_INDEX') {
                    let dbSize = 0;
                    try { dbSize = statSync(dbPath).size; } catch { /* ignore */ }
                    return ok(
                        `code_index_health: status=unhealthy, index DB is corrupt at ${dbPath}`,
                        {
                            status: 'unhealthy',
                            reason: 'corrupt_index',
                            project_root: root,
                            index_path: dbPath,
                            db_size_bytes: dbSize,
                            candidate_files: liveFiles.length,
                            supported_languages: Object.keys(LANGUAGES),
                            error: {
                                message: err.message,
                                hint: err.hint,
                                stderr: err.stderr,
                            },
                        },
                        'Delete .claude/.code-graph/index.db and let the next tool call rebuild the index.',
                    );
                }
                // Any other open failure (permission, etc.) — fail() it.
                return fail(err);
            }

            try {
                const last = db.getMeta('last_index_at');
                const projectStored = db.getMeta('project_root');
                const langCounts = db.all(
                    'SELECT lang, COUNT(*) AS n FROM files GROUP BY lang ORDER BY lang',
                );
                const fileCount = db.get('SELECT COUNT(*) AS n FROM files')?.n ?? 0;
                const symbolCount = db.get('SELECT COUNT(*) AS n FROM symbols')?.n ?? 0;
                const edgeCount = db.get('SELECT COUNT(*) AS n FROM edges')?.n ?? 0;
                const resolvedEdges = db.get('SELECT COUNT(*) AS n FROM edges WHERE dst_symbol_id IS NOT NULL')?.n ?? 0;

                const indexed = Number(fileCount);
                const live = liveFiles.length;
                const drift = Math.abs(live - indexed);
                const isStale = drift >= STALE_FILE_THRESHOLD;
                const status = isStale ? 'stale' : 'healthy';

                let dbSize = 0;
                try { dbSize = statSync(dbPath).size; } catch { /* ignore */ }

                const data = {
                    status,
                    project_root: root,
                    project_root_stored: projectStored,
                    index_path: dbPath,
                    last_index_at: last,
                    indexed_files: indexed,
                    live_files: live,
                    drift,
                    stale_threshold: STALE_FILE_THRESHOLD,
                    symbols: Number(symbolCount),
                    edges: Number(edgeCount),
                    resolved_edges: Number(resolvedEdges),
                    coverage_by_lang: Object.fromEntries(
                        langCounts.map((r) => [r.lang, Number(r.n)]),
                    ),
                    candidate_files: live,
                    candidate_by_lang: countByLang(liveFiles),
                    db_size_bytes: dbSize,
                    supported_languages: Object.keys(LANGUAGES),
                    walk_error: walkError ? walkError.message : null,
                };
                const obsParts = [];
                if (isStale) {
                    obsParts.push(`Index drifted by ${drift} files vs the live tree (threshold=${STALE_FILE_THRESHOLD}); the next tool call will refresh the changed files.`);
                }
                if (resolvedEdges < edgeCount) {
                    obsParts.push(`${edgeCount - resolvedEdges} of ${edgeCount} edges remain unresolved (no concrete symbol for the dst name). Common causes: external library calls, dynamic dispatch, name collisions across files.`);
                }
                if (walkError) {
                    obsParts.push(`File walk reported: ${walkError.message}. The "live_files" count may be wrong.`);
                }
                return ok(
                    `code_index_health: status=${status}, indexed=${indexed}, live=${live}, drift=${drift}` +
                        (last ? `, last_index_at=${last}` : ''),
                    data,
                    obsParts.length > 0 ? obsParts.join(' ') : 'Healthy: graph tools should return useful results.',
                );
            } finally {
                db.close();
            }
        }),
    );
}

function countByLang(files) {
    const out = {};
    for (const f of files) {
        out[f.lang] = (out[f.lang] || 0) + 1;
    }
    return out;
}
