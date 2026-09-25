import { useMemo, useRef, useState } from "react";
import {
  backendCanHost,
  backendOptions,
  buildNodeDraft,
  initialNewLoopForm,
  loopTypeOptions,
  validateNewLoop,
  type NewLoopErrors,
  type NewLoopFormState,
} from "../forms/newLoop";
import type { NodeDraftPayload } from "../protocol/commands";
import { useDialogFocus } from "./dialogFocus";

const stepNames = ["Shape", "Brief", "Execution", "Review"] as const;

function FieldError({
  id,
  message,
}: {
  id: string;
  message: string | undefined;
}) {
  return message ? (
    <span id={id} className="field-error">
      {message}
    </span>
  ) : null;
}

function inputProps(errors: NewLoopErrors, field: keyof NewLoopFormState) {
  return {
    "aria-invalid": Boolean(errors[field]),
    "aria-describedby": errors[field] ? `${field}-error` : undefined,
  } as const;
}

export function NewLoopDialog({
  projectName,
  onClose,
  onCreate,
}: {
  projectName: string;
  onClose(): void;
  onCreate(draft: NodeDraftPayload): Promise<void>;
}) {
  const [step, setStep] = useState(0);
  const [form, setForm] = useState<NewLoopFormState>(initialNewLoopForm);
  const [draftId] = useState(() => crypto.randomUUID());
  const [errors, setErrors] = useState<NewLoopErrors>({});
  const [submitError, setSubmitError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const titleRef = useRef<HTMLInputElement>(null);
  const dirty = useMemo(
    () => JSON.stringify(form) !== JSON.stringify(initialNewLoopForm),
    [form],
  );

  function update<K extends keyof NewLoopFormState>(
    field: K,
    value: NewLoopFormState[K],
  ) {
    setForm((current) => ({ ...current, [field]: value }));
    setErrors((current) => ({
      ...current,
      [field]: undefined,
      form: undefined,
    }));
    setSubmitError(undefined);
  }

  function requestClose() {
    if (
      submitting ||
      (dirty && !window.confirm("Discard this New Loop draft?"))
    ) {
      return;
    }
    onClose();
  }

  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: titleRef,
    onClose: requestClose,
  });

  function validateStep(targetStep: number): boolean {
    const nextErrors = validateNewLoop(form);
    const fieldsByStep: (keyof NewLoopFormState)[][] = [
      ["title", "loopType"],
      [
        "firstInstruction",
        "checkDescription",
        "triggerPrompt",
        "goalSummary",
        "goalPredicate",
      ],
      [
        "backend",
        "heartbeatIntervalSeconds",
        "pollIntervalSeconds",
        "stallAfterSeconds",
        "tokenBudget",
        "worktreeId",
        "worktreeRepositoryPath",
        "worktreePath",
        "worktreeBranch",
      ],
      Object.keys(form) as (keyof NewLoopFormState)[],
    ];
    const relevant = Object.fromEntries(
      Object.entries(nextErrors).filter(([field]) =>
        fieldsByStep[targetStep].includes(field as keyof NewLoopFormState),
      ),
    ) as NewLoopErrors;
    setErrors(relevant);
    return Object.keys(relevant).length === 0;
  }

  async function submit() {
    const nextErrors = validateNewLoop(form);
    setErrors(nextErrors);
    if (Object.keys(nextErrors).length) {
      setSubmitError(
        "Review the highlighted fields before creating this loop.",
      );
      return;
    }
    setSubmitting(true);
    setSubmitError(undefined);
    try {
      await onCreate(buildNodeDraft(form, draftId));
      onClose();
    } catch (error) {
      setSubmitError(error instanceof Error ? error.message : String(error));
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <div className="new-loop-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="new-loop-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="new-loop-title"
        onKeyDown={(event) => {
          if (handleDialogKeyDown(event)) return;
          if (event.ctrlKey && event.key === "Enter") {
            event.preventDefault();
            if (step === stepNames.length - 1) {
              void submit();
            } else if (validateStep(step)) {
              setStep((current) => current + 1);
            }
            return;
          }
        }}
      >
        <header className="new-loop-header">
          <div>
            <p className="eyebrow">Create in {projectName}</p>
            <h2 id="new-loop-title">New Loop</h2>
          </div>
          <button
            type="button"
            onClick={requestClose}
            aria-label="Close New Loop"
          >
            ×
          </button>
        </header>

        <ol className="new-loop-steps" aria-label="New Loop progress">
          {stepNames.map((name, index) => (
            <li
              key={name}
              className={
                index === step
                  ? "step-current"
                  : index < step
                    ? "step-complete"
                    : ""
              }
              aria-current={index === step ? "step" : undefined}
            >
              <span>{index + 1}</span>
              {name}
            </li>
          ))}
        </ol>

        <form
          className="new-loop-form"
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          {step === 0 ? (
            <fieldset className="form-section">
              <legend>Choose the loop shape</legend>
              <p className="form-help">
                The shape decides who starts the session and what ends or
                repeats it.
              </p>
              <div className="loop-type-grid">
                {loopTypeOptions.map((option) => (
                  <label
                    key={option.value}
                    className={
                      form.loopType === option.value ? "type-selected" : ""
                    }
                  >
                    <input
                      type="radio"
                      name="loopType"
                      value={option.value}
                      checked={form.loopType === option.value}
                      onChange={() => update("loopType", option.value)}
                    />
                    <strong>{option.label}</strong>
                    <span>{option.description}</span>
                  </label>
                ))}
              </div>
              <label className="form-field">
                <span>
                  Title
                  {form.loopType === "proactive"
                    ? " (required)"
                    : " (optional)"}
                </span>
                <input
                  ref={titleRef}
                  autoFocus
                  value={form.title}
                  onChange={(event) =>
                    update("title", event.currentTarget.value)
                  }
                  placeholder={
                    form.loopType === "proactive"
                      ? "Nightly quality routine"
                      : "GraphCode can suggest a title after launch"
                  }
                  {...inputProps(errors, "title")}
                />
                <FieldError id="title-error" message={errors.title} />
              </label>
            </fieldset>
          ) : null}

          {step === 1 ? (
            <fieldset className="form-section">
              <legend>Describe the work</legend>
              {form.loopType === "sketch" ? (
                <label className="form-field">
                  <span>Starting note (optional)</span>
                  <textarea
                    autoFocus
                    value={form.firstInstruction}
                    onChange={(event) =>
                      update("firstInstruction", event.currentTarget.value)
                    }
                    placeholder="What should the session know when it opens?"
                  />
                </label>
              ) : null}
              {form.loopType === "turnBased" ? (
                <>
                  <label className="form-field">
                    <span>First instruction</span>
                    <textarea
                      autoFocus
                      value={form.firstInstruction}
                      onChange={(event) =>
                        update("firstInstruction", event.currentTarget.value)
                      }
                      {...inputProps(errors, "firstInstruction")}
                    />
                    <FieldError
                      id="firstInstruction-error"
                      message={errors.firstInstruction}
                    />
                  </label>
                  <label className="form-field">
                    <span>Verify each turn (optional)</span>
                    <textarea
                      value={form.checkDescription}
                      onChange={(event) =>
                        update("checkDescription", event.currentTarget.value)
                      }
                      placeholder="What should the human check?"
                    />
                  </label>
                  <label className="check-field">
                    <input
                      type="checkbox"
                      checked={form.pausesBeforeWritesOnly}
                      onChange={(event) =>
                        update(
                          "pausesBeforeWritesOnly",
                          event.currentTarget.checked,
                        )
                      }
                    />
                    Pause only before changes to files or state
                  </label>
                </>
              ) : null}
              {form.loopType === "goalBased" ? (
                <>
                  <label className="form-field">
                    <span>Goal: what does done mean?</span>
                    <textarea
                      autoFocus
                      value={form.goalSummary}
                      onChange={(event) =>
                        update("goalSummary", event.currentTarget.value)
                      }
                      {...inputProps(errors, "goalSummary")}
                    />
                    <FieldError
                      id="goalSummary-error"
                      message={errors.goalSummary}
                    />
                  </label>
                  <label className="form-field">
                    <span>Predicate command (optional)</span>
                    <input
                      value={form.goalPredicate}
                      onChange={(event) =>
                        update("goalPredicate", event.currentTarget.value)
                      }
                      placeholder="Exit 0 when the goal is met"
                    />
                  </label>
                </>
              ) : null}
              {form.loopType === "timeBased" ? (
                <label className="form-field">
                  <span>Repeated task</span>
                  <textarea
                    autoFocus
                    value={form.triggerPrompt}
                    onChange={(event) =>
                      update("triggerPrompt", event.currentTarget.value)
                    }
                    placeholder="For session recurrence, include the backend's /loop or /every directive."
                    {...inputProps(errors, "triggerPrompt")}
                  />
                  <FieldError
                    id="triggerPrompt-error"
                    message={errors.triggerPrompt}
                  />
                </label>
              ) : null}
              {form.loopType === "proactive" ? (
                <label className="form-field">
                  <span>Intended schedule (optional)</span>
                  <input
                    autoFocus
                    value={form.triggerPrompt}
                    onChange={(event) =>
                      update("triggerPrompt", event.currentTarget.value)
                    }
                    placeholder="Recorded until the composite is piloted and armed"
                  />
                </label>
              ) : null}

              <div className="planned-capabilities">
                <div>
                  <strong>Templates</strong>
                  <span>
                    Disabled pending remote ownership investigation DT-005.
                  </span>
                </div>
                <button type="button" disabled>
                  Choose template
                </button>
                <div>
                  <strong>Attachments</strong>
                  <span>
                    Disabled pending secure native staging and DT-005.
                  </span>
                </div>
                <button type="button" disabled>
                  Add files
                </button>
              </div>
            </fieldset>
          ) : null}

          {step === 2 ? (
            <fieldset className="form-section">
              <legend>Configure execution</legend>
              <div className="form-grid">
                <label className="form-field">
                  <span>Backend</span>
                  <select
                    autoFocus
                    value={form.backend}
                    onChange={(event) =>
                      update(
                        "backend",
                        event.currentTarget
                          .value as NewLoopFormState["backend"],
                      )
                    }
                    {...inputProps(errors, "backend")}
                  >
                    <option value="">
                      Workspace default (Claude fallback)
                    </option>
                    {backendOptions.map((backend) => (
                      <option
                        key={backend.value}
                        value={backend.value}
                        disabled={
                          !backendCanHost(
                            backend.value,
                            form.loopType,
                            form.cadenceMode,
                          )
                        }
                      >
                        {backend.label}
                      </option>
                    ))}
                  </select>
                  <FieldError id="backend-error" message={errors.backend} />
                </label>
                <label className="form-field">
                  <span>Model tier</span>
                  <select
                    value={form.modelTier}
                    onChange={(event) =>
                      update(
                        "modelTier",
                        event.currentTarget
                          .value as NewLoopFormState["modelTier"],
                      )
                    }
                  >
                    <option value="">Agent / workspace default</option>
                    <option value="fast">Fast</option>
                    <option value="standard">Standard</option>
                    <option value="capable">Capable</option>
                  </select>
                </label>
              </div>

              {form.loopType === "timeBased" ? (
                <div className="form-subsection">
                  <h3>Recurrence</h3>
                  <label className="radio-field">
                    <input
                      type="radio"
                      name="cadenceMode"
                      checked={form.cadenceMode === "session"}
                      onChange={() => update("cadenceMode", "session")}
                    />
                    <span>
                      <strong>Session-owned</strong>
                      Use the directive included in the repeated-task prompt.
                      Supported by Claude Code and Copilot CLI.
                    </span>
                  </label>
                  <label className="radio-field">
                    <input
                      type="radio"
                      name="cadenceMode"
                      checked={form.cadenceMode === "daemon"}
                      onChange={() => update("cadenceMode", "daemon")}
                    />
                    <span>
                      <strong>Daemon heartbeat</strong>
                      Requires `daemonHeartbeatEnabled` in shared settings.
                    </span>
                  </label>
                  {form.cadenceMode === "daemon" ? (
                    <label className="form-field">
                      <span>Heartbeat interval (seconds)</span>
                      <input
                        inputMode="decimal"
                        value={form.heartbeatIntervalSeconds}
                        onChange={(event) =>
                          update(
                            "heartbeatIntervalSeconds",
                            event.currentTarget.value,
                          )
                        }
                        {...inputProps(errors, "heartbeatIntervalSeconds")}
                      />
                      <FieldError
                        id="heartbeatIntervalSeconds-error"
                        message={errors.heartbeatIntervalSeconds}
                      />
                    </label>
                  ) : null}
                </div>
              ) : null}

              {form.loopType === "goalBased" ? (
                <div className="form-subsection">
                  <h3>Goal monitoring</h3>
                  <div className="form-grid">
                    <label className="form-field">
                      <span>Poll interval (seconds)</span>
                      <input
                        inputMode="decimal"
                        value={form.pollIntervalSeconds}
                        onChange={(event) =>
                          update(
                            "pollIntervalSeconds",
                            event.currentTarget.value,
                          )
                        }
                        {...inputProps(errors, "pollIntervalSeconds")}
                      />
                      <FieldError
                        id="pollIntervalSeconds-error"
                        message={errors.pollIntervalSeconds}
                      />
                    </label>
                    <label className="form-field">
                      <span>Stall after seconds (optional)</span>
                      <input
                        inputMode="decimal"
                        value={form.stallAfterSeconds}
                        onChange={(event) =>
                          update("stallAfterSeconds", event.currentTarget.value)
                        }
                        {...inputProps(errors, "stallAfterSeconds")}
                      />
                      <FieldError
                        id="stallAfterSeconds-error"
                        message={errors.stallAfterSeconds}
                      />
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
                            event.currentTarget
                              .value as NewLoopFormState["metricDirection"],
                          )
                        }
                      >
                        <option value="maximize">Higher is better</option>
                        <option value="minimize">Lower is better</option>
                      </select>
                    </label>
                    <label className="form-field">
                      <span>Token budget (optional)</span>
                      <input
                        inputMode="numeric"
                        value={form.tokenBudget}
                        onChange={(event) =>
                          update("tokenBudget", event.currentTarget.value)
                        }
                        {...inputProps(errors, "tokenBudget")}
                      />
                      <FieldError
                        id="tokenBudget-error"
                        message={errors.tokenBudget}
                      />
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
                    Skip repeated predicate checks while the workspace is
                    unchanged
                  </label>
                </div>
              ) : null}

              <div className="form-subsection">
                <h3>Worktree</h3>
                <label className="check-field">
                  <input
                    type="checkbox"
                    checked={form.bindWorktree}
                    onChange={(event) =>
                      update("bindWorktree", event.currentTarget.checked)
                    }
                  />
                  Bind an existing worktree
                </label>
                {form.bindWorktree ? (
                  <div className="form-grid worktree-fields">
                    {[
                      ["worktreeId", "Worktree ID"],
                      ["worktreeBranch", "Branch"],
                      ["worktreeRepositoryPath", "Repository path"],
                      ["worktreePath", "Worktree path"],
                    ].map(([field, label]) => {
                      const key = field as
                        | "worktreeId"
                        | "worktreeBranch"
                        | "worktreeRepositoryPath"
                        | "worktreePath";
                      return (
                        <label className="form-field" key={key}>
                          <span>{label}</span>
                          <input
                            value={form[key]}
                            onChange={(event) =>
                              update(key, event.currentTarget.value)
                            }
                            {...inputProps(errors, key)}
                          />
                          <FieldError
                            id={`${key}-error`}
                            message={errors[key]}
                          />
                        </label>
                      );
                    })}
                  </div>
                ) : null}
              </div>
            </fieldset>
          ) : null}

          {step === 3 ? (
            <fieldset className="form-section review-section">
              <legend>Review the loop</legend>
              <dl>
                <div>
                  <dt>Project</dt>
                  <dd>{projectName}</dd>
                </div>
                <div>
                  <dt>Shape</dt>
                  <dd>
                    {
                      loopTypeOptions.find(
                        (option) => option.value === form.loopType,
                      )?.label
                    }
                  </dd>
                </div>
                <div>
                  <dt>Title</dt>
                  <dd>{form.title.trim() || "NewNode (daemon fallback)"}</dd>
                </div>
                <div>
                  <dt>Backend</dt>
                  <dd>
                    {backendOptions.find(
                      (option) => option.value === form.backend,
                    )?.label ?? "Workspace default"}
                  </dd>
                </div>
                <div>
                  <dt>Model</dt>
                  <dd>{form.modelTier || "Agent default"}</dd>
                </div>
                <div>
                  <dt>Worktree</dt>
                  <dd>
                    {form.bindWorktree
                      ? `${form.worktreeBranch} — ${form.worktreePath}`
                      : "Project root"}
                  </dd>
                </div>
                <div>
                  <dt>Attachments</dt>
                  <dd>None — DT-005 is not implemented</dd>
                </div>
                <div>
                  <dt>Template</dt>
                  <dd>Snapshot without template — DT-005 is not implemented</dd>
                </div>
              </dl>
              <p className="review-note">
                GraphCode will wait for graphcoded to accept the typed
                `createNode(NodeDraft)` request. The graph changes only when the
                authoritative snapshot arrives.
              </p>
            </fieldset>
          ) : null}

          {submitError ? (
            <div
              className="form-error-summary"
              role="alert"
              aria-live="assertive"
            >
              {submitError}
            </div>
          ) : null}

          <footer className="new-loop-footer">
            <span>Ctrl+Enter continues or creates · Esc cancels</span>
            <div>
              {step > 0 ? (
                <button
                  type="button"
                  disabled={submitting}
                  onClick={() => {
                    setErrors({});
                    setStep((current) => current - 1);
                  }}
                >
                  Back
                </button>
              ) : null}
              {step < stepNames.length - 1 ? (
                <button
                  type="button"
                  className="primary-button"
                  onClick={() => {
                    if (validateStep(step)) setStep((current) => current + 1);
                  }}
                >
                  Continue
                </button>
              ) : (
                <button
                  type="submit"
                  className="primary-button"
                  disabled={submitting}
                >
                  {submitting ? "Creating…" : "Create Loop"}
                </button>
              )}
            </div>
          </footer>
        </form>
      </section>
    </div>
  );
}
