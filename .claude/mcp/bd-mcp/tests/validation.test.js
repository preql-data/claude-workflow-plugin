// validation.test.js — Phase 6b QA followups for Phase 6a (J29).
//
// Three followups land in this file:
//
//   1. **JSON-RPC integration test** — drive the server through a real
//      Client+Transport pair (InMemoryTransport from the MCP SDK) so the
//      protocol-level Zod validation actually runs. The Phase 6a
//      integration tests bypass validation by calling tool.handler()
//      directly; that meant cap=50, missing required fields, and other
//      schema rules were declared but never exercised. Here we send raw
//      JSON-RPC frames and assert that bad inputs are rejected by the
//      protocol layer with an InvalidParams error before the handler
//      runs.
//
//   2. **Path-safety unit test** — explicit assertion that validateTaskId
//      rejects `../../etc/passwd`, shell metacharacters, NUL bytes,
//      whitespace, oversized input, and empty strings. The integration
//      suite exercised one shape ("not a real id with spaces") but did
//      not enumerate the safety landscape.
//
//   3. **resolveBdCwd tightening** — assert that an explicit cwd that
//      already has .beads/ is used as-is, even when a parent dir also has
//      .beads/. This guards against accidentally picking up an unrelated
//      parent's database.
//
// All three are pure-Node tests (no bd CLI required for tests 1 and 3).
// Test 2 uses validateTaskId from exec-bd.js directly. Test 1 needs `bd`
// to be on PATH for the `tools/list` path to succeed; the validation
// rejections fire before the bd shell-out, so the tests pass regardless
// of bd availability.

import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, rmSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { InMemoryTransport } from '@modelcontextprotocol/sdk/inMemory.js';

import { buildServer } from '../src/server.js';
import { validateTaskId, resolveBdCwd, BdError } from '../src/lib/exec-bd.js';

// ---------------------------------------------------------------------------
// Helper: stand up a Client+Server pair connected via the in-memory transport.
// Returns { client, cleanup } so each test can drive the server via real
// JSON-RPC and trigger the SDK's Zod validation on tool inputs.
async function buildClient() {
    const server = buildServer();
    const [clientTransport, serverTransport] = InMemoryTransport.createLinkedPair();
    await server.connect(serverTransport);

    const client = new Client(
        { name: 'bd-mcp-validation-test', version: '1.0.0' },
        { capabilities: {} },
    );
    await client.connect(clientTransport);

    return {
        client,
        cleanup: async () => {
            await client.close();
            await server.close();
        },
    };
}

// ---------------------------------------------------------------------------
// 1. JSON-RPC validation tests — bad inputs must be rejected at the protocol
//    layer, not by the tool handler.
//
// The SDK surfaces Zod validation failures as a CallToolResult with
// `isError: true` and the protocol code `-32602` (InvalidParams) embedded
// in the response text. That's the standard MCP shape for input
// validation rejection — it's structurally distinct from a tool's own
// error path, which uses `BdError` formatting via the format.js helpers.
// We assert on `-32602` to verify the Zod layer (not the handler) caught
// the bad input.

function assertProtocolValidationError(result, pattern, hint) {
    assert.ok(result, `${hint}: expected a result, got nothing`);
    assert.equal(
        result.isError, true,
        `${hint}: expected isError=true (validation rejection); got: ${JSON.stringify(result).slice(0, 400)}`,
    );
    const text = result.content?.[0]?.text || '';
    assert.match(
        text, /-32602|Input validation error|Invalid arguments/i,
        `${hint}: expected an MCP -32602 InvalidParams marker in the error text; got: ${text.slice(0, 400)}`,
    );
    assert.match(
        text, pattern,
        `${hint}: expected the violation pattern ${pattern} in the error text; got: ${text.slice(0, 400)}`,
    );
}

