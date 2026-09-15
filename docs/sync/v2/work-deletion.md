# 作品の完全削除（D-092）

macOS作品一覧の「削除…」で対象のタイトルと不可逆性を確認する。ゴミ箱ではなく、この端末と現行サーバーの本文・全snapshot・履歴・添付参照を削除する。別WorkIDのコピーと他作品が共有するobjectは保持する。アカウント削除の30日猶予とは別の操作である。

端末はSQLiteの`work_deletions`へscope付きintentを先に確定する。以後checkpoint、clone元／先、remote graphのstage/adoptを拒否し、workerを無効化する。編集中の対象はローカルdocument gate内で閉じる。HTTPをこのgateで待たない。

未同期のunbound作品は端末だけで完了する。bound／remote-only作品は認証scope付き`DELETE /v2/works/{workId}`の200応答（JCS、`result: deleted`と一致するWorkID）を確認した後に端末graphを一括削除する。404や通信エラーを成功扱いしない。未完了intentと本文は保持し、起動・接続時のresumePendingで再試行する。別account／fenceに完了を適用しない。

サーバーはaccount scope lockのtransactionでgraphを削除し、`deleted_works`にaccount/WorkID/日時だけ残す。全commandとclone先の再利用を拒否する。未知のWorkIDも同じ応答で予約するため、他accountの存在を漏らさない。clone元receiptの参照は残るcloneのhead eventから切り離し、コピー自体は保持する。DDLは[0005相当](work-deletion.sql)、基底postgres.sqlは0001との同一性を維持する。

端末の削除transactionはimmutable-delete triggerを一時的に外してgraphを消し、commit前に元のDDLを戻す。失敗はDDLを含めrollbackする。これは通常編集・GCに削除権限を追加しない。削除済みIDのみを残し、古いcatalog応答からの再表示を抑止する。最後の作品を削除した後の再起動は空の作品一覧で止まり、自動で作品を増やさない。

この処理は稼働DBの論理的削除であり、SQLite WALの旧ページ、運用backup、別のoffline端末や明示export済みファイルの物理消去は保証しない。別端末の同じWorkIDによる再publishはサーバーで拒否する。サーバーのmigration/API反映前は削除を完了扱いせず、端末にデータを残す。

検証: Store graph共有object保持・再起動、Application offline→再起動retry、macOS最後の作品削除、PostgreSQL/HTTPの競合・復元・clone graph／別account保持／再送／再create拒否。

serverのmigration/APIは反映記録がある。現在の稼働状態とschemaは操作時に照合する。[DB更新契約](deployment.md)と[運用証跡](../../ACCOUNT_RETENTION_OPERATIONS.md)を参照。アカウント削除とは独立した機能で、文書更新は実作品の削除を伴わない。
