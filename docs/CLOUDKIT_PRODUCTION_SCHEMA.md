# CloudKit署名・Production Schemaチェックリスト

この文書はD-063のApple外部Gateを再現可能に実行するためのoperator checklistである。containerはprivate databaseだけを使い、固定identifierは`iCloud.dev.serikayuzuki.fuminiwa.sync`、zoneは`FUMINIWA.DeviceSync.v1`である。署名済みempty-catalog smokeをremote CRUD、paired device、Production deploy、Release GOへ読み替えない。live 契約は[DEVICE_SYNC.md](DEVICE_SYNC.md) 0章。0章の件数は当時の local 証跡であり、再計測せずに更新しない。

## 0. 現在の検証状態（2026-08-13）

- `NovelSync`: 156 / 156件（18 suites）。うちN4 in-memory paired／offline／process-kill／account分離を含む
- `NovelSyncCloudKit`: 91 / 91件（25 suites）。`FUMINIWANote*V1` codec、catalog isolate、conflict inspector、engine pending filter、workID query fallbackを含む
- macOS Device Sync: 90 / 90件（5 suites）。iOS Device Sync: 87 / 87件（4 suites）。hosted NoteSync 3択 Mac 2 / 2、iOS Simulator 2 / 2。`FUMINIWAExperimental` build
- D-071 live経路のsource inventoryはlegacy 7 type＋Note 7 typeの14 type。Note typeの`workID`はQUERYABLE。inline JSONまたはentity `payloadAsset`＋`payloadByteCount`
- 署名済みMac＋iPhone paired、Development schemaのDashboard目視照合、実CloudKit create／fetch／update／delete、Production schema deployは **未実施**
- `./Scripts/check.sh`は`All checks passed`。N2〜N4 local成功をempty-catalog smoke、paired native、Release GOへ読み替えない
- 次の実装待ちは無い。残るN4は操作者の署名済みMac＋iPhone検証（本書5章）

ここまでが (a) source＋unit の証跡である。(b) Simulator／fakeはMac／iOSの短い3択layout test。(c) 署名済み実CloudKitは未実施。Release NO-GOを維持する。

## 1. Teamと署名設定

1. XcodeのSettings > Accountsで利用するApple Developer TeamとApple Development証明書を確認する。
2. `Config/Signing.local.xcconfig.example`を`Config/Signing.local.xcconfig`へコピーし、`DEVELOPMENT_TEAM`へTeam IDを設定する。local fileはGit管理外であり、証明書、秘密鍵、profile、Apple IDをrepositoryへ置かない。
3. `./Scripts/generate-project.sh`でprojectを再生成する。`project.yml`と`Config/Signing.xcconfig`が正であり、生成した`.xcodeproj`へのTeam手動設定を永続設定として扱わない。
4. Developer portalでmacOS App ID `dev.serikayuzuki.fuminiwa`とiOS App ID `dev.serikayuzuki.fuminiwa.ios`の両方へ、同じcontainer、iCloud / CloudKit、Push Notificationsを割り当て、profileを再生成する。

環境はbuild configurationとprofileの両方で一致させる。

| Configuration | APNs entitlement | iCloud container environment | 用途 |
| --- | --- | --- | --- |
| Debug | `development` | `Development` | Development containerと開発署名 |
| Release | `production` | `Production` | Production schemaを使う配布候補 |

macOSは`com.apple.developer.aps-environment`、iOSは`aps-environment`を使う。両targetは`com.apple.developer.icloud-container-environment`を持つ。macOSへApp Sandboxを追加せず、iOSだけが`UIBackgroundModes = remote-notification`を持つ。

## 2. Development schemaの全量照合

source inventoryのmachine-readableな正は`CloudKitSyncSchema.productionSchemaChecklist`である。Development環境で各record typeとfield typeを照合してからProductionへdeployする。文字列検索に使う本文fieldやtitle fieldへ不要なindex／full-text searchを付けない。

D-071の通常App live経路は`FUMINIWANote*V1` entity recordである。source checklistはlegacy 7 type＋Note 7 typeの14 typeを列挙する。**CloudKit Dashboard／Development／Productionへのschema deployは未実施**。D-059／D-060のEpisode経路3 typeとD-061のWork 3 typeは互換資料とsourceとして保持するが、D-071 cutover後の通常App live経路ではない。catalogの正は`FUMINIWANoteWorkV1`の存在であり、`FUMINIWAWorkControlV1`のheadをdownload条件にしない。

`productionSchemaChecklist`はsourceに残るCloudKit codecの全量inventoryとして14 typeを列挙する。Production schemaへ含める場合は、全typeのsystem field `recordName`に`QUERYABLE` indexを1つ作り、Note 7 typeにはカスタムfield `workID`のQUERYABLE indexも付ける。通常のD-071操作だけでは旧Episode／Work 6 typeがDevelopment schemaへ自動materializeされない。codec testはfield名／型のsource契約を検査するだけで、Dashboard上のschema生成やProduction deployを証明しない。

### 現行D-071 live経路（7 type）

