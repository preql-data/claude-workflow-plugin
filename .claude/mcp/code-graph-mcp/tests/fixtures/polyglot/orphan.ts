// orphan.ts — seeded ORPHAN export the dead_code test asserts on.
// Nothing in the fixture imports this file or its symbols, so
// unusedHelper is unambiguously dead by the static graph.

export function unusedHelper(): number {
    return 0;
}
