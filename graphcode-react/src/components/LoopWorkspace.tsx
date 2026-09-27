import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useEffect, useRef, useState } from "react";
import {
  loadTerminalHistory,
  openTerminal,
  type TerminalConnection,
} from "../bridge/terminal";
import type { AppCommand } from "../commands/registry";
import type { LoopGraph, LoopNode } from "../protocol/domain";
import { NodeInspector } from "./NodeInspector";

type TerminalPhase = "connecting" | "connected" | "exited" | "failed";

export function LoopWorkspace({
  graph,
  node,
  commands,
  pendingCommandId,
  onBack,
  onExecuteCommand,
}: {
  graph: LoopGraph;
  node: LoopNode;
  commands: AppCommand[];
  pendingCommandId?: string;
  onBack(): void;
  onExecuteCommand(command: AppCommand): void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const connectionRef = useRef<TerminalConnection | undefined>(undefined);
  const [phase, setPhase] = useState<TerminalPhase>("connecting");
  const [error, setError] = useState<string>();
  const [historyTruncated, setHistoryTruncated] = useState(false);
  const nodeCommands = commands.filter(
    (command) => command.id !== "loop.openTerminal",
  );

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    let active = true;
    let resizeTimer: number | undefined;
    const terminal = new Terminal({
      cursorBlink: true,
      convertEol: false,
      fontFamily: '"Cascadia Mono", Consolas, monospace',
      fontSize: 13,
      screenReaderMode: true,
      scrollback: 10_000,
      theme: {
        background: "#0d0f0c",
        foreground: "#e3e8df",
        cursor: "#b9e4ad",
        selectionBackground: "#49654488",
      },
    });
    const fit = new FitAddon();
    terminal.loadAddon(fit);
    terminal.open(container);
    fit.fit();
    terminal.focus();

    const reportError = (value: unknown) => {
      if (!active) return;
      setPhase("failed");
      setError(value instanceof Error ? value.message : String(value));
    };

    void (async () => {
      try {
        const history = await loadTerminalHistory(node.id);
        if (!active) return;
        setHistoryTruncated(history.truncated);
        if (history.bytes.length) {
          await new Promise<void>((resolve) =>
            terminal.write(history.bytes, resolve),
          );
        }
        if (!active) return;
        const connection = await openTerminal(
          node.id,
          terminal.cols,
          terminal.rows,
          {
            onOutput(bytes, _sequence, acknowledge) {
              if (!active) return;
              terminal.write(bytes, () => {
                void acknowledge().catch(reportError);
              });
            },
            onError: reportError,
            onExit() {
              if (active) setPhase("exited");
            },
          },
        );
        if (!active) {
          await connection.close();
          return;
        }
        connectionRef.current = connection;
        terminal.onData((data) => {
          void connection.write(data).catch(reportError);
        });
        setPhase("connected");
      } catch (caught) {
        reportError(caught);
      }
    })();

    const resizeObserver = new ResizeObserver(() => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(() => {
        if (!active) return;
        fit.fit();
        void connectionRef.current
          ?.resize(terminal.cols, terminal.rows)
          .catch(reportError);
      }, 100);
    });
    resizeObserver.observe(container);

    return () => {
      active = false;
      resizeObserver.disconnect();
      window.clearTimeout(resizeTimer);
      const connection = connectionRef.current;
      connectionRef.current = undefined;
      if (connection) void connection.close();
      terminal.dispose();
    };
  }, [node.id]);

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
          {phase === "connecting"
            ? "Attaching…"
            : phase === "connected"
              ? "Live"
              : phase === "exited"
                ? "Session ended"
                : "Unavailable"}
        </div>
      </header>
      {historyTruncated ? (
        <p className="terminal-notice" role="status">
          Showing the newest 1 MiB of retained terminal history.
        </p>
      ) : null}
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
        <NodeInspector
          graph={graph}
          node={node}
          commands={nodeCommands}
          pendingCommandId={pendingCommandId}
          onClose={onBack}
          onExecuteCommand={onExecuteCommand}
        />
      </div>
    </section>
  );
}
