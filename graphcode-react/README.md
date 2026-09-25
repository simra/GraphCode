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
Playbook refine and rollback use the existing daemon commands; current playbook and
rollback-history reads remain blocked on DT-001.
