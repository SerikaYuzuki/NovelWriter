# 長い履歴の初回取り込みと検証エラーの改善

2026-09-13。`3dfec9e46`の同期復旧を土台にした追加改善。

## 変更

- HTTP履歴取得の128件制限と再帰呼び出しを除去した。明示的な探索スタックで
  親を先に並べ、共有する親は一度だけ取得する。取得結果の配列を階層ごとにコピーしない。
- 保存済みSnapshotを検証済みの起点として使い、未採用のverified Inboxは親まで検証する
  既存のscope境界を維持する。別Workのmanifestはobject取得前に拒否する。
- objectは同一取得内で再利用する。v2契約のunique object 100,000件の上限を
  objectダウンロード前に検査し、無制限な取り込みにはしない。
- 各探索ステップとobject取得の間でキャンセルを確認する。32版ごとに実行権を譲る。
  全graphが揃い、Inboxを検証してから作品を採用する。途中のgraphは作品として返さない。
- SQLite側のgraph到達性と循環検査も再帰を使わない形へ変更した。
- 既存3ファイルのSwiftFormatエラーを修正した。続けて見つかったSwiftLintの
  3エラーは、競合候補の引数集約、bootstrapのextensionへの移動、テスト用Markdownの
  複数行表記で修正した。検査の無効化やbaselineの追加はしていない。

## 検証

512件の履歴をHTTP fixtureから取得し、空のSQLiteへstage・verify・adoptして
最終版をopenできることを確認した。共有親／objectの重複取得、保存済み履歴の再利用、
検証済み未採用Inbox、キャンセル、object上限も関連テストで確認する。
10,000段の親参照と循環拒否は、保存側の非再帰検査の専用テストで成功した。
既存のwrong-work受信テストはruntime生成、open、resumeでworkerを重複起動し、
receiptMismatchが後続の隔離状態に切り替わる競合があった。runtime生成の一度だけで起動し、
receiptMismatchとsealed commandのquarantine、両作品が不変であることを確認する形へ修正した。
修正後の単独10回連続実行と共通部分502件のテストは成功した。
Macのpost-apply account fenceテストも、resolveServer送信を待ってから疑似応答を
切り替えるようにした。アカウント保護の製品コードは変更せず、関連7テストは成功した。
iOSの即時projectionテストは保存後にworkerが同期中へ進む正常遷移を含め、
localDurabilityがsavedであることを確認するよう修正した。テスト環境名のUUID展開漏れも
修正し、保存場所・設定を各テストで分離した。関連2テストは成功した。
最終の`./Scripts/check.sh`は全段階が成功した。

- 独立conformance、source構造、SwiftFormat、SwiftLint: 成功。既存の警告は残る。
- SwiftPM共通部分: 502件成功。
- iOS compile check: 成功。
- macOS App: 168件成功。
- iOS Simulator EditorKit: 76件成功。
- iOS Simulator App: 135件成功。

途中の失敗は上記のfixture／待ち合わせ修正後に再実行した。
PostgreSQL統合はcheck.shの規定どおり無効。server変更はない。

## 端末反映

macOS／iOSの署名付きRelease buildは成功。Macでは作品一覧への起動と、
既存2作品の「同期済み」を確認した。iPhoneへの更新インストールも成功した。
起動確認は端末ロックで待機中。
更新前に両端末のSQLiteを非公開backupへ保存し、integrity_checkがokであることを確認した。
初回取り込みの受入は隔離HTTP fixtureと空のSQLiteで行い、実端末の作品は削除していない。

## 境界・制約

wire、schema、認証、server、SQLite正本の扱いは変更しない。
件数128の打ち切りはなくなるが、初回は必要な履歴を順に取得するため、通信量と時間は
履歴の量に依存する。全graphを返すAPIと最終Inbox検証は維持しているため、
無制限のメモリ量を保証する変更ではない。初回取得の途中経過を永続化して通信中断位置から
再開する機能は今回追加していない。端末の実データを空にした実験は行わない。
