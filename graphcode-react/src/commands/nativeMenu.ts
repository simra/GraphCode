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

interface NativeMenuUpdate {
  revision: number;
  commands: NativeMenuCommand[];
}

type NativeMenuUpdater = (update: NativeMenuUpdate) => Promise<void>;

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
    shortcut.key.length === 1
      ? shortcut.key.toUpperCase()
      : ({
          ArrowLeft: "Left",
          ArrowRight: "Right",
          ArrowUp: "Up",
          ArrowDown: "Down",
        }[shortcut.key] ?? shortcut.key);
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

export function createNativeMenuSynchronizer(
  update: NativeMenuUpdater,
  initialRevision = 0,
) {
  let revision = initialRevision;
  let tail = Promise.resolve();

  return (commands: AppCommand[]): Promise<void> => {
    const next = {
      revision: ++revision,
      commands: nativeMenuProjection(commands),
    };
    const synchronization = tail
      .catch(() => undefined)
      .then(() => update(next));
    tail = synchronization;
    return synchronization;
  };
}

export function routeNativeMenuCommand(
  commands: AppCommand[],
  id: CommandId,
  execute: (command: AppCommand) => void,
): boolean {
  const command = commands.find((candidate) => candidate.id === id);
  if (!command) return false;
  execute(command);
  return true;
}

const synchronizeNativeMenu = createNativeMenuSynchronizer(
  async ({ revision, commands }) => {
    await invoke("set_native_menu", { revision, commands });
  },
  Date.now() * 1_000,
);

export async function syncNativeMenu(commands: AppCommand[]): Promise<void> {
  if (!("__TAURI_INTERNALS__" in window)) return;
  await synchronizeNativeMenu(commands);
}

export async function listenForNativeMenuCommands(
  onCommand: (id: CommandId) => void,
): Promise<UnlistenFn> {
  return listen<string>("menu://command", ({ payload }) => {
    onCommand(payload as CommandId);
  });
}