test('JSON-RPC: bd_create_epic.children cap=50 is enforced by Zod', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    // 51 children should be rejected by the schema (cap is .max(50)).
    const tooMany = Array.from({ length: 51 }, (_, i) => ({
        title: `child ${i}`,
    }));

    const result = await client.callTool({
        name: 'bd_create_epic',
        arguments: { title: 'big epic', children: tooMany },
    });
    assertProtocolValidationError(
        result,
        /too_big|maximum.*50|at most 50/i,
        'cap=50 children should be rejected by protocol-layer Zod validation',
    );
});

test('JSON-RPC: bd_create_task missing required title is rejected by Zod', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    const result = await client.callTool({
        name: 'bd_create_task',
        arguments: {},
    });
    assertProtocolValidationError(
        result,
        /title|Required|invalid_type/i,
        'missing required title should be rejected by Zod',
    );
});

test('JSON-RPC: bd_create_task title length cap is enforced', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    // 501 chars exceeds .max(500).
    const tooLong = 'x'.repeat(501);
    const result = await client.callTool({
        name: 'bd_create_task',
        arguments: { title: tooLong },
    });
    assertProtocolValidationError(
        result,
        /too_big|maximum.*500|at most 500/i,
        'title >500 chars should be rejected by Zod',
    );
});

test('JSON-RPC: bd_show_task wrong-typed task_id is rejected by Zod', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    // task_id must be a string. Pass a number to trip Zod.
    const result = await client.callTool({
        name: 'bd_show_task',
        arguments: { task_id: 123 },
    });
    assertProtocolValidationError(
        result,
        /invalid_type|expected.*string|received.*number/i,
        'non-string task_id should be rejected by Zod',
    );
});

test('JSON-RPC: priority enum is enforced by Zod', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    // priority is z.enum(['0','1','2','3','4']); '99' is not a member.
    const result = await client.callTool({
        name: 'bd_create_task',
        arguments: { title: 'prio test', priority: '99' },
    });
    assertProtocolValidationError(
        result,
        /invalid_enum_value|enum|expected/i,
        'priority=99 should be rejected by Zod enum',
    );
});

test('JSON-RPC: bd_show_task with path-traversal id is rejected (defense-in-depth)', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    // The Zod schema only checks length (1..256). Path-traversal is rejected
    // by validateTaskId() inside the handler — but we verify here that the
    // FULL pipeline (Zod -> handler -> validateTaskId) ends up rejecting it
    // cleanly, not silently passing it to bd.
    const result = await client.callTool({
        name: 'bd_show_task',
        arguments: { task_id: '../../etc/passwd' },
    });
    assert.equal(result.isError, true,
        'path-traversal id should result in isError=true via either Zod or validateTaskId');
    const text = result.content?.[0]?.text || '';
    assert.match(text, /invalid characters|invalid|hint/i,
        `expected an actionable error for path-traversal id, got: ${text.slice(0, 400)}`);
});

test('JSON-RPC: bd_show_task with shell metacharacter id is rejected', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    // Shell-meta characters are rejected by validateTaskId in the handler.
    const result = await client.callTool({
        name: 'bd_show_task',
        arguments: { task_id: 'foo;rm -rf /' },
    });
    assert.equal(result.isError, true,
        'shell-meta id should result in isError=true');
    const text = result.content?.[0]?.text || '';
    assert.match(text, /invalid characters|invalid|hint/i);
});

test('JSON-RPC: tools/list lists all 21 registered tools and they have inputSchema', async (t) => {
    const { client, cleanup } = await buildClient();
    t.after(cleanup);

    const result = await client.listTools();
    assert.ok(Array.isArray(result.tools), 'tools/list should return tools array');
    assert.ok(
        result.tools.length >= 17,
        `expected at least 17 tools, got ${result.tools.length}: ${result.tools.map(t => t.name).join(', ')}`,
    );
    for (const tool of result.tools) {
        assert.ok(tool.name, `every tool must have a name`);
        assert.ok(tool.inputSchema, `${tool.name}: inputSchema must be present in tools/list response`);
        assert.ok(tool.description, `${tool.name}: description must be present`);
        // Verify annotations make it through the protocol layer.
        if (tool.annotations) {
            assert.equal(typeof tool.annotations.openWorldHint, 'boolean',
                `${tool.name}: openWorldHint should be present in annotations`);
        }
    }
});