| Record type | Fields（型。`?`はoptional） | 必須index |
| --- | --- | --- |
| `FUMINIWANoteWorkV1` | `protocolVersion` Int64, `workID` String, `entityID` String, `entityKind` String, `payloadJSON` String?, `payloadAsset` Asset?, `payloadByteCount` Int64?, `contentDigest` String, `title` String? | `recordName` QUERYABLE, `workID` QUERYABLE |
| `FUMINIWANoteChapterV1` | 同上（`title`なし） | `recordName` QUERYABLE, `workID` QUERYABLE |
| `FUMINIWANoteEpisodeV1` | 同上 | `recordName` QUERYABLE, `workID` QUERYABLE |
| `FUMINIWANoteCharacterV1` | 同上 | `recordName` QUERYABLE, `workID` QUERYABLE |
| `FUMINIWANotePlotCardV1` | 同上 | `recordName` QUERYABLE, `workID` QUERYABLE |
| `FUMINIWANoteFlagV1` | 同上 | `recordName` QUERYABLE, `workID` QUERYABLE |
| `FUMINIWANoteWorldNoteV1` | 同上 | `recordName` QUERYABLE, `workID` QUERYABLE |

payloadはinline JSONかentity `CKAsset`のどちらか一方。両方または両方欠けはinvalid。作品全体を1つの`CKAsset`にしない。

### 保持中の旧D-063 live経路（4 type）

| Record type | Fields（型。`?`はoptional） | 必須index |
| --- | --- | --- |
| `FUMINIWASyncWorkV1` | `protocolVersion` Int64, `workID` String, `sourceDocumentID` String, `structureDigest` String, `title` String | `recordName` QUERYABLE |
| `FUMINIWAWorkControlV1` | `protocolVersion` Int64, `workID` String, `headRevisionID` String?, `snapshotDigest` String?, `sourceDocumentID` String?, `structureDigest` String?, `title` String?, `titleDigest` String?, `titleUTF8ByteCount` Int64?, `snapshotByteCount` Int64?, `clientCreatedAt` Date/Time? | `recordName` QUERYABLE |
| `FUMINIWAWorkRevisionV1` | `protocolVersion` Int64, `workID` String, `revisionID` String, `parentRevisionIDs` List<String>?, `branchID` String, `authorReplicaID` String, `authorSessionID` String, `clientCreatedAt` Date/Time, `snapshotDigest` String, `snapshotByteCount` Int64, `revisionDigest` String, `revisionByteCount` Int64, `revisionAsset` Asset, `mutationID` String, `attachmentCount` Int64, `attachmentManifestDigest` String? | `recordName` QUERYABLE |
| `FUMINIWAWorkMutationReceiptV1` | `protocolVersion` Int64, `workID` String, `mutationID` String, `commandDigest` String, `resultHeadRevisionID` String, `snapshotDigest` String | `recordName` QUERYABLE |

### 保持中の旧Episode経路（3 type）

| Record type | Fields（型。`?`はoptional） | 必須index |
| --- | --- | --- |
| `FUMINIWAEpisodeControlV1` | `protocolVersion` Int64, `workID` String, `episodeID` String, `leaseEpoch` Int64, `headRevisionID` String?, `holderReplicaID` String?, `holderSessionID` String?, `leaseExpiresAt` Date/Time? | `recordName` QUERYABLE |
| `FUMINIWAEpisodeRevisionV1` | `protocolVersion` Int64, `workID` String, `episodeID` String, `revisionID` String, `parentRevisionIDs` List<String>?, `branchID` String, `authorReplicaID` String, `authorSessionID` String, `clientCreatedAt` Date/Time, `bodyDigest` String, `bodyByteCount` Int64, `bodyAsset` Asset, `mutationID` String | `recordName` QUERYABLE |
| `FUMINIWAMutationReceiptV1` | `protocolVersion` Int64, `workID` String, `episodeID` String, `mutationID` String, `commandDigest` String, `resultHeadRevisionID` String, `resultLeaseEpoch` Int64, `resultHolderReplicaID` String, `resultHolderSessionID` String, `resultLeaseExpiresAt` Date/Time | `recordName` QUERYABLE |

cleanなDevelopment containerにはcustom zoneがまだ存在しない。live account確認済みで、confirmed binding、cached remote head、pending downloadがない場合だけ、zone-not-foundを空の利用可能catalogとして扱う。その後、利用者の明示的新規作成が`bootstrapZoneForNewSync`を通ってzoneを作る。

zone作成後、Note catalogのCKQueryがCKError 12 / CKInternalErrorDomain 2015（`.invalidArguments`）になるのは、`FUMINIWANoteWorkV1`が未作成か`recordName`がQUERYABLEでないDevelopment窓である。account scopeがありcached remote／pending downloadがなければ空のavailable catalogとして扱い、明示の「iCloudに保存」で型をJIT作成する。保存済みのNote workはCKQueryではなくrecord ID fetchで棚へ戻す。confirmed local bindingだけを理由にfail-closedにしない。missing zoneはconfirmed bindingがあるとfail-closed。zone reset、malformed record、account未確認／変更はfail-closedのままとする。別端末のremote-only一覧はDashboardで`recordName`と`workID`をQUERYABLEにしたあと。

