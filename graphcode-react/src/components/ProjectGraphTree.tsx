import { useEffect, useState } from "react";
import type { LoopGraph, LoopNode } from "../protocol/domain";

function stateLabel(node: LoopNode) {
  if (typeof node.state === "string") return node.state;
  return Object.keys(node.state)[0] ?? "unknown";
}

function pathKey(path: readonly string[]) {
  return JSON.stringify(path);
}

export function ProjectGraphTree({
  graph,
  compositePath,
  selectedNodeId,
  onSelectNode,
  onOpenGraph,
}: {
  graph: LoopGraph;
  compositePath: readonly string[];
  selectedNodeId?: string;
  onSelectNode(parentPath: string[], nodeId: string): void;
  onOpenGraph(path: string[]): void;
}) {
  const [expanded, setExpanded] = useState(
    () =>
      new Set(
        compositePath.map((_, index) =>
          pathKey(compositePath.slice(0, index + 1)),
        ),
      ),
  );

  useEffect(() => {
    setExpanded((current) => {
      const next = new Set(current);
      compositePath.forEach((_, index) =>
        next.add(pathKey(compositePath.slice(0, index + 1))),
      );
      return next;
    });
  }, [compositePath]);

  function renderNodes(currentGraph: LoopGraph, parentPath: string[]) {
    return (
      <ul>
        {currentGraph.nodes.map((node) => {
          const childPath = [...parentPath, node.id];
          const childKey = pathKey(childPath);
          const hasChildGraph = Boolean(node.subGraph);
          const isExpanded = hasChildGraph && expanded.has(childKey);
          const selected =
            selectedNodeId === node.id &&
            pathKey(compositePath) === pathKey(parentPath);
          return (
            <li key={node.id}>
              <div className="project-tree-row">
                <button
                  className={`project-tree-node${selected ? " project-selected" : ""}`}
                  type="button"
                  aria-current={selected ? "true" : undefined}
                  onClick={() => onSelectNode(parentPath, node.id)}
                >
                  <span aria-hidden="true">{hasChildGraph ? "◇" : "·"}</span>
                  <span>
                    <strong>{node.title}</strong>
                    <small>
                      {node.loopType ?? "loop"} · {stateLabel(node)}
                    </small>
                  </span>
                </button>
                {hasChildGraph ? (
                  <>
                    <button
                      className="project-tree-open"
                      type="button"
                      title={`Open ${node.title} composite graph`}
                      aria-label={`Open ${node.title} composite graph`}
                      onClick={() => onOpenGraph(childPath)}
                    >
                      ↳
                    </button>
                    <button
                      className="project-tree-toggle"
                      type="button"
                      aria-expanded={isExpanded}
                      aria-label={`${isExpanded ? "Collapse" : "Expand"} ${node.title}`}
                      onClick={() =>
                        setExpanded((current) => {
                          const next = new Set(current);
                          if (next.has(childKey)) {
                            next.delete(childKey);
                          } else {
                            next.add(childKey);
                          }
                          return next;
                        })
                      }
                    >
                      {isExpanded ? "−" : "+"}
                    </button>
                  </>
                ) : null}
              </div>
              {node.subGraph && isExpanded
                ? renderNodes(node.subGraph, childPath)
                : null}
            </li>
          );
        })}
      </ul>
    );
  }

  return (
    <nav
      className="project-graph-tree"
      aria-label={`${graph.project.name} graph hierarchy`}
    >
      {graph.nodes.length ? (
        renderNodes(graph, [])
      ) : (
        <p>No loops in this graph.</p>
      )}
    </nav>
  );
}
