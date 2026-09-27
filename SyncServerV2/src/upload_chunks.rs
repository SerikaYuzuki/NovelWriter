use crate::{domain::*, postgres::Repository};
use chrono::Utc;
use sqlx::Row;
use uuid::Uuid;

pub const MAX_UPLOAD_CHUNK_BYTES: usize = 8 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct UploadRange {
    pub start: usize,
    pub end: usize,
    pub total: usize,
}

impl UploadRange {
    pub fn parse(value: &str) -> SyncResult<Self> {
        let parse = || -> Option<Self> {
            let (range, total) = value.strip_prefix("bytes ")?.split_once('/')?;
            let (start, end) = range.split_once('-')?;
            let number = |text: &str| {
                if text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit()) {
                    return None;
                }
                text.parse::<usize>().ok()
            };
            Some(Self {
                start: number(start)?,
                end: number(end)?,
                total: number(total)?,
            })
        };
        let range = parse().ok_or(SyncError::SizeLimitExceeded)?;
        if range.start > range.end
            || range.end >= range.total
            || range.total > MAX_OBJECT_BYTES
            || range.end - range.start + 1 > MAX_UPLOAD_CHUNK_BYTES
        {
            return Err(SyncError::SizeLimitExceeded);
        }
        Ok(range)
    }
}

impl Repository {
    pub async fn upload_chunk(
        &self,
        p: &AuthenticatedPrincipal,
        upload_id: Uuid,
        capability: &str,
        range: UploadRange,
        bytes: &[u8],
    ) -> SyncResult<()> {
        if range.start > range.end
            || range.end >= range.total
            || range.total > MAX_OBJECT_BYTES
            || bytes.len() > MAX_UPLOAD_CHUNK_BYTES
            || range.end - range.start + 1 != bytes.len()
        {
            return Err(SyncError::SizeLimitExceeded);
        }
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        let row = sqlx::query("SELECT object_id,byte_count,account_fence,state,expires_at,command_id,octet_length(partial_bytes) AS received FROM sync_v2.upload_capabilities WHERE account_id=$1 AND upload_id=$2 FOR UPDATE")
            .bind(&p.account_id).bind(upload_id).fetch_optional(&mut *tx).await?.ok_or(SyncError::NotFound)?;
        let command_id: Uuid = row.try_get("command_id")?;
        if row.try_get::<String, _>("account_fence")? != p.account_fence
            || capability
                != upload_capability(&p.account_id, &p.account_fence, upload_id, command_id)
        {
            return Err(SyncError::UploadCapabilityMismatch);
        }
        if row.try_get::<chrono::DateTime<Utc>, _>("expires_at")? <= Utc::now()
            || !matches!(
                row.try_get::<String, _>("state")?.as_str(),
                "prepared" | "uploaded" | "finalized"
            )
        {
            return Err(SyncError::UploadExpired);
        }
        if row.try_get::<i64, _>("byte_count")? != range.total as i64 {
            return Err(SyncError::ObjectDigestMismatch);
        }
        let object: Vec<u8> = row.try_get("object_id")?;
        let state: String = row.try_get("state")?;
        let received = row.try_get::<i32, _>("received")? as usize;
        if state != "prepared" || range.start < received {
            // Lost responses and process restarts may replay exact chunks only.
            let stored: Option<Vec<u8>> = if state != "prepared" {
                sqlx::query_scalar("SELECT substring(raw_bytes FROM $2 FOR $3) FROM sync_v2.global_blobs WHERE object_id=$1")
                    .bind(&object).bind(range.start as i32 + 1).bind(bytes.len() as i32).fetch_optional(&mut *tx).await?
            } else {
                sqlx::query_scalar("SELECT substring(partial_bytes FROM $3 FOR $4) FROM sync_v2.upload_capabilities WHERE account_id=$1 AND upload_id=$2")
                    .bind(&p.account_id).bind(upload_id).bind(range.start as i32 + 1).bind(bytes.len() as i32).fetch_optional(&mut *tx).await?
            };
            if stored.as_deref() != Some(bytes) {
                return Err(SyncError::ObjectDigestMismatch);
            }
            tx.commit().await?;
            return Ok(());
        }
        if range.start != received {
            return Err(SyncError::ObjectDigestMismatch);
        }
        sqlx::query("UPDATE sync_v2.upload_capabilities SET partial_bytes=partial_bytes || $3 WHERE account_id=$1 AND upload_id=$2")
            .bind(&p.account_id).bind(upload_id).bind(bytes).execute(&mut *tx).await?;
        if range.end + 1 == range.total {
            let complete: Vec<u8> = sqlx::query_scalar("SELECT partial_bytes FROM sync_v2.upload_capabilities WHERE account_id=$1 AND upload_id=$2")
                .bind(&p.account_id).bind(upload_id).fetch_one(&mut *tx).await?;
            let object_id: [u8; 32] = object
                .as_slice()
                .try_into()
                .map_err(|_| SyncError::ObjectDigestMismatch)?;
            self.object_store
                .put(&mut tx, &object_id, &complete)
                .await?;
            sqlx::query("UPDATE sync_v2.upload_capabilities SET state='uploaded',partial_bytes='\\x'::bytea WHERE account_id=$1 AND upload_id=$2")
                .bind(&p.account_id).bind(upload_id).execute(&mut *tx).await?;
        }
        tx.commit().await?;
        Ok(())
    }

    pub async fn expire_partial_uploads(&self) -> SyncResult<()> {
        sqlx::query("UPDATE sync_v2.upload_capabilities SET partial_bytes='\\x'::bytea,state='expired' WHERE (account_id,upload_id) IN (SELECT account_id,upload_id FROM sync_v2.upload_capabilities WHERE expires_at<=now() AND octet_length(partial_bytes)>0 LIMIT 100 FOR UPDATE SKIP LOCKED)")
            .execute(&self.pool).await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ranges_reject_overflow_gaps_and_oversized_bodies() {
        assert_eq!(
            UploadRange::parse("bytes 0-2/3").unwrap(),
            UploadRange {
                start: 0,
                end: 2,
                total: 3
            }
        );
        for invalid in [
            "bytes 2-1/3",
            "bytes 0-3/3",
            "bytes 0-8388608/9000000",
            "bytes 0-1/262144001",
            "bytes -1-2/3",
            "bytes 0-1/*",
            "bytes 0-18446744073709551615/2",
        ] {
            assert!(UploadRange::parse(invalid).is_err(), "{invalid}");
        }
    }
}
