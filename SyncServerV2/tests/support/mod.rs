use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use fuminiwa_sync_server_v2::{
    application::{parse_command, strict_json},
    domain::{canonical_json, decode_digest, sha256},
    AuthenticatedPrincipal, CommandKind, Repository, SealedCommand, SyncError,
};
use serde::Deserialize;
use serde_json::{json, Value};
use sqlx::{postgres::PgPoolOptions, Row};
use std::{error::Error, io, path::PathBuf};
use uuid::Uuid;

pub type ScenarioResult<T> = Result<T, Box<dyn Error + Send + Sync>>;

const SERVER_INSTANCE: &str = "sync-v2-scenario";
const FENCE: &str = "fixture-fence";
const DDL_CONTRACT_MARKER: &str = "snapshot-sync-v2-postgres-r3";

#[derive(Clone)]
#[allow(dead_code)]
pub struct ScenarioContext {
    pub repo: Repository,
    pub account_a: AuthenticatedPrincipal,
    pub account_b: AuthenticatedPrincipal,
    pub primary_work: Uuid,
    pub foreign_work: Uuid,
    pub active_conflict_work: Uuid,
    pub history_work: Uuid,
    pub root_snapshot: [u8; 32],
    pub object_id: [u8; 32],
    pub receipt_id: Uuid,
    pub rejected_resolution: SealedCommand,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObjectFixtureList {
    objects: Vec<ObjectFixture>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ObjectFixture {
    file: String,
    byte_count: usize,
    object_id: String,
}

fn failure(message: impl Into<String>) -> Box<dyn Error + Send + Sync> {
    Box::new(io::Error::other(message.into()))
}

fn ensure(condition: bool, message: impl Into<String>) -> ScenarioResult<()> {
    if condition {
        Ok(())
    } else {
        Err(failure(message))
    }
}

fn principal(account_id: &str) -> AuthenticatedPrincipal {
    AuthenticatedPrincipal {
        account_id: account_id.into(),
        account_fence: FENCE.into(),
        account_auth_epoch: 1,
        server_instance_id: SERVER_INSTANCE.into(),
        protocol_epoch: 2,
    }
}

fn command(
    principal: &AuthenticatedPrincipal,
    command_id: Uuid,
    kind: CommandKind,
    work_id: Uuid,
    source_snapshot_id: [u8; 32],
    source_generation: i64,
    payload: Value,
) -> ScenarioResult<SealedCommand> {
    let value = json!({
        "binding": {
            "accountFence": principal.account_fence,
            "accountId": principal.account_id,
            "protocolEpoch": principal.protocol_epoch,
            "serverInstanceId": principal.server_instance_id
        },
        "commandId": command_id,
        "commandKind": kind.as_str(),
        "payload": payload,
        "schemaVersion": 2,
        "sourceGeneration": source_generation,
        "sourceSnapshotId": hex::encode(source_snapshot_id)
    });
    let bytes = canonical_json(&value).map_err(failure)?;
    let sealed =
        parse_command(&bytes).map_err(|error| failure(format!("command parse failed: {error}")))?;
    ensure(
        sealed.work_id == work_id,
        "command payload did not preserve requested WorkID",
    )?;
    Ok(sealed)
}

fn response_value(bytes: &[u8]) -> ScenarioResult<Value> {
    let value = strict_json(bytes)
        .map_err(|error| failure(format!("response is not strict JSON: {error}")))?;
    ensure(
        canonical_json(&value).map_err(failure)? == bytes,
        "response is not canonical",
    )?;
    Ok(value)
}

fn fixture_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("crate has repository parent")
        .join("docs/sync/v2/fixtures/canonical")
}

pub fn validate_test_database_url(url: &str) -> ScenarioResult<()> {
    let lower = url.to_ascii_lowercase();
    ensure(
        lower.starts_with("postgres://") || lower.starts_with("postgresql://"),
        "NO-GO: integration database URL must be PostgreSQL",
    )?;
    let without_scheme = lower
        .split_once("://")
        .map(|(_, rest)| rest)
        .ok_or_else(|| failure("NO-GO: integration database URL has no authority"))?;
    let (authority, path) = without_scheme
        .split_once('/')
        .ok_or_else(|| failure("NO-GO: integration database URL has no database name"))?;
    let host = authority.rsplit('@').next().unwrap_or(authority);
    let database = path
        .split(['?', '#'])
        .next()
        .filter(|value| !value.is_empty() && !value.contains('/'))
        .ok_or_else(|| failure("NO-GO: integration database URL has no database name"))?;
    let private_172 = (16..=31).any(|octet| host.starts_with(&format!("172.{octet}.")));
    ensure(
        !host.starts_with("192.168.") && !host.starts_with("10.") && !private_172,
        "NO-GO: integration database URL must not target a private LAN host",
    )?;
    ensure(
        database == "fuminiwa_v2_test" || database.starts_with("fuminiwa_v2_test_"),
        "NO-GO: integration database name must carry the fuminiwa_v2_test marker",
    )?;
    ensure(
        !["legacy", "production", "prod", "staging", "syncserver"]
            .iter()
            .any(|marker| database.contains(marker)),
        "NO-GO: integration database name resembles an existing authority",
    )
}

async fn require_empty_database(url: &str) -> ScenarioResult<()> {
    validate_test_database_url(url)?;
    let pool = PgPoolOptions::new().max_connections(1).connect(url).await?;
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM information_schema.tables
         WHERE table_schema NOT IN ('pg_catalog','information_schema')",
    )
    .fetch_one(&pool)
    .await?;
    pool.close().await;
    ensure(
        count == 0,
        "NO-GO: integration database must be newly created and empty",
    )
}

async fn create_work(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    work_id: Uuid,
    document_id: Uuid,
) -> ScenarioResult<(SealedCommand, Vec<u8>)> {
    let cmd = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CreateWork,
        work_id,
        [0x11; 32],
        1,
        json!({"documentId":document_id,"workId":work_id}),
    )?;
    let (status, bytes) = repo.command(principal, &cmd).await?;
    ensure(status == 201, "createWork did not return 201")?;
    let replay = repo.command(principal, &cmd).await?;
    ensure(
        replay == (status, bytes.clone()),
        "createWork exact replay diverged",
    )?;
    Ok((cmd, bytes))
}

