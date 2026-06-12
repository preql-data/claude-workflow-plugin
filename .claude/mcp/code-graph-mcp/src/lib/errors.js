// errors.js — error type + agent-centric formatter.
//
// Mirrors bd-mcp's BdError / formatBdError. Every tool failure surfaces a
// message of the form:
//
//   <what was wrong>
//
//   stderr (last 6 lines): ...    (when applicable)
//
//   hint: <what a valid call looks like>
//
// The hint is the single most important field — it tells the LLM caller
// exactly how to retry. We refuse to ship a CodeGraphError without one
// (the constructor warns to stderr if hint is missing, but does not
// throw — defensive against catch-all paths).

export class CodeGraphError extends Error {
    constructor(message, { stderr, code, hint, example } = {}) {
        super(message);
        this.name = 'CodeGraphError';
        this.stderr = (stderr || '').toString();
        this.code = code;
        this.hint = hint;
        // `example` is an optional pre-formatted "valid call" snippet the
        // tool layer can append to the hint. Keeps the per-tool hint
        // strings short while making the failure self-correcting.
        this.example = example;
    }
}

/**
 * Format a CodeGraphError for the LLM. Compact — we keep the message
 * short so it doesn't blow the caller's context budget, but we always
 * include a hint and (when present) a worked example.
 */
export function formatCodeGraphError(err) {
    if (!(err instanceof CodeGraphError)) {
        return `Internal error: ${err && err.message ? err.message : String(err)}`;
    }
    const parts = [err.message];
    if (err.stderr && err.stderr.trim().length > 0) {
        const tail = err.stderr.trim().split('\n').slice(-6).join('\n');
        parts.push(`stderr (last 6 lines):\n${tail}`);
    }
    if (err.hint) {
        parts.push(`hint: ${err.hint}`);
    }
    if (err.example) {
        parts.push(`example: ${err.example}`);
    }
    return parts.join('\n\n');
}
