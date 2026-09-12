use crate::{domain::*, postgres::Repository};
use uuid::Uuid;

impl Repository {
    /// A single account-locked transaction erases every revision and body reference.
    /// Shared objects stay alive for other works/accounts. Unknown IDs are tombstoned
    /// as well, so retrying deletion after a lost response is harmless and never
    /// permits an in-flight createWork request to recreate the erased identity.
    pub async fn delete_work(&self, p: &AuthenticatedPrincipal, work: Uuid) -> SyncResult<()> {
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        // scope() serializes every command in this account, including createWork.
        sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE")
            .bind(&p.account_id)
            .bind(work)
            .fetch_optional(&mut *tx)
            .await?;
        let objects: Vec<Vec<u8>> = sqlx::query_scalar(
            "SELECT DISTINCT e.object_id FROM sync_v2.snapshot_entries e JOIN sync_v2.snapshots s ON s.account_id=e.account_id AND s.snapshot_id=e.snapshot_id WHERE s.account_id=$1 AND s.work_id=$2
             UNION SELECT object_id FROM sync_v2.upload_capabilities WHERE account_id=$1 AND work_id=$2")
            .bind(&p.account_id).bind(work).fetch_all(&mut *tx).await?;
        sqlx::query("INSERT INTO sync_v2.deleted_works(account_id,work_id,deleted_at) VALUES($1,$2,now()) ON CONFLICT(account_id,work_id) DO NOTHING")
            .bind(&p.account_id).bind(work).execute(&mut *tx).await?;
        // Clear cyclic pointers before removing their targets. All remaining
        // deletes follow the FK graph; constraints remain enabled throughout.
        sqlx::query("UPDATE sync_v2.works SET head_snapshot_id=NULL,head_generation=NULL WHERE account_id=$1 AND work_id=$2")
            .bind(&p.account_id).bind(work).execute(&mut *tx).await?;
        sqlx::query("UPDATE sync_v2.head_events SET command_work_id=NULL,command_scope='deletedOrigin' WHERE account_id=$1 AND command_work_id=$2 AND work_id<>$2 AND command_scope='cloneNewWork'")
            .bind(&p.account_id).bind(work).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM sync_v2.conflict_events WHERE account_id=$1 AND conflict_id IN (SELECT conflict_id FROM sync_v2.active_conflicts WHERE account_id=$1 AND work_id=$2)")
            .bind(&p.account_id).bind(work).execute(&mut *tx).await?;
        for table in [
            "quarantine_records",
            "catalog_events",
            "head_events",
            "restore_receipts",
            "history",
            "conflict_candidates",
            "active_conflicts",
            "upload_capabilities",
            "receipts",
            "sealed_commands",
            "snapshot_parents",
        ] {
            let statement =
                format!("DELETE FROM sync_v2.{table} WHERE account_id=$1 AND work_id=$2");
            sqlx::query(&statement)
                .bind(&p.account_id)
                .bind(work)
                .execute(&mut *tx)
                .await?;
        }
        sqlx::query("DELETE FROM sync_v2.snapshot_entries WHERE account_id=$1 AND snapshot_id IN (SELECT snapshot_id FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2)")
            .bind(&p.account_id).bind(work).execute(&mut *tx).await?;
        sqlx::query("DELETE FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2")
            .bind(&p.account_id)
            .bind(work)
            .execute(&mut *tx)
            .await?;
        sqlx::query("DELETE FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
            .bind(&p.account_id)
            .bind(work)
            .execute(&mut *tx)
            .await?;
        for object in objects {
            sqlx::query("DELETE FROM sync_v2.account_objects a WHERE account_id=$1 AND object_id=$2 AND NOT EXISTS(SELECT 1 FROM sync_v2.snapshot_entries e WHERE e.account_id=a.account_id AND e.object_id=a.object_id) AND NOT EXISTS(SELECT 1 FROM sync_v2.upload_capabilities u WHERE u.account_id=a.account_id AND u.object_id=a.object_id)")
                .bind(&p.account_id).bind(&object).execute(&mut *tx).await?;
            sqlx::query("DELETE FROM sync_v2.global_blobs b WHERE object_id=$1 AND NOT EXISTS(SELECT 1 FROM sync_v2.account_objects a WHERE a.object_id=b.object_id)")
                .bind(&object).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(())
    }
}
