import { describe, expect, it } from "vitest";
import { decodeUiLayoutState } from "./uiLayout";

describe("UI layout persistence", () => {
  it("accepts the versioned per-project viewport shape", () => {
    expect(
      decodeUiLayoutState({
        version: 1,
        projects: {
          "C:\\work\\graph": {
            views: {
              root: { x: 10, y: 20, width: 900, height: 420 },
            },
            nodePositions: {
              root: { "node-a": { x: 120, y: 80 } },
            },
          },
        },
      }).projects["C:\\work\\graph"].views.root.width,
    ).toBe(900);
    expect(
      decodeUiLayoutState({
        version: 1,
        projects: {
          "C:\\work\\graph": {
            views: {},
            nodePositions: { root: { "node-a": { x: 120, y: 80 } } },
          },
        },
      }).projects["C:\\work\\graph"].nodePositions.root["node-a"].x,
    ).toBe(120);
  });

  it("loads version-1 viewport files written before node positioning", () => {
    expect(
      decodeUiLayoutState({
        version: 1,
        projects: { project: { views: {} } },
      }).projects.project.nodePositions,
    ).toEqual({});
  });

  it("rejects unsupported versions and invalid dimensions", () => {
    expect(() => decodeUiLayoutState({ version: 2, projects: {} })).toThrow();
    expect(() =>
      decodeUiLayoutState({
        version: 1,
        projects: {
          project: {
            views: {
              root: { x: 0, y: 0, width: 0, height: 420 },
            },
          },
        },
      }),
    ).toThrow();
  });
});
