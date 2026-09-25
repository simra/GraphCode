import { open } from "@tauri-apps/plugin-dialog";

export async function pickProjectFolder(): Promise<string | undefined> {
  const selected = await open({
    directory: true,
    multiple: false,
    title: "Open GraphCode Project",
  });
  return typeof selected === "string" ? selected : undefined;
}
