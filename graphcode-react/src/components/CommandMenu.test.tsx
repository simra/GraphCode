// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { AppCommand } from "../commands/registry";
import "../styles.css";
import { CommandMenu } from "./CommandMenu";
import { InspectorPane } from "./InspectorPane";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const commands: AppCommand[] = [
  {
    id: "loop.rename",
    label: "Rename Loop",
    description: "Rename",
    category: "Loop",
    surfaces: ["node"],
    enabled: true,
    execute: () => undefined,
  },
  {
    id: "loop.delete",
    label: "Delete Loop",
    description: "Delete",
    category: "Loop",
    surfaces: ["node"],
    enabled: true,
    danger: true,
    execute: () => undefined,
  },
];

afterEach(() => {
  document.body.innerHTML = "";
});

describe("CommandMenu", () => {
  it("portals above clipping containers and keeps the menu inside the viewport", async () => {
    const container = document.createElement("div");
    container.style.overflow = "hidden";
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <CommandMenu commands={commands} onExecute={() => undefined} />,
      );
    });
    const trigger = container.querySelector<HTMLButtonElement>("button")!;
    Object.defineProperty(trigger, "getBoundingClientRect", {
      value: () => ({
        x: 980,
        y: 700,
        left: 980,
        top: 700,
        right: 1060,
        bottom: 734,
        width: 80,
        height: 34,
        toJSON: () => undefined,
      }),
    });
    Object.defineProperties(window, {
      innerWidth: { configurable: true, value: 1024 },
      innerHeight: { configurable: true, value: 768 },
    });

    await act(async () => {
      trigger.click();
    });
    await act(async () => undefined);

    const menu = document.body.querySelector<HTMLElement>(
      ".command-menu-popover",
    )!;
    expect(menu).not.toBeNull();
    expect(container.contains(menu)).toBe(false);
    expect(getComputedStyle(menu).position).toBe("fixed");
    expect(getComputedStyle(menu).zIndex).toBe("200");
    expect(Number.parseFloat(menu.style.left)).toBeGreaterThanOrEqual(8);
    expect(Number.parseFloat(menu.style.top)).toBeGreaterThanOrEqual(8);
    expect(trigger.getAttribute("aria-expanded")).toBe("true");

    await act(async () => {
      root.unmount();
    });
  });

  it("supports keyboard navigation, Escape focus restoration, and outside click", async () => {
    const onExecute = vi.fn();
    const container = document.createElement("div");
    const outside = document.createElement("button");
    document.body.append(container, outside);
    const root = createRoot(container);

    await act(async () => {
      root.render(<CommandMenu commands={commands} onExecute={onExecute} />);
    });
    const trigger = container.querySelector<HTMLButtonElement>("button")!;
    trigger.focus();

    await act(async () => {
      trigger.dispatchEvent(
        new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
      );
    });
    await act(async () => undefined);
    const items = [
      ...document.body.querySelectorAll<HTMLButtonElement>('[role="menuitem"]'),
    ];
    expect(document.activeElement).toBe(items[0]);

    items[0].dispatchEvent(
      new KeyboardEvent("keydown", { key: "ArrowDown", bubbles: true }),
    );
    expect(document.activeElement).toBe(items[1]);

    await act(async () => {
      items[1].dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
      );
    });
    await act(async () => undefined);
    expect(document.body.querySelector('[role="menu"]')).toBeNull();
    expect(document.activeElement).toBe(trigger);

    await act(async () => {
      trigger.click();
    });
    await act(async () => undefined);
    await act(async () => {
      outside.dispatchEvent(new PointerEvent("pointerdown", { bubbles: true }));
    });
    expect(document.body.querySelector('[role="menu"]')).toBeNull();

    await act(async () => {
      root.unmount();
    });
  });

  it("closes only the menu on Escape when hosted in an open inspector", async () => {
    const closeInspector = vi.fn();
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(
        <InspectorPane selectionKey="node:a" onClose={closeInspector}>
          <CommandMenu commands={commands} onExecute={() => undefined} />
        </InspectorPane>,
      );
    });
    const trigger = container.querySelector<HTMLButtonElement>(
      "[aria-haspopup='menu']",
    )!;
    await act(async () => {
      trigger.click();
    });
    await act(async () => undefined);
    const firstItem =
      document.body.querySelector<HTMLButtonElement>('[role="menuitem"]')!;

    await act(async () => {
      firstItem.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
      );
    });

    expect(document.body.querySelector('[role="menu"]')).toBeNull();
    expect(closeInspector).not.toHaveBeenCalled();
    expect(document.activeElement).toBe(trigger);

    await act(async () => {
      root.unmount();
    });
  });
});
