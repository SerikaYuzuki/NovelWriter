# 公開前の技術受入

一般公開の受入は未完了。ここは公開に必要な条件を扱い、日常の文書編集に全項目の実行を要求しない。変更ごとの検証は[AGENTS](../AGENTS.md)、実装の残件は[CODE_HEALTH](CODE_HEALTH.md)。価格・法務・販促・決済は明示依頼の範囲で扱う。

## 実装と公開の境界

| 領域 | 実装されているもの | 残る条件 |
| --- | --- | --- |
| 保存・同期 | 両AppのSQLite、Outbox/Inbox、競合3択、履歴復元 | 現行版の二端末・offline・失敗／再起動受入 |
| 執筆・画面 | macOS Workbench、iOS段階navigation、補助入力、原稿コピー | IME・Undo・accessibility・各画面の端末受入 |
| AI | preview後のHTTP送信、macOS校正反映、感想・アドバイスの保存／同期 | iOS校正反映は未実装。実サービス確認は合成原稿で行う |
| 認証・削除 | Appleログイン、削除予約／取消API、期限到来worker | アプリ内予約／取消画面、Apple通知route差分、実通知・鍵rotation受入 |
| backup | 自宅サーバーの日次暗号化・1暦年保持 | 別機器へのbackup・鍵退避、削除済みaccountを復活させない復旧運用 |
| package | v3 reader/writer、portable bridge、部分validation | 共通fixtureとPackage Validator全体、Windows往復 |
| 配布 | projectの署名・Hardened Runtime・OS下限設定 | 配布物の署名、公証、clean install、更新／rollback |

## 原稿保全と認証

- local checkpoint、account/namespace隔離、lost response、process restart、容量不足・保存失敗、復元前保全を対象版で確認する。
- 二端末の通常往復とoffline分岐、競合3択、履歴復元、remote-only取得、account切替を実機で確認する。
- Apple再認証・refresh・失効・障害と通知URLを確認し、認証失敗中も端末内編集を維持する。
- 削除の予約・取消・期限表示をアプリから扱い、サーバー消去とApple失効完了を区別する。仕様は[削除lifecycle](auth/v1/account-deletion.md)。
- backupを隔離先へ復元し、現在の削除記録と照合してから公開へ戻す。[復旧手順](ACCOUNT_RETENTION_OPERATIONS.md)に従う。

## packageとOS

Package Validator / W0・Windows往復の条件は[CROSS_PLATFORM](CROSS_PLATFORM.md)へ集約する。v3の成功fixtureと非対応versionの拒否、参照・Unicode・path・resource保持・書き出し途中失敗を扱う。v1/v2 readerの復活を完了条件にしない。

外部packageはImport / Export専用。sourceの変更・移動・削除・lock、途中失敗時の原本と既存destinationの保持を確認する。通常編集へopen-in-placeを追加しない。

Mac／iPhone／iPadでは日本語IME、Undo、keyboard、VoiceOver、Dynamic Type、Light/Dark、Reduce Transparency、長文、scene／終了を確認する。Windows 11とMSI等の配布は計画段階で、実装・配布受入は別途必要。

## 配布物

Developer ID署名、公証、stapling、Gatekeeper、別Mac／新規userでのinstall・起動・Recoveryを対象配布物で確認する。version、更新、rollback、portable互換、原稿救出、AppIcon・Finder/Dock/Aboutの表示を揃える。

build、conformance、デプロイ、remote head確認、実機受入、公開は別の結果として記録する。設定や過去の成功だけで公開完了にしない。
