import { useEffect, useState } from "react";
import {
  loadSettings,
  listenForSettingsChanges,
  setDaemonHeartbeatEnabled,
  settingsTiming,
  type SettingsSnapshot,
} from "../bridge/settings";

export function SettingsDialog({ onClose }: { onClose(): void }) {
  const [settings, setSettings] = useState<SettingsSnapshot>();
  const [heartbeatEnabled, setHeartbeatEnabled] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string>();

  const reload = () => {
    setError(undefined);
    void loadSettings()
      .then((loaded) => {
        setSettings(loaded);
        setHeartbeatEnabled(loaded.daemonHeartbeatEnabled);
      })
      .catch((caught: unknown) =>
        setError(caught instanceof Error ? caught.message : String(caught)),
      );
  };

  useEffect(() => {
    reload();
    let unlisten: (() => void) | undefined;
    void listenForSettingsChanges((snapshot) => {
      setSettings(snapshot);
      setHeartbeatEnabled(snapshot.daemonHeartbeatEnabled);
      setError(undefined);
    }).then((stop) => {
      unlisten = stop;
    });
    return () => unlisten?.();
  }, []);

  const save = async () => {
    if (!settings) return;
    setSaving(true);
    setError(undefined);
    try {
      const saved = await setDaemonHeartbeatEnabled(
        settings.revision,
        settings.settings,
        heartbeatEnabled,
      );
      setSettings(saved);
      setHeartbeatEnabled(saved.daemonHeartbeatEnabled);
    } catch (caught) {
      setError(caught instanceof Error ? caught.message : String(caught));
    } finally {
      setSaving(false);
    }
  };

  return (
    <div className="new-loop-overlay" role="presentation">
      <section
        className="new-loop-dialog settings-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-title"
      >
        <header className="new-loop-header">
          <div>
            <p className="eyebrow">GraphCode configuration</p>
            <h2 id="settings-title">Settings</h2>
          </div>
          <button
            type="button"
            className="icon-button"
            aria-label="Close settings"
            onClick={onClose}
          >
            ×
          </button>
        </header>
        <div className="settings-body">
          <section>
            <h3>Scheduling</h3>
            <label className="settings-toggle">
              <input
                type="checkbox"
                checked={heartbeatEnabled}
                disabled={!settings || saving}
                onChange={(event) => setHeartbeatEnabled(event.target.checked)}
              />
              <span>
                <strong>Enable daemon heartbeat</strong>
                <small>
                  Let graphcoded trigger timed loops that define a heartbeat
                  interval.{" "}
                  {settings &&
                  settingsTiming(settings, "daemonHeartbeatEnabled") === "live"
                    ? "Changes apply to live loops without a daemon restart."
                    : "GraphCode will report when this change takes effect."}
                </small>
              </span>
            </label>
            <p className="settings-guidance">
              Leave this off for session-managed schedules whose prompt begins
              with <code>/loop</code> or <code>/every</code>.
            </p>
          </section>
          {settings ? (
            <section className="settings-location">
              <h3>Workspace settings file</h3>
              <code>{settings.filePath}</code>
            </section>
          ) : null}
          {error ? (
            <div className="terminal-error" role="alert">
              {error}
              <button type="button" onClick={reload}>
                Reload
              </button>
            </div>
          ) : null}
        </div>
        <footer className="new-loop-footer">
          <span>
            Settings writes preserve keys added by other GraphCode versions.
          </span>
          <div>
            <button type="button" onClick={onClose}>
              Close
            </button>
            <button
              type="button"
              className="primary-button"
              disabled={
                !settings ||
                saving ||
                heartbeatEnabled === settings.daemonHeartbeatEnabled
              }
              onClick={() => void save()}
            >
              {saving ? "Saving…" : "Save"}
            </button>
          </div>
        </footer>
      </section>
    </div>
  );
}
