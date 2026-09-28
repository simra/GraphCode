import { describe, expect, it } from "vitest";
import type { AppState } from "./graphState";
import { initialAppState } from "./graphState";
import {
  canNavigateBack,
  canNavigateForward,
  createNavigationHistory,
  navigateBack,
  navigateForward,
  navigationAnnouncement,
  navigationRouteForNodeSelection,
  recordNavigation,
  resolveNavigationRoute,
  traverseNavigation,
  type NavigationRoute,
} from "./navigationHistory";

function stateWithRoutes(): AppState {
  return {
    ...initialAppState,
    selectedProjectPath: "C:\\work\\graph",
    graphs: {
      "graphcode://global": {
        id: "global",
        project: { path: "graphcode://global", name: "Overview" },
        nodes: [],
        edges: [],
      },
      "C:\\work\\graph": {
        id: "root",
        project: { path: "C:\\work\\graph", name: "Graph" },
        nodes: [
          {
            id: "parent",
            title: "Parent",
            loopType: "proactive",
            state: "running",
            subGraph: {
              id: "child",
              project: { path: "C:\\work\\graph", name: "Graph" },
              nodes: [
                {
                  id: "child-node",
                  title: "Child",
                  loopType: "turnBased",
                  state: "running",
                },
              ],
              edges: [],
            },
          },
          {
            id: "terminal-node",
            title: "Terminal",
            loopType: "turnBased",
            state: "running",
          },
          {
            id: "sketch-node",
            title: "Sketch",
            loopType: "sketch",
            state: "idle",
          },
        ],
        edges: [],
      },
    },
    quickChats: [
      {
        id: "chat-a",
        title: "Scratch",
        backend: "copilot",
        createdAt: "2026-09-28T10:00:00Z",
      },
    ],
  };
}

describe("navigation history", () => {
  it("deduplicates arrivals, truncates forward history, and stays bounded", () => {
    let history = createNavigationHistory();
    const project = {
      kind: "project",
      projectPath: "C:\\work\\graph",
      compositePath: [],
    } satisfies NavigationRoute;
    history = recordNavigation(history, project);
    history = recordNavigation(history, project);
    history = recordNavigation(history, { kind: "quickChats" });
    history = navigateBack(history, () => true).history;
    history = recordNavigation(history, { kind: "quickChat", id: "chat-a" });

    expect(history.entries).toEqual([
      project,
      { kind: "quickChat", id: "chat-a" },
    ]);
    expect(history.cursor).toBe(1);

    for (let index = 0; index < 60; index += 1) {
      history = recordNavigation(history, {
        kind: "quickChat",
        id: `chat-${index}`,
      });
    }
    expect(history.entries).toHaveLength(50);
    expect(history.cursor).toBe(49);
  });

  it("skips unavailable targets without deleting entries or moving on a miss", () => {
    const project = {
      kind: "project",
      projectPath: "C:\\work\\graph",
      compositePath: [],
    } satisfies NavigationRoute;
    const deleted = {
      kind: "quickChat",
      id: "deleted",
    } satisfies NavigationRoute;
    const current = { kind: "quickChats" } satisfies NavigationRoute;
    const history = createNavigationHistory([project, deleted, current], 2);
    const isResolvable = (route: NavigationRoute) => route !== deleted;

    expect(canNavigateBack(history, isResolvable)).toBe(true);
    const back = navigateBack(history, isResolvable);
    expect(back.route).toEqual(project);
    expect(back.history.cursor).toBe(0);
    expect(back.history.entries).toEqual(history.entries);

    const forward = navigateForward(back.history, (route) => route === current);
    expect(forward.route).toEqual(current);
    expect(forward.history.cursor).toBe(2);

    const missed = navigateBack(back.history, () => false);
    expect(missed.route).toBeUndefined();
    expect(missed.history.cursor).toBe(0);
    expect(canNavigateForward(missed.history, () => false)).toBe(false);
  });

  it("resolves every supported route lazily against current client state", () => {
    const state = stateWithRoutes();
    const routes: NavigationRoute[] = [
      {
        kind: "project",
        projectPath: "graphcode://global",
        compositePath: [],
      },
      {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: [],
      },
      {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: [],
        nodeId: "terminal-node",
      },
      {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: [],
        nodeId: "terminal-node",
        terminal: true,
      },
      {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: [],
        nodeId: "sketch-node",
        terminal: true,
      },
      {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: ["parent"],
      },
      {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: ["parent"],
        nodeId: "child-node",
      },
      { kind: "mailroom", projectPath: "C:\\work\\graph" },
      { kind: "quickChats" },
      { kind: "quickChat", id: "chat-a" },
    ];

    expect(
      routes.map((route) => resolveNavigationRoute(state, route)?.route),
    ).toEqual(routes);
    expect(
      resolveNavigationRoute(state, {
        kind: "project",
        projectPath: "C:\\work\\missing",
        compositePath: [],
      }),
    ).toBeUndefined();
    expect(
      resolveNavigationRoute(state, { kind: "quickChat", id: "deleted" }),
    ).toBeUndefined();
    expect(
      resolveNavigationRoute(state, {
        kind: "project",
        projectPath: "C:\\work\\graph",
        compositePath: [],
        nodeId: "parent",
        terminal: true,
      }),
    ).toBeUndefined();
  });

  it("provides concise accessibility announcements for history traversal", () => {
    expect(navigationAnnouncement("back", "Child terminal")).toBe(
      "Back to Child terminal.",
    );
    expect(navigationAnnouncement("forward", "Quick Chats")).toBe(
      "Forward to Quick Chats.",
    );
  });

  it("records nested canvas node selections and truncates the forward branch", () => {
    const project = {
      kind: "project",
      projectPath: "C:\\work\\graph",
      compositePath: [],
    } satisfies NavigationRoute;
    const abandonedForward = {
      kind: "quickChats",
    } satisfies NavigationRoute;
    const clicked = navigationRouteForNodeSelection(
      "C:\\work\\graph",
      ["parent"],
      "child-node",
    );
    const history = createNavigationHistory([project, abandonedForward], 0);

    expect(recordNavigation(history, clicked)).toEqual({
      version: 1,
      entries: [project, clicked],
      cursor: 1,
    });
  });

  it("commits traversal only after activation succeeds", async () => {
    const project = {
      kind: "project",
      projectPath: "C:\\work\\graph",
      compositePath: [],
    } satisfies NavigationRoute;
    const chat = {
      kind: "quickChat",
      id: "chat-a",
    } satisfies NavigationRoute;
    const history = createNavigationHistory([project, chat], 0);

    const failed = await traverseNavigation(
      history,
      "forward",
      () => true,
      async () => false,
    );
    expect(failed).toEqual({ history });

    const activated = await traverseNavigation(
      history,
      "forward",
      () => true,
      async () => true,
    );
    expect(activated).toEqual({
      history: { ...history, cursor: 1 },
      route: chat,
    });
    expect(history.cursor).toBe(0);

    await expect(
      traverseNavigation(
        history,
        "forward",
        () => true,
        async () => {
          throw new Error("activation refused");
        },
      ),
    ).rejects.toThrow("activation refused");
    expect(history.cursor).toBe(0);
  });
});
