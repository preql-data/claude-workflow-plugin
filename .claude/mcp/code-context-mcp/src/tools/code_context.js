// code_context.js — `code_context(symbol)` MCP tool.
//
// Goal: given a symbol name, return its likely definition site plus a
// few of its usages, so the orchestrator can pre-load call sites before
// delegating to a specialist (and QA can pre-load call sites of changed
// symbols for regression assessment, per J19).
//
// We use `git grep -n -w` (word-boundary, line-numbered) when available;
// it's more accurate than `code_search` for identifier lookups because
// `-w` filters out partial matches. The result is split into:
//
//   { definitions: [...], usages: [...] }
//
// where "definitions" are heuristically detected matches that look like
// a binding (a line with `function`, `class`, `const`, `def`, `fn`,
// `type`, `interface` near the symbol) and "usages" are everything else.
//
// We DO NOT do full-blown semantic analysis. That's the tree-sitter
// version's job; the simpler version trades precision for zero install
// cost and works on any language.

import { z } from 'zod';
import {
    runCmd,
    resolveCwd,
    isGitRepo,
    hasRipgrep,
    hasGit,
    validateSymbol,
    CodeContextError,
} from '../lib/exec.js';
import { ok, fail, safe } from '../lib/format.js';

// Heuristic: a line "looks like" a definition when it contains one of
// these binding keywords reasonably close to the symbol. The check is
// not language-specific — it just matches the patterns that show up
// most often in the wild.
const DEF_KEYWORDS_RE =
    /\b(function|class|const|let|var|def|fn|type|interface|struct|enum|module|impl|trait|public|private|static|async|export\s+(?:default\s+)?(?:async\s+)?(?:function|class|const|let|interface|type)|namespace)\b/;

function classifyLine(snippet) {
    return DEF_KEYWORDS_RE.test(snippet) ? 'definition' : 'usage';
}

function parseGitGrep(stdout) {
    const out = [];
    for (const line of stdout.split('\n')) {
        if (!line) continue;
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

function parseRgJsonl(stdout) {
    const out = [];
    for (const raw of stdout.split('\n')) {
        if (!raw) continue;
        try {
            const evt = JSON.parse(raw);
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
            /* skip */
        }
    }
    return out;
}

export function registerContextTools(server) {
    server.registerTool(
        'code_context',
        {
            title: 'Find definition + usages of a symbol',
            description:
                "Given a symbol name (function, class, constant, variable), return its likely definition " +
                "site(s) and a sample of its usages. Uses `git grep -n -w` for word-boundary matching when " +
                "available; falls back to ripgrep, then plain grep.\n\n" +
                "Returns { definitions: [...], usages: [...] } where each entry is { file, line, snippet }. " +
                "The classification is heuristic (looks for binding keywords like `function`, `class`, " +
                "`const`, `def`, `fn`, `type`, `interface`); for high-precision semantic analysis, swap " +
                "to a tree-sitter-backed Phase 7+ replacement.\n\n" +
                "Use this BEFORE delegating: pre-load the calling context of every symbol the specialist " +
                "will touch, and the QA agent will use the same tool to find regression candidates.",
            inputSchema: {
                symbol: z.string().min(1).max(256)
                    .describe("Code identifier to look up (e.g., 'foo_bar', 'MyClass', 'API_BASE')."),
                max_results: z.number().int().min(1).max(200).optional()
                    .describe("Maximum results across definitions+usages combined. Default: 30."),
                cwd: z.string().optional()
                    .describe("Working directory (overrides CODE_CONTEXT_CWD env)."),
            },
            annotations: {
                title: 'Get symbol context',
                readOnlyHint: true,
                destructiveHint: false,
                idempotentHint: true,
                openWorldHint: true,
            },
        },
        safe(async (input) => {
            const symbol = validateSymbol(input.symbol);
            const maxResults = input.max_results ?? 30;
            const cwd = resolveCwd({ cwd: input.cwd });

            // Strategy: prefer `git grep -n -w` because the -w word-boundary
            // is exactly what we need for identifier lookups. Falls back
            // to ripgrep with --word-regexp.
            let entries = [];
            let backend = 'unknown';

            if (await hasGit() && isGitRepo(cwd)) {
                const args = ['grep', '-n', '-w', '-F', '-e', symbol, '--'];
                const { stdout, stderr, code } = await runCmd('git', args, { cwd: input.cwd });
                if (code !== 0 && code !== 1) {
                    return fail(new CodeContextError(`git grep failed (exit ${code})`, { stderr }));
                }
                entries = parseGitGrep(stdout);
                backend = 'git-grep -w';
            } else if (await hasRipgrep()) {
                const args = ['--json', '--word-regexp', '-F', '--', symbol];
                const { stdout, stderr, code } = await runCmd('rg', args, { cwd: input.cwd });
                if (code !== 0 && code !== 1) {
                    return fail(new CodeContextError(`rg failed (exit ${code})`, { stderr }));
                }
                entries = parseRgJsonl(stdout);
                backend = 'rg --word-regexp';
            } else {
                // Plain grep. -w to match whole-word.
                const args = [
                    '-rn', '-w', '-F',
                    '--exclude-dir', '.git',
                    '--exclude-dir', 'node_modules',
                    '--exclude-dir', 'dist',
                    '--exclude-dir', 'build',
                    '--exclude-dir', 'target',
                    '--exclude-dir', '__pycache__',
                    '-e', symbol,
                    '.',
                ];
                const { stdout, stderr, code } = await runCmd('grep', args, { cwd: input.cwd });
                if (code !== 0 && code !== 1) {
                    return fail(new CodeContextError(`grep failed (exit ${code})`, { stderr }));
                }
                entries = parseGitGrep(stdout);
                backend = 'grep -rwn';
            }

            // Classify and cap.
            const definitions = [];
            const usages = [];
            for (const entry of entries) {
                if (definitions.length + usages.length >= maxResults) break;
                const cls = classifyLine(entry.snippet);
                if (cls === 'definition') {
                    definitions.push(entry);
                } else {
                    usages.push(entry);
                }
            }

            const totalShown = definitions.length + usages.length;
            const truncated = entries.length > totalShown;

            return ok(
                `code_context for ${JSON.stringify(symbol)}: ${definitions.length} definition(s), ${usages.length} usage(s)` +
                    (truncated ? ` (truncated from ${entries.length})` : ''),
                {
                    symbol,
                    backend,
                    max_results: maxResults,
                    definitions,
                    usages,
                    total_matches: entries.length,
                    truncated,
                },
                truncated
                    ? `Showing ${totalShown} of ${entries.length} matches. Increase max_results to see more, or refine the symbol name.`
                    : (totalShown === 0
                        ? "No matches. Verify the symbol name (case matters); try code_search for a looser pattern."
                        : "Definition classification is heuristic — verify by reading the file. For tree-sitter-grade precision, swap this MCP for the Phase 7+ replacement."),
            );
        }),
    );
}
