# 保存・同期の作業入口

現行仕様は[Snapshot Sync v2](SNAPSHOT_SYNC_V2.md)、残件は[CODE_HEALTH](CODE_HEALTH.md)、契約は[sync/v2](sync/v2/README.md)。時系列の作業記録はGit履歴とサーバーの運用証跡に集約する。

- 通常保存は端末SQLiteで確定し、その後remote workerを再開する。
- 操作の取得時と完了時にWorkID・session・account・operation gateを照合する。
- 読込失敗を空作品へ置換せず、明示保存・添付・削除も同じ保存境界へ通す。
- DB更新は[deployment](sync/v2/deployment.md)。既存SQL migrationの削除・書換え、稼働DBのreset、旧binaryへの無条件切戻しをしない。
- 削除・backupの稼働状況と復旧制約は[自動運用](ACCOUNT_RETENTION_OPERATIONS.md)。
