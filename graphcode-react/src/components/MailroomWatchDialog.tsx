import { useEffect, useRef, useState } from "react";

type WatchMode = "off" | "all" | "topic";

export function MailroomWatchDialog({
  nodeTitle,
  currentTopic,
  watching,
  onClose,
  onSave,
}: {
  nodeTitle: string;
  currentTopic?: string;
  watching: boolean;
  onClose(): void;
  onSave(on: boolean, topic: string | null): Promise<void>;
}) {
  const [mode, setMode] = useState<WatchMode>(
    watching ? (currentTopic ? "topic" : "all") : "off",
  );
  const [topic, setTopic] = useState(currentTopic ?? "");
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const dialogRef = useRef<HTMLElement>(null);
  const firstControlRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    firstControlRef.current?.focus();
  }, []);

  async function submit() {
    const trimmed = topic.trim();
    if (mode === "topic" && !trimmed) {
      setError("A topic is required for a topic-only watch.");
      return;
    }
    if (new TextEncoder().encode(trimmed).length > 64) {
      setError("Topics are limited to 64 UTF-8 bytes.");
      return;
    }
    setSubmitting(true);
    setError(undefined);
    try {
      await onSave(mode !== "off", mode === "topic" ? trimmed : null);
      onClose();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="text-command-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="mailroom-watch-title"
        onKeyDown={(event) => {
          if (event.key === "Escape" && !submitting) {
            event.preventDefault();
            onClose();
          } else if (event.key === "Enter" && !submitting) {
            event.preventDefault();
            void submit();
          } else if (event.key === "Tab") {
            const focusable = [
              ...(dialogRef.current?.querySelectorAll<HTMLElement>(
                'button:not(:disabled), input:not(:disabled), [tabindex="0"]',
              ) ?? []),
            ];
            if (!focusable.length) return;
            const first = focusable[0];
            const last = focusable.at(-1)!;
            if (event.shiftKey && document.activeElement === first) {
              event.preventDefault();
              last.focus();
            } else if (!event.shiftKey && document.activeElement === last) {
              event.preventDefault();
              first.focus();
            }
          }
        }}
      >
        <header>
          <div>
            <p className="eyebrow">Mailroom subscription</p>
            <h2 id="mailroom-watch-title">Watch for {nodeTitle}</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close Mailroom watch"
          >
            ×
          </button>
        </header>
        <p>
          Matching posts are delivered to this loop when its session can receive
          them. graphcoded owns and confirms the subscription.
        </p>
        <fieldset className="mailroom-watch-options">
          <legend>Watch scope</legend>
          <label className="radio-field">
            <input
              ref={firstControlRef}
              type="radio"
              name="mailroom-watch"
              checked={mode === "off"}
              onChange={() => setMode("off")}
            />
            <span>
              <strong>Off</strong>
              Stop delivering Mailroom posts to this loop.
            </span>
          </label>
          <label className="radio-field">
            <input
              type="radio"
              name="mailroom-watch"
              checked={mode === "all"}
              onChange={() => setMode("all")}
            />
            <span>
              <strong>All posts</strong>
              Deliver every topic.
            </span>
          </label>
          <label className="radio-field">
            <input
              type="radio"
              name="mailroom-watch"
              checked={mode === "topic"}
              onChange={() => setMode("topic")}
            />
            <span>
              <strong>One topic</strong>
              Deliver only exact topic matches.
            </span>
          </label>
        </fieldset>
        {mode === "topic" ? (
          <label className="form-field">
            <span>Topic</span>
            <input
              value={topic}
              aria-invalid={Boolean(error)}
              aria-describedby={error ? "mailroom-watch-error" : undefined}
              onChange={(event) => {
                setTopic(event.currentTarget.value);
                setError(undefined);
              }}
            />
          </label>
        ) : null}
        {error ? (
          <p id="mailroom-watch-error" className="field-error" role="alert">
            {error}
          </p>
        ) : null}
        <footer>
          <button type="button" disabled={submitting} onClick={onClose}>
            Cancel
          </button>
          <button
            className="primary-button"
            type="button"
            disabled={submitting}
            onClick={() => void submit()}
          >
            {submitting ? "Saving…" : "Save watch"}
          </button>
        </footer>
      </section>
    </div>
  );
}
