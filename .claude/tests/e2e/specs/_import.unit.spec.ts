import { describe, it, expect } from "vitest";
import { runFixture } from "../lib/runFixture.js";

describe("runFixture import surface", () => {
  it("is callable", () => {
    expect(typeof runFixture).toBe("function");
  });

  it("rejects missing fixturePath", async () => {
    await expect(
      runFixture({
        fixturePath: "/nonexistent/path",
        prompt: "x",
        modelSnapshot: "claude-opus-4-7",
      }),
    ).rejects.toThrow(/fixturePath does not exist/i);
  });

  it("rejects missing modelSnapshot", async () => {
    await expect(
      runFixture({
        fixturePath: "/tmp",
        prompt: "x",
        // @ts-expect-error -- explicitly testing the missing-required branch
        modelSnapshot: undefined,
      }),
    ).rejects.toThrow(/modelSnapshot is required/i);
  });
});
