// Tiny utility module the fixture prompt seeds for revision-loop exercise.
//
// The prompt asks Claude to add an email-validation helper here, and
// explicitly tells the orchestrator NOT to add tests unless review demands
// them. The default rubric's "tests added exercise user behavior" criterion
// (C2) will fail on the first grader pass, triggering the rubric loop
// (needs_revision → specialist iterates → rubric satisfied) the fixture
// is designed to exercise.

/**
 * Returns the trimmed normalized form of the input string.
 *
 * Intentionally pedestrian — the seeded module exists so the prompt has
 * a tangible file to extend, not because the helper itself is interesting.
 *
 * @param {string} value
 * @returns {string}
 */
export function normalize(value) {
    if (typeof value !== "string") {
        return "";
    }
    return value.trim().toLowerCase();
}
