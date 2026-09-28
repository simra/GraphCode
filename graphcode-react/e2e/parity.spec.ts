import { expect, test, type Page } from "@playwright/test";

const projectPath = "C:\\fixtures\\GraphCode E2E";
const sketchId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";

const envelopes = [
  {
    version: 2,
    kind: "event",
    sequence: 1,
    event: {
      recentProjectsListed: [{ path: projectPath, name: "GraphCode E2E" }],
    },
  },
  {
    version: 2,
    kind: "event",
    sequence: 2,
    event: {
      quickChatsListed: [],
    },
  },
  {
    version: 2,
    kind: "event",
    sequence: 3,
    event: {
      graphChanged: {
        id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
        revision: 7,
        project: { path: projectPath, name: "GraphCode E2E" },
        mailroomDigest: { count: 1, latestID: 12, fingerprint: 12 },
        nodes: [
          {
            id: sketchId,
            title: "Test session",
            loopType: "sketch",
            backend: "copilotCLI",
            state: { idle: {} },
            activity: "Ready for attended work",
            summary: {
              beats: [
                {
                  id: "beat-1",
                  at: "2026-09-28T18:00:00Z",
                  pass: 1,
                  kind: "reading",
                  text: "Mapped the parity requirements",
                  endsTurn: false,
                },
                {
                  id: "beat-2",
                  at: "2026-09-28T18:01:00Z",
                  pass: 1,
                  kind: "editing",
                  text: "Added the workspace rail",
                  evidence:
                    "graphcode-react/src/components/LoopWorkspaceRail.tsx",
                  endsTurn: true,
                },
              ],
              passes: [
                {
                  pass: 1,
                  text: "Implemented the first parity wave",
                  delta: "Sketch terminal, rail, and navigation",
                },
              ],
              currentPass: 1,
              lastTurnAt: "2026-09-28T18:01:00Z",
            },
            board: {
              form: "flow",
              title: "Parity work",
              direction: "leftRight",
              nodes: [
                { id: "audit", text: "Audit", shape: "rounded" },
                { id: "ship", text: "Ship", shape: "terminal" },
              ],
              edges: [
                {
                  from: "audit",
                  to: "ship",
                  label: "validated",
                  style: "solid",
                },
              ],
              pass: 1,
              composedAt: "2026-09-28T18:01:00Z",
              source: "flowchart LR; audit --> ship",
            },
          },
          {
            id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            title: "Timed worker",
            loopType: "timeBased",
            backend: "copilotCLI",
            state: { idle: {} },
            triggerPrompt: "/every 1h check status",
          },
        ],
        edges: [],
      },
    },
  },
  {
    version: 2,
    kind: "event",
    sequence: 4,
    event: {
      mailbox: {
        projectPath,
        mailbox: {
          posts: [
            {
              id: 12,
              at: "2026-09-28T18:02:00Z",
              author: "Test coordinator",
              topic: "parity",
              body: "Validate the integrated workspace.",
              kind: "notice",
            },
          ],
          bodiesTrimmed: false,
          digest: { count: 1, latestID: 12, fingerprint: 12 },
          lastRead: 0,
          highestDeliveredID: 0,
          remaining: 0,
          prunedUnread: 0,
        },
      },
    },
  },
];

async function installTauriMock(page: Page) {
  await page.addInitScript(
    ({ daemonEnvelopes }) => {
      type Callback = (payload: unknown) => void;
      type TauriMockWindow = Window & {
        __TAURI_INTERNALS__: {
          invoke(
            command: string,
            args?: Record<string, unknown>,
          ): Promise<unknown>;
          transformCallback(callback: Callback, once?: boolean): number;
          unregisterCallback(id: number): void;
          convertFileSrc(path: string): string;
        };
        __TAURI_EVENT_PLUGIN_INTERNALS__: {
          unregisterListener(event: string, id: number): void;
        };
        __GRAPHCODE_E2E_COMMANDS__: unknown[];
      };

      const target = window as TauriMockWindow;
      const callbacks = new Map<
        number,
        { callback: Callback; once: boolean }
      >();
      const listeners = new Map<string, number[]>();
      let nextCallbackId = 1;
      target.__GRAPHCODE_E2E_COMMANDS__ = [];

      function runCallback(id: number, payload: unknown) {
        const registered = callbacks.get(id);
        if (!registered) return;
        registered.callback(payload);
        if (registered.once) callbacks.delete(id);
      }

      function emit(event: string, payload: unknown) {
        for (const id of listeners.get(event) ?? []) {
          runCallback(id, { event, id, payload });
        }
      }

      target.__TAURI_INTERNALS__ = {
        async invoke(command, args = {}) {
          if (command === "plugin:event|listen") {
            const event = String(args.event);
            const id = Number(args.handler);
            listeners.set(event, [...(listeners.get(event) ?? []), id]);
            return id;
          }
          if (command === "plugin:event|unlisten") {
            const event = String(args.event);
            const id = Number(args.id);
            listeners.set(
              event,
              (listeners.get(event) ?? []).filter(
                (listenerId) => listenerId !== id,
              ),
            );
            return null;
          }
          if (command === "start_daemon_connection") {
            queueMicrotask(() => {
              emit("daemon://status", {
                phase: "connected",
                endpoint: "\\\\.\\pipe\\graphcode-e2e",
                attempt: 1,
              });
              for (const envelope of daemonEnvelopes) {
                emit("daemon://frame", envelope);
              }
            });
            return {
              endpoint: "\\\\.\\pipe\\graphcode-e2e",
              clientId: "playwright",
            };
          }
          if (command === "load_navigation_history") {
            return { version: 1, entries: [] };
          }
          if (command === "load_ui_layout") {
            return { version: 1, projects: {} };
          }
          if (command === "send_daemon_command") {
            target.__GRAPHCODE_E2E_COMMANDS__.push(args.command);
            return {
              version: 2,
              kind: "response",
              requestID: crypto.randomUUID(),
              success: true,
            };
          }
          if (command === "open_terminal") {
            return { handle: "terminal-e2e", sessionName: "graphcode-e2e" };
          }
          return null;
        },
        transformCallback(callback, once = false) {
          const id = nextCallbackId++;
          callbacks.set(id, { callback, once });
          return id;
        },
        unregisterCallback(id) {
          callbacks.delete(id);
        },
        convertFileSrc(path) {
          return path;
        },
      };
      target.__TAURI_EVENT_PLUGIN_INTERNALS__ = {
        unregisterListener(event, id) {
          listeners.set(
            event,
            (listeners.get(event) ?? []).filter(
              (listenerId) => listenerId !== id,
            ),
          );
          callbacks.delete(id);
        },
      };
    },
    { daemonEnvelopes: envelopes },
  );
}

