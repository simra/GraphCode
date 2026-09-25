# React + Tauri frontend rewrite implementation plan

## Status and scope

This plan introduces `graphcode-react`, a React + TypeScript client hosted by
Tauri v2, beside the existing `graphcode-windows` Zig/Win32 client. The daemon
remains authoritative. The existing client must ship until the new client meets
the parity and migration gates below.

The initial vertical slice is implemented in this branch:

- a Vite/React/TypeScript application and Tauri v2 host;
- strict protocol-v2 envelope and graph snapshot decoding based on
  `GraphcodeKit/Sources/IPC/DaemonWireProtocol.swift`,
  `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`, and frozen Windows fixtures;
- reducer state for recent projects, full graph snapshots, `nodesChanged` deltas,
  sequence de-duplication, and explicit protocol errors;
- a Rust endpoint/transport/protocol bridge that derives the authenticated
  Windows pipe name, negotiates v2, announces delta support, requests restore and
  recent-project state, and returns received frames;
- an accessible application shell, project navigation, connection state, and a
  focused SVG graph preview;
- explicit fixture fallback when a live daemon is unavailable.

The connection layer now has a persistent Rust actor with stable client identity,
request correlation, acknowledged replay cursors, reconnect/resync handling and
explicit unknown-outcome errors. It still needs daemon-restart integration tests
and byte-based queue limits. The slice does **not** yet provide graph mutation
forms, settings, terminal streaming, packaging, or production parity.

## Goals

1. Preserve `graphcoded` as the only owner of graph mutation, orchestration,
   persistence, project membership, mailroom state, worktrees, quick chats,
   predicates, sessions, and settings policy.
2. Reuse the four-byte big-endian framed v1/v2 daemon protocol. Do not introduce a
   REST service, WebSocket proxy, or second state authority.
3. Put transport, authentication, framing, handshake, replay, request correlation,
   and backpressure in Rust. React receives typed domain events and invokes typed
   commands; it never opens a raw pipe/socket.
4. Put navigation, forms, graph interaction, terminal presentation,
   accessibility, styling, theming, responsive layout, and DPI behavior in React.
5. Preserve zmx as terminal-session owner while replacing Winghostty HWND embedding
   with xterm.js and a native zmx streaming bridge.
6. Run old and new clients concurrently against the same daemon throughout the
   migration.

## Non-goals

- Reimplementing daemon business rules in TypeScript or Rust.
- Changing persisted graph formats for the frontend rewrite.
- Removing v1 support from the daemon.
- Replacing zmx, backend CLIs, worktree ownership, or transcript stores.
- Embedding the existing Winghostty child HWND in WebView2.
- Shipping an Electron fallback.
- Deleting or freezing `graphcode-windows` before production parity.

## Decisions

### Host and application architecture

- **Tauri v2** provides native window lifecycle, menus, folder pickers,
  notifications, updates, deep links, process bootstrap, and daemon discovery with
  a materially smaller runtime than Electron.
- **React 19 + TypeScript strict mode** owns the UI. Domain state is framework-free
  reducer/store code so protocol tests do not require a browser.
- **Vite** provides development and production bundling.
- **Zod** validates untrusted daemon JSON at the Rust/React boundary. Compile-time
  interfaces alone are insufficient for protocol evolution or malformed frames.
- Start with reducer/context state. Adopt Zustand only if component update pressure
  or cross-cutting command state becomes measurable; do not add Redux/TanStack
  Query because daemon events, not HTTP cache entries, are authoritative.
- The first graph uses a focused SVG implementation. GraphCode currently needs
  cards, directed edges, selection, keyboard navigation, zoom/pan, edge creation,
  composite drill-in, and deterministic persisted layout, not React Flow's full
  node-editor surface. SVG avoids roughly a framework-sized dependency and gives
  direct ARIA control. Re-evaluate React Flow before interactive edge editing:
  choose it only if connection handles, viewport virtualization, and nested graph
  ergonomics save more maintained code than its bundle and accessibility cost.

### Repository layout

```text
graphcode-react/
  src/
    bridge/              typed Tauri invocation/event adapter
    components/          shell, sidebar, graph, forms, terminal, settings
    protocol/            generated/mirrored wire and domain types, validators
    state/               connection, projects, graphs, navigation, commands
    fixtures/            frozen fallback/golden protocol data
  src-tauri/
    src/
      endpoint.rs        platform endpoint discovery
      transport.rs       named-pipe/Unix-socket abstraction
      protocol.rs        framing and v2 negotiation
      connection.rs      future actor: replay, requests, subscriptions
      terminal.rs        future zmx streaming manager
      commands.rs        Tauri command surface
```

