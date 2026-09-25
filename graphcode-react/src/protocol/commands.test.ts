import { describe, expect, it } from "vitest";
import { stopNodeCommand } from "./commands";

describe("daemon commands", () => {
  it("encodes stopNode with Swift Codable's single-value wrapper", () => {
    expect(
      stopNodeCommand(
        "C:\\work\\graph",
        "11111111-1111-4111-8111-111111111111",
      ),
    ).toEqual({
      graphCommand: {
        projectPath: "C:\\work\\graph",
        command: {
          stopNode: { _0: "11111111-1111-4111-8111-111111111111" },
        },
      },
    });
  });
});
