import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { EdgeInspector } from "./EdgeInspector";

describe("EdgeInspector", () => {
  it("shows endpoint, delivery, firing, and supported edit details", () => {
    const markup = renderToStaticMarkup(
      <EdgeInspector
        graph={{
          id: "graph",
          project: { path: "C:\\project", name: "Project" },
          nodes: [
            { id: "a", title: "Plan", state: "idle" },
            { id: "b", title: "Build", state: "running" },
          ],
          edges: [],
        }}
        edge={{
          id: "edge-1",
          from: "a",
          to: "b",
          kind: "handoff",
          condition: "onSuccess",
          payloadTransform: { none: {} },
          fireCount: 3,
        }}
        commands={[
          {
            id: "edge.edit",
            label: "Edit Edge",
            description: "Edit",
            category: "Loop",
            surfaces: [],
            enabled: true,
            execute: () => undefined,
          },
          {
            id: "edge.delete",
            label: "Delete Edge",
            description: "Delete",
            category: "Loop",
            surfaces: [],
            enabled: true,
            danger: true,
            execute: () => undefined,
          },
        ]}
        onClose={() => undefined}
        onExecuteCommand={() => undefined}
      />,
    );

    expect(markup).toContain("Plan");
    expect(markup).toContain("Build");
    expect(markup).toContain("handoff");
    expect(markup).toContain("Fired 3 times");
    expect(markup).toContain("Edit Edge");
    expect(markup).toContain("Delete Edge");
    expect(markup).toContain("atomic precondition");
  });
});
