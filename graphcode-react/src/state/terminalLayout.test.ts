import { describe, expect, it } from "vitest";
import {
  closePane,
  closeTab,
  createTerminalLayout,
  focusRelativePane,
  resizeSplit,
  selectRelativeTab,
  splitFocusedPane,
  type TerminalLayout,
} from "./terminalLayout";

const nodeId = "11111111-1111-4111-8111-111111111111";
const ids = [
  "22222222-2222-4222-8222-222222222222",
  "33333333-3333-4333-8333-333333333333",
  "44444444-4444-4444-8444-444444444444",
];

function split(
  layout: TerminalLayout,
  direction: "horizontal" | "vertical",
  id: string,
) {
  return splitFocusedPane(layout, direction, () => id);
}

describe("terminal layout", () => {
  it("starts with the node session as a stable agent surface", () => {
    const layout = createTerminalLayout(nodeId, () => ids[0]);

    expect(layout.tabs).toHaveLength(1);
    expect(layout.tabs[0].root).toEqual({
      kind: "leaf",
      surface: { id: nodeId, kind: "node" },
    });
    expect(layout.tabs[0].focusedSurfaceId).toBe(nodeId);
  });

  it("splits the focused pane recursively and focuses the addition", () => {
    let layout = createTerminalLayout(nodeId, () => ids[0]);
    layout = split(layout, "horizontal", ids[1]);
    layout = split(layout, "vertical", ids[2]);

    expect(layout.tabs[0].root).toEqual({
      kind: "split",
      id: `split-${ids[1]}`,
      direction: "horizontal",
      sizes: [0.5, 0.5],
      children: [
        { kind: "leaf", surface: { id: nodeId, kind: "node" } },
        {
          kind: "split",
          id: `split-${ids[2]}`,
          direction: "vertical",
          sizes: [0.5, 0.5],
          children: [
            { kind: "leaf", surface: { id: ids[1], kind: "shell" } },
            { kind: "leaf", surface: { id: ids[2], kind: "shell" } },
          ],
        },
      ],
    });
    expect(layout.tabs[0].focusedSurfaceId).toBe(ids[2]);
  });

  it("cycles tabs and panes with wrapping focus", () => {
    let layout = createTerminalLayout(nodeId, () => ids[0]);
    layout = split(layout, "horizontal", ids[1]);
    layout = focusRelativePane(layout, 1);
    expect(layout.tabs[0].focusedSurfaceId).toBe(nodeId);

    layout = closePane(layout, layout.tabs[0].id, ids[1], nodeId);
    layout = {
      ...layout,
      tabs: [
        ...layout.tabs,
        {
          id: ids[2],
          root: {
            kind: "leaf",
            surface: { id: ids[2], kind: "shell" },
          },
          focusedSurfaceId: ids[2],
        },
      ],
    };
    layout = selectRelativeTab(layout, 1);
    expect(layout.selectedTabId).toBe(ids[2]);
    layout = selectRelativeTab(layout, 1);
    expect(layout.selectedTabId).toBe(layout.tabs[0].id);
  });

  it("collapses a split and restores the node when the final shell closes", () => {
    let layout = createTerminalLayout(nodeId, () => ids[0]);
    const tabId = layout.tabs[0].id;
    layout = split(layout, "horizontal", ids[1]);
    layout = closePane(layout, tabId, nodeId, nodeId);

    expect(layout.tabs[0].root).toEqual({
      kind: "leaf",
      surface: { id: ids[1], kind: "shell" },
    });
    expect(layout.tabs[0].focusedSurfaceId).toBe(ids[1]);
    expect(closePane(layout, tabId, ids[1], nodeId).tabs[0]).toMatchObject({
      id: tabId,
      root: {
        kind: "leaf",
        surface: { id: nodeId, kind: "node" },
      },
      focusedSurfaceId: nodeId,
    });
    expect(closeTab(layout, tabId, nodeId).tabs[0]).toMatchObject({
      root: {
        kind: "leaf",
        surface: { id: nodeId, kind: "node" },
      },
      focusedSurfaceId: nodeId,
    });
  });

  it("persists bounded adjacent split sizes", () => {
    let layout = createTerminalLayout(nodeId, () => ids[0]);
    layout = split(layout, "horizontal", ids[1]);
    const splitId = `split-${ids[1]}`;

    layout = resizeSplit(layout, layout.tabs[0].id, splitId, 0, 0.2);
    expect(layout.tabs[0].root.kind).toBe("split");
    if (layout.tabs[0].root.kind !== "split") return;
    expect(layout.tabs[0].root.sizes[0]).toBeCloseTo(0.7);
    expect(layout.tabs[0].root.sizes[1]).toBeCloseTo(0.3);

    layout = resizeSplit(layout, layout.tabs[0].id, splitId, 0, 1);
    expect(layout.tabs[0].root.kind).toBe("split");
    if (layout.tabs[0].root.kind !== "split") return;
    expect(layout.tabs[0].root.sizes[0]).toBeCloseTo(0.9);
    expect(layout.tabs[0].root.sizes[1]).toBeCloseTo(0.1);
  });
});
