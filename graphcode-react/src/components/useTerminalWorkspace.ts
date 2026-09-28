import { FitAddon } from "@xterm/addon-fit";
import { Terminal } from "@xterm/xterm";
import "@xterm/xterm/css/xterm.css";
import { useEffect, useRef, useState } from "react";
import { openTerminal, type TerminalConnection } from "../bridge/terminal";

export type TerminalPhase = "connecting" | "connected" | "exited" | "failed";

const WINDOWS_ZMX_COLUMNS = 80;

export function useTerminalWorkspace(
  targetId: string,
  onSessionExit?: (succeeded: boolean) => Promise<void>,
) {
  const containerRef = useRef<HTMLDivElement>(null);
  const connectionRef = useRef<TerminalConnection | undefined>(undefined);
  const onSessionExitRef = useRef(onSessionExit);
  const [phase, setPhase] = useState<TerminalPhase>("connecting");
  const [error, setError] = useState<string>();
  onSessionExitRef.current = onSessionExit;

  useEffect(() => {
    const container = containerRef.current;
    if (!container) return;

    setPhase("connecting");
    setError(undefined);

    let active = true;
    let resizeTimer: number | undefined;
    let inputSubscription: { dispose(): void } | undefined;
    let lastSentColumns: number | undefined;
    let lastSentRows: number | undefined;
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

    const fitRows = () => {
      const proposed = fit.proposeDimensions();
      terminal.resize(
        WINDOWS_ZMX_COLUMNS,
        Math.max(1, proposed?.rows ?? terminal.rows),
      );
    };

    fitRows();
    terminal.focus();

    const reportError = (value: unknown) => {
      if (!active) return;
      setPhase("failed");
      setError(value instanceof Error ? value.message : String(value));
    };

    const fitAndResize = () => {
      if (!active) return;
      fitRows();
      const connection = connectionRef.current;
      if (
        !connection ||
        (terminal.cols === lastSentColumns && terminal.rows === lastSentRows)
      ) {
        return;
      }
      lastSentColumns = terminal.cols;
      lastSentRows = terminal.rows;
      void connection.resize(terminal.cols, terminal.rows).catch(reportError);
    };

    const scheduleFit = () => {
      window.clearTimeout(resizeTimer);
      resizeTimer = window.setTimeout(fitAndResize, 100);
    };

    void (async () => {
      try {
        const openedColumns = terminal.cols;
        const openedRows = terminal.rows;
        const connection = await openTerminal(
          targetId,
          openedColumns,
          openedRows,
          {
            onOutput(bytes, _sequence, acknowledge) {
              if (!active) return;
              terminal.write(bytes, () => {
                void acknowledge().catch(reportError);
              });
            },
            onError: reportError,
            onExit(code) {
              if (!active) return;
              setPhase("exited");
              if (onSessionExitRef.current) {
                void onSessionExitRef.current(code === 0).catch(reportError);
              }
            },
          },
        );
        if (!active) {
          await connection.close();
          return;
        }
        connectionRef.current = connection;
        lastSentColumns = openedColumns;
        lastSentRows = openedRows;
        inputSubscription = terminal.onData((data) => {
          void connection.write(data).catch(reportError);
        });
        fitAndResize();
        void document.fonts?.ready.then(() => {
          if (active) scheduleFit();
        });
        setPhase("connected");
      } catch (caught) {
        reportError(caught);
      }
    })();

    const resizeObserver = new ResizeObserver(scheduleFit);
    resizeObserver.observe(container);
    window.addEventListener("resize", scheduleFit);
    window.visualViewport?.addEventListener("resize", scheduleFit);

    return () => {
      active = false;
      resizeObserver.disconnect();
      window.removeEventListener("resize", scheduleFit);
      window.visualViewport?.removeEventListener("resize", scheduleFit);
      window.clearTimeout(resizeTimer);
      inputSubscription?.dispose();
      const connection = connectionRef.current;
      connectionRef.current = undefined;
      if (connection) void connection.close();
      terminal.dispose();
    };
  }, [targetId]);

  return { containerRef, phase, error };
}

export function terminalPhaseLabel(phase: TerminalPhase): string {
  return phase === "connecting"
    ? "Attaching…"
    : phase === "connected"
      ? "Live"
      : phase === "exited"
        ? "Session ended"
        : "Unavailable";
}
