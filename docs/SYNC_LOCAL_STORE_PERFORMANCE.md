# ローカル取り込み・checkpointの性能計測（2026-10-01）

対象は `codex/sync-v2-review-fixes`、変更前の土台は `579106051`。実原稿・実DB・serverを使わず、一時ディレクトリに新規SQLiteを作成し、終了時にその合成fixtureだけを削除した。SQLite schema、NovelCoreの依存関係、既存履歴・同期証跡の保持方針は変更していない。commit・push・deployは行っていない。

環境はmacOS arm64、Xcode-beta / Apple Swift 6.4。Releaseで1回ずつ計測。1,500 snapshots、各29 entries、4章・各1話、本文は約7 KB。各世代で1話の本文objectだけを変更し、他のentityとdocument anchorを固定した。graph生成時間・ビルド時間はphase計測に含めない。

| 計測対象 | 変更前 | 変更後 |
| --- | ---: | ---: |
| stage | 7.210068 s | 1.691502 s |
| verify | 8.603119 s | 0.984787 s |
| adopt | 10.140889 s | 1.262545 s |
| 3段階合計 | 25.954076 s | 3.938833 s |
| 長い履歴の末尾で本文を変更するcheckpoint | 15.234 ms | 10.281 ms |
| 初回専用install（空の別SQLite） | 専用経路なし | 1.723327 s |
| 初回install＋別作品の継続checkpoint | 未計測 | 1.850545 s |
| 上記の別作品checkpointの最大待ち時間込み所要時間 | 未計測 | 310.869 ms |

新しい初回経路はstage/verify/adoptの代わりに、検証済みgraphを単一transactionでinstallする。通常同期・競合用の3段階は残す。競合計測では、同じstoreの別作品の本文を20ms間隔で変更し、毎回checkpointを確定させた。初回graphのCPU検証はstore actor外、DB反映はactor内の単一BEGIN IMMEDIATEで実行する。

全manifest/entryの読み取りと保存には引き続き O(Σentries) が必要であり、履歴全体を保存するコストが消えたという結果ではない。除去したのは祖先の重複探索、各世代が参照する全bytesの重複hash・decode、entryごとのprepare・問い合わせ・新規行read-back。manifestのhash・構造、unique objectのhash、閉包・到達可能性・循環・anchor・scope・CASは検証する。実機iPhoneでの速度と、さらに大きな履歴での最大lock時間は未計測。

| ID | 変更箇所と内容 |
| --- | --- |
| F-06追修正 | `SyncV2Application+Library.swift` / `ImportProgress.swift` / `ProductionSyncV2RemoteClient+HTTP.swift` / `ProductionSyncV2RemoteClient.swift`。全体180秒制限を受信停止60秒へ変更。URLSessionのdownload byte callbackで進捗を更新。request idle 30秒、resource 1時間。local-store検証・installは通信監視の外。 |
| L-01 | `LocalSyncV2Store+SQLite.swift`。transaction内の挿入・完全照合済みObjectIDを共有。通常checkpointの既存objectはbyte_countとcontent addressing・不変triggerを信頼し、読込時にhash検証。importでは既存CASの破損を取り込まないようunique objectごとに1回bytesも照合する。cacheはcommit/rollbackで破棄。 |
| L-02 | 同ファイル。新規snapshotは親の存在だけを検査。即時FKと親IDを含むmanifest hashにより循環を閉じられない。既存snapshotは循環・bytes・entry/parentを照合し、欠けた証跡をINSERT OR IGNOREで補修しない。 |
| L-03 | `SnapshotValidation+Graph.swift` / `SnapshotValidation+Closure.swift` / `SnapshotValidation+Entity.swift` / `LocalSyncV2Store+GraphValidation.swift`。object/entityをcall内cacheで検証し、各snapshotの参照閉包を検査。全世代のmodelをdecodeしない。anchorはObjectID一致と1回のdecode。既存schema_metaにinbox単位の検証器version＋head digestを保存し、欠落・不一致時は全文検証。永続inboxのbytesは常に再hashする。 |
| L-04 | `LocalSyncV2Store.swift` / `+SQLite.swift` / `+InboxLoading.swift`。storeごとのprepared statement cache、reset/clear_bindings、close時finalize。object/manifest/closureをordered bulk queryで読み、メモリで照合。 |
| L-05 | `+SQLite.swift` / `CanonicalTimestamp.swift` / `SnapshotCodec+Encoding.swift` / `SnapshotCodec+ModelDecoding.swift`。新規行の直後のattestationを省略。formatterはlock付きcache、hex変換はUTF-8 bytesで処理。 |
| L-06 | `LocalSyncV2Store+InitialInstall.swift` / `ProductionSyncV2Kernel.swift`。検証済みtokenを作成後、live bindingを再照合して単一transactionへ渡す。世代0/current NULL、scope、anchor、conflict・intent不在をtransaction内で再確認。COMMIT前の失敗は全rollback。COMMIT後の取消しは表示を拒否し完成済み作品を保持。旧未完了inboxは削除しない。契約は `download.md`、DecisionはD-102。 |
| L-07 | `+Inbox.swift` / `+InitialInstall.swift`。graph検証をactor外へ出し取消しを伝播。actorへ戻った後でmutable条件を再確認。上記の競合benchmarkで別作品の実checkpointを確認。 |

