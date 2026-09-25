import type { LoopNode } from "../protocol/domain";
import type { DraftModelTier, NodeUpdatePayload } from "../protocol/commands";

export interface EditLoopFormState {
  goalSummary: string;
  goalPredicate: string;
  pollIntervalSeconds: string;
  stallAfterSeconds: string;
  metricCommand: string;
  metricDirection: "minimize" | "maximize";
  tokenBudget: string;
  skipsUnchangedWorkspace: boolean;
  triggerPrompt: string;
  heartbeatIntervalSeconds: string;
  checkDescription: string;
  modelTier: DraftModelTier | "";
}

export type EditLoopErrors = Partial<
  Record<keyof EditLoopFormState | "form", string>
>;

export function editLoopInitialState(node: LoopNode): EditLoopFormState {
  return {
    goalSummary: node.goal?.summary ?? "",
    goalPredicate: node.goal?.predicate ?? "",
    pollIntervalSeconds: String(node.goal?.pollIntervalSeconds ?? 60),
    stallAfterSeconds:
      node.goal?.stallAfterSeconds === undefined
        ? ""
        : String(node.goal.stallAfterSeconds),
    metricCommand: node.goal?.metricCommand ?? "",
    metricDirection: node.goal?.metricDirection ?? "maximize",
    tokenBudget:
      node.goal?.tokenBudget === undefined ? "" : String(node.goal.tokenBudget),
    skipsUnchangedWorkspace: node.goal?.skipsUnchangedWorkspace ?? false,
    triggerPrompt: node.triggerPrompt ?? "",
    heartbeatIntervalSeconds:
      node.heartbeatIntervalSeconds === undefined
        ? ""
        : String(node.heartbeatIntervalSeconds),
    checkDescription: node.checkDescription ?? "",
    modelTier:
      node.modelTier === "fast" ||
      node.modelTier === "standard" ||
      node.modelTier === "capable"
        ? node.modelTier
        : "",
  };
}

function positiveNumber(
  value: string,
  field: keyof EditLoopFormState,
  errors: EditLoopErrors,
  required: boolean,
) {
  if (!value.trim() && !required) return;
  const parsed = Number(value);
  if (!Number.isFinite(parsed) || parsed <= 0) {
    errors[field] = "Enter a positive number.";
  }
}

export function validateEditLoop(
  node: LoopNode,
  form: EditLoopFormState,
): EditLoopErrors {
  const errors: EditLoopErrors = {};
  if (node.loopType === "goalBased") {
    if (!form.goalSummary.trim()) {
      errors.goalSummary = "Goal summary is required.";
    }
    positiveNumber(
      form.pollIntervalSeconds,
      "pollIntervalSeconds",
      errors,
      true,
    );
    positiveNumber(form.stallAfterSeconds, "stallAfterSeconds", errors, false);
    positiveNumber(form.tokenBudget, "tokenBudget", errors, false);
    if (
      form.tokenBudget.trim() &&
      !Number.isInteger(Number(form.tokenBudget))
    ) {
      errors.tokenBudget = "Enter a positive whole number.";
    }
  }
  if (node.loopType === "timeBased") {
    if (!form.triggerPrompt.trim()) {
      errors.triggerPrompt = "Timed prompt is required.";
    }
    positiveNumber(
      form.heartbeatIntervalSeconds,
      "heartbeatIntervalSeconds",
      errors,
      false,
    );
  }
  return errors;
}

function changedText(
  next: string,
  current: string | undefined,
): string | undefined {
  const normalized = next.trim();
  const existing = current?.trim() ?? "";
  return normalized === existing ? undefined : normalized;
}

function changedOptionalNumber(
  next: string,
  current: number | undefined,
): number | undefined {
  if (!next.trim()) return current === undefined ? undefined : 0;
  const parsed = Number(next);
  return parsed === current ? undefined : parsed;
}

export function buildNodeUpdate(
  node: LoopNode,
  form: EditLoopFormState,
): NodeUpdatePayload {
  const errors = validateEditLoop(node, form);
  if (Object.keys(errors).length) {
    throw new Error("Cannot build an invalid loop update.");
  }

  const update: NodeUpdatePayload = { updatedBy: null };
  if (node.loopType === "goalBased" && node.goal) {
    update.goalSummary = changedText(form.goalSummary, node.goal.summary);
    update.goalPredicate = changedText(form.goalPredicate, node.goal.predicate);
    const pollInterval = Number(form.pollIntervalSeconds);
    if (pollInterval !== node.goal.pollIntervalSeconds) {
      update.pollIntervalSeconds = pollInterval;
    }
    update.stallAfterSeconds = changedOptionalNumber(
      form.stallAfterSeconds,
      node.goal.stallAfterSeconds,
    );
    update.metricCommand = changedText(
      form.metricCommand,
      node.goal.metricCommand,
    );
    if (form.metricDirection !== node.goal.metricDirection) {
      update.metricDirection = form.metricDirection;
    }
    update.tokenBudget = changedOptionalNumber(
      form.tokenBudget,
      node.goal.tokenBudget,
    );
    if (form.skipsUnchangedWorkspace !== node.goal.skipsUnchangedWorkspace) {
      update.skipsUnchangedWorkspace = form.skipsUnchangedWorkspace;
    }
  }
  if (node.loopType === "timeBased") {
    update.triggerPrompt = changedText(form.triggerPrompt, node.triggerPrompt);
    update.heartbeatIntervalSeconds = changedOptionalNumber(
      form.heartbeatIntervalSeconds,
      node.heartbeatIntervalSeconds,
    );
  }
  if (node.loopType === "turnBased") {
    update.checkDescription = changedText(
      form.checkDescription,
      node.checkDescription,
    );
  }
  if (form.modelTier && form.modelTier !== node.modelTier) {
    update.modelTier = form.modelTier;
  }

  for (const key of Object.keys(update) as (keyof NodeUpdatePayload)[]) {
    if (update[key] === undefined) delete update[key];
  }
  if (Object.keys(update).length === 1) {
    throw new Error("Change at least one editable field.");
  }
  return update;
}
