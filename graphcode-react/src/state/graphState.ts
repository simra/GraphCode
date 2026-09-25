import type {
  DaemonEvent,
  DaemonWireEnvelope,
  LoopGraph,
  LoopNode,
  Mailbox,
  ProjectRef,
  QuickChat,
} from "../protocol/domain";

export type ConnectionPhase =
  | "idle"
  | "connecting"
  | "connected"
  | "reconnecting"
  | "resyncing"
  | "fixture"
  | "error";

export interface AppState {
  connection: {
    phase: ConnectionPhase;
    endpoint?: string;
    error?: string;
    usingFixture: boolean;
  };
  recentProjects: ProjectRef[];
  graphs: Record<string, LoopGraph>;
  mailboxes: Record<string, Mailbox>;
  quickChats: QuickChat[];
  quickChatsSelected: boolean;
  selectedQuickChatId?: string;
  selectedProjectPath?: string;
  compositePath: string[];
  selectedNodeId?: string;
  lastSequence: number;
  protocolWarnings: string[];
}

export type AppAction =
  | { type: "connectionStarted" }
  | { type: "connectionReady"; endpoint: string }
  | {
      type: "connectionStatus";
      phase: "connecting" | "connected" | "reconnecting" | "resyncing";
      endpoint: string;
      message?: string;
    }
  | { type: "connectionFailed"; message: string }
  | { type: "fixtureLoaded"; reason: string }
  | { type: "selectQuickChats" }
  | { type: "selectQuickChat"; id: string }
  | { type: "selectProject"; path: string }
  | { type: "enterComposite"; nodeId: string }
  | { type: "leaveComposite"; depth: number }
  | {
      type: "projectRemoved";
      path: string;
      removeFromRecents: boolean;
    }
  | { type: "selectNode"; projectPath: string; nodeId: string }
  | { type: "clearNodeSelection" }
  | { type: "envelopeReceived"; envelope: DaemonWireEnvelope };

export const initialAppState: AppState = {
  connection: { phase: "idle", usingFixture: false },
  recentProjects: [],
  graphs: {},
  mailboxes: {},
  quickChats: [],
  quickChatsSelected: false,
  compositePath: [],
  lastSequence: 0,
  protocolWarnings: [],
};

function graphAtPath(
  root: LoopGraph | undefined,
  compositePath: readonly string[],
): LoopGraph | undefined {
  let graph = root;
  for (const nodeId of compositePath) {
    graph = graph?.nodes.find((node) => node.id === nodeId)?.subGraph;
    if (!graph) return undefined;
  }
  return graph;
}

function validCompositePath(
  root: LoopGraph,
  compositePath: readonly string[],
): string[] {
  const valid: string[] = [];
  let graph: LoopGraph | undefined = root;
  for (const nodeId of compositePath) {
    if (!graph) break;
    const child: LoopGraph | undefined = graph.nodes.find(
      (node) => node.id === nodeId,
    )?.subGraph;
    if (!child) break;
    valid.push(nodeId);
    graph = child;
  }
  return valid;
}

