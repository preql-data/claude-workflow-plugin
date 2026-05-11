// server.js — code-context-mcp entry point (J30, simpler version).
//
// This is the lightweight tree-sitter-FREE alternative described in the v3
// plan: rather than shipping full codebase-graph tooling (heavy parser
// dependencies, language-specific configs), we expose three tools that
// wrap `git grep` (or `rg` when available) so the orchestrator can
// pre-load relevant call sites before delegating.
//
// Tools exposed:
//   - code_search(query, max_results=10)  -> array of {file, line, snippet}
//   - code_context(symbol)                -> definition lines + first-N usages
//   - code_index_health()                 -> sanity report (git? files?)
//
// Why not tree-sitter:
//   The v3 plan offers TWO J30 paths — full codebase-graph (heavy) or this
//   simpler search-based variant. We ship the simpler one to keep the MCP
//   surface tiny and to avoid pinning a tree-sitter version that breaks
//   on Node upgrades. A Phase 7+ migration to tree-sitter is straightforward
//   because the tool surface (search/context/health) is the stable API.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { registerSearchTools } from './tools/code_search.js';
import { registerContextTools } from './tools/code_context.js';
import { registerHealthTools } from './tools/code_index_health.js';

const PKG_NAME = 'code-context-mcp';
const PKG_VERSION = process.env.npm_package_version || '1.0.0';

/**
 * Build a McpServer with every code-context tool registered. Exported so
 * tests can construct an in-process server and exercise tools directly
 * without a stdio transport.
 */
export function buildServer() {
    const server = new McpServer({
        name: PKG_NAME,
        version: PKG_VERSION,
    });

    registerSearchTools(server);
    registerContextTools(server);
    registerHealthTools(server);

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
    process.argv[1]?.endsWith('code-context-mcp.js') ||
    process.argv[1]?.endsWith('server.js');

if (isDirectInvocation) {
    main().catch((err) => {
        process.stderr.write(`code-context-mcp: server crashed: ${err && err.stack ? err.stack : err}\n`);
        process.exit(1);
    });
}
