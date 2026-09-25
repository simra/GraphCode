import {
  useCallback,
  useEffect,
  useMemo,
  useReducer,
  useRef,
  useState,
} from "react";
import {
  sendDaemonCommand,
  startDaemonConnection,
  type DaemonConnection,
} from "./bridge/daemon";
import { pickProjectFolder } from "./bridge/projects";
import {
  commandMatchesShortcut,
  createCommandRegistry,
  isEditableTarget,
  type AppCommand,
  type CommandId,
} from "./commands/registry";
import {
  listenForNativeMenuCommands,
  syncNativeMenu,
} from "./commands/nativeMenu";
import { CommandPalette } from "./components/CommandPalette";
import { ConnectionBanner } from "./components/ConnectionBanner";
import { EditLoopDialog } from "./components/EditLoopDialog";
import { GraphCanvas, type GraphCanvasHandle } from "./components/GraphCanvas";
import { LoopTextDialog } from "./components/LoopTextDialog";
import { NewLoopDialog } from "./components/NewLoopDialog";
import { NodeInspector } from "./components/NodeInspector";
import { initialSnapshotFixture } from "./fixtures/initialSnapshot";
import {
  completeNodeCommand,
  createNodeCommand,
  deleteNodeCommand,
  openProjectCommand,
  refreshUsageCommand,
  renameNodeCommand,
  restartNodeCommand,
  resumeSessionCommand,
  stopNodeCommand,
  type NodeDraftPayload,
  updateNodeCommand,
} from "./protocol/commands";
import { appReducer, initialAppState, selectedNode } from "./state/graphState";
import { deriveProjectNavigation } from "./state/projectNavigation";

