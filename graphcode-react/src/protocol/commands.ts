export interface StopNodeCommand {
  graphCommand: {
    projectPath: string;
    command: {
      stopNode: {
        _0: string;
      };
    };
  };
}

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

export interface CreateNodeCommand {
  graphCommand: {
    projectPath: string;
    command: {
      createNode: {
        _0: NodeDraftPayload;
      };
    };
  };
}

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
