import { describe, expect, it } from "vitest";
import type { ProjectRef } from "../protocol/domain";
import {
  projectCapabilityDisabledReason,
  projectSupports,
} from "./projectCapabilities";

const path = "C:\\identical\\project";
const capabilities = {
  revealInFileManager: true,
  templates: true,
  attachments: true,
  interactiveTerminals: true,
  diagnostics: true,
};

function project(
  location: "local" | "ssh" | "codespace",
  overrides: Partial<typeof capabilities> = {},
): ProjectRef {
  return {
    path,
    name: "Identical",
    metadata: {
      location,
      capabilities: { ...capabilities, ...overrides },
    },
  };
}

describe("project capabilities", () => {
  it("uses authoritative metadata rather than identical-looking paths", () => {
    const local = project("local");
    const ssh = project("ssh", {
      revealInFileManager: false,
      templates: false,
      attachments: false,
      interactiveTerminals: false,
    });
    const codespace = project("codespace", {
      revealInFileManager: false,
      templates: false,
      attachments: false,
      interactiveTerminals: false,
    });

    expect(projectSupports(local, "interactiveTerminals")).toBe(true);
    expect(projectSupports(ssh, "interactiveTerminals")).toBe(false);
    expect(projectSupports(codespace, "interactiveTerminals")).toBe(false);
    expect(projectCapabilityDisabledReason(codespace, "attachments")).toContain(
      "Codespace projects",
    );
  });

  it("fails closed when legacy references omit metadata", () => {
    const legacy = { path, name: "Legacy" };
    for (const capability of Object.keys(
      capabilities,
    ) as (keyof typeof capabilities)[]) {
      expect(projectSupports(legacy, capability)).toBe(false);
      expect(projectCapabilityDisabledReason(legacy, capability)).toContain(
        "did not advertise",
      );
    }
  });

  it("preserves implemented global graph session operations", () => {
    const global = { path: "graphcode://global", name: "Global" };

    expect(projectSupports(global, "interactiveTerminals")).toBe(true);
    expect(projectSupports(global, "diagnostics")).toBe(true);
    expect(projectSupports(global, "revealInFileManager")).toBe(false);
    expect(projectSupports(global, "templates")).toBe(false);
    expect(projectSupports(global, "attachments")).toBe(false);
  });
});
