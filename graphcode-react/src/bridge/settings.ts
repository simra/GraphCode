import { invoke } from "@tauri-apps/api/core";

export interface SettingsSnapshot {
  supportDirectory: string;
  filePath: string;
  revision: string;
  exists: boolean;
  daemonHeartbeatEnabled: boolean;
}

export function loadSettings(): Promise<SettingsSnapshot> {
  return invoke("load_settings");
}

export function setDaemonHeartbeatEnabled(
  expectedRevision: string,
  enabled: boolean,
): Promise<SettingsSnapshot> {
  return invoke("set_daemon_heartbeat_enabled", {
    expectedRevision,
    enabled,
  });
}
