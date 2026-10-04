# ふみにわ 現行設計

現行構成は`project.yml`と`NovelKit/Package.swift`で確認する。採択済みの方針は[DECISIONS](DECISIONS.md)、実装の残件は[CODE_HEALTH](CODE_HEALTH.md)に置く。

## 1. 目的

日本語の長編・中編小説を快適に書き、通信や認証の失敗でローカル編集を止めず、原稿を安全に保存・復元できること。macOSを先行し、iOS / iPadOSと共有の保存・同期機能を使う。Windowsは別実装の計画段階である。

通常作品の正本は端末内SQLite。同期はその確定済みSnapshotを複製する機能であり、保存の成立条件にしない。`.novelpkg`は明示的なImport / Exportの境界で、通常編集の作業ファイルに戻さない。

## 2. 開発方針

### 2.1 基本方針

- 原稿保全、IME、Undo、オフライン保存を製品の基本契約とする。
- macOS / iOSは共有v2 application・store・workerを使い、プラットフォーム側に表示・入力・ライフサイクルの差だけを置く。
- 作品はWorkID、選択は章・話のIDで扱う。path、表示名、現在の選択を非同期操作のidentityにしない。
- 設計とsourceに差があれば、差分と根拠を記録する。実装の存在だけで受入完了にせず、未実装の設計を既存機能として案内しない。

### 2.2 技術スタック

| 境界 | 現行 |
| --- | --- |
| macOS 14以上 | SwiftUI shell + AppKit `NSTextView` / TextKit 2 |
| iOS / iPadOS 17以上 | SwiftUIの適応navigation + UIKit `UITextView` / TextKit 2 |
| Apple共有実装 | Swift 6、ローカルSwift Package `NovelKit` |
| 端末内保存 | v2 SQLite、`CSQLite`。初版objectはDB内BLOB |
| サーバー | `SyncServerV2`のRust / PostgreSQL。初版objectはBYTEA |
| 認証 | Sign in with Apple、FUMINIWA session。Auth wire v1 / Sync epoch 2 |
| 作品受け渡し | `.novelpkg` v3読込 / v3書出 |
| 原稿出力 | TXT / Markdown / EPUB 3 |
| Windows | Windows 11のみ。WinUI 3 + C# / .NET、MSIなどのインストーラー配布を計画。W0未完了 |

現在の保存実装はCSQLiteとPostgreSQL BYTEA。サーバーはserver-readableで、E2EEではない（D-078 / D-080）。macOSは非Sandboxの直接配布方針（D-011）で、今回の協力者向け受け渡しは公証済みDMGとする（D-099）。配布・公開の受入は別途必要である。

## 3. モジュール構成

通常targetの構成は[project.yml](../project.yml)、Swiftの依存関係は[Package.swift](../NovelKit/Package.swift)が具体的な確認先である。

| 場所 | 責務 |
| --- | --- |
| `NovelApp/` | macOSの作品状態、Workbench、入力・OS境界 |
| `NovelAppIOS/` | iPhone / iPadの作品棚、段階navigation、入力・OS境界 |
| `NovelKit/Sources/NovelCore/` | 文書・章・話・関連モデルと値型、依存ゼロ |
| `NovelTiming` | 端末内の起動時時間設定。Foundationのみ。保存・同期のデータには含めない |
| `NovelSyncV2` | canonical Snapshot・command・scope等の値と契約 |
| `NovelSyncV2Store` | SQLite transaction、Snapshot / objects、Outbox / Inbox、履歴・競合 |
| `NovelSyncV2Application` | ローカル操作、同期計画・worker、account transitionの共通窓口 |
| `NovelSyncV2Runtime` | 実store / HTTP / scope resolverのcomposition |
| `NovelSyncV2PortableBridge` | 検証済みpackageとv2作品の明示Import / Export変換 |
| `NovelAuth` / `NovelAuthApple` | session / HTTP認証とApple・Keychain境界 |
| `NovelWritingSupport` / `NovelWritingStore` | AI記録・範囲付き編集の値型と検証 / 本文と独立したSQLite・outbox・Undo journal |
| `NovelTextAnalysis` | 全話本文の検索・置換、人物の登場（Foundation / NovelCore） |
| `NovelStorage` / `NovelExport` | package codec / 配布用原稿の生成 |
| `EditorKit` / `NovelUI` / `PreviewSupport` | 本文エディタ / 共有UI / 固定previewデータ |
| `SyncServerV2/` | `/v2`同期、`auth_v1`認証、PostgreSQL、運用境界 |

