# 公開に向けた実装・品質Gate

**現況整理: 2026-09-12 / Release NO-GO**

原稿保全、執筆体験、互換性、検証、配布技術の完了条件を追跡する(D-042)。価格、法務、販促、決済、事業運用は明示依頼がない限りこのbacklogへ加えない。設計は [DESIGN.md](DESIGN.md)、直近の実装課題は [v2 handoff](SNAPSHOT_SYNC_V2_HANDOFF.md) を優先する。

## 1. 現在確認できる範囲

| 項目 | ソース・過去証跡で確認できること | 未完了との境界 |
| --- | --- | --- |
| 保存と同期 | Mac／iOSのv2 composition、SQLite checkpoint、Outbox／Inbox、conflict／restore実装 | paired実機・staging read-back・全体Gateは別 |
| macOS UI | 既存Workbench、機能section、v2状態表示、履歴／同期への接続 | 現在の全操作を実機受入済みとはしない |
| iOS UI | 段階route、複数列、各機能View、v2本文Editor | 執筆補助とprompt入口がlive Viewへ未接続。ホーム等に診断UIが残る |
| Apple認証 | 2026-08-18に実iPhoneでsigninと再起動後のsession復元を確認した記録 | 公開認証、account lifecycle、全端末受入とは別 |
| portable形式 | NovelStorageのcodecとv2 portable bridge、関連tests | 完全なPackage Validator、W0、Windows往復は未完了 |
| AI支援 | 共有prompt builderとmacOS copy、iOS側API | providerなし。iOSの全copy入口は未完了 |
| 配布設定 | `project.yml`にHardened Runtime、macOS 14／iOS 17、署名設定あり | 設定の存在は署名済み配布物・公証・clean installの証拠ではない |

今回行ったのはソースと文書の照合。過去の「All checks passed」、旧CloudKitのsource freeze、focused test件数を2026-09-12の実行結果として再掲しない。

## 2. 直近の優先事項

1. 既存のiOS執筆体験をv2へ接続し、作品棚／ホーム／履歴／競合の診断UIを製品UIへ整える。既存の製品要件は [IOS.md](IOS.md) と [STYLE.md](STYLE.md)。
2. signin済み新規作品がlocal-onlyに留まった実機報告を再現し、local checkpoint後の明示account scope・remote登録・head確認までを検証する。任意の既存unbound作品の自動採用で解決しない。
3. 現行commitで標準ローカル検証を通す。handoffのD-076大規模認証ファイルによる停止記録は、最新の分割状態と再実行結果で更新する。
4. 認証済みstaging read-back、Mac↔iPhone往復、offline分岐・3択・履歴／復元・restart・account切替を実機で記録する。

これは実装の依存順であり、公開判断を先取りしない。今回のmd整理ではコード、server、旧データを変更しない。

## 3. Package Validator / W0

packageは通常autosaveの正本ではなくImport／Export境界。以下を [CROSS_PLATFORM.md](CROSS_PLATFORM.md) の共通schema／fixtureへまとめ、既存の部分検証と不足を区別する。

- 全domainのduplicate ID、不正参照、version別必須項目、UUID／ID filename、日時、valid UTF-8。
- symlink／junction／reparse point、package外参照、Windows禁止名、Unicode衝突、depth／file数／byte／path budget。
- 参照されない原稿と非hidden未知resourceの保全、元を直接修復しない検証済み修復コピー。
- Import／Exportの採用前検証とread-back、途中失敗時の元データ・既存destinationの保持。
- v1〜v3の独立fixtureとMac内round-trip。Windows実装後は双方の往復。

missing／invalid UTF-8拒否やportable bridgeのtestsだけでこのGate全体を閉じない。

## 4. 外部変更と復旧

旧計画の「開いたpackageの外部更新検出」は、現在の通常SQLite編集へそのまま適用しない。外部package取込／書出、資料取込のsource変更・移動・削除・lock、失敗時の再試行と原本保全を検証する。open-in-placeを追加するなら保存所有者と競合UIを別Decisionで設計する。

SQLiteはmigration／integrity失敗時に空DBへfallbackせず、backup、restore、process kill、lost response、容量不足の証拠を揃える。remote conflictはv2の単一競合・3択で扱い、復元前候補を保持する。

## 5. 公開前に残る技術Gate

- v2の独立conformance、shared kernel、account／namespace隔離、restart、staging実DB、backup／restore、運用保護。
- Authの失効／refresh／account switch／Apple障害、app内account deletion開始とremote削除完了read-backなど、採択済み契約の公開条件。
- iOS / iPadOSとMacのIME、Undo、keyboard、VoiceOver、Dynamic Type、Light／Dark、Reduce Transparency、長文／大量データ、scene／終了。
- AppIcon、Finder／Dock／About／配布物のブランド表示と実在する機能だけの説明。
- Developer ID署名、公証、stapling、Gatekeeper、cleanな別Mac／新規userでのinstall・起動・Recovery。
- versioning、更新、rollback、旧版とのportable互換、データ保持／救出導線。

conformance成功、build、preview、signin成功、deploy、remote head確認、実機受入、公開の各段階を別に記録する。満たした証拠がない項目は未完了のまま残す。

## 6. 判断が必要になる境界

既存UIの復旧、仕様内の不具合修正、local検証は実装判断として進められる。公開時期／対象platformの優先順を変える、既定のUIや機能を削る、providerを再開する、Windowsの最低対応OS／配布方式を選ぶ場合は利用者の判断を得てDecisionへ記録する。これらを先に決めないと現行の修復が進められない、という扱いにはしない。

## 7. 履歴

[整理前の技術Gate・AI研究証跡の全文](archive/product-guidance-20260912/COMMERCIALIZATION_IMPLEMENTATION.md)、[当時の総合監査](COMMERCIALIZATION_AUDIT_2026-07-19.md)は履歴として保存する。旧Experimental providerはD-075で実装削除済みで、公開Gateの達成や将来APIの採用根拠にはしない。
