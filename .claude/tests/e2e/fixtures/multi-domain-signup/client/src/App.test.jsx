// Baseline client smoke test. After SignupForm lands, additional
// cases (form submits, error states, success redirect) will be added.
import { describe, it, expect } from "vitest";
import App from "./App.jsx";

describe("App stub", () => {
    it("is a React component (function)", () => {
        expect(typeof App).toBe("function");
    });
});
