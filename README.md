# ふみにわ（FUMINIWA）

ことばを育て、物語を編む。日本語の長編・中編小説を、通信を待たずに書くためのアプリです。

macOSはSwiftUI + `NSTextView`、iOS / iPadOSはSwiftUI + `UITextView`を使います。本文エディタはTextKit 2です。Windows版はWindows 11のみを対象に、WinUI 3 + C# / .NETでの別実装とMSIなどのインストーラー配布を計画しています。

## 現在の状態

2026-09-12にローカルsource（文書改訂前`32e60bdf6`）を確認しました。

- 通常アプリの保存・同期は **SQLite + Snapshot Sync v2** です。端末内の保存後、Rust / PostgreSQLサーバーへ非同期で複製します。旧CloudKit・同期v1は通常targetから外れています。
- `.novelpkg`は作品の取り込み・書き出し用です。通常の自動保存先ではありません。配布用原稿はTXT / Markdown / EPUB 3へ書き出せます。
- 章・話、本文・メモ、人物、プロット・伏線、世界観、資料の実装があります。iOSは主要画面への接続がある一方、旧UIからの復元・操作導線・実機受入に残件があります。
- AI支援は校正／アドバイス用promptのコピーです。アプリ内でAIを実行する機能はありません。iOSの画面導線には未接続箇所があります。
- **一般公開の受入は未完了です。** Apple認証の過去の実機成功と、二端末同期・競合・履歴復元の完了は別です。既知の問題と最新証拠は[v2引き継ぎ](docs/SNAPSHOT_SYNC_V2_HANDOFF.md)にまとめています。

次の作業はv2上の執筆体験と同期の残件を解消し、Mac / iPhoneで確認することです。Windows W0、Package Validator全体、公開・配布のGateは別途残ります。[コードの現状](docs/CODE_HEALTH.md)と[決定済み方針と残る実装事項](docs/OWNER_DECISIONS.md)を参照してください。

## 開発を始める

最低対象はmacOS 14 / iOS 17。Swift 6対応Xcode、SwiftFormat、SwiftLint、XcodeGen、jq、ripgrepを使います。同期のローカル検証にはPython 3とRust/Cargoも必要です。SwiftLintの要求versionは[構造チェック](Scripts/check-code-structure.sh)にあります。

```sh
./Scripts/generate-project.sh
open FUMINIWA.xcodeproj
```

Xcodeで`FUMINIWA`（macOS）か`FUMINIWAIOS`（iOS）を選びます。`project.yml`が生成元です。生成プロジェクトとローカル署名設定はコミットしません。

## 検証

編集内容に応じて「検証なし／軽い／中ぐらい／重たい」を選びます（D-086）。マージ前も一律には全体検証を要求しません。目安は[AGENTS](AGENTS.md)を参照してください。重たい検証で使う全体チェックは次です。

```sh
./Scripts/check.sh
```

全体Gateにはv2 conformance、構造・依存境界、format / lint、NovelKit、macOS、iOSコンパイル・Simulatorテストが含まれます。実PostgreSQL、staging、署名済み実機の検証は別です。現在の既知の失敗は[CODE_HEALTH](docs/CODE_HEALTH.md)を参照してください。

## 文書と構成

| 知りたいこと | 入口 |
| --- | --- |
| AIエージェントで作業する | [AGENTS.md](AGENTS.md) |
| 全体設計・モジュール責務 | [DESIGN](docs/DESIGN.md) |
| 決定理由・変更履歴 | [DECISIONS](docs/DECISIONS.md) |
| 同期v2・認証・サーバー運用 | [v2契約](docs/sync/v2/README.md)、[SyncServerV2](SyncServerV2/README.md) |
| 画面・package・過去の資料 | [文書一覧](docs/README.md) |

実装は`NovelApp/`、`NovelAppIOS/`、共有Swift Packageの`NovelKit/`、`SyncServerV2/`に分かれます。同期v1や旧UIのsourceも比較・移行用に残っているため、ファイルがあるだけでは通常アプリに組み込まれているとは限りません。
