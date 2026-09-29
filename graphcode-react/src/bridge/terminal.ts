import { Channel, invoke } from "@tauri-apps/api/core";

export interface TerminalOutputEvent {
  kind: "output";
  sequence: number;
  byteLength: number;
  data: string;
}

export interface TerminalErrorEvent {
  kind: "error";
  message: string;
}

export interface TerminalExitEvent {
  kind: "exit";
  code: number | null;
}

export type TerminalEvent =
  TerminalOutputEvent | TerminalErrorEvent | TerminalExitEvent;

export interface TerminalHistory {
  byteLength: number;
  truncated: boolean;
  data: string;
}

export interface TerminalConnection {
  handle: string;
  sessionName: string;
  write(data: string): Promise<void>;
  resize(columns: number, rows: number): Promise<void>;
  acknowledge(sequence: number): Promise<void>;
  close(): Promise<void>;
}

export interface TerminalHandlers {
  onOutput(
    bytes: Uint8Array,
    sequence: number,
    acknowledge: () => Promise<void>,
  ): void;
  onError(error: Error): void;
  onExit(code: number | null): void;
}

interface TerminalOpenResult {
  handle: string;
  sessionName: string;
}

export type TerminalTarget =
  | { kind: "node"; nodeId: string }
  | { kind: "shell"; surfaceId: string; workingDirectory?: string };

export function decodeBase64(data: string): Uint8Array {
  const binary = globalThis.atob(data);
  return Uint8Array.from(binary, (character) => character.charCodeAt(0));
}

export function encodeTerminalInput(data: string): string {
  const bytes = new TextEncoder().encode(data);
  let binary = "";
  for (let offset = 0; offset < bytes.length; offset += 0x8000) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + 0x8000));
  }
  return globalThis.btoa(binary);
}

export async function loadTerminalHistory(
  nodeId: string,
  maxBytes = 1024 * 1024,
): Promise<{ bytes: Uint8Array; truncated: boolean }> {
  const history = await invoke<TerminalHistory>("load_terminal_history", {
    nodeId,
    maxBytes,
  });
  return {
    bytes: decodeBase64(history.data),
    truncated: history.truncated,
  };
}

export async function openTerminal(
  target: TerminalTarget,
  columns: number,
  rows: number,
  handlers: TerminalHandlers,
): Promise<TerminalConnection> {
  const onEvent = new Channel<TerminalEvent>();
  let handle: string | undefined;
  const pendingAcknowledgements: number[] = [];

  const acknowledge = async (sequence: number) => {
    if (!handle) {
      pendingAcknowledgements.push(sequence);
      return;
    }
    await invoke("acknowledge_terminal_output", { handle, sequence });
  };

  onEvent.onmessage = (event) => {
    switch (event.kind) {
      case "output":
        handlers.onOutput(decodeBase64(event.data), event.sequence, () =>
          acknowledge(event.sequence),
        );
        break;
      case "error":
        handlers.onError(new Error(event.message));
        break;
      case "exit":
        handlers.onExit(event.code);
        break;
    }
  };

  const opened = await invoke<TerminalOpenResult>("open_terminal", {
    target,
    columns,
    rows,
    onEvent,
  });
  handle = opened.handle;
  for (const sequence of pendingAcknowledgements.splice(0)) {
    await acknowledge(sequence);
  }

  return {
    handle,
    sessionName: opened.sessionName,
    async write(data) {
      await invoke("write_terminal", {
        handle,
        data: encodeTerminalInput(data),
      });
    },
    async resize(nextColumns, nextRows) {
      await invoke("resize_terminal", {
        handle,
        columns: nextColumns,
        rows: nextRows,
      });
    },
    acknowledge,
    async close() {
      await invoke("close_terminal", { handle });
    },
  };
}

export async function killTerminalSession(surfaceId: string): Promise<void> {
  await invoke("kill_terminal_session", { surfaceId });
}
