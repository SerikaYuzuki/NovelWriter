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

自動保存のdebounce方針は2026-10-03に変更した。保存中に入力が続いても次のautosaveを直ちに始めず、通常の入力停止2秒を待つ。即時保存の経路は維持する。

## サムネイル（D-104）

NovelThumbnailが予約名・所有者判定とImageIO／CoreGraphicsでの縮小JPEG生成を担当し、NovelUIが両OS共通の表示・切り抜き・設定操作を提供する。作品情報・人物・世界観と棚に接続し、所有者との同時削除、AI／MCPからの除外と添付書き戻し保全を実装。schema／wire／package形式の変更はない。合成画像・隔離された端末ストアで検証し、実写真・実原稿・実accountによる試験は行わない。実機の写真権限・Files provider別の操作や二台同期の受入は別途必要。

執筆の進み具合は端末内だけに保存する。通常Undo／Redoも手入力経路として扱うため、Redoで加筆量が再加算される。集計の書込失敗は本文保存へ伝播させずメモリ保持・再試行するが、再試行前のプロセス強制終了では未書込分を失う。到達履歴の初回読取が失敗している間は、重複通知を避けるため到達通知を抑止する。端末変更・再インストール時の集計移行は第1弾の対象外。

作品全体検索・置換と人物の登場話一覧は両OSで共有ロジックを使う。検索結果の件数上限・ページングは設けず、全一致を保持してListで表示するため、非常に多い一致では結果メモリと描画負荷が残る。置換の一時Undoは直前一回だけで、編集済みの話は戻さず明示履歴へ案内する。検索後の対象本文変更は全体中止で統一する。通常のネイティブUndo／Redoの集計は第1弾の一般規則を維持し、置換と検索画面からの「元に戻す」は集計しない。実機IME・Dynamic Type・VoiceOver、二端末同期の受入は別途必要。

表記・記号チェックは端末内の手動解析。Apple CFStringTokenizerの語分割・読みはOS辞書に依存し、同音異義語や固有名詞の誤検出・見逃しがある。人物名は同じ文字種・長さ・1字差・少ない出現に限定し、別の登録人物名は候補から除く。ひらがなの人物読みも同じ文字種内で照合するが、未知語の分割次第では拾えない。無視・件数の多数派表示で利用者が判断し、検出器は差し替え可能にした。ルビの親字は語として調べ、傍点で文字ごとに分かれた表記は語分割の限界が残る。結果の件数上限・ページングは設けず、多数の指摘ではメモリ・List描画負荷が残る。同数では置換を提案せず、3表記以上の組は最少数→最多数を入力する。個別無視は位置・文脈を含むため周辺の編集で再指摘され得る。実機VoiceOver・長時間IME・iPadの受入は別途必要。

## 執筆中の負荷（2026-10-03）

AI記録の同期は両OS共通の`WritingSyncScheduler`へ集約した。AI画面表示中10秒、非表示時5分、前面復帰・表示開始・記録追加後にwakeし、失敗は20秒から最大10分へバックオフする。チャット内の重複10秒ループも除いた。[同期間隔と他端末への影響](WRITING_ASSISTANT.md)。iOSの話一覧は表示・読み上げで同じ`ManuscriptCountCache`値を使う。

Apple M4 Max / macOS、Releaseの合成日本語文書を1字ずつ変更し、`SyncV2Application.checkpoint`からlocal commit後の戻りまで測った。初回を除く5回の中央値（ms）。unbound、vaultなし、fake remote、添付・resourceなしの経路で、実Keychain・network・画面描画は含めない。scope解決、encode、比較、SQLiteは同じ公開経路の中で測り、SQLite欄はcommit直後のcache記帳も含む。phaseごとの中央値の合計はtotalと一致しない。旧ハーネスの62.40 / 133.28 / 387.56msはStoreだけの経路で、scopeの全読込／検証を含んでいなかった。

