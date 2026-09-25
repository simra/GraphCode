import type { ReactNode } from "react";
import type { AppCommand } from "../commands/registry";
import type {
  EncodedEnum,
  LoopGraph,
  LoopNode,
  Mailbox,
} from "../protocol/domain";
import { CommandMenu } from "./CommandMenu";

function enumLabel(value: EncodedEnum | undefined): string | undefined {
  if (typeof value === "string") return value;
  if (!value) return undefined;
  return Object.keys(value)[0];
}

function sentence(value: string | undefined): string | undefined {
  if (!value) return undefined;
  return value.replace(/([a-z])([A-Z])/g, "$1 $2");
}

function formatDate(value: string | number | undefined): string | undefined {
  if (value === undefined) return undefined;
  const date = new Date(value);
  return Number.isNaN(date.valueOf()) ? String(value) : date.toLocaleString();
}

function formatDuration(seconds: number | undefined): string | undefined {
  if (seconds === undefined) return undefined;
  if (seconds < 60) return `${seconds} seconds`;
  if (seconds < 3600) return `${seconds / 60} minutes`;
  return `${seconds / 3600} hours`;
}

function detailText(value: unknown): string | undefined {
  if (
    typeof value === "string" ||
    typeof value === "number" ||
    typeof value === "boolean"
  ) {
    return String(value);
  }
  if (!value || typeof value !== "object") return undefined;
  for (const key of ["text", "summary", "title", "activity", "message"]) {
    const candidate = (value as Record<string, unknown>)[key];
    if (typeof candidate === "string") return candidate;
  }
  return undefined;
}

function Detail({
  label,
  value,
  code = false,
}: {
  label: string;
  value: string | number | undefined;
  code?: boolean;
}) {
  if (value === undefined || value === "") return null;
  return (
    <div className="inspector-detail">
      <dt>{label}</dt>
      <dd>{code ? <code>{value}</code> : value}</dd>
    </div>
  );
}

function InspectorSection({
  title,
  children,
}: {
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="inspector-section">
      <h3>{title}</h3>
      <dl>{children}</dl>
    </section>
  );
}

