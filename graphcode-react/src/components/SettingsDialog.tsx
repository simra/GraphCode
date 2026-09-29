import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  type FormEvent,
} from "react";
import {
  loadSettings,
  listenForSettingsChanges,
  settingsBridgeError,
  settingsTiming,
  updateSettings,
  type SettingsSnapshot,
} from "../bridge/settings";
import {
  changedSettingsFields,
  copilotInstallCommand,
  graphcodeSettingsSchema,
  rebaseSettingsDraft,
  validateSettingsDraft,
  type EditableSettingsField,
  type GraphcodeSettings,
  type SettingsValidationErrors,
} from "../forms/settingsForm";
import { useDialogFocus } from "./dialogFocus";

const backendOptions = [
  ["claudeCode", "Claude Code"],
  ["copilotCLI", "Copilot CLI"],
  ["codex", "Codex"],
  ["openCode", "OpenCode"],
  ["pi", "Pi"],
] as const;
const modelOptions = [
  ["fast", "Fast"],
  ["standard", "Standard"],
  ["capable", "Capable"],
] as const;
const claudeOptions = [
  ["manual", "Ask every time"],
  ["acceptEdits", "Accept file edits"],
  ["auto", "Auto (recommended)"],
  ["dontAsk", "Don't ask"],
  ["bypassPermissions", "Bypass all checks"],
] as const;
const copilotOptions = [
  ["ask", "Ask every time"],
  ["allowTools", "Allow tools only"],
  ["allowEverything", "YOLO (recommended)"],
  ["yoloAutopilot", "YOLO + Autopilot"],
] as const;
const codexOptions = [
  ["ask", "Ask when unsure"],
  ["workspace", "Workspace (recommended)"],
  ["unsandboxed", "No sandbox"],
  ["yolo", "YOLO (recommended)"],
] as const;
const openCodeOptions = [
  ["ask", "Ask every time"],
  ["auto", "Auto-approve (recommended)"],
] as const;
const piOptions = [
  ["approve", "Trust the project (recommended)"],
  ["ask", "Ask every time"],
] as const;

const claudeExplanations: Record<string, string> = {
  manual:
    "The CLI default. An unattended loop waits at the first permission prompt.",
  acceptEdits: "File edits proceed; other tools still ask.",
  auto: "Approves ordinary coding work while retaining provider guardrails.",
  dontAsk: "Stops asking without removing Claude Code's checks.",
  bypassPermissions:
    "Skips every Claude Code permission check. A loop can do anything you can.",
};
const copilotExplanations: Record<string, string> = {
  ask: "The provider default. An unattended loop can wait for a prompt nobody sees.",
  allowTools:
    "Tools proceed, but URLs and paths beyond granted directories can still prompt.",
  allowEverything:
    "Copilot --yolo approves tools, paths, and URLs for unattended work.",
  yoloAutopilot:
    "YOLO permissions plus Copilot --autopilot continuing past its first reply.",
};
const codexExplanations: Record<string, string> = {
  ask: "The provider default. An unattended loop can wait for a prompt nobody sees.",
  workspace:
    "Codex runs without asking and may write inside the provided workspace.",
  unsandboxed: "Codex skips approvals and its sandbox entirely.",
  yolo: "Codex bypasses approvals and its sandbox entirely.",
};
const openCodeExplanations: Record<string, string> = {
  ask: "The provider default. An unattended loop can wait for a prompt nobody sees.",
  auto: "OpenCode --auto approves everything not denied by your own opencode.json.",
};
const piExplanations: Record<string, string> = {
  approve:
    "Pi trusts project-local extensions, skills, and settings without a startup prompt.",
  ask: "Pi asks whether to trust project-local resources when the session starts.",
};

const clientUnsupported: Partial<Record<EditableSettingsField, string>> = {
  showsActivityStrip:
    "The activity strip is not implemented in the Tauri client yet. The saved value is shown but cannot be changed here.",
  betaUpdates:
    "The beta update channel is currently consumed by the macOS updater, not the Tauri client.",
  keepsMacAwakeWhileLoopsRun:
    "This setting controls the macOS idle-sleep assertion and is not available on Windows.",
  worktreePolicies:
    "Worktree policies require a project-scoped editor. Existing policies are preserved unchanged.",
};

