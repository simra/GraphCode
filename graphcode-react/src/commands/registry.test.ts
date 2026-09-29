import { describe, expect, it, vi } from "vitest";
import type { AppState } from "../state/graphState";
import { initialAppState } from "../state/graphState";
import {
  createCommandRegistry,
  createEdgeCommands,
  createMailroomPostCommands,
  createProjectRowCommands,
  createQuickChatCommands,
  selectHeaderCommands,
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
  it("selects only command search and the contextual primary header action", () => {
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      openProjectFolder: vi.fn(async () => undefined),
      openNewQuickChat: vi.fn(),
      openNewLoop: vi.fn(),
      openMailroom: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
    });

    expect(
      selectHeaderCommands(commands, "overview").map((command) => command.id),
    ).toEqual(["app.commandPalette", "project.openFolder"]);
    expect(
      selectHeaderCommands(commands, "project").map((command) => command.id),
    ).toEqual(["app.commandPalette", "loop.new"]);
    expect(
      selectHeaderCommands(commands, "quickChats").map((command) => command.id),
    ).toEqual(["app.commandPalette", "chat.new"]);
    expect(
      selectHeaderCommands(commands, "mailroom").map((command) => command.id),
    ).toEqual(["app.commandPalette"]);
    expect(
      commands.find((command) => command.id === "project.openMailroom")
        ?.surfaces,
    ).toEqual([]);
  });

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

  it("opens terminals for executable loops including sketches", () => {
    const state = stateWithSelectedNode();
    const openTerminal = vi.fn();
    let commands = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      openTerminal,
    });

    const command = commands.find(
      (candidate) => candidate.id === "loop.openTerminal",
    );
    expect(command?.enabled).toBe(true);
    command?.execute();
    expect(openTerminal).toHaveBeenCalledOnce();

    state.graphs["C:\\work\\graph"].nodes[0].loopType = "sketch";
    commands = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      openTerminal,
    });
    const sketchCommand = commands.find(
      (candidate) => candidate.id === "loop.openTerminal",
    );
    expect(sketchCommand?.enabled).toBe(true);
    sketchCommand?.execute();
    expect(openTerminal).toHaveBeenCalledTimes(2);
  });

  it("capability-gates structured session history by provider", () => {
    const state = stateWithSelectedNode();
    state.graphs["C:\\work\\graph"].nodes[0].backend = "copilotCLI";
    const openHistory = vi.fn();
    let commands = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      openHistory,
    });

    const supported = commands.find(
      (candidate) => candidate.id === "loop.openHistory",
    );
    expect(supported?.enabled).toBe(true);
    supported?.execute();
    expect(openHistory).toHaveBeenCalledOnce();

    state.graphs["C:\\work\\graph"].nodes[0].backend = "openCode";
    commands = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      openHistory,
    });
    const unsupported = commands.find(
      (candidate) => candidate.id === "loop.openHistory",
    );
    expect(unsupported).toMatchObject({
      enabled: false,
      disabledReason:
        "openCode does not advertise structured transcript support",
    });
  });

  it("exposes terminal layout actions only while a workspace is open", async () => {
    const actions = {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      newTerminalTab: vi.fn(),
      closeTerminalPane: vi.fn(async () => undefined),
      closeTerminalTab: vi.fn(async () => undefined),
      splitTerminalRight: vi.fn(),
      splitTerminalDown: vi.fn(),
      selectNextTerminalTab: vi.fn(),
      selectPreviousTerminalTab: vi.fn(),
      focusNextTerminalPane: vi.fn(),
      focusPreviousTerminalPane: vi.fn(),
      terminalIsSplit: true,
    };
    const commands = createCommandRegistry(stateWithSelectedNode(), actions);

    for (const id of [
      "terminal.newTab",
      "terminal.closePane",
      "terminal.closeTab",
      "terminal.splitRight",
      "terminal.splitDown",
      "terminal.nextTab",
      "terminal.previousTab",
      "terminal.focusNextPane",
      "terminal.focusPreviousPane",
    ] as const) {
      expect(commands.find((command) => command.id === id)?.enabled).toBe(true);
    }
    commands.find((command) => command.id === "terminal.splitRight")?.execute();
    expect(actions.splitTerminalRight).toHaveBeenCalledOnce();
    expect(
      Object.fromEntries(
        commands
          .filter((command) => command.category === "Terminal")
          .map((command) => [command.id, command.shortcut?.label]),
      ),
    ).toMatchObject({
      "terminal.newTab": "Ctrl+Shift+T",
      "terminal.closePane": "Ctrl+Shift+W",
      "terminal.splitRight": "Ctrl+Shift+E",
      "terminal.splitDown": "Ctrl+Shift+O",
      "terminal.nextTab": "Ctrl+PageDown",
      "terminal.previousTab": "Ctrl+PageUp",
      "terminal.focusNextPane": "F6",
      "terminal.focusPreviousPane": "Shift+F6",
    });
    for (const shortcut of commands
      .filter((command) => command.category === "Terminal")
      .map((command) => command.shortcut)
      .filter((shortcut) => shortcut !== undefined)) {
      expect(shortcut).not.toMatchObject({
        ctrl: true,
        shift: undefined,
        alt: undefined,
        key: expect.stringMatching(/^[twd]$/i),
      });
    }

    const closed = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
    });
    expect(
      closed.find((command) => command.id === "terminal.newTab")?.enabled,
    ).toBe(false);
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

  it("exposes persistent Back and Forward navigation with desktop shortcuts", () => {
    const navigateBack = vi.fn();
    const navigateForward = vi.fn();
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      navigateBack,
      navigateForward,
      canNavigateBack: true,
      canNavigateForward: false,
    });

    const back = commands.find((command) => command.id === "navigation.back");
    const forward = commands.find(
      (command) => command.id === "navigation.forward",
    );
    expect(back).toMatchObject({
      enabled: true,
      shortcut: {
        key: "ArrowLeft",
        ctrl: true,
        alt: true,
        label: "Ctrl+Alt+←",
      },
    });
    expect(forward?.enabled).toBe(false);
    back?.execute();
    expect(navigateBack).toHaveBeenCalledOnce();
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
      refineNode: vi.fn(),
      rollbackRefinement: vi.fn(async () => undefined),
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
      "loop.refine",
      "loop.rollbackRefinement",
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
      openComposite: vi.fn(),
    };

    let commands = createCommandRegistry(state, actions);
    expect(
      commands.find((command) => command.id === "loop.pilotComposite")?.enabled,
    ).toBe(true);
    expect(
      commands.find((command) => command.id === "loop.openComposite")?.enabled,
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

  it("exposes authoritative Mailroom controls only on the project graph", () => {
    const actions = {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      refreshMailroom: vi.fn(async () => undefined),
      loadUnreadMailroom: vi.fn(async () => undefined),
      markUnreadMailroomRead: vi.fn(async () => undefined),
      searchMailroom: vi.fn(),
      configureMailroomWatch: vi.fn(),
      postMailroom: vi.fn(),
      openMailroom: vi.fn(),
    };
    const state = stateWithSelectedNode();
    let commands = createCommandRegistry(state, actions);
    expect(
      commands.find((command) => command.id === "project.openMailroom")
        ?.enabled,
    ).toBe(true);
    for (const id of [
      "loop.mailroomRefresh",
      "loop.mailroomUnread",
      "loop.mailroomMarkRead",
      "loop.mailroomSearch",
      "loop.mailroomWatch",
      "loop.mailroomPost",
    ] as const) {
      expect(commands.find((command) => command.id === id)?.enabled).toBe(true);
    }

    state.selectedNodeId = undefined;
    commands = createCommandRegistry(state, actions);
    for (const id of [
      "loop.mailroomRefresh",
      "loop.mailroomSearch",
      "loop.mailroomPost",
    ] as const) {
      expect(commands.find((command) => command.id === id)?.enabled).toBe(true);
    }
    state.selectedNodeId = "node-a";

    state.graphs["C:\\work\\graph"].nodes = [
      {
        id: "parent",
        title: "Parent",
        loopType: "proactive",
        state: "idle",
        subGraph: {
          id: "child",
          project: { path: "C:\\work\\graph", name: "Graph" },
          nodes: [{ id: "node-a", title: "A", state: "running" }],
          edges: [],
        },
      },
    ];
    state.compositePath = ["parent"];
    commands = createCommandRegistry(state, actions);
    expect(
      commands.find((command) => command.id === "loop.mailroomUnread")
        ?.disabledReason,
    ).toContain("ownership is not established");
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

  it("enables edge creation and refuses stable-ID actions without an ID", () => {
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
      editEdge: vi.fn(),
      deleteEdge: vi.fn(async () => undefined),
    });
    expect(
      missingId.find((command) => command.id === "edge.edit")?.disabledReason,
    ).toContain("no stable ID");
    expect(
      missingId.find((command) => command.id === "edge.delete")?.disabledReason,
    ).toContain("no stable ID");
  });

  it("offers promotion only for a connected sketch and editing for stable edges", () => {
    const state = stateWithSelectedNode();
    state.graphs["C:\\work\\graph"].nodes[0].loopType = "sketch";
    const promoteNode = vi.fn();
    const promotion = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      promoteNode,
    }).find((command) => command.id === "loop.promote");
    expect(promotion?.enabled).toBe(true);
    promotion?.execute();
    expect(promoteNode).toHaveBeenCalledOnce();

    const editEdge = vi.fn();
    const edgeCommands = createEdgeCommands(true, "edge", {
      editEdge,
      deleteEdge: vi.fn(async () => undefined),
    });
    expect(
      edgeCommands.find((command) => command.id === "edge.edit")?.enabled,
    ).toBe(true);
    edgeCommands.find((command) => command.id === "edge.edit")?.execute();
    expect(editEdge).toHaveBeenCalledOnce();
  });

  it("offers the opposite unattended type for live goal and timed loops", () => {
    const state = stateWithSelectedNode();
    const promoteNode = vi.fn();
    state.graphs["C:\\work\\graph"].nodes[0].loopType = "goalBased";

    const goalCommand = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      promoteNode,
    }).find((command) => command.id === "loop.promote");
    expect(goalCommand).toMatchObject({
      label: "Change to Timed Loop",
      enabled: true,
    });

    state.graphs["C:\\work\\graph"].nodes[0].loopType = "timeBased";
    const timedCommand = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      promoteNode,
    }).find((command) => command.id === "loop.promote");
    expect(timedCommand).toMatchObject({
      label: "Change to Goal Loop",
      enabled: true,
    });

    state.graphs["C:\\work\\graph"].nodes[0].state = { stopped: {} };
    const stoppedCommand = createCommandRegistry(state, {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      promoteNode,
    }).find((command) => command.id === "loop.promote");
    expect(stoppedCommand).toMatchObject({
      enabled: false,
      disabledReason: "Stopped loops cannot change type",
    });
  });

  it("exposes client-owned automatic layout reset", () => {
    const resetLayout = vi.fn();
    const commands = createCommandRegistry(stateWithSelectedNode(), {
      openPalette: vi.fn(),
      clearSelection: vi.fn(),
      selectNode: vi.fn(),
      resetLayout,
    });

    const reset = commands.find((command) => command.id === "view.resetLayout");
    expect(reset?.enabled).toBe(true);
    reset?.execute();
    expect(resetLayout).toHaveBeenCalledOnce();
  });

  it("creates a correlated deep-read command for a Mailroom post", () => {
    const readPost = vi.fn(async () => undefined);
    const command = createMailroomPostCommands(true, 42, { readPost })[0];

    expect(command.id).toBe("mailroom.readPost");
    expect(command.description).toContain("#42");
    expect(command.enabled).toBe(true);
  });
});
