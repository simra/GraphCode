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

  it("explains both supported timed scheduling models", () => {
    const markup = renderToStaticMarkup(
      <EditLoopDialog
        node={{
          id: "timed",
          title: "Weather",
          loopType: "timeBased",
          state: "idle",
          triggerPrompt: "Check the weather",
          heartbeatIntervalSeconds: 900,
        }}
        onClose={() => undefined}
        onSave={async () => undefined}
      />,
    );

    expect(markup).toContain("graphcoded");
    expect(markup).toContain("/loop 15m task");
    expect(markup).toContain("/every 1h task");
    expect(markup).toContain("Daemon heartbeat interval in seconds");
  });
});
