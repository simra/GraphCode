import { renderToStaticMarkup } from "react-dom/server";
import { describe, expect, it } from "vitest";
import { SketchPromotionDialog } from "./SketchPromotionDialog";

describe("SketchPromotionDialog", () => {
  it("offers the three supported in-place promotion targets accessibly", () => {
    const markup = renderToStaticMarkup(
      <SketchPromotionDialog
        node={{
          id: "sketch",
          title: "Investigate",
          loopType: "sketch",
          state: "idle",
          firstInstruction: "Inspect the logs",
        }}
        onClose={() => undefined}
        onPromote={async () => undefined}
      />,
    );

    expect(markup).toContain('role="dialog"');
    expect(markup).toContain("Promote Investigate");
    expect(markup).toContain("Goal");
    expect(markup).toContain("Turn");
    expect(markup).toContain("Timed");
    expect(markup).toContain("does not create a replacement loop");
    expect(markup).toContain('disabled=""');
  });

  it("asks a goal loop only for the timed-loop decisions", () => {
    const markup = renderToStaticMarkup(
      <SketchPromotionDialog
        node={{
          id: "goal",
          title: "Keep CI green",
          loopType: "goalBased",
          state: "running",
          goal: {
            summary: "CI passes",
            pollIntervalSeconds: 60,
            metricDirection: "maximize",
            skipsUnchangedWorkspace: false,
          },
        }}
        onClose={() => undefined}
        onPromote={async () => undefined}
      />,
    );

    expect(markup).toContain("Change Keep CI green to Timed");
    expect(markup).toContain("What should each pass do?");
    expect(markup).toContain("Cadence");
    expect(markup).not.toContain("Choose a loop shape");
    expect(markup).not.toContain("Where should it pause?");
  });
});
