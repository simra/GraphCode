import type {
  DraftBackend,
  DraftLoopType,
  DraftModelTier,
  NodeDraftPayload,
} from "../protocol/commands";

export type CadenceMode = "session" | "daemon";

export interface NewLoopFormState {
  title: string;
  loopType: DraftLoopType;
  firstInstruction: string;
  checkDescription: string;
  pausesBeforeWritesOnly: boolean;
  triggerPrompt: string;
  cadenceMode: CadenceMode;
  heartbeatIntervalSeconds: string;
  goalSummary: string;
  goalPredicate: string;
  pollIntervalSeconds: string;
  stallAfterSeconds: string;
  metricCommand: string;
  metricDirection: "minimize" | "maximize";
  tokenBudget: string;
  skipsUnchangedWorkspace: boolean;
  backend: DraftBackend | "";
  modelTier: DraftModelTier | "";
  bindWorktree: boolean;
  worktreeId: string;
  worktreeRepositoryPath: string;
  worktreePath: string;
  worktreeBranch: string;
}

export type NewLoopErrors = Partial<
  Record<keyof NewLoopFormState | "form", string>
>;

export const initialNewLoopForm: NewLoopFormState = {
  title: "",
  loopType: "sketch",
  firstInstruction: "",
  checkDescription: "",
  pausesBeforeWritesOnly: false,
  triggerPrompt: "",
  cadenceMode: "session",
  heartbeatIntervalSeconds: "300",
  goalSummary: "",
  goalPredicate: "",
  pollIntervalSeconds: "60",
  stallAfterSeconds: "",
  metricCommand: "",
  metricDirection: "maximize",
  tokenBudget: "",
  skipsUnchangedWorkspace: false,
  backend: "",
  modelTier: "",
  bindWorktree: false,
  worktreeId: "",
  worktreeRepositoryPath: "",
  worktreePath: "",
  worktreeBranch: "",
};

export const loopTypeOptions: {
  value: DraftLoopType;
  label: string;
  description: string;
}[] = [
  {
    value: "sketch",
    label: "Main",
    description: "Open a session with no required workflow shape.",
  },
  {
    value: "goalBased",
    label: "Goal",
    description: "Work until a human or machine stop condition is met.",
  },
  {
    value: "timeBased",
    label: "Timed",
    description: "Repeat a task on an in-session or daemon heartbeat.",
  },
  {
    value: "turnBased",
    label: "Turn",
    description: "Pause for human review between turns.",
  },
  {
    value: "proactive",
    label: "Composite",
    description: "Create a nested graph that is piloted before it is armed.",
  },
];

export const backendOptions: { value: DraftBackend; label: string }[] = [
  { value: "claudeCode", label: "Claude Code" },
  { value: "copilotCLI", label: "Copilot CLI" },
  { value: "codex", label: "Codex" },
  { value: "openCode", label: "OpenCode" },
  { value: "pi", label: "Pi" },
];

const compositeBackends = new Set<DraftBackend>(["claudeCode", "copilotCLI"]);
const inSessionRecurrenceBackends = new Set<DraftBackend>([
  "claudeCode",
  "copilotCLI",
]);

export function backendCanHost(
  backend: DraftBackend | "",
  loopType: DraftLoopType,
  cadenceMode: CadenceMode,
): boolean {
  const effectiveBackend = backend || "claudeCode";
  if (loopType === "proactive") {
    return compositeBackends.has(effectiveBackend);
  }
  if (loopType === "timeBased" && cadenceMode === "session") {
    return inSessionRecurrenceBackends.has(effectiveBackend);
  }
  return true;
}

function positiveNumber(
  value: string,
  field: keyof NewLoopFormState,
  errors: NewLoopErrors,
  required: boolean,
): number | null {
  const trimmed = value.trim();
  if (!trimmed && !required) return null;
  const number = Number(trimmed);
  if (!Number.isFinite(number) || number <= 0) {
    errors[field] = "Enter a positive number.";
    return null;
  }
  return number;
}

function positiveInteger(
  value: string,
  field: keyof NewLoopFormState,
  errors: NewLoopErrors,
): number | null {
  const parsed = positiveNumber(value, field, errors, false);
  if (parsed !== null && !Number.isInteger(parsed)) {
    errors[field] = "Enter a positive whole number.";
    return null;
  }
  return parsed;
}

