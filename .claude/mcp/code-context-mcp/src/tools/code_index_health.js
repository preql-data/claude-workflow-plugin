// code_index_health.js — `code_index_health()` MCP tool.
//
// Sanity check the project the MCP server is running against. We answer:
//   - Is the cwd resolvable?
//   - Is it a git repo?
//   - Is ripgrep available? Is git available?
//   - Roughly how many tracked files exist (so the orchestrator knows the
//     project is non-empty before paying for a code_search)?
//
// Returns a structured report; never throws unless the cwd itself is
// unreadable (catastrophic).

import { z } from 'zod';
import {
    runCmd,
    resolveCwd,
    isGitRepo,
    hasRipgrep,
    hasGit,
    CodeContextError,
} from '../lib/exec.js';
import { ok, fail, safe } from '../lib/format.js';
import { existsSync, statSync, readdirSync } from 'node:fs';
import path from 'node:path';

/**
 * Cheap upper-bound estimate of file count under cwd, for a no-git
 * fallback. We walk at most depth=3 and cap at 1000 entries to keep
 * this fast on huge trees.
 */
function approximateFileCount(cwd, maxDepth = 3, cap = 1000) {
    const stack = [{ dir: cwd, depth: 0 }];
    let count = 0;
    while (stack.length > 0 && count < cap) {
        const { dir, depth } = stack.pop();
        let entries;
        try {
            entries = readdirSync(dir, { withFileTypes: true });
        } catch {
            continue;
        }
        for (const entry of entries) {
            if (count >= cap) break;
            // Skip standard noise.
            if (entry.name === '.git' || entry.name === 'node_modules' ||
                entry.name === 'dist' || entry.name === 'build' ||
                entry.name === 'target' || entry.name === '__pycache__') continue;
            const full = path.join(dir, entry.name);
            if (entry.isDirectory() && depth < maxDepth) {
                stack.push({ dir: full, depth: depth + 1 });
            } else if (entry.isFile()) {
                count++;
            }
        }
    }
    return { count, capped: count >= cap };
}

export function registerHealthTools(server) {
    server.registerTool(
        'code_index_health',
        {
            title: 'Check code-context environment health',
            description:
                "Sanity-check the project the MCP is operating against. Reports whether the cwd is " +
                "resolvable, whether git and ripgrep are available, and roughly how many tracked files " +
                "exist. Run this once at the start of a session to confirm code_search and code_context " +
                "will work; do not call it in a hot loop.",
            inputSchema: {
                cwd: z.string().optional()
                    .describe("Working directory to check (overrides CODE_CONTEXT_CWD env)."),
            },
            annotations: {
                title: 'Health check',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: false,
            },
        },
        safe(async (input) => {
            let cwd;
            try {
                cwd = resolveCwd({ cwd: input.cwd });
            } catch (err) {
                return fail(err);
            }
            if (!existsSync(cwd)) {
                return fail(
                    new CodeContextError(`cwd not found: ${cwd}`, {
                        hint: "Pass an existing directory via the cwd parameter, or set CODE_CONTEXT_CWD / CLAUDE_PROJECT_DIR.",
                    }),
                );
            }
            let isDir;
            try {
                isDir = statSync(cwd).isDirectory();
            } catch (err) {
                return fail(new CodeContextError(`cwd is not stat-able: ${err.message}`, { hint: "Permission issue?" }));
            }
            if (!isDir) {
                return fail(new CodeContextError(`cwd is not a directory: ${cwd}`, {}));
            }

            const gitAvail = await hasGit();
            const rgAvail = await hasRipgrep();
            const isGit = gitAvail && isGitRepo(cwd);

            // File count: from `git ls-files` if it's a git repo, else
            // approximate via filesystem walk.
            let trackedFiles = null;
            let approxFiles = null;
            if (isGit) {
                try {
                    const { stdout } = await runCmd('git', ['ls-files'], { cwd: input.cwd });
                    trackedFiles = stdout.split('\n').filter(Boolean).length;
                } catch {
                    /* ignore — git ls-files should not fail in a git repo, but be defensive */
                }
            }
            if (trackedFiles === null) {
                approxFiles = approximateFileCount(cwd);
            }

            const observations = [];
            if (!gitAvail) observations.push("git is not on PATH; code_context falls back to ripgrep or plain grep.");
            if (!rgAvail) observations.push("ripgrep (`rg`) is not on PATH; code_search will use git grep or plain grep, which may be slower.");
            if (!isGit && !gitAvail) {
                observations.push("Not a git repo and no git CLI — searches are filesystem-walk only and will be slow on large trees.");
            } else if (!isGit) {
                observations.push("cwd is not a git repo (no .git/). `git init` and commit your code for word-boundary symbol lookups.");
            }
            if (trackedFiles === 0) {
                observations.push("git ls-files returned no tracked files. Did you forget to `git add`?");
            }

            const data = {
                cwd,
                git_available: gitAvail,
                ripgrep_available: rgAvail,
                is_git_repo: isGit,
                tracked_files: trackedFiles,
                approximate_files: approxFiles,
            };

            return ok(
                `code_index_health: cwd=${path.basename(cwd)}, git=${gitAvail ? 'yes' : 'no'}, rg=${rgAvail ? 'yes' : 'no'}, repo=${isGit ? 'yes' : 'no'}` +
                    (trackedFiles !== null ? `, tracked_files=${trackedFiles}` : '') +
                    (approxFiles !== null ? `, approx_files=${approxFiles.count}${approxFiles.capped ? '+' : ''}` : ''),
                data,
                observations.length > 0 ? observations.join(' ') : "Healthy: code_search and code_context should work optimally.",
            );
        }),
    );
}
