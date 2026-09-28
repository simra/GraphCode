// @vitest-environment jsdom

import { act, useState } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AppCommand, CommandId } from "../commands/registry";
import type { LoopGraph, LoopNode, Mailbox } from "../protocol/domain";
import { LoopWorkspaceRail } from "./LoopWorkspaceRail";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const graph: LoopGraph = {
  id: "graph",
  project: { path: "C:\\project", name: "Project" },
  nodes: [],
  edges: [],
};

const populatedNode: LoopNode = {
  id: "loop",
  title: "Build rail",
  state: { running: {} },
  presence: { presence: "busy" },
  lastMailroomRead: 4,
  mailroomWatch: { topic: "release" },
  summary: {
    beats: [
      {
        id: "beat-1",
        at: "2026-09-28T10:00:00Z",
        pass: 1,
        kind: "reading",
        text: "Mapped the reference",
        endsTurn: false,
      },
      {
        id: "beat-2",
        at: "2026-09-28T10:01:00Z",
        pass: 2,
        kind: "editing",
        text: "Built the rail",
        evidence: "LoopWorkspaceRail.tsx",
        endsTurn: false,
      },
    ],
    passes: [{ pass: 1, text: "Mapped the UI", delta: "+3 files" }],
    currentPass: 2,
  },
  board: {
    form: "table",
    direction: "topDown",
    title: "Parity",
    nodes: [],
    edges: [],
    table: {
      headers: ["Surface", "State"],
      rows: [["Summary", "Ready"]],
      alignments: ["leading", "center"],
    },
    source: "| Surface | State |",
    pass: 2,
  },
};

const mailbox: Mailbox = {
  posts: [
    {
      id: 5,
      at: "2026-09-28T10:02:00Z",
      author: "Planner",
      topic: "release",
      body: "Run the full frontend suite.",
      kind: "notice",
    },
  ],
  bodiesTrimmed: false,
  digest: { count: 1, latestID: 5, fingerprint: 5 },
  remaining: 0,
  prunedUnread: 0,
};

function command(id: CommandId, label: string): AppCommand {
  return {
    id,
    label,
    description: label,
    category: "Loop",
    surfaces: ["node"],
    enabled: true,
    execute: () => undefined,
  };
}

const commands = [
  command("loop.mailroomRefresh", "Refresh Mailroom"),
  command("loop.mailroomUnread", "Load Unread Mail"),
  command("loop.mailroomMarkRead", "Read and Advance Loop Cursor"),
  command("loop.mailroomWatch", "Change Mailroom Watch"),
  command("loop.mailroomPost", "Post to Mailroom"),
];

