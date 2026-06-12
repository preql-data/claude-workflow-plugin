// graph.js — graph traversal helpers over the DbHandle.
//
// All functions here are SYNC because they read only from the
// in-memory sql.js DB (no I/O). They never write — the indexer owns
// every mutation. Tools call into these helpers and shape the result
// into the public response schema.
//
// Vocabulary:
//   - "symbol id" = symbols.id; every node in the graph is a symbol.
//   - "incoming"  = "callers" — edges where dst_symbol_id = symbol.
//                   ALSO accept name-only matches as a fallback for
//                   edges where resolution failed (dst_symbol_id NULL
//                   but dst_name = symbol's name).
//   - "outgoing"  = "callees" — edges where src_symbol_id = symbol.
//   - "depth"     = number of edges from the seed. Depth 0 is the seed.

/**
 * Look up every symbol with a given name. Returns rows with file path
 * joined so callers can present locations.
 */
export function findSymbolsByName(db, name) {
    return db.all(
        `SELECT symbols.id, symbols.name, symbols.kind, symbols.line, symbols.col,
                symbols.is_export, files.path AS file, files.lang
         FROM symbols
         JOIN files ON files.id = symbols.file_id
         WHERE symbols.name = ?
         ORDER BY symbols.file_id, symbols.line`,
        [name],
    );
}

/**
 * Get the symbol(s) defined within a file at a given line (or covering
 * a given line). Used by impact_of when the caller passes a file path
 * — we look for the symbol at line 1 (the file-as-unit) and walk all
 * symbols defined in the file.
 */
export function symbolsInFile(db, filePath) {
    return db.all(
        `SELECT symbols.id, symbols.name, symbols.kind, symbols.line, symbols.col,
                symbols.is_export, files.path AS file, files.lang
         FROM symbols
         JOIN files ON files.id = symbols.file_id
         WHERE files.path = ?
         ORDER BY symbols.line`,
        [filePath],
    );
}

/**
 * Find the file row for a path. Returns null if absent.
 */
export function findFile(db, filePath) {
    return db.get(
        'SELECT id, path, lang, hash, indexed_at FROM files WHERE path = ?',
        [filePath],
    );
}

/**
 * Get all symbols in a file. Convenience for impact_of(file).
 */
export function symbolIdsInFile(db, fileId) {
    return db.all('SELECT id FROM symbols WHERE file_id = ?', [fileId]).map((r) => r.id);
}

/**
 * Direct callers of a symbol. Returns one row per call site. We
 * include edges whose dst_symbol_id matches AND edges whose dst_name
 * matches the symbol's name but were never resolved (so callers see
 * the unresolved-but-textually-named hits too — a high-recall default
 * the README and tool descriptions document).
 */
export function directCallers(db, symbolId) {
    const target = db.get('SELECT name FROM symbols WHERE id = ?', [symbolId]);
    if (!target) return [];
    return db.all(
        `SELECT
            edges.id AS edge_id,
            edges.line AS call_line,
            edges.col AS call_col,
            edges.kind AS edge_kind,
            edges.dst_symbol_id AS resolved,
            src.id AS src_id,
            src.name AS src_name,
            src.kind AS src_kind,
            src.line AS src_line,
            src_file.path AS src_file,
            src_file.lang AS src_lang
         FROM edges
         JOIN symbols src ON src.id = edges.src_symbol_id
         JOIN files src_file ON src_file.id = src.file_id
         WHERE edges.dst_symbol_id = ? OR (edges.dst_symbol_id IS NULL AND edges.dst_name = ?)
         ORDER BY src_file.path, edges.line`,
        [symbolId, target.name],
    );
}

/**
 * Transitive callers up to max_depth hops. BFS; emits one row per
 * unique symbol encountered with the depth at which it was first
 * reached.
 *
 * Returns:
 *   [
 *     { symbol_id, name, kind, file, line, depth, relation: "caller" },
 *     ...
 *   ]
 *
 * `max_depth = 0` returns only direct callers (depth 1). The seed
 * symbol itself is NOT included in the output.
 */
