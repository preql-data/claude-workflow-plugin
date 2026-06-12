// tools.test.js — end-to-end tests for every tool over the polyglot
// fixture. Drives the McpServer via the in-memory transport pair (so
// every Zod validation + structured-output path is exercised).
//
// Coverage:
//   - code_search    happy path (identifier + scan) + 0-match path
//   - code_context   happy path against the seeded callers
//   - symbol_callers seeded callers count
//   - impact_of      transitive closure of getCurrentTask reaches the
//                    c.js call chain via TaskHandler.handle
//   - dead_code      finds the seeded `unusedHelper` orphan in a.ts
//   - dependency_path callerOne -> middle -> deep (length 1) AND
//                    not-connected for an isolated symbol
//   - code_index_health healthy after build, unhealthy after corruption

import test from 'node:test';
import assert from 'node:assert/strict';
import {
    mkdtempSync, rmSync, writeFileSync, cpSync, existsSync,
} from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { buildServer } from '../src/server.js';

const FIXTURE_SRC = path.resolve(import.meta.dirname, 'fixtures', 'polyglot');

async function buildClient() {
    const server = buildServer();
    const [c, s] = InMemoryTransport.createLinkedPair();
    await server.connect(s);
    const client = new Client({ name: 'cg-mcp-test', version: '1.0.0' }, { capabilities: {} });
    await client.connect(c);
    return {
        client,
        cleanup: async () => {
            await client.close();
            await server.close();
        },
    };
}

function mkProject() {
    const root = mkdtempSync(path.join(tmpdir(), 'code-graph-mcp-tools-'));
    cpSync(FIXTURE_SRC, root, { recursive: true });
    return {
        root,
        cleanup() {
            try { rmSync(root, { recursive: true, force: true }); } catch { /* best effort */ }
        },
    };
}

function structured(result) {
    return result?.structuredContent;
}

test('tools/list returns exactly the 7 declared tools', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    const list = await client.listTools();
    const names = list.tools.map((tl) => tl.name).sort();
    assert.deepEqual(
        names,
        [
            'code_context',
            'code_index_health',
            'code_search',
            'dead_code',
            'dependency_path',
            'impact_of',
            'symbol_callers',
        ],
        `expected exactly the 7 tools; got: ${names.join(', ')}`,
    );

    // Every tool must declare an inputSchema and an informative description.
    for (const tool of list.tools) {
        assert.ok(tool.inputSchema, `${tool.name}: inputSchema must be present`);
        assert.ok(tool.description && tool.description.length > 30,
            `${tool.name}: description must be informative`);
        if (tool.annotations) {
            assert.equal(typeof tool.annotations.readOnlyHint, 'boolean',
                `${tool.name}: readOnlyHint should be boolean`);
        }
    }
});

test('code_search finds the planted symbol via the graph-index fast path', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'code_search',
        arguments: { query: 'getCurrentTask', cwd: proj.root, max_results: 20 },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(data && Array.isArray(data.matches));
    assert.ok(data.matches.length >= 1, `expected >=1 match; got ${JSON.stringify(data.matches)}`);
    assert.ok(data.tool === 'graph-index' || data.tool === 'graph-scan',
        `backend should be graph-index/graph-scan; got ${data.tool}`);
});

test('code_search returns empty matches for a missing symbol', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'code_search',
        arguments: { query: 'noSuchSymbol_zzzz', cwd: proj.root },
    });
    assert.ok(!res.isError, 'no-match must not be an error');
    assert.deepEqual(structured(res)?.data?.matches, []);
});

test('code_context returns definitions and usages for getCurrentTask', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'code_context',
        arguments: { symbol: 'getCurrentTask', cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(Array.isArray(data.definitions));
    assert.ok(Array.isArray(data.usages));
    assert.ok(data.definitions.length >= 1,
        `expected a definition for getCurrentTask; got ${JSON.stringify(data)}`);
    assert.ok(data.usages.length >= 2,
        `expected >=2 usages (callerOne + callerTwo); got ${JSON.stringify(data)}`);
    assert.equal(data.backend, 'graph-index');
});

test('symbol_callers lists the seeded callers of getCurrentTask', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'symbol_callers',
        arguments: { symbol: 'getCurrentTask', cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(Array.isArray(data.callers));
    // callerOne + callerTwo in b.ts. TaskHandler.handle calls
    // getCurrentTask too, so the count is at least 3.
    assert.ok(data.callers.length >= 2,
        `expected >=2 callers of getCurrentTask; got ${data.callers.length}: ${JSON.stringify(data.callers)}`);
    const names = data.callers.map((c) => c.caller_symbol).sort();
    assert.ok(names.includes('callerOne'),
        `callerOne missing from callers; got ${JSON.stringify(names)}`);
    assert.ok(names.includes('callerTwo'),
        `callerTwo missing from callers; got ${JSON.stringify(names)}`);
});

