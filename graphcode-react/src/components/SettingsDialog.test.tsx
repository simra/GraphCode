// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const settingsBridge = vi.hoisted(() => ({
  load: vi.fn(),
  save: vi.fn(),
}));

vi.mock("../bridge/settings", () => ({
  loadSettings: settingsBridge.load,
  setDaemonHeartbeatEnabled: settingsBridge.save,
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
  daemonHeartbeatEnabled: false,
};

beforeEach(() => {
  settingsBridge.load.mockReset();
  settingsBridge.load.mockResolvedValue(snapshot);
  settingsBridge.save.mockReset();
  settingsBridge.save.mockResolvedValue({
    ...snapshot,
    revision: "revision-2",
    daemonHeartbeatEnabled: true,
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

    expect(settingsBridge.save).toHaveBeenCalledWith("revision-1", true);
    expect(container.textContent).toContain("without a daemon restart");
  });
});
