import { describe, expect, it } from "vitest";
import codespaceClassification from "../../../graphcode-windows/fixtures/daemon-v2-project-classification-codespace.json";
import localClassification from "../../../graphcode-windows/fixtures/daemon-v2-project-classification-local.json";
import sshClassification from "../../../graphcode-windows/fixtures/daemon-v2-project-classification-ssh.json";
import oversizedGrace from "../../../windows-tests/fixtures/settings/oversized-grace.json";
import { decodeEnvelope, ProtocolDecodeError } from "./decode";
import { MAX_RESOLVED_SESSION_GRACE_MINUTES } from "./domain";

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

  it("decodes authoritative project metadata and accepts legacy references", () => {
    const current = [
      decodeEnvelope(localClassification),
      decodeEnvelope(sshClassification),
      decodeEnvelope(codespaceClassification),
    ];
    const legacy = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 15,
      event: {
        recentProjectsListed: [{ path: "C:\\same\\project", name: "Legacy" }],
      },
    });

    if (
      current.some(
        (envelope) =>
          envelope.kind !== "event" ||
          envelope.event.type !== "recentProjectsListed",
      ) ||
      legacy.kind !== "event" ||
      legacy.event.type !== "recentProjectsListed"
    ) {
      throw new Error("Expected recent project events");
    }
    const projects = current.map((envelope) => {
      if (
        envelope.kind !== "event" ||
        envelope.event.type !== "recentProjectsListed"
      ) {
        throw new Error("Expected recent project event");
      }
      return envelope.event.projects[0];
    });
    expect(projects.map((project) => project.path)).toEqual([
      "C:\\synthetic\\identical",
      "C:\\synthetic\\identical",
      "C:\\synthetic\\identical",
    ]);
    expect(projects.map((project) => project.metadata?.location)).toEqual([
      "local",
      "ssh",
      "codespace",
    ]);
    expect(legacy.event.projects[0].metadata).toBeUndefined();
  });

  it("defaults omitted capability flags to unsupported", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 16,
      event: {
        recentProjectsListed: [
          {
            path: "C:\\same\\project",
            name: "Partial",
            metadata: {
              location: "ssh",
              capabilities: { diagnostics: true },
            },
          },
        ],
      },
    });

    if (
      envelope.kind !== "event" ||
      envelope.event.type !== "recentProjectsListed"
    ) {
      throw new Error("Expected recent project event");
    }
    expect(envelope.event.projects[0].metadata?.capabilities).toEqual({
      revealInFileManager: false,
      templates: false,
      attachments: false,
      interactiveTerminals: false,
      diagnostics: true,
    });
  });

  it("decodes the shared settings snapshot and application timing", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "event",
      sequence: 14,
      event: {
        settingsChanged: {
          _0: {
            settings: { daemonHeartbeatEnabled: true, futureSetting: 7 },
            revision: "content-revision",
            exists: true,
            supportDirectory: "C:\\fixture",
            filePath: "C:\\fixture\\settings.json",
            fields: [
              { field: "daemonHeartbeatEnabled", timing: "live" },
              { field: "copilotPreferredVersion", timing: "nextSession" },
            ],
          },
        },
      },
    });

    if (
      envelope.kind !== "event" ||
      envelope.event.type !== "settingsChanged"
    ) {
      throw new Error("Expected settingsChanged event");
    }
    expect(envelope.event.snapshot.settings.daemonHeartbeatEnabled).toBe(true);
    expect(envelope.event.snapshot.settings.futureSetting).toBe(7);
    expect(envelope.event.snapshot.fields[1].timing).toBe("nextSession");
  });

  it("normalizes the oversized shared fixture at the protocol boundary", () => {
    expect(MAX_RESOLVED_SESSION_GRACE_MINUTES).toBe(
      Math.floor(Number.MAX_SAFE_INTEGER / 60),
    );
    const envelope = decodeEnvelope({
      version: 2,
      kind: "response",
      requestID: "bootstrap-load",
      event: {
        settingsChanged: {
          _0: {
            settings: oversizedGrace,
            revision: "oversized-fixture",
            exists: true,
            supportDirectory: "C:\\fixture",
            filePath: "C:\\fixture\\settings.json",
            fields: [
              { field: "endsResolvedSessionsAfterMinutes", timing: "live" },
            ],
          },
        },
      },
    });

    if (
      envelope.kind !== "response" ||
      envelope.event?.type !== "settingsChanged"
    ) {
      throw new Error("Expected settingsChanged response");
    }
    expect(
      envelope.event.snapshot.settings.endsResolvedSessionsAfterMinutes,
    ).toBe(MAX_RESOLVED_SESSION_GRACE_MINUTES);
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
              summary: {
                beats: [
                  {
                    id: "beat-1",
                    at: "2026-09-25T00:01:00Z",
                    pass: 2,
                    kind: "editing",
                    text: "Built the workspace rail",
                    evidence: "LoopWorkspaceRail.tsx",
                    endsTurn: false,
                  },
                ],
                passes: [
                  {
                    pass: 1,
                    text: "Mapped the reference",
                    delta: "+3 files",
                  },
                ],
                currentPass: 2,
              },
              board: {
                form: "table",
                title: "Parity",
                direction: "topDown",
                nodes: [],
                edges: [],
                table: {
                  headers: ["Surface", "State"],
                  rows: [["Summary", "Ready"]],
                  alignments: ["leading", "center"],
                },
                source: "| Surface | State |",
                pass: 2,
                composedAt: "2026-09-25T00:02:00Z",
              },
              mailroomWatch: { topic: "build" },
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
    expect(node.mailroomWatch?.topic).toBe("build");
    expect(node.summary?.beats[0].kind).toBe("editing");
    expect(node.summary?.passes[0].delta).toBe("+3 files");
    expect(node.board?.table?.rows[0]).toEqual(["Summary", "Ready"]);
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

  it("decodes a correlated bounded transcript page", () => {
    const envelope = decodeEnvelope({
      version: 2,
      kind: "response",
      requestID: "request",
      event: {
        transcriptPage: {
          _0: {
            nodeID: "11111111-1111-4111-8111-111111111111",
            provider: "claudeCode",
            entries: [
              {
                sourceOffset: 0,
                kind: "prompt",
                text: "[redacted prompt]",
                redactions: ["prompt"],
              },
            ],
            nextCursor: "opaque",
            hasMore: true,
          },
        },
      },
    });

    expect(envelope.kind).toBe("response");
    if (
      envelope.kind !== "response" ||
      envelope.event?.type !== "transcriptPage"
    ) {
      throw new Error("Expected transcriptPage response");
    }
    expect(envelope.event.page.entries[0].redactions).toEqual(["prompt"]);
    expect(envelope.event.page.nextCursor).toBe("opaque");
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
