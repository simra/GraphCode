import { describe, expect, it } from "vitest";
import type { LoopNode } from "../protocol/domain";
import {
  buildNodeUpdate,
  editLoopInitialState,
  parseSessionSchedule,
  timedSchedule,
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

  it("describes daemon and session-managed timed schedules", () => {
    expect(
      timedSchedule({
        id: "timed",
        title: "Weather",
        loopType: "timeBased",
        state: "idle",
        triggerPrompt: "Check the weather",
        heartbeatIntervalSeconds: 900,
      }),
    ).toEqual({
      scheduler: "daemon",
      cadence: "15 minutes",
      task: "Check the weather",
    });
    expect(parseSessionSchedule("/every 1h Check the weather")).toEqual({
      cadence: "1h",
      task: "Check the weather",
    });
  });

  it("requires one scheduling mechanism for timed loops", () => {
    const timedNode: LoopNode = {
      id: "timed",
      title: "Weather",
      loopType: "timeBased",
      state: "idle",
      triggerPrompt: "Check the weather",
    };
    expect(
      validateEditLoop(timedNode, editLoopInitialState(timedNode)),
    ).toMatchObject({
      heartbeatIntervalSeconds: expect.stringContaining("heartbeat"),
    });
  });
});
