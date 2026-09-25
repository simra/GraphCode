export interface GraphCommandEnvelope<TCommand> {
  graphCommand: {
    projectPath: string;
    command: TCommand;
  };
}

export type StopNodeCommand = GraphCommandEnvelope<{
  stopNode: {
    _0: string;
  };
}>;

export type DraftLoopType =
  "sketch" | "goalBased" | "timeBased" | "turnBased" | "proactive";

export type DraftBackend =
  "claudeCode" | "copilotCLI" | "codex" | "openCode" | "pi";

export interface ListQuickChatsCommand {
  listQuickChats: Record<string, never>;
}

export interface CreateQuickChatCommand {
  createQuickChat: {
    title: string;
    backend: DraftBackend;
  };
}

export interface OpenQuickChatCommand {
  openQuickChat: {
    id: string;
  };
}

export interface RenameQuickChatCommand {
  renameQuickChat: {
    id: string;
    title: string;
  };
}

export interface DeleteQuickChatCommand {
  deleteQuickChat: {
    id: string;
  };
}

export type DraftModelTier = "fast" | "standard" | "capable";

export interface GoalDraft {
  summary: string;
  predicate: string | null;
  pollIntervalSeconds: number;
  stallAfterSeconds: number | null;
  metricCommand: string | null;
  metricDirection: "minimize" | "maximize";
  tokenBudget: number | null;
  skipsUnchangedWorkspace: boolean;
}

export interface WorktreeDraft {
  id: string;
  repositoryPath: string;
  worktreePath: string;
  branch: string;
}

export interface NodeDraftPayload {
  id: string;
  title: string;
  loopType: DraftLoopType;
  checkDescription: string | null;
  triggerPrompt: string | null;
  heartbeatIntervalSeconds: number | null;
  firstInstruction: string | null;
  pausesBeforeWritesOnly: boolean;
  attachments: [];
  goal: GoalDraft | null;
  backend: DraftBackend | null;
  modelTier: DraftModelTier | null;
  worktree: WorktreeDraft | null;
  subGraph: null;
  createdBy: null;
  createdFromTemplateID: null;
  templateFollow: null;
}

export type CreateNodeCommand = GraphCommandEnvelope<{
  createNode: {
    _0: NodeDraftPayload;
  };
}>;

export type RenameNodeCommand = GraphCommandEnvelope<{
  renameNode: {
    _0: string;
    title: string;
  };
}>;

export type NodeIdentityCommand = GraphCommandEnvelope<
  | { restartNode: { _0: string } }
  | { resumeSession: { _0: string } }
  | { deleteNode: { _0: string } }
>;

export type CompleteNodeCommand = GraphCommandEnvelope<{
  completeNode: {
    _0: string;
    result: string | null;
    from: null;
  };
}>;

export type RefreshUsageCommand = GraphCommandEnvelope<{
  refreshUsage: Record<string, never>;
}>;

export interface OpenProjectCommand {
  openProject: {
    path: string;
  };
}

export interface ProjectPathCommand {
  closeProject?: { path: string };
  forgetProject?: { path: string };
  deleteProjectGraph?: { path: string };
}

export interface NodeUpdatePayload {
  goalSummary?: string;
  goalPredicate?: string;
  pollIntervalSeconds?: number;
  stallAfterSeconds?: number;
  metricCommand?: string;
  metricDirection?: "minimize" | "maximize";
  tokenBudget?: number;
  skipsUnchangedWorkspace?: boolean;
  triggerPrompt?: string;
  heartbeatIntervalSeconds?: number;
  checkDescription?: string;
  modelTier?: DraftModelTier;
  updatedBy: null;
}

export type UpdateNodeCommand = GraphCommandEnvelope<{
  updateNode: {
    _0: string;
    update: NodeUpdatePayload;
  };
}>;

export type MessageNodeCommand = GraphCommandEnvelope<{
  messageNode: {
    _0: string;
    text: string;
    from: null;
    followUp?: true;
  };
}>;

export type MemoNodeCommand = GraphCommandEnvelope<{
  memoNode: {
    _0: string;
    text: string;
    from: null;
  };
}>;

export type RefineNodeCommand = GraphCommandEnvelope<{
  refineNode: {
    _0: string;
    text: string;
    from: null;
  };
}>;

