import type { AppCommand } from "../commands/registry";

export function CommandMenu({
  commands,
  pendingCommandId,
  onExecute,
}: {
  commands: AppCommand[];
  pendingCommandId?: string;
  onExecute(command: AppCommand): void;
}) {
  return (
    <details className="command-menu">
      <summary aria-label="More loop actions">More</summary>
      <div role="menu">
        {commands.map((command) => (
          <button
            key={command.id}
            type="button"
            role="menuitem"
            className={command.danger ? "command-danger" : undefined}
            disabled={!command.enabled || pendingCommandId === command.id}
            title={command.disabledReason}
            onClick={(event) => {
              onExecute(command);
              event.currentTarget.closest("details")?.removeAttribute("open");
            }}
          >
            <span>{command.label}</span>
            {command.shortcut ? <kbd>{command.shortcut.label}</kbd> : null}
          </button>
        ))}
      </div>
    </details>
  );
}
