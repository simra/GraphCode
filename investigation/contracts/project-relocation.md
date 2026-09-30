# Project relocation contract

Project relocation is a daemon-owned protocol-v2 transaction. Clients never move a
directory themselves and never provide graph, memory, template, session, or other support
paths. They provide only the source project path, destination path, an operation UUID, the
daemon-issued source identity token, the graph revision observed during preparation, and
explicit options.

## Supported scope

- Only projects authoritatively classified as `local` with the
  `projectRelocation` capability are eligible.
- SSH and Codespace projects return `projectRelocationUnsupported`.
- Relocation is an atomic rename on one filesystem volume. Cross-volume copy/delete is
  unsupported because GraphCode does not yet have a copy/fsync/verify/delete journal.
- A project with a live session, a node bound to a worktree, a linked-worktree Git file,
  registered Git worktrees, or submodules is rejected before filesystem mutation.
- Connected daemon clients are allowed. Clients that announced `projectRelocation` receive
  the correlated result and convergence event; older joined clients are disconnected so
  reconnect/restore observes only the canonical destination.

## Path and identity rules

Both paths are absolute, canonical local paths. The daemon rejects roots, the current
user's home, the GraphCode support directory, aliases, symbolic links, junctions/reparse
points, source/destination nesting, an existing destination, a case-only collision, an
unwritable parent, and a destination parent on another volume. The source identity token
is derived from stable filesystem volume/file identity, not the path, so it remains valid
across the rename. Preparation returns that opaque token and the current graph revision.
Commit reopens and reverifies both immediately before rename.

## State ownership

The transaction rewrites the authoritative root project on the graph and every nested
subgraph, recent/open project indexes, path-keyed graph and Mailroom files, node memory,
playbooks, refinement history, and attachments, plus persisted loop-history visits.
Project templates are inside the project and move with the directory. Terminal layouts,
provider transcripts/session IDs, and quick chats are keyed by node/chat UUID and do not
move. Live sessions and worktree bindings are rejected rather than killed or rewritten.

## Journal, commit, rollback, and recovery

The durable journal is written under the GraphCode support directory before mutation and
contains the operation, canonical paths, stable source identity, and rewritten graph.
The commit point is the successful same-volume directory rename. Before that point a
failure removes only transaction staging and the source remains authoritative.

After rename, metadata migration is idempotent. A failure before metadata mutation starts
first attempts to rename the verified destination back to the source. A successful
rollback returns an explicit rolled-back error. Once metadata mutation has started, or if
rollback cannot be proven, the destination remains the canonical filesystem authority,
the journal remains, and the result is success-shaped with `recoveryRequired: true`;
returning ordinary failure would invite a client to keep using the old path after an
irreversible move. That requesting connection is closed after receiving its correlated
result so reconnect/restore cannot keep using a leased old store. Daemon startup replays
journals:

- source present/destination absent: discard an uncommitted journal;
- source absent/destination present: finish support-state migration and record a receipt;
- both or neither present, or identity mismatch: retain the journal and report recovery
  failure on a later request rather than guessing.

Receipts make replay of the same operation UUID idempotent. Reusing an operation UUID
with different paths or expectations is a conflict.

## Protocol and events

The v2 hello advertises `projectRelocation`. `prepareProjectRelocation` returns a
correlated plan. `relocateProject` returns `projectRelocated`, and capable joined clients
receive one replayable `projectRelocated` convergence event followed by the ordinary
destination `graphChanged` snapshot. Version-1 commands and all pre-existing enum cases
remain unchanged.

Error codes distinguish unauthorized capability use, unsupported classification, source
missing or changed, active sessions, worktrees, destination collision, unsafe path,
cross-volume, permission, preflight, rollback, recovery, duplicate conflict, and transport
failure.
