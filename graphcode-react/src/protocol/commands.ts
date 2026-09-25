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
