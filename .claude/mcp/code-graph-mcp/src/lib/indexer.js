// indexer.js — tree-sitter -> SQLite indexer.
//
// `ensureIndex(opts)` is the only public entry point.
//
// Behaviour:
//
//   1. Walk the project tree (walker.js) — collecting every supported
//      source file.
//   2. Preload every grammar parser the walk needs (async).
//   3. Open (or create) the index DB (sql.js).
//   4. Per file: compute sha1; compare to stored hash; if different
//      (or no prior row), delete the file's previous symbols/imports
//      and re-parse. If the hash matches and `force` is false, skip.
//   5. Prune files no longer on disk.
//   6. Resolve edges (call sites -> concrete symbol ids) and imports
//      (module paths -> local file ids) across the whole DB.
//   7. Persist the DB and close.
//
// Incremental reindex: step 4 is the heart of the contract. A no-op
// run on an unchanged tree increments `unchanged` only; no rows
// change. A run where one file's content shifts re-parses that file
// alone and refreshes its symbols/imports/edges.
//
// Concurrency: ensureIndex is re-entrant-safe at the cwd granularity
// only — two concurrent calls on the same project will both read,
// both mutate their own in-memory DB, and the last to persist() wins.
// We don't add a file-lock because: (a) the server runs single-process
// stdio; (b) the index only grows and never loses user data; (c) a
// rare race produces nothing worse than a stale row that the next
// indexing pass corrects.
//
// Lazy build: this module never indexes at module load. server.js
// calls ensureIndex from inside each tool handler — the first tool
// call after server boot pays the indexing cost; subsequent calls hit
// the warm cache.

import { readFileSync, statSync } from 'node:fs';
import { createHash } from 'node:crypto';
import path from 'node:path';
import { Query } from 'web-tree-sitter';
import { resolveProjectRoot } from './resolve.js';
import { openDb } from './db.js';
import {
    getParserSync,
    getLanguageSync,
    preloadParsers,
    detectLanguage,
} from './parser-loader.js';
import { QUERIES, kindFromNodeType } from './queries.js';
import { walkProject } from './walker.js';
import { CodeGraphError } from './errors.js';

const HASH_ALG = 'sha1';

function sha1(content) {
    return createHash(HASH_ALG).update(content).digest('hex');
}

/**
 * Index (or refresh-by-hash) the project rooted at the resolved cwd.
 *
 * @param {object} opts
 * @param {string}  [opts.cwd]
 * @param {boolean} [opts.force]   — reindex every file even if hashes match
 * @param {string}  [opts.dbPath]  — explicit DB path (test override)
 * @returns {Promise<{
 *   indexed: number,            // files (re)parsed this call
 *   unchanged: number,          // files skipped because hash matched
 *   total: number,              // files in the project after this call
 *   by_lang: Record<string,number>,
 *   index_path: string,
 *   project_root: string,
 *   lazy_first_build: boolean,
 * }>}
 */