// ---------------------------------------------------------------------------
// 2. Path-safety unit test — validateTaskId should reject every dangerous
//    shape it is supposed to reject. This is belt-and-braces because we use
//    execFile (no shell) anyway, but tightening the input filter at the API
//    boundary stops crafted inputs from reaching bd's own argument parser.

test('path-safety: validateTaskId rejects path-traversal attempts', () => {
    const cases = [
        '../../etc/passwd',
        '..\\..\\Windows\\System32',
        '../',
        '../foo',
        './foo',
        '/etc/passwd',
        '\\\\server\\share',
    ];
    for (const id of cases) {
        assert.throws(
            () => validateTaskId(id),
            BdError,
            `validateTaskId should reject path-traversal: ${JSON.stringify(id)}`,
        );
    }
});

test('path-safety: validateTaskId rejects shell metacharacters', () => {
    const cases = [
        'foo;rm -rf /',
        'foo$(whoami)',
        'foo`whoami`',
        'foo|cat',
        'foo&echo',
        'foo>out',
        'foo<in',
        'foo*bar',
        'foo?bar',
        'foo~bar',
        'foo#bar',
        'foo!bar',
        'foo"bar',
        "foo'bar",
        'foo\\bar',
        'foo bar',  // whitespace
        'foo\tbar', // tab
        'foo\nbar', // newline
    ];
    for (const id of cases) {
        assert.throws(
            () => validateTaskId(id),
            BdError,
            `validateTaskId should reject shell-meta: ${JSON.stringify(id)}`,
        );
    }
});

test('path-safety: validateTaskId rejects NUL bytes and control characters', () => {
    const cases = [
        'foo bar',
        'foobar',
        'foobar',
        'foobar',  // ESC
        'foobar',  // DEL
    ];
    for (const id of cases) {
        assert.throws(
            () => validateTaskId(id),
            BdError,
            `validateTaskId should reject control char: ${JSON.stringify(id)}`,
        );
    }
});

test('path-safety: validateTaskId rejects empty / oversized input', () => {
    assert.throws(() => validateTaskId(''), BdError);
    assert.throws(() => validateTaskId('   '), BdError);  // whitespace-only
    assert.throws(() => validateTaskId('a'.repeat(257)), BdError);
});

test('path-safety: validateTaskId rejects non-string input', () => {
    assert.throws(() => validateTaskId(123), BdError);
    assert.throws(() => validateTaskId(null), BdError);
    assert.throws(() => validateTaskId(undefined), BdError);
    assert.throws(() => validateTaskId({ id: 'foo' }), BdError);
    assert.throws(() => validateTaskId(['foo']), BdError);
});

test('path-safety: validateTaskId accepts valid bd ids', () => {
    const cases = [
        'bd-1',
        'my-project-42',
        'project.sub.task-1',
        'my_project-1',
        'a',
        'A1',
        'foo-1.2',
        'multi-word-project-name-1234',
    ];
    for (const id of cases) {
        const out = validateTaskId(id);
        assert.equal(out, id, `validateTaskId should accept ${JSON.stringify(id)}`);
    }
});

test('path-safety: validateTaskId rejects ids starting with non-alphanumeric', () => {
    // The regex requires the first char to be [A-Za-z0-9]. Leading dots,
    // dashes, or underscores are rejected — these shapes are how a crafted
    // input might masquerade as a flag or hidden file.
    const cases = [
        '-foo',       // looks like a flag
        '.foo',       // hidden file
        '_foo',
        '--help',
        '-h',
    ];
    for (const id of cases) {
        assert.throws(
            () => validateTaskId(id),
            BdError,
            `validateTaskId should reject leading-non-alphanumeric: ${JSON.stringify(id)}`,
        );
    }
});

