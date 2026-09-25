import { describe, expect, it } from "vitest";
import {
  deriveProjectNavigation,
  globalProjectPath,
} from "./projectNavigation";

describe("project navigation", () => {
  it("separates global, open and unopened recent projects", () => {
    const navigation = deriveProjectNavigation(
      [
        { path: "C:\\open", name: "Open", lastOpenedAt: 1 },
        { path: "C:\\recent-old", name: "Old", lastOpenedAt: 2 },
        { path: "C:\\recent-new", name: "New", lastOpenedAt: 3 },
      ],
      {
        [globalProjectPath]: {
          id: "global",
          project: { path: globalProjectPath, name: "Overview" },
          nodes: [],
          edges: [],
        },
        "C:\\OPEN": {
          id: "open",
          project: { path: "C:\\OPEN", name: "Open" },
          nodes: [],
          edges: [],
        },
      },
    );

    expect(navigation.global?.name).toBe("Overview");
    expect(navigation.open.map((project) => project.name)).toEqual(["Open"]);
    expect(navigation.recent.map((project) => project.name)).toEqual([
      "New",
      "Old",
    ]);
  });
});