function RailHarness({
  node,
  visible = true,
  initialSeenBeatId = "beat-2",
}: {
  node: LoopNode;
  visible?: boolean;
  initialSeenBeatId?: string;
}) {
  const [seenByNode, setSeenByNode] = useState<Record<string, string>>({
    [node.id]: initialSeenBeatId,
  });
  return visible ? (
    <LoopWorkspaceRail
      graph={graph}
      node={node}
      mailroomOwned
      seenBeatId={seenByNode[node.id]}
      commands={commands}
      onSummarySeen={(beatId) =>
        setSeenByNode((current) => ({ ...current, [node.id]: beatId }))
      }
      onExecuteCommand={() => undefined}
    />
  ) : null;
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("LoopWorkspaceRail", () => {
  it("renders populated summary, board, attention, and Mailroom state", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <LoopWorkspaceRail
          graph={graph}
          node={populatedNode}
          mailbox={mailbox}
          mailroomOwned
          commands={commands}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
        />,
      );
    });

    expect(container.textContent).toContain("Built the rail");
    expect(container.textContent).toContain("Mapped the UI");
    expect(container.textContent).toContain("Parity");
    expect(container.textContent).toContain("1 new");
    expect(container.textContent).toContain("Loop inbox cursor: #4");
    expect(container.textContent).toContain("topic “release”");
    expect(container.querySelector("table")?.textContent).toContain("Summary");

    await act(async () => root.unmount());
  });

  it("reports beats received while unmounted as new when reopened", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<RailHarness node={populatedNode} />);
    });
    const updatedNode = {
      ...populatedNode,
      summary: {
        ...populatedNode.summary!,
        beats: [
          ...populatedNode.summary!.beats,
          {
            id: "beat-3",
            at: "2026-09-28T10:03:00Z",
            pass: 2,
            kind: "running" as const,
            text: "Running focused tests",
            endsTurn: false,
          },
        ],
      },
    };
    await act(async () => {
      root.render(<RailHarness node={updatedNode} visible={false} />);
    });
    expect(container.textContent).toBe("");
    await act(async () => {
      root.render(<RailHarness node={updatedNode} />);
    });
    expect(container.textContent).toContain("1 new");
    const markRead = [...container.querySelectorAll("button")].find(
      (button) => button.textContent === "Mark summary read",
    );
    await act(async () => markRead?.click());
    expect(container.textContent).not.toContain("1 new");

    await act(async () => root.unmount());
  });

  it("executes existing Mailroom commands and fails closed when nested", async () => {
    const onExecute = vi.fn();
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <LoopWorkspaceRail
          graph={graph}
          node={populatedNode}
          mailbox={mailbox}
          mailroomOwned
          seenMailroomPostId={4}
          commands={commands}
          onSummarySeen={() => undefined}
          onExecuteCommand={onExecute}
        />,
      );
    });
    const post = [...container.querySelectorAll("button")].find(
      (button) => button.textContent === "Post to Mailroom",
    );
    await act(async () => post?.click());
    expect(onExecute).toHaveBeenCalledWith(
      expect.objectContaining({ id: "loop.mailroomPost" }),
    );

    await act(async () => {
      root.render(
        <LoopWorkspaceRail
          graph={graph}
          node={populatedNode}
          mailbox={mailbox}
          mailroomOwned={false}
          seenMailroomPostId={4}
          commands={commands.map((item) => ({
            ...item,
            enabled: false,
            disabledReason:
              "Nested Mailroom ownership is not established; return to the project graph",
          }))}
          onSummarySeen={() => undefined}
          onExecuteCommand={onExecute}
        />,
      );
    });
    expect(container.textContent).toContain(
      "Nested Mailroom ownership is not established",
    );
    expect(container.textContent).not.toContain("Run the full frontend suite.");
    expect(
      [...container.querySelectorAll("button")].find(
        (button) => button.textContent === "Post to Mailroom",
      )?.disabled,
    ).toBe(true);

    await act(async () => root.unmount());
  });

  it("collapses empty data into honest supported states", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <LoopWorkspaceRail
          graph={graph}
          node={{ id: "empty", title: "Empty", state: "running" }}
          mailroomOwned
          commands={commands}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
        />,
      );
    });
    expect(container.textContent).toContain("Getting its bearings");
    expect(container.textContent).toContain(
      "Load the project Mailroom to see notices",
    );
    expect(container.textContent).not.toContain("Expand board");

    await act(async () => root.unmount());
  });

  it("keeps human Mailroom seen state separate from the loop inbox cursor", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const onExecute = vi.fn();

    await act(async () => {
      root.render(
        <LoopWorkspaceRail
          graph={graph}
          node={{ ...populatedNode, lastMailroomRead: 5 }}
          mailbox={mailbox}
          mailroomOwned
          seenMailroomPostId={4}
          commands={commands}
          onSummarySeen={() => undefined}
          onExecuteCommand={onExecute}
        />,
      );
    });
    expect(container.textContent).toContain("1 new");
    expect(container.textContent).toContain("Human view: through #4");
    expect(container.textContent).toContain("Loop inbox cursor: #5");

    const advanceCursor = [...container.querySelectorAll("button")].find(
      (button) => button.textContent === "Read and Advance Loop Cursor",
    );
    await act(async () => advanceCursor?.click());
    expect(onExecute).toHaveBeenCalledWith(
      expect.objectContaining({ id: "loop.mailroomMarkRead" }),
    );
    expect(container.textContent).toContain("Human view: through #4");

    await act(async () => root.unmount());
  });

  it("traps expanded-board focus, closes on Escape, and restores the trigger", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <LoopWorkspaceRail
          graph={graph}
          node={populatedNode}
          mailroomOwned
          commands={commands}
          onSummarySeen={() => undefined}
          onExecuteCommand={() => undefined}
        />,
      );
    });
    const expand = [...container.querySelectorAll("button")].find(
      (button) => button.textContent === "Expand board",
    )!;
    expand.focus();
    await act(async () => expand.click());

    const close = container.querySelector<HTMLButtonElement>(
      '[aria-label="Close expanded board"]',
    )!;
    expect(document.activeElement).toBe(close);
    close.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Tab", bubbles: true }),
    );
    expect(document.activeElement).toBe(close);

    await act(async () => {
      close.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
      );
    });
    expect(container.querySelector('[role="dialog"]')).toBeNull();
    expect(document.activeElement).toBe(expand);

    await act(async () => root.unmount());
  });
});