The design record lives under `investigation/` because the repository ignores
most of `docs/`; this keeps the implementation plan versioned without changing the
published GitHub Pages contract.

## Existing capability inventory

The parity source of truth is `investigation/ui-parity-matrix.md`, supplemented by
`graphcode-windows/src/App.zig`, `GraphCanvas.zig`, `Sidebar.zig`,
`TerminalSurface.zig`, the native form/dialog modules, and Windows validation
scripts.

| Surface | Existing capability | React/Tauri target |
| --- | --- | --- |
| Shell | Win32 window, menu bar, tray, lifecycle, daemon supervision, updater | Tauri window/menu/tray/process/update plugins with Rust lifecycle coordinator |
| Navigation | Local/remote project groups, global graph, Quick Chats, attention/activity, jump palette | Semantic sidebar/tree, router-free destination state, command palette |
| Projects | Open folder, clone HTTPS/SSH, Codespaces, close/forget/delete, recent/open restore | Native pickers and Rust process adapters; daemon commands remain authoritative |
| Graph | Full snapshots, cards/edges, selection, pan/zoom, create/edit/delete, composite drill-in | SVG or React Flow canvas, keyboard model, typed daemon mutations |
| Forms | Node, edge, settings, repository, project, worktree, import/export | React forms with schema validation; native pickers only where OS access is needed |
| Workspaces | Graph/terminal switch, tabs, split panes, layout persistence | React split/tab model persisted via Tauri settings and daemon-owned session IDs |
| Terminals | Winghostty HWND attached to persistent zmx session | xterm.js attached through Rust to the same zmx session |
| Quick Chats | Create/open/rename/delete/activity | Typed daemon events and chat workspace |
| Settings | Product/UI/provider/update settings and experimental flags | React settings with Rust file/native adapters; no invented daemon settings command |
| Updates | GitHub release checks, offer/install/relaunch path | Signed Tauri updater after packaging/signing decision; preserve channel semantics |
| Accessibility | UI Automation provider, keyboard shortcuts, native controls | Semantic HTML/ARIA, roving focus, shortcut registry, automated axe and screen-reader gates |
| DPI/theme | Per-monitor-v2 scaling and native dark tokens | WebView device-pixel scaling, CSS logical pixels/tokens, 100–300% test matrix |

## Daemon protocol reuse

### Authoritative wire behavior

- Frame: four-byte big-endian length followed by UTF-8 JSON.
- v2 payload maximum: 1 MiB. Legacy v1 ceiling: 2 MiB.
- v2 envelope fields and validation are defined by
  `DaemonWireEnvelope` in `DaemonWireProtocol.swift`.
- Hello sends `[1, 2]`, a stable `clientID`, optional `resumeFrom`, and optional
  `subscription.projectPaths`; the daemon selects the highest common version.
- Requests are correlated only by `requestID`.
- Subscription events have monotonically increasing per-logical-client sequence
  numbers. Responses and errors are not replayed.
- Replay is strictly after `resumeFrom`, retained for 128 events by default, and
  can fail with `replayUnavailable` or `cursorOutsideWindow`.
- `graphChanged` is the authoritative full snapshot. `nodesChanged` is opt-in via
  `announce(["nodesChanged"])` and applies only when its graph revision is newer.
- Omitted subscription paths mean all joined projects. A list is an allow-list.
- Join snapshots may create non-replayable sequence gaps; clients must not require
  contiguous sequence numbers.

### Rust connection actor

The connection actor uses one Tokio task owning the raw stream:

1. Discover endpoint and connect with a bounded timeout.
2. Load or create a stable client UUID in Tauri app data.
3. Send hello with the saved replay cursor and current subscription.
4. Validate selected protocol version.
5. Start one serialized writer queue and one reader loop.
6. Send `announce(nodesChanged)`, `restoreOpenProjects`,
   `openGlobalGraph`, `listRecentProjects`, and `listQuickChats`.
7. Resolve pending requests by request ID; emit sequenced events to React.
8. Persist `lastAppliedSequence` only after React/state acknowledges successful
   application, not merely after the pipe read.
