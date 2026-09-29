import type { AppCommand } from "../commands/registry";
import type { LoopGraph, LoopNode, Mailbox } from "../protocol/domain";
import {
  useEffect,
  useRef,
  type CSSProperties,
  type KeyboardEvent as ReactKeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
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

interface DividerBounds {
  id: string;
  splitId: string;
  dividerIndex: number;
  direction: SplitDirection;
  left: number;
  top: number;
  length: number;
  ownerWidth: number;
  ownerHeight: number;
  value: number;
}

interface TerminalGeometry {
  panes: PaneBounds[];
  dividers: DividerBounds[];
}

function terminalGeometry(
  node: SplitNode,
  left = 0,
  top = 0,
  width = 100,
  height = 100,
): TerminalGeometry {
  if (node.kind === "leaf") {
    return {
      panes: [{ surface: node.surface, left, top, width, height }],
      dividers: [],
    };
  }
  const panes: PaneBounds[] = [];
  const dividers: DividerBounds[] = [];
  let offset = 0;
  node.children.forEach((child, index) => {
    const share = node.sizes[index];
    const childGeometry =
      node.direction === "horizontal"
        ? terminalGeometry(
            child,
            left + width * offset,
            top,
            width * share,
            height,
          )
        : terminalGeometry(
            child,
            left,
            top + height * offset,
            width,
            height * share,
          );
    panes.push(...childGeometry.panes);
    dividers.push(...childGeometry.dividers);
    offset += share;
    if (index < node.children.length - 1) {
      const pairSize = share + node.sizes[index + 1];
      dividers.push({
        id: `${node.id}:${index}`,
        splitId: node.id,
        dividerIndex: index,
        direction: node.direction,
        left: node.direction === "horizontal" ? left + width * offset : left,
        top: node.direction === "vertical" ? top + height * offset : top,
        length: node.direction === "horizontal" ? height : width,
        ownerWidth: width,
        ownerHeight: height,
        value: pairSize > 0 ? Math.round((share / pairSize) * 100) : 50,
      });
    }
  });
  return { panes, dividers };
}

function SplitDivider({
  divider,
  onResize,
}: {
  divider: DividerBounds;
  onResize(delta: number): void;
}) {
  const lastPointerPosition = useRef(0);

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    event.preventDefault();
    const panel = event.currentTarget.parentElement;
    if (!panel) return;
    const panelBounds = panel.getBoundingClientRect();
    const dimension =
      divider.direction === "horizontal"
        ? panelBounds.width * (divider.ownerWidth / 100)
        : panelBounds.height * (divider.ownerHeight / 100);
    if (dimension <= 0) return;
    lastPointerPosition.current =
      divider.direction === "horizontal" ? event.clientX : event.clientY;
    const onPointerMove = (moveEvent: PointerEvent) => {
      const position =
        divider.direction === "horizontal"
          ? moveEvent.clientX
          : moveEvent.clientY;
      const delta = (position - lastPointerPosition.current) / dimension;
      if (delta === 0) return;
      lastPointerPosition.current = position;
      onResize(delta);
    };
    const onPointerUp = () => {
      window.removeEventListener("pointermove", onPointerMove);
      window.removeEventListener("pointerup", onPointerUp);
    };
    window.addEventListener("pointermove", onPointerMove);
    window.addEventListener("pointerup", onPointerUp, { once: true });
  };

  const onKeyDown = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    const decrease =
      divider.direction === "horizontal"
        ? event.key === "ArrowLeft"
        : event.key === "ArrowUp";
    const increase =
      divider.direction === "horizontal"
        ? event.key === "ArrowRight"
        : event.key === "ArrowDown";
    if (!decrease && !increase) return;
    event.preventDefault();
    onResize(increase ? 0.05 : -0.05);
  };

  return (
    <div
      role="separator"
      tabIndex={0}
      aria-label={`Resize ${divider.direction === "horizontal" ? "left and right" : "upper and lower"} terminal panes`}
      aria-orientation={
        divider.direction === "horizontal" ? "vertical" : "horizontal"
      }
      aria-valuemin={10}
      aria-valuemax={90}
      aria-valuenow={divider.value}
      className={`terminal-split-divider terminal-split-divider-${divider.direction}`}
      style={
        {
          "--divider-left": `${divider.left}%`,
          "--divider-top": `${divider.top}%`,
          "--divider-length": `${divider.length}%`,
        } as CSSProperties
      }
      onPointerDown={onPointerDown}
      onKeyDown={onKeyDown}
    />
  );
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
  onResizeSplit,
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
  onResizeSplit(
    tabId: string,
    splitId: string,
    dividerIndex: number,
    delta: number,
  ): void;
  onBack(): void;
  onSummarySeen(beatId: string): void;
  onExecuteCommand(command: AppCommand): void;
  onSessionExit(succeeded: boolean): Promise<void>;
}) {
  const nodeCommands = commands.filter(
    (command) => command.id !== "loop.openTerminal",
  );
  const historyCommand = commands.find(
    (command) => command.id === "loop.openHistory",
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
        {historyCommand ? (
          <button
            type="button"
            className="workspace-history-button"
            disabled={!historyCommand.enabled}
            title={historyCommand.disabledReason}
            onClick={() => onExecuteCommand(historyCommand)}
          >
            Session history
          </button>
        ) : null}
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
                  {layout.tabs.length > 1 ||
                  !terminalSurfaces(tab.root).some(
                    (surface) => surface.kind === "node",
                  ) ? (
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
              const geometry = terminalGeometry(tab.root);
              return (
                <div
                  key={tab.id}
                  role="tabpanel"
                  hidden={!selected}
                  className="terminal-tab-panel"
                >
                  {geometry.panes.map(
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
                              closePane(layout, tab.id, surface.id, node.id),
                            )
                          }
                          onSessionExit={onSessionExit}
                        />
                      </div>
                    ),
                  )}
                  {geometry.dividers.map((divider) => (
                    <SplitDivider
                      key={divider.id}
                      divider={divider}
                      onResize={(delta) =>
                        onResizeSplit(
                          tab.id,
                          divider.splitId,
                          divider.dividerIndex,
                          delta,
                        )
                      }
                    />
                  ))}
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
