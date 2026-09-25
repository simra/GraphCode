import { useEffect, useMemo, useReducer } from "react";
import { startDaemonConnection, type DaemonConnection } from "./bridge/daemon";
import { ConnectionBanner } from "./components/ConnectionBanner";
import { GraphCanvas } from "./components/GraphCanvas";
import { initialSnapshotFixture } from "./fixtures/initialSnapshot";
import { appReducer, initialAppState } from "./state/graphState";

export default function App() {
  const [state, dispatch] = useReducer(appReducer, initialAppState);

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
  const projects = useMemo(() => {
    const byPath = new Map(
      state.recentProjects.map((project) => [project.path, project]),
    );
    for (const graph of Object.values(state.graphs)) {
      byPath.set(graph.project.path, graph.project);
    }
    return [...byPath.values()];
  }, [state.graphs, state.recentProjects]);

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
          <button
            type="button"
            disabled
            title="Terminal streaming is planned for phase 3"
          >
            Open terminal
          </button>
        </header>
        <ConnectionBanner connection={state.connection} />
        {state.protocolWarnings.length ? (
          <div className="protocol-warning" role="alert">
            {state.protocolWarnings.at(-1)}
          </div>
        ) : null}
        <GraphCanvas graph={selectedGraph} />
      </section>
    </main>
  );
}
