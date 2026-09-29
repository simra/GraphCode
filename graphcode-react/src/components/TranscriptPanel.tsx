import { useCallback, useEffect, useReducer, useRef } from "react";
import { readTranscriptPage } from "../bridge/daemon";
import type {
  LoopNode,
  TranscriptEntry,
  TranscriptPage,
} from "../protocol/domain";
import {
  createTranscriptHistoryState,
  providerLabel,
  redactionLabel,
  transcriptHistoryError,
  transcriptHistoryReducer,
} from "../state/transcriptHistory";
import { useDialogFocus } from "./dialogFocus";

const PAGE_ENTRIES = 32;
const PAGE_BYTES = 64 * 1024;

export type TranscriptPageReader = (
  projectPath: string,
  nodeID: string,
  cursor?: string | null,
  maxEntries?: number,
  maxBytes?: number,
) => Promise<TranscriptPage>;

function entryLabel(entry: TranscriptEntry): string {
  switch (entry.kind) {
    case "prompt":
      return "Prompt";
    case "assistant":
      return "Assistant";
    case "toolUse":
      return entry.toolName ? `Tool: ${entry.toolName}` : "Tool";
    case "toolResult":
      return "Tool result";
    case "status":
      return "Status";
  }
}

function TranscriptEntryView({ entry }: { entry: TranscriptEntry }) {
  return (
    <article className={`transcript-entry transcript-entry-${entry.kind}`}>
      <header>
        <strong>{entryLabel(entry)}</strong>
        {entry.timestamp ? (
          <time dateTime={entry.timestamp}>
            {new Date(entry.timestamp).toLocaleString()}
          </time>
        ) : null}
      </header>
      <p>{entry.text}</p>
      {entry.redactions.length ? (
        <ul className="transcript-redactions" aria-label="Applied redactions">
          {entry.redactions.map((redaction) => (
            <li key={redaction}>{redactionLabel(redaction)}</li>
          ))}
        </ul>
      ) : null}
    </article>
  );
}

export function TranscriptPanel({
  projectPath,
  node,
  onClose,
  readPage = readTranscriptPage,
}: {
  projectPath: string;
  node: LoopNode;
  onClose(): void;
  readPage?: TranscriptPageReader;
}) {
  const identity = `${projectPath}\u0000${node.id}`;
  const [state, dispatch] = useReducer(
    transcriptHistoryReducer,
    identity,
    createTranscriptHistoryState,
  );
  const generationRef = useRef(0);
  const pendingCursorsRef = useRef(new Set<string>());
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({ onClose });

  const loadPage = useCallback(
    async (cursor?: string) => {
      const generation = generationRef.current;
      const cursorKey = `${generation}:${cursor ?? "__first__"}`;
      if (pendingCursorsRef.current.has(cursorKey)) return;
      pendingCursorsRef.current.add(cursorKey);
      dispatch({ type: "loadStarted", cursor });
      try {
        const page = await readPage(
          projectPath,
          node.id,
          cursor ?? null,
          PAGE_ENTRIES,
          PAGE_BYTES,
        );
        if (generation !== generationRef.current) return;
        if (page.nodeID !== node.id) {
          throw new Error("transcriptTransportFailure: node identity mismatch");
        }
        dispatch({ type: "pageLoaded", cursor, page });
      } catch (error) {
        if (generation !== generationRef.current) return;
        dispatch({
          type: "loadFailed",
          cursor,
          error: transcriptHistoryError(error),
        });
      } finally {
        pendingCursorsRef.current.delete(cursorKey);
      }
    },
    [node.id, projectPath, readPage],
  );

  useEffect(() => {
    generationRef.current += 1;
    pendingCursorsRef.current.clear();
    dispatch({ type: "reset", identity });
    void loadPage();
    return () => {
      generationRef.current += 1;
    };
  }, [identity, loadPage]);

  const provider = state.provider ?? node.backend;
  const statusText = state.loadingInitial
    ? "Loading session history."
    : state.loadingMore
      ? "Loading the next history page."
      : state.error
        ? state.error.title
        : state.entries.length
          ? `${state.entries.length} history entries loaded.`
          : "No history entries are available.";

  return (
    <div className="transcript-backdrop">
      <div
        ref={(element) => {
          dialogRef.current = element;
        }}
        className="transcript-panel"
        role="dialog"
        aria-modal="true"
        aria-labelledby="transcript-title"
        aria-describedby="transcript-redaction-policy"
        onKeyDown={handleDialogKeyDown}
      >
        <header className="transcript-panel-header">
          <div>
            <p className="eyebrow">Session history</p>
            <h2 id="transcript-title">{node.title}</h2>
            <p>{providerLabel(provider)}</p>
          </div>
          <button type="button" onClick={onClose} aria-label="Close history">
            ×
          </button>
        </header>

        <p id="transcript-redaction-policy" className="transcript-policy">
          This is a bounded, semantic transcript from graphcoded. Prompts,
          assistant text, tool inputs, tool results, paths, secrets, and model
          metadata may be withheld. Raw provider payloads are never shown.
        </p>

        <p className="sr-only" role="status" aria-live="polite">
          {statusText}
        </p>

        <div className="transcript-scroll">
          {state.loadingInitial ? (
            <div className="transcript-state" role="status">
              <strong>Loading session history</strong>
              <p>Requesting the first bounded page from graphcoded.</p>
            </div>
          ) : null}

          {!state.loadingInitial && !state.entries.length && !state.error ? (
            <div className="transcript-state">
              <strong>No history entries yet</strong>
              <p>
                The provider session may be new. Close history and return after
                the loop has produced transcript records.
              </p>
            </div>
          ) : null}

          {state.entries.length ? (
            <ol className="transcript-entries">
              {state.entries.map((entry) => (
                <li key={entry.sourceOffset}>
                  <TranscriptEntryView entry={entry} />
                </li>
              ))}
            </ol>
          ) : null}

          {state.error ? (
            <div
              className="transcript-state transcript-state-error"
              role="alert"
            >
              <strong>{state.error.title}</strong>
              <p>{state.error.message}</p>
              {state.error.kind !== "invalidCursor" ? (
                <button
                  type="button"
                  disabled={state.loadingInitial || state.loadingMore}
                  onClick={() =>
                    void loadPage(
                      state.entries.length ? state.nextCursor : undefined,
                    )
                  }
                >
                  Try again
                </button>
              ) : null}
            </div>
          ) : null}
        </div>

        {!state.error && state.hasMore && state.nextCursor ? (
          <footer className="transcript-panel-footer">
            <button
              type="button"
              disabled={state.loadingMore}
              onClick={() => void loadPage(state.nextCursor)}
            >
              {state.loadingMore ? "Loading more…" : "Load more history"}
            </button>
            <span>Pages remain bounded to 32 entries and 64 KiB.</span>
          </footer>
        ) : null}
      </div>
    </div>
  );
}
