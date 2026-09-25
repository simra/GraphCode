import type { AppState } from "../state/graphState";

export function ConnectionBanner({
  connection,
}: {
  connection: AppState["connection"];
}) {
  const label = {
    idle: "Not connected",
    connecting: "Connecting to graphcoded…",
    connected: "Connected to graphcoded",
    reconnecting: "Reconnecting to graphcoded…",
    resyncing: "Resynchronizing daemon state…",
    fixture: "Previewing a repository fixture",
    error: "graphcoded connection failed",
  }[connection.phase];

  return (
    <div
      className={`connection-banner connection-${connection.phase}`}
      role="status"
    >
      <span className="connection-dot" aria-hidden="true" />
      <strong>{label}</strong>
      {connection.endpoint ? <code>{connection.endpoint}</code> : null}
      {connection.error ? <span>{connection.error}</span> : null}
    </div>
  );
}
