// Smoke test for the existing Button component. Confirms vitest is
// discovering this package's tests. After the refactor a sibling
// RetryButton.test.jsx is expected to exist alongside this file.
import { describe, it, expect } from "vitest";
import Button from "./Button.jsx";

describe("Button stub", () => {
    it("is a function component", () => {
        expect(typeof Button).toBe("function");
    });
});
