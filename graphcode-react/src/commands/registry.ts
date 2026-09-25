import type { AppState } from "../state/graphState";
import { selectedNode } from "../state/graphState";

export type CommandId =
  | "app.commandPalette"
  | "loop.new"
  | "loop.stop"
  | "loop.rename"
  | "loop.restartSession"
  | "loop.complete"
  | "loop.delete"
  | "loop.refreshUsage"
  | "loop.edit"
  | "loop.message"
  | "loop.openTerminal"
  | "selection.clear"
  | "selection.nextLoop"
  | "selection.previousLoop";

export type CommandCategory = "Application" | "Loop" | "Navigation";
export type CommandSurface = "header" | "node";

export interface CommandShortcut {
  key: string;
  ctrl?: boolean;
  shift?: boolean;
  alt?: boolean;
  label: string;
  global?: boolean;
}

export interface AppCommand {
  id: CommandId;
  label: string;
  description: string;
  category: CommandCategory;
  shortcut?: CommandShortcut;
  surfaces: CommandSurface[];
  enabled: boolean;
  disabledReason?: string;
  danger?: boolean;
  execute(): void | Promise<void>;
}

export interface CommandActions {
  openPalette(): void;
  openNewLoop?(): void;
  clearSelection(): void;
  selectNode(nodeId: string): void;
  stopNode?(): Promise<void>;
  renameNode?(): void;
  restartSession?(): Promise<void>;
  completeNode?(): void;
  deleteNode?(): Promise<void>;
  refreshUsage?(): Promise<void>;
}

function unavailable(reason: string) {
  return { enabled: false, disabledReason: reason };
}

function encodedCase(
  value: AppState["graphs"][string]["nodes"][number]["state"],
) {
  return typeof value === "string" ? value : Object.keys(value)[0];
}

