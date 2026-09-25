import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { LoopTextDialog } from "./LoopTextDialog";

describe("LoopTextDialog", () => {
  it("renders an accessible required text command", () => {
    const markup = renderToStaticMarkup(
      <LoopTextDialog
        title="Rename loop"
        description="Keep the stable loop identity."
        label="Loop title"
        initialValue="Current title"
        required
        submitLabel="Rename"
        onClose={() => undefined}
        onSubmit={async () => undefined}
      />,
    );

    expect(markup).toContain('role="dialog"');
    expect(markup).toContain('aria-modal="true"');
    expect(markup).toContain("Current title");
    expect(markup).toContain("Rename");
  });
});
