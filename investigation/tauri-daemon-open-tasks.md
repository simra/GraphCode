# Tauri frontend: daemon and protocol open investigations

Status: open investigation backlog as of 2026-09-25.

This document contains only questions that may require new or changed
`graphcoded`/wire-protocol support. It deliberately excludes React, Tauri, Rust
bridge, and native-service implementation that can use existing commands, events,
files, or zmx interfaces.

The classifications are:

- **New daemon support required**: the current authoritative protocol cannot
  provide the required behavior safely.
- **Needs investigation before classification**: current ownership or remote
  semantics are not established well enough to choose daemon versus native support.
- **Existing daemon support sufficient**: recorded only in the exclusion register
  so client work is not incorrectly blocked on protocol changes.

No item authorizes a daemon change on `simra/tauri`. Confirmed daemon work belongs
on a daemon-focused branch and must preserve v1/v2 compatibility.

## Classification summary

| ID | Interface | Classification | Blocking frontend work |
| --- | --- | --- | --- |
| DT-001 | Bounded node memory and playbook reads | New daemon support required | Complete inspector Memory history |
| DT-002 | Atomic edge editing | New daemon support required | Editing an existing edge without identity loss |
| DT-003 | Project relocation | New daemon support required | Move Project |
| DT-004 | Bounded transcript/history reads | Needs investigation before classification | Transcript/history view |
| DT-005 | Remote-aware templates and attachments | Needs investigation before classification | Remote New Loop template/attachment parity |
| DT-006 | Remote zmx terminal streaming | Needs investigation before classification | Remote terminal parity |
| DT-007 | Export/import and session transplantation | Needs investigation before classification | Remote/transactional import/export parity |
| DT-008 | Shared settings-store bridging | Needs investigation before classification | Settings mutation and cross-client refresh |

## Confirmed daemon work

### DT-001 — Bounded node memory and playbook reads

**Problem**

The inspector must show durable node memory, playbook state, and refinement history.
The current protocol can append a memo and refine or roll back a playbook, but it
cannot read the resulting history.

**Evidence and current limitation**

- `GraphCommand.memoNode`, `refineNode`, and `rollbackRefinement` mutate
  `NodeMemory`.
- `LoopNode` snapshots do not embed memory entries or playbook history.
- `ProjectPersistence+Export.swift` and `GraphExportBundle+ZIP.swift` read memory
  files for export, proving the data exists outside the graph snapshot.
- `DaemonCommand.mailbox` demonstrates the desired bounded, request-specific read
  pattern, but no equivalent memory command/event exists.
- Reading files directly from Tauri would give local projects different semantics
  from remote projects and bypass daemon ownership and authorization decisions.

**Investigation questions**

1. Should one query return memory entries, the current playbook, and refinement
   metadata, or should those be separate resources?
2. What stable cursor is available: byte offset, entry UUID, timestamp plus tie
   breaker, or append sequence?
3. What maximum entry count and encoded-byte limit stays safely below the 1 MiB v2
   frame ceiling?
4. Can a memory entry contain attachment references, and how are unavailable files
   represented?
5. Is the playbook history itself user-visible, or only current playbook plus
   rollback availability?
6. How should deleted nodes, imported nodes, composite children, and remote projects
   be addressed?

**Likely daemon files and types**

- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
  - proposed `DaemonCommand.nodeMemory(projectPath:nodeID:query:)`
  - proposed `DaemonEvent.nodeMemory(projectPath:nodeID:page:)`
- `GraphcodeKit/Sources/NodeMemory.swift` or the current `NodeMemory` definition
- `GraphcodeKit/Sources/ProjectRegistry.swift`
- `GraphcodeKit/Sources/GraphStore.swift`
- new bounded domain types such as `NodeMemoryQuery`, `NodeMemoryPage`,
  `NodeMemoryEntrySummary`, and `PlaybookSnapshot`
- protocol fixture and compatibility tests under `GraphcodeKit/Tests` and
  `graphcode-windows/fixtures`

**Compatibility and security**

- Additive v2 command/event cases must not alter existing encodings.
- Responses must be request-scoped, not broadcast in every graph snapshot.
- Enforce entry and byte limits before allocation/encoding.
- Do not log memory text, prompts, attachment paths, or playbook contents.
- Canonicalize project/node identity through `ProjectRegistry`; never accept an
  arbitrary memory filesystem path.
