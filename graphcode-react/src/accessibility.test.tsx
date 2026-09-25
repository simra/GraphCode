// @vitest-environment jsdom

import axe from "axe-core";
import { afterEach, describe, expect, it } from "vitest";
import { renderToStaticMarkup } from "react-dom/server";
import { GraphCanvas } from "./components/GraphCanvas";
import { MailroomView } from "./components/MailroomView";
import { NewEdgeDialog } from "./components/NewEdgeDialog";
import { ProjectGraphTree } from "./components/ProjectGraphTree";
import type { AppCommand } from "./commands/registry";
import type { LoopGraph } from "./protocol/domain";

const graph: LoopGraph = {
  id: "root",
  project: { path: "C:\\project", name: "Project" },
  nodes: [
    {
      id: "parent",
      title: "Parent",
      loopType: "proactive",
      state: "running",
      subGraph: {
        id: "child",
        project: { path: "C:\\project", name: "Project" },
        nodes: [{ id: "child-node", title: "Child", state: "idle" }],
        edges: [],
      },
    },
    { id: "review", title: "Review", loopType: "turnBased", state: "idle" },
  ],
  edges: [
    {
      id: "edge",
      from: "parent",
      to: "review",
      kind: "handoff",
      fireCount: 2,
    },
  ],
};

const refreshCommand: AppCommand = {
  id: "loop.mailroomRefresh",
  label: "Refresh Mailroom",
  description: "Refresh",
  category: "Project",
  surfaces: ["mailroom"],
  enabled: true,
  execute: () => undefined,
};

async function expectNoAxeViolations(markup: string) {
  document.body.innerHTML = markup;
  const result = await axe.run(document.body, {
    rules: {
      "color-contrast": { enabled: false },
    },
  });
  expect(
    result.violations.map(({ id, nodes }) => ({
      id,
      targets: nodes.map((node) => node.target),
    })),
  ).toEqual([]);
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("automated accessibility checks", () => {
  it("checks graph and nested sidebar navigation semantics", async () => {
    await expectNoAxeViolations(
      renderToStaticMarkup(
        <main>
          <GraphCanvas
            graph={graph}
            selectedNodeId="parent"
            onSelectNode={() => undefined}
            onCreateEdge={() => undefined}
          />
          <ProjectGraphTree
            graph={graph}
            compositePath={["parent"]}
            selectedNodeId="child-node"
            onSelectNode={() => undefined}
            onOpenGraph={() => undefined}
          />
        </main>,
      ),
    );
  });

  it("checks Mailroom list/detail and action semantics", async () => {
    await expectNoAxeViolations(
      renderToStaticMarkup(
        <MailroomView
          graph={graph}
          mailbox={{
            posts: [
              {
                id: 7,
                at: "2026-09-25T10:00:00Z",
                author: "Planner",
                topic: "Release",
                body: "Ship the frontend.",
                kind: "letter",
              },
            ],
            bodiesTrimmed: true,
            digest: { count: 1, latestID: 7, fingerprint: 7 },
            remaining: 0,
            prunedUnread: 0,
          }}
          commands={[refreshCommand]}
          commandsForPost={() => [
            {
              ...refreshCommand,
              id: "mailroom.readPost",
              label: "Load Complete Post",
            },
          ]}
          onBack={() => undefined}
          onExecute={() => undefined}
        />,
      ),
    );
  });

  it("checks the keyboard edge editor dialog", async () => {
    await expectNoAxeViolations(
      renderToStaticMarkup(
        <NewEdgeDialog
          nodes={graph.nodes}
          onClose={() => undefined}
          onCreate={async () => undefined}
        />,
      ),
    );
  });
});
