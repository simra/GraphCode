import { describe, expect, it } from "vitest";
import type { DaemonWireEnvelope } from "../protocol/domain";
import { appReducer, initialAppState } from "./graphState";

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
});
