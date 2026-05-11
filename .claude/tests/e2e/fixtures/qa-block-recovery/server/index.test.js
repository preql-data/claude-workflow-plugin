// Bootstrap smoke test — kept separate from validate.test.js so the
// baseline always passes even when the seeded broken test fails.
import { describe, it, expect } from "vitest";
import { createApp } from "./index.js";

describe("server bootstrap", () => {
    it("creates an app instance", () => {
        const app = createApp();
        expect(typeof app.listen).toBe("function");
    });
});
