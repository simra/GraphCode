import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { decodeEnvelope } from "../protocol/decode";
import type {
  SettingsApplicationTiming,
  SettingsSnapshot as DaemonSettingsSnapshot,
} from "../protocol/domain";

export type SettingsSnapshot = DaemonSettingsSnapshot;

export function loadSettings(): Promise<SettingsSnapshot> {
  return invoke("load_settings");
}

export function updateSettings(
  expectedRevision: string,
  settings: Record<string, unknown>,
): Promise<SettingsSnapshot> {
  return invoke("update_settings", {
    expectedRevision,
    settings,
  });
}

export function settingsTiming(
  snapshot: SettingsSnapshot,
  field: string,
): SettingsApplicationTiming | undefined {
  return snapshot.fields.find((entry) => entry.field === field)?.timing;
}

export async function listenForSettingsChanges(
  onChange: (snapshot: SettingsSnapshot) => void,
): Promise<UnlistenFn> {
  return listen<unknown>("daemon://frame", ({ payload }) => {
    const envelope = decodeEnvelope(payload);
    if (
      (envelope.kind === "event" || envelope.kind === "response") &&
      envelope.event?.type === "settingsChanged"
    ) {
      onChange({
        ...envelope.event.snapshot,
      });
    }
  });
}

export interface SettingsBridgeError {
  code: string;
  message: string;
}

export function settingsBridgeError(error: unknown): SettingsBridgeError {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    "message" in error &&
    typeof error.code === "string" &&
    typeof error.message === "string"
  ) {
    return { code: error.code, message: error.message };
  }
  return {
    code: "settingsUnavailable",
    message: error instanceof Error ? error.message : String(error),
  };
}
