import type { LoopNode, PassSummary, SummaryBeat } from "../protocol/domain";
import { displayState } from "./attention";

const resolvedStates = new Set(["succeeded", "failed", "stalled", "stopped"]);

export interface LoopSummaryPresentation {
  mode: "starting" | "working" | "asking" | "resolved";
  current?: SummaryBeat;
  receding: SummaryBeat[];
  passes: PassSummary[];
  earlierPasses: number;
  pass?: number;
  unseen: number;
  isLive: boolean;
}

function encodedCase(value: LoopNode["state"]): string {
  return typeof value === "string"
    ? value
    : (Object.keys(value)[0] ?? "unknown");
}

export function summaryUnseenCount(
  beats: readonly SummaryBeat[],
  seenBeatId?: string,
): number {
  if (!beats.length) return 0;
  if (!seenBeatId) return beats.length;
  const seenIndex = beats.findIndex((beat) => beat.id === seenBeatId);
  return seenIndex === -1 ? beats.length : beats.length - seenIndex - 1;
}

export function presentLoopSummary(
  node: LoopNode,
  seenBeatId?: string,
): LoopSummaryPresentation {
  const beats = node.summary?.beats ?? [];
  const current = beats.at(-1);
  const state = encodedCase(node.state);
  const display = displayState(node);
  const mode = resolvedStates.has(state)
    ? "resolved"
    : display === "awaitingInput"
      ? "asking"
      : current
        ? "working"
        : "starting";
  const currentPass = current?.pass ?? node.summary?.currentPass;
  const passes = node.summary?.passes ?? [];

  return {
    mode,
    current,
    receding: beats.slice(0, -1).reverse(),
    passes,
    earlierPasses: Math.max(0, (currentPass ?? 0) - 1 - passes.length),
    pass: currentPass || undefined,
    unseen: summaryUnseenCount(beats, seenBeatId),
    isLive:
      node.presence?.presence === "busy" &&
      !resolvedStates.has(state) &&
      current?.endsTurn !== true,
  };
}

export function boardIsDrawable(node: LoopNode): boolean {
  const board = node.board;
  if (!board) return false;
  return board.form === "table"
    ? Boolean(board.table?.headers.length && board.table.rows.length)
    : board.nodes.length >= 2 && board.edges.length > 0;
}
