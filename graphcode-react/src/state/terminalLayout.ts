export type TerminalSurface =
  { id: string; kind: "node" } | { id: string; kind: "shell" };

export type SplitDirection = "horizontal" | "vertical";

export type SplitNode =
  | { kind: "leaf"; surface: TerminalSurface }
  | {
      kind: "split";
      id: string;
      direction: SplitDirection;
      children: SplitNode[];
      sizes: number[];
    };

export interface TerminalTab {
  id: string;
  root: SplitNode;
  focusedSurfaceId: string;
}

export interface TerminalLayout {
  tabs: TerminalTab[];
  selectedTabId: string;
}

export function createTerminalLayout(
  nodeId: string,
  createId: () => string = () => crypto.randomUUID(),
): TerminalLayout {
  const tabId = createId();
  return {
    tabs: [
      {
        id: tabId,
        root: { kind: "leaf", surface: { id: nodeId, kind: "node" } },
        focusedSurfaceId: nodeId,
      },
    ],
    selectedTabId: tabId,
  };
}

export function terminalSurfaces(node: SplitNode): TerminalSurface[] {
  return node.kind === "leaf"
    ? [node.surface]
    : node.children.flatMap(terminalSurfaces);
}

export function selectedTerminalTab(
  layout: TerminalLayout,
): TerminalTab | undefined {
  return layout.tabs.find((tab) => tab.id === layout.selectedTabId);
}

export function addShellTab(
  layout: TerminalLayout,
  createId: () => string = () => crypto.randomUUID(),
): TerminalLayout {
  const surfaceId = createId();
  const tab: TerminalTab = {
    id: createId(),
    root: { kind: "leaf", surface: { id: surfaceId, kind: "shell" } },
    focusedSurfaceId: surfaceId,
  };
  return {
    tabs: [...layout.tabs, tab],
    selectedTabId: tab.id,
  };
}

export function selectTab(
  layout: TerminalLayout,
  tabId: string,
): TerminalLayout {
  return layout.tabs.some((tab) => tab.id === tabId)
    ? { ...layout, selectedTabId: tabId }
    : layout;
}

export function selectRelativeTab(
  layout: TerminalLayout,
  offset: number,
): TerminalLayout {
  const index = layout.tabs.findIndex((tab) => tab.id === layout.selectedTabId);
  if (index < 0 || layout.tabs.length < 2) return layout;
  const next =
    (((index + offset) % layout.tabs.length) + layout.tabs.length) %
    layout.tabs.length;
  return { ...layout, selectedTabId: layout.tabs[next].id };
}

export function focusPane(
  layout: TerminalLayout,
  tabId: string,
  surfaceId: string,
): TerminalLayout {
  return updateTab(layout, tabId, (tab) =>
    terminalSurfaces(tab.root).some((surface) => surface.id === surfaceId)
      ? { ...tab, focusedSurfaceId: surfaceId }
      : tab,
  );
}

export function focusRelativePane(
  layout: TerminalLayout,
  offset: number,
): TerminalLayout {
  const tab = selectedTerminalTab(layout);
  if (!tab) return layout;
  const surfaces = terminalSurfaces(tab.root);
  if (surfaces.length < 2) return layout;
  const current = Math.max(
    0,
    surfaces.findIndex((surface) => surface.id === tab.focusedSurfaceId),
  );
  const next =
    (((current + offset) % surfaces.length) + surfaces.length) %
    surfaces.length;
  return focusPane(layout, tab.id, surfaces[next].id);
}

export function splitFocusedPane(
  layout: TerminalLayout,
  direction: SplitDirection,
  createId: () => string = () => crypto.randomUUID(),
): TerminalLayout {
  const tab = selectedTerminalTab(layout);
  if (!tab) return layout;
  const addition: TerminalSurface = { id: createId(), kind: "shell" };
  return updateTab(layout, tab.id, (current) => ({
    ...current,
    root: splitNode(
      current.root,
      current.focusedSurfaceId,
      addition,
      direction,
    ),
    focusedSurfaceId: addition.id,
  }));
}

export function closePane(
  layout: TerminalLayout,
  tabId: string,
  surfaceId: string,
  nodeId: string,
): TerminalLayout {
  const tab = layout.tabs.find((candidate) => candidate.id === tabId);
  if (!tab) return layout;
  const before = terminalSurfaces(tab.root);
  const closedIndex = before.findIndex((surface) => surface.id === surfaceId);
  if (closedIndex < 0) return layout;
  const root = removeSurface(tab.root, surfaceId);
  if (!root) return closeTab(layout, tabId, nodeId);
  const survivors = terminalSurfaces(root);
  return updateTab(layout, tabId, (current) => ({
    ...current,
    root,
    focusedSurfaceId:
      current.focusedSurfaceId === surfaceId
        ? survivors[Math.max(0, closedIndex - 1)].id
        : current.focusedSurfaceId,
  }));
}

