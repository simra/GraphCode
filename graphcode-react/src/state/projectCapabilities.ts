import type {
  ProjectCapabilities,
  ProjectLocationKind,
  ProjectRef,
} from "../protocol/domain";

export type ProjectCapability = keyof ProjectCapabilities;

const capabilityLabels: Record<ProjectCapability, string> = {
  revealInFileManager: "Reveal in File Explorer",
  templates: "Templates",
  attachments: "Attachments",
  interactiveTerminals: "Interactive terminals",
  diagnostics: "Diagnostics",
  memoryReads: "Memory history",
};

const unsupportedPhrases: Record<ProjectCapability, string> = {
  revealInFileManager: "Reveal in File Explorer is not supported",
  templates: "Templates are not supported",
  attachments: "Attachments are not supported",
  interactiveTerminals: "Interactive terminals are not supported",
  diagnostics: "Diagnostics are not supported",
  memoryReads: "Memory history is not supported",
};

const locationLabels: Record<ProjectLocationKind, string> = {
  local: "local projects",
  ssh: "SSH projects",
  codespace: "Codespace projects",
};

export function projectSupports(
  project: ProjectRef | undefined,
  capability: ProjectCapability,
): boolean {
  if (project?.path === "graphcode://global") {
    return (
      capability === "interactiveTerminals" || capability === "diagnostics"
    );
  }
  return project?.metadata?.capabilities[capability] === true;
}

export function projectCapabilityDisabledReason(
  project: ProjectRef | undefined,
  capability: ProjectCapability,
): string | undefined {
  if (projectSupports(project, capability)) return undefined;
  if (project?.path === "graphcode://global") {
    return `${capabilityLabels[capability]} is not available for the global graph`;
  }
  if (!project?.metadata) {
    return `${capabilityLabels[capability]} is unavailable because this daemon did not advertise authoritative project capabilities`;
  }
  return `${unsupportedPhrases[capability]} for ${locationLabels[project.metadata.location]}`;
}
