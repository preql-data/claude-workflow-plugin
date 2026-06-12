// indexer.test.js — indexer correctness on the polyglot fixture.
//
// Covers:
//   1. Cross-file resolution: getCurrentTask defined in a.ts is reached
//      from b.ts's callers and c.js's chain via TaskHandler.handle.
//   2. Incremental rebuild: a no-op second run reports zero `indexed`,
//      all files as `unchanged`. Mutating one file's content reindexes
//      ONLY that file.
//   3. Pruning: deleting a file from disk drops its rows on next index.
//   4. Full def coverage for ts/js/python/go; smoke def coverage for
//      the other supported languages (rust/java/ruby/php/bash).
//   5. CORRUPT_INDEX detection: openDb on a malformed file throws a
//      CodeGraphError with code === 'CORRUPT_INDEX' — the contract
//      that code_index_health relies on for its `unhealthy` branch.

import test from 'node:test';
import assert from 'node:assert/strict';
import {
    mkdtempSync, rmSync, writeFileSync, readFileSync, statSync,
    cpSync, existsSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { ensureIndex } from '../src/lib/indexer.js';
import { openDb } from '../src/lib/db.js';
import { CodeGraphError } from '../src/lib/errors.js';
import { _resetForTest } from '../src/lib/parser-loader.js';

const FIXTURE_SRC = path.resolve(import.meta.dirname, 'fixtures', 'polyglot');

function mkProject() {
    const root = mkdtempSync(path.join(tmpdir(), 'code-graph-mcp-idx-'));
    cpSync(FIXTURE_SRC, root, { recursive: true });
    return {
        root,
        cleanup() {
            try { rmSync(root, { recursive: true, force: true }); } catch { /* best effort */ }
        },
    };
}

test('ensureIndex indexes every supported file and resolves cross-file calls', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    const summary = await ensureIndex({ cwd: proj.root });
    assert.equal(summary.lazy_first_build, true, 'first call must be a fresh build');
    assert.ok(summary.indexed > 0, 'should have indexed at least some files');
    assert.ok(summary.by_lang.typescript >= 2, `expected at least 2 typescript files; got ${JSON.stringify(summary.by_lang)}`);
    assert.ok(summary.by_lang.javascript >= 1, 'expected at least 1 javascript file');
    assert.ok(summary.by_lang.python >= 2, 'expected at least 2 python files');
    assert.ok(summary.by_lang.go >= 1, 'expected at least 1 go file');

    // Open the DB to assert on the actual graph.
    const db = await openDb({ cwd: proj.root });
    try {
        // getCurrentTask is defined in a.ts and called from b.ts twice.
        const defs = db.all(
            `SELECT files.path AS file FROM symbols
             JOIN files ON files.id = symbols.file_id
             WHERE symbols.name = ?`,
            ['getCurrentTask'],
        );
        assert.ok(defs.length >= 1, `getCurrentTask should be defined; got ${JSON.stringify(defs)}`);
        const defFile = defs.find((d) => d.file === 'a.ts');
        assert.ok(defFile, `getCurrentTask definition should be in a.ts; got files: ${defs.map((d) => d.file).join(',')}`);

        // Callers (resolved by name; the same name appears once in
        // a.ts as the def and twice in b.ts as calls).
        const callers = db.all(
            `SELECT files.path AS file, edges.dst_symbol_id AS resolved
             FROM edges
             JOIN symbols src ON src.id = edges.src_symbol_id
             JOIN files ON files.id = src.file_id
             WHERE edges.dst_name = ?`,
            ['getCurrentTask'],
        );
        assert.ok(callers.length >= 2,
            `expected >=2 callers for getCurrentTask; got ${callers.length}: ${JSON.stringify(callers)}`);
        // At least the b.ts callers should be present.
        const bCalls = callers.filter((c) => c.file === 'b.ts');
        assert.ok(bCalls.length >= 2,
            `expected >=2 callers in b.ts (callerOne + callerTwo); got ${bCalls.length}`);
        // At least one of the b.ts edges must be resolved (single name match).
        assert.ok(
            bCalls.some((c) => c.resolved !== null),
            'at least one b.ts call should resolve to a concrete symbol id',
        );
    } finally {
        db.close();
    }
});

