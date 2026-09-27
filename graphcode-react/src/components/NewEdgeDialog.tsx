import { useRef, useState } from "react";
import {
  buildEdgeSpec,
  edgeSpecForm,
  edgeSpecFromSnapshot,
} from "../forms/edgeSpec";
import type { LoopEdge, LoopNode } from "../protocol/domain";
import type {
  EdgeConditionPayload,
  EdgeKindPayload,
  EdgeSpecPayload,
} from "../protocol/commands";
import { useDialogFocus } from "./dialogFocus";

export function NewEdgeDialog({
  nodes,
  initialFrom,
  initialTo,
  edge,
  onClose,
  onCreate,
  onUpdate,
}: {
  nodes: LoopNode[];
  initialFrom?: string;
  initialTo?: string;
  edge?: LoopEdge;
  onClose(): void;
  onCreate?(from: string, to: string, spec: EdgeSpecPayload): Promise<void>;
  onUpdate?(spec: EdgeSpecPayload): Promise<void>;
}) {
  const editing = Boolean(edge);
  const currentSpec = edge ? edgeSpecFromSnapshot(edge) : undefined;
  const initialForm = edgeSpecForm(currentSpec);
  const initialSource = edge?.from ?? initialFrom ?? nodes[0]?.id ?? "";
  const [from, setFrom] = useState(initialSource);
  const [to, setTo] = useState(
    edge?.to ??
      initialTo ??
      nodes.find((node) => node.id !== initialSource)?.id ??
      "",
  );
  const [kind, setKind] = useState<EdgeKindPayload>(initialForm.kind);
  const [condition, setCondition] = useState<EdgeConditionPayload>(
    initialForm.condition,
  );
  const [transform, setTransform] = useState<"none" | "template" | "script">(
    initialForm.transform,
  );
  const [transformText, setTransformText] = useState(initialForm.transformText);
  const [maxIterations, setMaxIterations] = useState(initialForm.maxIterations);
  const [until, setUntil] = useState(initialForm.until);
  const [plateauPasses, setPlateauPasses] = useState(initialForm.plateauPasses);
  const [spawnPath, setSpawnPath] = useState(initialForm.spawnPath);
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const firstRef = useRef<HTMLSelectElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    canClose: !submitting,
    initialFocusRef: firstRef,
    onClose,
  });

  async function submit() {
    try {
      if (!from || !to) throw new Error("Choose both endpoint loops.");
      if (from === to)
        throw new Error("An edge cannot connect a loop to itself.");
      const spec = buildEdgeSpec({
        kind,
        condition,
        transform,
        transformText,
        maxIterations,
        until,
        plateauPasses,
        spawnPath,
      });
      setSubmitting(true);
      setError(undefined);
      if (editing) {
        if (!onUpdate) throw new Error("Edge update is unavailable.");
        await onUpdate(spec);
      } else {
        if (!onCreate) throw new Error("Edge creation is unavailable.");
        await onCreate(from, to, spec);
      }
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
        className="edit-loop-dialog edge-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="edge-dialog-title"
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
            <p className="eyebrow">Graph connection</p>
            <h2 id="edge-dialog-title">
              {editing ? "Edit edge" : "Create edge"}
            </h2>
          </div>
          <button
            className="icon-button"
            type="button"
            disabled={submitting}
            onClick={onClose}
            aria-label="Close edge editor"
          >
            ×
          </button>
        </header>
        <div className="dialog-grid">
          <label className="form-field">
            <span>From</span>
            <select
              ref={!editing ? firstRef : undefined}
              value={from}
              disabled={editing}
              onChange={(event) => setFrom(event.currentTarget.value)}
            >
              {nodes.map((node) => (
                <option key={node.id} value={node.id}>
                  {node.title}
                </option>
              ))}
            </select>
          </label>
          <label className="form-field">
            <span>To</span>
            <select
              value={to}
              disabled={editing}
              onChange={(event) => setTo(event.currentTarget.value)}
            >
              {nodes.map((node) => (
                <option key={node.id} value={node.id}>
                  {node.title}
                </option>
              ))}
            </select>
          </label>
          <label className="form-field">
            <span>Kind</span>
            <select
              ref={editing ? firstRef : undefined}
              value={kind}
              onChange={(event) =>
                setKind(event.currentTarget.value as EdgeKindPayload)
              }
            >
              <option value="handoff">Handoff</option>
              <option value="message">Message</option>
              <option value="spawn">Spawn</option>
            </select>
          </label>
          <label className="form-field">
            <span>Condition</span>
            <select
              value={condition}
              onChange={(event) =>
                setCondition(event.currentTarget.value as EdgeConditionPayload)
              }
            >
              <option value="always">Always</option>
              <option value="onSuccess">On success</option>
              <option value="onFailure">On failure</option>
            </select>
          </label>
        </div>
        <details>
          <summary>Payload and cycle options</summary>
          <div className="dialog-grid">
            <label className="form-field">
              <span>Payload transform</span>
              <select
                value={transform}
                onChange={(event) =>
                  setTransform(
                    event.currentTarget.value as "none" | "template" | "script",
                  )
                }
              >
                <option value="none">None</option>
                <option value="template">Template</option>
                <option value="script">Script</option>
              </select>
            </label>
            {transform !== "none" ? (
              <label className="form-field">
                <span>{transform === "template" ? "Template" : "Command"}</span>
                <input
                  value={transformText}
                  onChange={(event) =>
                    setTransformText(event.currentTarget.value)
                  }
                />
              </label>
            ) : null}
            <label className="form-field">
              <span>Maximum iterations</span>
              <input
                inputMode="numeric"
                value={maxIterations}
                onChange={(event) =>
                  setMaxIterations(event.currentTarget.value)
                }
              />
            </label>
            <label className="form-field">
              <span>Until command succeeds</span>
              <input
                value={until}
                onChange={(event) => setUntil(event.currentTarget.value)}
              />
            </label>
            <label className="form-field">
              <span>Stop after flat passes</span>
              <input
                inputMode="numeric"
                value={plateauPasses}
                onChange={(event) =>
                  setPlateauPasses(event.currentTarget.value)
                }
              />
            </label>
            {kind === "spawn" ? (
              <label className="form-field">
                <span>Target project path (optional)</span>
                <input
                  value={spawnPath}
                  onChange={(event) => setSpawnPath(event.currentTarget.value)}
                />
              </label>
            ) : null}
          </div>
        </details>
        {error ? (
          <p className="field-error" role="alert">
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
            disabled={submitting || nodes.length < 2}
            onClick={() => void submit()}
          >
            {submitting
              ? editing
                ? "Saving…"
                : "Creating…"
              : editing
                ? "Save edge"
                : "Create edge"}
          </button>
        </footer>
      </section>
    </div>
  );
}
