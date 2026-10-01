# Remote asset ownership and transfer contract

Remote assets use daemon protocol v2 correlated requests. The daemon is the authorization
boundary and chooses every destination. Clients provide a project identity, node identity,
safe display name, media type, byte count, digest, and ordered bytes; they never provide a
host destination path.

## Ownership

| Project classification | Authoritative template host                                                             | Attachment staging host                                             |
| ---------------------- | --------------------------------------------------------------------------------------- | ------------------------------------------------------------------- |
| Local                  | daemon host: project `.graphcode/templates` plus daemon user's template library         | daemon host: node memory attachment directory                       |
| SSH                    | SSH project host: project `.graphcode/templates` plus that host user's template library | SSH project host: `~/.graphcode/staging/<project-digest>/<node-id>` |
| Codespace              | Codespace project host, reached through the existing `gh codespace ssh` transport       | Codespace host, with the same staging layout as SSH                 |

`ProjectRef.metadata` is authoritative. Missing metadata or a false `templates` /
`attachments` capability fails closed. Local-looking strings do not change ownership:
classification, joined-project authorization, the canonical project identity, and the node
identity all have to agree. The authenticated project identity hashes both the
authoritative location kind and canonical path, so identical-looking local, SSH, and
Codespace paths remain distinct.

Attachment draft ownership combines the app's shared logical client ID with the
operating-system-authenticated peer process identity. The macOS orchestrator announces
the same logical ID used by its short-lived v2 asset sessions; copying a UUID from another
process does not claim its drafts. Closing an upload socket cancels that socket's active
transfers but preserves delivered drafts while another authenticated connection for the
logical client remains live. Closing the last connection cleans its uncommitted drafts.

## Template list and read

```mermaid
sequenceDiagram
  participant C as Client
  participant D as graphcoded
  participant H as Authoritative host
  C->>D: v2 openProject(project)
  C->>D: listTemplates(project, maxCount, maxBytes)
  D->>D: verify joined project + authoritative capability
  D->>H: bounded list/read regular *.md files
  H-->>D: safe names + bounded UTF-8 documents
  D->>D: reject duplicate UUIDs; sign origin + name + content digest
  D-->>C: correlated templateList (metadata + authenticated asset ID)
  C->>D: readTemplate(project, UUID, authenticated asset ID, maxBytes)
  D->>H: repeat bounded authoritative read and verify the exact identity
  D-->>C: correlated normalized templateContent
```

Hidden entries, non-markdown files, symlinks, non-regular files, hard-linked remote files,
oversized files, invalid UTF-8, malformed templates, unsafe names, and entries beyond the
request limits are rejected or omitted. Local and remote files are opened without
following links and validated from the opened handle before bounded reads. Remote process
stdout and stderr are drained concurrently with hard byte ceilings. Template contents are never replayed, broadcast,
logged, journaled, or copied into graph snapshots.

The daemon-issued template asset ID binds the authoritative project identity, template
UUID, project/home origin, safe filename, and content digest. Reads without that identity
fail closed. Duplicate UUIDs are rejected independent of list order, and a file that
changes or moves between project and home scope after listing cannot satisfy the read.

## Attachment upload and launch

```mermaid
sequenceDiagram
  participant C as Client
  participant D as graphcoded
  participant H as Authoritative host
  participant L as Session launcher
  C->>D: begin(project,node,name,type,size,sha256)
  D-->>C: transferID, chunk limit, expiry
  loop contiguous chunks
    C->>D: chunk(transferID, exact offset, bytes)
    D-->>C: nextOffset
  end
  C->>D: finalize(transferID)
  D->>D: verify owner, expiry, size, SHA-256
  D->>H: atomic write to daemon-selected project/node staging
  H-->>D: staged
  D->>D: hold provisional publication until response delivery
  D-->>C: PromptAttachment(opaque authenticated owner-bound reference, safe name)
  D->>D: commit publication only after response frame succeeds
  C->>D: createNode or nested subGraphCommand(...createNode)
  D->>D: resolve target graph; reject duplicate ID; validate references
  D->>H: move exact size+digest files into a no-replace lease namespace
  H-->>D: durable reversible lease
  D->>H: reverify lease at graph-commit boundary
  D->>D: apply the exact graph command
  D->>H: publish content-addressed retained ownership
  D->>D: finalize catalog ownership; remove unselected draft files
  C->>D: attended start / unattended ensure / restart / liveness recovery
  D->>D: authorize client or trusted daemon authority
  D->>D: resolve references at the common launch-copy boundary
  D->>L: node copy containing host-local paths
```

The maximum file size remains 10 MiB, the maximum attachment count is 10, and the raw
chunk maximum is 256 KiB. A maximum chunk encoded inside a complete v2 request envelope is
below the 1 MiB frame limit. Offsets must be exact and monotonic; overlap, gaps, replay,
unknown IDs, cross-client transfer use, hash mismatch, expiry, disconnect, cancellation,
and oversized chunks fail. Finalization uses a temporary regular file followed by
atomic no-clobber publication. Existing destinations are never followed or overwritten.

Aggregate reservations prevent many-node exhaustion in addition to the per-file and
per-node limits:

