import { describe, expect, it, vi } from "vitest";
import type { AppCommand } from "./registry";
import {
  createNativeMenuSynchronizer,
  nativeMenuProjection,
  routeNativeMenuCommand,
} from "./nativeMenu";

describe("native menu projection", () => {
  it("preserves command identity, availability and supported accelerators", () => {
    const commands: AppCommand[] = [
      {
        id: "loop.new",
        label: "New Loop",
        description: "Create",
        category: "Loop",
        shortcut: { key: "n", ctrl: true, label: "Ctrl+N" },
        surfaces: ["header"],
        enabled: true,
        execute: () => undefined,
      },
      {
        id: "loop.openTerminal",
        label: "Open Terminal",
        description: "Open",
        category: "Loop",
        shortcut: { key: "Enter", label: "Enter" },
        surfaces: ["node"],
        enabled: false,
        disabledReason: "Bridge required",
        execute: () => undefined,
      },
    ];

    expect(nativeMenuProjection(commands)).toEqual([
      {
        id: "loop.new",
        label: "New Loop",
        category: "Loop",
        enabled: true,
        accelerator: "Ctrl+N",
      },
      {
        id: "loop.openTerminal",
        label: "Open Terminal",
        category: "Loop",
        enabled: false,
        accelerator: undefined,
      },
    ]);
  });

  it("serializes rebuilds and applies the newest enabled state last", async () => {
    let releaseFirstUpdate: (() => void) | undefined;
    const updates: Array<{
      revision: number;
      commands: ReturnType<typeof nativeMenuProjection>;
    }> = [];
    const update = vi.fn(
      (next: {
        revision: number;
        commands: ReturnType<typeof nativeMenuProjection>;
      }) => {
        updates.push(next);
        if (next.revision !== 1) return Promise.resolve();
        return new Promise<void>((resolve) => {
          releaseFirstUpdate = resolve;
        });
      },
    );
    const synchronize = createNativeMenuSynchronizer(update);
    const command: AppCommand = {
      id: "loop.new",
      label: "New Loop",
      description: "Create",
      category: "Loop",
      surfaces: ["header"],
      enabled: false,
      execute: () => undefined,
    };

    const first = synchronize([command]);
    await vi.waitFor(() => expect(update).toHaveBeenCalledTimes(1));
    const second = synchronize([{ ...command, enabled: true }]);

    expect(update).toHaveBeenCalledTimes(1);
    releaseFirstUpdate?.();
    await Promise.all([first, second]);

    expect(updates).toEqual([
      {
        revision: 1,
        commands: [
          {
            id: "loop.new",
            label: "New Loop",
            category: "Loop",
            enabled: false,
            accelerator: undefined,
          },
        ],
      },
      {
        revision: 2,
        commands: [
          {
            id: "loop.new",
            label: "New Loop",
            category: "Loop",
            enabled: true,
            accelerator: undefined,
          },
        ],
      },
    ]);
  });

  it("routes native selections through the shared command object", () => {
    const execute = vi.fn();
    const command: AppCommand = {
      id: "loop.new",
      label: "New Loop",
      description: "Create",
      category: "Loop",
      surfaces: ["header"],
      enabled: true,
      execute: vi.fn(),
    };

    expect(routeNativeMenuCommand([command], "loop.new", execute)).toBe(true);
    expect(execute).toHaveBeenCalledWith(command);
    expect(routeNativeMenuCommand([command], "selection.clear", execute)).toBe(
      false,
    );
    expect(execute).toHaveBeenCalledTimes(1);
  });
});
