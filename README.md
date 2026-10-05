# FUMINIWA（ふみにわ）

日本語小説の執筆アプリ。macOS 14 / iOS 17以降、SwiftUIとEditorKitを使う。

## 現在できること

- 章・話と本文・メモ、人物、プロット・伏線、世界観、資料を編集する。
- 端末SQLiteへ自動保存し、Snapshot Sync v2でRust / PostgreSQLへ非同期に複製する。通常の編集・保存はネットワークを待たない。
- `.novelpkg`を明示的にImport / Exportし、配布用原稿をTXT / Markdown / EPUB 3へ書き出す。
- 確認した話をOpenAI対応APIへ明示送信し、校正・感想・アドバイスを利用する。APIキーは端末のKeychainに保存する。
- 自宅サーバーで30日猶予の削除APIと、日次暗号化バックアップの1年保持を運用する。

アカウント削除のアプリ画面、Windows 11版・インストーラー、一般公開の受入は未完了。[残件](docs/CODE_HEALTH.md)を参照。

## 開発

Swift 6対応Xcode、XcodeGen、SwiftFormat、SwiftLint、jq、ripgrep、Python 3、Rust/Cargoを使用する。SwiftLintの要求versionは[構造チェック](Scripts/check-code-structure.sh)に記載。

```sh
./Scripts/generate-project.sh
open FUMINIWA.xcodeproj
```

`FUMINIWA`または`FUMINIWAIOS` schemeを選ぶ。`project.yml`が生成元で、生成物とローカル署名設定はコミットしない。検証は[AGENTS](AGENTS.md)の4段階で選び、中ぐらいの検証は`./Scripts/check-changed.py`、重たい検証は`./Scripts/check.sh`を使う。

## AIによる起動・画面確認

任意の開発ツールとしてXcodeBuildMCP 2.7.0を使う（`npm install -g xcodebuildmcp@2.7.0`）。Codex用接続は`.codex/config.toml`、対象と機能は`.xcodebuildmcp/config.yaml`。設定追加後はCodexのMCPを再読み込みする。接続後に現在のproject・schemeを確認し、必要な実行先を選ぶ。macOS／Simulator／iOS画面操作が有効で、実機操作とdebuggerは必要な作業で設定を追加する。

先に`./Scripts/generate-project.sh`を実行する。既定schemeは`FUMINIWAIOS`。macOSを扱うときは`FUMINIWA`を明示し、iOSの実行先は利用可能なSimulatorから選ぶ。起動・画面確認の補助に使い、検証段階と`check.sh`は従来どおり。

## 入口

[作業ルール](AGENTS.md) · [文書一覧](docs/README.md) · [設計](docs/DESIGN.md) · [現在の決定](docs/DECISIONS.md) · [サーバー](SyncServerV2/README.md)

実装は`NovelApp/`、`NovelAppIOS/`、`NovelKit/`、`SyncServerV2/`。廃止実装と過去の記録はGit履歴で参照する。