9. On EOF, daemon restart, timeout, or transport error, fail in-flight requests
   explicitly, retain desired joins/subscription, and retry with full-jitter
   exponential backoff (100 ms to 4 s, matching the Windows client).
10. On replay failure, clear the cursor, reconnect, issue fresh restore/global/chat
    joins, and replace snapshots. Surface a nonfatal resync reason to the UI.
11. Bound writer count/bytes and event-emission count/bytes. Reject new commands
    with `clientBackpressure` rather than growing memory.

No reader may infer that an unrelated event acknowledges a command. A reconnect
never retries non-idempotent mutations automatically; callers receive an
`outcomeUnknown` error and refresh the affected snapshot.

### Type generation and compatibility

Short term, TypeScript and Rust mirror the subset exercised by the client and use
golden JSON fixtures from `graphcode-windows/fixtures` plus Swift-produced fixtures.
Every mirrored case must cite its Swift source and have decode tests.

Phase 2 adds a repository tool that compiles a small Swift executable against
GraphcodeKit and emits:

- JSON Schema for envelope/domain structs;
- a manifest of enum cases and associated labels;
- canonical sample JSON for every command/event case.

TypeScript types/validators are generated from that artifact and checked in.
Behavioral rules (framing, negotiation, replay, request correlation, endpoint
security) remain hand-written and tested because they are not Codable shape.
CI fails when regenerated output differs. Additive unknown daemon events decode to
an explicit `unsupported` case and a diagnostic; malformed known cases fail.

## Terminal streaming design

### Ownership and lifecycle

zmx remains the session owner. The Rust bridge attaches to the session name derived
from the loop UUID (`SurfaceRef(id:).zmxSessionName`) and exposes a Tauri channel
identified by an opaque terminal handle. Closing a pane detaches the client only;
it never kills the zmx session. Stop/restart/delete continue through daemon
commands.

### Native API

```text
terminal_attach(nodeID, cols, rows, scrollbackCursor?) -> handle + metadata
terminal_write(handle, bytes)
terminal_resize(handle, cols, rows, pixelWidth, pixelHeight)
terminal_ack(handle, highestChunkSequence)
terminal_detach(handle)
terminal_history(nodeID, beforeCursor, byteLimit) -> bounded chunks
```

Rust emits `terminal://chunk`, `terminal://state`, and `terminal://error` events
containing handle, monotonic chunk sequence, bytes (binary channel where supported,
base64 only as a measured fallback), and replay/scrollback cursors.

### Attach/read/write semantics

- Attach uses zmx's real bidirectional attach protocol or a pinned zmx library;
  spawning a line-oriented `zmx attach` subprocess is acceptable only if it
  preserves raw VT bytes, resize controls, labels, detach, and exit status.
- Rust reads raw VT output and writes it to xterm.js without text transcoding.
- Input is UTF-8/raw terminal bytes. Paste is chunked and bounded; bracketed-paste
  sequences remain xterm.js terminal behavior.
- Resize is coalesced (latest wins, at most one update per animation frame) and sent
  through zmx's control channel. Initial dimensions are sent before output replay.
- zmx scrollback is authoritative for detached periods. Attach returns a cursor and
  enough state/output to reconstruct the terminal. The client de-duplicates chunks
  by sequence/cursor.
- Transcript/history views are separate from terminal scrollback and use existing
  backend transcript stores through a future daemon/native read API; terminal output
  is not treated as a durable transcript.

### Flow control and reconnect

- Each terminal has bounded native and WebView queues by bytes and chunk count.
- React acknowledges rendered chunk sequences. If the window falls behind, Rust
  pauses reads when zmx permits; otherwise it drops the attachment, reports
  `terminalConsumerTooSlow`, and allows reattach from scrollback.
- On WebView reload, process sleep, daemon reconnect, or zmx attach loss, the pane
  reattaches using node ID plus the last scrollback cursor. Duplicate bytes are
  discarded. A missing/dead session is reported distinctly from transport failure.
- One writer lease per node is the default. Additional panes are read-only unless the
  user explicitly transfers input ownership. This avoids two WebViews typing into one
  agent session accidentally.

### Terminal security

- Node IDs are validated UUIDs and mapped internally to zmx session names; React
  cannot submit an arbitrary executable or session path.
- Rust launches only the pinned/discovered zmx binary and never interpolates shell
  command strings.
- Terminal handles are random, window-scoped capabilities.
- OSC 52 clipboard, file hyperlinks, shell integration, and URL opening are denied by
  default and enabled through explicit allow-lists/prompts.
