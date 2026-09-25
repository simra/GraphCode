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

  it("decodes Swift Codable single associated values wrapped under _0", () => {
    const graphEnvelope = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 13,
      event: {
        graphChanged: {
          _0: {
            id: "graph-live",
            project: { path: "C:\\work\\live", name: "Live Graph" },
            nodes: [],
            edges: [],
          },
        },
      },
    });
    const projectsEnvelope = decodeEnvelope({
      version: 2,
      kind: "response",
      requestID: "69ECFAE8-E0D0-48F3-AE5C-BBA390BD0B30",
      event: {
        recentProjectsListed: {
          _0: [{ path: "C:\\work\\live", name: "Live Graph" }],
        },
      },
    });

    expect(graphEnvelope.kind).toBe("event");
    if (
      graphEnvelope.kind !== "event" ||
      graphEnvelope.event.type !== "graphChanged"
    ) {
      throw new Error("Expected graphChanged event");
    }
    expect(graphEnvelope.event.graph.project.name).toBe("Live Graph");

    expect(projectsEnvelope.kind).toBe("response");
    if (
      projectsEnvelope.kind !== "response" ||
      projectsEnvelope.event?.type !== "recentProjectsListed"
    ) {
      throw new Error("Expected recentProjectsListed response");
    }
    expect(projectsEnvelope.event.projects[0].path).toBe("C:\\work\\live");
  });

  it("validates inspector fields already carried by LoopNode snapshots", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 14,
      event: {
        graphChanged: {
          id: "graph",
          project: { path: "C:\\work\\graph", name: "Graph" },
          edges: [],
          nodes: [
            {
              id: "node",
              title: "Goal",
              loopType: "goalBased",
              state: { running: {} },
              backend: "copilotCLI",
              modelTier: "capable",
              goal: {
                summary: "Ship it",
                predicate: "test -f done",
                pollIntervalSeconds: 30,
                stallAfterSeconds: 3600,
                metricCommand: "score",
                metricDirection: "maximize",
                tokenBudget: 5000,
                skipsUnchangedWorkspace: true,
              },
              usage: {
                inputTokens: 100,
                outputTokens: 25,
                costUSD: 0.02,
              },
              metricHistory: [{ value: 4, recordedAt: "2026-09-25T00:00:00Z" }],
              worktreeBinding: {
                id: "worktree",
                repositoryPath: "C:\\work\\graph",
                worktreePath: "C:\\work\\graph-feature",
                branch: "feature",
              },
            },
          ],
        },
      },
    });

    if (envelope.kind !== "event" || envelope.event.type !== "graphChanged") {
      throw new Error("Expected graphChanged event");
    }
    const node = envelope.event.graph.nodes[0];
    expect(node.goal?.tokenBudget).toBe(5000);
    expect(node.usage?.inputTokens).toBe(100);
    expect(node.worktreeBinding?.branch).toBe("feature");
  });

  it("decodes bounded Mailroom responses", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "response",
      requestID: "mailbox-request",
      event: {
        mailbox: {
          projectPath: "C:\\work\\graph",
          mailbox: {
            posts: [
              {
                id: 3,
                at: 788918400,
                authorID: null,
                author: "a human",
                topic: "build",
                body: "Build is green",
                kind: "notice",
              },
            ],
            bodiesTrimmed: false,
            digest: { count: 1, latestID: 3, fingerprint: 42 },
            lastRead: null,
            highestDeliveredID: null,
            remaining: 0,
            prunedUnread: 0,
          },
        },
      },
    });
    if (envelope.kind !== "response" || envelope.event?.type !== "mailbox") {
      throw new Error("Expected mailbox response");
    }
    expect(envelope.event.projectPath).toBe("C:\\work\\graph");
    expect(envelope.event.mailbox.posts[0].body).toBe("Build is green");
  });

  it("decodes Quick Chat snapshots and monotonic activity events", () => {
    const listed = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 15,
      event: {
        quickChatsListed: [
          {
            id: "11111111-1111-4111-8111-111111111111",
            title: "Scratch",
            backend: "claudeCode",
            createdAt: 0,
            activity: {
              sequence: 2,
              text: "editing",
              presence: { presence: "busy", confidence: "reported" },
            },
          },
        ],
      },
    });
    const activity = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 16,
      event: {
        quickChatActivity: {
          id: "11111111-1111-4111-8111-111111111111",
          activity: { sequence: 3, text: "ready", presence: null },
        },
      },
    });

    if (listed.kind !== "event" || listed.event.type !== "quickChatsListed") {
      throw new Error("Expected quickChatsListed event");
    }
    expect(listed.event.chats[0].activity?.text).toBe("editing");
    if (
      activity.kind !== "event" ||
      activity.event.type !== "quickChatActivity"
    ) {
      throw new Error("Expected quickChatActivity event");
    }
    expect(activity.event.activity.sequence).toBe(3);
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
