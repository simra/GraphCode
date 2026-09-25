import type { LoopGraph, LoopNode } from "../protocol/domain";

const cardWidth = 220;
const cardHeight = 104;
const gap = 72;
const padding = 52;

function stateLabel(node: LoopNode): string {
  if (typeof node.state === "string") return node.state;
  return Object.keys(node.state)[0] ?? "unknown";
}

export function GraphCanvas({ graph }: { graph?: LoopGraph }) {
  if (!graph) {
    return (
      <section className="empty-canvas" aria-labelledby="empty-title">
        <p className="eyebrow">Graph canvas</p>
        <h2 id="empty-title">No graph snapshot yet</h2>
        <p>
          Connect to graphcoded or select a project snapshot from the sidebar.
        </p>
      </section>
    );
  }

  const width = Math.max(
    700,
    padding * 2 + graph.nodes.length * (cardWidth + gap),
  );
  const height = 360;
  const positions = new Map(
    graph.nodes.map((node, index) => [
      node.id,
      { x: padding + index * (cardWidth + gap), y: 126 },
    ]),
  );

  return (
    <section className="canvas-panel" aria-labelledby="graph-title">
      <div className="canvas-heading">
        <div>
          <p className="eyebrow">Project graph</p>
          <h2 id="graph-title">{graph.project.name}</h2>
        </div>
        <span>{graph.nodes.length} loops</span>
      </div>
      <div
        className="canvas-scroll"
        tabIndex={0}
        aria-label={`${graph.project.name} graph`}
      >
        <svg
          className="graph-canvas"
          viewBox={`0 0 ${width} ${height}`}
          role="img"
          aria-labelledby="graph-svg-title graph-svg-description"
        >
          <title id="graph-svg-title">{graph.project.name}</title>
          <desc id="graph-svg-description">
            {graph.nodes.length} loops connected by {graph.edges.length} edges.
          </desc>
          <defs>
            <marker
              id="arrow"
              markerWidth="10"
              markerHeight="10"
              refX="8"
              refY="3"
              orient="auto"
              markerUnits="strokeWidth"
            >
              <path d="M0,0 L0,6 L9,3 z" className="edge-arrow" />
            </marker>
          </defs>
          {graph.edges.map((edge, index) => {
            const from = positions.get(edge.from);
            const to = positions.get(edge.to);
            if (!from || !to) return null;
            return (
              <path
                key={edge.id ?? `${edge.from}-${edge.to}-${index}`}
                className={
                  edge.fireCount ? "graph-edge graph-edge-fired" : "graph-edge"
                }
                d={`M ${from.x + cardWidth} ${from.y + cardHeight / 2} C ${from.x + cardWidth + 34} ${from.y + cardHeight / 2}, ${to.x - 34} ${to.y + cardHeight / 2}, ${to.x} ${to.y + cardHeight / 2}`}
                markerEnd="url(#arrow)"
              />
            );
          })}
          {graph.nodes.map((node) => {
            const position = positions.get(node.id)!;
            const state = stateLabel(node);
            return (
              <g
                key={node.id}
                className="graph-node"
                transform={`translate(${position.x} ${position.y})`}
                role="group"
                aria-label={`${node.title}, ${state}`}
                tabIndex={0}
              >
                <rect width={cardWidth} height={cardHeight} rx="14" />
                <rect
                  className={`node-stripe node-${node.loopType ?? "unknown"}`}
                  width="6"
                  height={cardHeight}
                  rx="3"
                />
                <text className="node-title" x="22" y="32">
                  {node.title}
                </text>
                <text className="node-activity" x="22" y="58">
                  {(node.activity ?? node.loopType ?? "Loop").slice(0, 30)}
                </text>
                <text className={`node-state state-${state}`} x="22" y="86">
                  {state.toUpperCase()}
                </text>
              </g>
            );
          })}
        </svg>
      </div>
    </section>
  );
}
