import { beforeEach, describe, expect, it, vi } from "vitest";

const eventMock = vi.hoisted(() => ({
  handler: undefined as ((event: { payload: unknown }) => void) | undefined,
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(
    async (_event: string, handler: (event: { payload: unknown }) => void) => {
      eventMock.handler = handler;
      return () => undefined;
    },
  ),
}));

import { listenForSettingsChanges } from "./settings";

const snapshot = {
  settings: { daemonHeartbeatEnabled: false },
  revision: "revision-1",
  exists: true,
  supportDirectory: "C:\\fixture",
  filePath: "C:\\fixture\\settings.json",
  fields: [{ field: "daemonHeartbeatEnabled", timing: "live" }],
};

function emit(kind: "event" | "response", revision: string) {
  eventMock.handler?.({
    payload: {
      version: 2,
      kind,
      ...(kind === "event" ? { sequence: 7 } : {}),
      ...(kind === "response" ? { requestID: "correlated-request" } : {}),
      event: {
        settingsChanged: {
          _0: { ...snapshot, revision },
        },
      },
    },
  });
}

beforeEach(() => {
  eventMock.handler = undefined;
});

describe("settings change subscription", () => {
  it("ignores correlated load and conflict-reload responses", async () => {
    const changed = vi.fn();
    await listenForSettingsChanges(changed);

    emit("response", "load-response");
    emit("response", "conflict-reload-response");

    expect(changed).not.toHaveBeenCalled();
  });

  it("publishes unsolicited settingsChanged events", async () => {
    const changed = vi.fn();
    await listenForSettingsChanges(changed);

    emit("event", "cross-client");

    expect(changed).toHaveBeenCalledWith(
      expect.objectContaining({ revision: "cross-client" }),
    );
  });
});