async fn exercise_auth_scope_rotation(repo: &Repository) -> ScenarioResult<()> {
    let old = principal("account-rotation");
    let work_id = Uuid::new_v4();
    create_work(repo, &old, work_id, Uuid::new_v4()).await?;

    // Simulate a process restart with an old sealed command and parked work.
    // The next authenticated command must quarantine/rebind both atomically.
    let old_command = command(
        &old,
        Uuid::new_v4(),
        CommandKind::Publish,
        work_id,
        [0x33; 32],
        1,
        json!({
            "candidateSnapshotId":hex::encode([0x33; 32]),
            "expectedRemoteHead":Value::Null,
            "workId":work_id
        }),
    )?;
    let mut tx = repo.pool.begin().await?;
    sqlx::query(
        "UPDATE sync_v2.works SET state='quarantined'
         WHERE account_id=$1 AND work_id=$2",
    )
    .bind(&old.account_id)
    .bind(work_id)
    .execute(&mut *tx)
    .await?;
    sqlx::query(
        "INSERT INTO sync_v2.sealed_commands(
            account_id,command_id,work_id,account_fence,command_kind,
            canonical_request,request_digest,source_snapshot_id,source_generation,state
         ) VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,'sending')",
    )
    .bind(&old.account_id)
    .bind(old_command.command_id)
    .bind(work_id)
    .bind(&old.account_fence)
    .bind(old_command.kind.as_str())
    .bind(&old_command.canonical_bytes)
    .bind(old_command.request_digest.as_slice())
    .bind(old_command.source_snapshot_id.as_slice())
    .bind(old_command.source_generation)
    .execute(&mut *tx)
    .await?;
    tx.commit().await?;

    let rotated = AuthenticatedPrincipal {
        account_id: old.account_id.clone(),
        account_fence: "rotated-fence".into(),
        account_auth_epoch: 2,
        server_instance_id: old.server_instance_id.clone(),
        protocol_epoch: old.protocol_epoch,
    };
    let new_work = Uuid::new_v4();
    create_work(repo, &rotated, new_work, Uuid::new_v4()).await?;
    ensure(
        matches!(
            repo.command(&old, &old_command).await,
            Err(SyncError::AccountFenceMismatch)
        ),
        "old authenticated scope resumed after fence rotation",
    )?;
    let sealed_state: String = sqlx::query_scalar(
        "SELECT state FROM sync_v2.sealed_commands
         WHERE account_id=$1 AND command_id=$2",
    )
    .bind(&old.account_id)
    .bind(old_command.command_id)
    .fetch_one(&repo.pool)
    .await?;
    let work_state: String =
        sqlx::query_scalar("SELECT state FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
            .bind(&old.account_id)
            .bind(work_id)
            .fetch_one(&repo.pool)
            .await?;
    let scope: (i64, String) = sqlx::query_as(
        "SELECT account_auth_epoch,account_fence FROM sync_v2.account_scopes
         WHERE account_id=$1",
    )
    .bind(&old.account_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(
        sealed_state == "quarantined"
            && work_state == "bound"
            && scope == (2, "rotated-fence".into()),
        "scope rotation did not quarantine/rebind atomically",
    )?;
    let same_epoch = AuthenticatedPrincipal {
        account_fence: "same-epoch-fence".into(),
        ..rotated.clone()
    };
    ensure(
        matches!(
            repo.check_scope(&same_epoch).await,
            Err(SyncError::AccountFenceMismatch)
        ),
        "same-epoch fence change bypassed scope monotonicity",
    )?;
    let backwards = AuthenticatedPrincipal {
        account_fence: FENCE.into(),
        account_auth_epoch: 1,
        ..rotated.clone()
    };
    ensure(
        matches!(
            repo.check_scope(&backwards).await,
            Err(SyncError::AccountFenceMismatch)
        ),
        "older auth epoch bypassed scope monotonicity",
    )?;

    let foreign = AuthenticatedPrincipal {
        account_id: "account-rotation-foreign".into(),
        account_fence: "foreign-fence".into(),
        account_auth_epoch: 9,
        server_instance_id: old.server_instance_id,
        protocol_epoch: old.protocol_epoch,
    };
    create_work(repo, &foreign, Uuid::new_v4(), Uuid::new_v4()).await?;
    let unchanged: (i64, String) = sqlx::query_as(
        "SELECT account_auth_epoch,account_fence FROM sync_v2.account_scopes
         WHERE account_id=$1",
    )
    .bind(&old.account_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(
        unchanged == (2, "rotated-fence".into()),
        "different account changed another account's scope",
    )?;
    Ok(())
}

async fn upload_object(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    work_id: Uuid,
    bytes: &[u8],
    source_snapshot_id: [u8; 32],
    source_generation: i64,
) -> ScenarioResult<[u8; 32]> {
    let object_id = sha256(bytes);
    let prepare = command(
        principal,
        Uuid::new_v4(),
        CommandKind::PrepareObject,
        work_id,
        source_snapshot_id,
        source_generation,
        json!({"byteCount":bytes.len(),"objectId":hex::encode(object_id),"workId":work_id}),
    )?;
    let (status, response) = repo.command(principal, &prepare).await?;
    if status == 200 {
        ensure(
            response_value(&response)?["result"] == "noChanges",
            "existing object did not return noChanges",
        )?;
        return Ok(object_id);
    }
    ensure(status == 201, "prepareObject did not return 201")?;
    let value = response_value(&response)?;
    let upload_id = Uuid::parse_str(
        value["uploadId"]
            .as_str()
            .ok_or_else(|| failure("prepare receipt missing uploadId"))?,
    )?;
    let capability = value["uploadCapability"]
        .as_str()
        .ok_or_else(|| failure("prepare receipt missing capability"))?;
    repo.upload(principal, upload_id, capability, bytes).await?;
    repo.upload(principal, upload_id, capability, bytes).await?;
    let finalize = command(
        principal,
        Uuid::new_v4(),
        CommandKind::FinalizeObject,
        work_id,
        source_snapshot_id,
        source_generation,
        json!({"byteCount":bytes.len(),"objectId":hex::encode(object_id),"uploadId":upload_id,"workId":work_id}),
    )?;
    let first = repo.command(principal, &finalize).await?;
    ensure(first.0 == 200, "finalizeObject did not return 200")?;
    ensure(
        repo.command(principal, &finalize).await? == first,
        "finalizeObject exact replay diverged",
    )?;
    Ok(object_id)
}

async fn register_snapshot(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    work_id: Uuid,
    manifest_bytes: Vec<u8>,
    source_generation: i64,
) -> ScenarioResult<([u8; 32], SealedCommand)> {
    let snapshot_id = sha256(&manifest_bytes);
    let cmd = command(
        principal,
        Uuid::new_v4(),
        CommandKind::RegisterSnapshot,
        work_id,
        snapshot_id,
        source_generation,
        json!({
            "manifestBase64URL": URL_SAFE_NO_PAD.encode(&manifest_bytes),
            "manifestBytesDigest": hex::encode(snapshot_id),
            "snapshotId": hex::encode(snapshot_id),
            "workId": work_id
        }),
    )?;
    let first = repo.command(principal, &cmd).await?;
    ensure(first.0 == 200, "registerSnapshot did not return 200")?;
    ensure(
        repo.command(principal, &cmd).await? == first,
        "registerSnapshot exact replay diverged",
    )?;
    Ok((snapshot_id, cmd))
}

async fn publish(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    work_id: Uuid,
    candidate: [u8; 32],
    source_generation: i64,
    expected: Option<([u8; 32], i64)>,
) -> ScenarioResult<(SealedCommand, i32, Vec<u8>)> {
    let expected = expected.map_or(Value::Null, |(snapshot_id, generation)| {
        json!({"generation":generation,"snapshotId":hex::encode(snapshot_id)})
    });
    let cmd = command(
        principal,
        Uuid::new_v4(),
        CommandKind::Publish,
        work_id,
        candidate,
        source_generation,
        json!({"candidateSnapshotId":hex::encode(candidate),"expectedRemoteHead":expected,"workId":work_id}),
    )?;
    let (status, bytes) = repo.command(principal, &cmd).await?;
    Ok((cmd, status, bytes))
}

fn derive_manifest(
    template: &Value,
    work_id: Uuid,
    document_object: [u8; 32],
    document_count: usize,
    title_object: [u8; 32],
    title_count: usize,
    parents: &[[u8; 32]],
) -> ScenarioResult<Vec<u8>> {
    let mut manifest = template.clone();
    manifest["workId"] = Value::String(work_id.to_string());
    let mut parent_ids = parents.iter().map(hex::encode).collect::<Vec<_>>();
    parent_ids.sort();
    manifest["parentSnapshotIds"] =
        Value::Array(parent_ids.into_iter().map(Value::String).collect());
    let entries = manifest["entries"]
        .as_array_mut()
        .ok_or_else(|| failure("fixture manifest has no entries"))?;
    for entry in entries {
        match entry["entityKey"].as_str() {
            Some("work/document") => {
                entry["objectId"] = Value::String(hex::encode(document_object));
                entry["byteCount"] = Value::from(document_count as i64);
            }
            Some("work/title") => {
                entry["objectId"] = Value::String(hex::encode(title_object));
                entry["byteCount"] = Value::from(title_count as i64);
            }
            _ => {}
        }
    }
    canonical_json(&manifest).map_err(failure)
}

struct WorkGraph {
    work_id: Uuid,
    document_bytes: Vec<u8>,
    root: [u8; 32],
    remote: [u8; 32],
    local: [u8; 32],
    local_manifest: Vec<u8>,
    remote_generation: i64,
    conflict_id: Uuid,
    conflict_revision: i64,
    conflict_source_generation: i64,
}

async fn setup_conflicted_work(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    template: &Value,
    base_title_object: [u8; 32],
    base_title_count: usize,
    work_id: Uuid,
    add_revision: bool,
) -> ScenarioResult<WorkGraph> {
    let document_id = Uuid::new_v4();
    create_work(repo, principal, work_id, document_id).await?;
    let document_value = json!({
        "documentCreatedAt":"2026-08-17T00:00:00Z",
        "documentId":document_id
    });
    let document_bytes = canonical_json(&document_value).map_err(failure)?;
    let document_object =
        upload_object(repo, principal, work_id, &document_bytes, [0x22; 32], 1).await?;
    let root_bytes = derive_manifest(
        template,
        work_id,
        document_object,
        document_bytes.len(),
        base_title_object,
        base_title_count,
        &[],
    )?;
    let (root, _) = register_snapshot(repo, principal, work_id, root_bytes, 1).await?;
    let (_, status, _) = publish(repo, principal, work_id, root, 1, None).await?;
    ensure(status == 200, "root publish failed")?;

    let remote_title =
        canonical_json(&json!({"value":format!("remote-{work_id}")})).map_err(failure)?;
    let remote_title_object =
        upload_object(repo, principal, work_id, &remote_title, root, 2).await?;
    let remote_bytes = derive_manifest(
        template,
        work_id,
        document_object,
        document_bytes.len(),
        remote_title_object,
        remote_title.len(),
        &[root],
    )?;
    let (remote, _) = register_snapshot(repo, principal, work_id, remote_bytes, 2).await?;
    let (_, status, _) = publish(repo, principal, work_id, remote, 2, Some((root, 1))).await?;
    ensure(status == 200, "remote branch publish failed")?;

    // Re-sending an already contained candidate is a successful no-op. These
    // two calls cover both the strict-equality and ancestor branches before a
    // real divergent candidate opens the single conflict lane.
    let (_, status, response) =
        publish(repo, principal, work_id, remote, 2, Some((root, 1))).await?;
    ensure(status == 200, "equal publish did not succeed")?;
    ensure(
        response_value(&response)?["result"] == "noChanges",
        "equal publish did not return noChanges",
    )?;
    let (_, status, response) = publish(repo, principal, work_id, root, 2, Some((root, 1))).await?;
    ensure(status == 200, "ancestor publish did not succeed")?;
    ensure(
        response_value(&response)?["result"] == "noChanges",
        "ancestor publish did not return noChanges",
    )?;

    let local_title =
        canonical_json(&json!({"value":format!("local-{work_id}")})).map_err(failure)?;
    let local_title_object = upload_object(repo, principal, work_id, &local_title, root, 3).await?;
    let local_bytes = derive_manifest(
        template,
        work_id,
        document_object,
        document_bytes.len(),
        local_title_object,
        local_title.len(),
        &[root],
    )?;
    let (local, _) = register_snapshot(repo, principal, work_id, local_bytes.clone(), 3).await?;
    let (_, status, conflict_response) =
        publish(repo, principal, work_id, local, 3, Some((root, 1))).await?;
    ensure(status == 409, "stale local publish did not create conflict")?;
    let first_conflict = response_value(&conflict_response)?;
    let conflict_id = Uuid::parse_str(
        first_conflict["conflictId"]
            .as_str()
            .ok_or_else(|| failure("conflict response missing id"))?,
    )?;
    let mut conflict_revision = first_conflict["conflictRevision"]
        .as_i64()
        .ok_or_else(|| failure("conflict response missing revision"))?;
    let mut source_generation = 3;
    let mut effective_manifest = local_bytes;
    let mut effective_local = local;

    // A lost response can be retried with a new operation ID. It must project
    // the existing active revision rather than append another candidate.
    let candidates_before_retry: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sync_v2.conflict_candidates
         WHERE account_id=$1 AND conflict_id=$2",
    )
    .bind(&principal.account_id)
    .bind(conflict_id)
    .fetch_one(&repo.pool)
    .await?;
    let (_, retry_status, retry_response) =
        publish(repo, principal, work_id, local, 3, Some((root, 1))).await?;
    ensure(
        retry_status == 409,
        "semantic conflict retry did not remain pending",
    )?;
    let retry = response_value(&retry_response)?;
    ensure(
        retry["conflictId"] == Value::String(conflict_id.to_string())
            && retry["conflictRevision"] == 1
            && retry["sourceGeneration"] == 3,
        "semantic conflict retry changed the active revision",
    )?;
    let candidates_after_retry: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sync_v2.conflict_candidates
         WHERE account_id=$1 AND conflict_id=$2",
    )
    .bind(&principal.account_id)
    .bind(conflict_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(
        candidates_after_retry == candidates_before_retry,
        "semantic conflict retry appended a candidate",
    )?;

    if add_revision {
        let latest_title =
            canonical_json(&json!({"value":format!("local-latest-{work_id}")})).map_err(failure)?;
        let latest_title_object =
            upload_object(repo, principal, work_id, &latest_title, local, 4).await?;
        let latest_bytes = derive_manifest(
            template,
            work_id,
            document_object,
            document_bytes.len(),
            latest_title_object,
            latest_title.len(),
            &[root],
        )?;
        let (latest, _) =
            register_snapshot(repo, principal, work_id, latest_bytes.clone(), 4).await?;
        let (_, status, response) =
            publish(repo, principal, work_id, latest, 4, Some((root, 1))).await?;
        ensure(
            status == 409,
            "new divergence did not append a conflict revision",
        )?;
        let appended = response_value(&response)?;
        ensure(
            appended["conflictId"] == Value::String(conflict_id.to_string())
                && appended["conflictRevision"] == 2
                && appended["sourceGeneration"] == 4,
            "new divergence did not preserve the active conflict lane",
        )?;
        source_generation = 4;
        conflict_revision = 2;
        effective_local = latest;
        effective_manifest = latest_bytes;
    }

    let active_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sync_v2.active_conflicts
         WHERE account_id=$1 AND work_id=$2 AND state='active'",
    )
    .bind(&principal.account_id)
    .bind(work_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(active_count == 1, "work has more than one active conflict")?;

    Ok(WorkGraph {
        work_id,
        document_bytes,
        root,
        remote,
        local: effective_local,
        local_manifest: effective_manifest,
        remote_generation: 2,
        conflict_id,
        conflict_revision,
        conflict_source_generation: source_generation,
    })
}

async fn resolve_server_and_restore(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    graph: &WorkGraph,
) -> ScenarioResult<()> {
    let resolve = command(
        principal,
        Uuid::new_v4(),
        CommandKind::ResolveServer,
        graph.work_id,
        graph.local,
        graph.conflict_source_generation,
        json!({
            "conflictId":graph.conflict_id,
            "conflictRevision":graph.conflict_revision,
            "expectedCurrentSnapshotId":hex::encode(graph.local),
            "expectedLocalGeneration":graph.conflict_source_generation,
            "preAdoptionSnapshotId":hex::encode(graph.local),
            "remoteSnapshotId":hex::encode(graph.remote),
            "workId":graph.work_id
        }),
    )?;
    let first = repo.command(principal, &resolve).await?;
    ensure(first.0 == 200, "useServer failed")?;
    ensure(
        repo.command(principal, &resolve).await? == first,
        "useServer exact retry diverged",
    )?;
    let state: String = sqlx::query_scalar(
        "SELECT state FROM sync_v2.active_conflicts WHERE account_id=$1 AND conflict_id=$2",
    )
    .bind(&principal.account_id)
    .bind(graph.conflict_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(state == "resolved", "useServer left conflict active")?;
    let pinned: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM sync_v2.history
         WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3
           AND reason='preAdoptionLocal' AND pinned=true)",
    )
    .bind(&principal.account_id)
    .bind(graph.work_id)
    .bind(graph.local.as_slice())
    .fetch_one(&repo.pool)
    .await?;
    ensure(pinned, "useServer did not pin local candidate")?;

    let selected_row = sqlx::query(
        "SELECT manifest_bytes FROM sync_v2.snapshots
         WHERE account_id=$1 AND work_id=$2 AND snapshot_id=$3",
    )
    .bind(&principal.account_id)
    .bind(graph.work_id)
    .bind(graph.root.as_slice())
    .fetch_one(&repo.pool)
    .await?;
    let selected_bytes: Vec<u8> = selected_row.try_get("manifest_bytes")?;
    let mut restored_manifest = strict_json(&selected_bytes)
        .map_err(|error| failure(format!("selected manifest invalid: {error}")))?;
    let mut parents = vec![hex::encode(graph.remote), hex::encode(graph.root)];
    parents.sort();
    restored_manifest["parentSnapshotIds"] =
        Value::Array(parents.into_iter().map(Value::String).collect());
    let restored_bytes = canonical_json(&restored_manifest).map_err(failure)?;
    let restored_id = sha256(&restored_bytes);
    let restore = command(
        principal,
        Uuid::new_v4(),
        CommandKind::Restore,
        graph.work_id,
        graph.remote,
        graph.remote_generation,
        json!({
            "expectedCurrentSnapshotId":hex::encode(graph.remote),
            "expectedLocalGeneration":graph.remote_generation,
            "expectedRemoteHead":{"generation":graph.remote_generation,"snapshotId":hex::encode(graph.remote)},
            "newSnapshotId":hex::encode(restored_id),
            "selectedSnapshotId":hex::encode(graph.root),
            "workId":graph.work_id
        }),
    )?;
    let first = repo.command(principal, &restore).await?;
    ensure(first.0 == 200, "restore failed")?;
    ensure(
        repo.command(principal, &restore).await? == first,
        "restore exact retry diverged",
    )?;
    let head: (Vec<u8>, i64) = sqlx::query_as(
        "SELECT head_snapshot_id,head_generation FROM sync_v2.works
         WHERE account_id=$1 AND work_id=$2",
    )
    .bind(&principal.account_id)
    .bind(graph.work_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(
        head.0 == restored_id && head.1 == graph.remote_generation + 1,
        "restore did not advance exact head",
    )
}

async fn resolution_state(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    graph: &WorkGraph,
) -> ScenarioResult<(String, i64, i64, Vec<u8>, i64, i64, i64, i64)> {
    sqlx::query_as(
        "SELECT a.state,a.current_revision,a.source_generation,
                w.head_snapshot_id,w.head_generation,
                (SELECT COUNT(*) FROM sync_v2.history h
                 WHERE h.account_id=a.account_id AND h.work_id=a.work_id),
                (SELECT COUNT(*) FROM sync_v2.receipts r
                 WHERE r.account_id=a.account_id AND r.work_id=a.work_id),
                (SELECT COUNT(*) FROM sync_v2.conflict_events e
                 WHERE e.account_id=a.account_id AND e.conflict_id=a.conflict_id)
         FROM sync_v2.active_conflicts a
         JOIN sync_v2.works w ON w.account_id=a.account_id AND w.work_id=a.work_id
         WHERE a.account_id=$1 AND a.conflict_id=$2",
    )
    .bind(&principal.account_id)
    .bind(graph.conflict_id)
    .fetch_one(&repo.pool)
    .await
    .map_err(Into::into)
}

async fn reject_mismatched_server_resolutions(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    graph: &WorkGraph,
) -> ScenarioResult<SealedCommand> {
    let make = |source_snapshot_id, source_generation, local, remote| {
        command(
            principal,
            Uuid::new_v4(),
            CommandKind::ResolveServer,
            graph.work_id,
            source_snapshot_id,
            source_generation,
            json!({
                "conflictId":graph.conflict_id,
                "conflictRevision":graph.conflict_revision,
                "expectedCurrentSnapshotId":hex::encode(local),
                "expectedLocalGeneration":source_generation,
                "preAdoptionSnapshotId":hex::encode(local),
                "remoteSnapshotId":hex::encode(remote),
                "workId":graph.work_id
            }),
        )
    };
    let generation_mismatch = make(
        graph.local,
        graph.conflict_source_generation + 1,
        graph.local,
        graph.remote,
    )?;
    let local_mismatch = make(
        graph.root,
        graph.conflict_source_generation,
        graph.root,
        graph.remote,
    )?;
    let remote_mismatch = make(
        graph.local,
        graph.conflict_source_generation,
        graph.local,
        graph.root,
    )?;
    let before = resolution_state(repo, principal, graph).await?;
    for rejected in [&generation_mismatch, &local_mismatch, &remote_mismatch] {
        ensure(
            matches!(
                repo.command(principal, rejected).await,
                Err(SyncError::StaleConflictRevision)
            ),
            "useServer mismatch was not rejected as staleConflictRevision",
        )?;
        ensure(
            resolution_state(repo, principal, graph).await? == before,
            "rejected useServer changed conflict/head/history/receipt state",
        )?;
    }
    Ok(local_mismatch)
}

async fn resolve_device(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    graph: &WorkGraph,
) -> ScenarioResult<()> {
    let mut decision_manifest = strict_json(&graph.local_manifest)
        .map_err(|error| failure(format!("local manifest invalid: {error}")))?;
    let mut parents = vec![hex::encode(graph.local), hex::encode(graph.remote)];
    parents.sort();
    decision_manifest["parentSnapshotIds"] =
        Value::Array(parents.into_iter().map(Value::String).collect());
    let decision_bytes = canonical_json(&decision_manifest).map_err(failure)?;
    let (decision, _) = register_snapshot(
        repo,
        principal,
        graph.work_id,
        decision_bytes,
        graph.conflict_source_generation,
    )
    .await?;
    let resolve = command(
        principal,
        Uuid::new_v4(),
        CommandKind::ResolveDevice,
        graph.work_id,
        graph.local,
        graph.conflict_source_generation,
        json!({
            "conflictId":graph.conflict_id,
            "conflictRevision":graph.conflict_revision,
            "decisionSnapshotId":hex::encode(decision),
            "expectedRemoteHead":{"generation":graph.remote_generation,"snapshotId":hex::encode(graph.remote)},
            "localCandidateSnapshotId":hex::encode(graph.local),
            "workId":graph.work_id
        }),
    )?;
    let first = repo.command(principal, &resolve).await?;
    ensure(first.0 == 200, "useDevice failed")?;
    ensure(
        repo.command(principal, &resolve).await? == first,
        "useDevice exact retry diverged",
    )?;
    let row = sqlx::query(
        "SELECT w.head_snapshot_id,w.head_generation,a.state,
                EXISTS(SELECT 1 FROM sync_v2.catalog_events c
                       WHERE c.account_id=w.account_id AND c.work_id=w.work_id
                         AND c.head_snapshot_id=w.head_snapshot_id
                         AND c.head_generation=w.head_generation AND c.tombstoned=false) AS cataloged
         FROM sync_v2.works w
         JOIN sync_v2.active_conflicts a ON a.account_id=w.account_id AND a.work_id=w.work_id
         WHERE w.account_id=$1 AND w.work_id=$2",
    )
    .bind(&principal.account_id)
    .bind(graph.work_id)
    .fetch_one(&repo.pool)
    .await?;
    let head: Vec<u8> = row.try_get("head_snapshot_id")?;
    let generation: i64 = row.try_get("head_generation")?;
    let state: String = row.try_get("state")?;
    let cataloged: bool = row.try_get("cataloged")?;
    ensure(
        head == decision
            && generation == graph.remote_generation + 1
            && state == "resolved"
            && cataloged,
        "useDevice did not atomically advance head/catalog/conflict",
    )
}

async fn clone_work(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    graph: &WorkGraph,
) -> ScenarioResult<Uuid> {
    let new_work = Uuid::new_v4();
    let new_document = Uuid::new_v4();
    let mut clone_manifest = strict_json(&graph.local_manifest)
        .map_err(|error| failure(format!("local manifest invalid: {error}")))?;
    clone_manifest["workId"] = Value::String(new_work.to_string());
    clone_manifest["parentSnapshotIds"] = Value::Array(Vec::new());
    let mut clone_document = strict_json(&graph.document_bytes)
        .map_err(|error| failure(format!("document object invalid: {error}")))?;
    clone_document["documentId"] = Value::String(new_document.to_string());
    let clone_document_bytes = canonical_json(&clone_document).map_err(failure)?;
    let clone_document_id = sha256(&clone_document_bytes);
    for entry in clone_manifest["entries"]
        .as_array_mut()
        .ok_or_else(|| failure("clone manifest missing entries"))?
    {
        if entry["entityKey"] == "work/document" {
            entry["objectId"] = Value::String(hex::encode(clone_document_id));
            entry["byteCount"] = Value::from(clone_document_bytes.len() as i64);
        }
    }
    let clone_bytes = canonical_json(&clone_manifest).map_err(failure)?;
    let clone_root = sha256(&clone_bytes);
    let payload = |root: [u8; 32]| {
        json!({
            "conflictId":graph.conflict_id,
            "conflictRevision":graph.conflict_revision,
            "expectedOriginalHead":{"generation":graph.remote_generation,"snapshotId":hex::encode(graph.remote)},
            "localCandidateSnapshotId":hex::encode(graph.local),
            "newDocumentId":new_document,
            "newRootSnapshotId":hex::encode(root),
            "newWorkId":new_work,
            "sourceWorkId":graph.work_id
        })
    };
    let arbitrary_candidate = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CloneWork,
        graph.work_id,
        graph.root,
        graph.conflict_source_generation,
        {
            let mut value = payload([0xFF; 32]);
            value["localCandidateSnapshotId"] = Value::String(hex::encode(graph.root));
            value
        },
    )?;
    ensure(
        matches!(
            repo.command(principal, &arbitrary_candidate).await,
            Err(SyncError::StaleConflictRevision)
        ),
        "keepBoth accepted an arbitrary same-work snapshot",
    )?;
    let invalid = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CloneWork,
        graph.work_id,
        graph.local,
        graph.conflict_source_generation,
        payload([0xFF; 32]),
    )?;
    ensure(
        matches!(
            repo.command(principal, &invalid).await,
            Err(SyncError::SnapshotDigestMismatch)
        ),
        "keepBoth invalid root did not fail closed",
    )?;
    let rollback_state: (i64, i64) = sqlx::query_as(
        "SELECT
             (SELECT COUNT(*) FROM sync_v2.works WHERE account_id=$1 AND work_id=$2),
             (SELECT COUNT(*) FROM sync_v2.active_conflicts
              WHERE account_id=$1 AND conflict_id=$3 AND state='active')",
    )
    .bind(&principal.account_id)
    .bind(new_work)
    .bind(graph.conflict_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(
        rollback_state == (0, 1),
        "keepBoth failure left a partial work or resolved conflict",
    )?;

    let cmd = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CloneWork,
        graph.work_id,
        graph.local,
        graph.conflict_source_generation,
        payload(clone_root),
    )?;
    let first = repo.command(principal, &cmd).await?;
    ensure(first.0 == 200, "keepBoth failed")?;
    ensure(
        repo.command(principal, &cmd).await? == first,
        "keepBoth exact replay diverged",
    )?;
    let row = sqlx::query(
        "SELECT w.head_snapshot_id,w.head_generation,
                EXISTS(SELECT 1 FROM sync_v2.catalog_events c
                       WHERE c.account_id=w.account_id AND c.work_id=w.work_id
                         AND c.head_snapshot_id=w.head_snapshot_id
                         AND c.head_generation=w.head_generation AND c.tombstoned=false) AS cataloged
         FROM sync_v2.works w WHERE w.account_id=$1 AND w.work_id=$2",
    )
    .bind(&principal.account_id)
    .bind(new_work)
    .fetch_one(&repo.pool)
    .await?;
    ensure(
        row.try_get::<Vec<u8>, _>("head_snapshot_id")? == clone_root
            && row.try_get::<i64, _>("head_generation")? == 1
            && row.try_get::<bool, _>("cataloged")?,
        "keepBoth clone is not independently openable/cataloged",
    )?;
    Ok(new_work)
}

