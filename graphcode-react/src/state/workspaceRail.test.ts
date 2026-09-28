import { describe, expect, it } from "vitest";
import type { LoopNode, SummaryBeat } from "../protocol/domain";
import {
  boardIsDrawable,
  presentLoopSummary,
  summaryUnseenCount,
} from "./workspaceRail";

const beats: SummaryBeat[] = [
  {
    id: "beat-1",
    at: "2026-09-28T10:00:00Z",
    pass: 1,
    kind: "reading",
    text: "Read the current implementation",
    endsTurn: false,
  },
  {
    id: "beat-2",
    at: "2026-09-28T10:01:00Z",
    pass: 1,
    kind: "editing",
    text: "Added the workspace rail",
    endsTurn: false,
  },
];

describe("workspace rail presentation", () => {
  it("tracks unseen beats across updates", () => {
    expect(summaryUnseenCount(beats, "beat-1")).toBe(1);
    expect(summaryUnseenCount(beats, "missing")).toBe(2);
    expect(summaryUnseenCount([], "beat-1")).toBe(0);
  });

  it("presents current, receding, pass, and attention state", () => {
    const node: LoopNode = {
      id: "loop",
      title: "Build rail",
      state: { running: {} },
      presence: { presence: "awaitingInput" },
      summary: {
        beats,
        passes: [{ pass: 1, text: "Mapped the current UI", delta: "+4 files" }],
        currentPass: 2,
      },
    };

    expect(presentLoopSummary(node, "beat-1")).toMatchObject({
      mode: "asking",
      current: beats[1],
      receding: [beats[0]],
      unseen: 1,
      pass: 1,
    });
  });

  it("accepts only useful supported board forms", () => {
    const node: LoopNode = {
      id: "loop",
      title: "Build rail",
      state: "running",
      board: {
        form: "flow",
        direction: "topDown",
        title: "Plan",
        nodes: [
          { id: "a", text: "Inspect", shape: "box" },
          { id: "b", text: "Implement", shape: "rounded" },
        ],
        edges: [{ from: "a", to: "b", style: "solid" }],
        source: "flowchart TD",
        pass: 1,
      },
    };
    expect(boardIsDrawable(node)).toBe(true);
    expect(
      boardIsDrawable({
        ...node,
        board: { ...node.board!, nodes: node.board!.nodes.slice(0, 1) },
      }),
    ).toBe(false);
  });
});
