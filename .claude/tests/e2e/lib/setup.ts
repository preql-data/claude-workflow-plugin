/**
 * Vitest setupFiles entry. Registers the custom Trace matchers globally
 * so every spec can `expect(trace).subagentInvoked(...)` without an
 * import.
 */
import { registerMatchers } from "./assertions.js";

registerMatchers();
