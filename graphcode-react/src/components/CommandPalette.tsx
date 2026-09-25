import { useEffect, useMemo, useRef, useState } from "react";
import type { AppCommand } from "../commands/registry";
import { useDialogFocus } from "./dialogFocus";

export function CommandPalette({
  commands,
  open,
  pendingCommandId,
  onClose,
  onExecute,
}: {
  commands: AppCommand[];
  open: boolean;
  pendingCommandId?: string;
  onClose(): void;
  onExecute(command: AppCommand): void;
}) {
  const [query, setQuery] = useState("");
  const inputRef = useRef<HTMLInputElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    active: open,
    initialFocusRef: inputRef,
    onClose,
  });
  const results = useMemo(() => {
    const normalized = query.trim().toLocaleLowerCase();
    return commands
      .filter((command) => command.id !== "app.commandPalette")
      .filter(
        (command) =>
          !normalized ||
          `${command.label} ${command.description} ${command.category}`
            .toLocaleLowerCase()
            .includes(normalized),
      );
  }, [commands, query]);

  useEffect(() => {
    if (!open) {
      setQuery("");
    }
  }, [open]);

  if (!open) return null;

  return (
    <div className="command-overlay" role="presentation" onMouseDown={onClose}>
      <section
        ref={dialogRef}
        className="command-palette"
        role="dialog"
        aria-modal="true"
        aria-labelledby="command-palette-title"
        onMouseDown={(event) => event.stopPropagation()}
        onKeyDown={handleDialogKeyDown}
      >
        <h2 id="command-palette-title">GraphCode commands</h2>
        <input
          ref={inputRef}
          type="search"
          value={query}
          onChange={(event) => setQuery(event.currentTarget.value)}
          placeholder="Search commands"
          aria-label="Search commands"
        />
        <ul className="command-results">
          {results.map((command) => (
            <li key={command.id}>
              <button
                type="button"
                disabled={!command.enabled || pendingCommandId === command.id}
                title={command.disabledReason}
                onClick={() => onExecute(command)}
              >
                <span>
                  <strong>{command.label}</strong>
                  <small>{command.description}</small>
                  {!command.enabled && command.disabledReason ? (
                    <small className="command-disabled-reason">
                      {command.disabledReason}
                    </small>
                  ) : null}
                </span>
                {command.shortcut ? <kbd>{command.shortcut.label}</kbd> : null}
              </button>
            </li>
          ))}
        </ul>
        {!results.length ? (
          <p className="command-empty">No commands found.</p>
        ) : null}
      </section>
    </div>
  );
}
