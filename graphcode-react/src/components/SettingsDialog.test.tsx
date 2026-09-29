// @vitest-environment jsdom

import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

const settingsBridge = vi.hoisted(() => ({
  load: vi.fn(),
  save: vi.fn(),
  listen: vi.fn(),
}));

vi.mock("../bridge/settings", () => ({
  loadSettings: settingsBridge.load,
  listenForSettingsChanges: settingsBridge.listen,
  updateSettings: settingsBridge.save,
  settingsTiming: (
    snapshot: { fields: { field: string; timing: string }[] },
    field: string,
  ) => snapshot.fields.find((entry) => entry.field === field)?.timing,
  settingsBridgeError: (error: unknown) => {
    if (typeof error === "object" && error && "code" in error) return error;
    return {
      code: "settingsUnavailable",
      message: error instanceof Error ? error.message : String(error),
    };
  },
}));

import {
  editableSettingsFields,
  MAX_RESOLVED_SESSION_GRACE_MINUTES,
  settingsDefaults,
} from "../forms/settingsForm";
import { SettingsDialog } from "./SettingsDialog";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const timings = {
  defaultBackend: "nextLoop",
  defaultModelTier: "nextLoop",
  autoSelectsModel: "nextLoop",
  claudePermissionMode: "nextSession",
  copilotPermissions: "nextSession",
  codexApprovals: "nextSession",
  openCodePermissions: "nextSession",
  piProjectTrust: "nextSession",
  copilotPreferredVersion: "nextSession",
  briefsSessionsAboutTheGraph: "nextSession",
} as const;

const snapshot = {
  supportDirectory: "C:\\Users\\me\\.graphcode",
  filePath: "C:\\Users\\me\\.graphcode\\settings.json",
  revision: "revision-1",
  exists: true,
  settings: { ...settingsDefaults, futureSetting: { enabled: true } },
  fields: editableSettingsFields.map((field) => ({
    field,
    timing: timings[field as keyof typeof timings] ?? "live",
  })),
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  let reject!: (reason: unknown) => void;
  const promise = new Promise<T>((complete, fail) => {
    resolve = complete;
    reject = fail;
  });
  return { promise, resolve, reject };
}

function changedSnapshot(revision: string, changes: Record<string, unknown>) {
  return {
    ...snapshot,
    revision,
    settings: { ...snapshot.settings, ...changes },
  };
}

function fieldControl<T extends HTMLElement>(
  container: HTMLElement,
  field: string,
) {
  return container.querySelector<T>(
    `[data-setting="${field}"] input, [data-setting="${field}"] select`,
  )!;
}

async function renderDialog(onClose = vi.fn()) {
  const container = document.createElement("div");
  document.body.append(container);
  const root = createRoot(container);
  await act(async () => {
    root.render(<SettingsDialog onClose={onClose} />);
  });
  return { container, root, onClose };
}

async function clickSave(container: HTMLElement) {
  const save = Array.from(container.querySelectorAll("button")).find(
    (button) => button.textContent === "Save",
  )!;
  await act(async () => {
    save.click();
  });
}

let roots: Root[] = [];

beforeEach(() => {
  roots = [];
  settingsBridge.load.mockReset();
  settingsBridge.load.mockResolvedValue(snapshot);
  settingsBridge.save.mockReset();
  settingsBridge.listen.mockReset();
  settingsBridge.listen.mockResolvedValue(() => undefined);
  settingsBridge.save.mockResolvedValue(
    changedSnapshot("revision-2", { daemonHeartbeatEnabled: true }),
  );
});

afterEach(async () => {
  await act(async () => {
    for (const root of roots) root.unmount();
  });
  document.body.innerHTML = "";
});

