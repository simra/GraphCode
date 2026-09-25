import { describe, expect, it } from "vitest";
import type { DaemonWireEnvelope } from "../protocol/domain";
import {
  appReducer,
  initialAppState,
  selectedNode,
  type AppState,
} from "./graphState";

const snapshot: DaemonWireEnvelope = {
  version: 2,
  kind: "event",
  sequence: 5,
  event: {
    type: "graphChanged",
    graph: {
      id: "graph",
      revision: 10,
      project: { path: "C:\\work\\graph", name: "Graph" },
      nodes: [{ id: "node", title: "Node", state: { running: {} } }],
      edges: [],
    },
  },
};

function originalGraph() {
  if (snapshot.kind !== "event" || snapshot.event.type !== "graphChanged") {
    throw new Error("Expected graphChanged fixture");
  }
  return snapshot.event.graph;
}

describe("appReducer", () => {
  it("surfaces reconnect and resync status without using fixture data", () => {
    const reconnecting = appReducer(initialAppState, {
      type: "connectionStatus",
      phase: "reconnecting",
      endpoint: "\\\\.\\pipe\\graphcode-test",
      message: "daemon I/O failed",
    });
    expect(reconnecting.connection).toEqual({
      phase: "reconnecting",
      endpoint: "\\\\.\\pipe\\graphcode-test",
      error: "daemon I/O failed",
      usingFixture: false,
    });

    const resyncing = appReducer(reconnecting, {
      type: "connectionStatus",
      phase: "resyncing",
      endpoint: "\\\\.\\pipe\\graphcode-test",
      message: "Saved replay cursor was unavailable",
    });
    expect(resyncing.connection.phase).toBe("resyncing");
  });

  it("applies snapshots and newer node deltas by stable node ID", () => {
    const withSnapshot = appReducer(initialAppState, {
      type: "envelopeReceived",
      envelope: snapshot,
    });
    const withDelta = appReducer(withSnapshot, {
      type: "envelopeReceived",
      envelope: {
        version: 2,
        kind: "event",
        sequence: 6,
        event: {
          type: "nodesChanged",
          change: {
            projectPath: "C:\\work\\graph",
            revision: 11,
            nodes: [{ id: "node", title: "Node", state: { succeeded: {} } }],
          },
        },
      },
    });

    expect(withDelta.graphs["C:\\work\\graph"].revision).toBe(11);
    expect(withDelta.graphs["C:\\work\\graph"].nodes[0].state).toEqual({
      succeeded: {},
    });
  });

  it("ignores duplicate replay events and stale graph revisions", () => {
    const withSnapshot = appReducer(initialAppState, {
      type: "envelopeReceived",
      envelope: snapshot,
    });
    const duplicate = appReducer(withSnapshot, {
      type: "envelopeReceived",
      envelope: snapshot,
    });
    expect(duplicate).toBe(withSnapshot);

    const stale = appReducer(withSnapshot, {
      type: "envelopeReceived",
      envelope: {
        version: 2,
        kind: "event",
        sequence: 6,
        event: {
          type: "nodesChanged",
          change: {
            projectPath: "C:\\work\\graph",
            revision: 9,
            nodes: [{ id: "node", title: "Wrong", state: "failed" }],
          },
        },
      },
    });
    expect(stale.graphs["C:\\work\\graph"].nodes[0].title).toBe("Node");
  });

  it("keeps node selection by stable ID and clears it when the node disappears", () => {
    const withSnapshot = appReducer(initialAppState, {
      type: "envelopeReceived",
      envelope: snapshot,
    });
    const withSelection = appReducer(withSnapshot, {
      type: "selectNode",
      projectPath: "C:\\work\\graph",
      nodeId: "node",
    });
    expect(selectedNode(withSelection)?.title).toBe("Node");

    const refreshed = appReducer(withSelection, {
      type: "envelopeReceived",
      envelope: {
        ...snapshot,
        sequence: 6,
        event: {
          type: "graphChanged",
          graph: {
            ...originalGraph(),
            revision: 11,
            nodes: [{ id: "node", title: "Renamed", state: { running: {} } }],
          },
        },
      },
    });
    expect(selectedNode(refreshed)?.title).toBe("Renamed");

    const removed = appReducer(refreshed, {
      type: "envelopeReceived",
      envelope: {
        ...snapshot,
        sequence: 7,
        event: {
          type: "graphChanged",
          graph: { ...originalGraph(), revision: 12, nodes: [] },
        },
      },
    });
    expect(removed.selectedNodeId).toBeUndefined();
  });

  it("removes confirmed project state and selects a predictable fallback", () => {
    const state: AppState = {
      ...initialAppState,
      selectedProjectPath: "C:\\work\\B",
      selectedNodeId: "node-b",
      recentProjects: [
        { path: "C:\\work\\B", name: "B" },
        { path: "C:\\work\\C", name: "C" },
      ],
      graphs: {
        "graphcode://global": {
          id: "global",
          project: { path: "graphcode://global", name: "Overview" },
          nodes: [],
          edges: [],
        },
        "C:\\work\\B": {
          id: "b",
          project: { path: "C:\\work\\B", name: "B" },
          nodes: [{ id: "node-b", title: "B", state: "idle" }],
          edges: [],
        },
      },
    };
    const closed = appReducer(state, {
      type: "projectRemoved",
      path: "C:\\work\\B",
      removeFromRecents: false,
    });
    expect(closed.graphs["C:\\work\\B"]).toBeUndefined();
    expect(closed.recentProjects).toHaveLength(2);
    expect(closed.selectedProjectPath).toBe("graphcode://global");
    expect(closed.selectedNodeId).toBeUndefined();

    const forgotten = appReducer(state, {
      type: "projectRemoved",
      path: "C:\\work\\B",
      removeFromRecents: true,
    });
    expect(forgotten.recentProjects.map((project) => project.name)).toEqual([
      "C",
    ]);
  });
});