export async function ensureIndex(opts = {}) {
    const root = resolveProjectRoot(opts);
    const files = walkProject(root);
    if (files.length > 0) {
        await preloadParsers(files.map((f) => f.lang));
    }

    const db = await openDb(opts);

    const wasEmpty = countFiles(db) === 0;
    const summary = {
        indexed: 0,
        unchanged: 0,
        total: files.length,
        by_lang: {},
        index_path: db.dbPath,
        project_root: root,
        lazy_first_build: wasEmpty,
    };

    const existingPaths = new Set(
        db.all('SELECT path FROM files').map((r) => r.path),
    );
    const onDiskPaths = new Set(files.map((f) => f.rel));

    db.transaction((tx) => {
        // 1. Per-file: compare hash, reindex on miss.
        for (const file of files) {
            let content;
            try {
                content = readFileSync(file.abs, 'utf8');
            } catch {
                continue;
            }
            const hash = sha1(content);
            const existing = tx.get(
                'SELECT id, hash FROM files WHERE path = ?',
                [file.rel],
            );
            if (existing && existing.hash === hash && !opts.force) {
                summary.unchanged++;
                summary.by_lang[file.lang] = (summary.by_lang[file.lang] || 0) + 1;
                continue;
            }
            if (existing) {
                tx.run('DELETE FROM symbols WHERE file_id = ?', [existing.id]);
                tx.run('DELETE FROM imports WHERE file_id = ?', [existing.id]);
                tx.run('DELETE FROM files   WHERE id = ?',      [existing.id]);
                // edges referencing the file's symbols cascade via FK.
            }
            const stat = (() => {
                try { return statSync(file.abs); } catch { return { mtimeMs: Date.now() }; }
            })();
            tx.run(
                'INSERT INTO files(path, hash, lang, mtime_ms, indexed_at) VALUES (?,?,?,?,?)',
                [file.rel, hash, file.lang, Math.floor(stat.mtimeMs), new Date().toISOString()],
            );
            const fileRow = tx.get('SELECT id FROM files WHERE path = ?', [file.rel]);
            if (!fileRow) continue;
            try {
                parseAndStore(tx, file, content, fileRow.id);
                summary.indexed++;
                summary.by_lang[file.lang] = (summary.by_lang[file.lang] || 0) + 1;
            } catch (err) {
                // Per-file parse failures must not blow the whole
                // index. The file's row stays (so the hash is recorded
                // and we don't retry on every call) but symbols/imports
                // are empty.
                process.stderr.write(
                    `code-graph-mcp: indexer skipped ${file.rel}: ${err && err.message ? err.message : String(err)}\n`,
                );
            }
        }

        // 2. Prune files that no longer exist on disk.
        for (const oldPath of existingPaths) {
            if (!onDiskPaths.has(oldPath)) {
                const row = tx.get('SELECT id FROM files WHERE path = ?', [oldPath]);
                if (row) {
                    tx.run('DELETE FROM symbols WHERE file_id = ?', [row.id]);
                    tx.run('DELETE FROM imports WHERE file_id = ?', [row.id]);
                    tx.run('DELETE FROM files   WHERE id = ?',      [row.id]);
                }
            }
        }
    });

    // Resolution passes run OUTSIDE the per-file transaction so they see
    // the final symbol set across the whole repo.
    resolveEdges(db);
    resolveImports(db);

    db.setMeta('last_index_at', new Date().toISOString());
    db.setMeta('project_root', root);
    db.persist();
    db.close();

    return summary;
}

/**
 * The core parse-and-store loop. Runs inside the per-file
 * transaction. Tree-sitter operations are synchronous; we rely on
 * preloadParsers having warmed the cache before entering the
 * transaction.
 */