export function createCommandRegistry(
  state: AppState,
  actions: CommandActions,
): AppCommand[] {
  const graph = state.selectedProjectPath
    ? state.graphs[state.selectedProjectPath]
    : undefined;
  const node = selectedNode(state);
  const connected = state.connection.phase === "connected";
  const nodeResolved =
    node &&
    ["succeeded", "failed", "stalled", "stopped"].includes(
      encodedCase(node.state) ?? "",
    );
  const selectedIndex = graph?.nodes.findIndex(
    (candidate) => candidate.id === node?.id,
  );
  const hasMultipleNodes = (graph?.nodes.length ?? 0) > 1;

  function selectRelativeNode(direction: -1 | 1) {
    if (!graph?.nodes.length) return;
    const current =
      selectedIndex !== undefined && selectedIndex >= 0 ? selectedIndex : 0;
    const next =
      graph.nodes[
        (current + direction + graph.nodes.length) % graph.nodes.length
      ];
    actions.selectNode(next.id);
  }

  return [
    {
      id: "app.commandPalette",
      label: "Show commands",
      description: "Search GraphCode actions and destinations",
      category: "Application",
      shortcut: { key: "p", ctrl: true, label: "Ctrl+P", global: true },
      surfaces: ["header"],
      enabled: true,
      execute: actions.openPalette,
    },
    {
      id: "loop.new",
      label: "New Loop",
      description: "Create a loop in the selected project",
      category: "Loop",
      shortcut: { key: "n", ctrl: true, label: "Ctrl+N" },
      surfaces: ["header"],
      ...(graph
        ? actions.openNewLoop
          ? { enabled: true, execute: actions.openNewLoop }
          : {
              ...unavailable(
                "New Loop dialog is tracked by the next frontend task",
              ),
              execute: () => undefined,
            }
        : {
            ...unavailable("Select an open project first"),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.stop",
      label: "Stop Loop",
      description: "Stop the selected loop without deleting its transcript",
      category: "Loop",
      shortcut: { key: "s", ctrl: true, label: "Ctrl+S" },
      surfaces: ["node"],
      danger: true,
      ...(node
        ? nodeResolved
          ? {
              ...unavailable("This loop is already resolved"),
              execute: () => undefined,
            }
          : connected && actions.stopNode
            ? { enabled: true, execute: actions.stopNode }
            : {
                ...unavailable(
                  "Reconnect to graphcoded before stopping this loop",
                ),
                execute: () => undefined,
              }
        : {
            ...unavailable("Select a loop first"),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.rename",
      label: "Rename Loop",
      description: "Change the selected loop's display title",
      category: "Loop",
      shortcut: { key: "F2", label: "F2" },
      surfaces: ["node"],
      ...(node && connected && actions.renameNode
        ? { enabled: true, execute: actions.renameNode }
        : {
            ...unavailable(
              node
                ? "Reconnect to graphcoded before renaming this loop"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.edit",
      label: "Edit Loop",
      description: "Edit fields supported by NodeUpdate",
      category: "Loop",
      shortcut: { key: "e", ctrl: true, label: "Ctrl+E" },
      surfaces: ["node"],
      ...unavailable(
        node ? "Loop editing is not implemented yet" : "Select a loop first",
      ),
      execute: () => undefined,
    },
    {
      id: "loop.message",
      label: "Message Loop",
      description: "Send an immediate or follow-up message",
      category: "Loop",
      shortcut: { key: "m", ctrl: true, label: "Ctrl+M" },
      surfaces: ["node"],
      ...unavailable(
        node ? "Loop messaging is not implemented yet" : "Select a loop first",
      ),
      execute: () => undefined,
    },
    {
      id: "loop.restartSession",
      label: nodeResolved ? "Resume Session" : "Restart Session",
      description: nodeResolved
        ? "Resume the selected loop on its preserved transcript"
        : "Restart the selected loop's session on its preserved transcript",
      category: "Loop",
      surfaces: ["node"],
      ...(node && connected && actions.restartSession
        ? { enabled: true, execute: actions.restartSession }
        : {
            ...unavailable(
              node
                ? "Reconnect to graphcoded before changing this session"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.complete",
      label: "Mark Goal Complete",
      description: "Report the selected goal loop as complete",
      category: "Loop",
      surfaces: ["node"],
      ...(node?.loopType === "goalBased" && !nodeResolved
        ? connected && actions.completeNode
          ? { enabled: true, execute: actions.completeNode }
          : {
              ...unavailable(
                "Reconnect to graphcoded before completing this goal",
              ),
              execute: () => undefined,
            }
        : {
            ...unavailable(
              node
                ? node.loopType === "goalBased"
                  ? "This goal is already resolved"
                  : "Only goal loops can be marked complete"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.refreshUsage",
      label: "Refresh Usage",
      description: "Ask all backends in this graph for fresh usage readings",
      category: "Loop",
      surfaces: ["node"],
      ...(graph && connected && actions.refreshUsage
        ? { enabled: true, execute: actions.refreshUsage }
        : {
            ...unavailable(
              graph
                ? "Reconnect to graphcoded before refreshing usage"
                : "Select an open project first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.openTerminal",
      label: "Open Terminal",
      description: "Attach to the selected loop's zmx session",
      category: "Loop",
      shortcut: { key: "Enter", label: "Enter" },
      surfaces: ["node"],
      ...unavailable(
        node
          ? "Terminal streaming requires the zmx bridge"
          : "Select a loop first",
      ),
      execute: () => undefined,
    },
    {
      id: "loop.delete",
      label: "Delete Loop",
      description: "Permanently remove the selected loop and its edges",
      category: "Loop",
      surfaces: ["node"],
      danger: true,
      ...(node && connected && actions.deleteNode
        ? { enabled: true, execute: actions.deleteNode }
        : {
            ...unavailable(
              node
                ? "Reconnect to graphcoded before deleting this loop"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "selection.clear",
      label: "Clear Loop Selection",
      description: "Close the loop inspector",
      category: "Navigation",
      shortcut: { key: "Escape", label: "Esc" },
      surfaces: ["node"],
      enabled: Boolean(node),
      disabledReason: node ? undefined : "No loop is selected",
      execute: actions.clearSelection,
    },
    {
      id: "selection.nextLoop",
      label: "Inspect Next Loop",
      description: "Move selection to the next loop in the graph",
      category: "Navigation",
      surfaces: ["node"],
      enabled: hasMultipleNodes,
      disabledReason: hasMultipleNodes
        ? undefined
        : "The selected graph has fewer than two loops",
      execute: () => selectRelativeNode(1),
    },
    {
      id: "selection.previousLoop",
      label: "Inspect Previous Loop",
      description: "Move selection to the previous loop in the graph",
      category: "Navigation",
      surfaces: ["node"],
      enabled: hasMultipleNodes,
      disabledReason: hasMultipleNodes
        ? undefined
        : "The selected graph has fewer than two loops",
      execute: () => selectRelativeNode(-1),
    },
  ];
}

export function commandMatchesShortcut(
  command: AppCommand,
  event: KeyboardEvent,
): boolean {
  const shortcut = command.shortcut;
  if (!shortcut) return false;
  return (
    event.key.toLowerCase() === shortcut.key.toLowerCase() &&
    event.ctrlKey === Boolean(shortcut.ctrl) &&
    event.shiftKey === Boolean(shortcut.shift) &&
    event.altKey === Boolean(shortcut.alt)
  );
}

export function isEditableTarget(target: EventTarget | null): boolean {
  if (!(target instanceof HTMLElement)) return false;
  return (
    target.isContentEditable ||
    target.tagName === "INPUT" ||
    target.tagName === "TEXTAREA" ||
    target.tagName === "SELECT"
  );
}
