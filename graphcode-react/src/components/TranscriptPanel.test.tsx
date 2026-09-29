// @vitest-environment jsdom

import { act } from "react";
import { createRoot } from "react-dom/client";
import { afterEach, describe, expect, it, vi } from "vitest";
import type { LoopNode, TranscriptPage } from "../protocol/domain";
import { TranscriptPanel } from "./TranscriptPanel";

(
  globalThis as typeof globalThis & { IS_REACT_ACT_ENVIRONMENT: boolean }
).IS_REACT_ACT_ENVIRONMENT = true;

const node: LoopNode = {
  id: "node-1",
  title: "Readable session",
  backend: "copilotCLI",
  state: "idle",
};

function deferred<T>() {
  let resolve!: (value: T) => void;
  const promise = new Promise<T>((complete) => {
    resolve = complete;
  });
  return { promise, resolve };
}

afterEach(() => {
  document.body.innerHTML = "";
});

describe("TranscriptPanel", () => {
  it("renders semantic redactions and loads another page only once", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const second = deferred<TranscriptPage>();
    const readPage = vi
      .fn()
      .mockResolvedValueOnce({
        nodeID: node.id,
        provider: "copilotCLI",
        entries: [
          {
            sourceOffset: 1,
            timestamp: "2026-09-29T18:00:00Z",
            kind: "toolUse",
            text: "Used an allowlisted tool",
            toolName: "read",
            redactions: ["toolInput", "filesystemPath"],
          },
        ],
        nextCursor: "next",
        hasMore: true,
      })
      .mockReturnValueOnce(second.promise);

    await act(async () => {
      root.render(
        <TranscriptPanel
          projectPath="C:\\project"
          node={node}
          onClose={() => undefined}
          readPage={readPage}
        />,
      );
    });

    expect(container.textContent).toContain("Tool: read");
    expect(container.textContent).toContain("Tool input withheld");
    expect(container.textContent).toContain("Path redacted");
    const loadMore = Array.from(container.querySelectorAll("button")).find(
      (button) => button.textContent === "Load more history",
    )!;
    await act(async () => {
      loadMore.click();
      loadMore.click();
    });
    expect(readPage).toHaveBeenCalledTimes(2);

    await act(async () => {
      second.resolve({
        nodeID: node.id,
        provider: "copilotCLI",
        entries: [
          {
            sourceOffset: 2,
            kind: "assistant",
            text: "[redacted assistant text]",
            redactions: ["secret"],
          },
        ],
        hasMore: false,
      });
      await second.promise;
    });
    expect(container.textContent).toContain("[redacted assistant text]");
    expect(container.textContent).toContain("Secret redacted");
  });

  it("ignores a stale response after the node changes", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const oldPage = deferred<TranscriptPage>();
    const readPage = vi
      .fn()
      .mockReturnValueOnce(oldPage.promise)
      .mockResolvedValueOnce({
        nodeID: "node-2",
        provider: "codex",
        entries: [
          {
            sourceOffset: 20,
            kind: "status",
            text: "New selection",
            redactions: [],
          },
        ],
        hasMore: false,
      });

    await act(async () => {
      root.render(
        <TranscriptPanel
          projectPath="C:\\project"
          node={node}
          onClose={() => undefined}
          readPage={readPage}
        />,
      );
    });
    await act(async () => {
      root.render(
        <TranscriptPanel
          projectPath="C:\\project"
          node={{ ...node, id: "node-2", title: "New node", backend: "codex" }}
          onClose={() => undefined}
          readPage={readPage}
        />,
      );
    });
    await act(async () => {
      oldPage.resolve({
        nodeID: node.id,
        provider: "copilotCLI",
        entries: [
          {
            sourceOffset: 10,
            kind: "status",
            text: "Stale selection",
            redactions: [],
          },
        ],
        hasMore: false,
      });
      await oldPage.promise;
    });

    expect(container.textContent).toContain("New selection");
    expect(container.textContent).not.toContain("Stale selection");
  });

  it("keeps loaded entries visible when a later page fails", async () => {
    const container = document.createElement("div");
    document.body.append(container);
    const root = createRoot(container);
    const readPage = vi
      .fn()
      .mockResolvedValueOnce({
        nodeID: node.id,
        provider: "copilotCLI",
        entries: [
          {
            sourceOffset: 1,
            kind: "status",
            text: "Already loaded",
            redactions: [],
          },
        ],
        nextCursor: "next",
        hasMore: true,
      })
      .mockRejectedValueOnce(
        new Error("transcriptInvalidCursor: source changed"),
      );

    await act(async () => {
      root.render(
        <TranscriptPanel
          projectPath="C:\\project"
          node={node}
          onClose={() => undefined}
          readPage={readPage}
        />,
      );
    });
    await act(async () => {
      Array.from(container.querySelectorAll("button"))
        .find((button) => button.textContent === "Load more history")!
        .click();
    });

    expect(container.textContent).toContain("Already loaded");
    expect(container.textContent).toContain(
      "The transcript changed while paging",
    );
    expect(container.textContent).not.toContain("Load more history");
  });

  it("focuses the panel controls and closes with Escape", async () => {
    const container = document.createElement("div");
    const invoker = document.createElement("button");
    invoker.textContent = "Open history";
    document.body.append(invoker, container);
    invoker.focus();
    const root = createRoot(container);
    const onClose = vi.fn();

    await act(async () => {
      root.render(
        <TranscriptPanel
          projectPath="C:\\project"
          node={node}
          onClose={onClose}
          readPage={async () => ({
            nodeID: node.id,
            provider: "copilotCLI",
            entries: [],
            hasMore: false,
          })}
        />,
      );
    });

    expect(document.activeElement?.getAttribute("aria-label")).toBe(
      "Close history",
    );
    await act(async () => {
      document.activeElement?.dispatchEvent(
        new KeyboardEvent("keydown", { key: "Escape", bubbles: true }),
      );
    });
    expect(onClose).toHaveBeenCalledOnce();

    await act(async () => {
      root.unmount();
    });
    expect(document.activeElement).toBe(invoker);
  });
});
