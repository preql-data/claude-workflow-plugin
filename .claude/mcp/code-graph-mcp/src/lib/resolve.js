// resolve.js — cwd + index-path resolution.
//
// Precedence chain mirrors bd-mcp's resolveBdCwd and
// code-context-mcp's resolveCwd:
//
//   1. Explicit opts.cwd from the tool call
//   2. CODE_GRAPH_CWD env (test override; per-process scope)
//   3. CLAUDE_PROJECT_DIR (set by Claude Code; the documented form
//      per spec item 0.1)
//   4. process.cwd() — last resort
//
// The index lives at <project-root>/.claude/.code-graph/index.db. The
// directory is created on first index-write; the path itself is
// returned even when the file does not yet exist so callers can branch
// on existence (lazy-build path).

import path from 'node:path';
import { mkdirSync } from 'node:fs';

export const INDEX_REL_DIR = '.claude/.code-graph';
export const INDEX_FILENAME = 'index.db';

export function resolveProjectRoot(opts = {}) {
    const candidate =
        opts.cwd ||
        process.env.CODE_GRAPH_CWD ||
        process.env.CLAUDE_PROJECT_DIR ||
        process.cwd();
    return path.resolve(candidate);
}

export function indexPath(opts = {}) {
    const root = resolveProjectRoot(opts);
    return path.join(root, INDEX_REL_DIR, INDEX_FILENAME);
}

export function indexDir(opts = {}) {
    const root = resolveProjectRoot(opts);
    return path.join(root, INDEX_REL_DIR);
}

/**
 * Create the index dir on demand. Idempotent. Used by the indexer
 * before the first write; the tool layer doesn't call this directly.
 */
export function ensureIndexDir(opts = {}) {
    const dir = indexDir(opts);
    mkdirSync(dir, { recursive: true });
    return dir;
}
