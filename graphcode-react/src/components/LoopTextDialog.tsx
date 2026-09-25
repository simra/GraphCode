import { useRef, useState } from "react";
import { useDialogFocus } from "./dialogFocus";

export function LoopTextDialog({
  title,
  description,
  label,
  initialValue = "",
  multiline = false,
  required = false,
  submitLabel,
  onClose,
  onSubmit,
}: {
  title: string;
  description: string;
  label: string;
  initialValue?: string;
  multiline?: boolean;
  required?: boolean;
  submitLabel: string;
  onClose(): void;
  onSubmit(value: string): Promise<void>;
}) {
  const [value, setValue] = useState(initialValue);
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const inputRef = useRef<HTMLInputElement & HTMLTextAreaElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: inputRef,
    onClose,
    selectInitial: true,
  });

  async function submit() {
    const trimmed = value.trim();
    if (required && !trimmed) {
      setError(`${label} is required.`);
      return;
    }
    setSubmitting(true);
    setError(undefined);
    try {
      await onSubmit(trimmed);
      onClose();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSubmitting(false);
    }
  }

  const fieldProps = {
    ref: inputRef,
    value,
    "aria-invalid": Boolean(error),
    "aria-describedby": error ? "loop-text-dialog-error" : undefined,
    onChange: (
      event: React.ChangeEvent<HTMLInputElement | HTMLTextAreaElement>,
    ) => {
      setValue(event.currentTarget.value);
      setError(undefined);
    },
  };

  return (
    <div className="modal-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="text-command-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="loop-text-dialog-title"
        onKeyDown={(event) => {
          if (handleDialogKeyDown(event)) return;
          if (
            event.key === "Enter" &&
            (!multiline || event.ctrlKey) &&
            !submitting
          ) {
            event.preventDefault();
            void submit();
          }
        }}
      >
        <header>
          <div>
            <p className="eyebrow">Loop action</p>
            <h2 id="loop-text-dialog-title">{title}</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label={`Close ${title}`}
          >
            ×
          </button>
        </header>
        <p>{description}</p>
        <label className="form-field">
          <span>{label}</span>
          {multiline ? (
            <textarea {...fieldProps} rows={5} />
          ) : (
            <input {...fieldProps} />
          )}
        </label>
        {error ? (
          <p id="loop-text-dialog-error" className="field-error" role="alert">
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
            {submitting ? "Working…" : submitLabel}
          </button>
        </footer>
      </section>
    </div>
  );
}
