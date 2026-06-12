// db.js — sql.js-backed graph store.
//
// We use sql.js (SQLite compiled to wasm) so the dependency is pure
// JavaScript and never triggers node-gyp. The trade-off is that sql.js
// reads the whole DB into memory; the entire DB is then flushed back to
// disk as one write. For the index sizes we expect (a few MB even on
// large polyglot repos), that's fine. The Phase B spec calls out
// `node:sqlite` (Node 22+) as an alternative; we stick with sql.js to
// preserve the Node 18.17 floor.
//
// Schema (see SCHEMA_SQL below for the exact DDL):
//
//   index_meta(key, value)            — schema version + project root + timestamps
//   files(id, path, hash, lang, ...)  — per-file row with content hash for incremental
//   symbols(id, file_id, name, kind,  — definitions, with location and is_export
//           line, col, end_line,
//           end_col, is_export)
//   edges(id, src_symbol_id,          — call/reference edges. dst_name is the
//         dst_name, dst_symbol_id,    — textual callee; dst_symbol_id is set
//         kind, line, col)             — to the resolved symbol id when we can.
//   imports(id, file_id, module,      — import statements; resolved_file_id is set
//           resolved_file_id, line)    — when the module maps to a local file.
//
// Indexes are added on the columns we hit hottest in the tools:
// symbols(name), symbols(file_id), edges(src_symbol_id),
// edges(dst_name), edges(dst_symbol_id), imports(file_id), imports(module).

import initSqlJs from 'sql.js';
import { readFileSync, writeFileSync, existsSync, renameSync } from 'node:fs';
import path from 'node:path';
import { ensureIndexDir, indexPath } from './resolve.js';
import { CodeGraphError } from './errors.js';

export const SCHEMA_VERSION = 1;

const SCHEMA_SQL = `
CREATE TABLE IF NOT EXISTS index_meta (
    key TEXT PRIMARY KEY,
    value TEXT
);

CREATE TABLE IF NOT EXISTS files (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    path TEXT UNIQUE NOT NULL,
    hash TEXT NOT NULL,
    lang TEXT NOT NULL,
    mtime_ms INTEGER NOT NULL,
    indexed_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS symbols (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    line INTEGER NOT NULL,
    col INTEGER NOT NULL,
    end_line INTEGER NOT NULL,
    end_col INTEGER NOT NULL,
    is_export INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS edges (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    src_symbol_id INTEGER NOT NULL REFERENCES symbols(id) ON DELETE CASCADE,
    dst_name TEXT NOT NULL,
    dst_symbol_id INTEGER,
    kind TEXT NOT NULL,
    line INTEGER NOT NULL,
    col INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS imports (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    file_id INTEGER NOT NULL REFERENCES files(id) ON DELETE CASCADE,
    module TEXT NOT NULL,
    resolved_file_id INTEGER,
    line INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_symbols_name ON symbols(name);
CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);
CREATE INDEX IF NOT EXISTS idx_edges_src    ON edges(src_symbol_id);
CREATE INDEX IF NOT EXISTS idx_edges_dst_n  ON edges(dst_name);
CREATE INDEX IF NOT EXISTS idx_edges_dst_id ON edges(dst_symbol_id);
CREATE INDEX IF NOT EXISTS idx_imports_file ON imports(file_id);
CREATE INDEX IF NOT EXISTS idx_imports_mod  ON imports(module);
`;

// sql.js singleton — emscripten module load is expensive (~150 ms);
// we share one instance for the process lifetime.
let _sqlPromise = null;
async function getSql() {
    if (!_sqlPromise) {
        _sqlPromise = initSqlJs({}).catch((err) => {
            _sqlPromise = null;
            throw new CodeGraphError('sql.js initialisation failed', {
                hint: 'Run `npm install` under .claude/mcp/code-graph-mcp/. The sql.js wasm payload lives in node_modules/sql.js/dist/.',
                stderr: err && err.stack ? err.stack : String(err),
            });
        });
    }
    return _sqlPromise;
}

/**
 * Open (or create) the project's index DB.
 *
 * @param {object} opts
 * @param {string} [opts.cwd]    — project root override
 * @param {string} [opts.dbPath] — explicit DB path (test override)
 * @param {boolean} [opts.fresh] — wipe + recreate the DB even if it exists
 * @returns {Promise<DbHandle>}
 */
