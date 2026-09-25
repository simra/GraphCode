import { useRef, useState } from "react";
import { useDialogFocus } from "./dialogFocus";

export function MessageLoopDialog({
  nodeTitle,
  onClose,
  onSend,
}: {
  nodeTitle: string;
  onClose(): void;
  onSend(text: string, followUp: boolean): Promise<void>;
}) {
  const [text, setText] = useState("");
  const [followUp, setFollowUp] = useState(false);
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const textRef = useRef<HTMLTextAreaElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: textRef,
    onClose,
  });

  async function submit() {
    const trimmed = text.trim();
    if (!trimmed) {
      setError("Message text is required.");
      return;
    }
    setSubmitting(true);
    setError(undefined);
    try {
      await onSend(trimmed, followUp);
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
        aria-labelledby="message-loop-title"
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
            <p className="eyebrow">Loop communication</p>
            <h2 id="message-loop-title">Message {nodeTitle}</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close message composer"
          >
            ×
          </button>
        </header>
        <p>
          Immediate messages interrupt an available live session. Follow-ups are
          staged until the loop next becomes idle.
        </p>
        <label className="form-field">
          <span>Message</span>
          <textarea
            ref={textRef}
            rows={6}
            value={text}
            aria-invalid={Boolean(error)}
            aria-describedby={error ? "message-loop-error" : undefined}
            onChange={(event) => {
              setText(event.currentTarget.value);
              setError(undefined);
            }}
          />
        </label>
        <label className="check-field">
          <input
            type="checkbox"
            checked={followUp}
            onChange={(event) => setFollowUp(event.currentTarget.checked)}
          />
          Deliver when idle instead of interrupting
        </label>
        {error ? (
          <p id="message-loop-error" className="field-error" role="alert">
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
            {submitting
              ? "Sending…"
              : followUp
                ? "Queue follow-up"
                : "Send now"}
          </button>
        </footer>
      </section>
    </div>
  );
}
