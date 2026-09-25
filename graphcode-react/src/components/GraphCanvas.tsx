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
const emptyNodePositions: Record<string, Position> = {};

export interface Position {
  x: number;
  y: number;
}

interface EdgeDrag {
  sourceId: string;
  pointerId: number;
  x: number;
  y: number;
  targetId?: string;
}

interface PointerSample {
  x: number;
  y: number;
}

interface PinchGesture {
  pointerIds: [number, number];
  distance: number;
  viewport: Viewport;
  anchor: Position;
}

interface NodeDrag {
  nodeId: string;
  pointerId: number;
  clientX: number;
  clientY: number;
  origin: Position;
  moved: boolean;
}

export interface GraphLayout {
  positions: Map<string, Position>;
  width: number;
  height: number;
}

export interface Viewport {
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
  resetLayout(): void;
}

export function edgeTargetAtPoint(
  nodes: LoopNode[],
  positions: Map<string, Position>,
  sourceId: string,
  point: Position,
): string | undefined {
  return nodes.find((node) => {
    if (node.id === sourceId) return false;
    const position = positions.get(node.id);
    return (
      position !== undefined &&
      point.x >= position.x &&
      point.x <= position.x + cardWidth &&
      point.y >= position.y &&
      point.y <= position.y + cardHeight
    );
  })?.id;
}

type GraphDirection = "left" | "right" | "up" | "down";

