# React/Tauri versus Zig/Win32 feature-parity review

Status: source-derived audit as of 2026-09-25.

This document compares the production `graphcode-windows` Zig/Win32 client with
the initial `graphcode-react` React/Tauri client. It is an implementation ledger
and UX recommendation, not a claim that the Win32 client is itself complete. When
the daemon supports more than the Win32 surface exposes, the daemon/domain model is
treated as the forward-compatible target.

## Sources reviewed

Authoritative implementation sources:

- `graphcode-windows/src/App.zig`
- `graphcode-windows/src/MainWindow.zig`
- `graphcode-windows/src/InputRouter.zig`
- `graphcode-windows/src/Accessibility.zig`
- `graphcode-windows/src/GraphContextMenu.zig`
- `graphcode-windows/src/GraphCanvas.zig`
- `graphcode-windows/src/Sidebar.zig`
- `graphcode-windows/src/Forms.zig`
- `graphcode-windows/src/NativeForms.zig`
- `graphcode-windows/src/TemplateLibrary.zig`
- `graphcode-windows/src/DraftAttachments.zig`
- `graphcode-windows/src/TerminalSurface.zig`
- `graphcode-windows/src/WorkspaceLayout.zig`
- `graphcode-windows/src/WorkspaceLifecycle.zig`
- `graphcode-windows/src/Wire.zig`
- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
- `GraphcodeKit/Sources/IPC/DaemonWireProtocol.swift`
- `GraphcodeKit/Sources/Domain/LoopNode.swift`
- `GraphcodeKit/Sources/Domain/NodeDraft.swift`
- `GraphcodeKit/Sources/Domain/NodeUpdate.swift`
- `GraphcodeKit/Sources/Domain/GoalSpec.swift`
- `GraphcodeKit/Sources/Domain/GraphcodeSettings.swift`
- current `graphcode-react/src` and `graphcode-react/src-tauri/src`
- `investigation/ui-parity-matrix.md`
- `investigation/react-tauri-implementation-plan.md`

The Win32 UI does not have one unified node inspector. Node information and
commands are spread across cards, sidebar rows, context menus, modal forms,
workspace chrome, attention/activity surfaces, and terminal panes. The proposed
React inspector intentionally consolidates those capabilities rather than copying
the fragmented native layout.

## Status and priority vocabulary

- **Implemented**: reachable and functional in `graphcode-react`.
- **Partial**: some data or presentation exists, but the production behavior is
  materially incomplete.
- **Missing**: no React equivalent.
- **Blocked**: requires an explicit protocol/native integration decision.
- **P0**: required for the next usable vertical slice.
- **P1**: required before serious side-by-side daily use.
- **P2**: required before default-client consideration.
- **P3**: later polish or specialized workflows.

Complexity is relative: **S** days, **M** roughly one focused engineering week,
**L** multi-week or cross-layer work, **XL** a subsystem.

## Remaining-work implementation boundary

This register classifies every remaining capability at the layer where its next
authoritative change belongs. "Frontend-only" includes React and narrow Tauri/Rust
native integration that does not change `graphcoded` or its wire protocol.
"Existing protocol" means the UI must send or consume the named current command or
event and wait for authoritative daemon state. "Daemon/protocol" includes open
ownership investigations where implementing a local-only approximation would create
different local and remote behavior.

### 1. Frontend/native only

| Remaining capability | Correct implementation boundary |
| --- | --- |
| v1 fallback policy, daemon restart fault tests and byte-bounded client queues | Rust connection actor; current v1/v2 wire cases are sufficient |
| Sidebar hierarchy, open/recent grouping, selection synchronization and attention aggregation | React state derived from existing project/graph snapshots |
| Native Tauri menu, command palette destinations, contextual menus, shortcut reference and additional accelerators | Project the typed React command registry through Tauri menu events; do not add daemon commands |
| Graph pan/zoom/fit, client layout, node positioning and local layout persistence | React SVG viewport plus a versioned Tauri app-data store |
| Textual graph outline, live regions, axe/Narrator gates, focus restoration and color-independent status presentation | React/WebView accessibility work |
| Responsive inspector/sheets, resizable panes, DPI handling, theme/high contrast and CSS token alignment | React/CSS and WebView monitor testing |
| Local zmx byte streaming and xterm workspace UI | Dedicated Rust-to-zmx channel plus React/xterm; graph daemon byte proxy is not required for local sessions, while remote ownership remains DT-006 |
| Tabs, splits, workspace layout and client-side workspace focus/navigation | React/native state after the terminal bridge exists |
| Native picker/process shells for local folder ingress, Explorer integration, notifications, tray, updates, diagnostics collection, onboarding and packaging | Tauri/Rust/platform integration; project registration still uses existing daemon commands |
| Local template discovery, local attachment staging and local export bundle bytes | Narrow Rust filesystem adapters using existing formats; remote semantics remain DT-005/DT-007 |
| Error center, UI preferences, expansion state and recoverable client persistence | React plus atomic/versioned Tauri app-data files |

### 2. Implementable with the existing daemon protocol

| Remaining capability | Existing authoritative command/event |
| --- | --- |
| Open folder and recent/open project UX | `openProject`, `listRecentProjects`, `recentProjectsListed`, `graphChanged` |
| Close, forget and delete project graph | `closeProject`, `forgetProject`, `deleteProjectGraph` |
| Global overview | `openGlobalGraph` and ordinary `graphChanged` |
| Quick Chats | `listQuickChats`, create/open/rename/delete commands and Quick Chat events |
| Inspector rename/edit/message/memo/complete/restart/resume/delete/template detach | Existing `GraphCommand` cases; UI waits for `graphChanged`/`nodesChanged` |
| Inspector usage refresh | `refreshUsage` plus authoritative node usage fields |
| Inspector Mailroom read/post/watch | `mailbox`, `mailroomPost`, `mailroomWatch`, and `mailbox` event |
| Composite drill-in and lifecycle | Snapshot `subGraph` plus `subGraphCommand`, `pilotComposite`, `armComposite` |
| Sketch promotion | `promoteNode` with typed `SketchPromotion` |
| Edge creation and deletion | `createEdge` and `deleteEdge`; editing an existing edge is excluded by DT-002 |
| Graph rendering, state/attention, activity, summary, board and metrics | Existing `LoopGraph`/`LoopNode` snapshots and deltas |
| New Loop fields already represented by `NodeDraft` | Existing `createNode`; local adapters may later populate attachments/template references |
| Import's final authoritative graph merge | Existing `importNodes`; bundle/session transaction remains DT-007 |
| Reconnect/replay and correlated mutation errors | Existing v2 hello, sequence, replay and response envelopes |

