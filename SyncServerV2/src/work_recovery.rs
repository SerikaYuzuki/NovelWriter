use crate::{
    application::{parse_command, strict_json},
    domain::*,
    postgres::Repository,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use uuid::Uuid;

#[derive(Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecoveryRequest {
    pub operation_id: Uuid,
    pub snapshot_id: String,
    pub new_work_id: Uuid,
    pub new_document_id: Uuid,
}

impl Repository {
    pub async fn work_protection_status(
        &self,
        p: &AuthenticatedPrincipal,
        work: Uuid,
    ) -> SyncResult<Value> {
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        let deleted: Option<chrono::DateTime<chrono::Utc>> = sqlx::query_scalar(
            "SELECT deleted_at FROM sync_v2.deleted_works WHERE account_id=$1 AND work_id=$2",
        )
        .bind(&p.account_id)
        .bind(work)
        .fetch_optional(&mut *tx)
        .await?;
        let exists: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2)",
        )
        .bind(&p.account_id)
        .bind(work)
        .fetch_one(&mut *tx)
        .await?;
        if deleted.is_none() && !exists {
            return Err(SyncError::NotFound);
        }
        tx.commit().await?;
        Ok(
            json!({"workId":work,"deleted":deleted.is_some(),"deletedAt":deleted.map(|v|v.to_rfc3339()),"result":"noChanges","retentionYears":1}),
        )
    }

    /// Source validation, new root and all three ordinary receipts are one
    /// transaction. No public command kind or snapshot wire format changes.
    pub async fn recover_work(
        &self,
        p: &AuthenticatedPrincipal,
        source: Uuid,
        request: &RecoveryRequest,
    ) -> SyncResult<Value> {
        if source == request.new_work_id {
            return Err(SyncError::SchemaViolation("newWorkId".into()));
        }
        let selected = decode_digest(&request.snapshot_id).map_err(SyncError::SchemaViolation)?;
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        let source_bytes: Vec<u8> = sqlx::query_scalar("SELECT s.manifest_bytes FROM sync_v2.snapshots s JOIN sync_v2.works w USING(account_id,work_id) WHERE s.account_id=$1 AND s.work_id=$2 AND s.snapshot_id=$3 AND w.state='bound' AND NOT EXISTS (SELECT 1 FROM sync_v2.deleted_works d WHERE d.account_id=s.account_id AND d.work_id=s.work_id AND (d.deleted_at AT TIME ZONE 'UTC') + interval '1 year' <= (clock_timestamp() AT TIME ZONE 'UTC'))")
            .bind(&p.account_id).bind(source).bind(selected.as_slice()).fetch_optional(&mut *tx).await?.ok_or(SyncError::NotFound)?;
        if sha256(&source_bytes) != selected {
            return Err(SyncError::SnapshotDigestMismatch);
        }
        let mut manifest = strict_json(&source_bytes)?;
        manifest["workId"] = json!(request.new_work_id);
        manifest["parentSnapshotIds"] = json!([]);
        let entries = manifest["entries"]
            .as_array_mut()
            .ok_or(SyncError::LineageViolation)?;
        for entry in entries {
            let object = digest_field(entry, "objectId").map_err(SyncError::SchemaViolation)?;
            let bytes: Vec<u8> = sqlx::query_scalar("SELECT b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects a USING(object_id) WHERE a.account_id=$1 AND a.object_id=$2 AND a.state='available'")
                .bind(&p.account_id).bind(object.as_slice()).fetch_optional(&mut *tx).await?.ok_or(SyncError::NotFound)?;
            if sha256(&bytes) != object || entry["byteCount"].as_u64() != Some(bytes.len() as u64) {
                return Err(SyncError::ObjectDigestMismatch);
            }
            if entry["entityKey"] == "work/document" {
                let mut document = strict_json(&bytes)?;
                document["documentId"] = json!(request.new_document_id);
                let bytes =
                    canonical_json(&document).map_err(|_| SyncError::InvalidCanonicalBytes)?;
                let digest = sha256(&bytes);
                self.object_store.put(&mut tx, &digest, &bytes).await?;
                sqlx::query("INSERT INTO sync_v2.account_objects(account_id,object_id,state) VALUES($1,$2,'available') ON CONFLICT DO NOTHING")
                    .bind(&p.account_id).bind(digest.as_slice()).execute(&mut *tx).await?;
                entry["objectId"] = json!(hex::encode(digest));
                entry["byteCount"] = json!(bytes.len());
            }
        }
        let root = canonical_json(&manifest).map_err(|_| SyncError::InvalidCanonicalBytes)?;
        let root_id = hex::encode(sha256(&root));
        for (kind, payload) in [
            (
                "createWork",
                json!({"workId":request.new_work_id,"documentId":request.new_document_id}),
            ),
            (
                "registerSnapshot",
                json!({"workId":request.new_work_id,"snapshotId":root_id,"manifestBytesDigest":root_id,"manifestBase64URL":URL_SAFE_NO_PAD.encode(&root)}),
            ),
            (
                "publish",
                json!({"workId":request.new_work_id,"candidateSnapshotId":root_id,"expectedRemoteHead":null}),
            ),
        ] {
            let id_bytes = sha256(format!("recovery:{}:{kind}", request.operation_id).as_bytes());
            let command_id = Uuid::from_bytes(id_bytes[..16].try_into().unwrap());
            let value = json!({"binding":{"accountId":p.account_id,"accountFence":p.account_fence,"serverInstanceId":p.server_instance_id,"protocolEpoch":2},"commandId":command_id,"commandKind":kind,"payload":payload,"schemaVersion":2,"sourceGeneration":1,"sourceSnapshotId":root_id});
            let bytes = canonical_json(&value).map_err(|_| SyncError::InvalidCanonicalBytes)?;
            let cmd = parse_command(&bytes)?;
            self.command_in_transaction(&mut tx, p, &cmd).await?;
        }
        tx.commit().await?;
        Ok(
            json!({"result":"applied","operationId":request.operation_id,"newWorkId":request.new_work_id,"newDocumentId":request.new_document_id,"snapshotId":root_id}),
        )
    }
}