async fn exercise_upload_expiry(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    work_id: Uuid,
) -> ScenarioResult<()> {
    let bytes = b"expired-upload-scenario";
    let object_id = sha256(bytes);
    let prepare = command(
        principal,
        Uuid::new_v4(),
        CommandKind::PrepareObject,
        work_id,
        [0x33; 32],
        1,
        json!({"byteCount":bytes.len(),"objectId":hex::encode(object_id),"workId":work_id}),
    )?;
    let (status, response) = repo.command(principal, &prepare).await?;
    ensure(status == 201, "expiry prepare did not allocate upload")?;
    let value = response_value(&response)?;
    let upload_id = Uuid::parse_str(
        value["uploadId"]
            .as_str()
            .ok_or_else(|| failure("expiry prepare missing uploadId"))?,
    )?;
    let capability = value["uploadCapability"]
        .as_str()
        .ok_or_else(|| failure("expiry prepare missing capability"))?;
    sqlx::query(
        "UPDATE sync_v2.upload_capabilities SET expires_at=now()-interval '1 second'
         WHERE account_id=$1 AND upload_id=$2",
    )
    .bind(&principal.account_id)
    .bind(upload_id)
    .execute(&repo.pool)
    .await?;
    ensure(
        matches!(
            repo.upload(principal, upload_id, capability, bytes).await,
            Err(SyncError::UploadExpired)
        ),
        "expired upload was accepted",
    )?;
    let state: String = sqlx::query_scalar(
        "SELECT state FROM sync_v2.upload_capabilities
         WHERE account_id=$1 AND upload_id=$2",
    )
    .bind(&principal.account_id)
    .bind(upload_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(state == "expired", "expired upload state was not durable")
}

async fn exercise_concurrent_create(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
) -> ScenarioResult<()> {
    let work = Uuid::new_v4();
    let document = Uuid::new_v4();
    let exact = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CreateWork,
        work,
        [0x44; 32],
        1,
        json!({"documentId":document,"workId":work}),
    )?;
    let left_repo = repo.clone();
    let right_repo = repo.clone();
    let left_principal = principal.clone();
    let right_principal = principal.clone();
    let left_command = exact.clone();
    let right_command = exact.clone();
    let (left, right) = tokio::join!(
        async move { left_repo.command(&left_principal, &left_command).await },
        async move { right_repo.command(&right_principal, &right_command).await }
    );
    let left = left?;
    let right = right?;
    ensure(
        left == right && left.0 == 201,
        "concurrent exact create diverged",
    )?;
    let counts: (i64, i64) = sqlx::query_as(
        "SELECT
           (SELECT COUNT(*) FROM sync_v2.works WHERE account_id=$1 AND work_id=$2),
           (SELECT COUNT(*) FROM sync_v2.receipts WHERE account_id=$1 AND command_id=$3)",
    )
    .bind(&principal.account_id)
    .bind(work)
    .bind(exact.command_id)
    .fetch_one(&repo.pool)
    .await?;
    ensure(counts == (1, 1), "concurrent exact create duplicated rows")?;

    let contested_work = Uuid::new_v4();
    let first = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CreateWork,
        contested_work,
        [0x45; 32],
        1,
        json!({"documentId":Uuid::new_v4(),"workId":contested_work}),
    )?;
    let second = command(
        principal,
        Uuid::new_v4(),
        CommandKind::CreateWork,
        contested_work,
        [0x46; 32],
        1,
        json!({"documentId":Uuid::new_v4(),"workId":contested_work}),
    )?;
    let left_repo = repo.clone();
    let right_repo = repo.clone();
    let left_principal = principal.clone();
    let right_principal = principal.clone();
    let (left, right) = tokio::join!(
        async move { left_repo.command(&left_principal, &first).await },
        async move { right_repo.command(&right_principal, &second).await }
    );
    let success_count = [left.as_ref(), right.as_ref()]
        .into_iter()
        .filter(|result| result.is_ok())
        .count();
    let reuse_count = [left.as_ref(), right.as_ref()]
        .into_iter()
        .filter(|result| matches!(result, Err(SyncError::CommandIdReused)))
        .count();
    ensure(
        success_count == 1 && reuse_count == 1,
        "contested create did not choose one deterministic winner",
    )
}