### 3. Requires daemon/protocol or unresolved authority work

| Backlog ID | Blocked capability | Boundary |
| --- | --- | --- |
| DT-001 | Bounded memory/playbook history | New daemon read API required |
| DT-002 | Atomic edit of an existing edge | New `updateEdge`-style graph command required |
| DT-003 | Project relocation | New authoritative relocation transaction/event required |
| DT-004 | Transcript/session history | Ownership/channel decision and likely bounded daemon or authenticated native API required |
| DT-005 | Remote-aware templates and attachments | Remote filesystem/upload authority is unresolved |
| DT-006 | Remote zmx terminal streaming | Remote authenticated terminal channel/tunnel ownership is unresolved |
| DT-007 | Export/import and session transplantation | Transaction, rollback and remote byte ownership are unresolved |
| DT-008 | Shared settings-store bridging | Multi-writer authority, validation and notification contract must be resolved before React writes settings |

The following must not be represented as working UI until the corresponding DT
item closes: memory history, transcript/history, Move Project, atomic edge edit,
remote template/attachment staging, remote terminal attach, transactional
import/export, and settings mutation. Disabled surfaces may link to the DT item but
must not fabricate data or perform delete/recreate/file-write approximations.

## Executive findings

The React client is currently a live, read-only protocol demonstration:

- it discovers the authenticated Windows pipe;
- negotiates protocol v2;
- requests restore/recent-project state;
- decodes snapshots and node deltas;
- lists projects;
- renders a simple, fixed-row SVG graph;
- exposes basic semantic landmarks and connection status.

It is not yet an application-equivalent client. A persistent connection actor,
stable canvas selection, and a responsive read-only node inspector now exist, but
there are no edit/message forms, remote/clone/Codespace ingress,
Quick Chats, global overview, graph pan/zoom/layout persistence, terminals,
workspaces, settings, updates, native lifecycle, or packaging integration.

The first usable vertical slice is now implemented:

> **persistent connection + stable node selection + right-side inspector + shared
> command registry + visible New Loop flow + typed `createNode` command**

The next highest-value slice is the remaining inspector mutation parity (edit,
message, memo and composite actions), followed by project ingress and graph
viewport/layout.

## Complete capability matrix