function effectLabel(snapshot: SettingsSnapshot, field: string) {
  switch (settingsTiming(snapshot, field)) {
    case "live":
      return "Live";
    case "nextLoop":
      return "New loops";
    case "nextSession":
      return "Next session";
    case "appRestart":
      return "App restart";
    case "daemonRestart":
      return "Daemon restart";
    default:
      return "Unavailable";
  }
}

function fieldUnavailableReason(
  snapshot: SettingsSnapshot,
  field: EditableSettingsField,
) {
  return (
    clientUnsupported[field] ??
    (!snapshot.fields.some((entry) => entry.field === field)
      ? "The connected daemon does not advertise this setting."
      : undefined)
  );
}

function SettingFrame({
  snapshot,
  field,
  label,
  description,
  children,
}: {
  snapshot: SettingsSnapshot;
  field: EditableSettingsField;
  label: string;
  description: string;
  children: React.ReactNode;
}) {
  const unavailable = fieldUnavailableReason(snapshot, field);
  const descriptionId = `settings-${field}-description`;
  return (
    <div
      className={`settings-field${unavailable ? " settings-field-disabled" : ""}`}
      data-setting={field}
    >
      <div className="settings-field-heading">
        <label htmlFor={`settings-${field}`}>{label}</label>
        <span className="settings-effect">{effectLabel(snapshot, field)}</span>
      </div>
      <div className="settings-control">{children}</div>
      <p id={descriptionId}>{unavailable ?? description}</p>
    </div>
  );
}

function SelectSetting({
  snapshot,
  field,
  label,
  description,
  value,
  options,
  onChange,
  inputRef,
}: {
  snapshot: SettingsSnapshot;
  field: EditableSettingsField;
  label: string;
  description: string;
  value: string;
  options: readonly (readonly [string, string])[];
  onChange(value: string): void;
  inputRef?: React.Ref<HTMLSelectElement>;
}) {
  const unavailable = fieldUnavailableReason(snapshot, field);
  return (
    <SettingFrame
      snapshot={snapshot}
      field={field}
      label={label}
      description={description}
    >
      <select
        ref={inputRef}
        id={`settings-${field}`}
        value={value}
        disabled={Boolean(unavailable)}
        aria-describedby={`settings-${field}-description`}
        onChange={(event) => onChange(event.currentTarget.value)}
      >
        {options.map(([optionValue, optionLabel]) => (
          <option key={optionValue} value={optionValue}>
            {optionLabel}
          </option>
        ))}
      </select>
    </SettingFrame>
  );
}

function ToggleSetting({
  snapshot,
  field,
  label,
  description,
  checked,
  disabled = false,
  onChange,
}: {
  snapshot: SettingsSnapshot;
  field: EditableSettingsField;
  label: string;
  description: string;
  checked: boolean;
  disabled?: boolean;
  onChange(value: boolean): void;
}) {
  const unavailable = fieldUnavailableReason(snapshot, field);
  return (
    <SettingFrame
      snapshot={snapshot}
      field={field}
      label={label}
      description={description}
    >
      <input
        id={`settings-${field}`}
        type="checkbox"
        checked={checked}
        disabled={disabled || Boolean(unavailable)}
        aria-describedby={`settings-${field}-description`}
        onChange={(event) => onChange(event.currentTarget.checked)}
      />
    </SettingFrame>
  );
}

