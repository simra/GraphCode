import { describe, expect, it, vi } from "vitest";
import type { AppState } from "../state/graphState";
import { initialAppState } from "../state/graphState";
import { createCommandRegistry } from "./registry";

function stateWithSelectedNode(): AppState {
  return {
    ...initialAppState,
    connection: { phase: "connected", usingFixture: false },
    selectedProjectPath: "C:\\work\\graph",
    selectedNodeId: "node-a",
    graphs: {
      "C:\\work\\graph": {
        id: "graph",
        project: { path: "C:\\work\\graph", name: "Graph" },
        nodes: [
          { id: "node-a", title: "A", state: "running" },
          { id: "node-b", title: "B", state: "idle" },
        ],
        edges: [],
      },
    },
  };
}

describe("command registry", () => {
  it("projects connection and selection state into command availability", () => {
    const stopNode = vi.fn(async () => undefined);
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      stopNode,
    });

    expect(
      commands.find((command) => command.id === "loop.stop")?.enabled,
    ).toBe(true);
    expect(
      commands.find((command) => command.id === "loop.new")?.disabledReason,
    ).toContain("next frontend task");
  });

  it("uses the same registry execution for relative navigation", () => {
    const selectNode = vi.fn();
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode,
    });

    commands.find((command) => command.id === "selection.nextLoop")?.execute();
    expect(selectNode).toHaveBeenCalledWith("node-b");
  });
});
