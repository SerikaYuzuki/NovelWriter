## 概要

<!-- このPRが何を解決するか、なぜ必要かを簡潔に書く -->

## 変更内容

<!-- 具体的な変更点を箇条書きで -->

-
-

## テスト方法

<!-- どのように動作確認したか。実行したコマンド・手順を書く -->

- [ ] `./Scripts/check.sh`
- [ ] Windows変更時: Windows側ローカル検証スクリプト(W0 / W1で追加)
- [ ] 相互運用変更時: `CompatibilityFixtures/` を検証(Windows reader / writer実装後はmacOS / Windows双方)
- [ ] その他の手動確認:

## チェックリスト

<!-- docs/DESIGN.md 9章「実装ルール」に基づく確認事項 -->

- [ ] 依存方向を守った(`NovelCore` は他モジュールに依存しない。`NovelStorage` / `NovelExport` / `NovelUI` / `EditorKit` → `NovelCore` の一方向。Windows側も同じ意味のproject reference)
- [ ] NovelCore は依存なしのまま(Foundation 以外のフレームワークを import していない)
- [ ] Public API に `NSTextView` / `UITextView` / WinUI型を出していない(OS固有型は各機能の `Platform/` またはWindows側App / Editor projectへ閉じ込めた)
- [ ] 編集中のnative editor本文をモデルから上書きしていない(全置換は話切り替え／EpisodeID変更時のみ。IME変換中は同期・自動介入しない)
- [ ] `.novelpkg` 契約を変えた場合は `docs/CROSS_PLATFORM.md` とgolden fixtureを同時に更新した
- [ ] テストを書いた(または既存テストで担保されていることを確認した)

## 関連Issue / ドキュメント

<!-- 関連するIssue番号や docs/DESIGN.md, docs/DECISIONS.md の該当箇所があればリンク -->
