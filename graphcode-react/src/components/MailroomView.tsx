import { useEffect, useState } from "react";
import type { AppCommand } from "../commands/registry";
import type { LoopGraph, Mailbox, MailroomPost } from "../protocol/domain";

function formattedTime(value: string | number) {
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? String(value) : date.toLocaleString();
}

export function MailroomView({
  graph,
  mailbox,
  commands,
  pendingCommandId,
  commandsForPost,
  onBack,
  onExecute,
}: {
  graph: LoopGraph;
  mailbox?: Mailbox;
  commands: AppCommand[];
  pendingCommandId?: string;
  commandsForPost(post: MailroomPost): AppCommand[];
  onBack(): void;
  onExecute(command: AppCommand): void;
}) {
  const [selectedPostId, setSelectedPostId] = useState<number>();
  const selectedPost =
    mailbox?.posts.find((post) => post.id === selectedPostId) ??
    mailbox?.posts[0];

  useEffect(() => {
    if (
      selectedPostId !== undefined &&
      !mailbox?.posts.some((post) => post.id === selectedPostId)
    ) {
      setSelectedPostId(undefined);
    }
  }, [mailbox?.posts, selectedPostId]);

  return (
    <main className="mailroom-view" aria-labelledby="mailroom-title">
      <header className="mailroom-header">
        <div>
          <button className="back-button" type="button" onClick={onBack}>
            ← Project graph
          </button>
          <p className="eyebrow">Project Mailroom</p>
          <h2 id="mailroom-title">{graph.project.name}</h2>
          <p>
            Top-level project posts from graphcoded. Loop cursors and watches
            remain available from each loop inspector.
          </p>
        </div>
        <div className="mailroom-actions" aria-label="Mailroom actions">
          {commands.map((command) => (
            <button
              key={command.id}
              className={
                command.id === "loop.mailroomPost"
                  ? "primary-button"
                  : undefined
              }
              type="button"
              disabled={!command.enabled || pendingCommandId === command.id}
              title={command.disabledReason ?? command.description}
              onClick={() => onExecute(command)}
            >
              {command.label}
            </button>
          ))}
        </div>
      </header>
      {!mailbox ? (
        <section className="mailroom-empty">
          <h3>Mailroom not loaded</h3>
          <p>Refresh to request the bounded project board from graphcoded.</p>
        </section>
      ) : mailbox.posts.length ? (
        <div className="mailroom-content">
          <ol className="mailroom-post-list" aria-label="Mailroom posts">
            {mailbox.posts.map((post) => (
              <li key={post.id}>
                <button
                  type="button"
                  className={selectedPost?.id === post.id ? "selected" : ""}
                  aria-current={selectedPost?.id === post.id}
                  onClick={() => setSelectedPostId(post.id)}
                >
                  <span>
                    <strong>{post.author}</strong>
                    <small>#{post.id}</small>
                  </span>
                  <span>{post.topic ?? "No topic"}</span>
                  <p>{post.body}</p>
                </button>
              </li>
            ))}
          </ol>
          {selectedPost ? (
            <article
              className="mailroom-post-detail"
              aria-labelledby={`mailroom-post-${selectedPost.id}`}
            >
              <header>
                <div>
                  <p className="eyebrow">{selectedPost.kind}</p>
                  <h3 id={`mailroom-post-${selectedPost.id}`}>
                    {selectedPost.topic ?? `Post #${selectedPost.id}`}
                  </h3>
                </div>
                <span>#{selectedPost.id}</span>
              </header>
              <dl>
                <div>
                  <dt>Author</dt>
                  <dd>{selectedPost.author}</dd>
                </div>
                <div>
                  <dt>Posted</dt>
                  <dd>{formattedTime(selectedPost.at)}</dd>
                </div>
              </dl>
              <p className="mailroom-post-body">{selectedPost.body}</p>
              {mailbox.bodiesTrimmed
                ? commandsForPost(selectedPost).map((command) => (
                    <button
                      key={command.id}
                      type="button"
                      disabled={
                        !command.enabled || pendingCommandId === command.id
                      }
                      title={command.disabledReason ?? command.description}
                      onClick={() => onExecute(command)}
                    >
                      {command.label}
                    </button>
                  ))
                : null}
            </article>
          ) : null}
        </div>
      ) : (
        <section className="mailroom-empty">
          <h3>The Mailroom is empty</h3>
          <p>Posts from project loops will appear here.</p>
        </section>
      )}
      {mailbox ? (
        <footer className="mailroom-status" aria-label="Mailbox status">
          <span>{mailbox.digest.count} total posts</span>
          <span>{mailbox.remaining} unread remaining in this query</span>
          {mailbox.prunedUnread ? (
            <span>{mailbox.prunedUnread} older unread posts pruned</span>
          ) : null}
        </footer>
      ) : null}
    </main>
  );
}