- Output, input, and transcript text are excluded from telemetry. Logs contain IDs,
  byte counts, durations, and error codes only.

Use `@xterm/xterm`, `@xterm/addon-fit`, and optionally WebGL after a compatibility
gate. Dispose addons/listeners on every pane close and WebView reload.

## React modules and state boundaries

- `ConnectionProvider`: bridge lifecycle, status, replay/resync diagnostics.
- `ProjectStore`: recent/open projects, selected destination, stable path identity.
- `GraphStore`: snapshots by project path, revisions, node deltas, optimistic
  command markers only (never optimistic graph truth).
- `CommandBus`: typed request IDs, pending state, cancellation, explicit daemon
  errors, no silent retry of mutations.
- `Shell`: header, menu command bindings, responsive regions.
- `Sidebar`: project groups, loop tree, Quick Chats, attention, activity.
- `GraphCanvas`: viewport/layout, selection, edge/node interaction, composite stack.
- `LoopForms`: create/edit/promote/message/stop/restart/delete workflows.
- `Workspace`: terminal tabs/splits, graph return, panel visibility, persisted layout.
- `Settings`: UI/local settings and native adapters; daemon-owned settings continue
  through the existing settings file/store contract until an authoritative settings
  command exists.
- `NativeServices`: folder picker, notifications, updater, clipboard, process
  bootstrap, menus, tray.

Selectors isolate high-frequency presence/terminal updates from shell rerenders.
Terminal byte streams never enter React application state.

## Accessibility and input

- Use semantic landmarks, lists, buttons, dialogs, forms, and status regions before
  adding ARIA.
- Implement roving focus for graph cards and tree rows, with stable focus by
  project/node ID across snapshots.
- Graph keyboard model: arrows navigate spatially, Enter opens, Space selects,
  Delete requests deletion, Ctrl+N creates, Ctrl+E edits, Ctrl+J advances, Ctrl+P
  opens jump, Ctrl+Tab advances attention. Shortcuts are discoverable and disabled
  while a conflicting text field/dialog owns input.
- SVG nodes expose accessible names and edge relationships; provide a synchronized
  textual graph outline for screen readers once edges become interactive.
- Respect reduced motion, high contrast, text scaling, OS zoom, and 200%/300% DPI.
- Gate releases with axe, keyboard-only Playwright tests, Windows Narrator smoke,
  and contrast checks.

## DPI, responsive layout, and theming

- CSS pixels remain logical units; do not manually multiply layout by device scale.
- Observe `devicePixelRatio`, resize, and monitor moves only for canvas/terminal
  backing-store resolution and zmx cell metrics.
- Use CSS custom properties generated from the canonical GraphCode theme tokens.
  Preserve dark palette fidelity from `Theme.swift`/`DesignTokens.zig`; add light
  theme only as a separate product decision.
- Test 100%, 125%, 150%, 200%, and 300%, narrow window, ultrawide, and monitor moves.
- Sidebar collapses into an overlay/navigation sheet below the compact breakpoint;
  graph and terminal remain independently scrollable.

## Performance budgets

- Initial JS (excluding xterm loaded on demand): target < 250 KiB gzip.
- Idle React commit rate: zero; presence deltas rerender only changed cards.
- Snapshot decode/apply p95: < 16 ms for 250 nodes, < 50 ms for 1,000 nodes.
- Canvas pan/zoom: 60 fps target; virtualize/offscreen-cull above 250 visible cards.
- Terminal input echo and bridge overhead p95: < 30 ms locally.
- Native event and command queues are bounded. Record queue depth and drops.
- Lazy-load terminals, settings, import/export, and update UI.

## Security

- Preserve OS-level per-user pipe/socket security and the Windows
  SID/support-hash/rendezvous-secret endpoint. The client reads but never creates or
  rotates the daemon secret.
- Enforce frame ceilings before allocation and validate envelope fields before
  dispatch.
- Keep CSP restrictive; no remote scripts, eval, arbitrary navigation, or remote
  content in the WebView.
- Minimize Tauri permissions/capabilities. Expose narrow commands rather than shell,
  filesystem, or process plugins directly to JavaScript.
- Canonicalize and validate paths in Rust. Folder picker grants do not imply broad
  filesystem access.
- Redact prompts, terminal content, paths (unless opted in), tokens, and rendezvous
  material from logs/crash reports.
