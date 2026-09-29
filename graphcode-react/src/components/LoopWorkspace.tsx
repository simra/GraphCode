import type { AppCommand } from "../commands/registry";
import type { LoopGraph, LoopNode, Mailbox } from "../protocol/domain";
import { useEffect, type CSSProperties } from "react";
import {
  addShellTab,
  closePane,
  focusPane,
  selectTab,
  splitFocusedPane,
  terminalSurfaces,
  type SplitDirection,
  type SplitNode,
  type TerminalLayout,
  type TerminalSurface,
  type TerminalTab,
} from "../state/terminalLayout";
import { LoopWorkspaceRail } from "./LoopWorkspaceRail";
import {
  terminalPhaseLabel,
  useTerminalWorkspace,
} from "./useTerminalWorkspace";

function TerminalPane({
  node,
  surface,
  workingDirectory,
  selected,
  focused,
  split,
  onFocus,
  onClose,
  onShellExit,
  onSessionExit,
}: {
  node: LoopNode;
  surface: TerminalSurface;
  workingDirectory?: string;
  selected: boolean;
  focused: boolean;
  split: boolean;
  onFocus(): void;
  onClose(): void;
  onShellExit(): void;
  onSessionExit(succeeded: boolean): Promise<void>;
}) {
  const { containerRef, phase, error, focus } = useTerminalWorkspace(
    surface.kind === "node"
      ? { kind: "node", nodeId: surface.id }
      : { kind: "shell", surfaceId: surface.id, workingDirectory },
    surface.kind === "node"
      ? onSessionExit
      : async () => {
          onShellExit();
        },
    selected && focused,
  );

  return (
    <section
      className={`terminal-pane ${focused ? "terminal-pane-focused" : ""}`}
      aria-label={`${surface.kind === "node" ? node.title : "Local shell"} terminal pane`}
      onMouseDown={() => {
        onFocus();
        focus();
      }}
    >
      <header className="terminal-pane-header">
        <span>
          <strong>{surface.kind === "node" ? "Node" : "Shell"}</strong>
          <small>{surface.kind === "node" ? node.title : "local"}</small>
        </span>
        <span className={`terminal-pane-phase terminal-phase-${phase}`}>
          {terminalPhaseLabel(phase)}
        </span>
        {split ? (
          <button
            type="button"
            className="terminal-pane-close"
            aria-label={`Close ${surface.kind === "node" ? "node" : "shell"} pane`}
            onClick={(event) => {
              event.stopPropagation();
              onClose();
            }}
          >
            ×
          </button>
        ) : null}
      </header>
      {error ? (
        <div className="terminal-error terminal-pane-error" role="alert">
          {error}
        </div>
      ) : null}
      <div ref={containerRef} className="terminal-host" />
    </section>
  );
}

interface PaneBounds {
  surface: TerminalSurface;
  left: number;
  top: number;
  width: number;
  height: number;
}

function paneBounds(
  node: SplitNode,
  left = 0,
  top = 0,
  width = 100,
  height = 100,
): PaneBounds[] {
  if (node.kind === "leaf") {
    return [{ surface: node.surface, left, top, width, height }];
  }
  return node.children.flatMap((child, index) => {
    const share = 1 / node.children.length;
    return node.direction === "horizontal"
      ? paneBounds(
          child,
          left + width * share * index,
          top,
          width * share,
          height,
        )
      : paneBounds(
          child,
          left,
          top + height * share * index,
          width,
          height * share,
        );
  });
}

function tabLabel(tab: TerminalTab, nodeId: string): string {
  return terminalSurfaces(tab.root).some(
    (surface) => surface.kind === "node" && surface.id === nodeId,
  )
    ? "Node"
    : "Shell";
}

