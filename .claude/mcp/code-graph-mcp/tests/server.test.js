// server.test.js — protocol-level tests (JSON-RPC envelope, Zod
// validation, error shape, structuredContent + content[] coherence).
// Mirrors bd-mcp/validation.test.js — every input that should be
// rejected by the SDK's Zod layer goes here.

import test from 'node:test';
import assert from 'node:assert/strict';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { buildServer } from '../src/server.js';

async function buildClient() {
    const server = buildServer();
    const [c, s] = InMemoryTransport.createLinkedPair();
    await server.connect(s);
    const client = new Client({ name: 'cg-mcp-proto-test', version: '1.0.0' }, { capabilities: {} });
    await client.connect(c);
    return {
        client,
        cleanup: async () => {
            await client.close();
            await server.close();
        },
    };
}

test('JSON-RPC: code_search rejects oversized query at the Zod layer', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const huge = 'x'.repeat(2000);
    const res = await client.callTool({
        name: 'code_search',
        arguments: { query: huge },
    });
    assert.equal(res.isError, true, 'oversized query must be rejected');
    const text = res.content?.[0]?.text || '';
    // -32602 = MCP InvalidParams; the SDK also surfaces "too_big"/"Invalid"
    // depending on Zod version. Match either.
    assert.match(text, /-32602|too_big|Invalid|maximum/i,
        `expected protocol-layer validation error; got: ${text.slice(0, 200)}`);
});

test('JSON-RPC: code_search rejects non-string query', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const res = await client.callTool({
        name: 'code_search',
        arguments: { query: 123 },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /-32602|invalid_type|expected.*string/i,
        `expected typed validation error; got: ${text.slice(0, 200)}`);
});

test('JSON-RPC: code_context rejects symbol with whitespace at the handler layer', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    // Zod accepts the string; validateSymbol in the handler rejects.
    const res = await client.callTool({
        name: 'code_context',
        arguments: { symbol: 'foo bar' },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /invalid characters|hint/i,
        `expected an actionable error mentioning invalid chars + hint; got: ${text.slice(0, 200)}`);
    assert.match(text, /example/i, 'expected an `example:` line in the error envelope');
});

test('JSON-RPC: impact_of rejects missing seed (neither symbol nor file)', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const res = await client.callTool({
        name: 'impact_of',
        arguments: { max_depth: 3 },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /exactly one of `symbol` or `file`/);
});

test('JSON-RPC: impact_of rejects max_depth > 50', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const res = await client.callTool({
        name: 'impact_of',
        arguments: { symbol: 'foo', max_depth: 500 },
    });
    assert.equal(res.isError, true);
});

test('JSON-RPC: dependency_path requires both from and to', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const res = await client.callTool({
        name: 'dependency_path',
        arguments: { from: 'foo' },
    });
    assert.equal(res.isError, true);
});

test('JSON-RPC: dead_code rejects absolute scope path at the handler layer', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const res = await client.callTool({
        name: 'dead_code',
        arguments: { scope: '/etc/passwd' },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /project-relative|absolute/i);
});

test('JSON-RPC: dead_code rejects ".." traversal at the handler layer', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    const res = await client.callTool({
        name: 'dead_code',
        arguments: { scope: '../../etc' },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /path traversal|\.\./);
});

test('every error result carries a hint AND an example for agent self-correction', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);
    // Trigger a handler-layer error that goes through CodeGraphError.
    const res = await client.callTool({
        name: 'symbol_callers',
        arguments: { symbol: 'has spaces and bad!chars' },
    });
    assert.equal(res.isError, true);
    const text = res.content?.[0]?.text || '';
    assert.match(text, /hint:/, 'error must include hint:');
    assert.match(text, /example:/, 'error must include example:');
});
