import { describe, expect, it } from "vitest";
import { edgeSpecFromSnapshot } from "./edgeSpec";

describe("edge spec snapshot conversion", () => {
  it("preserves every daemon-owned specification field and ignores runtime count", () => {
    expect(
      edgeSpecFromSnapshot({
        id: "edge",
        from: "source",
        to: "target",
        kind: "spawn",
        condition: { onFailure: {} },
        payloadTransform: { script: { _0: "emit.ps1" } },
        cycleGuard: {
          maxIterations: 5,
          until: "Test-Path done",
          stopAfterPassesWithoutImprovement: 2,
        },
        spawnTargetProjectPath: "C:\\other",
        fireCount: 19,
      }),
    ).toEqual({
      kind: "spawn",
      condition: "onFailure",
      payloadTransform: { script: { _0: "emit.ps1" } },
      cycleGuard: {
        maxIterations: 5,
        until: "Test-Path done",
        stopAfterPassesWithoutImprovement: 2,
      },
      spawnTargetProjectPath: "C:\\other",
    });
  });
});
