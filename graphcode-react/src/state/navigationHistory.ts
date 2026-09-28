import type { LoopGraph } from "../protocol/domain";
import type { AppState } from "./graphState";

export type NavigationRoute =
  | {
      kind: "project";
      projectPath: string;
      compositePath: string[];
      nodeId?: string;
      terminal?: boolean;
    }
  | { kind: "mailroom"; projectPath: string }
  | { kind: "quickChats" }
  | { kind: "quickChat"; id: string };

export interface NavigationHistory {
  version: 1;
  entries: NavigationRoute[];
  cursor?: number;
}

export interface ResolvedNavigationRoute {
  route: NavigationRoute;
  label: string;
}

export interface NavigationStep {
  history: NavigationHistory;
  route?: NavigationRoute;
}

export function navigationAnnouncement(
  direction: "back" | "forward",
  label: string,
): string {
  return `${direction === "back" ? "Back" : "Forward"} to ${label}.`;
}

const historyLimit = 50;

export function createNavigationHistory(
  entries: NavigationRoute[] = [],
  cursor?: number,
): NavigationHistory {
  const boundedEntries = entries.slice(-historyLimit);
  const removed = entries.length - boundedEntries.length;
  const adjustedCursor =
    cursor === undefined ? undefined : Math.max(0, cursor - removed);
  return {
    version: 1,
    entries: boundedEntries,
    cursor:
      adjustedCursor === undefined || !boundedEntries.length
        ? undefined
        : Math.min(adjustedCursor, boundedEntries.length - 1),
  };
}

function routeKey(route: NavigationRoute): string {
  switch (route.kind) {
    case "project":
      return [
        route.kind,
        route.projectPath,
        route.compositePath.join("\0"),
        route.nodeId ?? "",
        route.terminal ? "terminal" : "graph",
      ].join("\0");
    case "mailroom":
      return `${route.kind}\0${route.projectPath}`;
    case "quickChats":
      return route.kind;
    case "quickChat":
      return `${route.kind}\0${route.id}`;
  }
}

export function recordNavigation(
  history: NavigationHistory,
  route: NavigationRoute,
): NavigationHistory {
  const current =
    history.cursor === undefined ? undefined : history.entries[history.cursor];
  if (current && routeKey(current) === routeKey(route)) return history;

  const entries =
    history.cursor !== undefined && history.cursor < history.entries.length - 1
      ? history.entries.slice(0, history.cursor + 1)
      : [...history.entries];
  entries.push(route);
  return createNavigationHistory(entries, entries.length - 1);
}

function findRoute(
  history: NavigationHistory,
  offset: -1 | 1,
  isResolvable: (route: NavigationRoute) => boolean,
): { index: number; route: NavigationRoute } | undefined {
  if (history.cursor === undefined) return undefined;
  for (
    let index = history.cursor + offset;
    index >= 0 && index < history.entries.length;
    index += offset
  ) {
    const route = history.entries[index];
    if (isResolvable(route)) return { index, route };
  }
  return undefined;
}

export function canNavigateBack(
  history: NavigationHistory,
  isResolvable: (route: NavigationRoute) => boolean,
): boolean {
  return findRoute(history, -1, isResolvable) !== undefined;
}

export function canNavigateForward(
  history: NavigationHistory,
  isResolvable: (route: NavigationRoute) => boolean,
): boolean {
  return findRoute(history, 1, isResolvable) !== undefined;
}

function step(
  history: NavigationHistory,
  offset: -1 | 1,
  isResolvable: (route: NavigationRoute) => boolean,
): NavigationStep {
  const found = findRoute(history, offset, isResolvable);
  if (!found) return { history };
  return {
    history: { ...history, cursor: found.index },
    route: found.route,
  };
}

export function navigateBack(
  history: NavigationHistory,
  isResolvable: (route: NavigationRoute) => boolean,
): NavigationStep {
  return step(history, -1, isResolvable);
}

export function navigateForward(
  history: NavigationHistory,
  isResolvable: (route: NavigationRoute) => boolean,
): NavigationStep {
  return step(history, 1, isResolvable);
}

export async function traverseNavigation(
  history: NavigationHistory,
  direction: "back" | "forward",
  isResolvable: (route: NavigationRoute) => boolean,
  activate: (route: NavigationRoute) => Promise<boolean>,
): Promise<NavigationStep> {
  const found = findRoute(history, direction === "back" ? -1 : 1, isResolvable);
  if (!found || !(await activate(found.route))) return { history };
  return {
    history: { ...history, cursor: found.index },
    route: found.route,
  };
}

export function navigationRouteForNodeSelection(
  projectPath: string,
  compositePath: readonly string[],
  nodeId: string,
): NavigationRoute {
  return {
    kind: "project",
    projectPath,
    compositePath: [...compositePath],
    nodeId,
  };
}

function graphAtPath(
  root: LoopGraph,
  compositePath: readonly string[],
): LoopGraph | undefined {
  let graph: LoopGraph | undefined = root;
  for (const nodeId of compositePath) {
    graph = graph.nodes.find((node) => node.id === nodeId)?.subGraph;
    if (!graph) return undefined;
  }
  return graph;
}

function graphLocationLabel(
  root: LoopGraph,
  compositePath: readonly string[],
): string {
  const labels = [root.project.name];
  let graph = root;
  for (const nodeId of compositePath) {
    const node = graph.nodes.find((candidate) => candidate.id === nodeId);
    if (!node?.subGraph) break;
    labels.push(node.title);
    graph = node.subGraph;
  }
  return labels.join(" / ");
}

export function resolveNavigationRoute(
  state: AppState,
  route: NavigationRoute,
): ResolvedNavigationRoute | undefined {
  switch (route.kind) {
    case "project": {
      const root = state.graphs[route.projectPath];
      if (!root) return undefined;
      const graph = graphAtPath(root, route.compositePath);
      if (!graph) return undefined;
      const node = route.nodeId
        ? graph.nodes.find((candidate) => candidate.id === route.nodeId)
        : undefined;
      if (route.nodeId && !node) return undefined;
      if (
        route.terminal &&
        (!node || (node.loopType === "proactive" && Boolean(node.subGraph)))
      ) {
        return undefined;
      }
      return {
        route,
        label: node
          ? `${node.title}${route.terminal ? " terminal" : ""}`
          : graphLocationLabel(root, route.compositePath),
      };
    }
    case "mailroom": {
      const graph = state.graphs[route.projectPath];
      if (!graph || graph.project.path === "graphcode://global")
        return undefined;
      return { route, label: `${graph.project.name} Mailroom` };
    }
    case "quickChats":
      return { route, label: "Quick Chats" };
    case "quickChat": {
      const chat = state.quickChats.find(
        (candidate) => candidate.id === route.id,
      );
      return chat ? { route, label: `Quick Chat ${chat.title}` } : undefined;
    }
  }
}