function parseAndStore(tx, file, content, fileId) {
    const parser = getParserSync(file.lang);
    const language = getLanguageSync(file.lang);

    const tree = parser.parse(content);
    if (!tree) {
        throw new CodeGraphError(`tree-sitter returned null tree for ${file.rel}`, {
            hint: 'Possible OOM or grammar mismatch.',
        });
    }
    try {
        const defs = QUERIES[file.lang]?.defs;
        const calls = QUERIES[file.lang]?.calls;
        const imps = QUERIES[file.lang]?.imports;

        // ---- definitions (symbols)
        //
        // tree-sitter queries fire independently for each pattern, so
        // a definition wrapped in an `export_statement` produces TWO
        // matches: one for the bare definition, one for the wrapping
        // export. We collect into a Map keyed by start position and
        // merge the is_export flag so each unique definition lands
        // exactly once. Otherwise downstream resolveEdges sees
        // duplicate candidates and refuses to bind any of them.
        if (defs) {
            const query = new Query(language, defs);
            try {
                const matches = query.matches(tree.rootNode);
                // key = `${startLine}:${startCol}:${name}`
                const collected = new Map();
                for (const m of matches) {
                    const nameCap = m.captures.find((c) => c.name === 'def.name');
                    const nodeCap = m.captures.find((c) => c.name === 'def.node') || nameCap;
                    const isExport = m.captures.some((c) => c.name === 'export');
                    if (!nameCap || !nodeCap) continue;
                    const symName = nameCap.node.text;
                    const kind = kindFromNodeType(nodeCap.node.type);
                    const { row: line, column: col } = nodeCap.node.startPosition;
                    const { row: endLine, column: endCol } = nodeCap.node.endPosition;
                    const key = `${line}:${col}:${symName}`;
                    const prev = collected.get(key);
                    if (prev) {
                        // Merge: keep the earlier kind unless the new
                        // one is more specific (function > symbol), and
                        // OR-in the export flag.
                        prev.isExport = prev.isExport || isExport;
                        if (prev.kind === 'symbol' && kind !== 'symbol') {
                            prev.kind = kind;
                        }
                        continue;
                    }
                    collected.set(key, {
                        name: symName, kind, line, col, endLine, endCol, isExport,
                    });
                }
                for (const sym of collected.values()) {
                    tx.run(
                        'INSERT INTO symbols(file_id, name, kind, line, col, end_line, end_col, is_export) VALUES (?,?,?,?,?,?,?,?)',
                        [fileId, sym.name, sym.kind, sym.line + 1, sym.col + 1,
                         sym.endLine + 1, sym.endCol + 1, sym.isExport ? 1 : 0],
                    );
                }
            } finally {
                query.delete();
            }
        }

        // ---- calls (edges)
        // Attribute each call to the enclosing definition by line
        // range (tightest containing symbol wins). File-level calls
        // (top of module, no enclosing function) attach to a
        // synthetic "<module>" symbol — created lazily so files
        // without top-level calls don't accrete dead rows.
        if (calls) {
            const fileSymbols = tx.all(
                'SELECT id, line, end_line FROM symbols WHERE file_id = ?',
                [fileId],
            );
            let moduleSymbolId = null;
            const ensureModuleSymbol = () => {
                if (moduleSymbolId !== null) return moduleSymbolId;
                tx.run(
                    'INSERT INTO symbols(file_id, name, kind, line, col, end_line, end_col, is_export) VALUES (?,?,?,?,?,?,?,?)',
                    [fileId, '<module>', 'module', 1, 1, 1, 1, 0],
                );
                const row = tx.get(
                    'SELECT id FROM symbols WHERE file_id = ? AND name = ? ORDER BY id DESC LIMIT 1',
                    [fileId, '<module>'],
                );
                moduleSymbolId = row ? row.id : null;
                if (moduleSymbolId !== null) {
                    fileSymbols.push({ id: moduleSymbolId, line: 1, end_line: 1_000_000 });
                }
                return moduleSymbolId;
            };
            const query = new Query(language, calls);
            try {
                const matches = query.matches(tree.rootNode);
                for (const m of matches) {
                    // Skip predicate-only matches (helper captures
                    // start with `_` in our query strings).
                    const nameCap = m.captures.find((c) => c.name === 'call.name');
                    if (!nameCap) continue;
                    const callName = nameCap.node.text;
                    if (!callName) continue;
                    const { row, column } = nameCap.node.startPosition;
                    // Tightest-enclosing-symbol lookup.
                    let enclosing = null;
                    let enclosingRange = Infinity;
                    for (const sym of fileSymbols) {
                        const endLine = sym.end_line ?? 1_000_000;
                        if (sym.line <= row + 1 && endLine >= row + 1) {
                            const range = endLine - sym.line;
                            if (range < enclosingRange) {
                                enclosing = sym;
                                enclosingRange = range;
                            }
                        }
                    }
                    const srcId = enclosing ? enclosing.id : ensureModuleSymbol();
                    if (srcId === null || srcId === undefined) continue;
                    tx.run(
                        'INSERT INTO edges(src_symbol_id, dst_name, dst_symbol_id, kind, line, col) VALUES (?,?,?,?,?,?)',
                        [srcId, callName, null, 'call', row + 1, column + 1],
                    );
                }
            } finally {
                query.delete();
            }
        }

        // ---- imports
        if (imps) {
            const query = new Query(language, imps);
            try {
                const matches = query.matches(tree.rootNode);
                for (const m of matches) {
                    const modCap = m.captures.find((c) => c.name === 'import.module');
                    if (!modCap) continue;
                    let modText = modCap.node.text;
                    // Strip enclosing quotes for grammars that hand
                    // them to us (Go interpreted_string_literal, etc.).
                    if (
                        (modText.startsWith('"') && modText.endsWith('"')) ||
                        (modText.startsWith("'") && modText.endsWith("'")) ||
                        (modText.startsWith('`') && modText.endsWith('`'))
                    ) {
                        modText = modText.slice(1, -1);
                    }
                    const line = modCap.node.startPosition.row + 1;
                    tx.run(
                        'INSERT INTO imports(file_id, module, resolved_file_id, line) VALUES (?,?,?,?)',
                        [fileId, modText, null, line],
                    );
                }
            } finally {
                query.delete();
            }
        }
    } finally {
        tree.delete();
    }
}

