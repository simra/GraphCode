# Bounded transcript read contract

## Authority and transport

`graphcoded` is the sole transcript authority. A client identifies a project and node; it
never supplies a filesystem path or provider session identifier.

- **Local projects:** the daemon resolves the node's banked session through the existing
  Claude Code, Copilot CLI, or Codex resolver and reads the provider-owned JSONL file.
- **SSH projects:** the local daemon resolves and reads the provider file through the
  project's existing multiplexed SSH transport.
- **Codespace projects:** the same remote command runs through `gh codespace ssh` (and the
  existing multiplexed path after its SSH user is learned).

Codex is resolved by identity, never by working directory. The daemon reads the node's
banked ID from `SessionIDStore` (or its remote twin), lets `CodexThreadResolver` replace
an ephemeral notify ID with the node-named persisted thread when Codex's state database
proves that mapping, and then accepts only a rollout whose filename contains that exact
thread UUID. Two nodes in the same CWD therefore cannot select each other's rollout. If
the banked/resolved ID and exact rollout cannot both be established, the read is missing;
the daemon does not fall back to newest-by-CWD.

The API is `DaemonCommand.transcript(projectPath:query:)`, available only in protocol v2.
Its `DaemonEvent.transcriptPage` answer is a response carrying the request ID. It is never
broadcast, sequenced, retained for replay, persisted in a graph, or included in
`graphChanged`/`nodesChanged`.

## Authorization

A read is allowed only when all three ownership checks succeed:

1. the requesting socket has joined the canonical project;
2. that resident project's graph owns the requested node (including a composite child);
3. the daemon resolves the provider session from that stored node.

There is no caller-controlled transcript path or session ID. Unknown projects, unjoined
projects, unknown nodes, and path-routing refusals all return `transcriptUnauthorized` so
the response does not reveal whether another project or session exists.

## Normalized records and lossless data

The wire returns normalized `TranscriptEntry` values: source byte offset, optional
timestamp, kind (`prompt`, `assistant`, `toolUse`, `toolResult`, or `status`), redacted
text, optional tool name, and the applied redaction classes.

Provider JSONL remains the lossless source of truth on the machine where the provider
wrote it. GraphCode neither rewrites nor persists a normalized copy. The first contract
does not expose raw records because normalization is not reversible and raw tool payloads
can contain arbitrary files, command output, prompts, credentials, and model metadata.
A future lossless export must be a separately authorized artifact channel, not an option
on this response.

## Pagination and bounds

Pages proceed from the start of the JSONL source in complete-record order. An opaque
cursor binds:

- contract version, node, and provider;
- provider source identity;
- the next byte offset;
- a SHA-256 commitment to every source byte before that offset;
- the length and hash of the preceding complete record.

Appending after a page does not change the committed prefix, offset, or anchor, so the
cursor remains valid and newly appended complete records appear on later pages. The
daemon hashes the committed prefix before and after each bounded read; local hashing is
streamed and remote hashing emits only the fixed-size digest. Replacement during a read,
same-inode truncate/regrow, an earlier-prefix rewrite, compaction, provider change, node
change, or alteration at the page boundary returns `transcriptInvalidCursor`; the daemon
never guesses a new position or remaps this integrity failure to a transport failure.

Requests default to 32 entries / 64 KiB and are capped at 64 entries / 128 KiB of encoded
entry JSON. A normalized entry is capped at 32 KiB and a provider source record at
256 KiB. The full response envelope is preflighted against the v2 1 MiB frame ceiling.
An entry, source record, or response that cannot fit fails with `transcriptOversized`
rather than being silently truncated. A final partially appended JSONL line is not
consumed until its newline arrives.

## Errors

The correlated v2 error codes are:

- `transcriptUnauthorized`
- `transcriptMissing`
- `transcriptCorrupt`
- `transcriptOversized`
- `transcriptInvalidBounds`
- `transcriptInvalidCursor`
- `transcriptUnsupportedProvider`
- `transcriptTransportFailure`

Malformed provider JSON is corrupt. Missing provider files are missing. OpenCode and Pi
remain explicitly unsupported by this prototype.

## Redaction

Normalization occurs before pagination bytes are counted and before any response leaves
the daemon.

- user prompts are replaced wholesale with `[redacted prompt]`;
- tool inputs are never copied; tool calls retain only the tool name;
- tool results are replaced wholesale with `[redacted tool result]`;
- arbitrary assistant/reasoning text is replaced wholesale with
  `[redacted assistant text]`; pattern redaction is used only to classify why content
  was withheld, not as permission to emit free-form provider text;
- tool names are emitted only from a fixed safe allowlist; unknown or malformed names
  become `tool`;
- only strict ISO-8601 UTC timestamps are retained;
- filesystem paths include quoted and unquoted Windows/POSIX forms, including spaces;
- secrets include AWS access/secret/session keys, bearer/basic authorization, URL
  credentials, JWTs, private keys, GitHub/Azure tokens, and API-key/`sk-` forms;
- provider/model metadata records and fields are omitted.

Each entry lists the redaction classes applied. Redaction is defense in depth, not an
authorization substitute.
