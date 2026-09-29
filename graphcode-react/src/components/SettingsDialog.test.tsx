// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const settingsBridge = vi.hoisted(() => ({
  load: vi.fn(),
  save: vi.fn(),
  listen: vi.fn(),
}));

vi.mock("../bridge/settings", () => ({
  loadSettings: settingsBridge.load,
  listenForSettingsChanges: settingsBridge.listen,
  setDaemonHeartbeatEnabled: settingsBridge.save,
  settingsTiming: () => "live",
}));

import { SettingsDialog } from "./SettingsDialog";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const snapshot = {
  supportDirectory: "C:\\Users\\me\\.graphcode",
  filePath: "C:\\Users\\me\\.graphcode\\settings.json",
  revision: "revision-1",
  exists: true,
  settings: { daemonHeartbeatEnabled: false },
  fields: [{ field: "daemonHeartbeatEnabled", timing: "live" }],
  daemonHeartbeatEnabled: false,
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

function changedSnapshot(revision: string, enabled: boolean) {
  return {
    ...snapshot,
    revision,
    daemonHeartbeatEnabled: enabled,
    settings: { daemonHeartbeatEnabled: enabled },
  };
}

beforeEach(() => {
  settingsBridge.load.mockReset();
  settingsBridge.load.mockResolvedValue(snapshot);
  settingsBridge.save.mockReset();
  settingsBridge.listen.mockReset();
  settingsBridge.listen.mockResolvedValue(() => undefined);
  settingsBridge.save.mockResolvedValue({
    ...snapshot,
    revision: "revision-2",
    daemonHeartbeatEnabled: true,
    settings: { daemonHeartbeatEnabled: true },
  });
});

afterEach(() => {
  document.body.innerHTML = "";
});

describe("SettingsDialog", () => {
  it("saves heartbeat changes against the loaded revision", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<SettingsDialog onClose={() => undefined} />);
    });

    const checkbox = container.querySelector<HTMLInputElement>(
      'input[type="checkbox"]',
    )!;
    await act(async () => {
      checkbox.click();
    });
    const save = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent === "Save",
    )!;
    await act(async () => {
      save.click();
    });

    expect(settingsBridge.save).toHaveBeenCalledWith(
      "revision-1",
      snapshot.settings,
      true,
    );
    expect(container.textContent).toContain("without a daemon restart");
  });

  it("installs the listener before starting the initial load", async () => {
    const order: string[] = [];
    settingsBridge.listen.mockImplementation(async () => {
      order.push("listen");
      return () => undefined;
    });
    settingsBridge.load.mockImplementation(async () => {
      order.push("load");
      return snapshot;
    });
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<SettingsDialog onClose={() => undefined} />);
    });

    expect(order).toEqual(["listen", "load"]);
  });

  it("does not let a delayed load overwrite a newer settings event", async () => {
    const pendingLoad = deferred<typeof snapshot>();
    let publish!: (value: typeof snapshot) => void;
    settingsBridge.load.mockReturnValue(pendingLoad.promise);
    settingsBridge.listen.mockImplementation(
      async (listener: (value: typeof snapshot) => void) => {
        publish = listener;
        return () => undefined;
      },
    );
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);

    await act(async () => {
      root.render(<SettingsDialog onClose={() => undefined} />);
    });
    await act(async () => {
      publish(changedSnapshot("event-revision", true));
      pendingLoad.resolve(snapshot);
      await pendingLoad.promise;
    });

    const checkbox = container.querySelector<HTMLInputElement>(
      'input[type="checkbox"]',
    )!;
    expect(checkbox.checked).toBe(true);
    expect(container.textContent).toContain("settings.json");
  });

  it("does not let a delayed save overwrite a newer settings event", async () => {
    const pendingSave = deferred<typeof snapshot>();
    let publish!: (value: typeof snapshot) => void;
    settingsBridge.save.mockReturnValue(pendingSave.promise);
    settingsBridge.listen.mockImplementation(
      async (listener: (value: typeof snapshot) => void) => {
        publish = listener;
        return () => undefined;
      },
    );
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    await act(async () => {
      root.render(<SettingsDialog onClose={() => undefined} />);
    });
    const checkbox = container.querySelector<HTMLInputElement>(
      'input[type="checkbox"]',
    )!;
    await act(async () => checkbox.click());
    const save = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent === "Save",
    )!;
    await act(async () => save.click());

    await act(async () => {
      publish(changedSnapshot("event-revision", false));
      pendingSave.resolve(changedSnapshot("save-revision", true));
      await pendingSave.promise;
    });

    expect(checkbox.checked).toBe(false);
  });
});
