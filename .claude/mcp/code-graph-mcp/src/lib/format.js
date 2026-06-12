// format.js — CallToolResult shapers for code-graph-mcp.
//
// Mirrors bd-mcp/format.js and code-context-mcp/format.js. ok() and fail()
// build CallToolResult objects with both content[] (text) and
// structuredContent (typed payload). Every payload carries an
// `llm_observations` free-form field (principle 9 in the v3 plan).

import { CodeGraphError, formatCodeGraphError } from './errors.js';

export function ok(headline, data, observations) {
    const body = data === undefined ? null : data;
    const json = body === null ? '' : JSON.stringify(body, null, 2);
    const obs = observations ? `\n\nllm_observations: ${observations}` : '';
    const text = json
        ? `${headline}\n\n${json}${obs}`
        : `${headline}${obs}`;
    return {
        content: [{ type: 'text', text }],
        structuredContent: {
            ok: true,
            headline,
            data: body,
            llm_observations: observations || null,
        },
    };
}

export function fail(err, hint) {
    const message = err instanceof CodeGraphError
        ? formatCodeGraphError(err)
        : typeof err === 'string'
            ? err
            : (err && err.message) || String(err);
    const fullText = hint ? `${message}\n\nadditional hint: ${hint}` : message;
    return {
        content: [{ type: 'text', text: fullText }],
        isError: true,
        structuredContent: {
            ok: false,
            error: err instanceof CodeGraphError ? {
                message: err.message,
                code: err.code,
                stderr: err.stderr,
                hint: err.hint,
                example: err.example,
            } : { message: (err && err.message) || String(err) },
        },
    };
}

/**
 * Wrap an async tool body so any thrown error becomes a fail() result.
 * The MCP SDK would otherwise surface unhandled promise rejections as an
 * opaque "internal error" — this gives the LLM a structured envelope
 * including the hint string.
 */
export function safe(fn) {
    return async (args, extra) => {
        try {
            return await fn(args, extra);
        } catch (err) {
            return fail(err);
        }
    };
}
