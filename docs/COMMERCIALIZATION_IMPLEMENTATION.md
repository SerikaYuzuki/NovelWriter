# 商業化基盤 実装状況

**基準日: 2026-08-08 / 状態: 商業化準備中（公開可能ではない）**

本書は[商業化総合監査](COMMERCIALIZATION_AUDIT_2026-07-19.md)を実装へ落とすための進捗表である。設計の正は[DESIGN.md](DESIGN.md)、個別判断は[DECISIONS.md](DECISIONS.md)を優先する。

## 今回までに実装した範囲

| Gate | 現在の結果 | 境界 |
| --- | --- | --- |
| Brand | 日本語名「ふみにわ」、配布名`FUMINIWA`、bundle ID、Document Type / UTTypeを移行 | `.novelpkg` v1〜v3、NovelKit系名称、legacy toolbar IDは互換資産として維持。商標クリアランスは別途必要 |
| Preference migration | 旧bundle domainからrecent URL、section、Editor設定をallowlistで一度だけ移行 | 新値を上書きせず、旧domainと旧作品を削除・一括移動しない |
| Safe Launch | `loading` / `ready` / `recovery`を分離。読込失敗時は原稿もrecent URLも変更しない | Recoveryは再試行、Finder表示、別作品選択、明示的新規作成を提供 |
| Lifecycle safety | 同時bootstrapを共有Taskへ合流。作品切替・別名保存・資料・snapshotをFIFO化し、古い確認操作をsessionで拒否。切替前にフォーム／IMEを旧作品へ確定してWorkbench変更を止め、終了要求後の作品操作を遮断 | 外部rename／削除、同期・別プロセス競合の検出は後続Gate。待機TaskのcancellationとSave As確定失敗時に残るcopyの案内／cleanupはP2 follow-up |
| Payload integrity | manifest参照の話本文、world参照本文を必須valid UTF-8としてfail-closed。存在するメモもvalid UTF-8を要求 | 空メモのファイル省略は互換仕様として維持。完全なpackage validatorではない |
| Product truth | 実処理のないAI panel、AI状態、`Cmd+J`を出荷UIから撤去 | AIはプライバシー・同意・費用・失敗時挙動を設計してから任意機能として再検討 |
| Native UX | chromeはシステムLight／Darkへ追従。本文キャンバスは独立した利用者設定で既定暗色 | 下部は保存状態、再試行、話／全体文字数、検索不一致だけを示す |
| Explicit save | Fileメニューの`Cmd+S`を`AppState.saveNow()`へ接続 | `ready`な作品だけを自動保存・終了前保存と同じrevision直列化で保存 |
| Build baseline | Hardened Runtimeをproject設定で有効化 | Developer ID署名・公証済み配布物、別Mac検証の完了を意味しない |

## 次の一単位: Package Validator Gate

次はpackageを開く前、保存物を置換する前、修復コピーを採用する前に共通利用できる検証境界を作る。

1. 全domainのduplicate ID、参照先欠損、IDファイル名の不一致を型付きエラーにする
2. package rootと既知pathの各componentでsymlinkを拒否し、package外を読み書きしない
3. 深さ、ファイル数、JSON／本文／添付／総byte数にresource budgetを設ける
4. manifestから参照されない本文・メモ・世界観本文を消さずにinventory化し、隔離または修復コピーへ保全する
5. 元packageを直接修復せず、検証済みの別コピーを作って差分と採用判断を利用者へ示す
6. 一時packageを置換前に検証し、失敗時は既存packageとdirty状態を維持する
7. schemaとgolden / failure fixtureへ統合し、[CROSS_PLATFORM.md](CROSS_PLATFORM.md)のW0残件を同じ契約で前進させる。このGateだけでW0完了とはしない

## 続く一単位: External Change / Conflict Gate

Finderでの移動／削除、同期サービス、別プロセスによる変更を検出し、黙って旧URLへ別作品を再作成したり外部更新を上書きしたりしない。現在作品と外部状態を比較し、状況に応じて再読込、別名保存、競合コピーの保全を利用者が選べるようにする。

## 商業公開までに残る主要Gate

- AppIcon、ロゴ、Finder / Dock / About / DMGを含むブランド視覚品質
- Developer ID署名、公証、stapling、Hardened Runtime、クリーンな別Mac／新規ユーザーでのGatekeeper検証
- 更新機構、versioning、release note、rollback、旧版との文書互換検証
- インストール、初回起動、既存利用者移行、Recovery、アンインストール／データ保持の説明
- アクセシビリティ、キーボード、VoiceOver、Light／Dark、Reduce Transparency、長文／大量データの実機QA
- Privacy Policy、利用規約／EULA、第三者ライセンス、AIを導入する場合のprovider・データ処理条件
- 価格、trial／返金、問い合わせ窓口、障害告知、バックアップ／復旧手順、サポートSLA
- 商標・ドメイン・SNS・配布ストア上の名称確認

これらを通るまでは「販売可能」「原稿を失わない」「Windows互換完了」「AI対応」と表現しない。
