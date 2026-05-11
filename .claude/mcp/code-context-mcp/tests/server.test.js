// server.test.js — integration tests for code-context-mcp.
//
// Two layers:
//   1. JSON-RPC over an in-memory transport pair: verify tools/list returns
//      our three tools with proper inputSchema + annotations, and that
//      callTool with bad arguments hits Zod validation.
//   2. Direct tool invocation against a temp git repo with a few files
//      exercises the real code_search / code_context / code_index_health
//      paths.

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { buildServer } from '../src/server.js';

// ---------------------------------------------------------------------------
// Helpers

async function buildClient() {
    const server = buildServer();
    const [c, s] = InMemoryTransport.createLinkedPair();
    await server.connect(s);
    const client = new Client({ name: 'cc-mcp-test', version: '1.0.0' }, { capabilities: {} });
    await client.connect(c);
    return {
        client,
        cleanup: async () => {
            await client.close();
            await server.close();
        },
    };
}

function createTempProject() {
    const root = mkdtempSync(path.join(tmpdir(), 'cc-mcp-test-'));
    // git init
    try {
        execFileSync('git', ['init', '-q'], { cwd: root, stdio: 'ignore' });
        execFileSync('git', ['config', 'user.email', 'test@example.com'], { cwd: root, stdio: 'ignore' });
        execFileSync('git', ['config', 'user.name', 'Test'], { cwd: root, stdio: 'ignore' });
    } catch {
        // Continue even if git is missing; some tests can still run on filesystem-walk.
    }
    // Plant a few files with a known symbol.
    writeFileSync(
        path.join(root, 'a.ts'),
        [
            '// a.ts',
            'export function getCurrentTask() {',
            '  return "task-1";',
            '}',
            '',
            'export const SOME_CONSTANT = 42;',
            '',
        ].join('\n'),
    );
    writeFileSync(
        path.join(root, 'b.ts'),
        [
            '// b.ts',
            'import { getCurrentTask } from "./a";',
            '',
            'function callerOne() {',
            '  return getCurrentTask();',
            '}',
            '',
            'function callerTwo() {',
            '  return getCurrentTask();',
            '}',
            '',
        ].join('\n'),
    );
    writeFileSync(
        path.join(root, 'c.py'),
        [
            '# c.py',
            'def get_current_task():',
            '    return "task-2"',
            '',
            'class TaskHelper:',
            '    pass',
            '',
        ].join('\n'),
    );
    // Commit so git ls-files / git grep have something to look at.
    try {
        execFileSync('git', ['add', '-A'], { cwd: root, stdio: 'ignore' });
        execFileSync('git', ['commit', '-q', '-m', 'init'], { cwd: root, stdio: 'ignore' });
    } catch {
        /* fine */
    }
    return {
        cwd: root,
        cleanup() {
            try {
                rmSync(root, { recursive: true, force: true });
            } catch {
                /* best-effort */
            }
        },
    };
}

// ---------------------------------------------------------------------------
// Protocol-layer tests

test('tools/list returns the three code-context tools with annotations', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const result = await client.listTools();
    const names = result.tools.map((t) => t.name).sort();
    assert.deepEqual(
        names,
        ['code_context', 'code_index_health', 'code_search'],
        `expected exactly the three code-context tools; got: ${names.join(', ')}`,
    );
    for (const tool of result.tools) {
        assert.ok(tool.inputSchema, `${tool.name}: inputSchema must be present`);
        assert.ok(tool.description && tool.description.length > 20, `${tool.name}: description must be informative`);
        if (tool.annotations) {
            assert.equal(typeof tool.annotations.openWorldHint, 'boolean',
                `${tool.name}: openWorldHint should be a boolean`);
            assert.equal(typeof tool.annotations.readOnlyHint, 'boolean',
                `${tool.name}: readOnlyHint should be a boolean`);
        }
    }
});

test('JSON-RPC: code_search rejects oversized query via Zod', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const huge = 'x'.repeat(2000);
    const result = await client.callTool({
        name: 'code_search',
        arguments: { query: huge },
    });
    assert.equal(result.isError, true, 'oversized query must be rejected');
    const text = result.content?.[0]?.text || '';
    assert.match(text, /-32602|too_big|Invalid|maximum/i,
        `expected protocol-layer validation error; got: ${text.slice(0, 200)}`);
});

