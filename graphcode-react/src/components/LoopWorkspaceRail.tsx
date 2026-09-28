import { useMemo, useRef, useState, type RefObject } from "react";
import type { AppCommand, CommandId } from "../commands/registry";
import type { LoopGraph, LoopNode, Mailbox } from "../protocol/domain";
import { displayState } from "../state/attention";
import { boardIsDrawable, presentLoopSummary } from "../state/workspaceRail";
import { CommandMenu } from "./CommandMenu";
import { useDialogFocus } from "./dialogFocus";
import { SummaryBoardView } from "./SummaryBoardView";

const mailroomCommandIds = new Set<CommandId>([
  "loop.mailroomRefresh",
  "loop.mailroomUnread",
  "loop.mailroomMarkRead",
  "loop.mailroomWatch",
  "loop.mailroomPost",
]);

function commandById(commands: AppCommand[], id: CommandId) {
  return commands.find((command) => command.id === id);
}

function RailCommand({
  command,
  pendingCommandId,
  onExecute,
}: {
  command?: AppCommand;
  pendingCommandId?: string;
  onExecute(command: AppCommand): void;
}) {
  if (!command) return null;
  return (
    <button
      type="button"
      disabled={!command.enabled || pendingCommandId === command.id}
      title={command.disabledReason ?? command.description}
      onClick={() => onExecute(command)}
    >
      {command.label}
    </button>
  );
}

function SummarySection({
  node,
  seenBeatId,
  onMarkSeen,
}: {
  node: LoopNode;
  seenBeatId?: string;
  onMarkSeen(): void;
}) {
  const presentation = presentLoopSummary(node, seenBeatId);
  const label =
    presentation.mode === "resolved"
      ? "Last did"
      : presentation.mode === "asking"
        ? "Needs you"
        : presentation.isLive
          ? "Doing now"
          : "Latest beat";
  const text =
    presentation.current?.text ??
    (presentation.mode === "resolved"
      ? node.goal?.summary || node.title
      : "Getting its bearings");

  return (
    <details className="workspace-rail-section" open>
      <summary>
        <span>Summary</span>
        {presentation.unseen ? (
          <span className="workspace-rail-count">
            {presentation.unseen} new
          </span>
        ) : null}
      </summary>
      <div className={`workspace-summary-now summary-${presentation.mode}`}>
        <span className="workspace-section-label">{label}</span>
        <strong>{text}</strong>
        {presentation.current?.evidence ? (
          <code>{presentation.current.evidence}</code>
        ) : null}
        {presentation.pass ? <small>Pass {presentation.pass}</small> : null}
      </div>
      {presentation.receding.length ? (
        <ol className="workspace-beat-list" aria-label="Earlier summary beats">
          {presentation.receding.map((beat) => (
            <li key={beat.id}>
              <span
                className={`beat-dot beat-${beat.kind}`}
                aria-hidden="true"
              />
              <span>{beat.text}</span>
              <small>Pass {beat.pass}</small>
            </li>
          ))}
        </ol>
      ) : null}
      {presentation.passes.length || presentation.earlierPasses ? (
        <div className="workspace-pass-history">
          <span className="workspace-section-label">Finished passes</span>
          {presentation.earlierPasses ? (
            <small>{presentation.earlierPasses} earlier</small>
          ) : null}
          <ol>
            {presentation.passes.map((pass) => (
              <li key={pass.pass}>
                <span>Pass {pass.pass}</span>
                <span>{pass.text}</span>
                {pass.delta ? <code>{pass.delta}</code> : null}
              </li>
            ))}
          </ol>
        </div>
      ) : null}
      {presentation.unseen ? (
        <button
          className="workspace-secondary-action"
          type="button"
          onClick={onMarkSeen}
        >
          Mark summary read
        </button>
      ) : null}
    </details>
  );
}