export function LoopWorkspace({
  graph,
  node,
  mailbox,
  mailroomOwned,
  seenBeatId,
  seenMailroomPostId,
  commands,
  pendingCommandId,
  layout,
  onLayoutChange,
  onClosePane,
  onCloseTab,
  onBack,
  onSummarySeen,
  onExecuteCommand,
  onSessionExit,
}: {
  graph: LoopGraph;
  node: LoopNode;
  mailbox?: Mailbox;
  mailroomOwned: boolean;
  seenBeatId?: string;
  seenMailroomPostId?: number;
  commands: AppCommand[];
  pendingCommandId?: string;
  layout: TerminalLayout;
  onLayoutChange(layout: TerminalLayout): void;
  onClosePane(tabId: string, surface: TerminalSurface): void;
  onCloseTab(tab: TerminalTab): void;
  onBack(): void;
  onSummarySeen(beatId: string): void;
  onExecuteCommand(command: AppCommand): void;
  onSessionExit(succeeded: boolean): Promise<void>;
}) {
  const nodeCommands = commands.filter(
    (command) => command.id !== "loop.openTerminal",
  );
  const workingDirectory =
    node.worktreeBinding?.worktreePath ??
    (graph.project.path.startsWith("graphcode://")
      ? undefined
      : graph.project.path);

  const split = (direction: SplitDirection) =>
    onLayoutChange(splitFocusedPane(layout, direction));

  useEffect(() => {
    const selectNumberedTab = (event: KeyboardEvent) => {
      if (
        !event.ctrlKey ||
        event.altKey ||
        event.shiftKey ||
        !/^[1-9]$/.test(event.key)
      ) {
        return;
      }
      const tab = layout.tabs[Number(event.key) - 1];
      if (!tab) return;
      event.preventDefault();
      onLayoutChange(selectTab(layout, tab.id));
    };
    window.addEventListener("keydown", selectNumberedTab);
    return () => window.removeEventListener("keydown", selectNumberedTab);
  }, [layout, onLayoutChange]);

  return (
    <section className="loop-workspace" aria-labelledby="loop-workspace-title">
      <header className="loop-workspace-header">
        <div>
          <button type="button" className="workspace-back" onClick={onBack}>
            ← Show in graph
          </button>
          <p className="eyebrow">{graph.project.name}</p>
          <h2 id="loop-workspace-title">{node.title}</h2>
        </div>
      </header>
      <div className="loop-workspace-content">
        <div className="terminal-workspace">
          <div
            className="terminal-tab-bar"
            role="tablist"
            aria-label="Terminal tabs"
          >
            <div className="terminal-tabs">
              {layout.tabs.map((tab, index) => (
                <div
                  className={
                    tab.id === layout.selectedTabId
                      ? "terminal-tab terminal-tab-selected"
                      : "terminal-tab"
                  }
                  key={tab.id}
                >
                  <button
                    type="button"
                    role="tab"
                    aria-selected={tab.id === layout.selectedTabId}
                    onClick={() => onLayoutChange(selectTab(layout, tab.id))}
                  >
                    <span>{tabLabel(tab, node.id)}</span>
                    <kbd>Ctrl+{index + 1}</kbd>
                  </button>
                  {layout.tabs.length > 1 ? (
                    <button
                      type="button"
                      className="terminal-tab-close"
                      aria-label={`Close ${tabLabel(tab, node.id)} tab`}
                      onClick={(event) => {
                        event.stopPropagation();
                        onCloseTab(tab);
                      }}
                    >
                      ×
                    </button>
                  ) : null}
                </div>
              ))}
            </div>
            <div className="terminal-tab-actions">
              <button type="button" onClick={() => split("horizontal")}>
                Split right
              </button>
              <button type="button" onClick={() => split("vertical")}>
                Split down
              </button>
              <button
                type="button"
                onClick={() => onLayoutChange(addShellTab(layout))}
              >
                + Shell
              </button>
            </div>
          </div>
          <div className="terminal-tab-stack">
            {layout.tabs.map((tab) => {
              const selected = tab.id === layout.selectedTabId;
              const surfaces = terminalSurfaces(tab.root);
              return (
                <div
                  key={tab.id}
                  role="tabpanel"
                  hidden={!selected}
                  className="terminal-tab-panel"
                >
                  {paneBounds(tab.root).map(
                    ({ surface, left, top, width, height }) => (
                      <div
                        className="terminal-pane-position"
                        key={surface.id}
                        style={
                          {
                            "--pane-left": `${left}%`,
                            "--pane-top": `${top}%`,
                            "--pane-width": `${width}%`,
                            "--pane-height": `${height}%`,
                          } as CSSProperties
                        }
                      >
                        <TerminalPane
                          node={node}
                          surface={surface}
                          workingDirectory={workingDirectory}
                          selected={selected}
                          focused={surface.id === tab.focusedSurfaceId}
                          split={surfaces.length > 1}
                          onFocus={() =>
                            onLayoutChange(
                              focusPane(layout, tab.id, surface.id),
                            )
                          }
                          onClose={() => onClosePane(tab.id, surface)}
                          onShellExit={() =>
                            onLayoutChange(
                              closePane(layout, tab.id, surface.id),
                            )
                          }
                          onSessionExit={onSessionExit}
                        />
                      </div>
                    ),
                  )}
                </div>
              );
            })}
          </div>
        </div>
        <LoopWorkspaceRail
          graph={graph}
          node={node}
          mailbox={mailbox}
          mailroomOwned={mailroomOwned}
          seenBeatId={seenBeatId}
          seenMailroomPostId={seenMailroomPostId}
          commands={nodeCommands}
          pendingCommandId={pendingCommandId}
          onSummarySeen={onSummarySeen}
          onExecuteCommand={onExecuteCommand}
        />
      </div>
    </section>
  );
}
