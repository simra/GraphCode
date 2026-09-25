import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { ProjectGraphTree } from "./ProjectGraphTree";

describe("ProjectGraphTree", () => {
  it("renders nested composite hierarchy and synchronized selection", () => {
    const markup = renderToStaticMarkup(
      <ProjectGraphTree
        graph={{
          id: "root",
          project: { path: "C:\\project", name: "Project" },
          edges: [],
          nodes: [
            {
              id: "parent",
              title: "Parent",
              loopType: "proactive",
              state: "running",
              subGraph: {
                id: "child",
                project: { path: "C:\\project", name: "Project" },
                edges: [],
                nodes: [{ id: "child-node", title: "Child", state: "idle" }],
              },
            },
          ],
        }}
        compositePath={["parent"]}
        selectedNodeId="child-node"
        onSelectNode={() => undefined}
        onOpenGraph={() => undefined}
      />,
    );

    expect(markup).toContain("Project graph hierarchy");
    expect(markup).toContain("Open Parent composite graph");
    expect(markup).toContain("Child");
    expect(markup).toContain('aria-current="true"');
  });
});
