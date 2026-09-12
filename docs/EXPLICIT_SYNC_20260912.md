# 明示同期とLANサーバー検証 — 2026-09-12

土台`ec8a42625`、作業branch`codex/explicit-sync-20260912`。利用者は明示同期ボタン、同期実態の確認、不足実装の修正を依頼し、続いて192.168.11.5のSSH操作・必要な修正を許可した。D-091へ判断を記録した。

## 判明したこと

- 送信worker、sealed command、receipt検証、SQLite保存、再試行・競合処理は存在した。一方、明示syncはpending処理再開だけで、outboxが空ならサーバーに接続せずnoChangesを返していた。
- `publish/noChanges`で届くremote descendantは検証保存されても、通常のdocument gate経由の反映待ちとして接続されていなかった。
- Macの実DBを読み取り専用で集計した結果、作品1件、account binding 0、unbound pending intent 1、command/receipt/Inbox 0。本文・タイトル・credentialは読んでいない。この作品は実際にサーバーへ送られていない。
- LANのrole-split構成はedge/server/PostgreSQLともhealthy、restart count 0。SSHログイン成功。auth capabilitiesはTLS経由で成功し、Auth epoch 1 / Sync epoch 2を確認。
- 稼働サーバーのsourceの主要Rust実装・Cargo.lock・Dockerfileは手元とSHA-256一致。DB集計は作品1、Snapshot 0、createWork receipt 1、upload 0、account object 0、conflict 0。過去の作品作成が本文同期完了の証拠ではない。原因をサーバー停止と決めつけない。

## 変更

- Macの「今すぐ同期」を文字付き・常設化。iOS本文画面にも追加し、作品ホームと共通部品にした。
- サインイン／unbound作品のaccount追加への導線を追加。追加時は原本を残すcloneで、確認対象のsession/accountを固定する。利用者の既存作品を今回自動送信していない。
- 両OSの明示syncでIME確定→document gate内local保存→scope再確認→worker再開の順を守る。Macの握り潰した開始エラーを表示し、iOSの開始失敗を一律offline扱いしない。
- 明示syncは未変更でもcheckpoint intentを要求し、既存のsealed publish経路で最新headを照合する。pending/sealed intentがあれば再利用し、再起動後も同じ作業を続ける。unboundは認証要求として拒否する。
- 完了publish receiptとverified Inboxをscope/source generationで結び、安全なfast-forward反映待ちをDBから導出する。反映前にpending intent／local generation／競合を再検査し、既存の消費型document gateからだけinstallする。反映前版を履歴へ保護し、portable resourceもAppへの返り値へ保持する。
- Plannerのcommand payloadを分離し、kernel/workerの責務をextensionへ整理した。wire/DB schemaは変えていない。

## 検証（重たい）

| 対象 | 今回の結果 |
| --- | --- |
| Swift package | 成功、470 tests。変更なし送受信のproduction composition統合test、再起動、二重要求、未接続拒否、receiptなし反映拒否、反映前の追加入力保護を含む |
| macOS app | 成功、142 tests / 30 suites |
| iOS app | 成功、110 tests / 22 suites |
| 通常macOS / generic iOS build | 成功、署名なし |
| Python/Swift conformance | 成功、Python 60 vectors / Swift 6 tests |
| 全体check.sh | MacにcargoがなくRust開始で停止。単一スクリプトの全通し成功とはしない |
| Rust | LANホストのrust:1.93-bookwormで79 tests成功 |
| 実PostgreSQL/HTTP | 新規の隔離DB `fuminiwa_v2_test`でintegration_gateを明示実行し成功。既存DBへtest URLを向けていない |
| 構造・依存境界・network/AI/v2境界・lint | 成功。既存の警告は残る |
| 実アカウント・署名済みMac/iPhone間の往復 | 未実施。実Appleサインインと新ビルドでの受入が必要 |

LANで作成した専用testコンテナ・ネットワーク・cache volume・source一時directoryは終了後に削除。稼働中のserver/config/DB、既存の他test環境、原稿・credentialは変更していない。今回の証拠ではサーバーのデプロイ修正は不要だった。

## 利用時の確認

新ビルドで「今すぐ同期」→必要ならAppleサインイン→もう一度「今すぐ同期」→「アカウントへ追加して同期」。原本を残した同期用作品が開く。その後MacとiPhone双方で同じアカウントを使い、編集→同期→相手側同期で本文を照合する。テスト成功をこの実機受入の代わりにはしない。

GitHub push/PR/mergeは行っていない。週間残高は確認時56%、下限40%を維持した。

## ツールバーoverflowからの設定案内（追補）

macOS通常版のプロット画面で、標準overflow内の「今すぐ同期」を選んでも設定案内が出ず、メニューだけ閉じる状態を再現した。ボタン自身の`confirmationDialog`と一時状態を、作品画面が所有する`ExplicitSyncPresentation`とalertへ移した。作品／account切替による取消と、追加直前のscope照合は維持する。

検証は中ぐらい。変更後のmacOS build成功、macOSアプリテスト142件成功。更新した通常版の画面確認と、Apple認証を含む端末間同期の受入は未実施。サーバー／DB／wireの変更はない。
