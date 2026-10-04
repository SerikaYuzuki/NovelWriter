# FUMINIWA 作業ガイド

日本語小説の執筆アプリ。macOS / iOSはSwiftUI＋EditorKit、通常保存は端末SQLite、同期はSnapshot Sync v2。`.novelpkg`は明示Import / Export用。現行のv2名称を維持する。

## 作業に応じた参照先

| 変更する責務 | 読む場所 |
| --- | --- |
| 設計・依存関係 | [DESIGN](docs/DESIGN.md)、`project.yml`、`NovelKit/Package.swift` |
| 現状・未完了事項 | [CODE_HEALTH](docs/CODE_HEALTH.md) |
| 保存・同期 | [同期概要](docs/SNAPSHOT_SYNC_V2.md)、変更対象の[v2契約](docs/sync/v2/README.md) |
| 認証・削除・backup | [AUTH](docs/AUTH.md)、[自宅サーバー運用](docs/ACCOUNT_RETENTION_OPERATIONS.md) |
| 本文・IME・Undo | [DESIGN 4.3〜4.5](docs/DESIGN.md#43-editorkit)、EditorKitの該当Rulesとテスト |
| 画面 | [STYLE](docs/STYLE.md)、[macOS](docs/TOOLBAR.md)／[iOS](docs/IOS.md) |
| package・出力 | [互換契約](docs/CROSS_PLATFORM.md)、[EXPORT](docs/EXPORT.md) |
| 原稿コピー・AI | [コピー](docs/CLIPBOARD_AI_ASSIST.md)、[AI支援](docs/WRITING_ASSISTANT.md) |
| 方針・判断待ち | [OWNER_DECISIONS](docs/OWNER_DECISIONS.md)、[DECISIONS](docs/DECISIONS.md) |

参照表は入口であり、毎回の通読手順ではない。詳細の一覧は[docs/README](docs/README.md)。

## 保つ境界

- 編集・自動保存・遷移・終了はローカルで完結する。SQLite checkpointを確定してremote workerを再開し、networkを保存の成立条件にしない。通常保存で同期用コピーを増やさない。
- 編集中の本文はEditorKitが所有する。IME中のモデル反映・plugin介入を避け、TextKit 2を使う。公開APIへネイティブtext viewを出さない。
- 作品切替・復元はIME確定→ローカル保存→install。取得時と完了時のWorkID/session/account、世代、document operation gateを守り、古い完了を別作品へ適用しない。読込失敗では原稿を保持する。
- `NovelCore`は依存ゼロ。章・話の順序は配列が正。package内部はNovelStorage、通常保存はv2へ閉じ込める。互換変更はDecision・schema・fixture・該当文書を揃える。
- AIは明示送信する。校正・感想は本文preview、チャットは参照確認を挟まず、選択した本文と依頼ごとの編集範囲を守る。指定範囲内の直接編集は共通編集サービスと永続Undoを通す。キー・HTTP・設定は本文保存から分離する。MCPは初回登録した接続を信頼し、申告範囲を機械的に制限する。原稿コピーは指定範囲のplain text。

## 進め方と完了

開始時にブランチと差分を確認し、現在の土台から作業ブランチを作る。無関係な変更、原稿、DB、`NovelApp 20…/`退避フォルダを保持し、区切りで今回の変更だけをコミットする。廃止実装と過去の全文はGit履歴へ集約する。

依頼範囲の編集、選んだ検証、変更による不具合修正まで続ける。通常の可逆な作業は逐次確認せず進める。新しい製品判断が必要なら根拠・推奨・影響を示し、独立にできる作業を続ける。

| 検証段階（D-086） | 選ぶ目安と実施範囲 |
| --- | --- |
| **検証なし** | 動作を変えない決定済み方針・説明の更新。必要な読取・編集・コミットのみ。テスト・build・lint・リンク検査・追加レビューを行わない |
| **軽い検証** | 局所的な文言・表示・設定。影響を確かめる最小限の差分・表示・小さなテスト等 |
| **中ぐらいの検証** | 単一機能の挙動変更。`./Scripts/check-changed.py`で差分に関係するテストとbuildだけを流す（`--dry-run`で計画表示）。全体の`swift test`や両OSの全App testを足さない。入力変更は該当IME・Undoも確認 |
| **重たい検証** | 保存・migration・互換・認証scope・共有基盤・複数機能・公開準備。`./Scripts/check.sh`と影響する境界。実DB・staging・実機は必要な範囲 |

利用者の明示指定を優先し、行数・拡張子・マージだけで段階を上げない。schema/wireやscript入力を変えるMarkdownは実際の影響で選ぶ。問題が出れば関係する確認へ広げ、十分な結果が得られたら完了へ進む。修正後の再確認は失敗した対象から始め、通った検証を毎回やり直さない。

Xcode projectは`./Scripts/generate-project.sh`で生成する。`project.yml`を編集し、生成project・`.derivedData/`・署名設定・秘密情報をコミットしない。Appleの起動・画面確認には利用可能なXcodeBuildMCPを使う（[開発入口](README.md#aiによる起動画面確認)）。Swiftテストはswift-testing（`@Test`）。

機能を利用可能にするための必要なデプロイは、対象・backup・反映後を確認して進める。Cloudflare有料枠が必要な処理は可能な限り`192.168.11.5`へ置く。GitHubへのpush / PR / merge、実データ削除、価格・法務・販促はその操作の依頼範囲で行い、既存の許可を取り直さない。

完了報告は変更点、検証の「なし／成功／失敗／未実施」、残る制約・判断点を示す。実装、ローカル検証、稼働反映、実機受入、公開完了を区別する。
