// Baseline server smoke test. After signup lands here, additional cases
// (POST /signup happy path, validation errors, conflict on existing
// email) will be added by the @backend specialist.
import { describe, it, expect } from "vitest";
import { createApp } from "./index.js";

describe("server bootstrap", () => {
    it("creates an app instance", () => {
        const app = createApp();
        expect(typeof app.listen).toBe("function");
    });
});