export function transitiveCallers(db, seedSymbolId, maxDepth) {
    const visited = new Set([seedSymbolId]);
    const out = [];
    let frontier = [seedSymbolId];
    for (let depth = 1; depth <= maxDepth + 1; depth++) {
        const next = [];
        for (const sid of frontier) {
            const callers = directCallers(db, sid);
            for (const c of callers) {
                if (visited.has(c.src_id)) continue;
                visited.add(c.src_id);
                out.push({
                    symbol_id: c.src_id,
                    name: c.src_name,
                    kind: c.src_kind,
                    file: c.src_file,
                    lang: c.src_lang,
                    line: c.src_line,
                    depth,
                    relation: 'caller',
                });
                next.push(c.src_id);
            }
        }
        if (next.length === 0) break;
        frontier = next;
    }
    return out;
}

/**
 * File dependents: every file whose imports.resolved_file_id matches.
 * Used by impact_of(file) to surface files that would break if the
 * named file's interface changes.
 */
export function fileDependents(db, fileId) {
    return db.all(
        `SELECT DISTINCT files.id AS file_id, files.path AS file, files.lang
         FROM imports
         JOIN files ON files.id = imports.file_id
         WHERE imports.resolved_file_id = ?`,
        [fileId],
    );
}

/**
 * Shortest dependency path between two endpoints. Returns the list of
 * symbol ids in order, or null if no path exists.
 *
 * Edges traversed are call edges (resolved or by-name) in the same
 * direction as a call chain — "from" depends on "to" if from calls
 * something that eventually reaches to.
 *
 * Implementation: BFS over the dst_symbol_id/dst_name edges, recording
 * parent pointers and reconstructing the path on hit. Capped at 1000
 * visited nodes to keep traversal bounded.
 */
export function shortestPath(db, fromSymbolId, toSymbolId) {
    if (fromSymbolId === toSymbolId) return [fromSymbolId];
    const parent = new Map();
    parent.set(fromSymbolId, null);
    const queue = [fromSymbolId];
    let visited = 0;
    const cap = 5000;
    while (queue.length > 0 && visited < cap) {
        const sid = queue.shift();
        visited++;
        // Callees of sid: resolve outgoing edges. We follow resolved
        // edges first; for unresolved, we look up dst_name -> single
        // candidate.
        const outgoing = db.all(
            `SELECT dst_symbol_id, dst_name FROM edges WHERE src_symbol_id = ?`,
            [sid],
        );
        for (const e of outgoing) {
            let next;
            if (e.dst_symbol_id != null) {
                next = e.dst_symbol_id;
            } else {
                const cand = db.all('SELECT id FROM symbols WHERE name = ?', [e.dst_name]);
                if (cand.length === 1) {
                    next = cand[0].id;
                } else {
                    continue;
                }
            }
            if (parent.has(next)) continue;
            parent.set(next, sid);
            if (next === toSymbolId) {
                // Reconstruct.
                const path = [next];
                let cur = sid;
                while (cur !== null && cur !== undefined) {
                    path.unshift(cur);
                    cur = parent.get(cur);
                }
                return path;
            }
            queue.push(next);
        }
    }
    return null;
}

/**
 * Expand a list of symbol ids into the rich row shape used by tool
 * responses. Done in one query for efficiency.
 */
export function expandSymbolIds(db, ids) {
    if (!ids || ids.length === 0) return [];
    const placeholders = ids.map(() => '?').join(',');
    const rows = db.all(
        `SELECT symbols.id, symbols.name, symbols.kind, symbols.line, symbols.col,
                symbols.is_export, files.path AS file, files.lang
         FROM symbols
         JOIN files ON files.id = symbols.file_id
         WHERE symbols.id IN (${placeholders})`,
        ids,
    );
    // Preserve order from the input ids.
    const byId = new Map(rows.map((r) => [r.id, r]));
    return ids.map((i) => byId.get(i)).filter(Boolean);
}
