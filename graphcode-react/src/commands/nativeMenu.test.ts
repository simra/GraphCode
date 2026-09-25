import { describe, expect, it } from "vitest";
import type { AppCommand } from "./registry";
import { nativeMenuProjection } from "./nativeMenu";

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
});