/**
 * Pass 2: bind edges.dst_name -> symbols.id where possible.
 *
 * Pragmatic rule:
 *   - One symbol matches → bind.
 *   - Many match, exactly one is in the caller's file → prefer it.
 *   - Otherwise leave unresolved; the tool layer still surfaces such
 *     edges by name.
 */
function resolveEdges(db) {
    const unresolved = db.all(
        'SELECT id, dst_name, src_symbol_id FROM edges WHERE dst_symbol_id IS NULL',
    );
    for (const e of unresolved) {
        const candidates = db.all(
            'SELECT id, file_id FROM symbols WHERE name = ?',
            [e.dst_name],
        );
        if (candidates.length === 0) continue;
        if (candidates.length === 1) {
            db.run('UPDATE edges SET dst_symbol_id = ? WHERE id = ?',
                [candidates[0].id, e.id]);
            continue;
        }
        const srcFile = db.get(
            'SELECT file_id FROM symbols WHERE id = ?',
            [e.src_symbol_id],
        );
        if (srcFile) {
            const sameFile = candidates.filter((c) => c.file_id === srcFile.file_id);
            if (sameFile.length === 1) {
                db.run('UPDATE edges SET dst_symbol_id = ? WHERE id = ?',
                    [sameFile[0].id, e.id]);
            }
        }
    }
}

/**
 * Pass 3: bind imports.module -> files.id where the module path is
 * resolvable as a local file. The resolver is per-language and
 * intentionally simple — TS/JS resolves relative paths against common
 * extensions and index files; Python resolves dotted modules against
 * the project layout; Ruby honours `.rb` suffix. Go/Rust/Java/PHP
 * imports are recorded by name only (the package layout for those
 * languages would need build-system-aware resolution we don't ship).
 */
function resolveImports(db) {
    const unresolved = db.all(
        `SELECT imports.id, imports.module, imports.file_id, files.path AS src_path, files.lang
         FROM imports JOIN files ON files.id = imports.file_id
         WHERE imports.resolved_file_id IS NULL`,
    );
    for (const imp of unresolved) {
        const candidates = candidateImportPaths(imp.lang, imp.src_path, imp.module);
        if (!candidates || candidates.length === 0) continue;
        for (const candidate of candidates) {
            const target = db.get('SELECT id FROM files WHERE path = ?', [candidate]);
            if (target) {
                db.run('UPDATE imports SET resolved_file_id = ? WHERE id = ?',
                    [target.id, imp.id]);
                break;
            }
        }
    }
}

function candidateImportPaths(lang, srcPath, modPath) {
    if (lang === 'typescript' || lang === 'tsx' || lang === 'javascript') {
        if (!modPath.startsWith('.')) return null;  // external package
        const dir = path.posix.dirname(srcPath.replace(/\\/g, '/'));
        const base = path.posix.normalize(path.posix.join(dir, modPath));
        return [
            `${base}.ts`, `${base}.tsx`, `${base}.js`, `${base}.jsx`,
            `${base}.mjs`, `${base}.cjs`,
            `${base}/index.ts`, `${base}/index.tsx`, `${base}/index.js`,
        ];
    }
    if (lang === 'python') {
        const rel = modPath.replace(/\./g, '/');
        return [`${rel}.py`, `${rel}/__init__.py`];
    }
    if (lang === 'ruby') {
        if (modPath.endsWith('.rb')) return [modPath];
        return [`${modPath}.rb`];
    }
    return null;
}

export function countFiles(db) {
    const row = db.get('SELECT COUNT(*) AS n FROM files');
    return row ? Number(row.n) : 0;
}

// Re-export the language detector so server-side tool code can use it
// without dragging in parser-loader's other internals.
export { detectLanguage };
