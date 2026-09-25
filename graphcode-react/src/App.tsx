import { useCallback, useEffect, useMemo, useReducer, useState } from "react";
import {
  sendDaemonCommand,
  startDaemonConnection,
  type DaemonConnection,
} from "./bridge/daemon";
import {
  commandMatchesShortcut,
  createCommandRegistry,
  isEditableTarget,
  type AppCommand,
  type CommandId,
} from "./commands/registry";
import { CommandPalette } from "./components/CommandPalette";
import { ConnectionBanner } from "./components/ConnectionBanner";
import { GraphCanvas } from "./components/GraphCanvas";
import { NewLoopDialog } from "./components/NewLoopDialog";
import { NodeInspector } from "./components/NodeInspector";
import { initialSnapshotFixture } from "./fixtures/initialSnapshot";
import {
  createNodeCommand,
  stopNodeCommand,
  type NodeDraftPayload,
} from "./protocol/commands";
import { appReducer, initialAppState, selectedNode } from "./state/graphState";

export default function App() {
  const [state, dispatch] = useReducer(appReducer, initialAppState);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [newLoopOpen, setNewLoopOpen] = useState(false);
  const [pendingCreatedNode, setPendingCreatedNode] = useState<{
    projectPath: string;
    nodeId: string;
  }>();
  const [pendingCommandId, setPendingCommandId] = useState<CommandId>();
  const [commandError, setCommandError] = useState<string>();

  useEffect(() => {
    let active = true;
    let connection: DaemonConnection | undefined;
    dispatch({ type: "connectionStarted" });
    startDaemonConnection({
      onEnvelope(envelope) {
        if (!active) return;
        dispatch({ type: "envelopeReceived", envelope });
      },
      onStatus(status) {
        if (!active) return;
        dispatch({
          type: "connectionStatus",
          phase: status.phase,
          endpoint: status.endpoint,
          message: status.message,
        });
      },
      onError(error) {
        if (!active) return;
        dispatch({ type: "connectionFailed", message: error.message });
      },
    })
      .then((startedConnection) => {
        if (!active) {
          void startedConnection.dispose();
          return;
        }
        connection = startedConnection;
      })
      .catch((error: unknown) => {
        if (!active) return;
        const message = error instanceof Error ? error.message : String(error);
        if ("__TAURI_INTERNALS__" in window) {
          dispatch({ type: "connectionFailed", message });
        } else {
          dispatch({ type: "fixtureLoaded", reason: message });
          for (const envelope of initialSnapshotFixture) {
            dispatch({ type: "envelopeReceived", envelope });
          }
        }
      });
    return () => {
      active = false;
      void connection?.dispose();
    };
  }, []);

  const selectedGraph = state.selectedProjectPath
    ? state.graphs[state.selectedProjectPath]
    : undefined;
  const selectedProjectPath = state.selectedProjectPath;
  const inspectedNode = selectedNode(state);
  const projects = useMemo(() => {
    const byPath = new Map(
      state.recentProjects.map((project) => [project.path, project]),
    );
    for (const graph of Object.values(state.graphs)) {
      byPath.set(graph.project.path, graph.project);
    }
    return [...byPath.values()];
  }, [state.graphs, state.recentProjects]);
  const commands = useMemo(
    () =>
      createCommandRegistry(state, {
        openPalette: () => setPaletteOpen(true),
        openNewLoop: () => setNewLoopOpen(true),
        clearSelection: () => dispatch({ type: "clearNodeSelection" }),
        selectNode: (nodeId) => {
          if (!state.selectedProjectPath) return;
          dispatch({
            type: "selectNode",
            projectPath: state.selectedProjectPath,
            nodeId,
          });
        },
        stopNode:
          selectedProjectPath && inspectedNode
            ? async () => {
                if (
                  !window.confirm(
                    `Stop "${inspectedNode.title}"? Its transcript and graph node will be preserved.`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  stopNodeCommand(selectedProjectPath, inspectedNode.id),
                );
              }
            : undefined,
      }),
    [inspectedNode, selectedProjectPath, state],
  );

  useEffect(() => {
    if (!pendingCreatedNode) return;
    const graph = state.graphs[pendingCreatedNode.projectPath];
    if (!graph?.nodes.some((node) => node.id === pendingCreatedNode.nodeId)) {
      return;
    }
    dispatch({
      type: "selectNode",
      projectPath: pendingCreatedNode.projectPath,
      nodeId: pendingCreatedNode.nodeId,
    });
    setPendingCreatedNode(undefined);
  }, [pendingCreatedNode, state.graphs]);

  const executeCommand = useCallback(async (command: AppCommand) => {
    if (!command.enabled) return;
    setPendingCommandId(command.id);
    setCommandError(undefined);
    try {
      await command.execute();
      if (command.id !== "app.commandPalette") {
        setPaletteOpen(false);
      }
    } catch (error) {
      setCommandError(error instanceof Error ? error.message : String(error));
    } finally {
      setPendingCommandId(undefined);
    }
  }, []);

  useEffect(() => {
    const handleShortcut = (event: KeyboardEvent) => {
      if (paletteOpen && event.key === "Escape") {
        event.preventDefault();
        setPaletteOpen(false);
        return;
      }
      const command = commands.find((candidate) =>
        commandMatchesShortcut(candidate, event),
      );
      if (!command) return;
      if (isEditableTarget(event.target) && command.shortcut?.global !== true) {
        return;
      }
      event.preventDefault();
      void executeCommand(command);
    };
    window.addEventListener("keydown", handleShortcut);
    return () => window.removeEventListener("keydown", handleShortcut);
  }, [commands, executeCommand, paletteOpen]);

  const headerCommands = commands.filter((command) =>
    command.surfaces.includes("header"),
  );
  const nodeCommands = commands.filter((command) =>
    command.surfaces.includes("node"),
  );

  return (
    <main className="app-shell">
      <aside className="sidebar" aria-label="GraphCode navigation">
        <div className="brand">
          <span className="brand-mark" aria-hidden="true">
            G
          </span>
          <div>
            <strong>GraphCode</strong>
            <span>React preview</span>
          </div>
        </div>
        <nav aria-labelledby="projects-heading">
          <div className="section-heading">
            <h2 id="projects-heading">Projects</h2>
            <span>{projects.length}</span>
          </div>
          <ul className="project-list">
            {projects.map((project) => (
              <li key={project.path}>
                <button
                  className={
                    project.path === state.selectedProjectPath
                      ? "project-selected"
                      : ""
                  }
                  onClick={() =>
                    dispatch({ type: "selectProject", path: project.path })
                  }
                >
                  <span aria-hidden="true">⌁</span>
                  <span>
                    <strong>{project.name}</strong>
                    <small>{project.path}</small>
                  </span>
                </button>
              </li>
            ))}
          </ul>
        </nav>
        <div className="sidebar-footer">
          <span>Protocol v2</span>
          <span>Sequence {state.lastSequence}</span>
        </div>
      </aside>
      <section className="main-column">
        <header className="app-header">
          <div>
            <p className="eyebrow">Daemon-owned orchestration</p>
            <h1>{selectedGraph?.project.name ?? "GraphCode"}</h1>
          </div>
          <div className="header-actions">
            {headerCommands.map((command) => (
              <button
                key={command.id}
                type="button"
                disabled={!command.enabled || pendingCommandId === command.id}
                title={command.disabledReason}
                onClick={() => void executeCommand(command)}
              >
                {command.label}
                {command.shortcut ? <kbd>{command.shortcut.label}</kbd> : null}
              </button>
            ))}
          </div>
        </header>
        <ConnectionBanner connection={state.connection} />
        {commandError ? (
          <div className="command-error" role="alert">
            {commandError}
          </div>
        ) : null}
        {state.protocolWarnings.length ? (
          <div className="protocol-warning" role="alert">
            {state.protocolWarnings.at(-1)}
          </div>
        ) : null}
        <div className="content-layout">
          <GraphCanvas
            graph={selectedGraph}
            selectedNodeId={state.selectedNodeId}
            onSelectNode={(nodeId) => {
              if (!state.selectedProjectPath) return;
              dispatch({
                type: "selectNode",
                projectPath: state.selectedProjectPath,
                nodeId,
              });
            }}
          />
          <NodeInspector
            graph={selectedGraph}
            node={inspectedNode}
            commands={nodeCommands}
            pendingCommandId={pendingCommandId}
            onClose={() => dispatch({ type: "clearNodeSelection" })}
            onExecuteCommand={(command) => void executeCommand(command)}
          />
        </div>
      </section>
      <CommandPalette
        commands={commands}
        open={paletteOpen}
        pendingCommandId={pendingCommandId}
        onClose={() => setPaletteOpen(false)}
        onExecute={(command) => void executeCommand(command)}
      />
      {newLoopOpen && selectedGraph && selectedProjectPath ? (
        <NewLoopDialog
          projectName={selectedGraph.project.name}
          onClose={() => setNewLoopOpen(false)}
          onCreate={async (draft: NodeDraftPayload) => {
            setPendingCreatedNode({
              projectPath: selectedProjectPath,
              nodeId: draft.id,
            });
            try {
              await sendDaemonCommand(
                createNodeCommand(selectedProjectPath, draft),
              );
            } catch (error) {
              setPendingCreatedNode(undefined);
              throw error;
            }
          }}
        />
      ) : null}
    </main>
  );
}
