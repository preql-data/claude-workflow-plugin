// Smoke test for the @fixture/app entry. Confirms the consumer
// resolves @fixture/ui's barrel.
import { describe, it, expect } from "vitest";
import App from "./index.js";

describe("@fixture/app", () => {
    it("App resolves a Button reference from @fixture/ui", () => {
        expect(typeof App).toBe("function");
        expect(App()).toBeDefined();
    });
});
