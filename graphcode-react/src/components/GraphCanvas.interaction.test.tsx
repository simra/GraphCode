// @vitest-environment jsdom

import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it } from "vitest";
import type { LoopGraph } from "../protocol/domain";
import { GraphCanvas, type Viewport } from "./GraphCanvas";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const graph: LoopGraph = {
  id: "graph",
  project: { name: "Project", path: "C:\\project" },
  nodes: [{ id: "a", title: "A", state: "idle" }],
  edges: [],
};

function pointerEvent(
  type: string,
  pointerId: number,
  clientX: number,
  clientY: number,
) {
  const event = new MouseEvent(type, {
    bubbles: true,
    button: 0,
    clientX,
    clientY,
  });
  Object.defineProperties(event, {
    pointerId: { value: pointerId },
    pointerType: { value: "touch" },
  });
  return event;
}

function Harness() {
  const [viewport, setViewport] = useState<Viewport>({
    x: 0,
    y: 0,
    width: 900,
    height: 420,
  });
  return (
    <GraphCanvas
      graph={graph}
      initialViewport={viewport}
      layoutReady
      viewportKey={"C:\\project\0root"}
      onViewportChange={setViewport}
    />
  );
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("GraphCanvas gestures", () => {
  it("keeps an active pinch gesture alive when persistence echoes viewport changes", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<Harness />);
    });

    const svg = container.querySelector("svg")!;
    Object.defineProperties(svg, {
      clientWidth: { value: 900 },
      clientHeight: { value: 420 },
      setPointerCapture: { value: () => undefined },
      releasePointerCapture: { value: () => undefined },
      hasPointerCapture: { value: () => true },
      getBoundingClientRect: {
        value: () => ({
          x: 0,
          y: 0,
          left: 0,
          top: 0,
          right: 900,
          bottom: 420,
          width: 900,
          height: 420,
          toJSON: () => undefined,
        }),
      },
    });

    await act(async () => {
      svg.dispatchEvent(pointerEvent("pointerdown", 1, 300, 210));
      svg.dispatchEvent(pointerEvent("pointerdown", 2, 600, 210));
      svg.dispatchEvent(pointerEvent("pointermove", 2, 700, 210));
    });
    const firstWidth = Number(svg.getAttribute("viewBox")!.split(" ")[2]);

    await act(async () => {
      svg.dispatchEvent(pointerEvent("pointermove", 2, 800, 210));
    });
    const secondWidth = Number(svg.getAttribute("viewBox")!.split(" ")[2]);

    expect(secondWidth).toBeLessThan(firstWidth);

    await act(async () => {
      root.unmount();
    });
  });
});
