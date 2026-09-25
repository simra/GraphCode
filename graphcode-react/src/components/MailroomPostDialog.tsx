import { useRef, useState } from "react";
import { useDialogFocus } from "./dialogFocus";

const encoder = new TextEncoder();

export function MailroomPostDialog({
  projectName,
  onClose,
  onPost,
}: {
  projectName: string;
  onClose(): void;
  onPost(body: string, topic: string | null): Promise<void>;
}) {
  const [topic, setTopic] = useState("");
  const [body, setBody] = useState("");
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const bodyRef = useRef<HTMLTextAreaElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: bodyRef,
    onClose,
  });

  async function submit() {
    const trimmedBody = body.trim();
    const trimmedTopic = topic.trim();
    if (!trimmedBody) {
      setError("Post body is required.");
      return;
    }
    if (encoder.encode(trimmedBody).length > 1024) {
      setError("Post body must be at most 1,024 UTF-8 bytes.");
      return;
    }
    if (encoder.encode(trimmedTopic).length > 64) {
      setError("Topic must be at most 64 UTF-8 bytes.");
      return;
    }
    setSubmitting(true);
    setError(undefined);
    try {
      await onPost(trimmedBody, trimmedTopic || null);
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
        aria-labelledby="mailroom-post-title"
        onKeyDown={(event) => {
          if (handleDialogKeyDown(event)) return;
          if (event.ctrlKey && event.key === "Enter" && !submitting) {
            event.preventDefault();
            void submit();
          }
        }}
      >
        <header>
          <div>
            <p className="eyebrow">Project Mailroom</p>
            <h2 id="mailroom-post-title">Post to {projectName}</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close Mailroom post composer"
          >
            ×
          </button>
        </header>
        <p>
          This durable note is visible to every loop in the project. It is not
          addressed to one loop.
        </p>
        <label className="form-field">
          <span>Topic (optional)</span>
          <input
            value={topic}
            onChange={(event) => {
              setTopic(event.currentTarget.value);
              setError(undefined);
            }}
          />
        </label>
        <label className="form-field">
          <span>Post</span>
          <textarea
            ref={bodyRef}
            rows={6}
            value={body}
            aria-invalid={Boolean(error)}
            aria-describedby={error ? "mailroom-post-error" : undefined}
            onChange={(event) => {
              setBody(event.currentTarget.value);
              setError(undefined);
            }}
          />
        </label>
        <small>{encoder.encode(body).length} / 1,024 UTF-8 bytes</small>
        {error ? (
          <p id="mailroom-post-error" className="field-error" role="alert">
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
            {submitting ? "Posting…" : "Post note"}
          </button>
        </footer>
      </section>
    </div>
  );
}