export function adjacentNodeId(
  nodeId: string,
  direction: GraphDirection,
  positions: Map<string, Position>,
): string | undefined {
  const origin = positions.get(nodeId);
  if (!origin) return undefined;
  let best: { id: string; score: number } | undefined;
  for (const [candidateId, candidate] of positions) {
    if (candidateId === nodeId) continue;
    const dx = candidate.x - origin.x;
    const dy = candidate.y - origin.y;
    const primary =
      direction === "right"
        ? dx
        : direction === "left"
          ? -dx
          : direction === "down"
            ? dy
            : -dy;
    if (primary <= 0) continue;
    const cross =
      direction === "left" || direction === "right"
        ? Math.abs(dy)
        : Math.abs(dx);
    if (cross > primary * 2) continue;
    const score = primary + cross * 2;
    if (!best || score < best.score) {
      best = { id: candidateId, score };
    }
  }
  return best?.id;
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

export function applyNodePositions(
  layout: GraphLayout,
  nodes: LoopNode[],
  savedPositions: Record<string, Position>,
): GraphLayout {
  const nodeIds = new Set(nodes.map((node) => node.id));
  const positions = new Map(layout.positions);
  for (const [nodeId, position] of Object.entries(savedPositions)) {
    if (nodeIds.has(nodeId)) positions.set(nodeId, position);
  }
  return {
    positions,
    width: Math.max(
      layout.width,
      ...[...positions.values()].map(
        (position) => position.x + cardWidth + padding,
      ),
    ),
    height: Math.max(
      layout.height,
      ...[...positions.values()].map(
        (position) => position.y + cardHeight + padding,
      ),
    ),
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

export function zoomedViewport(
  viewport: Viewport,
  factor: number,
  minimumWidth: number,
  maximumWidth: number,
  anchor: Position = {
    x: viewport.x + viewport.width / 2,
    y: viewport.y + viewport.height / 2,
  },
  anchorRatio: Position = {
    x: (anchor.x - viewport.x) / viewport.width,
    y: (anchor.y - viewport.y) / viewport.height,
  },
): Viewport {
  const width = Math.min(
    maximumWidth,
    Math.max(minimumWidth, viewport.width / factor),
  );
  const height = viewport.height * (width / viewport.width);
  return {
    x: anchor.x - anchorRatio.x * width,
    y: anchor.y - anchorRatio.y * height,
    width,
    height,
  };
}

export const GraphCanvas = forwardRef<
  GraphCanvasHandle,
  {
    graph?: LoopGraph;
    selectedNodeId?: string;
    selectedEdgeKey?: string;
    commands?: AppCommand[];
    pendingCommandId?: string;
    initialViewport?: Viewport;
    initialNodePositions?: Record<string, Position>;
    viewportKey?: string;
    onSelectNode?(nodeId: string): void;
    onSelectEdge?(edgeKey?: string): void;
    onExecuteCommand?(command: AppCommand): void;
    onCreateEdge?(from: string, to: string): void;
    onViewportChange?(viewport: Viewport): void;
    onNodePositionsChange?(positions: Record<string, Position>): void;
  }
>(function GraphCanvas(
  {
    graph,
    selectedNodeId,
    selectedEdgeKey,
    commands = [],
    pendingCommandId,
    initialViewport,
    initialNodePositions = emptyNodePositions,
    viewportKey,
    onSelectNode,
    onSelectEdge,
    onExecuteCommand = () => undefined,
    onCreateEdge,
    onViewportChange,
    onNodePositionsChange,
  },
  ref,
) {
  const automaticLayout = useMemo(
    () => buildGraphLayout(graph?.nodes ?? [], graph?.edges ?? []),
    [graph?.edges, graph?.nodes],
  );
  const [nodePositions, setNodePositions] =
    useState<Record<string, Position>>(initialNodePositions);
  const nodePositionsRef = useRef(nodePositions);
  nodePositionsRef.current = nodePositions;
  const layout = useMemo(
    () =>
      applyNodePositions(automaticLayout, graph?.nodes ?? [], nodePositions),
    [automaticLayout, graph?.nodes, nodePositions],
  );
  const [viewport, setViewport] = useState<Viewport>(() =>
    fittedViewport(layout),
  );
  const [edgeDrag, setEdgeDrag] = useState<EdgeDrag>();
  const dragRef = useRef<{ x: number; y: number } | undefined>(undefined);
  const edgeDragRef = useRef<EdgeDrag | undefined>(undefined);
  const nodeDragRef = useRef<NodeDrag | undefined>(undefined);
  const touchPointersRef = useRef(new Map<number, PointerSample>());
  const pinchRef = useRef<PinchGesture | undefined>(undefined);
  const suppressClickRef = useRef(false);
  const svgRef = useRef<SVGSVGElement>(null);
  const onViewportChangeRef = useRef(onViewportChange);
  const onNodePositionsChangeRef = useRef(onNodePositionsChange);
  onViewportChangeRef.current = onViewportChange;
  onNodePositionsChangeRef.current = onNodePositionsChange;

  useEffect(() => {
    const next = initialViewport ?? fittedViewport(automaticLayout);
    setViewport((current) =>
      current.x === next.x &&
      current.y === next.y &&
      current.width === next.width &&
      current.height === next.height
        ? current
        : next,
    );
    setEdgeDrag(undefined);
    edgeDragRef.current = undefined;
    touchPointersRef.current.clear();
    pinchRef.current = undefined;
  }, [
    graph?.id,
    initialViewport?.height,
    initialViewport?.width,
    initialViewport?.x,
    initialViewport?.y,
    automaticLayout,
    viewportKey,
  ]);

  useEffect(() => {
    setNodePositions((current) => {
      const currentEntries = Object.entries(current);
      const nextEntries = Object.entries(initialNodePositions);
      return currentEntries.length === nextEntries.length &&
        nextEntries.every(
          ([nodeId, position]) =>
            current[nodeId]?.x === position.x &&
            current[nodeId]?.y === position.y,
        )
        ? current
        : initialNodePositions;
    });
    nodeDragRef.current = undefined;
  }, [graph?.id, initialNodePositions, viewportKey]);

  useEffect(() => {
    onViewportChangeRef.current?.(viewport);
  }, [viewport]);

  const edgeDragSourcePosition = edgeDrag
    ? layout.positions.get(edgeDrag.sourceId)
    : undefined;

  function zoom(factor: number, anchor?: Position, anchorRatio?: Position) {
    setViewport((current) =>
      zoomedViewport(
        current,
        factor,
        cardWidth * 1.4,
        Math.max(cardWidth * 1.4, layout.width * 4),
        anchor,
        anchorRatio,
      ),
    );
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
      resetLayout: () => {
        nodePositionsRef.current = {};
        setNodePositions({});
        onNodePositionsChangeRef.current?.({});
      },
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

  function graphPoint(event: ReactPointerEvent<SVGElement>): Position {
    const bounds = svgRef.current?.getBoundingClientRect();
    if (!bounds?.width || !bounds.height) return { x: 0, y: 0 };
    return {
      x:
        viewport.x +
        ((event.clientX - bounds.left) / bounds.width) * viewport.width,
      y:
        viewport.y +
        ((event.clientY - bounds.top) / bounds.height) * viewport.height,
    };
  }

  function pointInViewport(
    point: PointerSample,
    bounds: DOMRect,
    targetViewport: Viewport,
  ): Position {
    return {
      x:
        targetViewport.x +
        ((point.x - bounds.left) / bounds.width) * targetViewport.width,
      y:
        targetViewport.y +
        ((point.y - bounds.top) / bounds.height) * targetViewport.height,
    };
  }

  function startTouch(event: ReactPointerEvent<SVGSVGElement>) {
    if (event.pointerType !== "touch") return;
    touchPointersRef.current.set(event.pointerId, {
      x: event.clientX,
      y: event.clientY,
    });
    event.currentTarget.setPointerCapture(event.pointerId);
    if (touchPointersRef.current.size !== 2 || !svgRef.current) return;
    const entries = [...touchPointersRef.current.entries()];
    const [[firstId, first], [secondId, second]] = entries;
    const distance = Math.hypot(second.x - first.x, second.y - first.y);
    const bounds = svgRef.current.getBoundingClientRect();
    if (!distance || !bounds.width || !bounds.height) return;
    const midpoint = {
      x: (first.x + second.x) / 2,
      y: (first.y + second.y) / 2,
    };
    pinchRef.current = {
      pointerIds: [firstId, secondId],
      distance,
      viewport,
      anchor: pointInViewport(midpoint, bounds, viewport),
    };
    dragRef.current = undefined;
    edgeDragRef.current = undefined;
    setEdgeDrag(undefined);
    if (nodeDragRef.current?.moved) {
      onNodePositionsChangeRef.current?.(nodePositionsRef.current);
    }
    nodeDragRef.current = undefined;
  }

  function movePinch(event: ReactPointerEvent<SVGSVGElement>) {
    if (
      event.pointerType !== "touch" ||
      !touchPointersRef.current.has(event.pointerId)
    ) {
      return false;
    }
    touchPointersRef.current.set(event.pointerId, {
      x: event.clientX,
      y: event.clientY,
    });
    const pinch = pinchRef.current;
    const bounds = svgRef.current?.getBoundingClientRect();
    if (!pinch || !bounds?.width || !bounds.height) return false;
    const first = touchPointersRef.current.get(pinch.pointerIds[0]);
    const second = touchPointersRef.current.get(pinch.pointerIds[1]);
    if (!first || !second) return false;
    const distance = Math.hypot(second.x - first.x, second.y - first.y);
    if (!distance) return true;
    const midpoint = {
      x: (first.x + second.x) / 2,
      y: (first.y + second.y) / 2,
    };
    setViewport(
      zoomedViewport(
        pinch.viewport,
        distance / pinch.distance,
        cardWidth * 1.4,
        Math.max(cardWidth * 1.4, layout.width * 4),
        pinch.anchor,
        {
          x: (midpoint.x - bounds.left) / bounds.width,
          y: (midpoint.y - bounds.top) / bounds.height,
        },
      ),
    );
    return true;
  }

  function endTouch(event: ReactPointerEvent<SVGSVGElement>) {
    if (event.pointerType !== "touch") return;
    const wasPinching = Boolean(pinchRef.current);
    touchPointersRef.current.delete(event.pointerId);
    if (
      pinchRef.current?.pointerIds.includes(event.pointerId) ||
      touchPointersRef.current.size < 2
    ) {
      pinchRef.current = undefined;
    }
    if (wasPinching) {
      suppressClickRef.current = true;
      window.setTimeout(() => {
        suppressClickRef.current = false;
      }, 0);
    }
  }

  function moveNode(event: ReactPointerEvent<SVGSVGElement>) {
    const current = nodeDragRef.current;
    const bounds = svgRef.current?.getBoundingClientRect();
    if (
      !current ||
      current.pointerId !== event.pointerId ||
      !bounds?.width ||
      !bounds.height
    ) {
      return false;
    }
    const deltaX =
      ((event.clientX - current.clientX) / bounds.width) * viewport.width;
    const deltaY =
      ((event.clientY - current.clientY) / bounds.height) * viewport.height;
    const next = {
      x: Math.max(0, current.origin.x + deltaX),
      y: Math.max(0, current.origin.y + deltaY),
    };
    const moved =
      current.moved ||
      Math.hypot(
        event.clientX - current.clientX,
        event.clientY - current.clientY,
      ) >= 3;
    nodeDragRef.current = { ...current, moved };
    if (moved) {
      const positions = {
        ...nodePositionsRef.current,
        [current.nodeId]: next,
      };
      nodePositionsRef.current = positions;
      setNodePositions(positions);
    }
    return true;
  }

  function finishNode(pointerId: number) {
    const current = nodeDragRef.current;
    if (!current || current.pointerId !== pointerId) return;
    nodeDragRef.current = undefined;
    if (!current.moved) return;
    suppressClickRef.current = true;
    window.setTimeout(() => {
      suppressClickRef.current = false;
    }, 0);
    onNodePositionsChangeRef.current?.(nodePositionsRef.current);
  }

  function moveEdge(event: ReactPointerEvent<SVGSVGElement>) {
    const current = edgeDragRef.current;
    if (!current || current.pointerId !== event.pointerId) return false;
    const point = graphPoint(event);
    const next = {
      ...current,
      ...point,
      targetId: edgeTargetAtPoint(
        graph?.nodes ?? [],
        layout.positions,
        current.sourceId,
        point,
      ),
    };
    edgeDragRef.current = next;
    setEdgeDrag(next);
    return true;
  }

  function finishEdge(pointerId: number) {
    const current = edgeDragRef.current;
    edgeDragRef.current = undefined;
    setEdgeDrag(undefined);
    if (current?.pointerId === pointerId && current.targetId && onCreateEdge) {
      onCreateEdge(current.sourceId, current.targetId);
    }
  }

  function wheelZoom(event: WheelEvent<SVGSVGElement>) {
    event.preventDefault();
    const bounds = svgRef.current?.getBoundingClientRect();
    if (!bounds?.width || !bounds.height) return;
    const anchor = {
      x:
        viewport.x +
        ((event.clientX - bounds.left) / bounds.width) * viewport.width,
      y:
        viewport.y +
        ((event.clientY - bounds.top) / bounds.height) * viewport.height,
    };
    zoom(event.deltaY < 0 ? 1.12 : 1 / 1.12, anchor);
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
      <p id="graph-keyboard-instructions" className="canvas-help">
        Tab to a loop or edge. Arrow keys move between nearby loops; Home and
        End jump to the first and last loop. Alt+Arrow repositions a loop, and
        Enter or Space selects. Wheel and pinch zoom stay anchored beneath the
        pointer or touch midpoint.
      </p>
      <div className="canvas-scroll">
        <svg
          ref={svgRef}
          className="graph-canvas"
          viewBox={`${viewport.x} ${viewport.y} ${viewport.width} ${viewport.height}`}
          role="group"
          aria-labelledby="graph-svg-title graph-svg-description"
          aria-describedby="graph-keyboard-instructions"
          onWheel={wheelZoom}
          onClickCapture={(event) => {
            if (suppressClickRef.current) {
              event.preventDefault();
              event.stopPropagation();
            }
          }}
          onPointerDownCapture={startTouch}
          onPointerDown={(event) => {
            if (
              event.button !== 0 ||
              (event.target as Element).closest(".graph-node, .graph-edge")
            )
              return;
            event.currentTarget.setPointerCapture(event.pointerId);
            dragRef.current = { x: event.clientX, y: event.clientY };
          }}
          onPointerMove={pan}
          onPointerMoveCapture={(event) => {
            if (movePinch(event) || moveNode(event) || moveEdge(event)) {
              event.stopPropagation();
            }
          }}
          onPointerUp={(event) => {
            endTouch(event);
            finishNode(event.pointerId);
            finishEdge(event.pointerId);
            dragRef.current = undefined;
            if (event.currentTarget.hasPointerCapture(event.pointerId)) {
              event.currentTarget.releasePointerCapture(event.pointerId);
            }
          }}
          onPointerCancel={(event) => {
            endTouch(event);
            finishNode(event.pointerId);
            dragRef.current = undefined;
            edgeDragRef.current = undefined;
            setEdgeDrag(undefined);
          }}
        >
          <title id="graph-svg-title">{graph.project.name}</title>
          <desc id="graph-svg-description">
            {graph.nodes.length} loops connected by {graph.edges.length} edges.
            Use the toolbar or keyboard shortcuts to zoom, and drag the
            background to pan. Wheel and pinch zoom remain anchored beneath the
            pointer or touch midpoint. Drag a loop to reposition it, or use
            Alt+Arrow. Drag from a loop connection handle to another loop to
            configure an edge, or use New Edge for a keyboard accessible
            alternative.
          </desc>
          <defs>
            <pattern
              id="goal-pattern"
              width="6"
              height="6"
              patternUnits="userSpaceOnUse"
            >
              <rect width="6" height="6" fill="#c88d58" />
              <path d="M-1,1 L1,-1 M0,6 L6,0 M5,7 L7,5" stroke="#1b1f19" />
            </pattern>
            <pattern
              id="turn-pattern"
              width="6"
              height="6"
              patternUnits="userSpaceOnUse"
            >
              <rect width="6" height="6" fill="#74a4c7" />
              <circle cx="3" cy="3" r="1.3" fill="#1b1f19" />
            </pattern>
            <pattern
              id="proactive-pattern"
              width="6"
              height="6"
              patternUnits="userSpaceOnUse"
            >
              <rect width="6" height="6" fill="#a987c7" />
              <path d="M0,3 H6 M3,0 V6" stroke="#1b1f19" />
            </pattern>
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
            const edgeKey = edge.id ?? `${edge.from}-${edge.to}-${index}`;
            const fromTitle =
              graph.nodes.find((node) => node.id === edge.from)?.title ??
              edge.from;
            const toTitle =
              graph.nodes.find((node) => node.id === edge.to)?.title ?? edge.to;
            return (
              <path
                key={edgeKey}
                className={`${edge.fireCount ? "graph-edge graph-edge-fired" : "graph-edge"}${selectedEdgeKey === edgeKey ? " graph-edge-selected" : ""}`}
                d={`M ${from.x + cardWidth} ${from.y + cardHeight / 2} C ${from.x + cardWidth + 42} ${from.y + cardHeight / 2}, ${to.x - 42} ${to.y + cardHeight / 2}, ${to.x} ${to.y + cardHeight / 2}`}
                markerEnd="url(#arrow)"
                style={{ pointerEvents: "stroke" }}
                role="button"
                tabIndex={0}
                aria-label={`Edge from ${fromTitle} to ${toTitle}, ${edge.kind ?? "connection"}${edge.fireCount ? `, fired ${edge.fireCount} time${edge.fireCount === 1 ? "" : "s"}` : ""}`}
                aria-pressed={selectedEdgeKey === edgeKey}
                aria-keyshortcuts="Enter Space Escape"
                onClick={(event) => {
                  event.stopPropagation();
                  onSelectEdge?.(
                    selectedEdgeKey === edgeKey ? undefined : edgeKey,
                  );
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    onSelectEdge?.(
                      selectedEdgeKey === edgeKey ? undefined : edgeKey,
                    );
                  } else if (event.key === "Escape") {
                    onSelectEdge?.(undefined);
                  }
                }}
              />
            );
          })}
          {edgeDrag && edgeDragSourcePosition ? (
            <path
              className="graph-edge-preview"
              d={`M ${edgeDragSourcePosition.x + cardWidth} ${edgeDragSourcePosition.y + cardHeight / 2} C ${edgeDragSourcePosition.x + cardWidth + 42} ${edgeDragSourcePosition.y + cardHeight / 2}, ${edgeDrag.x - 42} ${edgeDrag.y}, ${edgeDrag.x} ${edgeDrag.y}`}
              markerEnd="url(#arrow)"
              aria-hidden="true"
            />
          ) : null}
          {graph.nodes.map((node, index) => {
            const position = layout.positions.get(node.id)!;
            const state = stateLabel(node);
            const selected = selectedNodeId === node.id;
            const selectNode = () => {
              onSelectEdge?.(undefined);
              onSelectNode?.(node.id);
            };
            return (
              <g
                id={`graph-node-${node.id}`}
                key={node.id}
                className={`graph-node${selected ? " graph-node-selected" : ""}${edgeDrag?.sourceId === node.id ? " graph-node-edge-source" : ""}${edgeDrag?.targetId === node.id ? " graph-node-edge-target" : ""}`}
                transform={`translate(${position.x} ${position.y})`}
                role="button"
                aria-label={`${node.title}, ${node.loopType ?? "loop"}, ${state}${selected ? ", selected" : ""}`}
                aria-pressed={selected}
                aria-keyshortcuts="ArrowLeft ArrowRight ArrowUp ArrowDown Alt+ArrowLeft Alt+ArrowRight Alt+ArrowUp Alt+ArrowDown Home End Enter Space"
                tabIndex={selected || (!selectedNodeId && index === 0) ? 0 : -1}
                onClick={selectNode}
                onPointerDown={(event) => {
                  if (
                    event.button !== 0 ||
                    (event.target as Element).closest(".edge-drag-handle")
                  ) {
                    return;
                  }
                  event.stopPropagation();
                  nodeDragRef.current = {
                    nodeId: node.id,
                    pointerId: event.pointerId,
                    clientX: event.clientX,
                    clientY: event.clientY,
                    origin: position,
                    moved: false,
                  };
                  svgRef.current?.setPointerCapture(event.pointerId);
                }}
                onKeyDown={(event) => {
                  if (event.key === "Enter" || event.key === " ") {
                    event.preventDefault();
                    selectNode();
                    return;
                  }
                  const nudge =
                    event.key === "ArrowRight"
                      ? { x: 24, y: 0 }
                      : event.key === "ArrowLeft"
                        ? { x: -24, y: 0 }
                        : event.key === "ArrowDown"
                          ? { x: 0, y: 24 }
                          : event.key === "ArrowUp"
                            ? { x: 0, y: -24 }
                            : undefined;
                  if (event.altKey && nudge) {
                    event.preventDefault();
                    const positions = {
                      ...nodePositionsRef.current,
                      [node.id]: {
                        x: Math.max(0, position.x + nudge.x),
                        y: Math.max(0, position.y + nudge.y),
                      },
                    };
                    nodePositionsRef.current = positions;
                    setNodePositions(positions);
                    onNodePositionsChangeRef.current?.(positions);
                    return;
                  }
                  const direction: GraphDirection | undefined =
                    event.key === "ArrowRight"
                      ? "right"
                      : event.key === "ArrowLeft"
                        ? "left"
                        : event.key === "ArrowDown"
                          ? "down"
                          : event.key === "ArrowUp"
                            ? "up"
                            : undefined;
                  const nextId =
                    event.key === "Home"
                      ? graph.nodes[0]?.id
                      : event.key === "End"
                        ? graph.nodes.at(-1)?.id
                        : direction
                          ? adjacentNodeId(node.id, direction, layout.positions)
                          : undefined;
                  if (!nextId) return;
                  event.preventDefault();
                  onSelectNode?.(nextId);
                  requestAnimationFrame(() =>
                    document.getElementById(`graph-node-${nextId}`)?.focus(),
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
                <text
                  className="node-kind"
                  x={cardWidth - 16}
                  y="86"
                  textAnchor="end"
                >
                  {node.loopType ?? "loop"}
                </text>
                {selected ? (
                  <text
                    className="node-selection-indicator"
                    x={cardWidth - 17}
                    y="27"
                    textAnchor="end"
                    aria-hidden="true"
                  >
                    ✓
                  </text>
                ) : null}
                {onCreateEdge ? (
                  <circle
                    className="edge-drag-handle"
                    cx={cardWidth}
                    cy={cardHeight / 2}
                    r="9"
                    aria-hidden="true"
                    onPointerDown={(event) => {
                      if (event.button !== 0) return;
                      event.preventDefault();
                      event.stopPropagation();
                      const start = {
                        sourceId: node.id,
                        pointerId: event.pointerId,
                        x: position.x + cardWidth,
                        y: position.y + cardHeight / 2,
                      };
                      edgeDragRef.current = start;
                      setEdgeDrag(start);
                      svgRef.current?.setPointerCapture(event.pointerId);
                    }}
                  />
                ) : null}
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
