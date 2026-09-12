# ふみにわ 現行設計

2026-09-12更新。文書改訂前のsource `32e60bdf6`、`project.yml`、`NovelKit/Package.swift`を照合した。設計の決定理由は[DECISIONS](DECISIONS.md)、実装の残件は[CODE_HEALTH](CODE_HEALTH.md)、同期の受入状況は[v2引き継ぎ](SNAPSHOT_SYNC_V2_HANDOFF.md)に置く。

旧v0.94の全文・変更履歴は[改訂前の設計書](archive/2026-09-12-DESIGN.md)に保存した。本書では現行契約と実装箇所を案内し、未完了の受入を区別する。章番号はsourceコメントの参照を維持するため残す。

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

現在のv2にGRDBやS3への依存はない。以前の計画に出てくるそれらを導入済みと扱わない。サーバーはserver-readableで、E2EEではない（D-078 / D-080）。macOSはGitHub Releasesによる直接配布・非Sandbox方針（D-011）。配布・公開の受入は別途必要である。

## 3. モジュール構成

通常targetの構成は[project.yml](../project.yml)、Swiftの依存関係は[Package.swift](../NovelKit/Package.swift)が具体的な確認先である。

| 場所 | 責務 |
| --- | --- |
| `NovelApp/` | macOSの作品状態、Workbench、入力・OS境界 |
| `NovelAppIOS/` | iPhone / iPadの作品棚、段階navigation、入力・OS境界 |
| `NovelKit/Sources/NovelCore/` | 文書・章・話・関連モデルと値型、依存ゼロ |
| `NovelSyncV2` | canonical Snapshot・command・scope等の値と契約 |
| `NovelSyncV2Store` | SQLite transaction、Snapshot / objects、Outbox / Inbox、履歴・競合 |
| `NovelSyncV2Application` | ローカル操作、同期計画・worker、account transitionの共通窓口 |
| `NovelSyncV2Runtime` | 実store / HTTP / scope resolverのcomposition |
| `NovelSyncV2PortableBridge` | 検証済みpackageとv2作品の明示Import / Export変換 |
| `NovelAuth` / `NovelAuthApple` | session / HTTP認証とApple・Keychain境界 |
| `NovelStorage` / `NovelExport` | package codec / 配布用原稿の生成 |
| `EditorKit` / `NovelUI` / `PreviewSupport` | 本文エディタ / 共有UI / 固定previewデータ |
| `SyncServerV2/` | `/v2`同期、`auth_v1`認証、PostgreSQL、運用境界 |

旧同期・旧Library・旧serverと除外画面はD-090で削除した。履歴はGitと凍結文書で参照する。

## 4. 各モジュールの責務

### 4.1 NovelCore

`NovelDocument`、`Chapter`、`Episode`、人物・プロット・伏線・世界観等のモデルを持つ。章順は`NovelDocument.chapters`、話順は`Chapter.episodes`の配列順だけを正とし、`order`を重ねない。本文と話メモはEpisodeに属する（D-004 / D-028）。

他module、UI、SQLite、HTTPへ依存しない。`DocumentRepository`は明示portable転送の抽象。通常保存の直列化は両Appで共有する`NovelApp/DocumentLifecycle/V2DocumentSaveCoordinator.swift`が担当する。

### 4.2 NovelSyncV2Store / NovelStorage

v2 storeはcurrent state、immutable Snapshotとobjects、head / generation、account scope、durable remote workをatomic checkpointで確定する。networkをSQLite transactionに含めない。schema不整合や読込失敗では既存原稿を保持し、空の新規DBへのfallbackで成功に見せない。

NovelStorageはpackageの詳細を所有する。Importは外部原本を変えずnew WorkIDへ取り込み、Exportは既存のWorkID / session / binding / Undoを変えない。v2との接続は`NovelSyncV2PortableBridge`を使う。

manifestが参照する本文・世界観payloadは必須valid UTF-8。メモは欠損のみ省略可能で、存在するファイルの読込失敗を空文字にしない。未知resourceの保持、symlink、上限、ID / 参照整合を含む互換・検証条件は[CROSS_PLATFORM](CROSS_PLATFORM.md)に集約する。個別validationの存在はPackage Validator全体の受入を意味しない。

### 4.3 EditorKit

編集中の本文はネイティブtext viewが所有する。SwiftUIから素朴な`Binding<String>`で往復させない。通常のモデル→本文installは話・作品の切替境界に限定し、remote結果や古いselectionを編集中の本文へ注入しない。

IME変換中はモデル反映もプラグイン介入もしない。変換確定を旧作品へ反映してから保存・遷移する。TextKit 2を使い、`layoutManager`へのアクセスによるTextKit 1へのfallbackを避ける。

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