export function closeTab(
  layout: TerminalLayout,
  tabId: string,
  nodeId: string,
): TerminalLayout {
  const index = layout.tabs.findIndex((tab) => tab.id === tabId);
  if (index < 0) return layout;
  if (layout.tabs.length === 1) {
    const tab = layout.tabs[0];
    if (
      tab.root.kind === "leaf" &&
      tab.root.surface.kind === "node" &&
      tab.root.surface.id === nodeId
    ) {
      return layout;
    }
    return {
      tabs: [
        {
          ...tab,
          root: { kind: "leaf", surface: { id: nodeId, kind: "node" } },
          focusedSurfaceId: nodeId,
        },
      ],
      selectedTabId: tab.id,
    };
  }
  const tabs = layout.tabs.filter((tab) => tab.id !== tabId);
  return {
    tabs,
    selectedTabId:
      layout.selectedTabId === tabId
        ? tabs[Math.min(index, tabs.length - 1)].id
        : layout.selectedTabId,
  };
}

export function resizeSplit(
  layout: TerminalLayout,
  tabId: string,
  splitId: string,
  dividerIndex: number,
  delta: number,
): TerminalLayout {
  return updateTab(layout, tabId, (tab) => {
    const root = resizeSplitNode(tab.root, splitId, dividerIndex, delta);
    return root === tab.root ? tab : { ...tab, root };
  });
}

function updateTab(
  layout: TerminalLayout,
  tabId: string,
  update: (tab: TerminalTab) => TerminalTab,
): TerminalLayout {
  let changed = false;
  const tabs = layout.tabs.map((tab) => {
    if (tab.id !== tabId) return tab;
    const next = update(tab);
    changed ||= next !== tab;
    return next;
  });
  return changed ? { ...layout, tabs } : layout;
}

function splitNode(
  node: SplitNode,
  targetId: string,
  addition: TerminalSurface,
  direction: SplitDirection,
): SplitNode {
  if (node.kind === "leaf") {
    return node.surface.id === targetId
      ? {
          kind: "split",
          id: `split-${addition.id}`,
          direction,
          children: [node, { kind: "leaf", surface: addition }],
          sizes: [0.5, 0.5],
        }
      : node;
  }
  if (node.direction === direction) {
    const index = node.children.findIndex(
      (child) => child.kind === "leaf" && child.surface.id === targetId,
    );
    if (index >= 0) {
      const children = [...node.children];
      children.splice(index + 1, 0, { kind: "leaf", surface: addition });
      const sizes = [...node.sizes];
      const targetSize = sizes[index];
      sizes[index] = targetSize / 2;
      sizes.splice(index + 1, 0, targetSize / 2);
      return { ...node, children, sizes };
    }
  }
  return {
    ...node,
    children: node.children.map((child) =>
      splitNode(child, targetId, addition, direction),
    ),
  };
}

function removeSurface(node: SplitNode, surfaceId: string): SplitNode | null {
  if (node.kind === "leaf") {
    return node.surface.id === surfaceId ? null : node;
  }
  const children: SplitNode[] = [];
  const sizes: number[] = [];
  node.children.forEach((child, index) => {
    const next = removeSurface(child, surfaceId);
    if (!next) return;
    children.push(next);
    sizes.push(node.sizes[index]);
  });
  if (!children.length) return null;
  if (children.length === 1) return children[0];
  return { ...node, children, sizes: normalizeSizes(sizes) };
}

function resizeSplitNode(
  node: SplitNode,
  splitId: string,
  dividerIndex: number,
  delta: number,
): SplitNode {
  if (node.kind === "leaf") return node;
  if (
    node.id === splitId &&
    dividerIndex >= 0 &&
    dividerIndex < node.children.length - 1
  ) {
    const pairSize = node.sizes[dividerIndex] + node.sizes[dividerIndex + 1];
    const minimum = Math.min(0.1, pairSize / 3);
    const first = Math.min(
      pairSize - minimum,
      Math.max(minimum, node.sizes[dividerIndex] + delta),
    );
    if (first === node.sizes[dividerIndex]) return node;
    const sizes = [...node.sizes];
    sizes[dividerIndex] = first;
    sizes[dividerIndex + 1] = pairSize - first;
    return { ...node, sizes };
  }
  let changed = false;
  const children = node.children.map((child) => {
    const next = resizeSplitNode(child, splitId, dividerIndex, delta);
    changed ||= next !== child;
    return next;
  });
  return changed ? { ...node, children } : node;
}

function normalizeSizes(sizes: number[]): number[] {
  const total = sizes.reduce((sum, size) => sum + size, 0);
  return total > 0
    ? sizes.map((size) => size / total)
    : sizes.map(() => 1 / sizes.length);
}
