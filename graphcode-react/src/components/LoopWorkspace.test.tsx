// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LoopGraph, LoopNode } from "../protocol/domain";

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
  observe() {}
  disconnect() {}
}

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

    await act(async () => {
      root.render(
        <LoopWorkspace
          graph={graph}
          node={node}
          mailroomOwned
          commands={[]}
          onBack={() => undefined}
          onExecuteCommand={() => undefined}
          onSessionExit={onSessionExit}
        />,
      );
    });

    expect(bridge.openTerminal).toHaveBeenCalledWith(
      node.id,
      80,
      24,
      expect.any(Object),
    );
    expect(container.textContent).toContain("Live");
    const workspaceContent = container.querySelector(".loop-workspace-content");
    expect(
      workspaceContent?.children[0].classList.contains("terminal-host"),
    ).toBe(true);
    expect(
      workspaceContent?.children[1].classList.contains("loop-workspace-rail"),
    ).toBe(true);
    xterm.proposedRows = 31;
    window.dispatchEvent(new Event("resize"));
    await act(async () => {
      await new Promise((resolve) => window.setTimeout(resolve, 110));
    });
    expect(xterm.resize).toHaveBeenLastCalledWith(80, 31);
    expect(bridge.resize).toHaveBeenCalledWith(80, 31);

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

    await act(async () => {
      root.render(
        <LoopWorkspace
          graph={graph}
          node={node}
          commands={[]}
          onBack={() => undefined}
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
});