- Decide whether client capability announcement is needed before returning rich
  memory records.

**Dependencies**

- Define transcript ownership in DT-004 so memory and transcript APIs do not
  duplicate each other.
- Reuse mailbox-style pagination/error behavior where possible.

**Acceptance criteria**

- A v2 client can request newest and older bounded pages for one existing node.
- Ordering and cursor behavior are deterministic under concurrent memo appends.
- Current playbook and rollback availability are represented without reading files
  in the WebView or Tauri layer.
- Missing project/node, corrupt memory, oversized request, and unsupported cursor
  produce explicit correlated errors.
- Local and remote projects have identical protocol semantics.
- Swift round-trip, frame-limit, authorization/path, and compatibility fixtures
  pass.

### DT-002 — Atomic edge editing

**Problem**

The native edge editor can change an existing edge specification. The daemon
protocol currently exposes `createEdge(from:to:spec:)` and `deleteEdge(UUID)` but no
atomic update operation.

Delete followed by create is not equivalent: it loses edge identity, exposes an
intermediate graph to subscribers, can partially fail, and may alter persisted
layout or activity references.

**Evidence and current limitation**

- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift` defines `createEdge` and
  `deleteEdge` only.
- `LoopEdge` has a stable ID and an `EdgeSpec`.
- Win32 collects an edge specification in its editor/context workflow.
- `graphChanged` can publish the final graph but cannot make two separate mutation
  requests atomic.

**Investigation questions**

1. Is the complete editable unit only `EdgeSpec`, or may endpoints change?
2. Should the command be `updateEdge(UUID, spec: EdgeSpec)` or a partial
   `EdgeUpdate`?
3. Which validation from edge creation must be rerun for an update?
4. Does changing an already-fired edge affect firing history or only future
   evaluation?
5. Are imported/composite nested edges addressed through the existing
   `subGraphCommand` wrapper without additional protocol work?

**Likely daemon files and types**

- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
  - proposed `GraphCommand.updateEdge(UUID, spec: EdgeSpec)`
- `GraphcodeKit/Sources/Domain/LoopEdge.swift`
- `GraphcodeKit/Sources/Domain/EdgeSpec.swift`
- `GraphcodeKit/Sources/GraphStore.swift`
- CLI command parsing in `GraphcodeKit/Sources/CLI/GraphcodeCommand.swift`
- Swift and frozen Windows wire fixtures

**Compatibility and security**

- Additive GraphCommand case only; preserve existing edge decoding.
- Validate referenced edge and any endpoint/predicate/path data before mutation.
- Emit one authoritative graph revision and no observable delete/create
  intermediate state.
- Return explicit refusal for immutable fields rather than silently ignoring them.

**Dependencies**

- None for top-level edges.
- Composite UI depends on confirming the command routes unchanged through
  `subGraphCommand`.

**Acceptance criteria**

- Updating an edge preserves its UUID.
- Subscribers observe one graph revision containing the complete edited edge.
- Invalid predicate/spec/cycle changes leave the original edge untouched.
- Nested composite edges update through the standard graph-command routing.
- Old clients continue to decode snapshots containing updated edges.
- Command round-trip and GraphStore atomicity tests pass.

### DT-003 — Project relocation

**Problem**

The Windows UI intentionally does not offer Move Project because the daemon has no
authoritative relocation command. A safe move must coordinate the project path,
registry membership, persisted graph, memory, sessions, templates/worktrees,
recent/open-project records, subscriptions, and every client keyed by canonical
path.

**Evidence and current limitation**

- `DaemonCommand` provides `openProject`, `closeProject`, `forgetProject`, and
  `deleteProjectGraph`, but no move/relocate command.
- Project path is used as routing identity in `graphCommand(projectPath:command:)`,
  graph events, mailbox commands, registry storage, and client selection state.
- A native filesystem move followed by open/forget is not transactional and can
  strand support-directory state or active sessions.

**Investigation questions**

1. Is relocation limited to local projects on the same volume, or may it cross
   volumes and remote hosts?
2. Must all sessions be stopped, or can zmx sessions and worktree bindings survive
   a canonical root change?
3. Which support-directory artifacts are path-slug keyed and need migration?
4. How do connected clients learn the identity change: a dedicated
   `projectRelocated` event, close/open pair, or registry snapshot?
5. What rollback is possible after filesystem move succeeds but metadata migration
   fails?
6. How are active worktrees, linked repositories, templates, imported attachment
   paths, and recent-project records rewritten?

**Likely daemon files and types**

- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
  - proposed `DaemonCommand.relocateProject(fromPath:toPath:)`
  - likely `DaemonEvent.projectRelocated(fromPath:project:)`
- `GraphcodeKit/Sources/ProjectRegistry.swift`
- project persistence and recent/open-project stores
- `GraphcodeKit/Sources/GraphStore.swift`
- `NodeMemory`, worktree, template, session-launch and zmx locator code
- Windows/macOS project lifecycle clients and tests

**Compatibility and security**

- Canonicalize source and destination and reject traversal, aliases, nested moves,
  unsupported remote schemes, and destination collisions.
- Do not accept raw shell commands.
- Define same-user permissions and symlink/reparse-point behavior.
- Avoid exposing a period where both paths are writable authorities.
- Old clients that do not understand a relocation event must converge through
  compatible close/open snapshots or be explicitly disconnected/resynced.

**Dependencies**

- DT-005 for remote project semantics.
- Worktree/session ownership investigation before allowing moves with active loops.

**Acceptance criteria**

- The operation is atomic from daemon clients' perspective or has a documented,
  tested rollback state.
- Graph, memory, session, recent/open-project, worktree and template references are
  either migrated or explicitly rejected before filesystem mutation.
- All subscribed clients converge on one new canonical project identity.
- Destination collision, active-session, permission, cross-volume and partial-copy
  failures are covered by tests.
- Existing open/close/forget behavior remains wire compatible.

## Needs investigation before classification

### DT-004 — Bounded transcript and session-history reads

**Problem**

React needs transcript/history views separate from terminal scrollback. Backend
transcript resolvers already exist, but the correct authority for bounded local and
remote reads is not established.

**Evidence and current limitation**

- `LoopNode` and daemon events do not carry transcript content.
- `GraphStore` reads backend transcripts internally for orchestration summaries,
  goal verdicts, and usage.
- `GraphExportBundle.swift` installs/exports transcript artifacts client-side
  because they can be megabytes and must not pass through ordinary graph frames.
- The v2 frame ceiling is 1 MiB, so an unbounded transcript event is invalid.

**Investigation questions**

1. Can a narrow Rust adapter reuse the same backend transcript resolvers without
   duplicating parsing and remote access rules?
2. Does graphcoded already have the only valid remote transport/context for remote
   transcripts?
3. Should the UI receive normalized messages, raw backend records, or bounded text
   chunks?
4. What cursor remains stable while a transcript is appended or compacted?
5. Which content may be redacted, and can tool payloads contain secrets?
6. Should transcript requests share the graph daemon protocol or use a separate
   authenticated high-volume channel?

**Likely daemon files and types if daemon support is chosen**

- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
- backend transcript readers/resolvers and `GraphStore` transcript polling paths
- new `TranscriptQuery`, `TranscriptPage`, and normalized entry types
- possibly a separate authenticated streaming endpoint rather than broadcast
  events

**Compatibility and security**

- Never broadcast transcripts to all project subscribers.
- Enforce byte/entry bounds and redact logs.
- Treat tool inputs, prompts, filesystem paths, tokens, and model metadata as
  sensitive.
- Preserve backend-specific lossless data if normalized output is not reversible.

**Dependencies**

- Coordinate with DT-001 so memory is not presented as transcript history.
- Coordinate with DT-006 if remote terminal and transcript access share a transport.

**Acceptance criteria for classification**

- A written ownership decision covers local and remote projects, cursor semantics,
  maximum transfer size, normalization, authorization, and redaction.
- A prototype proves a bounded read from at least Claude, Copilot CLI, and Codex.
- The decision states either the exact new daemon cases/channel or the exact native
  API proving daemon support is unnecessary.

### DT-005 — Remote-aware templates and attachments

**Problem**

Local template discovery and attachment staging are filesystem operations. It is
unclear whether remote projects expose those files through a client-owned SSH
adapter, through graphcoded, or through another existing remote session layer.

**Evidence and current limitation**

- Windows `TemplateLibrary.zig` reads project/user Markdown templates directly.
- `DraftAttachments.zig` stages files into support-directory node memory before
  sending `NodeDraft.attachments`.
- `createNode(NodeDraft)` already transports attachment metadata; it does not upload
  bytes.
- Applying local project-template semantics to a remote project would read the
  wrong filesystem.

**Investigation questions**

1. Where does graphcoded run for a remote project, and which process can access its
   project templates and support memory?
2. Are remote templates project files, user files on the remote host, or local user
   templates applied to a remote draft?
3. Is attachment upload needed, and if so can it use an existing SSH/file channel
   rather than the 1 MiB daemon frame?
4. Who validates file type, size, destination and cleanup after cancellation?
5. Can `PromptAttachment` remain a path/reference, or does remote use need an opaque
   attachment ID?

**Likely daemon files and types if daemon support is chosen**

- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
- template parsing/domain types
- `NodeMemory` attachment paths
- `ProjectRegistry` and remote project/session transport
- possible bounded template-list/read commands and attachment-upload capabilities

**Compatibility and security**

- Do not expose arbitrary remote file reads/writes.
- Enforce the existing eight-file and 10 MB-per-file limits before transfer.
- Canonicalize destinations and reject traversal/symlink escapes.
- Keep uploaded draft files isolated and garbage-collected after cancel/failure.
- Template bodies and attachment contents are sensitive and excluded from logs.

**Dependencies**

- Remote project architecture and DT-006 transport ownership.
- Import/export decisions in DT-007 may provide reusable large-file transfer.

**Acceptance criteria for classification**

- A sequence diagram identifies which process reads project/user templates and
  stages attachment bytes for local, SSH and Codespace projects.
- A prototype validates cancellation cleanup and one remote attachment.
- The result names exact daemon cases/types if required or an existing authenticated
  native channel if not.

### DT-006 — Remote zmx terminal streaming

**Problem**

Local terminal streaming can attach from Rust directly to zmx and does not require
graph daemon changes. Remote projects may place zmx on another host, and the
existing ownership/tunnel path must be confirmed before the same conclusion is
valid remotely.

**Evidence and current limitation**

- zmx remains the session owner; graph commands already stop/restart sessions.
- Current Tauri planning correctly assigns raw local zmx attach/read/write/resize to
  Rust, not to `graphcoded`.
- The daemon protocol has no terminal-byte commands or events, which is desirable
  for normal local operation.
- Remote project ingress and terminal attachment may already use SSH forwarding in
  the native client, but the reusable boundary for Tauri is not documented.

**Investigation questions**

1. Does the current remote client attach directly to remote zmx, tunnel a local
   socket, or ask a remote graphcode process to proxy it?
2. Can Rust reuse that authenticated tunnel without adding terminal bytes to the
   graph protocol?
3. How are node UUID, remote host/project identity, session name, and writer lease
   authorized?
4. Where does scrollback live and how is a reattach cursor represented?
5. Is a separate authenticated terminal channel required if no reusable tunnel
   exists?

**Likely daemon files and types if daemon support is chosen**

- zmx session launcher/locator and remote transport code
- project registry remote project representation
- potentially a separate terminal endpoint/capability announcement, not
  `DaemonEvent` byte broadcasts

**Compatibility and security**

- React must never provide an arbitrary session name, executable, host or command.
- Terminal bytes, paste content and scrollback are sensitive and never logged.
- Bound queues and enforce a writer lease.
- Preserve authenticated per-user/per-project isolation across tunnels.

**Dependencies**

- DT-005 remote ownership model.
- A local Rust zmx attach/resize/scrollback spike should complete first.

**Acceptance criteria for classification**

- Local streaming is confirmed daemon-independent.
- A real remote project proves attach, raw VT, input, resize, scrollback and
  reconnect through the selected transport.
- If new daemon support is required, the design uses a dedicated bounded channel
  and does not overload graph snapshot/event framing.

### DT-007 — Export/import and session transplantation

**Problem**

The daemon supports final graph import, while export bundle construction and
backend session installation are intentionally client-side. The transaction and
remote-host semantics need classification before React implements the workflow.

**Evidence and current limitation**

- `GraphCommand.importNodes(GraphImportRequest)` performs authoritative graph merge.
- `GraphExportBundle.swift`, `GraphExportBundle+ZIP.swift`, and
  `ProjectPersistence+Export.swift` collect graph, memory, prompts and sessions.
- Source comments state that session installation is client-side because transcripts
  can be megabytes and should not traverse the daemon frame.
- A failed session install followed by graph import, or vice versa, can leave a
  partial result without a defined transaction/rollback contract.

**Investigation questions**

1. Which client/native API already installs each backend's resumable session?
2. Must all sessions install successfully before `importNodes`, and how is cleanup
   performed if graph import then fails?
3. For remote projects, where is ZIP validation/extraction and session installation
   executed?
4. Does the daemon need a prepare/commit token for import without carrying bundle
   bytes?
5. How are node/session IDs remapped and reported back to the client?
6. What bundle size, archive-entry and path traversal limits are enforced?

**Likely daemon files and types if daemon support is chosen**

- `GraphcodeKit/Sources/GraphExportBundle.swift`
- `GraphcodeKit/Sources/GraphExportBundle+ZIP.swift`
- `GraphcodeKit/Sources/ProjectPersistence+Export.swift`
- `GraphcodeKit/Sources/IPC/DaemonProtocol.swift`
- `GraphcodeKit/Sources/GraphStore.swift`
- possible prepare/commit/abort metadata commands while bytes remain on a native
  authenticated file-transfer path

**Compatibility and security**

- Never send multi-megabyte ZIP/session contents in ordinary v2 frames.
- Validate archive paths, entry count, decompressed size, symlinks and executable
  content before installation.
- Do not overwrite unrelated provider sessions.
- Define rollback and orphan cleanup for every partial failure.
- Imported prompts, memory and transcripts are sensitive and excluded from logs.

**Dependencies**

- DT-004 transcript ownership.
- DT-005 remote large-file transfer.
- Backend session transplant support for every offered provider.

**Acceptance criteria for classification**

- A documented transaction orders validate, map IDs, install sessions, import graph,
  commit and cleanup/rollback.
- Local and remote sequence diagrams identify the process owning every byte.
- Failure injection at each stage leaves either the old state or a documented
  recoverable staging state.
- The decision names any new metadata-only daemon commands or proves existing
  `importNodes` is sufficient.

### DT-008 — Shared settings-store bridging

**Problem**

The React UI can render settings controls, but it must not write
`~/.graphcode/settings.json` until ownership between graphcoded, the existing native
clients and a Tauri Rust adapter is explicit. A naive read-modify-write adapter can
lose unknown fields, race another writer, or leave the daemon running with stale
values that the UI presents as active.

**Evidence and current limitation**

- `GraphcodeSettingsStore` is the authoritative decoder/default/migration contract.
- The current daemon protocol has no settings read/write event or revision.
- Existing clients write the shared file directly, while graphcoded reads settings
  at feature-specific points; live reload behavior is not one uniform contract.
- Reimplementing Swift defaults and migrations independently in TypeScript or Rust
  risks schema drift and destructive writes.

**Investigation questions**

1. Is one process intended to own writes, or may clients coordinate through atomic
   file replacement and optimistic revision checks?
2. Which settings take effect immediately, on the next command, or only after daemon
   restart?
3. How are unknown future fields preserved by an older Tauri client?
4. Should the bridge invoke a small shared Swift settings helper, duplicate the
   schema in Rust with golden fixtures, or add bounded settings commands/events?
5. How do all clients learn that another writer changed the file?
6. What validation and recovery behavior applies to corrupt or partially migrated
   files?

**Likely daemon/native files and types**

- `GraphcodeKit/Sources/Domain/GraphcodeSettings.swift`
- `GraphcodeKit/Sources/GraphcodeSettingsStore.swift`
- feature-specific settings reads in `ProjectRegistry`, `GraphStore` and session
  launch paths
- Tauri Rust settings adapter if file ownership remains client-side
- `DaemonProtocol.swift` only if graphcoded becomes the settings authority

**Compatibility and security**

- Preserve unknown fields and existing defaults/migrations.
- Use atomic replacement, same-user permissions and explicit parse/validation
  errors; never silently reset a corrupt file.
- Do not log provider credentials, paths or future sensitive settings fields.
- Surface restart-required versus live-applied values accurately.

**Dependencies**

- None for read-only presentation from a proven adapter.
- Native menu/settings entry points may be built before mutation, but save/apply
  remains blocked.

**Acceptance criteria for classification**

- A written ownership decision covers concurrent writers, revisions, unknown-field
  preservation, live reload and restart-required values.
- Golden fixtures prove the chosen adapter preserves Swift defaults, migrations and
  unknown fields.
- Concurrent-write and corrupt-file tests produce explicit recoverable errors.
- The decision names exact daemon cases if graphcoded owns settings, or the exact
  atomic native API if it does not.

### DT-009 — Nested composite Mailroom ownership and routing

**Problem**

Top-level project Mailroom reads and loop watch mutations have established wire
shapes. A drilled-in composite exposes child nodes through `subGraph`, but the
protocol does not state whether those children read/watch the parent project's
Mailroom or a child graph Mailroom.

**Evidence and current limitation**

- `DaemonCommand.mailbox(projectPath:query:)` addresses only a project path and has no
  composite parent chain.
- `GraphCommand.mailroomWatch(on:topic:from:)` requires the watcher to exist in the
  receiving `GraphStore`; routing it through `subGraphCommand` would target the child
  store, while an unwrapped command cannot find a nested watcher in the root store.
- `LoopGraph` and nested `subGraph` snapshots can each carry a Mailroom digest, but no
  source contract says whether those rooms are shared or independent.
- The React client therefore fails closed for Mailroom controls while drilled into a
  composite instead of reading the root room or inventing nested routing.

**Investigation questions**

1. Is Mailroom ownership project-wide, graph-instance-wide, or inherited by nested
   graphs?
2. If project-wide, how should an unread query address a nested reader atomically?
3. If graph-instance-wide, should `DaemonCommand.mailbox` accept a composite parent
   chain matching `subGraphCommand`?
4. Which graph snapshot/digest is authoritative after a nested watch or cursor advance?

**Acceptance criteria**

- One documented routing rule covers board, search, unread, cursor advance, post and
  watch operations for nested nodes.
- Frozen command/event fixtures cover at least a two-level composite reader and watch.
- A nested cursor advance cannot mark parent or sibling mail read accidentally.
- Old clients retain their current top-level project behavior.

## Existing daemon support is sufficient

These are not daemon backlog items. They remain frontend/native tasks and must not
be used to justify protocol changes without new evidence.

| ID | Interface | Existing support / correct boundary |
| --- | --- | --- |
| DS-001 | Node inspector snapshot data | `graphChanged` and `nodesChanged` already carry `LoopNode`, including state, instructions, goal, metrics, budget, worktree, attachments, summary, board, activity, usage and composite data |
| DS-002 | New Loop | `GraphCommand.createNode(NodeDraft)` already supports all five domain loop types, goal policy, heartbeat, backend/model, worktree, attachments and template attribution |
| DS-003 | Node lifecycle/actions | Existing rename/update/promote/stop/restart/resume/delete/message/memo/complete/refine/rollback/template/composite commands are sufficient |
| DS-004 | Mailroom | Existing mailbox query/response and post/watch commands provide bounded read and mutations |
| DS-005 | Persistent connection and replay | Existing v2 hello, stable client ID, `resumeFrom`, sequencing, subscriptions and replay errors are sufficient; implementation belongs in Rust |
| DS-006 | Local zmx streaming | Direct Rust-to-zmx attach/read/write/resize/scrollback is the intended boundary; no graph daemon byte proxy is needed |
| DS-008 | Local templates and attachment staging | Existing filesystem formats and `NodeDraft` references are sufficient through narrow native adapters |
| DS-009 | Local export/import bytes | Bundle construction/session installation remain native/client-side; existing `importNodes` performs the final graph mutation |
| DS-010 | Project open/close/forget/delete/global/recents | Existing `DaemonCommand` cases are sufficient |
| DS-011 | Quick Chats | Existing commands/events are sufficient |
| DS-012 | Edge create/delete | Existing commands are sufficient; only editing an existing edge is DT-002 |

DS-007 is retired and intentionally not reused. Settings-store bridging is now
tracked by DT-008 because cross-client write authority, schema preservation and
change notification were not proven by the existence of the file format alone.

## Investigation discipline

For each DT item:

1. Reproduce the limitation against authoritative Swift types and a real daemon.
2. Prefer a bounded request/response over adding data to every graph snapshot.
3. Prefer an existing authenticated native/zmx/SSH channel for high-volume bytes.
4. Additive protocol cases require Swift golden JSON and Windows compatibility
   fixtures before client implementation.
5. Do not create a parallel REST service or a second graph authority.
6. Close the item by changing its classification, recording the decision, and
   linking the implementation commit or design document.