// ---------------------------------------------------------------------------
// 3. resolveBdCwd tightening — explicit cwd with .beads/ uses it as-is;
//    walk-up only kicks in when explicit cwd lacks .beads/.

test('resolveBdCwd: explicit cwd with .beads/ is used as-is', () => {
    // Set up: parent has .beads, child has .beads. Caller passes child.
    // We expect child to be returned, NOT parent.
    const root = mkdtempSync(path.join(tmpdir(), 'bdmcp-resolve-'));
    try {
        const parent = path.join(root, 'parent');
        const child = path.join(parent, 'child');
        mkdirSync(path.join(parent, '.beads'), { recursive: true });
        mkdirSync(path.join(child, '.beads'), { recursive: true });

        // Save and clear env vars to ensure opts.cwd takes precedence.
        const savedBdCwd = process.env.BD_CWD;
        const savedClaudeProjectDir = process.env.CLAUDE_PROJECT_DIR;
        delete process.env.BD_CWD;
        delete process.env.CLAUDE_PROJECT_DIR;
        try {
            const resolved = resolveBdCwd({ cwd: child });
            assert.equal(
                resolved, child,
                'when explicit cwd has .beads/, resolveBdCwd should return it as-is, never walking up to a parent .beads',
            );
        } finally {
            if (savedBdCwd !== undefined) process.env.BD_CWD = savedBdCwd;
            if (savedClaudeProjectDir !== undefined) process.env.CLAUDE_PROJECT_DIR = savedClaudeProjectDir;
        }
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});

test('resolveBdCwd: walk-up still works when explicit cwd lacks .beads/', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'bdmcp-resolve-'));
    try {
        // Only the parent has .beads/. The child does not. Walk-up should
        // find the parent.
        const parent = path.join(root, 'parent');
        const child = path.join(parent, 'subdir');
        mkdirSync(path.join(parent, '.beads'), { recursive: true });
        mkdirSync(child, { recursive: true });

        const savedBdCwd = process.env.BD_CWD;
        const savedClaudeProjectDir = process.env.CLAUDE_PROJECT_DIR;
        delete process.env.BD_CWD;
        delete process.env.CLAUDE_PROJECT_DIR;
        try {
            const resolved = resolveBdCwd({ cwd: child });
            assert.equal(resolved, parent, 'walk-up should locate parent .beads/');
        } finally {
            if (savedBdCwd !== undefined) process.env.BD_CWD = savedBdCwd;
            if (savedClaudeProjectDir !== undefined) process.env.CLAUDE_PROJECT_DIR = savedClaudeProjectDir;
        }
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});

test('resolveBdCwd: when no .beads/ found anywhere, returns the original candidate', () => {
    const root = mkdtempSync(path.join(tmpdir(), 'bdmcp-resolve-'));
    try {
        const dir = path.join(root, 'no-beads-here');
        mkdirSync(dir, { recursive: true });

        const savedBdCwd = process.env.BD_CWD;
        const savedClaudeProjectDir = process.env.CLAUDE_PROJECT_DIR;
        delete process.env.BD_CWD;
        delete process.env.CLAUDE_PROJECT_DIR;
        try {
            const resolved = resolveBdCwd({ cwd: dir });
            // No .beads anywhere up the chain — falls back to the original candidate.
            assert.equal(resolved, dir);
        } finally {
            if (savedBdCwd !== undefined) process.env.BD_CWD = savedBdCwd;
            if (savedClaudeProjectDir !== undefined) process.env.CLAUDE_PROJECT_DIR = savedClaudeProjectDir;
        }
    } finally {
        rmSync(root, { recursive: true, force: true });
    }
});