function AttentionSection({ node }: { node: LoopNode }) {
  const state = displayState(node);
  const needsAttention = ["awaitingInput", "failed", "stalled"].includes(state);
  return (
    <section
      className={`workspace-attention ${needsAttention ? "needs-attention" : ""}`}
      aria-label="Loop attention"
    >
      <span className="workspace-section-label">Attention</span>
      <strong>
        {state === "awaitingInput"
          ? "Waiting for your input"
          : state === "failed"
            ? "Session failed"
            : state === "stalled"
              ? "Loop stalled"
              : state === "running"
                ? "Working"
                : "No action needed"}
      </strong>
      {node.stallReason ? <p>{node.stallReason}</p> : null}
    </section>
  );
}

function BoardSection({
  node,
  expandButtonRef,
  onExpand,
}: {
  node: LoopNode;
  expandButtonRef: RefObject<HTMLButtonElement | null>;
  onExpand(): void;
}) {
  if (!boardIsDrawable(node) || !node.board) return null;
  const stale = (node.summary?.currentPass ?? 0) > node.board.pass;
  return (
    <details className="workspace-rail-section" open>
      <summary>
        <span>{node.board.title || "Board"}</span>
        <span className="workspace-rail-meta">
          Pass {node.board.pass}
          {stale ? " · earlier" : ""}
        </span>
      </summary>
      <SummaryBoardView board={node.board} />
      <button
        ref={expandButtonRef}
        className="workspace-secondary-action"
        type="button"
        onClick={onExpand}
      >
        Expand board
      </button>
    </details>
  );
}

function MailroomSection({
  graph,
  node,
  mailbox,
  owned,
  seenPostId,
  commands,
  pendingCommandId,
  onExecute,
}: {
  graph: LoopGraph;
  node: LoopNode;
  mailbox?: Mailbox;
  owned: boolean;
  seenPostId?: number;
  commands: AppCommand[];
  pendingCommandId?: string;
  onExecute(command: AppCommand): void;
}) {
  const notices = owned
    ? (mailbox?.posts.filter((post) => post.kind === "notice") ?? [])
    : [];
  const newNotices = notices.filter((post) => post.id > (seenPostId ?? 0));
  const newNoticeIds = new Set(newNotices.map((post) => post.id));
  const refresh = commandById(commands, "loop.mailroomRefresh");
  const loadUnread = commandById(commands, "loop.mailroomUnread");
  const markRead = commandById(commands, "loop.mailroomMarkRead");
  const watch = commandById(commands, "loop.mailroomWatch");
  const post = commandById(commands, "loop.mailroomPost");

  return (
    <details className="workspace-rail-section" open>
      <summary>
        <span>Mailroom for {graph.project.name}</span>
        {owned && newNotices.length ? (
          <span className="workspace-rail-count">{newNotices.length} new</span>
        ) : null}
      </summary>
      {!owned ? (
        <p className="workspace-rail-empty" role="status">
          Nested Mailroom ownership is not established. Return to the project
          graph to read or change Mailroom state.
        </p>
      ) : mailbox ? (
        notices.length ? (
          <ol className="workspace-mail-list" aria-label="Mailroom notices">
            {notices.map((notice) => (
              <li
                key={notice.id}
                className={newNoticeIds.has(notice.id) ? "unread" : ""}
              >
                <header>
                  <strong>{notice.topic ?? "Notice"}</strong>
                  <span>#{notice.id}</span>
                </header>
                <p>{notice.body}</p>
                <small>{notice.author}</small>
              </li>
            ))}
          </ol>
        ) : (
          <p className="workspace-rail-empty">
            No Mailroom notices have been posted.
          </p>
        )
      ) : (
        <p className="workspace-rail-empty">
          Load the project Mailroom to see notices for this loop.
        </p>
      )}
      <div className="workspace-rail-actions" aria-label="Mailroom controls">
        <RailCommand
          command={refresh}
          pendingCommandId={pendingCommandId}
          onExecute={onExecute}
        />
        <RailCommand
          command={loadUnread}
          pendingCommandId={pendingCommandId}
          onExecute={onExecute}
        />
        <RailCommand
          command={markRead}
          pendingCommandId={pendingCommandId}
          onExecute={onExecute}
        />
        <RailCommand
          command={watch}
          pendingCommandId={pendingCommandId}
          onExecute={onExecute}
        />
        <RailCommand
          command={post}
          pendingCommandId={pendingCommandId}
          onExecute={onExecute}
        />
      </div>
      {owned ? (
        <div className="workspace-mail-status">
          <span>
            Human view:{" "}
            {seenPostId === undefined ? "not seen" : `through #${seenPostId}`}
          </span>
          <span>
            Loop inbox cursor:{" "}
            {node.lastMailroomRead === undefined
              ? "not advanced"
              : `#${node.lastMailroomRead}`}
          </span>
          <span>
            Watch:{" "}
            {node.mailroomWatch
              ? node.mailroomWatch.topic
                ? `topic “${node.mailroomWatch.topic}”`
                : "all posts"
              : "off"}
          </span>
        </div>
      ) : null}
    </details>
  );
}

