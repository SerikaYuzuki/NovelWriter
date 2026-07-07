## 概要

<!-- このPRが何を解決するか、なぜ必要かを簡潔に書く -->

## 変更内容

<!-- 具体的な変更点を箇条書きで -->

-
-

## テスト方法

<!-- どのように動作確認したか。実行したコマンド・手順を書く -->

- [ ] `cd NovelKit && swift test`
- [ ] `cd NovelKit && xcodebuild build -scheme NovelKit-Package -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO`
- [ ] その他の手動確認:

## チェックリスト

<!-- docs/DESIGN.md 9章「実装ルール」に基づく確認事項 -->

- [ ] 依存方向を守った(`NovelCore` は他モジュールに依存しない。`NovelStorage` / `NovelUI` / `EditorKit` → `NovelCore` の一方向)
- [ ] NovelCore は依存なしのまま(Foundation 以外のフレームワークを import していない)
- [ ] Public API に `NSTextView` / `UITextView` を出していない(AppKit / UIKit は EditorKit の `Platform/` 配下に閉じ込めた)
- [ ] 編集中に外部から `textStorage` を書き換えていない(テキスト所有権ルール。モデル→View反映は章切り替え時のみ)
- [ ] テストを書いた(または既存テストで担保されていることを確認した)

## 関連Issue / ドキュメント

<!-- 関連するIssue番号や docs/DESIGN.md, docs/DECISIONS.md の該当箇所があればリンク -->
