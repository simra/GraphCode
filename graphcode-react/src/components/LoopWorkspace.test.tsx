// @vitest-environment jsdom

import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LoopGraph, LoopNode } from "../protocol/domain";
import {
  closePane,
  createTerminalLayout,
  resizeSplit,
  splitFocusedPane,
  type TerminalLayout,
  type TerminalSurface,
} from "../state/terminalLayout";

const bridge = vi.hoisted(() => ({
  acknowledge: vi.fn(async () => undefined),
  close: vi.fn(async () => undefined),
  openTerminal: vi.fn(),
  resize: vi.fn(async () => undefined),
  write: vi.fn(async () => undefined),
  handlers: undefined as
    | {
        onExit(code: number | null): void;
      }
    | undefined,
}));

const xterm = vi.hoisted(() => ({
  dataHandler: undefined as ((data: string) => void) | undefined,
  dispose: vi.fn(),
  focus: vi.fn(),
  instance: undefined as { cols: number; rows: number } | undefined,
  proposedRows: 24,
  resize: vi.fn(),
  writes: [] as Uint8Array[],
}));

vi.mock("../bridge/terminal", () => ({
  openTerminal: bridge.openTerminal,
}));

vi.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    proposeDimensions() {
      return { cols: 112, rows: xterm.proposedRows };
    }
  },
}));

vi.mock("@xterm/xterm", () => ({
  Terminal: class {
    cols = 80;
    rows = 24;
    constructor() {
      xterm.instance = this;
    }
    loadAddon() {}
    open() {}
    focus = xterm.focus;
    dispose = xterm.dispose;
    resize(columns: number, rows: number) {
      this.cols = columns;
      this.rows = rows;
      xterm.resize(columns, rows);
    }
    write(data: Uint8Array, callback?: () => void) {
      xterm.writes.push(data);
      callback?.();
    }
    onData(handler: (data: string) => void) {
      xterm.dataHandler = handler;
      return { dispose() {} };
    }
  },
}));

import { LoopWorkspace } from "./LoopWorkspace";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

class ResizeObserverStub {
  constructor(private readonly callback: ResizeObserverCallback) {
    resizeObservers.push(callback);
  }
  observe() {}
  disconnect() {}
}

let resizeObservers: ResizeObserverCallback[] = [];

const node: LoopNode = {
  id: "11111111-1111-4111-8111-111111111111",
  title: "Weather loop",
  loopType: "timed",
  state: { running: {} },
};

const graph: LoopGraph = {
  id: "graph",
  project: { path: "C:\\project", name: "Project" },
  nodes: [node],
  edges: [],
};

beforeEach(() => {
  vi.stubGlobal("ResizeObserver", ResizeObserverStub);
  xterm.writes = [];
  xterm.dataHandler = undefined;
  xterm.instance = undefined;
  xterm.proposedRows = 24;
  xterm.resize.mockClear();
  resizeObservers = [];
  bridge.openTerminal.mockReset();
  bridge.handlers = undefined;
  bridge.openTerminal.mockImplementation(
    async (_id, _columns, _rows, handlers) => {
      bridge.handlers = handlers;
      return {
        handle: "terminal-1",
        sessionName: "graphcode-LOOP",
        write: bridge.write,
        resize: bridge.resize,
        acknowledge: bridge.acknowledge,
        close: bridge.close,
      };
    },
  );
  bridge.write.mockClear();
  bridge.resize.mockClear();
  bridge.close.mockClear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.innerHTML = "";
});

