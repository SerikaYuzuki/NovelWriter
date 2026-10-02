# 現行実装と未完了事項

文書更新時にソースを照合した状態。稼働環境・実機の受入結果は別に扱い、過去のテスト結果をここへ積み上げない。

## 実装の入口

| 責務 | 場所 |
| --- | --- |
| ビルド・依存 | `project.yml`、`NovelKit/Package.swift` |
| macOS・iOS画面 | `NovelApp/Application/`、`NovelAppIOS/Library/`、各`Features/` |
| 保存・遷移・IME | `DocumentLifecycle/`、`AppState+SnapshotSyncV2*`、EditorKit |
| SQLite・同期 | NovelSyncV2Store / Application / Runtime |
| Import / Export | NovelSyncV2PortableBridge、NovelStorage、NovelExport |
| 認証・server | NovelAuth / NovelAuthApple、`SyncServerV2/` |
| AI会話・編集・同期 | `WritingAssistant/`、`AssistantIntegration/`、`ExternalAI/`、NovelWritingSupport / Store、iOS adapter |
| Apple開発補助 | `.codex/config.toml`、`.xcodebuildmcp/config.yaml`。[使い方](../README.md#aiによる起動画面確認) |

端末SQLiteへの保存後にremote workerを動かす。250 MiB添付は8 MiB単位で送り、全体digestを確認する。長い履歴は非再帰で取得し、128件を理由に打ち切らない。原稿コピー、校正・感想、AIチャット、共通・作品指示の同期、依頼範囲への生成編集と永続Undo、Mac起動中のMCPを実装した。同期作品の削除後1年保管、別作品復元、日単位の復元履歴、再送、小さな5分遅延表示、可読救出も実装済み。

自動保存は安定checkpointからの端末内の葉とし、保護保存・明示同期・60秒待機・5分上限・起動復旧で昇格する（D-103）。旧履歴とローカルの葉は保持する。既存の長い履歴自体は短縮しないため、serverの深さ上限など[レビュー S-01](SYNC_REVIEW.md)の別課題は残る。

macOSの滑らかなカーソルを通常EditorKitへ組み込み、端末の執筆設定で切り替える。[表示の仕様と受入](CARET_ANIMATION_INVESTIGATION.md)。

## 実装が残るもの

- Sync v2全体の不具合・性能・構造・UIの課題。[全体レビュー](SYNC_REVIEW.md)。D-01の端末内自動保存・昇格は実装済み。残る項目は個別に扱う。
- 構造整理R-08はpass A / Bで実装済み。型付きrowと6つの内部repositoryを共有`SQLiteExecutor`の上に配置し、公開actor・checkpoint/install等の単一transaction・SQL/schema/wireを維持する。Store内のSQL処理はrepositoryへ移し、schema migrationの判断は`Schema.swift`に残す。実機受入・公開完了とは別の構造整理。
- 削除予約・取消のアプリ画面。サーバーAPIと720時間後のworkerは実装済み。[lifecycle](auth/v1/account-deletion.md)。
- Package Validator / 共通fixtureの全体、Windows 11版とinstaller。[互換契約](CROSS_PLATFORM.md)。

## 仕様と実装の差

- Apple通知: 規範`/v1/auth/providers/apple/notifications`に対し、`auth_http.rs`は`/v1/auth/apple/notifications`を登録している。規範へ揃える際はApple側の登録先も確認する。[通知契約](auth/v1/apple-notification.md)。
- LAN CA export: `Scripts/export-sync-v2-staging-ca.sh`のedge固定名が現行role-splitと異なり、Sync epoch検査も不足する。[LAN手順](SNAPSHOT_SYNC_V2_STAGING.md)。


いずれも今回の文書更新では実装修正していない。

2026-09-26の実装・全体検証・サーバー反映と端末インストールは[受入記録](PROTECTION_AI_ACCEPTANCE.md)を参照する。

## 受入が残るもの

D-106 Step 1〜3は実装済み。head-first／backfill、優先取得、未取得版の復元確認、深いInbox／競合の待機、通信・検証エラー、従量接続の確認を両OSへ接続した。[検証範囲と残る制約](sync/v2/shallow-history-verification.md)。実accountでの二台同期・実機Low Data Mode・VoiceOver受入と稼働反映は未実施。

AI実APIでの応答・編集、登録済みMCPクライアントとの実利用、Mac／iPhone／iPadでのAI記録と指示の二台同期は別途受入する。

現行版のMac／iPhone／iPadでApple認証、長時間のIME・Undo、offline編集、二端末競合、履歴復元を確認する。署名・配布・clean install等の一般公開条件は[公開受入](COMMERCIALIZATION_IMPLEMENTATION.md)。ローカルテスト・個別画面・過去の実機成功から全項目を完了扱いにしない。

自動保存のdebounce変更は利用者が不採用とした方針であり、不具合修正の残件へ戻さない。

## サムネイル（D-104）

NovelThumbnailが予約名・所有者判定とImageIO／CoreGraphicsでの縮小JPEG生成を担当し、NovelUIが両OS共通の表示・切り抜き・設定操作を提供する。作品情報・人物・世界観と棚に接続し、所有者との同時削除、AI／MCPからの除外と添付書き戻し保全を実装。schema／wire／package形式の変更はない。合成画像・隔離された端末ストアで検証し、実写真・実原稿・実accountによる試験は行わない。実機の写真権限・Files provider別の操作や二台同期の受入は別途必要。

執筆の進み具合は端末内だけに保存する。通常Undo／Redoも手入力経路として扱うため、Redoで加筆量が再加算される。集計の書込失敗は本文保存へ伝播させずメモリ保持・再試行するが、再試行前のプロセス強制終了では未書込分を失う。到達履歴の初回読取が失敗している間は、重複通知を避けるため到達通知を抑止する。端末変更・再インストール時の集計移行は第1弾の対象外。

作品全体検索・置換と人物の登場話一覧は両OSで共有ロジックを使う。検索結果の件数上限・ページングは設けず、全一致を保持してListで表示するため、非常に多い一致では結果メモリと描画負荷が残る。置換の一時Undoは直前一回だけで、編集済みの話は戻さず明示履歴へ案内する。検索後の対象本文変更は全体中止で統一する。通常のネイティブUndo／Redoの集計は第1弾の一般規則を維持し、置換と検索画面からの「元に戻す」は集計しない。実機IME・Dynamic Type・VoiceOver、二端末同期の受入は別途必要。

表記・記号チェックは端末内の手動解析。Apple CFStringTokenizerの語分割・読みはOS辞書に依存し、同音異義語や固有名詞の誤検出・見逃しがある。人物名は同じ文字種・長さ・1字差・少ない出現に限定し、別の登録人物名は候補から除く。ひらがなの人物読みも同じ文字種内で照合するが、未知語の分割次第では拾えない。無視・件数の多数派表示で利用者が判断し、検出器は差し替え可能にした。ルビの親字は語として調べ、傍点で文字ごとに分かれた表記は語分割の限界が残る。結果の件数上限・ページングは設けず、多数の指摘ではメモリ・List描画負荷が残る。同数では置換を提案せず、3表記以上の組は最少数→最多数を入力する。個別無視は位置・文脈を含むため周辺の編集で再指摘され得る。実機VoiceOver・長時間IME・iPadの受入は別途必要。

## 執筆中の負荷（2026-10-03）

AI記録の同期は両OS共通の`WritingSyncScheduler`へ集約した。AI画面表示中10秒、非表示時5分、前面復帰・表示開始・記録追加後にwakeし、失敗は20秒から最大10分へバックオフする。チャット内の重複10秒ループも除いた。[同期間隔と他端末への影響](WRITING_ASSISTANT.md)。iOSの話一覧は表示・読み上げで同じ`ManuscriptCountCache`値を使う。

Apple M4 Max / macOS、Releaseの合成日本語文書を1字ずつ変更して計測。初回を除き、encode・比較・SQLite transactionは5回、公開checkpoint全体は3回の中央値（ms）。以下はencode再利用を取り下げた後の既存経路の再計測値。phaseと公開全体は別のcheckpointを測るため、中央値の合計は一致しない。

| 文書 | encode | 比較 | SQLite | checkpoint全体 |
| --- | ---: | ---: | ---: | ---: |
| 10万字 / 100話 | 8.64 | 22.30 | 31.30 | 62.40 |
| 30万字 / 150話 | 15.48 | 44.27 | 73.40 | 133.28 |
| 100万字 / 300話 | 38.72 | 116.07 | 229.94 | 387.56 |

最初の既存経路の公開全体は順に61.79 / 127.78 / 376.23msだった。今回も比較・SQLite書込が支配的で、30万字の全体は20ms目安を超える。変更のない話のencode再利用を試したが、全体時間の安定した短縮は確認できなかったため、今回は見送った。codec・store・cache専用のconformance変更は起点へ戻した。計測ハーネスだけをcacheに依存せず残す。次の候補は比較・SQLite書込の削減（既存snapshot読込・digest/closure検証、transaction内decode/検証とobject照合）。canonical出力、保存の成立条件、世代検査、durabilityの順序を維持する必要がある。CPU時間・実消費電力や実機の温度改善は未計測。

30万字/150行の一覧字数処理は、既存の2回走査7.80msから1回のキャッシュ参照0.037msへ（10回中央値、変更話1件、warm cache。SwiftUI描画全体は含めない）。指定iPhone 17 Pro Maxシミュレータで10万字の話は、通常文字入力のshouldChange 0.005ms、didChange 2.308ms、合計中央値2.314ms・最大2.802ms（5回warm-up後20回）。UITextStorageの置換は別に0.035ms。実キーボード・IME・App側モデル反映・レイアウト全体は含まない。5ms目安を下回るため、EditorKitの全文取得・比較は測定だけとし、実装を変更しない。実機と長時間IME・Undo、二端末AI同期は別途受入する。

再計測は`cd NovelKit && FUMINIWA_TYPING_BENCHMARK=1 swift test -c release --filter 'typingEnergyCheckpointBenchmark|typingEnergyOutlineCountBenchmark'`。iOSのdelegate計測はEditorKitの`IOSTextAdapterIntegrationTests`に含む（destinationは指定端末）。

cache取り下げ後はNovelKit全744件、checkpoint計測1件、macOS App全231件、指定Pro MaxのiOS App全189件、Python/Swift/Rustのconformance、SwiftFormat/SwiftLintで成功。両OSのAppテストは初回実行で通過した。前回のiOS Appテストは初回に検索遷移とsidebarの2件が失敗し、無変更の再実行では成功した。再現性の揺れの原因は未特定。PostgreSQL integrationは既存ゲートの方針により未実施。
