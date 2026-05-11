// format.js — response shaping helpers for bd-mcp tools.
//
// Why this lives here:
//   The MCP tool layer wants to return CallToolResult-shaped objects with
//   { content: [...], isError?: boolean, structuredContent?: object }. The
//   per-tool callbacks each end up doing the same wrapping; consolidating
//   it here keeps tools to ~30 lines apiece and makes structured output
//   consistent.
//
// We intentionally include both:
//   - content[]: human/LLM-readable text (the "headline")
//   - structuredContent: the full data object for downstream tooling
//
// Tools also add an `llm_observations` free-form text field (per principle
// #9 in the v3 plan) so specialists can stash whatever didn't fit the
// schema.

import { BdError, formatBdError } from './exec-bd.js';

/**
 * Build a successful CallToolResult.
 *
 * @param {string} headline - one-line human/LLM summary
 * @param {object} [data]   - structured payload (also rendered as JSON in content[])
 * @param {string} [observations] - free-form notes appended after the JSON
 */
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

/**
 * Build a failed CallToolResult. Always sets isError: true so the LLM
 * sees the failure semantics.
 *
 * @param {Error|string} err - BdError preferred, but plain string/Error work too
 * @param {string} [hint]    - extra hint appended after the formatted error
 */
export function fail(err, hint) {
    const message = err instanceof BdError
        ? formatBdError(err)
        : typeof err === 'string'
            ? err
            : (err && err.message) || String(err);
    const fullText = hint ? `${message}\n\nadditional hint: ${hint}` : message;
    return {
        content: [{ type: 'text', text: fullText }],
        isError: true,
        structuredContent: {
            ok: false,
            error: err instanceof BdError ? {
                message: err.message,
                code: err.code,
                stderr: err.stderr,
                hint: err.hint,
            } : { message: (err && err.message) || String(err) },
        },
    };
}

/**
 * Wrap an async tool body so any thrown BdError / Error becomes a fail()
 * result instead of bubbling out of the MCP handler. This guarantees the
 * tool always returns a CallToolResult, never an unhandled promise
 * rejection (which the SDK would surface as an "internal error" on the
 * client side).
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
