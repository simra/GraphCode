import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { LoopGraph, LoopNode } from "../protocol/domain";
import { NodeInspector } from "./NodeInspector";

const node: LoopNode = {
  id: "11111111-1111-4111-8111-111111111111",
  title: "Improve tests",
  loopType: "goalBased",
  state: { running: {} },
  backend: "copilotCLI",
  modelTier: "capable",
  firstInstruction: "Inspect the failing suite",
  goal: {
    summary: "All tests pass",
    predicate: "swift test",
    pollIntervalSeconds: 60,
    stallAfterSeconds: 3600,
    metricCommand: "count-failures",
    metricDirection: "minimize",
    tokenBudget: 10000,
    skipsUnchangedWorkspace: true,
  },
  usage: { inputTokens: 50, outputTokens: 25, costUSD: 0.01 },
  metricHistory: [{ value: 2, recordedAt: "2026-09-25T00:00:00Z" }],
  attachments: [],
  mailroomWatch: { topic: "build" },
};

const graph: LoopGraph = {
  id: "22222222-2222-4222-8222-222222222222",
  project: { path: "C:\\work\\graph", name: "Graph" },
  nodes: [node],
  edges: [],
};

describe("NodeInspector", () => {
  it("renders an accessible empty state", () => {
    const markup = renderToStaticMarkup(
      <NodeInspector onClose={() => undefined} />,
    );
    expect(markup).toContain('aria-label="Loop inspector"');
    expect(markup).toContain("No loop selected");
  });

  it("renders snapshot-backed brief, goal, usage, and investigation state", () => {
    const markup = renderToStaticMarkup(
      <NodeInspector graph={graph} node={node} onClose={() => undefined} />,
    );
    expect(markup).toContain("Improve tests");
    expect(markup).toContain("All tests pass");
    expect(markup).toContain("10,000");
    expect(markup).toContain("Requires daemon investigation DT-001");
    expect(markup).toContain("Topic: build");
    expect(markup).toContain('aria-label="Close loop inspector"');
  });

  it("renders authoritative Mailroom cursor metadata", () => {
    const markup = renderToStaticMarkup(
      <NodeInspector
        graph={graph}
        node={node}
        mailbox={{
          posts: [],
          bodiesTrimmed: false,
          digest: { count: 3, latestID: 9, fingerprint: 42 },
          lastRead: 4,
          highestDeliveredID: 8,
          remaining: 1,
          prunedUnread: 2,
        }}
        onClose={() => undefined}
      />,
    );
    expect(markup).toContain("Highest delivered");
    expect(markup).toContain("Unread remaining");
    expect(markup).toContain("Pruned unread");
  });

  it("does not repeat matching state and presence badges", () => {
    const markup = renderToStaticMarkup(
      <NodeInspector
        graph={graph}
        node={{ ...node, state: "idle", presence: { presence: "idle" } }}
        onClose={() => undefined}
      />,
    );
    expect(markup.match(/status-badge status-idle/g)).toHaveLength(1);
    expect(markup).not.toContain("<dt>Presence</dt>");
  });

  it("shows a timed schedule without irrelevant inert actions", () => {
    const markup = renderToStaticMarkup(
      <NodeInspector
        graph={graph}
        node={{
          ...node,
          loopType: "timeBased",
          triggerPrompt: "Check the weather",
          heartbeatIntervalSeconds: 900,
        }}
        commands={[
          {
            id: "loop.edit",
            label: "Edit Loop",
            description: "Edit",
            category: "Loop",
            surfaces: ["node"],
            enabled: true,
            execute: () => undefined,
          },
          {
            id: "loop.openComposite",
            label: "Open Composite",
            description: "Open",
            category: "Loop",
            surfaces: ["node"],
            enabled: false,
            execute: () => undefined,
          },
          {
            id: "loop.openTerminal",
            label: "Open Terminal",
            description: "Open",
            category: "Loop",
            surfaces: ["node"],
            enabled: false,
            execute: () => undefined,
          },
        ]}
        onClose={() => undefined}
      />,
    );
    expect(markup).toContain("GraphCode daemon heartbeat");
    expect(markup).toContain("15 minutes");
    expect(markup).not.toContain("Open Composite");
    expect(markup).not.toContain("Open Terminal");
  });
});
