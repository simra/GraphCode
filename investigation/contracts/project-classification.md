# Project classification contract

`ProjectRef.metadata` is optional additive daemon-owned metadata on every recent-project
reference and every `LoopGraph.project` snapshot.

```json
{
  "metadata": {
    "location": "local | ssh | codespace",
    "capabilities": {
      "revealInFileManager": true,
      "templates": true,
      "attachments": true,
      "interactiveTerminals": true,
      "diagnostics": true,
      "memoryReads": true,
      "projectRelocation": true
    }
  }
}
```

The location is an opaque classification, not connection configuration. The metadata
must not contain SSH users, hosts, ports, commands, repository URLs, Codespace names,
tokens, or credentials. `path` remains the stable project identity and keeps its existing
canonicalization and duplicate-path behavior.

The registry is authoritative. Persisted graph and recent-project metadata is untrusted
input: it is overwritten from the registry's classifier whenever a graph or recent
reference is loaded or emitted. Persisted `location: local` or capability booleans can
therefore never authorize a local operation. Production classification may bootstrap
from `RemoteProjectLocation`, but clients do not parse path syntax and tests can inject
different registry classifications for identical display names and path text.

Every graph held by a project `GraphStore`, including every recursively nested composite
subgraph, carries the canonical root project path and classification. Nested graph names
remain available for display, but nested synthetic paths and metadata are never
authority. The invariant is applied on load, draft/import/template ingress, child-store
writeback, and again before persistence, replay insertion, or broadcast.

Current daemon capability defaults reflect implemented behavior:

| Location  | Reveal | Templates | Attachments | Interactive terminals | Diagnostics | Memory reads | Relocation |
| --------- | ------ | --------- | ----------- | --------------------- | ----------- | ------------ | ---------- |
| Local     | Yes    | Yes       | Yes         | Yes                   | Yes         | Yes          | Yes        |
| SSH       | No     | No        | No          | No                    | Yes         | Yes          | No         |
| Codespace | No     | No        | No          | No                    | Yes         | Yes          | No         |

Remote diagnostics cover the existing daemon-owned remote usage, presence, summary, and
transcript reads. Memory reads are location-independent because the daemon-owned durable
memory store remains local even for remote sessions; see `node-resource-read.md`. Remote
template resolution and attachment staging use the bounded daemon-owned v2 contract in
`remote-assets.md`. Local file-manager reveal and Tauri terminal streaming remain
unadvertised.

Clients must treat absent metadata or absent capability flags as unsupported. Older
clients ignore the additive field and retain their existing behavior. The daemon enriches
legacy recent entries when it lists them and records the same metadata into subsequent
open and replayable graph snapshots.

Unknown future locations or malformed metadata discard only the optional `metadata`
field. The surrounding `ProjectRef`, graph, recent-project list, and daemon envelope
remain decodable so clients can preserve identity and continue acknowledging frames.

The reserved `graphcode://global` scope is not a project location and does not carry this
metadata. Its existing interactive terminal and diagnostic operations remain available;
project-only reveal, template, and attachment operations do not apply.