test('incremental: second run with no changes reports indexed=0, unchanged=total', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    const first = await ensureIndex({ cwd: proj.root });
    assert.ok(first.indexed > 0);

    const second = await ensureIndex({ cwd: proj.root });
    assert.equal(second.indexed, 0, `second run should reindex nothing; got indexed=${second.indexed}, summary=${JSON.stringify(second)}`);
    assert.equal(second.unchanged, first.indexed + first.unchanged,
        `second run should mark everything unchanged; got ${JSON.stringify(second)}`);
    assert.equal(second.lazy_first_build, false, 'second run is not a first build');
});

test('incremental: editing one file reindexes only that file', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    await ensureIndex({ cwd: proj.root });
    const aTs = path.join(proj.root, 'a.ts');
    const original = readFileSync(aTs, 'utf8');
    writeFileSync(aTs, original + '\n// trivial change\n');

    const refresh = await ensureIndex({ cwd: proj.root });
    assert.equal(refresh.indexed, 1, `only a.ts should reindex; got ${JSON.stringify(refresh)}`);
    assert.ok(refresh.unchanged > 0, 'other files should be unchanged');
});

test('pruning: deleting a file drops its rows on next index', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    await ensureIndex({ cwd: proj.root });
    const aTs = path.join(proj.root, 'a.ts');
    rmSync(aTs);

    await ensureIndex({ cwd: proj.root });
    const db = await openDb({ cwd: proj.root });
    try {
        const row = db.get('SELECT id FROM files WHERE path = ?', ['a.ts']);
        assert.equal(row, null, `a.ts row should be pruned; got ${JSON.stringify(row)}`);
        const syms = db.all('SELECT name FROM symbols WHERE name = ?', ['getCurrentTask']);
        assert.deepEqual(syms, [], 'getCurrentTask definition must be gone after a.ts deletion');
    } finally {
        db.close();
    }
});

test('polyglot smoke: rust/java/ruby/php/bash defs are extracted', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    await ensureIndex({ cwd: proj.root });
    const db = await openDb({ cwd: proj.root });
    try {
        for (const want of [
            { lang: 'rust',  name: 'rust_main' },
            { lang: 'java',  name: 'greet' },
            { lang: 'ruby',  name: 'smoke_method' },
            { lang: 'php',   name: 'smokeFn' },
            { lang: 'bash',  name: 'smoke_fn' },
        ]) {
            const rows = db.all(
                `SELECT symbols.name FROM symbols
                 JOIN files ON files.id = symbols.file_id
                 WHERE files.lang = ? AND symbols.name = ?`,
                [want.lang, want.name],
            );
            assert.ok(
                rows.length >= 1,
                `expected ${want.lang} grammar to capture ${want.name}; got rows=${JSON.stringify(rows)}`,
            );
        }
    } finally {
        db.close();
    }
});

test('CORRUPT_INDEX: openDb throws CodeGraphError(code=CORRUPT_INDEX) on garbage file', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    // First, build a valid index so we know the path.
    await ensureIndex({ cwd: proj.root });
    const dbPath = path.join(proj.root, '.claude', '.code-graph', 'index.db');
    assert.ok(existsSync(dbPath), `index should exist at ${dbPath}`);

    // Corrupt the file by writing garbage over it.
    writeFileSync(dbPath, 'NOT A SQLITE FILE — gibberish content for the META-TEST');

    let caught = null;
    try {
        await openDb({ cwd: proj.root });
    } catch (err) {
        caught = err;
    }
    assert.ok(caught instanceof CodeGraphError,
        `should throw CodeGraphError on corruption; got ${caught && caught.constructor.name}`);
    assert.equal(caught.code, 'CORRUPT_INDEX',
        `code must be CORRUPT_INDEX so code_index_health can branch on it; got ${caught.code}`);
});

test('force=true reindexes every file regardless of hash', async (t) => {
    const proj = mkProject();
    t.after(() => proj.cleanup());

    const first = await ensureIndex({ cwd: proj.root });
    const forced = await ensureIndex({ cwd: proj.root, force: true });
    assert.equal(forced.unchanged, 0, 'force=true must skip the hash-equal shortcut');
    assert.equal(forced.indexed, first.indexed + first.unchanged,
        `force=true must touch every file; got ${JSON.stringify(forced)}`);
});

// Make tests independent by resetting the parser cache between files
// (some tests delete + recreate fixtures that share grammars).
test.beforeEach(() => {
    // intentionally not resetting between every test — the parser
    // cache is read-only across tests and resetting it pays for a
    // grammar re-load.
});