export default function App() {
  const [state, dispatch] = useReducer(appReducer, initialAppState);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [newLoopOpen, setNewLoopOpen] = useState(false);
  const [editingLoop, setEditingLoop] = useState<{
    projectPath: string;
    node: NonNullable<ReturnType<typeof selectedNode>>;
  }>();
  const [pendingCreatedNode, setPendingCreatedNode] = useState<{
    projectPath: string;
    nodeId: string;
  }>();
  const [pendingCommandId, setPendingCommandId] = useState<CommandId>();
  const [commandError, setCommandError] = useState<string>();
  const [openingProjectPath, setOpeningProjectPath] = useState<string>();
  const [textDialog, setTextDialog] = useState<
    | {
        kind: "rename" | "complete";
        projectPath: string;
        nodeId: string;
        nodeTitle: string;
      }
    | undefined
  >();
  const graphCanvasRef = useRef<GraphCanvasHandle>(null);

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
  const inspectedNodeState =
    typeof inspectedNode?.state === "string"
      ? inspectedNode.state
      : inspectedNode?.state
        ? Object.keys(inspectedNode.state)[0]
        : undefined;
  const inspectedNodeResolved = Boolean(
    inspectedNodeState &&
    ["succeeded", "failed", "stalled", "stopped"].includes(inspectedNodeState),
  );
  const projectNavigation = useMemo(
    () => deriveProjectNavigation(state.recentProjects, state.graphs),
    [state.graphs, state.recentProjects],
  );
  const requestOpenProject = useCallback(async (path: string) => {
    setOpeningProjectPath(path);
    try {
      const response = await sendDaemonCommand(openProjectCommand(path));
      if (
        response.kind === "response" &&
        response.event?.type === "graphChanged"
      ) {
        setOpeningProjectPath(response.event.graph.project.path);
        dispatch({ type: "envelopeReceived", envelope: response });
      }
    } catch (error) {
      setOpeningProjectPath(undefined);
      throw error;
    }
  }, []);
  const commands = useMemo(
    () =>
      createCommandRegistry(state, {
        openPalette: () => setPaletteOpen(true),
        openProjectFolder:
          "__TAURI_INTERNALS__" in window
            ? async () => {
                const path = await pickProjectFolder();
                if (path) await requestOpenProject(path);
              }
            : undefined,
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
        renameNode:
          selectedProjectPath && inspectedNode
            ? () =>
                setTextDialog({
                  kind: "rename",
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                })
            : undefined,
        editNode:
          selectedProjectPath && inspectedNode
            ? () =>
                setEditingLoop({
                  projectPath: selectedProjectPath,
                  node: inspectedNode,
                })
            : undefined,
        restartSession:
          selectedProjectPath && inspectedNode
            ? async () => {
                const verb = inspectedNodeResolved ? "Resume" : "Restart";
                if (
                  !window.confirm(
                    `${verb} "${inspectedNode.title}" on its preserved transcript?`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  inspectedNodeResolved
                    ? resumeSessionCommand(
                        selectedProjectPath,
                        inspectedNode.id,
                      )
                    : restartNodeCommand(selectedProjectPath, inspectedNode.id),
                );
              }
            : undefined,
        completeNode:
          selectedProjectPath && inspectedNode
            ? () =>
                setTextDialog({
                  kind: "complete",
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                })
            : undefined,
        deleteNode:
          selectedProjectPath && inspectedNode
            ? async () => {
                if (
                  !window.confirm(
                    `Permanently delete "${inspectedNode.title}" and every edge connected to it? This cannot be undone.`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  deleteNodeCommand(selectedProjectPath, inspectedNode.id),
                );
              }
            : undefined,
        refreshUsage: selectedProjectPath
          ? async () => {
              await sendDaemonCommand(refreshUsageCommand(selectedProjectPath));
            }
          : undefined,
        zoomIn: () => graphCanvasRef.current?.zoomIn(),
        zoomOut: () => graphCanvasRef.current?.zoomOut(),
        resetZoom: () => graphCanvasRef.current?.resetZoom(),
        fitGraph: () => graphCanvasRef.current?.fitGraph(),
      }),
    [
      inspectedNode,
      inspectedNodeResolved,
      requestOpenProject,
      selectedProjectPath,
      state,
    ],
  );
  const commandsRef = useRef(commands);
  commandsRef.current = commands;

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

  useEffect(() => {
    if (!openingProjectPath) return;
    const openedPath = Object.keys(state.graphs).find(
      (path) => path.toLowerCase() === openingProjectPath.toLowerCase(),
    );
    if (!openedPath) return;
    dispatch({ type: "selectProject", path: openedPath });
    setOpeningProjectPath(undefined);
  }, [openingProjectPath, state.graphs]);

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
    void syncNativeMenu(commands).catch((error: unknown) => {
      setCommandError(
        `Native menu update failed: ${
          error instanceof Error ? error.message : String(error)
        }`,
      );
    });
  }, [commands]);

  useEffect(() => {
    if (!("__TAURI_INTERNALS__" in window)) return;
    let active = true;
    let unlisten: (() => void) | undefined;
    listenForNativeMenuCommands((id) => {
      const command = commandsRef.current.find(
        (candidate) => candidate.id === id,
      );
      if (command) void executeCommand(command);
    })
      .then((stopListening) => {
        if (active) {
          unlisten = stopListening;
        } else {
          stopListening();
        }
      })
      .catch((error: unknown) => {
        setCommandError(
          `Native menu listener failed: ${
            error instanceof Error ? error.message : String(error)
          }`,
        );
      });
    return () => {
      active = false;
      unlisten?.();
    };
  }, [executeCommand]);

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
  const canvasCommands = commands.filter((command) =>
    command.surfaces.includes("canvas"),
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
            <span>
              {projectNavigation.open.length + projectNavigation.recent.length}
            </span>
          </div>
          {projectNavigation.global ? (
            <button
              className={`overview-link ${
                state.selectedProjectPath === projectNavigation.global.path
                  ? "project-selected"
                  : ""
              }`}
              type="button"
              onClick={() =>
                dispatch({
                  type: "selectProject",
                  path: projectNavigation.global!.path,
                })
              }
            >
              <span aria-hidden="true">⌘</span>
              <span>
                <strong>Overview</strong>
                <small>All open projects</small>
              </span>
            </button>
          ) : null}
          <p className="project-group-label">Open</p>
          <ul className="project-list" aria-label="Open projects">
            {projectNavigation.open.map((project) => (
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
          <p className="project-group-label">Recent</p>
          <ul
            className="project-list recent-project-list"
            aria-label="Recent projects"
          >
            {projectNavigation.recent.map((project) => (
              <li key={project.path}>
                <button
                  type="button"
                  disabled={openingProjectPath === project.path}
                  onClick={() => {
                    setCommandError(undefined);
                    void requestOpenProject(project.path).catch(
                      (error: unknown) =>
                        setCommandError(
                          error instanceof Error
                            ? error.message
                            : String(error),
                        ),
                    );
                  }}
                >
                  <span aria-hidden="true">＋</span>
                  <span>
                    <strong>{project.name}</strong>
                    <small>
                      {openingProjectPath === project.path
                        ? "Opening…"
                        : project.path}
                    </small>
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
            ref={graphCanvasRef}
            graph={selectedGraph}
            selectedNodeId={state.selectedNodeId}
            commands={canvasCommands}
            pendingCommandId={pendingCommandId}
            onExecuteCommand={(command) => void executeCommand(command)}
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
      {editingLoop ? (
        <EditLoopDialog
          node={editingLoop.node}
          onClose={() => setEditingLoop(undefined)}
          onSave={async (update) => {
            await sendDaemonCommand(
              updateNodeCommand(
                editingLoop.projectPath,
                editingLoop.node.id,
                update,
              ),
            );
          }}
        />
      ) : null}
      {textDialog?.kind === "rename" ? (
        <LoopTextDialog
          title={`Rename ${textDialog.nodeTitle}`}
          description="The loop keeps its identity, transcript, edges, and session."
          label="Loop title"
          initialValue={textDialog.nodeTitle}
          required
          submitLabel="Rename"
          onClose={() => setTextDialog(undefined)}
          onSubmit={async (title) => {
            await sendDaemonCommand(
              renameNodeCommand(
                textDialog.projectPath,
                textDialog.nodeId,
                title,
              ),
            );
          }}
        />
      ) : null}
      {textDialog?.kind === "complete" ? (
        <LoopTextDialog
          title={`Complete ${textDialog.nodeTitle}`}
          description="Report this goal as met. An optional result is recorded with the authoritative completion."
          label="Result (optional)"
          multiline
          submitLabel="Mark complete"
          onClose={() => setTextDialog(undefined)}
          onSubmit={async (result) => {
            await sendDaemonCommand(
              completeNodeCommand(
                textDialog.projectPath,
                textDialog.nodeId,
                result || null,
              ),
            );
          }}
        />
      ) : null}
    </main>
  );
}