| 段階 | 文書 | scope | encode | 比較 | SQLite | 公開経路total |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 修正前 | 10万字 / 100話 | 50.67 | 8.43 | 21.98 | 31.01 | 112.75 |
| 修正前 | 30万字 / 150話 | 106.49 | 15.40 | 43.78 | 73.43 | 238.66 |
| 修正前 | 100万字 / 300話 | 304.50 | 38.63 | 115.74 | 234.14 | 693.01 |
| A | 10万字 / 100話 | 51.01 | 8.32 | 23.05 | 25.28 | 107.73 |
| A | 30万字 / 150話 | 107.02 | 15.25 | 42.72 | 56.21 | 224.62 |
| A | 100万字 / 300話 | 302.73 | 38.83 | 117.28 | 174.94 | 630.91 |
| A+B | 10万字 / 100話 | 51.69 | 8.40 | 6.41 | 24.94 | 92.04 |
| A+B | 30万字 / 150話 | 106.77 | 15.22 | 9.03 | 57.42 | 189.32 |
| A+B | 100万字 / 300話 | 305.90 | 38.88 | 18.41 | 171.90 | 531.01 |
| A+B+D | 10万字 / 100話 | 48.37 | 7.98 | 5.57 | 23.82 | 86.00 |
| A+B+D | 30万字 / 150話 | 103.79 | 14.66 | 8.38 | 56.23 | 183.53 |
| A+B+D | 100万字 / 300話 | 298.05 | 38.22 | 17.44 | 174.78 | 528.61 |
| F導入直後 | 10万字 / 100話 | 0.15 | 8.09 | 5.78 | 23.41 | 38.03 |
| F導入直後 | 30万字 / 150話 | 0.23 | 15.52 | 8.95 | 57.95 | 83.81 |
| F導入直後 | 100万字 / 300話 | 0.16 | 39.91 | 17.32 | 204.95 | 267.73 |
| 最終 A+B+D+F | 10万字 / 100話 | 0.14 | 7.77 | 5.73 | 23.86 | 38.22 |
| 最終 A+B+D+F | 30万字 / 150話 | 0.16 | 14.51 | 8.55 | 56.25 | 81.47 |
| 最終 A+B+D+F | 100万字 / 300話 | 0.20 | 36.49 | 16.60 | 168.49 | 225.58 |

同じiPhone 17 Pro Max（`DC53181E-2D66-43D8-B765-99425D254C6C`）のiOS Simulatorでも、Releaseの公開経路を5回中央値で比較した。修正前はHEADの原実装を同じworktree内の一時packageに取り出し、計測observerだけ加えた。実機の消費電力・温度を示す値ではない。

| iOS Simulator | 文書 | scope | encode | 比較 | SQLite | 公開経路total |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| 修正前 | 10万字 / 100話 | 49.61 | 8.05 | 21.45 | 30.53 | 111.61 |
| 修正前 | 30万字 / 150話 | 107.36 | 14.99 | 44.04 | 73.16 | 242.10 |
| 修正前 | 100万字 / 300話 | 304.09 | 37.27 | 116.82 | 229.66 | 688.75 |
| 改善後 | 10万字 / 100話 | 0.17 | 7.98 | 5.87 | 24.45 | 39.36 |
| 改善後 | 30万字 / 150話 | 0.19 | 15.29 | 8.91 | 59.51 | 85.46 |
| 改善後 | 100万字 / 300話 | 0.19 | 37.15 | 17.12 | 180.34 | 237.14 |

Aはentries insert等のmanifest SHA-256を一回にし、Bは既存snapshotのobject全読込／再hash／JSON検証をentries比較から除いた。Bではmanifestのdigest・schema・work照合とentries／parents行のattestationを維持する。親が異なる昇格済み版でも、object ID・byte count・content typeを含むentriesで同じcontent判定になる。DはEntityKeyの正規表現を事前compileし、末尾改行を含む従来の文法と一致するテストを置いた。

FはStore actor内の検証済みcache。本文やencoded objectのコピーは増やさない。WorkID・scope・snapshot ID・世代・document anchor・`data_version`・`total_changes()`が一致した時だけscopeの全読込／検証を省く。作品openとcache missでは完全検証し、安定した成功読取はstampを記録する。本文を変えないと監査した書込だけは、前後の版を照合してstampを引き継ぐ。account／作品切替、未分類transaction、import／install／adoption／復元、世代不一致、close／再open、別connectionのSQL変更、rollbackは無効にする。表はwarm autosaveで、cold missは完全検証が必要。ただし成功したresolverの検証をStoreで再利用するため、旧実装の二重検証はなくなった。

省く検査は、cache hitの通常保存で既存本文・添付・resourceを読み直してhash・closure・decodeを再確認する処理と、Bの比較時の既存object再検証。SQLiteの既存immutability triggerはobject・snapshot・entries・parentsの書換え／削除を拒否し、SQL変更番号と版の照合がcacheの根拠になる。新しく保存するsnapshotの全decode／object・closure検証、作品を開く時、remote／import取り込み時、cache無効化後の完全検証、scope／世代／親のCAS、COMMIT後のUI反映、ローカルだけで保存が成立する境界は維持した。SQL変更番号に現れない媒体破損を、cache hitのautosaveで再検出する検査は失う。再openなどの完全読取で再検査する。

