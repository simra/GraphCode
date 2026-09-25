import { invoke } from "@tauri-apps/api/core";
import { z } from "zod";

const maximumViewportValue = 10_000_000;

const viewportSchema = z.object({
  x: z.number().finite().min(-maximumViewportValue).max(maximumViewportValue),
  y: z.number().finite().min(-maximumViewportValue).max(maximumViewportValue),
  width: z.number().positive().finite().max(maximumViewportValue),
  height: z.number().positive().finite().max(maximumViewportValue),
});

const positionSchema = z.object({
  x: z.number().finite().min(0).max(maximumViewportValue),
  y: z.number().finite().min(0).max(maximumViewportValue),
});

const layoutStateSchema = z.object({
  version: z.literal(1),
  projects: z.record(
    z.string(),
    z.object({
      views: z.record(z.string(), viewportSchema),
      nodePositions: z
        .record(z.string(), z.record(z.string(), positionSchema))
        .default({}),
    }),
  ),
});

export type SavedViewport = z.infer<typeof viewportSchema>;
export type SavedNodePositions = z.infer<
  typeof layoutStateSchema
>["projects"][string]["nodePositions"][string];
export type UiLayoutState = z.infer<typeof layoutStateSchema>;

export function decodeUiLayoutState(value: unknown): UiLayoutState {
  return layoutStateSchema.parse(value);
}

export async function loadUiLayout(): Promise<UiLayoutState> {
  if (!("__TAURI_INTERNALS__" in window)) {
    return { version: 1, projects: {} };
  }
  return decodeUiLayoutState(await invoke<unknown>("load_ui_layout"));
}

export async function saveUiViewport(
  projectPath: string,
  viewKey: string,
  viewport: SavedViewport,
): Promise<void> {
  if (!("__TAURI_INTERNALS__" in window)) return;
  viewportSchema.parse(viewport);
  await invoke("save_ui_viewport", { projectPath, viewKey, viewport });
}

export async function saveUiNodePositions(
  projectPath: string,
  viewKey: string,
  positions: SavedNodePositions,
): Promise<void> {
  if (!("__TAURI_INTERNALS__" in window)) return;
  const parsed = z.record(z.string(), positionSchema).parse(positions);
  await invoke("save_ui_node_positions", {
    projectPath,
    viewKey,
    positions: parsed,
  });
}