明示scopeのclipboard promptを維持し、D-089に基づき現在の1話のpreview後にOpenAI対応APIへ送信できる。共有の`NovelApp/WritingAssistant/`は文字列payload・設定・Keychain・HTTP・表示を担当し、EditorKitや同期moduleには依存しない。原稿の自動編集はしない。[WRITING_ASSISTANT](WRITING_ASSISTANT.md)参照。

### 4.10 作品棚

通常Appはv2 applicationのlocal shelfとaccount-scoped remote catalogを使う。local workはネットワークを待たずに開き、remote-only workの初回取得は対象accountを検証して行う。`NovelLibrary`の旧registryをv2の正本へ戻さない。

### 4.11 Snapshot Sync v2

同期・競合・履歴の単位は作品。sealed commandは送信前に永続化し、再試行は同一操作として行う。受信内容はInboxへ保存・検証してから、session / generation / IME / dirty状態を確認した安全な境界で採用する。

競合は作品ごとにactive 1件、「この端末」「サーバー」「両方」の3択。自動で勝者を選ばない。復元は事前checkpointを残し、新しいSnapshotとして記録する。no-op同期・変更のない保存は成功状態である。

account / fence変更をまたぐACK、catalog、history、worker完了を新scopeへ適用しない。既存unbound workをログイン後のaccountへ自動送信しない。厳密なwire・状態機械・SQL・fixtureは[SNAPSHOT_SYNC_V2](SNAPSHOT_SYNC_V2.md)、[v2契約](sync/v2/README.md)、D-080〜D-085を参照する。

### 4.12 旧CloudKit経路

現行adapter・entitlementでは使わない。比較記録は[DEVICE_SYNC](DEVICE_SYNC.md)に残す。現在の同期修正はv2へ行う。

## 5. App側の設計

### 5.1 AppDependencies

macOSの[AppDependencies](../NovelApp/Application/AppDependencies.swift)と各Appのcomposition rootが具体実装を組み立てる。通常appとapp-hosted testは`FUMINIWA_TEST_COMPOSITION`で分離する。v2の物理modeはproduction / test / previewであり、testへproduction root・URL・vaultを渡さない。

### 5.2 AppState

macOSは`NovelApp/AppState.swift`、iOSは`NovelAppIOS/DocumentLifecycle/IOSDocumentStore.swift`が画面の状態を持つ。機能処理は既存の責務別extensionに置く。作品操作と非同期確認は呼出時のsession / WorkID / account scopeを保持し、完了時に検査する。

### 5.3 ContentView

macOSは[ContentView](../NovelApp/Application/ContentView.swift)から作品選択・recovery・既存Workbenchへ分岐する。ready以外で編集可能なWorkbenchを作らない。iOSは作品棚→作品ホーム→機能画面の階層と、iPadの複数列を使う。

現在のiOSには主要routeがあるが、旧操作バー・promptコピー等の導線復元と実機確認が残る。[IOS](IOS.md)が現況と受入条件を整理する。過去のUI完了文書は製品意図を調べる資料であり、v2での完了証拠にはしない。

## 6. 製品要件

### 6.1 作品管理

新規・Import・棚からの選択・Exportを提供する。読込不能を新規作品へ見せかけず、current documentと原本を保持する。外部原本のopen-in-placeは対象外。

### 6.2 章／話管理

章・話の作成、選択、並べ替え、削除はIDと配列順を守る。遷移前に旧本文・フォームを確定する。表示時の確認対象を後から現在選択へ読み替えない。

### 6.3 本文編集

本文、話メモ、話内検索、字下げ・鉤括弧補助を提供する。IME、選択、執筆位置、Undo / Redoを維持する。UIの復元でもEditorKitの所有権を迂回しない。

### 6.4 保存

現在の両Appは`V2DocumentSaveCoordinator`からv2 checkpointへ委譲する。`Cmd+S`・自動保存・遷移前保存を同じ直列化境界へ集める。document operation gateの内側で保存を待つが、network完了は待たない。gate付きpublic APIを相互に呼んで再入待ちにしない。

遷移の最終保存からinstallまでWorkbench全体の変更を止め、終了要求後は新しい作品操作を受け付けない（D-041）。

保存失敗時はdirty状態と旧作品を保持し、保存済みと表示しない。保存成功はSQLiteへの耐久化を表し、remote read-backの成功と分ける。

### 6.5 世界観・執筆補助

人物、プロット・伏線、世界観、資料を同じ作品とsessionに属する機能として扱う。世界観本文にもEditorKitの入力契約を適用する。portable resourceはlocal SQLiteで保全し、online対象との違いはv2 entity契約とCROSS_PLATFORMに従う。

### 6.6 認証とアカウントライフサイクル

D-087のaccount lifecycleは方針採択・実装前。Appleログイン以外の独自回復を提供せず、削除の取消猶予は30日、backup保持は1年とする。通常の再認証・session復旧・端末内原稿保全とは区別し、詳細は[AUTH](AUTH.md)へ集約する。