async fn exercise_account_isolation(
    repo: &Repository,
    account_a: &AuthenticatedPrincipal,
    account_b: &AuthenticatedPrincipal,
    primary_work: Uuid,
    object_id: [u8; 32],
    object_bytes: &[u8],
    receipt_id: Uuid,
) -> ScenarioResult<Uuid> {
    let foreign_work = Uuid::new_v4();
    create_work(repo, account_b, foreign_work, Uuid::new_v4()).await?;
    ensure(
        matches!(
            repo.receipt(account_b, receipt_id).await,
            Err(SyncError::NotFound)
        ),
        "foreign receipt was disclosed",
    )?;
    ensure(
        matches!(
            repo.object_store
                .get(&account_b.account_id, &object_id)
                .await,
            Err(SyncError::NotFound)
        ),
        "foreign object ownership was disclosed",
    )?;
    let foreign_prepare = command(
        account_b,
        Uuid::new_v4(),
        CommandKind::PrepareObject,
        foreign_work,
        [0x55; 32],
        1,
        json!({"byteCount":object_bytes.len(),"objectId":hex::encode(object_id),"workId":foreign_work}),
    )?;
    let (status, response) = repo.command(account_b, &foreign_prepare).await?;
    ensure(
        status == 201 && response_value(&response)?["result"] == "applied",
        "global blob existence leaked through prepareObject",
    )?;
    let value = response_value(&response)?;
    let upload_id = Uuid::parse_str(
        value["uploadId"]
            .as_str()
            .ok_or_else(|| failure("foreign prepare missing uploadId"))?,
    )?;
    let capability = value["uploadCapability"]
        .as_str()
        .ok_or_else(|| failure("foreign prepare missing capability"))?;
    ensure(
        matches!(
            repo.upload(account_a, upload_id, capability, object_bytes)
                .await,
            Err(SyncError::NotFound)
        ),
        "foreign upload capability crossed account boundary",
    )?;
    repo.upload(account_b, upload_id, capability, object_bytes)
        .await?;
    let finalize = command(
        account_b,
        Uuid::new_v4(),
        CommandKind::FinalizeObject,
        foreign_work,
        [0x55; 32],
        1,
        json!({"byteCount":object_bytes.len(),"objectId":hex::encode(object_id),"uploadId":upload_id,"workId":foreign_work}),
    )?;
    ensure(
        repo.command(account_b, &finalize).await?.0 == 200,
        "foreign account could not independently adopt identical bytes",
    )?;
    let against_foreign = command(
        account_a,
        Uuid::new_v4(),
        CommandKind::PrepareObject,
        foreign_work,
        [0x56; 32],
        1,
        json!({"byteCount":object_bytes.len(),"objectId":hex::encode(object_id),"workId":foreign_work}),
    )?;
    ensure(
        matches!(
            repo.command(account_a, &against_foreign).await,
            Err(SyncError::NotFound)
        ),
        "foreign WorkID was accessible",
    )?;
    let cross_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM sync_v2.catalog_events
         WHERE account_id=$1 AND work_id=$2",
    )
    .bind(&account_b.account_id)
    .bind(primary_work)
    .fetch_one(&repo.pool)
    .await?;
    ensure(cross_count == 0, "catalog crossed AccountID boundary")?;
    Ok(foreign_work)
}

