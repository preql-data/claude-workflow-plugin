// SEEDED BROKEN TEST (intentional fixture state).
//
// The assertion below is OBVIOUSLY wrong — "foo@bar.com" is a valid
// email by every reasonable definition. A test like this slipping
// through is a classic regression-coverage failure mode: the test
// "passes" against the current stub (validateEmail returns false for
// everything), but the assertion is conceptually inverted.
//
// The QA gate's job (J19, regression-coverage check) is to catch this:
// either by reading the test for plausibility, or by noticing that the
// test still passes after Claude lands real validation logic — meaning
// either the production code is wrong (it returns false on a valid
// email) or the test is wrong (it expects false on a valid email).
// QA should block, surface the wrong assertion, and the recovery path
// lands a corrected test alongside the validation implementation.
//
// DO NOT FIX THIS TEST DURING FIXTURE BUILD. The whole point of the
// fixture is for the harness to EXERCISE the QA recovery flow on it.

import { describe, it, expect } from "vitest";
import { validateEmail, validateName } from "./index.js";

describe("input validation", () => {
    it("validateEmail accepts a well-formed email", () => {
        // BROKEN ASSERTION: should be `.toBe(true)`. The fixture is
        // seeded this way deliberately so QA's gate catches it.
        expect(validateEmail("foo@bar.com")).toBe(false);
    });

    it("validateEmail rejects an empty string", () => {
        expect(validateEmail("")).toBe(false);
    });

    it("validateName accepts a non-empty string", () => {
        // This assertion is conceptually correct but won't pass against
        // the stub (which returns false for everything). It serves as a
        // canary for the recovery path: when Claude lands real logic
        // here, this test should flip from failing to passing.
        expect(validateName("Alice")).toBe(true);
    });
});