function ExpandedBoardDialog({
  node,
  onClose,
}: {
  node: LoopNode;
  onClose(): void;
}) {
  const closeButtonRef = useRef<HTMLButtonElement>(null);
  const { dialogRef, handleDialogKeyDown } = useDialogFocus({
    initialFocusRef: closeButtonRef,
    onClose,
  });

  if (!node.board) return null;
  return (
    <div className="workspace-board-overlay" role="presentation">
      <section
        ref={dialogRef}
        className="workspace-board-dialog"
        role="dialog"
        aria-modal="true"
        aria-labelledby="workspace-board-title"
        tabIndex={-1}
        onKeyDown={handleDialogKeyDown}
      >
        <header>
          <div>
            <p className="eyebrow">Pass {node.board.pass}</p>
            <h2 id="workspace-board-title">
              {node.board.title || `${node.title} board`}
            </h2>
          </div>
          <button
            ref={closeButtonRef}
            type="button"
            aria-label="Close expanded board"
            onClick={onClose}
          >
            ×
          </button>
        </header>
        <SummaryBoardView board={node.board} />
      </section>
    </div>
  );
}

export function LoopWorkspaceRail({
  graph,
  node,
  mailbox,
  mailroomOwned,
  seenBeatId,
  seenMailroomPostId,
  commands,
  pendingCommandId,
  onSummarySeen,
  onExecuteCommand,
}: {
  graph: LoopGraph;
  node: LoopNode;
  mailbox?: Mailbox;
  mailroomOwned: boolean;
  seenBeatId?: string;
  seenMailroomPostId?: number;
  commands: AppCommand[];
  pendingCommandId?: string;
  onSummarySeen(beatId: string): void;
  onExecuteCommand(command: AppCommand): void;
}) {
  const latestBeatId = node.summary?.beats.at(-1)?.id;
  const [expandedBoard, setExpandedBoard] = useState(false);
  const expandButtonRef = useRef<HTMLButtonElement>(null);
  const loopCommands = useMemo(
    () =>
      commands.filter(
        (command) =>
          !mailroomCommandIds.has(command.id) &&
          command.id !== "loop.openTerminal" &&
          command.id !== "selection.clear",
      ),
    [commands],
  );

  return (
    <>
      <aside className="loop-workspace-rail" aria-label="Loop workspace rail">
        <AttentionSection node={node} />
        <SummarySection
          node={node}
          seenBeatId={seenBeatId}
          onMarkSeen={() => {
            if (latestBeatId) onSummarySeen(latestBeatId);
          }}
        />
        <BoardSection
          node={node}
          expandButtonRef={expandButtonRef}
          onExpand={() => setExpandedBoard(true)}
        />
        <MailroomSection
          graph={graph}
          node={node}
          mailbox={mailbox}
          owned={mailroomOwned}
          seenPostId={seenMailroomPostId}
          commands={commands}
          pendingCommandId={pendingCommandId}
          onExecute={onExecuteCommand}
        />
        {loopCommands.length ? (
          <section className="workspace-loop-actions">
            <span className="workspace-section-label">Loop controls</span>
            <CommandMenu
              commands={loopCommands}
              pendingCommandId={pendingCommandId}
              onExecute={onExecuteCommand}
            />
          </section>
        ) : null}
      </aside>
      {expandedBoard ? (
        <ExpandedBoardDialog
          node={node}
          onClose={() => setExpandedBoard(false)}
        />
      ) : null}
    </>
  );
}
