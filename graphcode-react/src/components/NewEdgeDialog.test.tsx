import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { NewEdgeDialog } from "./NewEdgeDialog";

describe("NewEdgeDialog", () => {
  it("exposes endpoints, executable kinds, conditions, transforms, and guards", () => {
    const markup = renderToStaticMarkup(
      <NewEdgeDialog
        nodes={[
          { id: "a", title: "A", state: "idle" },
          { id: "b", title: "B", state: "idle" },
        ]}
        initialFrom="b"
        initialTo="a"
        onClose={() => undefined}
        onCreate={async () => undefined}
      />,
    );
    expect(markup).toContain("Create edge");
    expect(markup).toContain("Handoff");
    expect(markup).toContain("On failure");
    expect(markup).toContain("Payload and cycle options");
    expect(markup).toContain("Maximum iterations");
    expect(markup).toContain('<option value="b" selected="">B</option>');
    expect(markup).toContain('<option value="a" selected="">A</option>');
  });
});
