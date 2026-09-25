import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { ProjectRowActions } from "./ProjectRowActions";

describe("ProjectRowActions", () => {
  it("projects lifecycle descriptions into an accessible row menu", () => {
    const markup = renderToStaticMarkup(
      <ProjectRowActions
        projectName="Graph"
        commands={[
          {
            id: "project.close",
            label: "Close Project",
            description: "Keep it recent",
            category: "Project",
            surfaces: [],
            enabled: true,
            execute: () => undefined,
          },
        ]}
        onExecute={() => undefined}
      />,
    );
    expect(markup).toContain("Actions for Graph");
    expect(markup).toContain('role="menu"');
    expect(markup).toContain("Keep it recent");
  });
});
