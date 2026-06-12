#!/usr/bin/env node
// code-graph-mcp launcher.
//
// .mcp.json wires this binary into Claude Code. We import the server
// module rather than running it inline so the entry point is
// consistent across `node ./bin/...`, `npm start`, and direct
// import from tests.

import('../src/server.js').catch((err) => {
    process.stderr.write(`code-graph-mcp launcher error: ${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
});
