# Snapshot Sync v2 — 現在地と残件

更新: 2026-09-12（source・target構成の照合）。実機・stagingの最終記録は2026-08-18。**実装・統合中、Release NO-GO**。

この文書は実装状況と次の成果を示す。規範は[SNAPSHOT_SYNC_V2.md](SNAPSHOT_SYNC_V2.md)、[DECISIONS.md](DECISIONS.md) D-080〜D-085、[sync/v2/](sync/v2/)、認証は[AUTH.md](AUTH.md)。旧[SNAPSHOT_SYNC_HANDOFF.md](SNAPSHOT_SYNC_HANDOFF.md)はv1の履歴である。

## 現行sourceで確認できること

| 境界 | 実装と根拠 | まだ証明していないこと |
| --- | --- | --- |
| 保存・同期 | `NovelSyncV2`、`NovelSyncV2Store`、`NovelSyncV2Application`、`NovelSyncV2Runtime`を両Appが使用。SQLite BLOBとcheckpointがlocal authority | 両実機の安定した往復同期・異常終了復旧 |
| portable受渡し | `NovelSyncV2PortableBridge`が明示Import／Exportを担当。旧package／CloudKit lifecycleは`project.yml`でlive target外 | 全portable edge caseの製品受入 |
| 認証 | `NovelAuth`／`NovelAuthApple`、Rust `auth*.rs`、両Appの認証extensionが存在 | 本番notification、鍵rotation、backup復旧、account lifecycle |
| iOS導線 | `IOSWorkbenchViewV2.swift`に作品ホームから7機能への導線、regular幅の`NavigationSplitView`、`IOSEditorPane`がある | 以前の製品UIとの同等性。執筆補助・prompt copyのlive接続、ホーム等の仕上げ、実機受入 |
| 新規作品 | `makeNewDocument`→`checkpointAndInstallNewDocument`でaccount/sessionを固定・再検査。`ProductionSyncV2Kernel`→`ProductionScopeResolver.scopeForCheckpoint`は新Workを有効なepoch 2のaccountへbindする経路を持つ | 2026-08-18に報告された「signed-in新規作品が端末のみ」の解消。原因はsourceだけでは確定しない |
| server | `SyncServerV2`にAxum／SQLx、BYTEA object store、role-split bootstrap／migrator／runtimeがある | 現在稼働中のimage・DB・TLS・authenticated head。9月12日はremoteへ接続していない |
| 標準検証 | iOS `IOSDocumentStore+AuthenticationV2.swift`は現在も822行 | `check.sh`全通し成功。下記の8月18日失敗記録を参照 |

旧ハンドオフの「iOSはminimal shellだけ」は現行sourceの説明として使わない。一方、画面やAPIが存在するだけで製品UIの復旧完了とも扱わない。詳細は[IOS.md](IOS.md)と[STYLE.md](STYLE.md)を参照する。

## 次に解消する課題

### P0: iOSの執筆体験をv2へ接続する

目的は、既存の執筆要件と作品導線をv2保存・同期の上で使えるようにすること。live UIは以下にある。

- `NovelAppIOS/Features/Writing/IOSWorkbenchViewV2.swift`
- `NovelAppIOS/Library/IOSProjectHomeViewV2.swift`
- `NovelAppIOS/Library/IOSLibraryViewV2.swift`

旧UIは見た目と操作の参照に使える。storage／CloudKit／Note・Work・Episode同期を復活させず、shared application facade、session、IME、document gateを維持する。現在は画面遷移が接続済みだが、live editorに旧執筆補助やprompt copy導線が接続されておらず、作品ホームにSnapshot ID入力等の診断UIも残る。

完了の証拠は、復旧した操作と残る差分の一覧、必要なnavigation／編集回帰検証、署名済みiPhoneでの操作確認。プレビューやbuild成功だけでは完了にしない。

### P0: signed-in新規作品の端末のみ表示を再現・切り分けする

2026-08-18のiPhoneではsigned-in状態で作った試験作品が`端末のみ　同期を再試行できます`に留まった。現行sourceには新規Workのaccount binding経路があるため、「binding未実装」を原因として直し始めない。

local checkpoint、captured accountとvaultのbinding、durable intent、createWork→upload→register→publish、worker再開、remote head read-back、棚projectionのどこで止まるかを特定する。成果は原因を示す再現、対象境界の回帰検証、再起動／offlineでも先にlocal保存が完了する証拠、および実機の`同期待ち`→`同期済み`確認。

既存のunbound作品をloginだけでadoptする修正は不可。新規作成時の明示online scopeと、既存作品の移動・複製は別の境界にする。

### P1: 標準検証と運用文書の差分

- `IOSDocumentStore+AuthenticationV2.swift`は822行で、D-076の800行基準を超える。責務分割を検討し、コード変更後に標準検証を完走する。文書だけを直して成功へ読み替えない。
- Apple notificationの規範URLは`/v1/auth/providers/apple/notifications`、現行routeは`/v1/auth/apple/notifications`。通知統合前に[認証契約](AUTH.md)との不一致を解消する。
- [CA export script](../Scripts/export-sync-v2-staging-ca.sh)は旧v2 edge名`fuminiwa-sync-v2-edge`に固定され、checked-in Composeの`fuminiwa-sync-v2-role-split-edge`と一致しない。namespace文字列の確認のみでepoch 2も検査していない。[STAGING](SNAPSHOT_SYNC_V2_STAGING.md)の前提を確認してから使う。
- auth／syncはschemaを分離しているが、現在のruntime DB roleは両方の必要DMLを持つ。migration/runtime分離を、auth/sync別credentialの受入証拠にはしない。

