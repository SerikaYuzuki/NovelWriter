use crate::{application::strict_json, domain::*, postgres::Repository};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sqlx::{Postgres, Row, Transaction};
use uuid::Uuid;

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AssistantRecord {
    pub id: Uuid,
    pub work_id: Option<Uuid>,
    pub kind: String,
    pub key: String,
    pub parent_id: Option<Uuid>,
    pub created_at: String,
    pub payload: String,
}

impl AssistantRecord {
    fn bytes(&self) -> SyncResult<Vec<u8>> {
        if DateTime::parse_from_rfc3339(&self.created_at).is_err()
            || !["prompt", "conversation", "message", "request", "edit"]
                .contains(&self.kind.as_str())
            || self.key.is_empty()
            || self.key.len() > 128
            || self.payload.len() > 1_100_000
            || self.work_id.is_none() && self.kind != "prompt"
            || !strict_json(self.payload.as_bytes())?.is_object()
        {
            return Err(SyncError::SchemaViolation("assistantRecord".into()));
        }
        let bytes = canonical_json(
            &serde_json::to_value(self).map_err(|_| SyncError::InvalidCanonicalBytes)?,
        )
        .map_err(|_| SyncError::InvalidCanonicalBytes)?;
        if bytes.len() > 2 * 1024 * 1024 {
            return Err(SyncError::SchemaViolation("assistantRecordTooLarge".into()));
        }
        Ok(bytes)
    }
}

impl Repository {
    pub async fn append_assistant_record(
        &self,
        p: &AuthenticatedPrincipal,
        record: &AssistantRecord,
    ) -> SyncResult<Value> {
        if record.payload.len() > 1_000_000
            && !strict_json(record.payload.as_bytes())?["recoveryProvenance"].is_object()
        {
            return Err(SyncError::SchemaViolation("payloadTooLarge".into()));
        }
        let bytes = record.bytes()?;
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        Self::require_assistant_work(&mut tx, &p.account_id, record.work_id).await?;
        if let Some(row) = sqlx::query("SELECT request_bytes,sequence,conflicted FROM sync_v2.assistant_records WHERE account_id=$1 AND record_id=$2")
            .bind(&p.account_id).bind(record.id).fetch_optional(&mut *tx).await? {
            if row.try_get::<Vec<u8>,_>("request_bytes")? != bytes { return Err(SyncError::CommandIdReused); }
            return Ok(json!({"record":record,"sequence":row.try_get::<i64,_>("sequence")?,"conflicted":row.try_get::<bool,_>("conflicted")?}));
        }
        let latest: Option<Uuid> = if record.kind == "prompt" {
            sqlx::query_scalar("SELECT record_id FROM sync_v2.assistant_records WHERE account_id=$1 AND work_id IS NOT DISTINCT FROM $2 AND kind='prompt' AND record_key=$3 AND NOT conflicted ORDER BY sequence DESC LIMIT 1")
                .bind(&p.account_id).bind(record.work_id).bind(&record.key).fetch_optional(&mut *tx).await?
        } else {
            None
        };
        let conflict = record.kind == "prompt" && latest != record.parent_id;
        let sequence:i64=sqlx::query_scalar("INSERT INTO sync_v2.assistant_records(account_id,record_id,work_id,kind,record_key,parent_id,conflicted,request_bytes) VALUES($1,$2,$3,$4,$5,$6,$7,$8) RETURNING sequence")
            .bind(&p.account_id).bind(record.id).bind(record.work_id).bind(&record.kind).bind(&record.key).bind(record.parent_id).bind(conflict).bind(bytes).fetch_one(&mut *tx).await?;
        tx.commit().await?;
        Ok(json!({"record":record,"sequence":sequence,"conflicted":conflict}))
    }

    pub async fn assistant_record_page(
        &self,
        p: &AuthenticatedPrincipal,
        work: Option<Uuid>,
        after: i64,
    ) -> SyncResult<Value> {
        if after < 0 {
            return Err(SyncError::SchemaViolation("after".into()));
        }
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        Self::require_assistant_work(&mut tx, &p.account_id, work).await?;
        let rows=sqlx::query("SELECT request_bytes,sequence,conflicted FROM sync_v2.assistant_records WHERE account_id=$1 AND work_id IS NOT DISTINCT FROM $2 AND sequence>$3 ORDER BY sequence LIMIT 9")
            .bind(&p.account_id).bind(work).bind(after).fetch_all(&mut *tx).await?;
        let mut items = Vec::new();
        for row in rows.iter().take(8) {
            let bytes: Vec<u8> = row.try_get("request_bytes")?;
            items.push(json!({"record":strict_json(&bytes)?,"sequence":row.try_get::<i64,_>("sequence")?,"conflicted":row.try_get::<bool,_>("conflicted")?}));
        }
        let next = if rows.len() > 8 {
            items.last().map(|v| v["sequence"].clone())
        } else {
            None
        };
        tx.commit().await?;
        Ok(json!({"items":items,"nextAfter":next}))
    }

