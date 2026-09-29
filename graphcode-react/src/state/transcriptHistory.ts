import type {
  TranscriptEntry,
  TranscriptPage,
  TranscriptRedaction,
} from "../protocol/domain";

export type TranscriptHistoryErrorKind =
  | "unauthorized"
  | "missing"
  | "unsupported"
  | "oversized"
  | "invalidCursor"
  | "corrupt"
  | "transport"
  | "unknown";

export interface TranscriptHistoryError {
  kind: TranscriptHistoryErrorKind;
  title: string;
  message: string;
}

export interface TranscriptHistoryState {
  identity: string;
  entries: TranscriptEntry[];
  provider?: TranscriptPage["provider"];
  nextCursor?: string;
  hasMore: boolean;
  loadingInitial: boolean;
  loadingMore: boolean;
  error?: TranscriptHistoryError;
}

export type TranscriptHistoryAction =
  | { type: "reset"; identity: string }
  | { type: "loadStarted"; cursor?: string }
  | { type: "pageLoaded"; cursor?: string; page: TranscriptPage }
  | {
      type: "loadFailed";
      cursor?: string;
      error: TranscriptHistoryError;
    };

export function createTranscriptHistoryState(
  identity: string,
): TranscriptHistoryState {
  return {
    identity,
    entries: [],
    hasMore: false,
    loadingInitial: false,
    loadingMore: false,
  };
}

export function transcriptHistoryReducer(
  state: TranscriptHistoryState,
  action: TranscriptHistoryAction,
): TranscriptHistoryState {
  switch (action.type) {
    case "reset":
      return createTranscriptHistoryState(action.identity);
    case "loadStarted":
      return {
        ...state,
        loadingInitial: action.cursor === undefined,
        loadingMore: action.cursor !== undefined,
        error: undefined,
      };
    case "pageLoaded": {
      const entries =
        action.cursor === undefined
          ? action.page.entries
          : appendOrderedEntries(state.entries, action.page.entries);
      return {
        ...state,
        entries,
        provider: action.page.provider,
        nextCursor: action.page.nextCursor,
        hasMore: action.page.hasMore,
        loadingInitial: false,
        loadingMore: false,
        error: undefined,
      };
    }
    case "loadFailed":
      return {
        ...state,
        loadingInitial: false,
        loadingMore: false,
        error: action.error,
      };
  }
}

function appendOrderedEntries(
  current: TranscriptEntry[],
  next: TranscriptEntry[],
): TranscriptEntry[] {
  const seenOffsets = new Set(current.map((entry) => entry.sourceOffset));
  return [
    ...current,
    ...next.filter((entry) => !seenOffsets.has(entry.sourceOffset)),
  ];
}

export function transcriptHistoryError(error: unknown): TranscriptHistoryError {
  const message = error instanceof Error ? error.message : String(error);
  const code = message.split(":", 1)[0];
  switch (code) {
    case "transcriptUnauthorized":
      return {
        kind: "unauthorized",
        title: "History is not authorized",
        message:
          "Reopen this project and select the loop again. GraphCode will not reveal whether transcripts outside the joined project exist.",
      };
    case "transcriptMissing":
      return {
        kind: "missing",
        title: "No transcript was found",
        message:
          "The provider session may not have started yet, or its retained transcript may have expired.",
      };
    case "transcriptUnsupportedProvider":
      return {
        kind: "unsupported",
        title: "This provider does not support structured history",
        message:
          "GraphCode will not substitute raw terminal output for a transcript on this provider.",
      };
    case "transcriptOversized":
      return {
        kind: "oversized",
        title: "This transcript is too large to read safely",
        message:
          "The daemon rejected the bounded read rather than truncating or loading an unbounded session.",
      };
    case "transcriptInvalidCursor":
      return {
        kind: "invalidCursor",
        title: "The transcript changed while paging",
        message:
          "Close and reopen history to start from a fresh bounded snapshot. Already loaded entries remain visible.",
      };
    case "transcriptCorrupt":
    case "transcriptInvalidBounds":
      return {
        kind: "corrupt",
        title: "The transcript could not be decoded safely",
        message:
          "The provider history is malformed or violated the daemon's bounded transcript contract.",
      };
    case "transcriptTransportFailure":
      return {
        kind: "transport",
        title: "History could not reach the transcript source",
        message:
          "Check the project connection and try again. Already loaded entries remain visible.",
      };
    default:
      return {
        kind: "unknown",
        title: "History could not be loaded",
        message:
          "Reconnect to graphcoded and try again. The live terminal was not affected.",
      };
  }
}

export function providerLabel(
  provider: TranscriptPage["provider"] | string | undefined,
): string {
  switch (provider) {
    case "claudeCode":
      return "Claude Code";
    case "copilotCLI":
      return "Copilot CLI";
    case "codex":
      return "Codex";
    case "openCode":
      return "OpenCode";
    case "pi":
      return "Pi";
    default:
      return "Provider pending";
  }
}

export function supportsStructuredTranscript(provider: string | undefined) {
  return (
    provider === "claudeCode" ||
    provider === "copilotCLI" ||
    provider === "codex"
  );
}

export function redactionLabel(redaction: TranscriptRedaction): string {
  switch (redaction) {
    case "prompt":
      return "Prompt withheld";
    case "toolInput":
      return "Tool input withheld";
    case "toolResult":
      return "Tool result withheld";
    case "filesystemPath":
      return "Path redacted";
    case "secret":
      return "Secret redacted";
    case "modelMetadata":
      return "Model metadata withheld";
  }
}
