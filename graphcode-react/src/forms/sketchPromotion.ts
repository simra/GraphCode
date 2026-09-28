import type { GoalDraft, SketchPromotionPayload } from "../protocol/commands";
import type { LoopNode } from "../protocol/domain";

export type PromotionTarget = "goalBased" | "turnBased" | "timeBased";

export interface SketchPromotionFormState {
  target: PromotionTarget;
  goalSummary: string;
  pausesBeforeWritesOnly: boolean;
  cadence: string;
  timedTask: string;
}

export type SketchPromotionErrors = Partial<
  Record<keyof SketchPromotionFormState, string>
>;

export const initialSketchPromotionForm: SketchPromotionFormState = {
  target: "goalBased",
  goalSummary: "",
  pausesBeforeWritesOnly: false,
  cadence: "1h",
  timedTask: "Carry on with what this session has been doing.",
};

export function promotionTargetForNode(
  node: Pick<LoopNode, "loopType" | "state">,
): PromotionTarget | undefined {
  const state =
    typeof node.state === "string" ? node.state : Object.keys(node.state)[0];
  if (state === "stopped") return undefined;
  if (node.loopType === "goalBased") return "timeBased";
  if (node.loopType === "timeBased") return "goalBased";
  return undefined;
}

export function sketchPromotionInitialState(
  node: Pick<LoopNode, "loopType" | "state" | "firstInstruction">,
): SketchPromotionFormState {
  const target = promotionTargetForNode(node) ?? "goalBased";
  return {
    ...initialSketchPromotionForm,
    target,
    timedTask:
      node.loopType === "goalBased"
        ? ""
        : node.firstInstruction?.trim() || initialSketchPromotionForm.timedTask,
  };
}

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
    if (!form.timedTask.trim()) {
      errors.timedTask = "Describe what each pass should do.";
    }
  }
  return errors;
}

export function buildSketchPromotion(
  form: SketchPromotionFormState,
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
  return {
    timed: {
      triggerPrompt: `/loop ${form.cadence.trim().toLocaleLowerCase()} ${form.timedTask.trim()}`,
    },
  };
}