## 4. 各モジュールの責務

### 4.1 NovelCore

`NovelDocument`、`Chapter`、`Episode`、人物・プロット・伏線・世界観等のモデルを持つ。章順は`NovelDocument.chapters`、話順は`Chapter.episodes`の配列順だけを正とし、`order`を重ねない。本文と話メモはEpisodeに属する（D-004 / D-028）。

他module、UI、SQLite、HTTPへ依存しない。`DocumentRepository`は明示portable転送の抽象。通常保存の直列化は両Appで共有する`NovelApp/DocumentLifecycle/V2DocumentSaveCoordinator.swift`が担当する。

### 4.2 NovelSyncV2Store / NovelStorage

v2 storeはcurrent state、immutable Snapshotとobjects、head / generation、account scope、durable remote workをatomic checkpointで確定する。networkをSQLite transactionに含めない。schema不整合や読込失敗では既存原稿を保持し、空の新規DBへのfallbackで成功に見せない。

`LocalSyncV2Store`だけを公開actorとし、内部の`OutboxRepository`（intent・command・receipt・upload・復旧）、`InboxRepository`（staging・attestation・adoption・shallow/backfill）、`ConflictRepository`（候補・keepBoth・restore）、`AccountRepository`（binding・scope遷移）、`DeletionRepository`（削除intentと順序付きpurge）、`WorkRepository`（work・snapshot・object・履歴・remote対応）へ委譲する。repositoryは同期的なstructで、同じ`SQLiteExecutor`を保持する。個別のactorやconnectionは作らない。

Storeがcheckpoint、install/adopt、publish acknowledgement、account transition、deletion等のtransactionを開始する。repositoryの`...Transaction` / `...InTransaction`と永続化helperはそのtransaction内で呼び、SQLの実行順序を保つ。executorはconnection・statement cache・query/exec/changes・transaction内のobject検証cacheを所有し、ネストは従来どおり拒否する。schemaの移行判断とSQL順序は`Schema.swift`、低水準のCSQLite操作は`SQLiteExecutor.swift` / `SQLiteExecutor+Schema.swift`に置く。

通常保存のscope解決は、同じStore actorが完全検証した現在版、または直前のautosaveでcommitした検証済み版に限り、既存本文・添付・portable resourceの全読込／再hash／全decodeを省く。cacheは本文コピーを持たず、WorkID・account scope・snapshot ID・世代・document anchor・SQLiteの`data_version`と`total_changes()`を照合する。作品openは必ず完全検証し、成功した安定読取は次のautosaveのstampを記録する。読込中の外部書込やcache記帳失敗はstampを捨てるだけで、完全読込に成功したopenを失敗へ変えない。cache missの完全検証も記録するため、resolverとStoreで同じ版を二度検証しない。