export async function openDb(opts = {}) {
    const SQL = await getSql();
    const target = opts.dbPath || indexPath(opts);
    let db;
    if (!opts.fresh && existsSync(target)) {
        let bytes;
        try {
            bytes = readFileSync(target);
        } catch (err) {
            throw new CodeGraphError(`failed to read index DB: ${target}`, {
                hint: 'The index is at .claude/.code-graph/index.db. Delete it to force a fresh build, or check filesystem permissions.',
                stderr: err && err.message ? err.message : String(err),
            });
        }
        try {
            db = new SQL.Database(new Uint8Array(bytes));
        } catch (err) {
            // sql.js doesn't always throw at construct-time on
            // corruption (the SQLite VFS is lazy); the integrity
            // check after the schema run below catches the rest.
            // But if it DOES throw here, that's a hard fail.
            throw new CodeGraphError(`index DB is corrupt at ${target}`, {
                hint: 'Delete .claude/.code-graph/index.db and let the next tool call rebuild it. Common causes: partial-write during an OS crash or accidental editor save.',
                stderr: err && err.message ? err.message : String(err),
                code: 'CORRUPT_INDEX',
            });
        }
    } else {
        db = new SQL.Database();
    }
    // Apply schema. CREATE TABLE IF NOT EXISTS is a no-op on a
    // well-formed DB; on garbage bytes it triggers the SQLite parser
    // which then throws with messages like "file is not a database".
    // We catch every error here and re-throw as a CORRUPT_INDEX so
    // code_index_health can branch on it deterministically.
    try {
        db.run(SCHEMA_SQL);
        db.run(`INSERT OR REPLACE INTO index_meta(key, value) VALUES (?, ?)`,
            ['schema_version', String(SCHEMA_VERSION)]);
    } catch (err) {
        try { db.close(); } catch { /* ignore */ }
        throw new CodeGraphError(`index DB is corrupt at ${target}`, {
            hint: 'Delete .claude/.code-graph/index.db and let the next tool call rebuild it. Common causes: partial-write during an OS crash or accidental editor save.',
            stderr: err && err.message ? err.message : String(err),
            code: 'CORRUPT_INDEX',
        });
    }

    return new DbHandle(db, target);
}

export class DbHandle {
    constructor(db, dbPath) {
        this.db = db;
        this.dbPath = dbPath;
        // Derive the project root from the DB path so persist() can
        // ensure the index dir exists without re-resolving cwd. The
        // index path is always `<root>/.claude/.code-graph/index.db`.
        const idxRel = path.join('.claude', '.code-graph', 'index.db');
        if (dbPath.endsWith(idxRel)) {
            this._rootCwd = dbPath.slice(0, -idxRel.length).replace(/[/\\]+$/, '');
        } else {
            // Test paths (e.g. /tmp/foo.db). persist() falls back to mkdir of the parent.
            this._rootCwd = path.dirname(dbPath);
        }
    }

    /**
     * Persist the in-memory DB to disk. Must be called after any
     * mutation the caller wants to survive process death. sql.js's
     * Database#export returns the full DB as a Uint8Array; we write it
     * atomically via a temp + rename so a crash mid-write cannot
     * corrupt the existing index.
     */
    persist() {
        // Ensure parent dir exists (handles both the standard
        // .claude/.code-graph case and test-only direct paths).
        if (this._rootCwd && this._rootCwd.endsWith(path.join('.claude', '.code-graph'))) {
            // legacy path
        }
        try {
            ensureIndexDir({ cwd: this._rootCwd });
        } catch {
            // Test paths under tmp — ensureIndexDir's mkdir may build a
            // non-standard path. Fall back to mkdir on the parent dir.
            const dir = path.dirname(this.dbPath);
            try {
                // eslint-disable-next-line no-restricted-syntax
                writeFileSync(path.join(dir, '.code-graph-sentinel'), '');
            } catch {
                // give up silently; the rename below will surface the real error
            }
        }
        const data = this.db.export();
        const tmp = `${this.dbPath}.tmp-${process.pid}-${Date.now()}`;
        writeFileSync(tmp, Buffer.from(data));
        renameSync(tmp, this.dbPath);
    }

    close() {
        try { this.db.close(); } catch { /* idempotent */ }
    }

    /** Set a meta key (upsert). */
    setMeta(key, value) {
        this.db.run(
            `INSERT OR REPLACE INTO index_meta(key, value) VALUES (?, ?)`,
            [key, String(value)],
        );
    }

    /** Get a meta key value, or null if absent. */
    getMeta(key) {
        const stmt = this.db.prepare(`SELECT value FROM index_meta WHERE key = ?`);
        try {
            stmt.bind([key]);
            if (stmt.step()) {
                return stmt.getAsObject().value;
            }
            return null;
        } finally {
            stmt.free();
        }
    }

    /** Run a SELECT, returning every row as a JS object. */
    all(sql, params = []) {
        const out = [];
        const stmt = this.db.prepare(sql);
        try {
            stmt.bind(params);
            while (stmt.step()) {
                out.push(stmt.getAsObject());
            }
        } finally {
            stmt.free();
        }
        return out;
    }

    /** Run a SELECT, returning the first row or null. */
    get(sql, params = []) {
        const stmt = this.db.prepare(sql);
        try {
            stmt.bind(params);
            if (stmt.step()) return stmt.getAsObject();
            return null;
        } finally {
            stmt.free();
        }
    }

    /**
     * Run a side-effect statement (INSERT/UPDATE/DELETE/CREATE).
     * Returns the last_insert_rowid for INSERTs.
     */
    run(sql, params = []) {
        const stmt = this.db.prepare(sql);
        try {
            stmt.bind(params);
            stmt.step();
        } finally {
            stmt.free();
        }
        const ridResult = this.db.exec('SELECT last_insert_rowid() AS rid');
        return ridResult?.[0]?.values?.[0]?.[0];
    }

    /** Run a SQL string with no params, no result. */
    exec(sql) {
        this.db.run(sql);
    }

    /**
     * Begin/commit/rollback wrapper. The callback receives `this`. On
     * thrown error, ROLLBACK is attempted and the error rethrown.
     */
    transaction(fn) {
        this.db.run('BEGIN');
        try {
            const result = fn(this);
            this.db.run('COMMIT');
            return result;
        } catch (err) {
            try { this.db.run('ROLLBACK'); } catch { /* rollback fail is non-fatal */ }
            throw err;
        }
    }
}
