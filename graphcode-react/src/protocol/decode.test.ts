import { describe, expect, it } from "vitest";
import { decodeEnvelope, ProtocolDecodeError } from "./decode";

describe("decodeEnvelope", () => {
  it("decodes the frozen graphChanged event shape", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 12,
      event: {
        graphChanged: {
          id: "graph-local",
          project: { path: "C:\\work\\local", name: "Local Graph" },
          nodes: [
            {
              id: "local-loop",
              title: "Local loop",
              loopType: "turnBased",
              state: { running: {} },
            },
          ],
          edges: [],
        },
      },
    });

    expect(envelope.kind).toBe("event");
    if (envelope.kind !== "event" || envelope.event.type !== "graphChanged") {
      throw new Error("Expected graphChanged event");
    }
    expect(envelope.event.graph.project.path).toBe("C:\\work\\local");
    expect(envelope.event.graph.nodes[0].state).toEqual({ running: {} });
  });

  it("rejects malformed response envelopes instead of silently defaulting", () => {
    expect(() =>
      decodeEnvelope({
        version: 2,
        kind: "response",
        requestID: "request",
      }),
    ).toThrow(ProtocolDecodeError);
  });

  it("retains additive unknown event cases as unsupported events", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 9,
      event: { futureEvent: { value: 1 } },
    });
    expect(envelope.kind).toBe("event");
    if (envelope.kind !== "event") throw new Error("Expected event");
    expect(envelope.event).toEqual({
      type: "unsupported",
      name: "futureEvent",
      payload: { value: 1 },
    });
  });
});
