import { useEffect, useRef, useState } from "react";
import type { LoopNode } from "../protocol/domain";
import type {
  EdgeConditionPayload,
  EdgeKindPayload,
  EdgeSpecPayload,
} from "../protocol/commands";

export function NewEdgeDialog({
  nodes,
  initialFrom,
  onClose,
  onCreate,
}: {
  nodes: LoopNode[];
  initialFrom?: string;
  onClose(): void;
  onCreate(from: string, to: string, spec: EdgeSpecPayload): Promise<void>;
}) {
  const initialSource = initialFrom ?? nodes[0]?.id ?? "";
  const [from, setFrom] = useState(initialSource);
  const [to, setTo] = useState(
    nodes.find((node) => node.id !== initialSource)?.id ?? "",
  );
  const [kind, setKind] = useState<EdgeKindPayload>("handoff");
  const [condition, setCondition] = useState<EdgeConditionPayload>("always");
  const [transform, setTransform] = useState<"none" | "template" | "script">(
    "none",
  );
  const [transformText, setTransformText] = useState("");
  const [maxIterations, setMaxIterations] = useState("");
  const [until, setUntil] = useState("");
  const [plateauPasses, setPlateauPasses] = useState("");
  const [spawnPath, setSpawnPath] = useState("");
  const [error, setError] = useState<string>();
  const [submitting, setSubmitting] = useState(false);
  const dialogRef = useRef<HTMLElement>(null);
  const firstRef = useRef<HTMLSelectElement>(null);

  useEffect(() => {
    firstRef.current?.focus();
  }, []);

  function positiveInteger(value: string, label: string) {
    if (!value.trim()) return null;
    const parsed = Number(value);
    if (!Number.isInteger(parsed) || parsed <= 0) {
      throw new Error(`${label} must be a positive integer.`);
    }
    return parsed;
  }

  async function submit() {
    try {
      if (!from || !to) throw new Error("Choose both endpoint loops.");
      if (from === to)
        throw new Error("An edge cannot connect a loop to itself.");
      const text = transformText.trim();
      if (transform !== "none" && !text) {
        throw new Error("Template or script text is required.");
      }
      const max = positiveInteger(maxIterations, "Maximum iterations");
      const plateau = positiveInteger(
        plateauPasses,
        "Passes without improvement",
      );
      const untilCommand = until.trim() || null;
      const cycleGuard =
        max !== null || plateau !== null || untilCommand
          ? {
              maxIterations: max,
              until: untilCommand,
              stopAfterPassesWithoutImprovement: plateau,
            }
          : null;
      const payloadTransform =
        transform === "none"
          ? ({ none: {} } as const)
          : transform === "template"
            ? ({ template: { _0: text } } as const)
            : ({ script: { _0: text } } as const);
      setSubmitting(true);
      setError(undefined);
      await onCreate(from, to, {
        kind,
        condition,
        payloadTransform,
        cycleGuard,
        spawnTargetProjectPath:
          kind === "spawn" ? spawnPath.trim() || null : null,
      });
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
        aria-labelledby="new-edge-title"
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
                'button:not(:disabled), input:not(:disabled), select:not(:disabled), [tabindex="0"]',
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
            <p className="eyebrow">Graph connection</p>
            <h2 id="new-edge-title">Create edge</h2>
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
              ref={firstRef}
              value={from}
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
            {submitting ? "Creating…" : "Create edge"}
          </button>
        </footer>
      </section>
    </div>
  );
}
