import { describe, expect, it } from "vitest";
import type { LoopGraph } from "../protocol/domain";
import { attentionItems, attentionSummary, displayState } from "./attention";

const now = Date.parse("2026-09-25T12:00:00Z");

describe("sidebar attention aggregation", () => {
  it("uses presence-corrected state and includes nested loops", () => {
    const graph: LoopGraph = {
      id: "root",
      project: { path: "C:\\project", name: "Project" },
      edges: [],
      nodes: [
        { id: "failed", title: "Failed", state: "failed" },
        {
          id: "asking",
          title: "Needs answer",
          state: "running",
          presence: { presence: "awaitingInput" },
        },
        {
          id: "parent",
          title: "Parent",
          state: "running",
          subGraph: {
            id: "nested",
            project: { path: "C:\\project", name: "Project" },
            edges: [],
            nodes: [{ id: "stalled", title: "Stalled", state: "stalled" }],
          },
        },
      ],
    };

    const items = attentionItems(graph, now);
    expect(items.map(({ reason }) => reason)).toEqual([
      "failed",
      "stalled",
      "awaiting input",
    ]);
    expect(attentionSummary(items)).toBe(
      "3 need attention: 1 failed, 1 stalled, 1 awaiting input",
    );
  });

  it("reports only blocked loops whose handoff cannot still arrive", () => {
    const graph: LoopGraph = {
      id: "root",
      project: { path: "C:\\project", name: "Project" },
      nodes: [
        { id: "done", title: "Done", state: "succeeded" },
        { id: "live", title: "Live", state: "running" },
        { id: "stranded", title: "Stranded", state: "blocked" },
        { id: "waiting", title: "Waiting", state: "blocked" },
      ],
      edges: [
        {
          from: "done",
          to: "stranded",
          kind: "handoff",
          fireCount: 0,
        },
        {
          from: "live",
          to: "waiting",
          kind: "handoff",
          fireCount: 0,
        },
      ],
    };

    expect(attentionItems(graph, now)).toEqual([
      { nodeId: "stranded", nodeTitle: "Stranded", reason: "blocked" },
    ]);
  });

  it("fails an old absent unattended session without guessing for attended loops", () => {
    const old = "2026-09-25T11:58:00Z";
    expect(
      displayState(
        {
          id: "goal",
          title: "Goal",
          loopType: "goalBased",
          state: "running",
          createdAt: old,
          presence: { presence: "absent" },
        },
        now,
      ),
    ).toBe("failed");
    expect(
      displayState(
        {
          id: "turn",
          title: "Turn",
          loopType: "turnBased",
          state: "running",
          createdAt: old,
          presence: { presence: "absent" },
        },
        now,
      ),
    ).toBe("idle");
  });
});