| Capability | Zig/Win32 behavior | Daemon/protocol dependency | React status | React UX recommendation | Priority | Complexity / risk | Acceptance criteria |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Daemon discovery and v2 handshake | Authenticated per-user named pipe, v2 hello, v1 fallback, explicit status | Existing endpoint identity and v1/v2 envelopes | **Partial**: correct persistent v2 connection and stable client ID; no v1 fallback | Keep transport entirely in Rust | P0 | M; downgrade decision | Stable client ID, v2 negotiation, supported downgrade decision, explicit failure codes |
| Persistent connection, replay, subscriptions | Reconnect backoff, stable client ID, resume cursor, restore joins, bounded queues | Existing hello `clientID`, `resumeFrom`, subscription and replay errors | **Partial**: Rust actor, count-bounded command queue, request correlation, replay cursor acknowledgement, reconnect/resync and explicit unknown outcomes; daemon-restart integration and byte bounds remain | Complete integration/fault tests and byte accounting | P0 | M; ordering/backpressure | Daemon restart replays exactly once; replay loss causes full resync; mutations never silently retry |
| Project/folder opening | Folder picker, local folder, clone HTTPS, SSH remote, Codespace | Existing `openProject`; native process/dialog work for clone/remote/Codespace | **Partial**: registry/header/native Project menu `Ctrl+O` opens the native Tauri directory picker and sends typed `openProject`; clone/remote/Codespace remain | Add an ingress chooser for clone/SSH/Codespace without changing local open semantics | P1 | L; process security and remote validation | Each ingress path opens the same daemon project and reports exact errors |
| Recent projects | Native File submenu and sidebar recent/open distinction | Existing `listRecentProjects`, `recentProjectsListed` | **Implemented**: Overview, alphabetized Open projects and recency-sorted unopened Recent projects are distinct; selecting a recent project opens it authoritatively and row overflow exposes valid lifecycle actions | Add clone/remote ingress | P1 | S | Recent unopened projects remain selectable; open projects retain graph state |
| Project lifecycle | Close, forget/remove, delete graph, Explorer/remote info; move explicitly unavailable | Existing `closeProject`, `forgetProject`, `deleteProjectGraph`; no move command | **Implemented** for Close, Forget and Delete Saved Graph: exact typed commands, distinct confirmation text, mutation only after correlated daemon success, and predictable selection fallback; Explorer/remote info remain | Add native Explorer/reveal and remote details; keep Move blocked by DT-003 | P1 | M | Correct command per action; Move shown only after protocol exists |
| Global overview | Pinned Graph destination and cross-project lanes | Existing `openGlobalGraph`, ordinary `graphChanged` | **Partial**: persistent Overview destination is separated above project groups and selects the daemon-owned global graph; lane-specific visualization remains | Add cross-project lane layout and destination search | P1 | M | Global graph joins on reconnect and shows cross-project lanes |
| Quick Chats | List, create, open, rename, delete, activity, dedicated empty state | Existing Quick Chat commands/events | **Missing** | Sidebar group plus chat workspace | P1 | M | Stable chat identity and activity ordering; delete confirmation |
| Sidebar hierarchy | Local/remote groups, project disclosure, edge-derived nested loop tree, attention/activity | Graph snapshots; some layout state is client-local | **Missing** | Semantic tree with roving focus and stable IDs | P1 | L; cycles and focus restoration | Snapshot reorder does not lose selection/expansion/focus |
| Command surfaces | Native File/Loop/Terminal/Workspace/View/Help menus, context menus and jump palette | Client state plus existing commands | **Partial**: one typed registry now drives header actions, `Ctrl+P` search, selected-node overflow, lifecycle commands, shortcuts and native Tauri GraphCode/Project/Loop/Navigation menus with synchronized availability; project-row/edge/chat contexts remain | Continue projecting the same registry rather than adding parallel handlers | P0 | M | Header, palette, shortcuts, contextual menus and native menu invoke one command ID/path |
| Graph snapshot rendering | Cards, connectors, lanes, grid, state styling | Existing `graphChanged`, `nodesChanged` | **Partial**: SVG cards and fired/unfired edges use a dependency-layered multi-row layout with cycle fallback; richer lane/state/presence visuals remain | Continue the focused SVG implementation through edge and composite interactions | P0 | M | Real graph topology, state, presence and fired edges render correctly |
| Graph selection | Stable node/edge selection synchronized with sidebar/workspace | Client state only | **Partial**: node selection is keyed by project/node ID, survives snapshots, clears on removal, and supports click/arrow/Enter/Space; sidebar and edge selection remain | Extend the same selection model to sidebar, edges and workspace | P0 | M | Click, keyboard and sidebar select the same identity across refreshes |
| Graph pan/zoom/fit | Pointer pan, wheel/pinch anchored zoom, zoom controls, persisted canvas layout | Client-local persistence | **Partial**: pointer background pan, wheel zoom, visible controls and registry/native-menu shortcuts for zoom in/out, 100% and fit are implemented; pinch anchoring and persistence remain | Add pointer-anchored/pinch zoom and persist the viewport per project | P1 | M | 60 fps target; focus and hit testing remain aligned at all zooms |
| Graph layout persistence | Per-project canvas pan/zoom and node layout | Client-local `CanvasLayoutStore` | **Missing** | Tauri app-data layout store versioned by project/graph | P1 | M | Restart restores layout; corrupt entries fail visibly and reset locally |
| Node inspector | Win32 information/actions are fragmented across card, context menu, forms, loop bar and workspace | Most fields already in `LoopNode`; mailbox is separate | **Partial**: responsive inspector shows snapshot-backed overview, brief, goal/metrics/budget, usage, worktree, attachments, activity/summary/board, Mailroom metadata, composite state and provenance; registry-driven lifecycle, edit, message, memo, pilot and arm actions work while drill-in, playbook actions and memory history remain | Add remaining registry actions and DT-001 memory pages | P0 | M | Selecting a node exposes complete supported data/actions without opening a modal |
| New Loop creation | Native modal creates Turn, Timed, Goal and Composite drafts with backend/model/worktree/template/attachment support | Existing `createNode(NodeDraft)` | **Partial**: visible header/`Ctrl+N`/palette action opens a four-step accessible dialog for all five domain types, validates backend capabilities, recurrence, complete goal policy and worktree tuples, sends typed `NodeDraft`, surfaces refusal, and selects the authoritative created node; templates/attachments await DT-005/native staging | Add native template/attachment adapters and installed-backend discovery | P0 | M | Every supported non-template/non-attachment draft round-trips and appears only from daemon state |
| Node state and attention | Idle/running/awaiting/blocked/waiting/succeeded/failed/stalled/stopped, presence, active dependents, reasons | `LoopNode.state`, `presence`, `stallReason`, `launchFailure`, `resolution`, edges | **Partial**: inspector exposes state, presence, active dependents, stall/launch/resolution reasons; cross-project Needs You remains | Add attention aggregation and color-independent icons | P0 | M | Every enum case has distinct label, color-independent icon and explanation |
| Open terminal | Context action and workspace transition | No daemon command required for attach; zmx session identity from node UUID | **Missing/Blocked** | Primary inspector action; opens/reuses workspace pane | P1 | XL; zmx streaming | Real attach/input/resize/reconnect gate passes; closing pane preserves session |
| Node stop | Context/menu/shortcut | Existing `stopNode` | **Implemented** for selected unresolved loops through registry, overflow, `Ctrl+S`, confirmation and correlated errors | Add state-sensitive wording only if user testing requires it | P0 | S | Correlated refusal shown; node remains and transcript survives |
| Node restart/resume | Daemon supports restart/resume; Win32 context menu does not expose restart | Existing `restartNode`, `resumeSession`, `restartSessions` | **Implemented** for selected loops: unresolved loops restart, resolved loops resume, both with confirmation and preserved-transcript wording | Add all-loop restart only when a dedicated global surface exists | P1 | M | Restart waits for authoritative `sessionRestarts`/snapshot before reattach |
| Node rename | Context menu and F2 | Existing `renameNode` | **Implemented** through registry, F2 and an accessible required-title dialog | Consider inline inspector title editing only if it improves usability | P1 | S | Blank title refused; stable node/session identity retained |
| Node edit | Win32 modal edits goal/predicate/poll/stall/metric/trigger/check/model subset | Existing `updateNode(NodeUpdate)` | **Implemented**: accessible registry/Ctrl+E dialog edits the exact `NodeUpdate` field set, validates by loop type, sends only changed fields, uses documented clear sentinels and refuses empty updates | Consider section-level inline entry points after usability testing | P0 | M | Only changed fields sent; empty update refused; self-stop-condition rules surfaced |
| Node delete | Context action with cancellation-default warning | Existing `deleteNode` | **Implemented** through registry with explicit title/edge warning and authoritative selection clearing | Keep in inspector overflow/danger styling | P1 | S | Explicit project/node identity in confirmation; selection moves predictably |
| Message node | Keyboard/action vocabulary; daemon supports immediate/follow-up; native popup does not expose it consistently | Existing `messageNode(... followUp:)` | **Implemented**: registry/Ctrl+M composer chooses immediate or when-idle delivery and sends the exact optional `followUp` wire field | Keep Message as a visible inspector action | P1 | M | Follow-up flag mapped; correlated refusal visible |
| Memo and playbook | Memo command exists; refine/rollback supported by daemon; no unified native viewer | Existing `memoNode`, `refineNode`, `rollbackRefinement`; no memory-read event | **Partial**: inspector Add Memo writes through the existing command and explicitly states DT-001 blocks memory reads; refine/rollback remain missing | Add playbook write actions; history still requires new API | P1 | L | Memo/refine commands work; history is not fabricated when unavailable |
| Goal completion | Daemon can report completion/result | Existing `completeNode` | **Implemented** for unresolved goal loops with optional result composer and correlated errors | Add richer resolution presentation if user testing requires it | P1 | S | Only goal-compatible states expose action; result reaches authoritative snapshot |
| Goal/predicate/metric/budget | Native forms expose summary, predicate, poll, stall, metric; current domain also has token budget and skip-unchanged | Existing `GoalSpec`, `NodeUpdate` | **Implemented** for creation, inspection and supported live edits, including explicit clearing of predicate/metric/stall/budget | Add metric history visualization | P0 | M | Full `GoalSpec` round-trips, including budget and skip-unchanged |
| Prompt/check/recurrence | Turn instruction/check/pause, timed prompt, optional daemon heartbeat | Existing `NodeDraft`, `NodeUpdate`; heartbeat gated by setting/capability | **Partial**: creation supports all draft fields; live edit supports timed prompt/heartbeat and turn check, while first instruction and pause policy remain intentionally immutable | Add settings capability read only after DT-008 resolves | P0 | M | Invalid/unsupported recurrence cannot submit |
| Backend and model | Native create offers default, Claude, Copilot, Codex; domain has Claude/Copilot/Codex/OpenCode/pi and model tiers | Existing `CLISessionBackendKind`, `ModelTier`; backend immutable in `NodeUpdate` | **Partial**: all domain choices and host-capability rules are encoded; installed/version capability discovery remains | Add native availability/version discovery and keep inherited/default distinct | P0 | M; capability discovery | Payload uses null for inherited choices; unavailable backends explain why |
| Worktree binding | Native create can bind complete repository/path/branch tuple; management dialog and policy | Existing `WorktreeRef`; no live update by design | **Partial**: create flow validates and sends complete existing-worktree tuples; picker/management/policy surface remains | Replace manual fields with native project Worktrees selection | P1 | L | Partial binding impossible; immutable binding is explained after creation |
| Attachments and drag/drop | Attach/remove up to 8, 10 MB each, supported image/text/document types, staged cleanup | Existing `[PromptAttachment]` in `NodeDraft`; native file staging required | **Missing** | Drop zone + picker + ordered attachment list | P1 | L; lifecycle/security | Limits enforced before copy; cancel removes staged files; placeholders stay consistent |
| Templates | Project/user Markdown library, picker, save as template, detach following template | Existing filesystem format; `createdFromTemplateID`, `templateFollow`, `detachTemplate` | **Missing** | Template-first New Loop path and inspector attribution | P1 | L; local/remote filesystem semantics | Precedence/deduplication match; follow allowed only for timed/composite |
| Composite loops | Create composite, open group, pilot once, arm schedule, nested command routing | Existing subgraph, `subGraphCommand`, `pilotComposite`, `armComposite` | **Partial**: New Loop creates composites, inspector shows child/pilot state, Pilot and Arm use exact commands, and Arm is disabled until authoritative state is `piloted`; nested drill-in/routing remains | Add breadcrumb/drill-in and nested registry routing | P1 | L | Arm disabled until piloted; nested mutations address parent chain correctly |
| Edge creation/edit/delete | Drag connector and modal spec editor; context actions | Existing `createEdge`, `deleteEdge`; no atomic `updateEdge` command | **Missing/Blocked for edit** | Connector drag plus accessible Create/Edit Edge dialog; add atomic update rather than delete/recreate | P1 | L | Keyboard alternative exists; invalid cycles/specs show daemon refusal; edit preserves edge identity |
| Entry/unwired actions | Native context offers Wire it up / Mark as entry for unwired loops | Primarily client topology/layout; authoritative mutation must use existing edge/ordering support | **Missing** | Contextual inspector/canvas guidance, not permanent toolbar actions | P2 | M | Only unwired nodes expose actions; resulting topology persists |
| Memory history | Session memory exists on disk and export bundles include it | No current daemon read command/event | **Blocked** | Add `nodeMemory(projectPath,nodeID,cursor,limit)` response or narrow native reader | P1 | L; privacy and remote access | Bounded pagination, redaction/logging policy, local and remote semantics |
| Mailroom | Digest in graph, mailbox query, post/watch commands | Existing `mailbox`, `mailroomPost`, `mailroomWatch`; mailbox response event | **Missing** | Inspector Mailroom section and project Mailroom view | P1 | M | Digest/unread count matches mailbox; watch state and errors are authoritative |
| Activity/summary/board | Native sidebar/activity surfaces; node carries activity, summary and board | Existing `LoopNode` fields and deltas | **Missing** | Inspector Activity tab; render safe structured board, not arbitrary HTML | P1 | L; Mermaid/security | Updates do not rerender terminal/shell; inaccessible diagrams have text alternative |
| Usage and metrics | Usage refresh, usage samples, metric history/sparklines | Existing node usage/metric fields and `refreshUsage` | **Partial**: inspector shows reported usage/metrics and registry-driven Refresh Usage; charts and richer history remain | Add accessible metric history visualization | P1 | M | Refresh is user-triggered; no estimated usage is presented as reported |
| Workspace tabs/splits | New/close tab, split right/down, focus panes, next/previous tab | Client-local workspace plus zmx surfaces | **Missing** | React split tree and tab model | P1 | XL | Layout persists; keyboard focus and terminal ownership remain deterministic |
| Workspace lifecycle | Multiple support-directory workspaces, create/rename/delete/switch | Native lifecycle and process/bootstrap integration | **Missing** | Workspace switcher in command palette/native menu | P2 | L | Current/default workspaces cannot be renamed/deleted; multi-instance isolation holds |
| Terminal scrollback/history | Winghostty attaches to zmx; session survives surface destruction | zmx attach protocol; transcript stores are separate | **Blocked** | xterm.js + Rust zmx bridge; separate transcript/history reader | P1 | XL | Raw VT, resize, flow control, scrollback reconstruction and security gates pass |
| Import/export | Export bundles include graph, memory, prompts and resumable sessions; import uses daemon merge | Existing `importNodes`; export/session transplant is client/native work | **Missing** | Project/selection Import and Export commands with progress summary | P2 | XL; large files and remote restore | IDs re-map, sessions install before import, socket payload remains bounded |
| Settings | Native product and advanced connection dialogs; daemon reads shared settings file | No settings daemon command; existing `GraphcodeSettingsStore` contract | **Missing** | React Settings route with narrow Rust read/write adapter | P1 | L | All settings preserve defaults/migrations; invalid file write is atomic and explicit |
| Updates | Check, offer, channel selection, install/relaunch work in native paths with gating | Native GitHub/update/install integration | **Missing** | Native Tauri/Rust update service, React progress surfaces | P2 | XL; signing/rollback | Stable/beta rules and rollback/install lifecycle match package tests |
| Diagnostics | Native status, ingress errors, resource/daemon diagnostics, advanced connection settings | Primarily native/local | **Missing** | Status center plus Diagnostics route; copy sanitized report | P2 | M | Errors have code/context; no prompt/terminal/secret leakage |
| Notifications and tray | Native notification icon, restore/exit, Explorer recovery; status announcements | Native Tauri APIs | **Missing** | Tauri tray and opt-in system notifications | P2 | L | Single-instance restore and owned-daemon shutdown contracts hold |
| Onboarding/empty states | Four-page onboarding and destination-specific empty states/actions | Local persisted seen state | **Missing** | Short React onboarding; every empty state contains next action | P2 | M | Keyboard complete, persisted, reopenable from Help |
| Accessibility structure | Custom UIA provider exposes roles/patterns/dynamic commands | No daemon work | **Partial**: semantic shell/inspector, named SVG graph, roving node focus, keyboard selection, viewport controls and a textual graph outline; axe and Narrator gates remain | Add live regions and automated/manual gates | P0 continuously | L; WebView/Narrator variance | Axe + keyboard + Narrator gates; all actions reachable without pointer |
| Keyboard shortcuts | Native accelerators and centralized `InputRouter` | No daemon work | **Partial**: registry-driven Ctrl+P/Ctrl+O/Ctrl+N/Ctrl+S/Ctrl+E/Ctrl+M, F2, Enter/Escape and Ctrl+-/Ctrl+0/Ctrl+=/Ctrl+9 with editable-field suppression and native accelerators; workspace shortcuts remain | Generate a shortcuts reference and extend with workspace commands | P0 | M | Conflicts suppressed in text fields; shortcuts discoverable and testable |
| DPI/responsive behavior | Per-monitor-v2 scaling, terminal font scaling, logical coordinates | Native/browser and zmx resize work | **Partial**: one CSS breakpoint | Responsive three-pane layout; browser logical pixels; monitor/DPR tests | P1 | L | 100–300% DPI and compact/ultrawide layouts remain operable |
| Theme | Dark tokens and native gradients | No daemon work | **Partial**: independent dark CSS | Generate CSS tokens from canonical theme values | P2 | M | Token comparison test prevents drift; high contrast remains legible |
| Error handling | Correlated daemon errors, persistent ingress errors, native status/UIA announcements | Existing v2 error envelopes | **Partial**: initial errors and warnings only | Global error center plus inline command errors | P0 | M | No silent fallback for mutations; unknown outcomes force resync |
| Persistence | Open projects daemon-owned; UI layout/expansion/workspace settings client-owned | Mixed daemon and client stores | **Missing/partial** | Versioned app-data stores with atomic writes | P1 | M | Corrupt local state cannot corrupt daemon graph and is recoverable |
| Packaging/bootstrap | Self-contained ZIP, daemon/CLI/zmx/providers/runtime, install/upgrade/rollback | Existing PowerShell packaging and daemon lock/readiness contracts | **Missing** | Stage Tauri executable beside native client first | P2 | XL | Clean install/upgrade/rollback and one-daemon handoff pass |

