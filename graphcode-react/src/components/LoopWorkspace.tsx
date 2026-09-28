import type { AppCommand } from "../commands/registry";
import type { LoopGraph, LoopNode, Mailbox } from "../protocol/domain";
import { LoopWorkspaceRail } from "./LoopWorkspaceRail";
import {
  terminalPhaseLabel,
  useTerminalWorkspace,
} from "./useTerminalWorkspace";

export function LoopWorkspace({
  graph,
  node,
  mailbox,
  mailroomOwned,
  seenBeatId,
  seenMailroomPostId,
  commands,
  pendingCommandId,
  onBack,
  onSummarySeen,
  onExecuteCommand,
  onSessionExit,
}: {
  graph: LoopGraph;
  node: LoopNode;
  mailbox?: Mailbox;
  mailroomOwned: boolean;
  seenBeatId?: string;
  seenMailroomPostId?: number;
  commands: AppCommand[];
  pendingCommandId?: string;
  onBack(): void;
  onSummarySeen(beatId: string): void;
  onExecuteCommand(command: AppCommand): void;
  onSessionExit(succeeded: boolean): Promise<void>;
}) {
  const { containerRef, phase, error } = useTerminalWorkspace(
    node.id,
    onSessionExit,
  );
  const nodeCommands = commands.filter(
    (command) => command.id !== "loop.openTerminal",
  );

  return (
    <section className="loop-workspace" aria-labelledby="loop-workspace-title">
      <header className="loop-workspace-header">
        <div>
          <button type="button" className="workspace-back" onClick={onBack}>
            ← Show in graph
          </button>
          <p className="eyebrow">{graph.project.name}</p>
          <h2 id="loop-workspace-title">{node.title}</h2>
        </div>
        <div className={`terminal-phase terminal-phase-${phase}`}>
          {terminalPhaseLabel(phase)}
        </div>
      </header>
      {error ? (
        <div className="terminal-error" role="alert">
          {error}
        </div>
      ) : null}
      <div className="loop-workspace-content">
        <div
          ref={containerRef}
          className="terminal-host"
          role="region"
          aria-label={`${node.title} terminal`}
        />
        <LoopWorkspaceRail
          graph={graph}
          node={node}
          mailbox={mailbox}
          mailroomOwned={mailroomOwned}
          seenBeatId={seenBeatId}
          seenMailroomPostId={seenMailroomPostId}
          commands={nodeCommands}
          pendingCommandId={pendingCommandId}
          onSummarySeen={onSummarySeen}
          onExecuteCommand={onExecuteCommand}
        />
      </div>
    </section>
  );
}
