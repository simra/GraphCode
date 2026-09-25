import { invoke } from "@tauri-apps/api/core";
import { listen, type UnlistenFn } from "@tauri-apps/api/event";
import { decodeEnvelope } from "../protocol/decode";
import type { DaemonWireEnvelope } from "../protocol/domain";

export interface DaemonConnectionStatus {
  phase: "connecting" | "connected" | "reconnecting" | "resyncing";
  endpoint: string;
  attempt: number;
  message?: string;
  resumeFrom?: number;
}

export interface DaemonConnectionInfo {
  endpoint: string;
  clientId: string;
  resumeFrom?: number;
}

export interface DaemonConnectionHandlers {
  onEnvelope(envelope: DaemonWireEnvelope): void;
  onStatus(status: DaemonConnectionStatus): void;
  onError(error: Error): void;
}

export interface DaemonConnection {
  info: DaemonConnectionInfo;
  dispose(): Promise<void>;
}

export async function startDaemonConnection(
  handlers: DaemonConnectionHandlers,
): Promise<DaemonConnection> {
  const unlisteners: UnlistenFn[] = [];
  unlisteners.push(
    await listen<unknown>("daemon://frame", ({ payload }) => {
      try {
        const envelope = decodeEnvelope(payload);
        handlers.onEnvelope(envelope);
        if (envelope.kind === "event") {
          void acknowledgeDaemonSequence(envelope.sequence).catch((error) =>
            handlers.onError(asError(error)),
          );
        }
      } catch (error) {
        handlers.onError(asError(error));
      }
    }),
  );
  unlisteners.push(
    await listen<DaemonConnectionStatus>("daemon://status", ({ payload }) =>
      handlers.onStatus(payload),
    ),
  );

  try {
    const info = await invoke<DaemonConnectionInfo>("start_daemon_connection");
    return {
      info,
      async dispose() {
        for (const unlisten of unlisteners) {
          unlisten();
        }
      },
    };
  } catch (error) {
    for (const unlisten of unlisteners) {
      unlisten();
    }
    throw asError(error);
  }
}

export async function sendDaemonCommand(
  command: object,
): Promise<DaemonWireEnvelope> {
  const raw = await invoke<unknown>("send_daemon_command", { command });
  const envelope = decodeEnvelope(raw);
  if (envelope.kind === "error") {
    throw new Error(`${envelope.error.code}: ${envelope.error.message}`);
  }
  return envelope;
}

export async function acknowledgeDaemonSequence(
  sequence: number,
): Promise<void> {
  await invoke("acknowledge_daemon_sequence", { sequence });
}

function asError(value: unknown): Error {
  return value instanceof Error ? value : new Error(String(value));
}
