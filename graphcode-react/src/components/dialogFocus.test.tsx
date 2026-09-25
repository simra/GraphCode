// @vitest-environment jsdom

import { act, useRef } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import { useDialogFocus } from "./dialogFocus";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

function TestDialog({ onClose }: { onClose(): void }) {
  const initialFocusRef = useRef<HTMLInputElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    initialFocusRef,
    onClose,
  });
  return (
    <section
      ref={dialogRef}
      role="dialog"
      tabIndex={-1}
      onKeyDown={handleDialogKeyDown}
    >
      <input ref={initialFocusRef} aria-label="First" />
      <textarea aria-label="Last" />
      <details>
        <summary>Advanced</summary>
        <button type="button">Closed detail action</button>
      </details>
    </section>
  );
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("useDialogFocus", () => {
  it("focuses the initial control, traps Tab, handles Escape, and restores the invoker", async () => {
    const onClose = vi.fn();
    const invoker = document.createElement("button");
    const container = document.createElement("div");
    document.body.append(invoker, container);
    invoker.focus();
    const root = createRoot(container);

    await act(async () => {
      root.render(<TestDialog onClose={onClose} />);
    });
    const first = container.querySelector("input")!;
    const last = container.querySelector("summary")!;
    expect(document.activeElement).toBe(first);
    expect(
      container.querySelector<HTMLButtonElement>("details button")!.tabIndex,
    ).toBeGreaterThanOrEqual(0);

    last.focus();
    last.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Tab", bubbles: true }),
    );
    expect(document.activeElement).toBe(first);

    first.dispatchEvent(
      new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
    );
    expect(onClose).toHaveBeenCalledOnce();

    await act(async () => {
      root.unmount();
    });
    expect(document.activeElement).toBe(invoker);
  });
});