export function SettingsEditor({
  snapshot,
  draft,
  errors,
  firstControlRef,
  enteringCopilotVersion,
  onEnteringCopilotVersionChange,
  onChange,
}: {
  snapshot: SettingsSnapshot;
  draft: GraphcodeSettings;
  errors: SettingsValidationErrors;
  firstControlRef?: React.Ref<HTMLSelectElement>;
  enteringCopilotVersion: boolean;
  onEnteringCopilotVersionChange(value: boolean): void;
  onChange<K extends EditableSettingsField>(
    field: K,
    value: GraphcodeSettings[K],
  ): void;
}) {
  const installCommand = copilotInstallCommand(draft.copilotPreferredVersion);
  const setString = (field: EditableSettingsField) => (value: string) =>
    onChange(field, value);
  const setBoolean = (field: EditableSettingsField) => (value: boolean) =>
    onChange(field, value);

  return (
    <div className="settings-sections">
      <section className="settings-section" aria-labelledby="settings-defaults">
        <h3 id="settings-defaults">Defaults</h3>
        <SelectSetting
          snapshot={snapshot}
          field="defaultBackend"
          label="New loops use"
          description="Copied into each new loop. You can still choose a different backend per loop."
          value={draft.defaultBackend}
          options={backendOptions}
          onChange={setString("defaultBackend")}
          inputRef={firstControlRef}
        />
        <SelectSetting
          snapshot={snapshot}
          field="defaultModelTier"
          label="Default model"
          description="Copied into new loops unless model auto-selection or a per-loop choice overrides it."
          value={draft.defaultModelTier}
          options={modelOptions}
          onChange={setString("defaultModelTier")}
        />
        <ToggleSetting
          snapshot={snapshot}
          field="autoSelectsModel"
          label="Pick a model for each loop"
          description="Routes unpinned turn-based loops to Capable and timed polling to Fast. A per-loop model always wins."
          checked={draft.autoSelectsModel}
          onChange={setBoolean("autoSelectsModel")}
        />
      </section>

      <section
        className="settings-section"
        aria-labelledby="settings-permissions"
      >
        <h3 id="settings-permissions">Permissions</h3>
        <p className="settings-section-intro">
          Unattended loops cannot answer provider permission prompts.
        </p>
        <SelectSetting
          snapshot={snapshot}
          field="claudePermissionMode"
          label="Claude Code"
          description={claudeExplanations[draft.claudePermissionMode]}
          value={draft.claudePermissionMode}
          options={claudeOptions}
          onChange={setString("claudePermissionMode")}
        />
        <SelectSetting
          snapshot={snapshot}
          field="copilotPermissions"
          label="Copilot CLI"
          description={copilotExplanations[draft.copilotPermissions]}
          value={draft.copilotPermissions}
          options={copilotOptions}
          onChange={setString("copilotPermissions")}
        />
        <SelectSetting
          snapshot={snapshot}
          field="codexApprovals"
          label="Codex"
          description={codexExplanations[draft.codexApprovals]}
          value={draft.codexApprovals}
          options={codexOptions}
          onChange={setString("codexApprovals")}
        />
        <SelectSetting
          snapshot={snapshot}
          field="openCodePermissions"
          label="OpenCode"
          description={openCodeExplanations[draft.openCodePermissions]}
          value={draft.openCodePermissions}
          options={openCodeOptions}
          onChange={setString("openCodePermissions")}
        />
        <SelectSetting
          snapshot={snapshot}
          field="piProjectTrust"
          label="Pi"
          description={piExplanations[draft.piProjectTrust]}
          value={draft.piProjectTrust}
          options={piOptions}
          onChange={setString("piProjectTrust")}
        />
      </section>

      <section className="settings-section" aria-labelledby="settings-versions">
        <h3 id="settings-versions">Preferred versions</h3>
        <SettingFrame
          snapshot={snapshot}
          field="copilotPreferredVersion"
          label="Copilot CLI"
          description="Default leaves version selection to the CLI. A specific version applies to new and resumed sessions; installation is not automatic."
        >
          <select
            id="settings-copilotPreferredVersion"
            value={enteringCopilotVersion ? "specific" : "default"}
            disabled={Boolean(
              fieldUnavailableReason(snapshot, "copilotPreferredVersion"),
            )}
            aria-describedby="settings-copilotPreferredVersion-description"
            onChange={(event) => {
              const specific = event.currentTarget.value === "specific";
              onEnteringCopilotVersionChange(specific);
              if (!specific) onChange("copilotPreferredVersion", "");
            }}
          >
            <option value="default">Default</option>
            <option value="specific">Specific version</option>
          </select>
          {enteringCopilotVersion ? (
            <div className="settings-inline-editor">
              <label htmlFor="settings-copilot-version-value">Version</label>
              <input
                id="settings-copilot-version-value"
                value={draft.copilotPreferredVersion}
                onChange={(event) =>
                  onChange("copilotPreferredVersion", event.currentTarget.value)
                }
              />
              {installCommand ? (
                <div className="settings-copy-row">
                  <code>{installCommand}</code>
                  <button
                    type="button"
                    onClick={() =>
                      void navigator.clipboard.writeText(installCommand)
                    }
                  >
                    Copy
                  </button>
                </div>
              ) : null}
            </div>
          ) : null}
        </SettingFrame>
      </section>

      <section className="settings-section" aria-labelledby="settings-behavior">
        <h3 id="settings-behavior">Loop behavior</h3>
        <ToggleSetting
          snapshot={snapshot}
          field="briefsSessionsAboutTheGraph"
          label="Tell sessions they're part of a graph"
          description="Lets a loop create more loops when work genuinely splits."
          checked={draft.briefsSessionsAboutTheGraph}
          onChange={setBoolean("briefsSessionsAboutTheGraph")}
        />
        <SettingFrame
          snapshot={snapshot}
          field="endsResolvedSessionsAfterMinutes"
          label="End a finished loop's session"
          description="Use zero to keep sessions indefinitely. The loop, transcript, and history remain after its process ends."
        >
          <div className="settings-number-row">
            <input
              id="settings-endsResolvedSessionsAfterMinutes"
              type="number"
              min={0}
              step={1}
              value={draft.endsResolvedSessionsAfterMinutes}
              aria-invalid={Boolean(errors.endsResolvedSessionsAfterMinutes)}
              aria-describedby={
                errors.endsResolvedSessionsAfterMinutes
                  ? "settings-endsResolvedSessionsAfterMinutes-error"
                  : "settings-endsResolvedSessionsAfterMinutes-description"
              }
              onChange={(event) =>
                onChange(
                  "endsResolvedSessionsAfterMinutes",
                  Number(event.currentTarget.value),
                )
              }
            />
            <span>minutes</span>
          </div>
          {errors.endsResolvedSessionsAfterMinutes ? (
            <span
              id="settings-endsResolvedSessionsAfterMinutes-error"
              className="field-error"
            >
              {errors.endsResolvedSessionsAfterMinutes}
            </span>
          ) : null}
        </SettingFrame>
        <ToggleSetting
          snapshot={snapshot}
          field="daemonHeartbeatEnabled"
          label="Daemon heartbeat (experimental)"
          description="The daemon drives heartbeat-based timed loops. Turning it off silences existing heartbeat loops immediately."
          checked={draft.daemonHeartbeatEnabled}
          onChange={setBoolean("daemonHeartbeatEnabled")}
        />
        <ToggleSetting
          snapshot={snapshot}
          field="mailroomEnabled"
          label="Mailroom"
          description="Enables graph mail commands, shared notices, and the workspace rail Mailroom section."
          checked={draft.mailroomEnabled}
          onChange={setBoolean("mailroomEnabled")}
        />
      </section>

      <section className="settings-section" aria-labelledby="settings-summary">
        <h3 id="settings-summary">Summary and board</h3>
        <ToggleSetting
          snapshot={snapshot}
          field="summarisesLoops"
          label="Summarise what loops are doing (experimental)"
          description="Reads each session's transcript to produce the summary rail without a model call."
          checked={draft.summarisesLoops}
          onChange={setBoolean("summarisesLoops")}
        />
        <ToggleSetting
          snapshot={snapshot}
          field="summaryUsesModel"
          label="Let a model write the summaries (experimental)"
          description="Makes one short backend CLI call per changed beat. This is the part that costs money."
          checked={draft.summaryUsesModel}
          disabled={!draft.summarisesLoops}
          onChange={setBoolean("summaryUsesModel")}
        />
        <ToggleSetting
          snapshot={snapshot}
          field="visualisesSummaries"
          label="Visualise what loops did (experimental)"
          description="May draw a flowchart or table for a finished pass using one short model call per pass."
          checked={draft.visualisesSummaries}
          disabled={!draft.summarisesLoops}
          onChange={setBoolean("visualisesSummaries")}
        />
      </section>

      <section
        className="settings-section"
        aria-labelledby="settings-platform-capabilities"
      >
        <h3 id="settings-platform-capabilities">Platform capabilities</h3>
        <ToggleSetting
          snapshot={snapshot}
          field="showsActivityStrip"
          label="Show the activity strip"
          description=""
          checked={draft.showsActivityStrip}
          onChange={setBoolean("showsActivityStrip")}
        />
        <ToggleSetting
          snapshot={snapshot}
          field="betaUpdates"
          label="Get beta releases"
          description=""
          checked={draft.betaUpdates}
          onChange={setBoolean("betaUpdates")}
        />
        <ToggleSetting
          snapshot={snapshot}
          field="keepsMacAwakeWhileLoopsRun"
          label="Keep the Mac awake while loops run"
          description=""
          checked={draft.keepsMacAwakeWhileLoopsRun}
          onChange={setBoolean("keepsMacAwakeWhileLoopsRun")}
        />
        <SettingFrame
          snapshot={snapshot}
          field="worktreePolicies"
          label="Per-project worktree policies"
          description=""
        >
          <button type="button" disabled>
            Manage per project
          </button>
        </SettingFrame>
      </section>
    </div>
  );
}