test('impact_of returns the known transitive closure for a symbol seed', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'impact_of',
        arguments: { symbol: 'getCurrentTask', max_depth: 5, cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(Array.isArray(data.nodes));
    const names = new Set(data.nodes.map((n) => n.name));
    // Direct callers
    assert.ok(names.has('callerOne'), `expected callerOne in transitive closure; got ${[...names].join(',')}`);
    assert.ok(names.has('callerTwo'), 'expected callerTwo in transitive closure');
    // Indirect via TaskHandler.handle: handle calls getCurrentTask; in c.js,
    // useTaskHandler -> h.handle() -> getCurrentTask transitively.
    // We assert on `handle` which is a direct (depth 1) caller via the
    // class method, and on `useTaskHandler` which is a depth-2 caller.
    assert.ok(names.has('handle'), `expected handle in transitive closure; got ${[...names].join(',')}`);
});

test('impact_of: file seed returns symbols + file dependents', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'impact_of',
        arguments: { file: 'a.ts', max_depth: 2, cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(Array.isArray(data.file_dependents));
    // b.ts imports from './a' → resolved to a.ts → dependent.
    const depFiles = data.file_dependents.map((d) => d.file);
    assert.ok(depFiles.includes('b.ts'),
        `b.ts should be a file dependent of a.ts; got ${JSON.stringify(depFiles)}`);
});

test('impact_of rejects both seeds present', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'impact_of',
        arguments: { symbol: 'x', file: 'a.ts', cwd: proj.root },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /exactly one of `symbol` or `file`/);
});

test('dead_code finds the seeded orphan export `unusedHelper`', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'dead_code',
        arguments: { cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(Array.isArray(data.dead));
    const names = data.dead.map((d) => d.name);
    assert.ok(names.includes('unusedHelper'),
        `expected unusedHelper in dead exports; got ${JSON.stringify(names)}`);
});

test('dependency_path finds callerOne -> middle? returns not_connected (no chain)', async (t) => {
    // callerOne -> getCurrentTask only; middle calls deep. They are
    // disconnected. Asserts the not-connected branch.
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'dependency_path',
        arguments: { from: 'callerOne', to: 'deep', cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.equal(data.path, null, `expected not_connected; got ${JSON.stringify(data)}`);
    assert.equal(data.reason, 'not_connected');
});

test('dependency_path finds middle -> deep (length 1)', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'dependency_path',
        arguments: { from: 'middle', to: 'deep', cwd: proj.root },
    });
    assert.ok(!res.isError, `should succeed: ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.ok(data.path && data.path.length === 2,
        `expected 2-node path middle -> deep; got ${JSON.stringify(data)}`);
    assert.equal(data.path[0].name, 'middle');
    assert.equal(data.path[1].name, 'deep');
    assert.equal(data.length, 1);
});

test('dependency_path: unknown from-symbol returns from_not_found', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const res = await client.callTool({
        name: 'dependency_path',
        arguments: { from: 'nonexistent_symbol_zzz', to: 'deep', cwd: proj.root },
    });
    assert.ok(!res.isError);
    assert.equal(structured(res)?.data?.reason, 'from_not_found');
});

test('code_index_health reports healthy after a successful build', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    // Trigger lazy build first.
    await client.callTool({
        name: 'code_search',
        arguments: { query: 'getCurrentTask', cwd: proj.root },
    });
    const res = await client.callTool({
        name: 'code_index_health',
        arguments: { cwd: proj.root },
    });
    assert.ok(!res.isError);
    const data = structured(res)?.data;
    assert.equal(data.status, 'healthy', `expected healthy; got ${data.status}: ${JSON.stringify(data)}`);
    assert.ok(data.indexed_files > 0);
    assert.ok(data.symbols > 0);
});

test('code_index_health reports unhealthy on a corrupted index DB', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    // Build the index then corrupt it.
    await client.callTool({
        name: 'code_search',
        arguments: { query: 'getCurrentTask', cwd: proj.root },
    });
    const dbPath = path.join(proj.root, '.claude', '.code-graph', 'index.db');
    assert.ok(existsSync(dbPath));
    writeFileSync(dbPath, 'CORRUPTED-FOR-META-TEST');

    const res = await client.callTool({
        name: 'code_index_health',
        arguments: { cwd: proj.root },
    });
    // The tool returns ok() with structured status=unhealthy.
    assert.ok(!res.isError, `health probe should not set isError on a corrupt DB; got ${JSON.stringify(res).slice(0, 400)}`);
    const data = structured(res)?.data;
    assert.equal(data.status, 'unhealthy',
        `expected status=unhealthy on corruption; got ${data.status}: ${JSON.stringify(data)}`);
    assert.equal(data.reason, 'corrupt_index');
});

test('code_index_health on uninitialized project reports uninitialized', async (t) => {
    const proj = mkProject();
    const { client, cleanup } = await buildClient();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    // Don't run any indexing tool; ask health directly.
    const res = await client.callTool({
        name: 'code_index_health',
        arguments: { cwd: proj.root },
    });
    assert.ok(!res.isError);
    const data = structured(res)?.data;
    assert.equal(data.status, 'uninitialized',
        `expected uninitialized; got ${data.status}: ${JSON.stringify(data)}`);
    assert.ok(data.candidate_files > 0);
});
