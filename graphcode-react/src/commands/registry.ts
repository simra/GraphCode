import type { AppState } from "../state/graphState";
import { selectedNode } from "../state/graphState";

export type CommandId =
  | "app.commandPalette"
  | "project.openFolder"
  | "project.close"
  | "project.forget"
  | "project.deleteGraph"
  | "loop.new"
  | "loop.stop"
  | "loop.rename"
  | "loop.restartSession"
  | "loop.complete"
  | "loop.delete"
  | "loop.refreshUsage"
  | "loop.edit"
  | "loop.message"
  | "loop.memo"
  | "loop.pilotComposite"
  | "loop.armComposite"
  | "loop.openTerminal"
  | "view.zoomIn"
  | "view.zoomOut"
  | "view.resetZoom"
  | "view.fitGraph"
  | "selection.clear"
  | "selection.nextLoop"
  | "selection.previousLoop";

export type CommandCategory =
  "Application" | "Project" | "Loop" | "View" | "Navigation";
export type CommandSurface = "header" | "node" | "canvas";

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
  openProjectFolder?(): Promise<void>;
  openNewLoop?(): void;
  clearSelection(): void;
  selectNode(nodeId: string): void;
  stopNode?(): Promise<void>;
  renameNode?(): void;
  editNode?(): void;
  messageNode?(): void;
  memoNode?(): void;
  pilotComposite?(): Promise<void>;
  armComposite?(): Promise<void>;
  restartSession?(): Promise<void>;
  completeNode?(): void;
  deleteNode?(): Promise<void>;
  refreshUsage?(): Promise<void>;
  zoomIn?(): void;
  zoomOut?(): void;
  resetZoom?(): void;
  fitGraph?(): void;
}

