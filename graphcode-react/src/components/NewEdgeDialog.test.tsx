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

  it("edits the current spec while keeping identity and endpoints fixed", () => {
    const markup = renderToStaticMarkup(
      <NewEdgeDialog
        nodes={[
          { id: "a", title: "A", state: "idle" },
          { id: "b", title: "B", state: "idle" },
        ]}
        edge={{
          id: "edge",
          from: "a",
          to: "b",
          kind: "message",
          condition: "onFailure",
          payloadTransform: { template: { _0: "Current payload" } },
          cycleGuard: { maxIterations: 4 },
        }}
        onClose={() => undefined}
        onUpdate={async () => undefined}
      />,
    );
    expect(markup).toContain("Edit edge");
    expect(markup).toContain('<option value="a" selected="">A</option>');
    expect(markup).toContain('<option value="b" selected="">B</option>');
    expect(markup.match(/disabled=""/g)).toHaveLength(2);
    expect(markup).toContain(
      '<option value="message" selected="">Message</option>',
    );
    expect(markup).toContain("Current payload");
    expect(markup).toContain('value="4"');
    expect(markup).toContain("Save edge");
  });
});