## Right-side node inspector design

### Purpose

Selecting a loop should answer four questions without opening a modal:

1. What is this loop and why is it in its current state?
2. What was it instructed to do?
3. What is it doing, consuming, and waiting on?
4. What can I safely do next?

The inspector is the canonical selected-node surface. Context menus and keyboard
commands invoke the same command registry; they do not contain separate behavior.

### Component hierarchy

```text
NodeInspector
  InspectorEmptyState
  InspectorSelection
    InspectorHeader
      LoopTypeStripe
      EditableTitle
      StateBadge
      PresenceBadge
      ProjectBreadcrumb
      CloseInspectorButton
    InspectorPrimaryActions
      OpenTerminalButton
      MessageButton
      EditButton
      MoreActionsMenu
    InspectorStatusCallout
      AttentionReason
      StallReason
      LaunchFailure
      Resolution
      UpstreamBlockers
    InspectorTabs
      OverviewTab
        BriefSection
        ExecutionSection
        WorktreeSection
        TemplateSection
        AttachmentsSection
      ActivityTab
        CurrentActivity
        SummaryBeats
        SummaryBoard
        PresenceAndDependents
      MetricsTab
        Usage
        TokenBudget
        MetricHistory
        PollAndStallPolicy
      MemoryTab
        MemoComposer
        PlaybookActions
        MemoryHistoryPlaceholderOrResults
        MailroomDigestAndWatch
      CompositeTab
        PilotState
        ChildGraphSummary
        OpenGroup
        PilotOnce
        ArmSchedule
    InspectorDangerZone
      Stop
      RestartOrResume
      Delete
```