- Verify updater signatures and HTTPS origin; no unsigned in-app execution.
- Threat-model deep links, imported bundles, OSC sequences, URL opening, clipboard,
  and daemon downgrade before enabling them.

## Packaging, updates, and daemon bootstrap

Phase 5 extends existing Windows staging rather than replacing it immediately:

1. Build React assets and Tauri executable with pinned Node/Rust toolchains.
2. Stage `graphcode-react.exe` beside `graphcode-windows.exe`, `graphcoded.exe`,
   `graphcode.exe`, `zmx.exe`, Swift runtime DLLs, notices, and provenance.
3. Add a developer-only selector/feature flag; keep the Zig shell default.
4. Tauri/Rust locates the packaged daemon relative to the executable, then uses the
   existing lifetime/startup lock and readiness publication contract. It never starts
   a second daemon for the same support directory.
5. Reuse stable/beta release-channel semantics. Move to Tauri updater only after
   signing, rollback, scheduled-task, and relaunch tests cover the same contracts as
   `Tools/windows/package.ps1`.
6. Produce MSIX/installer decisions separately; ZIP parity is the first gate.

macOS/Linux use the same frontend and protocol actor with Unix-domain sockets, but
platform packaging follows existing signing/notarization/distribution rules.

## Logging and telemetry

- Structured native logs: connection attempt, endpoint kind (not secret), negotiated
  version, reconnect reason, replay outcome, request command name/duration/result,
  queue depth, terminal byte counts, and updater state.
- Structured frontend diagnostics: route/surface, render timing, decoder error code,
  accessibility assertion failures. Never log payload bodies by default.
- Correlate requests with generated IDs but hash project paths in diagnostics.
- Default remains local logs only. Any product telemetry requires an explicit policy,
  consent, retention, and schema review; this rewrite does not add telemetry.

## Test strategy

### TypeScript

- Golden decode tests for every used Swift command/event and malformed envelopes.
- Reducer tests for snapshots, newer/stale deltas, duplicate replay events, project
  selection, reconnect resync, and explicit errors.
- Component tests for shell states/forms and axe checks.
- Property tests for event ordering and reducer idempotence.

### Rust

- Endpoint derivation golden tests for SID/support/secret hashes and overrides.
- Framing tests for partial reads/writes, boundaries, oversize, invalid UTF-8/JSON,
  and cumulative timeouts.
- Connection actor tests with an in-process fake pipe/socket: negotiation, interleaved
  response/event, replay, replay failure, backpressure, reconnect, and cancellation.
- zmx fake-server tests for attach/read/write/resize/history/slow-consumer behavior.

### Integration and end to end

- Run both clients against one daemon and assert snapshots/mutations converge.
- Reuse Swift-produced fixtures and `Tools/windows/Stub-Daemon.ps1`, extending it
  only with protocol-valid scenarios.
- Playwright/Tauri driver coverage for project restore, graph navigation, forms,
  workspace layout, settings, and updater prompts.
- Terminal gate with real pinned zmx: session survives client close/reload, input and
  resize work, scrollback reconstructs, two-pane lease policy holds.
- Packaging lifecycle, clean-machine, upgrade/rollback, UIA/Narrator, multi-DPI, and
  resource leak/stress gates.

## Migration phases and acceptance criteria

### Phase 0 — foundation (this branch)

Dependencies: none.

- Scaffold React/Tauri beside the existing client.
- Decode real v2 envelopes/snapshots and apply node deltas.
- Derive the platform endpoint and negotiate v2.
- Render connection state, projects, and a graph snapshot or labeled fixture.
- Add focused unit tests and developer instructions.

Acceptance: TypeScript format/check/test/build and Rust fmt/test/check pass; fixture
fallback is visibly distinct; no existing client files are changed.

### Phase 1 — production connection actor

Dependencies: Phase 0.

- Stable client ID, persistent connection, request map, event channels, bounded
  queues, reconnect/replay/resync, subscription updates, daemon bootstrap.
- Generated protocol artifact and golden compatibility CI.

Acceptance: daemon restart and 128-event replay tests pass; replay loss causes a
fresh authoritative snapshot; interleaved events never satisfy requests.

### Phase 2 — read parity

Dependencies: Phase 1.

- Recent/open/global projects, sidebar tree, Quick Chats, attention/activity,
  graph layout, composite drill-in, mailroom summaries, jump palette, settings read.