export type RollbackRefinementCommand = GraphCommandEnvelope<{
  rollbackRefinement: {
    _0: string;
    from: null;
  };
}>;

export type PilotCompositeCommand = GraphCommandEnvelope<{
  pilotComposite: { _0: string };
}>;

export type ArmCompositeCommand = GraphCommandEnvelope<{
  armComposite: { _0: string };
}>;

export type MailboxSelectionPayload =
  | { board: Record<string, never> }
  | { unread: { reader: string } }
  | { post: { id: number } };

export interface MailboxQueryPayload {
  selection: MailboxSelectionPayload;
  search: string | null;
  fullBodies: boolean | null;
  advanceCursor: boolean | null;
}

export interface MailboxCommand {
  mailbox: {
    projectPath: string;
    query: MailboxQueryPayload;
  };
}

export type MailroomPostCommand = GraphCommandEnvelope<{
  mailroomPost: {
    text: string;
    topic: string | null;
    from: null;
  };
}>;

export type MailroomWatchCommand = GraphCommandEnvelope<{
  mailroomWatch: {
    on: boolean;
    topic: string | null;
    from: string;
  };
}>;

export type EdgeKindPayload = "handoff" | "message" | "spawn";
export type EdgeConditionPayload = "always" | "onSuccess" | "onFailure";
export type PayloadTransformPayload =
  | { none: Record<string, never> }
  | { template: { _0: string } }
  | { script: { _0: string } };

export interface EdgeSpecPayload {
  kind: EdgeKindPayload;
  condition: EdgeConditionPayload;
  payloadTransform: PayloadTransformPayload;
  cycleGuard: {
    maxIterations: number | null;
    until: string | null;
    stopAfterPassesWithoutImprovement: number | null;
  } | null;
  spawnTargetProjectPath: string | null;
}

export type CreateEdgeCommand = GraphCommandEnvelope<{
  createEdge: {
    from: string;
    to: string;
    spec: EdgeSpecPayload;
  };
}>;

export type DeleteEdgeCommand = GraphCommandEnvelope<{
  deleteEdge: { _0: string };
}>;

export function stopNodeCommand(
  projectPath: string,
  nodeId: string,
): StopNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { stopNode: { _0: nodeId } },
    },
  };
}

export function listQuickChatsCommand(): ListQuickChatsCommand {
  return { listQuickChats: {} };
}

export function createQuickChatCommand(
  title: string,
  backend: DraftBackend,
): CreateQuickChatCommand {
  return { createQuickChat: { title, backend } };
}

export function openQuickChatCommand(id: string): OpenQuickChatCommand {
  return { openQuickChat: { id } };
}

export function renameQuickChatCommand(
  id: string,
  title: string,
): RenameQuickChatCommand {
  return { renameQuickChat: { id, title } };
}

export function deleteQuickChatCommand(id: string): DeleteQuickChatCommand {
  return { deleteQuickChat: { id } };
}

export function createNodeCommand(
  projectPath: string,
  draft: NodeDraftPayload,
): CreateNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        createNode: { _0: draft },
      },
    },
  };
}

export function renameNodeCommand(
  projectPath: string,
  nodeId: string,
  title: string,
): RenameNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { renameNode: { _0: nodeId, title } },
    },
  };
}

export function restartNodeCommand(
  projectPath: string,
  nodeId: string,
): NodeIdentityCommand {
  return {
    graphCommand: {
      projectPath,
      command: { restartNode: { _0: nodeId } },
    },
  };
}

export function resumeSessionCommand(
  projectPath: string,
  nodeId: string,
): NodeIdentityCommand {
  return {
    graphCommand: {
      projectPath,
      command: { resumeSession: { _0: nodeId } },
    },
  };
}

export function deleteNodeCommand(
  projectPath: string,
  nodeId: string,
): NodeIdentityCommand {
  return {
    graphCommand: {
      projectPath,
      command: { deleteNode: { _0: nodeId } },
    },
  };
}

export function completeNodeCommand(
  projectPath: string,
  nodeId: string,
  result: string | null,
): CompleteNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        completeNode: { _0: nodeId, result, from: null },
      },
    },
  };
}

export function refreshUsageCommand(projectPath: string): RefreshUsageCommand {
  return {
    graphCommand: {
      projectPath,
      command: { refreshUsage: {} },
    },
  };
}

export function openProjectCommand(path: string): OpenProjectCommand {
  return {
    openProject: { path },
  };
}