function applyDaemonEvent(state: AppState, event: DaemonEvent): AppState {
  switch (event.type) {
    case "recentProjectsListed":
      return { ...state, recentProjects: event.projects };
    case "graphChanged": {
      const path = event.graph.project.path;
      const selectedProjectPath = state.selectedProjectPath ?? path;
      const compositePath =
        selectedProjectPath === path
          ? validCompositePath(event.graph, state.compositePath)
          : state.compositePath;
      const selectedGraph =
        selectedProjectPath === path
          ? graphAtPath(event.graph, compositePath)
          : undefined;
      const selectedNodeId =
        selectedProjectPath === path &&
        state.selectedNodeId &&
        selectedGraph?.nodes.some((node) => node.id === state.selectedNodeId)
          ? state.selectedNodeId
          : selectedProjectPath === path
            ? undefined
            : state.selectedNodeId;
      return {
        ...state,
        graphs: { ...state.graphs, [path]: event.graph },
        selectedProjectPath,
        compositePath,
        selectedNodeId,
      };
    }
    case "nodesChanged": {
      const existing = state.graphs[event.change.projectPath];
      if (!existing) {
        return {
          ...state,
          protocolWarnings: [
            ...state.protocolWarnings,
            `Ignored nodesChanged for ${event.change.projectPath} before its snapshot`,
          ],
        };
      }
      if ((existing.revision ?? -1) >= event.change.revision) {
        return state;
      }
      const changes = new Map(
        event.change.nodes.map((node) => [node.id, node]),
      );
      const graph = {
        ...existing,
        revision: event.change.revision,
        nodes: existing.nodes.map((node) => changes.get(node.id) ?? node),
      };
      return {
        ...state,
        graphs: { ...state.graphs, [event.change.projectPath]: graph },
      };
    }
    case "quickChatsListed": {
      const selectedQuickChatId = event.chats.some(
        (chat) => chat.id === state.selectedQuickChatId,
      )
        ? state.selectedQuickChatId
        : undefined;
      return { ...state, quickChats: event.chats, selectedQuickChatId };
    }
    case "quickChatChanged": {
      const existingIndex = state.quickChats.findIndex(
        (chat) => chat.id === event.chat.id,
      );
      const quickChats =
        existingIndex === -1
          ? [...state.quickChats, event.chat]
          : state.quickChats.map((chat, index) =>
              index === existingIndex ? event.chat : chat,
            );
      return { ...state, quickChats };
    }
    case "quickChatDeleted":
      return {
        ...state,
        quickChats: state.quickChats.filter((chat) => chat.id !== event.id),
        selectedQuickChatId:
          state.selectedQuickChatId === event.id
            ? undefined
            : state.selectedQuickChatId,
      };
    case "quickChatActivity":
      return {
        ...state,
        quickChats: state.quickChats.map((chat) =>
          chat.id === event.id &&
          (chat.activity?.sequence ?? -1) < event.activity.sequence
            ? { ...chat, activity: event.activity }
            : chat,
        ),
      };
    case "mailbox":
      return {
        ...state,
        mailboxes: {
          ...state.mailboxes,
          [event.projectPath]: event.mailbox,
        },
      };
    case "errorOccurred":
      return {
        ...state,
        connection: {
          ...state.connection,
          phase: "error",
          error: event.message,
        },
      };
    case "unsupported":
      return {
        ...state,
        protocolWarnings: [
          ...state.protocolWarnings,
          `Ignored unsupported daemon event ${event.name}`,
        ],
      };
  }
}

