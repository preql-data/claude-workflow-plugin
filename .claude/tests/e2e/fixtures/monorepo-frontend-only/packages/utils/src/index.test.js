// Smoke tests for @fixture/utils. Each helper has one small case so
// the package's `npm test` resolves to passing on a clean baseline.
import { describe, it, expect } from "vitest";
import { delay, clamp } from "./index.js";

describe("@fixture/utils", () => {
    it("delay returns a thenable", () => {
        const promise = delay(0);
        expect(typeof promise.then).toBe("function");
    });

    it("clamp bounds n to [lo, hi]", () => {
        expect(clamp(5, 0, 10)).toBe(5);
        expect(clamp(-1, 0, 10)).toBe(0);
        expect(clamp(99, 0, 10)).toBe(10);
    });
});
