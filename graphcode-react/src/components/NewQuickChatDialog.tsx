import { useRef, useState } from "react";
import type { DraftBackend } from "../protocol/commands";
import { useDialogFocus } from "./dialogFocus";

const backendOptions: Array<{ value: DraftBackend; label: string }> = [
  { value: "claudeCode", label: "Claude Code" },
  { value: "copilotCLI", label: "GitHub Copilot CLI" },
  { value: "codex", label: "Codex" },
  { value: "openCode", label: "OpenCode" },
  { value: "pi", label: "pi" },
];

export function NewQuickChatDialog({
  onClose,
  onCreate,
}: {
  onClose(): void;
  onCreate(title: string, backend: DraftBackend): Promise<void>;
}) {
  const [title, setTitle] = useState("");
  const [backend, setBackend] = useState<DraftBackend>("claudeCode");
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const titleRef = useRef<HTMLInputElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: titleRef,
    onClose,
  });

  async function submit() {
    const trimmed = title.trim();
    if (!trimmed) {
      setError("Chat title is required.");
      return;
    }
    setSubmitting(true);
    setError(undefined);
    try {
      await onCreate(trimmed, backend);
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
        aria-labelledby="new-quick-chat-title"
        onKeyDown={(event) => {
          if (handleDialogKeyDown(event)) return;
          if (event.key === "Enter" && !submitting) {
            event.preventDefault();
            void submit();
          }
        }}
      >
        <header>
          <div>
            <p className="eyebrow">Ad-hoc session</p>
            <h2 id="new-quick-chat-title">New Quick Chat</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close New Quick Chat"
          >
            ×
          </button>
        </header>
        <p>
          Create a bare conversation with no goal, trigger, or project graph.
          The selected backend is fixed for the lifetime of the chat.
        </p>
        <label className="form-field">
          <span>Chat title</span>
          <input
            ref={titleRef}
            value={title}
            required
            aria-invalid={Boolean(error)}
            aria-describedby={error ? "new-quick-chat-error" : undefined}
            onChange={(event) => {
              setTitle(event.currentTarget.value);
              setError(undefined);
            }}
          />
        </label>
        <label className="form-field">
          <span>Backend</span>
          <select
            value={backend}
            onChange={(event) =>
              setBackend(event.currentTarget.value as DraftBackend)
            }
          >
            {backendOptions.map((option) => (
              <option key={option.value} value={option.value}>
                {option.label}
              </option>
            ))}
          </select>
        </label>
        {error ? (
          <p id="new-quick-chat-error" className="field-error" role="alert">
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
            {submitting ? "Creating…" : "Create and open"}
          </button>
        </footer>
      </section>
    </div>
  );
}
