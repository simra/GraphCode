import type { DaemonWireEnvelope } from "../protocol/domain";

// Faithful to GraphcodeKit's Codable graph shape and the repository's frozen
// graphcode-windows fixtures. It is used only when the native daemon probe fails.
export const initialSnapshotFixture: DaemonWireEnvelope[] = [
  {
    version: 2,
    kind: "event",
    sequence: 1,
    event: {
      type: "recentProjectsListed",
      projects: [
        {
          path: "graphcode://fixtures/react-vertical-slice",
          name: "React vertical slice",
        },
      ],
    },
  },
  {
    version: 2,
    kind: "event",
    sequence: 2,
    event: {
      type: "quickChatsListed",
      chats: [
        {
          id: "77777777-7777-4777-8777-777777777777",
          title: "Review the next frontend slice",
          backend: "copilotCLI",
          createdAt: "2026-09-25T12:00:00Z",
          activity: {
            sequence: 1,
            text: "Ready for a focused question",
            presence: { presence: "idle", confidence: "reported" },
          },
        },
      ],
    },
  },
  {
    version: 2,
    kind: "event",
    sequence: 3,
    event: {
      type: "graphChanged",
      graph: {
        id: "11111111-1111-4111-8111-111111111111",
        revision: 1,
        project: {
          path: "graphcode://fixtures/react-vertical-slice",
          name: "React vertical slice",
        },
        nodes: [
          {
            id: "22222222-2222-4222-8222-222222222222",
            title: "Map protocol",
            loopType: "goalBased",
            backend: "copilotCLI",
            state: { succeeded: {} },
            activity: "Authoritative v2 shapes mapped",
          },
          {
            id: "33333333-3333-4333-8333-333333333333",
            title: "Build React shell",
            loopType: "turnBased",
            backend: "copilotCLI",
            state: { running: {} },
            presence: { presence: "busy", confidence: "reported" },
            activity: "Rendering daemon snapshots",
          },
          {
            id: "44444444-4444-4444-8444-444444444444",
            title: "Stream terminals",
            loopType: "proactive",
            backend: "copilotCLI",
            state: { blocked: {} },
            activity: "Planned for the zmx bridge phase",
          },
        ],
        edges: [
          {
            id: "55555555-5555-4555-8555-555555555555",
            from: "22222222-2222-4222-8222-222222222222",
            to: "33333333-3333-4333-8333-333333333333",
            kind: "handoff",
            condition: "always",
            payloadTransform: "none",
            fireCount: 1,
          },
          {
            id: "66666666-6666-4666-8666-666666666666",
            from: "33333333-3333-4333-8333-333333333333",
            to: "44444444-4444-4444-8444-444444444444",
            kind: "handoff",
            condition: "onSuccess",
            payloadTransform: "none",
            fireCount: 0,
          },
        ],
      },
    },
  },
];
