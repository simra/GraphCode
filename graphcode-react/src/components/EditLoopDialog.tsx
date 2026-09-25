import { useEffect, useRef, useState } from "react";
import {
  buildNodeUpdate,
  editLoopInitialState,
  validateEditLoop,
  type EditLoopErrors,
  type EditLoopFormState,
} from "../forms/editLoop";
import type { LoopNode } from "../protocol/domain";
import type { NodeUpdatePayload } from "../protocol/commands";

function FieldError({
  field,
  errors,
}: {
  field: keyof EditLoopFormState;
  errors: EditLoopErrors;
}) {
  return errors[field] ? (
    <span id={`edit-${field}-error`} className="field-error">
      {errors[field]}
    </span>
  ) : null;
}

function fieldProps(field: keyof EditLoopFormState, errors: EditLoopErrors) {
  return {
    "aria-invalid": Boolean(errors[field]),
    "aria-describedby": errors[field] ? `edit-${field}-error` : undefined,
  } as const;
}

export function EditLoopDialog({
  node,
  onClose,
  onSave,
}: {
  node: LoopNode;
  onClose(): void;
  onSave(update: NodeUpdatePayload): Promise<void>;
}) {
  const [form, setForm] = useState(() => editLoopInitialState(node));
  const [errors, setErrors] = useState<EditLoopErrors>({});
  const [submitError, setSubmitError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const dialogRef = useRef<HTMLElement>(null);
  const firstFieldRef = useRef<HTMLElement>(null);

  useEffect(() => {
    firstFieldRef.current?.focus();
  }, []);

  function update<K extends keyof EditLoopFormState>(
    field: K,
    value: EditLoopFormState[K],
  ) {
    setForm((current) => ({ ...current, [field]: value }));
    setErrors((current) => ({ ...current, [field]: undefined }));
    setSubmitError(undefined);
  }

  async function submit() {
    const nextErrors = validateEditLoop(node, form);
    setErrors(nextErrors);
    if (Object.keys(nextErrors).length) return;
    setSubmitting(true);
    setSubmitError(undefined);
    try {
      await onSave(buildNodeUpdate(node, form));
      onClose();
    } catch (error) {
      setSubmitError(error instanceof Error ? error.message : String(error));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="modal-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="edit-loop-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="edit-loop-title"
        onKeyDown={(event) => {
          if (event.key === "Escape" && !submitting) {
            event.preventDefault();
            onClose();
          } else if (event.ctrlKey && event.key === "Enter" && !submitting) {
            event.preventDefault();
            void submit();
          } else if (event.key === "Tab") {
            const focusable = [
              ...(dialogRef.current?.querySelectorAll<HTMLElement>(
                'button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), [tabindex="0"]',
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
            <p className="eyebrow">Supported live fields</p>
            <h2 id="edit-loop-title">Edit {node.title}</h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close loop editor"
          >
            ×
          </button>
        </header>
        <div className="edit-loop-scroll">
          <p className="form-note">
            Loop type, backend, worktree, initial instruction, attachments and
            template source are immutable after creation.
          </p>

          {node.loopType === "goalBased" ? (
            <fieldset className="form-section">
              <legend>Goal and monitoring</legend>
              <label className="form-field">
                <span>Goal summary</span>
                <textarea
                  ref={(element) => {
                    firstFieldRef.current = element;
                  }}
                  value={form.goalSummary}
                  onChange={(event) =>
                    update("goalSummary", event.currentTarget.value)
                  }
                  {...fieldProps("goalSummary", errors)}
                />
                <FieldError field="goalSummary" errors={errors} />
              </label>
              <label className="form-field">
                <span>Predicate command (optional)</span>
                <input
                  value={form.goalPredicate}
                  onChange={(event) =>
                    update("goalPredicate", event.currentTarget.value)
                  }
                />
              </label>
              <div className="form-grid">
                <label className="form-field">
                  <span>Poll interval (seconds)</span>
                  <input
                    inputMode="decimal"
                    value={form.pollIntervalSeconds}
                    onChange={(event) =>
                      update("pollIntervalSeconds", event.currentTarget.value)
                    }
                    {...fieldProps("pollIntervalSeconds", errors)}
                  />
                  <FieldError field="pollIntervalSeconds" errors={errors} />
                </label>
                <label className="form-field">
                  <span>Stall after seconds (blank clears)</span>
                  <input
                    inputMode="decimal"
                    value={form.stallAfterSeconds}
                    onChange={(event) =>
                      update("stallAfterSeconds", event.currentTarget.value)
                    }
                    {...fieldProps("stallAfterSeconds", errors)}
                  />
                  <FieldError field="stallAfterSeconds" errors={errors} />
                </label>
                <label className="form-field">
                  <span>Metric command (optional)</span>
                  <input
                    value={form.metricCommand}
                    onChange={(event) =>
                      update("metricCommand", event.currentTarget.value)
                    }
                  />
                </label>
                <label className="form-field">
                  <span>Metric direction</span>
                  <select
                    value={form.metricDirection}
                    onChange={(event) =>
                      update(
                        "metricDirection",
                        event.currentTarget.value as "minimize" | "maximize",
                      )
                    }
                  >
                    <option value="maximize">Maximize</option>
                    <option value="minimize">Minimize</option>
                  </select>
                </label>
                <label className="form-field">
                  <span>Token budget (blank clears)</span>
                  <input
                    inputMode="numeric"
                    value={form.tokenBudget}
                    onChange={(event) =>
                      update("tokenBudget", event.currentTarget.value)
                    }
                    {...fieldProps("tokenBudget", errors)}
                  />
                  <FieldError field="tokenBudget" errors={errors} />
                </label>
              </div>
              <label className="check-field">
                <input
                  type="checkbox"
                  checked={form.skipsUnchangedWorkspace}
                  onChange={(event) =>
                    update(
                      "skipsUnchangedWorkspace",
                      event.currentTarget.checked,
                    )
                  }
                />
                Skip predicate checks when the workspace has not changed
              </label>
            </fieldset>
          ) : null}

          {node.loopType === "timeBased" ? (
            <fieldset className="form-section">
              <legend>Timed execution</legend>
              <label className="form-field">
                <span>Repeated prompt</span>
                <textarea
                  ref={(element) => {
                    firstFieldRef.current = element;
                  }}
                  value={form.triggerPrompt}
                  onChange={(event) =>
                    update("triggerPrompt", event.currentTarget.value)
                  }
                  {...fieldProps("triggerPrompt", errors)}
                />
                <FieldError field="triggerPrompt" errors={errors} />
              </label>
              <label className="form-field">
                <span>Daemon heartbeat seconds (blank clears)</span>
                <input
                  inputMode="decimal"
                  value={form.heartbeatIntervalSeconds}
                  onChange={(event) =>
                    update(
                      "heartbeatIntervalSeconds",
                      event.currentTarget.value,
                    )
                  }
                  {...fieldProps("heartbeatIntervalSeconds", errors)}
                />
                <FieldError field="heartbeatIntervalSeconds" errors={errors} />
              </label>
            </fieldset>
          ) : null}

          {node.loopType === "turnBased" ? (
            <fieldset className="form-section">
              <legend>Turn review</legend>
              <label className="form-field">
                <span>Check description (blank clears)</span>
                <textarea
                  ref={(element) => {
                    firstFieldRef.current = element;
                  }}
                  value={form.checkDescription}
                  onChange={(event) =>
                    update("checkDescription", event.currentTarget.value)
                  }
                />
              </label>
            </fieldset>
          ) : null}

          <fieldset className="form-section">
            <legend>Next launch</legend>
            <label className="form-field">
              <span>Model tier</span>
              <select
                ref={(element) => {
                  if (node.loopType === "sketch") {
                    firstFieldRef.current = element;
                  }
                }}
                value={form.modelTier}
                onChange={(event) =>
                  update(
                    "modelTier",
                    event.currentTarget.value as EditLoopFormState["modelTier"],
                  )
                }
              >
                <option value="">Keep agent/default routing</option>
                <option value="fast">Fast</option>
                <option value="standard">Standard</option>
                <option value="capable">Capable</option>
              </select>
            </label>
          </fieldset>
        </div>
        {submitError ? (
          <p className="field-error edit-loop-submit-error" role="alert">
            {submitError}
          </p>
        ) : null}
        <footer>
          <span>Ctrl+Enter to save</span>
          <div>
            <button type="button" disabled={submitting} onClick={onClose}>
              Cancel
            </button>
            <button
              className="primary-button"
              type="button"
              disabled={submitting}
              onClick={() => void submit()}
            >
              {submitting ? "Saving…" : "Save changes"}
            </button>
          </div>
        </footer>
      </section>
    </div>
  );
}