再現用の通常入口は `./Scripts/measure-import-performance.sh`。`FUMINIWA_IMPORT_BENCHMARK=1` がない通常の `swift test` ではbenchmarkを実行しない。この実行環境ではcache先とcompiler macro subprocessの設定が必要だったため、以下を使用した。

```sh
CLANG_MODULE_CACHE_PATH=/tmp/fuminiwa-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/tmp/fuminiwa-swift-cache \
./Scripts/measure-import-performance.sh \
  --disable-sandbox --build-system native \
  --scratch-path /tmp/fuminiwa-native-build -Xswiftc -disable-sandbox
```

以下のSwiftPMコマンドにも同じ2つのcache環境変数を設定した。

```sh
# 全Swiftテスト：実行したが完了せず中断
swift test --disable-sandbox --build-system native \
  --scratch-path /tmp/fuminiwa-native-build --package-path NovelKit \
  -Xswiftc -disable-sandbox

# 同期関連：最終209テスト成功
swift test --disable-sandbox --build-system native \
  --scratch-path /tmp/fuminiwa-native-build --package-path NovelKit \
  -Xswiftc -disable-sandbox \
  --filter 'NovelSyncV2StoreTests|NovelSyncV2Tests|NovelSyncV2ApplicationTests' \
  --skip ProductionFreshResumeTests

# iOS向けNovelKit全体：成功（Simulator/実機でのtest実行ではない）
swift build --disable-sandbox --build-system native \
  --scratch-path /tmp/fuminiwa-ios-package --package-path NovelKit \
  --triple arm64-apple-ios17.0 \
  --sdk /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk \
  -Xswiftc -disable-sandbox
```

| 検証 | 結果 |
| --- | --- |
| 変更前・変更後Release benchmark | 成功。上表。 |
| 同期関連Swiftテスト | 成功、209 tests / 22 suites、42.855秒。初回rollback、取消し・binding境界6ケース、C-01の既存inbox4ケース、single-flight、永続inbox破損・version不一致、既存CAS破損、証跡欠落、large-object transport、graph conformanceを含む。 |
| 全Swiftテスト | 失敗・未完了。Keychain関連2テストで `.status(-50)` 等の4 issues。一部のUI・storage等のテストが完了せず中断（exit 130）。全件成功は確認できていない。切り出し実行では `ProductionFreshResumeTests` の2テストを除外した。 |
| `./Scripts/check.sh` | 失敗。最初のconformance段階のSwiftマクロ実行で `sandbox_apply: Operation not permitted`。その前のPython canonical fixture 66 vectorsとproduction/test境界は成功。以降のRust・後続gateには未到達。 |
| check.sh記載のiOS compile (`cd NovelKit && xcodebuild build -scheme NovelKit-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`) | 失敗。Xcodeがその場所をproject/workspace/packageとして認識せず、Simulator接続も拒否。上記SwiftPMのiOS全体compileは別途成功。 |
| macOS app test | 実行を試みたが開始前に失敗。`xcodebuild test -project FUMINIWA.xcodeproj -scheme FUMINIWA -destination 'platform=macOS' -derivedDataPath /tmp/fuminiwa-mac-tests CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`。SwiftPM manifest cache/診断fileへの書込拒否。cache環境変数・`-packageCachePath`・`OTHER_SWIFT_FLAGS`を指定した再試行でも同じ制約。 |
| iOS app test | 実行を試みたが開始前に失敗。scheme `FUMINIWAIOS`、destination `generic/platform=iOS Simulator`、derivedData `/tmp/fuminiwa-ios-tests`、他は同上。manifest cache書込拒否。`xcrun simctl list devices available -j` 自体もCoreSimulatorService接続拒否で失敗し、具体的なSimulatorを取得できなかった。実機・Simulator受入は未実施。 |
| SwiftFormat（変更24 Swift filesのみ） | 成功、0 files require formatting。退避フォルダは対象外。 |
| `swiftlint lint --quiet --no-cache --baseline .swiftlint.baseline.yml` | 成功（exit 0、既存を含むwarningsあり）。 |
| `check-code-structure.sh` / `check-sync-target-dependencies.sh` | 成功。 |
| `check-test-network-boundary.sh` / `check-ai-target-separation.sh` / `check-sync-v2-boundary.sh` | 成功。 |
| `git diff --check` | 成功。 |

実装と上記ローカル検証まで。稼働反映・実機受入・公開完了を示すものではない。
