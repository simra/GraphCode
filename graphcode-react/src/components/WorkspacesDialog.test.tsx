// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const workspaceBridge = vi.hoisted(() => ({
  create: vi.fn(),
  delete: vi.fn(),
  list: vi.fn(),
  open: vi.fn(),
  prepareDelete: vi.fn(),
  rename: vi.fn(),
}));

vi.mock("../bridge/workspaces", () => ({
  createWorkspace: workspaceBridge.create,
  deleteWorkspace: workspaceBridge.delete,
  listWorkspaces: workspaceBridge.list,
  openWorkspace: workspaceBridge.open,
  prepareWorkspaceDeletion: workspaceBridge.prepareDelete,
  renameWorkspace: workspaceBridge.rename,
}));

import { WorkspacesDialog } from "./WorkspacesDialog";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const workspaces = [
  {
    id: "C:\\Users\\me\\.graphcode",
    name: "Default",
    path: "C:\\Users\\me\\.graphcode",
    isDefault: true,
    isCurrent: true,
    isOpen: true,
    projects: 2,
    loops: 5,
    terminalSessions: 7,
  },
  {
    id: "C:\\Users\\me\\.graphcode-research",
    name: "research",
    path: "C:\\Users\\me\\.graphcode-research",
    isDefault: false,
    isCurrent: false,
    isOpen: false,
    projects: 1,
    loops: 3,
    terminalSessions: 4,
  },
];

beforeEach(() => {
  workspaceBridge.list.mockReset();
  workspaceBridge.list.mockResolvedValue(workspaces);
  workspaceBridge.open.mockReset();
  workspaceBridge.open.mockResolvedValue(undefined);
  workspaceBridge.create.mockReset();
  workspaceBridge.delete.mockReset();
  workspaceBridge.delete.mockResolvedValue(undefined);
  workspaceBridge.prepareDelete.mockReset();
  workspaceBridge.prepareDelete.mockImplementation((id: string) => {
    const workspace = workspaces.find((candidate) => candidate.id === id)!;
    return Promise.resolve({
      id: workspace.id,
      name: workspace.name,
      canonicalPath: workspace.path,
      projects: workspace.projects,
      loops: workspace.loops,
      terminalSessions: workspace.terminalSessions,
    });
  });
  workspaceBridge.rename.mockReset();
});

afterEach(() => {
  document.body.innerHTML = "";
});

describe("WorkspacesDialog", () => {
  it("lists workspace contents and opens an inactive workspace", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<WorkspacesDialog onClose={() => undefined} />);
    });

    expect(container.textContent).toContain("2 projects · 5 loops · Current");
    expect(container.textContent).toContain("1 project · 3 loops");
    const openButtons = Array.from(container.querySelectorAll("button")).filter(
      (button) => button.textContent === "Open",
    );
    expect(openButtons[0].disabled).toBe(true);
    await act(async () => {
      openButtons[1].click();
    });
    expect(workspaceBridge.open).toHaveBeenCalledWith(workspaces[1].id);
    const deleteButtons = Array.from(
      container.querySelectorAll("button"),
    ).filter((button) => button.textContent === "Delete");
    expect(deleteButtons[0].disabled).toBe(true);
    expect(deleteButtons[1].disabled).toBe(false);
  });

  it("confirms the canonical path and teardown impact before deletion", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<WorkspacesDialog onClose={() => undefined} />);
    });

    const deleteButtons = Array.from(
      container.querySelectorAll("button"),
    ).filter((button) => button.textContent === "Delete");
    await act(async () => {
      deleteButtons[1].click();
    });

    expect(container.textContent).toContain(workspaces[1].path);
    expect(container.textContent).toContain("1 project");
    expect(container.textContent).toContain("3 loops");
    expect(container.textContent).toContain("4 terminal sessions");
    expect(container.textContent).toContain("Windows Recycle Bin");
    expect(workspaceBridge.delete).not.toHaveBeenCalled();

    const confirm = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent === "Delete Workspace",
    );
    await act(async () => {
      confirm?.click();
    });

    expect(workspaceBridge.delete).toHaveBeenCalledWith(
      workspaces[1].id,
      workspaces[1].path,
    );
  });
});