## 受入基準

検証はD-086 / [AGENTS](../AGENTS.md)に従い、編集内容から「なし／軽い／中ぐらい／重たい」を選ぶ。merge前も一律の全通しは要求しない。保存・認証scope等に影響する重たい変更では`Scripts/check.sh`と関係する[conformance](sync/v2/CONFORMANCE.md)、[server検証](../SyncServerV2/README.md)、[Auth DB gate](../SyncServerV2/AUTH_INTEGRATION.md)を使う。今回の方針記録は検証なし。

以下は2026-08-18時点で未完了として引き継がれ、9月12日の文書改訂では再実施していない。

| 受入対象 | 必要な証拠 |
| --- | --- |
| 同一AccountIDのMac↔iPhone同期 | 双方向の編集とremote head read-back |
| 同時offline編集 | active conflictが1件だけになる |
| 競合3択 | この端末／サーバー／両方を実機で選び、元のlocal candidateを復元できる |
| 履歴・復元 | 両platformで事前checkpointを保持して復元できる |
| 障害・再起動 | process kill／lost response後にexact commandを再開する |
| offline | 起動・open・編集・autosave・closeがnetworkを待たない |
| remote-only作品 | account確認後に取得・openできる |
| no-op | 変更なし同期・保存が成功として表示される |
| account/fence | switch／rotation後にcross-account表示・送信・暗黙adoptが起きない |
| iOS製品UI | VoiceOver、Dynamic Type、IME、hardware keyboard、background／scene lifecycle／終了 |
| staging・公開運用 | exact image/project、TLS、authenticated capabilities/head、backup/restore、本番認証・account lifecycle |

次の引き継ぎには、変更点・検証日・対象revision・実行環境・結果・残件を記す。source確認、component test、staging、実機を分ける。原稿、token、鍵、`.env`、passwordを記録しない。

## 利用者の判断と実機確認

D-087でAppleログイン以外の独自account回復は提供しないこと、account削除の取消猶予30日、backup保持1年を採択した。判断待ちへ戻さず、この方針をversioned lifecycleへ実装する。検証段階とWindows方針を含む[決定済み事項](OWNER_DECISIONS.md)も参照する。

UI不足の復旧は既決要件に沿って進める。準備した画面の受入確認、署名・Appleシート・端末trust設定など利用者操作が必要な検証は、その段階で対象と操作を限定して依頼する。既定仕様をもう一度承認してもらう手続きにはしない。

Apple-only、server-readable、SQLite v2 authority、旧runtimeを戻さない方針は採択済み。通常の原因調査や境界を守る修正のために再承認を求めない。

## 履歴: 2026-08-18の実装・実機記録

以下は当時の観測の保存であり、現在の再検証結果ではない。

- branchは`codex/snapshot-sync-v2`、実装baselineは`71ee6e8a0`（`fix: accept lowercase auth response UUIDs`）。Swift／Rust canonical fixture、focused store/auth/application tests、およびApp hostの一時SQLite／fake transport／isolated defaults／test vault分離確認が成功した記録がある。
- 署名済みiOS appが`https://192.168.11.5:8443`へ到達し、端末でCaddy rootをtrustした後、challenge→Apple native authorization→exchangeを完了した。cold restartでもFUMINIWA sessionが復元した。
- lowercase wire UUIDをSwiftのuppercase `UUID.uuidString`と比較したfalse rejectionを`71ee6e8a0`で修正した。raw canonical-wire検査は維持した。
- 直前の修正は`c10a2b0fa`（stuck iOS sign-in retry）、`e07e1abef`（stale challenge lanes）、`dc7fee947`（Caddyの重複no-store header）、`50b81d0e0`（Apple認証phase診断）。
- 当時のCompose projectは`fuminiwa-sync-v2-role-split`、edgeは`fuminiwa-sync-v2-role-split-edge`。root SHA-256は`8E:1F:4F:B0:3C:ED:32:9F:34:4F:5B:E4:09:C3:F7:F0:B6:30:CE:21:D0:E6:04:4F:9F:E2:F3:89:F7:EC:43:EC`。trustはrotateし得るため現在値として再利用しない。
- 最新の標準`check.sh`試行はconformance／fixture段階後に、`IOSDocumentStore+AuthenticationV2.swift`の822行・新規800行超過で停止した。focused test合格を全通し合格に読み替えない。
- 利用者は既存作品・legacy dataの保全のために旧実装へ追加工数を割かず、製品UIを優先する意向を示した。旧データ削除自体はこの記録の作業では実施していない。必要になってもexact legacy-only対象を解決し、現行v2 DB・source・credential・既存未追跡backupは除外する。
- 当時はlocal／remote branchが文書commit前に一致し、既存`NovelApp 2026-07-16 23-51-50/`だけが未追跡だった。現在のbranchをこの記録に合わせて切り替えず、作業開始時のGit状態を確認する。

`project.yml`と`Scripts/generate-project.sh`がXcode構成の正。device ID、稼働image、server状態は検証時に取得する。
