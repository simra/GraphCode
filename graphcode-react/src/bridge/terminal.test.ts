import { beforeEach, describe, expect, it, vi } from "vitest";

const invokeMock = vi.hoisted(() => vi.fn());

vi.mock("@tauri-apps/api/core", () => ({
  Channel: class {
    onmessage?: (message: unknown) => void;
  },
  invoke: invokeMock,
}));

import { decodeBase64, encodeTerminalInput, openTerminal } from "./terminal";

beforeEach(() => {
  invokeMock.mockReset();
});

describe("terminal bridge encoding", () => {
  it("round-trips Unicode input without treating bytes as JSON numbers", () => {
    const encoded = encodeTerminalInput("hello λ 👋\r");
    expect(new TextDecoder().decode(decodeBase64(encoded))).toBe(
      "hello λ 👋\r",
    );
  });

  it("decodes raw VT bytes", () => {
    expect(Array.from(decodeBase64("G1sySg=="))).toEqual([27, 91, 50, 74]);
  });

  it("acknowledges output delivered before open returns", async () => {
    invokeMock.mockImplementation(
      async (command: string, arguments_: Record<string, unknown>) => {
        if (command === "open_terminal") {
          const channel = arguments_.onEvent as {
            onmessage(message: unknown): void;
          };
          channel.onmessage({
            kind: "output",
            sequence: 7,
            byteLength: 3,
            data: "YWJj",
          });
          return { handle: "terminal-1", sessionName: "graphcode-LOOP" };
        }
        return undefined;
      },
    );

    const connection = await openTerminal(
      { kind: "node", nodeId: "loop" },
      80,
      24,
      {
        onOutput(bytes, _sequence, acknowledge) {
          expect(new TextDecoder().decode(bytes)).toBe("abc");
          void acknowledge();
        },
        onError: vi.fn(),
        onExit: vi.fn(),
      },
    );

    expect(connection.handle).toBe("terminal-1");
    expect(invokeMock).toHaveBeenCalledWith(
      "open_terminal",
      expect.objectContaining({
        target: { kind: "node", nodeId: "loop" },
        columns: 80,
        rows: 24,
      }),
    );
    expect(invokeMock).toHaveBeenCalledWith("acknowledge_terminal_output", {
      handle: "terminal-1",
      sequence: 7,
    });
  });
});
