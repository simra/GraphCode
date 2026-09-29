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
        new Error("transcriptTransportFailure: disconnected"),
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
    ["transcriptUnauthorized", "unauthorized"],
    ["transcriptMissing", "missing"],
    ["transcriptUnsupportedProvider", "unsupported"],
    ["transcriptOversized", "oversized"],
    ["transcriptInvalidCursor", "invalidCursor"],
    ["transcriptCorrupt", "corrupt"],
    ["transcriptTransportFailure", "transport"],
  ] as const)("maps %s into an actionable %s state", (code, kind) => {
    expect(transcriptHistoryError(new Error(`${code}: fixture`)).kind).toBe(
      kind,
    );
  });
});
