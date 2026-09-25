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
  createEdgeCommands,
  createProjectRowCommands,
  createQuickChatCommands,
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
import { MailroomPostDialog } from "./components/MailroomPostDialog";
import { MailroomWatchDialog } from "./components/MailroomWatchDialog";
import { MessageLoopDialog } from "./components/MessageLoopDialog";
import { NewLoopDialog } from "./components/NewLoopDialog";
import { NewQuickChatDialog } from "./components/NewQuickChatDialog";
import { NewEdgeDialog } from "./components/NewEdgeDialog";
import { NodeInspector } from "./components/NodeInspector";
import { ProjectRowActions } from "./components/ProjectRowActions";
import { QuickChatsView } from "./components/QuickChatsView";
import { initialSnapshotFixture } from "./fixtures/initialSnapshot";
import {
  addressGraphCommand,
  armCompositeCommand,
  closeProjectCommand,
  completeNodeCommand,
  createEdgeCommand,
  createNodeCommand,
  createQuickChatCommand,
  deleteQuickChatCommand,
  deleteNodeCommand,
  deleteEdgeCommand,
  deleteProjectGraphCommand,
  forgetProjectCommand,
  mailboxCommand,
  mailboxSearchCommand,
  mailboxUnreadCommand,
  mailroomPostCommand,
  mailroomWatchCommand,
  memoNodeCommand,
  messageNodeCommand,
  openQuickChatCommand,
  openProjectCommand,
  pilotCompositeCommand,
  refreshUsageCommand,
  refineNodeCommand,
  renameNodeCommand,
  renameQuickChatCommand,
  restartNodeCommand,
  resumeSessionCommand,
  rollbackRefinementCommand,
  stopNodeCommand,
  type NodeDraftPayload,
  type GraphCommandEnvelope,
  updateNodeCommand,
} from "./protocol/commands";
import {
  appReducer,
  currentGraph,
  initialAppState,
  selectedNode,
  selectedQuickChat,
} from "./state/graphState";
import { deriveProjectNavigation } from "./state/projectNavigation";

