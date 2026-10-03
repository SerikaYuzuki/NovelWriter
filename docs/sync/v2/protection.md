# 作品保管・別作品復元の追加API

Snapshot Sync v2のmanifest、sealed command、既存DELETE応答は変更しない。以下はAuth v1 sessionと現行v2 scopeヘッダーを要求する追加経路。API応答はv2 JCS media type、Cache-Control: no-store、Pragma: no-cache。旧serverにこの経路がなければ404を「データ利用不可」とし、削除済みと推測しない。

| Method / path | 入出力 |
| --- | --- |
| GET `/v2/protection?after=<UUID>` | `items: [{workId,title,deletedAt: ISO8601|null}]`, `nextAfter: UUID|null`, `result: noChanges`。現在のaccountの同期済み作品と期限内の削除保管作品、UUID昇順500件 |
| GET `/v2/protection/{workId}/status` | `workId`, `deleted: bool`, `deletedAt: ISO8601|null`, `retentionYears: 1`, `result: noChanges`。purge後もtombstoneに基づく削除状態を返す。他account／未知作品は404 |
| GET `/v2/protection/{workId}/history?after=<eventId>` | `items: [{eventId,snapshotId,createdAt}]`, `nextAfter: integer|null`, `result: noChanges`。受領eventId昇順500件。直近7日は各時点、以前は日本時間の各日の最後の時点。編集のない日は作らない |
| POST `/v2/protection/{workId}/recover` | application/json、4 KiB上限。`operationId`, `snapshotId`, `newWorkId`, `newDocumentId`の4項目。UUIDとdigestを検証、unknown field拒否。成功は`result: applied`と上記4項目のうちsnapshotIdを新rootに置き換えた値 |

元WorkIDとsnapshotが同じaccountの保持中graphに属することを検証する。account scope lock下で全objectのdigest/byteCountを確認し、work/documentのDocumentIDだけ置き換え、新WorkID・親なしのmanifestを正規canonicalizationで生成する。既存のcreateWork/registerSnapshot/publishを同一transactionで確定する。新WorkIDは別作品でなければならない。操作IDから安定したcommandIdを生成し、同じ要求の再送では既存receiptを読む。違う新IDで同じ操作IDを再利用すると失敗する。旧graphを上書きしない。

復元画面は未確認の操作IDと新IDを端末に保持し、手動再試行で同じ要求を送る。再起動後の自動送信はしない。成功後は通常の作品一覧から新しい作品を取得する。旧作品の期限切れやaccount削除が先に確定した場合は復元を拒否する。

SQLite側の削除時の救出はremote復元と別操作で、現在のcheckpointを新しいWorkID/DocumentIDへコピーする。bound/parkedの属性やoutboxは継承せず、同期を有効にするには利用者が別途操作する。

本文と別のAI同期データの保管・復元については、その永続化契約を追加するときに拡張する。現時点のこの追加APIは本文snapshot graphを扱う。

検証: PostgreSQL integration gateで保管・再送・期限・共有object・別account・親なし復元・再create拒否を確認。SwiftのStore/Applicationテストで未送信checkpointの保持、unbound救出、再試行のowner/account境界を確認。

閉じた復元request/responseは[JSON Schema](protection.schema.json)、[canonical fixture](fixtures/canonical/protection.json)と独立Python conformanceで照合する。

復旧APIの`Fuminiwa-Device-Label`は内部publishのhistoryへ渡す任意metadata。operation digest／recovery receiptには含めず、replayでは初回値を保つ。
