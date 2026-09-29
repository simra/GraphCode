import { useEffect, useState } from "react";
import {
  createWorkspace,
  deleteWorkspace,
  listWorkspaces,
  openWorkspace,
  prepareWorkspaceDeletion,
  renameWorkspace,
  type WorkspaceDeletionPlan,
  type WorkspaceSummary,
} from "../bridge/workspaces";

export function WorkspacesDialog({ onClose }: { onClose(): void }) {
  const [workspaces, setWorkspaces] = useState<WorkspaceSummary[]>([]);
  const [newName, setNewName] = useState("");
  const [renaming, setRenaming] = useState<WorkspaceSummary>();
  const [deleting, setDeleting] = useState<WorkspaceDeletionPlan>();
  const [renameValue, setRenameValue] = useState("");
  const [busy, setBusy] = useState<string>();
  const [error, setError] = useState<string>();
  const [notice, setNotice] = useState<string>();

  const refresh = () => {
    setDeleting(undefined);
    setError(undefined);
    setNotice(undefined);
    void listWorkspaces()
      .then(setWorkspaces)
      .catch((caught: unknown) =>
        setError(caught instanceof Error ? caught.message : String(caught)),
      );
  };

  useEffect(refresh, []);

  const run = async (key: string, operation: () => Promise<unknown>) => {
    setDeleting(undefined);
    setBusy(key);
    setError(undefined);
    setNotice(undefined);
    try {
      await operation();
      await listWorkspaces().then(setWorkspaces);
      return true;
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
      return false;
    } finally {
      setBusy(undefined);
    }
  };

  const prepareDeletion = async (workspace: WorkspaceSummary) => {
    setBusy(`prepare-delete:${workspace.id}`);
    setError(undefined);
    setNotice(undefined);
    try {
      setDeleting(await prepareWorkspaceDeletion(workspace.id));
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(undefined);
    }
  };

  const commitDeletion = async (plan: WorkspaceDeletionPlan) => {
    setDeleting(undefined);
    setBusy(`delete:${plan.id}`);
    setError(undefined);
    setNotice(undefined);
    try {
      const result = await deleteWorkspace(
        plan.id,
        plan.canonicalPath,
        plan.recoveryPath,
        plan.identityToken,
      );
      if (!result.committed) {
        throw new Error("Workspace deletion did not commit.");
      }
      setWorkspaces((current) =>
        current.filter((workspace) => workspace.id !== plan.id),
      );
      setNotice(
        result.cleanupWarning ??
          `Workspace moved to the recovery location: ${result.recoveryPath}`,
      );
      setWorkspaces(await listWorkspaces());
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setBusy(undefined);
    }
  };

  return (
    <div className="new-loop-overlay" role="presentation">
      <section
        className="new-loop-dialog workspaces-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="workspaces-title"
      >
        <header className="new-loop-header">
          <div>
            <p className="eyebrow">Isolated support directories</p>
            <h2 id="workspaces-title">Workspaces</h2>
          </div>
          <button
            type="button"
            className="icon-button"
            aria-label="Close workspaces"
            onClick={onClose}
          >
            ×
          </button>
        </header>
        <div className="workspace-dialog-body">
          <ul className="workspace-list">
            {workspaces.map((workspace) => (
              <li key={workspace.id}>
                <div>
                  <strong>{workspace.name}</strong>
                  <small>
                    {workspace.projects} project
                    {workspace.projects === 1 ? "" : "s"} · {workspace.loops}{" "}
                    loop{workspace.loops === 1 ? "" : "s"}
                    {workspace.isCurrent
                      ? " · Current"
                      : workspace.isOpen
                        ? " · Open"
                        : ""}
                  </small>
                  <code>{workspace.path}</code>
                </div>
                <div className="workspace-row-actions">
                  <button
                    type="button"
                    disabled={
                      workspace.isCurrent ||
                      workspace.isOpen ||
                      busy !== undefined
                    }
                    onClick={() =>
                      void run(`open:${workspace.id}`, () =>
                        openWorkspace(workspace.id),
                      )
                    }
                  >
                    {busy === `open:${workspace.id}` ? "Opening…" : "Open"}
                  </button>
                  <button
                    type="button"
                    disabled={
                      workspace.isDefault ||
                      workspace.isCurrent ||
                      workspace.isOpen ||
                      busy !== undefined
                    }
                    onClick={() => {
                      setRenaming(workspace);
                      setRenameValue(workspace.name);
                    }}
                  >
                    Rename
                  </button>
                  <button
                    type="button"
                    disabled={
                      workspace.isDefault ||
                      workspace.isCurrent ||
                      workspace.isOpen ||
                      busy !== undefined
                    }
                    title={
                      workspace.isDefault
                        ? "The default workspace cannot be deleted"
                        : workspace.isCurrent
                          ? "Switch to another workspace before deleting this one"
                          : workspace.isOpen
                            ? "Quit the other GraphCode window before deleting this workspace"
                            : undefined
                    }
                    onClick={() => void prepareDeletion(workspace)}
                  >
                    {busy === `prepare-delete:${workspace.id}`
                      ? "Checking…"
                      : "Delete"}
                  </button>
                </div>
              </li>
            ))}
          </ul>
          {deleting ? (
            <section
              className="workspace-delete-confirmation"
              aria-labelledby="workspace-delete-title"
            >
              <div>
                <p className="eyebrow">Recoverable workspace deletion</p>
                <h3 id="workspace-delete-title">
                  Delete the “{deleting.name}” workspace?
                </h3>
              </div>
              <p>
                This ends its graphcoded process and {deleting.terminalSessions}{" "}
                terminal session
                {deleting.terminalSessions === 1 ? "" : "s"}, removes its owned
                lock and rendezvous files, and atomically moves the workspace
                folder to the GraphCode recovery folder.
              </p>
              <p>
                It contains {deleting.projects} project
                {deleting.projects === 1 ? "" : "s"} and {deleting.loops} loop
                {deleting.loops === 1 ? "" : "s"}.
              </p>
              <code>{deleting.canonicalPath}</code>
              <p>Recovery location (move this folder back to restore it):</p>
              <code>{deleting.recoveryPath}</code>
              <div className="workspace-delete-actions">
                <button
                  type="button"
                  disabled={busy !== undefined}
                  onClick={() => setDeleting(undefined)}
                >
                  Cancel
                </button>
                <button
                  type="button"
                  className="danger-button"
                  disabled={busy !== undefined}
                  onClick={() => void commitDeletion(deleting)}
                >
                  {busy === `delete:${deleting.id}`
                    ? "Deleting…"
                    : "Delete Workspace"}
                </button>
              </div>
            </section>
          ) : null}
          <form
            className="workspace-create"
            onSubmit={(event) => {
              event.preventDefault();
              const name = newName.trim();
              if (!name) return;
              void run("create", () => createWorkspace(name)).then(
                (succeeded) => {
                  if (succeeded) setNewName("");
                },
              );
            }}
          >
            <label>
              New workspace
              <input
                value={newName}
                disabled={busy !== undefined}
                placeholder="Research builds"
                onChange={(event) => setNewName(event.target.value)}
              />
            </label>
            <button
              type="submit"
              className="primary-button"
              disabled={!newName.trim() || busy !== undefined}
            >
              {busy === "create" ? "Creating…" : "Create"}
            </button>
          </form>
          {renaming ? (
            <form
              className="workspace-create"
              onSubmit={(event) => {
                event.preventDefault();
                const name = renameValue.trim();
                if (!name) return;
                void run(`rename:${renaming.id}`, () =>
                  renameWorkspace(renaming.id, name),
                ).then((succeeded) => {
                  if (succeeded) setRenaming(undefined);
                });
              }}
            >
              <label>
                Rename {renaming.name}
                <input
                  value={renameValue}
                  disabled={busy !== undefined}
                  onChange={(event) => setRenameValue(event.target.value)}
                />
              </label>
              <button
                type="button"
                disabled={busy !== undefined}
                onClick={() => setRenaming(undefined)}
              >
                Cancel
              </button>
              <button
                type="submit"
                className="primary-button"
                disabled={!renameValue.trim() || busy !== undefined}
              >
                {busy === `rename:${renaming.id}` ? "Renaming…" : "Rename"}
              </button>
            </form>
          ) : null}
          {error ? (
            <div className="terminal-error" role="alert">
              {error}
              <button type="button" onClick={refresh}>
                Refresh
              </button>
            </div>
          ) : null}
          {notice ? (
            <div className="terminal-notice" role="status">
              {notice}
            </div>
          ) : null}
        </div>
        <footer className="new-loop-footer">
          <span>
            Opening a workspace starts its daemon and launches another GraphCode
            window.
          </span>
          <div>
            <button
              type="button"
              disabled={busy !== undefined}
              onClick={refresh}
            >
              Refresh
            </button>
            <button type="button" onClick={onClose}>
              Done
            </button>
          </div>
        </footer>
      </section>
    </div>
  );
}
