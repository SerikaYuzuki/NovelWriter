use crate::{
    application::{binding_matches, parse_command, strict_json},
    auth::{authenticate, RuntimeMode},
    domain::*,
    postgres::Repository,
};
use axum::{
    body::Bytes,
    extract::{DefaultBodyLimit, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::Response,
    routing::{get, post, put},
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use sqlx::Row;
use std::{collections::HashMap, sync::Arc};
use uuid::Uuid;

#[derive(Clone)]
pub struct AppState {
    pub repo: Arc<Repository>,
    pub runtime_mode: RuntimeMode,
}
fn error_response(error: SyncError) -> Response {
    let status = match error {
        SyncError::Unauthorized => StatusCode::UNAUTHORIZED,
        SyncError::AccountFenceMismatch => StatusCode::FORBIDDEN,
        SyncError::NotFound => StatusCode::NOT_FOUND,
        SyncError::CommandIdReused | SyncError::StaleHead | SyncError::StaleConflictRevision => {
            StatusCode::CONFLICT
        }
        SyncError::InvalidCanonicalBytes
        | SyncError::SchemaViolation(_)
        | SyncError::ObjectDigestMismatch
        | SyncError::SnapshotDigestMismatch
        | SyncError::LineageViolation
        | SyncError::SizeLimitExceeded => StatusCode::UNPROCESSABLE_ENTITY,
        _ => StatusCode::BAD_REQUEST,
    };
    let code = match &error {
        SyncError::InvalidCanonicalBytes => "invalidCanonicalBytes",
        SyncError::SchemaViolation(_) => "schemaViolation",
        SyncError::Unauthorized => "unauthorized",
        SyncError::AccountFenceMismatch => "accountFenceMismatch",
        SyncError::ProtocolEpochMismatch => "protocolEpochMismatch",
        SyncError::CommandIdReused => "commandIdReused",
        SyncError::NotFound => "notFoundInAccount",
        SyncError::StaleHead => "staleHead",
        SyncError::StaleConflictRevision => "staleConflictRevision",
        SyncError::ObjectDigestMismatch => "objectDigestMismatch",
        SyncError::SnapshotDigestMismatch => "snapshotDigestMismatch",
        SyncError::LineageViolation => "lineageViolation",
        SyncError::UploadCapabilityMismatch => "uploadCapabilityMismatch",
        SyncError::UploadExpired => "uploadExpired",
        SyncError::SizeLimitExceeded => "sizeLimitExceeded",
        SyncError::Retryable | SyncError::Database(_) => "retryable",
    };
    let retryable = matches!(error, SyncError::Retryable);
    let value = serde_json::json!({"error": code,"result":if retryable {"retryable"} else {"parked"},"retryable":retryable});
    let bytes = crate::domain::canonical_json(&value)
        .unwrap_or_else(|_| br#"{"error":"retryable"}"#.to_vec());
    Response::builder()
        .status(status)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
fn canonical_response(status: StatusCode, value: serde_json::Value) -> Response {
    let bytes = crate::domain::canonical_json(&value)
        .unwrap_or_else(|_| b"{\"error\":\"retryable\"}".to_vec());
    Response::builder()
        .status(status)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
const MAX_PAGE_SIZE: i64 = 500;
const DEFAULT_PAGE_SIZE: i64 = 100;

fn cursor_digest(endpoint: &str) -> String {
    hex::encode(sha256(endpoint.as_bytes()))
}

fn encode_cursor(value: serde_json::Value) -> Result<String, SyncError> {
    let bytes = canonical_json(&value).map_err(|_| SyncError::Retryable)?;
    Ok(URL_SAFE_NO_PAD.encode(bytes))
}

fn decode_cursor(encoded: &str) -> SyncResult<serde_json::Value> {
    if encoded.len() > 2048 {
        return Err(SyncError::SizeLimitExceeded);
    }
    let bytes = URL_SAFE_NO_PAD
        .decode(encoded)
        .map_err(|_| SyncError::SchemaViolation("cursor".into()))?;
    let value = strict_json(&bytes)?;
    if canonical_json(&value).map_err(|_| SyncError::InvalidCanonicalBytes)? != bytes {
        return Err(SyncError::InvalidCanonicalBytes);
    }
    Ok(value)
}

fn page_size(params: &HashMap<String, String>) -> SyncResult<i64> {
    let value = params
        .get("pageSize")
        .and_then(|value| value.parse::<i64>().ok())
        .unwrap_or(DEFAULT_PAGE_SIZE);
    if !(1..=MAX_PAGE_SIZE).contains(&value) {
        return Err(SyncError::SchemaViolation("pageSize".into()));
    }
    Ok(value)
}

fn cursor_scope(
    value: &serde_json::Value,
    endpoint: &str,
    p: &AuthenticatedPrincipal,
    page: i64,
    work: Option<Uuid>,
) -> SyncResult<(i64, String)> {
    if value.get("endpoint").and_then(serde_json::Value::as_str) != Some(endpoint)
        || value.get("accountId").and_then(serde_json::Value::as_str) != Some(p.account_id.as_str())
        || value
            .get("accountFence")
            .and_then(serde_json::Value::as_str)
            != Some(p.account_fence.as_str())
        || value
            .get("protocolEpoch")
            .and_then(serde_json::Value::as_i64)
            != Some(PROTOCOL_EPOCH)
        || value.get("queryDigest").and_then(serde_json::Value::as_str)
            != Some(cursor_digest(endpoint).as_str())
        || value.get("pageSize").and_then(serde_json::Value::as_i64) != Some(page)
    {
        return Err(SyncError::AccountFenceMismatch);
    }
    if let Some(work_id) = work {
        if value.get("workId").and_then(serde_json::Value::as_str)
            != Some(work_id.to_string().as_str())
        {
            return Err(SyncError::AccountFenceMismatch);
        }
    }
    let high = value
        .get("highWater")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| SyncError::SchemaViolation("cursor.highWater".into()))?;
    let last = value
        .get("last")
        .and_then(serde_json::Value::as_str)
        .unwrap_or_default()
        .to_owned();
    Ok((high, last))
}
#[allow(clippy::result_large_err)]
fn principal(headers: &HeaderMap, state: &AppState) -> Result<AuthenticatedPrincipal, Response> {
    let principal = authenticate(
        headers,
        state.runtime_mode,
        &state.repo.server_instance_id,
        "fixture-fence",
    )
    .map_err(error_response)?;
    if headers
        .get("x-fuminiwa-server-instance")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v != principal.server_instance_id)
    {
        return Err(error_response(SyncError::AccountFenceMismatch));
    }
    if headers
        .get("x-fuminiwa-account-fence")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v != principal.account_fence)
    {
        return Err(error_response(SyncError::AccountFenceMismatch));
    }
    if headers
        .get("x-fuminiwa-protocol-epoch")
        .and_then(|v| v.to_str().ok())
        .is_some_and(|v| v != principal.protocol_epoch.to_string())
    {
        return Err(error_response(SyncError::ProtocolEpochMismatch));
    }
    Ok(principal)
}
async fn command(headers: HeaderMap, state: State<AppState>, body: Bytes) -> Response {
    command_inner(headers, state, body, None).await
}
async fn command_inner(
    headers: HeaderMap,
    state: State<AppState>,
    body: Bytes,
    route_work_id: Option<Uuid>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let cmd = match parse_command(&body) {
        Ok(v) => v,
        Err(e) => return error_response(e),
    };
    if route_work_id.is_some_and(|route| route != cmd.work_id) {
        return error_response(SyncError::NotFound);
    }
    if !binding_matches(&cmd.value, &p) {
        return error_response(SyncError::AccountFenceMismatch);
    };
    match state.repo.command(&p, &cmd).await {
        Ok((status, bytes)) => Response::builder()
            .status(
                StatusCode::from_u16(status as u16).unwrap_or(StatusCode::INTERNAL_SERVER_ERROR),
            )
            .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
            .body(axum::body::Body::from(bytes))
            .unwrap(),
        Err(e) => error_response(e),
    }
}
async fn routed_command(
    Path(work_id): Path<Uuid>,
    headers: HeaderMap,
    state: State<AppState>,
    body: Bytes,
) -> Response {
    command_inner(headers, state, body, Some(work_id)).await
}
pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/v2/capabilities", get(capabilities))
        .route("/v2/works", get(list_works).post(command))
        .route("/v2/works/:work_id/head", get(head))
        .route("/v2/works/:work_id/history", get(history))
        .route("/v2/snapshots/:snapshot_id/manifest", get(manifest))
        .route("/v2/objects/:object_id", get(object))
        .route("/v2/objects/missing", post(missing_objects))
        .route("/v2/objects/prepare", post(command))
        .route("/v2/objects/finalize", post(command))
        .route("/v2/uploads/:upload_id", put(upload))
        .route("/v2/snapshots/register", post(command))
        .route("/v2/works/:work_id/publish", post(routed_command))
        .route("/v2/works/:work_id/conflict", get(conflict))
        .route("/v2/works/:work_id/conflict/resolve", post(routed_command))
        .route("/v2/works/:work_id/restore", post(routed_command))
        .route("/v2/receipts/:command_id", get(receipt))
        .layer(DefaultBodyLimit::max(MAX_OBJECT_BYTES))
        .with_state(state)
}
async fn capabilities(headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    canonical_response(
        StatusCode::OK,
        serde_json::json!({"accountId":p.account_id,"accountFence":p.account_fence,"serverInstanceId":p.server_instance_id,"protocolEpoch":PROTOCOL_EPOCH,"result":"noChanges","limits":{"maxObjectBytes":MAX_OBJECT_BYTES,"maxManifestBytes":MAX_MANIFEST_BYTES,"maxEntries":100000}}),
    )
}
async fn list_works(
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let requested_page = match page_size(&params) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let (high_water, last, page) = if let Some(encoded) = params.get("cursor") {
        let cursor = match decode_cursor(encoded) {
            Ok(value) => value,
            Err(error) => return error_response(error),
        };
        let page = match cursor.get("pageSize").and_then(serde_json::Value::as_i64) {
            Some(value) => value,
            None => return error_response(SyncError::SchemaViolation("cursor.pageSize".into())),
        };
        if params.contains_key("pageSize") && page != requested_page {
            return error_response(SyncError::SchemaViolation("cursor.pageSize".into()));
        }
        match cursor_scope(&cursor, "works", &p, page, None) {
            Ok((high, last)) => (high, last, page),
            Err(error) => return error_response(error),
        }
    } else {
        let high = match sqlx::query_scalar::<_, Option<i64>>(
            "SELECT MAX(event_id) FROM sync_v2.catalog_events WHERE account_id=$1",
        )
        .bind(&p.account_id)
        .fetch_one(&state.repo.pool)
        .await
        {
            Ok(value) => value.unwrap_or(0),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        (high, String::new(), requested_page)
    };
    let rows=sqlx::query("SELECT DISTINCT ON (c.work_id) c.work_id,c.head_generation,c.head_snapshot_id,c.title,c.tombstoned FROM sync_v2.catalog_events c WHERE c.account_id=$1 AND c.event_id <= $2 AND c.work_id::text > $3 ORDER BY c.work_id,c.event_id DESC LIMIT $4").bind(&p.account_id).bind(high_water).bind(&last).bind(page).fetch_all(&state.repo.pool).await;
    match rows {
        Ok(rows) => {
            let last_work = rows
                .last()
                .and_then(|row| row.try_get::<Uuid, _>("work_id").ok())
                .map(|value| value.to_string());
            let items:Vec<_>=rows.into_iter().filter_map(|r| {
                let work_id = r.try_get::<Uuid,_>("work_id").ok()?;
                let generation = r.try_get::<Option<i64>,_>("head_generation").ok().flatten()?;
                let snapshot = r.try_get::<Vec<u8>,_>("head_snapshot_id").ok()?;
                let title = r.try_get::<String,_>("title").ok()?;
                if r.try_get::<bool,_>("tombstoned").ok()? { return None; }
                Some(serde_json::json!({"workId":work_id,"title":title,"head":{"generation":generation,"snapshotId":hex::encode(snapshot)}}))
            }).collect();
            let next_cursor = if items.len() as i64 == page {
                last_work.and_then(|last| encode_cursor(serde_json::json!({"accountFence":p.account_fence,"accountId":p.account_id,"endpoint":"works","highWater":high_water,"last":last,"pageSize":page,"protocolEpoch":PROTOCOL_EPOCH,"queryDigest":cursor_digest("works")})).ok())
            } else {
                None
            };
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"items":items,"nextCursor":next_cursor,"result":"noChanges"}),
            )
        }
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn head(Path(work): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let row=sqlx::query("SELECT head_generation,head_snapshot_id FROM sync_v2.works WHERE account_id=$1 AND work_id=$2").bind(&p.account_id).bind(work).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let value=r.try_get::<Option<i64>,_>("head_generation").ok().flatten().map(|g|serde_json::json!({"generation":g,"snapshotId":hex::encode(r.try_get::<Vec<u8>,_>("head_snapshot_id").unwrap_or_default())}));
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"head":value,"result":"noChanges"}),
            )
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn history(
    Path(work): Path<Uuid>,
    headers: HeaderMap,
    Query(params): Query<HashMap<String, String>>,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let exists = match sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(&p.account_id)
        .bind(work)
        .fetch_optional(&state.repo.pool)
        .await
    {
        Ok(value) => value.is_some(),
        Err(error) => return error_response(SyncError::Database(error)),
    };
    if !exists {
        return error_response(SyncError::NotFound);
    }
    let requested_page = match page_size(&params) {
        Ok(value) => value,
        Err(error) => return error_response(error),
    };
    let (high_water, last, page) = if let Some(encoded) = params.get("cursor") {
        let cursor = match decode_cursor(encoded) {
            Ok(value) => value,
            Err(error) => return error_response(error),
        };
        let page = match cursor.get("pageSize").and_then(serde_json::Value::as_i64) {
            Some(value) => value,
            None => return error_response(SyncError::SchemaViolation("cursor.pageSize".into())),
        };
        if params.contains_key("pageSize") && page != requested_page {
            return error_response(SyncError::SchemaViolation("cursor.pageSize".into()));
        }
        match cursor_scope(&cursor, "history", &p, page, Some(work)) {
            Ok((high, last)) => match last.parse::<i64>() {
                Ok(last) if last >= 0 => (high, last, page),
                _ => return error_response(SyncError::SchemaViolation("cursor.last".into())),
            },
            Err(error) => return error_response(error),
        }
    } else {
        let high = match sqlx::query_scalar::<_, Option<i64>>(
            "SELECT MAX(event_id) FROM sync_v2.history WHERE account_id=$1 AND work_id=$2",
        )
        .bind(&p.account_id)
        .bind(work)
        .fetch_one(&state.repo.pool)
        .await
        {
            Ok(value) => value.unwrap_or(0),
            Err(error) => return error_response(SyncError::Database(error)),
        };
        (high, 0, requested_page)
    };
    let rows=sqlx::query("SELECT occurrence_id,snapshot_id,reason,pinned,created_at,event_id FROM sync_v2.history WHERE account_id=$1 AND work_id=$2 AND event_id <= $3 AND event_id > $4 ORDER BY event_id LIMIT $5").bind(&p.account_id).bind(work).bind(high_water).bind(last).bind(page).fetch_all(&state.repo.pool).await;
    match rows {
        Ok(rows) => canonical_response(StatusCode::OK, {
            let last_event = rows
                .last()
                .and_then(|row| row.try_get::<i64, _>("event_id").ok());
            let items = rows.into_iter().filter_map(|r| Some(serde_json::json!({"occurrenceId":r.try_get::<Uuid,_>("occurrence_id").ok()?,"snapshotId":hex::encode(r.try_get::<Vec<u8>,_>("snapshot_id").ok()?),"reason":r.try_get::<String,_>("reason").ok()? ,"pinned":r.try_get::<bool,_>("pinned").ok()?,"createdAt":r.try_get::<chrono::DateTime<chrono::Utc>,_>("created_at").ok()?.to_rfc3339()}))).collect::<Vec<_>>();
            let next_cursor = if items.len() as i64 == page {
                last_event.and_then(|last| encode_cursor(serde_json::json!({"accountFence":p.account_fence,"accountId":p.account_id,"endpoint":"history","highWater":high_water,"last":last.to_string(),"pageSize":page,"protocolEpoch":PROTOCOL_EPOCH,"queryDigest":cursor_digest("history"),"workId":work})).ok())
            } else {
                None
            };
            serde_json::json!({"items":items,"nextCursor":next_cursor,"result":"noChanges"})
        }),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn manifest(
    Path(snapshot): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let id = match decode_digest(&snapshot) {
        Ok(v) => v,
        Err(_) => return error_response(SyncError::NotFound),
    };
    let row=sqlx::query("SELECT manifest_bytes,manifest_digest FROM sync_v2.snapshots WHERE account_id=$1 AND snapshot_id=$2").bind(&p.account_id).bind(id.as_slice()).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let bytes: Vec<u8> = r.try_get("manifest_bytes").unwrap_or_default();
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"manifestBase64URL":URL_SAFE_NO_PAD.encode(bytes),"manifestBytesDigest":hex::encode(r.try_get::<Vec<u8>,_>("manifest_digest").unwrap_or_default()),"snapshotId":hex::encode(id),"result":"noChanges"}),
            )
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn object(
    Path(object): Path<String>,
    headers: HeaderMap,
    state: State<AppState>,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let id = match decode_digest(&object) {
        Ok(v) => v,
        Err(_) => return error_response(SyncError::NotFound),
    };
    let row=sqlx::query("SELECT b.raw_bytes FROM sync_v2.global_blobs b JOIN sync_v2.account_objects a ON a.object_id=b.object_id WHERE a.account_id=$1 AND a.object_id=$2 AND a.state='available'").bind(&p.account_id).bind(id.as_slice()).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => {
            let bytes: Vec<u8> = r.try_get("raw_bytes").unwrap_or_default();
            Response::builder()
                .status(200)
                .header("content-type", "application/octet-stream")
                .header("x-fuminiwa-object-digest", hex::encode(id))
                .header("x-fuminiwa-byte-count", bytes.len().to_string())
                .header("x-fuminiwa-result", "noChanges")
                .body(axum::body::Body::from(bytes))
                .unwrap()
        }
        Ok(None) => error_response(SyncError::NotFound),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn missing_objects(headers: HeaderMap, state: State<AppState>, body: Bytes) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let value = match strict_json(&body) {
        Ok(v) => v,
        Err(e) => return error_response(e),
    };
    if canonical_json(&value).ok().as_deref() != Some(body.as_ref()) {
        return error_response(SyncError::SchemaViolation("missing objects request".into()));
    }
    if value
        .get("schemaVersion")
        .and_then(serde_json::Value::as_i64)
        != Some(PROTOCOL_EPOCH)
        || value
            .as_object()
            .map(|object| {
                object
                    .keys()
                    .any(|key| !["objectIds", "schemaVersion", "workId"].contains(&key.as_str()))
            })
            .unwrap_or(true)
    {
        return error_response(SyncError::SchemaViolation("missing objects request".into()));
    }
    let work = match value
        .get("workId")
        .and_then(serde_json::Value::as_str)
        .and_then(|value| Uuid::parse_str(value).ok())
    {
        Some(work) => work,
        None => return error_response(SyncError::SchemaViolation("workId".into())),
    };
    if value.get("workId").and_then(serde_json::Value::as_str) != Some(work.to_string().as_str()) {
        return error_response(SyncError::SchemaViolation("workId".into()));
    }
    if !sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(&p.account_id)
        .bind(work)
        .fetch_optional(&state.repo.pool)
        .await
        .map(|value| value.is_some())
        .unwrap_or(false)
    {
        return error_response(SyncError::NotFound);
    }
    let Some(ids) = value.get("objectIds").and_then(serde_json::Value::as_array) else {
        return error_response(SyncError::SchemaViolation("objectIds".into()));
    };
    if ids.len() > 100_000 {
        return error_response(SyncError::SizeLimitExceeded);
    }
    let mut missing = Vec::new();
    let mut seen = std::collections::HashSet::new();
    for id in ids {
        let Some(text) = id.as_str() else {
            return error_response(SyncError::SchemaViolation("objectIds".into()));
        };
        let digest = match decode_digest(text) {
            Ok(v) => v,
            Err(e) => return error_response(e),
        };
        if !seen.insert(digest) {
            return error_response(SyncError::SchemaViolation("objectIds.unique".into()));
        }
        let found = match sqlx::query("SELECT 1 FROM sync_v2.account_objects WHERE account_id=$1 AND object_id=$2 AND state='available'")
            .bind(&p.account_id)
            .bind(digest.as_slice())
            .fetch_optional(&state.repo.pool)
            .await
        {
            Ok(v) => v.is_some(),
            Err(e) => return error_response(SyncError::Database(e)),
        };
        if !found {
            missing.push(serde_json::Value::String(text.to_owned()));
        }
    }
    let response = serde_json::json!({
        "missingObjectIds": missing,
        "result": if missing.is_empty() { "noChanges" } else { "applied" }
    });
    let bytes = match crate::domain::canonical_json(&response) {
        Ok(v) => v,
        Err(_) => return error_response(SyncError::Retryable),
    };
    Response::builder()
        .status(StatusCode::OK)
        .header("content-type", "application/vnd.fuminiwa.sync.v2+jcs")
        .body(axum::body::Body::from(bytes))
        .unwrap()
}
async fn upload(
    Path(upload): Path<Uuid>,
    headers: HeaderMap,
    state: State<AppState>,
    body: Bytes,
) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let Some(capability) = headers
        .get("x-fuminiwa-upload-capability")
        .and_then(|v| v.to_str().ok())
    else {
        return error_response(SyncError::UploadCapabilityMismatch);
    };
    match state.repo.upload(&p, upload, capability, &body).await {
        Ok(()) => Response::builder()
            .status(StatusCode::NO_CONTENT)
            .header("x-fuminiwa-result", "applied")
            .body(axum::body::Body::empty())
            .unwrap(),
        Err(e) => error_response(e),
    }
}
async fn conflict(Path(work): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    let exists = match sqlx::query("SELECT 1 FROM sync_v2.works WHERE account_id=$1 AND work_id=$2")
        .bind(&p.account_id)
        .bind(work)
        .fetch_optional(&state.repo.pool)
        .await
    {
        Ok(value) => value.is_some(),
        Err(error) => return error_response(SyncError::Database(error)),
    };
    if !exists {
        return error_response(SyncError::NotFound);
    }
    let row=sqlx::query("SELECT a.conflict_id,a.current_revision,a.source_generation,c.base_snapshot_id,c.local_snapshot_id,c.remote_snapshot_id FROM sync_v2.active_conflicts a JOIN sync_v2.conflict_candidates c ON c.account_id=a.account_id AND c.conflict_id=a.conflict_id AND c.revision=a.current_revision WHERE a.account_id=$1 AND a.work_id=$2 AND a.state='active'").bind(&p.account_id).bind(work).fetch_optional(&state.repo.pool).await;
    match row {
        Ok(Some(r)) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"conflict":{"baseSnapshotId":r.try_get::<Option<Vec<u8>>,_>("base_snapshot_id").ok().flatten().map(hex::encode),"conflictId":r.try_get::<Uuid,_>("conflict_id").ok(),"localSnapshotId":hex::encode(r.try_get::<Vec<u8>,_>("local_snapshot_id").unwrap_or_default()),"remoteSnapshotId":hex::encode(r.try_get::<Vec<u8>,_>("remote_snapshot_id").unwrap_or_default()),"revision":r.try_get::<i64,_>("current_revision").ok(),"sourceGeneration":r.try_get::<i64,_>("source_generation").ok(),"workId":work},"result":"noChanges"}),
        ),
        Ok(None) => canonical_response(
            StatusCode::OK,
            serde_json::json!({"conflict":null,"result":"noChanges"}),
        ),
        Err(e) => error_response(SyncError::Database(e)),
    }
}
async fn receipt(Path(id): Path<Uuid>, headers: HeaderMap, state: State<AppState>) -> Response {
    let p = match principal(&headers, &state) {
        Ok(v) => v,
        Err(e) => return e,
    };
    match state.repo.receipt(&p, id).await {
        Ok((kind, work_id, request_digest, bytes, _status)) => {
            let original = serde_json::from_slice::<serde_json::Value>(&bytes).ok();
            let result = original
                .as_ref()
                .and_then(|value| value.get("result"))
                .cloned()
                .unwrap_or_else(|| serde_json::Value::String("retryable".into()));
            let read_back = original.as_ref().and_then(|value| value.get("receipt").and_then(|receipt| receipt.get("readBack"))).cloned().unwrap_or_else(|| serde_json::json!({"accountMatched":false,"commandDigestMatched":false,"headMatched":false,"resourceMatched":false,"stateMatched":false}));
            canonical_response(
                StatusCode::OK,
                serde_json::json!({"commandId":id,"commandKind":kind,"workId":work_id,"requestDigest":hex::encode(request_digest),"canonicalResponseBase64URL":URL_SAFE_NO_PAD.encode(bytes),"originalResult":result,"readBack":read_back,"result":"noChanges"}),
            )
        }
        Err(e) => error_response(e),
    }
}
fn decode_digest(value: &str) -> Result<[u8; 32], SyncError> {
    crate::domain::decode_digest(value).map_err(|_| SyncError::NotFound)
}