本文を変えないと監査したStore内部のoutbox／upload書込とleaf昇格は、書込前のstampが有効で、書込後もcurrent pointer・世代・scope・anchor・`data_version`が同じ時だけ`total_changes()`を更新して引き継ぐ。対象は[CODE_HEALTH](CODE_HEALTH.md#同期onでのcheckpoint-cache)に列挙する。object／snapshot／entries／parentsのimmutability triggerに加え、対象経路は既存entriesへの追加insertやresource変更もしない。未分類transaction、account／作品切替、import・remote install／adoption・復元、世代不一致、close／再open、rollbackは無効化する。別connectionのSQL変更も検知し、書込lock取得後に`data_version`を再確認する。取り込み時の完全検証と新規snapshotの全decode／検証は維持する。cache記帳失敗をCOMMIT後の保存失敗へ変えない。

NovelStorageはpackageの詳細を所有する。Importは外部原本を変えずnew WorkIDへ取り込み、Exportは既存のWorkID / session / binding / Undoを変えない。v2との接続は`NovelSyncV2PortableBridge`を使う。

manifestが参照する本文・世界観payloadは必須valid UTF-8。メモは欠損のみ省略可能で、存在するファイルの読込失敗を空文字にしない。未知resourceの保持、symlink、上限、ID / 参照整合を含む互換・検証条件は[CROSS_PLATFORM](CROSS_PLATFORM.md)に集約する。個別validationの存在はPackage Validator全体の受入を意味しない。


#### 同期の実行状態とplatform session

`NovelSyncV2Application.WorkLane`が作品別のworker・retry・promotion所有権、session、取込・backfill状態を持つ。UI stateはlaneの投影であり、retryや自動確認の入力には使わない。安全境界の期待generation/current snapshotはkernelから永続値を取得し、install時のSQLite CASで再確認する。

Applicationは`SyncV2RemoteReads`を通してremoteのcatalog/head/history/conflict/downloadを読み、local kernelを中継しない。`SyncV2LibraryProvider`はローカル棚の投影だけを担当する。RuntimeのHTTP clientには読取専用`SnapshotCache`を注入し、backfillの書込能力は別の`HistoryBackfillPersistence`へ分ける。pageとresume cursorの単一transaction確定はStoreが引き続き所有する。

Mac/iOSで共有する`NovelKit/Sources/NovelWorkspace/DocumentLifecycle/SyncSessionController.swift`は、WorkID/session/account/editGenerationを持つ`WorkspaceOperationContext`の照合、remote-only open・prefetch・reprojectionのtask所有権、認証のremote suspension leaseを担当する。platform側はIME確定→ローカル保存→installとdocument operation gateを維持する。Macの即時取消とiOSの終了待ち取消は明示policyで区別する。両safe-adoption gateはarm解除・token消費の意味が異なるため別実装を維持する（[R-05](SYNC_REVIEW.md)）。

ApplicationはWorkID付きUI stateとadoption可能イベントを通知する。作品別streamは最新state/adoption通知をcoalesceし、他作品の通知でその作品のwakeを失わない。両アプリのadoption待ちは30秒の明示deadlineで終了し、通知を受けてもsession/account・編集世代とIMEの確認を省略しない。iOS rootとmacOS Workbenchが継続購読を所有する。

### 4.3 EditorKit

編集中の本文はネイティブtext viewが所有する。SwiftUIから素朴な`Binding<String>`で往復させない。通常のモデル→本文installは話・作品の切替境界に限定し、remote結果や古いselectionを編集中の本文へ注入しない。

明示保存・同期で受領した作品・添付・portable metadataが表示中と同一なら、検証済みの同期sessionだけを更新し、本文を再installしない。カーソル、選択範囲、手動スクロール位置、Undo履歴を維持する。
校正の色付けがない保存では本文属性も変更しない。属性が存在しない範囲への削除もTextKit 2の再レイアウトを起こし得るため、色付け解除は校正結果を表示している場合だけ行う。

IME変換中はモデル反映もプラグイン介入もしない。変換確定を旧作品へ反映してから保存・遷移する。TextKit 2を使い、`layoutManager`へのアクセスによるTextKit 1へのfallbackを避ける。

macOSのカーソル補間はEditorKit内部の`AnimatedCaretTextView`が表示だけを担当する。`EditorConfiguration.animatesCaret`で切り替え、本文属性・選択・marked text・Undo・IME候補座標は変更しない。設定切替だけで本文属性を再適用しない。詳細と受入境界は[カーソル表示](CARET_ANIMATION_INVESTIGATION.md)。

### 4.4 Editor Plugin System

入力機能は純粋な`Rules/`と薄い`EditorPlugin`へ分ける。既定pipelineは`IMEGuardPlugin`→`IndentPlugin`。追加pluginはIME guardの後ろに置き、EditorViewやadapterに判定を積み増さない。

`EditorAction`は許可、後続を省略する許可、範囲置換を区別する。置換はadapterの正規編集経路を通し、Undo / Redo、selection、IME確定後通知までを実`NSTextView` / `UITextView`の統合テストで確認する。APIの正確な型は[EditorPlugin.swift](../NovelKit/Sources/EditorKit/Core/EditorPlugin.swift)を参照する。

### 4.5 IndentRules

`String`とUTF-16の`NSRange`を使う純関数。範囲変換は`Range(_:in:)` / `NSRange(_:in:)`を使う。

- **R1'**: キャレットで単一改行を入力すると、新しい行を全角スペース1つで開始する。
- **R3**: 全角スペースだけの行末に鉤括弧を入れると字下げを置き換える。対応する空の括弧ペアは一括入力・開閉別入力ともキャレットを内部へ置く。
- **R4**: IME変換中は介入しない。
- **R5**: IME確定後の対象鉤括弧・キャレット条件に限り、全角字下げをUndo可能な編集で取り除き、空ペアのキャレットを内部へ置く。

対象外の選択置換・複数行pasteを一般化して書き換えない。細かな受入例は[IndentRules](../NovelKit/Sources/EditorKit/Rules/IndentRules.swift)と[対応テスト](../NovelKit/Tests/EditorKitTests/IndentRulesTests.swift)に置く。

### 4.6 NovelUI

共有SwiftUI部品の層。保存・同期・account状態の新しい所有者にしない。見た目と文言の契約は[STYLE](STYLE.md)を使う。

### 4.7 PreviewSupport

固定データでpreviewを構成する。productionのDB、network、credentialをpreviewへ接続しない。

### 4.8 NovelExport

不変の`NovelDocument`からTXT / Markdown / EPUB 3を生成する。NovelCoreだけに依存し、package内部を読まない。共通の作品→章→話展開を通し、同じ親の一時ファイルを完成させてからatomicに書き出す。`.novelpkg` Exportはこのrendererと別のportable bridgeを使う。

### 4.9 AI支援

原稿コピーはD-094のplain text。校正・感想はD-089のpreview後に明示送信し、アドバイスはD-098の会話と依頼単位の編集を使う。共有`WritingAssistant`はHTTP・設定・Keychain・表示、`NovelWritingSupport`は機械的な範囲検査、`NovelWritingStore`は独立した記録・同期待ち・Undoを担当する。Mac/iOS adapterがEditorKitとローカルcheckpointへ接続し、MCPも同じ編集窓口を通る。[WRITING_ASSISTANT](WRITING_ASSISTANT.md)参照。

### 4.10 作品棚

通常Appはv2 applicationのlocal shelfとaccount-scoped remote catalogを使う。local workはネットワークを待たずに開き、remote-only workの初回取得は対象accountを検証して行う。`NovelLibrary`の旧registryをv2の正本へ戻さない。

### 4.11 Snapshot Sync v2

同期・競合・履歴の単位は作品。sealed commandは送信前に永続化し、再試行は同一操作として行う。受信内容はInboxへ保存・検証してから、session / generation / IME / dirty状態を確認した安全な境界で採用する。

競合は作品ごとにactive 1件、「この端末」「サーバー」「両方」の3択。自動で勝者を選ばない。復元は事前checkpointを残し、新しいSnapshotとして記録する。no-op同期・変更のない保存は成功状態である。

account / fence変更をまたぐACK、catalog、history、worker完了を新scopeへ適用しない。既存unbound workをログイン後のaccountへ自動送信しない。厳密なwire・状態機械・SQL・fixtureは[SNAPSHOT_SYNC_V2](SNAPSHOT_SYNC_V2.md)、[v2契約](sync/v2/README.md)、D-080〜D-085を参照する。

## 5. App側の設計

### 5.1 AppDependencies

macOSの[AppDependencies](../NovelApp/Application/AppDependencies.swift)と各Appのcomposition rootが具体実装を組み立てる。通常appとapp-hosted testは`FUMINIWA_TEST_COMPOSITION`で分離する。v2の物理modeはproduction / test / previewであり、testへproduction root・URL・vaultを渡さない。

### 5.2 WorkspaceModelとApp adapter

`NovelWorkspace.WorkspaceModel`は`@MainActor @Observable`の共通状態を持つ。document、章／話選択、WorkspaceSessionToken、account scope／generation、添付setと表示一覧、保存状態、SyncUIState／競合、棚の同期行・catalog・loading／取り込み状態、keep-bothのwrite freeze、AssistantRequestCenterを両OSで共有する。AppState／IOSDocumentStoreはそれぞれ一つのmodelを所有し、既存名のcomputed forwarderはmodelのObservationを読む。モデル自体は保存・通信を開始しない。

`AppState`／`IOSDocumentStore`はmodelと共通coordinator／commandへの薄いadapterである。`ProjectFeatureCommands`、`WorkspaceAttachmentCommands`、`WritingAssistantHostFactory`／`WorkReplacementHostFactory`、`LibraryCoordinator`、`CheckpointCoordinator`／`V2DocumentSaveCoordinator`、`WorkOpenCoordinator`、`AdoptionCoordinator`、`ConflictCoordinator`、`OutlineCommands`／`EpisodeTransition`、`ManuscriptCopyCommand`、`AccountTransitionCoordinator`へ機能処理を委譲し、`SyncSessionController`が非同期taskの所有権を持つ。共有SwiftUIはNovelWorkspaceUIに置く。[D-111](DECISIONS.md#d-111-共通app層の段階移設2026-10-04)。

startup、終了・window／toolbar・MCP、iOSのscene／background・navigation departure・private working copy、IMEとdocument gate、provider／Keychain／HTTP compositionはAppに残す。Macの機能選択・棚の起動画面用表示identity／availabilityと、iOSの画面内機能選択は寿命・型が異なるため共有状態にしない。OS別の保存policy・通知・gateの意味差をこの整理で変えない。

app側identityは`WorkspaceSessionToken`（generation／workID／install済みdocumentID）と`WorkspaceAccountScope`（accountID／fence／serverInstanceID／protocolEpoch／generation）を共有する。account無効化ごとにmodelのgenerationを進め、全fieldで古いcompletionを拒否する。iOSのcurrent sessionはstartup eligibilityを確認してからmodelのpayload／active WorkIDで投影し、Macのinstall済みtokenは従来の更新境界を維持する。gate固有の`NovelSyncV2Application.DocumentSessionToken`は別型のまま保つ。

### 5.3 ContentView

macOSは[ContentView](../NovelApp/Application/ContentView.swift)から作品選択・recovery・既存Workbenchへ分岐する。ready以外で編集可能なWorkbenchを作らない。iOSは作品棚→作品ホーム→機能画面の階層と、iPadの複数列を使う。

現在のiOSには主要routeがあるが、各導線の実機確認が残る。原稿コピーはD-094で選択／話／章のplain textへ更新した。[IOS](IOS.md)が現況と受入条件を整理する。

## 6. 製品要件

### 6.1 作品管理

新規・Import・棚からの選択・Exportを提供する。読込不能を新規作品へ見せかけず、current documentと原本を保持する。外部原本のopen-in-placeは対象外。

### 6.2 章／話管理

章・話の作成、選択、並べ替え、削除はIDと配列順を守る。遷移前に旧本文・フォームを確定する。表示時の確認対象を後から現在選択へ読み替えない。

### 6.3 本文編集

本文、話メモ、話内検索、字下げ・鉤括弧補助を提供する。IME、選択、執筆位置、Undo / Redoを維持する。UIの復元でもEditorKitの所有権を迂回しない。

### 6.4 保存

現在の両Appは`V2DocumentSaveCoordinator`からv2 checkpointへ委譲する。`Cmd+S`・自動保存・遷移前保存を同じ直列化境界へ集める。document operation gateの内側で保存を待つが、network完了は待たない。gate付きpublic APIを相互に呼んで再入待ちにしない。

通常のautosaveは入力停止2秒のdebounceで一回分だけ保存する。保存中に新しいrevisionが届いた場合は、その入力のdebounceを待つ。timerが保存中に満了した場合は再予約する。`saveNow`とexclusive flushは最新revisionまで直ちにdrainし、IME確定、話／作品切替、終了、background、明示保存／同期・スナップショット保存の境界を保つ。途中のrevisionだけ保存された時はdirty表示を保ち、未保存分があるのにsavedとは通知しない。

保存・promotion・更新確認・送信retry・AI記録同期・進み具合の公開間隔は`NovelTiming.FuminiwaTiming`に集約し、両OSのhost生成時にアプリ側の`FuminiwaTiming+Defaults`でUserDefaultsから読み込み、NovelKitのruntime／schedulerへ値を注入する。NovelKitの時間設定型はUserDefaultsを読まない。変更はアプリ再起動後に反映する。以下のキーはすべて`fuminiwa.timing.`を先頭に付ける。単位は秒。数値は範囲内へclampし、非数値・bool・NaN・無限大は既定値に戻す。retry maximumはinitial以上、promotion maximumはidle以上にする。

| キーの末尾 | 既定値 | 範囲 |
| --- | ---: | ---: |
| `autosaveDebounceSeconds` | 2 | 0.25〜60 |
| `autosavePostSaveWaitSeconds` | 2 | 0.25〜60 |
| `writingSyncVisibleSeconds` | 10 | 1〜600 |
| `writingSyncHiddenSeconds` | 300 | 5〜3600 |
| `writingSyncRetryInitialSeconds` | 20 | 1〜600 |
| `writingSyncRetryMaximumSeconds` | 600 | 1〜3600（initial以上） |
| `progressPublishSeconds` | 3 | 0.1〜60 |
| `promotionIdleSeconds` | 60 | 1〜600 |
| `promotionMaximumSeconds` | 300 | 1〜3600（idle以上） |
| `headPollNormalSeconds` | 10 | 1〜600 |
| `headPollTypingSeconds` | 120 | 1〜3600 |
| `headPollFailureSeconds` | 60 | 1〜3600 |
| `headPollTypingWindowSeconds` | 60 | 1〜600 |
| `sendRetryInitialSeconds` | 2 | 0.25〜60 |
| `sendRetryMaximumSeconds` | 60 | 0.25〜600（initial以上） |

`autosavePostSaveWaitSeconds`は保存・exclusive操作中にtimerが満了して再予約する待機と、保存完了時に未保存revisionが残りtimerがない場合の待機に使う。入力が予約したtimerは通常のdebounceを使う。即時flushには適用しない。AI記録はinitialから倍増してmaximumで止め、成功でリセットする。進み具合の値はUI公開の間隔で、別DBへの永続化retry間隔ではない。

macOSではアプリを終了し、たとえば`defaults write dev.serikayuzuki.fuminiwa fuminiwa.timing.autosaveDebounceSeconds -float 4`を実行して再起動する。戻す時は`defaults delete dev.serikayuzuki.fuminiwa fuminiwa.timing.autosaveDebounceSeconds`。iOS開発ビルドはXcode SchemeのRun → Arguments Passed On Launchに`-fuminiwa.timing.autosaveDebounceSeconds`と`4`を追加して起動する（NSArgumentDomainの上書き）。外すと端末の保存値／既定値へ戻る。設定UIは追加しない。

前面で開いている作品の更新確認は、最後の本文編集から60秒未満なら120秒間隔、それ以外は10秒間隔、失敗後は60秒間隔にする。待機中も注入時計で入力状態を再判定する。前面復帰と章・話・作品の遷移完了は即時確認を起動するが、遷移は通信を待たない。本文編集以外のメタデータ変更は入力中の期限を延ばさない。promotion／uploadと競合処理は既存の経路を保つ。送信retryはinitialから倍増し、既存の0.75〜1.25倍のjitterを掛け、maximumで止める。

遷移の最終保存からinstallまでWorkbench全体の変更を止め、終了要求後は新しい作品操作を受け付けない（D-041）。

保存失敗時はdirty状態と旧作品を保持し、保存済みと表示しない。保存成功はSQLiteへの耐久化を表し、remote read-backの成功と分ける。

### 6.5 世界観・執筆補助

人物、プロット・伏線、世界観、資料を同じ作品とsessionに属する機能として扱う。世界観本文にもEditorKitの入力契約を適用する。portable resourceはlocal SQLiteで保全し、online対象との違いはv2 entity契約とCROSS_PLATFORMに従う。

### 6.6 認証とアカウントライフサイクル

Appleログイン、削除予約・取消API、720時間後の削除workerは実装済み。自宅サーバーで日次暗号化backupを1暦年保持する。予約・取消のアプリ画面と別機器への退避は未対応。通常の再認証・session復旧と独自のアカウント回復サービスは区別する。[AUTH](AUTH.md)と[運用](ACCOUNT_RETENTION_OPERATIONS.md)を参照。

### 6.7 執筆の進み具合（端末内）

`NovelWritingProgress`は日別加筆量・純増、継続、目標、区切りの到達を両Appで共有する。加筆量は手入力の本文変更ごとの`max(0, 新字数−旧字数)`の合計、純増は差分の合計。字数は改行を除く既存`ManuscriptMetrics`規則。既存guardを通ったmacOS／iOSの`updateEpisodeContent`だけが計上し、EditorKit内のhookは追加しない。通常Undo／Redoもこの入口を通り、Redoは再加算する。

AI／MCP編集とそのUndo、open／import／remote install／復元、話の追加・削除・移動は計上しない。AIのネイティブ置換から同期的に届くonTextChangeも、App側の呼出区間で集計だけを抑止し、モデル反映・保存は維持する。全体字数の既存超過は日付なしの「以前に到達」とし、手入力で下から跨いだ区切りだけを一度通知する。標準の1万・3万・5万・10万・15万・20万、以後10万ごとと目標値を区切りにする。

集計キーはpayloadのdocument IDではなく作品WorkIDと端末のローカル暦日（0:00区切り）。直前の話別字数を保持し、通常は変更話の新字数だけを数える。本文差し替え時はinstall／synchronizeで更新し、手入力時にキャッシュ本文との不一致を見つけた場合も文書全体の字数を再同期してから差分を計上する。日別値と到達記録はruntimeと同じlocal rootの独立WAL `writing-progress.sqlite`（user_version=1）、目標・任意の締切は`fuminiwa.progress.goal.<workID>`のUserDefaults JSONへ保存する。初回履歴読込は独立Taskで開始し、起動・本文保存・document transitionは完了を待たない。集計flushだけが履歴読込の完了を待ち、読込中の加筆を一度だけ併合する。手入力中は集計を非観測の内部状態へ積み、UIのrecords／totalは約3秒ごと、保存・install・画面表示時にまとめて公開する。同じ公開値は再代入しない。手入力後のdirty通知では全話synchronizeを重複実行せず、AI等の非手入力通知とキャッシュ不一致時には全体再同期を保つ。未計上値がない保存ではflush Taskを作らない。SQLiteは別actorで3秒ごと／保存時にまとめて書き、macOS終了・iOS backgroundでもflushする。失敗はメモリ保持と指数バックオフ（3秒から失敗ごとに倍増、最大180秒）へ閉じ込め、unsupportedVersionでは再試行を停止する。失敗中もUI集計の公開は約3秒以内を保ち、本文保存の成功条件や待機条件にしない。端末外への同期・package出力は行わず、v2 schema／wire／fixtureを増やさない。

継続は書いた日数を数え、完了した未執筆日が2日続くと途切れる。今日の未執筆では途切れず、1日休みは継続する。締切までの日数は今日を含め、必要日量は残り字数を日数で割って切り上げる。

### 6.9 作品全体の検索・置換と人物の登場

検索は章・話の配列順に全話本文だけを対象とし、話名・メモ・人物設定は含めない。FoundationのcaseInsensitiveによるプレーン文字列一致とUTF-16範囲はEditorKit.TextSearchと同じ。前後20書記素の文脈を示す。検索・登場検出は表示中の250ms debounce後にバックグラウンドで計算する。覆われた画面／onDisappear後は計算を止め、結果を保持して古くなった印だけを付け、再表示時に一回更新する。表示中の検索も本文変更では再検索せず、古くなった表示と「再検索」で更新する。query変更は表示中だけ再検索する。古い検索結果での置換操作は無効にし、ジャンプは従来の本文一致判定を通す。session/account変更では古いscopeを拒否する。

置換は一致ごとの除外（既定は全件）と件数確認を経て、document gate内でIME確定→端末保存→明示checkpoint（explicit）→適用→端末保存と進む。明示履歴に保存できなければ本文を変更しない。検索時から対象話の本文が一つでも変わっていたら全体を中止し、再検索を促す。適用前後のWorkID/session/accountを固定し、本文一致はUTF-8 bytesで確認する。置換結果の計算もバックグラウンドで行う。

開いている話はEditorCommandSession.applyProofreadingを通す一回のネイティブ編集としてUndoを保つ。入力停止は明示checkpoint完了まで維持し、同期的な適用区間だけ再開して直後に停止し、全対象話を一回の文書変更として保存する。AI編集のjournal・記録laneへは書かず、withUncountedEditorChangeとdirty時のsynchronizeで進み具合の手入力集計から除外する。

直前の置換一回を戻す一時操作は、置換後の本文と一致する話だけを一回の変更・保存で戻す。後から編集された話は保持し、置換前の履歴からの復元を案内する。作品/session/account切替やアプリ終了をまたいで保持しない。保存失敗では変更本文とdirty状態を保持し、再保存を案内する。

人物の登場は名前と読みを同じ照合規則で検索し、話ごとの回数・最初／最後の話を表示する。重なる名前／読みは一回と数える。既存の名前・読みの照合語は維持し、ジャンプは名前優先から本文内で最初の一致へ変更する（最初の登場位置を選択するため）。人物名の変更は本文へ自動反映せず、人物詳細menuの「本文の名前を置換…」で検索語を入力した検索画面を開く。モデル・同期schemaは追加しない。


## 7. 未実装・将来の機能

人物関係グラフ、時系列ビュー、PDF出力、追加provider SDK、Windows実装は現在の利用可能機能に含めない。追加時に目的と受入条件を定める。UIに未実装placeholderを置いて完成に見せない（D-040）。

## 8. 実装ルール

### 8.1 依存方向

NovelCoreは依存ゼロ。NovelStorage / NovelExport / EditorKit / NovelUI / NovelSyncV2はNovelCoreへ向く。v2 store / application / runtime / portable bridgeは[Package.swift](../NovelKit/Package.swift)の明示依存を使う。全moduleを「Coreだけに依存」と一括表現しない。

### 8.2 プラットフォーム依存

EditorKitのAppKit / UIKit処理は`Platform/`内に閉じ込める。公開Editor APIにはネイティブtext viewを出さない。AppのSwiftUI・OS adapterに必要なplatform依存とは区別する。platform UI型やcredentialをcanonical Snapshot・portable schemaへ出さない。

### 8.3 保存形式

packageはNovelStorageの抽象APIを介し、v2はWorkIDベースのapplication APIを介する。OS path、bookmark、handle、UI設定、account / session、provider promptをpackageに足さない。互換変更はCROSS_PLATFORMとschema / golden fixtureを同時更新する。

### 8.4 Editor拡張

4.3〜4.5の入力・所有権契約を守る。純粋判定はRules、正規編集とIME通知はplatform adapterに置く。新機能がUndoを壊さないことを受入条件に含める。

### 8.5 クロスプラットフォーム実装

Apple間はSwiftの共通moduleを使う。Windowsとはschema、fixture、ドメインの意味、Export仕様を共有する。WinUIをSwiftUIのview階層へ機械的に合わせない。Windows実装後は双方向round-tripを互換変更の完了条件にする（D-036）。

### 8.6 AI統合

AIのHTTP・Keychainは共有WritingAssistant内に置き、本文保存やEditorKitから分離する。明示送信と反映条件は[WRITING_ASSISTANT](WRITING_ASSISTANT.md)、通信しないコピーは[CLIPBOARD_AI_ASSIST](CLIPBOARD_AI_ASSIST.md)に従う。

## 9. 非目標

- 縦書き（執筆・出力ともD-012で対象外）、高度な組版、独自描画エンジン。
- リアルタイム共同編集、本文の自動3-way merge、時刻による競合winnerの自動選択。
- 外部原本のopen-in-place、SQLite DB自体のonline共有、旧CloudKit/v1へのfallback。
- ログイン後の既存unbound作品の自動adopt、別AccountIDへのWorkIDの付け替え。
- 明示送信なしのAI送信、依頼で許可した範囲外の書換え。

## macOSの作品一覧と画面遷移

`workbench`の単一Window sceneで、Loading／作品選択時は全幅の`LibraryView`、Ready時はWorkbench、Recovery時は復旧表示を使う。作品一覧へ戻る操作は`returnToSnapshotLibrary()`のIME確定・local checkpoint境界を通り、windowを閉じたり作り直したりしない。起動設定、外部package open、終了処理は既存のAppState／ApplicationDelegateが所有する。
