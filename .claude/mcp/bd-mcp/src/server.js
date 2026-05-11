// server.js — MCP server entry point for bd-mcp.
//
// Wires the registerXxxTools() functions onto an McpServer and connects
// the StdioServerTransport. Claude Code launches this binary via .mcp.json:
//
//   {
//     "mcpServers": {
//       "bd": {
//         "type": "stdio",
//         "command": "node",
//         "args": ["${CLAUDE_PLUGIN_ROOT}/.claude/mcp/bd-mcp/bin/bd-mcp.js"],
//         "env": {}
//       }
//     }
//   }
//
// The launcher is bin/bd-mcp.js; it import()s this module so the entry
// point is consistent whether the server is invoked via node, npx, or the
// package's bin field.

import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StdioServerTransport } from '@modelcontextprotocol/sdk/server/stdio.js';

import { registerCreateTools } from './tools/bd_create.js';
import { registerListTools } from './tools/bd_list.js';
import { registerUpdateTools } from './tools/bd_update.js';
import { registerLabelTools } from './tools/bd_label.js';
import { registerCommentTools } from './tools/bd_comment.js';
import { registerDepTools } from './tools/bd_dep.js';
import { registerDocTools } from './tools/bd_doc.js';
import { registerQaTools } from './tools/bd_qa.js';

// We accept the package version via process.env.npm_package_version when
// launched via npm scripts, and fall back to a literal otherwise.
const PKG_NAME = 'bd-mcp';
const PKG_VERSION = process.env.npm_package_version || '1.0.0';

/**
 * Build a McpServer with every bd-mcp tool registered. Exported so tests
 * can construct an in-process server and exercise tools directly without
 * spinning up a stdio transport.
 */
export function buildServer() {
    const server = new McpServer({
        name: PKG_NAME,
        version: PKG_VERSION,
    });

    registerCreateTools(server);
    registerListTools(server);
    registerUpdateTools(server);
    registerLabelTools(server);
    registerCommentTools(server);
    registerDepTools(server);
    registerDocTools(server);
    registerQaTools(server);

    return server;
}

/**
 * Main: connect a stdio transport. Errors are written to stderr so the
 * Claude Code MCP launch logs surface them.
 */
async function main() {
    const server = buildServer();
    const transport = new StdioServerTransport();
    await server.connect(transport);
    // The transport keeps the process alive until stdin closes.
}

// Only run main() when invoked as a script. When imported by tests, the
// caller drives buildServer() directly.
const isDirectInvocation =
    import.meta.url === `file://${process.argv[1]}` ||
    process.argv[1]?.endsWith('bd-mcp.js') ||
    process.argv[1]?.endsWith('server.js');

if (isDirectInvocation) {
    main().catch((err) => {
        process.stderr.write(`bd-mcp: server crashed: ${err && err.stack ? err.stack : err}\n`);
        process.exit(1);
    });
}
