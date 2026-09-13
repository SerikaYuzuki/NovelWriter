# FUMINIWA 作業ガイド

ふみにわは日本語小説の執筆アプリ。macOS / iOS は SwiftUI と EditorKit を使い、通常保存は端末内 SQLite、同期は Snapshot Sync v2。`.novelpkg` は明示的な取り込み・書き出しの互換形式である。

## 必要なときに読む

全資料の通読は不要。変更する責務に応じて参照する。

| 作業 | 参照先 |
| --- | --- |
| 設計・モジュール境界を変える | [DESIGN](docs/DESIGN.md) と [DECISIONS](docs/DECISIONS.md) の該当決定 |
| 現行経路、既知の問題、次の実装を調べる | [CODE_HEALTH](docs/CODE_HEALTH.md)、[v2引き継ぎ](docs/SNAPSHOT_SYNC_V2_HANDOFF.md) |
| 保存・同期・認証を変える | [Snapshot Sync v2](docs/SNAPSHOT_SYNC_V2.md)、[v2契約一覧](docs/sync/v2/README.md)、[AUTH](docs/AUTH.md) |
| 本文入力・IME・Undoを変える | [DESIGN 4.3〜4.5](docs/DESIGN.md#43-editorkit) と該当する EditorKit の Rules / 統合テスト |
| 画面・操作を変える | [STYLE](docs/STYLE.md)、macOS は [TOOLBAR](docs/TOOLBAR.md)、iOS は [IOS](docs/IOS.md) |
| package・OS間互換を変える | [CROSS_PLATFORM](docs/CROSS_PLATFORM.md) と NovelStorage の fixture |
| 原稿コピーを変える | [CLIPBOARD_AI_ASSIST](docs/CLIPBOARD_AI_ASSIST.md) |
| その他の資料・履歴を探す | [文書一覧](docs/README.md) |

## 保つ境界

- 通常編集・自動保存・画面遷移・終了はローカルで完結する。SQLite checkpointを先に確定し、remote workerを再開する。ネットワークを待たせず、packageとの二重正本や旧CloudKit/v1へのfallbackを作らない（D-080）。
- 編集中の本文は EditorKit 側が所有する。明示的な話・作品切替を除き、SwiftUI更新から本文を書き戻さない。IME変換中はモデル反映・プラグイン介入をせず、TextKit 2の`textLayoutManager`を使う。公開APIへ`NSTextView` / `UITextView`を出さない（D-005 / D-006）。
- 作品遷移・復元・確認操作は、取得時のWorkID/sessionとdocument operation gateを守る。IME確定→ローカル保存→installの順にし、非同期完了を別作品や別accountへ適用しない。読込失敗を空の新規作品へ置き換えない（D-039 / D-041 / D-084）。
- `NovelCore`は依存ゼロ。実際の依存グラフは`NovelKit/Package.swift`、通常targetの組み込みは`project.yml`を確認する。旧sourceの存在を現行経路の根拠にしない。
- 章・話の順序は配列順だけが正。package内部はNovelStorageへ閉じ込める。互換契約を変える場合はDecision、schema、fixture、関連文書を同じ変更で揃える。
- 原稿コピーはD-094の明示scopeのplain text。通常版AI支援はD-089の明示preview後のOpenAI対応API送信（校正は現在の1話、感想・アドバイスは選択した話）。設定・Keychain・HTTPは本文保存から分離し、自動送信・原稿への自動反映をしない。旧provider研究コードを戻さず、[AI支援](docs/WRITING_ASSISTANT.md)の境界を守る。

## 作業の進め方と完了

開始時にブランチと差分を確認し、今回の土台を保った作業ブランチを作る。現行v2の変更を古いmainへ載せ替えない。無関係な変更・原稿・DB・`NovelApp 20…/`退避フォルダを保持し、区切りで今回の変更だけをコミットする。

依頼された範囲の調査・編集・選択した段階の検証・その変更で起きた不具合修正まで続ける。通常の可逆な作業に逐次確認を挟まない。仕様選択が必要な場合は、根拠・選択肢・推奨・影響を示し、独立に進められる作業を続ける。利用者が決めた方針と残る実装事項は[OWNER_DECISIONS](docs/OWNER_DECISIONS.md)。

検証は編集内容の影響に応じ、以下の4段階から必要なものを選ぶ（D-086）。マージするという理由だけで段階を上げない。

| 段階 | 編集内容の目安 | 実施範囲 |
| --- | --- | --- |
| **検証なし** | 今回のような決定済み方針の文書反映、説明・コメントの整理など、動作を変えない編集 | テスト・build・lint・リンク検査・追加レビューを実行しない。編集に必要な読取と保存・コミットは行う |
| **軽い検証** | 局所的な文言・表示・設定値など、影響が限定される編集 | 関連する差分・表示・lint・小さなテストから、影響を確かめる最小限を選ぶ |
| **中ぐらいの検証** | 単一機能の挙動変更、局所的な不具合修正・リファクタリング | 該当module／機能のテストと必要なtarget build。UI・入力変更なら関係する画面やIME・Undoも確認する |
| **重たい検証** | 保存・migration・互換形式・認証scope・共有基盤・複数機能に及ぶ変更、公開準備 | `./Scripts/check.sh`と影響する境界のconformance・障害復旧等。実DB・staging・実機はその変更に必要な範囲で行う |

ファイル種別や行数だけで選ばず、実際に変わる挙動で決める。schema／wireやscriptの入力に影響するMarkdownは、その影響に応じた段階を使う。段階を決めるだけの追加調査やレビューを目的化しない。選んだ確認で問題が出た場合は影響範囲に応じて広げ、十分な結果が得られたら無関係な検証を繰り返さない。利用者の明示した段階を優先する。結果は「検証なし」「成功」「失敗」「未実施」を区別し、過去の成功を今回の成功として記載しない。

依頼された機能・修正を利用できる状態にするために必要なデプロイは、接続先・バックアップ・反映後の動作を確認し、追加の明示指定や許可を求めず進める。GitHubへのpush / PR / merge、実データ削除はその操作の依頼があるときに行う。既に指定された対象と範囲について同じ許可を取り直さない。価格・法務・販促は明示依頼の範囲で扱う（D-042）。

Xcodeプロジェクトは`./Scripts/generate-project.sh`で生成する。`project.yml`を編集元とし、生成された`FUMINIWA.xcodeproj`、`.derivedData/`、署名設定・秘密情報をコミットしない。Swiftのテストはswift-testing（`@Test`）を使う。

完了報告には変更点、検証結果、残る制約・判断点を記す。コード実装、ローカル検証、staging、実機受入、公開完了はそれぞれの証拠で報告する。
