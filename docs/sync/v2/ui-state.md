# Shared Mac/iOS sync projection

macOS and iOS use the same value projection and Japanese labels. Platform UI
may arrange the controls differently, but it must not invent another state or
different winner semantics.

This is the shared presentation contract. The current Swift names and labels
are implemented in `NovelKit/Sources/NovelSyncV2Application/UIState.swift`. The abstract `parked(reason)`/`failed` values below
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
| `failed` | `同期できませんでした` | local state remains safe; detail depends on the typed failure |

An explicit production sync reconciles the current checkpoint through the sealed publish and verified receipt path even when no new edit exists. A verified unchanged remote head returns `noChanges` and is success, not failure. An empty local outbox alone is not evidence of current remote equality. A verified remote descendant is projected as `readyForSafeAdoption` until the document gate and local generation allow its installation. The UI never turns a no-op into an error toast. All states expose a
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
| `failed(remoteDataUnavailable)` | `同期先のデータを利用できません` |
| `failed(uploadTooLarge)` | `送信上限を超えています` |
| その他の`failed` / `receiptMismatch` | `同期できませんでした` |

These source mappings do not establish that every app route renders them
correctly. Current implementation gaps and device acceptance remain
in [CODE_HEALTH](../../CODE_HEALTH.md).

## History availability (D-106)

`SyncV2HistoryItem.snapshotAvailability` is per snapshot: `local`, `unfetched`
or `unknown`. Page-level network availability does not prove that a version is
on this device. Both platforms use `SyncV2HistoryFetchState` and
`HistoryFetchControls`, with NovelUI theme tokens and accessibility labels.

| State | Label | Action |
| --- | --- | --- |
| Running | 古い履歴を取得中… | 復元 opens the waiting sheet |
| Paused / offline / constrained / expensive | オンラインで取得 | Priority fetch; costly paths require confirmation |
| Interrupted | 古い履歴を取得できませんでした・通信が途切れました | 再試行 |
| Validation failed | サーバーの履歴を確認できませんでした | 詳細 / explicit 再試行; no automatic retry |
| Suspended account/deletion | アカウントの状態を確認してください | Keep local history; no automatic restart |

The restore sheet says `この版はまだ端末にありません。取得後に復元できます。`
and offers `今すぐ取得`. Committed pages refresh the selected version's local
availability without rereading remote history. Arrival changes the sheet to the
normal restore confirmation; it never replaces the editor by itself. Actual
restore uses the existing IME/checkpoint/document operation gate and current
WorkID/session/account checks. Cancelling the sheet drops only the UI selection.

`retryable(historyIncomplete)` is a waiting state, preserving the sealed command,
Inbox, manuscript and unsent intents. Closed-group commits wake the existing
worker to retry its normal validation/CAS path. Sync/conflict status reads:
`サーバーの変更を確認するため古い履歴を取得しています。原稿は端末に保存済みです。`
Editing and local checkpoints remain available while waiting.

Only one backfill runs globally. Priority requests preempt the current work and
retain its queue entry and committed cursor. Validation failures are excluded
from automatic resume and priority-operation retries; an explicit retry is
required. Offline pauses all fetches. Low Data Mode, constrained and expensive
paths pause automatic fetches; a manual confirmation permits only the requested
work. A manual start on an unconstrained path does not authorize a later costly
path. Offline/account transitions revoke costly-path consent. HTTP page and
large-object requests carry the same network policy.

The shelf's secondary `historyBackfillNote` is separate from sync/publication
status and shown as progress only while running. It uses committed history MB
unless a snapshot count is known: wire `totals.items` counts manifests and
objects and must not populate `total_snapshots`. Page commits and terminal state
changes notify observers. Validation details are a fixed user-facing explanation,
never a raw error, URL, database path, or ID. Status transitions and readiness to
restore are announced without moving focus or blocking editing.
