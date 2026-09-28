import { describe, expect, it } from "vitest";
import { decodeNavigationHistory } from "./navigationHistory";

describe("navigation history persistence", () => {
  it("decodes versioned history and clamps an invalid cursor", () => {
    expect(
      decodeNavigationHistory({
        version: 1,
        entries: [{ kind: "quickChats" }],
        cursor: 9,
      }),
    ).toEqual({
      version: 1,
      entries: [{ kind: "quickChats" }],
      cursor: 0,
    });
  });

  it("rejects malformed route payloads", () => {
    expect(() =>
      decodeNavigationHistory({
        version: 1,
        entries: [{ kind: "project", projectPath: "", compositePath: [] }],
        cursor: 0,
      }),
    ).toThrow();
  });
});
