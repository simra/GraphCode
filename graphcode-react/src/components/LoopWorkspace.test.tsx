// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { LoopGraph, LoopNode } from "../protocol/domain";

const bridge = vi.hoisted(() => ({
  acknowledge: vi.fn(async () => undefined),
  close: vi.fn(async () => undefined),
  loadTerminalHistory: vi.fn(),
  openTerminal: vi.fn(),
  resize: vi.fn(async () => undefined),
  write: vi.fn(async () => undefined),
}));

const xterm = vi.hoisted(() => ({
  dataHandler: undefined as ((data: string) => void) | undefined,
  dispose: vi.fn(),
  fitCalls: 0,
  focus: vi.fn(),
  instance: undefined as { cols: number; rows: number } | undefined,
  writes: [] as Uint8Array[],
}));

vi.mock("../bridge/terminal", () => ({
  loadTerminalHistory: bridge.loadTerminalHistory,
  openTerminal: bridge.openTerminal,
}));

vi.mock("@xterm/addon-fit", () => ({
  FitAddon: class {
    fit() {
      xterm.fitCalls += 1;
      if (xterm.fitCalls > 1 && xterm.instance) {
        xterm.instance.cols = 112;
        xterm.instance.rows = 31;
      }
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
  xterm.fitCalls = 0;
  xterm.instance = undefined;
  bridge.loadTerminalHistory.mockReset();
  bridge.loadTerminalHistory.mockResolvedValue({
    bytes: new TextEncoder().encode("history"),
    truncated: false,
  });
  bridge.openTerminal.mockReset();
  bridge.openTerminal.mockResolvedValue({
    handle: "terminal-1",
    sessionName: "graphcode-LOOP",
    write: bridge.write,
    resize: bridge.resize,
    acknowledge: bridge.acknowledge,
    close: bridge.close,
  });
  bridge.write.mockClear();
  bridge.resize.mockClear();
  bridge.close.mockClear();
});

afterEach(() => {
  vi.unstubAllGlobals();
  document.body.innerHTML = "";
});

describe("LoopWorkspace", () => {
  it("loads retained history, attaches, forwards input, and detaches", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <LoopWorkspace
          graph={graph}
          node={node}
          commands={[]}
          onBack={() => undefined}
          onExecuteCommand={() => undefined}
        />,
      );
    });

    expect(bridge.loadTerminalHistory).toHaveBeenCalledWith(node.id);
    expect(bridge.openTerminal).toHaveBeenCalledWith(
      node.id,
      80,
      24,
      expect.any(Object),
    );
    expect(new TextDecoder().decode(xterm.writes[0])).toBe("history");
    expect(container.textContent).toContain("Live");
    expect(bridge.resize).toHaveBeenCalledWith(112, 31);

    await act(async () => {
      xterm.dataHandler?.("echo test\r");
    });
    expect(bridge.write).toHaveBeenCalledWith("echo test\r");

    await act(async () => {
      root.unmount();
    });
    expect(bridge.close).toHaveBeenCalledOnce();
  });
});
