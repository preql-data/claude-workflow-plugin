// validate.js — input validators with agent-centric error messages.
//
// Three primary validators, used by every tool that takes user-controlled
// arguments. All of them throw CodeGraphError on failure with both `hint`
// (what to do) and `example` (a worked call). The Zod schema in each
// tool catches type/shape problems first; these validators handle
// semantic constraints (length caps, character classes, path safety).

import { CodeGraphError } from './errors.js';

/**
 * Validate a search query. Non-empty, capped at 1024 chars, no NUL byte
 * (which corrupts argv handling).
 */
export function validateQuery(raw, label = 'query') {
    if (typeof raw !== 'string') {
        throw new CodeGraphError(`${label} must be a string`, {
            hint: "Pass a literal string or regex pattern.",
            example: 'code_search({query: "getCurrentTask"})',
        });
    }
    if (raw.length === 0) {
        throw new CodeGraphError(`${label} is empty`, {
            hint: "1..1024 chars; the query must contain at least one character.",
            example: 'code_search({query: "TODO"})',
        });
    }
    if (raw.length > 1024) {
        throw new CodeGraphError(`${label} is too long (${raw.length} > 1024 chars)`, {
            hint: "Narrow the search instead of pasting whole files; the index is for symbol-lookup, not text search of multi-paragraph strings.",
            example: 'code_search({query: "exports.getCurrentTask"})',
        });
    }
    if (raw.indexOf('\0') !== -1) {
        throw new CodeGraphError(`${label} contains a NUL byte`, {
            hint: "Strip embedded NULs before passing.",
            example: 'code_search({query: "myFunction"})',
        });
    }
    return raw;
}

/**
 * Validate a symbol name. Stricter than validateQuery — must look like a
 * code identifier so that we can plug it into our `name` index without
 * triggering wildcard matches. Mirrors code-context-mcp's SYMBOL_RE,
 * widened slightly to allow common method-access patterns
 * (`Module.method`) and dashed package names.
 */
const SYMBOL_RE = /^[A-Za-z_$][A-Za-z0-9_$.-]{0,255}$/;
export function validateSymbol(raw, label = 'symbol') {
    if (typeof raw !== 'string') {
        throw new CodeGraphError(`${label} must be a string`, {
            hint: "Pass a code identifier like 'getCurrentTask' or 'MyClass'.",
            example: 'code_context({symbol: "getCurrentTask"})',
        });
    }
    const trimmed = raw.trim();
    if (trimmed.length === 0) {
        throw new CodeGraphError(`${label} is empty`, {
            hint: "Symbols are non-empty identifiers; whitespace is not a symbol.",
            example: 'symbol_callers({symbol: "handleLogin"})',
        });
    }
    if (trimmed.length > 256) {
        throw new CodeGraphError(`${label} is too long (${trimmed.length} > 256 chars)`, {
            hint: "Identifiers are short — if you're passing a long path, you probably meant impact_of({file: ...}) instead.",
            example: 'symbol_callers({symbol: "handleLogin"})',
        });
    }
    if (!SYMBOL_RE.test(trimmed)) {
        throw new CodeGraphError(`${label} contains invalid characters: ${JSON.stringify(trimmed.slice(0, 64))}`, {
            hint: "Identifiers contain only [A-Za-z0-9_$.-] and start with a letter, '_', or '$'. Use code_search() for free-form pattern matches.",
            example: 'code_context({symbol: "handle_login"})',
        });
    }
    return trimmed;
}

/**
 * Validate a "scope" or "file" path that the caller wants us to look
 * inside. Path safety: no NUL, length cap, MUST be a relative-style
 * path (no leading "/", no "..", no Windows drive letters) so a
 * malicious caller cannot scope us to e.g. /etc/. The index itself
 * holds only paths relative to the project root, so this constraint is
 * also what the SQL queries expect.
 */
export function validateScopePath(raw, label = 'scope') {
    if (raw === undefined || raw === null || raw === '') {
        // Empty scope = whole project. Caller checks for this.
        return '';
    }
    if (typeof raw !== 'string') {
        throw new CodeGraphError(`${label} must be a string`, {
            hint: "Pass a project-relative path prefix like 'src/' or 'server/lib/'.",
            example: 'dead_code({scope: "src/"})',
        });
    }
    if (raw.length > 1024) {
        throw new CodeGraphError(`${label} is too long`, {
            hint: "Scopes are path prefixes; project paths are not multi-KB strings.",
            example: 'dead_code({scope: "src/auth/"})',
        });
    }
    if (raw.indexOf('\0') !== -1) {
        throw new CodeGraphError(`${label} contains a NUL byte`, {
            hint: "Strip embedded NULs before passing.",
            example: 'dead_code({scope: "src/"})',
        });
    }
    // Disallow absolute paths and parent-dir traversal. The index keys
    // every file by its repo-relative path; an absolute or ".." prefix
    // can't ever match.
    if (raw.startsWith('/') || raw.startsWith('\\') || /^[A-Za-z]:/.test(raw)) {
        throw new CodeGraphError(`${label} must be a project-relative path, not absolute: ${JSON.stringify(raw)}`, {
            hint: "Paths in the index are project-relative (no leading slash, no drive letter). Strip the leading separator.",
            example: 'dead_code({scope: "src/"})',
        });
    }
    if (raw.split(/[\\/]/).includes('..')) {
        throw new CodeGraphError(`${label} contains '..' — path traversal not allowed`, {
            hint: "Only forward-pointing prefixes. The whole project is the default scope; pick a subdirectory.",
            example: 'dead_code({scope: "src/"})',
        });
    }
    return raw;
}

/**
 * Validate a depth cap. Bounded sensibly so a malicious caller cannot
 * trigger O(N^2) graph traversal across the whole repo. 0 means
 * "direct only"; the cap of 50 is high enough for any real callgraph.
 */
export function validateDepth(raw, label = 'max_depth') {
    if (raw === undefined || raw === null) {
        return 5;  // default: 5 hops is usually enough for "what does this break"
    }
    if (typeof raw !== 'number' || !Number.isInteger(raw)) {
        throw new CodeGraphError(`${label} must be an integer`, {
            hint: "Pass an integer 0..50. 0 = direct callers only, 5 = sensible default.",
            example: 'impact_of({symbol: "handleLogin", max_depth: 3})',
        });
    }
    if (raw < 0 || raw > 50) {
        throw new CodeGraphError(`${label} must be between 0 and 50 (got ${raw})`, {
            hint: "0 = direct only; 50 is the hard cap to keep traversal bounded.",
            example: 'impact_of({symbol: "handleLogin", max_depth: 5})',
        });
    }
    return raw;
}