async fn exercise_migration_markers(url: &str, repo: &Repository) -> ScenarioResult<()> {
    let marker: String =
        sqlx::query_scalar("SELECT value FROM sync_v2.server_meta WHERE key='ddl_contract_marker'")
            .fetch_one(&repo.pool)
            .await?;
    ensure(
        marker == DDL_CONTRACT_MARKER,
        "repository initialization did not apply the current DDL contract marker",
    )?;
    ensure(
        Repository::connect(url, "wrong-deployment".into())
            .await
            .is_err(),
        "repository accepted the wrong deployment id",
    )?;
    sqlx::query(
        "UPDATE sync_v2.server_meta SET value='crash-marker' WHERE key='ddl_contract_marker'",
    )
    .execute(&repo.pool)
    .await?;
    let rejected = Repository::connect(url, SERVER_INSTANCE.into())
        .await
        .is_err();
    sqlx::query(
        "UPDATE sync_v2.server_meta SET value=$1
         WHERE key='ddl_contract_marker'",
    )
    .bind(DDL_CONTRACT_MARKER)
    .execute(&repo.pool)
    .await?;
    ensure(
        rejected,
        "repository accepted a crash-corrupted migration marker",
    )?;
    let rebound = Repository::connect(url, SERVER_INSTANCE.into()).await?;
    rebound.pool.close().await;
    Ok(())
}