Cは見送り。日時が形式に合っていても実在しない場合、`validateObjects`は通り、`SnapshotCodec.decode`は拒否することをテストで確認した。置換すると拒否条件が弱くなる。Eも見送り。最終100万字のSQLite内訳はdecode 162.68ms、既存object照合・新object挿入0.54ms、entries挿入2.26ms。存在確認の一括化では50msへ近づかず、queryの上限／重複object／import attestationに新しい場合分けを増やす費用が大きい。

Gは通常autosaveを一回で区切り、保存中の追加入力は入力停止2秒のdebounceを待つ。timerが保存中に満了した場合は再予約する。即時保存とexclusive flushは従来どおり最新revisionまでdrainし、終了／backgroundにも未保存を残さない。途中版だけ保存した場合はdirtyを通知する。保存間隔の追加延長は実装していない。

100万字はなお50msを大きく超える。次の候補は全decode／validationで重複するcanonical parseとentity decodeを、一つの完全検証passで共有すること。日付・参照・closure等の拒否条件を残す必要がある。検証済みmanifest／entriesの照合再利用も候補だが、主因はdecodeである。CPU時間・実消費電力・実機の温度改善は未計測。

### 執筆中の更新確認と端末の時間設定

2026-10-03の利用者決定で、前面作品のhead確認は最後の本文編集から60秒未満なら120秒間隔、停止後は10秒間隔、失敗後は60秒間隔にした。本文の既存session／IME guardを通った編集だけで時刻を更新する。待機中は通常間隔と入力中の期限で再判定し、停止後に長い待機を持ち越さない。前面復帰と章／話／作品遷移完了で即時確認を起動し、遷移は通信を待たない。promotion／uploadの既存処理とpublish時の競合検出は保つ。他端末の更新に気づくまで、連続入力中は最大約2分かかる。端末SQLiteの自動保存には通信を加えていない。

