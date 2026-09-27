import type { GoalDraft, SketchPromotionPayload } from "../protocol/commands";

export type PromotionTarget = "goalBased" | "turnBased" | "timeBased";

export interface SketchPromotionFormState {
  target: PromotionTarget;
  goalSummary: string;
  pausesBeforeWritesOnly: boolean;
  cadence: string;
}

export type SketchPromotionErrors = Partial<
  Record<keyof SketchPromotionFormState, string>
>;

export const initialSketchPromotionForm: SketchPromotionFormState = {
  target: "goalBased",
  goalSummary: "",
  pausesBeforeWritesOnly: false,
  cadence: "1h",
};

export function validateSketchPromotion(
  form: SketchPromotionFormState,
): SketchPromotionErrors {
  const errors: SketchPromotionErrors = {};
  if (form.target === "goalBased" && !form.goalSummary.trim()) {
    errors.goalSummary = "Describe what done means.";
  }
  if (form.target === "timeBased") {
    const cadence = form.cadence.trim().toLocaleLowerCase();
    const match = cadence.match(/^(\d+(?:\.\d+)?)([smhd]?)$/);
    if (!match || Number(match[1]) <= 0) {
      errors.cadence = "Use a positive interval such as 30m, 2h, or 3d.";
    }
  }
  return errors;
}

export function buildSketchPromotion(
  form: SketchPromotionFormState,
  node: { firstInstruction?: string },
): SketchPromotionPayload {
  if (Object.keys(validateSketchPromotion(form)).length) {
    throw new Error("Cannot build an invalid sketch promotion.");
  }
  if (form.target === "goalBased") {
    const goal: GoalDraft = {
      summary: form.goalSummary.trim(),
      predicate: null,
      pollIntervalSeconds: 60,
      stallAfterSeconds: null,
      metricCommand: null,
      metricDirection: "maximize",
      tokenBudget: null,
      skipsUnchangedWorkspace: false,
    };
    return { goal: { _0: goal } };
  }
  if (form.target === "turnBased") {
    return {
      turn: { pausesBeforeWritesOnly: form.pausesBeforeWritesOnly },
    };
  }
  const task =
    node.firstInstruction?.trim() ||
    "Carry on with what this session has been doing.";
  return {
    timed: {
      triggerPrompt: `/loop ${form.cadence.trim().toLocaleLowerCase()} ${task}`,
    },
  };
}
