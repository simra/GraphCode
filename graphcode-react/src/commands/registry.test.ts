import { describe, expect, it, vi } from "vitest";
import type { AppState } from "../state/graphState";
import { initialAppState } from "../state/graphState";
import {
  createCommandRegistry,
  createEdgeCommands,
  createProjectRowCommands,
  createQuickChatCommands,
} from "./registry";

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

  it("enables supported lifecycle actions and gates goal completion", () => {
    const actions = {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      renameNode: vi.fn(),
      editNode: vi.fn(),
      messageNode: vi.fn(),
      memoNode: vi.fn(),
      restartSession: vi.fn(async () => undefined),
      completeNode: vi.fn(),
      deleteNode: vi.fn(async () => undefined),
      refreshUsage: vi.fn(async () => undefined),
    };
    const commands = createCommandRegistry(stateWithSelectedNode(), actions);

    for (const id of [
      "loop.rename",
      "loop.edit",
      "loop.message",
      "loop.memo",
      "loop.restartSession",
      "loop.delete",
      "loop.refreshUsage",
    ] as const) {
      expect(commands.find((command) => command.id === id)?.enabled).toBe(true);
    }
    expect(
      commands.find((command) => command.id === "loop.complete")
        ?.disabledReason,
    ).toContain("Only goal loops");

    const goalState = stateWithSelectedNode();
    goalState.graphs["C:\\work\\graph"].nodes[0].loopType = "goalBased";
    expect(
      createCommandRegistry(goalState, actions).find(
        (command) => command.id === "loop.complete",
      )?.enabled,
    ).toBe(true);
  });

  it("uses resume semantics for resolved loops", () => {
    const state = stateWithSelectedNode();
    state.graphs["C:\\work\\graph"].nodes[0].state = "stopped";
    const command = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      restartSession: vi.fn(async () => undefined),
    }).find((candidate) => candidate.id === "loop.restartSession");

    expect(command?.label).toBe("Resume Session");
    expect(command?.enabled).toBe(true);
  });

  it("enables native folder ingress only when its action is available", () => {
    const openProjectFolder = vi.fn(async () => undefined);
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      openProjectFolder,
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
    });

    expect(
      commands.find((command) => command.id === "project.openFolder")?.enabled,
    ).toBe(true);
  });

  it("keeps Quick Chat lifecycle actions in the typed registry", () => {
    const openNewQuickChat = vi.fn();
    const globalCommands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      openNewQuickChat,
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
    });
    globalCommands.find((command) => command.id === "chat.new")?.execute();
    expect(openNewQuickChat).toHaveBeenCalledOnce();

    const chatCommands = createQuickChatCommands(true, {
      openQuickChat: vi.fn(async () => undefined),
      renameQuickChat: vi.fn(),
      deleteQuickChat: vi.fn(async () => undefined),
    });
    expect(chatCommands.map((command) => command.id)).toEqual([
      "chat.open",
      "chat.rename",
      "chat.delete",
    ]);
    expect(chatCommands.every((command) => command.enabled)).toBe(true);
    expect(chatCommands.at(-1)?.danger).toBe(true);
  });

  it("projects viewport controls from the same command registry", () => {
    const zoomIn = vi.fn();
    const fitGraph = vi.fn();
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      zoomIn,
      fitGraph,
    });

    commands.find((command) => command.id === "view.zoomIn")?.execute();
    commands.find((command) => command.id === "view.fitGraph")?.execute();
    expect(zoomIn).toHaveBeenCalledOnce();
    expect(fitGraph).toHaveBeenCalledOnce();
  });

  it("requires a completed pilot before a composite can be armed", () => {
    const state = stateWithSelectedNode();
    const node = state.graphs["C:\\work\\graph"].nodes[0];
    node.loopType = "proactive";
    node.subGraph = {
      id: "child",
      project: { path: "C:\\work\\graph", name: "Child" },
      nodes: [],
      edges: [],
    };
    node.pilotState = "notPiloted";
    const actions = {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      pilotComposite: vi.fn(async () => undefined),
      armComposite: vi.fn(async () => undefined),
    };

    let commands = createCommandRegistry(state, actions);
    expect(
      commands.find((command) => command.id === "loop.pilotComposite")?.enabled,
    ).toBe(true);
    expect(
      commands.find((command) => command.id === "loop.armComposite")
        ?.disabledReason,
    ).toContain("Pilot");

    node.pilotState = "piloted";
    commands = createCommandRegistry(state, actions);
    expect(
      commands.find((command) => command.id === "loop.armComposite")?.enabled,
    ).toBe(true);
  });

  it("distinguishes open and recent project lifecycle actions", () => {
    const actions = {
      closeProject: vi.fn(async () => undefined),
      forgetProject: vi.fn(async () => undefined),
      deleteProjectGraph: vi.fn(async () => undefined),
    };
    const open = createProjectRowCommands(true, true, actions);
    expect(
      open.find((command) => command.id === "project.close")?.enabled,
    ).toBe(true);
    expect(
      open.find((command) => command.id === "project.deleteGraph")?.danger,
    ).toBe(true);

    const recent = createProjectRowCommands(true, false, actions);
    expect(
      recent.find((command) => command.id === "project.close")?.disabledReason,
    ).toContain("not open");
    expect(
      recent.find((command) => command.id === "project.forget")?.enabled,
    ).toBe(true);
  });

  it("enables edge creation and refuses deletion without a stable edge ID", () => {
    const state = stateWithSelectedNode();
    const commands = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      openNewEdge: vi.fn(),
    });
    expect(commands.find((command) => command.id === "edge.new")?.enabled).toBe(
      true,
    );

    const missingId = createEdgeCommands(true, undefined, {
      deleteEdge: vi.fn(async () => undefined),
    });
    expect(missingId[0].disabledReason).toContain("no stable ID");
  });
});
