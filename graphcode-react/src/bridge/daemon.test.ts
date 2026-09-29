import { describe, expect, it } from "vitest";
import { daemonBridgeError } from "./daemon";

describe("daemonBridgeError", () => {
  it("decodes production Tauri command rejection strings", () => {
    expect(
      daemonBridgeError(
        "graphcoded refused the command (transcriptInvalidCursor): source changed",
      ),
    ).toMatchObject({
      code: "transcriptInvalidCursor",
      message: "source changed",
    });
  });

  it("preserves structured bridge errors when available", () => {
    expect(
      daemonBridgeError({
        code: "transcriptUnauthorized",
        message: "not joined",
      }),
    ).toMatchObject({
      code: "transcriptUnauthorized",
      message: "not joined",
    });
  });

  it("keeps unrelated failures generic", () => {
    expect(daemonBridgeError(new Error("socket closed"))).toMatchObject({
      code: "daemonUnavailable",
      message: "socket closed",
    });
  });
});