`CompositeTab` appears only for composite nodes. `MemoryTab` can ship initially
with write actions and an explicit “history is not available in this client yet”
state until a bounded read API exists.

### Layout and responsive behavior

- **Wide (>= 1280 CSS px):** sidebar, graph/workspace, 360–440 px inspector.
- **Medium (900–1279):** inspector overlays from the right but remains nonmodal;
  graph width is preserved and Escape closes the panel.
- **Compact (< 900):** inspector is a full-height sheet with a Back button; primary
  actions stay sticky at the bottom.
- Width is user-resizable on wide layouts and stored locally per workspace.
- Selecting another node replaces content without closing the inspector.
- Selecting an edge swaps to an Edge Inspector using the same panel container.
- Clearing selection shows a short empty state explaining keyboard/pointer selection.
- Project or graph changes preserve selection only if the stable ID still exists.

### Read-only versus editable sections

The inspector opens read-only. Editing happens in narrowly scoped modes:

- Title edits inline through `renameNode`.
- Goal/predicate/metric/budget/cadence/check/model edit through `updateNode`.
- Message and memo use small anchored composers.
- Backend, loop type, worktree binding, first instruction, attachments and template
  source are shown as immutable after creation where the daemon/domain intentionally
  does not support a live change.
- “Edit all supported fields” opens a sheet using the same section components; it
  must not imply unsupported fields can be changed.

### Action placement

- Primary: **Open Terminal**.
- Secondary visible: **Message**, **Edit**.
- Overflow: Memo, Mark Complete, Refine Playbook, Roll Back Playbook, Save as
  Template, Detach Template, Restart/Resume, composite actions.
- Stop is visible when the loop is unresolved/running.
- Delete is always in the danger zone and requires confirmation.
- Disabled actions include a visible reason, not only a disabled control.
- All actions expose their shortcut in tooltip, menu and accessible description.

### Field inventory and data source

