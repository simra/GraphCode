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

The native bridge respects `GRAPHCODE_DAEMON_PIPE` (the Windows shell override),
`GRAPHCODE_SOCKET` (the GraphcodeKit socket override), and
`GRAPHCODE_SUPPORT_DIR`. On Windows it otherwise derives the same
SID/support-directory/rendezvous-secret pipe name as GraphcodeKit.

The current slice negotiates protocol v2, announces `nodesChanged`, asks the daemon
to restore open projects, loads recent projects, and returns the received snapshots
to React. Reconnect/replay, long-lived event streaming, mutations, and terminal
streaming are specified in
`investigation/react-tauri-implementation-plan.md` but are not implemented yet.
