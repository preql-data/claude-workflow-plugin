// Trivial passing test so QA's `npm test` has a real green to confirm.
// The fixture prompt may add more tests; this baseline guarantees the
// happy-path harness run isn't gated by a vacuous "0 tests run" result.

import { describe, it, expect } from "vitest";
import { createApp } from "./index.js";

describe("server bootstrap", () => {
    it("creates an app instance", () => {
        const app = createApp();
        expect(typeof app.listen).toBe("function");
    });
});
