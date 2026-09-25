import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import type { AppCommand, CommandId, CommandShortcut } from "./registry";

export interface NativeMenuCommand {
  id: CommandId;
  label: string;
  category: string;
  enabled: boolean;
  accelerator?: string;
}

function nativeAccelerator(
  shortcut: CommandShortcut | undefined,
): string | undefined {
  if (!shortcut) return undefined;
  const modifiers = [
    shortcut.ctrl ? "Ctrl" : undefined,
    shortcut.shift ? "Shift" : undefined,
    shortcut.alt ? "Alt" : undefined,
  ].filter(Boolean);
  const key =
    shortcut.key.length === 1 ? shortcut.key.toUpperCase() : shortcut.key;
  if (!modifiers.length && !/^F\d{1,2}$/i.test(key)) return undefined;
  return [...modifiers, key].join("+");
}

export function nativeMenuProjection(
  commands: AppCommand[],
): NativeMenuCommand[] {
  return commands.map((command) => ({
    id: command.id,
    label: command.label,
    category:
      command.category === "Application" ? "GraphCode" : command.category,
    enabled: command.enabled,
    accelerator: nativeAccelerator(command.shortcut),
  }));
}

export async function syncNativeMenu(commands: AppCommand[]): Promise<void> {
  if (!("__TAURI_INTERNALS__" in window)) return;
  await invoke("set_native_menu", {
    commands: nativeMenuProjection(commands),
  });
}

export async function listenForNativeMenuCommands(
  onCommand: (id: CommandId) => void,
): Promise<UnlistenFn> {
  return listen<string>("menu://command", ({ payload }) => {
    onCommand(payload as CommandId);
  });
}
