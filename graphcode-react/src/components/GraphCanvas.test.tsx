import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { LoopNode } from "../protocol/domain";
import {
  adjacentNodeId,
  applyNodePositions,
  buildGraphLayout,
  edgeTargetAtPoint,
  GraphCanvas,
  zoomedViewport,
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

  it("moves to the nearest node in the requested spatial direction", () => {
    const positions = new Map([
      ["center", { x: 100, y: 100 }],
      ["right-near", { x: 200, y: 110 }],
      ["right-far", { x: 200, y: 300 }],
      ["down", { x: 90, y: 240 }],
    ]);

    expect(adjacentNodeId("center", "right", positions)).toBe("right-near");
    expect(adjacentNodeId("center", "down", positions)).toBe("down");
    expect(adjacentNodeId("center", "left", positions)).toBeUndefined();
  });

  it("applies saved node positions and expands the layout bounds", () => {
    const automatic = buildGraphLayout(nodes.slice(0, 2), []);
    const positioned = applyNodePositions(automatic, nodes.slice(0, 2), {
      a: { x: 1200, y: 800 },
      removed: { x: 5000, y: 5000 },
    });

    expect(positioned.positions.get("a")).toEqual({ x: 1200, y: 800 });
    expect(positioned.positions.has("removed")).toBe(false);
    expect(positioned.width).toBeGreaterThan(1200);
    expect(positioned.height).toBeGreaterThan(800);
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

  it("keeps the graph point beneath the pointer fixed while zooming", () => {
    const viewport = { x: 0, y: 0, width: 1000, height: 500 };
    const anchor = { x: 250, y: 100 };
    const zoomed = zoomedViewport(viewport, 2, 100, 4000, anchor);

    expect(zoomed).toEqual({
      x: 125,
      y: 50,
      width: 500,
      height: 250,
    });
    expect((anchor.x - zoomed.x) / zoomed.width).toBe(0.25);
    expect((anchor.y - zoomed.y) / zoomed.height).toBe(0.2);
  });

  it("supports a moved pinch midpoint without changing its graph anchor", () => {
    const viewport = { x: 0, y: 0, width: 1000, height: 500 };
    const anchor = { x: 500, y: 250 };
    const zoomed = zoomedViewport(viewport, 2, 100, 4000, anchor, {
      x: 0.6,
      y: 0.4,
    });

    expect(zoomed.x + zoomed.width * 0.6).toBe(anchor.x);
    expect(zoomed.y + zoomed.height * 0.4).toBe(anchor.y);
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
    expect(markup).toContain("Arrow keys move between nearby loops");
    expect(markup).toContain("Alt+Arrow repositions a loop");
    expect(markup).toContain("aria-keyshortcuts=");
  });
});