## 3. Production deploy

N4の署名済み検証はDevelopmentとNote 7 typeで行う。この章のProduction deployは、その後の別作業である。D-063当時の4 type手順をN4完了の条件にしない。

1. DevelopmentでD-063現行4 typeをlive操作から生成し、旧Episode 3 typeは管理されたschema seedingまたはDashboard手動定義で用意する。CloudKit Databaseで全7 type、全field型、7つの`recordName` QUERYABLE indexを目視照合し、方法と結果を記録する。
2. DevelopmentでMacから新規作品を作成し、catalog work／Work control／revision／receiptの4 typeが同じprivate zoneへ保存され、chooserのcatalog queryが成功することを確認する。zone作成直後のprocess-killからexact pending createが再開できることも確認する。
3. schema差分をreviewし、DevelopmentからProductionへ明示deployする。Production data／zoneをDevelopment cutoverのreset手順で削除しない。
4. Release configurationをProduction entitlementと配布用profileで署名し、同じProduction containerに対して新規作成、別端末download、offline編集、再接続、競合reviewを検証する。

## 4. 署名済み成果物のread-back

各buildの最終`.app`を対象に、埋込entitlementを`codesign -d --entitlements - <AppPath>`でread-backする。次を全て確認する。

- bundle IDとTeamが意図したApp ID／profileに一致する
- container identifierが両platformとも`iCloud.dev.serikayuzuki.fuminiwa.sync`
- DebugはAPNs `development`＋container `Development`
- ReleaseはAPNs `production`＋container `Production`
- `com.apple.developer.icloud-services`が`CloudKit`を含む
- macOSに`com.apple.security.app-sandbox`が混入していない
- iOS Info.plistに`remote-notification`があり、macOS Info.plistには機械的に追加されていない

最後に同一iCloud accountの署名済みMac＋iPhoneで、foreground、background、push欠落、offline、account sign-out／switch、各process-kill境界をcontent-free traceとjournal stateで照合する。Package Validator、External Change / Conflict、手動VoiceOver、production migration／minimum-version fenceは別Gateとして残る。

2026-08-12時点のread-back済み成果物はDebug macOS／iOSだけである。Release／Production profileのread-backと上記paired campaignは未実施である。

## 5. D-071 N4 署名済み検証（操作者）

この章だけが、今のsourceに対して利用者が行う次の作業である。local unit／Simulator成功をここに読み替えない。Production deploy（3章）はN4 Development pairedの後。

### 5.1 事前

1. 同一iCloud accountの署名済みMacとiPhone（またはiPad）。Debug configuration、container `Development`。
2. `Config/Signing.local.xcconfig`にTeam IDがある。`./Scripts/generate-project.sh`済み。
3. 通常の`FUMINIWA`／`FUMINIWAIOS`（Experimentalではない）を両方へ入れる。
4. 旧D-061／D-063のWork revisionが残っているDevelopment zoneは、N4ではcatalogに出ない。development cutoverとしてzoneと旧local `DeviceSync-v1` metadataをresetしてから始める。outbox／review／未回収packageがあればresetしない。
5. CloudKit Dashboard（Development、private database、zone `FUMINIWA.DeviceSync.v1`）で次を目視する。まだtypeが無ければ、Macで新規作品を1つ保存したあと再読込する。
   - `FUMINIWANoteWorkV1` ほかNote 7 type
   - 各typeの`recordName` QUERYABLE
   - 各Note typeのカスタムfield `workID` QUERYABLE（未設定だとConsoleに`workID query is unavailable`が出る。scan fallbackは動くが、Dashboardでindexを付けてから本試験する）

### 5.2 実施と報告

本文、話タイトルの全文、local path、CloudKitの生error payloadは送らない。各項目は成功／失敗、画面の状態、Consoleの`[FUMINIWA] note-sync`行だけでよい。明示同期は`explicit requested`／`explicit begin`／`explicit send`／`send ok`、拒否は`explicit skipped(…)`、通信失敗は`network failed(TypeName)`。

1. **往復**: Macで新規作品を作り、話を1つ書いて保存する。iPhoneの「iCloudの作品」に同じ作品が出て、開くと本文が一致する。
2. **逆方向**: iPhoneで別の話または人物を足して保存する。Macをforegroundに戻し、追加分だけが入る。入力中のEditorが巻き戻らない。
3. **offline**: 片側をAirplane Modeにして保存し、アプリを切って戻る。通信完了を待たずに開ける。再接続後に相手側へ届く。
4. **衝突**: 同じ話を両側で違う本文にして保存する。「変更の確認が必要です」と3択だけ。統合案、revision／merge等の内部語は出ない。1つ選んで結果を書く（選んだ側が残るか、両方が棚に残るか）。
5. **process-kill**: 保存直後に強制終了して再起動する。書いた内容がpackageに残る。再接続後に相手へ届く。
6. **account**: 別Apple Accountへ切り替える。今の作品が新accountの棚と混ざらない。旧accountへ自動送信しない。

失敗したら、その番号、画面の文言、`note-sync`のConsole行、Dashboardでtype／`workID` indexが見えたかを返す。

