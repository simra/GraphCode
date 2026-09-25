import { invoke } from "@tauri-apps/api/core";
import { decodeEnvelope } from "../protocol/decode";
import type { DaemonWireEnvelope } from "../protocol/domain";

interface InitialDaemonState {
  endpoint: string;
  frames: unknown[];
}

export interface DecodedInitialDaemonState {
  endpoint: string;
  frames: DaemonWireEnvelope[];
}

export async function connectInitialDaemonState(): Promise<DecodedInitialDaemonState> {
  const result = await invoke<InitialDaemonState>(
    "connect_initial_daemon_state",
  );
  return {
    endpoint: result.endpoint,
    frames: result.frames.map(decodeEnvelope),
  };
}