export function SettingsDialog({ onClose }: { onClose(): void }) {
  const [snapshot, setSnapshot] = useState<SettingsSnapshot>();
  const [baseline, setBaseline] = useState<GraphcodeSettings>();
  const [draft, setDraft] = useState<GraphcodeSettings>();
  const [enteringCopilotVersion, setEnteringCopilotVersion] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<{ code: string; message: string }>();
  const [subscriptionError, setSubscriptionError] = useState<string>();
  const [notice, setNotice] = useState<string>();
  const snapshotGeneration = useRef(0);
  const listenerAttempt = useRef(0);
  const activeUnlisten = useRef<(() => void) | undefined>(undefined);
  const baselineRef = useRef<GraphcodeSettings | undefined>(undefined);
  const draftRef = useRef<GraphcodeSettings | undefined>(undefined);
  const firstControlRef = useRef<HTMLSelectElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    active: Boolean(snapshot),
    canClose: !saving,
    initialFocusRef: firstControlRef,
    onClose,
  });

  const setCurrentDraft = useCallback((next: GraphcodeSettings) => {
    draftRef.current = next;
    setDraft(next);
  }, []);

  const applySnapshot = useCallback(
    (
      incomingSnapshot: SettingsSnapshot,
      source: "load" | "event" | "conflict",
    ) => {
      const incoming = graphcodeSettingsSchema.parse(incomingSnapshot.settings);
      const previousBaseline = baselineRef.current;
      const previousDraft = draftRef.current;
      const hasLocalChanges =
        previousBaseline &&
        previousDraft &&
        changedSettingsFields(previousBaseline, previousDraft).length > 0;
      const nextDraft = hasLocalChanges
        ? rebaseSettingsDraft(previousBaseline, previousDraft, incoming)
        : incoming;
      const remainingLocalChanges =
        hasLocalChanges && previousDraft
          ? changedSettingsFields(incoming, nextDraft).length
          : 0;

      baselineRef.current = incoming;
      setBaseline(incoming);
      setCurrentDraft(nextDraft);
      setSnapshot(incomingSnapshot);
      setEnteringCopilotVersion(
        nextDraft.copilotPreferredVersion.trim().length > 0,
      );
      if (source === "event") {
        setNotice(
          remainingLocalChanges
            ? "Settings changed in another client. Your edits were reapplied to the newest revision; review and save again."
            : hasLocalChanges
              ? "Settings saved."
              : "Settings refreshed from another client.",
        );
      } else if (source === "conflict") {
        setNotice(
          "The revision changed before your save. Your edits were reapplied to the latest settings; review and save again.",
        );
      }
    },
    [setCurrentDraft],
  );

  const loadCurrentSettings = useCallback(
    (source: "load" | "conflict" = "load") => {
      const startedAt = snapshotGeneration.current;
      setError(undefined);
      return loadSettings()
        .then((loaded) => {
          if (snapshotGeneration.current !== startedAt) return;
          snapshotGeneration.current += 1;
          applySnapshot(loaded, source);
        })
        .catch((caught: unknown) => {
          if (snapshotGeneration.current !== startedAt) return;
          setError(settingsBridgeError(caught));
        });
    },
    [applySnapshot],
  );

  const synchronize = useCallback(() => {
    const attempt = listenerAttempt.current + 1;
    listenerAttempt.current = attempt;
    snapshotGeneration.current += 1;
    activeUnlisten.current?.();
    activeUnlisten.current = undefined;
    setSubscriptionError(undefined);

    void listenForSettingsChanges((incoming) => {
      if (listenerAttempt.current !== attempt) return;
      snapshotGeneration.current += 1;
      applySnapshot(incoming, "event");
      setError(undefined);
    })
      .then((stop) => {
        if (listenerAttempt.current !== attempt) {
          stop();
          return;
        }
        activeUnlisten.current = stop;
      })
      .catch((caught: unknown) => {
        if (listenerAttempt.current !== attempt) return;
        const failure = settingsBridgeError(caught);
        setSubscriptionError(
          `Settings refresh subscription failed: ${failure.message}`,
        );
      })
      .finally(() => {
        if (listenerAttempt.current === attempt) {
          void loadCurrentSettings();
        }
      });
  }, [applySnapshot, loadCurrentSettings]);

  useEffect(() => {
    synchronize();
    return () => {
      listenerAttempt.current += 1;
      activeUnlisten.current?.();
      activeUnlisten.current = undefined;
    };
  }, [synchronize]);

  const errors = useMemo(
    () => (draft ? validateSettingsDraft(draft) : {}),
    [draft],
  );
  const dirtyFields = useMemo(
    () => (baseline && draft ? changedSettingsFields(baseline, draft) : []),
    [baseline, draft],
  );

  const changeSetting = useCallback(
    <K extends EditableSettingsField>(
      field: K,
      value: GraphcodeSettings[K],
    ) => {
      if (!draftRef.current) return;
      setCurrentDraft({ ...draftRef.current, [field]: value });
      setNotice(undefined);
    },
    [setCurrentDraft],
  );

  const save = async () => {
    if (!snapshot || !draft || Object.keys(errors).length > 0) return;
    const startedAt = snapshotGeneration.current;
    setSaving(true);
    setError(undefined);
    setNotice(undefined);
    try {
      const saved = await updateSettings(snapshot.revision, draft);
      if (snapshotGeneration.current === startedAt) {
        snapshotGeneration.current += 1;
        applySnapshot(saved, "load");
        setNotice("Settings saved.");
      }
    } catch (caught) {
      if (snapshotGeneration.current !== startedAt) return;
      const failure = settingsBridgeError(caught);
      if (failure.code === "settingsConflict") {
        await loadCurrentSettings("conflict");
      } else {
        setError(failure);
      }
    } finally {
      setSaving(false);
    }
  };

  const submit = (event: FormEvent) => {
    event.preventDefault();
    void save();
  };
  const visibleError = subscriptionError ?? error?.message;

  return (
    <div className="new-loop-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="new-loop-dialog settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-title"
        aria-describedby="settings-description"
        tabIndex={-1}
        onKeyDown={(event) => {
          if (handleDialogKeyDown(event)) return;
          if (event.ctrlKey && event.key === "Enter" && dirtyFields.length) {
            event.preventDefault();
            void save();
          }
        }}
      >
        <header className="new-loop-header">
          <div>
            <p className="eyebrow">GraphCode configuration</p>
            <h2 id="settings-title">Settings</h2>
            <p id="settings-description" className="settings-dialog-intro">
              Changes are saved through graphcoded and never written directly by
              this client.
            </p>
          </div>
          <button
            type="button"
            className="icon-button"
            aria-label="Close settings"
            disabled={saving}
            onClick={onClose}
          >
            ×
          </button>
        </header>
        <form className="settings-form" onSubmit={submit}>
          <div className="settings-body">
            {snapshot && draft ? (
              <SettingsEditor
                snapshot={snapshot}
                draft={draft}
                errors={errors}
                firstControlRef={firstControlRef}
                enteringCopilotVersion={enteringCopilotVersion}
                onEnteringCopilotVersionChange={setEnteringCopilotVersion}
                onChange={changeSetting}
              />
            ) : !visibleError ? (
              <p className="settings-loading" role="status">
                Loading settings…
              </p>
            ) : null}
            {snapshot ? (
              <section className="settings-location">
                <h3>Shared settings file</h3>
                <code>{snapshot.filePath}</code>
              </section>
            ) : null}
            {notice ? (
              <div className="settings-notice" role="status">
                {notice}
              </div>
            ) : null}
            {visibleError ? (
              <div className="terminal-error" role="alert">
                <span>
                  {visibleError}
                  {error?.code === "settingsCorrupt"
                    ? " GraphCode did not replace the file. Repair or restore it, then reload."
                    : ""}
                </span>
                <button type="button" onClick={synchronize}>
                  Reload
                </button>
              </div>
            ) : null}
          </div>
          <footer className="new-loop-footer">
            <span>
              {dirtyFields.length
                ? `${dirtyFields.length} unsaved setting${dirtyFields.length === 1 ? "" : "s"}.`
                : "Unknown and newer-version fields are preserved."}
            </span>
            <div>
              <button type="button" disabled={saving} onClick={onClose}>
                Close
              </button>
              <button
                type="submit"
                className="primary-button"
                disabled={
                  !snapshot ||
                  saving ||
                  dirtyFields.length === 0 ||
                  Object.keys(errors).length > 0
                }
              >
                {saving ? "Saving…" : "Save"}
              </button>
            </div>
          </footer>
        </form>
      </section>
    </div>
  );
}
