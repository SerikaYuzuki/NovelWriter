# コードの現状と検証

2026-09-13更新。現行sourceの入口と未完了の境界をまとめる。全体レビューの発見時点は[レビュー](PROJECT_REVIEW_20260913.md)、修正と今回の検証は[実装記録](REVIEW_IMPLEMENTATION_20260913.md)。以前の調査・追記は[更新前の記録](archive/2026-09-13-CODE_HEALTH-before-review.md)に分離した。

## 現行の入口

| 責務 | 編集・確認する場所 |
| --- | --- |
| 通常targetと依存関係 | `project.yml`、`NovelKit/Package.swift` |
| macOS起動・作品一覧 | `NovelApp/Application/FuminiwaApp.swift`、`LibraryWindowView.swift` |
| macOS保存・遷移 | `NovelApp/DocumentLifecycle/`、`NovelApp/Application/AppState+SnapshotSyncV2*.swift` |
| iOS作品一覧・執筆 | `NovelAppIOS/Library/`、`NovelAppIOS/Features/Writing/` |
| 本文、IME、Undo | `NovelKit/Sources/EditorKit/` |
| SQLite・同期の実行 | `NovelSyncV2Store`、`NovelSyncV2Application`、`NovelSyncV2Runtime` |
| 明示Import / Export | `NovelSyncV2PortableBridge`、`NovelStorage` |
| 同期server・Apple認証 | `SyncServerV2`、[認証契約](AUTH.md) |
| AIの明示送信 | [AI支援](WRITING_ASSISTANT.md) |

通常の正本は端末内SQLite。ローカル保存後にremote workerを再開する。旧CloudKit/v1やpackageを通常保存へ戻さない。コード上のsource・生成物・履歴は、通常targetへの接続の証拠として区別する。

## 今回の修正

利用者指定でR1のautosave debounceは変更しない。R2〜R14は、保存待ち中のID固定、保存と添付の排他、削除待ちの再認証対応、不要resourceの解放、履歴の非再帰化とobject共有、認証前upload読取の防止、Apple通知順序・revoke retry、Unicode文字数、再認証と同期不能の案内を扱う。

大きな添付は8 MiB単位で自宅サーバーへ送る。250 MiBのobject契約は維持し、全体digestを検証するまで公開しない。校正の色付けは共通の前後を比較対象から外し、大きな変更では変更ブロックを強調する。履歴reasonとAI回答未完了の理由を日本語で示す。

実装の有無、テスト、実サーバーへの反映、実機受入の結果は[実装記録](REVIEW_IMPLEMENTATION_20260913.md)で分けて管理する。

## 残る境界

- 実端末のAppleシート、長時間のIME・Undo、offline編集と端末間競合は、該当する実機証拠で受入する。
- account削除の30日猶予とbackup1年、公開運用、Windows W0は[利用者方針](OWNER_DECISIONS.md)と[互換契約](CROSS_PLATFORM.md)に従う。個別の同期テストをこれらの完成へ読み替えない。
- 全体チェックの過去の失敗・成功を今回の結果へ流用しない。D-086に従って変更影響に応じた段階を選ぶ。