| Scope                 | Active transfers | Declared bytes | Buffered bytes |
| --------------------- | ---------------- | -------------- | -------------- |
| Connection/owner      | 32               | 64 MiB         | 32 MiB         |
| Authoritative project | 128              | 256 MiB        | 128 MiB        |
| Daemon                | 256              | 512 MiB        | 256 MiB        |

Count and declared-byte reservations are atomic at begin; buffered bytes are reserved
before each append. Every terminal path releases the same accounting without wrapping
integer addition.

Finalized, response-delivered drafts have a separate 15-minute lifetime and separate
atomic reservations. The daemon durably records the reservation before returning an
opaque reference:

| Scope                 | Drafts | Attachments | Bytes   |
| --------------------- | ------ | ----------- | ------- |
| Logical owner         | 64     | 128         | 64 MiB  |
| Authoritative project | 256    | 512         | 256 MiB |
| Daemon                | 512    | 1024        | 512 MiB |

The lifetime starts when the first attachment is delivered for a node. Additional
uploads and passive sockets do not extend it. There is no protocol refresh operation.
Expiry runs independently of logical-client connection lifetime, releases accounting
before cleanup, and removes only files recorded in the expiring draft. Failed cleanup
remains in an explicit retry queue and cannot make an expired reference valid again.

The project-scoped catalog records opaque project identity, logical owner, node and safe
name, exact size and digest, original creation/expiry deadlines, lease state, and cleanup
state. It does not contain attachment bytes, credentials, remote commands, or local/remote
host paths. Writes use atomic replacement. Startup validates count/byte bounds with
overflow-safe arithmetic, quarantines corrupt catalogs, rebuilds quota accounting exactly
once, and preserves original deadlines. Opening a project binds its current canonical
path to matching opaque catalog records and reconciles them against the persisted graph:
a graph-owned lease is finalized idempotently, while a lease for an absent node is rolled
back. Thus restart cannot reset quota, abandon a delivered draft, or strand the
graph-persisted-before-finalize crash window.

The graph persists only the authenticated opaque reference and safe display name.
Attachment bytes never enter graph JSON, event replay, ordinary broadcasts, recents,
errors, journals, or dial logs. Attended starts, unattended starts, restart recovery, and
remote liveness ensures all resolve a launch-only node copy at one daemon boundary.
Persisted references are never replaced with host paths. A requesting connection must
already be joined to the canonical project before node lookup; internal recovery uses a
separate trusted daemon authority.

Finalize transitions atomically out of receiving before host staging begins. Cancel and
disconnect wait for an in-flight host operation, request transport cancellation where
supported, and remove any destination published before reference delivery. A failed
response write transfers ownership directly to the durable cleanup queue; no explicit
cancel is required. Draft expiry, graph rejection, provisional publication failure, and
lease rollback share that queue. Records are keyed by authoritative project, node, name,
digest, lease, and target, so duplicate requests deduplicate. Autonomous maintenance uses
bounded exponential backoff for at most eight attempts and seven days. The queue is
capped at 2,048 records and 1 GiB; admission reserves cleanup capacity before publication.
Terminal failures remain durably quarantined and are reported separately from pending
cleanup rather than being silently dropped. Cancellation never reports success while a
later finalize can publish.

Create rejects an existing node ID before any file operation. Reference validation is
non-destructive. Lease acquisition atomically removes the client-known mutable staging
name and verifies regular/single-link identity plus exact size and SHA-256 in a
lease-owned namespace. Local retained objects use a compact full-digest content key;
SSH/Codespace use the equivalent no-replace hard-link/unlink operation. The lease is
reverified immediately before `GraphStore`, and launch during the graph command resolves
from that lease. Only then can persistence, replay, or broadcast occur. A graph rejection
rolls back the lease namespace only. After graph success, the host idempotently publishes
retained content and the catalog drops the lease; a restart between those steps completes
publication from the graph as authority. Existing retained content is verified and never
removed by rollback. Successful creation removes only unselected draft files. Cleanup
failures release draft accounting only after durable cleanup ownership exists and never
delete pre-existing files or an existing node directory. Created-node files remain until
normal node-memory cleanup removes them.
The registry iteratively unwraps any depth of `subGraphCommand`, resolves each addressed
composite against the authoritative graph, and applies the same transaction to the exact
enclosed `createNode`. A missing or non-composite address rejects before dispatch and
cleans only that logical client's draft for the enclosed node ID.

## Compatibility

The contract is additive v2 and advertised by the `remoteAssets` server capability.
Unknown command/event fields retain normal Codable forward-compatibility behavior. V2
clients must use opaque attachment references and authenticated template asset IDs. The
shared logical client ID is an optional field on the existing capability announcement;
older daemons ignore it, while current daemons bind it to the authenticated peer process.
The narrow v1 local compatibility form accepts only a regular, single-link, non-reparse file
whose exact safe filename is already inside the authoritative project/node attachment
directory. Before graph persistence it receives the same exact descriptor-bound lease
and is rewritten to an authenticated opaque reference, so later launch never trusts the
legacy filename. Arbitrary daemon-host paths, traversal, remote legacy paths, and links
are rejected before graph mutation. New
macOS clients fall back to the legacy local template implementation when an older daemon
does not advertise v2 remote assets; remote access fails closed rather than reading a
client-local URI.
