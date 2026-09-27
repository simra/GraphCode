// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { NewEdgeDialog } from "./NewEdgeDialog";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

afterEach(() => {
  document.body.innerHTML = "";
});

describe("edge editing", () => {
  it("keeps the dialog open and surfaces a daemon refusal", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const onClose = vi.fn();

    await act(async () => {
      root.render(
        <NewEdgeDialog
          nodes={[
            { id: "a", title: "A", state: "idle" },
            { id: "b", title: "B", state: "idle" },
          ]}
          edge={{
            id: "edge",
            from: "a",
            to: "b",
            kind: "handoff",
            condition: "always",
            payloadTransform: { none: {} },
          }}
          onClose={onClose}
          onUpdate={async () => {
            throw new Error(
              "edgeChanged: the edge specification changed before this update",
            );
          }}
        />,
      );
    });

    await act(async () => {
      container.querySelector<HTMLButtonElement>(".primary-button")!.click();
    });

    expect(container.querySelector('[role="alert"]')?.textContent).toContain(
      "edgeChanged",
    );
    expect(container.querySelector('[role="dialog"]')).not.toBeNull();
    expect(onClose).not.toHaveBeenCalled();
    await act(async () => root.unmount());
  });
});