export interface ProjectRowCommandActions {
  closeProject?(): Promise<void>;
  forgetProject?(): Promise<void>;
  deleteProjectGraph?(): Promise<void>;
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
  const projectGraph =
    graph?.project.path === "graphcode://global" ? undefined : graph;
  const node = selectedNode(state);
  const connected = state.connection.phase === "connected";
  const nodeResolved =
    node &&
    ["succeeded", "failed", "stalled", "stopped"].includes(
      encodedCase(node.state) ?? "",
    );
  const pilotState = node?.pilotState
    ? encodedCase(node.pilotState)
    : "notPiloted";
  const isComposite = node?.loopType === "proactive" && Boolean(node.subGraph);
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
      id: "project.openFolder",
      label: "Open Folder",
      description: "Choose a local folder and open its GraphCode project",
      category: "Project",
      shortcut: { key: "o", ctrl: true, label: "Ctrl+O" },
      surfaces: ["header"],
      ...(connected && actions.openProjectFolder
        ? { enabled: true, execute: actions.openProjectFolder }
        : {
            ...unavailable(
              connected
                ? "Folder selection requires the Tauri desktop client"
                : "Reconnect to graphcoded before opening a project",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.new",
      label: "New Loop",
      description: "Create a loop in the selected project",
      category: "Loop",
      shortcut: { key: "n", ctrl: true, label: "Ctrl+N" },
      surfaces: ["header"],
      ...(projectGraph
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
      ...(node && connected && actions.editNode
        ? { enabled: true, execute: actions.editNode }
        : {
            ...unavailable(
              node
                ? "Reconnect to graphcoded before editing this loop"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.message",
      label: "Message Loop",
      description: "Send an immediate or follow-up message",
      category: "Loop",
      shortcut: { key: "m", ctrl: true, label: "Ctrl+M" },
      surfaces: ["node"],
      ...(node && connected && actions.messageNode
        ? { enabled: true, execute: actions.messageNode }
        : {
            ...unavailable(
              node
                ? "Reconnect to graphcoded before messaging this loop"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.memo",
      label: "Add Memo",
      description: "Append a durable note to the selected loop's memory",
      category: "Loop",
      surfaces: ["node"],
      ...(node && connected && actions.memoNode
        ? { enabled: true, execute: actions.memoNode }
        : {
            ...unavailable(
              node
                ? "Reconnect to graphcoded before adding a memo"
                : "Select a loop first",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.pilotComposite",
      label: "Pilot Composite Once",
      description: "Run the child graph once before enabling its live trigger",
      category: "Loop",
      surfaces: ["node"],
      ...(isComposite
        ? pilotState === "piloting"
          ? {
              ...unavailable("This composite pilot is already running"),
              execute: () => undefined,
            }
          : pilotState === "armed"
            ? {
                ...unavailable("This composite is already armed"),
                execute: () => undefined,
              }
            : connected && actions.pilotComposite
              ? { enabled: true, execute: actions.pilotComposite }
              : {
                  ...unavailable(
                    "Reconnect to graphcoded before piloting this composite",
                  ),
                  execute: () => undefined,
                }
        : {
            ...unavailable("Select a composite with a child graph first"),
            execute: () => undefined,
          }),
    },
    {
      id: "loop.armComposite",
      label: "Arm Composite Schedule",
      description: "Enable the piloted child graph against its live trigger",
      category: "Loop",
      surfaces: ["node"],
      danger: true,
      ...(isComposite
        ? pilotState === "piloted"
          ? connected && actions.armComposite
            ? { enabled: true, execute: actions.armComposite }
            : {
                ...unavailable(
                  "Reconnect to graphcoded before arming this composite",
                ),
                execute: () => undefined,
              }
          : {
              ...unavailable(
                pilotState === "armed"
                  ? "This composite is already armed"
                  : "Pilot this composite successfully before arming it",
              ),
              execute: () => undefined,
            }
        : {
            ...unavailable("Select a composite with a child graph first"),
            execute: () => undefined,
          }),
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
      id: "view.zoomIn",
      label: "Zoom In",
      description: "Magnify the selected graph viewport",
      category: "View",
      shortcut: { key: "=", ctrl: true, label: "Ctrl+=" },
      surfaces: ["canvas"],
      ...(graph && actions.zoomIn
        ? { enabled: true, execute: actions.zoomIn }
        : {
            ...unavailable("Select a graph first"),
            execute: () => undefined,
          }),
    },
    {
      id: "view.zoomOut",
      label: "Zoom Out",
      description: "Reduce the selected graph viewport",
      category: "View",
      shortcut: { key: "-", ctrl: true, label: "Ctrl+-" },
      surfaces: ["canvas"],
      ...(graph && actions.zoomOut
        ? { enabled: true, execute: actions.zoomOut }
        : {
            ...unavailable("Select a graph first"),
            execute: () => undefined,
          }),
    },
    {
      id: "view.resetZoom",
      label: "Reset Zoom",
      description: "Return the graph viewport to 100 percent",
      category: "View",
      shortcut: { key: "0", ctrl: true, label: "Ctrl+0" },
      surfaces: ["canvas"],
      ...(graph && actions.resetZoom
        ? { enabled: true, execute: actions.resetZoom }
        : {
            ...unavailable("Select a graph first"),
            execute: () => undefined,
          }),
    },
    {
      id: "view.fitGraph",
      label: "Fit Graph",
      description: "Fit every loop in the current graph viewport",
      category: "View",
      shortcut: { key: "9", ctrl: true, label: "Ctrl+9" },
      surfaces: ["canvas"],
      ...(graph && actions.fitGraph
        ? { enabled: true, execute: actions.fitGraph }
        : {
            ...unavailable("Select a graph first"),
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

export function createProjectRowCommands(
  connected: boolean,
  isOpen: boolean,
  actions: ProjectRowCommandActions,
): AppCommand[] {
  return [
    {
      id: "project.close",
      label: "Close Project",
      description: "Remove this project from the open list but keep it recent",
      category: "Project",
      surfaces: [],
      ...(isOpen && connected && actions.closeProject
        ? { enabled: true, execute: actions.closeProject }
        : {
            ...unavailable(
              isOpen
                ? "Reconnect to graphcoded before closing this project"
                : "This project is not open",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "project.forget",
      label: "Forget Project",
      description: "Close this project and remove it from recents",
      category: "Project",
      surfaces: [],
      ...(connected && actions.forgetProject
        ? { enabled: true, execute: actions.forgetProject }
        : {
            ...unavailable(
              "Reconnect to graphcoded before forgetting this project",
            ),
            execute: () => undefined,
          }),
    },
    {
      id: "project.deleteGraph",
      label: "Delete Saved Graph",
      description: "Permanently delete the project's saved loops and sessions",
      category: "Project",
      surfaces: [],
      danger: true,
      ...(connected && actions.deleteProjectGraph
        ? { enabled: true, execute: actions.deleteProjectGraph }
        : {
            ...unavailable(
              "Reconnect to graphcoded before deleting this project's graph",
            ),
            execute: () => undefined,
          }),
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
