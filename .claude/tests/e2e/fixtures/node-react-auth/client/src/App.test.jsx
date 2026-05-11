// Trivial smoke test for the React stub. Lets QA's `npm test --workspaces`
// resolve to one passing test on the client side too.

import { describe, it, expect } from "vitest";
import App from "./App.jsx";

describe("App stub", () => {
    it("is a React component (function)", () => {
        expect(typeof App).toBe("function");
    });
});
