use crate::domain::{sha256, SyncError, SyncResult, MAX_OBJECT_BYTES};
use async_trait::async_trait;
use sqlx::{PgPool, Postgres, Row, Transaction};

#[async_trait]
pub trait ObjectStore: Send + Sync {
    async fn put(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        object_id: &[u8; 32],
        bytes: &[u8],
    ) -> SyncResult<()>;
    async fn get(&self, account_id: &str, object_id: &[u8; 32]) -> SyncResult<Vec<u8>>;
}

#[derive(Clone)]
pub struct PostgresObjectStore {
    pub pool: PgPool,
}
#[async_trait]
impl ObjectStore for PostgresObjectStore {
    async fn put(
        &self,
        tx: &mut Transaction<'_, Postgres>,
        object_id: &[u8; 32],
        bytes: &[u8],
    ) -> SyncResult<()> {
        if bytes.len() > MAX_OBJECT_BYTES || sha256(bytes) != *object_id {
            return Err(SyncError::ObjectDigestMismatch);
        }
        sqlx::query("INSERT INTO sync_v2.global_blobs(object_id,byte_count,raw_bytes) VALUES($1,$2,$3) ON CONFLICT(object_id) DO NOTHING")
            .bind(object_id.as_slice())
            .bind(bytes.len() as i64)
            .bind(bytes)
            .execute(&mut **tx)
            .await?;
        let stored = sqlx::query(
            "SELECT byte_count,raw_bytes FROM sync_v2.global_blobs WHERE object_id=$1 FOR SHARE",
        )
        .bind(object_id.as_slice())
        .fetch_one(&mut **tx)
        .await?;
        let stored_count: i64 = stored.try_get("byte_count")?;
        let stored_bytes: Vec<u8> = stored.try_get("raw_bytes")?;
        if stored_count != bytes.len() as i64 || stored_bytes.as_slice() != bytes {
            return Err(SyncError::ObjectDigestMismatch);
        }
        Ok(())
    }
    async fn get(&self, account_id: &str, object_id: &[u8; 32]) -> SyncResult<Vec<u8>> {
        let row = sqlx::query("SELECT b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects a ON a.object_id=b.object_id AND a.account_id=$1 WHERE b.object_id=$2 AND a.state='available'")
            .bind(account_id).bind(object_id.as_slice()).fetch_optional(&self.pool).await?;
        row.ok_or(SyncError::NotFound)?
            .try_get("raw_bytes")
            .map_err(SyncError::Database)
    }
}
