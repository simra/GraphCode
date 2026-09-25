# GraphCode React/Tauri client

This is the side-by-side React + TypeScript + Tauri v2 client. It does not replace
or modify `graphcode-windows`; both clients use the authoritative `graphcoded`
protocol.

## Prerequisites

- Node.js 24 or newer and npm.
- Rust stable with Cargo and the MSVC build tools required by Tauri on Windows.
- WebView2 (included in current Windows 10/11 installations).
- A built/running `graphcoded` for live connectivity. Without one, the UI explicitly
  reports the connection error and renders a repository fixture.

## Develop and validate

```powershell
Set-Location graphcode-react
npm install
npm run format
npm run check
npm test
npm run build
cargo fmt --manifest-path src-tauri\Cargo.toml --check
cargo test --manifest-path src-tauri\Cargo.toml
cargo check --manifest-path src-tauri\Cargo.toml
npm run tauri dev
```

To include the opt-in live named-pipe protocol test against an already-running
local daemon:

```powershell
$env:GRAPHCODE_RUN_LIVE_DAEMON_TEST = "1"
cargo test --manifest-path src-tauri\Cargo.toml
```

The native bridge respects `GRAPHCODE_DAEMON_PIPE` (the Windows shell override),
`GRAPHCODE_SOCKET` (the GraphcodeKit socket override), and
`GRAPHCODE_SUPPORT_DIR`. On Windows it otherwise derives the same
SID/support-directory/rendezvous-secret pipe name as GraphcodeKit.

The client negotiates protocol v2, announces `nodesChanged`, restores open projects,
loads recents and Quick Chats, opens the global graph, and maintains a persistent
reconnecting event stream with replay acknowledgement. React mutations use the typed
command registry and wait for correlated daemon outcomes. Quick Chat list, create,
open, rename, delete, activity, and navigation are implemented; the opened workspace
explicitly remains non-interactive until the local zmx terminal bridge is available.
Composite snapshots can be drilled into through breadcrumbs, and graph mutations in
that view are wrapped through the authoritative `subGraphCommand` parent chain.
Pointer users can drag between loop connection handles to prefill the typed edge
editor; the New Edge command remains the keyboard-accessible endpoint selector.
The graph uses spatial arrow-key navigation, Home/End focus movement, explicit
keyboard instructions, patterned loop-type stripes, visible selection marks, and
dashed fired-edge styling so state is not communicated by color alone.
Root and composite graph viewports persist per project in a validated version-1
Tauri app-data file. Writes are debounced and atomically replaced; invalid,
oversized, or unsupported state is reported instead of silently applied.
Pointer drag or Alt+Arrow repositions individual loops in the same per-view store;
Reset Layout returns to the deterministic dependency layout without mutating the
daemon graph.
Wheel zoom remains anchored under the pointer, while two-touch pinch zoom tracks
both scale and midpoint translation in the same coordinates used for node and edge
hit testing.
Playbook refine and rollback use the existing daemon commands; current playbook and
rollback-history reads remain blocked on DT-001.
The inspector can load the whole Mailroom board, search it, query a selected loop's
unread slice with or without an atomic cursor advance, post within the protocol byte
limits, and configure that loop's all-post/topic/off watch. Each open project also has
a responsive Mailroom destination with post navigation and an authoritative
single-post deep read when a board response contains trimmed bodies. Nested Mailroom
ownership is not established, so those controls fail closed while drilled into a
composite.
The selected project's sidebar entry expands into a nested root/composite loop
hierarchy. Sidebar selection, composite routing, canvas selection, breadcrumbs, and
the inspector share the same reducer-validated graph location.
Selecting an edge opens a dedicated inspector with resolved endpoints, kind,
condition, delivery transform, cycle/spawn metadata, fire count, stable identity, and
the registry-driven authoritative delete action. Existing-edge edits remain excluded
until DT-002 defines an atomic daemon contract.

Run `npm run test:a11y` for the axe-core/jsdom semantic gate. The packaged Windows
Narrator, touch, DPI, contrast-theme, and focus-restoration procedure is documented in
[`ACCESSIBILITY.md`](ACCESSIBILITY.md).

A single atomic polite live region announces connection transitions, stable
loop/edge/chat selection changes, and successful mutations only after their
correlated daemon command completes. Visible errors remain assertive alerts. Project
local/remote grouping is intentionally blocked on DT-010 because current `ProjectRef`
snapshots contain no authoritative location kind.
