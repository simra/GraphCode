import { beforeEach, describe, expect, it, vi } from "vitest";

const eventMock = vi.hoisted(() => ({
  handlers: new Map<string, (event: { payload: unknown }) => void>(),
}));

vi.mock("@tauri-apps/api/event", () => ({
  listen: vi.fn(
    async (event: string, handler: (event: { payload: unknown }) => void) => {
      eventMock.handlers.set(event, handler);
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

function emit(
  channel: "daemon://frame" | "settings://changed",
  kind: "event" | "response",
  revision: string,
) {
  eventMock.handlers.get(channel)?.({
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
  eventMock.handlers.clear();
});

describe("settings change subscription", () => {
  it("ignores correlated load and conflict-reload responses on the daemon frame channel", async () => {
    const changed = vi.fn();
    await listenForSettingsChanges(changed);

    emit("daemon://frame", "response", "load-response");
    emit("daemon://frame", "response", "conflict-reload-response");

    expect(changed).not.toHaveBeenCalled();
  });

  it("publishes reconnect bootstrap responses and unsolicited events routed with settings provenance", async () => {
    const changed = vi.fn();
    await listenForSettingsChanges(changed);

    emit("settings://changed", "response", "reconnect-bootstrap");
    emit("settings://changed", "event", "cross-client");

    expect(changed.mock.calls.map(([value]) => value.revision)).toEqual([
      "reconnect-bootstrap",
      "cross-client",
    ]);
  });
});
