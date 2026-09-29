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
      "diagnostics": true
    }
  }
}
```

The location is an opaque classification, not connection configuration. The metadata
must not contain SSH users, hosts, ports, commands, repository URLs, Codespace names,
tokens, or credentials. `path` remains the stable project identity and keeps its existing
canonicalization and duplicate-path behavior.

The registry is authoritative. It retains persisted metadata for a known path and only
uses `RemoteProjectLocation` to classify a project that has no stored metadata. This
allows the same display name and path text to represent different synthetic registry
fixtures without requiring clients to parse path syntax.

Current daemon capability defaults reflect implemented behavior:

| Location  | Reveal | Templates | Attachments | Interactive terminals | Diagnostics |
| --------- | ------ | --------- | ----------- | --------------------- | ----------- |
| Local     | Yes    | Yes       | Yes         | Yes                   | Yes         |
| SSH       | No     | No        | No          | No                    | Yes         |
| Codespace | No     | No        | No          | No                    | Yes         |

Remote diagnostics cover the existing daemon-owned remote usage, presence, summary, and
transcript reads. Remote template resolution, attachment staging, local file-manager
reveal, and Tauri terminal streaming are not advertised.

Clients must treat absent metadata or absent capability flags as unsupported. Older
clients ignore the additive field and retain their existing behavior. The daemon enriches
legacy recent entries when it lists them and records the same metadata into subsequent
open and replayable graph snapshots.

The reserved `graphcode://global` scope is not a project location and does not carry this
metadata. Its existing interactive terminal and diagnostic operations remain available;
project-only reveal, template, and attachment operations do not apply.
