# Shared Mac/iOS sync projection

macOS and iOS use the same value projection and Japanese labels. Platform UI
may arrange the controls differently, but it must not invent another state or
different winner semantics.

This is the shared presentation contract. The current Swift names and labels
are implemented in `NovelKit/Sources/NovelSyncV2Application/UIState.swift`
(source reviewed 2026-09-12). The abstract `parked(reason)`/`failed` values below
summarize several concrete cases; they are not a second enum to implement.

The shared kernel emits one immutable value:

```text
SyncUIState {
  workID,
  localDurability: unsaved | saving | saved(generation, snapshotID) | failed,
  remoteProgress: idle | noChanges | syncing(commandID) | offline |
                  parked(reason) | quarantined(reason) | needsChoice | failed,
  conflict: { conflictID, revision, baseSnapshotID?, localSnapshotID,
              remoteSnapshotID, sourceGeneration, commandID? }?,
  lastTypedResult
}
```

Every sheet action carries `workID`, `conflictID`, `revision`, both branch IDs,
and the mandatory positive source generation persisted on that exact conflict
candidate/current projection. The kernel compares all values with the current
projection before it creates a command. A sheet from another work or older
revision returns typed `staleConflictAction`; it performs zero SQLite mutation
and zero network bytes. Only a current action seals a new command, after which
the returned projection carries its `commandID`. macOS and iOS close/refresh
the stale sheet from the same result rather than choosing a branch.

| Kernel state | Shared label | Meaning |
| --- | --- | --- |
| `idle` / `noChanges` | `同期済み` | local checkpoint is durable; no remote work remains |
| `syncing` | `同期中` | a sealed command or transfer is active |
| `offline` | `端末に保存済み・通信待ち` | local save succeeded; retry is parked |
| `needsChoice` | `競合の確認が必要です` | one active conflict; exactly three choices |
| `parked(differentAccount)` | `別のアカウントのため保留中` | no object lookup or upload is allowed |
| `quarantined(fenceChanged)` | `安全確認後に同期を再開します` | fence/bootstrap/replan is required |
| `failed` | `同期を再試行できます` | local state remains safe; retry is explicit or scheduled |

An explicit sync with no changes returns `noChanges` and is success, not
failure. The UI never turns a no-op into an error toast. All states expose a
local-save indicator independently from remote progress.

## Current Swift projection

In addition to the abstract contract above, the implemented state covers the
following actionable states. Both platforms should use the shared projection
instead of copying labels into their own state machines.

| Swift case | Implemented label |
| --- | --- |
| `pending` | `同期待ち` |
| `authenticationRequired` | `サインインすると同期します` |
| `fenceChanged` | `アカウントの安全確認が必要です` |
| `parkedDifferentAccount` | `別のアカウントのため保留中` |
| `quarantined` | `安全確認後に同期を再開します` |
| `retryable` | `端末に保存済み・同期を再試行します` |
| `readyForSafeAdoption` | `サーバーの版を適用できます` |
| `failed` / `receiptMismatch` | `同期を再試行できます` |

These source mappings do not establish that every app route renders them
correctly. The known signed-in new-work symptom and iOS acceptance work remain
in the [handoff](../../SNAPSHOT_SYNC_V2_HANDOFF.md).
