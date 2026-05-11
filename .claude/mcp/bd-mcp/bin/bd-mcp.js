#!/usr/bin/env node
// Thin launcher so `npx bd-mcp` and the bin entry from package.json both work.
// The actual server lives in src/server.js. We keep the launcher tiny so the
// shipped MCP binary has a stable, documentable entry point.
import('../src/server.js').catch((err) => {
    // Errors here are catastrophic (module load failure). Print to stderr so
    // the parent (Claude Code) can show them in its MCP launch logs.
    process.stderr.write(`bd-mcp: failed to start server: ${err && err.stack ? err.stack : err}\n`);
    process.exit(1);
});
