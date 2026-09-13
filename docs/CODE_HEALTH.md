# コードの現状と残件

## 現行の入口

| 責務 | 場所 |
| --- | --- |
| ビルド・依存関係 | `project.yml`、`NovelKit/Package.swift` |
| macOS・iOS画面 | `NovelApp/Application/`、`NovelAppIOS/Features/`、各`Library/` |
| 保存・遷移・IME境界 | 各Appの`DocumentLifecycle/`、`AppState+SnapshotSyncV2*`、`EditorKit` |
| SQLite・同期 | `NovelSyncV2Store`、`NovelSyncV2Application`、`NovelSyncV2Runtime` |
| Import / Export | `NovelSyncV2PortableBridge`、`NovelStorage`、`NovelExport` |
| 認証・サーバー | `NovelAuth`、`NovelAuthApple`、`SyncServerV2` |
| AI | `NovelApp/WritingAssistant/`、[仕様](WRITING_ASSISTANT.md) |

通常保存は端末SQLite。保存待ち中の操作はID・session・accountとoperation gateで再検査し、本文を別作品へ適用しない。添付は8 MiB単位で送信し、250 MiBまでを全体digest確認後に公開する。恒久的な同期失敗は再起動後も理由を保持する。

## 残件

- 自動保存のdebounce方式は利用者指定で変更しない。連続入力中の期限変更は採用していない。
- [削除・backupのサーバー自動運用](ACCOUNT_RETENTION_OPERATIONS.md)は実装済み。削除予約・取消のアプリ画面と、別機器へのbackup／鍵退避は未対応。
- macOS／iOSの実端末でApple認証、長時間のIME・Undo、offline編集、二端末競合、履歴復元を受入する。ローカルテストや過去の実機成功を代用しない。
- iOSでのAI校正本文反映、Windows 11版・インストーラー、Package Validator全体、一般公開の受入は未完了。
- Apple通知の規範URLと登録routeに差分がある。[通知契約](auth/v1/apple-notification.md)を参照。

検証は[AGENTS](../AGENTS.md)の変更影響に応じた段階で行う。過去のログはGit・サーバーの運用証跡で追い、ここへ時系列で追記しない。
