# Bounded node memory and playbook read contract

## Decision

Protocol v2 adds one request-scoped command:

```swift
DaemonCommand.nodeResource(projectPath: String, query: NodeResourceQuery)
```

`NodeResourceQuery` contains only the stored node UUID, one resource name, an optional
opaque cursor, and entry/encoded-byte limits. It accepts no filesystem path, support
directory, filename, session identifier, provider identifier, shell command, or remote
connection detail.

The three resources remain distinct from provider transcript history:

- `memory`: the daemon-owned append-only `NodeMemory` episode/memo log;
- `playbookCurrent`: normalized current playbook content and whether rollback is
  currently available;
- `playbookHistory`: prospective normalized refinement and rollback records written by
  the same mutation path that changes the playbook.

The answer is `DaemonEvent.nodeResourcePage`. It is legal only as the correlated response
to the request. It is never broadcast, sequenced, retained for reconnect replay, inserted
into `LoopGraph`, or included in `graphChanged`/`nodesChanged`. The React protocol layer
decodes the response for contract completeness, but issue #11 adds no inspector UI.

## Authority

`ProjectRegistry` authorizes every read from current daemon state. All checks must pass:

1. the socket negotiated protocol v2;
2. the socket joined the canonical resident project;
3. the root `LoopGraph.project` path is that canonical project;
4. authoritative registry classification advertises `memoryReads: true`;
5. the current graph tree owns the node UUID.

Missing metadata or capability fails closed. Persisted root metadata is overwritten by
the registry classifier, and every nested graph is rebound to the authoritative root
project before use. Editable nested graph paths or capability values therefore cannot
grant access. Unknown projects, unjoined projects, unknown nodes, and failed ownership
checks all return `nodeResourceUnauthorized` without revealing whether another project
or node exists.

`memoryReads` is advertised for local, SSH, and Codespace projects because the durable
memory store belongs to the local daemon for all three. A remote launch receives only the
bounded wake digest; the authoritative log, playbook, and audit history remain in the
daemon support directory. Consequently local, SSH, and Codespace requests execute the
same reader and cursor implementation and no SSH/Codespace script reads memory. This
also means no remote shell, SQL, glob, credential, or host-state input is involved.

## Storage and normalized content

Existing memory remains line-oriented and append-only. Public memory entries contain a
stable source-byte sequence, strict ISO-8601 timestamp, normalized content, and explicit
path/secret redaction labels.

Successful refinements and rollbacks append a versioned JSONL audit record under the
same `(project, node)` directory while holding the node-memory storage lock. A record
contains only timestamp, operation (`refinement` or `rollback`), the product playbook
content at that state, and rollback availability after the operation. The reader
normalizes controls and redacts filesystem paths and credential-shaped text before any
content reaches the wire. The record contains no daemon command invocation, author
credential, provider/model metadata, or hidden session state. Mutation failure rolls
back the tentative history append.

The current playbook response contains no internal filename. A never-refined node is a
successful state with `content: nil` and `rollbackAvailable: false`; absence is not
confused with a missing memory-log request.

## Pagination and cursor integrity

Memory and playbook history are returned newest first. The first request freezes the
complete-record source visible at that instant, up to the maximum readable extent.
Because all product writers hold the same storage lock and append a complete newline-
terminated record, a trailing partial record indicates external truncation/corruption
and is rejected. Older requests walk backward within only that frozen source.

The URL-safe base64 cursor is opaque to clients and binds:

- cursor contract version;
- SHA-256 project identity, node UUID, and resource;
- filesystem source identity;
- frozen snapshot extent;
- next older byte boundary;
- SHA-256 of the complete frozen prefix.

Every page re-reads and verifies the bounded frozen prefix before returning. Appends
beyond the frozen extent are accepted but cannot reorder, duplicate, or enter that
pagination session. A fresh cursor-less request sees them. Replacement, truncation below
the frozen extent, truncate/regrow with changed content, prefix rewrite, project/node
change, resource change, malformed cursor, or changed source identity returns
`nodeResourceInvalidCursor`; the daemon never silently restarts pagination.

Each request examines at most two 512 KiB buffers regardless of cursor depth. Paths are
derived solely from the authoritative project identity and node UUID through
`NodeMemory`; client text is never interpreted as a child path. Project strings
containing separators, quotes, shell syntax, SQL syntax, or glob characters only affect
the fixed storage key and cannot escape the daemon support directory. That key combines
a bounded readable slug with the full SHA-256 project identity, so two canonical project
strings that flatten to the same readable slug cannot share a node directory even when
they contain the same node UUID. The remote wake-digest mirror uses the same key.

The collision-safe key replaces the older slug-only memory directory. Slug-only
directories cannot be migrated automatically because they carry no authoritative
project identity and may already be ambiguous; they remain untouched rather than being
claimed by a possibly colliding project.

## Bounds and frame proof

- default page: 16 entries / 64 KiB encoded entry JSON;
- maximum page: 32 entries / 128 KiB encoded entry JSON;
- maximum single encoded entry: 64 KiB;
- maximum readable memory/history extent: 512 KiB;
- maximum current playbook source: the existing 8 KiB write bound;
- maximum cursor JSON before base64: 4 KiB.

The 128 KiB entry budget leaves more than 800 KiB beneath the existing 1 MiB v2 frame
limit for enum wrappers, field names, UUIDs, timestamps, cursor base64, JSON escaping,
and envelope/request correlation. The daemon separately encodes and preflights the
complete response envelope before delivery. UTF-8 content is counted after JSON encoding,
so multibyte text and escaping cannot bypass the page ceiling. Oversized sources, entries,
current playbooks, or complete envelopes fail explicitly rather than truncating.

## Errors and compatibility

Correlated error codes are:

- `nodeResourceUnauthorized`
- `nodeResourceMissing`
- `nodeResourceCorrupt`
- `nodeResourceOversized`
- `nodeResourceInvalidBounds`
- `nodeResourceInvalidCursor`
- `nodeResourceUnsupportedResource`
- `nodeResourceTransportFailure`

Unknown resource strings decode as an unsupported resource so they receive the explicit
code rather than a generic malformed-envelope error. The storage is provider-independent,
so there is no provider error.

The command/event and `memoryReads` capability are additive. Protocol-v1 commands retain
their existing encoding and behavior. Older v2 clients ignore the unknown response event
because they never request it; newer clients fail closed when an older daemon omits
`memoryReads`.
