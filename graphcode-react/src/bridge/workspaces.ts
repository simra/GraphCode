import { invoke } from "@tauri-apps/api/core";

export interface WorkspaceSummary {
  id: string;
  name: string;
  path: string;
  isDefault: boolean;
  isCurrent: boolean;
  isOpen: boolean;
  projects: number;
  loops: number;
  terminalSessions: number;
}

export interface WorkspaceDeletionPlan {
  id: string;
  name: string;
  canonicalPath: string;
  recoveryPath: string;
  projects: number;
  loops: number;
  terminalSessions: number;
}

export function listWorkspaces(): Promise<WorkspaceSummary[]> {
  return invoke("list_workspaces");
}

export function createWorkspace(name: string): Promise<WorkspaceSummary> {
  return invoke("create_workspace", { name });
}

export function renameWorkspace(
  id: string,
  name: string,
): Promise<WorkspaceSummary> {
  return invoke("rename_workspace", { id, name });
}

export function prepareWorkspaceDeletion(
  id: string,
): Promise<WorkspaceDeletionPlan> {
  return invoke("prepare_workspace_deletion", { id });
}

export function deleteWorkspace(
  id: string,
  expectedPath: string,
  expectedRecoveryPath: string,
): Promise<void> {
  return invoke("delete_workspace", {
    id,
    expectedPath,
    expectedRecoveryPath,
  });
}

export function openWorkspace(id: string): Promise<void> {
  return invoke("open_workspace", { id });
}
