import { z } from "zod";
import { MAX_RESOLVED_SESSION_GRACE_MINUTES } from "../protocol/domain";

export { MAX_RESOLVED_SESSION_GRACE_MINUTES } from "../protocol/domain";

const backendSchema = z.enum([
  "claudeCode",
  "copilotCLI",
  "codex",
  "openCode",
  "pi",
]);
const modelTierSchema = z.enum(["fast", "standard", "capable"]);
const codexApprovalsSchema = z.enum([
  "ask",
  "workspace",
  "unsandboxed",
  "yolo",
]);
const openCodePermissionsSchema = z.enum(["ask", "auto"]);
const piProjectTrustSchema = z.enum(["approve", "ask"]);
const claudePermissionModeSchema = z.enum([
  "manual",
  "acceptEdits",
  "auto",
  "dontAsk",
  "bypassPermissions",
]);
const copilotPermissionsSchema = z.enum([
  "ask",
  "allowTools",
  "allowEverything",
  "yoloAutopilot",
]);

export const graphcodeSettingsSchema = z
  .object({
    defaultBackend: backendSchema.default("claudeCode"),
    defaultModelTier: modelTierSchema.default("standard"),
    codexApprovals: codexApprovalsSchema.default("yolo"),
    openCodePermissions: openCodePermissionsSchema.default("auto"),
    piProjectTrust: piProjectTrustSchema.default("approve"),
    claudePermissionMode: claudePermissionModeSchema.default("auto"),
    copilotPermissions: copilotPermissionsSchema.default("allowEverything"),
    copilotPreferredVersion: z.string().default(""),
    briefsSessionsAboutTheGraph: z.boolean().default(true),
    endsResolvedSessionsAfterMinutes: z
      .number()
      .finite()
      .transform((value) =>
        Math.min(
          MAX_RESOLVED_SESSION_GRACE_MINUTES,
          Math.max(0, Math.trunc(value)),
        ),
      )
      .default(10),
    autoSelectsModel: z.boolean().default(false),
    worktreePolicies: z
      .record(z.string(), z.record(z.string(), z.unknown()))
      .default({}),
    showsActivityStrip: z.boolean().default(false),
    betaUpdates: z.boolean().default(false),
    summarisesLoops: z.boolean().default(false),
    summaryUsesModel: z.boolean().default(false),
    visualisesSummaries: z.boolean().default(false),
    daemonHeartbeatEnabled: z.boolean().default(false),
    mailroomEnabled: z.boolean().optional(),
    keepsMacAwakeWhileLoopsRun: z.boolean().default(false),
    artifactoryEnabled: z.boolean().optional(),
  })
  .passthrough()
  .transform((settings) => ({
    ...settings,
    mailroomEnabled:
      settings.mailroomEnabled ?? settings.artifactoryEnabled ?? true,
  }));

export type GraphcodeSettings = z.output<typeof graphcodeSettingsSchema>;

export const settingsDefaults = graphcodeSettingsSchema.parse({});

export type EditableSettingsField =
  | "defaultBackend"
  | "defaultModelTier"
  | "codexApprovals"
  | "openCodePermissions"
  | "piProjectTrust"
  | "claudePermissionMode"
  | "copilotPermissions"
  | "copilotPreferredVersion"
  | "briefsSessionsAboutTheGraph"
  | "endsResolvedSessionsAfterMinutes"
  | "autoSelectsModel"
  | "worktreePolicies"
  | "showsActivityStrip"
  | "betaUpdates"
  | "summarisesLoops"
  | "summaryUsesModel"
  | "visualisesSummaries"
  | "daemonHeartbeatEnabled"
  | "mailroomEnabled"
  | "keepsMacAwakeWhileLoopsRun";

export const editableSettingsFields: EditableSettingsField[] = [
  "defaultBackend",
  "defaultModelTier",
  "codexApprovals",
  "openCodePermissions",
  "piProjectTrust",
  "claudePermissionMode",
  "copilotPermissions",
  "copilotPreferredVersion",
  "briefsSessionsAboutTheGraph",
  "endsResolvedSessionsAfterMinutes",
  "autoSelectsModel",
  "worktreePolicies",
  "showsActivityStrip",
  "betaUpdates",
  "summarisesLoops",
  "summaryUsesModel",
  "visualisesSummaries",
  "daemonHeartbeatEnabled",
  "mailroomEnabled",
  "keepsMacAwakeWhileLoopsRun",
];

export type SettingsValidationErrors = Partial<
  Record<EditableSettingsField, string>
>;

export function validateSettingsDraft(
  draft: GraphcodeSettings,
): SettingsValidationErrors {
  const errors: SettingsValidationErrors = {};
  if (
    !Number.isSafeInteger(draft.endsResolvedSessionsAfterMinutes) ||
    draft.endsResolvedSessionsAfterMinutes < 0 ||
    draft.endsResolvedSessionsAfterMinutes > MAX_RESOLVED_SESSION_GRACE_MINUTES
  ) {
    errors.endsResolvedSessionsAfterMinutes = `Use zero to keep sessions, or a whole number up to ${MAX_RESOLVED_SESSION_GRACE_MINUTES.toLocaleString("en-US")} minutes.`;
  }
  return errors;
}

export function changedSettingsFields(
  baseline: GraphcodeSettings,
  draft: GraphcodeSettings,
): EditableSettingsField[] {
  return editableSettingsFields.filter(
    (field) => JSON.stringify(baseline[field]) !== JSON.stringify(draft[field]),
  );
}

export function rebaseSettingsDraft(
  baseline: GraphcodeSettings,
  draft: GraphcodeSettings,
  incoming: GraphcodeSettings,
): GraphcodeSettings {
  const rebased = { ...incoming };
  for (const field of changedSettingsFields(baseline, draft)) {
    rebased[field] = draft[field] as never;
  }
  return rebased;
}

export function copilotInstallCommand(version: string): string | undefined {
  const normalized = version.trim();
  if (!normalized) return undefined;
  const packageName = `@github/copilot@${normalized}`;
  return `npm install -g '${packageName.replaceAll("'", "'\\''")}'`;
}