export function validateNewLoop(form: NewLoopFormState): NewLoopErrors {
  const errors: NewLoopErrors = {};
  if (form.loopType === "proactive" && !form.title.trim()) {
    errors.title = "Composite loops require a title.";
  }
  if (form.loopType === "turnBased" && !form.firstInstruction.trim()) {
    errors.firstInstruction = "Describe the first turn.";
  }
  if (form.loopType === "goalBased" && !form.goalSummary.trim()) {
    errors.goalSummary = "Describe what done means.";
  }
  if (form.loopType === "timeBased" && !form.triggerPrompt.trim()) {
    errors.triggerPrompt = "Describe the repeated task.";
  }
  if (!backendCanHost(form.backend, form.loopType, form.cadenceMode)) {
    errors.backend =
      form.loopType === "proactive"
        ? "Composite loops require Claude Code or Copilot CLI sub-agent support."
        : "This backend requires daemon heartbeat recurrence for timed loops.";
  }

  if (form.loopType === "timeBased" && form.cadenceMode === "daemon") {
    positiveNumber(
      form.heartbeatIntervalSeconds,
      "heartbeatIntervalSeconds",
      errors,
      true,
    );
  }
  if (form.loopType === "goalBased") {
    positiveNumber(
      form.pollIntervalSeconds,
      "pollIntervalSeconds",
      errors,
      true,
    );
    positiveNumber(form.stallAfterSeconds, "stallAfterSeconds", errors, false);
    positiveInteger(form.tokenBudget, "tokenBudget", errors);
  }
  if (form.bindWorktree) {
    for (const field of [
      "worktreeId",
      "worktreeRepositoryPath",
      "worktreePath",
      "worktreeBranch",
    ] as const) {
      if (!form[field].trim()) {
        errors[field] = "Complete every worktree field.";
      }
    }
  }
  return errors;
}

function optionalText(value: string): string | null {
  const trimmed = value.trim();
  return trimmed ? trimmed : null;
}

export function buildNodeDraft(
  form: NewLoopFormState,
  id: string,
): NodeDraftPayload {
  const errors = validateNewLoop(form);
  if (Object.keys(errors).length) {
    throw new Error("Cannot build an invalid New Loop draft.");
  }

  return {
    id,
    title: form.title.trim(),
    loopType: form.loopType,
    checkDescription:
      form.loopType === "turnBased"
        ? optionalText(form.checkDescription)
        : null,
    triggerPrompt:
      form.loopType === "timeBased"
        ? optionalText(form.triggerPrompt)
        : form.loopType === "proactive"
          ? optionalText(form.triggerPrompt)
          : null,
    heartbeatIntervalSeconds:
      form.loopType === "timeBased" && form.cadenceMode === "daemon"
        ? Number(form.heartbeatIntervalSeconds)
        : null,
    firstInstruction:
      form.loopType === "turnBased" || form.loopType === "sketch"
        ? optionalText(form.firstInstruction)
        : null,
    pausesBeforeWritesOnly:
      form.loopType === "turnBased" && form.pausesBeforeWritesOnly,
    attachments: [],
    goal:
      form.loopType === "goalBased"
        ? {
            summary: form.goalSummary.trim(),
            predicate: optionalText(form.goalPredicate),
            pollIntervalSeconds: Number(form.pollIntervalSeconds),
            stallAfterSeconds: form.stallAfterSeconds.trim()
              ? Number(form.stallAfterSeconds)
              : null,
            metricCommand: optionalText(form.metricCommand),
            metricDirection: form.metricDirection,
            tokenBudget: form.tokenBudget.trim()
              ? Number(form.tokenBudget)
              : null,
            skipsUnchangedWorkspace: form.skipsUnchangedWorkspace,
          }
        : null,
    backend: form.backend || null,
    modelTier: form.modelTier || null,
    worktree: form.bindWorktree
      ? {
          id: form.worktreeId.trim(),
          repositoryPath: form.worktreeRepositoryPath.trim(),
          worktreePath: form.worktreePath.trim(),
          branch: form.worktreeBranch.trim(),
        }
      : null,
    subGraph: null,
    createdBy: null,
    createdFromTemplateID: null,
    templateFollow: null,
  };
}