export function closeProjectCommand(path: string): ProjectPathCommand {
  return { closeProject: { path } };
}

export function forgetProjectCommand(path: string): ProjectPathCommand {
  return { forgetProject: { path } };
}

export function deleteProjectGraphCommand(path: string): ProjectPathCommand {
  return { deleteProjectGraph: { path } };
}

export function updateNodeCommand(
  projectPath: string,
  nodeId: string,
  update: NodeUpdatePayload,
): UpdateNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        updateNode: { _0: nodeId, update },
      },
    },
  };
}

export function messageNodeCommand(
  projectPath: string,
  nodeId: string,
  text: string,
  followUp: boolean,
): MessageNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        messageNode: {
          _0: nodeId,
          text,
          from: null,
          ...(followUp ? { followUp: true as const } : {}),
        },
      },
    },
  };
}

export function memoNodeCommand(
  projectPath: string,
  nodeId: string,
  text: string,
): MemoNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        memoNode: { _0: nodeId, text, from: null },
      },
    },
  };
}

export function refineNodeCommand(
  projectPath: string,
  nodeId: string,
  text: string,
): RefineNodeCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        refineNode: { _0: nodeId, text, from: null },
      },
    },
  };
}

export function rollbackRefinementCommand(
  projectPath: string,
  nodeId: string,
): RollbackRefinementCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        rollbackRefinement: { _0: nodeId, from: null },
      },
    },
  };
}

export function addressGraphCommand<TCommand>(
  envelope: GraphCommandEnvelope<TCommand>,
  compositePath: readonly string[],
): GraphCommandEnvelope<Record<string, unknown>> {
  let command: Record<string, unknown> = envelope.graphCommand
    .command as Record<string, unknown>;
  for (const nodeID of [...compositePath].reverse()) {
    command = { subGraphCommand: { nodeID, command } };
  }
  return {
    graphCommand: {
      projectPath: envelope.graphCommand.projectPath,
      command,
    },
  };
}

export function pilotCompositeCommand(
  projectPath: string,
  nodeId: string,
): PilotCompositeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { pilotComposite: { _0: nodeId } },
    },
  };
}

export function armCompositeCommand(
  projectPath: string,
  nodeId: string,
): ArmCompositeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { armComposite: { _0: nodeId } },
    },
  };
}

export function mailboxCommand(
  projectPath: string,
  query: MailboxQueryPayload = {
    selection: { board: {} },
    search: null,
    fullBodies: true,
    advanceCursor: null,
  },
): MailboxCommand {
  return {
    mailbox: {
      projectPath,
      query,
    },
  };
}

export function mailboxSearchCommand(
  projectPath: string,
  search: string,
): MailboxCommand {
  return mailboxCommand(projectPath, {
    selection: { board: {} },
    search,
    fullBodies: true,
    advanceCursor: null,
  });
}

export function mailboxPostCommand(
  projectPath: string,
  postId: number,
): MailboxCommand {
  return mailboxCommand(projectPath, {
    selection: { post: { id: postId } },
    search: null,
    fullBodies: true,
    advanceCursor: null,
  });
}

export function mailboxUnreadCommand(
  projectPath: string,
  reader: string,
  advanceCursor: boolean,
): MailboxCommand {
  return mailboxCommand(projectPath, {
    selection: { unread: { reader } },
    search: null,
    fullBodies: null,
    advanceCursor,
  });
}

export function mailroomPostCommand(
  projectPath: string,
  text: string,
  topic: string | null,
): MailroomPostCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        mailroomPost: { text, topic, from: null },
      },
    },
  };
}

export function mailroomWatchCommand(
  projectPath: string,
  nodeId: string,
  on: boolean,
  topic: string | null,
): MailroomWatchCommand {
  return {
    graphCommand: {
      projectPath,
      command: {
        mailroomWatch: { on, topic, from: nodeId },
      },
    },
  };
}

export function createEdgeCommand(
  projectPath: string,
  from: string,
  to: string,
  spec: EdgeSpecPayload,
): CreateEdgeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { createEdge: { from, to, spec } },
    },
  };
}

export function deleteEdgeCommand(
  projectPath: string,
  edgeId: string,
): DeleteEdgeCommand {
  return {
    graphCommand: {
      projectPath,
      command: { deleteEdge: { _0: edgeId } },
    },
  };
}
