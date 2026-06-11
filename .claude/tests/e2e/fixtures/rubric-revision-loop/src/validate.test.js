// Baseline test so vitest has something green to anchor against when QA
// runs the suite at the gate. The prompt deliberately omits tests for
// the new validateEmail helper — that omission is what makes the
// default rubric's C2 ("tests added exercise user behavior") fail on
// the first grading pass, kicking off the rubric revision loop.

import { describe, it, expect } from "vitest";
import { normalize } from "./validate.js";

describe("normalize", () => {
    it("trims and lowercases string input", () => {
        expect(normalize("  Foo  ")).toBe("foo");
    });
    it("returns empty string for non-string input", () => {
        expect(normalize(null)).toBe("");
        expect(normalize(undefined)).toBe("");
        expect(normalize(42)).toBe("");
    });
});