| Inspector field | Source | Availability |
| --- | --- | --- |
| ID, title, type, backend, model, creator and created time | `LoopNode` snapshot | Existing |
| State, presence, activity, dependents | `LoopNode` snapshot/delta | Existing |
| Check, trigger prompt, heartbeat, first instruction, pause policy | `LoopNode` | Existing |
| Goal summary, predicate, poll, stall, metric, budget, skip unchanged | `LoopNode.goal` | Existing |
| Worktree repository/path/branch | `LoopNode.worktreeBinding` | Existing |
| Attachments | `LoopNode.attachments` | Existing |
| Template attribution/follow/missing | `createdFromTemplateID`, `templateFollow` | Existing |
| Usage and metric history | `usage`, `metricHistory` | Existing |
| Stall/launch/resolution/pending completion | `LoopNode` | Existing |
| Summary and board | `summary`, `board` | Existing |
| Mailroom digest | graph `mailroomDigest` | Existing |
| Mailroom posts/watch/cursor | `mailbox` response and node fields | Existing commands/events |
| Composite graph and pilot state | `subGraph`, `pilotState` | Existing |
| Session restart generation | `sessionRestarts` | Existing |
| Memory log/history | not in snapshot | **New bounded read API or native adapter required** |
| Transcript/history | backend transcript stores | **Native/daemon design required** |
| Live terminal stream | zmx | **Rust bridge required** |

### Inspector protocol requirements

No new daemon protocol is needed for the read-only Overview, Activity, Metrics or
Composite tabs, or for stop/restart/rename/update/delete/message/memo/complete/
refine/rollback/detach/pilot/arm actions.

New work is required for:

1. **Memory read:** preferably a daemon command/event such as
   `nodeMemory(projectPath:nodeID:before:limit:)` returning bounded entries and
   playbook metadata. A local-only Tauri file reader would not cover remote projects
   consistently.
2. **Transcript/history read:** either a daemon query or a narrow native adapter that
   uses the existing backend transcript resolvers locally and through remote access.
3. **Terminal:** a Tauri/Rust zmx streaming channel, not a new graph daemon REST API.

## New Loop flow

### Visible entry points

The primary project header action is **New Loop**. The same command appears in:

- empty project/global graph states;
- project row hover/overflow;
- graph background context menu;
- native Loop menu;
- command palette;
- `Ctrl+N`.

Every entry point dispatches one command with an explicit target project path.

### Progressive disclosure

Use a single dialog/sheet with four stages that can also be navigated as sections:

1. **Choose shape**
   - Optional template search.
   - Main, Goal, Timed, Turn, Composite cards.
   - One-sentence explanation and unattended/attended behavior.
2. **Describe the work**
   - Type-specific prompt/goal/check fields.
   - Attachments where supported.
3. **Execution**
   - Backend and model.
   - Worktree.
   - Cadence/heartbeat or goal monitoring.
4. **Review and create**
   - Human-readable summary of what will launch.
   - Advanced options.
   - Exact validation errors linked to fields.

Changing loop type preserves common fields and only clears a field after an explicit
warning when its meaning cannot carry to the new type.

### Loop types

The React target should expose the current domain vocabulary, not only the older
Windows picker:

| UI label | Wire value | Required fields | Start/ownership semantics |
| --- | --- | --- | --- |
| Main | `sketch` | Optional starting instruction/title | Attended, zero-commitment session |
| Goal | `goalBased` | Nonblank goal summary | Daemon starts and resolves/stalls |
| Timed | `timeBased` | Nonblank trigger prompt and valid cadence mode | Daemon starts; cadence is prompt- or heartbeat-owned |
| Turn | `turnBased` | Nonblank first instruction; optional check | Human opens/advances |
| Composite | `proactive` | Nonblank title; optional subgraph/template | Contains graph; pilot before arm |

The Win32 form currently exposes Turn, Time, Goal and Proactive/Composite, with Turn
as default. React should default from product settings and otherwise prefer **Main**
for low-commitment creation or **Goal** if product direction wants autonomous work
to be primary; that choice should be recorded explicitly rather than inherited from
an old form constant.

### Type-specific fields

**Common**

- Title, with a visible generated fallback.
- Backend.
- Model tier: Agent/default, Fast, Standard, Capable.
- Optional worktree binding.
- Template attribution/follow where valid.
- Creator attribution is supplied by trusted client context, not user-edited.

**Main**

- Starting instruction, optional.
- Attachments.

**Turn**

- First instruction, required.
- “Verify each turn” check, optional.
- Pause only before writes.
- Attachments.

**Timed**

- Trigger prompt, required.
- Cadence ownership:
  - In-session recurrence parsed from prompt; or
  - daemon heartbeat interval when enabled and supported.
- Attachments.
- Template follow option.

**Goal**

- Goal summary, required.
- Predicate command.
- Poll interval, positive; default 60 seconds.
- Stall after duration, optional positive.
- Metric command and direction.
- Token budget, optional positive.
- Skip predicate while workspace is unchanged.
- Attachments.

**Composite**

- Title, required.
- Template/subgraph source.
- Template follow option.
- Pilot/arm explanation.
- No prompt attachments in the current native contract.

### Backend and model choices

Domain backends are Claude Code, Copilot CLI, Codex, OpenCode and pi. The Win32 form
currently offers inherited/default plus Claude, Copilot and Codex. React should:

- query native availability/capabilities;
- show all supported choices with unavailable reasons;
- use `null` for inherited/default;
- keep permission/trust defaults in shared Settings, not invent per-node fields that
  the daemon does not store;
- clearly say model changes apply on the next launch for an existing node.

### Templates

- Search project templates first, then user templates.
- Deduplicate by stable template ID.
- Preview shape and body before applying.
- Applying a template fills the relevant type field and title but does not erase
  unrelated execution choices.
- Snapshot is the default.
- “Follow template” is available only for Timed and Composite and maps to
  `templateFollow`.
- `createdFromTemplateID` is always included when created from a template.

Template discovery/save is currently a filesystem/native concern. Remote-project
template semantics need an explicit adapter; do not silently read local templates
for a remote project and call them project templates.

### Attachments

- Drop zone and native picker.
- Maximum 8 files, 10 MB each.
- Show filename, size, type, remove and ordering.
- Stage through Rust into the support-directory draft location.
- Generate the node UUID before staging so paths are stable.
- Clean staged data on cancel/failure.
- Preserve `[image #N]` placeholder ordering when removing/reordering.
- Reject unsupported or empty files before copying.
- Do not expose arbitrary filesystem access to React.