export function appReducer(state: AppState, action: AppAction): AppState {
  switch (action.type) {
    case "connectionStarted":
      return {
        ...state,
        connection: { phase: "connecting", usingFixture: false },
      };
    case "connectionReady":
      return {
        ...state,
        connection: {
          phase: "connected",
          endpoint: action.endpoint,
          usingFixture: false,
        },
      };
    case "connectionStatus":
      return {
        ...state,
        connection: {
          phase: action.phase,
          endpoint: action.endpoint,
          error: action.message,
          usingFixture: false,
        },
      };
    case "connectionFailed":
      return {
        ...state,
        connection: {
          phase: "error",
          error: action.message,
          usingFixture: false,
        },
      };
    case "fixtureLoaded":
      return {
        ...state,
        connection: {
          phase: "fixture",
          error: action.reason,
          usingFixture: true,
        },
      };
    case "selectQuickChats":
      return {
        ...state,
        quickChatsSelected: true,
        selectedQuickChatId: undefined,
        compositePath: [],
        selectedNodeId: undefined,
      };
    case "selectQuickChat":
      return state.quickChats.some((chat) => chat.id === action.id)
        ? {
            ...state,
            quickChatsSelected: true,
            selectedQuickChatId: action.id,
            compositePath: [],
            selectedNodeId: undefined,
          }
        : state;
    case "selectProject":
      return state.graphs[action.path]
        ? {
            ...state,
            quickChatsSelected: false,
            selectedQuickChatId: undefined,
            selectedProjectPath: action.path,
            compositePath: [],
            selectedNodeId:
              action.path === state.selectedProjectPath
                ? state.selectedNodeId
                : undefined,
          }
        : state;
    case "enterComposite": {
      const graph = currentGraph(state);
      const node = graph?.nodes.find(
        (candidate) => candidate.id === action.nodeId,
      );
      return node?.subGraph
        ? {
            ...state,
            compositePath: [...state.compositePath, node.id],
            selectedNodeId: undefined,
          }
        : state;
    }
    case "leaveComposite": {
      const depth = Math.max(
        0,
        Math.min(action.depth, state.compositePath.length),
      );
      return {
        ...state,
        compositePath: state.compositePath.slice(0, depth),
        selectedNodeId: undefined,
      };
    }
    case "projectRemoved": {
      const graphs = { ...state.graphs };
      delete graphs[action.path];
      const mailboxes = { ...state.mailboxes };
      delete mailboxes[action.path];
      const recentProjects = action.removeFromRecents
        ? state.recentProjects.filter(
            (project) =>
              project.path.toLowerCase() !== action.path.toLowerCase(),
          )
        : state.recentProjects;
      if (state.selectedProjectPath !== action.path) {
        return { ...state, graphs, mailboxes, recentProjects };
      }
      const fallback =
        graphs["graphcode://global"]?.project.path ??
        Object.values(graphs)
          .map((graph) => graph.project)
          .filter((project) => project.path !== "graphcode://global")
          .sort((left, right) => left.name.localeCompare(right.name))[0]?.path;
      return {
        ...state,
        graphs,
        mailboxes,
        recentProjects,
        selectedProjectPath: fallback,
        compositePath: [],
        selectedNodeId: undefined,
      };
    }
    case "selectNode": {
      const graph =
        action.projectPath === state.selectedProjectPath
          ? currentGraph(state)
          : state.graphs[action.projectPath];
      return graph?.nodes.some((node) => node.id === action.nodeId)
        ? {
            ...state,
            quickChatsSelected: false,
            selectedQuickChatId: undefined,
            selectedProjectPath: action.projectPath,
            selectedNodeId: action.nodeId,
          }
        : state;
    }
    case "clearNodeSelection":
      return { ...state, selectedNodeId: undefined };
    case "envelopeReceived": {
      const envelope = action.envelope;
      if (envelope.kind === "error") {
        return {
          ...state,
          connection: {
            ...state.connection,
            phase: "error",
            error: `${envelope.error.code}: ${envelope.error.message}`,
          },
        };
      }
      if (envelope.kind !== "event" && envelope.kind !== "response") {
        return state;
      }
      if (
        envelope.kind === "event" &&
        envelope.sequence <= state.lastSequence
      ) {
        return state;
      }
      const withSequence =
        envelope.kind === "event"
          ? { ...state, lastSequence: envelope.sequence }
          : state;
      return envelope.event
        ? applyDaemonEvent(withSequence, envelope.event)
        : withSequence;
    }
  }
}

export function selectedNode(state: AppState): LoopNode | undefined {
  if (!state.selectedNodeId) return undefined;
  return currentGraph(state)?.nodes.find(
    (node) => node.id === state.selectedNodeId,
  );
}

export function currentGraph(state: AppState): LoopGraph | undefined {
  if (!state.selectedProjectPath) return undefined;
  return graphAtPath(
    state.graphs[state.selectedProjectPath],
    state.compositePath,
  );
}

export function selectedQuickChat(state: AppState): QuickChat | undefined {
  if (!state.selectedQuickChatId) return undefined;
  return state.quickChats.find((chat) => chat.id === state.selectedQuickChatId);
}