async fn exercise_catalog_commit_race(
    repo: &Repository,
    principal: &AuthenticatedPrincipal,
    work_id: Uuid,
) -> ScenarioResult<()> {
    let mut slow = repo.pool.begin().await?;
    sqlx::query(
        "SELECT pg_advisory_xact_lock(
             hashtextextended('sync_v2_catalog:' || $1, 0)
         )",
    )
    .bind(&principal.account_id)
    .execute(&mut *slow)
    .await?;
    let slow_event: i64 = sqlx::query_scalar(
        "INSERT INTO sync_v2.catalog_events(
             account_id,work_id,event_kind,head_generation,head_snapshot_id,
             title,tombstoned,created_at
         )
         SELECT account_id,work_id,'tombstone',head_generation,head_snapshot_id,
                '',true,now()
         FROM sync_v2.works WHERE account_id=$1 AND work_id=$2
         RETURNING event_id",
    )
    .bind(&principal.account_id)
    .bind(work_id)
    .fetch_one(&mut *slow)
    .await?;

    let pool = repo.pool.clone();
    let account = principal.account_id.clone();
    let (started_tx, started_rx) = tokio::sync::oneshot::channel();
    let mut later = tokio::spawn(async move {
        let mut tx = pool.begin().await?;
        let _ = started_tx.send(());
        sqlx::query(
            "SELECT pg_advisory_xact_lock(
                 hashtextextended('sync_v2_catalog:' || $1, 0)
             )",
        )
        .bind(&account)
        .execute(&mut *tx)
        .await?;
        let event: i64 = sqlx::query_scalar(
            "INSERT INTO sync_v2.catalog_events(
                 account_id,work_id,event_kind,head_generation,head_snapshot_id,
                 title,tombstoned,created_at
             )
             SELECT account_id,work_id,'upsert',head_generation,head_snapshot_id,
                    'race-upsert',false,now()
             FROM sync_v2.works WHERE account_id=$1 AND work_id=$2
             RETURNING event_id",
        )
        .bind(&account)
        .bind(work_id)
        .fetch_one(&mut *tx)
        .await?;
        tx.commit().await?;
        Ok::<i64, sqlx::Error>(event)
    });
    started_rx.await?;
    tokio::task::yield_now().await;
    ensure(
        !later.is_finished(),
        "later catalog writer bypassed the per-account commit-order lock",
    )?;

    let mut reader = repo.pool.begin().await?;
    sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY")
        .execute(&mut *reader)
        .await?;
    let high_water: i64 = sqlx::query_scalar(
        "SELECT COALESCE(MAX(event_id),0) FROM sync_v2.catalog_events
         WHERE account_id=$1",
    )
    .bind(&principal.account_id)
    .fetch_one(&mut *reader)
    .await?;
    ensure(
        high_water < slow_event,
        "reader observed an uncommitted catalog identity",
    )?;
    let sorted_page_sql = "WITH latest AS (
             SELECT DISTINCT ON (work_id) work_id,tombstoned
             FROM sync_v2.catalog_events
             WHERE account_id=$1 AND event_id <= $2
             ORDER BY work_id,event_id DESC
         )
         SELECT work_id FROM latest
         WHERE tombstoned=false AND work_id::text <= $3
         ORDER BY work_id";
    let page_before_commit: Vec<Uuid> = sqlx::query_scalar(sorted_page_sql)
        .bind(&principal.account_id)
        .bind(high_water)
        .bind(work_id.to_string())
        .fetch_all(&mut *reader)
        .await?;
    ensure(
        page_before_commit.contains(&work_id),
        "race fixture WorkID was absent before the late tombstone",
    )?;
    slow.commit().await?;
    let later_event = (&mut later).await??;
    ensure(
        later_event > slow_event,
        "catalog writer commit order did not preserve identity order",
    )?;

    let page_in_same_snapshot: Vec<Uuid> = sqlx::query_scalar(sorted_page_sql)
        .bind(&principal.account_id)
        .bind(high_water)
        .bind(work_id.to_string())
        .fetch_all(&mut *reader)
        .await?;
    reader.commit().await?;
    ensure(
        page_in_same_snapshot == page_before_commit,
        "late identity changed the repeatable-read WorkID-sorted page",
    )?;
    let page_from_cursor: Vec<Uuid> = sqlx::query_scalar(sorted_page_sql)
        .bind(&principal.account_id)
        .bind(high_water)
        .bind(work_id.to_string())
        .fetch_all(&repo.pool)
        .await?;
    ensure(
        page_from_cursor == page_before_commit,
        "cursor high-water admitted a later-committed event into WorkID order",
    )
}