`FuminiwaTiming`はUserDefaultsを読まない値型にし、アプリの起動時に共通adapterが15キーを読み、runtime・schedulerへ注入する。promotionのidle／maximum、head確認の通常／入力中／失敗後／入力中とみなす期限、送信retryのinitial／maximumを追加した。既定値・範囲・変更方法は[DESIGN 6.4](DESIGN.md#64-保存)。送信retryの既定値では元の2秒からの倍増とjitter／上限付近の挙動を維持する。設定UIは追加していない。

注入時計のテストで連続入力中の120秒、停止後10秒、失敗後60秒、観測再開時の即時確認、別WorkIDの独立性と設定値のruntimeへの伝達を確認する。両AppのUserDefaults adapterは全15キーの上書き、範囲clamp、bool／非数値／非有限値、起動時の固定値をテストする。

### 同期ONでのcheckpoint cache

2026-10-03の追加レビューで、従来の全transaction無効化は同期ONで効果が消えることを再現した。`CheckpointWorkerCacheTests`で公開checkpointを7回実行し、初回を除く6回を数えた。同期ONでは各回の通常leaf昇格境界を明示同期で進め、実Store・Production planner／workerとfake remoteのupload／ackを完了してから次を入力する。workerの実uploadは修正前後とも15回。完全検証回数は`checkpointFullValidationCount`（既存版の検証）で、新規snapshotの完全decodeは含めない。計測はヒット率で、実際の執筆sessionの頻度や消費電力を示すものではない。

| 経路 | 修正前ヒット | 修正後ヒット | 完全検証回数（修正前→後） |
| --- | ---: | ---: | ---: |
| 同期OFF | 5/6（83%） | 6/6（100%） | 2→0 |
| 同期ON・upload／ackあり | 0/6（0%） | 6/6（100%） | 12→0 |

引き継ぎ可としたStore経路：

- `promoteCurrentLeaf`（`promoteUnpromotedLeaves`を含む）：historyとintentのみ。snapshot／entries／current pointer／世代を変更しない。
- `persistSealedCommand`と`acknowledge`：`createWork`・`prepareObject`・`finalizeObject`・`registerSnapshot`・`publish`だけ。command／intent／receipt／upload／remote equivalentとworksのacknowledged headを更新する。復元・競合解決・cloneのseal／ackは対象外。
- `markSending`・`requeue`・`park`・`quarantine`、両`retryUnacknowledgedCommands`、`requestSynchronization`・`requestAutomaticSynchronization`・`replanRejectedPublish`：command／intent／quarantine／recoveryと昇格historyだけ。
- `persistUploadTransfer`・`acknowledgeUploadTransfer`・`quarantineUpload`：転送byteコピー、offset、lifecycle、quarantineだけ。snapshot object本体には書かない。

すべて書込前に既存stampの`total_changes()`と`data_version`まで一致を確認し、書込後も対象作品のscope・current snapshot・世代・anchor・`data_version`が同一の場合だけ変更回数を更新する。既に失効したstampは無害な書込でも復活させない。既存object／snapshot／entries／parentsはimmutability triggerでupdate／deleteを拒否する。対象経路はentriesの追加insertとlocal resource変更もしない。未分類書込は従来どおり無効化し、外部connectionの実DB変更は本文に関係なく失効する。AI記録は`writing-assistant.sqlite`、進み具合は別SQLiteに保存するので、このStoreのstamp引き継ぎ経路には含めない。

完全検証したopen直後とcache miss後にもstampを記録した。open自体は毎回完全検証し、processを跨いでstampは復元しない。読込中に外部書込が入った場合やcache記帳失敗時はstampを捨てるだけで、完全読込したopenの成功条件を変えない。設定キー・範囲・変更方法は[DESIGN 6.4](DESIGN.md#64-保存)に記載した。

30万字/150行の一覧字数処理は、既存の2回走査7.80msから1回のキャッシュ参照0.037msへ（10回中央値、変更話1件、warm cache。SwiftUI描画全体は含めない）。指定iPhone 17 Pro Maxシミュレータで10万字の話は、通常文字入力のshouldChange 0.005ms、didChange 2.308ms、合計中央値2.314ms・最大2.802ms（5回warm-up後20回）。UITextStorageの置換は別に0.035ms。実キーボード・IME・App側モデル反映・レイアウト全体は含まない。5ms目安を下回るため、EditorKitの全文取得・比較は測定だけとし、実装を変更しない。実機と長時間IME・Undo、二端末AI同期は別途受入する。

再計測は`cd NovelKit && FUMINIWA_TYPING_BENCHMARK=1 swift test -c release --filter 'typingEnergyCheckpointBenchmark|typingEnergyOutlineCountBenchmark'`。iOSのdelegate計測はEditorKitの`IOSTextAdapterIntegrationTests`に含む（destinationは指定端末）。

今回の追加依頼後の最終の重たい検証は成功。NovelKit全774件、macOS App全236件、Pro MaxのEditorKit全87件・iOS App全194件、Python／Swift／Rust conformance、SwiftFormat／SwiftLint、指定UDIDでの`./Scripts/check.sh`全体が通った。PostgreSQL integrationは既存ゲートに従い明示SKIP。最初のcheckpoint軽量化の検証では、既存の150ms download期限テストがlostResponseで一度失敗した。単独再実行は成功し、大文書テストの引数を直列化した全体再実行でも成功した。タイミング依存の原因は未確定。

追加レビューの途中では、競合解決テストが単独でも`safeBoundaryRejected`となった。open読込中に別connectionのremote状態が更新され、stampの安定性照合をopenの成功条件へ追加していたことが原因。完全読込後のcache記帳は失敗してもopenを失敗に変えないよう修正し、回帰テストと全体検証が成功した。新規`NovelTiming`のApp依存許可リストとiOS専用3テストのinitializerも更新した。指定Simulatorの別xcodebuildを検出する保護が一度停止し、現在は5秒ごとに空きを再確認してiOS検証を進める。サーバー側に起因するRust失敗はなかった。今回追加したruntime注入テストのpreview構成引数漏れと、新規テストの201文字の行がSwiftLint上限を超えた点は修正し、全体再実行が成功した。時間設定のUserDefaultsテストはmacOS／iOS両方で通った。

修正前のHEADを同じworktree内の一時packageとして実行し、1千／10万／30万／約100万字と添付・resource有無の8条件で修正後とsnapshot/object ID、manifest bytes、entries、works/history、intent/resource行を比較して一致した。実行ごとのoccurrence／intent UUIDと時刻だけ正規化した。一時package・比較用生成物・今回のビルド生成物は除いた。実account・実原稿・実DB・サーバー稼働反映・実機受入は対象外。
