# 作品の削除と保管（D-092、2026-09-26改訂）

同期した作品の削除は一覧から隠す操作とする。サーバー受領済みの本文・全snapshot・履歴・添付参照を削除日から1暦年保持し、その後graphをpurgeする。未知のWorkIDも同じ成功応答でtombstoneを残し、旧clientの再送や作成で復活しない。期限は最初の削除日時から固定し、2/29の翌年は2/28の同時刻（UTC）。別WorkIDのコピーと共有objectは保持する。アカウント削除確定はこの保管期限より優先する。

端末はSQLiteの`work_deletions`へscope付きintentを先に確定する。以後checkpoint、clone元／先、remote graphのstage/adoptを拒否し、workerを無効化する。編集中の対象はIME確定と保存を済ませ、document gate内で閉じる。HTTPをこのgateで待たない。

未同期のunbound作品は従来どおり端末graphを消去する。bound／remote-only作品は認証scope付き`DELETE /v2/works/{workId}`の200応答（JCS、`result: deleted`と一致するWorkID）を確認した後に完了markerへ移す。端末に未送信の原稿が残る可能性があるため、boundのgraphは救出用に保持する。通常一覧と通常編集からは除外し、復元画面の「この端末の削除時の原稿」から新しいunbound作品へ取り出す。元のWorkIDへ送信を再開しない。

404や通信エラーを成功扱いしない。未完了intentと本文を保持し、起動・接続時のresumePendingで再試行する。別account／fenceに削除完了を適用しない。別端末による削除は専用の[保管API](protection.md)で確認できた場合のみ専用状態として表示する。generic 404から推測しない。編集中の端末内容は消さず、同期ボタンのメニューから新しいローカル作品へ救出できる。

サーバーはaccount scope lockのtransactionで保管へ移し、既存の`deleted_works`で全commandとclone元／先を遮断する。通常catalog/head/history/objectは保管対象を隠す。専用の保管経路だけが参照を許可する。期限後purgeはaccount lock下で期限を再判定し、16件ずつ既存の参照順序で削除する。clone元receipt参照は残るcloneのhead eventから切り離す。再送拒否用tombstoneは残す。新しいDDLは不要で、既存[work-deletion.sql](work-deletion.sql)の同一性を維持する。

未同期作品の端末purgeはimmutable-delete triggerをtransaction内で一時的に外し、commit前に戻す。失敗はDDLを含めrollbackする。削除済みIDからの再表示は抑止する。最後の作品を削除した後の再起動では空の作品一覧を表示する。

保管・purgeは稼働DBの論理的状態を扱う。SQLite WALの旧ページ、日次backup、別offline端末、明示export済みファイルは別の保存物である。サーバー反映状態は[運用記録](../../ACCOUNT_RETENTION_OPERATIONS.md)で確認する。
