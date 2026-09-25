import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import type { LoopNode } from "../protocol/domain";
import { EditLoopDialog } from "./EditLoopDialog";

describe("EditLoopDialog", () => {
  it("renders goal fields and immutable-field guidance", () => {
    const node: LoopNode = {
      id: "node",
      title: "Ship",
      loopType: "goalBased",
      state: "running",
      goal: {
        summary: "All tests pass",
        pollIntervalSeconds: 60,
        metricDirection: "maximize",
        skipsUnchangedWorkspace: false,
      },
    };
    const markup = renderToStaticMarkup(
      <EditLoopDialog
        node={node}
        onClose={() => undefined}
        onSave={async () => undefined}
      />,
    );

    expect(markup).toContain('role="dialog"');
    expect(markup).toContain("Goal and monitoring");
    expect(markup).toContain("immutable after creation");
    expect(markup).toContain("All tests pass");
  });
});
