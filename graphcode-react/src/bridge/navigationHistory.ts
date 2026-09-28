import { invoke } from "@tauri-apps/api/core";
import { z } from "zod";
import {
  createNavigationHistory,
  type NavigationHistory,
} from "../state/navigationHistory";

const routeSchema = z.discriminatedUnion("kind", [
  z.object({
    kind: z.literal("project"),
    projectPath: z.string().min(1).max(32_768),
    compositePath: z.array(z.string().min(1).max(8_192)).max(64),
    nodeId: z.string().min(1).max(8_192).optional(),
    terminal: z.boolean().optional(),
  }),
  z.object({
    kind: z.literal("mailroom"),
    projectPath: z.string().min(1).max(32_768),
  }),
  z.object({ kind: z.literal("quickChats") }),
  z.object({
    kind: z.literal("quickChat"),
    id: z.string().min(1).max(8_192),
  }),
]);

const historySchema = z.object({
  version: z.literal(1),
  entries: z.array(routeSchema).max(50),
  cursor: z.number().int().nonnegative().optional(),
});

export function decodeNavigationHistory(value: unknown): NavigationHistory {
  const parsed = historySchema.parse(value);
  return createNavigationHistory(parsed.entries, parsed.cursor);
}

export async function loadNavigationHistory(): Promise<NavigationHistory> {
  if (!("__TAURI_INTERNALS__" in window)) return createNavigationHistory();
  return decodeNavigationHistory(
    await invoke<unknown>("load_navigation_history"),
  );
}

export async function saveNavigationHistory(
  history: NavigationHistory,
): Promise<void> {
  if (!("__TAURI_INTERNALS__" in window)) return;
  const parsed = historySchema.parse(history);
  await invoke("save_navigation_history", { history: parsed });
}
