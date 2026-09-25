import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { LoopNode } from "../protocol/domain";
import {
  buildGraphLayout,
  edgeTargetAtPoint,
  GraphCanvas,
} from "./GraphCanvas";

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

  it("resolves pointer edge targets while excluding the source", () => {
    const layout = buildGraphLayout(nodes, []);
    const target = layout.positions.get("b")!;

    expect(
      edgeTargetAtPoint(nodes, layout.positions, "a", {
        x: target.x + 20,
        y: target.y + 20,
      }),
    ).toBe("b");
    expect(
      edgeTargetAtPoint(nodes, layout.positions, "b", {
        x: target.x + 20,
        y: target.y + 20,
      }),
    ).toBeUndefined();
  });

  it("exposes pointer connection handles and describes the keyboard alternative", () => {
    const markup = renderToStaticMarkup(
      <GraphCanvas
        graph={{
          id: "graph",
          project: { name: "Project", path: "C:\\project" },
          nodes,
          edges: [],
        }}
        onCreateEdge={() => undefined}
      />,
    );

    expect(markup).toContain("edge-drag-handle");
    expect(markup).toContain(
      "use New Edge for a keyboard accessible alternative",
    );
  });
});
