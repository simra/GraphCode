import type { LoopGraph, ProjectRef } from "../protocol/domain";

export const globalProjectPath = "graphcode://global";

export interface ProjectNavigation {
  global?: ProjectRef;
  open: ProjectRef[];
  recent: ProjectRef[];
}

export function deriveProjectNavigation(
  recentProjects: ProjectRef[],
  graphs: Record<string, LoopGraph>,
): ProjectNavigation {
  const global = graphs[globalProjectPath]?.project;
  const open = Object.values(graphs)
    .map((graph) => graph.project)
    .filter((project) => project.path !== globalProjectPath)
    .sort((left, right) => left.name.localeCompare(right.name));
  const openPaths = new Set(open.map((project) => project.path.toLowerCase()));
  const recent = recentProjects
    .filter(
      (project) =>
        project.path !== globalProjectPath &&
        !openPaths.has(project.path.toLowerCase()),
    )
    .sort((left, right) => {
      const leftDate = new Date(left.lastOpenedAt ?? 0).valueOf();
      const rightDate = new Date(right.lastOpenedAt ?? 0).valueOf();
      return rightDate - leftDate || left.name.localeCompare(right.name);
    });

  return { global, open, recent };
}
