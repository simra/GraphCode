import type { AppCommand } from "../commands/registry";
import type { LoopEdge, LoopGraph } from "../protocol/domain";

function valueText(value: unknown): string | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value === "string" || typeof value === "number") {
    return String(value);
  }
  return JSON.stringify(value);
}

function Detail({ label, value }: { label: string; value: unknown }) {
  const text = valueText(value);
  if (text === undefined) return null;
  return (
    <div className="inspector-detail">
      <dt>{label}</dt>
      <dd>{text}</dd>
    </div>
  );
}

export function EdgeInspector({
  graph,
  edge,
  commands,
  pendingCommandId,
  onClose,
  onExecuteCommand,
}: {
  graph: LoopGraph;
  edge: LoopEdge;
  commands: AppCommand[];
  pendingCommandId?: string;
  onClose(): void;
  onExecuteCommand(command: AppCommand): void;
}) {
  const from =
    graph.nodes.find((node) => node.id === edge.from)?.title ?? edge.from;
  const to = graph.nodes.find((node) => node.id === edge.to)?.title ?? edge.to;

  return (
    <aside
      className="node-inspector edge-inspector"
      aria-labelledby="edge-inspector-title"
      aria-describedby="edge-inspector-project"
    >
      <header className="inspector-header">
        <div>
          <p className="eyebrow">Graph edge</p>
          <h2 id="edge-inspector-title">
            {from} → {to}
          </h2>
          <p id="edge-inspector-project">{graph.project.name}</p>
        </div>
        <button
          className="icon-button"
          type="button"
          onClick={onClose}
          aria-label="Close edge inspector"
        >
          ×
        </button>
      </header>
      <div className="inspector-badges" aria-label="Edge status">
        <span className="status-badge">{edge.kind ?? "connection"}</span>
        <span className="status-badge">
          Fired {edge.fireCount ?? 0} time{edge.fireCount === 1 ? "" : "s"}
        </span>
      </div>
      <div className="inspector-actions">
        {commands.map((command) => (
          <button
            key={command.id}
            className={command.danger ? "danger-command" : undefined}
            type="button"
            disabled={!command.enabled || pendingCommandId === command.id}
            title={command.disabledReason ?? command.description}
            onClick={() => onExecuteCommand(command)}
          >
            {command.label}
          </button>
        ))}
      </div>
      <div className="inspector-scroll">
        <section className="inspector-section">
          <h3>Connection</h3>
          <dl>
            <Detail label="Stable ID" value={edge.id ?? "Unavailable"} />
            <Detail label="From" value={from} />
            <Detail label="To" value={to} />
            <Detail label="Kind" value={edge.kind ?? "connection"} />
            <Detail label="Condition" value={edge.condition} />
            <Detail label="Fire count" value={edge.fireCount ?? 0} />
          </dl>
        </section>
        <section className="inspector-section">
          <h3>Delivery specification</h3>
          <dl>
            <Detail label="Payload transform" value={edge.payloadTransform} />
            <Detail label="Cycle guard" value={edge.cycleGuard} />
            <Detail label="Spawn target" value={edge.spawnTargetProjectPath} />
          </dl>
        </section>
        <p className="inspector-callout">
          Existing-edge editing is unavailable until the daemon provides the
          atomic DT-002 update contract. Delete remains authoritative and
          requires a stable edge ID.
        </p>
      </div>
    </aside>
  );
}
