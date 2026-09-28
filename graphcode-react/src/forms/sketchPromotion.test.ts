import { describe, expect, it } from "vitest";
import {
  buildSketchPromotion,
  initialSketchPromotionForm,
  promotionTargetForNode,
  sketchPromotionInitialState,
  validateSketchPromotion,
} from "./sketchPromotion";

describe("sketch promotion form", () => {
  it("requires a goal summary and emits the complete GoalSpec defaults", () => {
    expect(
      validateSketchPromotion({
        ...initialSketchPromotionForm,
        target: "goalBased",
      }),
    ).toHaveProperty("goalSummary");

    expect(
      buildSketchPromotion({
        ...initialSketchPromotionForm,
        target: "goalBased",
        goalSummary: "  Tests pass  ",
      }),
    ).toEqual({
      goal: {
        _0: {
          summary: "Tests pass",
          predicate: null,
          pollIntervalSeconds: 60,
          stallAfterSeconds: null,
          metricCommand: null,
          metricDirection: "maximize",
          tokenBudget: null,
          skipsUnchangedWorkspace: false,
        },
      },
    });
  });

  it("emits turn and timed promotions without re-briefing the sketch", () => {
    expect(
      buildSketchPromotion({
        ...initialSketchPromotionForm,
        target: "turnBased",
        pausesBeforeWritesOnly: true,
      }),
    ).toEqual({ turn: { pausesBeforeWritesOnly: true } });

    expect(
      buildSketchPromotion({
        ...initialSketchPromotionForm,
        target: "timeBased",
        cadence: "30m",
        timedTask: "Watch the build",
      }),
    ).toEqual({
      timed: { triggerPrompt: "/loop 30m Watch the build" },
    });
    expect(
      buildSketchPromotion({
        ...initialSketchPromotionForm,
        target: "timeBased",
        cadence: "1h",
      }),
    ).toEqual({
      timed: {
        triggerPrompt:
          "/loop 1h Carry on with what this session has been doing.",
      },
    });
  });

  it("rejects malformed timed cadences", () => {
    expect(
      validateSketchPromotion({
        ...initialSketchPromotionForm,
        target: "timeBased",
        cadence: "whenever",
      }),
    ).toHaveProperty("cadence");
  });

  it("offers only the opposite unattended type for live goal and timed loops", () => {
    expect(
      promotionTargetForNode({
        loopType: "goalBased",
        state: { running: {} },
      }),
    ).toBe("timeBased");
    expect(
      promotionTargetForNode({
        loopType: "timeBased",
        state: { idle: {} },
      }),
    ).toBe("goalBased");
    expect(
      promotionTargetForNode({
        loopType: "goalBased",
        state: { stopped: {} },
      }),
    ).toBeUndefined();

    expect(
      sketchPromotionInitialState({
        loopType: "goalBased",
        state: { running: {} },
      }),
    ).toMatchObject({ target: "timeBased", timedTask: "" });

    expect(
      buildSketchPromotion({
        ...sketchPromotionInitialState({
          loopType: "goalBased",
          state: { running: {} },
        }),
        cadence: "2h",
        timedTask: "Check that CI remains green",
      }),
    ).toEqual({
      timed: {
        triggerPrompt: "/loop 2h Check that CI remains green",
      },
    });
  });
});
