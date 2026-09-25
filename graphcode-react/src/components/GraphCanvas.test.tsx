import { describe, expect, it } from "vitest";
import type { LoopNode } from "../protocol/domain";
import { buildGraphLayout } from "./GraphCanvas";

const nodes: LoopNode[] = [
  { id: "a", title: "A", state: "idle" },
  { id: "b", title: "B", state: "idle" },
  { id: "c", title: "C", state: "idle" },
];

describe("graph layout", () => {
  it("places dependencies in later layers and preserves every node", () => {
    const layout = buildGraphLayout(nodes, [
      { from: "a", to: "b" },
      { from: "a", to: "c" },
    ]);

    expect(layout.positions.size).toBe(3);
    expect(layout.positions.get("b")!.x).toBeGreaterThan(
      layout.positions.get("a")!.x,
    );
    expect(layout.positions.get("c")!.y).toBeGreaterThan(
      layout.positions.get("b")!.y,
    );
  });

  it("still lays out nodes participating in a cycle", () => {
    const layout = buildGraphLayout(nodes.slice(0, 2), [
      { from: "a", to: "b" },
      { from: "b", to: "a" },
    ]);

    expect(layout.positions.size).toBe(2);
    expect(layout.width).toBeGreaterThan(0);
  });
});
