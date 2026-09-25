import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
  type WheelEvent,
} from "react";
import type { AppCommand } from "../commands/registry";
import type { LoopEdge, LoopGraph, LoopNode } from "../protocol/domain";

const cardWidth = 220;
const cardHeight = 104;
const horizontalGap = 110;
const verticalGap = 64;
const padding = 52;
const defaultViewportWidth = 900;
const defaultViewportHeight = 420;

interface Position {
  x: number;
  y: number;
}

export interface GraphLayout {
  positions: Map<string, Position>;
  width: number;
  height: number;
}

interface Viewport {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface GraphCanvasHandle {
  zoomIn(): void;
  zoomOut(): void;
  resetZoom(): void;
  fitGraph(): void;
}

function stateLabel(node: LoopNode): string {
  if (typeof node.state === "string") return node.state;
  return Object.keys(node.state)[0] ?? "unknown";
}

export function buildGraphLayout(
  nodes: LoopNode[],
  edges: LoopEdge[],
): GraphLayout {
  const nodeIds = new Set(nodes.map((node) => node.id));
  const incoming = new Map(nodes.map((node) => [node.id, 0]));
  const outgoing = new Map(nodes.map((node) => [node.id, [] as string[]]));
  for (const edge of edges) {
    if (!nodeIds.has(edge.from) || !nodeIds.has(edge.to)) continue;
    incoming.set(edge.to, (incoming.get(edge.to) ?? 0) + 1);
    outgoing.get(edge.from)?.push(edge.to);
  }

  const levels = new Map<string, number>();
  const queue = nodes
    .filter((node) => incoming.get(node.id) === 0)
    .map((node) => node.id);
  for (const id of queue) levels.set(id, 0);
  for (let index = 0; index < queue.length; index += 1) {
    const id = queue[index];
    for (const target of outgoing.get(id) ?? []) {
      levels.set(
        target,
        Math.max(levels.get(target) ?? 0, levels.get(id)! + 1),
      );
      const remaining = (incoming.get(target) ?? 1) - 1;
      incoming.set(target, remaining);
      if (remaining === 0) queue.push(target);
    }
  }

  let fallbackLevel = levels.size ? Math.max(...levels.values()) + 1 : 0;
  for (const node of nodes) {
    if (!levels.has(node.id)) {
      levels.set(node.id, fallbackLevel);
      fallbackLevel += 1;
    }
  }

  const layers = new Map<number, LoopNode[]>();
  for (const node of nodes) {
    const level = levels.get(node.id) ?? 0;
    layers.set(level, [...(layers.get(level) ?? []), node]);
  }
  const positions = new Map<string, Position>();
  let maxRows = 1;
  for (const [level, layer] of [...layers.entries()].sort(
    ([left], [right]) => left - right,
  )) {
    maxRows = Math.max(maxRows, layer.length);
    layer.forEach((node, row) => {
      positions.set(node.id, {
        x: padding + level * (cardWidth + horizontalGap),
        y: padding + row * (cardHeight + verticalGap),
      });
    });
  }

  const levelCount = Math.max(1, layers.size);
  return {
    positions,
    width:
      padding * 2 + levelCount * cardWidth + (levelCount - 1) * horizontalGap,
    height: padding * 2 + maxRows * cardHeight + (maxRows - 1) * verticalGap,
  };
}

function fittedViewport(layout: GraphLayout): Viewport {
  return {
    x: 0,
    y: 0,
    width: Math.max(layout.width, defaultViewportWidth),
    height: Math.max(layout.height, defaultViewportHeight),
  };
}

export const GraphCanvas = forwardRef<
  GraphCanvasHandle,
  {
    graph?: LoopGraph;
    selectedNodeId?: string;
    commands?: AppCommand[];
    pendingCommandId?: string;
    onSelectNode?(nodeId: string): void;
    onExecuteCommand?(command: AppCommand): void;
  }
>(function GraphCanvas(
  {
    graph,
    selectedNodeId,
    commands = [],
    pendingCommandId,
    onSelectNode,
    onExecuteCommand = () => undefined,
  },
  ref,
) {
  const layout = useMemo(
    () => buildGraphLayout(graph?.nodes ?? [], graph?.edges ?? []),
    [graph?.edges, graph?.nodes],
  );
  const [viewport, setViewport] = useState<Viewport>(() =>
    fittedViewport(layout),
  );
  const dragRef = useRef<{ x: number; y: number } | undefined>(undefined);
  const svgRef = useRef<SVGSVGElement>(null);

  useEffect(() => {
    setViewport(fittedViewport(layout));
  }, [graph?.id, layout]);

  function zoom(factor: number) {
    setViewport((current) => {
      const width = Math.min(
        layout.width * 4,
        Math.max(cardWidth * 1.4, current.width / factor),
      );
      const height = current.height * (width / current.width);
      return {
        x: current.x + (current.width - width) / 2,
        y: current.y + (current.height - height) / 2,
        width,
        height,
      };
    });
  }

  useImperativeHandle(
    ref,
    () => ({
      zoomIn: () => zoom(1.2),
      zoomOut: () => zoom(1 / 1.2),
      resetZoom: () =>
        setViewport({
          x: 0,
          y: 0,
          width: defaultViewportWidth,
          height: defaultViewportHeight,
        }),
      fitGraph: () => setViewport(fittedViewport(layout)),
    }),
    [layout],
  );

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

  function pan(event: ReactPointerEvent<SVGSVGElement>) {
    if (!dragRef.current || !svgRef.current) return;
    const scale = viewport.width / svgRef.current.clientWidth;
    const deltaX = (event.clientX - dragRef.current.x) * scale;
    const deltaY = (event.clientY - dragRef.current.y) * scale;
    dragRef.current = { x: event.clientX, y: event.clientY };
    setViewport((current) => ({
      ...current,
      x: current.x - deltaX,
      y: current.y - deltaY,
    }));
  }

  function wheelZoom(event: WheelEvent<SVGSVGElement>) {
    event.preventDefault();
    zoom(event.deltaY < 0 ? 1.12 : 1 / 1.12);
  }

  return (
    <section className="canvas-panel" aria-labelledby="graph-title">
      <div className="canvas-heading">
        <div>
          <p className="eyebrow">Project graph</p>
          <h2 id="graph-title">{graph.project.name}</h2>
        </div>
        <div className="canvas-toolbar" aria-label="Graph viewport">
          <span>{graph.nodes.length} loops</span>
          {commands.map((command) => (
            <button
              key={command.id}
              type="button"
              disabled={!command.enabled || pendingCommandId === command.id}
              title={command.disabledReason ?? command.description}
              aria-label={command.label}
              onClick={() => onExecuteCommand(command)}
            >
              {command.label
                .replace("Zoom ", "")
                .replace("Fit Graph", "Fit")
                .replace("Reset Zoom", "100%")}
            </button>
          ))}
        </div>
      </div>
      <div className="canvas-scroll">
        <svg
          ref={svgRef}
          className="graph-canvas"
          viewBox={`${viewport.x} ${viewport.y} ${viewport.width} ${viewport.height}`}
          role="img"
          aria-labelledby="graph-svg-title graph-svg-description"
          tabIndex={0}
          onWheel={wheelZoom}
          onPointerDown={(event) => {
            if (
              event.button !== 0 ||
              (event.target as Element).closest(".graph-node")
            )
              return;
            event.currentTarget.setPointerCapture(event.pointerId);
            dragRef.current = { x: event.clientX, y: event.clientY };
          }}
          onPointerMove={pan}
          onPointerUp={(event) => {
            dragRef.current = undefined;
            if (event.currentTarget.hasPointerCapture(event.pointerId)) {
              event.currentTarget.releasePointerCapture(event.pointerId);
            }
          }}
          onPointerCancel={() => {
            dragRef.current = undefined;
          }}
        >
          <title id="graph-svg-title">{graph.project.name}</title>
          <desc id="graph-svg-description">
            {graph.nodes.length} loops connected by {graph.edges.length} edges.
            Use the toolbar or keyboard shortcuts to zoom, and drag the
            background to pan.
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
            const from = layout.positions.get(edge.from);
            const to = layout.positions.get(edge.to);
            if (!from || !to) return null;
            return (
              <path
                key={edge.id ?? `${edge.from}-${edge.to}-${index}`}
                className={
                  edge.fireCount ? "graph-edge graph-edge-fired" : "graph-edge"
                }
                d={`M ${from.x + cardWidth} ${from.y + cardHeight / 2} C ${from.x + cardWidth + 42} ${from.y + cardHeight / 2}, ${to.x - 42} ${to.y + cardHeight / 2}, ${to.x} ${to.y + cardHeight / 2}`}
                markerEnd="url(#arrow)"
              />
            );
          })}
          {graph.nodes.map((node, index) => {
            const position = layout.positions.get(node.id)!;
            const state = stateLabel(node);
            const selected = selectedNodeId === node.id;
            const selectNode = () => onSelectNode?.(node.id);
            return (
              <g
                id={`graph-node-${node.id}`}
                key={node.id}
                className={`graph-node${selected ? " graph-node-selected" : ""}`}
                transform={`translate(${position.x} ${position.y})`}
                role="button"
                aria-label={`${node.title}, ${state}`}
                aria-pressed={selected}
                tabIndex={selected || (!selectedNodeId && index === 0) ? 0 : -1}
                onClick={selectNode}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    selectNode();
                    return;
                  }
                  const direction =
                    event.key === "ArrowRight" || event.key === "ArrowDown"
                      ? 1
                      : event.key === "ArrowLeft" || event.key === "ArrowUp"
                        ? -1
                        : 0;
                  if (!direction) return;
                  event.preventDefault();
                  const next =
                    graph.nodes[
                      (index + direction + graph.nodes.length) %
                        graph.nodes.length
                    ];
                  onSelectNode?.(next.id);
                  requestAnimationFrame(() =>
                    document.getElementById(`graph-node-${next.id}`)?.focus(),
                  );
                }}
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
        <ol className="visually-hidden" aria-label="Graph loops">
          {graph.nodes.map((node) => (
            <li key={node.id}>
              {node.title}, {stateLabel(node)}
            </li>
          ))}
        </ol>
      </div>
    </section>
  );
});
