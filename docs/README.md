# FUMINIWA 文書一覧

**現在のsourceを理解する入口は[DESIGN](DESIGN.md)、既知の問題は[CODE_HEALTH](CODE_HEALTH.md)、同期の進行状況は[v2引き継ぎ](SNAPSHOT_SYNC_V2_HANDOFF.md)。** 必要な項目だけ読み、履歴にある次タスクや完了記録を今の指示へ読み替えない。

## まず選ぶ

| 目的 | 文書 |
| --- | --- |
| 作業ルール | [AGENTS](../AGENTS.md)、Claudeも[共通ガイド](../CLAUDE.md)を使う |
| 製品・開発の概要 | [README](../README.md) |
| モジュール境界と入力・保存契約 | [DESIGN](DESIGN.md) |
| 採択理由・置換関係 | [DECISIONS](DECISIONS.md) |
| 現行source、負債、検証、Git | [CODE_HEALTH](CODE_HEALTH.md) |
| 利用者が選ぶ未決事項 | [OWNER_DECISIONS](OWNER_DECISIONS.md) |
| 不具合・提案・PRを書く | [不具合template](../.github/ISSUE_TEMPLATE/bug_report.md)、[提案template](../.github/ISSUE_TEMPLATE/feature_request.md)、[PR template](../.github/PULL_REQUEST_TEMPLATE.md) |

## 現行の製品要件

| 対象 | 文書 | 状態 |
| --- | --- | --- |
| 見た目と操作 | [STYLE](STYLE.md) | 規約。全画面での達成宣言ではない |
| macOS toolbar | [TOOLBAR](TOOLBAR.md) | 現行接続と製品要件 |
| iOS / iPadOS | [IOS](IOS.md) | 現行routeと未接続・受入待ちを区別 |
| package・Windows | [CROSS_PLATFORM](CROSS_PLATFORM.md) | 互換契約。Windows W0未完了 |
| AI用promptのコピー | [CLIPBOARD_AI_ASSIST](CLIPBOARD_AI_ASSIST.md) | providerなし。iOS入口に残件 |
| 公開・配布の技術Gate | [COMMERCIALIZATION_IMPLEMENTATION](COMMERCIALIZATION_IMPLEMENTATION.md) | 一般公開の受入未完了 |

## 同期v2・認証

| 作業 | 文書 |
| --- | --- |
| 全体契約・実装状況 | [SNAPSHOT_SYNC_V2](SNAPSHOT_SYNC_V2.md)、[HANDOFF](SNAPSHOT_SYNC_V2_HANDOFF.md) |
| wire / schema / fixtureを探す | [sync/v2 README](sync/v2/README.md)、[wire](sync/v2/wire.md)、[entity](sync/v2/entity-contract.md) |
| 状態遷移・表示・mode | [state-machine](sync/v2/state-machine.md)、[ui-state](sync/v2/ui-state.md)、[runtime-mode](sync/v2/runtime-mode.md) |
| 独立した契約検証 | [CONFORMANCE](sync/v2/CONFORMANCE.md) |
| 認証設計・wire | [AUTH](AUTH.md)、[auth/v1 README](auth/v1/README.md)、[Apple通知](auth/v1/apple-notification.md) |
| 認証と同期の接点 | [auth-boundary](sync/v2/auth-boundary.md)、[server認証実装](../SyncServerV2/AUTH_INTEGRATION.md) |
| server・DB・運用 | [SyncServerV2](../SyncServerV2/README.md)、[deployment](sync/v2/deployment.md) |
| LAN staging | [STAGING](SNAPSHOT_SYNC_V2_STAGING.md) |
| 明示的なoffline移行 | [migration](sync/v2/migration.md)、[移行ツール](../Tools/SnapshotSyncV2Migration/README.md) |

Auth wire v1は現在も使う。**Sync v1の凍結とは別**である。契約・実装・fixtureの差を見つけたら、sourceに合わせて規範を黙って緩めず差分として扱う。