pub async fn run_repository_scenarios(url: &str) -> ScenarioResult<ScenarioContext> {
    require_empty_database(url).await?;
    let repo = Repository::connect(url, SERVER_INSTANCE.into()).await?;
    let marker: String =
        sqlx::query_scalar("SELECT value FROM sync_v2.server_meta WHERE key='ddl_contract_marker'")
            .fetch_one(&repo.pool)
            .await?;
    ensure(
        marker == DDL_CONTRACT_MARKER,
        "fresh migration did not produce the current DDL contract marker",
    )?;
    let account_a = principal("scenario-account-a");
    let account_b = principal("scenario-account-b");
    exercise_concurrent_create(&repo, &account_a).await?;

    let fixture = fixture_root();
    let template_bytes = std::fs::read(fixture.join("snapshot.json"))?;
    let template = strict_json(&template_bytes)
        .map_err(|error| failure(format!("fixture manifest invalid: {error}")))?;
    let fixture_list: ObjectFixtureList =
        serde_json::from_slice(&std::fs::read(fixture.join("object-hashes.json"))?)?;
    let primary_work = Uuid::parse_str("00000000-0000-4000-8000-000000000002")?;
    let primary_document = Uuid::parse_str("00000000-0000-4000-8000-000000000003")?;
    let (create_command, _) =
        create_work(&repo, &account_a, primary_work, primary_document).await?;
    let mut first_object = None;
    let mut private_object = None;
    for object in &fixture_list.objects {
        let bytes = std::fs::read(fixture.join("objects").join(&object.file))?;
        let expected = decode_digest(&object.object_id).map_err(failure)?;
        ensure(
            bytes.len() == object.byte_count && sha256(&bytes) == expected,
            format!("fixture object {} has wrong digest/length", object.file),
        )?;
        let uploaded =
            upload_object(&repo, &account_a, primary_work, &bytes, [0x66; 32], 1).await?;
        ensure(uploaded == expected, "upload changed object identity")?;
        if first_object.is_none() {
            first_object = Some((uploaded, bytes));
        } else if private_object.is_none() {
            private_object = Some(uploaded);
        }
    }
    let (dedup_object_id, object_bytes) =
        first_object.ok_or_else(|| failure("no fixture objects"))?;
    let private_object_id = private_object.ok_or_else(|| failure("only one fixture object"))?;
    let mut idempotent_tx = repo.pool.begin().await?;
    repo.object_store
        .put(&mut idempotent_tx, &dedup_object_id, &object_bytes)
        .await?;
    idempotent_tx.commit().await?;
    let mut mismatch_tx = repo.pool.begin().await?;
    ensure(
        matches!(
            repo.object_store
                .put(&mut mismatch_tx, &dedup_object_id, b"different")
                .await,
            Err(SyncError::ObjectDigestMismatch)
        ),
        "immutable object store accepted mismatched bytes",
    )?;
    mismatch_tx.rollback().await?;
    let rolled_back_bytes = b"object-store-outer-rollback";
    let rolled_back_id = sha256(rolled_back_bytes);
    let mut failpoint_tx = repo.pool.begin().await?;
    repo.object_store
        .put(&mut failpoint_tx, &rolled_back_id, rolled_back_bytes)
        .await?;
    failpoint_tx.rollback().await?;
    let partial_blob: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM sync_v2.global_blobs WHERE object_id=$1)")
            .bind(rolled_back_id.as_slice())
            .fetch_one(&repo.pool)
            .await?;
    ensure(
        !partial_blob,
        "ObjectStore committed bytes outside the caller transaction",
    )?;
    exercise_upload_expiry(&repo, &account_a, primary_work).await?;

    let (root_snapshot, _) =
        register_snapshot(&repo, &account_a, primary_work, template_bytes, 1).await?;
    let (publish_command, status, publish_response) =
        publish(&repo, &account_a, primary_work, root_snapshot, 1, None).await?;
    ensure(status == 200, "fixture publish failed")?;
    ensure(
        repo.command(&account_a, &publish_command).await? == (status, publish_response.clone()),
        "lost ACK replay was not exact",
    )?;
    exercise_catalog_commit_race(&repo, &account_a, primary_work).await?;
    let restarted = Repository::connect(url, SERVER_INSTANCE.into()).await?;
    ensure(
        restarted.command(&account_a, &publish_command).await? == (status, publish_response),
        "receipt did not survive repository restart",
    )?;
    restarted.pool.close().await;
    exercise_auth_scope_rotation(&repo).await?;

    let base_title = fixture_list
        .objects
        .iter()
        .find(|object| object.file == "work-title.json")
        .ok_or_else(|| failure("fixture title missing"))?;
    let base_title_object = decode_digest(&base_title.object_id).map_err(failure)?;

    let server_graph = setup_conflicted_work(
        &repo,
        &account_a,
        &template,
        base_title_object,
        base_title.byte_count,
        Uuid::new_v4(),
        true,
    )
    .await?;
    resolve_server_and_restore(&repo, &account_a, &server_graph).await?;

    let device_graph = setup_conflicted_work(
        &repo,
        &account_a,
        &template,
        base_title_object,
        base_title.byte_count,
        Uuid::new_v4(),
        false,
    )
    .await?;
    resolve_device(&repo, &account_a, &device_graph).await?;

    let clone_graph = setup_conflicted_work(
        &repo,
        &account_a,
        &template,
        base_title_object,
        base_title.byte_count,
        Uuid::new_v4(),
        false,
    )
    .await?;
    let _clone_work = clone_work(&repo, &account_a, &clone_graph).await?;

    let active_graph = setup_conflicted_work(
        &repo,
        &account_a,
        &template,
        base_title_object,
        base_title.byte_count,
        Uuid::new_v4(),
        false,
    )
    .await?;
    let rejected_resolution =
        reject_mismatched_server_resolutions(&repo, &account_a, &active_graph).await?;
    let foreign_work = exercise_account_isolation(
        &repo,
        &account_a,
        &account_b,
        primary_work,
        dedup_object_id,
        &object_bytes,
        create_command.command_id,
    )
    .await?;
    exercise_migration_markers(url, &repo).await?;

    // Test-only catalog setup mirrors the repository writer lock; production
    // mutations append catalog events only through Repository.
    let mut tombstone_tx = repo.pool.begin().await?;
    sqlx::query(
        "SELECT pg_advisory_xact_lock(
             hashtextextended('sync_v2_catalog:' || $1, 0)
         )",
    )
    .bind(&account_a.account_id)
    .execute(&mut *tombstone_tx)
    .await?;
    sqlx::query(
        "INSERT INTO sync_v2.catalog_events(
             account_id,work_id,event_kind,head_generation,head_snapshot_id,title,tombstoned,created_at
         )
         SELECT account_id,work_id,'tombstone',head_generation,head_snapshot_id,'',true,now()
         FROM sync_v2.works WHERE account_id=$1 AND work_id=$2",
    )
    .bind(&account_a.account_id)
    .bind(primary_work)
    .execute(&mut *tombstone_tx)
    .await?;
    tombstone_tx.commit().await?;

    Ok(ScenarioContext {
        repo,
        account_a,
        account_b,
        primary_work,
        foreign_work,
        active_conflict_work: active_graph.work_id,
        history_work: server_graph.work_id,
        root_snapshot,
        object_id: private_object_id,
        receipt_id: create_command.command_id,
        rejected_resolution,
    })
}