### Worktree policy

- Default to project root/no binding.
- Present eligible worktrees with branch and dirty/reclaim state.
- Serialize only complete `WorktreeRef` values.
- Explain that binding cannot move after launch because the session working directory
  is immutable in `NodeUpdate`.
- Worktree creation/reclaim is a separate native/project workflow, not hidden inside
  loop creation.

### Validation

Client validation mirrors `NodeDraft.isValid` but never replaces daemon validation:

- recognized loop type, backend and model;
- required type-specific text after trimming;
- finite positive heartbeat/poll intervals;
- positive optional stall/budget;
- recurrence supported by selected backend/capabilities;
- complete worktree tuple;
- valid finite subgraph;
- maximum attachment count and file limits;
- template-follow restrictions;
- backend supports the selected loop semantics.

Submission remains pending until the correlated daemon response succeeds. A daemon
refusal is attached to the relevant section where possible and always remains in the
dialog.

### Canonical v2 `createNode` request shape

```json
{
  "graphCommand": {
    "projectPath": "<canonical path>",
    "command": {
      "createNode": {
        "_0": {
          "id": "<client UUID>",
          "title": "<title>",
          "loopType": "sketch|goalBased|timeBased|turnBased|proactive",
          "checkDescription": null,
          "triggerPrompt": null,
          "heartbeatIntervalSeconds": null,
          "firstInstruction": null,
          "pausesBeforeWritesOnly": false,
          "attachments": [],
          "goal": null,
          "backend": null,
          "modelTier": null,
          "worktree": null,
          "subGraph": null,
          "createdBy": null,
          "createdFromTemplateID": null,
          "templateFollow": null
        }
      }
    }
  }
}
```

The Swift Codable `_0` wrapper is wire-significant and must be generated/tested
rather than assumed. Optional fields may be omitted by Swift's encoder; explicit
`null` values are also accepted by the daemon's `decodeIfPresent` implementations.
`GoalSpec` includes `summary`, `predicate`, `pollIntervalSeconds`,
`stallAfterSeconds`, `metricCommand`, `metricDirection`, `tokenBudget`, and
`skipsUnchangedWorkspace`.

The Win32 draft also carries permission/briefing/activity fields that are not emitted
by its current full create builder and are not `NodeDraft` fields. React must not
pretend those are per-loop persisted options; they belong in shared settings unless
the daemon model changes.

### Keyboard and accessibility

- `Ctrl+N` opens the dialog for the current project.
- Initial focus is the type/template choice or title when type is preselected.
- Sections have headings and error summaries link to invalid controls.
- Type cards are radio buttons, not clickable generic divs.
- Escape cancels after warning if attachments or edits would be lost.
- Ctrl+Enter submits from multiline fields; plain Enter remains text input.
- Template search, backend/model and worktree controls support arrow navigation.
- Screen readers announce type changes, conditional fields, validation and daemon
  refusal.
- On success, focus moves to the new node in the graph and opens its inspector.

## Menu and command architecture

### Alternatives

| Approach | Strengths | Weaknesses | Verdict |
| --- | --- | --- | --- |
| Native Tauri menu only | Windows convention, Alt-key discovery, OS-level shortcuts | Poor contextual richness; duplicates React state; hidden on compact/custom chrome | Insufficient alone |
| React header/sidebar commands only | Flexible, visible, responsive, easy state descriptions | Weak Windows menu convention; shortcut discovery and global commands become ad hoc | Insufficient alone |
| Command palette only | Fast for experts, searchable, scales to many actions | Undiscoverable for new users; poor for dangerous/contextual actions | Secondary surface only |
| Context/overflow menus only | Keeps canvas uncluttered and target-specific | Hidden actions; keyboard and global lifecycle actions suffer | Secondary surface only |
| **Hybrid command registry** | One action model can drive native menu, visible UI, palette, shortcuts and context menus | Requires disciplined central command metadata and state selectors | **Recommended** |

### Recommendation

Build one typed command registry in TypeScript/Rust-facing application state:

```text
Command {
  id
  label
  description
  category
  defaultShortcut
  icon
  availability(state, target)
  disabledReason(state, target)
  danger
  execute(context)
}
```

Project that registry into five surfaces:

1. **Native Tauri application menu** for Windows-standard global commands and Alt-key
   discovery.
2. **Visible React header/sidebar commands** for the top current actions.
3. **Unified command/jump palette** for every command and stable project/node/chat
   destination.
4. **Contextual overflow menus** for project, node, edge and chat targets.
5. **Keyboard shortcut router** that respects focus/editing context.

There must be one execution path and one availability calculation. Native menu items
send command IDs back into the same registry; they do not implement parallel logic.

### Proposed top-level information architecture

**Persistent sidebar**

- Overview
- Quick Chats
- Needs You
- Activity
- Projects
  - Local
  - Remote
  - Recent
- Add Project
- Settings

**Project/graph header**

- Breadcrumb: project / composite path
- Search/jump
- **New Loop** primary button
- Needs You count
- Worktree status
- Graph/workspace toggle
- More actions

**Native application menu**

- **File**
  - Open Folder
  - Clone Repository
  - Add Remote Repository
  - Add Codespace
  - Recent Projects
  - New Quick Chat
  - Import
  - Export
  - Exit
- **Loop**
  - New Loop
  - Open Terminal
  - Edit Details
  - Message
  - Memo
  - Stop
  - Restart/Resume
  - Delete
  - Composite submenu: Open Group, Pilot Once, Arm Schedule
- **View**
  - Overview
  - Sidebar
  - Workspace panel
  - Activity
  - Zoom Out / Actual Size / Zoom In / Fit
  - Reconnect
- **Workspace**
  - New/Close Tab
  - Split Right/Down
  - Next/Previous Tab
  - Focus Next/Previous Pane
  - New/Rename/Delete/Switch Workspace
- **Tools**
  - Worktrees
  - Project Worktree Policy
  - Settings
  - Advanced Connection Settings
  - Diagnostics
- **Help**
  - GraphCode Basics
  - Keyboard Shortcuts
  - Check for Updates
  - About

Project lifecycle actions remain in the project row overflow and command palette
rather than crowding File. Edge/chat actions remain contextual.

### Palette behavior

- Preserve `Ctrl+P` as the unified jump surface because the current client already
  teaches it.
