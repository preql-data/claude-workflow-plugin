// helpers.js — test support code shared across integration tests.
//
// Spins up a temp `.beads` directory in an OS tmp dir, runs `bd init`, and
// returns a context object with cwd + cleanup hook. Tests pass `cwd:
// ctx.cwd` to every MCP tool call so the bd helper's resolveBdCwd() finds
// the temp tree, not the user's actual project.

import { mkdtempSync, rmSync, existsSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';

const execFileP = promisify(execFile);

/**
 * Create a fresh .beads-initialized scratch directory. Returns:
 *   { cwd, cleanup }  where cleanup() removes the temp tree.
 *
 * Tests can also opt to symlink the project's qa-gate.sh into the temp
 * tree at .claude/scripts/qa-gate.sh so QA tools exercise the real
 * helper rather than the JS fallback. We do that by default — the QA
 * suite specifically tests the qa-gate.sh path.
 */
export async function createTempBeadsRepo({ withQaGate = true, prefix = 'bdmcptest' } = {}) {
    const root = mkdtempSync(path.join(tmpdir(), `${prefix}-`));

    // bd init creates .beads/ in cwd.
    try {
        await execFileP('bd', ['init', '--prefix', 'tst'], {
            cwd: root,
            timeout: 30_000,
        });
    } catch (err) {
        // bd might error with a stderr but still init successfully (e.g.
        // existing dir warnings). If the .beads dir landed, accept it.
        if (!existsSync(path.join(root, '.beads'))) {
            throw new Error(
                `bd init failed in ${root}: ${err.stderr || err.message}`,
            );
        }
    }

    if (withQaGate) {
        // Symlink the real qa-gate.sh into the temp tree's expected location.
        // Using a symlink rather than a copy means we always exercise the
        // current source. Falls back to a copy if symlink isn't supported
        // (rare on the platforms we ship to).
        const dotClaude = path.join(root, '.claude', 'scripts');
        mkdirSync(dotClaude, { recursive: true });
        const dotQaTracking = path.join(root, '.claude', '.qa-tracking');
        mkdirSync(dotQaTracking, { recursive: true });

        const sourceQaGate = findRepoQaGate();
        const sourceCurrentTask = findRepoScript('current-task.sh');
        const target = path.join(dotClaude, 'qa-gate.sh');
        const currentTaskTarget = path.join(dotClaude, 'current-task.sh');

        if (sourceQaGate) {
            try {
                const { symlinkSync } = await import('node:fs');
                symlinkSync(sourceQaGate, target);
            } catch {
                const { copyFileSync, chmodSync } = await import('node:fs');
                copyFileSync(sourceQaGate, target);
                chmodSync(target, 0o755);
            }
        }
        if (sourceCurrentTask) {
            try {
                const { symlinkSync } = await import('node:fs');
                symlinkSync(sourceCurrentTask, currentTaskTarget);
            } catch {
                const { copyFileSync, chmodSync } = await import('node:fs');
                copyFileSync(sourceCurrentTask, currentTaskTarget);
                chmodSync(currentTaskTarget, 0o755);
            }
        }
    }

    return {
        cwd: root,
        cleanup() {
            try {
                rmSync(root, { recursive: true, force: true });
            } catch {
                /* best-effort cleanup */
            }
        },
    };
}

/**
 * Find the in-repo qa-gate.sh by walking up from this file's location to
 * the plugin root and looking under .claude/scripts/.
 */
function findRepoQaGate() {
    return findRepoScript('qa-gate.sh');
}

function findRepoScript(name) {
    // helpers.js -> .claude/mcp/bd-mcp/tests -> .claude/mcp/bd-mcp -> .claude/mcp -> .claude -> repo
    // Walk up from this file until we find .claude/scripts/<name>.
    const here = path.dirname(new URL(import.meta.url).pathname);
    let dir = here;
    for (let i = 0; i < 8; i++) {
        const candidate = path.join(dir, '.claude', 'scripts', name);
        if (existsSync(candidate)) return candidate;
        const parent = path.dirname(dir);
        if (parent === dir) break;
        dir = parent;
    }
    return null;
}

/**
 * Given a tool result (returned by safe()-wrapped handlers), return the
 * structuredContent.data payload. Throws if the result was an error so
 * tests fail loudly with an informative message.
 */
export function expectOk(result, hint = 'tool call should succeed') {
    if (!result || result.isError) {
        const text = result?.content?.[0]?.text || '(no text)';
        throw new Error(`${hint}: ${text}`);
    }
    return result.structuredContent?.data;
}

/**
 * Given a tool result, return the error text. Throws if the result was
 * NOT an error.
 */
export function expectErr(result, hint = 'tool call should fail') {
    if (!result || !result.isError) {
        throw new Error(`${hint}: result was not isError. content=${JSON.stringify(result?.content)}`);
    }
    return result.content?.[0]?.text || '';
}

/**
 * Drive a registered tool by name. Looks up the tool on the McpServer's
 * private _registeredTools map and calls the handler directly with the
 * given args. We bypass the JSON-RPC layer because:
 *   1. The unit tests want to assert on the CallToolResult shape directly.
 *   2. We avoid spinning up a stdio transport + client just for tests.
 */
export async function callTool(server, name, args = {}) {
    const tool = server._registeredTools?.[name];
    if (!tool) {
        throw new Error(`Tool '${name}' not registered`);
    }
    // McpServer (v1.18) stores the user-supplied handler under .handler.
    // We pass args directly to it. The handler expects already-validated
    // input; for tests we trust our own arg construction. Real clients go
    // through the SDK's JSON-RPC layer which runs Zod validation first;
    // none of our tools rely on that validation for safety (the lib/exec-bd
    // layer revalidates ids and shapes).
    if (typeof tool.handler === 'function') {
        return await tool.handler(args, {});
    }
    throw new Error(`Tool '${name}' has no handler`);
}
