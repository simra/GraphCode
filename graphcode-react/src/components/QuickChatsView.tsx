import type { AppCommand, CommandId } from "../commands/registry";
import type { QuickChat } from "../protocol/domain";

function encodedPresence(chat: QuickChat): string | undefined {
  return chat.activity?.presence?.presence;
}

function createdLabel(createdAt: string | number): string {
  const date =
    typeof createdAt === "number"
      ? new Date(createdAt < 10_000_000_000 ? createdAt * 1000 : createdAt)
      : new Date(createdAt);
  return Number.isNaN(date.getTime())
    ? "Creation time unavailable"
    : `Created ${date.toLocaleDateString()}`;
}

export function QuickChatsView({
  chats,
  selectedChat,
  pendingCommandId,
  commandsForChat,
  onBack,
  onNewChat,
  onExecute,
}: {
  chats: QuickChat[];
  selectedChat?: QuickChat;
  pendingCommandId?: CommandId;
  commandsForChat(chat: QuickChat): AppCommand[];
  onBack(): void;
  onNewChat(): void;
  onExecute(command: AppCommand): void;
}) {
  if (selectedChat) {
    const commands = commandsForChat(selectedChat);
    return (
      <section className="quick-chat-workspace" aria-labelledby="chat-title">
        <header>
          <button type="button" className="back-button" onClick={onBack}>
            ← All Quick Chats
          </button>
          <div className="quick-chat-actions">
            {commands.slice(1).map((command) => (
              <button
                key={command.id}
                type="button"
                className={command.danger ? "danger-command" : undefined}
                disabled={!command.enabled || pendingCommandId === command.id}
                title={command.disabledReason}
                onClick={() => onExecute(command)}
              >
                {command.label}
              </button>
            ))}
          </div>
        </header>
        <div className="quick-chat-workspace-body">
          <span className="chat-mark" aria-hidden="true">
            ◌
          </span>
          <p className="eyebrow">Quick Chat workspace</p>
          <h2 id="chat-title">{selectedChat.title}</h2>
          <dl>
            <div>
              <dt>Backend</dt>
              <dd>{selectedChat.backend}</dd>
            </div>
            <div>
              <dt>Presence</dt>
              <dd>{encodedPresence(selectedChat) ?? "Unknown"}</dd>
            </div>
            <div>
              <dt>Activity</dt>
              <dd>{selectedChat.activity?.text ?? "No activity reported"}</dd>
            </div>
          </dl>
          <div className="terminal-placeholder" role="status">
            <strong>Session ready</strong>
            <span>
              graphcoded confirmed this Quick Chat session. Interactive terminal
              attachment remains unavailable until the existing zmx bridge is
              implemented.
            </span>
          </div>
        </div>
      </section>
    );
  }

  return (
    <section className="quick-chats-panel" aria-labelledby="quick-chats-title">
      <header className="canvas-heading">
        <div>
          <p className="eyebrow">Daemon-owned conversations</p>
          <h2 id="quick-chats-title">Quick Chats</h2>
        </div>
        <button type="button" className="primary-button" onClick={onNewChat}>
          New Chat
        </button>
      </header>
      {chats.length ? (
        <ul className="quick-chat-grid">
          {chats.map((chat) => {
            const commands = commandsForChat(chat);
            const openCommand = commands[0];
            return (
              <li key={chat.id}>
                <article className="quick-chat-card">
                  <button
                    className="quick-chat-open"
                    type="button"
                    disabled={
                      !openCommand.enabled ||
                      pendingCommandId === openCommand.id
                    }
                    title={openCommand.disabledReason}
                    onClick={() => onExecute(openCommand)}
                  >
                    <span className="chat-mark" aria-hidden="true">
                      ◌
                    </span>
                    <span>
                      <strong>{chat.title}</strong>
                      <small>
                        {chat.activity?.text ??
                          `${chat.backend} · ${createdLabel(chat.createdAt)}`}
                      </small>
                    </span>
                    {encodedPresence(chat) ? (
                      <span className="presence-label">
                        {encodedPresence(chat)}
                      </span>
                    ) : null}
                  </button>
                  <details className="quick-chat-menu">
                    <summary aria-label={`Actions for ${chat.title}`}>
                      •••
                    </summary>
                    <div>
                      {commands.map((command) => (
                        <button
                          key={command.id}
                          type="button"
                          className={
                            command.danger ? "danger-command" : undefined
                          }
                          disabled={
                            !command.enabled || pendingCommandId === command.id
                          }
                          title={command.disabledReason}
                          onClick={(event) => {
                            event.currentTarget
                              .closest("details")
                              ?.removeAttribute("open");
                            onExecute(command);
                          }}
                        >
                          <strong>{command.label}</strong>
                          <small>{command.description}</small>
                        </button>
                      ))}
                    </div>
                  </details>
                </article>
              </li>
            );
          })}
        </ul>
      ) : (
        <div className="quick-chat-empty">
          <span className="chat-mark" aria-hidden="true">
            ◌
          </span>
          <h3>No chats yet</h3>
          <p>
            Start a bare conversation for work that does not need a loop,
            trigger, or project graph.
          </p>
          <button type="button" className="primary-button" onClick={onNewChat}>
            New Chat
          </button>
        </div>
      )}
    </section>
  );
}
