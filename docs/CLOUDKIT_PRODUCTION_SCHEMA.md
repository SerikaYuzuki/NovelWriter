# CloudKit署名・Production Schemaチェックリスト

この文書はD-063のApple外部Gateを再現可能に実行するためのoperator checklistである。containerはprivate databaseだけを使い、固定identifierは`iCloud.dev.serikayuzuki.fuminiwa.sync`、zoneは`FUMINIWA.DeviceSync.v1`である。署名済みempty-catalog smokeをremote CRUD、paired device、Production deploy、Release GOへ読み替えない。

## 0. 現在の検証状態（2026-08-12）

- freshな`./Scripts/check.sh`: `All checks passed`
- `NovelSync`: 142 / 142件（14 suites）
- `NovelSyncCloudKit`: 80 / 80件（20 suites）
- 署名済みDebug macOS／iOS build: codesignとentitlement read-back PASS。Team、Development container、CloudKit、APNs環境を確認
- 署名済み実Mac App: 同一accountのiCloud棚が`available`／0作品。restored stateのない初回`CKSyncEngine`がsame-account `.signIn`を通知しても、live scope再検証後に永久`accountRequired`へ落ちないことを確認

ここまでがsource complete／local automated GOとempty-catalog smokeの証跡である。Development schemaの実record／index目視照合、remote create／fetch／update／delete、receipt／CAS、paired Mac↔iPhone、Release／Production署名、Production schema deployは未実施であり、Release NO-GOを維持する。

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

D-063の現行通常Appがliveに必要とするのは、catalogの`FUMINIWASyncWorkV1`と、whole-work CASの`FUMINIWAWorkControlV1`、`FUMINIWAWorkRevisionV1`、`FUMINIWAWorkMutationReceiptV1`の4 typeである。D-059／D-060のEpisode経路3 typeは互換資料とsourceとして保持するが、D-063通常Appのlive経路ではない。

`productionSchemaChecklist`はsourceに残るCloudKit codecの全量inventoryとして7 typeを列挙する。そのため全7 typeをProduction schemaへ含める場合は、全typeのsystem field `recordName`に`QUERYABLE` indexを1つ作る。通常のD-063操作だけでは旧Episode 3 typeがDevelopment schemaへ自動materializeされないので、管理されたDevelopment-only schema seedingで代表recordを作るか、CloudKit Dashboardで3 typeを手動定義・照合する。どちらの方法を使ったか記録し、通常Appで旧Episode trafficを再開した証拠にはしない。codec testはfield名／型のsource契約を検査するだけで、Dashboard上のschema生成やProduction deployを証明しない。

### 現行D-063 live経路（4 type）

| Record type | Fields（型。`?`はoptional） | 必須index |
| --- | --- | --- |
| `FUMINIWASyncWorkV1` | `protocolVersion` Int64, `workID` String, `sourceDocumentID` String, `structureDigest` String, `title` String | `recordName` QUERYABLE |
| `FUMINIWAWorkControlV1` | `protocolVersion` Int64, `workID` String, `headRevisionID` String?, `snapshotDigest` String?, `sourceDocumentID` String?, `structureDigest` String?, `title` String?, `titleDigest` String?, `titleUTF8ByteCount` Int64?, `snapshotByteCount` Int64?, `clientCreatedAt` Date/Time? | `recordName` QUERYABLE |
| `FUMINIWAWorkRevisionV1` | `protocolVersion` Int64, `workID` String, `revisionID` String, `parentRevisionIDs` List<String>, `branchID` String, `authorReplicaID` String, `authorSessionID` String, `clientCreatedAt` Date/Time, `snapshotDigest` String, `snapshotByteCount` Int64, `revisionDigest` String, `revisionByteCount` Int64, `revisionAsset` Asset, `mutationID` String, `attachmentCount` Int64, `attachmentManifestDigest` String? | `recordName` QUERYABLE |
| `FUMINIWAWorkMutationReceiptV1` | `protocolVersion` Int64, `workID` String, `mutationID` String, `commandDigest` String, `resultHeadRevisionID` String, `snapshotDigest` String | `recordName` QUERYABLE |

### 保持中の旧Episode経路（3 type）

| Record type | Fields（型。`?`はoptional） | 必須index |
| --- | --- | --- |
| `FUMINIWAEpisodeControlV1` | `protocolVersion` Int64, `workID` String, `episodeID` String, `leaseEpoch` Int64, `headRevisionID` String?, `holderReplicaID` String?, `holderSessionID` String?, `leaseExpiresAt` Date/Time? | `recordName` QUERYABLE |
| `FUMINIWAEpisodeRevisionV1` | `protocolVersion` Int64, `workID` String, `episodeID` String, `revisionID` String, `parentRevisionIDs` List<String>, `branchID` String, `authorReplicaID` String, `authorSessionID` String, `clientCreatedAt` Date/Time, `bodyDigest` String, `bodyByteCount` Int64, `bodyAsset` Asset, `mutationID` String | `recordName` QUERYABLE |
| `FUMINIWAMutationReceiptV1` | `protocolVersion` Int64, `workID` String, `episodeID` String, `mutationID` String, `commandDigest` String, `resultHeadRevisionID` String, `resultLeaseEpoch` Int64, `resultHolderReplicaID` String, `resultHolderSessionID` String, `resultLeaseExpiresAt` Date/Time | `recordName` QUERYABLE |

cleanなDevelopment containerにはcustom zoneがまだ存在しない。live account確認済みで、confirmed binding、cached remote head、pending downloadがない場合だけ、zone-not-foundを空の利用可能catalogとして扱う。その後、利用者の明示的新規作成が`bootstrapZoneForNewSync`を通ってzoneを作る。

zone作成後、最初のWorkControl保存前にprocessが終了し、catalog queryがtyped `.invalidArguments`になった場合は、durableなpending createとbindingがlocator／WorkID単位で完全に1対1一致する時だけ同じ作成を再開する。unbound pending create、confirmed binding、件数／WorkID不一致、cached remote row、pending openでは再開しない。zone reset、malformed record、account未確認／変更、既存remote証跡があるzone-not-foundはfail-closedのままとする。このmappingと復旧は実Development containerのprocess-kill境界でも確認する。

## 3. Production deploy

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
