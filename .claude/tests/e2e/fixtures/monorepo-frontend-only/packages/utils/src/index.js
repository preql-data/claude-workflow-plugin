// @fixture/utils — pure helper functions. None of these should be
// touched by the prompt; their presence is here to give the workspace
// realistic multi-package shape so the polyglot detector picks the
// right scope.

export function delay(ms) {
    return new Promise((resolve) => setTimeout(resolve, ms));
}

export function clamp(n, lo, hi) {
    return Math.max(lo, Math.min(hi, n));
}