- Default results are projects, loops and chats ranked by identity/title/project.
- Typing `>` switches to commands, VS Code-style.
- `Ctrl+J` remains “Jump to Loop” and opens the same palette prefiltered to loops.
- Show shortcut, category, target and disabled reason.
- Destructive commands may be found but always require their normal confirmation.

### Shortcut strategy

Preserve established shortcuts unless they conflict with platform text editing:

- Ctrl+N New Loop
- Ctrl+O Open Folder
- Ctrl+P Search/jump/palette
- Ctrl+J Jump to Loop
- Ctrl+E Edit selected loop
- Ctrl+M Message selected loop
- Ctrl+S Stop selected loop only when focus is not in an editable control
- F2 Rename
- Delete Delete selected target
- Enter Open terminal/group
- Ctrl+Tab Review Needs You
- Tab / Shift+Tab next/previous loop only when graph owns focus
- Ctrl+T/W/D/Shift+D and Ctrl+PageUp/PageDown for terminal workspace
- Ctrl+-, Ctrl+0, Ctrl+=, Ctrl+9 for viewport
- Ctrl+, Settings; reserve Ctrl+Shift+, for product/advanced split only if both remain
- F1 Basics/help

The registry must suppress application shortcuts inside text editors, terminals and
dialogs unless the command is explicitly global. Display the effective shortcut in
menus, tooltips, palette results and the shortcuts reference.

## Prioritized implementation sequence

### Dependency graph

```text
A. Generated/complete protocol types
   -> B. Persistent Rust connection actor + command bus
      -> C. Stable selection/navigation store
         -> D. Read-only node inspector
         -> E. Command registry/menu/palette
         -> F. New Loop dialog + createNode
            -> G. Inspector mutations
               -> H. Edge/composite interactions
      -> I. Quick Chats/mailbox/settings readers

J. Native file/process capability layer
   -> project ingress
   -> attachment staging
   -> templates
   -> settings
   -> import/export
   -> packaging/update

K. zmx streaming spike
   -> terminal bridge
      -> workspace tabs/splits
         -> transcript/history
```

### Sequence

1. **P0 protocol/state foundation**
   - Complete `LoopNode`, `GoalSpec`, `NodeDraft`, `NodeUpdate`, edge and command
     validators from Swift-generated fixtures.
   - Replace the one-shot bridge with persistent connection/replay/request handling.
   - Add explicit command result and unknown-outcome states.
2. **P0 selection + inspector read slice**
   - Stable node selection from SVG and sidebar.
   - Responsive inspector with Overview/Activity/Metrics/Composite data.
   - Roving focus and textual graph outline.
3. **P0 command architecture — implemented for current command set**
   - Typed command registry.
   - Visible New Loop/header actions.
   - Native Tauri menu projection and unified palette shell.
4. **P0 New Loop create slice**
   - All five loop types.
   - Goal/turn/timed/main/composite validation.
   - Backend/model/defaults.
   - Typed `createNode` submission and focus new node on authoritative snapshot.
5. **P1 inspector mutations**
   - Rename/update/message/memo/stop/restart/delete/complete/template/composite actions.
   - Mailbox and usage refresh.
6. **P1 native project workflows**
   - Open/clone/remote/Codespace.
   - Worktrees, attachment staging, templates and settings.
7. **P1 graph editing**
   - Pan/zoom/layout persistence.
   - Edge creation/edit/delete and composite drill-in.
8. **P1 terminal/workspace**
   - zmx bridge, xterm.js, flow control, tabs/splits and persisted layout.
9. **P2 lifecycle/distribution**
   - Tray, notifications, onboarding, updates, diagnostics, import/export and package
     integration.

### Implemented vertical slice

The following milestone is implemented on `simra/tauri`:

1. persistent daemon connection with a typed `sendCommand`;
2. node selection by click and keyboard;
3. right-side read-only inspector for all snapshot-backed fields;
4. visible New Loop button;
5. New Loop dialog for all five domain loop types;
6. correlated `createNode` submission;
7. authoritative snapshot selects and displays the new node;
8. header, Ctrl+N and command-palette entry all invoke the same registry command.

Current acceptance:

- A user can connect, select a real node, understand its state/configuration, create a
  valid loop without raw JSON, see daemon validation errors, and inspect the created
  loop.
- The flow is keyboard-operable with dialog semantics and focus trapping; a Windows
  Narrator smoke test remains a release gate.
- No fixture or client-only graph mutation is used.
- Daemon restart during a draft preserves the draft locally, reconnects, and requires
  explicit resubmission rather than guessing whether creation succeeded.

Native Tauri menus are projected from the same registry into focused
GraphCode/Loop/Navigation groups. The React client intentionally does not recreate
the full Win32 menu bar.

## Protocol changes and blockers

### Existing protocol is sufficient for

- project list/open/restore/global/close/forget/delete;
- graph snapshots and node deltas;
- Quick Chats;
- creating, renaming, updating, promoting and deleting nodes;
- creating/deleting edges;
- stop/restart/resume;
- message, memo, complete, refine and rollback;
- Mailroom query/post/watch;
- composite subcommands/pilot/arm;
- usage refresh;
- import merge;
- all inspector fields already carried by `LoopNode`.

### New protocol/native design is required for

- **Memory history/playbook read:** no bounded daemon query/event exists.
- **Transcript/history read:** not in graph snapshots; must use existing transcript
  resolvers through a deliberate local/remote interface.
- **Project relocation:** no authoritative move command exists.
- **Edge editing:** no atomic `updateEdge` command exists. Delete/recreate can lose
  identity and expose an invalid intermediate graph, so it is not an equivalent edit.
- **Terminal streaming:** native zmx bridge is required, though this should not become a
  parallel graph REST API.
- **Settings:** no daemon command exists; use the established shared settings store
  through Rust unless a future authoritative command is added.
- **Template/project file access and attachments:** narrow native adapters are needed,
  particularly for remote projects.
- **Export/session transplant:** native filesystem/remote restore work is required;
  only the final graph merge uses `importNodes`.

## Release blockers

The React client cannot replace the Win32 client until at least:

- persistent reconnect/replay and mutation correlation are implemented;
- inspector and New Loop are complete;
- project ingress and lifecycle are available;
- graph interaction and accessibility reach daily-use parity;
- zmx/xterm terminal and workspace behavior pass the real terminal gate;
- shared settings, worktrees, templates and attachments are safe;
- lifecycle, tray, update and packaging contracts are integrated;
- clean install/upgrade/rollback and multi-DPI/Narrator gates pass.