    async fn require_assistant_work(
        tx: &mut Transaction<'_, Postgres>,
        account: &str,
        work: Option<Uuid>,
    ) -> SyncResult<()> {
        if let Some(work) = work {
            let visible:bool=sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.works w WHERE account_id=$1 AND work_id=$2 AND state='bound' AND NOT EXISTS(SELECT 1 FROM sync_v2.deleted_works d WHERE d.account_id=w.account_id AND d.work_id=w.work_id))")
                .bind(account).bind(work).fetch_one(&mut **tx).await?;
            if !visible {
                return Err(SyncError::NotFound);
            }
        }
        Ok(())
    }

    /// Historical copies contain no executable grants, and are not auto-resumed.
    pub(crate) async fn copy_assistant_records(
        tx: &mut Transaction<'_, Postgres>,
        account: &str,
        source: Uuid,
        destination: Uuid,
        operation: Uuid,
        snapshot: &str,
    ) -> SyncResult<()> {
        let rows=sqlx::query("SELECT record_id,request_bytes,conflicted FROM sync_v2.assistant_records WHERE account_id=$1 AND work_id=$2 ORDER BY sequence")
            .bind(account).bind(source).fetch_all(&mut **tx).await?;
        let new_id = |old: Uuid| {
            let hash = sha256(format!("recovered-assistant:{operation}:{old}").as_bytes());
            Uuid::from_bytes(hash[..16].try_into().unwrap())
        };
        let captured = Utc::now();
        for row in rows {
            let bytes: Vec<u8> = row.try_get("request_bytes")?;
            let mut record: AssistantRecord =
                serde_json::from_slice(&bytes).map_err(|_| SyncError::InvalidCanonicalBytes)?;
            let original_id = record.id;
            record.id = new_id(original_id);
            record.work_id = Some(destination);
            record.parent_id = record.parent_id.map(new_id);
            if ["message", "request", "edit"].contains(&record.kind.as_str()) {
                if let Ok(key) = Uuid::parse_str(&record.key) {
                    record.key = new_id(key).to_string();
                }
            }
            let mut payload = strict_json(record.payload.as_bytes())?;
            for field in ["conversationId", "requestId"] {
                if let Some(old) = payload[field]
                    .as_str()
                    .and_then(|v| Uuid::parse_str(v).ok())
                {
                    payload[field] = json!(new_id(old));
                }
            }
            payload["recoveryProvenance"] = json!({"workId":source,"recordId":original_id,"capturedAt":captured,"bodySnapshotId":snapshot});
            if record.kind == "request" {
                payload["state"] = json!("historical");
            }
            record.payload = String::from_utf8(
                canonical_json(&payload).map_err(|_| SyncError::InvalidCanonicalBytes)?,
            )
            .map_err(|_| SyncError::InvalidCanonicalBytes)?;
            let bytes = record.bytes()?;
            sqlx::query("INSERT INTO sync_v2.assistant_records(account_id,record_id,work_id,kind,record_key,parent_id,conflicted,request_bytes) VALUES($1,$2,$3,$4,$5,$6,$7,$8)")
                .bind(account).bind(record.id).bind(destination).bind(&record.kind).bind(&record.key).bind(record.parent_id).bind(row.try_get::<bool,_>("conflicted")?).bind(bytes).execute(&mut **tx).await?;
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn swift_generated_record_accepts_timestamp_and_canonical_bytes() {
        let bytes = std::env::var("FUMINIWA_ASSISTANT_INTEROP_FIXTURE")
            .map(|path| std::fs::read(path).unwrap())
            .unwrap_or_else(|_| include_bytes!("../../docs/sync/v2/fixtures/canonical/assistant-record.json").to_vec());
        let record: AssistantRecord = serde_json::from_slice(&bytes).unwrap();
        assert!(record.bytes().is_ok());
        let mut invalid = record;
        invalid.created_at = "2026-09-26T03:04:05.123".into();
        assert!(invalid.bytes().is_err());
    }
}