Acceptance: every read-only row in the parity matrix has automated evidence and
both clients show the same daemon state concurrently.

### Phase 3 — mutation and native integration parity

Dependencies: Phase 2.

- Node/edge forms and mutations, project lifecycle, repository/Codespace ingress,
  worktrees, import/export, settings writes, menus, tray, notifications.

Acceptance: mutation failures are visible and snapshots converge after every action;
folder/process access is only through narrow native commands.

### Phase 4 — terminal/workspace parity

Dependencies: Phase 1 for bridge; Phase 2 navigation.

- xterm.js, zmx stream bridge, tabs/splits, persisted layout, terminal controls,
  transcript/history surfaces.

Acceptance: real zmx gate verifies attach/input/resize/scrollback/reconnect, sessions
survive app restart, and slow consumers remain memory-bounded.

### Phase 5 — packaging, update, and accessibility release gate

Dependencies: Phases 3 and 4.

- Side-by-side package, signing/updater, lifecycle/bootstrap, crash diagnostics,
  full keyboard/Narrator/DPI/performance gates.

Acceptance: clean-machine install/upgrade/rollback passes; no critical parity gaps;
security review complete; React client can be selected as default behind rollback.

### Phase 6 — default switch and retirement

Dependencies: sustained Phase 5 production evidence.

- Make Tauri default, keep Zig fallback for at least one release, then remove only by
  a separate decision.

Acceptance: crash/connectivity/performance metrics meet or beat the native baseline,
support rollback is proven, and no daemon protocol fork exists.

## Risks and decision points

| Risk/decision | Mitigation / decision gate |
| --- | --- |
| zmx protocol integration is larger than expected | Build a standalone Rust zmx spike before terminal UI; require raw VT, resize, labels, detach, and scrollback proof |
| WebView terminal latency or memory | Binary channels, bounded queues, lazy loading, WebGL gate, stress benchmark |
| SVG canvas complexity grows | Re-evaluate React Flow at edge-editing milestone using bundle, a11y, nested graph, and virtualization prototypes |
| Swift Codable drift | Generated manifest/schema plus Swift golden fixtures in CI |
| Duplicate state authority | No optimistic graph mutation; daemon snapshot remains final |
| Replay cursor acknowledged too early | Persist only after state application acknowledgement |
| Settings lack daemon commands | Use existing settings store through narrow Rust adapter; do not invent protocol |
| Tauri updater differs from current rollback model | Keep current packaging path until signed update lifecycle tests reach parity |
| CSP/plugin capability creep | Deny by default, narrow custom commands, security review each plugin |
| Two clients contend for sessions | zmx writer lease; daemon/project subscriptions remain independent |
| Cross-platform endpoint drift | Golden tests against GraphcodeKit outputs on Windows and Unix |

## Executable task breakdown

1. **Protocol artifact generator** — depends on Phase 0; Swift emits schema/case
   manifest/golden values, TypeScript generation and CI diff check.
2. **Connection actor** — depends on protocol artifact; persistent Tokio owner,
   queues, requests, events, replay and subscription state.
3. **Daemon bootstrap** — depends on connection actor; reuse lifetime/startup lock,
   packaged executable discovery, readiness and owned-child shutdown.
4. **Project/graph stores** — depends on connection actor; restore/global/recents,
   revisions, deltas, stable selection and resync.
5. **Read-only shell parity** — depends on stores; sidebar, global graph, Quick Chats,
   attention/activity, composite navigation.
6. **Interactive canvas decision spike** — depends on read-only graph; compare SVG and
   React Flow against measured requirements, record decision.
7. **Mutation command bus/forms** — depends on stores and canvas decision; typed
   commands, validation, pending/error UX, no automatic mutation replay.
8. **Native service adapters** — depends on Tauri capability policy; folders, menus,
   tray, notifications, process/Codespace and settings.
9. **zmx Rust spike** — may run after connection actor; prove raw attach, resize,
   scrollback, labels, detach, reconnect and multi-attach policy.
10. **xterm workspace** — depends on zmx spike and shell navigation; channels,
    flow-control acknowledgements, tabs/splits and layout persistence.
11. **Packaging/signing/updater** — depends on native services and terminal workspace;
    side-by-side staging, provenance, clean-machine and rollback tests.
12. **Parity/security/accessibility gates** — continuous, final gate depends on all
    feature tasks; matrix evidence, threat model, Narrator, DPI and performance.
