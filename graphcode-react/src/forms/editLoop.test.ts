import { describe, expect, it } from "vitest";
import type { LoopNode } from "../protocol/domain";
import {
  buildNodeUpdate,
  editLoopInitialState,
  validateEditLoop,
} from "./editLoop";

const goalNode: LoopNode = {
  id: "node",
  title: "Goal",
  loopType: "goalBased",
  state: "running",
  modelTier: "standard",
  goal: {
    summary: "Ship",
    predicate: "test -f done",
    pollIntervalSeconds: 60,
    stallAfterSeconds: 600,
    metricCommand: "score",
    metricDirection: "maximize",
    tokenBudget: 1000,
    skipsUnchangedWorkspace: false,
  },
};

describe("loop editing", () => {
  it("builds only changed NodeUpdate fields and uses zero to clear bounds", () => {
    const form = editLoopInitialState(goalNode);
    form.goalPredicate = "";
    form.stallAfterSeconds = "";
    form.tokenBudget = "2000";
    form.skipsUnchangedWorkspace = true;

    expect(buildNodeUpdate(goalNode, form)).toEqual({
      goalPredicate: "",
      stallAfterSeconds: 0,
      tokenBudget: 2000,
      skipsUnchangedWorkspace: true,
      updatedBy: null,
    });
  });

  it("rejects empty updates and invalid goal fields", () => {
    expect(() =>
      buildNodeUpdate(goalNode, editLoopInitialState(goalNode)),
    ).toThrow("Change at least one");
    const form = editLoopInitialState(goalNode);
    form.goalSummary = "";
    form.pollIntervalSeconds = "0";
    expect(validateEditLoop(goalNode, form)).toMatchObject({
      goalSummary: expect.any(String),
      pollIntervalSeconds: expect.any(String),
    });
  });
});
