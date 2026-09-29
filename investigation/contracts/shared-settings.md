# Shared settings contract

`graphcoded` is the only product process that writes `settings.json`. macOS, Tauri, the
CLI, and future clients read and update the document through daemon protocol v2.
`GraphcodeSettingsStore.save` remains a persistence primitive for the daemon and tests,
not a client ownership boundary.

## Protocol

- `loadSettings` returns a correlated `settingsChanged(GraphcodeSettingsSnapshot)`.
- `updateSettings(expectedRevision:settings:)` replaces every setting known to the
  caller only when `expectedRevision` is the SHA-256 of the exact current file bytes.
- A successful update returns the new snapshot and broadcasts the same event to clients
  that announced the `settingsChanged` capability.
- Clients re-announce that capability and issue `loadSettings` on every reconnect, so an
  offline edit is published even when replay contains no settings event.
- Conflicts use `settingsConflict`; invalid JSON or a non-object document uses
  `settingsCorrupt`; unreadable/write failures use `settingsUnavailable`; oversized
  documents use `settingsPayloadTooLarge`.
- Version-2 frames remain under the existing 1 MiB envelope cap. The settings document is
  capped at half that size so response/envelope overhead cannot cross the frame bound.

The daemon serializes updates. A client must reload after a conflict and deliberately
reapply its edit; the daemon never merges two stale typed snapshots.

## Compatibility and recovery

The daemon decodes with `GraphcodeSettings`, so missing-field defaults and migrations are
identical to macOS. On save it encodes the complete known schema and overlays those keys
onto the original JSON object. Unknown, retired, and newer-version fields remain value
equivalent even though formatting is normalized. `worktreePolicies` membership comes from
the new typed value, so removing a known entry deletes it; unknown nested members inside
retained policy entries are recursively preserved.

A missing file is first launch and produces the default snapshot with `exists: false`.
A corrupt file is a recoverable error. It is not renamed, deleted, replaced, or decoded as
defaults by the write path. The user can repair or restore it and retry `loadSettings`.

## Application timing

Every snapshot carries the complete field timing table:

| Timing          | Fields                                                                                                                                                                                                                               |
| --------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `live`          | `endsResolvedSessionsAfterMinutes`, `worktreePolicies`, `showsActivityStrip`, `betaUpdates`, `summarisesLoops`, `summaryUsesModel`, `visualisesSummaries`, `daemonHeartbeatEnabled`, `mailroomEnabled`, `keepsMacAwakeWhileLoopsRun` |
| `nextLoop`      | `defaultBackend`, `defaultModelTier`, `autoSelectsModel`                                                                                                                                                                             |
| `nextSession`   | provider permission fields, `copilotPreferredVersion`, `briefsSessionsAboutTheGraph`                                                                                                                                                 |
| `appRestart`    | none                                                                                                                                                                                                                                 |
| `daemonRestart` | none                                                                                                                                                                                                                                 |

`nextSession` includes a resume or restart because launch arguments and briefing content
are assembled when that session starts. No current shared setting requires restarting the
daemon.
