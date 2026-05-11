// code_search.js — `code_search(query, max_results=10)` MCP tool.
//
// Behaviour:
//   1. If `rg` (ripgrep) is on PATH, use `rg --json -m <max> -- <query>`
//      and parse its JSONL output. ripgrep's --json gives us file/line/
//      column/match-text in a structured way.
//   2. Else, if cwd is a git repo, use `git grep -n -- <query>` and
//      parse the line-prefixed output.
//   3. Else, fall back to a slow `grep -rn` over the cwd (final
//      resort; most projects will have git or rg).
//
// The query is treated as a fixed string for ripgrep; pass
// `regex_safe=true` to get fixed-string semantics on git grep too. We
// default to fixed-string because the orchestrator typically searches
// for symbols, not regex.

import { z } from 'zod';
import {
    runCmd,
    resolveCwd,
    isGitRepo,
    hasRipgrep,
    hasGit,
    validateQuery,
    CodeContextError,
} from '../lib/exec.js';
import { ok, fail, safe } from '../lib/format.js';

/**
 * Parse `rg --json` output into match objects.
 *
 * Each line is a JSON document. We only care about `type: "match"` lines.
 */
function parseRgJsonl(stdout, maxResults) {
    const out = [];
    for (const line of stdout.split('\n')) {
        if (!line) continue;
        if (out.length >= maxResults) break;
        try {
            const evt = JSON.parse(line);
            if (evt.type !== 'match') continue;
            const file = evt.data?.path?.text;
            const lineNo = evt.data?.line_number;
            const text = evt.data?.lines?.text || '';
            if (!file || lineNo === undefined) continue;
            out.push({
                file,
                line: lineNo,
                snippet: text.replace(/\n$/, '').slice(0, 300),
            });
        } catch {
            // skip malformed JSON line
        }
    }
    return out;
}

/**
 * Parse `git grep -n` output into match objects.
 */
function parseGitGrep(stdout, maxResults) {
    const out = [];
    for (const line of stdout.split('\n')) {
        if (!line) continue;
        if (out.length >= maxResults) break;
        // Format: <file>:<lineno>:<text>
        const m = line.match(/^([^:]+):(\d+):(.*)$/);
        if (!m) continue;
        out.push({
            file: m[1],
            line: parseInt(m[2], 10),
            snippet: m[3].slice(0, 300),
        });
    }
    return out;
}

export function registerSearchTools(server) {
    server.registerTool(
        'code_search',
        {
            title: 'Search code in the current project',
            description:
                "Find a string or pattern in the project's source files. Uses ripgrep (`rg`) when available, " +
                "otherwise `git grep`, otherwise a slow filesystem scan. Returns up to `max_results` matches " +
                "as { file, line, snippet } objects.\n\n" +
                "Use this when you need to know where a function, constant, error message, or string literal " +
                "lives in the codebase. The orchestrator pre-loads relevant call sites with this tool before " +
                "delegating implementation, so the specialist doesn't have to re-discover them.",
            inputSchema: {
                query: z.string().min(1).max(1024)
                    .describe("Search string. Treated as fixed text by default; pass regex=true for regex semantics."),
                max_results: z.number().int().min(1).max(200).optional()
                    .describe("Maximum results to return. Default: 10. Cap: 200."),
                regex: z.boolean().optional()
                    .describe("If true, treat query as a regex. Default: false (fixed-string)."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CODE_CONTEXT_CWD env)."),
            },
            annotations: {
                title: 'Search code',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const query = validateQuery(input.query);
            const maxResults = input.max_results ?? 10;
            const useRegex = input.regex === true;
            const cwd = resolveCwd({ cwd: input.cwd });

            // Try ripgrep first.
            if (await hasRipgrep()) {
                const args = [
                    '--json',
                    '-m', String(maxResults),
                ];
                if (!useRegex) args.push('-F');  // fixed-string
                args.push('--', query);
                const { stdout, stderr, code } = await runCmd('rg', args, { cwd: input.cwd });
                if (code !== 0 && code !== 1) {
                    return fail(new CodeContextError(`rg returned exit ${code}`, {
                        stderr,
                        hint: "Falls through to git grep on the next attempt; if you keep seeing this, run `rg` manually to see what's wrong.",
                    }));
                }
                const matches = parseRgJsonl(stdout, maxResults);
                return ok(
                    `code_search via rg: ${matches.length} match(es) for ${JSON.stringify(query)}`,
                    { tool: 'rg', query, regex: useRegex, max_results: maxResults, matches },
                    matches.length === 0
                        ? "No matches. Try broadening the query, removing case sensitivity (rg is case-sensitive by default), or running code_index_health() to confirm the project is searchable."
                        : null,
                );
            }

            // Fallback: git grep.
            if (await hasGit() && isGitRepo(cwd)) {
                const args = ['grep', '-n'];
                if (!useRegex) args.push('-F');
                args.push('-e', query, '--');  // -e is safer than positional pattern
                const { stdout, stderr, code } = await runCmd('git', args, { cwd: input.cwd });
                if (code !== 0 && code !== 1) {
                    return fail(new CodeContextError(`git grep returned exit ${code}`, {
                        stderr,
                        hint: "Run `git grep` manually in the project to see what's failing.",
                    }));
                }
                const matches = parseGitGrep(stdout, maxResults);
                return ok(
                    `code_search via git grep: ${matches.length} match(es) for ${JSON.stringify(query)}`,
                    { tool: 'git-grep', query, regex: useRegex, max_results: maxResults, matches },
                    matches.length === 0
                        ? "No matches. Try broadening the query."
                        : "Tip: install ripgrep (`rg`) for faster searches and richer match data.",
                );
            }

            // Final fallback: filesystem grep. Slow on large trees; we cap
            // the depth conservatively.
            const args = [
                '-rn',
                '--include', '*',
                '--exclude-dir', '.git',
                '--exclude-dir', 'node_modules',
                '--exclude-dir', 'dist',
                '--exclude-dir', 'build',
                '--exclude-dir', 'target',
                '--exclude-dir', '__pycache__',
            ];
            if (!useRegex) args.push('-F');
            args.push('-e', query, '.');
            const { stdout, stderr, code } = await runCmd('grep', args, { cwd: input.cwd });
            if (code !== 0 && code !== 1) {
                return fail(new CodeContextError(
                    `grep -rn returned exit ${code}; cwd is not a git repo, ripgrep is missing, and grep itself failed`,
                    {
                        stderr,
                        hint: "Either install ripgrep (`rg`), or `git init` the project, or pick a real project directory via the cwd parameter.",
                    },
                ));
            }
            const matches = parseGitGrep(stdout, maxResults);
            return ok(
                `code_search via plain grep: ${matches.length} match(es) for ${JSON.stringify(query)}`,
                { tool: 'grep', query, regex: useRegex, max_results: maxResults, matches },
                "Plain grep is the slowest backend. Install ripgrep (`rg`) or work in a git repo for faster searches.",
            );
        }),
    );
}
