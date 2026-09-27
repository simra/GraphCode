// @vitest-environment jsdom

import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { LoopGraph } from "../protocol/domain";
import { GraphCanvas } from "./GraphCanvas";
import { InspectorPane } from "./InspectorPane";
import { NodeInspector } from "./NodeInspector";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const graph: LoopGraph = {
  id: "graph",
  project: { name: "Project", path: "C:\\project" },
  nodes: [{ id: "node", title: "Selected loop", state: "idle" }],
  edges: [],
};

function Harness() {
  const [selectedNodeId, setSelectedNodeId] = useState<string>();
  const node = graph.nodes.find((candidate) => candidate.id === selectedNodeId);
  return (
    <div className="content-layout">
      <GraphCanvas
        graph={graph}
        selectedNodeId={selectedNodeId}
        onSelectNode={setSelectedNodeId}
      />
      <InspectorPane
        selectionKey={node ? `node:${node.id}` : undefined}
        onClose={() => setSelectedNodeId(undefined)}
      >
        <NodeInspector
          graph={graph}
          node={node}
          onClose={() => setSelectedNodeId(undefined)}
        />
      </InspectorPane>
    </div>
  );
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("InspectorPane", () => {
  it("opens the inspector for graph selection without moving graph focus", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<Harness />);
    });
    const graphNode = container.querySelector<SVGGElement>(".graph-node")!;
    graphNode.focus();

    await act(async () => {
      graphNode.dispatchEvent(new MouseEvent("click", { bubbles: true }));
    });

    expect(
      container.querySelector("[data-inspector-state='open']"),
    ).not.toBeNull();
    expect(container.querySelector("#inspector-title")?.textContent).toBe(
      "Selected loop",
    );
    expect(document.activeElement).toBe(graphNode);

    await act(async () => {
      root.unmount();
    });
  });

  it("resets inspector scrolling for a new selection and closes on Escape", async () => {
    const onClose = vi.fn();
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <InspectorPane selectionKey="node:a" onClose={onClose}>
          <div className="inspector-scroll" />
        </InspectorPane>,
      );
    });
    const scrollRegion =
      container.querySelector<HTMLElement>(".inspector-scroll")!;
    scrollRegion.scrollTop = 120;

    await act(async () => {
      root.render(
        <InspectorPane selectionKey="node:b" onClose={onClose}>
          <div className="inspector-scroll" />
        </InspectorPane>,
      );
    });
    expect(scrollRegion.scrollTop).toBe(0);

    document.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
    expect(onClose).toHaveBeenCalledOnce();

    await act(async () => {
      root.unmount();
    });
  });
});
