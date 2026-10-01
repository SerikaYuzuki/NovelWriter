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

macOSの滑らかなカーソルを通常EditorKitへ組み込み、端末の執筆設定で切り替える。[表示の仕様と受入](CARET_ANIMATION_INVESTIGATION.md)。

## 実装が残るもの

- 端末未取得作品の初回表示の高速化。一括取得後も全履歴の検証・保存完了を待つため、履歴の多い作品は待ち時間が長い。[現状・測定結果・改善課題](INITIAL_IMPORT_LATENCY.md)。追加実装は保留。

- 削除予約・取消のアプリ画面。サーバーAPIと720時間後のworkerは実装済み。[lifecycle](auth/v1/account-deletion.md)。
- Package Validator / 共通fixtureの全体、Windows 11版とinstaller。[互換契約](CROSS_PLATFORM.md)。

## 仕様と実装の差

- Apple通知: 規範`/v1/auth/providers/apple/notifications`に対し、`auth_http.rs`は`/v1/auth/apple/notifications`を登録している。規範へ揃える際はApple側の登録先も確認する。[通知契約](auth/v1/apple-notification.md)。
- LAN CA export: `Scripts/export-sync-v2-staging-ca.sh`のedge固定名が現行role-splitと異なり、Sync epoch検査も不足する。[LAN手順](SNAPSHOT_SYNC_V2_STAGING.md)。

いずれも今回の文書更新では実装修正していない。

2026-09-26の実装・全体検証・サーバー反映と端末インストールは[受入記録](PROTECTION_AI_ACCEPTANCE.md)を参照する。

## 受入が残るもの

AI実APIでの応答・編集、登録済みMCPクライアントとの実利用、Mac／iPhone／iPadでのAI記録と指示の二台同期は別途受入する。

現行版のMac／iPhone／iPadでApple認証、長時間のIME・Undo、offline編集、二端末競合、履歴復元を確認する。署名・配布・clean install等の一般公開条件は[公開受入](COMMERCIALIZATION_IMPLEMENTATION.md)。ローカルテスト・個別画面・過去の実機成功から全項目を完了扱いにしない。

自動保存のdebounce変更は利用者が不採用とした方針であり、不具合修正の残件へ戻さない。
