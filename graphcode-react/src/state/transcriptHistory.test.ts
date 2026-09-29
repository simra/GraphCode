import { describe, expect, it } from "vitest";
import type { TranscriptPage } from "../protocol/domain";
import {
  createTranscriptHistoryState,
  transcriptHistoryError,
  transcriptHistoryReducer,
} from "./transcriptHistory";

const firstPage: TranscriptPage = {
  nodeID: "node",
  provider: "copilotCLI",
  entries: [
    {
      sourceOffset: 10,
      kind: "prompt",
      text: "[redacted prompt]",
      redactions: ["prompt"],
    },
  ],
  nextCursor: "cursor-1",
  hasMore: true,
};

describe("transcriptHistoryReducer", () => {
  it("preserves page ordering and ignores duplicate offsets", () => {
    let state = createTranscriptHistoryState("project\u0000node");
    state = transcriptHistoryReducer(state, {
      type: "pageLoaded",
      page: firstPage,
    });
    state = transcriptHistoryReducer(state, {
      type: "pageLoaded",
      cursor: "cursor-1",
      page: {
        ...firstPage,
        entries: [
          firstPage.entries[0],
          {
            sourceOffset: 20,
            kind: "status",
            text: "Complete",
            redactions: [],
          },
        ],
        nextCursor: undefined,
        hasMore: false,
      },
    });

    expect(state.entries.map((entry) => entry.sourceOffset)).toEqual([10, 20]);
    expect(state.hasMore).toBe(false);
  });

  it("retains loaded pages when a later cursor fails", () => {
    let state = transcriptHistoryReducer(
      createTranscriptHistoryState("project\u0000node"),
      { type: "pageLoaded", page: firstPage },
    );
    state = transcriptHistoryReducer(state, {
      type: "loadFailed",
      cursor: "cursor-1",
      error: transcriptHistoryError(
        "graphcoded refused the command (transcriptTransportFailure): disconnected",
      ),
    });

    expect(state.entries).toEqual(firstPage.entries);
    expect(state.error?.kind).toBe("transport");
  });

  it("resets all stale history for a new project and node identity", () => {
    const loaded = transcriptHistoryReducer(
      createTranscriptHistoryState("old"),
      { type: "pageLoaded", page: firstPage },
    );
    const reset = transcriptHistoryReducer(loaded, {
      type: "reset",
      identity: "new",
    });

    expect(reset).toEqual(createTranscriptHistoryState("new"));
  });

  it.each([
    ["transcriptUnauthorized", "unauthorized", false],
    ["transcriptMissing", "missing", true],
    ["transcriptCorrupt", "corrupt", false],
    ["transcriptOversized", "oversized", false],
    ["transcriptInvalidBounds", "invalidBounds", false],
    ["transcriptInvalidCursor", "invalidCursor", false],
    ["transcriptUnsupportedProvider", "unsupported", false],
    ["transcriptTransportFailure", "transport", true],
  ] as const)(
    "maps the production %s rejection into an actionable %s state",
    (code, kind, retryable) => {
      expect(
        transcriptHistoryError(
          `graphcoded refused the command (${code}): fixture`,
        ),
      ).toMatchObject({ kind, retryable });
    },
  );

  it("gives invalid cursors fresh-snapshot guidance without retrying the stale cursor", () => {
    expect(
      transcriptHistoryError(
        "graphcoded refused the command (transcriptInvalidCursor): source changed",
      ),
    ).toEqual({
      kind: "invalidCursor",
      title: "The transcript changed while paging",
      message:
        "Close and reopen history to start from a fresh bounded snapshot. Already loaded entries remain visible.",
      retryable: false,
    });
  });

  it("keeps unknown production bridge failures generic and retryable", () => {
    expect(
      transcriptHistoryError(
        "graphcoded refused the command (futureCode): fixture",
      ),
    ).toEqual({
      kind: "unknown",
      title: "History could not be loaded",
      message:
        "Reconnect to graphcoded and try again. The live terminal was not affected.",
      retryable: true,
    });
  });
});
