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
- Preparation acquires a project-wide relocation lease before the first awaited session
  enumeration. Graph mutations, project open/close/delete/forget, and session launch or
  ensure operations fail explicitly while the lease is held. Session and repository
  topology are enumerated again at the final commit boundary.
- Connected daemon clients are allowed. Clients that announced `projectRelocation` receive
  the correlated result and convergence event; older joined clients are disconnected so
  reconnect/restore observes only the canonical destination.

## Authorization and operation binding

The connection preparing an operation must already be joined to the canonical source
path. Preparation binds the operation UUID, originating logical client UUID, canonical
source and destination, source identity, graph revision, options, leased store, and graph
snapshot. Only that client may commit the prepared operation, and every immutable field
must exactly match the prepared request.

Receipts retain the same originating-client and request binding. A lost-response retry can
therefore return the recorded result after the old source and joined store have
disappeared, but another client cannot obtain the result by guessing the operation UUID.
Reusing the UUID with different immutable input is a duplicate conflict.

## Path and identity rules

Both paths are absolute, canonical local paths. The daemon rejects roots, the current
user's home, the GraphCode support directory, aliases, symbolic links, junctions/reparse
points, source/destination nesting, an existing destination, a case-only collision, an
unwritable parent, and a destination parent on another volume. The source identity token
is derived from stable filesystem volume/file identity, not the path, so it remains valid
across the rename. On Windows, every existing component through the destination parent is
opened without following reparse points and any reparse component is rejected. Preparation
returns the opaque source token and current graph revision.

Commit retains an open source directory handle/descriptor from before final preflight.
Windows uses that handle with no-replacement `SetFileInformationByHandle(FileRenameInfo)`;
Darwin uses retained descriptor identity and `renameatx_np(RENAME_EXCL)`. The source
identity, destination ancestry, destination absence, support collisions, sessions,
worktrees, and submodules are rechecked immediately before this rename.

## State ownership

The transaction rewrites the authoritative root project on the graph and every nested
subgraph, recent/open project indexes, path-keyed graph and Mailroom files, node memory,
playbooks, refinement history, and attachments, plus persisted loop-history visits.
Project templates are inside the project and move with the directory. Terminal layouts,
provider transcripts/session IDs, and quick chats are keyed by node/chat UUID and do not
move. Live sessions and worktree bindings are rejected rather than killed or rewritten.

Every destination support key is preflighted before filesystem mutation: graph, Mailroom,
legacy graph/Mailroom names, recents, open-project records, project memory/playbooks,
refinement history, attachments, loop history, relocation receipts, and relocation
journals. Existing data is a destination collision; relocation never overwrites, deletes,
or merges it.

Before support mutation, `GraphWriter` blocks admission of old-path saves and drains its
serial persistence queue. The path remains blocked through commit so a queued or later
save cannot recreate old support state. A verified precommit failure or successful
rollback removes the block; successful relocation binds subsequent work to the canonical
destination.

## Journal, commit, rollback, and recovery

The durable journal is written under the GraphCode support directory before mutation and
contains the operation, canonical paths, stable source identity, and rewritten graph.
The exact commit point is the successful platform-native same-volume rename of the
retained, identity-verified source directory handle. Before that point a failure removes
only transaction staging and the source remains authoritative.

After rename, metadata migration is idempotent. A failure before metadata mutation starts
first attempts to rename the verified destination back to the source. A successful
rollback returns an explicit rolled-back error. Once metadata mutation has started, or if
rollback cannot be proven, the destination remains the canonical filesystem authority,
the journal remains, and the result is success-shaped with `recoveryRequired: true`;
returning ordinary failure would invite a client to keep using the old path after an
irreversible move. That requesting connection is closed after receiving its correlated
result so reconnect/restore cannot keep using a leased old store. Daemon startup processes journals independently in deterministic filename order:

- source present/destination absent: archive an abandoned precommit journal;
- source absent/destination present: finish support-state migration and record a receipt;
- corrupt journals, both/neither topology, or identity mismatch: quarantine the evidence
  and report that operation as ambiguous rather than guessing.

One bad journal never blocks valid recovery of another. If quarantine itself fails, the
original journal remains in place. Recovery exposes a per-operation status of `recovered`,
`abandonedBeforeCommit`, or `quarantined`; evidence is never deleted silently.

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

## Platform limitation

The Windows and Darwin commit paths provide retained-identity, no-replacement native
rename semantics. The Glibc fallback retains and reverifies a source descriptor but still
uses Foundation's move after checking destination absence; until it uses
`renameat2(RENAME_NOREPLACE)`, Linux has a narrower destination-creation race and is not
the acceptance-grade native path.