describe("SettingsDialog", () => {
  it("renders the complete contract with timing and capability gating", async () => {
    const rendered = await renderDialog();
    roots.push(rendered.root);

    for (const field of editableSettingsFields) {
      expect(
        rendered.container.querySelector(`[data-setting="${field}"]`),
      ).not.toBeNull();
    }
    expect(
      rendered.container.querySelector(
        '[data-setting="defaultBackend"] .settings-effect',
      )?.textContent,
    ).toBe("New loops");
    expect(
      rendered.container.querySelector(
        '[data-setting="copilotPermissions"] .settings-effect',
      )?.textContent,
    ).toBe("Next session");
    expect(
      fieldControl<HTMLInputElement>(
        rendered.container,
        "keepsMacAwakeWhileLoopsRun",
      ).disabled,
    ).toBe(true);
    expect(rendered.container.textContent).toContain(
      "Existing policies are preserved unchanged.",
    );
  });

  it("sends a complete revisioned update and preserves unknown fields", async () => {
    const rendered = await renderDialog();
    roots.push(rendered.root);
    const heartbeat = fieldControl<HTMLInputElement>(
      rendered.container,
      "daemonHeartbeatEnabled",
    );

    await act(async () => heartbeat.click());
    await clickSave(rendered.container);

    expect(settingsBridge.save).toHaveBeenCalledWith(
      "revision-1",
      expect.objectContaining({
        daemonHeartbeatEnabled: true,
        defaultBackend: "claudeCode",
        futureSetting: { enabled: true },
      }),
    );
  });

  it("validates the grace period and blocks an invalid save", async () => {
    const rendered = await renderDialog();
    roots.push(rendered.root);
    const grace = fieldControl<HTMLInputElement>(
      rendered.container,
      "endsResolvedSessionsAfterMinutes",
    );

    await act(async () => {
      Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )?.set?.call(grace, "-1");
      grace.dispatchEvent(new Event("input", { bubbles: true }));
    });

    expect(grace.getAttribute("aria-invalid")).toBe("true");
    expect(rendered.container.textContent).toContain(
      "Use zero to keep sessions",
    );
    expect(settingsBridge.save).not.toHaveBeenCalled();
    expect(grace.max).toBe(String(MAX_RESOLVED_SESSION_GRACE_MINUTES));
  });

  it("disables every custom control descendant when capabilities are omitted", async () => {
    settingsBridge.load.mockResolvedValueOnce({
      ...snapshot,
      settings: {
        ...snapshot.settings,
        copilotPreferredVersion: "1.2.3",
      },
      fields: snapshot.fields.filter(
        ({ field }) =>
          field !== "copilotPreferredVersion" &&
          field !== "endsResolvedSessionsAfterMinutes",
      ),
    });
    const rendered = await renderDialog();
    roots.push(rendered.root);

    for (const field of [
      "copilotPreferredVersion",
      "endsResolvedSessionsAfterMinutes",
    ]) {
      const frame = rendered.container.querySelector(
        `[data-setting="${field}"]`,
      )!;
      const descendants = [
        ...frame.querySelectorAll<HTMLElement>("input, select, button"),
      ];
      expect(descendants.length).toBeGreaterThan(0);
      expect(descendants.every((element) => element.matches(":disabled"))).toBe(
        true,
      );
    }
    expect(
      rendered.container.querySelector<HTMLInputElement>(
        "#settings-copilot-version-value",
      ),
    ).not.toBeNull();
  });

  it("installs the listener before loading and retries after listener failure", async () => {
    const order: string[] = [];
    settingsBridge.listen
      .mockImplementationOnce(async () => {
        order.push("listen");
        throw new Error("listener unavailable");
      })
      .mockImplementationOnce(async () => () => undefined);
    settingsBridge.load.mockImplementation(async () => {
      order.push("load");
      return snapshot;
    });
    const rendered = await renderDialog();
    roots.push(rendered.root);

    expect(order).toEqual(["listen", "load"]);
    expect(rendered.container.textContent).toContain(
      "Settings refresh subscription failed: listener unavailable",
    );
    const reload = Array.from(
      rendered.container.querySelectorAll("button"),
    ).find((button) => button.textContent === "Reload")!;
    await act(async () => reload.click());
    expect(settingsBridge.listen).toHaveBeenCalledTimes(2);
    expect(settingsBridge.load).toHaveBeenCalledTimes(2);
  });

  it("surfaces a corrupt file without replacing it", async () => {
    settingsBridge.load.mockRejectedValueOnce({
      code: "settingsCorrupt",
      message: "settings.json is corrupt",
    });
    const rendered = await renderDialog();
    roots.push(rendered.root);

    expect(rendered.container.textContent).toContain(
      "settings.json is corrupt",
    );
    expect(rendered.container.textContent).toContain(
      "GraphCode did not replace the file. Repair or restore it, then reload.",
    );
    expect(settingsBridge.save).not.toHaveBeenCalled();
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
    const rendered = await renderDialog();
    roots.push(rendered.root);

    await act(async () => {
      publish(
        changedSnapshot("event-revision", {
          daemonHeartbeatEnabled: true,
        }),
      );
      pendingLoad.resolve(snapshot);
      await pendingLoad.promise;
    });

    expect(
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).checked,
    ).toBe(true);
  });

  it("rebases dirty fields over cross-client refreshes", async () => {
    let publish!: (value: typeof snapshot) => void;
    settingsBridge.listen.mockImplementation(
      async (listener: (value: typeof snapshot) => void) => {
        publish = listener;
        return () => undefined;
      },
    );
    const rendered = await renderDialog();
    roots.push(rendered.root);
    await act(async () =>
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).click(),
    );

    await act(async () => {
      publish(
        changedSnapshot("event-revision", {
          mailroomEnabled: false,
          futureSetting: { enabled: false },
        }),
      );
    });

    expect(rendered.container.textContent).toContain(
      "Your edits were reapplied",
    );
    expect(
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).checked,
    ).toBe(true);
    expect(
      fieldControl<HTMLInputElement>(rendered.container, "mailroomEnabled")
        .checked,
    ).toBe(false);

    await clickSave(rendered.container);
    expect(settingsBridge.save).toHaveBeenLastCalledWith(
      "event-revision",
      expect.objectContaining({
        daemonHeartbeatEnabled: true,
        mailroomEnabled: false,
        futureSetting: { enabled: false },
      }),
    );
  });

  it("reloads and reapplies edits after a revision conflict", async () => {
    const latest = changedSnapshot("revision-latest", {
      mailroomEnabled: false,
    });
    settingsBridge.load
      .mockResolvedValueOnce(snapshot)
      .mockResolvedValueOnce(latest);
    settingsBridge.save.mockRejectedValueOnce({
      code: "settingsConflict",
      message: "reload",
    });
    const rendered = await renderDialog();
    roots.push(rendered.root);
    await act(async () =>
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).click(),
    );

    await clickSave(rendered.container);

    expect(settingsBridge.load).toHaveBeenCalledTimes(2);
    expect(rendered.container.textContent).toContain(
      "revision changed before your save",
    );
    expect(
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).checked,
    ).toBe(true);
    expect(
      fieldControl<HTMLInputElement>(rendered.container, "mailroomEnabled")
        .checked,
    ).toBe(false);
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
    const rendered = await renderDialog();
    roots.push(rendered.root);
    await act(async () =>
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).click(),
    );
    await clickSave(rendered.container);

    await act(async () => {
      publish(
        changedSnapshot("event-revision", {
          daemonHeartbeatEnabled: false,
        }),
      );
      pendingSave.resolve(
        changedSnapshot("save-revision", {
          daemonHeartbeatEnabled: true,
        }),
      );
      await pendingSave.promise;
    });

    expect(
      fieldControl<HTMLInputElement>(
        rendered.container,
        "daemonHeartbeatEnabled",
      ).checked,
    ).toBe(true);
    expect(rendered.container.textContent).toContain(
      "Your edits were reapplied",
    );
  });

  it("focuses the first field, traps focus, and closes on Escape", async () => {
    const rendered = await renderDialog();
    roots.push(rendered.root);
    expect(document.activeElement).toBe(
      fieldControl(rendered.container, "defaultBackend"),
    );

    await act(async () => {
      document.activeElement?.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
      );
    });
    expect(rendered.onClose).toHaveBeenCalledTimes(1);
  });
});
