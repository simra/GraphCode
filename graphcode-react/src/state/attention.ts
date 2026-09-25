import type { LoopGraph, LoopNode } from "../protocol/domain";

export type AttentionReason =
  "failed" | "stalled" | "awaiting input" | "blocked";

export interface AttentionItem {
  nodeId: string;
  nodeTitle: string;
  reason: AttentionReason;
}

function encodedCase(value: LoopNode["state"]): string {
  return typeof value === "string"
    ? value
    : (Object.keys(value)[0] ?? "unknown");
}

function createdAtMilliseconds(
  value: LoopNode["createdAt"],
): number | undefined {
  if (value === undefined) return undefined;
  if (typeof value === "number") {
    return value < 10_000_000_000 ? value * 1000 : value;
  }
  const parsed = Date.parse(value);
  return Number.isNaN(parsed) ? undefined : parsed;
}

function runsUnattended(node: LoopNode) {
  return node.loopType === "timeBased" || node.loopType === "goalBased";
}

export function displayState(node: LoopNode, now = Date.now()): string {
  const state = encodedCase(node.state);
  const presence = node.presence;
  if (presence?.exitCode === undefined) {
    if (presence?.presence === "busy") return "running";
    if (presence?.presence === "awaitingInput") return "awaitingInput";
  }
  if (state !== "running" || !presence) return state;
  if (presence.exitCode !== undefined) {
    return presence.exitCode === 0 ? "idle" : "failed";
  }
  if (presence.presence === "idle") {
    return node.hasActiveDependents ? "waiting" : "idle";
  }
  if (presence.presence === "absent") {
    if (node.hasActiveDependents) return "waiting";
    const createdAt = createdAtMilliseconds(node.createdAt);
    return runsUnattended(node) &&
      createdAt !== undefined &&
      createdAt < now - 60_000
      ? "failed"
      : "idle";
  }
  return state;
}

function directReason(
  node: LoopNode,
  now: number,
): AttentionReason | undefined {
  switch (displayState(node, now)) {
    case "failed":
      return "failed";
    case "stalled":
      return "stalled";
    case "awaitingInput":
      return "awaiting input";
    default:
      return undefined;
  }
}

function mayStillReachResolution(node: LoopNode, now: number) {
  if (
    ["succeeded", "failed", "stalled", "stopped"].includes(
      encodedCase(node.state),
    )
  ) {
    return false;
  }
  const presence = node.presence;
  if (
    presence?.exitCode === undefined &&
    (presence?.presence === "busy" || presence?.presence === "awaitingInput")
  ) {
    return true;
  }
  if (
    !presence ||
    (presence.presence === "unknown" && presence.exitCode === undefined)
  ) {
    return true;
  }
  const createdAt = createdAtMilliseconds(node.createdAt);
  if (createdAt === undefined || now < createdAt + 60_000) return true;
  return runsUnattended(node) && displayState(node, now) !== "failed";
}

function graphAttention(graph: LoopGraph, now: number): AttentionItem[] {
  const items = graph.nodes.flatMap((node) => {
    const reason = directReason(node, now);
    const own = reason
      ? [{ nodeId: node.id, nodeTitle: node.title, reason }]
      : [];
    return node.subGraph
      ? [...own, ...graphAttention(node.subGraph, now)]
      : own;
  });
  const reported = new Set(items.map((item) => item.nodeId));
  for (const node of graph.nodes) {
    if (encodedCase(node.state) !== "blocked" || reported.has(node.id))
      continue;
    const inbound = graph.edges.filter(
      (edge) =>
        edge.to === node.id &&
        (edge.kind ?? "handoff") === "handoff" &&
        (edge.fireCount ?? 0) === 0,
    );
    if (
      inbound.length &&
      !inbound.some((edge) => {
        const source = graph.nodes.find(({ id }) => id === edge.from);
        return source ? mayStillReachResolution(source, now) : false;
      })
    ) {
      items.push({
        nodeId: node.id,
        nodeTitle: node.title,
        reason: "blocked",
      });
    }
  }
  return items;
}

export function attentionItems(
  graph: LoopGraph,
  now = Date.now(),
): AttentionItem[] {
  const rank: Record<AttentionReason, number> = {
    failed: 0,
    stalled: 1,
    "awaiting input": 2,
    blocked: 3,
  };
  return graphAttention(graph, now).sort(
    (left, right) => rank[left.reason] - rank[right.reason],
  );
}

export function attentionSummary(items: readonly AttentionItem[]): string {
  const counts = new Map<AttentionReason, number>();
  for (const item of items) {
    counts.set(item.reason, (counts.get(item.reason) ?? 0) + 1);
  }
  const details = (["failed", "stalled", "awaiting input", "blocked"] as const)
    .flatMap((reason) => {
      const count = counts.get(reason);
      return count ? [`${count} ${reason}`] : [];
    })
    .join(", ");
  return `${items.length} need attention: ${details}`;
}
