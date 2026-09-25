import type {
  DaemonEvent,
  DaemonWireEnvelope,
  LoopGraph,
  ProjectRef,
} from "../protocol/domain";

export type ConnectionPhase =
  "idle" | "connecting" | "connected" | "fixture" | "error";

export interface AppState {
  connection: {
    phase: ConnectionPhase;
    endpoint?: string;
    error?: string;
    usingFixture: boolean;
  };
  recentProjects: ProjectRef[];
  graphs: Record<string, LoopGraph>;
  selectedProjectPath?: string;
  lastSequence: number;
  protocolWarnings: string[];
}

export type AppAction =
  | { type: "connectionStarted" }
  | { type: "connectionReady"; endpoint: string }
  | { type: "connectionFailed"; message: string }
  | { type: "fixtureLoaded"; reason: string }
  | { type: "selectProject"; path: string }
  | { type: "envelopeReceived"; envelope: DaemonWireEnvelope };

export const initialAppState: AppState = {
  connection: { phase: "idle", usingFixture: false },
  recentProjects: [],
  graphs: {},
  lastSequence: 0,
  protocolWarnings: [],
};

function applyDaemonEvent(state: AppState, event: DaemonEvent): AppState {
  switch (event.type) {
    case "recentProjectsListed":
      return { ...state, recentProjects: event.projects };
    case "graphChanged": {
      const path = event.graph.project.path;
      return {
        ...state,
        graphs: { ...state.graphs, [path]: event.graph },
        selectedProjectPath: state.selectedProjectPath ?? path,
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
    case "selectProject":
      return state.graphs[action.path]
        ? { ...state, selectedProjectPath: action.path }
        : state;
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
