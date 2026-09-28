import { useRef, useState } from "react";
import {
  buildSketchPromotion,
  promotionTargetForNode,
  sketchPromotionInitialState,
  validateSketchPromotion,
  type PromotionTarget,
  type SketchPromotionFormState,
} from "../forms/sketchPromotion";
import type { SketchPromotionPayload } from "../protocol/commands";
import type { LoopNode } from "../protocol/domain";
import { useDialogFocus } from "./dialogFocus";

const targetOptions: {
  value: PromotionTarget;
  label: string;
  description: string;
}[] = [
  {
    value: "goalBased",
    label: "Goal",
    description: "Work until a stated definition of done is met.",
  },
  {
    value: "turnBased",
    label: "Turn",
    description: "Pause for human review between turns.",
  },
  {
    value: "timeBased",
    label: "Timed",
    description: "Repeat the sketch's existing work on a cadence.",
  },
];

export function SketchPromotionDialog({
  node,
  onClose,
  onPromote,
}: {
  node: LoopNode;
  onClose(): void;
  onPromote(promotion: SketchPromotionPayload): Promise<void>;
}) {
  const [form, setForm] = useState<SketchPromotionFormState>(() =>
    sketchPromotionInitialState(node),
  );
  const [errors, setErrors] = useState<
    ReturnType<typeof validateSketchPromotion>
  >({});
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const firstRef = useRef<HTMLElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: firstRef,
    onClose,
  });

  function update(patch: Partial<SketchPromotionFormState>) {
    const next = { ...form, ...patch };
    setForm(next);
    setErrors(validateSketchPromotion(next));
    setError(undefined);
  }

  async function submit() {
    const nextErrors = validateSketchPromotion(form);
    setErrors(nextErrors);
    if (Object.keys(nextErrors).length) return;
    setSubmitting(true);
    setError(undefined);
    try {
      await onPromote(buildSketchPromotion(form));
      onClose();
    } catch (reason) {
      setError(reason instanceof Error ? reason.message : String(reason));
    } finally {
      setSubmitting(false);
    }
  }

  const retypeTarget = promotionTargetForNode(node);
  const retyping = retypeTarget !== undefined;
  const targetLabel =
    targetOptions.find((option) => option.value === form.target)?.label ??
    "Loop";
  const valid = Object.keys(validateSketchPromotion(form)).length === 0;

  return (
    <div className="modal-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="edit-loop-dialog promotion-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="promotion-dialog-title"
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
            <p className="eyebrow">Keep its identity, session, and edges</p>
            <h2 id="promotion-dialog-title">
              {retyping
                ? `Change ${node.title} to ${targetLabel}`
                : `Promote ${node.title}`}
            </h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close promotion dialog"
          >
            ×
          </button>
        </header>
        <div className="edit-loop-scroll">
          <fieldset className="form-section promotion-targets">
            <legend>
              {retyping ? `Change to ${targetLabel}` : "Choose a loop shape"}
            </legend>
            <p className="form-help">
              {retyping
                ? "This keeps the loop's identity, session, transcript, and edges."
                : "Promotion changes this sketch in place; it does not create a replacement loop."}
            </p>
            {!retyping ? (
              <div className="loop-type-grid">
                {targetOptions.map((option, index) => (
                  <label
                    key={option.value}
                    className={
                      form.target === option.value ? "type-selected" : undefined
                    }
                  >
                    <input
                      ref={(element) => {
                        if (index === 0) firstRef.current = element;
                      }}
                      type="radio"
                      name="promotion-target"
                      value={option.value}
                      checked={form.target === option.value}
                      onChange={() => update({ target: option.value })}
                    />
                    <strong>{option.label}</strong>
                    <span>{option.description}</span>
                  </label>
                ))}
              </div>
            ) : null}
            {form.target === "goalBased" ? (
              <label className="form-field">
                <span>What does done look like?</span>
                <textarea
                  ref={(element) => {
                    if (retyping) firstRef.current = element;
                  }}
                  value={form.goalSummary}
                  aria-invalid={Boolean(errors.goalSummary)}
                  aria-describedby={
                    errors.goalSummary ? "promotion-goal-error" : undefined
                  }
                  onChange={(event) =>
                    update({ goalSummary: event.currentTarget.value })
                  }
                />
                {errors.goalSummary ? (
                  <span
                    id="promotion-goal-error"
                    className="field-error"
                    role="alert"
                  >
                    {errors.goalSummary}
                  </span>
                ) : null}
              </label>
            ) : null}
            {form.target === "turnBased" ? (
              <fieldset className="form-subsection">
                <legend>Where should it pause?</legend>
                <label className="radio-field">
                  <input
                    type="radio"
                    name="promotion-pause"
                    checked={!form.pausesBeforeWritesOnly}
                    onChange={() => update({ pausesBeforeWritesOnly: false })}
                  />
                  <span>After every turn</span>
                </label>
                <label className="radio-field">
                  <input
                    type="radio"
                    name="promotion-pause"
                    checked={form.pausesBeforeWritesOnly}
                    onChange={() => update({ pausesBeforeWritesOnly: true })}
                  />
                  <span>Only before it writes files</span>
                </label>
              </fieldset>
            ) : null}
            {form.target === "timeBased" ? (
              <div className="form-subsection">
                {node.loopType === "goalBased" ? (
                  <label className="form-field">
                    <span>What should each pass do?</span>
                    <textarea
                      ref={(element) => {
                        firstRef.current = element;
                      }}
                      value={form.timedTask}
                      aria-invalid={Boolean(errors.timedTask)}
                      aria-describedby={
                        errors.timedTask
                          ? "promotion-timed-task-error"
                          : undefined
                      }
                      onChange={(event) =>
                        update({ timedTask: event.currentTarget.value })
                      }
                    />
                    {errors.timedTask ? (
                      <span
                        id="promotion-timed-task-error"
                        className="field-error"
                        role="alert"
                      >
                        {errors.timedTask}
                      </span>
                    ) : null}
                  </label>
                ) : null}
                <label className="form-field">
                  <span>Cadence</span>
                  <input
                    value={form.cadence}
                    placeholder="30m, 2h, 3d"
                    aria-invalid={Boolean(errors.cadence)}
                    aria-describedby={
                      errors.cadence ? "promotion-cadence-error" : undefined
                    }
                    onChange={(event) =>
                      update({ cadence: event.currentTarget.value })
                    }
                  />
                  {errors.cadence ? (
                    <span
                      id="promotion-cadence-error"
                      className="field-error"
                      role="alert"
                    >
                      {errors.cadence}
                    </span>
                  ) : null}
                </label>
                <p className="form-help">
                  GraphCode will send:{" "}
                  <code>
                    /loop {form.cadence.trim() || "…"}{" "}
                    {form.timedTask.trim() || "…"}
                  </code>
                </p>
              </div>
            ) : null}
            {error ? (
              <p className="field-error" role="alert">
                {error}
              </p>
            ) : null}
          </fieldset>
        </div>
        <footer>
          <span>Ctrl+Enter {retyping ? "changes" : "promotes"} this loop.</span>
          <div>
            <button type="button" disabled={submitting} onClick={onClose}>
              Cancel
            </button>
            <button
              className="primary-button"
              type="button"
              disabled={submitting || !valid}
              onClick={() => void submit()}
            >
              {submitting
                ? retyping
                  ? "Changing…"
                  : "Promoting…"
                : retyping
                  ? "Change"
                  : "Promote"}
            </button>
          </div>
        </footer>
      </section>
    </div>
  );
}
