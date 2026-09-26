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
| AI送信・回答保存 | `NovelApp/WritingAssistant/`、`Features/AssistantFeedback/`、iOS adapter |
| Apple開発補助 | `.codex/config.toml`、`.xcodebuildmcp/config.yaml`。[使い方](../README.md#aiによる起動画面確認) |

端末SQLiteへの保存後にremote workerを動かす。250 MiB添付は8 MiB単位で送り、全体digestを確認する。長い履歴は非再帰で取得し、128件を理由に打ち切らない。原稿コピー、AIの明示送信、macOS校正反映、感想・アドバイスの保存／同期は実装済み。

## 実装が残るもの

- 削除予約・取消のアプリ画面。サーバーAPIと720時間後のworkerは実装済み。[lifecycle](auth/v1/account-deletion.md)。
- 通常の作品削除後の1年保管、別作品としての復元、履歴保持と未同期5分表示。現行との差分は[原稿保全・AI計画](PROTECTION_AI_PLAN.md)。外部backup・鍵退避は2026-09-26に不要と判断済み。
- iOSの校正本文反映。現在は回答表示まで。
- Package Validator / 共通fixtureの全体、Windows 11版とinstaller。[互換契約](CROSS_PLATFORM.md)。

## 仕様と実装の差

- Apple通知: 規範`/v1/auth/providers/apple/notifications`に対し、`auth_http.rs`は`/v1/auth/apple/notifications`を登録している。規範へ揃える際はApple側の登録先も確認する。[通知契約](auth/v1/apple-notification.md)。
- LAN CA export: `Scripts/export-sync-v2-staging-ca.sh`のedge固定名が現行role-splitと異なり、Sync epoch検査も不足する。[LAN手順](SNAPSHOT_SYNC_V2_STAGING.md)。

いずれも今回の文書更新では実装修正していない。

## 受入が残るもの

現行版のMac／iPhone／iPadでApple認証、長時間のIME・Undo、offline編集、二端末競合、履歴復元を確認する。署名・配布・clean install等の一般公開条件は[公開受入](COMMERCIALIZATION_IMPLEMENTATION.md)。ローカルテスト・個別画面・過去の実機成功から全項目を完了扱いにしない。

自動保存のdebounce変更は利用者が不採用とした方針であり、不具合修正の残件へ戻さない。
