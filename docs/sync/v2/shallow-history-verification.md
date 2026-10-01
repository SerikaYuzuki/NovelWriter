# D-106 検証範囲と制約

設計の正本は [shallow-history-design](shallow-history-design.md)。2026-10-02、Step 1〜3を実装。今回のStep 3は `codex/sync-v2-review-fixes` の未コミット差分。実原稿・実account・実serverは使わず、一時SQLite、合成履歴、隔離されたDebug-Testを使用した。稼働反映・実機受入・公開完了を意味しない。

## Step 3

- 優先取得、他作品の中断／cursor再開、未取得版の取得後復元、深いInbox／競合の待機と再実行、offline／従量接続、回線切替時の同意、検証エラーの自動再試行禁止と明示再試行、全状態の日本語mappingを対象にした。
- macOS Debug-Test: 198件成功、3件skip。iOS Debug-Test: 全体154件成功、2件skip。その後の取得待ち中の編集・保存と明示復元test、画像testも成功。既存の別用途の画像収録testはopt-inのまま。
- iOS Simulatorの合成画面: 履歴未取得・offline・復元待ちsheet・競合待機・通信失敗＋再試行・検証失敗をlight/darkで収録。画像と実行logは `/private/tmp/claude-501/shallow-step3/`。画像は実装したViewと一時SQLiteの状態から生成し、目視確認した。
- `./Scripts/check.sh`: sandbox内でSwiftマクロpluginの起動に失敗し完走できない。静的検査・Native build systemのNovelKit test・XcodeBuildMCPのapp testは別に実行する。全gate成功とは扱わない。
- NovelKit native全体: 656件、8 issues。内訳は実pasteboardを使う1 testの4 issuesとKeychainを使う2 testsの4 issues。対象の優先取得・履歴mapping・validation再試行禁止は成功。OS serviceの成功はこの実行から主張しない。該当3 testsのみを明示除外した最終実行は653件／57 suites成功。

- SwiftFormat lint成功、SwiftLint errors 0、source構造・依存・test-network・AI・sync-v2境界検査成功。変更したtestの`#expect`内にkey pathなし、入れ子の`#require`なし。
- Python conformance 75 vectors成功。Rust offline test成功（実DB Gateは環境変数を除去して未実施）。

Native実行は `swift test --disable-sandbox --scratch-path /tmp/d106-step3 --build-system native --no-parallel`。成功した限定実行では `--skip 'KeychainAuthSessionVaultTests|freshProductionCompositionResumesWithEmptyKeychain|localFirstEditabilityKeepsAllMutationPathsAvailable'` を付けた。画像testはiOS Debug-Testで `FUMINIWA_SHALLOW_CAPTURE=1` を指定する。

## Step 2から引き継ぐ制約

- 旧checksum `6b089b87ef6118cbf04e89b3e46295b8b1297463e68cde8e785d44149c76c467` は既存DDL builderで再現できない。正確な旧schemaの根拠なしに移行受入を広げず、fail-closedを維持。「全旧checksumで移行成功」とはしていない。
- 進捗はsnapshot総数でなくcommit済みの重複除去後のMB。wire totalsのitemsをsnapshot数へ読み替えない。
- Step 2の合成計測は1,500 snapshotsでfull import 3.448秒／head-first 0.027秒、256 wire itemsのbackfill write lock 37.6 ms。単発の端末内計測であり実機SLAではない。
- Step 2では共有fixtureのPython 75 vectors、Rust 104 passed / 1 ignoredと対象テストを確認した。旧検証記録の全文はGit履歴へ集約する。実DB Gateと実機Low Data Mode・VoiceOver・二台同期は別途必要。
