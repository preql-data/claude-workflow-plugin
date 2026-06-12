// server.js — code-graph-mcp entry point.
//
// Boots an McpServer with the 7 graph tools registered, then connects
// stdio for Claude Code to drive it. Lazy build: server boot is
// instant (no parsing, no DB read); the first tool call triggers
// ensureIndex inside its handler. Subsequent tool calls hit the
// already-built index.
//
// Surface, capped at 7 tools (spec):
//   1. code_search          — string/regex search; symbol-index fast path
//   2. code_context         — definitions + usages for a symbol
//   3. symbol_callers       — direct callers (one hop)         [new-stable]
//   4. impact_of            — transitive callers / dependents  [new-stable]
//   5. dead_code            — unreferenced exports in scope    [new-stable]
//   6. dependency_path      — shortest call chain a -> b       [new-stable]
//   7. code_index_health    — status, drift, coverage, db size
//
// code_search, code_context, code_index_health are byte-compatible with
// code-context-mcp on inputs/outputs (the stable surface). The others
// are new-stable per the .mcp.json `_phase7_codebase_graph_target`
// forward-pointer and the verification-suite Phase B spec.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { registerSearchTool } from './tools/code_search.js';
import { registerContextTool } from './tools/code_context.js';
import { registerHealthTool } from './tools/code_index_health.js';
import { registerSymbolCallersTool } from './tools/symbol_callers.js';
import { registerImpactTool } from './tools/impact_of.js';
import { registerDeadCodeTool } from './tools/dead_code.js';
import { registerDependencyPathTool } from './tools/dependency_path.js';

const PKG_NAME = 'code-graph-mcp';
const PKG_VERSION = process.env.npm_package_version || '1.0.0';

/**
 * Build a McpServer with every code-graph tool registered. Exported so
 * tests can construct an in-process server and exercise tools directly
 * without a stdio transport.
 */
export function buildServer() {
    const server = new McpServer({
        name: PKG_NAME,
        version: PKG_VERSION,
    });

    registerSearchTool(server);
    registerContextTool(server);
    registerSymbolCallersTool(server);
    registerImpactTool(server);
    registerDeadCodeTool(server);
    registerDependencyPathTool(server);
    registerHealthTool(server);

    return server;
}

async function main() {
    const server = buildServer();
    const transport = new StdioServerTransport();
    await server.connect(transport);
    // Process stays alive until stdin closes.
}

const isDirectInvocation =
    import.meta.url === `file://${process.argv[1]}` ||
    process.argv[1]?.endsWith('code-graph-mcp.js') ||
    process.argv[1]?.endsWith('server.js');

if (isDirectInvocation) {
    main().catch((err) => {
        process.stderr.write(`code-graph-mcp: server crashed: ${err && err.stack ? err.stack : err}\n`);
        process.exit(1);
    });
}