test.beforeEach(async ({ page }) => {
  await installTauriMock(page);
  await page.goto("/", { waitUntil: "domcontentloaded" });
  await expect(
    page.getByText("Connected to graphcoded", { exact: true }),
  ).toBeVisible();
  await expect(
    page.getByText("GraphCode E2E", { exact: true }).first(),
  ).toBeVisible();
});

test("opens an attended sketch with its summary, board, and Mailroom rail", async ({
  page,
}) => {
  await page.getByText("Test session", { exact: true }).first().click();
  await expect(
    page.getByRole("heading", { name: "Test session", exact: true }),
  ).toBeVisible();

  await page.getByRole("button", { name: "Open Terminal" }).click();

  await expect(
    page.getByRole("region", { name: "Test session terminal" }),
  ).toBeVisible();
  await expect(page.getByText("Added the workspace rail")).toBeVisible();
  await expect(page.getByText("Parity work", { exact: true })).toBeVisible();
  await expect(
    page.getByText("Validate the integrated workspace."),
  ).toBeVisible();

  await page.getByRole("button", { name: "Expand board" }).click();
  const boardDialog = page.getByRole("dialog", { name: "Parity work" });
  await expect(boardDialog).toBeVisible();
  await page.keyboard.press("Escape");
  await expect(boardDialog).toBeHidden();
  await expect(
    page.getByRole("button", { name: "Expand board" }),
  ).toBeFocused();
});

test("prepares the attended sketch before opening its terminal", async ({
  page,
}) => {
  await page.getByText("Test session", { exact: true }).first().click();
  await page.getByRole("button", { name: "Open Terminal" }).click();

  await expect
    .poll(async () =>
      page.evaluate(() => {
        const target = window as Window & {
          __GRAPHCODE_E2E_COMMANDS__: unknown[];
        };
        return target.__GRAPHCODE_E2E_COMMANDS__;
      }),
    )
    .toContainEqual({
      openNodeSession: {
        projectPath,
        nodeID: sketchId,
      },
    });
});

test("retypes a timed loop to a goal loop in place", async ({ page }) => {
  await page.getByText("Timed worker", { exact: true }).first().click();
  await page.getByRole("button", { name: "More loop actions" }).click();
  await page.getByRole("menuitem", { name: "Change to Goal Loop" }).click();

  const dialog = page.getByRole("dialog", {
    name: "Change Timed worker to Goal",
  });
  await expect(dialog).toBeVisible();
  await dialog
    .getByRole("textbox", { name: "What does done look like?" })
    .fill("The status check passes");
  await dialog.getByRole("button", { name: "Change", exact: true }).click();

  await expect
    .poll(async () =>
      page.evaluate(() => {
        const target = window as Window & {
          __GRAPHCODE_E2E_COMMANDS__: unknown[];
        };
        return target.__GRAPHCODE_E2E_COMMANDS__;
      }),
    )
    .toContainEqual({
      graphCommand: {
        projectPath,
        command: {
          promoteNode: {
            _0: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            promotion: {
              goal: {
                _0: {
                  summary: "The status check passes",
                  predicate: null,
                  pollIntervalSeconds: 60,
                  stallAfterSeconds: null,
                  metricCommand: null,
                  metricDirection: "maximize",
                  tokenBudget: null,
                  skipsUnchangedWorkspace: false,
                },
              },
            },
            promotedBy: null,
          },
        },
      },
    });
});