describe("LoopWorkspace", () => {
  it("attaches, forwards input, resizes, and detaches", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const onSessionExit = vi.fn(async () => undefined);
    const layout = createTerminalLayout(
      node.id,
      () => "22222222-2222-4222-8222-222222222222",
    );

    await act(async () => {
      root.render(
        <LoopWorkspace
          graph={graph}
          node={node}
          mailroomOwned
          commands={[]}
          layout={layout}
          onLayoutChange={() => undefined}
          onClosePane={() => undefined}
          onCloseTab={() => undefined}
          onResizeSplit={() => undefined}
          onBack={() => undefined}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
          onSessionExit={onSessionExit}
        />,
      );
    });

    expect(bridge.openTerminal).toHaveBeenCalledWith(
      { kind: "node", nodeId: node.id },
      112,
      24,
      expect.any(Object),
    );
    expect(container.textContent).toContain("Live");
    const workspaceContent = container.querySelector(".loop-workspace-content");
    expect(
      workspaceContent?.children[0].classList.contains("terminal-workspace"),
    ).toBe(true);
    expect(
      workspaceContent?.children[1].classList.contains("loop-workspace-rail"),
    ).toBe(true);
    xterm.proposedRows = 31;
    window.dispatchEvent(new Event("resize"));
    await act(async () => {
      await new Promise((resolve) => window.setTimeout(resolve, 110));
    });
    expect(xterm.resize).toHaveBeenLastCalledWith(112, 31);
    expect(bridge.resize).toHaveBeenCalledWith(112, 31);

    await act(async () => {
      xterm.dataHandler?.("echo test\r");
    });
    expect(bridge.write).toHaveBeenCalledWith("echo test\r");

    await act(async () => {
      bridge.handlers?.onExit(0);
    });
    expect(onSessionExit).toHaveBeenCalledWith(true);
    expect(container.textContent).toContain("Session ended");

    await act(async () => {
      root.unmount();
    });
    expect(bridge.close).toHaveBeenCalledOnce();
  });

  it("reports a nonzero or signal exit as rejected", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const onSessionExit = vi.fn(async () => undefined);
    const layout = createTerminalLayout(
      node.id,
      () => "22222222-2222-4222-8222-222222222222",
    );

    await act(async () => {
      root.render(
        <LoopWorkspace
          graph={graph}
          node={node}
          mailroomOwned
          commands={[]}
          layout={layout}
          onLayoutChange={() => undefined}
          onClosePane={() => undefined}
          onCloseTab={() => undefined}
          onResizeSplit={() => undefined}
          onBack={() => undefined}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
          onSessionExit={onSessionExit}
        />,
      );
    });

    await act(async () => {
      bridge.handlers?.onExit(null);
    });
    expect(onSessionExit).toHaveBeenCalledWith(false);
    await act(async () => {
      root.unmount();
    });
  });

  it("mounts stable panes and resizes them through an accessible divider", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const ids = [
      "22222222-2222-4222-8222-222222222222",
      "33333333-3333-4333-8333-333333333333",
    ];
    let index = 0;

    function Harness() {
      const [layout, setLayout] = useState<TerminalLayout>(() =>
        createTerminalLayout(node.id, () => ids[index++]),
      );
      return (
        <LoopWorkspace
          graph={graph}
          node={node}
          mailroomOwned
          commands={[]}
          layout={layout}
          onLayoutChange={setLayout}
          onClosePane={(tabId: string, surface: TerminalSurface) =>
            setLayout((current) =>
              closePane(current, tabId, surface.id, node.id),
            )
          }
          onCloseTab={() => undefined}
          onResizeSplit={(tabId, splitId, dividerIndex, delta) =>
            setLayout((current) =>
              resizeSplit(current, tabId, splitId, dividerIndex, delta),
            )
          }
          onBack={() => undefined}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
          onSessionExit={async () => undefined}
        />
      );
    }

    vi.stubGlobal("crypto", {
      randomUUID: () => ids[index++],
    });
    await act(async () => {
      root.render(<Harness />);
    });
    await act(async () => {
      (
        Array.from(container.querySelectorAll("button")).find(
          (button) => button.textContent === "Split right",
        ) as HTMLButtonElement
      ).click();
    });

    expect(container.querySelectorAll(".terminal-pane")).toHaveLength(2);
    expect(
      Array.from(
        container.querySelectorAll<HTMLElement>(".terminal-pane-position"),
      ).map((pane) => pane.style.getPropertyValue("--pane-width")),
    ).toEqual(["50%", "50%"]);
    expect(bridge.openTerminal).toHaveBeenCalledWith(
      { kind: "node", nodeId: node.id },
      112,
      24,
      expect.any(Object),
    );
    expect(bridge.openTerminal).toHaveBeenCalledWith(
      {
        kind: "shell",
        surfaceId: ids[1],
        workingDirectory: graph.project.path,
      },
      112,
      24,
      expect.any(Object),
    );

    const divider = container.querySelector<HTMLElement>(
      '[role="separator"][aria-orientation="vertical"]',
    );
    expect(divider).not.toBeNull();
    await act(async () => {
      divider?.dispatchEvent(
        new KeyboardEvent("keydown", { key: "ArrowRight", bubbles: true }),
      );
    });
    expect(
      Array.from(
        container.querySelectorAll<HTMLElement>(".terminal-pane-position"),
      ).map((pane) =>
        Number.parseFloat(pane.style.getPropertyValue("--pane-width")),
      ),
    ).toEqual([55.00000000000001, 44.99999999999999]);

    const panel = divider?.parentElement as HTMLElement;
    panel.getBoundingClientRect = () =>
      ({
        width: 1000,
        height: 500,
      }) as DOMRect;
    await act(async () => {
      divider?.dispatchEvent(
        new MouseEvent("pointerdown", {
          bubbles: true,
          clientX: 500,
          clientY: 0,
        }),
      );
      window.dispatchEvent(
        new MouseEvent("pointermove", {
          bubbles: true,
          clientX: 600,
          clientY: 0,
        }),
      );
      window.dispatchEvent(new MouseEvent("pointerup", { bubbles: true }));
    });
    expect(
      Array.from(
        container.querySelectorAll<HTMLElement>(".terminal-pane-position"),
      ).map((pane) =>
        Number.parseFloat(pane.style.getPropertyValue("--pane-width")),
      ),
    ).toEqual([65, 35]);

    bridge.resize.mockClear();
    xterm.resize.mockClear();
    xterm.proposedRows = 30;
    resizeObservers.forEach((callback) => callback([], {} as ResizeObserver));
    await act(async () => {
      await new Promise((resolve) => window.setTimeout(resolve, 110));
    });
    expect(xterm.resize).toHaveBeenCalledTimes(2);
    expect(bridge.resize).toHaveBeenCalledTimes(2);

    await act(async () => {
      root.unmount();
    });
    expect(bridge.close).toHaveBeenCalledTimes(2);
  });

  it("normalizes pointer movement to the owning nested split region", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const ids = [
      "22222222-2222-4222-8222-222222222222",
      "33333333-3333-4333-8333-333333333333",
      "44444444-4444-4444-8444-444444444444",
      "55555555-5555-4555-8555-555555555555",
    ];

    function Harness() {
      const [layout, setLayout] = useState<TerminalLayout>(() => {
        let initial = createTerminalLayout(node.id, () => ids[0]);
        initial = splitFocusedPane(initial, "horizontal", () => ids[1]);
        initial = splitFocusedPane(initial, "vertical", () => ids[2]);
        return splitFocusedPane(initial, "horizontal", () => ids[3]);
      });
      return (
        <LoopWorkspace
          graph={graph}
          node={node}
          mailroomOwned
          commands={[]}
          layout={layout}
          onLayoutChange={setLayout}
          onClosePane={() => undefined}
          onCloseTab={() => undefined}
          onResizeSplit={(tabId, splitId, dividerIndex, delta) =>
            setLayout((current) =>
              resizeSplit(current, tabId, splitId, dividerIndex, delta),
            )
          }
          onBack={() => undefined}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
          onSessionExit={async () => undefined}
        />
      );
    }

    await act(async () => {
      root.render(<Harness />);
    });

    const panel = container.querySelector<HTMLElement>(".terminal-tab-panel");
    if (!panel) throw new Error("terminal panel missing");
    panel.getBoundingClientRect = () =>
      ({
        width: 1000,
        height: 800,
      }) as DOMRect;
    const nestedDivider = Array.from(
      container.querySelectorAll<HTMLElement>(
        '[role="separator"][aria-orientation="vertical"]',
      ),
    ).find(
      (divider) =>
        Number.parseFloat(divider.style.getPropertyValue("--divider-left")) ===
        75,
    );
    expect(nestedDivider).toBeDefined();

    await act(async () => {
      nestedDivider?.dispatchEvent(
        new MouseEvent("pointerdown", {
          bubbles: true,
          clientX: 750,
          clientY: 600,
        }),
      );
      window.dispatchEvent(
        new MouseEvent("pointermove", {
          bubbles: true,
          clientX: 850,
          clientY: 600,
        }),
      );
      window.dispatchEvent(new MouseEvent("pointerup", { bubbles: true }));
    });

    const widths = Array.from(
      container.querySelectorAll<HTMLElement>(".terminal-pane-position"),
    ).map((pane) =>
      Number.parseFloat(pane.style.getPropertyValue("--pane-width")),
    );
    [50, 50, 35, 15].forEach((expected, index) => {
      expect(widths[index]).toBeCloseTo(expected);
    });

    await act(async () => {
      root.unmount();
    });
  });
});
