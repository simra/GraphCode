import type { AppCommand, CommandId } from "../commands/registry";

export function ProjectRowActions({
  projectName,
  commands,
  pendingCommandId,
  onExecute,
}: {
  projectName: string;
  commands: AppCommand[];
  pendingCommandId?: CommandId;
  onExecute(command: AppCommand): void;
}) {
  return (
    <details className="project-row-actions">
      <summary aria-label={`Actions for ${projectName}`}>•••</summary>
      <div role="menu" aria-label={`${projectName} project actions`}>
        {commands.map((command) => (
          <button
            key={command.id}
            type="button"
            role="menuitem"
            className={command.danger ? "danger-command" : undefined}
            disabled={!command.enabled || pendingCommandId === command.id}
            title={command.disabledReason}
            onClick={() => onExecute(command)}
          >
            <span>{command.label}</span>
            <small>{command.description}</small>
          </button>
        ))}
      </div>
    </details>
  );
}
