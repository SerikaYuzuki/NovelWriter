use crate::{
    application::{strict_json, validate_entity_payload, validate_manifest_bytes},
    domain::*,
    object_store::{ObjectStore, PostgresObjectStore},
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::Utc;
use serde_json::Value;
use sqlx::{postgres::PgPoolOptions, PgPool, Postgres, Row, Transaction};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
};
use uuid::Uuid;

const SERVER_NAMESPACE: &str = "fuminiwa-snapshot-sync-v2";
const SCHEMA_VERSION: &str = "2";
const SCHEMA_CHECKSUM: &str = "631b0fed89a0031f33c9ac86b75695309c276d354d31e78b4a0db4eeb39c4657";

#[derive(Clone)]
pub struct Repository {
    pub pool: PgPool,
    pub object_store: Arc<dyn ObjectStore>,
    pub server_instance_id: String,
    pub protocol_epoch: i64,
}
impl Repository {
    pub async fn connect(url: &str, server_instance_id: String) -> Result<Self, sqlx::Error> {
        let pool = PgPoolOptions::new()
            .max_connections(10)
            .connect(url)
            .await?;
        sqlx::migrate!("./migrations").run(&pool).await?;
        Self::verify_server_meta(&pool, &server_instance_id).await?;
        let object_store = Arc::new(PostgresObjectStore { pool: pool.clone() });
        Ok(Self {
            pool,
            object_store,
            server_instance_id,
            protocol_epoch: PROTOCOL_EPOCH,
        })
    }
    async fn verify_server_meta(pool: &PgPool, deployment_id: &str) -> Result<(), sqlx::Error> {
        if deployment_id.is_empty() || deployment_id == "unbound" {
            return Err(sqlx::Error::Protocol(
                "invalid Snapshot Sync v2 deployment id".into(),
            ));
        }
        let mut tx = pool.begin().await?;
        let rows = sqlx::query("SELECT key,value FROM sync_v2.server_meta FOR UPDATE")
            .fetch_all(&mut *tx)
            .await?;
        let metadata: HashMap<String, String> = rows
            .into_iter()
            .map(|row| Ok((row.try_get("key")?, row.try_get("value")?)))
            .collect::<Result<_, sqlx::Error>>()?;
        for (key, expected) in [
            ("namespace", SERVER_NAMESPACE),
            ("protocol_epoch", "2"),
            ("schema_version", SCHEMA_VERSION),
            ("schema_checksum", SCHEMA_CHECKSUM),
        ] {
            if metadata.get(key).map(String::as_str) != Some(expected) {
                return Err(sqlx::Error::Protocol(format!(
                    "Snapshot Sync v2 server_meta mismatch: {key}"
                )));
            }
        }
        let stored_deployment = metadata
            .get("deployment_id")
            .ok_or_else(|| sqlx::Error::Protocol("missing v2 deployment_id".into()))?;
        if stored_deployment == "unbound" {
            let updated = sqlx::query(
                "UPDATE sync_v2.server_meta SET value=$1 WHERE key='deployment_id' AND value='unbound'",
            )
            .bind(deployment_id)
            .execute(&mut *tx)
            .await?;
            if updated.rows_affected() != 1 {
                return Err(sqlx::Error::Protocol(
                    "Snapshot Sync v2 deployment bind lost".into(),
                ));
            }
        } else if stored_deployment != deployment_id {
            return Err(sqlx::Error::Protocol(
                "Snapshot Sync v2 deployment id mismatch".into(),
            ));
        }
        tx.commit().await?;
        Ok(())
    }
    async fn scope<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
    ) -> SyncResult<()> {
        if let Some(row) = sqlx::query("SELECT server_instance_id,protocol_epoch,account_fence FROM sync_v2.account_scopes WHERE account_id=$1 FOR UPDATE")
            .bind(&p.account_id).fetch_optional(&mut **tx).await? {
            let instance: String = row.try_get("server_instance_id")?;
            let epoch: i64 = row.try_get("protocol_epoch")?;
            let fence: String = row.try_get("account_fence")?;
            if instance != p.server_instance_id || epoch != p.protocol_epoch || fence != p.account_fence {
                return Err(SyncError::AccountFenceMismatch);
            }
        } else {
            sqlx::query("INSERT INTO sync_v2.account_scopes(account_id,server_instance_id,protocol_epoch,account_fence) VALUES($1,$2,$3,$4)")
                .bind(&p.account_id).bind(&p.server_instance_id).bind(p.protocol_epoch).bind(&p.account_fence).execute(&mut **tx).await?;
        }
        Ok(())
    }
    async fn receipt_lookup<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
    ) -> SyncResult<Option<(i32, Vec<u8>)>> {
        if let Some(row) = sqlx::query("SELECT command_kind,request_digest,state,response_status,canonical_response FROM sync_v2.receipts WHERE account_id=$1 AND command_id=$2 FOR UPDATE")
            .bind(&p.account_id).bind(cmd.command_id).fetch_optional(&mut **tx).await? {
            let kind: String = row.try_get("command_kind")?;
            let digest: Vec<u8> = row.try_get("request_digest")?;
            return replay_receipt(
                &kind,
                &digest,
                cmd.kind.as_str(),
                &cmd.request_digest,
                row.try_get::<String, _>("state")? == "completed",
                row.try_get("response_status").ok(),
                row.try_get::<Vec<u8>, _>("canonical_response").ok().as_deref(),
            );
        }
        Ok(None)
    }
    async fn seal<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
    ) -> SyncResult<()> {
        sqlx::query("INSERT INTO sync_v2.sealed_commands(account_id,command_id,work_id,account_fence,command_kind,canonical_request,request_digest,source_snapshot_id,source_generation,state) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'sending')")
            .bind(&p.account_id).bind(cmd.command_id).bind(cmd.work_id).bind(&p.account_fence).bind(cmd.kind.as_str()).bind(&cmd.canonical_bytes).bind(cmd.request_digest.as_slice()).bind(cmd.source_snapshot_id.as_slice()).bind(cmd.source_generation).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.receipts(account_id,command_id,work_id,command_kind,request_digest,canonical_request,state) VALUES($1,$2,$3,$4,$5,$6,'reserved')")
            .bind(&p.account_id).bind(cmd.command_id).bind(cmd.work_id).bind(cmd.kind.as_str()).bind(cmd.request_digest.as_slice()).bind(&cmd.canonical_bytes).execute(&mut **tx).await?;
        Ok(())
    }
    async fn verify_read_back<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
        response_bytes: &[u8],
    ) -> SyncResult<()> {
        let response = strict_json(response_bytes)?;
        if canonical_json(&response).map_err(|_| SyncError::Retryable)? != response_bytes {
            return Err(SyncError::Retryable);
        }
        let receipt = response
            .get("receipt")
            .and_then(Value::as_object)
            .ok_or(SyncError::Retryable)?;
        let read_back = receipt
            .get("readBack")
            .and_then(Value::as_object)
            .ok_or(SyncError::Retryable)?;
        if receipt.get("commandId").and_then(Value::as_str)
            != Some(cmd.command_id.to_string().as_str())
            || receipt.get("commandKind").and_then(Value::as_str) != Some(cmd.kind.as_str())
            || receipt.get("workId").and_then(Value::as_str)
                != Some(cmd.work_id.to_string().as_str())
            || receipt.get("requestDigest").and_then(Value::as_str)
                != Some(hex::encode(cmd.request_digest).as_str())
            || [
                "accountMatched",
                "commandDigestMatched",
                "headMatched",
                "resourceMatched",
                "stateMatched",
            ]
            .iter()
            .any(|key| read_back.get(*key).and_then(Value::as_bool) != Some(true))
        {
            return Err(SyncError::Retryable);
        }
        let envelope_matches: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM sync_v2.account_scopes a JOIN sync_v2.sealed_commands s ON s.account_id=a.account_id JOIN sync_v2.receipts r ON r.account_id=s.account_id AND r.command_id=s.command_id WHERE a.account_id=$1 AND a.server_instance_id=$2 AND a.protocol_epoch=$3 AND a.account_fence=$4 AND s.command_id=$5 AND s.work_id=$6 AND s.account_fence=$4 AND s.command_kind=$7 AND s.request_digest=$8 AND s.canonical_request=$9 AND s.state='sending' AND r.work_id=$6 AND r.command_kind=$7 AND r.request_digest=$8 AND r.canonical_request=$9 AND r.state='reserved')",
        )
        .bind(&p.account_id)
        .bind(&p.server_instance_id)
        .bind(p.protocol_epoch)
        .bind(&p.account_fence)
        .bind(cmd.command_id)
        .bind(cmd.work_id)
        .bind(cmd.kind.as_str())
        .bind(cmd.request_digest.as_slice())
        .bind(&cmd.canonical_bytes)
        .fetch_one(&mut **tx)
        .await?;
        if !envelope_matches {
            return Err(SyncError::Retryable);
        }
        self.verify_response_head(tx, p, cmd, &response).await?;
        self.verify_command_resource(tx, p, cmd, &response).await
    }
    async fn verify_response_head<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
        response: &Value,
    ) -> SyncResult<()> {
        let Some(expected) = response.get("head") else {
            return Ok(());
        };
        let work_id = if cmd.kind == CommandKind::CloneWork {
            response
                .get("newWorkId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(SyncError::Retryable)?
        } else {
            cmd.work_id
        };
        let row = sqlx::query(
            "SELECT head_snapshot_id,head_generation FROM sync_v2.works WHERE account_id=$1 AND work_id=$2",
        )
        .bind(&p.account_id)
        .bind(work_id)
        .fetch_optional(&mut **tx)
        .await?
        .ok_or(SyncError::Retryable)?;
        let snapshot: Option<Vec<u8>> = row.try_get("head_snapshot_id")?;
        let generation: Option<i64> = row.try_get("head_generation")?;
        if expected.is_null() {
            if snapshot.is_some() || generation.is_some() {
                return Err(SyncError::Retryable);
            }
            return Ok(());
        }
        let expected_snapshot =
            digest_field(expected, "snapshotId").map_err(|_| SyncError::Retryable)?;
        let expected_generation = expected
            .get("generation")
            .and_then(Value::as_i64)
            .ok_or(SyncError::Retryable)?;
        if snapshot.as_deref() != Some(expected_snapshot.as_slice())
            || generation != Some(expected_generation)
        {
            return Err(SyncError::Retryable);
        }
        Ok(())
    }
    async fn verify_command_resource<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
        response: &Value,
    ) -> SyncResult<()> {
        let payload = &cmd.value["payload"];
        let result = response
            .get("result")
            .and_then(Value::as_str)
            .ok_or(SyncError::Retryable)?;
        let matches = match cmd.kind {
            CommandKind::CreateWork => {
                let document = uuid(payload, "documentId").map_err(|_| SyncError::Retryable)?;
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 AND document_id=$3 AND state='bound')")
                    .bind(&p.account_id).bind(cmd.work_id).bind(document).fetch_one(&mut **tx).await?
            }
            CommandKind::PrepareObject => {
                let object = digest_field(payload, "objectId").map_err(|_| SyncError::Retryable)?;
                if result == "noChanges" {
                    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.account_objects WHERE account_id=$1 AND object_id=$2 AND state='available')")
                        .bind(&p.account_id).bind(object.as_slice()).fetch_one(&mut **tx).await?
                } else {
                    let upload = response
                        .get("uploadId")
                        .and_then(Value::as_str)
                        .and_then(|value| Uuid::parse_str(value).ok())
                        .ok_or(SyncError::Retryable)?;
                    sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.upload_capabilities WHERE account_id=$1 AND upload_id=$2 AND command_id=$3 AND work_id=$4 AND account_fence=$5 AND object_id=$6 AND byte_count=$7 AND state='prepared' AND expires_at>now())")
                        .bind(&p.account_id).bind(upload).bind(cmd.command_id).bind(cmd.work_id).bind(&p.account_fence).bind(object.as_slice()).bind(payload.get("byteCount").and_then(Value::as_i64).ok_or(SyncError::Retryable)?).fetch_one(&mut **tx).await?
                }
            }
            CommandKind::FinalizeObject => {
                let object = digest_field(payload, "objectId").map_err(|_| SyncError::Retryable)?;
                let upload = uuid(payload, "uploadId").map_err(|_| SyncError::Retryable)?;
                let count = payload
                    .get("byteCount")
                    .and_then(Value::as_i64)
                    .ok_or(SyncError::Retryable)?;
                let row = sqlx::query("SELECT b.byte_count,b.raw_bytes FROM sync_v2.upload_capabilities u JOIN sync_v2.account_objects a ON a.account_id=u.account_id AND a.object_id=u.object_id JOIN sync_v2.global_blobs b ON b.object_id=u.object_id WHERE u.account_id=$1 AND u.upload_id=$2 AND u.work_id=$3 AND u.object_id=$4 AND u.byte_count=$5 AND u.state='finalized' AND a.state='available'")
                    .bind(&p.account_id).bind(upload).bind(cmd.work_id).bind(object.as_slice()).bind(count).fetch_optional(&mut **tx).await?;
                if let Some(row) = row {
                    let raw: Vec<u8> = row.try_get("raw_bytes")?;
                    row.try_get::<i64, _>("byte_count")? == count
                        && raw.len() as i64 == count
                        && sha256(&raw) == object
                } else {
                    false
                }
            }
            CommandKind::RegisterSnapshot => {
                let snapshot =
                    digest_field(payload, "snapshotId").map_err(|_| SyncError::Retryable)?;
                let manifest = URL_SAFE_NO_PAD
                    .decode(
                        payload
                            .get("manifestBase64URL")
                            .and_then(Value::as_str)
                            .ok_or(SyncError::Retryable)?,
                    )
                    .map_err(|_| SyncError::Retryable)?;
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3 AND manifest_digest=$3 AND manifest_bytes=$4)")
                    .bind(&p.account_id).bind(cmd.work_id).bind(snapshot.as_slice()).bind(manifest).fetch_one(&mut **tx).await?
            }
            CommandKind::Publish => self.verify_publish_resource(tx, p, cmd, response).await?,
            CommandKind::ResolveDevice | CommandKind::ResolveServer | CommandKind::CloneWork => {
                self.verify_resolution_resource(tx, p, cmd).await?
            }
            CommandKind::Restore => {
                let selected = digest_field(payload, "selectedSnapshotId")
                    .map_err(|_| SyncError::Retryable)?;
                let before = digest_field(&payload["expectedRemoteHead"], "snapshotId")
                    .map_err(|_| SyncError::Retryable)?;
                let result_snapshot =
                    digest_field(payload, "newSnapshotId").map_err(|_| SyncError::Retryable)?;
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.restore_receipts rr JOIN sync_v2.head_events h ON h.account_id=rr.account_id AND h.command_id=rr.command_id AND h.work_id=rr.work_id WHERE rr.account_id=$1 AND rr.command_id=$2 AND rr.work_id=$3 AND rr.selected_snapshot_id=$4 AND rr.pre_restore_snapshot_id=$5 AND rr.result_snapshot_id=$6 AND h.snapshot_id=$6)")
                    .bind(&p.account_id).bind(cmd.command_id).bind(cmd.work_id).bind(selected.as_slice()).bind(before.as_slice()).bind(result_snapshot.as_slice()).fetch_one(&mut **tx).await?
            }
        };
        if !matches {
            return Err(SyncError::Retryable);
        }
        Ok(())
    }
    async fn verify_publish_resource<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
        response: &Value,
    ) -> SyncResult<bool> {
        if response.get("result").and_then(Value::as_str) == Some("conflictPending") {
            let conflict = response
                .get("conflictId")
                .and_then(Value::as_str)
                .and_then(|value| Uuid::parse_str(value).ok())
                .ok_or(SyncError::Retryable)?;
            let revision = response
                .get("conflictRevision")
                .and_then(Value::as_i64)
                .ok_or(SyncError::Retryable)?;
            let candidate = digest_field(&cmd.value["payload"], "candidateSnapshotId")
                .map_err(|_| SyncError::Retryable)?;
            return sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.active_conflicts a JOIN sync_v2.conflict_candidates c ON c.account_id=a.account_id AND c.conflict_id=a.conflict_id AND c.revision=a.current_revision WHERE a.account_id=$1 AND a.work_id=$2 AND a.conflict_id=$3 AND a.current_revision=$4 AND a.source_generation=$5 AND a.state='active' AND c.local_snapshot_id=$6 AND c.source_generation=$5)")
                .bind(&p.account_id).bind(cmd.work_id).bind(conflict).bind(revision).bind(cmd.source_generation).bind(candidate.as_slice()).fetch_one(&mut **tx).await.map_err(SyncError::Database);
        }
        let head = response.get("head").ok_or(SyncError::Retryable)?;
        let snapshot = digest_field(head, "snapshotId").map_err(|_| SyncError::Retryable)?;
        let generation = head
            .get("generation")
            .and_then(Value::as_i64)
            .ok_or(SyncError::Retryable)?;
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.head_events h JOIN sync_v2.history hi ON hi.account_id=h.account_id AND hi.work_id=h.work_id AND hi.snapshot_id=h.snapshot_id JOIN sync_v2.catalog_events c ON c.account_id=h.account_id AND c.work_id=h.work_id AND c.head_generation=h.generation AND c.head_snapshot_id=h.snapshot_id WHERE h.account_id=$1 AND h.work_id=$2 AND h.command_id=$3 AND h.generation=$4 AND h.snapshot_id=$5 AND h.command_kind='publish' AND hi.reason='publish' AND c.event_kind='upsert' AND c.tombstoned=false)")
            .bind(&p.account_id).bind(cmd.work_id).bind(cmd.command_id).bind(generation).bind(snapshot.as_slice()).fetch_one(&mut **tx).await.map_err(SyncError::Database)
    }
    async fn verify_resolution_resource<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
    ) -> SyncResult<bool> {
        let payload = &cmd.value["payload"];
        let conflict = uuid(payload, "conflictId").map_err(|_| SyncError::Retryable)?;
        let revision = payload
            .get("conflictRevision")
            .and_then(Value::as_i64)
            .ok_or(SyncError::Retryable)?;
        let resolved: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.active_conflicts a JOIN sync_v2.conflict_events e ON e.account_id=a.account_id AND e.conflict_id=a.conflict_id AND e.revision=$4 AND e.event_kind='resolved' WHERE a.account_id=$1 AND a.work_id=$2 AND a.conflict_id=$3 AND a.current_revision=$4 AND a.state='resolved')")
            .bind(&p.account_id).bind(cmd.work_id).bind(conflict).bind(revision).fetch_one(&mut **tx).await?;
        if !resolved {
            return Ok(false);
        }
        match cmd.kind {
            CommandKind::ResolveDevice => {
                let chosen = digest_field(payload, "decisionSnapshotId")
                    .map_err(|_| SyncError::Retryable)?;
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.head_events h JOIN sync_v2.history hi ON hi.account_id=h.account_id AND hi.work_id=h.work_id AND hi.snapshot_id=h.snapshot_id WHERE h.account_id=$1 AND h.work_id=$2 AND h.command_id=$3 AND h.snapshot_id=$4 AND h.command_kind='resolveDevice' AND hi.reason='conflictResolution')")
                    .bind(&p.account_id).bind(cmd.work_id).bind(cmd.command_id).bind(chosen.as_slice()).fetch_one(&mut **tx).await.map_err(SyncError::Database)
            }
            CommandKind::ResolveServer => {
                let local = digest_field(payload, "preAdoptionSnapshotId")
                    .map_err(|_| SyncError::Retryable)?;
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.history WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3 AND reason='preAdoptionLocal' AND pinned=true)")
                    .bind(&p.account_id).bind(cmd.work_id).bind(local.as_slice()).fetch_one(&mut **tx).await.map_err(SyncError::Database)
            }
            CommandKind::CloneWork => {
                let new_work = uuid(payload, "newWorkId").map_err(|_| SyncError::Retryable)?;
                let root =
                    digest_field(payload, "newRootSnapshotId").map_err(|_| SyncError::Retryable)?;
                sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.works w JOIN sync_v2.head_events h ON h.account_id=w.account_id AND h.work_id=w.work_id AND h.snapshot_id=w.head_snapshot_id JOIN sync_v2.history hi ON hi.account_id=w.account_id AND hi.work_id=w.work_id AND hi.snapshot_id=w.head_snapshot_id WHERE w.account_id=$1 AND w.work_id=$2 AND w.head_snapshot_id=$3 AND w.head_generation=1 AND h.command_id=$4 AND h.command_scope='cloneNewWork' AND hi.reason='keepBothCloneRoot')")
                    .bind(&p.account_id).bind(new_work).bind(root.as_slice()).bind(cmd.command_id).fetch_one(&mut **tx).await.map_err(SyncError::Database)
            }
            _ => Ok(false),
        }
    }
    async fn verify_completed_receipt<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
        status: i32,
        response: &[u8],
    ) -> SyncResult<()> {
        let matches: bool = sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.sealed_commands s JOIN sync_v2.receipts r ON r.account_id=s.account_id AND r.command_id=s.command_id WHERE s.account_id=$1 AND s.command_id=$2 AND s.work_id=$3 AND s.command_kind=$4 AND s.request_digest=$5 AND s.canonical_request=$6 AND s.state='completed' AND r.work_id=$3 AND r.command_kind=$4 AND r.request_digest=$5 AND r.canonical_request=$6 AND r.response_status=$7 AND r.canonical_response=$8 AND r.completed_at IS NOT NULL AND r.state='completed')")
            .bind(&p.account_id).bind(cmd.command_id).bind(cmd.work_id).bind(cmd.kind.as_str()).bind(cmd.request_digest.as_slice()).bind(&cmd.canonical_bytes).bind(status).bind(response).fetch_one(&mut **tx).await?;
        if !matches {
            return Err(SyncError::Retryable);
        }
        Ok(())
    }
    async fn complete<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
        status: i32,
        bytes: &[u8],
    ) -> SyncResult<()> {
        let receipt = sqlx::query("UPDATE sync_v2.receipts SET response_status=$3,canonical_response=$4,completed_at=$5,state='completed' WHERE account_id=$1 AND command_id=$2 AND work_id=$6 AND command_kind=$7 AND request_digest=$8 AND canonical_request=$9 AND state='reserved'")
            .bind(&p.account_id).bind(cmd.command_id).bind(status).bind(bytes).bind(Utc::now()).bind(cmd.work_id).bind(cmd.kind.as_str()).bind(cmd.request_digest.as_slice()).bind(&cmd.canonical_bytes).execute(&mut **tx).await?;
        let sealed = sqlx::query("UPDATE sync_v2.sealed_commands SET state='completed' WHERE account_id=$1 AND command_id=$2 AND work_id=$3 AND command_kind=$4 AND request_digest=$5 AND canonical_request=$6 AND state='sending'")
            .bind(&p.account_id).bind(cmd.command_id).bind(cmd.work_id).bind(cmd.kind.as_str()).bind(cmd.request_digest.as_slice()).bind(&cmd.canonical_bytes).execute(&mut **tx).await?;
        if receipt.rows_affected() != 1 || sealed.rows_affected() != 1 {
            return Err(SyncError::Retryable);
        }
        Ok(())
    }
    fn response(cmd: &SealedCommand, result: &str, extra: Vec<(String, Value)>) -> Vec<u8> {
        let mut map = serde_json::Map::new();
        map.insert(
            "commandId".into(),
            Value::String(cmd.command_id.to_string()),
        );
        map.insert(
            "commandKind".into(),
            Value::String(cmd.kind.as_str().into()),
        );
        map.insert("result".into(), Value::String(result.into()));
        map.insert(
            "receipt".into(),
            object([
                (
                    "commandId".into(),
                    Value::String(cmd.command_id.to_string()),
                ),
                (
                    "commandKind".into(),
                    Value::String(cmd.kind.as_str().into()),
                ),
                (
                    "requestDigest".into(),
                    Value::String(hex::encode(cmd.request_digest)),
                ),
                ("workId".into(), Value::String(cmd.work_id.to_string())),
                (
                    "readBack".into(),
                    object([
                        ("accountMatched".into(), Value::Bool(true)),
                        ("commandDigestMatched".into(), Value::Bool(true)),
                        ("headMatched".into(), Value::Bool(true)),
                        ("resourceMatched".into(), Value::Bool(true)),
                        ("stateMatched".into(), Value::Bool(true)),
                    ]),
                ),
            ]),
        );
        for (k, v) in extra {
            map.insert(k, v);
        }
        canonical_json(&Value::Object(map)).expect("response is canonical")
    }
    fn head_value(snapshot_id: &[u8], generation: i64) -> Value {
        object([
            ("generation".into(), Value::from(generation)),
            ("snapshotId".into(), Value::String(hex::encode(snapshot_id))),
        ])
    }
    async fn current_head_value<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        work_id: Uuid,
    ) -> SyncResult<Value> {
        let row = sqlx::query(
            "SELECT head_snapshot_id,head_generation FROM sync_v2.works WHERE account_id=$1 AND work_id=$2",
        )
        .bind(&p.account_id)
        .bind(work_id)
        .fetch_one(&mut **tx)
        .await?;
        let snapshot: Option<Vec<u8>> = row.try_get("head_snapshot_id")?;
        let generation: Option<i64> = row.try_get("head_generation")?;
        match (snapshot, generation) {
            (None, None) => Ok(Value::Null),
            (Some(snapshot), Some(generation)) => Ok(Self::head_value(&snapshot, generation)),
            _ => Err(SyncError::Retryable),
        }
    }
    pub async fn command(
        &self,
        p: &AuthenticatedPrincipal,
        cmd: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        if p.protocol_epoch != self.protocol_epoch
            || p.server_instance_id != self.server_instance_id
        {
            return Err(SyncError::ProtocolEpochMismatch);
        }
        let mut tx = self.pool.begin().await?;
        self.scope(&mut tx, p).await?;
        if let Some(r) = self.receipt_lookup(&mut tx, p, cmd).await? {
            tx.commit().await?;
            return Ok(r);
        }
        if cmd.kind != CommandKind::CreateWork {
            self.require_work(&mut tx, p, cmd.work_id).await?;
        } else {
            // sealed_commands has an immediate Work FK. Bootstrap the null-head
            // Work before sealing, in the same transaction, after scope/receipt
            // lookup. A failed command rolls this row back atomically.
            self.create_work_row(&mut tx, p, cmd).await?;
        }
        self.seal(&mut tx, p, cmd).await?;
        let (status, response) = match cmd.kind {
            CommandKind::CreateWork => self.create_work(&mut tx, p, cmd).await?,
            CommandKind::PrepareObject => self.prepare_object(&mut tx, p, cmd).await?,
            CommandKind::FinalizeObject => self.finalize_object(&mut tx, p, cmd).await?,
            CommandKind::RegisterSnapshot => self.register_snapshot(&mut tx, p, cmd).await?,
            CommandKind::Publish => self.publish(&mut tx, p, cmd).await?,
            CommandKind::ResolveDevice | CommandKind::ResolveServer | CommandKind::CloneWork => {
                self.resolve(&mut tx, p, cmd).await?
            }
            CommandKind::Restore => self.restore(&mut tx, p, cmd).await?,
        };
        self.verify_read_back(&mut tx, p, cmd, &response).await?;
        self.complete(&mut tx, p, cmd, status, &response).await?;
        self.verify_completed_receipt(&mut tx, p, cmd, status, &response)
            .await?;
        tx.commit().await?;
        Ok((status, response))
    }
    async fn require_work<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        id: Uuid,
    ) -> SyncResult<()> {
        let exists = sqlx::query(
            "SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE",
        )
        .bind(&p.account_id)
        .bind(id)
        .fetch_optional(&mut **tx)
        .await?;
        exists.map(|_| ()).ok_or(SyncError::NotFound)
    }
    async fn create_work<'a>(
        &self,
        _tx: &mut Transaction<'a, Postgres>,
        _p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let document =
            uuid(&c.value["payload"], "documentId").map_err(SyncError::SchemaViolation)?;
        Ok((
            201,
            Self::response(
                c,
                "applied",
                vec![
                    ("workId".into(), Value::String(c.work_id.to_string())),
                    ("documentId".into(), Value::String(document.to_string())),
                    ("head".into(), Value::Null),
                ],
            ),
        ))
    }
    async fn create_work_row<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<()> {
        let document =
            uuid(&c.value["payload"], "documentId").map_err(SyncError::SchemaViolation)?;
        let existing = sqlx::query(
            "SELECT document_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE",
        )
        .bind(&p.account_id)
        .bind(c.work_id)
        .fetch_optional(&mut **tx)
        .await?;
        if existing.is_some() {
            return Err(SyncError::CommandIdReused);
        }
        sqlx::query("INSERT INTO sync_v2.works(account_id,work_id,document_id,state) VALUES($1,$2,$3,'bound')")
            .bind(&p.account_id)
            .bind(c.work_id)
            .bind(document)
            .execute(&mut **tx)
            .await?;
        Ok(())
    }
    async fn prepare_object<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let object = digest_field(payload, "objectId").map_err(SyncError::SchemaViolation)?;
        let count = payload
            .get("byteCount")
            .and_then(Value::as_i64)
            .ok_or_else(|| SyncError::SchemaViolation("byteCount".into()))?;
        if sqlx::query("SELECT 1 FROM sync_v2.account_objects WHERE account_id=$1 AND object_id=$2 AND state='available'").bind(&p.account_id).bind(object.as_slice()).fetch_optional(&mut **tx).await?.is_some() { return Ok((200,Self::response(c,"noChanges",vec![]))); }
        let upload = Uuid::new_v4();
        let upload_row = sqlx::query("INSERT INTO sync_v2.upload_capabilities(account_id,upload_id,command_id,work_id,account_fence,object_id,byte_count,state,expires_at) VALUES($1,$2,$3,$4,$5,$6,$7,'prepared',now()+interval '15 minutes') RETURNING expires_at")
            .bind(&p.account_id).bind(upload).bind(c.command_id).bind(c.work_id).bind(&p.account_fence).bind(object.as_slice()).bind(count).fetch_one(&mut **tx).await?;
        let expires: chrono::DateTime<Utc> = upload_row.try_get("expires_at")?;
        let capability = upload_capability(&p.account_id, &p.account_fence, upload, c.command_id);
        Ok((
            201,
            Self::response(
                c,
                "applied",
                vec![
                    ("uploadId".into(), Value::String(upload.to_string())),
                    ("uploadCapability".into(), Value::String(capability)),
                    ("objectId".into(), Value::String(hex::encode(object))),
                    ("expiresAt".into(), Value::String(expires.to_rfc3339())),
                ],
            ),
        ))
    }
    async fn finalize_object<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let object = digest_field(payload, "objectId").map_err(SyncError::SchemaViolation)?;
        let upload = uuid(payload, "uploadId").map_err(SyncError::SchemaViolation)?;
        let row=sqlx::query("SELECT object_id,byte_count,state,expires_at,account_fence,work_id,command_id FROM sync_v2.upload_capabilities WHERE account_id=$1 AND upload_id=$2 FOR UPDATE").bind(&p.account_id).bind(upload).fetch_optional(&mut **tx).await?.ok_or(SyncError::NotFound)?;
        if row.try_get::<String, _>("account_fence")? != p.account_fence
            || row.try_get::<Uuid, _>("work_id")? != c.work_id
        {
            return Err(SyncError::UploadCapabilityMismatch);
        }
        let state: String = row.try_get("state")?;
        if state == "expired"
            || row.try_get::<chrono::DateTime<Utc>, _>("expires_at")? <= Utc::now()
        {
            return Err(SyncError::UploadExpired);
        }
        let expected: Vec<u8> = row.try_get("object_id")?;
        if expected != object {
            return Err(SyncError::UploadCapabilityMismatch);
        }
        let count: i64 = row.try_get("byte_count")?;
        let blob =
            sqlx::query("SELECT byte_count,raw_bytes FROM sync_v2.global_blobs WHERE object_id=$1")
                .bind(object.as_slice())
                .fetch_optional(&mut **tx)
                .await?
                .ok_or(SyncError::NotFound)?;
        let actual: i64 = blob.try_get("byte_count")?;
        let bytes: Vec<u8> = blob.try_get("raw_bytes")?;
        if actual != count || sha256(&bytes) != object {
            return Err(SyncError::ObjectDigestMismatch);
        }
        if state != "uploaded" && state != "finalized" {
            return Err(SyncError::UploadCapabilityMismatch);
        }
        sqlx::query("INSERT INTO sync_v2.account_objects(account_id,object_id,state) VALUES($1,$2,'available') ON CONFLICT(account_id,object_id) DO UPDATE SET state='available'").bind(&p.account_id).bind(object.as_slice()).execute(&mut **tx).await?;
        sqlx::query("UPDATE sync_v2.upload_capabilities SET state='finalized' WHERE account_id=$1 AND upload_id=$2").bind(&p.account_id).bind(upload).execute(&mut **tx).await?;
        let head = self.current_head_value(tx, p, c.work_id).await?;
        Ok((
            200,
            Self::response(
                c,
                "applied",
                vec![
                    ("objectId".into(), Value::String(hex::encode(object))),
                    ("byteCount".into(), Value::from(count)),
                    ("head".into(), head),
                ],
            ),
        ))
    }
    async fn register_snapshot<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let id = digest_field(payload, "snapshotId").map_err(SyncError::SchemaViolation)?;
        let expected =
            digest_field(payload, "manifestBytesDigest").map_err(SyncError::SchemaViolation)?;
        let text = payload
            .get("manifestBase64URL")
            .and_then(Value::as_str)
            .ok_or_else(|| SyncError::SchemaViolation("manifestBase64URL".into()))?;
        let bytes = URL_SAFE_NO_PAD
            .decode(text)
            .map_err(|_| SyncError::InvalidCanonicalBytes)?;
        if bytes.len() > MAX_MANIFEST_BYTES || sha256(&bytes) != expected || expected != id {
            return Err(SyncError::SnapshotDigestMismatch);
        };
        let entries = validate_manifest_bytes(&bytes, c.work_id)?;
        let manifest = strict_json(&bytes)?;
        let mut entity_values = HashMap::<String, Value>::new();
        for entry in &entries {
            let blob = sqlx::query("SELECT b.byte_count,b.raw_bytes FROM sync_v2.account_objects a JOIN sync_v2.global_blobs b ON b.object_id=a.object_id WHERE a.account_id=$1 AND a.object_id=$2 AND a.state='available'")
                .bind(&p.account_id).bind(entry.object_id.as_slice()).fetch_optional(&mut **tx).await?.ok_or(SyncError::NotFound)?;
            let count: i64 = blob.try_get("byte_count")?;
            let raw: Vec<u8> = blob.try_get("raw_bytes")?;
            if count != entry.byte_count
                || raw.len() as i64 != entry.byte_count
                || sha256(&raw) != entry.object_id
            {
                return Err(SyncError::ObjectDigestMismatch);
            }
            if entry.content_type != "application/octet-stream" {
                let parsed = strict_json(&raw)?;
                if canonical_json(&parsed).map_err(|_| SyncError::InvalidCanonicalBytes)? != raw {
                    return Err(SyncError::InvalidCanonicalBytes);
                }
                validate_entity_payload(&entry.entity_key, &parsed)?;
                entity_values.insert(entry.entity_key.clone(), parsed);
            }
        }
        for (key, value) in &entity_values {
            let parts: Vec<_> = key.split('/').collect();
            let expected_id = match parts.as_slice() {
                [kind, id]
                    if matches!(*kind, "character" | "plot-card" | "flag" | "world-note") =>
                {
                    Some((id, "id"))
                }
                ["attachment", id, "metadata"] => Some((id, "attachmentId")),
                _ => None,
            };
            if let Some((expected, field)) = expected_id {
                if value.get(field).and_then(Value::as_str) != Some(expected) {
                    return Err(SyncError::LineageViolation);
                }
            }
        }
        let mut expected_keys: HashSet<String> = [
            "work/document",
            "work/title",
            "work/synopsis",
            "work/chapter-order",
            "work/character-order",
            "work/plot-card-order",
            "work/flag-order",
            "work/world-note-order",
            "work/attachment-order",
        ]
        .into_iter()
        .map(str::to_owned)
        .collect();
        let ids_for = |key: &str, values: &HashMap<String, Value>| -> SyncResult<Vec<String>> {
            values
                .get(key)
                .and_then(|value| value.get("ids"))
                .and_then(Value::as_array)
                .ok_or_else(|| SyncError::SchemaViolation(key.into()))
                .map(|ids| {
                    ids.iter()
                        .filter_map(Value::as_str)
                        .map(str::to_owned)
                        .collect()
                })
        };
        let chapter_ids = ids_for("work/chapter-order", &entity_values)?;
        let chapter_set: HashSet<_> = chapter_ids.iter().cloned().collect();
        let mut episode_owners = HashSet::new();
        for chapter in chapter_ids {
            let prefix = format!("chapter/{chapter}");
            expected_keys.insert(format!("{prefix}/title"));
            expected_keys.insert(format!("{prefix}/episode-order"));
            for episode in ids_for(&format!("{prefix}/episode-order"), &entity_values)? {
                if !episode_owners.insert(episode.clone()) {
                    return Err(SyncError::LineageViolation);
                }
                let ep = format!("episode/{episode}");
                expected_keys.insert(format!("{ep}/title"));
                expected_keys.insert(format!("{ep}/body"));
                expected_keys.insert(format!("{ep}/memo"));
            }
        }
        for (order, prefix) in [
            ("work/character-order", "character"),
            ("work/plot-card-order", "plot-card"),
            ("work/flag-order", "flag"),
            ("work/world-note-order", "world-note"),
        ] {
            for id in ids_for(order, &entity_values)? {
                expected_keys.insert(format!("{prefix}/{id}"));
            }
        }
        for id in ids_for("work/attachment-order", &entity_values)? {
            expected_keys.insert(format!("attachment/{id}/metadata"));
            expected_keys.insert(format!("attachment/{id}/bytes"));
        }
        if entries
            .iter()
            .any(|entry| !expected_keys.contains(&entry.entity_key))
            || expected_keys.len() != entries.len()
        {
            return Err(SyncError::LineageViolation);
        }
        for (key, value) in &entity_values {
            if (key.starts_with("plot-card/") || key.starts_with("flag/"))
                && value
                    .get("plantedChapterId")
                    .or_else(|| value.get("chapterId"))
                    .or_else(|| value.get("resolvedChapterId"))
                    .is_some()
            {
                for field in ["chapterId", "plantedChapterId", "resolvedChapterId"] {
                    if let Some(chapter) = value.get(field).and_then(Value::as_str) {
                        if !chapter_set.contains(chapter) {
                            return Err(SyncError::LineageViolation);
                        }
                    }
                }
            }
        }
        for id in ids_for("work/attachment-order", &entity_values)? {
            let metadata = entity_values
                .get(&format!("attachment/{id}/metadata"))
                .ok_or(SyncError::LineageViolation)?;
            let meta_count = metadata
                .get("byteCount")
                .and_then(Value::as_i64)
                .ok_or(SyncError::LineageViolation)?;
            let bytes_entry = entries
                .iter()
                .find(|entry| entry.entity_key == format!("attachment/{id}/bytes"))
                .ok_or(SyncError::LineageViolation)?;
            if meta_count != bytes_entry.byte_count {
                return Err(SyncError::LineageViolation);
            }
        }
        let document_entry = entries
            .iter()
            .find(|entry| entry.entity_key == "work/document")
            .ok_or_else(|| SyncError::SchemaViolation("manifest.work/document".into()))?;
        let document_blob = sqlx::query("SELECT b.raw_bytes FROM sync_v2.account_objects a JOIN sync_v2.global_blobs b ON b.object_id=a.object_id WHERE a.account_id=$1 AND a.object_id=$2 AND a.state='available'")
            .bind(&p.account_id).bind(document_entry.object_id.as_slice()).fetch_one(&mut **tx).await?;
        let document_value = strict_json(&document_blob.try_get::<Vec<u8>, _>("raw_bytes")?)?;
        let document_id = Uuid::parse_str(
            document_value
                .get("documentId")
                .and_then(Value::as_str)
                .unwrap_or(""),
        )
        .map_err(|_| SyncError::LineageViolation)?;
        let work_document =
            sqlx::query("SELECT document_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
                .bind(&p.account_id)
                .bind(c.work_id)
                .fetch_one(&mut **tx)
                .await?
                .try_get::<Uuid, _>("document_id")?;
        if document_id != work_document {
            return Err(SyncError::LineageViolation);
        }
        let head = self.current_head_value(tx, p, c.work_id).await?;
        if let Some(existing) = sqlx::query("SELECT work_id,manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND snapshot_id=$2 FOR UPDATE")
            .bind(&p.account_id).bind(id.as_slice()).fetch_optional(&mut **tx).await? {
            let work: Uuid = existing.try_get("work_id")?;
            let old: Vec<u8> = existing.try_get("manifest_bytes")?;
            if work != c.work_id || old != bytes { return Err(SyncError::SnapshotDigestMismatch); }
            return Ok((200, Self::response(c, "noChanges", vec![("snapshotId".into(), Value::String(hex::encode(id))), ("head".into(), head)])));
        }
        sqlx::query("INSERT INTO sync_v2.snapshots(account_id,work_id,snapshot_id,manifest_bytes,manifest_digest,created_at) VALUES($1,$2,$3,$4,$3,now())")
            .bind(&p.account_id).bind(c.work_id).bind(id.as_slice()).bind(&bytes).execute(&mut **tx).await?;
        let parents = manifest
            .get("parentSnapshotIds")
            .and_then(Value::as_array)
            .ok_or_else(|| SyncError::SchemaViolation("parentSnapshotIds".into()))?;
        for parent in parents {
            let parent_id = decode_digest(
                parent
                    .as_str()
                    .ok_or_else(|| SyncError::SchemaViolation("parentSnapshotIds".into()))?,
            )
            .map_err(SyncError::SchemaViolation)?;
            let parent_exists = sqlx::query("SELECT 1 FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3")
                .bind(&p.account_id).bind(c.work_id).bind(parent_id.as_slice()).fetch_optional(&mut **tx).await?.is_some();
            if !parent_exists {
                return Err(SyncError::LineageViolation);
            }
            sqlx::query("INSERT INTO sync_v2.snapshot_parents(account_id,work_id,snapshot_id,parent_snapshot_id) VALUES($1,$2,$3,$4)")
                .bind(&p.account_id).bind(c.work_id).bind(id.as_slice()).bind(parent_id.as_slice()).execute(&mut **tx).await?;
        }
        for entry in &entries {
            sqlx::query("INSERT INTO sync_v2.snapshot_entries(account_id,snapshot_id,entity_key,object_id,byte_count,content_type) VALUES($1,$2,$3,$4,$5,$6)")
                .bind(&p.account_id).bind(id.as_slice()).bind(&entry.entity_key).bind(entry.object_id.as_slice()).bind(entry.byte_count).bind(&entry.content_type).execute(&mut **tx).await?;
        }
        Ok((
            200,
            Self::response(
                c,
                "applied",
                vec![
                    ("snapshotId".into(), Value::String(hex::encode(id))),
                    ("head".into(), head),
                ],
            ),
        ))
    }
    async fn publish<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let candidate =
            digest_field(payload, "candidateSnapshotId").map_err(SyncError::SchemaViolation)?;
        if sqlx::query(
            "SELECT 1 FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3",
        )
        .bind(&p.account_id)
        .bind(c.work_id)
        .bind(candidate.as_slice())
        .fetch_optional(&mut **tx)
        .await?
        .is_none()
        {
            return Err(SyncError::NotFound);
        }
        let row=sqlx::query("SELECT head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE").bind(&p.account_id).bind(c.work_id).fetch_one(&mut **tx).await?;
        let generation: Option<i64> = row.try_get("head_generation")?;
        let current: Option<Vec<u8>> = row.try_get("head_snapshot_id")?;
        let expected = &payload["expectedRemoteHead"];
        let (expected_id, expected_generation) = if expected.is_null() {
            (None, None)
        } else {
            let id = digest_field(expected, "snapshotId")
                .map_err(SyncError::SchemaViolation)?
                .to_vec();
            let gen = expected
                .get("generation")
                .and_then(Value::as_i64)
                .ok_or_else(|| {
                    SyncError::SchemaViolation("expectedRemoteHead.generation".into())
                })?;
            (Some(id), Some(gen))
        };
        if current != expected_id || generation != expected_generation {
            let remote = current.clone().ok_or(SyncError::StaleHead)?;
            let active = sqlx::query("SELECT conflict_id,current_revision FROM sync_v2.active_conflicts WHERE account_id=$1 AND work_id=$2 AND state='active' FOR UPDATE")
                .bind(&p.account_id).bind(c.work_id).fetch_optional(&mut **tx).await?;
            let (conflict, revision) = if let Some(row) = active {
                let id: Uuid = row.try_get("conflict_id")?;
                let next: i64 = row.try_get::<i64, _>("current_revision")? + 1;
                (id, next)
            } else {
                let id = Uuid::new_v4();
                sqlx::query("INSERT INTO sync_v2.active_conflicts(account_id,conflict_id,work_id,current_revision,source_generation,state) VALUES($1,$2,$3,1,$4,'active')")
                    .bind(&p.account_id).bind(id).bind(c.work_id).bind(c.source_generation).execute(&mut **tx).await?;
                (id, 1)
            };
            sqlx::query("INSERT INTO sync_v2.conflict_candidates(account_id,conflict_id,work_id,revision,base_snapshot_id,local_snapshot_id,remote_snapshot_id,source_generation,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,$8,now())")
                .bind(&p.account_id).bind(conflict).bind(c.work_id).bind(revision).bind(expected_id.as_deref()).bind(candidate.as_slice()).bind(remote.as_slice()).bind(c.source_generation).execute(&mut **tx).await?;
            sqlx::query("UPDATE sync_v2.active_conflicts SET current_revision=$3,source_generation=$4 WHERE account_id=$1 AND conflict_id=$2")
                .bind(&p.account_id).bind(conflict).bind(revision).bind(c.source_generation).execute(&mut **tx).await?;
            sqlx::query("INSERT INTO sync_v2.conflict_events(account_id,conflict_id,revision,event_kind,canonical_event,created_at) VALUES($1,$2,$3,$4,$5,now())")
                .bind(&p.account_id).bind(conflict).bind(revision).bind(if revision == 1 { "created" } else { "revision" }).bind(&c.canonical_bytes).execute(&mut **tx).await?;
            return Ok((
                409,
                Self::response(
                    c,
                    "conflictPending",
                    vec![
                        ("conflictId".into(), Value::String(conflict.to_string())),
                        ("conflictRevision".into(), Value::from(revision)),
                        ("sourceGeneration".into(), Value::from(c.source_generation)),
                        (
                            "head".into(),
                            Self::head_value(&remote, generation.unwrap_or(1)),
                        ),
                    ],
                ),
            ));
        }
        let next = generation.unwrap_or(0) + 1;
        sqlx::query("UPDATE sync_v2.works SET head_snapshot_id=$3,head_generation=$4 WHERE account_id=$1 AND work_id=$2").bind(&p.account_id).bind(c.work_id).bind(candidate.as_slice()).bind(next).execute(&mut **tx).await?;
        let title = sqlx::query("SELECT b.raw_bytes FROM sync_v2.snapshot_entries e JOIN sync_v2.account_objects ao ON ao.account_id=e.account_id AND ao.object_id=e.object_id JOIN sync_v2.global_blobs b ON b.object_id=e.object_id WHERE e.account_id=$1 AND e.snapshot_id=$2 AND e.entity_key='work/title' AND ao.state='available'")
            .bind(&p.account_id).bind(candidate.as_slice()).fetch_optional(&mut **tx).await?
            .and_then(|row| row.try_get::<Vec<u8>, _>("raw_bytes").ok())
            .and_then(|bytes| strict_json(&bytes).ok())
            .and_then(|value| value.get("value").and_then(Value::as_str).map(str::to_owned))
            .unwrap_or_default();
        let occurrence = Uuid::new_v4();
        sqlx::query("INSERT INTO sync_v2.history(account_id,occurrence_id,work_id,snapshot_id,reason,pinned,created_at) VALUES($1,$2,$3,$4,'publish',true,now())")
            .bind(&p.account_id).bind(occurrence).bind(c.work_id).bind(candidate.as_slice()).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.catalog_events(account_id,work_id,event_kind,head_generation,head_snapshot_id,title,tombstoned,created_at) VALUES($1,$2,'upsert',$3,$4,$5,false,now())")
            .bind(&p.account_id).bind(c.work_id).bind(next).bind(candidate.as_slice()).bind(title).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.head_events(account_id,work_id,generation,snapshot_id,command_id,command_work_id,command_kind,command_scope,created_at) VALUES($1,$2,$3,$4,$5,$6,$7,'sameWork',now())").bind(&p.account_id).bind(c.work_id).bind(next).bind(candidate.as_slice()).bind(c.command_id).bind(c.work_id).bind(c.kind.as_str()).execute(&mut **tx).await?;
        Ok((
            200,
            Self::response(
                c,
                "applied",
                vec![
                    ("generation".into(), Value::from(next)),
                    ("snapshotId".into(), Value::String(hex::encode(candidate))),
                    ("head".into(), Self::head_value(candidate.as_slice(), next)),
                ],
            ),
        ))
    }
    async fn resolve<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let conflict = uuid(payload, "conflictId").map_err(SyncError::SchemaViolation)?;
        let revision = payload
            .get("conflictRevision")
            .and_then(Value::as_i64)
            .ok_or(SyncError::SchemaViolation("conflictRevision".into()))?;
        let row = sqlx::query("SELECT work_id,current_revision,source_generation,state FROM sync_v2.active_conflicts WHERE account_id=$1 AND conflict_id=$2 FOR UPDATE")
            .bind(&p.account_id).bind(conflict).fetch_optional(&mut **tx).await?.ok_or(SyncError::NotFound)?;
        if row.try_get::<Uuid, _>("work_id")? != c.work_id {
            return Err(SyncError::NotFound);
        }
        if row.try_get::<String, _>("state")? != "active"
            || row.try_get::<i64, _>("current_revision")? != revision
            || row.try_get::<i64, _>("source_generation")? != c.source_generation
        {
            return Err(SyncError::StaleConflictRevision);
        }
        if c.kind == CommandKind::CloneWork {
            return self.clone_work(tx, p, c, conflict, revision).await;
        }
        let candidate_row = sqlx::query("SELECT base_snapshot_id,local_snapshot_id,remote_snapshot_id FROM sync_v2.conflict_candidates WHERE account_id=$1 AND conflict_id=$2 AND revision=$3")
            .bind(&p.account_id).bind(conflict).bind(revision).fetch_one(&mut **tx).await?;
        let conflict_local: Vec<u8> = candidate_row.try_get("local_snapshot_id")?;
        let conflict_remote: Vec<u8> = candidate_row.try_get("remote_snapshot_id")?;
        let chosen = if c.kind == CommandKind::ResolveDevice {
            let chosen =
                digest_field(payload, "decisionSnapshotId").map_err(SyncError::SchemaViolation)?;
            let local = digest_field(payload, "localCandidateSnapshotId")
                .map_err(SyncError::SchemaViolation)?;
            if local.as_slice() != conflict_local.as_slice() {
                return Err(SyncError::StaleConflictRevision);
            }
            chosen
        } else {
            let chosen =
                digest_field(payload, "remoteSnapshotId").map_err(SyncError::SchemaViolation)?;
            if chosen.as_slice() != conflict_remote.as_slice() {
                return Err(SyncError::StaleConflictRevision);
            }
            chosen
        };
        let expected = if c.kind == CommandKind::ResolveDevice {
            &payload["expectedRemoteHead"]
        } else {
            &Value::Null
        };
        let current = sqlx::query("SELECT head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE").bind(&p.account_id).bind(c.work_id).fetch_one(&mut **tx).await?;
        let generation: i64 = current
            .try_get::<Option<i64>, _>("head_generation")?
            .unwrap_or(0);
        let current_id: Option<Vec<u8>> = current.try_get("head_snapshot_id")?;
        let (expected_id, expected_remote_generation) = if expected.is_null() {
            (None, None)
        } else {
            let expected_generation = expected
                .get("generation")
                .and_then(Value::as_i64)
                .ok_or_else(|| {
                    SyncError::SchemaViolation("expectedRemoteHead.generation".into())
                })?;
            (
                Some(
                    digest_field(expected, "snapshotId")
                        .map_err(SyncError::SchemaViolation)?
                        .to_vec(),
                ),
                Some(expected_generation),
            )
        };
        if c.kind == CommandKind::ResolveServer {
            let expected_current = digest_field(payload, "expectedCurrentSnapshotId")
                .map_err(SyncError::SchemaViolation)?;
            let expected_generation = payload
                .get("expectedLocalGeneration")
                .and_then(Value::as_i64)
                .ok_or_else(|| SyncError::SchemaViolation("expectedLocalGeneration".into()))?;
            if digest_field(payload, "preAdoptionSnapshotId")
                .map_err(SyncError::SchemaViolation)?
                .as_slice()
                != conflict_local.as_slice()
            {
                return Err(SyncError::StaleConflictRevision);
            }
            if expected_generation < 1 {
                return Err(SyncError::SchemaViolation("expectedLocalGeneration".into()));
            }
            // The server head remains the selected remote branch. We only pin
            // the local candidate and resolve the active conflict; the client
            // installs remote bytes after its local-generation CAS boundary.
            if current_id.as_deref() != Some(conflict_remote.as_slice())
                || chosen.as_slice() != conflict_remote.as_slice()
            {
                return Err(SyncError::StaleHead);
            }
            let occurrence = Uuid::new_v4();
            sqlx::query("INSERT INTO sync_v2.history(account_id,occurrence_id,work_id,snapshot_id,reason,pinned,created_at) VALUES($1,$2,$3,$4,'preAdoptionLocal',true,now())")
                .bind(&p.account_id).bind(occurrence).bind(c.work_id).bind(expected_current.as_slice()).execute(&mut **tx).await?;
            sqlx::query("UPDATE sync_v2.active_conflicts SET state='resolved' WHERE account_id=$1 AND conflict_id=$2")
                .bind(&p.account_id).bind(conflict).execute(&mut **tx).await?;
            sqlx::query("INSERT INTO sync_v2.conflict_events(account_id,conflict_id,revision,event_kind,canonical_event,created_at) VALUES($1,$2,$3,'resolved',$4,now())")
                .bind(&p.account_id).bind(conflict).bind(revision).bind(&c.canonical_bytes).execute(&mut **tx).await?;
            return Ok((
                200,
                Self::response(
                    c,
                    "applied",
                    vec![
                        ("conflictId".into(), Value::String(conflict.to_string())),
                        ("conflictRevision".into(), Value::from(revision)),
                        (
                            "remoteSnapshotId".into(),
                            Value::String(hex::encode(&conflict_remote)),
                        ),
                        ("remoteGeneration".into(), Value::from(generation)),
                        (
                            "head".into(),
                            Self::head_value(&conflict_remote, generation),
                        ),
                    ],
                ),
            ));
        }
        if c.kind == CommandKind::ResolveDevice
            && (current_id != expected_id || Some(generation) != expected_remote_generation)
        {
            return Err(SyncError::StaleHead);
        }
        if sqlx::query(
            "SELECT 1 FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3",
        )
        .bind(&p.account_id)
        .bind(c.work_id)
        .bind(chosen.as_slice())
        .fetch_optional(&mut **tx)
        .await?
        .is_none()
        {
            return Err(SyncError::NotFound);
        }
        if c.kind == CommandKind::ResolveDevice {
            let decision = sqlx::query("SELECT manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3")
                .bind(&p.account_id).bind(c.work_id).bind(chosen.as_slice()).fetch_one(&mut **tx).await?;
            let decision_bytes: Vec<u8> = decision.try_get("manifest_bytes")?;
            let decision_manifest = strict_json(&decision_bytes)?;
            let parents = decision_manifest
                .get("parentSnapshotIds")
                .and_then(Value::as_array)
                .ok_or(SyncError::LineageViolation)?;
            let mut parent_ids: Vec<[u8; 32]> = parents
                .iter()
                .map(|parent| {
                    decode_digest(parent.as_str().ok_or(SyncError::LineageViolation)?)
                        .map_err(|_| SyncError::LineageViolation)
                })
                .collect::<Result<_, _>>()?;
            parent_ids.sort();
            let mut expected_parents = [conflict_remote.as_slice(), conflict_local.as_slice()];
            expected_parents.sort();
            if parent_ids.len() != 2
                || parent_ids[0].as_slice() != expected_parents[0]
                || parent_ids[1].as_slice() != expected_parents[1]
            {
                return Err(SyncError::LineageViolation);
            }
        }
        let next = generation + 1;
        sqlx::query("UPDATE sync_v2.works SET head_snapshot_id=$3,head_generation=$4 WHERE account_id=$1 AND work_id=$2").bind(&p.account_id).bind(c.work_id).bind(chosen.as_slice()).bind(next).execute(&mut **tx).await?;
        let occurrence = Uuid::new_v4();
        sqlx::query("INSERT INTO sync_v2.history(account_id,occurrence_id,work_id,snapshot_id,reason,pinned,created_at) VALUES($1,$2,$3,$4,'conflictResolution',true,now())").bind(&p.account_id).bind(occurrence).bind(c.work_id).bind(chosen.as_slice()).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.head_events(account_id,work_id,generation,snapshot_id,command_id,command_work_id,command_kind,command_scope,created_at) VALUES($1,$2,$3,$4,$5,$2,$6,'sameWork',now())").bind(&p.account_id).bind(c.work_id).bind(next).bind(chosen.as_slice()).bind(c.command_id).bind(c.kind.as_str()).execute(&mut **tx).await?;
        sqlx::query("UPDATE sync_v2.active_conflicts SET state='resolved' WHERE account_id=$1 AND conflict_id=$2").bind(&p.account_id).bind(conflict).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.conflict_events(account_id,conflict_id,revision,event_kind,canonical_event,created_at) VALUES($1,$2,$3,'resolved',$4,now())").bind(&p.account_id).bind(conflict).bind(revision).bind(&c.canonical_bytes).execute(&mut **tx).await?;
        Ok((
            200,
            Self::response(
                c,
                "applied",
                vec![
                    ("conflictId".into(), Value::String(conflict.to_string())),
                    ("conflictRevision".into(), Value::from(revision)),
                    ("generation".into(), Value::from(next)),
                    ("snapshotId".into(), Value::String(hex::encode(chosen))),
                    ("head".into(), Self::head_value(chosen.as_slice(), next)),
                ],
            ),
        ))
    }

    async fn clone_work<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
        conflict: Uuid,
        revision: i64,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let new_work = uuid(payload, "newWorkId").map_err(SyncError::SchemaViolation)?;
        let new_document = uuid(payload, "newDocumentId").map_err(SyncError::SchemaViolation)?;
        let source_snapshot = digest_field(payload, "localCandidateSnapshotId")
            .map_err(SyncError::SchemaViolation)?;
        let expected_head = &payload["expectedOriginalHead"];
        let original = sqlx::query("SELECT head_generation,head_snapshot_id,document_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE").bind(&p.account_id).bind(c.work_id).fetch_one(&mut **tx).await?;
        let original_generation: Option<i64> = original.try_get("head_generation")?;
        let current: Option<Vec<u8>> = original.try_get("head_snapshot_id")?;
        let expected = if expected_head.is_null() {
            if original_generation.is_some() {
                return Err(SyncError::StaleHead);
            }
            None
        } else {
            let expected_generation = expected_head
                .get("generation")
                .and_then(Value::as_i64)
                .ok_or_else(|| {
                    SyncError::SchemaViolation("expectedOriginalHead.generation".into())
                })?;
            if Some(expected_generation) != original_generation {
                return Err(SyncError::StaleHead);
            }
            Some(
                digest_field(expected_head, "snapshotId")
                    .map_err(SyncError::SchemaViolation)?
                    .to_vec(),
            )
        };
        if current != expected {
            return Err(SyncError::StaleHead);
        }
        if sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
            .bind(&p.account_id)
            .bind(new_work)
            .fetch_optional(&mut **tx)
            .await?
            .is_some()
        {
            return Err(SyncError::CommandIdReused);
        }
        let source = sqlx::query("SELECT manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3").bind(&p.account_id).bind(c.work_id).bind(source_snapshot.as_slice()).fetch_optional(&mut **tx).await?.ok_or(SyncError::NotFound)?;
        let source_bytes: Vec<u8> = source.try_get("manifest_bytes")?;
        let mut manifest: Value =
            serde_json::from_slice(&source_bytes).map_err(|_| SyncError::SnapshotDigestMismatch)?;
        manifest["workId"] = Value::String(new_work.to_string());
        manifest["parentSnapshotIds"] = Value::Array(Vec::new());
        if let Some(entries) = manifest.get_mut("entries").and_then(Value::as_array_mut) {
            for entry in entries {
                if entry.get("entityKey").and_then(Value::as_str) == Some("work/document") {
                    let object_id =
                        digest_field(entry, "objectId").map_err(SyncError::SchemaViolation)?;
                    let blob = sqlx::query(
                        "SELECT raw_bytes FROM sync_v2.global_blobs WHERE object_id=$1",
                    )
                    .bind(object_id.as_slice())
                    .fetch_optional(&mut **tx)
                    .await?
                    .ok_or(SyncError::NotFound)?;
                    let mut doc: Value =
                        serde_json::from_slice(&blob.try_get::<Vec<u8>, _>("raw_bytes")?)
                            .map_err(|_| SyncError::SnapshotDigestMismatch)?;
                    doc["documentId"] = Value::String(new_document.to_string());
                    let doc_bytes =
                        canonical_json(&doc).map_err(|_| SyncError::SnapshotDigestMismatch)?;
                    let new_object = sha256(&doc_bytes);
                    sqlx::query("INSERT INTO sync_v2.global_blobs(object_id,byte_count,raw_bytes) VALUES($1,$2,$3) ON CONFLICT DO NOTHING").bind(new_object.as_slice()).bind(doc_bytes.len() as i64).bind(&doc_bytes).execute(&mut **tx).await?;
                    sqlx::query("INSERT INTO sync_v2.account_objects(account_id,object_id,state) VALUES($1,$2,'available') ON CONFLICT DO NOTHING").bind(&p.account_id).bind(new_object.as_slice()).execute(&mut **tx).await?;
                    entry["objectId"] = Value::String(hex::encode(new_object));
                    entry["byteCount"] = Value::from(doc_bytes.len() as i64);
                }
            }
        }
        let root_bytes =
            canonical_json(&manifest).map_err(|_| SyncError::SnapshotDigestMismatch)?;
        let root_id = sha256(&root_bytes);
        let requested_root =
            digest_field(payload, "newRootSnapshotId").map_err(SyncError::SchemaViolation)?;
        if root_id != requested_root {
            return Err(SyncError::SnapshotDigestMismatch);
        };
        sqlx::query("INSERT INTO sync_v2.works(account_id,work_id,document_id,state,head_snapshot_id,head_generation) VALUES($1,$2,$3,'bound',$4,1)").bind(&p.account_id).bind(new_work).bind(new_document).bind(root_id.as_slice()).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.snapshots(account_id,work_id,snapshot_id,manifest_bytes,manifest_digest,created_at) VALUES($1,$2,$3,$4,$3,now())").bind(&p.account_id).bind(new_work).bind(root_id.as_slice()).bind(&root_bytes).execute(&mut **tx).await?;
        let root_entries = validate_manifest_bytes(&root_bytes, new_work)?;
        let source_entries = sqlx::query("SELECT entity_key,object_id,byte_count,content_type FROM sync_v2.snapshot_entries WHERE account_id=$1 AND snapshot_id=$2 ORDER BY entity_key")
            .bind(&p.account_id).bind(source_snapshot.as_slice()).fetch_all(&mut **tx).await?;
        if source_entries.len() != root_entries.len() {
            return Err(SyncError::LineageViolation);
        }
        for row in source_entries {
            let key: String = row.try_get("entity_key")?;
            let root_entry = root_entries
                .iter()
                .find(|entry| entry.entity_key == key)
                .ok_or(SyncError::LineageViolation)?;
            sqlx::query("INSERT INTO sync_v2.snapshot_entries(account_id,snapshot_id,entity_key,object_id,byte_count,content_type) VALUES($1,$2,$3,$4,$5,$6)")
                .bind(&p.account_id).bind(root_id.as_slice()).bind(&key).bind(root_entry.object_id.as_slice()).bind(root_entry.byte_count).bind(&root_entry.content_type).execute(&mut **tx).await?;
        }
        let original_occurrence = Uuid::new_v4();
        let clone_occurrence = Uuid::new_v4();
        sqlx::query("INSERT INTO sync_v2.history(account_id,occurrence_id,work_id,snapshot_id,reason,pinned,created_at) VALUES($1,$2,$3,$4,'conflictResolution',true,now()),($1,$5,$6,$4,'keepBothCloneRoot',true,now())").bind(&p.account_id).bind(original_occurrence).bind(c.work_id).bind(source_snapshot.as_slice()).bind(clone_occurrence).bind(new_work).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.head_events(account_id,work_id,generation,snapshot_id,command_id,command_work_id,command_kind,command_scope,created_at) VALUES($1,$2,1,$3,$4,$5,'cloneWork','cloneNewWork',now())").bind(&p.account_id).bind(new_work).bind(root_id.as_slice()).bind(c.command_id).bind(c.work_id).execute(&mut **tx).await?;
        sqlx::query("UPDATE sync_v2.active_conflicts SET state='resolved' WHERE account_id=$1 AND conflict_id=$2").bind(&p.account_id).bind(conflict).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.conflict_events(account_id,conflict_id,revision,event_kind,canonical_event,created_at) VALUES($1,$2,$3,'resolved',$4,now())").bind(&p.account_id).bind(conflict).bind(revision).bind(&c.canonical_bytes).execute(&mut **tx).await?;
        Ok((
            200,
            Self::response(
                c,
                "applied",
                vec![
                    ("conflictId".into(), Value::String(conflict.to_string())),
                    ("conflictRevision".into(), Value::from(revision)),
                    ("newWorkId".into(), Value::String(new_work.to_string())),
                    (
                        "newRootSnapshotId".into(),
                        Value::String(hex::encode(root_id)),
                    ),
                    ("head".into(), Self::head_value(root_id.as_slice(), 1)),
                ],
            ),
        ))
    }
    async fn restore<'a>(
        &self,
        tx: &mut Transaction<'a, Postgres>,
        p: &AuthenticatedPrincipal,
        c: &SealedCommand,
    ) -> SyncResult<(i32, Vec<u8>)> {
        let payload = &c.value["payload"];
        let selected =
            digest_field(payload, "selectedSnapshotId").map_err(SyncError::SchemaViolation)?;
        let new_id = digest_field(payload, "newSnapshotId").map_err(SyncError::SchemaViolation)?;
        let expected_current = digest_field(payload, "expectedCurrentSnapshotId")
            .map_err(SyncError::SchemaViolation)?;
        let row = sqlx::query("SELECT head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2 FOR UPDATE").bind(&p.account_id).bind(c.work_id).fetch_one(&mut **tx).await?;
        let generation = row
            .try_get::<Option<i64>, _>("head_generation")?
            .ok_or(SyncError::StaleHead)?;
        let current = row
            .try_get::<Option<Vec<u8>>, _>("head_snapshot_id")?
            .ok_or(SyncError::StaleHead)?;
        if expected_current != c.source_snapshot_id {
            return Err(SyncError::StaleHead);
        }
        let expected_local_generation = payload
            .get("expectedLocalGeneration")
            .and_then(Value::as_i64)
            .ok_or_else(|| SyncError::SchemaViolation("expectedLocalGeneration".into()))?;
        if expected_local_generation != c.source_generation {
            return Err(SyncError::StaleHead);
        }
        let expected_remote = payload
            .get("expectedRemoteHead")
            .filter(|value| value.is_object())
            .ok_or(SyncError::StaleHead)?;
        let expected_remote_snapshot =
            digest_field(expected_remote, "snapshotId").map_err(SyncError::SchemaViolation)?;
        let expected_remote_generation = expected_remote
            .get("generation")
            .and_then(Value::as_i64)
            .ok_or_else(|| SyncError::SchemaViolation("expectedRemoteHead.generation".into()))?;
        if current.as_slice() != expected_remote_snapshot.as_slice()
            || generation != expected_remote_generation
        {
            return Err(SyncError::StaleHead);
        }
        let selected_row=sqlx::query("SELECT manifest_bytes FROM sync_v2.snapshots WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3").bind(&p.account_id).bind(c.work_id).bind(selected.as_slice()).fetch_optional(&mut **tx).await?.ok_or(SyncError::NotFound)?;
        let selected_bytes: Vec<u8> = selected_row.try_get("manifest_bytes")?;
        let mut manifest: Value = serde_json::from_slice(&selected_bytes)
            .map_err(|_| SyncError::SnapshotDigestMismatch)?;
        manifest["workId"] = Value::String(c.work_id.to_string());
        let mut parent_ids = [hex::encode(current.as_slice()), hex::encode(selected)];
        parent_ids.sort();
        manifest["parentSnapshotIds"] =
            Value::Array(parent_ids.into_iter().map(Value::String).collect());
        let bytes = canonical_json(&manifest).map_err(|_| SyncError::SnapshotDigestMismatch)?;
        if sha256(&bytes) != new_id {
            return Err(SyncError::SnapshotDigestMismatch);
        };
        sqlx::query("INSERT INTO sync_v2.snapshots(account_id,work_id,snapshot_id,manifest_bytes,manifest_digest,created_at) VALUES($1,$2,$3,$4,$3,now())").bind(&p.account_id).bind(c.work_id).bind(new_id.as_slice()).bind(&bytes).execute(&mut **tx).await?;
        let selected_entries = sqlx::query("SELECT entity_key,object_id,byte_count,content_type FROM sync_v2.snapshot_entries WHERE account_id=$1 AND snapshot_id=$2 ORDER BY entity_key")
            .bind(&p.account_id).bind(selected.as_slice()).fetch_all(&mut **tx).await?;
        let result_entries = validate_manifest_bytes(&bytes, c.work_id)?;
        if selected_entries.len() != result_entries.len() {
            return Err(SyncError::LineageViolation);
        }
        for entry in result_entries {
            if !selected_entries.iter().any(|row| {
                row.try_get::<String, _>("entity_key").ok().as_deref()
                    == Some(entry.entity_key.as_str())
            }) {
                return Err(SyncError::LineageViolation);
            }
            sqlx::query("INSERT INTO sync_v2.snapshot_entries(account_id,snapshot_id,entity_key,object_id,byte_count,content_type) VALUES($1,$2,$3,$4,$5,$6)")
                .bind(&p.account_id).bind(new_id.as_slice()).bind(&entry.entity_key).bind(entry.object_id.as_slice()).bind(entry.byte_count).bind(&entry.content_type).execute(&mut **tx).await?;
        }
        sqlx::query("INSERT INTO sync_v2.snapshot_parents(account_id,work_id,snapshot_id,parent_snapshot_id) VALUES($1,$2,$3,$4),($1,$2,$3,$5)").bind(&p.account_id).bind(c.work_id).bind(new_id.as_slice()).bind(current.as_slice()).bind(selected.as_slice()).execute(&mut **tx).await?;
        let next = generation + 1;
        sqlx::query("UPDATE sync_v2.works SET head_snapshot_id=$3,head_generation=$4 WHERE account_id=$1 AND work_id=$2").bind(&p.account_id).bind(c.work_id).bind(new_id.as_slice()).bind(next).execute(&mut **tx).await?;
        let occurrence = Uuid::new_v4();
        sqlx::query("INSERT INTO sync_v2.history(account_id,occurrence_id,work_id,snapshot_id,reason,pinned,created_at) VALUES($1,$2,$3,$4,'restoreBefore',true,now())").bind(&p.account_id).bind(occurrence).bind(c.work_id).bind(current.as_slice()).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.restore_receipts(account_id,command_id,work_id,selected_snapshot_id,pre_restore_snapshot_id,result_snapshot_id) VALUES($1,$2,$3,$4,$5,$6)").bind(&p.account_id).bind(c.command_id).bind(c.work_id).bind(selected.as_slice()).bind(current.as_slice()).bind(new_id.as_slice()).execute(&mut **tx).await?;
        sqlx::query("INSERT INTO sync_v2.head_events(account_id,work_id,generation,snapshot_id,command_id,command_work_id,command_kind,command_scope,created_at) VALUES($1,$2,$3,$4,$5,$2,'restore','sameWork',now())").bind(&p.account_id).bind(c.work_id).bind(next).bind(new_id.as_slice()).bind(c.command_id).execute(&mut **tx).await?;
        Ok((
            200,
            Self::response(
                c,
                "applied",
                vec![
                    ("snapshotId".into(), Value::String(hex::encode(new_id))),
                    ("generation".into(), Value::from(next)),
                    (
                        "protectedRestoreBeforeSnapshotId".into(),
                        Value::String(hex::encode(current)),
                    ),
                    ("head".into(), Self::head_value(new_id.as_slice(), next)),
                ],
            ),
        ))
    }
    pub async fn upload(
        &self,
        p: &AuthenticatedPrincipal,
        upload_id: Uuid,
        capability: &str,
        bytes: &[u8],
    ) -> SyncResult<()> {
        if bytes.len() > MAX_OBJECT_BYTES {
            return Err(SyncError::SizeLimitExceeded);
        };
        let mut tx = self.pool.begin().await?;
        let row=sqlx::query("SELECT object_id,byte_count,account_fence,state,expires_at,command_id,work_id FROM sync_v2.upload_capabilities WHERE account_id=$1 AND upload_id=$2 FOR UPDATE").bind(&p.account_id).bind(upload_id).fetch_optional(&mut *tx).await?.ok_or(SyncError::NotFound)?;
        if row.try_get::<String, _>("account_fence")? != p.account_fence {
            return Err(SyncError::UploadCapabilityMismatch);
        };
        let command_id: Uuid = row.try_get("command_id")?;
        if capability != upload_capability(&p.account_id, &p.account_fence, upload_id, command_id) {
            return Err(SyncError::UploadCapabilityMismatch);
        }
        if row.try_get::<chrono::DateTime<Utc>, _>("expires_at")? <= Utc::now() {
            sqlx::query("UPDATE sync_v2.upload_capabilities SET state='expired' WHERE account_id=$1 AND upload_id=$2")
                .bind(&p.account_id).bind(upload_id).execute(&mut *tx).await?;
            tx.commit().await?;
            return Err(SyncError::UploadExpired);
        }
        if row.try_get::<String, _>("state")? == "uploaded"
            || row.try_get::<String, _>("state")? == "finalized"
        {
            tx.commit().await?;
            return Ok(());
        }
        if row.try_get::<String, _>("state")? != "prepared" {
            return Err(SyncError::UploadExpired);
        };
        let object: Vec<u8> = row.try_get("object_id")?;
        let count: i64 = row.try_get("byte_count")?;
        if count != bytes.len() as i64 || sha256(bytes).as_slice() != object.as_slice() {
            return Err(SyncError::ObjectDigestMismatch);
        };
        let object_id: [u8; 32] = object
            .as_slice()
            .try_into()
            .map_err(|_| SyncError::ObjectDigestMismatch)?;
        self.object_store.put(&object_id, bytes).await?;
        sqlx::query("UPDATE sync_v2.upload_capabilities SET state='uploaded' WHERE account_id=$1 AND upload_id=$2")
            .bind(&p.account_id).bind(upload_id).execute(&mut *tx).await?;
        tx.commit().await?;
        Ok(())
    }
    pub async fn receipt(
        &self,
        p: &AuthenticatedPrincipal,
        id: Uuid,
    ) -> SyncResult<(String, Uuid, Vec<u8>, Vec<u8>, i32)> {
        let row=sqlx::query("SELECT command_kind,work_id,request_digest,canonical_response,response_status FROM sync_v2.receipts WHERE account_id=$1 AND command_id=$2 AND state='completed'").bind(&p.account_id).bind(id).fetch_optional(&self.pool).await?.ok_or(SyncError::NotFound)?;
        Ok((
            row.try_get("command_kind")?,
            row.try_get("work_id")?,
            row.try_get("request_digest")?,
            row.try_get("canonical_response")?,
            row.try_get("response_status")?,
        ))
    }
}
