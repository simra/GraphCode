import type { EdgeSpecPayload } from "../protocol/commands";
import type { EncodedEnum, LoopEdge } from "../protocol/domain";

export interface EdgeSpecFormState {
  kind: EdgeSpecPayload["kind"];
  condition: EdgeSpecPayload["condition"];
  transform: "none" | "template" | "script";
  transformText: string;
  maxIterations: string;
  until: string;
  plateauPasses: string;
  spawnPath: string;
}

function encodedCase(value: EncodedEnum | undefined): string | undefined {
  return typeof value === "string" ? value : value && Object.keys(value)[0];
}

function associatedText(
  value: EncodedEnum | undefined,
  key: "template" | "script",
): string {
  if (!value || typeof value === "string") return "";
  const payload = value[key];
  if (!payload || typeof payload !== "object") return "";
  const text = (payload as Record<string, unknown>)._0;
  return typeof text === "string" ? text : "";
}

export function edgeSpecFromSnapshot(edge: LoopEdge): EdgeSpecPayload {
  const condition = encodedCase(edge.condition);
  const transform = encodedCase(edge.payloadTransform);
  return {
    kind:
      edge.kind === "message" || edge.kind === "spawn" ? edge.kind : "handoff",
    condition:
      condition === "onSuccess" || condition === "onFailure"
        ? condition
        : "always",
    payloadTransform:
      transform === "template"
        ? {
            template: { _0: associatedText(edge.payloadTransform, "template") },
          }
        : transform === "script"
          ? { script: { _0: associatedText(edge.payloadTransform, "script") } }
          : { none: {} },
    cycleGuard: edge.cycleGuard
      ? {
          maxIterations: edge.cycleGuard.maxIterations ?? null,
          until: edge.cycleGuard.until ?? null,
          stopAfterPassesWithoutImprovement:
            edge.cycleGuard.stopAfterPassesWithoutImprovement ?? null,
        }
      : null,
    spawnTargetProjectPath: edge.spawnTargetProjectPath ?? null,
  };
}

export function edgeSpecForm(spec?: EdgeSpecPayload): EdgeSpecFormState {
  const payloadTransform = spec?.payloadTransform;
  const transform =
    payloadTransform && "template" in payloadTransform
      ? "template"
      : payloadTransform && "script" in payloadTransform
        ? "script"
        : "none";
  const transformText =
    transform === "template"
      ? payloadTransform && "template" in payloadTransform
        ? payloadTransform.template._0
        : ""
      : transform === "script" &&
          payloadTransform &&
          "script" in payloadTransform
        ? payloadTransform.script._0
        : "";
  return {
    kind: spec?.kind ?? "handoff",
    condition: spec?.condition ?? "always",
    transform,
    transformText,
    maxIterations: spec?.cycleGuard?.maxIterations?.toString() ?? "",
    until: spec?.cycleGuard?.until ?? "",
    plateauPasses:
      spec?.cycleGuard?.stopAfterPassesWithoutImprovement?.toString() ?? "",
    spawnPath: spec?.spawnTargetProjectPath ?? "",
  };
}

function positiveInteger(value: string, label: string) {
  if (!value.trim()) return null;
  const parsed = Number(value);
  if (!Number.isInteger(parsed) || parsed <= 0) {
    throw new Error(`${label} must be a positive integer.`);
  }
  return parsed;
}

export function buildEdgeSpec(form: EdgeSpecFormState): EdgeSpecPayload {
  const text = form.transformText.trim();
  if (form.transform !== "none" && !text) {
    throw new Error("Template or script text is required.");
  }
  const max = positiveInteger(form.maxIterations, "Maximum iterations");
  const plateau = positiveInteger(
    form.plateauPasses,
    "Passes without improvement",
  );
  const until = form.until.trim() || null;
  return {
    kind: form.kind,
    condition: form.condition,
    payloadTransform:
      form.transform === "none"
        ? { none: {} }
        : form.transform === "template"
          ? { template: { _0: text } }
          : { script: { _0: text } },
    cycleGuard:
      max !== null || plateau !== null || until
        ? {
            maxIterations: max,
            until,
            stopAfterPassesWithoutImprovement: plateau,
          }
        : null,
    spawnTargetProjectPath:
      form.kind === "spawn" ? form.spawnPath.trim() || null : null,
  };
}