test('JSON-RPC: code_context rejects symbol with whitespace', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    // Zod accepts the string (length is fine); validateSymbol in the handler
    // rejects it because of the space.
    const result = await client.callTool({
        name: 'code_context',
        arguments: { symbol: 'foo bar' },
    });
    assert.equal(result.isError, true);
    const text = result.content?.[0]?.text || '';
    assert.match(text, /invalid characters|hint/i);
});

test('JSON-RPC: code_search rejects non-string query', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const result = await client.callTool({
        name: 'code_search',
        arguments: { query: 123 },
    });
    assert.equal(result.isError, true);
    const text = result.content?.[0]?.text || '';
    assert.match(text, /-32602|invalid_type|expected.*string/i);
});

// ---------------------------------------------------------------------------
// Direct tool invocation against a real temp project.

test('code_index_health reports healthy on a fresh git repo', async (t) => {
    const { client, cleanup } = await buildClient();
    const proj = createTempProject();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const result = await client.callTool({
        name: 'code_index_health',
        arguments: { cwd: proj.cwd },
    });
    assert.ok(!result.isError, `health check should succeed: ${JSON.stringify(result).slice(0, 400)}`);
    const data = result.structuredContent?.data;
    assert.ok(data);
    assert.equal(data.cwd, proj.cwd);
    // git availability is environment-dependent; just assert the field is boolean.
    assert.equal(typeof data.git_available, 'boolean');
    assert.equal(typeof data.ripgrep_available, 'boolean');
    assert.equal(typeof data.is_git_repo, 'boolean');
});

test('code_search finds the planted symbol', async (t) => {
    const { client, cleanup } = await buildClient();
    const proj = createTempProject();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const result = await client.callTool({
        name: 'code_search',
        arguments: { query: 'getCurrentTask', cwd: proj.cwd, max_results: 20 },
    });
    assert.ok(!result.isError, `search should succeed: ${JSON.stringify(result).slice(0, 400)}`);
    const data = result.structuredContent?.data;
    assert.ok(data && Array.isArray(data.matches));
    assert.ok(data.matches.length >= 1, `expected at least one match for getCurrentTask, got: ${JSON.stringify(data.matches)}`);
    // a.ts and b.ts both reference it.
    const files = new Set(data.matches.map((m) => m.file));
    assert.ok(files.has('a.ts') || files.has('./a.ts'), 'a.ts should match');
    assert.ok(files.has('b.ts') || files.has('./b.ts'), 'b.ts should match');
});

test('code_context returns definitions and usages for a symbol', async (t) => {
    const { client, cleanup } = await buildClient();
    const proj = createTempProject();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const result = await client.callTool({
        name: 'code_context',
        arguments: { symbol: 'getCurrentTask', cwd: proj.cwd },
    });
    assert.ok(!result.isError, `context lookup should succeed: ${JSON.stringify(result).slice(0, 400)}`);
    const data = result.structuredContent?.data;
    assert.ok(data);
    assert.ok(Array.isArray(data.definitions));
    assert.ok(Array.isArray(data.usages));
    // The function definition in a.ts begins with "export function" — that
    // line should be classified as a definition.
    assert.ok(
        data.definitions.length >= 1,
        `expected at least one definition match; got definitions=${JSON.stringify(data.definitions)} usages=${JSON.stringify(data.usages)}`,
    );
    // b.ts has at least two usages (callerOne, callerTwo).
    assert.ok(
        data.usages.length >= 2,
        `expected at least two usages; got usages=${JSON.stringify(data.usages)}`,
    );
});

test('code_search returns 0 matches gracefully for unknown symbol', async (t) => {
    const { client, cleanup } = await buildClient();
    const proj = createTempProject();
    t.after(async () => { await cleanup(); proj.cleanup(); });

    const result = await client.callTool({
        name: 'code_search',
        arguments: { query: 'thisDoesNotExist_zzzz', cwd: proj.cwd },
    });
    assert.ok(!result.isError, `search should succeed even on no matches: ${JSON.stringify(result).slice(0, 400)}`);
    const data = result.structuredContent?.data;
    assert.deepEqual(data.matches, []);
});

test('code_index_health on a non-existent cwd returns isError with a hint', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const result = await client.callTool({
        name: 'code_index_health',
        arguments: { cwd: '/nonexistent/path/should/not/exist/zzz' },
    });
    assert.equal(result.isError, true);
    const text = result.content?.[0]?.text || '';
    assert.match(text, /not found|hint/i);
});
