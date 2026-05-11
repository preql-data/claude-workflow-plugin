#!/usr/bin/env node
// code-context-mcp launcher.
//
// .mcp.json wires this binary into Claude Code:
//
//   "code-context": {
//     "type": "stdio",
//     "command": "node",
//     "args": ["${CLAUDE_PLUGIN_ROOT}/.claude/mcp/code-context-mcp/bin/code-context-mcp.js"],
//     "env": {}
//   }
//
// We import the server module rather than running it inline so the entry
// point is consistent across `node ./bin/...`, `npm start`, and direct
// import from tests.

import('../src/server.js').catch((err) => {
    process.stderr.write(`code-context-mcp launcher error: ${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
});