## 履歴・比較資料

| 資料 | 読む目的 |
| --- | --- |
| [SNAPSHOT_SYNC](SNAPSHOT_SYNC.md)、[旧HANDOFF](SNAPSHOT_SYNC_HANDOFF.md)、[旧SyncServer](../SyncServer/README.md) | v1の設計・実装経緯。現在の作業順・稼働手順には使わない |
| [sync/v1 README](sync/v1/README.md)、[CONFORMANCE](sync/v1/CONFORMANCE.md)、[errors](sync/v1/errors.md)、[invalid fixture説明](sync/v1/fixtures/canonical-invalid/README.md) | D-080で凍結。今回編集せず保持した契約資料 |
| [DEVICE_SYNC](DEVICE_SYNC.md)、[CLOUDKIT_PRODUCTION_SCHEMA](CLOUDKIT_PRODUCTION_SCHEMA.md) | 廃止したCloudKit / Note / Work / Episode同期の経緯 |
| [D-076-R5-LEGACY-INVENTORY](D-076-R5-LEGACY-INVENTORY.md) | 旧sourceの監査inventory。標準scriptから参照されるため構造を保持 |
| [AI_INTEGRATION](AI_INTEGRATION.md)、[CODEX_SDK_FEASIBILITY_REPORT](CODEX_SDK_FEASIBILITY_REPORT_2026-08-09.md) | D-075以前のprovider / SDK検討。再開時のAPI仕様には使わない |
| Sidecar [MANIFEST](../Sidecars/Codex/MANIFEST.md) / [PROTOCOL](../Sidecars/Codex/PROTOCOL.md) / [SUPERVISOR](../Sidecars/Codex/SUPERVISOR.md) | 削除したsidecarの記録。現行配布物ではない |
| [PHASE4](PHASE4.md)、[PHASE5](PHASE5.md) | 執筆支援・Exportの確定仕様と当時の完了記録。PHASE5の出力契約は現在も参照する |
| [UIDESIGN](UIDESIGN.md)、[UIREFRESH](UIREFRESH.md)、[UIREVISION](UIREVISION.md)、[UIFIX](UIFIX.md)、[UIPOLISH](UIPOLISH.md) | 画面の意図・過去の受入証拠。v2の受入結果へ転用しない |
| [COMMERCIALIZATION_AUDIT_2026-07-19](COMMERCIALIZATION_AUDIT_2026-07-19.md) | 当時の総合監査。現在の不具合・優先順位の一覧ではない |
| [改訂前DESIGN](archive/2026-09-12-DESIGN.md)、[改訂前CODE_HEALTH](archive/2026-09-12-CODE_HEALTH.md)、[製品ガイド旧版一覧](archive/product-guidance-20260912/README.md) | 全面整理前の本文・数値・判断経緯を保全 |

## 文書を更新するとき

[OpenAIの記事「Rethinking skills and prompts for GPT-6 Astra」](https://developers.openai.com/blog/rethinking-skills-and-prompts-for-gpt-6-astra)を参考に、2026-09-12に常時読む指示を短くし、作業別の参照、具体的な完了条件、必要な判断境界へ整理した。

現状の根拠は文書改訂前`32e60bdf6`のsourceである。8月18日の実機・staging記録は過去の証拠として残し、今回の成功へ更新していない。記事の方針は重要なデータ保全・互換・認証契約を省く理由にしない。

- `AGENTS.md`へ全仕様・進捗・巨大な手順を複写しない。taskに必要な詳細への入口を置く。
- 設計・現行実装・検証結果・履歴を区別し、sourceで確認した日時と受入の限界を書く。
- schema / fixtureと結びつく規範は一緒に改訂する。凍結文書は上位の案内から位置づけを示す。
- 製品の判断を伴わない通常の修正を、毎回の承認待ちにしない。新しい選択は選択肢と影響を具体化する。