export function NodeInspector({
  graph,
  node,
  mailbox,
  commands = [],
  pendingCommandId,
  onClose,
  onExecuteCommand = () => undefined,
}: {
  graph?: LoopGraph;
  node?: LoopNode;
  mailbox?: Mailbox;
  commands?: AppCommand[];
  pendingCommandId?: string;
  onClose(): void;
  onExecuteCommand?(command: AppCommand): void;
}) {
  if (!graph || !node) {
    return (
      <aside
        className="node-inspector inspector-empty"
        aria-label="Loop inspector"
      >
        <p className="eyebrow">Loop inspector</p>
        <h2>No loop selected</h2>
        <p>
          Select a loop card to inspect its brief, runtime state, metrics,
          worktree, and activity.
        </p>
      </aside>
    );
  }

  const state = enumLabel(node.state) ?? "unknown";
  const presence = node.presence?.presence;
  const currentBeat = node.summary?.beats.at(-1);
  const primaryCommandIds = new Set([
    "loop.openTerminal",
    "loop.message",
    "loop.edit",
    "loop.openComposite",
  ]);
  const primaryCommands = commands.filter((command) =>
    primaryCommandIds.has(command.id),
  );
  const overflowCommands = commands.filter(
    (command) => !primaryCommandIds.has(command.id),
  );
  const totalTokens =
    node.usage?.inputTokens !== undefined ||
    node.usage?.outputTokens !== undefined
      ? (node.usage.inputTokens ?? 0) + (node.usage.outputTokens ?? 0)
      : undefined;

  return (
    <aside
      className="node-inspector"
      aria-labelledby="inspector-title"
      aria-describedby="inspector-project"
    >
      <header className="inspector-header">
        <div>
          <p className="eyebrow">{sentence(node.loopType) ?? "Loop"}</p>
          <h2 id="inspector-title">{node.title}</h2>
          <p id="inspector-project">{graph.project.name}</p>
        </div>
        <button
          className="icon-button"
          type="button"
          onClick={onClose}
          aria-label="Close loop inspector"
        >
          ×
        </button>
      </header>

      <div className="inspector-badges" aria-label="Loop status">
        <span className={`status-badge status-${state}`}>
          {sentence(state)}
        </span>
        {presence ? (
          <span className="status-badge">{sentence(presence)}</span>
        ) : null}
        {node.hasActiveDependents ? (
          <span className="status-badge">Active dependents</span>
        ) : null}
      </div>

      {node.stallReason || node.launchFailure || node.resolution ? (
        <div className="inspector-callout" role="status">
          {node.stallReason ? <p>{node.stallReason}</p> : null}
          {node.launchFailure ? (
            <p>Launch failure: {enumLabel(node.launchFailure)}</p>
          ) : null}
          {node.resolution ? (
            <p>Resolution: {enumLabel(node.resolution)}</p>
          ) : null}
        </div>
      ) : null}

      <div className="inspector-actions" aria-label="Loop actions">
        {primaryCommands.map((command) => (
          <button
            key={command.id}
            type="button"
            disabled={!command.enabled || pendingCommandId === command.id}
            title={command.disabledReason}
            onClick={() => onExecuteCommand(command)}
          >
            {command.label.replace(" Loop", "")}
          </button>
        ))}
        <CommandMenu
          commands={overflowCommands}
          pendingCommandId={pendingCommandId}
          onExecute={onExecuteCommand}
        />
      </div>

      <div className="inspector-scroll">
        <InspectorSection title="Overview">
          <Detail label="State" value={sentence(state)} />
          <Detail label="Presence" value={sentence(presence)} />
          <Detail label="Activity" value={node.activity} />
          <Detail label="Backend" value={sentence(node.backend)} />
          <Detail
            label="Model"
            value={sentence(node.modelTier) ?? "Agent default"}
          />
          <Detail label="Session restarts" value={node.sessionRestarts} />
          <Detail label="Created" value={formatDate(node.createdAt)} />
        </InspectorSection>

        <InspectorSection title="Brief">
          <Detail label="Instruction" value={node.firstInstruction} />
          <Detail label="Timed prompt" value={node.triggerPrompt} />
          <Detail label="Verify each turn" value={node.checkDescription} />
          <Detail
            label="Pause policy"
            value={
              node.pausesBeforeWritesOnly
                ? "Pause before writes only"
                : node.loopType === "turnBased"
                  ? "Pause after every turn"
                  : undefined
            }
          />
          <Detail label="Goal" value={node.goal?.summary} />
          <Detail label="Predicate" value={node.goal?.predicate} code />
        </InspectorSection>

        {node.goal ? (
          <InspectorSection title="Goal and metrics">
            <Detail
              label="Poll interval"
              value={formatDuration(node.goal.pollIntervalSeconds)}
            />
            <Detail
              label="Stall after"
              value={formatDuration(node.goal.stallAfterSeconds) ?? "No limit"}
            />
            <Detail
              label="Metric command"
              value={node.goal.metricCommand}
              code
            />
            <Detail
              label="Metric direction"
              value={sentence(node.goal.metricDirection)}
            />
            <Detail
              label="Token budget"
              value={node.goal.tokenBudget?.toLocaleString()}
            />
            <Detail
              label="Unchanged workspace"
              value={
                node.goal.skipsUnchangedWorkspace
                  ? "Skip repeated predicate checks"
                  : "Check every poll"
              }
            />
            <Detail
              label="Latest metric"
              value={node.metricHistory?.at(-1)?.value}
            />
            <Detail label="Metric samples" value={node.metricHistory?.length} />
          </InspectorSection>
        ) : null}

        <InspectorSection title="Usage">
          <Detail label="Input tokens" value={node.usage?.inputTokens} />
          <Detail label="Output tokens" value={node.usage?.outputTokens} />
          <Detail label="Total tokens" value={totalTokens} />
          <Detail
            label="Reported cost"
            value={
              node.usage?.costUSD === undefined
                ? undefined
                : `$${node.usage.costUSD.toFixed(4)}`
            }
          />
          <Detail label="Reported" value={formatDate(node.usage?.reportedAt)} />
        </InspectorSection>

        {node.worktreeBinding ? (
          <InspectorSection title="Worktree">
            <Detail label="Branch" value={node.worktreeBinding.branch} />
            <Detail
              label="Worktree path"
              value={node.worktreeBinding.worktreePath}
              code
            />
            <Detail
              label="Repository"
              value={node.worktreeBinding.repositoryPath}
              code
            />
          </InspectorSection>
        ) : null}

        <InspectorSection title="Activity and summary">
          <Detail label="Current activity" value={node.activity} />
          <Detail label="Current pass" value={node.summary?.currentPass} />
          <Detail label="Latest beat" value={detailText(currentBeat)} />
          <Detail label="Summary beats" value={node.summary?.beats.length} />
          <Detail label="Pass summaries" value={node.summary?.passes.length} />
          <Detail
            label="Board"
            value={node.board?.title ?? enumLabel(node.board?.form)}
          />
          <Detail label="Board pass" value={node.board?.pass} />
        </InspectorSection>

        <InspectorSection title="Attachments and provenance">
          <Detail label="Attachments" value={node.attachments?.length} />
          {node.attachments?.map((attachment, index) => (
            <Detail
              key={attachment.id}
              label={`Attachment ${index + 1}`}
              value={attachment.path.split(/[\\/]/).at(-1)}
              code
            />
          ))}
          <Detail label="Created by loop" value={node.createdBy} code />
          <Detail label="Template ID" value={node.createdFromTemplateID} code />
          <Detail
            label="Following template"
            value={node.templateFollow?.name}
          />
          <Detail
            label="Template status"
            value={
              node.templateFollow?.missing
                ? "Missing; using snapshot"
                : undefined
            }
          />
        </InspectorSection>

        <InspectorSection title="Mailroom and memory">
          <Detail
            label="Project posts"
            value={graph.mailroomDigest?.count ?? mailbox?.digest.count}
          />
          <Detail label="Last read post" value={node.lastMailroomRead} />
          <Detail
            label="Mailroom watch"
            value={
              node.mailroomWatch
                ? node.mailroomWatch.topic
                  ? `Topic: ${node.mailroomWatch.topic}`
                  : "All posts"
                : "Off"
            }
          />
          <Detail
            label="Memory history"
            value="Requires daemon investigation DT-001"
          />
        </InspectorSection>

        {mailbox ? (
          <section className="inspector-section mailroom-board">
            <h3>Mailroom board</h3>
            {mailbox.posts.length ? (
              <ol>
                {mailbox.posts.map((post) => (
                  <li key={post.id}>
                    <header>
                      <strong>{post.author}</strong>
                      <span>#{post.id}</span>
                    </header>
                    {post.topic ? <small>{post.topic}</small> : null}
                    <p>{post.body}</p>
                  </li>
                ))}
              </ol>
            ) : (
              <p>The Mailroom is empty.</p>
            )}
            {mailbox.bodiesTrimmed ? (
              <p className="field-warning">
                Bodies were triaged by the daemon; refresh requests full bodies.
              </p>
            ) : null}
            <dl>
              <Detail label="Room posts" value={mailbox.digest.count} />
              <Detail label="Cursor before read" value={mailbox.lastRead} />
              <Detail
                label="Highest delivered"
                value={mailbox.highestDeliveredID}
              />
              <Detail label="Unread remaining" value={mailbox.remaining} />
              <Detail label="Pruned unread" value={mailbox.prunedUnread} />
            </dl>
          </section>
        ) : null}

        {node.subGraph || node.loopType === "proactive" ? (
          <InspectorSection title="Composite">
            <Detail label="Pilot state" value={enumLabel(node.pilotState)} />
            <Detail
              label="Child loops"
              value={node.subGraph?.nodes.length ?? 0}
            />
            <Detail
              label="Child edges"
              value={node.subGraph?.edges.length ?? 0}
            />
          </InspectorSection>
        ) : null}

        <InspectorSection title="Identity">
          <Detail label="Node ID" value={node.id} code />
          <Detail label="Graph ID" value={graph.id} code />
        </InspectorSection>
      </div>
    </aside>
  );
}
