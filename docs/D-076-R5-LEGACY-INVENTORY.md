# D-076 R5 legacy同期 source inventory

このファイルは、Episode／Work履歴同期を `NovelSyncLegacy` と
`NovelSyncCloudKitLegacy` へ移す前の source inventory である。R5aで通常の
production compositionから `workTransport` を外したが、現在の `NovelSync` と
`NovelSyncCloudKit` には履歴sourceがまだ含まれている。ここに書いた候補を
target分離済みとは扱わない。

## 移動候補（純粋なlegacy domain）

`NovelSyncLegacy` の初回移動候補は、現在のlive Note domainから参照されない
次のsourceである。

```text
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+Authority.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+Editing.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+Internals.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LeaseRequest.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirst.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstAuthority.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstConflictAncestry.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstConflictResolution.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstGraph.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstObservation.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstReconciliation.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+LocalFirstRecording.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+RemoteControl.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+Synchronization.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator+SynchronizationConflict.swift
NovelKit/Sources/NovelSync/EpisodeSyncCoordinator.swift
NovelKit/Sources/NovelSync/EpisodeSyncJournal+Validation.swift
NovelKit/Sources/NovelSync/EpisodeSyncJournal.swift
NovelKit/Sources/NovelSync/EpisodeSyncModels.swift
NovelKit/Sources/NovelSync/EpisodeSyncTransport.swift
NovelKit/Sources/NovelSync/FileEpisodeSyncJournal.swift
NovelKit/Sources/NovelSync/FileWorkSyncJournal.swift
NovelKit/Sources/NovelSync/WorkSnapshotMerger.swift
NovelKit/Sources/NovelSync/WorkSyncCoordinator.swift
NovelKit/Sources/NovelSync/WorkSyncJournal.swift
NovelKit/Sources/NovelSync/WorkSyncMutationLane.swift
NovelKit/Sources/NovelSync/WorkSyncTransport.swift
NovelKit/Sources/NovelSync/WorkSyncWireVersion.swift
NovelKit/Sources/NovelSyncCloudKit/CloudKitRecordCodec+Revision.swift
NovelKit/Sources/NovelSyncCloudKit/CloudKitRecordCodec+Work.swift
NovelKit/Sources/NovelSyncCloudKit/CloudKitWorkPublishPlanner.swift
```

## 移動前に分解する transitional source

次のsourceは、live Noteの作品棚・package readback・CloudKit compositionと
履歴同期が同居しているため、単純なファイル移動を禁止する。

- `WorkSnapshot.swift` / `WorkRevision.swift` / `SyncWorkCatalog.swift` /
  `SyncWorkLibrary.swift`
- `DeviceSyncSupport.swift` と `IOSDeviceSyncSupport.swift`
- `DeviceSyncProductionRuntime+Bindings.swift` /
  `+Library.swift` /
  `+Transport.swift`（iOS版を含む）
- `CloudKitEpisodeSyncTransport*`
- `AppleDeviceSyncLibrary*` / `AppleDeviceSyncServices*`
- `CloudKitSyncSchema.swift` と `CloudKitRecordCodec.swift`

これらは、まず通常AppのEpisode／Work coordinator依存をlive Note向けの
binding・package snapshot境界へ置き換える。その後に共有値型とlegacy adapterを
分け、`NovelSyncLegacy`／`NovelSyncCloudKitLegacy`へ移す。

## App sourceの依存境界

- `NovelApp/DeviceSync/Legacy/` と `NovelAppIOS/DeviceSync/Legacy/` は旧UI／旧
  coordinatorの保持場所であり、最終的にはunhosted compatibility testだけへ
  入れる。
- `NovelApp/DeviceSync/Runtime/` と `NovelAppIOS/DeviceSync/Runtime/` は現在
  liveとlegacyが交差している。production compositionはR5aでNote-onlyにしたが、
  runtime value typeのlegacy fieldsはR5本体で分離する。R5cではproduction runtime
  のWork transport実装と旧outbox再送だけを`DeviceSync/Legacy/`へ移し、次のtarget
  除外へ使える物理境界を先に固定した。
- `NovelApp/DeviceSync/Conflict/` と iOS Conflict adapterは履歴UIを保持する。
  通常targetから除外する前に、Note conflict viewとの共通presentation境界を確認する。

## R5の完了条件

1. transitional sourceからEpisode／Work coordinatorを取り除き、通常Appが
   `NovelSyncLegacy`／`NovelSyncCloudKitLegacy`を必要としない。
2. 候補sourceを各Legacy targetへ移し、旧test／fixtureだけがLegacy productを
   linkする。
3. `NovelSync`／`NovelLibrary`の公開APIにCloudKit型・旧coordinator型を残さない。
4. `.novelpkg` schema、Note wire、CloudKit Note record、offline／account fenceの
   挙動を変えず、`./Scripts/check.sh` を通す。

このinventoryはR5の実装準備であり、target追加・source移動の完了記録ではない。
