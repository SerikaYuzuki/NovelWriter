# Snapshot Sync v2 引き継ぎ

2026-09-13更新。直近の実装・検証・反映状況は[レビュー修正記録](REVIEW_IMPLEMENTATION_20260913.md)。旧タスク一覧は[更新前の記録](archive/2026-09-13-SNAPSHOT_SYNC_V2_HANDOFF-before-review.md)に保存した。履歴中の「次に実装する」を新たな作業指示として扱わない。

## 保つ経路

1. EditorKitでIMEを確定し、作品・session・accountを固定する。
2. document operation gateとsave coordinatorの境界でSQLite checkpointを確定する。
3. remote workerがprepare/upload/finalize/register/publishを進める。ローカル編集はHTTPを待たない。
4. receiptとInboxを検証し、同じscopeで安全に採用できる場合だけ反映する。取得中に編集が増えたら原稿を保持する。

`.novelpkg`は明示Import / Export用。読込失敗を空作品に置換せず、旧CloudKit/v1へfallbackしない。新規作品のbindingと、既存unbound作品の明示cloneは別操作。

## 今回の注意点

- R1は利用者指定で対象外。debounceを「修正漏れ」として追加変更しない。
- Apple通知の確認待ちはremoteだけを一時停止する。同じApple identityの新規ログイン後、以前の確認結果を新sessionへ適用しない。
- uploadの恒久失敗は再起動後も保持し、明示同期で同じtransferを再試行する。分割送信の部分データを完成objectとして扱わない。
- 作品削除待ちのfence更新は同じserver/epoch/accountだけ。別accountへ移さず、古い削除完了を適用しない。
- Mac・iOSとも作品やaccountが変わった後に、保存待ち前の位置や画面pathを適用しない。

## 運用

公開入口は[Cloudflare Tunnel](SNAPSHOT_SYNC_V2_TUNNEL.md)、処理と保存は自宅サーバー `192.168.11.5`。有料Cloudflareサービスを追加する前に自宅サーバーで実現する方式を優先する。

DB更新は[deployment](sync/v2/deployment.md)の対象version・role attestation・backup・復元確認に従う。実行用serverにDDL権限を持たせない。新しいschemaを必要とするserverは、更新前DBでは起動を拒否する。

残る公開運用・Windows互換・実機受入は、それぞれの契約と独立した証拠で完了を判定する。