export default function App() {
  const [state, dispatch] = useReducer(appReducer, initialAppState);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [newLoopOpen, setNewLoopOpen] = useState(false);
  const [newQuickChatOpen, setNewQuickChatOpen] = useState(false);
  const [newEdgeOpen, setNewEdgeOpen] = useState(false);
  const [newEdgeEndpoints, setNewEdgeEndpoints] = useState<{
    from?: string;
    to?: string;
  }>();
  const [editingLoop, setEditingLoop] = useState<{
    projectPath: string;
    node: NonNullable<ReturnType<typeof selectedNode>>;
  }>();
  const [messagingLoop, setMessagingLoop] = useState<{
    projectPath: string;
    nodeId: string;
    nodeTitle: string;
  }>();
  const [mailroomPosting, setMailroomPosting] = useState<{
    projectPath: string;
    projectName: string;
  }>();
  const [mailroomWatching, setMailroomWatching] = useState<{
    projectPath: string;
    nodeId: string;
    nodeTitle: string;
    currentTopic?: string;
    watching: boolean;
  }>();
  const [pendingCreatedNode, setPendingCreatedNode] = useState<{
    projectPath: string;
    nodeId: string;
  }>();
  const [pendingCommandId, setPendingCommandId] = useState<CommandId>();
  const [commandError, setCommandError] = useState<string>();
  const [openingProjectPath, setOpeningProjectPath] = useState<string>();
  const [renamingQuickChat, setRenamingQuickChat] = useState<{
    id: string;
    title: string;
  }>();
  const [textDialog, setTextDialog] = useState<
    | {
        kind: "rename" | "complete" | "memo" | "refine" | "mailSearch";
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

  const rootGraph = state.selectedProjectPath
    ? state.graphs[state.selectedProjectPath]
    : undefined;
  const selectedGraph = currentGraph(state);
  const selectedProjectPath = state.selectedProjectPath;
  const inspectedNode = selectedNode(state);
  const inspectedQuickChat = selectedQuickChat(state);
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
  const compositeBreadcrumbs = useMemo(() => {
    if (!rootGraph) return [];
    const breadcrumbs = [{ depth: 0, label: rootGraph.project.name }];
    let graph = rootGraph;
    state.compositePath.forEach((nodeId, index) => {
      const node = graph.nodes.find((candidate) => candidate.id === nodeId);
      if (!node?.subGraph) return;
      breadcrumbs.push({ depth: index + 1, label: node.title });
      graph = node.subGraph;
    });
    return breadcrumbs;
  }, [rootGraph, state.compositePath]);
  const routeGraphCommand = useCallback(
    <TCommand,>(command: GraphCommandEnvelope<TCommand>) =>
      addressGraphCommand(command, state.compositePath),
    [state.compositePath],
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
        openNewQuickChat: () => setNewQuickChatOpen(true),
        openNewEdge: () => {
          setNewEdgeEndpoints({ from: inspectedNode?.id });
          setNewEdgeOpen(true);
        },
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
                  routeGraphCommand(
                    stopNodeCommand(selectedProjectPath, inspectedNode.id),
                  ),
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
        messageNode:
          selectedProjectPath && inspectedNode
            ? () =>
                setMessagingLoop({
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                })
            : undefined,
        memoNode:
          selectedProjectPath && inspectedNode
            ? () =>
                setTextDialog({
                  kind: "memo",
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                })
            : undefined,
        refineNode:
          selectedProjectPath && inspectedNode
            ? () =>
                setTextDialog({
                  kind: "refine",
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                })
            : undefined,
        rollbackRefinement:
          selectedProjectPath && inspectedNode
            ? async () => {
                if (
                  !window.confirm(
                    `Restore the previous playbook for "${inspectedNode.title}"? graphcoded will refuse this if no rollback snapshot exists.`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  routeGraphCommand(
                    rollbackRefinementCommand(
                      selectedProjectPath,
                      inspectedNode.id,
                    ),
                  ),
                );
              }
            : undefined,
        openComposite: inspectedNode?.subGraph
          ? () =>
              dispatch({
                type: "enterComposite",
                nodeId: inspectedNode.id,
              })
          : undefined,
        pilotComposite:
          selectedProjectPath && inspectedNode
            ? async () => {
                if (
                  !window.confirm(
                    `Pilot "${inspectedNode.title}" once now? Its unattended child loops will run and incur real backend usage.`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  routeGraphCommand(
                    pilotCompositeCommand(
                      selectedProjectPath,
                      inspectedNode.id,
                    ),
                  ),
                );
              }
            : undefined,
        armComposite:
          selectedProjectPath && inspectedNode
            ? async () => {
                if (
                  !window.confirm(
                    `Arm "${inspectedNode.title}" against its live trigger? This enables its piloted child graph to run on schedule.`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  routeGraphCommand(
                    armCompositeCommand(selectedProjectPath, inspectedNode.id),
                  ),
                );
              }
            : undefined,
        refreshMailroom: selectedProjectPath
          ? async () => {
              await sendDaemonCommand(mailboxCommand(selectedProjectPath));
            }
          : undefined,
        loadUnreadMailroom:
          selectedProjectPath && inspectedNode && !state.compositePath.length
            ? async () => {
                await sendDaemonCommand(
                  mailboxUnreadCommand(
                    selectedProjectPath,
                    inspectedNode.id,
                    false,
                  ),
                );
              }
            : undefined,
        markUnreadMailroomRead:
          selectedProjectPath && inspectedNode && !state.compositePath.length
            ? async () => {
                if (
                  !window.confirm(
                    `Load unread Mailroom posts for "${inspectedNode.title}" and atomically advance its cursor through the delivered slice?`,
                  )
                ) {
                  return;
                }
                await sendDaemonCommand(
                  mailboxUnreadCommand(
                    selectedProjectPath,
                    inspectedNode.id,
                    true,
                  ),
                );
              }
            : undefined,
        searchMailroom:
          selectedProjectPath && inspectedNode && !state.compositePath.length
            ? () =>
                setTextDialog({
                  kind: "mailSearch",
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                })
            : undefined,
        configureMailroomWatch:
          selectedProjectPath && inspectedNode && !state.compositePath.length
            ? () =>
                setMailroomWatching({
                  projectPath: selectedProjectPath,
                  nodeId: inspectedNode.id,
                  nodeTitle: inspectedNode.title,
                  currentTopic: inspectedNode.mailroomWatch?.topic,
                  watching: Boolean(inspectedNode.mailroomWatch),
                })
            : undefined,
        postMailroom:
          selectedProjectPath && selectedGraph
            ? () =>
                setMailroomPosting({
                  projectPath: selectedProjectPath,
                  projectName: selectedGraph.project.name,
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
                    ? routeGraphCommand(
                        resumeSessionCommand(
                          selectedProjectPath,
                          inspectedNode.id,
                        ),
                      )
                    : routeGraphCommand(
                        restartNodeCommand(
                          selectedProjectPath,
                          inspectedNode.id,
                        ),
                      ),
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
                  routeGraphCommand(
                    deleteNodeCommand(selectedProjectPath, inspectedNode.id),
                  ),
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
      routeGraphCommand,
      selectedProjectPath,
      selectedGraph,
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

  function quickChatCommands(chat: (typeof state.quickChats)[number]) {
    return createQuickChatCommands(state.connection.phase === "connected", {
      openQuickChat: async () => {
        const response = await sendDaemonCommand(openQuickChatCommand(chat.id));
        if (
          response.kind === "response" &&
          response.event?.type === "quickChatChanged"
        ) {
          dispatch({ type: "envelopeReceived", envelope: response });
          dispatch({ type: "selectQuickChat", id: response.event.chat.id });
        }
      },
      renameQuickChat: () =>
        setRenamingQuickChat({ id: chat.id, title: chat.title }),
      deleteQuickChat: async () => {
        if (
          !window.confirm(
            `Delete "${chat.title}"? Its session and scrollback will be terminated and cannot be restored.`,
          )
        ) {
          return;
        }
        const response = await sendDaemonCommand(
          deleteQuickChatCommand(chat.id),
        );
        if (
          response.kind === "response" &&
          response.event?.type === "quickChatDeleted"
        ) {
          dispatch({ type: "envelopeReceived", envelope: response });
        }
      },
    });
  }

  function projectRowCommands(
    project: { path: string; name: string },
    isOpen: boolean,
  ) {
    const confirmedRemoval = async (mode: "close" | "forget" | "delete") => {
      const prompt =
        mode === "close"
          ? `Close "${project.name}"? Its saved graph remains available in Recent.`
          : mode === "forget"
            ? `Forget "${project.name}"? Its saved graph is preserved, but the folder is removed from Recent until opened again.`
            : `Permanently delete the saved graph for "${project.name}"? Its loops and detached sessions will be ended and cannot be restored.`;
      if (!window.confirm(prompt)) return;
      await sendDaemonCommand(
        mode === "close"
          ? closeProjectCommand(project.path)
          : mode === "forget"
            ? forgetProjectCommand(project.path)
            : deleteProjectGraphCommand(project.path),
      );
      dispatch({
        type: "projectRemoved",
        path: project.path,
        removeFromRecents: mode !== "close",
      });
    };
    return createProjectRowCommands(
      state.connection.phase === "connected",
      isOpen,
      {
        closeProject: isOpen ? () => confirmedRemoval("close") : undefined,
        forgetProject: () => confirmedRemoval("forget"),
        deleteProjectGraph: () => confirmedRemoval("delete"),
      },
    );
  }

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
        <nav aria-label="Destinations">
          <div className="section-heading quick-chats-heading">
            <h2 id="quick-chats-heading">Quick Chats</h2>
            <button
              type="button"
              aria-label="New Quick Chat"
              disabled={
                !commands.find((command) => command.id === "chat.new")?.enabled
              }
              onClick={() => {
                const command = commands.find(
                  (candidate) => candidate.id === "chat.new",
                );
                if (command) void executeCommand(command);
              }}
            >
              +
            </button>
          </div>
          <button
            className={`quick-chats-link ${
              state.quickChatsSelected && !state.selectedQuickChatId
                ? "project-selected"
                : ""
            }`}
            type="button"
            aria-expanded="true"
            onClick={() => dispatch({ type: "selectQuickChats" })}
          >
            <span aria-hidden="true">◌</span>
            <span>
              <strong>All Quick Chats</strong>
              <small>
                {state.quickChats.length
                  ? `${state.quickChats.length} conversation${
                      state.quickChats.length === 1 ? "" : "s"
                    }`
                  : "No conversations yet"}
              </small>
            </span>
          </button>
          <ul className="quick-chat-sidebar-list" aria-label="Quick Chats">
            {state.quickChats.map((chat) => {
              const openCommand = quickChatCommands(chat)[0];
              return (
                <li key={chat.id}>
                  <button
                    type="button"
                    className={
                      state.selectedQuickChatId === chat.id
                        ? "project-selected"
                        : ""
                    }
                    disabled={
                      !openCommand.enabled ||
                      pendingCommandId === openCommand.id
                    }
                    title={openCommand.disabledReason}
                    onClick={() => void executeCommand(openCommand)}
                  >
                    <span>{chat.title}</span>
                    <small>{chat.activity?.text ?? chat.backend}</small>
                  </button>
                </li>
              );
            })}
          </ul>
          <div className="section-heading projects-section-heading">
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
              <li className="project-row" key={project.path}>
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
                <ProjectRowActions
                  projectName={project.name}
                  commands={projectRowCommands(project, true)}
                  pendingCommandId={pendingCommandId}
                  onExecute={(command) => void executeCommand(command)}
                />
              </li>
            ))}
          </ul>
          <p className="project-group-label">Recent</p>
          <ul
            className="project-list recent-project-list"
            aria-label="Recent projects"
          >
            {projectNavigation.recent.map((project) => (
              <li className="project-row" key={project.path}>
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
                <ProjectRowActions
                  projectName={project.name}
                  commands={projectRowCommands(project, false)}
                  pendingCommandId={pendingCommandId}
                  onExecute={(command) => void executeCommand(command)}
                />
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
            <h1>
              {inspectedQuickChat?.title ??
                (state.quickChatsSelected
                  ? "Quick Chats"
                  : (selectedGraph?.project.name ?? "GraphCode"))}
            </h1>
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
        {!state.quickChatsSelected && compositeBreadcrumbs.length > 1 ? (
          <nav className="composite-breadcrumb" aria-label="Composite path">
            {compositeBreadcrumbs.map((breadcrumb, index) => (
              <span key={`${breadcrumb.depth}-${breadcrumb.label}`}>
                {index ? <span aria-hidden="true">/</span> : null}
                <button
                  type="button"
                  aria-current={
                    breadcrumb.depth === state.compositePath.length
                      ? "page"
                      : undefined
                  }
                  disabled={breadcrumb.depth === state.compositePath.length}
                  onClick={() =>
                    dispatch({
                      type: "leaveComposite",
                      depth: breadcrumb.depth,
                    })
                  }
                >
                  {breadcrumb.label}
                </button>
              </span>
            ))}
          </nav>
        ) : null}
        {state.quickChatsSelected ? (
          <QuickChatsView
            chats={state.quickChats}
            selectedChat={inspectedQuickChat}
            pendingCommandId={pendingCommandId}
            commandsForChat={quickChatCommands}
            onBack={() => dispatch({ type: "selectQuickChats" })}
            onNewChat={() => {
              const command = commands.find(
                (candidate) => candidate.id === "chat.new",
              );
              if (command) void executeCommand(command);
            }}
            onExecute={(command) => void executeCommand(command)}
          />
        ) : (
          <div className="content-layout">
            <GraphCanvas
              ref={graphCanvasRef}
              graph={selectedGraph}
              selectedNodeId={state.selectedNodeId}
              commands={canvasCommands}
              pendingCommandId={pendingCommandId}
              onExecuteCommand={(command) => void executeCommand(command)}
              onCreateEdge={
                state.connection.phase === "connected"
                  ? (from, to) => {
                      setNewEdgeEndpoints({ from, to });
                      setNewEdgeOpen(true);
                    }
                  : undefined
              }
              edgeCommands={(edge) =>
                createEdgeCommands(
                  state.connection.phase === "connected",
                  edge.id,
                  {
                    deleteEdge: edge.id
                      ? async () => {
                          if (!selectedProjectPath || !edge.id) return;
                          const from =
                            selectedGraph?.nodes.find(
                              (node) => node.id === edge.from,
                            )?.title ?? edge.from;
                          const to =
                            selectedGraph?.nodes.find(
                              (node) => node.id === edge.to,
                            )?.title ?? edge.to;
                          if (
                            !window.confirm(
                              `Delete the edge from "${from}" to "${to}"? This cannot be undone.`,
                            )
                          ) {
                            return;
                          }
                          await sendDaemonCommand(
                            routeGraphCommand(
                              deleteEdgeCommand(selectedProjectPath, edge.id),
                            ),
                          );
                        }
                      : undefined,
                  },
                )
              }
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
              mailbox={
                selectedProjectPath
                  ? state.mailboxes[selectedProjectPath]
                  : undefined
              }
              commands={nodeCommands}
              pendingCommandId={pendingCommandId}
              onClose={() => dispatch({ type: "clearNodeSelection" })}
              onExecuteCommand={(command) => void executeCommand(command)}
            />
          </div>
        )}
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
                routeGraphCommand(
                  createNodeCommand(selectedProjectPath, draft),
                ),
              );
            } catch (error) {
              setPendingCreatedNode(undefined);
              throw error;
            }
          }}
        />
      ) : null}
      {newQuickChatOpen ? (
        <NewQuickChatDialog
          onClose={() => setNewQuickChatOpen(false)}
          onCreate={async (title, backend) => {
            const response = await sendDaemonCommand(
              createQuickChatCommand(title, backend),
            );
            if (
              response.kind === "response" &&
              response.event?.type === "quickChatChanged"
            ) {
              dispatch({ type: "envelopeReceived", envelope: response });
              dispatch({
                type: "selectQuickChat",
                id: response.event.chat.id,
              });
            }
          }}
        />
      ) : null}
      {newEdgeOpen && selectedGraph && selectedProjectPath ? (
        <NewEdgeDialog
          key={`${newEdgeEndpoints?.from ?? ""}-${newEdgeEndpoints?.to ?? ""}`}
          nodes={selectedGraph.nodes}
          initialFrom={newEdgeEndpoints?.from}
          initialTo={newEdgeEndpoints?.to}
          onClose={() => {
            setNewEdgeOpen(false);
            setNewEdgeEndpoints(undefined);
          }}
          onCreate={async (from, to, spec) => {
            await sendDaemonCommand(
              routeGraphCommand(
                createEdgeCommand(selectedProjectPath, from, to, spec),
              ),
            );
          }}
        />
      ) : null}
      {editingLoop ? (
        <EditLoopDialog
          node={editingLoop.node}
          onClose={() => setEditingLoop(undefined)}
          onSave={async (update) => {
            await sendDaemonCommand(
              routeGraphCommand(
                updateNodeCommand(
                  editingLoop.projectPath,
                  editingLoop.node.id,
                  update,
                ),
              ),
            );
          }}
        />
      ) : null}
      {messagingLoop ? (
        <MessageLoopDialog
          nodeTitle={messagingLoop.nodeTitle}
          onClose={() => setMessagingLoop(undefined)}
          onSend={async (text, followUp) => {
            await sendDaemonCommand(
              routeGraphCommand(
                messageNodeCommand(
                  messagingLoop.projectPath,
                  messagingLoop.nodeId,
                  text,
                  followUp,
                ),
              ),
            );
          }}
        />
      ) : null}
      {mailroomPosting ? (
        <MailroomPostDialog
          projectName={mailroomPosting.projectName}
          onClose={() => setMailroomPosting(undefined)}
          onPost={async (body, topic) => {
            await sendDaemonCommand(
              mailroomPostCommand(mailroomPosting.projectPath, body, topic),
            );
            await sendDaemonCommand(
              mailboxCommand(mailroomPosting.projectPath),
            );
          }}
        />
      ) : null}
      {mailroomWatching ? (
        <MailroomWatchDialog
          nodeTitle={mailroomWatching.nodeTitle}
          currentTopic={mailroomWatching.currentTopic}
          watching={mailroomWatching.watching}
          onClose={() => setMailroomWatching(undefined)}
          onSave={async (on, topic) => {
            await sendDaemonCommand(
              mailroomWatchCommand(
                mailroomWatching.projectPath,
                mailroomWatching.nodeId,
                on,
                topic,
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
              routeGraphCommand(
                renameNodeCommand(
                  textDialog.projectPath,
                  textDialog.nodeId,
                  title,
                ),
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
              routeGraphCommand(
                completeNodeCommand(
                  textDialog.projectPath,
                  textDialog.nodeId,
                  result || null,
                ),
              ),
            );
          }}
        />
      ) : null}
      {textDialog?.kind === "memo" ? (
        <LoopTextDialog
          title={`Add memo to ${textDialog.nodeTitle}`}
          description="Append a durable note to this loop's memory. Reading memory history remains blocked on DT-001 and is not approximated here."
          label="Memo"
          multiline
          required
          submitLabel="Add memo"
          onClose={() => setTextDialog(undefined)}
          onSubmit={async (text) => {
            await sendDaemonCommand(
              routeGraphCommand(
                memoNodeCommand(
                  textDialog.projectPath,
                  textDialog.nodeId,
                  text,
                ),
              ),
            );
          }}
        />
      ) : null}
      {textDialog?.kind === "refine" ? (
        <LoopTextDialog
          title={`Refine ${textDialog.nodeTitle}`}
          description="Replace this loop's complete playbook for its next wake. Reading the current playbook and rollback history remains blocked on DT-001."
          label="Replacement playbook"
          multiline
          required
          submitLabel="Replace playbook"
          onClose={() => setTextDialog(undefined)}
          onSubmit={async (text) => {
            await sendDaemonCommand(
              routeGraphCommand(
                refineNodeCommand(
                  textDialog.projectPath,
                  textDialog.nodeId,
                  text,
                ),
              ),
            );
          }}
        />
      ) : null}
      {textDialog?.kind === "mailSearch" ? (
        <LoopTextDialog
          title={`Search ${selectedGraph?.project.name ?? "Mailroom"}`}
          description="Filter the project board case-insensitively across author, topic, and complete post body. The read does not move any loop cursor."
          label="Search text"
          required
          submitLabel="Search"
          onClose={() => setTextDialog(undefined)}
          onSubmit={async (search) => {
            await sendDaemonCommand(
              mailboxSearchCommand(textDialog.projectPath, search),
            );
          }}
        />
      ) : null}
      {renamingQuickChat ? (
        <LoopTextDialog
          title={`Rename ${renamingQuickChat.title}`}
          description="The chat keeps its stable identity, backend, session, and scrollback."
          label="Chat title"
          initialValue={renamingQuickChat.title}
          required
          submitLabel="Rename"
          onClose={() => setRenamingQuickChat(undefined)}
          onSubmit={async (title) => {
            const response = await sendDaemonCommand(
              renameQuickChatCommand(renamingQuickChat.id, title),
            );
            if (
              response.kind === "response" &&
              response.event?.type === "quickChatChanged"
            ) {
              dispatch({ type: "envelopeReceived", envelope: response });
            }
          }}
        />
      ) : null}
    </main>
  );
}
