// format.js — response shapers for code-context-mcp tools.
//
// Mirrors the shape used by bd-mcp/format.js: ok() and fail() build
// CallToolResult objects with both content[] (text) and structuredContent
// (typed payload). All tools also include an `llm_observations` free-form
// field per principle #9 in the v3 plan.

import { CodeContextError, formatCodeContextError } from './exec.js';

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
    const message = err instanceof CodeContextError
        ? formatCodeContextError(err)
        : typeof err === 'string'
            ? err
            : (err && err.message) || String(err);
    const fullText = hint ? `${message}\n\nadditional hint: ${hint}` : message;
    return {
        content: [{ type: 'text', text: fullText }],
        isError: true,
        structuredContent: {
            ok: false,
            error: err instanceof CodeContextError ? {
                message: err.message,
                code: err.code,
                stderr: err.stderr,
                hint: err.hint,
            } : { message: (err && err.message) || String(err) },
        },
    };
}

export function safe(fn) {
    return async (args, extra) => {
        try {
            return await fn(args, extra);
        } catch (err) {
            return fail(err);
        }
    };
}