## 7. 未実装・将来の機能

作品全体検索・置換、人物関係グラフ、時系列ビュー、PDF出力、provider統合、Windows実装は現在の利用可能機能に含めない。追加時に目的と受入条件を定める。UIに未実装placeholderを置いて完成に見せない（D-040）。

## 8. 開発ロードマップ

過去のPhase番号は実装経緯を示す。現在はv2上の製品機能、ローカル保存、account境界、二端末同期を安定させる段階である。順序と証拠は[v2引き継ぎ](SNAPSHOT_SYNC_V2_HANDOFF.md)に集約し、旧R0〜R8計画を新規着手一覧として再実行しない。

## 9. 実装ルール

### 9.1 依存方向

NovelCoreは依存ゼロ。NovelStorage / NovelExport / EditorKit / NovelUI / NovelSyncV2はNovelCoreへ向く。v2 store / application / runtime / portable bridgeは[Package.swift](../NovelKit/Package.swift)の明示依存を使う。全moduleを「Coreだけに依存」と一括表現しない。

### 9.2 プラットフォーム依存

EditorKitのAppKit / UIKit処理は`Platform/`内に閉じ込める。公開Editor APIにはネイティブtext viewを出さない。AppのSwiftUI・OS adapterに必要なplatform依存とは区別する。platform UI型やcredentialをcanonical Snapshot・portable schemaへ出さない。

### 9.3 保存形式

packageはNovelStorageの抽象APIを介し、v2はWorkIDベースのapplication APIを介する。OS path、bookmark、handle、UI設定、account / session、provider promptをpackageに足さない。互換変更はCROSS_PLATFORMとschema / golden fixtureを同時更新する。

### 9.4 Editor拡張

4.3〜4.5の入力・所有権契約を守る。純粋判定はRules、正規編集とIME通知はplatform adapterに置く。新機能がUndoを壊さないことを受入条件に含める。

### 9.5 クロスプラットフォーム実装

Apple間はSwiftの共通moduleを使う。Windowsとはschema、fixture、ドメインの意味、Export仕様を共有する。WinUIをSwiftUIのview階層へ機械的に合わせない。Windows実装後は双方向round-tripを互換変更の完了条件にする（D-036）。

### 9.6 AI統合

現在のscope・コピー・プライバシー境界はCLIPBOARD_AI_ASSISTへ集約する。通常版にprovider/networkを混ぜない。将来の統合でも本文所有権、明示scope、local identityを送らない条件を維持する（D-043 / D-075）。

## 10. AIエージェント向けの作業単位

依頼の成果と制約を先に把握し、必要な境界だけ読む。関連するモデル・実装・テスト・文書を一つの目的のために更新し、無関係な機能やリファクタリングを混ぜない。手順の細分化や毎回の全資料通読は要求しない。

依頼範囲の編集と、D-086で選択した段階の検証まで進める。検証なしも選択肢とし、マージ前の一律全通しを要求しない。設計変更が必要なときはDECISIONSへ追加し、既存の採択理由を消さずに置換範囲を示す。利用者の決定と残る実装事項は[OWNER_DECISIONS](OWNER_DECISIONS.md)へ置く。

## 11. 直近の次タスク

[v2引き継ぎ](SNAPSHOT_SYNC_V2_HANDOFF.md)の現況を確認し、iOSの未接続UI、認証済み新規作品のlocal-only報告、D-076構造Gateの失敗を扱う。主要routeやaccount bindingのコードは存在するため、「全体が未実装」と決めつけず、残る失敗を再現して直す。

その後、Mac / iPhone間の往復、offline分岐、競合3択、履歴復元、再起動、account切替を確認する。Package Validator / Windows W0 / 公開認証運用 / 配布技術のGateは別に残り、コード・fixtureの成功だけで一般公開を宣言しない。

## 12. 非目標

- 縦書き（執筆・出力ともD-012で対象外）、高度な組版、独自描画エンジン。
- リアルタイム共同編集、本文の自動3-way merge、時刻による競合winnerの自動選択。
- 外部原本のopen-in-place、SQLite DB自体のonline共有、旧CloudKit/v1へのfallback。
- ログイン後の既存unbound作品の自動adopt、別AccountIDへのWorkIDの付け替え。
- 通常版からのAI送信・自動本文書換え。価格・法務・販促の追加は明示依頼の範囲のみ（D-042）。

## 変更履歴

- **2026-09-12**: D-080〜D-085と現行target構成に合わせ全面整理。v1 / CloudKit / GRDB / S3を現行扱いしていた説明を修正し、過去の全変更履歴をarchiveへ保全。製品・wire・保存契約の新規採択は行っていない。
- **2026-09-12 追記**: 利用者決定D-086〜D-088を反映。検証を4段階へ変更し、独自account回復なし・削除猶予30日・backup1年・Windows 11／インストーラー配布を採択。今回の追記は検証なし。
