import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { NewLoopDialog } from "./NewLoopDialog";

describe("NewLoopDialog", () => {
  it("starts with all five domain loop shapes and planned capability IDs", () => {
    const markup = renderToStaticMarkup(
      <NewLoopDialog
        projectName="Graph"
        onClose={() => undefined}
        onCreate={async () => undefined}
      />,
    );

    for (const label of ["Main", "Goal", "Timed", "Turn", "Composite"]) {
      expect(markup).toContain(label);
    }
    expect(markup).toContain('aria-modal="true"');
    expect(markup).toContain("New Loop progress");
  });
});
