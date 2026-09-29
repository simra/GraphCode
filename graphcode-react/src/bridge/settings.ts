import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { decodeEnvelope } from "../protocol/decode";
import type {
  SettingsApplicationTiming,
  SettingsSnapshot as DaemonSettingsSnapshot,
} from "../protocol/domain";

export interface SettingsSnapshot extends DaemonSettingsSnapshot {
  daemonHeartbeatEnabled: boolean;
}

export function loadSettings(): Promise<SettingsSnapshot> {
  return invoke("load_settings");
}

export function setDaemonHeartbeatEnabled(
  expectedRevision: string,
  settings: Record<string, unknown>,
  enabled: boolean,
): Promise<SettingsSnapshot> {
  return invoke("set_daemon_heartbeat_enabled", {
    expectedRevision,
    settings,
    enabled,
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
        daemonHeartbeatEnabled:
          envelope.event.snapshot.settings.daemonHeartbeatEnabled,
      });
    }
  });
}
